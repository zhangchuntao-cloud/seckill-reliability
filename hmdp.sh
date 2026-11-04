#!/usr/bin/env bash
#
# 黑马点评 —— 一键启动 / 停止 / 查看状态
#
#   ./hmdp.sh start      启动中间件 + 应用
#   ./hmdp.sh stop       停止应用 + 中间件
#   ./hmdp.sh restart    重启
#   ./hmdp.sh status     查看各组件状态
#   ./hmdp.sh logs       跟踪应用日志
#   ./hmdp.sh build      重新打包（改了 Java 代码后用）
#   ./hmdp.sh clean      停止并清空所有数据卷（会重新导入建表脚本）
#
# 设计原则：
#   - 幂等：重复执行 start 不会起第二份进程
#   - 快速失败：前置条件不满足时给出明确提示，而不是跑到一半报错
#   - 不依赖 IDE：产出的是可独立运行的 jar

set -uo pipefail

# ---------------------------------------------------------------- 基础配置

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

APP_PORT=8081
JAR="target/hm-dianping-0.0.1-SNAPSHOT.jar"
RUN_DIR=".run"
PID_FILE="$RUN_DIR/hmdp.pid"
APP_LOG="$RUN_DIR/app.log"
MIN_JDK=17

C_RESET='\033[0m'; C_GREEN='\033[32m'; C_RED='\033[31m'
C_YELLOW='\033[33m'; C_BLUE='\033[36m'; C_DIM='\033[2m'

info()  { printf "${C_BLUE}▸${C_RESET} %s\n" "$*"; }
ok()    { printf "${C_GREEN}✓${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}!${C_RESET} %s\n" "$*"; }
fail()  { printf "${C_RED}✗${C_RESET} %s\n" "$*" >&2; }

# ---------------------------------------------------------------- 前置检查

detect_jdk() {
    # 优先用 JAVA_HOME；否则找本机 JDK 17+
    if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]]; then
        local major
        major=$("$JAVA_HOME/bin/java" -version 2>&1 | awk -F'"' '/version/ {print $2}' | cut -d. -f1)
        if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= MIN_JDK )); then
            return 0
        fi
        warn "JAVA_HOME 指向的 JDK 版本是 $major，低于 $MIN_JDK"
    fi

    # macOS 用 java_home 找
    if [[ -x /usr/libexec/java_home ]]; then
        local found
        found=$(/usr/libexec/java_home -v "$MIN_JDK" 2>/dev/null || true)
        if [[ -n "$found" ]]; then
            export JAVA_HOME="$found"
            ok "自动找到 JDK: $JAVA_HOME"
            return 0
        fi
    fi

    # 最后看 PATH 里的 java
    if command -v java >/dev/null 2>&1; then
        local major
        major=$(java -version 2>&1 | awk -F'"' '/version/ {print $2}' | cut -d. -f1)
        if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= MIN_JDK )); then
            ok "使用 PATH 中的 JDK $major"
            return 0
        fi
        fail "PATH 中的 JDK 是 $major，本项目需要 $MIN_JDK+"
    else
        fail "未找到 java"
    fi

    fail "请安装 JDK $MIN_JDK 或设置 JAVA_HOME 后重试"
    return 1
}

check_prereqs() {
    info "检查前置条件"
    detect_jdk || exit 1

    if ! command -v docker >/dev/null 2>&1; then
        fail "未找到 docker"; exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        fail "docker compose 不可用（需要 Compose v2）"; exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        fail "Docker 引擎未运行，请先启动 Docker Desktop"; exit 1
    fi
    ok "Docker $(docker compose version --short 2>/dev/null || echo '')"
}

# ---------------------------------------------------------------- 进程管理

app_pid() {
    [[ -f "$PID_FILE" ]] || return 1
    local pid; pid=$(cat "$PID_FILE" 2>/dev/null || true)
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && { echo "$pid"; return 0; }
    return 1
}

port_in_use() {
    nc -z 127.0.0.1 "$1" >/dev/null 2>&1
}

wait_for() {
    # wait_for <描述> <超时秒> <命令...>
    local desc="$1" timeout="$2"; shift 2
    local waited=0
    while (( waited < timeout )); do
        if "$@" >/dev/null 2>&1; then
            ok "$desc 就绪（${waited}s）"
            return 0
        fi
        sleep 2; waited=$((waited + 2))
        printf "${C_DIM}  ...等待 %s（%ss/%ss）${C_RESET}\r" "$desc" "$waited" "$timeout"
    done
    printf "\n"
    fail "$desc 在 ${timeout}s 内未就绪"
    return 1
}

# ---------------------------------------------------------------- 启动

start_infra() {
    info "启动中间件（MySQL / Redis / RabbitMQ / Prometheus / Grafana）"
    docker compose up -d 2>&1 | tail -3

    wait_for "MySQL" 90 bash -c \
        "docker compose ps mysql --format '{{.Health}}' 2>/dev/null | grep -q healthy" || exit 1
    wait_for "Redis" 60 bash -c \
        "redis-cli -p 6380 ping 2>/dev/null | grep -q PONG || nc -z 127.0.0.1 6380" || exit 1
    wait_for "RabbitMQ" 90 bash -c \
        "curl -sf -u guest:guest http://127.0.0.1:15673/api/overview >/dev/null" || exit 1
    wait_for "Prometheus" 60 bash -c \
        "curl -sf http://127.0.0.1:9090/-/healthy >/dev/null" || exit 1
    wait_for "Grafana" 60 bash -c \
        "curl -sf http://127.0.0.1:3000/api/health >/dev/null" || exit 1

    # 首次启动时 MySQL 要跑完建表脚本，确认表真的建出来了
    local tables
    tables=$(mysql -h127.0.0.1 -P3307 -uroot -proot -N -e \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='dingping';" 2>/dev/null || echo 0)
    if [[ "$tables" -ge 11 ]]; then
        ok "数据库已就绪（$tables 张表）"
    else
        warn "数据库只有 $tables 张表（应为 11）。若是首次启动请再等几秒；"
        warn "若持续如此，执行 ./hmdp.sh clean 重新初始化"
    fi
}

build_app() {
    if [[ -f "$JAR" && "${1:-}" != "--force" ]]; then
        # 源码比 jar 新就重新打包
        if [[ -z "$(find src -newer "$JAR" -name '*.java' -o -newer "$JAR" -name '*.yaml' 2>/dev/null | head -1)" ]]; then
            ok "jar 已是最新，跳过打包"
            return 0
        fi
        warn "源码有更新，重新打包"
    fi

    info "打包（首次会下载依赖，可能较慢）"
    if ! mvn -B -q clean package -DskipTests; then
        fail "打包失败"
        exit 1
    fi
    ok "打包完成：$JAR"
}

start_app() {
    if app_pid >/dev/null; then
        ok "应用已在运行（PID $(app_pid)）"
        return 0
    fi
    if port_in_use "$APP_PORT"; then
        # 端口被占用但本脚本没有 PID 记录 —— 可能是之前用 IDE 或 mvn 手动起的。
        # 如果健康检查通过，说明就是本项目，直接复用，不要报错。
        if curl -sf "http://127.0.0.1:$APP_PORT/actuator/health" 2>/dev/null | grep -q '"status":"UP"'; then
            warn "端口 $APP_PORT 上已有本项目的应用在运行（非本脚本启动，无 PID 记录）"
            ok "直接复用，跳过启动"
            return 0
        fi
        fail "端口 $APP_PORT 已被占用，且健康检查未通过"
        fail "查看占用：lsof -i :$APP_PORT"
        exit 1
    fi

    mkdir -p "$RUN_DIR"
    info "启动应用"
    nohup java -jar "$JAR" > "$APP_LOG" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    disown 2>/dev/null || true

    if wait_for "应用" 90 bash -c \
        "curl -sf http://127.0.0.1:$APP_PORT/actuator/health | grep -q '\"status\":\"UP\"'"; then
        ok "应用已启动（PID $pid）"
    else
        fail "应用启动失败，最近日志："
        tail -30 "$APP_LOG" >&2
        exit 1
    fi
}

print_urls() {
    echo
    printf "${C_GREEN}════════════════════════════════════════════════════${C_RESET}\n"
    printf "  应用        ${C_BLUE}http://localhost:%s${C_RESET}\n" "$APP_PORT"
    printf "  ${C_YELLOW}监控大盘${C_RESET}    ${C_BLUE}http://localhost:3000/d/hmdp-seckill${C_RESET}\n"
    printf "  Prometheus  ${C_BLUE}http://localhost:9090${C_RESET}\n"
    printf "  RabbitMQ    ${C_BLUE}http://localhost:15673${C_RESET}  (guest/guest)\n"
    printf "  指标原始值  ${C_BLUE}http://localhost:%s/actuator/prometheus${C_RESET}\n" "$APP_PORT"
    printf "${C_GREEN}════════════════════════════════════════════════════${C_RESET}\n"
    echo
    printf "  压测：  ${C_DIM}python3 scripts/seckill-loadtest.py --users 300${C_RESET}\n"
    printf "  日志：  ${C_DIM}./hmdp.sh logs${C_RESET}\n"
    printf "  状态：  ${C_DIM}./hmdp.sh status${C_RESET}\n"
    echo
}

cmd_start() {
    echo
    info "黑马点评 —— 一键启动"
    echo
    check_prereqs
    start_infra
    build_app
    start_app
    print_urls
}

# ---------------------------------------------------------------- 停止

cmd_stop() {
    info "停止应用"
    if app_pid >/dev/null; then
        kill "$(app_pid)" 2>/dev/null || true
        for _ in $(seq 1 15); do
            app_pid >/dev/null || break
            sleep 1
        done
        app_pid >/dev/null && kill -9 "$(app_pid)" 2>/dev/null || true
        ok "应用已停止"
    else
        ok "应用未在运行"
    fi
    rm -f "$PID_FILE"

    info "停止中间件"
    docker compose down 2>&1 | tail -2
    ok "中间件已停止（数据保留）"
}

# ---------------------------------------------------------------- 状态

cmd_status() {
    echo
    local pid; pid=$(app_pid 2>/dev/null || echo "")
    if [[ -n "$pid" ]]; then
        if curl -sf "http://127.0.0.1:$APP_PORT/actuator/health" | grep -q '"status":"UP"'; then
            ok "应用       运行中（PID $pid，健康检查 UP）"
        else
            warn "应用       进程存在（PID $pid），但健康检查未通过"
        fi
    elif port_in_use "$APP_PORT" && \
         curl -sf "http://127.0.0.1:$APP_PORT/actuator/health" 2>/dev/null | grep -q '"status":"UP"'; then
        # 端口活着且健康检查通过，但没有 PID 文件 —— 通常是 IDE / mvn 手动起的
        warn "应用       运行中（非本脚本启动，无 PID 记录；stop 不会停止它）"
    else
        fail "应用       未运行"
    fi

    echo
    printf "  中间件：\n"
    docker compose ps --format '    {{.Name}}\t{{.Status}}' 2>/dev/null || echo "    （未启动）"

    echo
    printf "  端口：\n"
    for p in "$APP_PORT" 3307 6380 5673 15673 9090 3000; do
        if port_in_use "$p"; then printf "    ${C_GREEN}✓${C_RESET} %s\n" "$p"
        else printf "    ${C_RED}✗${C_RESET} %s\n" "$p"; fi
    done
    echo
}

# ---------------------------------------------------------------- 其它

cmd_logs() {
    [[ -f "$APP_LOG" ]] || { fail "日志不存在：$APP_LOG"; exit 1; }
    info "跟踪 $APP_LOG（Ctrl-C 退出）"
    tail -f "$APP_LOG"
}

cmd_build() {
    check_prereqs
    build_app --force
}

cmd_clean() {
    warn "这会删除所有数据卷（数据库数据、Redis、RabbitMQ、Grafana 配置）"
    read -r -p "确认？[y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消"; exit 0; }
    cmd_stop
    docker compose down -v 2>&1 | tail -2
    rm -rf "$RUN_DIR"
    ok "已清空。下次 start 会重新导入建表脚本"
}

# ---------------------------------------------------------------- 入口

case "${1:-start}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_stop; echo; cmd_start ;;
    status)  cmd_status ;;
    logs)    cmd_logs ;;
    build)   cmd_build ;;
    clean)   cmd_clean ;;
    -h|--help|help)
        sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        fail "未知命令：$1"
        echo "可用命令：start | stop | restart | status | logs | build | clean"
        exit 1
        ;;
esac
