<script>
  import { api } from "./api.js";

  let decks = $state([]);
  let current = $state(null);
  let queue = $state([]);
  let cards = $state([]);
  let flipped = $state(false);
  let error = $state("");
  let health = $state("checking API…");
  let newDeck = $state("");
  let front = $state("");
  let back = $state("");

  const card = $derived(queue[0]);

  async function loadDecks() {
    try { decks = await api("/api/decks"); } catch (e) { error = e.message; }
  }

  async function openDeck(d) {
    current = d;
    flipped = false;
    [queue, cards] = await Promise.all([api(`/api/decks/${d.id}/due`), api(`/api/decks/${d.id}/cards`)]);
  }

  async function grade(g) {
    await api(`/api/cards/${card.id}/review`, { method: "POST", body: JSON.stringify({ grade: g }) });
    queue = queue.slice(1);
    flipped = false;
    await loadDecks();
  }

  async function createDeck(ev) {
    ev.preventDefault();
    try {
      const d = await api("/api/decks", { method: "POST", body: JSON.stringify({ name: newDeck }) });
      newDeck = "";
      await loadDecks();
      await openDeck(d);
    } catch (e) { error = e.message; }
  }

  async function addCard(ev) {
    ev.preventDefault();
    try {
      await api(`/api/decks/${current.id}/cards`, { method: "POST", body: JSON.stringify({ front, back }) });
      front = ""; back = "";
      await openDeck(current);
      await loadDecks();
    } catch (e) { error = e.message; }
  }

  async function removeCard(id) {
    await api(`/api/cards/${id}`, { method: "DELETE" });
    await openDeck(current);
    await loadDecks();
  }

  $effect(() => {
    loadDecks();
    api("/api/health")
      .then((h) => (health = `API ${h.status} · rss ${h.memory_mb.rss} MB · heap ${h.memory_mb.heap_used} MB`))
      .catch((e) => (health = `API unreachable: ${e.message}`));
  });
</script>

<main>
  <h1>🧠 Flashcards</h1>
  <p class="muted">Svelte 5 → Caddy → Hono (TS) → Supabase · Project 05</p>
  {#if error}<p class="error">{error}</p>{/if}

  <div class="layout">
    <aside>
      <h2>Decks</h2>
      <ul>
        {#each decks as d (d.id)}
          <li>
            <button class:active={current?.id === d.id} onclick={() => openDeck(d)}>
              {d.name}<small>{d.due} due · {d.total} cards</small>
            </button>
          </li>
        {/each}
      </ul>
      <form onsubmit={createDeck}>
        <input bind:value={newDeck} placeholder="New deck" required maxlength="80" />
        <button>Create</button>
      </form>
    </aside>

    <section>
      {#if !current}
        <p class="muted">Pick a deck to start reviewing.</p>
      {:else}
        <h2>{current.name}</h2>
        {#if card}
          <div class="card" role="button" tabindex="0" onclick={() => (flipped = !flipped)} onkeydown={(e) => e.key === " " && (flipped = !flipped)}>
            <p class="face">{flipped ? card.back : card.front}</p>
            <small class="muted">{flipped ? "answer" : "question — click to flip"}</small>
          </div>
          {#if flipped}
            <div class="grades">
              <button class="g0" onclick={() => grade(1)}>Again</button>
              <button class="g3" onclick={() => grade(3)}>Hard</button>
              <button class="g4" onclick={() => grade(4)}>Good</button>
              <button class="g5" onclick={() => grade(5)}>Easy</button>
            </div>
          {/if}
          <p class="muted">{queue.length} left in this session</p>
        {:else}
          <p class="done">🎉 Nothing due. Come back later.</p>
        {/if}

        <h3>Add card</h3>
        <form class="add" onsubmit={addCard}>
          <textarea bind:value={front} placeholder="Front (question)" required></textarea>
          <textarea bind:value={back} placeholder="Back (answer)" required></textarea>
          <button>Add card</button>
        </form>

        <h3>All cards ({cards.length})</h3>
        <ul class="all">
          {#each cards as c (c.id)}
            <li><span>{c.front}</span><small>ease {c.ease} · every {c.interval_days}d</small>
              <button class="x" onclick={() => removeCard(c.id)}>✕</button></li>
          {/each}
        </ul>
      {/if}
    </section>
  </div>
  <footer class="muted">{health}</footer>
</main>
