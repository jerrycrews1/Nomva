#!/usr/bin/env python3
"""
Nomva Food Database Builder
============================
Run this on your Mac to build the full foods.sqlite from scratch.

Downloads:
  - USDA FoodData Central (SR Legacy + Branded Foods)
  - Open Food Facts (filtered to US products with barcodes)

Then merges them into a single SQLite database where USDA is the source of
truth and OFF fills in the gaps.

Usage:
    cd /path/to/Nomva
    python3 scripts/rebuild_full_db.py

Output:
    Nomva/Resources/foods.sqlite

Requirements:
    Python 3.9+   (no pip packages needed — stdlib only)
"""

import gzip
import io
import json
import math
import os
import re
import shutil
import sqlite3
import sys
import time
import urllib.request
import zipfile

# ── Paths ──────────────────────────────────────────────────────────────────────

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
DB_PATH = os.path.join(PROJECT_ROOT, "Nomva", "Resources", "foods.sqlite")
DATA_DIR = os.path.join(PROJECT_ROOT, "_build_data")

# ── Download URLs ──────────────────────────────────────────────────────────────
# USDA changes their URLs every release. We try multiple patterns.

USDA_SR_LEGACY_URLS = [
    "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_sr_legacy_food_json_2018-04.zip",
    "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_sr_legacy_food_json_2024-10-31.zip",
    "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_sr_legacy_food_json_current.zip",
]
USDA_BRANDED_URLS = [
    "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_branded_food_json_2025-12-18.zip",
    "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_branded_food_json_2024-10-31.zip",
    "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_branded_food_json_current.zip",
]
OFF_URL = (
    "https://static.openfoodfacts.org/data/openfoodfacts-products.jsonl.gz"
)

# ── Constants ──────────────────────────────────────────────────────────────────

OFF_ACCEPTED_COUNTRIES = {
    "en:united-states",
    "en:us",
    "en:united-states-of-america",
}

WEAK_SERVING_DESCRIPTIONS = {
    "g", "gram", "grams", "gr", "ml", "serving", "100g", "100ml", "oz", "fl oz"
}

MICRONUTRIENT_COLUMNS = (
    "saturated_fat_g",
    "trans_fat_g",
    "cholesterol_mg",
    "added_sugar_g",
    "vitamin_d_mcg",
    "calcium_mg",
    "iron_mg",
    "potassium_mg",
    "vitamin_a_mcg_rae",
    "vitamin_c_mg",
    "vitamin_b12_mcg",
    "folate_mcg_dfe",
    "magnesium_mg",
    "zinc_mg",
)


# ═══════════════════════════════════════════════════════════════════════════════
#  UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

def safe_float(value):
    if value in (None, ""):
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        n = float(value)
        return n if math.isfinite(n) else None
    text = str(value).strip().replace(",", ".")
    if not text:
        return None
    try:
        n = float(text)
    except ValueError:
        return None
    return n if math.isfinite(n) else None


def normalize_whitespace(value):
    if value is None:
        return None
    text = re.sub(r"\s+", " ", str(value)).strip()
    return text or None


def prettify_label(value):
    text = normalize_whitespace(value)
    if not text:
        return None
    if text.isupper() or text.islower():
        return text.title()
    return text


def normalize_lookup_key(value):
    text = normalize_whitespace(value)
    if not text:
        return None
    text = re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()
    text = re.sub(r"\s+", " ", text)
    return text or None


def normalize_compact_key(value):
    key = normalize_lookup_key(value)
    return key.replace(" ", "") if key else None


def normalize_barcode(value):
    if value in (None, ""):
        return None
    digits = "".join(ch for ch in str(value) if ch.isdigit())
    if not digits:
        return None
    stripped = digits.lstrip("0")
    return stripped or "0"


def is_missing_text(value):
    return normalize_whitespace(value) is None


def is_weak_serving_desc(value):
    token = normalize_compact_key(value)
    return token in {item.replace(" ", "") for item in WEAK_SERVING_DESCRIPTIONS}


def should_replace_serving_desc(existing, incoming):
    if is_missing_text(incoming):
        return False
    if is_missing_text(existing):
        return True
    return is_weak_serving_desc(existing) and not is_weak_serving_desc(incoming)


def serving_bucket(serving_g):
    grams = safe_float(serving_g)
    if grams is None or grams <= 0:
        return None
    return int(round(grams))


def format_serving_description(serving_g):
    grams = safe_float(serving_g)
    if grams is None or grams <= 0:
        return None
    if abs(grams - round(grams)) < 0.01:
        return f"{int(round(grams))} g"
    return f"{grams:.1f} g"


USDA_PORTION_TEXT_WEIGHTS = [
    ("cup", 9),
    ("large", 9),
    ("medium", 8),
    ("small", 8),
    ("extra large", 8),
    ("jumbo", 8),
    ("tablespoon", 7),
    ("tbsp", 7),
    ("teaspoon", 6),
    ("tsp", 6),
    ("slice", 7),
    ("piece", 7),
    ("leaf", 5),
    ("clove", 6),
    ("stalk", 6),
    ("spear", 6),
    ("spears", 6),
    ("wedge", 6),
    ("fillet", 6),
    ("patty", 6),
]
USDA_PORTION_AVOID_WORDS = {
    "bunch", "package", "packages", "pkg", "bag", "box", "carton",
    "container", "loaf", "bottle", "can", "jar", "tray",
}


def build_usda_portion_description(portion):
    portion_desc = normalize_whitespace(portion.get("portionDescription"))
    modifier = normalize_whitespace(portion.get("modifier"))
    measure_name = normalize_whitespace((portion.get("measureUnit") or {}).get("name"))
    raw = portion_desc or modifier or measure_name
    if not raw:
        return None
    raw = re.sub(r"^[\s,;:()]+|[\s,;:()]+$", "", raw)
    if not raw:
        return None
    if re.match(r"^\d", raw):
        return raw
    return f"1 {raw.lower()}"


def choose_usda_serving(portions):
    best = None
    best_score = None

    for portion in portions or []:
        grams = safe_float(portion.get("gramWeight"))
        if grams is None or grams <= 0:
            continue

        desc = build_usda_portion_description(portion)
        if not desc:
            continue

        key = normalize_lookup_key(desc) or ""
        score = 0

        if 20 <= grams <= 120:
            score += 8
        elif 5 <= grams <= 180:
            score += 5
        elif grams <= 300:
            score += 2
        else:
            score -= 2

        if "(" in desc or ")" in desc:
            score -= 4

        matched_weights = [
            weight for token, weight in USDA_PORTION_TEXT_WEIGHTS
            if re.search(rf"\b{re.escape(token)}\b", key)
        ]
        if matched_weights:
            score += max(matched_weights)

        for token in USDA_PORTION_AVOID_WORDS:
            if token in key:
                score -= 10

        if best is None or score > best_score or (score == best_score and grams < best[0]):
            best = (grams, desc)
            best_score = score

    if best is not None and best_score is not None and best_score >= 8:
        return best[0], best[1], "explicit_serving"

    return 100.0, "100g", "fallback_raw"


def nutrient_value(nutrients, nutrient_id):
    for nutrient in nutrients:
        if nutrient.get("nutrient", {}).get("id") == nutrient_id:
            return safe_float(nutrient.get("amount"))
    return None


def per_serving(amount_per_100g, serving_g):
    amount = safe_float(amount_per_100g)
    if amount is None:
        return None
    grams = safe_float(serving_g)
    if grams is None or grams <= 0:
        return amount
    return amount * (grams / 100.0)


def label_nutrient_value(label_nutrients, key, fallback):
    payload = label_nutrients.get(key, {})
    value = safe_float(payload.get("value")) if isinstance(payload, dict) else None
    return value if value is not None else fallback


def convert_unit(value, source_unit, target_unit):
    amount = safe_float(value)
    if amount is None or not target_unit:
        return amount
    unit = (source_unit or target_unit or "").strip().lower()
    target = target_unit.lower()
    if target == "kcal":
        if unit in ("", "kcal"):
            return amount
        if unit == "kj":
            return amount / 4.184
        return amount
    if target == "g":
        if unit in ("", "g"):
            return amount
        if unit == "mg":
            return amount / 1000.0
        if unit in ("mcg", "µg", "ug"):
            return amount / 1_000_000.0
        if unit == "kg":
            return amount * 1000.0
        return amount
    if target == "mg":
        if unit in ("", "mg"):
            return amount
        if unit == "g":
            return amount * 1000.0
        if unit in ("mcg", "µg", "ug"):
            return amount / 1000.0
        if unit == "kg":
            return amount * 1_000_000.0
        return amount
    if target == "mcg":
        if unit in ("", "mcg", "µg", "ug"):
            return amount
        if unit == "mg":
            return amount * 1000.0
        if unit == "g":
            return amount * 1_000_000.0
        if unit == "kg":
            return amount * 1_000_000_000.0
        return amount
    return amount


def off_nutrient_per_serving(nutriments, keys, serving_g, target_unit):
    info = off_nutrient_value_info(nutriments, keys, serving_g, target_unit)
    return info["value"]


def off_nutrient_value_info(nutriments, keys, serving_g, target_unit):
    for key in keys:
        value = safe_float(nutriments.get(f"{key}_serving"))
        if value is not None:
            return {
                "value": convert_unit(value, nutriments.get(f"{key}_unit"), target_unit),
                "source": "serving",
            }
    for key in keys:
        value = safe_float(nutriments.get(f"{key}_100g"))
        if value is not None:
            grams = safe_float(serving_g)
            if grams and grams > 0:
                scaled = value * (grams / 100.0)
                return {
                    "value": convert_unit(scaled, nutriments.get(f"{key}_unit"), target_unit),
                    "source": "100g_scaled",
                }
            return {
                "value": convert_unit(value, nutriments.get(f"{key}_unit"), target_unit),
                "source": "100g_raw",
            }
    for key in keys:
        value = safe_float(nutriments.get(key))
        if value is not None:
            return {
                "value": convert_unit(value, nutriments.get(f"{key}_unit"), target_unit),
                "source": "raw",
            }
    return {"value": None, "source": None}


def normalize_off_source(source):
    if source is None:
        return None
    if source.startswith("100g"):
        return "100g"
    return source


def vitamin_d_mcg_from_usda(nutrients):
    """Prefer USDA's mcg Vitamin D field; fall back from IU when needed."""
    vitamin_d_mcg = nutrient_value(nutrients, 1114)
    if vitamin_d_mcg is not None:
        return vitamin_d_mcg

    vitamin_d_iu = nutrient_value(nutrients, 1110)
    if vitamin_d_iu is not None:
        return vitamin_d_iu / 40.0

    return None


def nutrient_tuple(values):
    return tuple(values.get(column) for column in MICRONUTRIENT_COLUMNS)


def usda_micronutrients(nutrients, serving_g, label_nutrients=None):
    label_nutrients = label_nutrients or {}
    return {
        "saturated_fat_g": label_nutrient_value(label_nutrients, "saturatedFat", per_serving(nutrient_value(nutrients, 1258), serving_g)),
        "trans_fat_g": label_nutrient_value(label_nutrients, "transFat", per_serving(nutrient_value(nutrients, 1257), serving_g)),
        "cholesterol_mg": label_nutrient_value(label_nutrients, "cholesterol", per_serving(nutrient_value(nutrients, 1253), serving_g)),
        "added_sugar_g": label_nutrient_value(label_nutrients, "addedSugar", per_serving(nutrient_value(nutrients, 1235), serving_g)),
        "vitamin_d_mcg": label_nutrient_value(label_nutrients, "vitaminD", per_serving(vitamin_d_mcg_from_usda(nutrients), serving_g)),
        "calcium_mg": label_nutrient_value(label_nutrients, "calcium", per_serving(nutrient_value(nutrients, 1087), serving_g)),
        "iron_mg": label_nutrient_value(label_nutrients, "iron", per_serving(nutrient_value(nutrients, 1089), serving_g)),
        "potassium_mg": label_nutrient_value(label_nutrients, "potassium", per_serving(nutrient_value(nutrients, 1092), serving_g)),
        "vitamin_a_mcg_rae": per_serving(nutrient_value(nutrients, 1106), serving_g),
        "vitamin_c_mg": label_nutrient_value(label_nutrients, "vitaminC", per_serving(nutrient_value(nutrients, 1162), serving_g)),
        "vitamin_b12_mcg": per_serving(nutrient_value(nutrients, 1178), serving_g),
        "folate_mcg_dfe": per_serving(nutrient_value(nutrients, 1190), serving_g),
        "magnesium_mg": per_serving(nutrient_value(nutrients, 1090), serving_g),
        "zinc_mg": per_serving(nutrient_value(nutrients, 1095), serving_g),
    }


def off_micronutrients(nutriments, serving_g):
    return {
        "saturated_fat_g": off_nutrient_per_serving(nutriments, ["saturated-fat"], serving_g, "g"),
        "trans_fat_g": off_nutrient_per_serving(nutriments, ["trans-fat"], serving_g, "g"),
        "cholesterol_mg": off_nutrient_per_serving(nutriments, ["cholesterol"], serving_g, "mg"),
        "added_sugar_g": off_nutrient_per_serving(nutriments, ["added-sugars", "added-sugar"], serving_g, "g"),
        "vitamin_d_mcg": off_nutrient_per_serving(nutriments, ["vitamin-d"], serving_g, "mcg"),
        "calcium_mg": off_nutrient_per_serving(nutriments, ["calcium"], serving_g, "mg"),
        "iron_mg": off_nutrient_per_serving(nutriments, ["iron"], serving_g, "mg"),
        "potassium_mg": off_nutrient_per_serving(nutriments, ["potassium"], serving_g, "mg"),
        "vitamin_a_mcg_rae": off_nutrient_per_serving(nutriments, ["vitamin-a"], serving_g, "mcg"),
        "vitamin_c_mg": off_nutrient_per_serving(nutriments, ["vitamin-c"], serving_g, "mg"),
        "vitamin_b12_mcg": off_nutrient_per_serving(nutriments, ["vitamin-b12"], serving_g, "mcg"),
        "folate_mcg_dfe": off_nutrient_per_serving(nutriments, ["vitamin-b9", "folates"], serving_g, "mcg"),
        "magnesium_mg": off_nutrient_per_serving(nutriments, ["magnesium"], serving_g, "mg"),
        "zinc_mg": off_nutrient_per_serving(nutriments, ["zinc"], serving_g, "mg"),
    }


def parse_serving_quantity_from_text(serving_size):
    text = normalize_whitespace(serving_size)
    if not text:
        return None
    match = re.search(
        r"(\d+(?:[.,]\d+)?)\s*(g|gr|gram|grams|ml|milliliter|milliliters)\b",
        text, re.IGNORECASE,
    )
    return safe_float(match.group(1)) if match else None


# ═══════════════════════════════════════════════════════════════════════════════
#  DOWNLOAD HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

def download_file(url, dest_path, label):
    """Download a single URL with progress. Returns True on success."""
    print(f"  {label}: trying {url}")
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Nomva-DB-Builder/1.0"})
        response = urllib.request.urlopen(req, timeout=120)
    except urllib.error.HTTPError as e:
        print(f"  {label}: {e.code} {e.reason} — skipping this URL")
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


def download_with_fallback(urls, dest_path, label):
    """Try multiple URLs. If all fail, tell the user how to provide the file manually."""
    if os.path.exists(dest_path):
        size_mb = os.path.getsize(dest_path) / (1024 * 1024)
        print(f"  {label}: already downloaded ({size_mb:.0f} MB), skipping")
        return True

    if isinstance(urls, str):
        urls = [urls]

    for url in urls:
        if download_file(url, dest_path, label):
            return True

    print(f"\n  {label}: download failed (will check for local data)")
    return False


def extract_zip(zip_path, extract_to, label):
    """Extract a ZIP file, looking for the JSON inside."""
    if os.path.exists(extract_to):
        # Check if we already have a JSON file extracted
        jsons = [f for f in os.listdir(extract_to) if f.endswith(".json")]
        if jsons:
            print(f"  {label}: already extracted ({len(jsons)} JSON files)")
            return
    os.makedirs(extract_to, exist_ok=True)
    print(f"  {label}: extracting...")
    with zipfile.ZipFile(zip_path, "r") as zf:
        zf.extractall(extract_to)
    print(f"  {label}: extracted")


# ═══════════════════════════════════════════════════════════════════════════════
#  DATABASE SCHEMA
# ═══════════════════════════════════════════════════════════════════════════════

def create_schema(conn):
    conn.execute("PRAGMA journal_mode=OFF")
    conn.execute("PRAGMA synchronous=OFF")
    conn.execute("PRAGMA temp_store=MEMORY")
    conn.execute("PRAGMA foreign_keys=OFF")

    conn.execute("""
        CREATE TABLE IF NOT EXISTS foods (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            fdc_id          INTEGER UNIQUE,
            name            TEXT NOT NULL,
            brand           TEXT,
            source          TEXT NOT NULL,
            serving_g       REAL,
            serving_desc    TEXT,
            portion_basis   TEXT NOT NULL DEFAULT 'grams',
            serving_source  TEXT,
            calories        REAL,
            protein_g       REAL,
            carbs_g         REAL,
            fat_g           REAL,
            fiber_g         REAL,
            sugar_g         REAL,
            sodium_mg       REAL,
            saturated_fat_g REAL,
            trans_fat_g     REAL,
            cholesterol_mg  REAL,
            added_sugar_g   REAL,
            vitamin_d_mcg   REAL,
            calcium_mg      REAL,
            iron_mg         REAL,
            potassium_mg    REAL,
            vitamin_a_mcg_rae REAL,
            vitamin_c_mg    REAL,
            vitamin_b12_mcg REAL,
            folate_mcg_dfe  REAL,
            magnesium_mg    REAL,
            zinc_mg         REAL,
            barcode         TEXT
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_barcode ON foods(barcode)")
    conn.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS foods_fts USING fts5(
            name, brand, content='foods', content_rowid='id'
        )
    """)
    conn.execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT)")
    conn.commit()


# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 1: SR LEGACY
# ═══════════════════════════════════════════════════════════════════════════════

def insert_sr_legacy(conn, sr_dir):
    """Parse and insert SR Legacy whole foods."""
    json_files = []
    for root, dirs, files in os.walk(sr_dir):
        for f in files:
            if f.endswith(".json"):
                json_files.append(os.path.join(root, f))

    if not json_files:
        print("  SR Legacy: no JSON files found, skipping")
        return 0

    cursor = conn.cursor()
    count = 0
    for filepath in json_files:
        with open(filepath, "r", encoding="utf-8") as f:
            try:
                data = json.load(f)
            except Exception:
                continue

        foods = data.get("SRLegacyFoods", data) if isinstance(data, dict) else data
        if not isinstance(foods, list):
            continue

        for food in foods:
            nutrients = food.get("foodNutrients", [])
            portions = food.get("foodPortions", [])
            portion_basis = "grams"
            serving_g, serving_desc, serving_source = choose_usda_serving(portions)
            micros = usda_micronutrients(nutrients, serving_g)

            cursor.execute("""
                INSERT OR IGNORE INTO foods
                    (fdc_id, name, brand, source, serving_g, serving_desc, portion_basis, serving_source,
                     calories, protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg,
                     saturated_fat_g, trans_fat_g, cholesterol_mg, added_sugar_g,
                     vitamin_d_mcg, calcium_mg, iron_mg, potassium_mg,
                     vitamin_a_mcg_rae, vitamin_c_mg, vitamin_b12_mcg,
                     folate_mcg_dfe, magnesium_mg, zinc_mg, barcode)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                food.get("fdcId"),
                prettify_label(food.get("description")) or "Unknown Food",
                None,
                "sr_legacy",
                serving_g,
                serving_desc,
                portion_basis,
                serving_source,
                per_serving(nutrient_value(nutrients, 1008), serving_g),
                per_serving(nutrient_value(nutrients, 1003), serving_g),
                per_serving(nutrient_value(nutrients, 1005), serving_g),
                per_serving(nutrient_value(nutrients, 1004), serving_g),
                per_serving(nutrient_value(nutrients, 1079), serving_g),
                per_serving(nutrient_value(nutrients, 2000), serving_g),
                per_serving(nutrient_value(nutrients, 1093), serving_g),
                *nutrient_tuple(micros),
                None,
            ))
            count += 1

    conn.commit()
    print(f"  SR Legacy: {count:,} foods")
    return count


# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 2: BRANDED FOODS (streaming — handles multi-GB files)
# ═══════════════════════════════════════════════════════════════════════════════

def iter_branded_foods(filepath):
    """
    Stream-parse a USDA Branded Foods JSON file without loading it all into RAM.
    The file structure is: {"BrandedFoods": [{...}, {...}, ...]}
    We read character by character to find each top-level object in the array.
    """
    with open(filepath, "r", encoding="utf-8") as f:
        # Skip to the opening bracket of the array
        # Read until we find the first '['
        depth = 0
        in_string = False
        escape_next = False
        found_array = False

        while True:
            ch = f.read(1)
            if not ch:
                return
            if ch == "[":
                found_array = True
                break

        if not found_array:
            return

        # Now stream individual JSON objects from the array
        buf = []
        depth = 0
        in_string = False
        escape_next = False

        while True:
            ch = f.read(1)
            if not ch:
                break

            if escape_next:
                buf.append(ch)
                escape_next = False
                continue

            if ch == "\\" and in_string:
                buf.append(ch)
                escape_next = True
                continue

            if ch == '"':
                buf.append(ch)
                in_string = not in_string
                continue

            if in_string:
                buf.append(ch)
                continue

            # Outside string
            if ch == "{":
                depth += 1
                buf.append(ch)
            elif ch == "}":
                depth -= 1
                buf.append(ch)
                if depth == 0:
                    raw = "".join(buf)
                    buf.clear()
                    try:
                        yield json.loads(raw)
                    except json.JSONDecodeError:
                        pass
            elif ch == "]" and depth == 0:
                break  # End of array
            elif depth > 0:
                buf.append(ch)


def insert_branded(conn, branded_dir):
    """Parse and insert Branded Foods using streaming to handle large files."""
    json_files = []
    for root, dirs, files in os.walk(branded_dir):
        for f in files:
            if f.endswith(".json"):
                json_files.append(os.path.join(root, f))

    if not json_files:
        print("  Branded: no JSON files found, skipping")
        return 0

    cursor = conn.cursor()
    count = 0
    skipped = 0

    for filepath in json_files:
        print(f"  Branded: streaming {os.path.basename(filepath)}...")
        for food in iter_branded_foods(filepath):
            nutrients = food.get("foodNutrients", [])
            label_nutrients = food.get("labelNutrients", {})
            explicit_serving_g = safe_float(food.get("servingSize"))
            label_calories = safe_float((label_nutrients.get("calories") or {}).get("value"))
            if explicit_serving_g and explicit_serving_g > 0:
                serving_g = explicit_serving_g
                portion_basis = "grams"
                serving_source = "explicit_serving"
            elif label_calories is not None:
                serving_g = None
                portion_basis = "fixed_serving"
                serving_source = "fallback_raw"
            else:
                serving_g = 100.0
                portion_basis = "grams"
                serving_source = "fallback_raw"

            calories = label_nutrient_value(
                label_nutrients, "calories",
                per_serving(nutrient_value(nutrients, 1008), serving_g),
            )
            if calories is None or calories <= 0:
                skipped += 1
                continue

            protein = label_nutrient_value(label_nutrients, "protein", per_serving(nutrient_value(nutrients, 1003), serving_g))
            carbs = label_nutrient_value(label_nutrients, "carbohydrates", per_serving(nutrient_value(nutrients, 1005), serving_g))
            fat = label_nutrient_value(label_nutrients, "fat", per_serving(nutrient_value(nutrients, 1004), serving_g))
            fiber = label_nutrient_value(label_nutrients, "fiber", per_serving(nutrient_value(nutrients, 1079), serving_g))
            sugar = label_nutrient_value(label_nutrients, "sugars", per_serving(nutrient_value(nutrients, 2000), serving_g))
            sodium = label_nutrient_value(label_nutrients, "sodium", per_serving(nutrient_value(nutrients, 1093), serving_g))
            micros = usda_micronutrients(nutrients, serving_g, label_nutrients)

            cursor.execute("""
                INSERT OR IGNORE INTO foods
                    (fdc_id, name, brand, source, serving_g, serving_desc, portion_basis, serving_source,
                     calories, protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg,
                     saturated_fat_g, trans_fat_g, cholesterol_mg, added_sugar_g,
                     vitamin_d_mcg, calcium_mg, iron_mg, potassium_mg,
                     vitamin_a_mcg_rae, vitamin_c_mg, vitamin_b12_mcg,
                     folate_mcg_dfe, magnesium_mg, zinc_mg, barcode)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                food.get("fdcId"),
                prettify_label(food.get("description")) or "Unknown Food",
                prettify_label(food.get("brandOwner")),
                "branded",
                serving_g,
                normalize_whitespace(food.get("householdServingFullText"))
                    or normalize_whitespace(food.get("servingSizeUnit"))
                    or (format_serving_description(serving_g) if portion_basis == "grams" else "1 serving"),
                portion_basis,
                serving_source,
                calories, protein, carbs, fat, fiber, sugar, sodium,
                *nutrient_tuple(micros),
                normalize_barcode(food.get("gtinUpc") or food.get("gtin")),
            ))
            count += 1

            if count % 50000 == 0:
                conn.commit()
                print(f"    ... {count:,} inserted so far")

    conn.commit()
    print(f"  Branded: {count:,} foods, skipped {skipped:,} (no calories)")
    return count


# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 3: OPEN FOOD FACTS (US products with barcodes only)
# ═══════════════════════════════════════════════════════════════════════════════

def build_match_indexes(conn):
    """Build in-memory indexes for deduplication against USDA records."""
    records = {}
    barcode_index = {}
    brand_name_index = {}
    brand_name_serving_index = {}
    unbranded_name_index = {}

    cursor = conn.execute(f"""
        SELECT id, name, brand, source, serving_g, serving_desc, portion_basis, serving_source,
               {", ".join(MICRONUTRIENT_COLUMNS)}, barcode
        FROM foods
    """)

    for row in cursor:
        row_id, name, brand, source, serving_g, serving_desc, portion_basis, serving_source = row[:8]
        micronutrient_values = row[8:8 + len(MICRONUTRIENT_COLUMNS)]
        barcode = row[-1]
        name_key = normalize_lookup_key(name)
        brand_key = normalize_lookup_key(brand)
        barcode_key = normalize_barcode(barcode)
        s_bucket = serving_bucket(serving_g)

        records[row_id] = {
            "name": name, "name_key": name_key,
            "brand": brand, "brand_key": brand_key,
            "source": source, "serving_g": safe_float(serving_g),
            "serving_desc": serving_desc, "portion_basis": portion_basis,
            "serving_source": serving_source, "barcode": barcode_key,
        }
        records[row_id].update(dict(zip(MICRONUTRIENT_COLUMNS, micronutrient_values)))

        if barcode_key:
            barcode_index.setdefault(barcode_key, row_id)
        if source != "open_food_facts":
            if brand_key and name_key:
                brand_name_index.setdefault((brand_key, name_key), row_id)
                if s_bucket is not None:
                    brand_name_serving_index.setdefault((brand_key, name_key, s_bucket), row_id)
            elif name_key:
                unbranded_name_index.setdefault(name_key, row_id)

    return {
        "records": records,
        "barcode": barcode_index,
        "brand_name": brand_name_index,
        "brand_name_serving": brand_name_serving_index,
        "unbranded_name": unbranded_name_index,
    }


def index_food_record(indexes, row_id):
    record = indexes["records"][row_id]
    barcode_key = record["barcode"]
    brand_key = record["brand_key"]
    name_key = record["name_key"]
    s_bucket = serving_bucket(record["serving_g"])
    source = record["source"]

    if barcode_key:
        indexes["barcode"].setdefault(barcode_key, row_id)
    if source != "open_food_facts":
        if brand_key and name_key:
            indexes["brand_name"].setdefault((brand_key, name_key), row_id)
            if s_bucket is not None:
                indexes["brand_name_serving"].setdefault((brand_key, name_key, s_bucket), row_id)
        elif name_key:
            indexes["unbranded_name"].setdefault(name_key, row_id)


def find_match(indexes, candidate):
    barcode_key = candidate["barcode"]
    if barcode_key and barcode_key in indexes["barcode"]:
        return indexes["barcode"][barcode_key]

    brand_key = candidate["brand_key"]
    name_key = candidate["name_key"]
    s_bucket = serving_bucket(candidate["serving_g"])

    if brand_key and name_key and s_bucket is not None:
        key = (brand_key, name_key, s_bucket)
        if key in indexes["brand_name_serving"]:
            return indexes["brand_name_serving"][key]

    if brand_key and name_key:
        key = (brand_key, name_key)
        if key in indexes["brand_name"]:
            return indexes["brand_name"][key]

    if not brand_key and name_key and name_key in indexes["unbranded_name"]:
        return indexes["unbranded_name"][name_key]

    return None


def off_brand_name(product):
    brands = normalize_whitespace(product.get("brands"))
    if brands:
        first = normalize_whitespace(brands.split(",")[0])
        if first:
            return prettify_label(first)
    return prettify_label(product.get("brand_owner"))


def looks_like_menu_item_name(name):
    lower = (name or "").lower()
    size_words = ("small", "medium", "large", "kids")
    piece_words = ("piece", "pieces", "nugget", "nuggets", "strip", "strips", "fries")
    if any(word in lower for word in size_words) and "," in lower:
        return True
    if re.search(r"\b\d+\s*(piece|pieces|pc|pcs|count|ct|nugget|nuggets|strip|strips)\b", lower):
        return True
    if any(word in lower for word in ("combo", "meal", "value meal", "kids meal")):
        return True
    return any(word in lower for word in piece_words) and lower.count(",") >= 1


def off_food_from_product(product):
    nutriments = product.get("nutriments", {})
    serving_desc = normalize_whitespace(product.get("serving_size"))
    explicit_serving_g = safe_float(product.get("serving_quantity"))
    parsed_serving_g = parse_serving_quantity_from_text(serving_desc) if explicit_serving_g is None else None
    serving_g = explicit_serving_g or parsed_serving_g
    if serving_g is not None and serving_g <= 0:
        serving_g = None

    calorie_info = off_nutrient_value_info(nutriments, ["energy-kcal", "energy"], serving_g, "kcal")
    protein_info = off_nutrient_value_info(nutriments, ["proteins"], serving_g, "g")
    carbs_info = off_nutrient_value_info(nutriments, ["carbohydrates"], serving_g, "g")
    fat_info = off_nutrient_value_info(nutriments, ["fat"], serving_g, "g")
    fiber_info = off_nutrient_value_info(nutriments, ["fiber"], serving_g, "g")
    sugar_info = off_nutrient_value_info(nutriments, ["sugars"], serving_g, "g")
    sodium_info = off_nutrient_value_info(nutriments, ["sodium"], serving_g, "mg")

    calories = calorie_info["value"]
    protein = protein_info["value"]
    carbs = carbs_info["value"]
    fat = fat_info["value"]
    fiber = fiber_info["value"]
    sugar = sugar_info["value"]
    sodium = sodium_info["value"]
    if sodium is None:
        salt_g = off_nutrient_per_serving(nutriments, ["salt"], serving_g, "g")
        sodium = salt_g * 393.4 if salt_g is not None else None
    micros = off_micronutrients(nutriments, serving_g)

    nutrient_sources = {
        normalize_off_source(info["source"])
        for info in (calorie_info, protein_info, carbs_info, fat_info)
        if info["source"] is not None
    }
    if explicit_serving_g and explicit_serving_g > 0:
        portion_basis = "grams"
        serving_source = "explicit_serving"
    elif parsed_serving_g and parsed_serving_g > 0:
        portion_basis = "grams"
        serving_source = "parsed_serving"
    elif nutrient_sources and nutrient_sources.issubset({"100g"}):
        portion_basis = "grams"
        serving_source = "fallback_raw"
        serving_g = 100.0
        if not serving_desc:
            serving_desc = "100g"
    else:
        portion_basis = "fixed_serving"
        serving_source = "fallback_raw"
        serving_g = None
        if not serving_desc:
            serving_desc = "1 serving"

    if portion_basis == "grams" and serving_g and not serving_desc:
        serving_desc = format_serving_description(serving_g)

    name = (
        prettify_label(product.get("product_name"))
        or prettify_label(product.get("product_name_en"))
        or prettify_label(product.get("abbreviated_product_name"))
        or prettify_label(product.get("generic_name"))
        or prettify_label(product.get("generic_name_en"))
    )

    brand = off_brand_name(product)
    barcode = normalize_barcode(product.get("code"))
    weak_explicit_hundred_grams = (
        explicit_serving_g is not None
        and abs(explicit_serving_g - 100.0) < 0.01
        and is_weak_serving_desc(serving_desc)
        and looks_like_menu_item_name(name)
        and ("raw" in nutrient_sources or "serving" in nutrient_sources)
    )

    if weak_explicit_hundred_grams:
        portion_basis = "fixed_serving"
        serving_source = "fallback_raw"
        serving_g = None
        serving_desc = "1 serving"

    return {
        "name": name, "name_key": normalize_lookup_key(name),
        "brand": brand, "brand_key": normalize_lookup_key(brand),
        "barcode": barcode, "serving_g": serving_g, "serving_desc": serving_desc,
        "portion_basis": portion_basis, "serving_source": serving_source,
        "calories": calories, "protein_g": protein, "carbs_g": carbs,
        "fat_g": fat, "fiber_g": fiber, "sugar_g": sugar, "sodium_mg": sodium,
        **micros,
    }


def merge_open_food_facts(conn, off_path):
    """Stream through the OFF dump, keeping only US products with barcodes."""
    print(f"  OFF: streaming {os.path.basename(off_path)} (this takes 10-20 minutes)...")
    indexes = build_match_indexes(conn)
    cursor = conn.cursor()

    stats = {"seen": 0, "us_barcoded": 0, "merged": 0, "inserted": 0,
             "matched_no_change": 0, "skipped": 0, "invalid": 0}

    opener = gzip.open if off_path.endswith(".gz") else open
    with opener(off_path, "rt", encoding="utf-8") as f:
        for line in f:
            stats["seen"] += 1
            payload = line.strip()
            if not payload:
                continue

            try:
                product = json.loads(payload)
            except json.JSONDecodeError:
                stats["invalid"] += 1
                continue

            # ── Filter: US products with barcodes ──────────────────────────
            countries = product.get("countries_tags", [])
            if not isinstance(countries, list):
                countries = []
            is_us = any(tag in OFF_ACCEPTED_COUNTRIES for tag in countries)
            if not is_us:
                stats["skipped"] += 1
                continue

            raw_barcode = normalize_barcode(product.get("code"))
            if not raw_barcode:
                stats["skipped"] += 1
                continue

            stats["us_barcoded"] += 1

            candidate = off_food_from_product(product)
            if not (candidate["barcode"] or candidate["name_key"]):
                stats["skipped"] += 1
                continue

            match_row_id = find_match(indexes, candidate)

            if match_row_id is not None:
                # USDA match found — only backfill missing metadata
                record = indexes["records"][match_row_id]
                updates = {}
                if is_missing_text(record["brand"]) and candidate["brand"]:
                    updates["brand"] = candidate["brand"]
                if is_missing_text(record["barcode"]) and candidate["barcode"]:
                    updates["barcode"] = candidate["barcode"]
                if record["serving_g"] in (None, 0) and candidate["serving_g"]:
                    updates["serving_g"] = candidate["serving_g"]
                if should_replace_serving_desc(record["serving_desc"], candidate["serving_desc"]):
                    updates["serving_desc"] = candidate["serving_desc"]
                if ("serving_g" in updates or "serving_desc" in updates) and candidate["portion_basis"]:
                    updates["portion_basis"] = candidate["portion_basis"]
                    updates["serving_source"] = candidate["serving_source"]
                elif record.get("serving_source") is None and candidate["serving_source"]:
                    updates["serving_source"] = candidate["serving_source"]
                for column in MICRONUTRIENT_COLUMNS:
                    if record.get(column) is None and candidate.get(column) is not None:
                        updates[column] = candidate[column]

                if updates:
                    set_clause = ", ".join(f"{col} = ?" for col in updates)
                    cursor.execute(
                        f"UPDATE foods SET {set_clause} WHERE id = ?",
                        list(updates.values()) + [match_row_id],
                    )
                    for k, v in updates.items():
                        if k == "brand":
                            record["brand"] = v
                            record["brand_key"] = normalize_lookup_key(v)
                        elif k == "barcode":
                            record["barcode"] = normalize_barcode(v)
                        elif k == "serving_g":
                            record["serving_g"] = safe_float(v)
                        elif k == "serving_desc":
                            record["serving_desc"] = v
                        elif k == "portion_basis":
                            record["portion_basis"] = v
                        elif k == "serving_source":
                            record["serving_source"] = v
                        elif k in MICRONUTRIENT_COLUMNS:
                            record[k] = v
                    index_food_record(indexes, match_row_id)
                    stats["merged"] += 1
                else:
                    stats["matched_no_change"] += 1
                continue

            # No USDA match — insert as OFF-only if it has real data
            if candidate["calories"] is None or candidate["calories"] <= 0 or not candidate["name"]:
                stats["skipped"] += 1
                continue

            cursor.execute("""
                INSERT INTO foods
                    (fdc_id, name, brand, source, serving_g, serving_desc, portion_basis, serving_source,
                     calories, protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg,
                     saturated_fat_g, trans_fat_g, cholesterol_mg, added_sugar_g,
                     vitamin_d_mcg, calcium_mg, iron_mg, potassium_mg,
                     vitamin_a_mcg_rae, vitamin_c_mg, vitamin_b12_mcg,
                     folate_mcg_dfe, magnesium_mg, zinc_mg, barcode)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                None,
                candidate["name"], candidate["brand"], "open_food_facts",
                candidate["serving_g"], candidate["serving_desc"],
                candidate["portion_basis"], candidate["serving_source"],
                candidate["calories"], candidate["protein_g"], candidate["carbs_g"],
                candidate["fat_g"], candidate["fiber_g"], candidate["sugar_g"],
                candidate["sodium_mg"], *nutrient_tuple(candidate), candidate["barcode"],
            ))

            row_id = cursor.lastrowid
            indexes["records"][row_id] = {
                "name": candidate["name"], "name_key": candidate["name_key"],
                "brand": candidate["brand"], "brand_key": candidate["brand_key"],
                "source": "open_food_facts", "serving_g": candidate["serving_g"],
                "serving_desc": candidate["serving_desc"], "portion_basis": candidate["portion_basis"],
                "serving_source": candidate["serving_source"], "barcode": candidate["barcode"],
            }
            index_food_record(indexes, row_id)
            stats["inserted"] += 1

            if stats["seen"] % 200000 == 0:
                conn.commit()
                print(
                    f"    ... {stats['seen']:,} scanned"
                    f" | {stats['us_barcoded']:,} US+barcode"
                    f" | {stats['inserted']:,} new"
                    f" | {stats['merged']:,} backfilled"
                )

    conn.commit()
    print(
        f"  OFF done:"
        f" {stats['seen']:,} scanned,"
        f" {stats['us_barcoded']:,} US+barcode,"
        f" {stats['inserted']:,} new foods,"
        f" {stats['merged']:,} USDA backfills,"
        f" {stats['matched_no_change']:,} exact dupes skipped"
    )
    return stats


# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════════

def main():
    print("=" * 60)
    print("  Nomva Food Database Builder")
    print("=" * 60)
    print()

    os.makedirs(DATA_DIR, exist_ok=True)

    # ── Step 0: Download everything ────────────────────────────────────────
    print("STEP 0: Downloading data sources\n")

    sr_zip = os.path.join(DATA_DIR, "sr_legacy.zip")
    branded_zip = os.path.join(DATA_DIR, "branded.zip")
    off_gz = os.path.join(DATA_DIR, "openfoodfacts-products.jsonl.gz")
    off_jsonl = os.path.join(DATA_DIR, "openfoodfacts-products.jsonl")

    # Possible locations where user already has data
    old_sr = os.path.join(PROJECT_ROOT, "sr_legacy")
    old_branded = os.path.join(PROJECT_ROOT, "branded")
    old_off_candidates = [
        os.path.join(PROJECT_ROOT, "open_food_facts", "openfoodfacts-products.jsonl.gz"),
        os.path.join(PROJECT_ROOT, "openfoodfacts-products.jsonl.gz"),
        os.path.join(PROJECT_ROOT, "open_food_facts", "openfoodfacts-products.jsonl"),
        os.path.join(PROJECT_ROOT, "openfoodfacts-products.jsonl"),
        os.path.join(DATA_DIR, "openfoodfacts-products.jsonl"),
    ]

    # Check for existing local data FIRST before downloading
    has_local_sr = os.path.isdir(old_sr) and any(
        f.endswith(".json") for f in os.listdir(old_sr)
    )
    has_local_branded = os.path.isdir(old_branded) and any(
        f.endswith(".json") for f in os.listdir(old_branded)
    )
    has_local_off = os.path.exists(off_jsonl) or any(os.path.exists(c) for c in old_off_candidates)

    if has_local_sr:
        print(f"  USDA SR Legacy: found local data at {old_sr}")
    else:
        download_with_fallback(USDA_SR_LEGACY_URLS, sr_zip, "USDA SR Legacy")

    if has_local_branded:
        print(f"  USDA Branded: found local data at {old_branded}")
    else:
        download_with_fallback(USDA_BRANDED_URLS, branded_zip, "USDA Branded")

    if has_local_off:
        if os.path.exists(off_jsonl):
            found = off_jsonl
        else:
            found = next(c for c in old_off_candidates if os.path.exists(c))
        size_gb = os.path.getsize(found) / (1024 * 1024 * 1024)
        print(f"  Open Food Facts: found local data ({size_gb:.1f} GB)")
    elif not os.path.exists(off_gz):
        download_with_fallback(OFF_URL, off_gz, "Open Food Facts")
    else:
        print(f"  Open Food Facts: already downloaded")

    # ── Step 0b: Resolve data directories ──────────────────────────────────
    # For each data source, prefer: downloaded zip → existing project dir
    print("\nResolving data sources...\n")

    # SR Legacy
    sr_dir = os.path.join(DATA_DIR, "sr_legacy")
    if os.path.exists(sr_zip):
        extract_zip(sr_zip, sr_dir, "SR Legacy")
    elif os.path.isdir(old_sr) and any(f.endswith(".json") for f in os.listdir(old_sr)):
        print(f"  SR Legacy: using existing data at {old_sr}")
        sr_dir = old_sr
    else:
        print("  !! ERROR: No SR Legacy data found. Download the JSON zip from:")
        print("  !!   https://fdc.nal.usda.gov/download-datasets/")
        print(f"  !! Save to: {sr_zip}")
        sys.exit(1)

    # Branded
    branded_dir = os.path.join(DATA_DIR, "branded")
    if os.path.exists(branded_zip):
        extract_zip(branded_zip, branded_dir, "Branded")
    elif os.path.isdir(old_branded) and any(f.endswith(".json") for f in os.listdir(old_branded)):
        print(f"  Branded: using existing data at {old_branded}")
        branded_dir = old_branded
    else:
        print("  !! ERROR: No Branded Foods data found. Download the JSON zip from:")
        print("  !!   https://fdc.nal.usda.gov/download-datasets/")
        print(f"  !! Save to: {branded_zip}")
        sys.exit(1)

    # Open Food Facts — check .gz first, then uncompressed .jsonl, then old candidates
    if not os.path.exists(off_gz):
        # Check for uncompressed .jsonl in _build_data
        if os.path.exists(off_jsonl):
            print(f"  OFF: found uncompressed JSONL at {off_jsonl}")
            off_gz = off_jsonl  # merge_open_food_facts handles both .gz and plain
        else:
            for candidate in old_off_candidates:
                if os.path.exists(candidate):
                    print(f"  OFF: using existing data at {candidate}")
                    off_gz = candidate
                    break
    if not os.path.exists(off_gz):
        print("  !! ERROR: No Open Food Facts data found.")
        print(f"  !! Download from: https://static.openfoodfacts.org/data/openfoodfacts-products.jsonl.gz")
        print(f"  !! Save to: {off_gz}")
        print(f"  !! (or save uncompressed as: {off_jsonl})")
        sys.exit(1)
    else:
        size_gb = os.path.getsize(off_gz) / (1024 * 1024 * 1024)
        print(f"  OFF: found ({size_gb:.1f} GB)")

    # ── Step 1: Create fresh database ──────────────────────────────────────
    print("\nSTEP 1: Building database\n")
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)

    conn = sqlite3.connect(DB_PATH)
    create_schema(conn)

    # ── Step 2: Insert USDA data ───────────────────────────────────────────
    print("STEP 2: Loading USDA data\n")
    sr_count = insert_sr_legacy(conn, sr_dir)
    branded_count = insert_branded(conn, branded_dir)

    # ── Step 3: Merge OFF ──────────────────────────────────────────────────
    print("\nSTEP 3: Merging Open Food Facts (US products with barcodes)\n")
    off_stats = merge_open_food_facts(conn, off_gz)

    # ── Step 4: Build FTS index ────────────────────────────────────────────
    print("\nSTEP 4: Building search index...")
    conn.execute("INSERT INTO foods_fts(foods_fts) VALUES('rebuild')")
    conn.commit()
    print("  FTS5 index built")

    # ── Step 5: Write metadata ─────────────────────────────────────────────
    total = conn.execute("SELECT COUNT(*) FROM foods").fetchone()[0]
    build_date = conn.execute("SELECT date('now')").fetchone()[0]
    meta = {
        "total_foods": str(total),
        "build_date": build_date,
        "sr_legacy_count": str(sr_count),
        "branded_count": str(branded_count),
        "off_inserted": str(off_stats["inserted"]),
        "off_merged": str(off_stats["merged"]),
        "off_scanned": str(off_stats["seen"]),
    }
    for key, value in meta.items():
        conn.execute("INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)", (key, value))
    conn.commit()

    # ── Summary ────────────────────────────────────────────────────────────
    sources = conn.execute("SELECT source, COUNT(*) FROM foods GROUP BY source").fetchall()
    conn.close()

    size_mb = os.path.getsize(DB_PATH) / (1024 * 1024)
    print("\n" + "=" * 60)
    print(f"  DONE — {DB_PATH}")
    print(f"  Total foods: {total:,}  |  Size: {size_mb:.0f} MB")
    print()
    for source, count in sorted(sources):
        print(f"    {source}: {count:,}")
    print("=" * 60)
    print()
    print("Next: open Nomva.xcodeproj in Xcode and build. The new")
    print("foods.sqlite is already in Nomva/Resources/.")


if __name__ == "__main__":
    main()
