package com.hmdp;

import com.hmdp.dto.UserDTO;
import com.hmdp.entity.SeckillVoucher;
import com.hmdp.entity.VoucherOrder;
import com.hmdp.service.ISeckillVoucherService;
import com.hmdp.service.IVoucherOrderService;
import com.hmdp.service.impl.VoucherOrderServiceImpl;
import com.hmdp.utils.SeckillKeys;
import com.hmdp.utils.UserHolder;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.script.DefaultRedisScript;
import org.springframework.core.io.ClassPathResource;

import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 秒杀链路的核心不变量测试。
 *
 * <p><b>为什么这些测试值得单独存在</b>：压测脚本（{@code seckill-loadtest.py}）
 * 也能验证超卖和重复单，但它需要人手动跑，而且会污染演示数据。
 * 这里把同样的断言固化成可重复执行的测试，改完代码跑一遍就知道有没有破坏原有保证。
 *
 * <p><b>前置条件</b>：MySQL / Redis / RabbitMQ 已启动（{@code docker compose up -d}）。
 * 测试使用独立的券 id {@link #TEST_VOUCHER_ID}，不会碰演示数据，且每个用例前后都会清理。
 *
 * <p><b>覆盖的不变量</b>：
 * <ol>
 *   <li>Lua 预检的四种返回码各自对应正确的业务含义</li>
 *   <li>重复落库被唯一索引拦截（幂等）</li>
 *   <li>并发下单不超卖、不产生重复订单</li>
 *   <li>Redis 丢 key 后重放，DB 侧仍不产生重复订单（混沌场景）</li>
 * </ol>
 */
@SpringBootTest(properties = {
        // 对账任务默认 60s 跑一次，可能在测试中途介入、把数据"修好"，
        // 导致断言看到的是被对账改写后的状态。测试期间把间隔拉长。
        "hmdp.seckill.reconcile-interval-ms=3600000"
})
class SeckillIntegrationTest {

    /** 独立测试券，避开演示数据 */
    private static final long TEST_VOUCHER_ID = 999001L;

    @Autowired
    private StringRedisTemplate stringRedisTemplate;

    @Autowired
    private ISeckillVoucherService seckillVoucherService;

    @Autowired
    private IVoucherOrderService voucherOrderService;

    @Autowired
    private VoucherOrderServiceImpl voucherOrderServiceImpl;

    private static final DefaultRedisScript<Long> SECKILL_SCRIPT;

    static {
        SECKILL_SCRIPT = new DefaultRedisScript<>();
        SECKILL_SCRIPT.setLocation(new ClassPathResource("seckill.lua"));
        SECKILL_SCRIPT.setResultType(Long.class);
    }

    @BeforeEach
    void setUp() {
        cleanUp();
        // 建一张 5 库存的测试券
        seckillVoucherService.save(new SeckillVoucher()
                .setVoucherId(TEST_VOUCHER_ID)
                .setStock(5)
                .setBeginTime(LocalDateTime.now().minusHours(1))
                .setEndTime(LocalDateTime.now().plusHours(1)));
        // 种入 Redis 库存与总量
        stringRedisTemplate.opsForValue().set(SeckillKeys.stock(TEST_VOUCHER_ID), "5");
        stringRedisTemplate.opsForValue().set(SeckillKeys.total(TEST_VOUCHER_ID), "5");
        stringRedisTemplate.delete(SeckillKeys.orders(TEST_VOUCHER_ID));
    }

    @AfterEach
    void tearDown() {
        cleanUp();
        UserHolder.removeUser();
    }

    private void cleanUp() {
        seckillVoucherService.removeById(TEST_VOUCHER_ID);
        voucherOrderService.lambdaUpdate()
                .eq(VoucherOrder::getVoucherId, TEST_VOUCHER_ID)
                .remove();
        stringRedisTemplate.delete(List.of(
                SeckillKeys.stock(TEST_VOUCHER_ID),
                SeckillKeys.total(TEST_VOUCHER_ID),
                SeckillKeys.orders(TEST_VOUCHER_ID)));
    }

    private Long runLua(long userId, long orderId) {
        return stringRedisTemplate.execute(
                SECKILL_SCRIPT,
                List.of(SeckillKeys.stock(TEST_VOUCHER_ID), SeckillKeys.orders(TEST_VOUCHER_ID)),
                String.valueOf(userId), String.valueOf(orderId));
    }

    // ---------------------------------------------------------------- 1. Lua 返回码

    @Test
    @DisplayName("Lua 预检：库存充足返回 0，并原子扣减库存与写入下单记录")
    void luaReturnsSuccessAndDeductsAtomically() {
        Long result = runLua(1001L, 1L);

        assertThat(result).isEqualTo(0L);
        assertThat(stringRedisTemplate.opsForValue().get(SeckillKeys.stock(TEST_VOUCHER_ID))).isEqualTo("4");
        // Hash 结构：userId -> orderId，供对账补单使用
        assertThat(stringRedisTemplate.opsForHash()
                .get(SeckillKeys.orders(TEST_VOUCHER_ID), "1001")).isEqualTo("1");
    }

    @Test
    @DisplayName("Lua 预检：库存耗尽返回 1")
    void luaReturnsOutOfStock() {
        stringRedisTemplate.opsForValue().set(SeckillKeys.stock(TEST_VOUCHER_ID), "0");

        assertThat(runLua(1002L, 2L)).isEqualTo(1L);
    }

    @Test
    @DisplayName("Lua 预检：同一用户重复下单返回 2")
    void luaReturnsDuplicate() {
        assertThat(runLua(1003L, 3L)).isEqualTo(0L);
        assertThat(runLua(1003L, 4L)).isEqualTo(2L);
        // 重复请求不应再次扣减库存
        assertThat(stringRedisTemplate.opsForValue().get(SeckillKeys.stock(TEST_VOUCHER_ID))).isEqualTo("4");
    }

    @Test
    @DisplayName("Lua 预检：库存 key 不存在返回 -1（而不是误报重复下单）")
    void luaReturnsNotInitializedWhenStockKeyMissing() {
        stringRedisTemplate.delete(SeckillKeys.stock(TEST_VOUCHER_ID));

        // 这是旧代码的一个真实缺陷：-1 被当成"不能重复下单"，完全误导使用者。
        // 现在它有独立的语义，调用方可以据此触发缓存重建。
        assertThat(runLua(1004L, 5L)).isEqualTo(-1L);
    }

    // ---------------------------------------------------------------- 2. 幂等落库

    @Test
    @DisplayName("幂等：同一订单重复落库，第二次被唯一索引拦下，且订单只有一条")
    void duplicateInsertIsRejectedByIdempotency() {
        long userId = 2001L;
        VoucherOrder order = new VoucherOrder()
                .setId(10001L)
                .setUserId(userId)
                .setVoucherId(TEST_VOUCHER_ID);

        voucherOrderService.createVoucherOrder(order);

        // 消息重投 / 消费者重启后重放，会再次走到这里
        assertThatThrownBy(() -> voucherOrderService.createVoucherOrder(
                new VoucherOrder().setId(10002L).setUserId(userId).setVoucherId(TEST_VOUCHER_ID)))
                .isInstanceOf(DuplicateKeyException.class);

        long count = voucherOrderService.lambdaQuery()
                .eq(VoucherOrder::getVoucherId, TEST_VOUCHER_ID)
                .count();
        assertThat(count).isEqualTo(1);

        // 关键：失败的那次插单会让整个事务回滚，所以库存只被扣了一次
        assertThat(seckillVoucherService.getById(TEST_VOUCHER_ID).getStock()).isEqualTo(4);
    }

    @Test
    @DisplayName("事务：库存为 0 时插单被回滚，不会留下没有库存对应的订单")
    void insertRollsBackWhenStockExhausted() {
        seckillVoucherService.lambdaUpdate()
                .eq(SeckillVoucher::getVoucherId, TEST_VOUCHER_ID)
                .set(SeckillVoucher::getStock, 0)
                .update();

        assertThatThrownBy(() -> voucherOrderService.createVoucherOrder(
                new VoucherOrder().setId(10003L).setUserId(2002L).setVoucherId(TEST_VOUCHER_ID)))
                .hasMessageContaining("库存不一致");

        assertThat(voucherOrderService.lambdaQuery()
                .eq(VoucherOrder::getVoucherId, TEST_VOUCHER_ID)
                .count()).isZero();
    }

    // ---------------------------------------------------------------- 3. 并发不超卖

    @Test
    @DisplayName("并发：5 个用户抢 5 库存，恰好 5 单，无超卖无重复")
    void concurrentSeckillDoesNotOversell() throws InterruptedException {
        int users = 6; // 比库存多一个，确保有拒绝
        int stock = 5;
        CountDownLatch start = new CountDownLatch(1);
        CountDownLatch done = new CountDownLatch(users);
        AtomicInteger success = new AtomicInteger();
        AtomicInteger outOfStock = new AtomicInteger();
        List<Long> orderIds = Collections.synchronizedList(new ArrayList<>());
        ExecutorService pool = Executors.newFixedThreadPool(users);

        for (int i = 0; i < users; i++) {
            long userId = 3000L + i;
            long orderId = 20000L + i;
            pool.submit(() -> {
                try {
                    start.await();
                    Long r = runLua(userId, orderId);
                    if (r != null && r == 0L) {
                        success.incrementAndGet();
                        orderIds.add(orderId);
                    } else if (r != null && r == 1L) {
                        outOfStock.incrementAndGet();
                    }
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                } finally {
                    done.countDown();
                }
            });
        }

        start.countDown();
        assertThat(done.await(10, TimeUnit.SECONDS)).isTrue();
        pool.shutdown();

        assertThat(success.get()).isEqualTo(stock);
        assertThat(outOfStock.get()).isEqualTo(users - stock);
        // Redis 库存归零，且不会为负
        assertThat(stringRedisTemplate.opsForValue().get(SeckillKeys.stock(TEST_VOUCHER_ID))).isEqualTo("0");
        assertThat(stringRedisTemplate.opsForHash().size(SeckillKeys.orders(TEST_VOUCHER_ID)))
                .isEqualTo((long) stock);
    }

    // ---------------------------------------------------------------- 4. 混沌：Redis 丢 key

    @Test
    @DisplayName("混沌：Redis 丢 key 后重放，DB 唯一索引兜底，不产生重复订单")
    void redisKeyLossDoesNotCauseDuplicateOrders() {
        long userId = 4001L;
        // 第一次：正常落库
        voucherOrderService.createVoucherOrder(
                new VoucherOrder().setId(30001L).setUserId(userId).setVoucherId(TEST_VOUCHER_ID));

        // 模拟 Redis 数据丢失（重启 / 淘汰 / FLUSHDB）
        stringRedisTemplate.delete(SeckillKeys.orders(TEST_VOUCHER_ID));
        stringRedisTemplate.opsForValue().set(SeckillKeys.stock(TEST_VOUCHER_ID), "5");

        // 重放：Lua 会放行（去重记录没了），但 DB 唯一索引会拦住
        assertThat(runLua(userId, 30002L)).isEqualTo(0L);
        assertThatThrownBy(() -> voucherOrderService.createVoucherOrder(
                new VoucherOrder().setId(30002L).setUserId(userId).setVoucherId(TEST_VOUCHER_ID)))
                .isInstanceOf(DuplicateKeyException.class);

        assertThat(voucherOrderService.lambdaQuery()
                .eq(VoucherOrder::getVoucherId, TEST_VOUCHER_ID)
                .count()).isEqualTo(1);
    }
}
