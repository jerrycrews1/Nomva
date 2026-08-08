#!/usr/bin/env python3
"""Atomically add current USDA Foundation and FNDDS foods to a Nomva DB."""

import argparse
import os
import shutil
import sqlite3
import tempfile

from usda_reference_data import ensure_search_schema, insert_reference_foods, rebuild_search_index


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="Existing foods.sqlite")
    parser.add_argument("--output", required=True, help="Augmented output foods.sqlite")
    parser.add_argument("--foundation", required=True, help="Foundation Foods JSON")
    parser.add_argument("--fndds", required=True, help="Survey/FNDDS JSON")
    parser.add_argument("--sr-legacy", help="Optional SR Legacy JSON to refresh in place")
    return parser.parse_args()


def main():
    args = parse_args()
    output_dir = os.path.dirname(os.path.abspath(args.output))
    os.makedirs(output_dir, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix="foods-", suffix=".sqlite", dir=output_dir)
    os.close(handle)

    try:
        shutil.copy2(args.input, temporary)
        connection = sqlite3.connect(temporary)
        connection.execute("PRAGMA journal_mode=DELETE")
        connection.execute("PRAGMA synchronous=FULL")
        connection.execute("BEGIN IMMEDIATE")
        ensure_search_schema(connection)
        sr_legacy = {"inserted": 0, "skipped": 0}
        if args.sr_legacy:
            sr_legacy = insert_reference_foods(
                connection,
                args.sr_legacy,
                "SRLegacyFoods",
                "sr_legacy",
                update_existing=True,
            )
        foundation = insert_reference_foods(
            connection, args.foundation, "FoundationFoods", "foundation"
        )
        fndds = insert_reference_foods(
            connection, args.fndds, "SurveyFoods", "survey_fndds"
        )
        rebuild_search_index(connection)
        for key, value in {
            "foundation_count": foundation["inserted"],
            "survey_fndds_count": fndds["inserted"],
            "sr_legacy_count": sr_legacy["inserted"],
            "reference_data_version": "foundation-2026-04-30;fndds-2021-2023",
        }.items():
            connection.execute(
                "INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)",
                (key, str(value)),
            )
        connection.commit()
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        source_counts = dict(connection.execute(
            "SELECT source, COUNT(*) FROM foods GROUP BY source"
        ).fetchall())
        connection.close()
        if integrity != "ok":
            raise RuntimeError(f"SQLite integrity check failed: {integrity}")
        os.replace(temporary, args.output)
        print({
            "sr_legacy": sr_legacy,
            "foundation": foundation,
            "fndds": fndds,
            "sources": source_counts,
        })
    except Exception:
        if os.path.exists(temporary):
            os.remove(temporary)
        raise


if __name__ == "__main__":
    main()
