import { MiddlewareConsumer, Module, NestModule } from "@nestjs/common";
import { DbService } from "./db.service";
import { CacheService } from "./cache.service";
import { StorageService } from "./storage.service";
import { HealthController } from "./health.controller";
import { TasksController } from "./tasks.controller";
import { FilesController } from "./files.controller";
import { RateLimitMiddleware } from "./rate-limit.middleware";

@Module({
  controllers: [HealthController, TasksController, FilesController],
  providers: [DbService, CacheService, StorageService],
})
export class AppModule implements NestModule {
  configure(consumer: MiddlewareConsumer) {
    consumer.apply(RateLimitMiddleware).forRoutes("*");
  }
}
