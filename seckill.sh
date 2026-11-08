#!/usr/bin/env bash
#
# 黑马点评 —— 一键启动 / 停止 / 查看状态
#
#   ./seckill.sh start      启动中间件 + 应用
#   ./seckill.sh stop       停止应用 + 中间件
#   ./seckill.sh restart    重启
#   ./seckill.sh status     查看各组件状态
#   ./seckill.sh logs       跟踪应用日志
#   ./seckill.sh build      重新打包（改了 Java 代码后用）
#   ./seckill.sh clean      停止并清空所有数据卷（会重新导入建表脚本）
#
# 设计原则：
#   - 幂等：重复执行 start 不会起第二份进程
#   - 快速失败：前置条件不满足时给出明确提示，而不是跑到一半报错
#   - 不依赖 IDE：产出的是可独立运行的 jar
#   - 跨平台：macOS / Linux / Windows（Git Bash、MSYS2）
#
# Windows 说明：
#   不需要预装 mvn / nc / mysql / redis-cli —— 这些 Linux/macOS 上顺手的工具
#   在 Git Bash 里往往没有。脚本改为：
#     * Maven：依次找 PATH、./mvnw、~/.m2/wrapper、IDEA 自带目录
#     * 端口探测：用 bash 自带的 /dev/tcp，没有才退回 nc
#     * MySQL / Redis 检查：走 docker exec，不依赖本机客户端
#     * 进程管理：用 jps 找到真实的 Windows PID，停止时走 taskkill

set -uo pipefail

# ---------------------------------------------------------------- 基础配置

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

APP_PORT=8081
JAR_NAME="seckill-reliability-0.0.1-SNAPSHOT.jar"
JAR="target/$JAR_NAME"
RUN_DIR=".run"
PID_FILE="$RUN_DIR/hmdp.pid"
APP_LOG="$RUN_DIR/app.log"
MIN_JDK=17
PROJECT_NAME="seckill-reliability"

# 中间件在宿主机上监听的端口，以及各自对应的 compose 服务名
INFRA_SPECS=(
    "mysql:3307"
    "redis:6380"
    "rabbitmq:5673"
    "rabbitmq:15673"
    "prometheus:9090"
    "grafana:3000"
)

IS_WINDOWS=0
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
esac

C_RESET='\033[0m'; C_GREEN='\033[32m'; C_RED='\033[31m'
C_YELLOW='\033[33m'; C_BLUE='\033[36m'; C_DIM='\033[2m'

info()  { printf "${C_BLUE}▸${C_RESET} %s\n" "$*"; }
ok()    { printf "${C_GREEN}✓${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}!${C_RESET} %s\n" "$*"; }
fail()  { printf "${C_RED}✗${C_RESET} %s\n" "$*" >&2; }

# ---------------------------------------------------------------- 平台工具

# Git Bash 的路径是 /d/xxx，而 Windows 程序（cmd、mvn.cmd）要 D:\xxx
to_win_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1" 2>/dev/null || printf '%s' "$1"
    else
        printf '%s' "$1"
    fi
}

# JAVA_HOME 常写成 D:\APP\jdk17，bash 里要 /d/APP/jdk17
to_unix_path() {
    local p="$1"
    if [[ $IS_WINDOWS -eq 1 ]] && command -v cygpath >/dev/null 2>&1 && [[ "$p" == *\\* ]]; then
        cygpath -u "$p" 2>/dev/null || printf '%s' "$p"
    else
        printf '%s' "$p"
    fi
}

# ---------------------------------------------------------------- 前置检查

JAVA_BIN=""
JPS_BIN=""
MVN_CMD=""

java_major() {
    "$1" -version 2>&1 | awk -F'"' '/version/ {print $2}' | cut -d. -f1
}

detect_jdk() {
    local home_bin major

    if [[ -n "${JAVA_HOME:-}" ]]; then
        home_bin="$(to_unix_path "$JAVA_HOME")"
        if [[ -x "$home_bin/bin/java" ]]; then
            major="$(java_major "$home_bin/bin/java")"
            if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= MIN_JDK )); then
                JAVA_BIN="$home_bin/bin/java"
                [[ -x "$home_bin/bin/jps" ]] && JPS_BIN="$home_bin/bin/jps"
                ok "使用 JAVA_HOME 的 JDK $major"
                return 0
            fi
            warn "JAVA_HOME 指向的 JDK 版本是 $major，低于 $MIN_JDK"
        else
            warn "JAVA_HOME 无效：$JAVA_HOME"
        fi
    fi

    # macOS 用 java_home 找
    if [[ -x /usr/libexec/java_home ]]; then
        local found
        found="$(/usr/libexec/java_home -v "$MIN_JDK" 2>/dev/null || true)"
        if [[ -n "$found" ]]; then
            export JAVA_HOME="$found"
            JAVA_BIN="$found/bin/java"
            [[ -x "$found/bin/jps" ]] && JPS_BIN="$found/bin/jps"
            ok "自动找到 JDK: $JAVA_HOME"
            return 0
        fi
    fi

    # Windows 常见安装位置
    if [[ $IS_WINDOWS -eq 1 ]]; then
        local d
        for d in "/c/Program Files/Java"/jdk-* \
                 "/c/Program Files/Eclipse Adoptium"/jdk-* \
                 "/c/Program Files/Microsoft"/jdk-* \
                 "/d/APP/APP_code"/jdk*; do
            [[ -x "$d/bin/java" ]] || continue
            major="$(java_major "$d/bin/java")"
            if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= MIN_JDK )); then
                export JAVA_HOME="$(to_win_path "$d")"
                JAVA_BIN="$d/bin/java"
                [[ -x "$d/bin/jps" ]] && JPS_BIN="$d/bin/jps"
                ok "自动找到 JDK: $JAVA_HOME"
                return 0
            fi
        done
    fi

    # 最后看 PATH 里的 java
    if command -v java >/dev/null 2>&1; then
        major="$(java_major "$(command -v java)")"
        if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= MIN_JDK )); then
            JAVA_BIN="$(command -v java)"
            command -v jps >/dev/null 2>&1 && JPS_BIN="$(command -v jps)"
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

# 找一个可用的 Maven。Windows 上 mvn 通常不在 PATH 里，
# 但 IDEA / Maven Wrapper 留下的分发包一般都在 ~/.m2/wrapper 下。
# Windows 上优先用 mvn.cmd：Git Bash 能直接执行它，而 mvn 那个 shell 脚本
# 在部分 MSYS 环境下会被路径转换绊住。
prefer_mvn_cmd() {
    local m="$1"
    if [[ $IS_WINDOWS -eq 1 && "$m" != *.cmd && -f "${m%/mvn}/mvn.cmd" ]]; then
        printf '%s' "${m%/mvn}/mvn.cmd"
    else
        printf '%s' "$m"
    fi
}

detect_maven() {
    local d

    if command -v mvn >/dev/null 2>&1; then
        MVN_CMD="$(prefer_mvn_cmd "$(command -v mvn)")"
        return 0
    fi
    if [[ -x "./mvnw" ]]; then
        MVN_CMD="./mvnw"
        return 0
    fi
    for d in "$HOME"/.m2/wrapper/dists/*/*/apache-maven-*/bin/mvn; do
        [[ -x "$d" ]] && { MVN_CMD="$(prefer_mvn_cmd "$d")"; return 0; }
    done
    if [[ $IS_WINDOWS -eq 1 ]]; then
        for d in "/c/Program Files/JetBrains"/*/plugins/maven/lib/maven3/bin/mvn \
                 "/c/Program Files (x86)/JetBrains"/*/plugins/maven/lib/maven3/bin/mvn \
                 "$HOME"/AppData/Local/JetBrains/*/plugins/maven/lib/maven3/bin/mvn \
                 "$HOME"/AppData/Local/Programs/*/plugins/maven/lib/maven3/bin/mvn; do
            [[ -x "$d" ]] && { MVN_CMD="$(prefer_mvn_cmd "$d")"; return 0; }
        done
    fi
    return 1
}

run_mvn() {
    # mvn.cmd 读 %JAVA_HOME%，若 JAVA_HOME 是 POSIX 形式（/d/...）要转成 D:\...
    (
        if [[ $IS_WINDOWS -eq 1 && "$MVN_CMD" == *.cmd && -n "${JAVA_HOME:-}" ]]; then
            export JAVA_HOME="$(to_win_path "$JAVA_HOME")"
        fi
        exec "$MVN_CMD" "$@"
    )
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
    if ! command -v curl >/dev/null 2>&1; then
        fail "未找到 curl"; exit 1
    fi
    ok "Docker $(docker compose version --short 2>/dev/null || echo '')"
}

# ---------------------------------------------------------------- 端口 / 容器

# 不依赖 nc：bash 自带 /dev/tcp；没有 /dev/tcp 的环境再退回 nc
port_in_use() {
    local p="$1"
    if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
        return 0
    fi
    if command -v nc >/dev/null 2>&1; then
        nc -z 127.0.0.1 "$p" >/dev/null 2>&1 && return 0
    fi
    return 1
}

container_id() {
    docker compose ps -a -q "$1" 2>/dev/null | head -1
}

container_healthy() {
    local cid st
    cid="$(container_id "$1")"
    [[ -n "$cid" ]] || return 1
    st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid" 2>/dev/null)"
    [[ "$st" == "healthy" ]]
}

# 服务容器是否真的把宿主机端口映射出来了。
# 历史上出现过：端口冲突时 compose 创建了容器但没绑上端口，
# 之后 up -d 只 start 不重建，容器看着健康、宿主机却连不上。
ports_published() {
    local svc="$1" port="$2"
    docker compose ps -a "$svc" --format '{{.Ports}}' 2>/dev/null | grep -q ":$port->"
}

# 同一份 compose 文件、不同项目名的历史容器会抢占端口
# （本项目从 dianping 改名为 seckill-reliability 后就踩过这个坑）。
cleanup_conflicting_projects() {
    local spec p owner done_list=","
    for spec in "${INFRA_SPECS[@]}"; do
        p="${spec##*:}"
        owner="$(docker ps --filter "publish=$p" --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | head -1)"
        [[ -z "$owner" ]] && continue
        [[ "$owner" == "$PROJECT_NAME" ]] && continue
        case "$done_list" in *",$owner,"*) continue ;; esac
        done_list="$done_list$owner,"
        warn "端口 $p 被旧 compose 项目 '$owner' 占用，停止它释放端口（数据卷保留）"
        docker compose -p "$owner" down 2>&1 | tail -2
    done
}

# ---------------------------------------------------------------- 进程管理

# 优先用 jps 按 jar 名找进程：Windows 下 $! 拿到的是 MSYS 虚拟 PID，
# 和 taskkill 要的 Windows PID 对不上。
app_pid() {
    local pid jps_bin="${JPS_BIN:-}"

    # status/stop 不一定会先跑 detect_jdk，这里再兜底找一次 jps
    if [[ -z "$jps_bin" || ! -x "$jps_bin" ]]; then
        jps_bin="$(command -v jps 2>/dev/null || true)"
    fi

    if [[ -n "$jps_bin" && -x "$jps_bin" ]]; then
        pid="$("$jps_bin" -l 2>/dev/null | awk -v n="$JAR_NAME" '
            { p = $2; sub(/.*[\\\/]/, "", p); if (p == n) { print $1; exit } }')"
        if [[ -n "$pid" ]]; then echo "$pid"; return 0; fi
    fi

    [[ -f "$PID_FILE" ]] || return 1
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] || return 1
    if [[ $IS_WINDOWS -eq 1 ]]; then
        tasklist //FI "PID eq $pid" 2>/dev/null | grep -q "$pid" && { echo "$pid"; return 0; }
    else
        kill -0 "$pid" 2>/dev/null && { echo "$pid"; return 0; }
    fi
    return 1
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
    cleanup_conflicting_projects
    docker compose up -d 2>&1 | tail -3

    # 端口没映射出来的话，强制重建一次（见 ports_published 的注释）
    local spec svc port need=0
    for spec in "${INFRA_SPECS[@]}"; do
        svc="${spec%%:*}"; port="${spec##*:}"
        ports_published "$svc" "$port" || need=1
    done
    if (( need )); then
        warn "有容器未正确发布端口，强制重建"
        docker compose up -d --force-recreate 2>&1 | tail -2
    fi

    wait_for "MySQL" 90 container_healthy mysql || exit 1
    wait_for "Redis" 60 container_healthy redis || exit 1
    wait_for "RabbitMQ" 90 curl -sf -u guest:guest http://127.0.0.1:15673/api/overview || exit 1
    wait_for "Prometheus" 60 curl -sf http://127.0.0.1:9090/-/healthy || exit 1
    wait_for "Grafana" 60 curl -sf http://127.0.0.1:3000/api/health || exit 1

    # 首次启动时 MySQL 要跑完建表脚本，确认表真的建出来了。
    # 走 docker exec，不要求宿主机装 mysql 客户端。
    local cid tables=0 waited=0
    cid="$(container_id mysql)"
    if [[ -n "$cid" ]]; then
        while (( waited < 60 )); do
            tables="$(docker exec "$cid" mysql -uroot -proot -N -e \
                "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='dingping';" \
                2>/dev/null | tr -d '\r' | head -1 || true)"
            [[ "$tables" =~ ^[0-9]+$ ]] && (( tables >= 11 )) && break
            sleep 2; waited=$((waited + 2))
        done
    fi
    if [[ "$tables" =~ ^[0-9]+$ ]] && (( tables >= 11 )); then
        ok "数据库已就绪（$tables 张表）"
    else
        warn "数据库只有 ${tables:-0} 张表（应为 11）。若是首次启动请再等几秒；"
        warn "若持续如此，执行 ./seckill.sh clean 重新初始化"
    fi
}

build_app() {
    if [[ -f "$JAR" && "${1:-}" != "--force" ]]; then
        # 源码比 jar 新就重新打包。
        # 注意要覆盖 src 下的**所有**文件，不能只盯 *.java / *.yaml ——
        # 静态资源（index.html）、Lua 脚本、SQL、配置都在 src 里，
        # 漏掉它们会导致"改了却跑的还是旧 jar"。
        if [[ -z "$(find src pom.xml -newer "$JAR" -type f 2>/dev/null | head -1)" ]]; then
            ok "jar 已是最新，跳过打包"
            return 0
        fi
        warn "源码有更新，重新打包"
    fi

    # Windows 上运行中的 jar 被 JVM 独占，clean 删不掉。
    # 要重建就先停应用，打包完成后由调用方（start/build）重新拉起。
    if app_pid >/dev/null 2>&1; then
        warn "应用正在运行，先停止以便重建 jar"
        stop_app
    fi

    if ! detect_maven; then
        fail "未找到 Maven。请任选其一："
        fail "  1) 安装 mvn 并加入 PATH"
        fail "  2) 在项目根目录放 mvnw"
        fail "  3) 让 ~/.m2/wrapper 下存在 apache-maven-* 分发包"
        exit 1
    fi

    info "打包（首次会下载依赖，可能较慢）"
    if ! run_mvn -B -q clean package -DskipTests; then
        fail "打包失败"
        exit 1
    fi
    ok "打包完成：$JAR"
}

start_app() {
    local pid
    if pid="$(app_pid 2>/dev/null)"; then
        ok "应用已在运行（PID $pid）"
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
        local holder
        holder="$(docker ps --filter "publish=$APP_PORT" --format '{{.Names}}' 2>/dev/null | head -1)"
        if [[ -n "$holder" ]]; then
            fail "占用者是一个容器：$holder"
        else
            fail "查看占用：netstat -ano | findstr :$APP_PORT  (Windows)"
            fail "          lsof -i :$APP_PORT                   (macOS/Linux)"
        fi
        exit 1
    fi

    mkdir -p "$RUN_DIR"
    info "启动应用"
    nohup "$JAVA_BIN" -jar "$JAR" > "$APP_LOG" 2>&1 &
    echo $! > "$PID_FILE"
    disown 2>/dev/null || true

    if wait_for "应用" 120 bash -c \
        "curl -sf http://127.0.0.1:$APP_PORT/actuator/health | grep -q '\"status\":\"UP\"'"; then
        # 把 PID 文件改写成真实的进程号（jps 能给出 Windows PID）
        local real
        real="$(app_pid 2>/dev/null || true)"
        [[ -n "$real" ]] && echo "$real" > "$PID_FILE"
        ok "应用已启动（PID ${real:-$(cat "$PID_FILE")}）"
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
    printf "  日志：  ${C_DIM}./seckill.sh logs${C_RESET}\n"
    printf "  状态：  ${C_DIM}./seckill.sh status${C_RESET}\n"
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

stop_app() {
    local pid
    if ! pid="$(app_pid 2>/dev/null)"; then
        ok "应用未在运行"
        rm -f "$PID_FILE"
        return 0
    fi

    info "停止应用（PID $pid）"
    if [[ $IS_WINDOWS -eq 1 ]]; then
        taskkill //PID "$pid" >/dev/null 2>&1 || true
    else
        kill "$pid" 2>/dev/null || true
    fi
    local i
    for i in $(seq 1 15); do
        app_pid >/dev/null 2>&1 || break
        sleep 1
    done
    if app_pid >/dev/null 2>&1; then
        if [[ $IS_WINDOWS -eq 1 ]]; then
            taskkill //F //PID "$pid" >/dev/null 2>&1 || true
        else
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi
    rm -f "$PID_FILE"
    ok "应用已停止"
}

cmd_stop() {
    stop_app
    info "停止中间件"
    docker compose down 2>&1 | tail -2
    ok "中间件已停止（数据保留）"
}

# ---------------------------------------------------------------- 状态

cmd_status() {
    echo
    local pid
    pid="$(app_pid 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
        if curl -sf "http://127.0.0.1:$APP_PORT/actuator/health" | grep -q '"status":"UP"'; then
            ok "应用       运行中（PID $pid，健康检查 UP）"
        else
            warn "应用       进程存在（PID $pid），但健康检查未通过"
        fi
    elif port_in_use "$APP_PORT" && \
         curl -sf "http://127.0.0.1:$APP_PORT/actuator/health" 2>/dev/null | grep -q '"status":"UP"'; then
        # 端口活着且健康检查通过，但没有 PID 记录 —— 通常是 IDE / mvn 手动起的
        warn "应用       运行中（非本脚本启动，无 PID 记录；stop 不会停止它）"
    else
        fail "应用       未运行"
    fi

    echo
    printf "  中间件：\n"
    docker compose ps --format '    {{.Name}}\t{{.Status}}' 2>/dev/null || echo "    （未启动）"

    echo
    printf "  端口：\n"
    local spec p
    for spec in "$APP_PORT" "${INFRA_SPECS[@]}"; do
        case "$spec" in
            *:*) p="${spec##*:}" ;;
            *)   p="$spec" ;;
        esac
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
    local was_running=0
    app_pid >/dev/null 2>&1 && was_running=1
    build_app --force
    if (( was_running )); then
        start_app
    fi
}

cmd_clean() {
    warn "这会删除所有数据卷（数据库数据、Redis、RabbitMQ、Grafana 配置）"
    read -r -p "确认？[y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消"; exit 0; }
    stop_app
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
        sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        fail "未知命令：$1"
        echo "可用命令：start | stop | restart | status | logs | build | clean"
        exit 1
        ;;
esac
