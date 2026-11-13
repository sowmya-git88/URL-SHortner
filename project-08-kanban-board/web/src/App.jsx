import { createResource, createSignal, For, Show } from "solid-js";

async function api(path, opts = {}) {
  const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...opts });
  if (res.status === 204) return null;
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
  return body;
}

export default function App() {
  const [boardId, setBoardId] = createSignal(null);
  const [boards, { refetch: refetchBoards }] = createResource(async () => {
    const list = await api("/api/boards");
    if (!boardId() && list.length) setBoardId(list[0].id);
    return list;
  });
  const [board, { refetch }] = createResource(boardId, (id) => api(`/api/boards/${id}`));
  const [health] = createResource(() => api("/api/health").catch((e) => ({ status: e.message })));
  const [dragging, setDragging] = createSignal(null);
  const [error, setError] = createSignal("");

  const run = async (fn) => {
    try { setError(""); await fn(); await refetch(); } catch (e) { setError(e.message); }
  };

  const addBoard = (e) => {
    e.preventDefault();
    const name = e.target.name.value;
    run(async () => {
      const b = await api("/api/boards", { method: "POST", body: JSON.stringify({ name }) });
      e.target.reset();
      await refetchBoards();
      setBoardId(b.id);
    });
  };

  const addCard = (e, col) => {
    e.preventDefault();
    const title = e.target.title.value;
    run(async () => {
      await api(`/api/columns/${col.id}/cards`, { method: "POST", body: JSON.stringify({ title }) });
      e.target.reset();
    });
  };

  // Drop on a column: append after its last card (fractional positions avoid renumbering)
  const dropOn = (col, beforeCard) => {
    const card = dragging();
    if (!card) return;
    const cards = col.cards.filter((c) => c.id !== card.id);
    let position;
    if (beforeCard) {
      const idx = cards.findIndex((c) => c.id === beforeCard.id);
      const prev = idx > 0 ? cards[idx - 1].position : 0;
      position = (prev + beforeCard.position) / 2;
    } else {
      position = cards.length ? cards[cards.length - 1].position + 1 : 1;
    }
    setDragging(null);
    run(() => api(`/api/cards/${card.id}`, { method: "PATCH", body: JSON.stringify({ column_id: col.id, position }) }));
  };

  const editCard = (card) => {
    const title = prompt("Card title", card.title);
    if (title === null) return;
    const description = prompt("Description", card.description) ?? card.description;
    run(() => api(`/api/cards/${card.id}`, { method: "PATCH", body: JSON.stringify({ title, description }) }));
  };

  return (
    <main>
      <header>
        <h1>🗂️ Kanban</h1>
        <p class="muted">SolidJS → Caddy → Deno (PM2) → CockroachDB · Project 08</p>
      </header>

      <nav>
        <For each={boards()}>
          {(b) => <button classList={{ on: b.id === boardId() }} onClick={() => setBoardId(b.id)}>{b.name}</button>}
        </For>
        <form onSubmit={addBoard}><input name="name" placeholder="New board" required /><button>+</button></form>
      </nav>

      <Show when={error()}><p class="error">{error()}</p></Show>

      <Show when={board()} fallback={<p class="muted">Loading board…</p>}>
        <section class="board">
          <For each={board().columns}>
            {(col) => (
              <div class="column" onDragOver={(e) => e.preventDefault()} onDrop={() => dropOn(col)}>
                <h2>{col.name} <small>{col.cards.length}</small></h2>
                <For each={col.cards}>
                  {(card) => (
                    <article draggable="true" class="card"
                      onDragStart={() => setDragging(card)}
                      onDrop={(e) => { e.stopPropagation(); dropOn(col, card); }}
                      onDblClick={() => editCard(card)}>
                      <strong>{card.title}</strong>
                      <Show when={card.description}><p>{card.description}</p></Show>
                      <button class="x" onClick={() => run(() => api(`/api/cards/${card.id}`, { method: "DELETE" }))}>✕</button>
                    </article>
                  )}
                </For>
                <form onSubmit={(e) => addCard(e, col)}><input name="title" placeholder="+ add card" required /></form>
              </div>
            )}
          </For>
        </section>
      </Show>
      <footer class="muted">
        {health() ? `API ${health().status}${health().deno ? ` · Deno ${health().deno} · ${health().db_version} · rss ${health().rss_mb} MB` : ""}` : "checking API…"}
        {" · double-click a card to edit, drag to move"}
      </footer>
    </main>
  );
}
