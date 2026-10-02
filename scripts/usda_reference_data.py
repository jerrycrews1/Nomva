#!/usr/bin/env python3
"""Shared USDA reference-food import and search-index helpers for Nomva."""

import json
import math
import os
import re


MICRONUTRIENT_IDS = {
    "saturated_fat_g": 1258,
    "trans_fat_g": 1257,
    "cholesterol_mg": 1253,
    "added_sugar_g": 1235,
    "calcium_mg": 1087,
    "iron_mg": 1089,
    "potassium_mg": 1092,
    "vitamin_a_mcg_rae": 1106,
    "vitamin_c_mg": 1162,
    "vitamin_b12_mcg": 1178,
    "folate_mcg_dfe": 1190,
    "magnesium_mg": 1090,
    "zinc_mg": 1095,
}

HOUSEHOLD_PORTION_WEIGHTS = {
    "cup": 16,
    "tablespoon": 14,
    "tbsp": 14,
    "teaspoon": 12,
    "tsp": 12,
    "medium": 20,
    "regular": 20,
    "fruit": 22,
    "slice": 11,
    "piece": 11,
    "fillet": 11,
    "patty": 11,
    "sandwich": 11,
    "bowl": 10,
    "small": 9,
    "large": 9,
    "ounce": 18,
    "oz": 18,
    "fl oz": 18,
}

PORTION_REJECTION_PHRASES = {
    "quantity not specified",
    "amount not specified",
    "undetermined",
    "not specified",
    "racc",
}

PORTION_PACKAGE_WORDS = {
    "bag", "bottle", "box", "bunch", "can", "carton", "container",
    "jar", "loaf", "package", "packages", "pkg", "tray",
}

INSERT_COLUMNS = (
    "fdc_id", "name", "brand", "source", "search_terms", "serving_g",
    "serving_desc", "portion_basis", "serving_source", "default_serving_g",
    "default_serving_desc", "default_serving_source", "calories",
    "protein_g", "carbs_g", "fat_g", "fiber_g", "sugar_g", "sodium_mg",
    "saturated_fat_g", "trans_fat_g", "cholesterol_mg", "added_sugar_g",
    "vitamin_d_mcg", "calcium_mg", "iron_mg", "potassium_mg",
    "vitamin_a_mcg_rae", "vitamin_c_mg", "vitamin_b12_mcg",
    "folate_mcg_dfe", "magnesium_mg", "zinc_mg", "barcode",
)


def safe_float(value):
    if value in (None, "") or isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
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
    return text.title() if text.isupper() or text.islower() else text


def nutrient_value(nutrients, nutrient_id):
    for item in nutrients or []:
        if (item.get("nutrient") or {}).get("id") == nutrient_id:
            return safe_float(item.get("amount"))
    return None


def first_nutrient_value(nutrients, nutrient_ids):
    for nutrient_id in nutrient_ids:
        value = nutrient_value(nutrients, nutrient_id)
        if value is not None:
            return value
    return None


# Most Foundation Foods report kcal only as Atwater energy (2048 specific,
# 2047 general), never as 1008. Specific factors match how SR Legacy computed
# 1008, so they come first.
ENERGY_KCAL_IDS = (1008, 2048, 2047)
# Foundation Foods publish total sugars as 1063 rather than 2000.
TOTAL_SUGAR_IDS = (2000, 1063)


def per_serving(amount_per_100g, serving_g):
    amount = safe_float(amount_per_100g)
    grams = safe_float(serving_g)
    if amount is None:
        return None
    return amount if grams is None or grams <= 0 else amount * grams / 100.0


def _portion_amount(portion):
    for key in ("amount", "value"):
        amount = safe_float(portion.get(key))
        if amount is not None and amount > 0:
            return amount
    return 1.0


def _display_number(number):
    return str(int(number)) if abs(number - round(number)) < 0.001 else f"{number:g}"


def _pluralize_measure(measure, amount):
    if abs(amount - 1) < 0.001:
        return measure
    irregular = {"inch": "inches", "leaf": "leaves", "loaf": "loaves"}
    if measure in irregular:
        return irregular[measure]
    if measure.endswith("s"):
        return measure
    return f"{measure}s"


def portion_description(portion):
    explicit = normalize_whitespace(portion.get("portionDescription"))
    if explicit:
        return explicit

    modifier = (normalize_whitespace(portion.get("modifier")) or "").rstrip(",;: ")  # USDA has "cup,"
    if modifier and not modifier.isdigit():
        if re.match(r"^[\d¼½¾⅐⅑⅒⅓⅔⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞]", modifier):
            return modifier
        return f"{_display_number(_portion_amount(portion))} {modifier.lower()}"

    measure = normalize_whitespace((portion.get("measureUnit") or {}).get("name"))
    if not measure:
        return None
    amount = _portion_amount(portion)
    measure = _pluralize_measure(measure.lower(), amount)
    return f"{_display_number(amount)} {measure}"


def choose_natural_serving(portions):
    portions = portions or []
    has_fluid_ounce_measure = any(
        re.search(r"\b(?:fl\s*oz|fluid\s+ounces?)\b", (portion_description(portion) or "").lower())
        for portion in portions
    )
    has_aggregate_household_measure = any(
        re.search(r"\b(?:cup|ounces?|oz|tablespoons?|tbsp)\b", (portion_description(portion) or "").lower())
        for portion in portions
    )
    best = None
    best_score = -10_000
    for portion in portions or []:
        grams = safe_float(portion.get("gramWeight"))
        description = portion_description(portion)
        if grams is None or grams <= 0 or not description:
            continue

        normalized = description.lower()
        score = 0
        if any(phrase in normalized for phrase in PORTION_REJECTION_PHRASES):
            score -= 100
        has_explicit_size = bool(re.search(
            r"\b\d+(?:\.\d+)?\s*(?:fl\s*)?(?:oz|ounce|ounces|g|gram|grams|ml)\b",
            normalized,
        ))
        if has_explicit_size:
            score += 8
        if "yields" in normalized or "yield after" in normalized:
            score -= 25
        if not has_explicit_size and any(
            re.search(rf"\b{re.escape(word)}\b", normalized)
            for word in PORTION_PACKAGE_WORDS
        ):
            score -= 25
        if (has_aggregate_household_measure
                and grams < 25
                and re.match(r"^1\s+(?:fruit|berry)\b", normalized)):
            # A single tiny fruit is a conversion unit, but a poor default for
            # an unspecified aggregate food when USDA also publishes a cup.
            score -= 15
        # Aliases overlap (for example, "fl oz" also contains "oz"). Treat
        # household labels as one scoring signal so an alias-rich description
        # cannot outrank a more natural first-choice serving by double counting.
        household_weight = max((
            weight
            for phrase, weight in HOUSEHOLD_PORTION_WEIGHTS.items()
            if re.search(rf"\b{re.escape(phrase)}\b", normalized)
        ), default=0)
        if has_fluid_ounce_measure and re.search(r"\bcup\b", normalized):
            # For liquids, an official cup is a more useful everyday default
            # than one fluid ounce. Keep this contextual so cup-based recipe
            # conversions do not replace natural item servings for solid food.
            household_weight += 10
        score += household_weight
        if 20 <= grams <= 120:
            score += 10
        elif 5 <= grams <= 350:
            score += 6
        elif grams <= 600:
            score += 3
        else:
            score -= 4
        sequence = safe_float(portion.get("sequenceNumber"))
        if sequence == 1:
            score += 7
        elif sequence is not None:
            score += max(0, 4 - int(sequence))

        if score > best_score:
            best = (grams, description)
            best_score = score

    if best and best_score >= 8:
        return best[0], best[1], "explicit_serving"
    return 100.0, "100 g", "fallback_raw"


def _legacy_portion_label(portion):
    """The label older catalogs stored, e.g. "1 cup, chopped or diced" for half a cup."""
    raw = (
        normalize_whitespace(portion.get("portionDescription"))
        or normalize_whitespace(portion.get("modifier"))
        or normalize_whitespace((portion.get("measureUnit") or {}).get("name"))
    )
    raw = re.sub(r"^[\s,;:()]+|[\s,;:()]+$", "", raw or "")
    if not raw:
        return None
    return raw if re.match(r"^\d", raw) else f"1 {raw.lower()}"


def keep_previous_serving(portions, previous):
    """Reuse the serving an earlier catalog chose for this food, relabelled from source.

    A rebuild refreshes data but must not change what an unquantified "egg" or
    "broccoli" logs as; only foods new to the catalog use choose_natural_serving.
    previous is {"serving_g", "serving_desc", "serving_source"}. Returns None
    when the source no longer offers that portion.
    """
    grams = safe_float(previous.get("serving_g"))
    if grams is None or grams <= 0:
        return None
    if previous.get("serving_source") == "fallback_raw":
        # Keep "100g"-style labels; any other label was stamped on by an
        # Open Food Facts product match in older builds.
        label = (previous.get("serving_desc") or "").strip()
        return grams, label if re.fullmatch(r"100\s?g", label) else "100 g", "fallback_raw"
    matches = [
        portion for portion in portions or []
        if math.isclose(safe_float(portion.get("gramWeight")) or -1, grams, rel_tol=0, abs_tol=1e-6)
        and portion_description(portion)
    ]
    if len(matches) > 1:
        # Same grams, different labels: prefer the portion the stored label names.
        label = previous.get("serving_desc")
        named = [
            portion for portion in matches
            if label and label in (portion_description(portion), _legacy_portion_label(portion))
        ]
        matches = sorted(named or matches, key=lambda portion: safe_float(portion.get("sequenceNumber")) or float("inf"))
    if not matches:
        return None
    return grams, portion_description(matches[0]), "explicit_serving"


def choose_default_serving(portions, serving_g, serving_desc, source):
    """Keep FNDDS's likely consumed amount separate from unit conversions."""
    base_grams = safe_float(serving_g)
    base_desc = normalize_whitespace(serving_desc) or "1 serving"
    if source != "survey_fndds" or base_grams is None or base_grams <= 0:
        return base_grams, base_desc, "natural_serving"

    qns = None
    for portion in portions or []:
        grams = safe_float(portion.get("gramWeight"))
        description = (portion_description(portion) or "").lower()
        if grams is None or grams <= 0:
            continue
        if "quantity not specified" in description or "amount not specified" in description:
            qns = grams
            break

    if qns is None:
        return base_grams, base_desc, "natural_serving"

    same_amount = abs(qns - base_grams) / base_grams <= 0.05
    return (
        qns,
        base_desc if same_amount else "1 estimated serving",
        "survey_qns",
    )


def _unique_text(values, maximum=2_000):
    unique = []
    seen = set()
    for value in values:
        text = normalize_whitespace(value)
        if not text:
            continue
        key = text.lower()
        if key in seen:
            continue
        seen.add(key)
        unique.append(text)
    return " | ".join(unique)[:maximum]


def food_search_terms(food):
    terms = []
    category = food.get("foodCategory") or {}
    terms.append(category.get("description"))
    wweia = food.get("wweiaFoodCategory") or {}
    terms.append(wweia.get("wweiaFoodCategoryDescription"))

    for input_food in food.get("inputFoods") or []:
        terms.append(input_food.get("foodDescription"))
        terms.append(input_food.get("ingredientDescription"))

    for attribute in food.get("foodAttributes") or []:
        if str(attribute.get("name") or "").lower() in {
            "additional food description", "wweia category description",
        }:
            terms.append(attribute.get("value"))
    return _unique_text(terms)


def _vitamin_d(nutrients):
    micrograms = nutrient_value(nutrients, 1114)
    if micrograms is not None:
        return micrograms
    iu = nutrient_value(nutrients, 1110)
    return None if iu is None else iu / 40.0


def food_record(food, source, previous=None):
    """Return INSERT_COLUMNS values, or None. previous: this food's row in the replaced catalog."""
    if not isinstance(food, dict):
        return None
    nutrients = food.get("foodNutrients") or []
    portions = food.get("foodPortions") or []
    kept = keep_previous_serving(portions, previous) if previous else None
    serving_g, serving_desc, serving_source = kept or choose_natural_serving(portions)
    if kept and previous.get("default_serving_g") is None:
        default_serving_g = default_serving_desc = default_serving_source = None
    else:
        default_serving_g, default_serving_desc, default_serving_source = choose_default_serving(
            portions, serving_g, serving_desc, source
        )
    calories = per_serving(first_nutrient_value(nutrients, ENERGY_KCAL_IDS), serving_g)
    if calories is None:
        return None

    micros = {
        column: per_serving(nutrient_value(nutrients, nutrient_id), serving_g)
        for column, nutrient_id in MICRONUTRIENT_IDS.items()
    }
    micros["vitamin_d_mcg"] = per_serving(_vitamin_d(nutrients), serving_g)
    values = {
        "fdc_id": food.get("fdcId"),
        "name": prettify_label(food.get("description")) or "Unknown Food",
        "brand": None,
        "source": source,
        "search_terms": food_search_terms(food),
        "serving_g": serving_g,
        "serving_desc": serving_desc,
        "portion_basis": "grams",
        "serving_source": serving_source,
        "default_serving_g": default_serving_g,
        "default_serving_desc": default_serving_desc,
        "default_serving_source": default_serving_source,
        "calories": calories,
        "protein_g": per_serving(nutrient_value(nutrients, 1003), serving_g),
        "carbs_g": per_serving(nutrient_value(nutrients, 1005), serving_g),
        "fat_g": per_serving(nutrient_value(nutrients, 1004), serving_g),
        "fiber_g": per_serving(nutrient_value(nutrients, 1079), serving_g),
        "sugar_g": per_serving(first_nutrient_value(nutrients, TOTAL_SUGAR_IDS), serving_g),
        "sodium_mg": per_serving(nutrient_value(nutrients, 1093), serving_g),
        "barcode": None,
        **micros,
    }
    return tuple(values[column] for column in INSERT_COLUMNS)


_EXPORT_ARRAY_START = re.compile(r'\s*(?:\{\s*"([^"]+)"\s*:\s*)?\[')
_EXPORT_SEPARATORS = re.compile(r"[\s,]*")
_MAX_FOOD_CHARS = 64 * 1024 * 1024


def iter_usda_foods(json_path, root_key, chunk_size=1024 * 1024):
    """Yield the foods in a FoodData Central JSON export one at a time.

    Exports are {"<root_key>": [food, food, ...]}. json.load on the 3+ GB
    Branded Foods file needs ~17 GB of RAM, more than GitHub's 16 GB runner
    has, so decode one array element at a time and keep memory flat.
    """
    decoder = json.JSONDecoder()
    with open(json_path, "r", encoding="utf-8-sig") as stream:
        buffer = stream.read(chunk_size)
        while "[" not in buffer and len(buffer) < 4096:
            more = stream.read(chunk_size)
            if not more:
                break
            buffer += more
        start = _EXPORT_ARRAY_START.match(buffer)
        if not start:
            raise ValueError(f"{json_path}: not a FoodData Central JSON export")
        if start.group(1) not in (None, root_key):
            raise ValueError(f"{json_path}: expected {root_key}, found {start.group(1)}")
        position = start.end()
        yielded = 0
        while True:
            position = _EXPORT_SEPARATORS.match(buffer, position).end()
            if position < len(buffer) and buffer[position] == "]":
                return
            try:
                food, position = decoder.raw_decode(buffer, position)
            except json.JSONDecodeError:
                # Usually the chunk ended mid-food: read more and retry.
                more = stream.read(chunk_size)
                if not more or len(buffer) - position > _MAX_FOOD_CHARS:
                    raise ValueError(
                        f"{json_path}: malformed or truncated export after {yielded:,} foods"
                    ) from None
                buffer = buffer[position:] + more
                position = 0
                continue
            yielded += 1
            yield food


def ensure_search_schema(connection):
    columns = {row[1] for row in connection.execute("PRAGMA table_info(foods)")}
    if "search_terms" not in columns:
        connection.execute("ALTER TABLE foods ADD COLUMN search_terms TEXT")
    if "default_serving_g" not in columns:
        connection.execute("ALTER TABLE foods ADD COLUMN default_serving_g REAL")
    if "default_serving_desc" not in columns:
        connection.execute("ALTER TABLE foods ADD COLUMN default_serving_desc TEXT")
    if "default_serving_source" not in columns:
        connection.execute("ALTER TABLE foods ADD COLUMN default_serving_source TEXT")

    connection.execute("DROP TABLE IF EXISTS foods_fts")
    connection.execute("""
        CREATE VIRTUAL TABLE foods_fts USING fts5(
            name,
            brand,
            search_terms,
            content='foods',
            content_rowid='id'
        )
    """)


def insert_reference_foods(connection, json_path, root_key, source, update_existing=False,
                           previous_rows=None):
    """previous_rows maps fdc_id to that food's serving fields in the replaced catalog."""
    placeholders = ", ".join("?" for _ in INSERT_COLUMNS)
    columns = ", ".join(INSERT_COLUMNS)
    if update_existing:
        assignments = ", ".join(
            f"{column}=excluded.{column}" for column in INSERT_COLUMNS if column != "fdc_id"
        )
        statement = (
            f"INSERT INTO foods ({columns}) VALUES ({placeholders}) "
            f"ON CONFLICT(fdc_id) DO UPDATE SET {assignments}"
        )
    else:
        statement = f"INSERT OR IGNORE INTO foods ({columns}) VALUES ({placeholders})"
    inserted = 0
    skipped = 0
    previous_rows = previous_rows or {}
    for food in iter_usda_foods(json_path, root_key):
        previous = previous_rows.get(food.get("fdcId")) if isinstance(food, dict) else None
        record = food_record(food, source, previous)
        if record is None:
            skipped += 1
            continue
        before = connection.total_changes
        connection.execute(statement, record)
        inserted += connection.total_changes - before
    return {"inserted": inserted, "skipped": skipped}


def rebuild_search_index(connection):
    connection.execute("INSERT INTO foods_fts(foods_fts) VALUES('rebuild')")
    connection.execute("ANALYZE")


def discover_single_json(directory):
    if not directory or not os.path.isdir(directory):
        return None
    matches = []
    for root, _, files in os.walk(directory):
        matches.extend(os.path.join(root, name) for name in files if name.endswith(".json"))
    return max(matches, key=os.path.getsize) if matches else None
