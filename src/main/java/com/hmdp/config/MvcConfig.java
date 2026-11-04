package com.hmdp.config;

import com.hmdp.interceptor.LoginInterceptor;
import com.hmdp.interceptor.RefreshTokenInterceptor;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

import jakarta.annotation.Resource;

@Configuration
public class MvcConfig implements WebMvcConfigurer {
    @Resource
    private StringRedisTemplate stringRedisTemplate;
    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        //登录拦截器
        registry.addInterceptor(new LoginInterceptor())
                .excludePathPatterns(
                        // 项目首页与静态资源。没有这条，打开 http://localhost:8081
                        // 会被登录拦截器拦下返回 401（浏览器显示空白），
                        // 而不是预期的首页。
                        "/",
                        "/index.html",
                        "/favicon.ico",
                        "/user/login",
                        "/upload/**",
                        // 注意：/voucher/** 仍然放行，因为其中的 GET /voucher/list/{shopId}
                        // 是前台要用的只读接口，而 excludePathPatterns 只按路径匹配、不看 HTTP 方法。
                        // 两个"造券"接口（POST /voucher 与 POST /voucher/seckill）的鉴权
                        // 已下沉到 VoucherController 内部，只允许管理员调用。
                        "/voucher/**",
                        "/user/code",
                        "/shop/**",
                        "/shop-type/**",
                        "/blog/hot"
                ).order(1);
        //token刷新的拦截器
        registry.addInterceptor(new RefreshTokenInterceptor(stringRedisTemplate))
                .addPathPatterns("/**").order(0);
    }
}
