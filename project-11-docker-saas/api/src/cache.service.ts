import { Injectable, OnModuleDestroy } from "@nestjs/common";
import Redis from "ioredis";

@Injectable()
export class CacheService implements OnModuleDestroy {
  readonly redis = new Redis(process.env.REDIS_URL ?? "redis://redis:6379", { maxRetriesPerRequest: 2 });

  async getJson<T>(key: string): Promise<T | null> {
    const v = await this.redis.get(key);
    return v ? (JSON.parse(v) as T) : null;
  }

  async setJson(key: string, value: unknown, ttlSeconds: number) {
    await this.redis.set(key, JSON.stringify(value), "EX", ttlSeconds);
  }

  async del(key: string) {
    await this.redis.del(key);
  }

  async onModuleDestroy() {
    await this.redis.quit();
  }
}
