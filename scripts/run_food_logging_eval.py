#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
from dataclasses import dataclass, field
from pathlib import Path


FILLER_WORDS = {
    "a", "an", "the", "for", "at", "to", "of", "and", "with", "i", "had",
    "ate", "drank", "this", "that", "it", "was", "just", "my", "me", "please",
    "no", "yes", "item", "items", "dude", "actually", "instead", "meant", "wasn", "t",
    "log", "logged", "from", "about",
}
MEAL_WORDS = {"breakfast", "lunch", "dinner", "snack"}
COUNT_WORDS = {"one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "couple", "pair", "double"}
UNIT_WORDS = {
    "cup", "cups", "bowl", "bowls", "slice", "slices", "piece", "pieces", "serving", "servings",
    "oz", "ounce", "ounces", "gram", "grams", "g", "lb", "lbs", "small", "medium", "large",
    "tablespoon", "tablespoons", "tbsp", "teaspoon", "teaspoons", "tsp", "bottle", "bottles", "can", "cans",
}
PREPARATION_WORDS = {
    "raw", "cooked", "fried", "baked", "grilled", "roasted", "plain", "instant", "dehydrated",
    "dried", "powder", "chips", "juice", "smoothie", "drink", "mix", "bar", "candy", "pudding",
    "bread", "muffin", "flavored", "chocolate", "yogurt", "yoghurt",
}
SUSPICIOUS_FORM_WORDS = [
    "dehydrated", "dried", "powder", "chips", "juice", "drink", "smoothie", "mix", "bar", "candy",
    "pudding", "bread", "muffin", "pepper", "syrup", "sauce", "mustard", "gelatin", "dessert",
    "cookie", "oatmeal", "cereal", "granola", "waffle", "waffles", "cream", "flavored", "shake",
    "yogurt", "yoghurt", "protein",
]
NUTRITION_MODIFIER_WORDS = {"low", "light", "lite", "reduced", "lean", "skinless", "fat", "free", "nonfat", "non", "diet"}
WHOLE_FOOD_NEUTRAL_WORDS = {"raw", "plain", "fresh"}
BASE_DESCRIPTOR_WORDS = {"pork", "beef", "whole", "cured", "uncured", "prepared", "unprepared", "cooked", "baked", "fried", "raw", "plain", "fresh"}
VARIANT_QUALIFIER_WORDS = {
    "meatless", "vegetarian", "vegan", "white", "yolk", "duck", "goose", "quail", "turkey", "canadian",
    "bit", "wrapped", "ranch", "maple", "onion", "jam", "sauce",
    "dressing", "pizza", "bean", "cheddar", "smoky", "club",
    "original", "center", "cut", "style", "grease", "salad", "cobb", "kids", "kid", "meal", "medium", "large", "small",
}


@dataclass
class Candidate:
    row_id: int
    fdc_id: int | None
    name: str
    brand: str | None
    source: str | None
    serving_g: float | None
    serving_desc: str | None
    calories: float
    protein_g: float
    carbs_g: float
    fat_g: float
    fiber_g: float
    sugar_g: float
    sodium_mg: float
    barcode: str | None
    portion_basis: str | None
    serving_source: str | None
    score: int = 0
    confidence: float = 0.0
    notes: list[str] = field(default_factory=list)


def tokenize(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", text.lower().replace("%", ""))


def meaningful_tokens(text: str) -> list[str]:
    return [token for token in tokenize(text) if token not in FILLER_WORDS and token not in MEAL_WORDS]


def identity_tokens(text: str) -> list[str]:
    return [
        token for token in meaningful_tokens(text)
        if not token.isdigit() and token not in COUNT_WORDS and token not in UNIT_WORDS
    ]


def singularize(token: str) -> str:
    if token.endswith("ies") and len(token) > 3:
        return token[:-3] + "y"
    if token.endswith("s") and len(token) > 3 and not token.endswith("ss"):
        return token[:-1]
    return token


def normalize_for_comparison(text: str) -> str:
    return " ".join(meaningful_tokens(text))


def normalize_search_text(text: str) -> str:
    return " ".join(identity_tokens(text))


def looks_like_generic_food_query(query: str) -> bool:
    tokens = identity_tokens(query)
    return bool(tokens) and len(tokens) <= 4 and not any(token in PREPARATION_WORDS for token in tokens)


def looks_like_plain_whole_food_query(query: str) -> bool:
    tokens = identity_tokens(query)
    return bool(tokens) and len(tokens) <= 2 and not any(token in PREPARATION_WORDS for token in tokens)


def is_count_based(query: str) -> bool:
    tokens = tokenize(query)
    return any(token.isdigit() or token in COUNT_WORDS for token in tokens) and not any(token in UNIT_WORDS for token in tokens)


def is_plain_coffee_query(query: str) -> bool:
    return {singularize(token) for token in identity_tokens(query)} == {"coffee"}


def is_ambiguous_plain_coffee_candidate(candidate: Candidate) -> bool:
    candidate_tokens = {singularize(token) for token in meaningful_tokens(candidate.name)}
    if candidate_tokens != {"coffee"}:
        return False
    if candidate.source == "recent" and candidate.calories > 25:
        return True
    density = calorie_density(candidate)
    return density is not None and density > 20


def inferred_serving_unit(query: str) -> str:
    tokens = {singularize(token) for token in tokenize(query)}
    for unit in ["nugget", "fry", "egg", "slice", "piece", "cup"]:
        if unit in tokens:
            return unit
    return "serving"


def requested_count(query: str) -> float | None:
    words = {
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "couple": 2, "pair": 2,
    }
    for token in tokenize(query):
        if token.isdigit():
            return float(token)
        if token in words:
            return float(words[token])
    return None


def count_represented_by_fixed_serving(candidate: Candidate, unit: str) -> float | None:
    singular_unit = singularize(unit.lower())
    if singular_unit not in {"nugget", "piece", "strip", "slice"}:
        return None
    tokens = tokenize(f"{candidate.name} {candidate.serving_desc or ''}")
    for index in range(len(tokens) - 1):
        try:
            value = float(tokens[index])
        except ValueError:
            continue
        if value <= 0:
            continue
        following = [singularize(token) for token in tokens[index + 1:index + 6]]
        if singular_unit in following:
            return value
    return None


def query_overlap_score(query: str, candidate_name: str, brand: str | None) -> int:
    query_tokens = {singularize(token) for token in identity_tokens(query)}
    name_tokens = {singularize(token) for token in meaningful_tokens(candidate_name)}
    brand_tokens = {singularize(token) for token in meaningful_tokens(brand or "")}
    return len(query_tokens.intersection(name_tokens.union(brand_tokens)))


def edit_distance_limited(left: str, right: str, max_distance: int = 1) -> int:
    if left == right:
        return 0
    if abs(len(left) - len(right)) > max_distance:
        return max_distance + 1
    previous = list(range(len(right) + 1))
    current = [0] * (len(right) + 1)
    for i, left_char in enumerate(left, start=1):
        current[0] = i
        row_min = current[0]
        for j, right_char in enumerate(right, start=1):
            substitution = previous[j - 1] + (0 if left_char == right_char else 1)
            insertion = current[j - 1] + 1
            deletion = previous[j] + 1
            current[j] = min(substitution, insertion, deletion)
            row_min = min(row_min, current[j])
        if row_min > max_distance:
            return max_distance + 1
        previous, current = current, previous
    return previous[len(right)]


def fuzzy_query_overlap_score(query_tokens: set[str], candidate_tokens: set[str]) -> int:
    total = 0
    for query_token in query_tokens:
        if query_token in candidate_tokens:
            continue
        if any(edit_distance_limited(query_token, candidate_token, 1) <= 1 for candidate_token in candidate_tokens):
            total += 1
    return total


def extra_concept_tokens(candidate_name: str, query: str) -> list[str]:
    query_tokens = {singularize(token) for token in identity_tokens(query)}
    candidate_tokens = [singularize(token) for token in meaningful_tokens(candidate_name)]
    extras: list[str] = []
    for token in candidate_tokens:
        if token in query_tokens or token in WHOLE_FOOD_NEUTRAL_WORDS:
            continue
        fuzzy_matched = any(
            len(token) >= 4 and len(query_token) >= 4 and edit_distance_limited(token, query_token, 1) <= 1
            for query_token in query_tokens
        )
        if not fuzzy_matched:
            extras.append(token)
    return extras


def is_literal_whole_food_match(candidate: Candidate, query: str) -> bool:
    if not looks_like_plain_whole_food_query(query):
        return False
    if is_plain_coffee_query(query) and is_ambiguous_plain_coffee_candidate(candidate):
        return False
    if candidate.brand:
        return False
    if candidate.source == "open_food_facts" and len(meaningful_tokens(candidate.name)) == 1:
        return False
    if candidate.source and "branded" in candidate.source:
        return False
    query_tokens = {singularize(token) for token in identity_tokens(query)}
    candidate_tokens = {singularize(token) for token in meaningful_tokens(candidate.name)}
    return bool(query_tokens) and query_tokens.issubset(candidate_tokens) and not extra_concept_tokens(candidate.name, query)


def is_simple_generic_base_match(candidate: Candidate, query: str) -> bool:
    if not looks_like_plain_whole_food_query(query):
        return False
    if is_plain_coffee_query(query) and is_ambiguous_plain_coffee_candidate(candidate):
        return False
    if candidate.brand:
        return False
    if candidate.source == "open_food_facts" and len(meaningful_tokens(candidate.name)) == 1:
        return False
    query_tokens = {singularize(token) for token in identity_tokens(query)}
    candidate_tokens = {singularize(token) for token in meaningful_tokens(candidate.name)}
    if not query_tokens or not query_tokens.issubset(candidate_tokens):
        return False
    extras = extra_concept_tokens(candidate.name, query)
    if not extras:
        return True
    if any(token in VARIANT_QUALIFIER_WORDS for token in extras):
        return False
    return all(token in BASE_DESCRIPTOR_WORDS for token in extras)


def search_variants(query: str) -> list[str]:
    raw_tokens = meaningful_tokens(query)
    core_tokens = identity_tokens(query)
    variants: list[str] = []
    if core_tokens:
        variants.append(" ".join(core_tokens))
    singular = [singularize(token) for token in core_tokens]
    if singular:
        variants.append(" ".join(singular))
    normalized = normalize_search_text(query)
    if normalized:
        variants.append(normalized)
    if looks_like_generic_food_query(query):
        base = singular or core_tokens
        if base:
            variants.append(" ".join(base) + " raw")
    if len(core_tokens) >= 3:
        variants.append(" ".join(core_tokens[1:]))
    if len(core_tokens) >= 2:
        for index in range(len(core_tokens)):
            reduced = [token for idx, token in enumerate(core_tokens) if idx != index]
            if reduced:
                variants.append(" ".join(reduced))
    variants.extend(food_family_search_variants(core_tokens))
    unique: list[str] = []
    for variant in variants:
        variant = variant.strip()
        if variant and variant not in unique:
            unique.append(variant)
    return unique


def food_family_search_variants(tokens: list[str]) -> list[str]:
    singular_tokens = {singularize(token) for token in tokens}
    variants: list[str] = []

    mentions_chickfila = "chick" in singular_tokens and "fil" in singular_tokens
    mentions_chicken = "chicken" in singular_tokens or mentions_chickfila
    mentions_nuggets = "nugget" in singular_tokens
    mentions_fries = "fry" in singular_tokens or "frie" in singular_tokens
    mentions_waffle = "waffle" in singular_tokens or mentions_chickfila

    if mentions_nuggets and mentions_chicken:
        variants.append("chicken nuggets")
    elif mentions_nuggets and len(tokens) == 1:
        variants.append("chicken nuggets")

    if mentions_fries and mentions_waffle:
        variants.append("waffle fries")
    elif mentions_fries and len(tokens) <= 2:
        variants.append("french fries")

    if "egg" in singular_tokens:
        variants.append("whole egg")

    if "spinach" in singular_tokens:
        variants.append("spinach raw")

    if "coffee" in singular_tokens:
        variants.append("black coffee")

    return variants


def calorie_density(candidate: Candidate) -> float | None:
    if candidate.portion_basis != "grams" or not candidate.serving_g or candidate.serving_g <= 0 or candidate.calories <= 0:
        return None
    return candidate.calories / candidate.serving_g * 100.0


def median(values: list[float]) -> float:
    ordered = sorted(values)
    midpoint = len(ordered) // 2
    if len(ordered) % 2 == 0:
        return (ordered[midpoint - 1] + ordered[midpoint]) / 2.0
    return ordered[midpoint]


def should_apply_density_penalty(query: str) -> bool:
    return not any(token in NUTRITION_MODIFIER_WORDS for token in meaningful_tokens(query))


def serving_quality(candidate: Candidate) -> int:
    if candidate.serving_source == "explicit_serving":
        return 3
    if candidate.serving_source == "parsed_serving":
        return 2
    if candidate.serving_source == "fallback_raw":
        if (candidate.serving_desc or "").strip().lower() == "100g":
            return 0
        return 1
    return 0


def build_match_query(query: str) -> str:
    tokens = re.findall(r"[a-z0-9]+", query.lower().replace("%", "").replace('"', " "))
    if not tokens:
        return ""
    if len(tokens) == 1:
        return f"{tokens[0]}*"
    phrase = " ".join(tokens)
    all_terms = " AND ".join(f"{token}*" for token in tokens)
    return f'"{phrase}" OR {all_terms}'


def strict_search(conn: sqlite3.Connection, query: str, limit: int = 15) -> list[Candidate]:
    match_query = build_match_query(query)
    if not match_query:
        return []
    sql = """
        SELECT f.id, f.fdc_id, f.name, f.brand, f.source, f.serving_g, f.serving_desc,
               f.calories, f.protein_g, f.carbs_g, f.fat_g, f.fiber_g,
               f.sugar_g, f.sodium_mg, f.barcode, f.portion_basis, f.serving_source
        FROM foods f
        JOIN foods_fts ON foods_fts.rowid = f.id
        WHERE foods_fts MATCH ?
        ORDER BY CASE WHEN f.brand IS NULL OR f.brand = '' THEN 0 ELSE 1 END ASC, rank ASC
        LIMIT ?
    """
    return [Candidate(*row) for row in conn.execute(sql, (match_query, limit)).fetchall()]


def loose_search(conn: sqlite3.Connection, query: str, limit: int = 15) -> list[Candidate]:
    tokens = [token for token in tokenize(query) if token]
    if not tokens:
        return []
    where_clause = " AND ".join("(lower(f.name) LIKE ? OR lower(IFNULL(f.brand, '')) LIKE ?)" for _ in tokens)
    sql = f"""
        SELECT f.id, f.fdc_id, f.name, f.brand, f.source, f.serving_g, f.serving_desc,
               f.calories, f.protein_g, f.carbs_g, f.fat_g, f.fiber_g,
               f.sugar_g, f.sodium_mg, f.barcode, f.portion_basis, f.serving_source
        FROM foods f
        WHERE {where_clause}
        ORDER BY CASE WHEN f.brand IS NULL OR f.brand = '' THEN 0 ELSE 1 END ASC, LENGTH(f.name) ASC
        LIMIT ?
    """
    params: list[object] = []
    for token in tokens:
        like = f"%{token}%"
        params.extend([like, like])
    params.append(limit)
    return [Candidate(*row) for row in conn.execute(sql, params).fetchall()]


def score_candidate(candidate: Candidate, query: str) -> Candidate:
    candidate = Candidate(**candidate.__dict__)
    tokens = meaningful_tokens(query)
    normalized_query = normalize_for_comparison(query)
    name = normalize_for_comparison(candidate.name)
    brand = normalize_for_comparison(candidate.brand or "")
    generic_query = looks_like_generic_food_query(query)
    plain_whole_query = looks_like_plain_whole_food_query(query)
    query_has_prep = any(token in PREPARATION_WORDS for token in tokens)
    count_based = is_count_based(query)
    query_singular_tokens = {singularize(token) for token in identity_tokens(query)}
    candidate_singular_tokens = {singularize(token) for token in meaningful_tokens(candidate.name)}
    brand_singular_tokens = {singularize(token) for token in meaningful_tokens(candidate.brand or "")}
    mentions_chickfila = "chick" in query_singular_tokens and "fil" in query_singular_tokens
    has_unstated_menu_size = bool(candidate_singular_tokens.intersection({"small", "medium", "large"})) and not bool(
        query_singular_tokens.intersection({"small", "medium", "large"})
    )

    if name == normalized_query:
        candidate.score += 80
        candidate.notes.append("exact name match")
    elif normalized_query and name.startswith(normalized_query):
        candidate.score += 45
        candidate.notes.append("strong prefix match")

    overlap = query_overlap_score(query, candidate.name, candidate.brand)
    candidate.score += overlap * 12
    if overlap:
        candidate.notes.append(f"token overlap {overlap}")

    fuzzy_overlap = fuzzy_query_overlap_score(query_singular_tokens, candidate_singular_tokens.union(brand_singular_tokens))
    candidate.score += fuzzy_overlap * 30
    if fuzzy_overlap:
        candidate.notes.append(f"fuzzy token overlap {fuzzy_overlap}")

    if generic_query and not candidate.brand:
        candidate.score += 18
        candidate.notes.append("generic match for generic request")

    if generic_query and candidate.source and "sr_legacy" in candidate.source:
        candidate.score += 14
        candidate.notes.append("whole-food source")

    if generic_query and candidate.portion_basis == "fixed_serving":
        candidate.score -= 36
        candidate.notes.append("fixed serving penalized for generic request")

    if candidate.source == "open_food_facts" and not candidate.brand and len(meaningful_tokens(candidate.name)) == 1:
        candidate.score -= 160
        candidate.notes.append("anonymous one-word OFF row penalized")

    if generic_query and " raw" in name:
        candidate.score += 16
        candidate.notes.append("plain/raw form")

    if "coffee" in query_singular_tokens and "coffee" in candidate_singular_tokens:
        if "black" in candidate_singular_tokens:
            candidate.score += 60
            candidate.notes.append("black coffee default")
        for bad in {"candy", "honey", "nut", "cashew"}:
            if bad in candidate_singular_tokens and bad not in query_singular_tokens:
                candidate.score -= 50
                candidate.notes.append(f"coffee extra concept {bad}")

    if is_plain_coffee_query(query) and is_ambiguous_plain_coffee_candidate(candidate):
        candidate.score -= 220
        candidate.notes.append("ambiguous caloric coffee penalized")

    if mentions_chickfila and brand_singular_tokens and brand_singular_tokens.issubset(query_singular_tokens):
        food_tokens = query_singular_tokens - brand_singular_tokens
        food_token_matched = not food_tokens or any(
            token in candidate_singular_tokens
            or any(edit_distance_limited(token, candidate_token, 1) <= 1 for candidate_token in candidate_singular_tokens)
            for token in food_tokens
        )
        if food_token_matched:
            candidate.score += 70 if has_unstated_menu_size and count_based else 500
        else:
            candidate.score -= 250
        candidate.notes.append("brand and food identity matched" if food_token_matched else "brand matched wrong food identity")

    if (
        mentions_chickfila
        and "nugget" in query_singular_tokens
        and "chicken" in candidate_singular_tokens
        and "nugget" in candidate_singular_tokens
    ):
        candidate.score += 48
        candidate.notes.append("restaurant nugget family match")

    if (
        mentions_chickfila
        and "fry" in query_singular_tokens
        and "waffle" in candidate_singular_tokens
        and "fry" in candidate_singular_tokens
    ):
        candidate.score += 48
        candidate.notes.append("restaurant fries family match")

    if (
        mentions_chickfila
        and "fry" in query_singular_tokens
        and any(token in {"small", "medium", "large"} for token in candidate_singular_tokens)
        and not any(token in {"small", "medium", "large"} for token in query_singular_tokens)
    ):
        candidate.score -= 48
        candidate.notes.append("unstated menu size penalized")

    if count_based and candidate.serving_g is not None:
        if "100g" in (candidate.serving_desc or "").lower():
            candidate.score -= 36
            candidate.notes.append("100g serving penalized for count request")
        if candidate.serving_g < 15:
            candidate.score -= 28
            candidate.notes.append("tiny serving penalized for count-based request")
        elif candidate.serving_g >= 40:
            candidate.score += 8

    if count_based and candidate.portion_basis == "fixed_serving":
        requested_unit = inferred_serving_unit(query)
        represented_count = count_represented_by_fixed_serving(candidate, requested_unit)
        if represented_count is not None:
            candidate.score += 140
            if (count := requested_count(query)) is not None:
                candidate.score -= min(int(abs(represented_count - count) * 16), 160)
            candidate.notes.append("fixed serving count matches request")
        else:
            candidate.score -= 180
            candidate.notes.append("uncounted fixed serving penalized for count request")

    if count_based and has_unstated_menu_size and candidate.portion_basis == "fixed_serving":
        candidate.score -= 320
        candidate.notes.append("unstated fixed menu size penalized for count request")

    if not query_has_prep:
        for word in SUSPICIOUS_FORM_WORDS:
            if word in name and word not in normalized_query:
                candidate.score -= 16

    if not generic_query and brand and brand in normalized_query:
        candidate.score += 18
        candidate.notes.append("brand referenced")

    if generic_query or count_based:
        extras = extra_concept_tokens(candidate.name, query)
        variant_extras = [token for token in extras if token in VARIANT_QUALIFIER_WORDS]
        other_extras = [token for token in extras if token not in VARIANT_QUALIFIER_WORDS and token not in BASE_DESCRIPTOR_WORDS]
        if variant_extras:
            candidate.score -= min(len(variant_extras) * 22, 110)
            candidate.notes.append("generic variant extras: " + ",".join(variant_extras))
        if other_extras:
            candidate.score -= min(len(other_extras) * 14, 84)
            candidate.notes.append("generic extra concepts: " + ",".join(other_extras))

    if plain_whole_query:
        extras = extra_concept_tokens(candidate.name, query)
        variant_extras = [token for token in extras if token in VARIANT_QUALIFIER_WORDS]
        descriptor_extras = [token for token in extras if token in BASE_DESCRIPTOR_WORDS]
        other_extras = [token for token in extras if token not in VARIANT_QUALIFIER_WORDS and token not in BASE_DESCRIPTOR_WORDS]
        if variant_extras:
            candidate.score -= min(len(variant_extras) * 34, 102)
            candidate.notes.append("variant qualifiers: " + ",".join(variant_extras))
        if other_extras:
            candidate.score -= min(len(other_extras) * 18, 72)
            candidate.notes.append("extra concepts: " + ",".join(other_extras))
        if candidate.source and "sr_legacy" in candidate.source and not variant_extras and not other_extras and descriptor_extras:
            candidate.score += 28
            candidate.notes.append("simple generic base form")
        if candidate.brand:
            candidate.score -= 12
            candidate.notes.append("branded result penalized for plain whole-food query")
        if candidate.source and "branded" in candidate.source:
            candidate.score -= 10

    return candidate


def search_candidates(conn: sqlite3.Connection, query: str) -> list[Candidate]:
    merged: dict[int, Candidate] = {}
    for variant in search_variants(query):
        for candidate in strict_search(conn, variant) + loose_search(conn, variant):
            merged.setdefault(candidate.row_id, candidate)
    scored = [score_candidate(candidate, query) for candidate in merged.values()]
    if should_apply_density_penalty(query):
        densities = [value for candidate in scored if (value := calorie_density(candidate)) is not None and 20 <= value <= 900]
        if len(densities) >= 4:
            baseline = median(densities)
            if baseline > 0:
                for candidate in scored:
                    density = calorie_density(candidate)
                    if density is None:
                        continue
                    is_low_outlier = density < baseline * 0.45
                    is_high_outlier = density > baseline * 2.2
                    if not (is_low_outlier or is_high_outlier):
                        continue
                    if not candidate.brand and candidate.source != "open_food_facts":
                        continue
                    candidate.score -= 48 if is_low_outlier else 28
    scored.sort(key=lambda candidate: (-candidate.score, -serving_quality(candidate), candidate.name))
    if scored:
        for index, candidate in enumerate(scored):
            next_score = scored[index + 1].score if index + 1 < len(scored) else max(candidate.score - 12, 0)
            gap = max(candidate.score - next_score, 0)
            base = max(candidate.score, 0) / 120.0
            gap_bonus = (gap / 90.0) if index == 0 else 0.0
            candidate.confidence = max(0.05, min(0.99, base + gap_bonus))
    if looks_like_plain_whole_food_query(query):
        literal = [candidate for candidate in scored if is_literal_whole_food_match(candidate, query)]
        if literal:
            return literal
        simple_base = [candidate for candidate in scored if is_simple_generic_base_match(candidate, query)]
        if simple_base:
            return simple_base
    return scored


def contains_any(text: str, patterns: list[str]) -> bool:
    return any(pattern in text for pattern in patterns)


def contains_digit(text: str) -> bool:
    return any(character.isdigit() for character in text)


def numeric_matches(expected: object, actual: object, tolerance: float = 0.1) -> bool:
    try:
        expected_number = float(expected)
        actual_number = float(actual)
    except (TypeError, ValueError):
        return False
    return abs(actual_number - expected_number) <= tolerance


def classify_intent(text: str) -> str:
    lower = text.lower()
    mentions_goals = contains_any(lower, ["goal", "goals", "target", "targets", "macro", "macros", "calorie goal", "protein goal", "daily goal"])
    mentions_goal_fields = contains_any(lower, ["calories", "protein", "carbs", "fat", "fiber", "macro", "macros", "goal", "goals", "target", "targets"])
    has_goal_update_verb = contains_any(lower, ["set", "change", "update", "adjust", "increase", "decrease", "raise", "lower"])
    if (mentions_goals and contains_digit(lower)) or (has_goal_update_verb and mentions_goal_fields):
        return "goal_update"
    if contains_any(lower, ["weigh", "weight", "lbs", "pounds"]) and contains_any(lower, ["i am", "i'm", "i weigh", "weighed", "weight is", "my weight"]):
        return "weight_log"
    if contains_any(lower, ["delete", "remove", "clear"]) and contains_any(lower, ["breakfast", "lunch", "dinner", "snack", "entry", "entries", "log"]):
        return "food_delete"
    if contains_any(lower, ["change", "edit", "update", "replace", "fix"]) and contains_any(lower, ["breakfast", "lunch", "dinner", "snack", "entry", "logged", "that", "this"]):
        return "food_edit"
    if contains_any(lower, ["wrong", "not right", "that wasn't", "actually", "meant", "instead"]):
        return "food_correction"
    if contains_any(lower, ["what did i", "how many", "show me", "did i", "history", "trend", "goal", "goals", "weight trend", "yesterday", "today", "this week", "last week"]):
        return "data_query"
    if contains_any(lower, ["i had", "for breakfast", "for lunch", "for dinner", "for snack", "i ate", "i drank", "had ", "ate ", "drank "]):
        return "food_logging"
    return "general_reply"


def should_reuse_session(existing_status: str, existing_intent: str, utterance: str) -> bool:
    if existing_status != "awaiting_clarification" or not existing_intent:
        return False

    standalone = classify_intent(utterance)
    if standalone != "general_reply":
        if standalone == existing_intent:
            return True
        if standalone == "food_correction" and existing_intent == "food_logging":
            return True
        return False

    tokens = tokenize(utterance)
    if not tokens:
        return False
    if len(tokens) <= 6:
        return True

    reply_signals = {
        "yes", "no", "with", "without", "just", "plain", "normal", "small",
        "medium", "large", "it", "was", "and", "plus",
    }
    return any(token in reply_signals or token in COUNT_WORDS or token in UNIT_WORDS or token.isdigit() for token in tokens)


def default_paths(repo_root: Path) -> tuple[Path, Path]:
    db_candidates = [
        repo_root / "Nomva" / "Resources" / "foods.sqlite",
        repo_root / "Resources" / "foods.sqlite",
    ]
    cases = repo_root / "scripts" / "food_logging_eval_cases.json"
    db_path = next((path for path in db_candidates if path.exists()), db_candidates[0])
    return db_path, cases


def run_intent_cases(cases: list[dict[str, str]]) -> list[str]:
    failures: list[str] = []
    for case in cases:
        actual = classify_intent(case["utterance"])
        expected = case["expected_intent"]
        if actual != expected:
            failures.append(f"Intent failed: {case['utterance']!r} -> {actual}, expected {expected}")
    return failures


def run_retrieval_cases(conn: sqlite3.Connection, cases: list[dict[str, object]]) -> list[str]:
    failures: list[str] = []
    for case in cases:
        query = str(case.get("search_query") or case["utterance"])
        results = search_candidates(conn, query)
        if not results:
            failures.append(f"Retrieval failed: {case['utterance']!r} -> no candidates")
            continue
        top = results[0]
        top_name = top.name.lower()
        for token in case.get("expected_top_contains", []):
            if str(token).lower() not in top_name:
                failures.append(f"Retrieval failed: {case['utterance']!r} -> top candidate {top.name!r} missing expected token {token!r}")
        for token in case.get("forbidden_top_contains", []):
            if str(token).lower() in top_name:
                failures.append(f"Retrieval failed: {case['utterance']!r} -> forbidden token {token!r} present in top candidate {top.name!r}")
        for forbidden_name in case.get("forbidden_top_equals", []):
            if top.name.lower() == str(forbidden_name).lower():
                failures.append(f"Retrieval failed: {case['utterance']!r} -> forbidden top candidate {top.name!r}")
        expected_top_source = case.get("expected_top_source")
        if expected_top_source and top.source != expected_top_source:
            failures.append(
                f"Retrieval failed: {case['utterance']!r} -> top source {top.source!r}, expected {expected_top_source!r}"
            )
        expected_top_brand_absent = case.get("expected_top_brand_absent")
        if expected_top_brand_absent and top.brand:
            failures.append(
                f"Retrieval failed: {case['utterance']!r} -> expected no top brand, got {top.brand!r}"
            )
        for token in case.get("forbidden_top_brand_contains", []):
            if str(token).lower() in str(top.brand or "").lower():
                failures.append(
                    f"Retrieval failed: {case['utterance']!r} -> forbidden brand token {token!r} present in top brand {top.brand!r}"
                )
        expected_top_portion_basis = case.get("expected_top_portion_basis")
        if expected_top_portion_basis and top.portion_basis != expected_top_portion_basis:
            failures.append(
                f"Retrieval failed: {case['utterance']!r} -> top portion basis {top.portion_basis!r}, expected {expected_top_portion_basis!r}"
            )
    return failures


def run_session_cases(cases: list[dict[str, object]]) -> list[str]:
    failures: list[str] = []
    for case in cases:
        utterance = str(case["utterance"])
        expected_reuse = bool(case["expected_reuse"])
        actual_reuse = should_reuse_session(
            str(case["existing_status"]),
            str(case["existing_intent"]),
            utterance,
        )
        if actual_reuse != expected_reuse:
            failures.append(
                f"Session failed: {utterance!r} -> reuse {actual_reuse}, expected {expected_reuse}"
            )
        standalone_intent = classify_intent(utterance)
        actual_intent = str(case["existing_intent"]) if actual_reuse and standalone_intent == "general_reply" else standalone_intent
        expected_intent = str(case["expected_intent"])
        if actual_intent != expected_intent:
            failures.append(
                f"Session intent failed: {utterance!r} -> {actual_intent}, expected {expected_intent}"
            )
    return failures


def run_database_row_cases(conn: sqlite3.Connection, cases: list[dict[str, object]]) -> list[str]:
    failures: list[str] = []
    for case in cases:
        name = str(case["name"])
        row = conn.execute(
            """
            SELECT name, source, calories, serving_desc, portion_basis, serving_source
            FROM foods
            WHERE lower(name) = lower(?)
            LIMIT 1
            """,
            (name,),
        ).fetchone()
        if row is None:
            failures.append(f"Database row failed: {name!r} not found")
            continue

        actual_name, actual_source, actual_calories, actual_serving_desc, actual_portion_basis, actual_serving_source = row

        expected_source = case.get("expected_source")
        if expected_source and actual_source != expected_source:
            failures.append(f"Database row failed: {actual_name!r} source {actual_source!r}, expected {expected_source!r}")

        expected_portion_basis = case.get("expected_portion_basis")
        if expected_portion_basis and actual_portion_basis != expected_portion_basis:
            failures.append(
                f"Database row failed: {actual_name!r} portion basis {actual_portion_basis!r}, expected {expected_portion_basis!r}"
            )

        expected_serving_source = case.get("expected_serving_source")
        if expected_serving_source and actual_serving_source != expected_serving_source:
            failures.append(
                f"Database row failed: {actual_name!r} serving source {actual_serving_source!r}, expected {expected_serving_source!r}"
            )

        expected_calories = case.get("expected_calories")
        if expected_calories is not None and not numeric_matches(expected_calories, actual_calories, case.get("calorie_tolerance", 1.0)):
            failures.append(
                f"Database row failed: {actual_name!r} calories {actual_calories!r}, expected {expected_calories!r}"
            )

        for token in case.get("expected_serving_desc_contains", []):
            if str(token).lower() not in str(actual_serving_desc or "").lower():
                failures.append(
                    f"Database row failed: {actual_name!r} serving description {actual_serving_desc!r} missing expected token {token!r}"
                )

        for token in case.get("forbidden_serving_desc_contains", []):
            if str(token).lower() in str(actual_serving_desc or "").lower():
                failures.append(
                    f"Database row failed: {actual_name!r} serving description {actual_serving_desc!r} contains forbidden token {token!r}"
                )
    return failures


def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    default_db, default_cases = default_paths(repo_root)

    parser = argparse.ArgumentParser(description="Run deterministic food logging eval cases.")
    parser.add_argument("--db", type=Path, default=default_db, help="Path to foods.sqlite")
    parser.add_argument("--cases", type=Path, default=default_cases, help="Path to eval case JSON")
    args = parser.parse_args()

    if not args.db.exists():
        print(f"Database not found: {args.db}", file=sys.stderr)
        return 2
    if not args.cases.exists():
        print(f"Cases file not found: {args.cases}", file=sys.stderr)
        return 2

    with args.cases.open() as handle:
        payload = json.load(handle)

    conn = sqlite3.connect(args.db)
    try:
        failures = []
        failures.extend(run_intent_cases(payload.get("intent_cases", [])))
        failures.extend(run_session_cases(payload.get("session_cases", [])))
        failures.extend(run_retrieval_cases(conn, payload.get("retrieval_cases", [])))
        failures.extend(run_database_row_cases(conn, payload.get("database_row_cases", [])))
    finally:
        conn.close()

    intent_count = len(payload.get("intent_cases", []))
    session_count = len(payload.get("session_cases", []))
    retrieval_count = len(payload.get("retrieval_cases", []))
    database_row_count = len(payload.get("database_row_cases", []))
    total = intent_count + session_count + retrieval_count + database_row_count
    passed = total - len(failures)

    print(f"Evaluated {total} cases: {passed} passed, {len(failures)} failed")
    if failures:
        print("")
        for failure in failures:
            print(f"- {failure}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
