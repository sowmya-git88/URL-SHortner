import { MongoClient } from "mongodb";

const uri = process.env.MONGODB_URI;
const dbName = process.env.MONGODB_DB || "habits";

if (!uri) {
  console.error("FATAL: MONGODB_URI is not set (EnvironmentFile missing?)");
  process.exit(78); // EX_CONFIG — systemd shows status=78
}

export const client = new MongoClient(uri, {
  maxPoolSize: 5,
  serverSelectionTimeoutMS: 8000,
  appName: "habit-tracker",
});

let db;

export async function connect() {
  await client.connect();
  db = client.db(dbName);
  await db.collection("habits").createIndex({ name: 1 }, { unique: true });
  await db.collection("habits").createIndex({ createdAt: -1 });
  return db;
}

export function getDb() {
  if (!db) throw new Error("database not connected");
  return db;
}
