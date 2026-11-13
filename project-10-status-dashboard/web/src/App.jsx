import { Fragment, useCallback, useEffect, useState } from "react";

async function api(path, opts = {}) {
  const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...opts });
  if (res.status === 204) return { data: null, servedBy: res.headers.get("x-served-by") };
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return { data, servedBy: res.headers.get("x-served-by") };
}

function Badge({ latest }) {
  if (!latest) return <span className="badge pending">pending</span>;
  return <span className={`badge ${latest.ok ? "up" : "down"}`}>{latest.ok ? "UP" : "DOWN"}</span>;
}

function History({ id }) {
  const [rows, setRows] = useState([]);
  useEffect(() => { api(`/api/monitors/${id}/history`).then((r) => setRows(r.data.slice().reverse())); }, [id]);
  return (
    <div className="bars" title="last 60 checks">
      {rows.map((r, i) => (
        <span key={i} className={r.ok ? "bar ok" : "bar ko"} title={`${r.checked_at} · ${r.status_code ?? r.error} · ${r.latency_ms} ms`} />
      ))}
    </div>
  );
}

export default function App() {
  const [monitors, setMonitors] = useState([]);
  const [health, setHealth] = useState(null);
  const [servedBy, setServedBy] = useState("");
  const [error, setError] = useState("");
  const [form, setForm] = useState({ name: "", url: "" });
  const [open, setOpen] = useState(null);

  const load = useCallback(async () => {
    try {
      const s = await api("/api/status");
      setMonitors(s.data);
      setServedBy(s.servedBy);
      setHealth((await api("/api/health")).data);
      setError("");
    } catch (e) { setError(e.message); }
  }, []);

  useEffect(() => { load(); const t = setInterval(load, 15000); return () => clearInterval(t); }, [load]);

  const add = async (e) => {
    e.preventDefault();
    try { await api("/api/monitors", { method: "POST", body: JSON.stringify(form) }); setForm({ name: "", url: "" }); load(); }
    catch (x) { setError(x.message); }
  };
  const remove = async (id) => { if (confirm("Remove monitor?")) { await api(`/api/monitors/${id}`, { method: "DELETE" }); load(); } };

  const down = monitors.filter((m) => m.latest && !m.latest.ok).length;

  return (
    <main>
      <header>
        <h1>📡 Status Dashboard</h1>
        <p className="muted">React (bun build) → Caddy → Bun ({servedBy || "…"}) → Neon + Upstash · Project 10</p>
        <div className={`overall ${down ? "bad" : "good"}`}>{down ? `${down} service(s) down` : "All systems operational"}</div>
      </header>

      {error && <p className="error">{error}</p>}

      <table>
        <thead><tr><th>Service</th><th>Status</th><th>Latency</th><th>Uptime 24h</th><th></th></tr></thead>
        <tbody>
          {monitors.map((m) => (
            <Fragment key={m.id}>
              <tr onClick={() => setOpen(open === m.id ? null : m.id)} className="row">
                <td><strong>{m.name}</strong><br /><small className="muted">{m.url}</small></td>
                <td><Badge latest={m.latest} /></td>
                <td>{m.latest ? `${m.latest.latency_ms} ms` : "—"}</td>
                <td>{m.uptime_24h === null ? "—" : `${m.uptime_24h}%`}</td>
                <td><button className="x" onClick={(e) => { e.stopPropagation(); remove(m.id); }}>✕</button></td>
              </tr>
              {open === m.id && <tr><td colSpan={5}><History id={m.id} /></td></tr>}
            </Fragment>
          ))}
        </tbody>
      </table>

      <form onSubmit={add}>
        <input placeholder="Name" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} required />
        <input placeholder="https://example.com/health" value={form.url} onChange={(e) => setForm({ ...form, url: e.target.value })} required />
        <button>Add monitor</button>
      </form>

      <footer className="muted">
        {health ? `instance ${health.color} · v${health.version} · Bun ${health.bun} · rss ${health.rss_mb} MB · db ${health.db_ok ? "✓" : "✗"} · redis ${health.redis_ok ? "✓" : "✗"}` : "checking…"}
      </footer>
    </main>
  );
}
