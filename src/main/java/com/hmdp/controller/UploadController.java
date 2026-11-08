package com.hmdp.controller;

import cn.hutool.core.io.FileUtil;
import cn.hutool.core.util.StrUtil;
import com.hmdp.dto.Result;
import com.hmdp.utils.SystemConstants;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MaxUploadSizeExceededException;
import org.springframework.web.multipart.MultipartFile;

import java.io.File;
import java.io.IOException;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;

@Slf4j
@RestController
@RequestMapping("upload")
public class UploadController {

    /** 允许的图片后缀。白名单而非黑名单——黑名单永远漏。 */
    private static final Set<String> ALLOWED_SUFFIXES = Set.of("jpg", "jpeg", "png", "gif", "webp", "bmp");

    /** 单文件大小上限，与 application.yaml 里的 multipart 限制保持一致 */
    private static final long MAX_IMAGE_BYTES = 5L * 1024 * 1024;

    /**
     * 图片存放根目录。
     *
     * <p>原实现引用 {@code SystemConstants.IMAGE_UPLOAD_DIR}，那是个硬编码的
     * Windows 绝对路径（{@code D:\tlias\...}），在 macOS / Linux 上目录不存在，
     * 每次上传都会 IOException → 500。现在改为可配置，默认在当前工作目录下。
     */
    @Value("${hmdp.upload.image-dir:" + SystemConstants.DEFAULT_IMAGE_UPLOAD_DIR + "}")
    private String imageUploadDir;

    @PostMapping("blog")
    public Result uploadImage(@RequestParam("file") MultipartFile image) {
        if (image == null || image.isEmpty()) {
            return Result.fail("文件不能为空");
        }
        if (image.getSize() > MAX_IMAGE_BYTES) {
            return Result.fail("图片不能超过 " + (MAX_IMAGE_BYTES / 1024 / 1024) + "MB");
        }

        String contentType = image.getContentType();
        if (contentType == null || !contentType.toLowerCase(Locale.ROOT).startsWith("image/")) {
            return Result.fail("只允许上传图片");
        }

        String originalFilename = image.getOriginalFilename();
        String suffix = StrUtil.subAfter(originalFilename, ".", true);
        suffix = suffix == null ? "" : suffix.toLowerCase(Locale.ROOT);
        if (!ALLOWED_SUFFIXES.contains(suffix)) {
            return Result.fail("不支持的图片格式，仅支持：jpg/jpeg/png/gif/webp/bmp");
        }

        try {
            // 生成新文件名
            String fileName = createNewFileName(suffix);

            // 必须用绝对路径，且必须落在上传根目录内。
            // MultipartFile.transferTo(File) 对**相对路径**会交给 Servlet 容器解析——
            // 实际落到 Tomcat 的临时工作目录（.../work/Tomcat/localhost/ROOT/...），
            // 而这个目录下并不存在 blogs/x/y 子目录，于是抛 FileNotFoundException。
            File target = resolveInsideRoot(fileName);
            FileUtil.mkParentDirs(target);

            image.transferTo(target);
            log.debug("文件上传成功，{} -> {}", fileName, target.getAbsolutePath());
            return Result.ok(fileName);
        } catch (IOException e) {
            log.error("文件上传失败", e);
            return Result.fail("文件上传失败");
        }
    }

    @GetMapping("/blog/delete")
    public Result deleteBlogImg(@RequestParam("name") String filename) {
        if (StrUtil.isBlank(filename)) {
            return Result.fail("文件名称不能为空");
        }

        File file;
        try {
            file = resolveInsideRoot(filename);
        } catch (IllegalArgumentException e) {
            // 传 ../ 或绝对路径想删根目录之外的文件，直接拒绝
            log.warn("拒绝删除越界路径：{}", filename);
            return Result.fail("错误的文件名称");
        }

        if (!file.exists()) {
            return Result.fail("文件不存在");
        }
        if (!file.isFile()) {
            return Result.fail("错误的文件名称");
        }
        FileUtil.del(file);
        return Result.ok();
    }

    /** 超过 Spring multipart 上限时，返回可读提示而不是 500 */
    @ExceptionHandler(MaxUploadSizeExceededException.class)
    public Result handleMaxUploadSize(MaxUploadSizeExceededException e) {
        return Result.fail("图片不能超过 " + (MAX_IMAGE_BYTES / 1024 / 1024) + "MB");
    }

    /**
     * 把配置的目录解析成绝对路径。
     *
     * <p>相对路径基于**进程工作目录**解析，而不是 Servlet 容器的临时目录——
     * 后者是 {@code MultipartFile.transferTo} 对相对路径的默认行为，会导致文件落到
     * {@code .../work/Tomcat/localhost/ROOT/} 下。
     */
    private File resolveInsideRoot(String relativePath) {
        Path root = Paths.get(imageUploadDir).toAbsolutePath().normalize();

        // 返回值里的文件名带前导 "/"（前端按 URL 用），这里去掉再拼，
        // 否则 root.resolve("/blogs/...") 会得到绝对路径 /blogs/...，直接逃出根目录。
        String cleaned = relativePath.replace('\\', '/');
        while (cleaned.startsWith("/")) {
            cleaned = cleaned.substring(1);
        }

        Path target = root.resolve(cleaned).normalize();
        if (!target.startsWith(root)) {
            throw new IllegalArgumentException("路径越界：" + relativePath);
        }
        return target.toFile();
    }

    private String createNewFileName(String suffix) {
        // 生成目录
        String name = UUID.randomUUID().toString();
        int hash = name.hashCode();
        int d1 = hash & 0xF;
        int d2 = (hash >> 4) & 0xF;
        // 生成文件名（目录由调用方在写入前创建）
        return StrUtil.format("/blogs/{}/{}/{}.{}", d1, d2, name, suffix);
    }

}
