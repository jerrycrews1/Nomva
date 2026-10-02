#!/usr/bin/env python3
"""
Nomva Food Database Builder (local)
===================================
Run this on your Mac to build the full foods.sqlite from scratch.

Gathers the sources into _build_data/ (reusing anything already there), then
calls build_db.build() -- the same builder the "Rebuild Food Database" GitHub
workflow runs, so local and CI builds can't drift apart.

Sources:
  - USDA FoodData Central: SR Legacy, Foundation, FNDDS, Branded Foods
    (the newest releases linked on the USDA download page)
  - Open Food Facts (filtered to US products with barcodes)

USDA is the source of truth; OFF fills in the gaps.

Usage:
    cd /path/to/Nomva
    python3 scripts/rebuild_full_db.py

Delete a dataset's folder under _build_data/ to fetch its newest release.

Output:
    Nomva/Resources/foods.sqlite

Requirements:
    Python 3.9+   (no pip packages needed — stdlib only)
"""

import os
import sys
import time
import urllib.error
import urllib.request
import zipfile

import build_db
from fdc_datasets import dataset_url, resolve_releases

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
DB_PATH = os.path.join(PROJECT_ROOT, "Nomva", "Resources", "foods.sqlite")
DATA_DIR = os.path.join(PROJECT_ROOT, "_build_data")

OFF_URL = "https://static.openfoodfacts.org/data/openfoodfacts-products.jsonl.gz"
OFF_CANDIDATES = [
    os.path.join(DATA_DIR, "openfoodfacts-products.jsonl.gz"),
    os.path.join(DATA_DIR, "openfoodfacts-products.jsonl"),
    os.path.join(PROJECT_ROOT, "open_food_facts", "openfoodfacts-products.jsonl.gz"),
    os.path.join(PROJECT_ROOT, "open_food_facts", "openfoodfacts-products.jsonl"),
    os.path.join(PROJECT_ROOT, "openfoodfacts-products.jsonl.gz"),
    os.path.join(PROJECT_ROOT, "openfoodfacts-products.jsonl"),
]

# (fdc_datasets key, label, folder used by older layouts of this project)
USDA_SOURCES = [
    ("sr_legacy", "USDA SR Legacy", os.path.join(PROJECT_ROOT, "sr_legacy")),
    ("foundation", "USDA Foundation", None),
    ("fndds", "USDA FNDDS", None),
    ("branded", "USDA Branded", os.path.join(PROJECT_ROOT, "branded")),
]


def download_file(url, dest_path, label):
    """Download a single URL with progress. Returns True on success."""
    print(f"  {label}: downloading {url}")
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Nomva-DB-Builder/1.0"})
        response = urllib.request.urlopen(req, timeout=120)
    except urllib.error.HTTPError as e:
        print(f"  {label}: {e.code} {e.reason}")
        return False
    except Exception as e:
        print(f"  {label}: failed — {e}")
        return False

    total = int(response.headers.get("Content-Length", 0))
    downloaded = 0
    start = time.time()
    tmp_path = dest_path + ".tmp"

    with open(tmp_path, "wb") as f:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            f.write(chunk)
            downloaded += len(chunk)
            elapsed = time.time() - start
            speed = downloaded / elapsed / (1024 * 1024) if elapsed > 0 else 0
            if total > 0:
                pct = downloaded / total * 100
                print(
                    f"\r  {label}: {downloaded / (1024*1024):.0f} / {total / (1024*1024):.0f} MB"
                    f" ({pct:.0f}%) — {speed:.1f} MB/s",
                    end="", flush=True,
                )
            else:
                print(
                    f"\r  {label}: {downloaded / (1024*1024):.0f} MB — {speed:.1f} MB/s",
                    end="", flush=True,
                )

    os.rename(tmp_path, dest_path)
    print(f"\n  {label}: done ({downloaded / (1024*1024):.0f} MB)")
    return True


def has_json(directory):
    return bool(directory) and os.path.isdir(directory) and any(
        name.endswith(".json") for name in os.listdir(directory)
    )


def resolve_usda_dir(key, label, legacy_dir, release):
    """Return a folder holding the dataset's JSON, downloading it if needed."""
    directory = os.path.join(DATA_DIR, key)
    for candidate in (directory, legacy_dir):
        if has_json(candidate):
            export = build_db.discover_single_json(candidate)
            print(f"  {label}: using {os.path.relpath(export, PROJECT_ROOT)} (newest USDA release: {release})")
            return candidate

    zip_path = os.path.join(DATA_DIR, f"{key}-{release}.zip")
    if not os.path.exists(zip_path) and not download_file(dataset_url(key, release), zip_path, label):
        print(f"  !! {label}: download failed. Get the JSON zip from https://fdc.nal.usda.gov/download-datasets/")
        print(f"  !! and save it as {zip_path}")
        sys.exit(1)
    os.makedirs(directory, exist_ok=True)
    print(f"  {label}: extracting...")
    with zipfile.ZipFile(zip_path, "r") as archive:
        archive.extractall(directory)
    return directory


def resolve_off_path():
    for candidate in OFF_CANDIDATES:
        if os.path.exists(candidate):
            size_gb = os.path.getsize(candidate) / (1024 ** 3)
            print(f"  Open Food Facts: using {os.path.relpath(candidate, PROJECT_ROOT)} ({size_gb:.1f} GB)")
            return candidate

    if not download_file(OFF_URL, OFF_CANDIDATES[0], "Open Food Facts"):
        print(f"  !! Open Food Facts: download failed. Save {OFF_URL}")
        print(f"  !! as {OFF_CANDIDATES[0]}")
        sys.exit(1)
    return OFF_CANDIDATES[0]


def main():
    print("=" * 60)
    print("  Nomva Food Database Builder")
    print("=" * 60)
    print()

    os.makedirs(DATA_DIR, exist_ok=True)
    print("STEP 1: Gathering data sources\n")
    releases, warnings = resolve_releases()
    for warning in warnings:
        print(f"  warning: {warning}")
    directories = {
        key: resolve_usda_dir(key, label, legacy_dir, releases[key])
        for key, label, legacy_dir in USDA_SOURCES
    }
    off_path = resolve_off_path()

    print("\nSTEP 2: Building database\n")
    build_db.build(
        db_path=DB_PATH,
        sr_legacy_dir=directories["sr_legacy"],
        foundation_dir=directories["foundation"],
        fndds_dir=directories["fndds"],
        branded_dir=directories["branded"],
        off_path=off_path,
        # The catalog being replaced keeps its row ids (the apps store them).
        previous_db=DB_PATH if os.path.exists(DB_PATH) else None,
    )
    print()
    print("Next: open Nomva.xcodeproj in Xcode and build. The new")
    print("foods.sqlite is already in Nomva/Resources/.")


if __name__ == "__main__":
    main()
