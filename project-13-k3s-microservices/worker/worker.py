"""Project 13 — Python worker. Pulls queued jobs from Postgres and processes them.

Many replicas can run at once: `FOR UPDATE SKIP LOCKED` hands each job to exactly one
worker without a message broker. SIGTERM finishes the current job, then exits.
"""
import hashlib
import json
import logging
import os
import re
import signal
import socket
import sys
import time
from collections import Counter
from pathlib import Path

import psycopg

DATABASE_URL = os.environ["DATABASE_URL"]
POD = os.environ.get("POD_NAME", socket.gethostname())
WORK_DELAY_MS = int(os.environ.get("WORK_DELAY_MS", "1500"))
POLL_INTERVAL_S = float(os.environ.get("POLL_INTERVAL_S", "1"))
HEARTBEAT = Path(os.environ.get("HEARTBEAT_FILE", "/tmp/heartbeat"))
STALE_AFTER_S = 120

logging.basicConfig(stream=sys.stdout, level=os.environ.get("LOG_LEVEL", "INFO"),
                    format='{"ts":"%(asctime)s","level":"%(levelname)s","pod":"' + POD + '","msg":"%(message)s"}')
log = logging.getLogger("worker")

running = True


def stop(signum, _frame):
    global running
    log.info("signal %s received: finishing current job then exiting", signum)
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)


def analyse(text: str) -> dict:
    words = re.findall(r"[A-Za-z0-9']+", text.lower())
    return {
        "chars": len(text),
        "words": len(words),
        "lines": text.count("\n") + 1,
        "sha256": hashlib.sha256(text.encode()).hexdigest(),
        "top_words": Counter(w for w in words if len(w) > 3).most_common(5),
    }


def requeue_stale(conn) -> None:
    """Jobs left 'running' by a worker that was SIGKILLed/OOM-killed go back to the queue."""
    with conn.transaction():
        cur = conn.execute(
            "UPDATE jobs SET status = 'queued' WHERE status = 'running' "
            "AND started_at < now() - make_interval(secs => %s) RETURNING id", (STALE_AFTER_S,))
        ids = [r[0] for r in cur.fetchall()]
    if ids:
        log.warning("requeued stale jobs %s", ids)


def claim(conn):
    with conn.transaction():
        row = conn.execute(
            "SELECT id, input FROM jobs WHERE status = 'queued' ORDER BY id "
            "FOR UPDATE SKIP LOCKED LIMIT 1").fetchone()
        if row is None:
            return None
        conn.execute("UPDATE jobs SET status = 'running', started_at = now(), attempts = attempts + 1, "
                     "processed_by = %s WHERE id = %s", (POD, row[0]))
        return row


def main() -> int:
    log.info("worker starting (delay=%sms)", WORK_DELAY_MS)
    last_requeue = 0.0
    while running:
        try:
            with psycopg.connect(DATABASE_URL, autocommit=True, connect_timeout=5) as conn:
                while running:
                    HEARTBEAT.touch()
                    if time.time() - last_requeue > 30:
                        requeue_stale(conn)
                        last_requeue = time.time()
                    job = claim(conn)
                    if job is None:
                        time.sleep(POLL_INTERVAL_S)
                        continue
                    job_id, text = job
                    try:
                        time.sleep(WORK_DELAY_MS / 1000)   # pretend this is expensive
                        result = analyse(text)
                        conn.execute("UPDATE jobs SET status = 'done', result = %s, finished_at = now(), error = NULL "
                                     "WHERE id = %s", (json.dumps(result), job_id))
                        log.info("job %s done (%s words)", job_id, result["words"])
                    except Exception as exc:  # noqa: BLE001
                        conn.execute("UPDATE jobs SET status = 'failed', error = %s, finished_at = now() WHERE id = %s",
                                     (str(exc)[:500], job_id))
                        log.error("job %s failed: %s", job_id, exc)
        except psycopg.OperationalError as exc:
            log.error("database unavailable: %s — retrying in 3s", str(exc).strip().replace('"', "'"))
            time.sleep(3)
    log.info("bye")
    return 0


if __name__ == "__main__":
    sys.exit(main())
