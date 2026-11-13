package com.devops.store;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.*;

import java.lang.management.ManagementFactory;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;

@RestController
@RequestMapping("/api")
public class StoreController {

    private final OrderService orders;
    private final JdbcTemplate jdbc;

    public StoreController(OrderService orders, JdbcTemplate jdbc) {
        this.orders = orders;
        this.jdbc = jdbc;
    }

    public record OrderRequest(String customer, String sku, int quantity) {}

    @GetMapping("/health")
    public ResponseEntity<Map<String, Object>> health() {
        Map<String, Object> body = new LinkedHashMap<>();
        boolean dbOk;
        try {
            jdbc.queryForObject("SELECT 1", Integer.class);
            dbOk = true;
        } catch (Exception e) {
            dbOk = false;
        }
        Runtime rt = Runtime.getRuntime();
        body.put("status", dbOk ? "ok" : "degraded");
        body.put("database", "postgres");
        body.put("db_ok", dbOk);
        body.put("java", System.getProperty("java.version"));
        body.put("uptime_s", ManagementFactory.getRuntimeMXBean().getUptime() / 1000);
        body.put("heap_used_mb", (rt.totalMemory() - rt.freeMemory()) / 1048576);
        body.put("heap_max_mb", rt.maxMemory() / 1048576);
        return ResponseEntity.status(dbOk ? HttpStatus.OK : HttpStatus.SERVICE_UNAVAILABLE).body(body);
    }

    @GetMapping("/products")
    public List<Map<String, Object>> products() {
        return orders.products();
    }

    @GetMapping("/orders")
    public List<Map<String, Object>> recent() {
        return orders.recentOrders();
    }

    @GetMapping("/stats")
    public Map<String, Object> stats() {
        return orders.stats();
    }

    @PostMapping("/orders")
    @ResponseStatus(HttpStatus.CREATED)
    public Map<String, Object> create(@RequestBody OrderRequest req) {
        return orders.create(req.customer(), req.sku(), req.quantity());
    }

    // ---------- chaos endpoints used by scripts/alert_test.sh ----------
    @GetMapping("/chaos/error")
    public ResponseEntity<Map<String, String>> chaosError() {
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(Map.of("error", "chaos: simulated failure"));
    }

    @GetMapping("/chaos/slow")
    public Map<String, Object> chaosSlow() throws InterruptedException {
        long ms = ThreadLocalRandom.current().nextLong(800, 2500);
        Thread.sleep(ms);
        return Map.of("slept_ms", ms);
    }

    @ExceptionHandler(IllegalArgumentException.class)
    public ResponseEntity<Map<String, String>> badRequest(IllegalArgumentException e) {
        return ResponseEntity.badRequest().body(Map.of("error", e.getMessage()));
    }

    @ExceptionHandler(IllegalStateException.class)
    public ResponseEntity<Map<String, String>> conflict(IllegalStateException e) {
        return ResponseEntity.status(HttpStatus.CONFLICT).body(Map.of("error", e.getMessage()));
    }
}
