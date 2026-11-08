package com.hmdp.controller;

import cn.hutool.core.bean.BeanUtil;
import cn.hutool.core.util.StrUtil;
import com.hmdp.dto.LoginFormDTO;
import com.hmdp.dto.Result;
import com.hmdp.dto.UserDTO;
import com.hmdp.entity.User;
import com.hmdp.service.IUserService;
import com.hmdp.service.IVoucherOrderService;
import com.hmdp.utils.RedisConstants;
import com.hmdp.utils.UserHolder;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.web.bind.annotation.*;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/**
 * 演示接口：一次调用完成「登录 → 下单」全流程。
 *
 * <p><b>为什么需要它</b>：本项目没有前端页面，秒杀接口又需要登录 token。
 * 想手动试一次下单，得手动走「请求验证码 → 从 Redis 取码 → 登录换 token →
 * 带 token 下单」四步。这个接口把它包成一次调用，方便演示和自测。
 *
 * <p><b>仅用于本地演示</b>。它会：
 * <ul>
 *   <li>直接用测试手机号发验证码，并从 Redis 读回验证码（生产环境这是短信内容）</li>
 *   <li>把 token 一并返回给调用方</li>
 * </ul>
 * 因此必须通过 {@code hmdp.demo.enabled} 控制开关，**生产环境务必设为 false**。
 */
@Slf4j
@RestController
@RequestMapping("/demo")
@RequiredArgsConstructor
public class DemoController {

    private final IUserService userService;
    private final IVoucherOrderService voucherOrderService;
    private final StringRedisTemplate stringRedisTemplate;

    @Value("${hmdp.demo.enabled:true}")
    private boolean demoEnabled;

    /**
     * 用指定手机号登录并抢购指定券。
     *
     * <p>同一个手机号重复调用时，第一次成功、后续会被 Redis 去重拦下并返回
     * "不能重复下单"——这正是「一人一单」在起作用。
     */
    @PostMapping("/seckill")
    public Result seckill(@RequestParam String phone,
                          @RequestParam(defaultValue = "10") Long voucherId) {
        if (!demoEnabled) {
            return Result.fail("演示接口已关闭");
        }
        if (StrUtil.isBlank(phone)) {
            return Result.fail("手机号不能为空");
        }

        Map<String, Object> trace = new LinkedHashMap<>();

        // 1. 发验证码（写入 Redis，同时会打到服务端日志）
        clearSendCodeRateLimit(phone);
        Result codeResult = userService.sendCode(phone, null);
        if (Boolean.FALSE.equals(codeResult.getSuccess())) {
            return codeResult;
        }
        String code = stringRedisTemplate.opsForValue().get(RedisConstants.LOGIN_CODE_KEY + phone);
        trace.put("step1_验证码", code);
        if (code == null) {
            return Result.fail("验证码未写入 Redis");
        }

        // 2. 登录换 token
        LoginFormDTO form = LoginFormDTO.builder().phone(phone).code(code).build();
        Result loginResult = userService.login(form, null);
        if (Boolean.FALSE.equals(loginResult.getSuccess())) {
            return loginResult;
        }
        String token = String.valueOf(loginResult.getData());
        trace.put("step2_token", token);

        // 3. 秒杀接口读的是 ThreadLocal 里的用户，这里手动填上
        User user = userService.lambdaQuery().eq(User::getPhone, phone).one();
        if (user == null) {
            return Result.fail("该手机号未注册");
        }
        UserDTO userDTO = BeanUtil.copyProperties(user, UserDTO.class);
        UserHolder.saveUser(userDTO);

        try {
            // 4. 下单
            Result orderResult = voucherOrderService.seckillVoucher(voucherId);
            trace.put("step3_下单", orderResult.getSuccess()
                    ? "成功，订单号 " + orderResult.getData()
                    : "失败：" + orderResult.getErrorMsg());
            trace.put("voucherId", voucherId);
            trace.put("userId", userDTO.getId());

            // 把执行轨迹一并返回，方便观察每一步到底发生了什么
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("success", orderResult.getSuccess());
            body.put("orderId", orderResult.getData());
            body.put("errorMsg", orderResult.getErrorMsg());
            body.put("trace", trace);
            return Result.ok(body);
        } finally {
            UserHolder.removeUser();
        }
    }

    /**
     * 演示接口常需要同一手机号连续调用（例如连续演示两次以展示「一人一单」），
     * 验证码频控会先把第二次拦掉。这里清掉频控 key，只影响本地演示环境
     * （{@code hmdp.demo.enabled=true}），不影响真实的发送限流逻辑。
     */
    private void clearSendCodeRateLimit(String phone) {
        stringRedisTemplate.delete(RedisConstants.LOGIN_CODE_RATE_KEY + phone);
    }

    /** 查询某手机号的登录 token（调试用：拿到 token 后可以自己用 curl 调秒杀接口） */
    @GetMapping("/token")
    public Result token(@RequestParam String phone) {
        if (!demoEnabled) {
            return Result.fail("演示接口已关闭");
        }
        clearSendCodeRateLimit(phone);
        userService.sendCode(phone, null);
        String code = stringRedisTemplate.opsForValue().get(RedisConstants.LOGIN_CODE_KEY + phone);
        if (code == null) {
            return Result.fail("验证码未写入 Redis");
        }
        LoginFormDTO form = LoginFormDTO.builder().phone(phone).code(code).build();
        Result loginResult = userService.login(form, null);
        if (Boolean.FALSE.equals(loginResult.getSuccess())) {
            return loginResult;
        }
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("phone", phone);
        body.put("token", loginResult.getData());
        body.put("usage", "curl -X POST http://localhost:8081/voucher-order/seckill/10 -H 'authorization: "
                + loginResult.getData() + "'");
        return Result.ok(body);
    }

    /** 查看某张券的实时库存（Redis 与 DB 各一份，两边应当一致） */
    @GetMapping("/stock/{voucherId}")
    public Result stock(@PathVariable Long voucherId) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("redisStock", stringRedisTemplate.opsForValue()
                .get("seckill:stock:{" + voucherId + "}"));
        body.put("note", "DB 库存见 tb_seckill_voucher，可用 mysql 查询");
        return Result.ok(body);
    }

    /**
     * 随机取一个还没对这张券下过单的用户。
     *
     * <p>演示时用它换用户——否则同一个手机号第二次必然被「一人一单」拒绝，
     * 就没法演示连续抢购了。
     */
    @GetMapping("/users")
    public Result randomUser(@RequestParam(defaultValue = "10") Long voucherId) {
        if (!demoEnabled) {
            return Result.fail("演示接口已关闭");
        }
        List<Long> orderedUserIds = voucherOrderService.lambdaQuery()
                .eq(com.hmdp.entity.VoucherOrder::getVoucherId, voucherId)
                .list()
                .stream()
                .map(com.hmdp.entity.VoucherOrder::getUserId)
                .toList();

        User user = userService.lambdaQuery()
                .notIn(!orderedUserIds.isEmpty(), User::getId, orderedUserIds)
                .last("ORDER BY RAND() LIMIT 1")
                .one();
        if (user == null) {
            return Result.fail("没有可用用户了");
        }
        return Result.ok(Map.of("phone", user.getPhone(), "userId", user.getId()));
    }
}
