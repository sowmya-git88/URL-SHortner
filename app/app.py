"""Project 01 - URL shortener (Flask + SQLite).

Runs behind Caddy. Gunicorn binds to 127.0.0.1:5001 so the app is never exposed
directly to the internet; Caddy terminates TLS and forwards /api/* and /s/*.
"""
import os
import re
import secrets
import sqlite3
import string
import time
from pathlib import Path
from urllib.parse import urlparse

from flask import Flask, abort, g, jsonify, redirect, request
from werkzeug.middleware.proxy_fix import ProxyFix

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = os.environ.get("DB_PATH", str(BASE_DIR / "urlshort.db"))
CODE_LENGTH = int(os.environ.get("CODE_LENGTH", "6"))
PUBLIC_BASE_URL = os.environ.get("PUBLIC_BASE_URL", "").rstrip("/")
ALPHABET = string.ascii_letters + string.digits
CODE_RE = re.compile(r"^[A-Za-z0-9_-]{3,32}$")
STARTED_AT = time.time()

app = Flask(__name__)
# Trust exactly ONE proxy hop (Caddy) for X-Forwarded-For / -Proto / -Host.
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)


def get_db() -> sqlite3.Connection:
    if "db" not in g:
        conn = sqlite3.connect(DB_PATH, timeout=5)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        g.db = conn
    return g.db


@app.teardown_appcontext
def close_db(_exc):
    conn = g.pop("db", None)
    if conn is not None:
        conn.close()


def init_db(seed: bool = False) -> None:
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(DB_PATH) as conn:
        conn.executescript((BASE_DIR / "schema.sql").read_text())
        if seed:
            samples = [
                ("gh", "https://github.com"),
                ("ubuntu", "https://ubuntu.com/server/docs"),
                ("fhs", "https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html"),
            ]
            conn.executemany(
                "INSERT OR IGNORE INTO links(code, target_url) VALUES (?, ?)", samples
            )
    print(f"database ready at {DB_PATH} (seed={seed})")


def valid_url(url: str) -> bool:
    parsed = urlparse(url)
    return parsed.scheme in ("http", "https") and bool(parsed.netloc) and len(url) <= 2048


def base_url() -> str:
    return PUBLIC_BASE_URL or request.host_url.rstrip("/")


def link_to_dict(row: sqlite3.Row) -> dict:
    return {
        "code": row["code"],
        "target_url": row["target_url"],
        "short_url": f"{base_url()}/s/{row['code']}",
        "clicks": row["clicks"],
        "created_at": row["created_at"],
        "last_click": row["last_click"],
    }


@app.get("/api/health")
def health():
    try:
        get_db().execute("SELECT 1").fetchone()
        db_ok = True
    except sqlite3.Error:
        db_ok = False
    status = 200 if db_ok else 503
    return jsonify(
        status="ok" if db_ok else "degraded",
        database="sqlite",
        db_ok=db_ok,
        uptime_seconds=round(time.time() - STARTED_AT, 1),
        pid=os.getpid(),
    ), status


@app.get("/api/links")
def list_links():
    rows = get_db().execute(
        "SELECT * FROM links ORDER BY id DESC LIMIT 50"
    ).fetchall()
    return jsonify([link_to_dict(r) for r in rows])


@app.post("/api/links")
def create_link():
    payload = request.get_json(silent=True) or {}
    url = str(payload.get("url", "")).strip()
    custom = str(payload.get("code", "")).strip()
    if not valid_url(url):
        return jsonify(error="url must be an absolute http(s) URL"), 400
    if custom and not CODE_RE.match(custom):
        return jsonify(error="code must be 3-32 chars: letters, digits, _ or -"), 400

    db = get_db()
    for _ in range(5):
        code = custom or "".join(secrets.choice(ALPHABET) for _ in range(CODE_LENGTH))
        try:
            db.execute("INSERT INTO links(code, target_url) VALUES (?, ?)", (code, url))
            db.commit()
            row = db.execute("SELECT * FROM links WHERE code = ?", (code,)).fetchone()
            return jsonify(link_to_dict(row)), 201
        except sqlite3.IntegrityError:
            if custom:
                return jsonify(error="code already taken"), 409
    return jsonify(error="could not allocate a unique code, retry"), 500


@app.get("/api/links/<code>")
def link_stats(code: str):
    db = get_db()
    row = db.execute("SELECT * FROM links WHERE code = ?", (code,)).fetchone()
    if row is None:
        return jsonify(error="not found"), 404
    recent = db.execute(
        "SELECT clicked_at, referrer, user_agent FROM click_log "
        "WHERE link_id = ? ORDER BY id DESC LIMIT 20",
        (row["id"],),
    ).fetchall()
    data = link_to_dict(row)
    data["recent_clicks"] = [dict(r) for r in recent]
    return jsonify(data)


@app.delete("/api/links/<code>")
def delete_link(code: str):
    db = get_db()
    cur = db.execute("DELETE FROM links WHERE code = ?", (code,))
    db.commit()
    if cur.rowcount == 0:
        return jsonify(error="not found"), 404
    return "", 204


@app.get("/s/<code>")
def follow(code: str):
    db = get_db()
    row = db.execute("SELECT id, target_url FROM links WHERE code = ?", (code,)).fetchone()
    if row is None:
        abort(404)
    db.execute(
        "UPDATE links SET clicks = clicks + 1, "
        "last_click = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?",
        (row["id"],),
    )
    db.execute(
        "INSERT INTO click_log(link_id, referrer, user_agent) VALUES (?, ?, ?)",
        (row["id"], request.referrer, (request.user_agent.string or "")[:300]),
    )
    db.commit()
    return redirect(row["target_url"], code=302)


@app.cli.command("init-db")
def init_db_command():
    """flask --app app init-db"""
    init_db(seed=False)


@app.cli.command("seed-db")
def seed_db_command():
    """flask --app app seed-db"""
    init_db(seed=True)


if __name__ == "__main__":
    init_db(seed=True)
    app.run(host="127.0.0.1", port=5001, debug=True)
