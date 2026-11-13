import { Injectable, Logger, OnModuleInit } from "@nestjs/common";
import * as Minio from "minio";
import { Readable } from "stream";

@Injectable()
export class StorageService implements OnModuleInit {
  private readonly log = new Logger("Storage");
  readonly bucket = process.env.MINIO_BUCKET ?? "saas-files";
  readonly client = new Minio.Client({
    endPoint: process.env.MINIO_ENDPOINT ?? "minio",
    port: Number(process.env.MINIO_PORT ?? 9000),
    useSSL: false, // traffic stays inside the internal 'data' network
    accessKey: process.env.MINIO_ACCESS_KEY ?? "",
    secretKey: process.env.MINIO_SECRET_KEY ?? "",
  });

  async onModuleInit() {
    if (!(await this.client.bucketExists(this.bucket))) {
      await this.client.makeBucket(this.bucket);
      this.log.log(`created bucket ${this.bucket}`);
    }
  }

  async put(key: string, data: Buffer, contentType: string) {
    await this.client.putObject(this.bucket, key, data, data.length, { "Content-Type": contentType });
  }

  async get(key: string): Promise<Readable> {
    return this.client.getObject(this.bucket, key);
  }

  async remove(key: string) {
    await this.client.removeObject(this.bucket, key);
  }

  async ping(): Promise<boolean> {
    return this.client.bucketExists(this.bucket);
  }
}
