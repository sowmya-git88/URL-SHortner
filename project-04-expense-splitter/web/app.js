const $ = (s, el = document) => el.querySelector(s);
const state = { groups: [], current: null };

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const money = (cents, cur = "INR") =>
  new Intl.NumberFormat(undefined, { style: "currency", currency: cur }).format(cents / 100);

async function api(path, opts = {}) {
  const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...opts });
  if (res.status === 204) return null;
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const msg = Array.isArray(body.detail) ? body.detail.map((d) => d.msg).join("; ") : body.detail || body.error;
    throw new Error(msg || `HTTP ${res.status}`);
  }
  return body;
}

function showError(e) { $("#error").textContent = e ? e.message : ""; }

async function loadGroups() {
  state.groups = await api("/api/groups");
  $("#groups").innerHTML = state.groups.map((g) => `
    <li><button class="link ${state.current?.id === g.id ? "active" : ""}" data-id="${g.id}">
      ${esc(g.name)} <small>${g.member_count} people · ${money(g.total_cents, g.currency)}</small>
    </button></li>`).join("") || "<li class='muted'>No groups yet</li>";
}

async function openGroup(id) {
  state.current = await api(`/api/groups/${id}`);
  renderDetail();
  await loadGroups();
}

function renderDetail() {
  const g = state.current;
  const cur = g.currency;
  const opts = g.members.map((m) => `<option value="${m.id}">${esc(m.name)}</option>`).join("");
  const checks = g.members.map((m) => `<label><input type="checkbox" name="split" value="${m.id}" checked> ${esc(m.name)}</label>`).join("");
  $("#detail").innerHTML = `
    <div class="row-between"><h2>${esc(g.name)}</h2><button id="del-group" class="danger">Delete group</button></div>

    <h3>Balances</h3>
    <ul class="balances">${g.members.map((m) => `
      <li><span>${esc(m.name)}</span>
      <strong class="${m.balance_cents >= 0 ? "pos" : "neg"}">${money(m.balance_cents, cur)}</strong></li>`).join("")}</ul>
    <form id="member-form" class="inline"><input name="name" placeholder="Add member" required><button>Add</button></form>

    <h3>Settle up</h3>
    <ul>${g.settle_up.map((t) => `<li>${esc(t.from_name)} → ${esc(t.to_name)}: <strong>${money(t.amount_cents, cur)}</strong></li>`).join("") || "<li class='muted'>All settled 🎉</li>"}</ul>

    <h3>Add expense</h3>
    <form id="expense-form">
      <input name="description" placeholder="Description" required>
      <input name="amount" type="number" step="0.01" min="0.01" placeholder="Amount" required>
      <label>Paid by <select name="paid_by">${opts}</select></label>
      <fieldset><legend>Split among</legend>${checks}</fieldset>
      <button ${g.members.length ? "" : "disabled"}>Add expense</button>
    </form>

    <h3>Expenses</h3>
    <table><tbody>${g.expenses.map((e) => `
      <tr><td>${esc(e.description)}</td><td>${esc(e.paid_by_name)}</td><td>${money(e.amount_cents, cur)}</td>
      <td><button class="x" data-exp="${e.id}">✕</button></td></tr>`).join("")}</tbody></table>`;
}

document.addEventListener("click", async (ev) => {
  try {
    const gBtn = ev.target.closest("button[data-id]");
    if (gBtn) return await openGroup(gBtn.dataset.id);
    const xBtn = ev.target.closest("button[data-exp]");
    if (xBtn) {
      await api(`/api/groups/${state.current.id}/expenses/${xBtn.dataset.exp}`, { method: "DELETE" });
      return await openGroup(state.current.id);
    }
    if (ev.target.id === "del-group" && confirm("Delete this group?")) {
      await api(`/api/groups/${state.current.id}`, { method: "DELETE" });
      state.current = null;
      $("#detail").innerHTML = "<p class='muted'>Group deleted.</p>";
      await loadGroups();
    }
  } catch (e) { showError(e); }
});

document.addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const f = ev.target;
  const data = new FormData(f);
  try {
    showError(null);
    if (f.id === "group-form") {
      const members = String(data.get("members") || "").split(",").map((s) => s.trim()).filter(Boolean);
      const g = await api("/api/groups", { method: "POST", body: JSON.stringify({ name: data.get("name"), members }) });
      f.reset();
      await openGroup(g.id);
    } else if (f.id === "member-form") {
      await api(`/api/groups/${state.current.id}/members`, { method: "POST", body: JSON.stringify({ name: data.get("name") }) });
      await openGroup(state.current.id);
    } else if (f.id === "expense-form") {
      const split_among = data.getAll("split").map(Number);
      await api(`/api/groups/${state.current.id}/expenses`, {
        method: "POST",
        body: JSON.stringify({ description: data.get("description"), amount: data.get("amount"), paid_by: Number(data.get("paid_by")), split_among }),
      });
      await openGroup(state.current.id);
    }
  } catch (e) { showError(e); }
});

(async () => {
  try {
    const h = await api("/api/health");
    $("#health").textContent = `API ${h.status} · pid ${h.pid} · pool ${h.pool.available}/${h.pool.size}`;
  } catch (e) { $("#health").textContent = `API unreachable: ${e.message}`; }
  try { await loadGroups(); } catch (e) { showError(e); }
})();
