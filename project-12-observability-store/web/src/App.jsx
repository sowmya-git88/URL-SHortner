import { useCallback, useEffect, useState } from "react";

async function api(path, opts = {}) {
  const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...opts });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
  return body;
}

const money = (c) => `$${(c / 100).toFixed(2)}`;

export default function App() {
  const [products, setProducts] = useState([]);
  const [orders, setOrders] = useState([]);
  const [stats, setStats] = useState(null);
  const [health, setHealth] = useState(null);
  const [customer, setCustomer] = useState("sowmya");
  const [msg, setMsg] = useState("");

  const load = useCallback(async () => {
    try {
      const [p, o, s, h] = await Promise.all([api("/api/products"), api("/api/orders"), api("/api/stats"), api("/api/health")]);
      setProducts(p); setOrders(o); setStats(s); setHealth(h);
    } catch (e) { setMsg(e.message); }
  }, []);

  useEffect(() => { load(); const t = setInterval(load, 3000); return () => clearInterval(t); }, [load]);

  const buy = async (sku, quantity = 1) => {
    try {
      const o = await api("/api/orders", { method: "POST", body: JSON.stringify({ customer, sku, quantity }) });
      setMsg(`Order #${o.id} created → Kafka → fulfillment…`);
      load();
    } catch (e) { setMsg(`❌ ${e.message}`); }
  };

  const burst = async () => {
    setMsg("Sending 50 orders…");
    await Promise.allSettled(Array.from({ length: 50 }, (_, i) => buy(products[i % products.length].sku)));
    load();
  };

  return (
    <main>
      <h1>🛒 Observability Store</h1>
      <p className="muted">React → Nginx → Spring Boot (Java 21) → Postgres + Kafka · metrics → Prometheus → Grafana · Project 12</p>

      {stats && (
        <section className="kpis">
          <div><b>{stats.total}</b><span>orders</span></div>
          <div><b>{stats.fulfilled}</b><span>fulfilled</span></div>
          <div className={stats.pending > 10 ? "warn" : ""}><b>{stats.pending}</b><span>pending (Kafka lag)</span></div>
          <div><b>{money(stats.revenue_cents)}</b><span>revenue</span></div>
        </section>
      )}

      <label className="cust">Customer <input value={customer} onChange={(e) => setCustomer(e.target.value)} /></label>
      <section className="products">
        {products.map((p) => (
          <article key={p.sku}>
            <h3>{p.name}</h3>
            <p className="muted">{p.sku} · {p.stock} in stock</p>
            <p className="price">{money(p.price_cents)}</p>
            <button disabled={p.stock < 1} onClick={() => buy(p.sku)}>Buy</button>
          </article>
        ))}
      </section>
      <p>
        <button className="ghost" onClick={burst} disabled={!products.length}>⚡ Load test: 50 orders</button>
        <button className="ghost" onClick={() => fetch("/api/chaos/error")}>💥 Trigger a 500</button>
      </p>
      <p className="msg">{msg}</p>

      <h2>Recent orders</h2>
      <table>
        <thead><tr><th>#</th><th>Customer</th><th>SKU</th><th>Qty</th><th>Total</th><th>Status</th></tr></thead>
        <tbody>
          {orders.map((o) => (
            <tr key={o.id}>
              <td>{o.id}</td><td>{o.customer}</td><td>{o.sku}</td><td>{o.quantity}</td><td>{money(o.total_cents)}</td>
              <td><span className={`st ${o.status}`}>{o.status}</span></td>
            </tr>
          ))}
        </tbody>
      </table>
      <footer className="muted">
        {health ? `API ${health.status} · Java ${health.java} · heap ${health.heap_used_mb}/${health.heap_max_mb} MB · up ${health.uptime_s}s` : "checking…"}
        {" · Grafana http://127.0.0.1:3000 · Prometheus http://127.0.0.1:9090"}
      </footer>
    </main>
  );
}
