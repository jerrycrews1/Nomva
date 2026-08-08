import json
import os
import sqlite3
import sys
import tempfile
import unittest


SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if SCRIPTS not in sys.path:
    sys.path.insert(0, SCRIPTS)

from usda_reference_data import (  # noqa: E402
    INSERT_COLUMNS,
    choose_default_serving,
    choose_natural_serving,
    ensure_search_schema,
    food_record,
    insert_reference_foods,
    rebuild_search_index,
)


FOODS_SCHEMA = """
CREATE TABLE foods (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    fdc_id INTEGER UNIQUE,
    name TEXT NOT NULL,
    brand TEXT,
    source TEXT NOT NULL,
    serving_g REAL,
    serving_desc TEXT,
    portion_basis TEXT NOT NULL DEFAULT 'grams',
    serving_source TEXT,
    default_serving_g REAL,
    default_serving_desc TEXT,
    default_serving_source TEXT,
    calories REAL,
    protein_g REAL,
    carbs_g REAL,
    fat_g REAL,
    fiber_g REAL,
    sugar_g REAL,
    sodium_mg REAL,
    saturated_fat_g REAL,
    trans_fat_g REAL,
    cholesterol_mg REAL,
    added_sugar_g REAL,
    vitamin_d_mcg REAL,
    calcium_mg REAL,
    iron_mg REAL,
    potassium_mg REAL,
    vitamin_a_mcg_rae REAL,
    vitamin_c_mg REAL,
    vitamin_b12_mcg REAL,
    folate_mcg_dfe REAL,
    magnesium_mg REAL,
    zinc_mg REAL,
    barcode TEXT
)
"""


class USDAReferenceDataTests(unittest.TestCase):
    def test_fndds_qns_is_preserved_separately_from_natural_slice(self):
        portions = [
            {"portionDescription": "1 slice", "gramWeight": 30, "sequenceNumber": 1},
            {"portionDescription": "Quantity not specified", "gramWeight": 60, "sequenceNumber": 2},
        ]
        serving = choose_natural_serving(portions)
        default = choose_default_serving(portions, serving[0], serving[1], "survey_fndds")

        self.assertEqual(serving, (30, "1 slice", "explicit_serving"))
        self.assertEqual(default, (60, "1 estimated serving", "survey_qns"))

    def test_equal_fndds_qns_keeps_the_natural_household_description(self):
        portions = [
            {"portionDescription": "1 cup", "gramWeight": 244, "sequenceNumber": 1},
            {"portionDescription": "Quantity not specified", "gramWeight": 244, "sequenceNumber": 2},
        ]
        default = choose_default_serving(portions, 244, "1 cup", "survey_fndds")

        self.assertEqual(default, (244, "1 cup", "survey_qns"))

    def test_foundation_measure_amount_is_preserved(self):
        serving = choose_natural_serving([{
            "amount": 2,
            "measureUnit": {"name": "tablespoon"},
            "gramWeight": 33.9,
            "sequenceNumber": 1,
        }])
        self.assertEqual(serving, (33.9, "2 tablespoons", "explicit_serving"))

    def test_natural_portion_prefers_an_ounce_of_nuts_over_a_full_cup(self):
        serving = choose_natural_serving([
            {"portionDescription": "1 nut", "gramWeight": 1.2, "sequenceNumber": 1},
            {"portionDescription": "1 cup", "gramWeight": 141, "sequenceNumber": 2},
            {"portionDescription": "1 oz", "gramWeight": 28.35, "sequenceNumber": 5},
        ])
        self.assertEqual(serving, (28.35, "1 oz", "explicit_serving"))

    def test_liquid_prefers_first_choice_cup_without_double_counting_fluid_ounce_aliases(self):
        record = food_record({
            "fdcId": 123,
            "description": "Milk, NFS",
            "foodPortions": [
                {
                    "portionDescription": "1 fl oz",
                    "gramWeight": 30.5,
                    "sequenceNumber": 2,
                },
                {
                    "portionDescription": "1 cup",
                    "gramWeight": 244,
                    "sequenceNumber": 1,
                },
            ],
            "foodNutrients": [
                {"nutrient": {"id": 1008}, "amount": 52},
            ],
        }, "survey_fndds")

        values = dict(zip(INSERT_COLUMNS, record))
        self.assertEqual(values["serving_g"], 244)
        self.assertEqual(values["serving_desc"], "1 cup")
        self.assertAlmostEqual(values["calories"], 126.88)

    def test_solid_food_does_not_prefer_recipe_cup_over_a_natural_item(self):
        serving = choose_natural_serving([
            {"portionDescription": "1 small/regular", "gramWeight": 105, "sequenceNumber": 2},
            {"portionDescription": "1 miniature", "gramWeight": 50, "sequenceNumber": 1},
            {"portionDescription": "1 large", "gramWeight": 160, "sequenceNumber": 3},
            {"portionDescription": "1 cup", "gramWeight": 120, "sequenceNumber": 4},
        ])
        self.assertEqual(serving, (105, "1 small/regular", "explicit_serving"))

    def test_tiny_generic_fruit_unit_yields_to_household_aggregate(self):
        serving = choose_natural_serving([
            {"portionDescription": "Quantity not specified", "gramWeight": 75, "sequenceNumber": 3},
            {"portionDescription": "1 fruit", "gramWeight": 18, "sequenceNumber": 1},
            {"portionDescription": "1 cup", "gramWeight": 150, "sequenceNumber": 2},
        ])
        self.assertEqual(serving, (150, "1 cup", "explicit_serving"))

    def test_explicit_single_size_container_is_a_natural_serving(self):
        serving = choose_natural_serving([
            {"portionDescription": "1 5.3 oz container", "gramWeight": 150, "sequenceNumber": 1},
            {"portionDescription": "1 cup", "gramWeight": 245, "sequenceNumber": 4},
        ])
        self.assertEqual(serving, (150, "1 5.3 oz container", "explicit_serving"))

    def test_conversion_yield_does_not_beat_a_natural_whole_portion(self):
        serving = choose_natural_serving([
            {"portionDescription": "1 oz, raw, yields", "gramWeight": 30, "sequenceNumber": 5},
            {"portionDescription": "1 small", "gramWeight": 130, "sequenceNumber": 2},
        ])
        self.assertEqual(serving, (130, "1 small", "explicit_serving"))

    def test_fndds_alias_is_searchable_and_nutrition_uses_selected_portion(self):
        payload = {
            "SurveyFoods": [{
                "fdcId": 2708360,
                "description": "Cereal, cooked, NFS",
                "foodPortions": [
                    {
                        "portionDescription": "Quantity not specified",
                        "gramWeight": 240,
                        "sequenceNumber": 2,
                    },
                    {
                        "portionDescription": "1 cup, cooked",
                        "gramWeight": 240,
                        "sequenceNumber": 1,
                    },
                ],
                "inputFoods": [{
                    "foodDescription": "Oatmeal, regular or quick, made with water, no added fat",
                    "ingredientDescription": "Oatmeal, regular or quick, made with water, no added fat",
                }],
                "wweiaFoodCategory": {
                    "wweiaFoodCategoryDescription": "Grits and other cooked cereals"
                },
                "foodNutrients": [
                    {"nutrient": {"id": 1008}, "amount": 64},
                    {"nutrient": {"id": 1003}, "amount": 2.1},
                    {"nutrient": {"id": 1005}, "amount": 12},
                    {"nutrient": {"id": 1004}, "amount": 1.5},
                ],
            }]
        }

        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, "survey.json")
            with open(source, "w", encoding="utf-8") as file:
                json.dump(payload, file)
            connection = sqlite3.connect(":memory:")
            connection.execute(FOODS_SCHEMA)
            ensure_search_schema(connection)
            stats = insert_reference_foods(
                connection, source, "SurveyFoods", "survey_fndds"
            )
            rebuild_search_index(connection)

            self.assertEqual(stats["inserted"], 1)
            row = connection.execute(
                "SELECT name, source, serving_desc, calories FROM foods"
            ).fetchone()
            self.assertEqual(row[:3], ("Cereal, cooked, NFS", "survey_fndds", "1 cup, cooked"))
            self.assertAlmostEqual(row[3], 153.6)
            match = connection.execute(
                "SELECT f.name FROM foods f JOIN foods_fts x ON x.rowid=f.id "
                "WHERE foods_fts MATCH 'oatmeal*'"
            ).fetchone()
            self.assertEqual(match[0], "Cereal, cooked, NFS")

    def test_malformed_upstream_rows_are_skipped(self):
        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, "foundation.json")
            with open(source, "w", encoding="utf-8") as file:
                json.dump({"FoundationFoods": [None]}, file)
            connection = sqlite3.connect(":memory:")
            connection.execute(FOODS_SCHEMA)
            ensure_search_schema(connection)
            stats = insert_reference_foods(
                connection, source, "FoundationFoods", "foundation"
            )
            self.assertEqual(stats, {"inserted": 0, "skipped": 1})


if __name__ == "__main__":
    unittest.main()
