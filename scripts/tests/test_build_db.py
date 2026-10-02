from contextlib import closing
import gzip
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_db  # noqa: E402
from fdc_datasets import newest_releases, resolve_releases  # noqa: E402
from usda_reference_data import (  # noqa: E402
    INSERT_COLUMNS, food_record, iter_usda_foods, keep_previous_serving, portion_description,
)
from validate_food_db import compare, compare_ids, compare_servings  # noqa: E402


def write_fdc_export(path, root_key, foods):
    """Write the layout USDA ships: one food per line inside the wrapper."""
    lines = [f'{{"{root_key}": [']
    lines += [json.dumps(food) + ("," if index < len(foods) - 1 else "]}") for index, food in enumerate(foods)]
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")


def nutrients(**amounts):
    ids = {"kcal": 1008, "protein": 1003, "fat": 1004, "carbs": 1005, "atwater_general": 2047,
           "atwater_specific": 2048, "sugar": 2000, "sugar_total": 1063}
    return [{"nutrient": {"id": ids[name]}, "amount": amount} for name, amount in amounts.items()]


def write_catalog(path, rows, max_food_id=None):
    """Write a minimal catalog with explicit (id, fdc_id, name, source, barcode) rows."""
    with closing(sqlite3.connect(path)) as connection:
        build_db.create_schema(connection)
        connection.executemany("INSERT INTO foods (id, fdc_id, name, source, barcode) VALUES (?, ?, ?, ?, ?)", rows)
        if max_food_id is not None:
            connection.execute("UPDATE sqlite_sequence SET seq = ? WHERE name = 'foods'", (max_food_id,))
        connection.commit()


# Raw broccoli as SR Legacy publishes it: the natural chooser picks the 91 g cup,
# but older catalogs chose the 44 g half cup and labelled it "1 cup, ...".
BROCCOLI_PORTIONS = [
    {"modifier": "cup chopped", "amount": 1, "gramWeight": 91, "sequenceNumber": 1},
    {"modifier": "cup, chopped or diced", "amount": 0.5, "gramWeight": 44, "sequenceNumber": 2},
]
PREVIOUS_BROCCOLI = {"serving_g": 44, "serving_desc": "1 cup, chopped or diced",
                     "serving_source": "explicit_serving", "default_serving_g": None}


def branded_food(fdc_id, name, upc, calories):
    return {
        "fdcId": fdc_id, "description": name, "brandOwner": "Acme", "gtinUpc": upc,
        "servingSize": 30, "servingSizeUnit": "g", "householdServingFullText": "1 bar",
        "labelNutrients": {"calories": {"value": calories}, "protein": {"value": 3}},
        "foodNutrients": [],
    }


class IterUSDAFoodsTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.foods = [
            {"fdcId": 1, "description": 'Bar "classic", with nuts [large]', "foodUpdateLog": [{"x": 1}]},
            None,
            {"fdcId": 3, "description": "Café latte \\ whole milk", "foodNutrients": []},
        ]

    def test_streams_every_layout_usda_and_json_dump_produce(self):
        layouts = {
            "fdc.json": None,
            "single_line.json": json.dumps({"BrandedFoods": self.foods}),
            "pretty.json": json.dumps({"BrandedFoods": self.foods}, indent=2),
            "bare_list.json": json.dumps(self.foods),
        }
        for name, text in layouts.items():
            path = self.directory / name
            if text is None:
                write_fdc_export(path, "BrandedFoods", self.foods)
            else:
                path.write_text(text, encoding="utf-8")
            for chunk_size in (7, 64, 1 << 20):  # tiny chunks split foods mid-record
                with self.subTest(layout=name, chunk_size=chunk_size):
                    self.assertEqual(list(iter_usda_foods(path, "BrandedFoods", chunk_size)), self.foods)

    def test_wrong_root_key_fails_instead_of_importing_nothing(self):
        path = self.directory / "survey.json"
        write_fdc_export(path, "SurveyFoods", self.foods)
        with self.assertRaisesRegex(ValueError, "expected BrandedFoods, found SurveyFoods"):
            list(iter_usda_foods(path, "BrandedFoods"))

    def test_truncated_export_fails_loudly(self):
        path = self.directory / "truncated.json"
        write_fdc_export(path, "BrandedFoods", self.foods)
        path.write_text(path.read_text()[:-40], encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "malformed or truncated export after 2 foods"):
            list(iter_usda_foods(path, "BrandedFoods", chunk_size=16))


class ReferenceFoodTests(unittest.TestCase):
    def values(self, food):
        record = food_record({"fdcId": 1, "description": "Apples, gala, with skin, raw", **food}, "foundation")
        return None if record is None else dict(zip(INSERT_COLUMNS, record))

    def test_foundation_foods_with_only_atwater_energy_are_kept(self):
        values = self.values({"foodNutrients": nutrients(atwater_general=61, atwater_specific=57, carbs=14.8)})
        self.assertEqual(values["calories"], 57)  # specific factors, like SR Legacy's 1008
        self.assertEqual(values["carbs_g"], 14.8)
        self.assertEqual(self.values({"foodNutrients": nutrients(atwater_general=61)})["calories"], 61)

    def test_reported_energy_still_wins_and_foods_without_energy_are_skipped(self):
        self.assertEqual(self.values({"foodNutrients": nutrients(kcal=52, atwater_specific=57)})["calories"], 52)
        self.assertIsNone(self.values({"foodNutrients": nutrients(protein=1)}))

    def test_foundation_total_sugars_are_read(self):
        self.assertEqual(self.values({"foodNutrients": nutrients(kcal=52, sugar_total=10.4)})["sugar_g"], 10.4)

    def test_portion_labels_keep_the_source_quantity(self):
        for portion, expected in (
            ({"modifier": "waffles", "amount": 2, "gramWeight": 70}, "2 waffles"),
            ({"modifier": "cup, chopped or diced", "amount": 0.5, "gramWeight": 44}, "0.5 cup, chopped or diced"),
        ):
            with self.subTest(expected=expected):
                values = self.values({"foodNutrients": nutrients(kcal=34),
                                      "foodPortions": [dict(portion, sequenceNumber=1)]})
                self.assertEqual((values["serving_desc"], values["serving_g"]), (expected, portion["gramWeight"]))
        self.assertEqual(portion_description({"modifier": "cup,", "amount": 1}), "1 cup")

    def test_existing_foods_keep_their_serving_with_the_source_amount_in_the_label(self):
        broccoli = {"foodNutrients": nutrients(kcal=34), "foodPortions": BROCCOLI_PORTIONS}
        self.assertEqual(self.values(broccoli)["serving_g"], 91)  # a new food gets the natural choice
        record = food_record({"fdcId": 1, "description": "Broccoli, raw", **broccoli}, "sr_legacy",
                             PREVIOUS_BROCCOLI)
        values = dict(zip(INSERT_COLUMNS, record))
        self.assertEqual((values["serving_g"], values["serving_desc"]), (44, "0.5 cup, chopped or diced"))
        self.assertAlmostEqual(values["calories"], 14.96)
        self.assertIsNone(values["default_serving_g"])  # the replaced catalog had no separate default

    def test_same_weight_portions_follow_the_stored_label(self):
        portions = [
            {"modifier": "cup, whole", "amount": 1, "gramWeight": 144, "sequenceNumber": 1},
            {"modifier": "cup, halves", "amount": 1, "gramWeight": 144, "sequenceNumber": 2},
        ]
        previous = {"serving_g": 144, "serving_desc": "1 cup, halves", "serving_source": "explicit_serving"}
        self.assertEqual(keep_previous_serving(portions, previous), (144, "1 cup, halves", "explicit_serving"))

    def test_fallback_is_kept_and_a_vanished_portion_falls_back_to_the_chooser(self):
        fallback = {"serving_g": 100, "serving_desc": "100g", "serving_source": "fallback_raw"}
        self.assertEqual(keep_previous_serving(BROCCOLI_PORTIONS, fallback), (100, "100g", "fallback_raw"))
        stamped = dict(fallback, serving_desc="1 serving")  # left by an old Open Food Facts match
        self.assertEqual(keep_previous_serving(BROCCOLI_PORTIONS, stamped), (100, "100 g", "fallback_raw"))
        vanished = dict(PREVIOUS_BROCCOLI, serving_g=50)
        self.assertIsNone(keep_previous_serving(BROCCOLI_PORTIONS, vanished))

    def test_all_zero_codes_are_not_barcodes(self):
        self.assertIsNone(build_db.normalize_barcode("0000000000000"))
        self.assertEqual(build_db.normalize_barcode("00012345678905"), "12345678905")


class BuildTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        reference = {"foodPortions": [{"portionDescription": "1 cup", "gramWeight": 100, "sequenceNumber": 1}]}
        self.dirs = {}
        for key, root_key, food in (
            ("sr_legacy", "SRLegacyFoods", {"fdcId": 10, "description": "Bananas, raw",
                                             "foodNutrients": nutrients(kcal=89), **reference}),
            ("foundation", "FoundationFoods", {"fdcId": 20, "description": "Spinach, baby",
                                                "foodNutrients": nutrients(atwater_specific=23), **reference}),
            ("fndds", "SurveyFoods", {"fdcId": 30, "description": "Oatmeal, NFS",
                                      "foodNutrients": nutrients(kcal=71), **reference}),
            ("branded", "BrandedFoods", None),
        ):
            folder = self.root / key
            folder.mkdir()
            foods = [food] if food else [
                branded_food(40, "GRANOLA BAR", "00012345678905", 120),
                branded_food(41, "WATER", "00012345678912", 0),  # no calories: skipped
            ]
            write_fdc_export(folder / f"{key}.json", root_key, foods)
            self.dirs[f"{key}_dir"] = str(folder)
        self.off_path = self.root / "off.jsonl.gz"
        products = [
            {"code": "12345678905", "countries_tags": ["en:united-states"], "product_name": "Granola bar",
             "brands": "Acme", "nutriments": {"vitamin-c_serving": 0.006, "vitamin-c_unit": "g"}},
            {"code": "0099", "countries_tags": ["en:united-states"], "product_name": "Trail mix",
             "brands": "Hike", "serving_quantity": 40, "nutriments": {"energy-kcal_100g": 500}},
            {"code": "0777", "countries_tags": ["en:france"], "product_name": "Pain au chocolat",
             "nutriments": {"energy-kcal_100g": 400}},
        ]
        with gzip.open(self.off_path, "wt", encoding="utf-8") as stream:
            stream.write("\n".join(json.dumps(product) for product in products) + "\nnot json\n")
        self.db_path = self.root / "out" / "foods.sqlite"

    def build(self, **overrides):
        options = {"db_path": str(self.db_path), "off_path": str(self.off_path), **self.dirs, **overrides}
        return build_db.build(**options)

    def test_builds_every_source_and_merges_us_open_food_facts(self):
        self.assertEqual(self.build(), 5)
        with sqlite3.connect(self.db_path) as connection:
            rows = dict(connection.execute("SELECT name, source FROM foods"))
            self.assertEqual(rows, {
                "Bananas, raw": "sr_legacy", "Spinach, baby": "foundation", "Oatmeal, NFS": "survey_fndds",
                "Granola Bar": "branded", "Trail mix": "open_food_facts",
            })
            vitamin_c = connection.execute("SELECT vitamin_c_mg FROM foods WHERE fdc_id = 40").fetchone()[0]
            self.assertAlmostEqual(vitamin_c, 6.0)  # backfilled from the matching OFF barcode
            metadata = dict(connection.execute("SELECT key, value FROM metadata"))
            self.assertEqual(metadata["total_foods"], "5")
            self.assertEqual(metadata["open_food_facts_seen"], "4")
            self.assertEqual(
                connection.execute("SELECT COUNT(*) FROM foods_fts WHERE foods_fts MATCH 'spinach'").fetchone()[0], 1
            )
        self.assertEqual(os.listdir(self.db_path.parent), ["foods.sqlite"])

    def test_open_food_facts_never_edits_usda_reference_foods(self):
        with gzip.open(self.off_path, "wt", encoding="utf-8") as stream:
            stream.write(json.dumps({"code": "0042", "countries_tags": ["en:united-states"],
                                     "product_name": "Bananas, raw", "serving_size": "1 serving",
                                     "nutriments": {"energy-kcal_serving": 105}}) + "\n")
        self.build()
        with closing(sqlite3.connect(self.db_path)) as connection:
            rows = connection.execute(
                "SELECT source, barcode, portion_basis, serving_desc FROM foods WHERE name = 'Bananas, raw' ORDER BY source"
            ).fetchall()
        self.assertEqual(rows, [
            ("open_food_facts", "42", "fixed_serving", "1 serving"),
            ("sr_legacy", None, "grams", "1 cup"),
        ])

    def test_failed_build_leaves_the_existing_database_untouched(self):
        self.db_path.parent.mkdir()
        self.db_path.write_bytes(b"previous catalog")
        branded = Path(self.dirs["branded_dir"]) / "branded.json"
        branded.write_text(branded.read_text()[:-30], encoding="utf-8")
        with self.assertRaises(ValueError):
            self.build()
        self.assertEqual(self.db_path.read_bytes(), b"previous catalog")
        self.assertEqual(os.listdir(self.db_path.parent), ["foods.sqlite"])

    def test_rebuilds_keep_the_row_ids_the_apps_have_stored(self):
        previous = self.root / "previous.sqlite"
        # Id 1000 was used by a food that has since been retired; it must not be reused.
        write_catalog(previous, [
            (500, 10, "Bananas, raw", "sr_legacy", None),
            (900, None, "Trail mix", "open_food_facts", "99"),
        ], max_food_id=1000)
        self.build(previous_db=str(previous))
        with closing(sqlite3.connect(self.db_path)) as connection:
            self.assertEqual(dict(connection.execute("SELECT name, id FROM foods")), {
                "Bananas, raw": 500, "Trail mix": 900,
                "Spinach, baby": 1001, "Oatmeal, NFS": 1002, "Granola Bar": 1003,
            })
            self.assertEqual(
                connection.execute("SELECT seq FROM sqlite_sequence WHERE name = 'foods'").fetchone()[0], 1003
            )
            self.assertEqual(
                connection.execute("SELECT value FROM metadata WHERE key = 'max_food_id'").fetchone()[0], "1003"
            )
            self.assertEqual(connection.execute(
                "SELECT f.id FROM foods f JOIN foods_fts ON foods_fts.rowid = f.id WHERE foods_fts MATCH 'spinach'"
            ).fetchall(), [(1001,)])
            self.assertIn("idx_barcode", {row[1] for row in connection.execute("PRAGMA index_list(foods)")})
        report, problems = compare_ids(self.db_path, previous)
        self.assertEqual(problems, [])
        self.assertIn("2 of 2 pinned foods keep their id", report)

    def test_rebuilds_keep_reference_servings_the_apps_already_use(self):
        write_fdc_export(Path(self.dirs["sr_legacy_dir"]) / "sr_legacy.json", "SRLegacyFoods", [
            {"fdcId": 10, "description": "Broccoli, raw", "foodNutrients": nutrients(kcal=34),
             "foodPortions": BROCCOLI_PORTIONS},
        ])
        previous = self.root / "previous.sqlite"
        write_catalog(previous, [(500, 10, "Broccoli, raw", "sr_legacy", None)])
        with closing(sqlite3.connect(previous)) as connection:
            connection.execute(
                "UPDATE foods SET serving_g = 44, serving_desc = '1 cup, chopped or diced',"
                " serving_source = 'explicit_serving' WHERE id = 500"
            )
            connection.commit()
        self.build(previous_db=str(previous))
        with closing(sqlite3.connect(self.db_path)) as connection:
            row = connection.execute(
                "SELECT id, serving_g, serving_desc, round(calories, 2), default_serving_g FROM foods WHERE fdc_id = 10"
            ).fetchone()
        self.assertEqual(row, (500, 44.0, "0.5 cup, chopped or diced", 14.96, None))
        report, problems = compare_servings(self.db_path, previous)
        self.assertEqual(problems, [])
        self.assertIn("0 of 1 kept USDA reference foods changed grams", report)

    def test_row_id_rewrite_leaves_no_free_pages(self):
        # Enough foods that the dropped pre-rewrite table outgrows what the search index reuses.
        write_fdc_export(Path(self.dirs["branded_dir"]) / "branded.json", "BrandedFoods", [
            branded_food(100 + index, f"Granola bar flavor {index}", str(10 ** 10 + index), 120)
            for index in range(1500)
        ])
        previous = self.root / "previous.sqlite"
        write_catalog(previous, [(500, 10, "Bananas, raw", "sr_legacy", None)])
        self.build(previous_db=str(previous))
        with closing(sqlite3.connect(self.db_path)) as connection:
            self.assertEqual(connection.execute("PRAGMA freelist_count").fetchone()[0], 0)

    def test_missing_usda_export_fails_before_touching_anything(self):
        with self.assertRaisesRegex(RuntimeError, "USDA JSON missing for Branded"):
            self.build(branded_dir=str(self.root / "nowhere"))
        self.assertFalse(self.db_path.parent.exists())


class ReleaseDiscoveryTests(unittest.TestCase):
    def test_picks_the_newest_linked_release_per_dataset(self):
        page = " ".join(
            f'<a href="/fdc-datasets/FoodData_Central_{name}.zip">' for name in (
                "branded_food_json_2025-12-18", "branded_food_json_2026-10-30", "foundation_food_json_2026-04-30",
                "survey_food_json_2024-10-31", "sr_legacy_food_json_2018-04", "branded_food_csv_2027-01-01",
            )
        )
        self.assertEqual(newest_releases(page), {
            "sr_legacy": "2018-04", "foundation": "2026-04-30", "fndds": "2024-10-31", "branded": "2026-10-30",
        })

    def test_unreadable_page_falls_back_to_last_known_releases_with_a_warning(self):
        def offline():
            raise OSError("network down")
        releases, warnings = resolve_releases(fetch=offline)
        self.assertEqual(releases["branded"], "2026-04-30")
        self.assertIn("network down", warnings[0])


class ValidationTests(unittest.TestCase):
    def test_flags_an_id_that_now_names_another_food_or_reuses_a_retired_id(self):
        with tempfile.TemporaryDirectory() as directory:
            previous, new = Path(directory) / "previous.sqlite", Path(directory) / "new.sqlite"
            write_catalog(previous, [(500, 10, "Bananas, raw", "sr_legacy", None),
                                     (900, None, "Trail mix", "open_food_facts", "99")], max_food_id=1000)
            write_catalog(new, [(500, 11, "Plantains, raw", "sr_legacy", None),
                                (900, None, "Trail mix", "open_food_facts", "99"),
                                (950, 12, "New food", "branded", None)])
            report, problems = compare_ids(new, previous)
        self.assertEqual(problems, [
            "row ids now naming a different food than in the pinned catalog: 1",
            "new foods reusing retired row ids (at or below 1,000): 1",
        ])
        self.assertIn("1 of 2 pinned foods keep their id", report)

    def test_flags_a_source_or_total_that_shrinks_more_than_ten_percent(self):
        old = {"branded": 100_000, "open_food_facts": 650_000}
        self.assertEqual(compare({"branded": 95_000, "open_food_facts": 650_000}, old), [])
        self.assertEqual(
            compare({"branded": 50_000, "open_food_facts": 650_000}, old),
            ["branded dropped from 100,000 to 50,000 rows"],
        )
        self.assertEqual(
            compare({"branded": 100_000, "open_food_facts": 0}, old),
            ["open_food_facts dropped from 650,000 to 0 rows", "total dropped from 750,000 to 100,000 foods"],
        )


if __name__ == "__main__":
    unittest.main()
