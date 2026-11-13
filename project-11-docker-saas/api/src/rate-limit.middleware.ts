import { Injectable, NestMiddleware } from "@nestjs/common";
import { NextFunction, Request, Response } from "express";
import { CacheService } from "./cache.service";

// Fixed-window rate limiter in Redis: INCR a per-IP-per-minute key, expire it after 60 s.
@Injectable()
export class RateLimitMiddleware implements NestMiddleware {
  private readonly limit = Number(process.env.RATE_LIMIT_PER_MIN ?? 120);
  constructor(private readonly cache: CacheService) {}

  async use(req: Request, res: Response, next: NextFunction) {
    if (req.path.endsWith("/health")) return next();
    const key = `rl:${req.ip}:${Math.floor(Date.now() / 60_000)}`;
    try {
      const n = await this.cache.redis.incr(key);
      if (n === 1) await this.cache.redis.expire(key, 60);
      res.setHeader("X-RateLimit-Limit", String(this.limit));
      res.setHeader("X-RateLimit-Remaining", String(Math.max(0, this.limit - n)));
      if (n > this.limit) {
        res.status(429).json({ error: "rate limit exceeded, retry in a minute" });
        return;
      }
    } catch {
      // Redis down → fail open (availability over strictness)
    }
    next();
  }
}
