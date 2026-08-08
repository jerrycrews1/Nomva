#!/usr/bin/env python3
"""
USDA + Open Food Facts → SQLite pipeline for Nomva.

Builds `Nomva/Resources/foods.sqlite` from:
  - USDA Foundation, Survey/FNDDS, and SR Legacy JSON exports
  - USDA Branded Foods JSON exports
  - Optional Open Food Facts JSONL/NDJSON dump (plain or gzip-compressed)

USDA remains the source of truth. Open Food Facts only:
  - backfills missing barcode / brand / serving metadata on matched USDA rows
  - inserts OFF-only foods as new searchable rows when no USDA match exists

Environment overrides:
  NOMVA_FOOD_DB_PATH
  USDA_SR_LEGACY_DIR
  USDA_BRANDED_DIR
  OPEN_FOOD_FACTS_PATH
"""

import glob
import gzip
import json
import math
import os
import re
import sqlite3

from usda_reference_data import discover_single_json, insert_reference_foods, rebuild_search_index

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
DB_PATH = os.environ.get(
    "NOMVA_FOOD_DB_PATH",
    os.path.join(PROJECT_ROOT, "Nomva", "Resources", "foods.sqlite"),
)
SR_LEGACY_DIR = os.environ.get("USDA_SR_LEGACY_DIR", os.path.join(PROJECT_ROOT, "sr_legacy"))
BRANDED_DIR = os.environ.get("USDA_BRANDED_DIR", os.path.join(PROJECT_ROOT, "branded"))
FOUNDATION_DIR = os.environ.get(
    "USDA_FOUNDATION_DIR", os.path.join(PROJECT_ROOT, "_build_data", "foundation")
)
FNDDS_DIR = os.environ.get(
    "USDA_FNDDS_DIR", os.path.join(PROJECT_ROOT, "_build_data", "fndds")
)

OFF_GLOB_PATTERNS = [
    os.path.join(PROJECT_ROOT, "open_food_facts", "**", "*.jsonl.gz"),
    os.path.join(PROJECT_ROOT, "open_food_facts", "**", "*.jsonl"),
    os.path.join(PROJECT_ROOT, "open_food_facts", "**", "*.ndjson.gz"),
    os.path.join(PROJECT_ROOT, "open_food_facts", "**", "*.ndjson"),
    os.path.join(PROJECT_ROOT, "openfoodfacts", "**", "*.jsonl.gz"),
    os.path.join(PROJECT_ROOT, "openfoodfacts", "**", "*.jsonl"),
    os.path.join(PROJECT_ROOT, "off", "**", "*.jsonl.gz"),
    os.path.join(PROJECT_ROOT, "off", "**", "*.jsonl"),
    os.path.join(PROJECT_ROOT, "*openfoodfacts*.jsonl.gz"),
    os.path.join(PROJECT_ROOT, "*openfoodfacts*.jsonl"),
]

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

# Countries we accept from Open Food Facts (US-focused)
OFF_ACCEPTED_COUNTRIES = {
    "en:united-states",
    "en:us",
    "en:united-states-of-america",
}


def configure_connection(conn):
    """Speed up one-shot local DB builds."""
    pragmas = [
        "PRAGMA journal_mode=OFF",
        "PRAGMA synchronous=OFF",
        "PRAGMA temp_store=MEMORY",
        "PRAGMA foreign_keys=OFF",
    ]
    for pragma in pragmas:
        conn.execute(pragma)


def extract_foods(data, root_key):
    """Normalize USDA exports that wrap foods under a top-level key."""
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        foods = data.get(root_key, [])
        return foods if isinstance(foods, list) else []
    return []


def safe_float(value):
    if value in (None, ""):
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
        return number if math.isfinite(number) else None

    text = str(value).strip().replace(",", ".")
    if not text:
        return None
    try:
        number = float(text)
    except ValueError:
        return None
    return number if math.isfinite(number) else None


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
    text = re.sub(r"[^a-z0-9]+", " ", text.lower())
    text = re.sub(r"\s+", " ", text).strip()
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
    """Extract a USDA nutrient if present, preserving NULL vs explicit 0."""
    for nutrient in nutrients:
        if nutrient.get("nutrient", {}).get("id") == nutrient_id:
            return safe_float(nutrient.get("amount"))
    return None


def per_serving(amount_per_100g, serving_g):
    """Convert 100g nutrient values to serving-sized values when possible."""
    amount = safe_float(amount_per_100g)
    if amount is None:
        return None

    grams = safe_float(serving_g)
    if grams is None or grams <= 0:
        return amount
    return amount * (grams / 100.0)


def label_nutrient_value(label_nutrients, key, fallback):
    """Prefer label nutrients (per serving) when USDA provides them."""
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

    match = re.search(r"(\d+(?:[.,]\d+)?)\s*(g|gr|gram|grams|ml|milliliter|milliliters)\b", text, re.IGNORECASE)
    if not match:
        return None
    return safe_float(match.group(1))


def discover_open_food_facts_path():
    override = normalize_whitespace(os.environ.get("OPEN_FOOD_FACTS_PATH"))
    if override:
        return override if os.path.exists(override) else None

    matches = []
    for pattern in OFF_GLOB_PATTERNS:
        matches.extend(glob.glob(pattern, recursive=True))

    if not matches:
        return None

    matches = sorted(set(matches), key=lambda path: (os.path.getsize(path), path), reverse=True)
    return matches[0]


def open_json_lines(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8")
    return open(path, "r", encoding="utf-8")


def create_schema(conn):
    cursor = conn.cursor()

    cursor.execute("""
        CREATE TABLE IF NOT EXISTS foods (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            fdc_id          INTEGER UNIQUE,
            name            TEXT NOT NULL,
            brand           TEXT,
            source          TEXT NOT NULL,
            search_terms    TEXT,
            serving_g       REAL,
            serving_desc    TEXT,
            portion_basis   TEXT NOT NULL DEFAULT 'grams',
            serving_source  TEXT,
            default_serving_g REAL,
            default_serving_desc TEXT,
            default_serving_source TEXT,
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

    cursor.execute("CREATE INDEX IF NOT EXISTS idx_barcode ON foods(barcode)")
    cursor.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS foods_fts USING fts5(
            name,
            brand,
            search_terms,
            content='foods',
            content_rowid='id'
        )
    """)
    cursor.execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT)")

    conn.commit()


def insert_sr_legacy(conn):
    """Parse and insert SR Legacy whole foods."""
    cursor = conn.cursor()
    files = glob.glob(os.path.join(SR_LEGACY_DIR, "**", "*.json"), recursive=True)
    count = 0

    for filepath in files:
        with open(filepath, "r", encoding="utf-8") as file:
            try:
                data = json.load(file)
            except Exception:
                continue

        foods = extract_foods(data, "SRLegacyFoods")

        for food in foods:
            nutrients = food.get("foodNutrients", [])
            portions = food.get("foodPortions", [])
            portion_basis = "grams"
            serving_g, serving_desc, serving_source = choose_usda_serving(portions)

            calories = per_serving(nutrient_value(nutrients, 1008), serving_g)
            protein = per_serving(nutrient_value(nutrients, 1003), serving_g)
            carbs = per_serving(nutrient_value(nutrients, 1005), serving_g)
            fat = per_serving(nutrient_value(nutrients, 1004), serving_g)
            fiber = per_serving(nutrient_value(nutrients, 1079), serving_g)
            sugar = per_serving(nutrient_value(nutrients, 2000), serving_g)
            sodium = per_serving(nutrient_value(nutrients, 1093), serving_g)
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
                calories,
                protein,
                carbs,
                fat,
                fiber,
                sugar,
                sodium,
                *nutrient_tuple(micros),
                None,
            ))
            count += 1

    conn.commit()
    print(f"SR Legacy: inserted {count:,} foods")
    return count


def insert_branded(conn):
    """Parse and insert Branded Foods."""
    cursor = conn.cursor()
    files = glob.glob(os.path.join(BRANDED_DIR, "**", "*.json"), recursive=True)
    count = 0
    skipped = 0

    for filepath in files:
        with open(filepath, "r", encoding="utf-8") as file:
            try:
                data = json.load(file)
            except Exception:
                continue

        foods = extract_foods(data, "BrandedFoods")

        for food in foods:
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
                label_nutrients,
                "calories",
                per_serving(nutrient_value(nutrients, 1008), serving_g)
            )

            if calories is None or calories <= 0:
                skipped += 1
                continue

            protein = label_nutrient_value(
                label_nutrients,
                "protein",
                per_serving(nutrient_value(nutrients, 1003), serving_g)
            )
            carbs = label_nutrient_value(
                label_nutrients,
                "carbohydrates",
                per_serving(nutrient_value(nutrients, 1005), serving_g)
            )
            fat = label_nutrient_value(
                label_nutrients,
                "fat",
                per_serving(nutrient_value(nutrients, 1004), serving_g)
            )
            fiber = label_nutrient_value(
                label_nutrients,
                "fiber",
                per_serving(nutrient_value(nutrients, 1079), serving_g)
            )
            sugar = label_nutrient_value(
                label_nutrients,
                "sugars",
                per_serving(nutrient_value(nutrients, 2000), serving_g)
            )
            sodium = label_nutrient_value(
                label_nutrients,
                "sodium",
                per_serving(nutrient_value(nutrients, 1093), serving_g)
            )
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
                calories,
                protein,
                carbs,
                fat,
                fiber,
                sugar,
                sodium,
                *nutrient_tuple(micros),
                normalize_barcode(food.get("gtinUpc") or food.get("gtin")),
            ))
            count += 1

    conn.commit()
    print(f"Branded Foods: inserted {count:,} foods, skipped {skipped:,} (no calorie data)")
    return count


def build_match_indexes(conn):
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
        serving_key = serving_bucket(serving_g)

        records[row_id] = {
            "name": name,
            "name_key": name_key,
            "brand": brand,
            "brand_key": brand_key,
            "source": source,
            "serving_g": safe_float(serving_g),
            "serving_desc": serving_desc,
            "portion_basis": portion_basis,
            "serving_source": serving_source,
            "barcode": barcode_key,
        }
        record_nutrients = dict(zip(MICRONUTRIENT_COLUMNS, micronutrient_values))
        records[row_id].update(record_nutrients)

        if barcode_key:
            barcode_index.setdefault(barcode_key, row_id)
        if source != "open_food_facts":
            if brand_key and name_key:
                brand_name_index.setdefault((brand_key, name_key), row_id)
                if serving_key is not None:
                    brand_name_serving_index.setdefault((brand_key, name_key, serving_key), row_id)
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
    serving_key = serving_bucket(record["serving_g"])
    source = record["source"]

    if barcode_key:
        indexes["barcode"].setdefault(barcode_key, row_id)
    if source != "open_food_facts":
        if brand_key and name_key:
            indexes["brand_name"].setdefault((brand_key, name_key), row_id)
            if serving_key is not None:
                indexes["brand_name_serving"].setdefault((brand_key, name_key, serving_key), row_id)
        elif name_key:
            indexes["unbranded_name"].setdefault(name_key, row_id)


def find_match(indexes, candidate):
    barcode_key = candidate["barcode"]
    if barcode_key and barcode_key in indexes["barcode"]:
        return indexes["barcode"][barcode_key]

    brand_key = candidate["brand_key"]
    name_key = candidate["name_key"]
    serving_key = serving_bucket(candidate["serving_g"])

    if brand_key and name_key and serving_key is not None:
        key = (brand_key, name_key, serving_key)
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
        "name": name,
        "name_key": normalize_lookup_key(name),
        "brand": brand,
        "brand_key": normalize_lookup_key(brand),
        "barcode": barcode,
        "serving_g": serving_g,
        "serving_desc": serving_desc,
        "portion_basis": portion_basis,
        "serving_source": serving_source,
        "calories": calories,
        "protein_g": protein,
        "carbs_g": carbs,
        "fat_g": fat,
        "fiber_g": fiber,
        "sugar_g": sugar,
        "sodium_mg": sodium,
        **micros,
    }


def merge_open_food_facts(conn):
    off_path = discover_open_food_facts_path()
    if not off_path:
        print("Open Food Facts: no dump found, skipping")
        return {
            "path": None,
            "seen": 0,
            "parsed": 0,
            "merged": 0,
            "inserted": 0,
            "matched_without_change": 0,
            "skipped": 0,
            "invalid": 0,
        }

    print(f"Open Food Facts: importing {off_path}")
    indexes = build_match_indexes(conn)
    cursor = conn.cursor()

    summary = {
        "path": off_path,
        "seen": 0,
        "parsed": 0,
        "merged": 0,
        "inserted": 0,
        "matched_without_change": 0,
        "skipped": 0,
        "invalid": 0,
    }

    with open_json_lines(off_path) as file:
        for line_number, line in enumerate(file, start=1):
            summary["seen"] += 1
            payload = line.strip()
            if not payload:
                continue

            try:
                product = json.loads(payload)
            except json.JSONDecodeError:
                summary["invalid"] += 1
                continue

            # Filter: US products with barcodes only
            countries = product.get("countries_tags", [])
            if not isinstance(countries, list):
                countries = []
            is_us = any(tag in OFF_ACCEPTED_COUNTRIES for tag in countries)
            if not is_us:
                summary["skipped"] += 1
                continue

            raw_barcode = normalize_barcode(product.get("code"))
            if not raw_barcode:
                summary["skipped"] += 1
                continue

            candidate = off_food_from_product(product)
            has_match_key = candidate["barcode"] or candidate["name_key"]
            if not has_match_key:
                summary["skipped"] += 1
                continue

            summary["parsed"] += 1
            match_row_id = find_match(indexes, candidate)

            if match_row_id is not None:
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
                    set_clause = ", ".join(f"{column} = ?" for column in updates.keys())
                    params = list(updates.values()) + [match_row_id]
                    cursor.execute(f"UPDATE foods SET {set_clause} WHERE id = ?", params)

                    if "brand" in updates:
                        record["brand"] = updates["brand"]
                        record["brand_key"] = normalize_lookup_key(updates["brand"])
                    if "barcode" in updates:
                        record["barcode"] = normalize_barcode(updates["barcode"])
                    if "serving_g" in updates:
                        record["serving_g"] = safe_float(updates["serving_g"])
                    if "serving_desc" in updates:
                        record["serving_desc"] = updates["serving_desc"]
                    if "portion_basis" in updates:
                        record["portion_basis"] = updates["portion_basis"]
                    if "serving_source" in updates:
                        record["serving_source"] = updates["serving_source"]
                    for column in MICRONUTRIENT_COLUMNS:
                        if column in updates:
                            record[column] = updates[column]

                    index_food_record(indexes, match_row_id)
                    summary["merged"] += 1
                else:
                    summary["matched_without_change"] += 1
                continue

            if candidate["calories"] is None or candidate["calories"] <= 0 or not candidate["name"]:
                summary["skipped"] += 1
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
                candidate["name"],
                candidate["brand"],
                "open_food_facts",
                candidate["serving_g"],
                candidate["serving_desc"],
                candidate["portion_basis"],
                candidate["serving_source"],
                candidate["calories"],
                candidate["protein_g"],
                candidate["carbs_g"],
                candidate["fat_g"],
                candidate["fiber_g"],
                candidate["sugar_g"],
                candidate["sodium_mg"],
                *nutrient_tuple(candidate),
                candidate["barcode"],
            ))

            row_id = cursor.lastrowid
            indexes["records"][row_id] = {
                "name": candidate["name"],
                "name_key": candidate["name_key"],
                "brand": candidate["brand"],
                "brand_key": candidate["brand_key"],
                "source": "open_food_facts",
                "serving_g": candidate["serving_g"],
                "serving_desc": candidate["serving_desc"],
                "portion_basis": candidate["portion_basis"],
                "serving_source": candidate["serving_source"],
                "barcode": candidate["barcode"],
            }
            index_food_record(indexes, row_id)
            summary["inserted"] += 1

            if line_number % 100000 == 0:
                print(
                    "  OFF progress:"
                    f" seen={summary['seen']:,}"
                    f" merged={summary['merged']:,}"
                    f" inserted={summary['inserted']:,}"
                    f" skipped={summary['skipped']:,}"
                )

    conn.commit()
    print(
        "Open Food Facts:"
        f" merged {summary['merged']:,},"
        f" inserted {summary['inserted']:,},"
        f" matched-no-change {summary['matched_without_change']:,},"
        f" skipped {summary['skipped']:,},"
        f" invalid {summary['invalid']:,}"
    )
    return summary


def build_fts_index(conn):
    """Populate the FTS5 index from the foods table."""
    conn.execute("INSERT INTO foods_fts(foods_fts) VALUES('rebuild')")
    conn.commit()
    print("FTS5 index built")


def write_metadata(conn, sr_count, foundation_count, fndds_count, branded_count, off_summary):
    total_foods = conn.execute("SELECT COUNT(*) FROM foods").fetchone()[0]
    values = {
        "total_foods": str(total_foods),
        "build_date": conn.execute("SELECT date('now')").fetchone()[0],
        "sr_legacy_count": str(sr_count),
        "foundation_count": str(foundation_count),
        "survey_fndds_count": str(fndds_count),
        "reference_data_version": "foundation-2026-04-30;fndds-2021-2023",
        "branded_count": str(branded_count),
        "open_food_facts_seen": str(off_summary["seen"]),
        "open_food_facts_merged": str(off_summary["merged"]),
        "open_food_facts_inserted": str(off_summary["inserted"]),
        "open_food_facts_skipped": str(off_summary["skipped"]),
        "open_food_facts_path": off_summary["path"] or "",
    }

    for key, value in values.items():
        conn.execute("INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)", (key, value))
    conn.commit()
    return total_foods


def main():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)

    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)

    conn = sqlite3.connect(DB_PATH)
    configure_connection(conn)

    print("Creating schema...")
    create_schema(conn)

    print("Inserting SR Legacy...")
    sr_json = discover_single_json(SR_LEGACY_DIR)
    if not sr_json:
        raise RuntimeError("SR Legacy JSON is missing")
    sr_count = insert_reference_foods(
        conn, sr_json, "SRLegacyFoods", "sr_legacy"
    )["inserted"]

    foundation_json = discover_single_json(FOUNDATION_DIR)
    fndds_json = discover_single_json(FNDDS_DIR)
    if not foundation_json or not fndds_json:
        raise RuntimeError(
            "USDA Foundation and FNDDS JSON are required. Run rebuild_full_db.py to download them."
        )
    foundation_count = insert_reference_foods(
        conn, foundation_json, "FoundationFoods", "foundation"
    )["inserted"]
    fndds_count = insert_reference_foods(
        conn, fndds_json, "SurveyFoods", "survey_fndds"
    )["inserted"]

    print("Inserting Branded Foods...")
    branded_count = insert_branded(conn)

    print("Merging Open Food Facts...")
    off_summary = merge_open_food_facts(conn)

    print("Building FTS5 index...")
    rebuild_search_index(conn)

    total_foods = write_metadata(
        conn, sr_count, foundation_count, fndds_count, branded_count, off_summary
    )
    conn.close()

    size_mb = os.path.getsize(DB_PATH) / (1024 * 1024)
    print(f"\nDone. Database: {DB_PATH} ({size_mb:.1f} MB)")
    print(f"Total foods: {total_foods:,}")


if __name__ == "__main__":
    main()
