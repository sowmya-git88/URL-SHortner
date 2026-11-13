const { createApp } = Vue;

async function api(path, opts = {}) {
  const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...opts });
  if (res.status === 204) return null;
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
  return body;
}

createApp({
  data() {
    return {
      langs: ["text", "bash", "python", "ruby", "javascript", "go", "sql", "yaml", "json", "dockerfile", "nginx"],
      form: { title: "", lang: "bash", ttl_hours: 72, content: "" },
      recent: [],
      viewing: null,
      error: "",
      busy: false,
      health: "checking API…",
      stats: "",
      location: window.location,
    };
  },
  methods: {
    async refresh() {
      try {
        this.recent = await api("/api/snippets");
        const s = await api("/api/stats");
        this.stats = `${s.created} created · ${s.views} views · ${s.keys_in_db} keys`;
      } catch (e) { this.error = e.message; }
    },
    async route() {
      const m = location.hash.match(/^#\/s\/([A-Za-z0-9]{8})$/);
      this.error = "";
      if (!m) { this.viewing = null; return; }
      try { this.viewing = await api(`/api/snippets/${m[1]}`); }
      catch (e) { this.viewing = null; this.error = e.message; }
    },
    async create() {
      this.busy = true;
      try {
        const r = await api("/api/snippets", { method: "POST", body: JSON.stringify(this.form) });
        this.form.content = ""; this.form.title = "";
        location.hash = `#/s/${r.id}`;
        await this.refresh();
      } catch (e) { this.error = e.message; }
      finally { this.busy = false; }
    },
    async remove(id) {
      if (!confirm("Delete snippet?")) return;
      await api(`/api/snippets/${id}`, { method: "DELETE" });
      location.hash = "#/";
      await this.refresh();
    },
    copy(text) { navigator.clipboard?.writeText(text); },
    expiry(s) {
      if (!s) return "no expiry";
      const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
      return `expires in ${h}h ${m}m`;
    },
  },
  async mounted() {
    window.addEventListener("hashchange", () => this.route());
    await Promise.all([this.refresh(), this.route()]);
    try {
      const h = await api("/api/health");
      this.health = `API ${h.status} · Ruby ${h.ruby} · Redis ${h.redis_ms} ms · pid ${h.pid}`;
    } catch (e) { this.health = `API unreachable: ${e.message}`; }
  },
}).mount("#app");
