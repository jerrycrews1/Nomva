# Nomva bundled food database

The `foods.sqlite` database distributed with Nomva combines USDA FoodData Central records with Open Food Facts records and some Open Food Facts fields merged into USDA rows. The complete combined SQLite database is offered under the [Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/). To the extent we hold separate rights in individual database contents, we offer those rights under the [Database Contents License (DbCL) 1.0](https://opendatacommons.org/licenses/dbcl/1-0/). This license statement applies to the food database, not to Nomva's app code or artwork or third-party product marks.

Open Food Facts contributors supplied product data. Attribution: [Open Food Facts](https://world.openfoodfacts.org/). USDA FoodData Central supplied the USDA reference and branded food records. USDA data is public domain in the United States. Product information can change, and nutrition values may be incomplete or inaccurate; verify packaging and consult a qualified professional for medical or allergy decisions.

The exact machine-readable database bundled in Nomva 1.6 (build 46) is available as a [compressed SQLite download](https://github.com/jerrycrews1/Nomva/releases/download/food-db-9debd65e/foods.sqlite.gz). Its uncompressed SHA-256 is `9debd65ed41eadf15f9d1d01346e5b5115d3d8525f5d08cbdf6a6f38696be9df`. The GitHub release should carry this same license and attribution notice. Future database releases must publish their own exact database artifact and notice before the corresponding app build is distributed.

This notice does not apply to individual products fetched directly from the Open Food Facts API; those are also attributed to Open Food Facts under ODbL where displayed.
