#!/usr/bin/env python3
"""
Generates a one-line commit message summary from the built SQLite database.
Used by GitHub Actions after a DB rebuild.
"""
from pathlib import Path
import sqlite3

repo_root = Path(__file__).resolve().parent.parent
db_path = repo_root / "Nomva" / "Resources" / "foods.sqlite"

conn = sqlite3.connect(db_path)
total = conn.execute("SELECT value FROM metadata WHERE key='total_foods'").fetchone()
build_date = conn.execute("SELECT value FROM metadata WHERE key='build_date'").fetchone()
conn.close()

print(f"{int(total[0]):,} foods as of {build_date[0]}")
