const $ = (sel) => document.querySelector(sel);

async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (res.status === 204) return null;
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
  return body;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

async function loadLinks() {
  const links = await api("/api/links");
  $("#links").innerHTML = links
    .map(
      (l) => `<tr>
        <td><a href="${escapeHtml(l.short_url)}" target="_blank" rel="noopener">${escapeHtml(l.code)}</a></td>
        <td class="target" title="${escapeHtml(l.target_url)}">${escapeHtml(l.target_url)}</td>
        <td>${l.clicks}</td>
        <td><button class="del" data-code="${escapeHtml(l.code)}">✕</button></td>
      </tr>`
    )
    .join("");
}

async function checkHealth() {
  try {
    const h = await api("/api/health");
    $("#health").textContent = `API ${h.status} · pid ${h.pid} · uptime ${h.uptime_seconds}s`;
  } catch (e) {
    $("#health").textContent = `API unreachable: ${e.message}`;
  }
}

$("#shorten-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  $("#error").hidden = true;
  $("#result").hidden = true;
  try {
    const payload = { url: $("#url").value.trim() };
    const code = $("#code").value.trim();
    if (code) payload.code = code;
    const link = await api("/api/links", { method: "POST", body: JSON.stringify(payload) });
    $("#result").innerHTML = `Short URL: <a href="${escapeHtml(link.short_url)}" target="_blank">${escapeHtml(link.short_url)}</a>`;
    $("#result").hidden = false;
    ev.target.reset();
    await loadLinks();
  } catch (e) {
    $("#error").textContent = e.message;
    $("#error").hidden = false;
  }
});

$("#links").addEventListener("click", async (ev) => {
  const btn = ev.target.closest("button.del");
  if (!btn) return;
  await api(`/api/links/${encodeURIComponent(btn.dataset.code)}`, { method: "DELETE" });
  await loadLinks();
});

loadLinks().catch((e) => { $("#error").textContent = e.message; $("#error").hidden = false; });
checkHealth();
