import "reflect-metadata";
import { NestFactory } from "@nestjs/core";
import { AppModule } from "./app.module";

async function bootstrap() {
  const app = await NestFactory.create(AppModule, { logger: ["log", "warn", "error"] });
  app.setGlobalPrefix("api");
  // Runs OnModuleDestroy hooks (close pg/redis) when Docker sends SIGTERM
  app.enableShutdownHooks();
  // Trust Caddy's X-Forwarded-For (one proxy hop) for rate limiting by client IP
  app.getHttpAdapter().getInstance().set("trust proxy", 1);
  const port = Number(process.env.PORT ?? 3000);
  await app.listen(port, "0.0.0.0");
  console.log(`saas-api listening on :${port} (pid ${process.pid})`);
}
bootstrap();
