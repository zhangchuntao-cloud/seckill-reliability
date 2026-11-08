package com.hmdp;

import com.hmdp.dto.Result;
import com.hmdp.service.IUserService;
import com.hmdp.utils.RedisConstants;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.data.redis.core.StringRedisTemplate;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 验证码发送频率限制。
 *
 * <p>修复前的实现只有「验证码 2 分钟过期」，没有发送间隔限制——
 * 同一手机号可以被无限次触发发送，等于把短信通道敞开给人刷。
 */
@SpringBootTest
class LoginCodeRateLimitTest {

    private static final String PHONE = "13900001111";
    private static final String OTHER_PHONE = "13900002222";

    @Autowired
    private IUserService userService;

    @Autowired
    private StringRedisTemplate stringRedisTemplate;

    @AfterEach
    void cleanUp() {
        stringRedisTemplate.delete(RedisConstants.LOGIN_CODE_KEY + PHONE);
        stringRedisTemplate.delete(RedisConstants.LOGIN_CODE_RATE_KEY + PHONE);
        stringRedisTemplate.delete(RedisConstants.LOGIN_CODE_KEY + OTHER_PHONE);
        stringRedisTemplate.delete(RedisConstants.LOGIN_CODE_RATE_KEY + OTHER_PHONE);
    }

    @Test
    @DisplayName("同一手机号 60 秒内重复发送验证码被拒绝")
    void duplicateSendIsRejected() {
        Result first = userService.sendCode(PHONE, null);
        assertThat(first.getSuccess()).isTrue();

        Result second = userService.sendCode(PHONE, null);
        assertThat(second.getSuccess()).isFalse();
        assertThat(second.getErrorMsg()).contains("频繁");
    }

    @Test
    @DisplayName("频控按手机号隔离，不同号码互不影响")
    void differentPhonesAreIndependent() {
        assertThat(userService.sendCode(PHONE, null).getSuccess()).isTrue();
        assertThat(userService.sendCode(OTHER_PHONE, null).getSuccess()).isTrue();
    }
}
