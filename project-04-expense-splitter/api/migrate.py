"""Tiny migration runner: applies migrations/*.sql in order, once each.

Usage: DATABASE_URL=... python migrate.py
"""
import os
import sys
from pathlib import Path

import psycopg

MIGRATIONS = Path(__file__).resolve().parent / "migrations"


def main() -> int:
    url = os.environ.get("DATABASE_URL")
    if not url:
        print("DATABASE_URL not set", file=sys.stderr)
        return 2
    with psycopg.connect(url, autocommit=False, connect_timeout=15) as conn:
        conn.execute(
            "CREATE TABLE IF NOT EXISTS schema_migrations ("
            " filename TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())"
        )
        conn.commit()
        applied = {r[0] for r in conn.execute("SELECT filename FROM schema_migrations")}
        for f in sorted(MIGRATIONS.glob("*.sql")):
            if f.name in applied:
                print(f"skip   {f.name}")
                continue
            print(f"apply  {f.name}")
            with conn.transaction():
                conn.execute(f.read_text())
                conn.execute("INSERT INTO schema_migrations(filename) VALUES (%s)", (f.name,))
    print("migrations complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
