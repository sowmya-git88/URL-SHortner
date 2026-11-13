import {
  BadRequestException, Controller, Delete, Get, HttpCode, NotFoundException, Param, ParseIntPipe, Post, Res, UploadedFile, UseInterceptors,
} from "@nestjs/common";
import { FileInterceptor } from "@nestjs/platform-express";
import { Response } from "express";
import { randomUUID } from "crypto";
import { DbService } from "./db.service";
import { StorageService } from "./storage.service";

type FileRow = { id: number; object_key: string; filename: string; content_type: string; size_bytes: string; created_at: string };

@Controller("files")
export class FilesController {
  constructor(private db: DbService, private storage: StorageService) {}

  @Get()
  list() {
    return this.db.query<FileRow>("SELECT * FROM files ORDER BY id DESC LIMIT 100");
  }

  @Post()
  @UseInterceptors(FileInterceptor("file", { limits: { fileSize: 10 * 1024 * 1024 } }))
  async upload(@UploadedFile() file?: Express.Multer.File) {
    if (!file) throw new BadRequestException("multipart field 'file' is required");
    const safe = file.originalname.replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 120);
    const key = `${randomUUID()}-${safe}`;
    await this.storage.put(key, file.buffer, file.mimetype || "application/octet-stream");
    const [row] = await this.db.query<FileRow>(
      "INSERT INTO files(object_key, filename, content_type, size_bytes) VALUES ($1, $2, $3, $4) RETURNING *",
      [key, safe, file.mimetype || "application/octet-stream", file.size],
    );
    return row;
  }

  @Get(":id/download")
  async download(@Param("id", ParseIntPipe) id: number, @Res() res: Response) {
    const [row] = await this.db.query<FileRow>("SELECT * FROM files WHERE id = $1", [id]);
    if (!row) throw new NotFoundException();
    const stream = await this.storage.get(row.object_key);
    res.setHeader("Content-Type", row.content_type);
    res.setHeader("Content-Disposition", `attachment; filename="${row.filename}"`);
    stream.pipe(res);
  }

  @Delete(":id")
  @HttpCode(204)
  async remove(@Param("id", ParseIntPipe) id: number) {
    const [row] = await this.db.query<FileRow>("DELETE FROM files WHERE id = $1 RETURNING *", [id]);
    if (!row) throw new NotFoundException();
    await this.storage.remove(row.object_key);
  }
}
