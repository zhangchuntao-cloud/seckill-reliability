package com.hmdp;

import cn.hutool.core.io.FileUtil;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.hmdp.utils.RedisConstants;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.web.servlet.MockMvc;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Paths;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.multipart;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * 上传接口的鉴权与路径安全。
 *
 * <p>修复前：{@code /upload/**} 在 {@code MvcConfig} 里整体放行，
 * 且删除接口直接 {@code new File(根目录, name)}——
 * 未登录就能用 {@code name=../../xxx} 删除进程有权限的任意文件。
 */
@SpringBootTest(properties = {
        // 测试写自己的目录，别污染 uploads/imgs
        "hmdp.upload.image-dir=target/test-uploads"
})
@AutoConfigureMockMvc
class UploadControllerTest {

    private static final String TOKEN = "test-upload-token";

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private StringRedisTemplate stringRedisTemplate;

    @Autowired
    private ObjectMapper objectMapper;

    private File uploadRoot;

    @BeforeEach
    void setUp() {
        // 伪造一个已登录会话：RefreshTokenInterceptor 读的是 Redis Hash
        stringRedisTemplate.opsForHash().putAll(
                RedisConstants.LOGIN_USER_KEY + TOKEN,
                Map.of("id", "1", "nickName", "tester"));
        uploadRoot = Paths.get("target/test-uploads").toAbsolutePath().normalize().toFile();
    }

    @AfterEach
    void tearDown() {
        stringRedisTemplate.delete(RedisConstants.LOGIN_USER_KEY + TOKEN);
        FileUtil.del(uploadRoot);
    }

    private MockMultipartFile png(String name) {
        return new MockMultipartFile("file", name, "image/png", new byte[]{(byte) 0x89, 'P', 'N', 'G'});
    }

    @Test
    @DisplayName("未登录上传返回 401")
    void anonymousUploadIsRejected() throws Exception {
        mockMvc.perform(multipart("/upload/blog").file(png("a.png")))
                .andExpect(status().isUnauthorized());
    }

    @Test
    @DisplayName("非图片后缀被拒绝")
    void disallowedExtensionIsRejected() throws Exception {
        MockMultipartFile file = new MockMultipartFile(
                "file", "shell.jsp", "image/png", new byte[]{1, 2, 3});

        String body = mockMvc.perform(multipart("/upload/blog").file(file)
                        .header("authorization", TOKEN))
                .andExpect(status().isOk())
                .andReturn().getResponse().getContentAsString(StandardCharsets.UTF_8);

        assertThat(body).contains("\"success\":false").contains("不支持的图片格式");
    }

    @Test
    @DisplayName("删除接口拒绝 ../ 越界路径")
    void deleteRejectsPathTraversal() throws Exception {
        String body = mockMvc.perform(get("/upload/blog/delete")
                        .param("name", "../../pom.xml")
                        .header("authorization", TOKEN))
                .andExpect(status().isOk())
                .andReturn().getResponse().getContentAsString(StandardCharsets.UTF_8);

        assertThat(body).contains("\"success\":false");
        // 项目文件必须还在
        assertThat(new File("pom.xml")).exists();
    }

    @Test
    @DisplayName("合法图片上传成功，文件落在上传根目录内")
    void validUploadSucceeds() throws Exception {
        String body = mockMvc.perform(multipart("/upload/blog").file(png("ok.png"))
                        .header("authorization", TOKEN))
                .andExpect(status().isOk())
                .andReturn().getResponse().getContentAsString(StandardCharsets.UTF_8);

        JsonNode json = objectMapper.readTree(body);
        assertThat(json.get("success").asBoolean()).isTrue();

        String fileName = json.get("data").asText();
        File saved = uploadRoot.toPath()
                .resolve(fileName.replaceFirst("^/+", ""))
                .normalize()
                .toFile();

        assertThat(saved).exists();
        assertThat(saved.toPath().normalize().startsWith(uploadRoot.toPath())).isTrue();
    }
}
