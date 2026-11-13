"""Project 04 — Expense splitter API (FastAPI + Neon Postgres).

Money is stored as integer cents to avoid floating point rounding errors.
"""
import os
import time
from contextlib import asynccontextmanager
from decimal import ROUND_HALF_UP, Decimal
from typing import List

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from pydantic import BaseModel, Field, field_validator

DATABASE_URL = os.environ.get("DATABASE_URL", "")
STARTED = time.time()

pool = ConnectionPool(
    conninfo=DATABASE_URL,
    min_size=int(os.environ.get("DB_POOL_MIN", "1")),
    max_size=int(os.environ.get("DB_POOL_MAX", "4")),
    kwargs={"row_factory": dict_row, "connect_timeout": 10},
    # Neon suspends idle computes and drops connections: validate before handing one out.
    check=ConnectionPool.check_connection,
    open=False,
)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    if not DATABASE_URL:
        raise RuntimeError("DATABASE_URL is not set")
    pool.open(wait=False)
    yield
    pool.close()


app = FastAPI(title="Expense Splitter", version="1.0.0", lifespan=lifespan,
              docs_url="/api/docs", openapi_url="/api/openapi.json")


# ---------- models ----------
class GroupIn(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    currency: str = Field(default="INR", min_length=3, max_length=3)
    members: List[str] = Field(default_factory=list)


class MemberIn(BaseModel):
    name: str = Field(min_length=1, max_length=60)


class ExpenseIn(BaseModel):
    description: str = Field(min_length=1, max_length=120)
    amount: Decimal = Field(gt=0, max_digits=12, decimal_places=2)
    paid_by: int
    split_among: List[int] = Field(min_length=1)

    @field_validator("split_among")
    @classmethod
    def unique_members(cls, v):
        if len(set(v)) != len(v):
            raise ValueError("split_among contains duplicates")
        return v


# ---------- helpers ----------
def to_cents(amount: Decimal) -> int:
    return int((amount * 100).quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def split_equally(total: int, n: int) -> List[int]:
    """Distribute leftover cents to the first members so shares sum exactly to total."""
    base, rem = divmod(total, n)
    return [base + (1 if i < rem else 0) for i in range(n)]


def settle(balances: dict) -> list:
    """Greedy minimum-transfer settlement. balances: member_id -> cents (+ owed to them)."""
    creditors = sorted([[m, b] for m, b in balances.items() if b > 0], key=lambda x: -x[1])
    debtors = sorted([[m, -b] for m, b in balances.items() if b < 0], key=lambda x: -x[1])
    transfers, i, j = [], 0, 0
    while i < len(debtors) and j < len(creditors):
        amt = min(debtors[i][1], creditors[j][1])
        transfers.append({"from": debtors[i][0], "to": creditors[j][0], "amount_cents": amt})
        debtors[i][1] -= amt
        creditors[j][1] -= amt
        if debtors[i][1] == 0:
            i += 1
        if creditors[j][1] == 0:
            j += 1
    return transfers


def group_or_404(cur, group_id: int) -> dict:
    cur.execute("SELECT id, name, currency, created_at FROM groups WHERE id = %s", (group_id,))
    g = cur.fetchone()
    if not g:
        raise HTTPException(404, "group not found")
    return g


# ---------- routes ----------
@app.get("/api/health")
def health():
    try:
        with pool.connection(timeout=5) as conn:
            conn.execute("SELECT 1")
        stats = pool.get_stats()
        return {"status": "ok", "database": "neon-postgres", "db_ok": True,
                "pid": os.getpid(), "uptime_s": round(time.time() - STARTED),
                "pool": {"size": stats.get("pool_size"), "available": stats.get("pool_available")}}
    except Exception as exc:  # noqa: BLE001
        return JSONResponse(status_code=503, content={"status": "degraded", "db_ok": False, "error": str(exc)})


@app.get("/api/groups")
def list_groups():
    with pool.connection() as conn:
        return conn.execute(
            "SELECT g.id, g.name, g.currency, g.created_at, "
            " (SELECT count(*) FROM members m WHERE m.group_id = g.id) AS member_count, "
            " COALESCE((SELECT sum(amount_cents) FROM expenses e WHERE e.group_id = g.id), 0) AS total_cents "
            "FROM groups g ORDER BY g.id DESC"
        ).fetchall()


@app.post("/api/groups", status_code=201)
def create_group(body: GroupIn):
    names = [n.strip() for n in body.members if n.strip()]
    with pool.connection() as conn, conn.transaction():
        g = conn.execute(
            "INSERT INTO groups(name, currency) VALUES (%s, %s) RETURNING id, name, currency, created_at",
            (body.name.strip(), body.currency.upper()),
        ).fetchone()
        for n in dict.fromkeys(names):
            conn.execute("INSERT INTO members(group_id, name) VALUES (%s, %s)", (g["id"], n))
    return g


@app.delete("/api/groups/{group_id}", status_code=204)
def delete_group(group_id: int):
    with pool.connection() as conn:
        cur = conn.execute("DELETE FROM groups WHERE id = %s", (group_id,))
        if cur.rowcount == 0:
            raise HTTPException(404, "group not found")


@app.post("/api/groups/{group_id}/members", status_code=201)
def add_member(group_id: int, body: MemberIn):
    with pool.connection() as conn:
        cur = conn.cursor()
        group_or_404(cur, group_id)
        try:
            return cur.execute(
                "INSERT INTO members(group_id, name) VALUES (%s, %s) RETURNING id, name",
                (group_id, body.name.strip()),
            ).fetchone()
        except Exception as exc:  # unique violation
            raise HTTPException(409, f"member exists: {exc.__class__.__name__}") from exc


@app.post("/api/groups/{group_id}/expenses", status_code=201)
def add_expense(group_id: int, body: ExpenseIn):
    total = to_cents(body.amount)
    with pool.connection() as conn, conn.transaction():
        cur = conn.cursor()
        group_or_404(cur, group_id)
        ids = {r["id"] for r in cur.execute("SELECT id FROM members WHERE group_id = %s", (group_id,))}
        if body.paid_by not in ids or not set(body.split_among) <= ids:
            raise HTTPException(400, "paid_by and split_among must be members of this group")
        exp = cur.execute(
            "INSERT INTO expenses(group_id, paid_by, description, amount_cents) "
            "VALUES (%s, %s, %s, %s) RETURNING id, description, amount_cents, paid_by, created_at",
            (group_id, body.paid_by, body.description.strip(), total),
        ).fetchone()
        for member_id, share in zip(sorted(body.split_among), split_equally(total, len(body.split_among))):
            cur.execute(
                "INSERT INTO expense_shares(expense_id, member_id, share_cents) VALUES (%s, %s, %s)",
                (exp["id"], member_id, share),
            )
    return exp


@app.delete("/api/groups/{group_id}/expenses/{expense_id}", status_code=204)
def delete_expense(group_id: int, expense_id: int):
    with pool.connection() as conn:
        cur = conn.execute("DELETE FROM expenses WHERE id = %s AND group_id = %s", (expense_id, group_id))
        if cur.rowcount == 0:
            raise HTTPException(404, "expense not found")


@app.get("/api/groups/{group_id}")
def group_detail(group_id: int):
    with pool.connection() as conn:
        cur = conn.cursor()
        g = group_or_404(cur, group_id)
        members = cur.execute(
            "SELECT id, name FROM members WHERE group_id = %s ORDER BY id", (group_id,)
        ).fetchall()
        expenses = cur.execute(
            "SELECT e.id, e.description, e.amount_cents, e.paid_by, m.name AS paid_by_name, e.created_at "
            "FROM expenses e JOIN members m ON m.id = e.paid_by WHERE e.group_id = %s ORDER BY e.id DESC",
            (group_id,),
        ).fetchall()
        rows = cur.execute(
            "SELECT m.id, "
            " COALESCE((SELECT sum(amount_cents) FROM expenses WHERE paid_by = m.id), 0) "
            " - COALESCE((SELECT sum(share_cents) FROM expense_shares WHERE member_id = m.id), 0) AS balance "
            "FROM members m WHERE m.group_id = %s",
            (group_id,),
        ).fetchall()
    balances = {r["id"]: int(r["balance"]) for r in rows}
    names = {m["id"]: m["name"] for m in members}
    transfers = [
        {**t, "from_name": names[t["from"]], "to_name": names[t["to"]]} for t in settle(balances)
    ]
    return {
        **g,
        "members": [{**m, "balance_cents": balances.get(m["id"], 0)} for m in members],
        "expenses": expenses,
        "settle_up": transfers,
    }
