"use client";

import { FormEvent, useCallback, useEffect, useState } from "react";

type Task = { id: number; title: string; done: boolean };
type FileRow = { id: number; filename: string; content_type: string; size_bytes: string; created_at: string };
type Health = { status: string; checks: Record<string, boolean>; container: string; rss_mb: number; took_ms: number };

async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, init);
  if (res.status === 204) return undefined as T;
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.message || body.error || `HTTP ${res.status}`);
  return body as T;
}

export default function Home() {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [source, setSource] = useState("");
  const [files, setFiles] = useState<FileRow[]>([]);
  const [health, setHealth] = useState<Health | null>(null);
  const [title, setTitle] = useState("");
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    try {
      const t = await api<{ source: string; tasks: Task[] }>("/api/tasks");
      setTasks(t.tasks);
      setSource(t.source);
      setFiles(await api<FileRow[]>("/api/files"));
      setHealth(await api<Health>("/api/health"));
      setError("");
    } catch (e) {
      setError((e as Error).message);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const addTask = async (e: FormEvent) => {
    e.preventDefault();
    try {
      await api("/api/tasks", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ title }) });
      setTitle("");
      load();
    } catch (x) {
      setError((x as Error).message);
    }
  };

  const toggle = async (t: Task) => {
    await api(`/api/tasks/${t.id}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ done: !t.done }) });
    load();
  };

  const removeTask = async (t: Task) => {
    await api(`/api/tasks/${t.id}`, { method: "DELETE" });
    load();
  };

  const upload = async (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const form = e.currentTarget;
    try {
      await api("/api/files", { method: "POST", body: new FormData(form) });
      form.reset();
      load();
    } catch (x) {
      setError((x as Error).message);
    }
  };

  const removeFile = async (f: FileRow) => {
    await api(`/api/files/${f.id}`, { method: "DELETE" });
    load();
  };

  return (
    <main>
      <h1>📦 TaskBox</h1>
      <p className="muted">Next.js → Caddy → NestJS → Postgres · Redis · MinIO — all in Docker Compose · Project 11</p>
      {error && <p className="error">{error}</p>}

      <section className="grid">
        <div className="panel">
          <h2>Tasks <small className="muted">(served from {source || "…"})</small></h2>
          <form onSubmit={addTask} className="row">
            <input value={title} onChange={(e) => setTitle(e.target.value)} placeholder="New task" required maxLength={200} />
            <button>Add</button>
          </form>
          <ul>
            {tasks.map((t) => (
              <li key={t.id} className={t.done ? "done" : ""}>
                <label>
                  <input type="checkbox" checked={t.done} onChange={() => toggle(t)} /> {t.title}
                </label>
                <button className="x" onClick={() => removeTask(t)}>✕</button>
              </li>
            ))}
          </ul>
        </div>

        <div className="panel">
          <h2>Files (MinIO)</h2>
          <form onSubmit={upload} className="row">
            <input type="file" name="file" required />
            <button>Upload</button>
          </form>
          <ul>
            {files.map((f) => (
              <li key={f.id}>
                <a href={`/api/files/${f.id}/download`}>{f.filename}</a>
                <small className="muted"> {(Number(f.size_bytes) / 1024).toFixed(1)} KB</small>
                <button className="x" onClick={() => removeFile(f)}>✕</button>
              </li>
            ))}
          </ul>
        </div>
      </section>

      <footer className="muted">
        {health
          ? `API ${health.status} · container ${health.container} · ${Object.entries(health.checks).map(([k, v]) => `${k} ${v ? "✓" : "✗"}`).join(" · ")} · rss ${health.rss_mb} MB · ${health.took_ms} ms`
          : "checking API…"}
      </footer>
    </main>
  );
}
