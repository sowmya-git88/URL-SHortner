import { Controller, Get, HttpException, HttpStatus } from "@nestjs/common";
import { hostname } from "os";
import { DbService } from "./db.service";
import { CacheService } from "./cache.service";
import { StorageService } from "./storage.service";

@Controller("health")
export class HealthController {
  constructor(private db: DbService, private cache: CacheService, private storage: StorageService) {}

  @Get()
  async health() {
    const started = Date.now();
    const [pg, redis, minio] = await Promise.allSettled([
      this.db.query("SELECT 1"),
      this.cache.redis.ping(),
      this.storage.ping(),
    ]);
    const checks = {
      postgres: pg.status === "fulfilled",
      redis: redis.status === "fulfilled",
      minio: minio.status === "fulfilled" && minio.value === true,
    };
    const ok = Object.values(checks).every(Boolean);
    const body = {
      status: ok ? "ok" : "degraded",
      checks,
      container: hostname(),
      pid: process.pid,
      rss_mb: Math.round(process.memoryUsage().rss / 1048576),
      took_ms: Date.now() - started,
    };
    if (!ok) throw new HttpException(body, HttpStatus.SERVICE_UNAVAILABLE);
    return body;
  }
}
