#!/usr/bin/env python3
"""Check a freshly built foods.sqlite before it is published.

Fails (exit 1) when the catalog is corrupt, is missing a column the iOS app,
Android app, or server reads, has implausibly few rows for a source, lost more
than 10% of a source compared with the previously pinned catalog, gave a
food's row id to a different food (the apps store row ids on logged foods), or
changed the default serving of many USDA reference foods.

    python3 scripts/validate_food_db.py NEW.sqlite [--previous OLD.sqlite] [--summary FILE]

--summary appends a Markdown report (used for the workflow summary and the PR).
"""

import argparse
from contextlib import closing
from pathlib import Path
import sqlite3
import sys

from build_db import max_food_id
from usda_reference_data import INSERT_COLUMNS

# Every column the iOS app, Android app, and server select.
REQUIRED_COLUMNS = ("id",) + INSERT_COLUMNS
MINIMUM_ROWS = {
    "sr_legacy": 7_000,
    "foundation": 90,
    "survey_fndds": 5_000,
    "branded": 300_000,
    "open_food_facts": 150_000,
}
MINIMUM_TOTAL = 600_000
MINIMUM_BARCODED = 500_000
MAX_SOURCE_DROP = 0.10
# A rebuild keeps reference foods' servings; many changes mean that broke.
MAX_SERVING_CHANGES = 0.05
SEARCH_PROBES = ("banana", "broccoli", "chicken breast", "oatmeal", "greek yogurt", "peanut butter")


def readonly(path):
    return closing(sqlite3.connect(Path(path).resolve().as_uri() + "?mode=ro", uri=True))


def source_counts(connection):
    return dict(connection.execute("SELECT source, COUNT(*) FROM foods GROUP BY source"))


def inspect(path):
    problems = []
    with readonly(path) as connection:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            problems.append(f"integrity_check: {integrity}")

        columns = {row[1] for row in connection.execute("PRAGMA table_info(foods)")}
        missing = [column for column in REQUIRED_COLUMNS if column not in columns]
        if missing:
            problems.append(f"foods is missing columns: {', '.join(missing)}")
            return {}, problems

        counts = source_counts(connection)
        total = sum(counts.values())
        for source, minimum in MINIMUM_ROWS.items():
            if counts.get(source, 0) < minimum:
                problems.append(f"{source} has {counts.get(source, 0):,} rows (expected at least {minimum:,})")
        if total < MINIMUM_TOTAL:
            problems.append(f"only {total:,} foods (expected at least {MINIMUM_TOTAL:,})")

        barcoded = connection.execute("SELECT COUNT(*) FROM foods WHERE barcode IS NOT NULL").fetchone()[0]
        if barcoded < MINIMUM_BARCODED:
            problems.append(f"only {barcoded:,} foods have barcodes (expected at least {MINIMUM_BARCODED:,})")

        for label, sql in (
            ("foods without a name", "SELECT COUNT(*) FROM foods WHERE name IS NULL OR trim(name) = ''"),
            ("foods without calories", "SELECT COUNT(*) FROM foods WHERE calories IS NULL"),
            ("foods with negative calories", "SELECT COUNT(*) FROM foods WHERE calories < 0"),
        ):
            bad = connection.execute(sql).fetchone()[0]
            if bad:
                problems.append(f"{bad:,} {label}")

        metadata = dict(connection.execute("SELECT key, value FROM metadata"))
        if metadata.get("total_foods") != str(total):
            problems.append(f"metadata.total_foods is {metadata.get('total_foods')!r}, table has {total:,}")
        if not metadata.get("build_date"):
            problems.append("metadata.build_date is missing")

        for probe in SEARCH_PROBES:
            try:
                hits = connection.execute(
                    "SELECT COUNT(*) FROM foods f JOIN foods_fts ON foods_fts.rowid = f.id "
                    "WHERE foods_fts MATCH ?", (probe,)
                ).fetchone()[0]
            except sqlite3.Error as error:
                problems.append(f"search for {probe!r} failed: {error}")
                break
            if not hits:
                problems.append(f"search for {probe!r} found nothing")
    return counts, problems


def compare(new_counts, old_counts):
    problems = []
    for source in sorted(set(old_counts) | set(new_counts)):
        old, new = old_counts.get(source, 0), new_counts.get(source, 0)
        if old and new < old * (1 - MAX_SOURCE_DROP):
            problems.append(f"{source} dropped from {old:,} to {new:,} rows")
    old_total, new_total = sum(old_counts.values()), sum(new_counts.values())
    if old_total and new_total < old_total * (1 - MAX_SOURCE_DROP):
        problems.append(f"total dropped from {old_total:,} to {new_total:,} foods")
    return problems


def compare_ids(path, previous_path):
    """Return (report line, problems) for row-id stability against the pinned catalog."""
    with readonly(previous_path) as previous:
        high_water = max_food_id(previous)
    with readonly(path) as connection:
        connection.execute("ATTACH DATABASE ? AS previous", (Path(previous_path).resolve().as_uri() + "?mode=ro",))
        kept, moved = connection.execute("""
            SELECT COUNT(*), COALESCE(SUM(CASE
                WHEN p.fdc_id IS NOT NULL THEN f.fdc_id IS NOT p.fdc_id
                ELSE f.source != 'open_food_facts' OR f.barcode IS NOT p.barcode
            END), 0)
            FROM foods f JOIN previous.foods p ON p.id = f.id
        """).fetchone()
        previous_total = connection.execute("SELECT COUNT(*) FROM previous.foods").fetchone()[0]
        reused = connection.execute(
            "SELECT COUNT(*) FROM foods WHERE id <= ? AND id NOT IN (SELECT id FROM previous.foods)",
            (high_water,),
        ).fetchone()[0]
    problems = []
    if moved:
        problems.append(f"row ids now naming a different food than in the pinned catalog: {moved:,}")
    if reused:
        problems.append(f"new foods reusing retired row ids (at or below {high_water:,}): {reused:,}")
    share = kept / previous_total if previous_total else 0
    report = f"Row ids: {kept - moved:,} of {previous_total:,} pinned foods keep their id ({share:.1%})."
    return report, problems


def compare_servings(path, previous_path):
    """Return (report line, problems): kept USDA reference foods should keep their serving."""
    with readonly(path) as connection:
        connection.execute("ATTACH DATABASE ? AS previous", (Path(previous_path).resolve().as_uri() + "?mode=ro",))
        kept, changed = connection.execute("""
            SELECT COUNT(*), COALESCE(SUM(f.serving_g IS NOT p.serving_g), 0)
            FROM foods f JOIN previous.foods p ON p.id = f.id AND p.fdc_id = f.fdc_id
            WHERE p.source IN ('sr_legacy', 'foundation', 'survey_fndds')
        """).fetchone()
    problems = []
    if changed > kept * MAX_SERVING_CHANGES:
        problems.append(f"USDA reference foods whose default serving changed: {changed:,} of {kept:,}")
    return f"Default servings: {changed:,} of {kept:,} kept USDA reference foods changed grams.", problems


def markdown(new_counts, old_counts, problems, notes=()):
    lines = ["| Source | Pinned catalog | New build | Change |", "| --- | ---: | ---: | ---: |"]
    rows = sorted(set(new_counts) | set(old_counts))
    for source in rows + ["total"]:
        if source == "total":
            old, new = sum(old_counts.values()), sum(new_counts.values())
        else:
            old, new = old_counts.get(source, 0), new_counts.get(source, 0)
        change = f"{new - old:+,}" if old_counts else ""
        old_text = f"{old:,}" if old_counts else "—"
        label = f"**{source}**" if source == "total" else source
        lines.append(f"| {label} | {old_text} | {new:,} | {change} |")
    lines.append("")
    lines.extend(f"{note}\n" for note in notes)
    if problems:
        lines.append("**Validation failed:**")
        lines.extend(f"- {problem}" for problem in problems)
    else:
        lines.append("Validation passed: integrity, schema, row counts, row ids, and search probes.")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("database")
    parser.add_argument("--previous", help="Currently pinned catalog to compare row counts against")
    parser.add_argument("--summary", help="Append a Markdown report to this file")
    args = parser.parse_args()

    new_counts, problems = inspect(args.database)
    old_counts, notes = {}, []
    if args.previous:
        with readonly(args.previous) as connection:
            old_counts = source_counts(connection)
        problems += compare(new_counts, old_counts)
        for check in (compare_ids, compare_servings):
            note, check_problems = check(args.database, args.previous)
            notes.append(note)
            problems += check_problems

    report = markdown(new_counts, old_counts, problems, notes)
    print(report)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as stream:
            stream.write(report)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
