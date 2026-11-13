package com.devops.store;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.time.Duration;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

@Service
public class OrderService {

    private static final Logger log = LoggerFactory.getLogger(OrderService.class);

    private final JdbcTemplate jdbc;
    private final KafkaTemplate<String, String> kafka;
    private final String topic;
    private final long fulfillmentDelayMs;
    private final Counter created;
    private final Counter fulfilled;
    private final Counter rejected;
    private final Timer fulfillmentLatency;
    private final AtomicLong pending = new AtomicLong();

    public OrderService(JdbcTemplate jdbc, KafkaTemplate<String, String> kafka, MeterRegistry registry,
                        @Value("${store.topic}") String topic,
                        @Value("${store.fulfillment-delay-ms}") long fulfillmentDelayMs) {
        this.jdbc = jdbc;
        this.kafka = kafka;
        this.topic = topic;
        this.fulfillmentDelayMs = fulfillmentDelayMs;
        // Custom business metrics → /actuator/prometheus as orders_created_total, etc.
        this.created = Counter.builder("orders.created").description("Orders accepted by the API").register(registry);
        this.fulfilled = Counter.builder("orders.fulfilled").description("Orders fulfilled by the Kafka consumer").register(registry);
        this.rejected = Counter.builder("orders.rejected").description("Orders rejected (stock/validation)").register(registry);
        this.fulfillmentLatency = Timer.builder("orders.fulfillment.latency")
                .description("Time from order creation to fulfillment").register(registry);
        registry.gauge("orders.pending", pending);
        pending.set(countPending());
    }

    private long countPending() {
        try {
            Long n = jdbc.queryForObject("SELECT count(*) FROM orders WHERE status = 'CREATED'", Long.class);
            return n == null ? 0 : n;
        } catch (Exception e) {
            return 0;
        }
    }

    public List<Map<String, Object>> products() {
        return jdbc.queryForList("SELECT sku, name, price_cents, stock FROM products ORDER BY sku");
    }

    public List<Map<String, Object>> recentOrders() {
        return jdbc.queryForList("SELECT id, customer, sku, quantity, total_cents, status, created_at, fulfilled_at " +
                "FROM orders ORDER BY id DESC LIMIT 30");
    }

    @Transactional
    public Map<String, Object> create(String customer, String sku, int quantity) {
        if (customer == null || customer.isBlank() || quantity < 1 || quantity > 20) {
            rejected.increment();
            throw new IllegalArgumentException("customer required, quantity 1-20");
        }
        // Atomic stock decrement: succeeds only if enough stock remains
        int updated = jdbc.update("UPDATE products SET stock = stock - ? WHERE sku = ? AND stock >= ?", quantity, sku, quantity);
        if (updated == 0) {
            rejected.increment();
            throw new IllegalStateException("unknown sku or insufficient stock");
        }
        Integer price = jdbc.queryForObject("SELECT price_cents FROM products WHERE sku = ?", Integer.class, sku);
        Map<String, Object> order = jdbc.queryForMap(
                "INSERT INTO orders (customer, sku, quantity, total_cents) VALUES (?, ?, ?, ?) " +
                "RETURNING id, customer, sku, quantity, total_cents, status, created_at",
                customer.trim(), sku, quantity, price * quantity);
        String id = String.valueOf(order.get("id"));
        // Publish only AFTER the DB transaction commits; otherwise the consumer could read the
        // event before the order row is visible and skip it. Key = order id → stable partition.
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override
            public void afterCommit() {
                kafka.send(topic, id, id);
            }
        });
        created.increment();
        pending.incrementAndGet();
        log.info("order {} created sku={} qty={}", id, sku, quantity);
        return order;
    }

    /** Kafka consumer: marks orders fulfilled and records end-to-end latency. */
    @KafkaListener(topics = "${store.topic}", groupId = "fulfillment")
    public void fulfill(String orderId) throws InterruptedException {
        Thread.sleep(fulfillmentDelayMs);   // simulate picking & packing
        List<Map<String, Object>> rows = jdbc.queryForList(
                "UPDATE orders SET status = 'FULFILLED', fulfilled_at = now() " +
                "WHERE id = ? AND status = 'CREATED' RETURNING created_at", Long.parseLong(orderId));
        if (rows.isEmpty()) {
            return;   // already processed (at-least-once delivery → be idempotent)
        }
        Object createdAt = rows.get(0).get("created_at");
        if (createdAt instanceof java.sql.Timestamp ts) {
            fulfillmentLatency.record(Duration.between(ts.toInstant(), OffsetDateTime.now().toInstant()).toMillis(), TimeUnit.MILLISECONDS);
        }
        fulfilled.increment();
        pending.decrementAndGet();
        log.info("order {} fulfilled", orderId);
    }

    public Map<String, Object> stats() {
        return jdbc.queryForMap("SELECT count(*) AS total, " +
                "count(*) FILTER (WHERE status = 'FULFILLED') AS fulfilled, " +
                "count(*) FILTER (WHERE status = 'CREATED') AS pending, " +
                "coalesce(sum(total_cents), 0) AS revenue_cents FROM orders");
    }
}
