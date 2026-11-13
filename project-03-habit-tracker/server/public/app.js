function habitApp() {
  const iso = (d) => d.toISOString().slice(0, 10);
  return {
    habits: [],
    newName: "",
    newColor: "#22c55e",
    error: "",
    health: "checking API…",
    lastDays: [],
    async api(path, opts = {}) {
      const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...opts });
      if (res.status === 204) return null;
      const body = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
      return body;
    },
    async init() {
      const days = [];
      for (let i = 6; i >= 0; i--) {
        const d = new Date();
        d.setUTCDate(d.getUTCDate() - i);
        days.push(iso(d));
      }
      this.lastDays = days;
      await this.load();
      try {
        const h = await this.api("/api/health");
        this.health = `API ${h.status} · pid ${h.pid} · rss ${h.rss_mb} MB · up ${h.uptime_s}s`;
      } catch (e) { this.health = `API unreachable: ${e.message}`; }
    },
    async load() {
      try { this.habits = await this.api("/api/habits"); this.error = ""; }
      catch (e) { this.error = e.message; }
    },
    async add() {
      try {
        await this.api("/api/habits", { method: "POST", body: JSON.stringify({ name: this.newName, color: this.newColor }) });
        this.newName = "";
        await this.load();
      } catch (e) { this.error = e.message; }
    },
    async toggle(h, date) {
      try {
        const updated = await this.api(`/api/habits/${h.id}/toggle`, { method: "POST", body: JSON.stringify({ date }) });
        this.habits = this.habits.map((x) => (x.id === updated.id ? updated : x));
      } catch (e) { this.error = e.message; }
    },
    async remove(h) {
      if (!confirm(`Delete "${h.name}"?`)) return;
      await this.api(`/api/habits/${h.id}`, { method: "DELETE" });
      await this.load();
    },
  };
}
