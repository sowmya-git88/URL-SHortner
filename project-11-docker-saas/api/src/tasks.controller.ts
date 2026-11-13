import { Body, Controller, Delete, Get, HttpCode, NotFoundException, BadRequestException, Param, ParseIntPipe, Patch, Post } from "@nestjs/common";
import { DbService } from "./db.service";
import { CacheService } from "./cache.service";

const CACHE_KEY = "tasks:all";

@Controller("tasks")
export class TasksController {
  constructor(private db: DbService, private cache: CacheService) {}

  @Get()
  async list() {
    const cached = await this.cache.getJson<unknown[]>(CACHE_KEY).catch(() => null);
    if (cached) return { source: "redis", tasks: cached };
    const tasks = await this.db.query("SELECT * FROM tasks ORDER BY id");
    await this.cache.setJson(CACHE_KEY, tasks, 30).catch(() => undefined);
    return { source: "postgres", tasks };
  }

  @Post()
  async create(@Body() body: { title?: string }) {
    const title = String(body?.title ?? "").trim();
    if (!title || title.length > 200) throw new BadRequestException("title must be 1-200 chars");
    const [task] = await this.db.query("INSERT INTO tasks(title) VALUES ($1) RETURNING *", [title]);
    await this.cache.del(CACHE_KEY);
    return task;
  }

  @Patch(":id")
  async toggle(@Param("id", ParseIntPipe) id: number, @Body() body: { done?: boolean }) {
    const [task] = await this.db.query("UPDATE tasks SET done = $2 WHERE id = $1 RETURNING *", [id, Boolean(body?.done)]);
    if (!task) throw new NotFoundException();
    await this.cache.del(CACHE_KEY);
    return task;
  }

  @Delete(":id")
  @HttpCode(204)
  async remove(@Param("id", ParseIntPipe) id: number) {
    const rows = await this.db.query("DELETE FROM tasks WHERE id = $1 RETURNING id", [id]);
    if (!rows.length) throw new NotFoundException();
    await this.cache.del(CACHE_KEY);
  }
}
