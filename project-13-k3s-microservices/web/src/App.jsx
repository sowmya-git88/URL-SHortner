import { useCallback, useEffect, useState } from "react";

async function api(path, opts = {}) {
  const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...opts });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
  return { body, pod: res.headers.get("x-served-by") };
}

export default function App() {
  const [jobs, setJobs] = useState([]);
  const [stats, setStats] = useState(null);
  const [text, setText] = useState("Pods are cattle, not pets. Probes tell Kubernetes when to restart and when to route traffic.");
  const [apiPods, setApiPods] = useState({});
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    try {
      const [j, s] = await Promise.all([api("/api/jobs"), api("/api/stats")]);
      setJobs(j.body);
      setStats(s.body);
      setApiPods((p) => ({ ...p, [j.pod]: Date.now() }));
      setError("");
    } catch (e) { setError(e.message); }
  }, []);

  useEffect(() => { load(); const t = setInterval(load, 2000); return () => clearInterval(t); }, [load]);

  const submit = async (n = 1) => {
    try {
      await Promise.all(Array.from({ length: n }, (_, i) =>
        api("/api/jobs", { method: "POST", body: JSON.stringify({ input: n > 1 ? `${text} (#${i + 1})` : text }) })));
      load();
    } catch (e) { setError(e.message); }
  };

  const recentApiPods = Object.entries(apiPods).filter(([, t]) => Date.now() - t < 20000).map(([p]) => p);

  return (
    <main>
      <h1>☸️ k3s Jobs</h1>
      <p className="muted">React (nginx) → Traefik Ingress → Go API (×2) → Postgres StatefulSet ← Python workers (×N) · Project 13</p>
      {error && <p className="error">{error}</p>}

      {stats && (
        <section className="kpis">
          {Object.entries(stats.counts).map(([k, v]) => <div key={k} className={k}><b>{v}</b><span>{k}</span></div>)}
        </section>
      )}

      <section className="pods">
        <div><h3>API pods answering</h3>{recentApiPods.map((p) => <code key={p}>{p}</code>)}</div>
        <div><h3>Workers active (5 min)</h3>{stats?.active_workers.map((p) => <code key={p}>{p}</code>)}</div>
      </section>

      <textarea rows={3} value={text} onChange={(e) => setText(e.target.value)} />
      <p>
        <button onClick={() => submit(1)}>Submit job</button>
        <button className="ghost" onClick={() => submit(25)}>Submit 25 jobs</button>
      </p>

      <table>
        <thead><tr><th>#</th><th>Status</th><th>Words</th><th>Top words</th><th>Processed by</th><th>Tries</th></tr></thead>
        <tbody>
          {jobs.map((j) => (
            <tr key={j.id}>
              <td>{j.id}</td>
              <td><span className={`st ${j.status}`}>{j.status}</span></td>
              <td>{j.result?.words ?? "—"}</td>
              <td>{j.result?.top_words?.map(([w, c]) => `${w}×${c}`).join(", ") ?? j.error ?? "—"}</td>
              <td><code>{j.processed_by ?? "—"}</code></td>
              <td>{j.attempts}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </main>
  );
}
