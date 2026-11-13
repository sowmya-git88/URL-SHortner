import { client, connect } from "./db.js";

const days = (n) => {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() - n);
  return d.toISOString().slice(0, 10);
};

const samples = [
  { name: "Read 20 pages", color: "#3b82f6", checkins: [days(0), days(1), days(2), days(3)] },
  { name: "Linux lab 1 hour", color: "#22c55e", checkins: [days(1), days(2)] },
  { name: "Walk 8k steps", color: "#f59e0b", checkins: [days(0), days(2), days(5)] },
];

const db = await connect();
for (const s of samples) {
  await db.collection("habits").updateOne(
    { name: s.name },
    { $setOnInsert: { ...s, createdAt: new Date() } },
    { upsert: true }
  );
}
console.log(`seeded ${samples.length} habits`);
await client.close();
