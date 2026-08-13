import os
import time
from flask import Flask, render_template, request, redirect, url_for
import psycopg2
from psycopg2 import OperationalError

app = Flask(__name__)

TEAM_NAME = os.environ.get("TEAM_NAME", "unknown")
TEAM_COLOR = os.environ.get("TEAM_COLOR", "#4f46e5")

DB_HOST = os.environ.get("POSTGRES_HOST", "postgres")
DB_PORT = "5432"
DB_NAME = os.environ.get("POSTGRES_DB", "appdb")
DB_USER = os.environ.get("POSTGRES_USER", "appuser")
DB_PASSWORD = os.environ.get("POSTGRES_PASSWORD", "")


def get_connection():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=DB_USER, password=DB_PASSWORD
    )


def init_db(retries=10, delay=3):
    """Retry loop: al primo avvio Postgres potrebbe non essere ancora pronto
    ad accettare connessioni, anche se il pod risulta Running."""
    for attempt in range(retries):
        try:
            conn = get_connection()
            cur = conn.cursor()
            cur.execute("""
                CREATE TABLE IF NOT EXISTS tasks (
                    id SERIAL PRIMARY KEY,
                    content TEXT NOT NULL,
                    created_at TIMESTAMP DEFAULT NOW()
                )
            """)
            conn.commit()
            cur.close()
            conn.close()
            return
        except OperationalError as e:
            print(f"[init_db] Attempt {attempt+1}/{retries} failed: {e}", flush=True)
            time.sleep(delay)
    raise RuntimeError("Could not connect to database after retries")

init_db()


@app.route("/")
def index():
    conn = get_connection()
    cur = conn.cursor()
    cur.execute("SELECT id, content, created_at FROM tasks ORDER BY created_at DESC")
    tasks = cur.fetchall()
    cur.close()
    conn.close()
    return render_template("index.html", team_name=TEAM_NAME, team_color=TEAM_COLOR, tasks=tasks)


@app.route("/add", methods=["POST"])
def add_task():
    content = request.form.get("content", "").strip()
    if content:
        conn = get_connection()
        cur = conn.cursor()
        cur.execute("INSERT INTO tasks (content) VALUES (%s)", (content,))
        conn.commit()
        cur.close()
        conn.close()
    return redirect(url_for("index"))


@app.route("/delete/<int:task_id>", methods=["POST"])
def delete_task(task_id):
    conn = get_connection()
    cur = conn.cursor()
    cur.execute("DELETE FROM tasks WHERE id = %s", (task_id,))
    conn.commit()
    cur.close()
    conn.close()
    return redirect(url_for("index"))


@app.route("/healthz")
def healthz():
    """Endpoint per readiness/liveness probe Kubernetes (Fase 6)."""
    return {"status": "ok"}, 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)