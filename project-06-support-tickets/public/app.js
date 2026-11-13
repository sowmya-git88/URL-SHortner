// Preact + htm straight from an ES-module CDN: no Node build step on the 1 GB server.
import { h, render } from "https://esm.sh/preact@10.24.3";
import { useEffect, useState } from "https://esm.sh/preact@10.24.3/hooks";
import htm from "https://esm.sh/htm@3.1.1";

const html = htm.bind(h);

async function api(path, opts = {}) {
  const res = await fetch(path, { credentials: "same-origin", headers: { "Content-Type": "application/json" }, ...opts });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
  return body;
}

function NewTicket() {
  const [msg, setMsg] = useState("");
  const submit = async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    try {
      const r = await api("/api/tickets", { method: "POST", body: JSON.stringify(Object.fromEntries(f)) });
      setMsg(`✅ Ticket #${r.id} created. We'll get back to you.`);
      e.target.reset();
    } catch (err) { setMsg(`❌ ${err.message}`); }
  };
  return html`<section class="panel">
    <h2>Open a ticket</h2>
    <form onSubmit=${submit}>
      <input name="requester" type="email" placeholder="Your email" required />
      <input name="subject" placeholder="Subject" maxlength="160" required />
      <select name="priority">${["low", "normal", "high", "urgent"].map((p) => html`<option selected=${p === "normal"}>${p}</option>`)}</select>
      <textarea name="body" rows="4" placeholder="Describe the problem" required></textarea>
      <button>Submit</button>
    </form>
    <p>${msg}</p>
  </section>`;
}

function Login({ onLogin }) {
  const [err, setErr] = useState("");
  const submit = async (e) => {
    e.preventDefault();
    const f = Object.fromEntries(new FormData(e.target));
    try { onLogin((await api("/api/login", { method: "POST", body: JSON.stringify(f) })).agent); }
    catch (x) { setErr(x.message); }
  };
  return html`<section class="panel">
    <h2>Agent login</h2>
    <form onSubmit=${submit}>
      <input name="email" type="email" placeholder="agent@example.com" required />
      <input name="password" type="password" placeholder="Password" required />
      <button>Log in</button>
    </form>
    <p class="error">${err}</p>
  </section>`;
}

function TicketDetail({ id, onChange }) {
  const [t, setT] = useState(null);
  const load = () => api(`/api/tickets/${id}`).then(setT);
  useEffect(() => { load(); }, [id]);
  if (!t) return html`<p>Loading…</p>`;
  const patch = async (data) => { await api(`/api/tickets/${id}`, { method: "PATCH", body: JSON.stringify(data) }); await load(); onChange(); };
  const comment = async (e) => {
    e.preventDefault();
    await api(`/api/tickets/${id}/comments`, { method: "POST", body: JSON.stringify({ body: e.target.body.value }) });
    e.target.reset(); await load();
  };
  return html`<div class="detail">
    <h3>#${t.id} ${t.subject}</h3>
    <p class="muted">from ${t.requester} · ${t.created_at} · assignee: ${t.assignee || "—"}</p>
    <p class="body">${t.body}</p>
    <div class="actions">
      <select value=${t.status} onChange=${(e) => patch({ status: e.target.value })}>
        ${["open", "pending", "resolved", "closed"].map((s) => html`<option value=${s}>${s}</option>`)}
      </select>
      <select value=${t.priority} onChange=${(e) => patch({ priority: e.target.value })}>
        ${["low", "normal", "high", "urgent"].map((s) => html`<option value=${s}>${s}</option>`)}
      </select>
      <button onClick=${() => patch({ assign_to_me: true })}>Assign to me</button>
    </div>
    <ul class="comments">${t.comments.map((c) => html`<li><b>${c.author}</b> <small>${c.created_at}</small><br/>${c.body}</li>`)}</ul>
    <form onSubmit=${comment}><textarea name="body" rows="2" placeholder="Internal reply" required></textarea><button>Comment</button></form>
  </div>`;
}

function Dashboard({ agent, onLogout }) {
  const [data, setData] = useState({ tickets: [], counts: {} });
  const [filter, setFilter] = useState("");
  const [sel, setSel] = useState(null);
  const load = () => api(`/api/tickets${filter ? `?status=${filter}` : ""}`).then(setData);
  useEffect(() => { load(); }, [filter]);
  return html`<section class="panel wide">
    <div class="row"><h2>Queue</h2><span>${agent.name} · <a href="#" onClick=${async (e) => { e.preventDefault(); await api("/api/logout", { method: "POST" }); onLogout(); }}>log out</a></span></div>
    <div class="filters">
      ${["", "open", "pending", "resolved", "closed"].map((s) => html`<button class=${filter === s ? "on" : ""} onClick=${() => setFilter(s)}>${s || "all"} ${s ? `(${data.counts[s] || 0})` : ""}</button>`)}
    </div>
    <div class="split">
      <ul class="list">${data.tickets.map((t) => html`<li class=${`p-${t.priority} ${sel === t.id ? "sel" : ""}`} onClick=${() => setSel(t.id)}>
        <b>#${t.id}</b> ${t.subject}<br/><small>${t.status} · ${t.priority} · ${t.requester}</small></li>`)}</ul>
      ${sel ? html`<${TicketDetail} id=${sel} onChange=${load} />` : html`<p class="muted">Select a ticket</p>`}
    </div>
  </section>`;
}

function App() {
  const [agent, setAgent] = useState(undefined);
  const [health, setHealth] = useState("checking…");
  useEffect(() => {
    api("/api/me").then((r) => setAgent(r.agent)).catch(() => setAgent(null));
    api("/api/health").then((x) => setHealth(`API ${x.status} · PHP ${x.php} (${x.sapi}) as ${x.user} · DB ${x.db_ms} ms · https=${x.https}`))
      .catch((e) => setHealth(`API unreachable: ${e.message}`));
  }, []);
  return html`<main>
    <h1>🎫 HelpDesk Lite</h1>
    <p class="muted">Preact → Nginx → PHP-FPM (Unix socket) → Aiven MySQL · Project 06</p>
    <div class="grid">
      <${NewTicket} />
      ${agent === undefined ? null : agent ? html`<${Dashboard} agent=${agent} onLogout=${() => setAgent(null)} />` : html`<${Login} onLogin=${setAgent} />`}
    </div>
    <footer class="muted">${health}</footer>
  </main>`;
}

render(html`<${App} />`, document.getElementById("app"));
