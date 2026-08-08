#!/usr/bin/env node

"use strict";

const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
const Database = require(path.join(ROOT, "server", "node_modules", "better-sqlite3"));
const serverEnvPath = path.join(ROOT, "server", ".env");
if (fs.existsSync(serverEnvPath)) {
  require(path.join(ROOT, "server", "node_modules", "dotenv")).config({ path: serverEnvPath });
}
const BASE_URL = (process.env.NOMVA_EVAL_BASE_URL || "https://nomva.nerdquad.com").replace(/\/$/, "");
const AUTOMATION_TOKEN = process.env.NOMVA_AUTOMATION_TOKEN || "";
const SET = process.argv.find((argument) => argument.startsWith("--set="))?.split("=")[1] || "train";
const DRY_RUN = process.argv.includes("--dry-run");
const CONCURRENCY = Math.max(1, Math.min(4, Number(process.env.NOMVA_EVAL_CONCURRENCY || 2)));
const MAX_REQUEST_MS = Number(process.env.NOMVA_EVAL_MAX_REQUEST_MS || 20_000);
const REPORT_DIR = path.join(ROOT, "reports", "release-gate");
const FOOD_DB_PATH = process.env.NOMVA_EVAL_FOOD_DB_PATH
  || path.join(ROOT, "Nomva", "Resources", "foods.sqlite");

if (!["train", "validation", "holdout2"].includes(SET)) {
  throw new Error("--set must be train, validation, or holdout2");
}

function normalize(value) {
  return String(value || "")
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function matches(value, pattern) {
  return new RegExp(pattern, "is").test(String(value ?? ""));
}

function singularToken(token) {
  if (token.endsWith("ies") && token.length > 3) return `${token.slice(0, -3)}y`;
  if (token.endsWith("s") && token.length > 3 && !token.endsWith("ss")) return token.slice(0, -1);
  return token;
}

function foodIdentityMatches(value, label, pattern) {
  if (matches(value, pattern)) return true;
  const ignored = new Set(["a", "an", "the", "side", "plain"]);
  const expected = normalize(label).split(" ").map(singularToken).filter((token) => !ignored.has(token));
  const actual = new Set(normalize(value).split(" ").map(singularToken));
  return expected.length > 0 && expected.every((token) => actual.has(token));
}

function read(relativePath) {
  return fs.readFileSync(path.join(ROOT, relativePath), "utf8");
}

function percentile(values, fraction) {
  if (!values.length) return null;
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1)];
}

function assertion(name, passed, expected, actual, critical = false) {
  return { name, passed: Boolean(passed), expected, actual, critical };
}

function getPath(value, dottedPath) {
  return dottedPath.split(".").reduce((current, key) => current?.[key], value);
}

class NomvaAPI {
  constructor() {
    const suffix = `${SET}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    this.userId = `codex-release-gate-${suffix}`;
    this.deviceToken = `release-gate-device-${suffix}`;
    this.token = null;
    this.requests = [];
  }

  headers() {
    const headers = {
      "Content-Type": "application/json",
      "X-Nomva-User-ID": this.userId,
      "X-Nomva-Device-Token": this.deviceToken,
    };
    if (AUTOMATION_TOKEN) {
      headers["X-Nomva-Automation-Token"] = AUTOMATION_TOKEN;
    } else {
      headers["X-Nomva-App-Attest-Mode"] = "simulator";
    }
    if (this.token) headers.Authorization = `Bearer ${this.token}`;
    return headers;
  }

  async request(route, body = {}, options = {}) {
    const startedAt = Date.now();
    for (let attempt = 1; attempt <= 4; attempt += 1) {
      try {
        const response = await fetch(`${BASE_URL}${route}`, {
          method: options.method || "POST",
          headers: this.headers(),
          body: (options.method || "POST") === "GET" ? undefined : JSON.stringify(body),
          signal: AbortSignal.timeout(MAX_REQUEST_MS + 5_000),
        });
        const raw = await response.text();
        let parsed;
        try {
          parsed = raw ? JSON.parse(raw) : {};
        } catch {
          parsed = { raw };
        }
        const durationMs = Date.now() - startedAt;

        const retryableStatus = [408, 425, 429, 500, 502, 503, 504].includes(response.status);
        if (retryableStatus && attempt < 4) {
          const retryAfter = Number(response.headers.get("retry-after"));
          const delayMs = Number.isFinite(retryAfter) && retryAfter > 0
            ? retryAfter * 1_000
            : 250 * (2 ** (attempt - 1));
          await new Promise((resolve) => setTimeout(resolve, delayMs));
          continue;
        }

        this.requests.push({ route, status: response.status, durationMs, attempt });
        return { status: response.status, body: parsed, durationMs };
      } catch (error) {
        if (attempt >= 4) throw error;
        await new Promise((resolve) => setTimeout(resolve, 250 * (2 ** (attempt - 1))));
      }
    }
    throw new Error(`${route} exhausted retries`);
  }

  async register() {
    if (!AUTOMATION_TOKEN && !/^https?:\/\/(localhost|127\.0\.0\.1)(:|\/|$)/i.test(BASE_URL)) {
      throw new Error("NOMVA_AUTOMATION_TOKEN is required for remote release-gate runs.");
    }
    const response = await this.request("/v1/auth/register", {
      nomvaUserId: this.userId,
      deviceToken: this.deviceToken,
    });
    this.token = response.body.token;
    if (response.status !== 200 || !this.token) {
      throw new Error(`Authentication failed: ${JSON.stringify(response.body)}`);
    }
  }
}

const foodCatalogs = {
  train: [
    ["plain Greek yogurt", "greek.*yogurt|yogurt.*greek", 40, 350],
    ["blueberries", "blueberr", 20, 250],
    ["black coffee", "coffee", 0, 25],
    ["scrambled eggs", "egg", 50, 400],
    ["whole wheat toast", "toast|whole.*wheat.*bread", 35, 260],
    ["bacon", "bacon", 25, 450],
    ["grilled chicken breast", "chicken.*breast|breast.*chicken", 70, 600],
    ["white rice", "rice", 60, 500],
    ["broccoli", "broccoli", 5, 220],
    ["salmon", "salmon", 70, 650],
    ["sweet potato", "sweet.*potato|potato.*sweet", 35, 400],
    ["asparagus", "asparagus", 5, 180],
    ["turkey sandwich", "turkey.*sandwich|sandwich.*turkey", 120, 850],
    ["an apple", "apple", 20, 220],
    ["oatmeal", "oatmeal|oat", 50, 500],
    ["a banana", "banana", 35, 240],
    ["peanut butter", "peanut.*butter", 60, 420],
    ["beef tacos", "taco", 90, 950],
    ["black beans", "black.*bean|bean.*black", 50, 450],
    ["spaghetti", "spaghetti|pasta", 80, 750],
    ["meatballs", "meatball", 60, 750],
    ["a side salad", "salad", 0, 500],
    ["Cheerios", "cheerio", 50, 400],
    ["milk", "milk", 20, 320],
    ["strawberries", "strawberr", 10, 220],
    ["cottage cheese", "cottage.*cheese", 40, 350],
    ["almonds", "almond", 50, 400],
    ["avocado", "avocado", 30, 420],
    ["brown rice", "brown.*rice|rice.*brown", 60, 500],
    ["tuna salad", "tuna.*salad|salad.*tuna", 80, 700],
    ["hummus", "hummus", 30, 500],
    ["pita bread", "pita", 40, 420],
  ],
  validation: [
    ["plain skyr", "skyr", 40, 350],
    ["raspberries", "raspberr", 15, 250],
    ["unsweetened green tea", "green.*tea|tea", 0, 30],
    ["poached eggs", "egg", 45, 380],
    ["rye toast", "rye.*toast|rye.*bread|toast", 35, 280],
    ["turkey sausage", "turkey.*sausage|sausage.*turkey", 40, 500],
    ["pork tenderloin", "pork.*tenderloin|tenderloin", 70, 650],
    ["quinoa", "quinoa", 60, 500],
    ["green beans", "green.*bean|bean.*green", 10, 260],
    ["baked cod", "cod", 50, 550],
    ["a baked potato", "baked.*potato|potato", 40, 500],
    ["Brussels sprouts", "brussels.*sprout|sprout", 10, 300],
    ["ham sandwich", "ham.*sandwich|sandwich.*ham", 120, 850],
    ["a pear", "pear", 25, 240],
    ["cream of wheat", "cream.*wheat|wheat.*cereal", 50, 500],
    ["an orange", "orange", 20, 220],
    ["almond butter", "almond.*butter", 60, 430],
    ["chicken enchiladas", "enchilada", 100, 950],
    ["pinto beans", "pinto.*bean|bean.*pinto", 50, 450],
    ["penne pasta", "penne|pasta", 80, 750],
    ["turkey meatballs", "turkey.*meatball|meatball", 60, 700],
    ["Caesar salad", "caesar.*salad|salad", 20, 750],
    ["corn flakes", "corn.*flake|flake", 50, 420],
    ["soy milk", "soy.*milk|milk.*soy", 20, 300],
    ["peaches", "peach", 15, 240],
    ["ricotta cheese", "ricotta", 40, 450],
    ["cashews", "cashew", 50, 420],
    ["guacamole", "guacamole", 30, 450],
    ["wild rice", "wild.*rice|rice.*wild", 60, 500],
    ["egg salad", "egg.*salad|salad.*egg", 70, 650],
    ["baba ganoush", "baba.*ganoush|eggplant", 20, 450],
    ["naan", "naan", 70, 520],
  ],
  holdout2: [
    ["plain kefir", "kefir", 40, 300],
    ["blackberries", "blackberr", 10, 220],
    ["large Wendy's chili", "wendy.*chili|chili.*wendy", 180, 550],
    ["hard-boiled eggs", "egg.*hard.*boil|hard.*boil.*egg", 40, 350],
    ["sourdough toast", "sourdough.*(?:toast|bread)|(?:toast|bread).*sourdough", 35, 260],
    ["chicken sausage", "chicken.*sausage|sausage.*chicken", 40, 500],
    ["flank steak", "flank.*steak|steak.*flank", 80, 700],
    ["couscous", "couscous", 50, 520],
    ["cauliflower", "cauliflower", 5, 240],
    ["tilapia", "tilapia", 50, 550],
    ["butternut squash", "butternut.*squash|squash.*butternut", 20, 320],
    ["zucchini", "zucchini", 5, 220],
    ["chicken salad sandwich", "chicken.*salad.*sandwich|sandwich.*chicken.*salad", 120, 900],
    ["a plum", "plum", 15, 200],
    ["grits", "grit", 50, 520],
    ["a mango", "mango", 20, 280],
    ["tahini", "tahini", 40, 380],
    ["fish tacos", "fish.*taco|taco.*fish", 90, 1_000],
    ["kidney beans", "kidney.*bean|bean.*kidney", 50, 520],
    ["fusilli pasta", "fusilli|pasta", 70, 780],
    ["falafel", "falafel", 50, 650],
    ["Greek salad", "greek.*salad|salad.*greek", 20, 800],
    ["bran flakes", "bran.*flake|flake.*bran", 40, 450],
    ["oat milk", "oat.*milk|milk.*oat", 20, 330],
    ["mozzarella cheese", "mozzarella", 35, 480],
    ["pistachios", "pistachio", 50, 450],
    ["salsa", "salsa", 0, 180],
    ["barley", "barley", 50, 540],
    ["potato salad", "potato.*salad|salad.*potato", 70, 750],
    ["tzatziki", "tzatziki", 10, 320],
    ["a Chipotle chicken burrito bowl", "chipotle.*chicken.*burrito.*bowl|chicken.*burrito.*bowl", 350, 1_300],
    ["split pea soup", "split.*pea.*soup|soup.*split.*pea", 40, 540],
  ],
};

const intentSets = {
  train: [
    ["I ate a peach after work", "log_food"], ["Breakfast was eggs and toast", "log_food"],
    ["Add a bowl of lentil soup", "log_food"], ["Had sparkling water with lime", "log_food"],
    ["Delete the peach", "delete_food"], ["Remove everything from breakfast", "delete_food"],
    ["I did not eat that sandwich", "delete_food"], ["Clear today's food log", "delete_food"],
    ["Make the rice half a cup", "edit_food"], ["Actually that was decaf", "edit_food"],
    ["Change the soup to two bowls", "edit_food"], ["That portion is too large", "edit_food"],
    ["Move the apple from snack to lunch", "move_food"], ["Put that oatmeal under breakfast", "move_food"],
    ["I drank 18 ounces of water", "log_water"], ["Set today's hydration total to 70 oz", "log_water"],
    ["I weigh 178.4 pounds", "log_weight"], ["Delete yesterday's weight", "log_weight"],
    ["Set my calorie goal to 2050", "set_goal"], ["Raise protein by 20 grams", "set_goal"],
    ["Change my target weight to 170 pounds", "set_goal"],
    ["How much protein is left today?", "query_data"], ["What is my two-week weight trend?", "query_data"],
    ["How much water have I had?", "query_data"],
  ],
  validation: [
    ["Please log the soup I just ate", "log_food"], ["Lunch ended up being a turkey wrap", "log_food"],
    ["Track one kiwi for my snack", "log_food"], ["I drank a latte this morning", "log_food"],
    ["Take the kiwi back out", "delete_food"], ["Erase my dinner entries", "delete_food"],
    ["No, remove both of those", "delete_food"], ["Wipe all foods for today", "delete_food"],
    ["The wrap was only half", "edit_food"], ["It was soy milk, not dairy milk", "edit_food"],
    ["Update the kiwi to two", "edit_food"], ["Undo that portion change", "edit_food"],
    ["Reassign the latte to breakfast", "move_food"], ["That soup belongs in dinner", "move_food"],
    ["Add 450 milliliters of water", "log_water"], ["Clear today's water", "log_water"],
    ["Record 80.6 kilograms today", "log_weight"], ["Change today's weight to 176.2", "log_weight"],
    ["Lower carbs by 30 grams", "set_goal"], ["Make my water goal 88 ounces", "set_goal"],
    ["Set calories to 2300 and fiber to 32 grams", "set_goal"],
    ["Average calories over the last month?", "query_data"], ["What did I weigh most recently?", "query_data"],
    ["How many calories remain?", "query_data"],
  ],
  holdout2: [
    ["Dinner was a bowl of minestrone", "log_food"], ["Can you put down one nectarine for my snack?", "log_food"],
    ["Track my breakfast: two waffles", "log_food"], ["Just had an iced Americano", "log_food"],
    ["Scratch that nectarine", "delete_food"], ["Drop every item from lunch", "delete_food"],
    ["Those last two foods were a mistake", "delete_food"], ["Empty out today's meals", "delete_food"],
    ["The waffles were three, not two", "edit_food"], ["Use lactose-free milk for that instead", "edit_food"],
    ["Make the minestrone one and a half bowls", "edit_food"], ["Revert my last serving edit", "edit_food"],
    ["File the Americano under breakfast", "move_food"], ["Switch that nectarine over to lunch", "move_food"],
    ["Log 600 mL of water", "log_water"], ["Reset today's water total to zero", "log_water"],
    ["Add a weigh-in of 168.9 lb", "log_weight"], ["Remove yesterday morning's weigh-in", "log_weight"],
    ["Set fat to 65 grams", "set_goal"], ["Add 10 grams to my fiber target", "set_goal"],
    ["Make 160 pounds my target", "set_goal"],
    ["Tell me today's remaining carbs", "query_data"], ["Compare my weight this month", "query_data"],
    ["What's my hydration total for this date?", "query_data"],
  ],
};

const splitSets = {
  train: [
    ["a peanut butter and jelly sandwich", ["peanut.*butter.*jelly.*sandwich"]],
    ["mac and cheese", ["mac.*cheese"]],
    ["fish and chips", ["fish.*chips"]],
    ["a bacon egg and cheese sandwich", ["bacon.*egg.*cheese.*sandwich"]],
    ["cookies and cream yogurt", ["cookies.*cream.*yogurt"]],
    ["tofu bibimbap", ["tofu.*bibimbap|bibimbap.*tofu"]],
    ["chicken curry", ["chicken.*curry|curry.*chicken"]],
    ["vegetable pizza", ["vegetable.*pizza|pizza.*vegetable"]],
    ["a turkey sandwich", ["turkey.*sandwich|sandwich.*turkey"]],
    ["protein oatmeal", ["protein.*oatmeal|oatmeal.*protein"]],
    ["salmon with a side of rice", ["salmon", "rice"]],
    ["a burger with a side salad", ["burger", "salad"]],
    ["two cups of tea with one tablespoon of honey", ["tea", "honey"]],
    ["yogurt topped with granola", ["yogurt", "granola"]],
    ["tacos, beans, and rice", ["taco", "bean", "rice"]],
    ["soup and a piece of bread", ["soup", "bread"]],
    ["pasta with a side of meatballs", ["pasta", "meatball"]],
    ["coffee with two tablespoons of cream", ["coffee", "cream"]],
    ["oatmeal topped with berries", ["oatmeal", "berr"]],
    ["cereal with one cup of milk", ["cereal", "milk"]],
  ],
  validation: [
    ["beef stew", ["beef.*stew|stew.*beef"]],
    ["a grilled cheese sandwich", ["grilled.*cheese.*sandwich"]],
    ["chicken pot pie", ["chicken.*pot.*pie"]],
    ["tofu pad thai", ["tofu.*pad.*thai|pad.*thai.*tofu"]],
    ["lentil curry", ["lentil.*curry|curry.*lentil"]],
    ["a veggie burger", ["veggie.*burger|vegetable.*burger"]],
    ["an egg salad sandwich", ["egg.*salad.*sandwich"]],
    ["shrimp fried rice", ["shrimp.*fried.*rice"]],
    ["mushroom risotto", ["mushroom.*risotto|risotto.*mushroom"]],
    ["a vanilla protein shake", ["vanilla.*protein.*shake|protein.*shake"]],
    ["steak with a baked potato on the side", ["steak", "potato"]],
    ["tomato soup with a side of crackers", ["tomato.*soup|soup", "cracker"]],
    ["green tea with one teaspoon of sugar", ["tea", "sugar"]],
    ["cottage cheese topped with pineapple", ["cottage.*cheese", "pineapple"]],
    ["rice, pinto beans, and avocado", ["rice", "pinto.*bean|bean", "avocado"]],
    ["hummus and pita bread", ["hummus", "pita"]],
    ["salmon with asparagus on the side", ["salmon", "asparagus"]],
    ["coffee with a splash of milk", ["coffee", "milk"]],
    ["pancakes topped with blueberries", ["pancake", "blueberr"]],
    ["corn flakes with soy milk", ["corn.*flake|flake", "soy.*milk|milk"]],
  ],
  holdout2: [
    ["shepherd's pie", ["shepherd.*pie"]],
    ["a tuna melt", ["tuna.*melt"]],
    ["huevos rancheros", ["huevos.*rancheros"]],
    ["chicken tikka masala", ["chicken.*tikka.*masala|tikka.*masala"]],
    ["vegetable lasagna", ["vegetable.*lasagna|lasagna.*vegetable"]],
    ["a bean burrito", ["bean.*burrito|burrito.*bean"]],
    ["miso soup", ["miso.*soup|soup.*miso"]],
    ["beef stroganoff", ["beef.*stroganoff|stroganoff.*beef"]],
    ["a spinach omelet", ["spinach.*omelet|omelet.*spinach"]],
    ["banana bread", ["banana.*bread|bread.*banana"]],
    ["roast chicken with mashed potatoes", ["roast.*chicken|chicken", "mashed.*potato|potato"]],
    ["chili with cornbread", ["chili", "cornbread"]],
    ["coffee with oat milk", ["coffee", "oat.*milk|milk"]],
    ["ricotta topped with figs", ["ricotta", "fig"]],
    ["bulgur, chickpeas, and cucumber", ["bulgur", "chickpea", "cucumber"]],
    ["falafel with tzatziki", ["falafel", "tzatziki"]],
    ["tilapia and couscous", ["tilapia", "couscous"]],
    ["waffles with maple syrup", ["waffle", "maple.*syrup|syrup"]],
    ["bran flakes with oat milk", ["bran.*flake|flake", "oat.*milk|milk"]],
    ["flatbread with hummus and olives", ["flatbread", "hummus", "olive"]],
  ],
};

function contextCases(setName) {
  const validation = setName === "validation";
  const holdout = setName === "holdout2";
  const foods = validation
    ? ["Quinoa", "Green Beans", "Pear", "Skyr", "Naan", "Cod", "Cashews", "Ricotta"]
    : holdout
      ? ["Kefir", "Cauliflower", "Mango", "Couscous", "Flatbread", "Tilapia", "Pistachios", "Mozzarella"]
      : ["Rice", "Broccoli", "Apple", "Yogurt", "Pita", "Salmon", "Almonds", "Cottage Cheese"];
  const meals = ["breakfast", "lunch", "dinner", "snack"];
  const cases = [];

  for (let index = 0; index < 8; index += 1) {
    const first = foods[index];
    const second = foods[(index + 1) % foods.length];
    cases.push({
      category: "multi-turn delete",
      route: "/v1/pick-delete-targets",
      message: holdout
        ? (index % 2 === 0 ? "Take back the pair I just logged" : "Get rid of those two")
        : (index % 2 === 0 ? "Delete that" : "Remove both of those"),
      body: {
        recentMessages: [
          { role: "user", content: `I had ${first} and ${second}` },
          { role: "assistant", content: `✓ ${first} (1 serving)\n✓ ${second} (1 serving)` },
        ],
        logSummary: `${first} (${meals[index % 4]})\n${second} (${meals[index % 4]})`,
      },
      verify(body) {
        const names = Array.isArray(body.foodNames) ? body.foodNames : [];
        return [
          assertion("all grouped targets", names.length === 2, [first, second], names, true),
          assertion("first target", names.some((name) => matches(name, normalize(first).replace(/ /g, ".*"))), first, names),
          assertion("second target", names.some((name) => matches(name, normalize(second).replace(/ /g, ".*"))), second, names),
        ];
      },
    });
  }

  for (let index = 0; index < 8; index += 1) {
    const food = foods[index];
    const portion = index % 2 === 0 ? "two servings" : "half a serving";
    cases.push({
      category: "multi-turn edit",
      route: "/v1/pick-edit-target",
      message: holdout
        ? `Revise the ${food} entry to ${portion}`
        : validation ? `Make ${food} ${portion}` : `Change ${food} to ${portion}`,
      body: {
        recentMessages: [
          { role: "user", content: `I had ${food}` },
          { role: "assistant", content: `✓ ${food} (1 serving)` },
        ],
        logSummary: `${food} (${meals[index % 4]})`,
      },
      verify(body) {
        return [assertion("edit target", matches(body.foodName, normalize(food).replace(/ /g, ".*")), food, body.foodName, true)];
      },
    });
  }

  for (let index = 0; index < 8; index += 1) {
    const food = foods[index];
    const destination = meals[(index + 1) % meals.length];
    cases.push({
      category: "multi-turn move",
      route: "/v1/extract-food-move",
      message: holdout
        ? `Put ${food} in ${destination} instead`
        : validation
          ? `That ${food} belongs under ${destination}`
          : `Move ${food} to ${destination}`,
      body: {
        recentMessages: [
          { role: "user", content: `I had ${food}` },
          { role: "assistant", content: `✓ ${food} (1 serving)` },
        ],
        logSummary: `${food} (${meals[index % 4]})`,
      },
      verify(body) {
        return [
          assertion("move target", matches(body.foodName, normalize(food).replace(/ /g, ".*")), food, body.foodName, true),
          assertion("destination meal", body.destinationMeal === destination, destination, body.destinationMeal, true),
        ];
      },
    });
  }
  return cases;
}

const servingMealSets = {
  train: {
    servings: [
      ["150 grams plain yogurt", "plain yogurt", null, "150.*g|150.*gram"],
      ["6 ounces grilled chicken", "grilled chicken", null, "6.*oz|6.*ounce"],
      ["half a cup of brown rice", "brown rice", 0.5, "half|1/2|0.5"],
      ["2 tablespoons peanut butter", "peanut butter", 2, "2.*tbsp|2.*table"],
      ["one third of an avocado", "avocado", 1 / 3, "third|1/3|0.33"],
      ["8 fluid ounces almond milk", "almond milk", null, "8.*fl|8.*oz|1.*cup"],
      ["one and a half muffins", "muffins", 1.5, "1.5|1 1/2|1 and a half|one and a half"],
      ["a quarter of a pizza", "pizza", 0.25, "quarter|1/4|0.25"],
      ["320 grams beef chili", "beef chili", null, "320.*g|320.*gram"],
      ["a small handful of almonds", "almonds", 1, "handful|serving"],
    ],
    meals: [
      ["Breakfast was oatmeal", "breakfast"], ["I ate soup for lunch", "lunch"],
      ["Dinner: salmon", "dinner"], ["I had almonds as a snack", "snack"],
      ["Eggs this morning", "breakfast"], ["Rice at noon", "lunch"],
      ["Pasta this evening", "dinner"], ["My afternoon snack was fruit", "snack"],
      ["For breakfast I had toast", "breakfast"], ["I ate tacos tonight", "dinner"],
    ],
  },
  validation: {
    servings: [
      ["225 g plain skyr", "plain skyr", null, "225.*g|225.*gram"],
      ["5 oz pork tenderloin", "pork tenderloin", null, "5.*oz|5.*ounce"],
      ["three quarters cup quinoa", "quinoa", 0.75, "three quarters|3/4|0.75"],
      ["1.5 tablespoons almond butter", "almond butter", 1.5, "1.5.*tbsp|1.5.*table"],
      ["two thirds of a pear", "pear", 2 / 3, "two thirds|2/3|0.67"],
      ["12 fluid ounces soy milk", "soy milk", null, "12.*fl|12.*oz"],
      ["two and a quarter enchiladas", "enchiladas", 2.25, "2.25|2 1/4|two and a quarter"],
      ["one eighth of a cake", "cake", 0.125, "eighth|1/8|0.125"],
      ["275 grams lentil curry", "lentil curry", null, "275.*g|275.*gram"],
      ["a heaping scoop of ricotta", "ricotta", 1, "scoop|serving"],
    ],
    meals: [
      ["Please log skyr under breakfast", "breakfast"], ["That sandwich was my lunch", "lunch"],
      ["Put the cod in dinner", "dinner"], ["Cashews were my snack", "snack"],
      ["I ate eggs earlier this morning", "breakfast"], ["Quinoa at midday", "lunch"],
      ["Naan with my meal tonight", "dinner"], ["Late-night snack: ricotta", "snack"],
      ["Track toast for breakfast", "breakfast"], ["This evening I had risotto", "dinner"],
    ],
  },
  holdout2: {
    servings: [
      ["180 grams plain kefir", "plain kefir", null, "180.*g|180.*gram"],
      ["7 oz flank steak", "flank steak", null, "7.*oz|7.*ounce"],
      ["one quarter cup couscous", "couscous", 0.25, "quarter|1/4|0.25"],
      ["2.5 tablespoons tahini", "tahini", 2.5, "2.5.*tbsp|2.5.*table"],
      ["half of a mango", "mango", 0.5, "half|1/2|0.5"],
      ["10 fluid ounces oat milk", "oat milk", null, "10.*fl|10.*oz"],
      ["three and a half falafel patties", "falafel patties", 3.5, "3.5|3 1/2|three and a half"],
      ["one sixth of a flatbread", "flatbread", 1 / 6, "sixth|1/6|0.16|0.17"],
      ["340 grams split pea soup", "split pea soup", null, "340.*g|340.*gram"],
      ["a generous spoonful of tzatziki", "tzatziki", 1, "spoonful|serving"],
    ],
    meals: [
      ["Breakfast entry: bran flakes", "breakfast"], ["Log the sandwich with lunch", "lunch"],
      ["Tilapia was supper", "dinner"], ["Pistachios were an afternoon snack", "snack"],
      ["My first meal was hard-boiled eggs", "breakfast"], ["Couscous at lunch today", "lunch"],
      ["I had flatbread for supper", "dinner"], ["Before bed I snacked on mozzarella", "snack"],
      ["Morning meal was grits", "breakfast"], ["Tonight's meal included falafel", "dinner"],
    ],
  },
};

const mutationSets = {
  train: [
    ["/v1/extract-water-mutation", "Add 16 oz of water", { action: "add", amountOz: 16 }],
    ["/v1/extract-water-mutation", "I drank 500 ml water", { action: "add", amountOz: 16.9, tolerance: 0.7 }],
    ["/v1/extract-water-mutation", "Log two cups of water", { action: "add", amountOz: 16 }],
    ["/v1/extract-water-mutation", "Set today's water total to 72 oz", { action: "update_total", amountOz: 72 }],
    ["/v1/extract-water-mutation", "Clear all water from today", { action: "delete_all" }],
    ["/v1/extract-water-mutation", "How much water today?", { action: "reply" }],
    ["/v1/extract-weight-mutation", "I weigh 181.4 pounds today", { action: "add", weightLbs: 181.4, dateHint: "today" }],
    ["/v1/extract-weight-mutation", "Log 82 kg today", { action: "add", weightLbs: 180.8, dateHint: "today", tolerance: 0.8 }],
    ["/v1/extract-weight-mutation", "Change today's weight to 179.8", { action: "update", weightLbs: 179.8, dateHint: "today" }],
    ["/v1/extract-weight-mutation", "Delete yesterday's weight", { action: "delete", dateHint: "yesterday" }],
    ["/v1/extract-weight-mutation", "Clear all my weight entries", { action: "delete_all" }],
    ["/v1/extract-weight-mutation", "What is my weight trend?", { action: "reply" }],
    ["/v1/extract-goal", "Set my calorie goal to 2100", { change: ["calories", "set", 2100] }],
    ["/v1/extract-goal", "Change protein to 175 grams", { change: ["protein", "set", 175] }],
    ["/v1/extract-goal", "Set 2400 calories and 35g fiber", { changes: [["calories", "set", 2400], ["fiber", "set", 35]] }],
    ["/v1/extract-goal", "Lower my calorie goal by 200", { change: ["calories", "decrease", 200] }],
    ["/v1/extract-goal", "Set my water goal to 90 ounces", { change: ["water_oz", "set", 90] }],
    ["/v1/extract-goal", "Change my target weight to 165 pounds", { change: ["target_weight_lbs", "set", 165] }],
    ["/v1/parse-data-query", "How many calories are left today?", { query: ["calories", "remaining", "selected_day", null] }],
    ["/v1/parse-data-query", "Average protein for the last 7 days", { query: ["protein", "average", "last_n_days", 7] }],
    ["/v1/parse-data-query", "Total water today", { query: ["water", "total", "selected_day", null] }],
    ["/v1/parse-data-query", "What is my latest weight?", { query: ["weight", "latest", "selected_day", null] }],
    ["/v1/parse-data-query", "Weight change over the last 14 days", { query: ["weight", "change", "last_n_days", 14] }],
    ["/v1/parse-data-query", "Average calories over 30 days", { query: ["calories", "average", "last_n_days", 30] }],
  ],
  validation: [
    ["/v1/extract-water-mutation", "Please add 22 ounces of water", { action: "add", amountOz: 22 }],
    ["/v1/extract-water-mutation", "Track 750 milliliters of water", { action: "add", amountOz: 25.4, tolerance: 0.8 }],
    ["/v1/extract-water-mutation", "I finished three cups of water", { action: "add", amountOz: 24 }],
    ["/v1/extract-water-mutation", "Make today's hydration total 80 ounces", { action: "update_total", amountOz: 80 }],
    ["/v1/extract-water-mutation", "Erase today's hydration entries", { action: "delete_all" }],
    ["/v1/extract-water-mutation", "Do I need more water?", { action: "reply" }],
    ["/v1/extract-weight-mutation", "Record 176.6 lbs today", { action: "add", weightLbs: 176.6, dateHint: "today" }],
    ["/v1/extract-weight-mutation", "Today I am 79.5 kilograms", { action: "add", weightLbs: 175.3, dateHint: "today", tolerance: 0.8 }],
    ["/v1/extract-weight-mutation", "Correct today's weigh-in to 175.2", { action: "update", weightLbs: 175.2, dateHint: "today" }],
    ["/v1/extract-weight-mutation", "Remove my latest weigh-in", { action: "delete", dateHint: "latest" }],
    ["/v1/extract-weight-mutation", "Delete my entire weight history", { action: "delete_all" }],
    ["/v1/extract-weight-mutation", "Am I losing weight?", { action: "reply" }],
    ["/v1/extract-goal", "Make my daily calories 2250", { change: ["calories", "set", 2250] }],
    ["/v1/extract-goal", "Increase carbs by 40 grams", { change: ["carbs", "increase", 40] }],
    ["/v1/extract-goal", "Use 180g protein and 70g fat", { changes: [["protein", "set", 180], ["fat", "set", 70]] }],
    ["/v1/extract-goal", "Reduce fiber by 5 grams", { change: ["fiber", "decrease", 5] }],
    ["/v1/extract-goal", "My hydration target should be 88 oz", { change: ["water_oz", "set", 88] }],
    ["/v1/extract-goal", "Set a goal weight of 172.5 pounds", { change: ["target_weight_lbs", "set", 172.5] }],
    ["/v1/parse-data-query", "How much protein remains for this day?", { query: ["protein", "remaining", "selected_day", null] }],
    ["/v1/parse-data-query", "What was my mean fiber intake for 10 days?", { query: ["fiber", "average", "last_n_days", 10] }],
    ["/v1/parse-data-query", "How much water did I drink on this day?", { query: ["water", "total", "selected_day", null] }],
    ["/v1/parse-data-query", "Show the newest weight entry", { query: ["weight", "latest", "selected_day", null] }],
    ["/v1/parse-data-query", "Trend my weight across 21 days", { query: ["weight", "trend", "last_n_days", 21] }],
    ["/v1/parse-data-query", "Total carbs during the past 5 days", { query: ["carbs", "total", "last_n_days", 5] }],
  ],
  holdout2: [
    ["/v1/extract-water-mutation", "Pour 30 ounces into today's water log", { action: "add", amountOz: 30 }],
    ["/v1/extract-water-mutation", "Log 1.25 liters of water", { action: "add", amountOz: 42.3, tolerance: 0.8 }],
    ["/v1/extract-water-mutation", "Four cups of water just now", { action: "add", amountOz: 32 }],
    ["/v1/extract-water-mutation", "Update hydration to exactly 96 ounces", { action: "update_total", amountOz: 96 }],
    ["/v1/extract-water-mutation", "Remove every water record for this date", { action: "delete_all" }],
    ["/v1/extract-water-mutation", "What's left to hit my hydration target?", { action: "reply" }],
    ["/v1/extract-weight-mutation", "The scale read 169.2 lb this morning", { action: "add", weightLbs: 169.2, dateHint: "today" }],
    ["/v1/extract-weight-mutation", "Enter 74.8 kilograms for today", { action: "add", weightLbs: 164.9, dateHint: "today", tolerance: 0.8 }],
    ["/v1/extract-weight-mutation", "Replace today's measurement with 168.7 lb", { action: "update", weightLbs: 168.7, dateHint: "today" }],
    ["/v1/extract-weight-mutation", "Remove yesterday morning's weight", { action: "delete", dateHint: "yesterday" }],
    ["/v1/extract-weight-mutation", "Purge all recorded weights", { action: "delete_all" }],
    ["/v1/extract-weight-mutation", "Summarize my progress on the scale", { action: "reply" }],
    ["/v1/extract-goal", "Set my daily fat target at 68 grams", { change: ["fat", "set", 68] }],
    ["/v1/extract-goal", "Bump my protein target up by 15 grams", { change: ["protein", "increase", 15] }],
    ["/v1/extract-goal", "Make it 2150 calories and 210 grams of carbs", { changes: [["calories", "set", 2150], ["carbs", "set", 210]] }],
    ["/v1/extract-goal", "Take 4 grams off my fiber goal", { change: ["fiber", "decrease", 4] }],
    ["/v1/extract-goal", "Use 3 liters as my daily water target", { change: ["water_oz", "set", 101.4] }],
    ["/v1/extract-goal", "My target body weight is 70 kilograms", { change: ["target_weight_lbs", "set", 154.3] }],
    ["/v1/parse-data-query", "How many calories have I logged on this date?", { query: ["calories", "total", "selected_day", null] }],
    ["/v1/parse-data-query", "Give me average fat for the past two weeks", { query: ["fat", "average", "last_n_days", 14] }],
    ["/v1/parse-data-query", "Hydration total for the selected date", { query: ["water", "total", "selected_day", null] }],
    ["/v1/parse-data-query", "Which weigh-in is most recent?", { query: ["weight", "latest", "selected_day", null] }],
    ["/v1/parse-data-query", "Protein consumed across the last 3 days", { query: ["protein", "total", "last_n_days", 3] }],
    ["/v1/parse-data-query", "How did my weight change over four weeks?", { query: ["weight", "change", "last_n_days", 28] }],
  ],
};

const sourceCases = [
  ["transactional chat mutations", [
    ["Nomva/Views/Chat/ChatView.swift", "commitMutation\\("],
    ["Nomva/Views/Chat/ChatView.swift", "modelContext\\.rollback\\(\\)"],
  ]],
  ["single active calorie goal across screens", [
    ["Nomva/Views/Chat/ChatView.swift", "GoalService\\.currentGoal"],
    ["Nomva/Views/Log/DailyLogView.swift", "GoalService\\.currentGoal"],
    ["Nomva/Views/Settings/GoalsSettingsView.swift", "GoalService\\.currentGoal"],
    ["Nomva/Services/NomvaWidgetSyncBridge.swift", "GoalService\\.currentGoal"],
  ]],
  ["duplicate food suppression", [
    ["server/index.js", "sanitizeFoodMentions"],
    ["Nomva/Services/FoodLoggingService.swift", "deduplicatedFoodMentions"],
    ["Nomva/Services/FoodLoggingService.swift", "foodIdentityKey"],
  ]],
  ["typed meal move", [
    ["Nomva/Services/LLMProvider.swift", "case moveFood"],
    ["Nomva/Views/Chat/ChatView.swift", "case \\.moveEntry"],
  ]],
  ["favorites and meal-confirmed quick add", [
    ["Nomva/Models/DataModels.swift", "isFavorite"],
    ["Nomva/Views/Log/DailyLogView.swift", "showQuickAddMealPicker"],
  ]],
  ["meal template save and reuse", [
    ["Nomva/Views/Log/DailyLogView.swift", "showTemplateNamePrompt"],
    ["Nomva/Services/FoodLoggingService.swift", "handleMealTemplateReuse"],
  ]],
  ["barcode recovery into custom food", [
    ["Nomva/Views/Chat/ChatView.swift", "CustomFoodCreateView\\(initialBarcode:"],
    ["Nomva/Models/DataModels.swift", "var barcode: String\\?"],
  ]],
  ["complete export and restore", [
    ["Nomva/Services/ExportService.swift", "water:\\s*\\[WaterEntry\\]"],
    ["Nomva/Services/ExportService.swift", "SyncMigrationService\\.Archive"],
    ["Nomva/Views/Settings/ExportSettingsView.swift", "SyncMigrationService\\.merge"],
  ]],
  ["AI privacy disclosure and deletion", [
    ["Nomva/Views/Settings/LLMProviderSettingsView.swift", "up to 90 days"],
    ["Nomva/Views/Settings/LLMProviderSettingsView.swift", "Delete Cloud Analytics"],
    ["server/index.js", "/v1/privacy/analytics"],
  ]],
  ["coherent VoiceOver food rows", [
    ["Nomva/Views/Log/DailyLogView.swift", "accessibilityElement\\(children: \\.ignore\\)"],
    ["Nomva/Views/Log/DailyLogView.swift", "accessibilityActions"],
  ]],
  ["reduced-motion coverage", [
    ["Nomva/Views/Chat/ChatView.swift", "accessibilityReduceMotion"],
    ["Nomva/Views/Components/HydrationSheetView.swift", "accessibilityReduceMotion"],
    ["Nomva/Views/Weight/WeightLoggingView.swift", "accessibilityReduceMotion"],
  ]],
  ["visible undo across logs", [
    ["Nomva/Views/Log/DailyLogView.swift", "Button\\(\"Undo\""],
    ["Nomva/Views/Components/HydrationSheetView.swift", "Button\\(\"Undo\""],
    ["Nomva/Views/Weight/WeightLoggingView.swift", "Button\\(\"Undo\""],
  ]],
  ["cancel retry and progress stages", [
    ["Nomva/Views/Chat/ChatView.swift", "cancelActiveRequest"],
    ["Nomva/Views/Chat/ChatView.swift", "Label\\(\"Retry\""],
    ["Nomva/Views/Chat/ChatView.swift", "processingStage"],
  ]],
  ["TestFlight complimentary access", [
    ["Nomva/Services/SubscriptionManager.swift", "AppTransaction\\.shared"],
    ["Nomva/Services/SubscriptionManager.swift", "environment == \\.sandbox"],
    ["Nomva/Views/Settings/PaywallView.swift", "Continue Testing"],
  ]],
];

const databaseRowCache = new Map();
let foodDatabase;
let inspectDatabaseRowStatement;

function getFoodDatabaseRowStatement() {
  if (!foodDatabase) {
    foodDatabase = new Database(FOOD_DB_PATH, {
      readonly: true,
      fileMustExist: true,
    });
    inspectDatabaseRowStatement = foodDatabase.prepare(
      "SELECT id, name, brand, source, calories FROM foods WHERE id = ? LIMIT 1"
    );
  }
  return inspectDatabaseRowStatement;
}

function closeFoodDatabase() {
  if (!foodDatabase) return;
  foodDatabase.close();
  foodDatabase = undefined;
  inspectDatabaseRowStatement = undefined;
}

function inspectDatabaseRow(candidateId) {
  const rowId = Number(String(candidateId || "").replace(/^db_/, ""));
  if (!Number.isInteger(rowId) || rowId <= 0) return null;
  if (databaseRowCache.has(rowId)) return databaseRowCache.get(rowId);
  try {
    const row = getFoodDatabaseRowStatement().get(rowId) || null;
    databaseRowCache.set(rowId, row);
    return row;
  } catch {
    return null;
  }
}

function hasTraceableWebProvenance(body) {
  const source = String(body?.source || "");
  const quality = String(body?.quality || "");
  const confidence = Number(body?.confidence);
  let sourceUrl;
  try {
    sourceUrl = new URL(String(body?.sourceUrl || ""));
  } catch {
    return false;
  }
  const expectedQuality = source === "web_published" ? "published" : "estimated";
  return ["web_published", "web_estimate"].includes(source)
    && quality === expectedQuality
    && sourceUrl.protocol === "https:"
    && sourceUrl.hostname.length > 3
    && String(body?.sourceTitle || "").trim().length > 3
    && Number.isFinite(confidence)
    && confidence >= (source === "web_published" ? 0.75 : 0.5);
}

function resolvedCalories(body, databaseRow) {
  const perServing = databaseRow
    ? Number(databaseRow.calories)
    : Number(body?.caloriesPerServing);
  const servings = Number(body?.servings);
  return Number.isFinite(perServing) && Number.isFinite(servings)
    ? perServing * servings
    : NaN;
}

function findMention(mentions, food) {
  const expectedTokens = normalize(food[0]).split(" ").filter((token) => token.length > 2);
  const best = mentions
    .map((mention) => ({
      mention,
      overlap: expectedTokens.filter((token) => normalize(mention).includes(token)).length,
    }))
    .sort((left, right) => right.overlap - left.overlap)[0];
  return best?.overlap > 0 ? best.mention : null;
}

function buildFoodCases() {
  const catalog = foodCatalogs[SET];
  const meals = ["breakfast", "lunch", "dinner", "snack"];
  const singles = catalog.map((food, index) => ({
    category: "food retrieval",
    foods: [food],
    meal: meals[index % meals.length],
    message: SET === "train"
      ? [`I had ${food[0]} for ${meals[index % 4]}`, `Log ${meals[index % 4]}: ${food[0]}`][index % 2]
      : SET === "validation"
        ? [`Please track ${food[0]} as my ${meals[index % 4]}`, `For ${meals[index % 4]}, I ended up having ${food[0]}`][index % 2]
        : [`Put ${food[0]} into ${meals[index % 4]}`, `${meals[index % 4]} included ${food[0]}`][index % 2],
  }));
  const pairs = catalog.map((food, index) => {
    const second = catalog[(index + 11) % catalog.length];
    const meal = meals[(index + 1) % meals.length];
    return {
      category: "multi-food retrieval",
      foods: [food, second],
      meal,
      message: SET === "train"
        ? `For ${meal} I had ${food[0]} and ${second[0]}`
        : SET === "validation"
          ? `${meal}: ${food[0]}, plus ${second[0]}`
          : `Add both ${food[0]} and ${second[0]} to ${meal}`,
    };
  });
  return [...singles, ...pairs];
}

function buildCases() {
  const cases = [];

  for (const foodCase of buildFoodCases()) {
    cases.push({
      ...foodCase,
      async run(api) {
        const plan = foodCase.foods.length > 1
          ? await api.request("/v1/plan-food-log", { userMessage: foodCase.message })
          : null;
        const split = !plan || plan.status !== 200
          ? await api.request("/v1/split-foods", { userMessage: foodCase.message })
          : null;
        const plannedItems = Array.isArray(plan?.body?.items) ? plan.body.items : [];
        const mentions = plannedItems.length
          ? plannedItems.map((item) => item.mention)
          : Array.isArray(split?.body?.foods) ? split.body.foods : [];
        const semanticStatus = plannedItems.length ? plan.status : split?.status;
        const checks = [
          assertion("semantic food plan status", semanticStatus === 200, 200, semanticStatus, true),
          assertion("distinct food count", mentions.length === foodCase.foods.length, foodCase.foods.length, mentions, true),
          assertion("no duplicate mentions", new Set(mentions.map(normalize)).size === mentions.length, "all unique", mentions, true),
        ];
        const resolutions = await Promise.all(foodCase.foods.map(async (food) => {
          const mention = findMention(mentions, food);
          if (!mention) return { food, mention: null, response: null };
          const plannedItem = plannedItems.find((item) => item.mention === mention);
          const response = await api.request("/v1/resolve-food-candidate", {
            userMessage: foodCase.message,
            foodMention: mention,
            searchQuery: plannedItem?.searchQuery || mention,
            resolutionHint: plannedItem?.kind || "",
          });
          return { food, mention, response };
        }));
        for (const { food, mention, response } of resolutions) {
          checks.push(assertion(`mention ${food[0]}`, Boolean(mention), food[0], mentions, true));
          if (!response) continue;
          const row = inspectDatabaseRow(response.body.candidateId);
          const identity = `${response.body.name || ""} ${response.body.brand || ""}`;
          const calories = resolvedCalories(response.body, row);
          const traceable = Boolean(row) || hasTraceableWebProvenance(response.body);
          checks.push(assertion(`resolve ${food[0]}`, response.status === 200, 200, response.status, true));
          checks.push(assertion(`identity ${food[0]}`, foodIdentityMatches(identity, food[0], food[1]), food[1], identity, true));
          checks.push(assertion(
            `traceable nutrition provenance ${food[0]}`,
            traceable,
            "USDA/database row or source-backed web nutrition",
            { candidateId: response.body.candidateId, source: response.body.source, sourceUrl: response.body.sourceUrl },
            true
          ));
          checks.push(assertion(
            `calorie plausibility ${food[0]}`,
            Number.isFinite(calories) && calories >= food[2] && calories <= food[3],
            [food[2], food[3]],
            Number.isFinite(calories) ? Math.round(calories * 10) / 10 : null
          ));
        }
        return { checks, observed: { mentions, resolutions: resolutions.map((item) => item.response?.body || null) } };
      },
    });
  }

  for (const [message, expectedIntent] of intentSets[SET]) {
    cases.push({
      category: "intent and context",
      message,
      async run(api) {
        const response = await api.request("/v1/classify-intent", {
          userMessage: message,
          recentMessages: message.includes("that") || message.includes("both")
            ? [
              { role: "user", content: "I had soup and bread" },
              { role: "assistant", content: "✓ Soup\n✓ Bread" },
            ]
            : [],
        });
        return {
          checks: [
            assertion("intent status", response.status === 200, 200, response.status, true),
            assertion("intent", response.body.intent === expectedIntent, expectedIntent, response.body.intent, true),
          ],
          observed: response.body,
        };
      },
    });
  }

  for (const contextCase of contextCases(SET)) {
    cases.push({
      ...contextCase,
      async run(api) {
        const response = await api.request(contextCase.route, {
          userMessage: contextCase.message,
          ...contextCase.body,
        });
        return {
          checks: [
            assertion("context route status", response.status === 200, 200, response.status, true),
            ...contextCase.verify(response.body),
          ],
          observed: response.body,
        };
      },
    });
  }

  for (const [message, expectedPatterns] of splitSets[SET]) {
    cases.push({
      category: "compound and duplicate guard",
      message,
      async run(api) {
        const response = await api.request("/v1/split-foods", { userMessage: `I had ${message}` });
        const foods = Array.isArray(response.body.foods) ? response.body.foods : [];
        const checks = [
          assertion("split status", response.status === 200, 200, response.status, true),
          assertion("smallest independent set", foods.length === expectedPatterns.length, expectedPatterns.length, foods, true),
          assertion("no duplicate output", new Set(foods.map(normalize)).size === foods.length, "all unique", foods, true),
        ];
        for (const pattern of expectedPatterns) {
          checks.push(assertion(`contains ${pattern}`, foods.some((food) => matches(food, pattern)), pattern, foods, true));
        }
        return { checks, observed: foods };
      },
    });
  }

  for (const [message, mention, servings, portionPattern] of servingMealSets[SET].servings) {
    cases.push({
      category: "portion extraction",
      message,
      async run(api) {
        const response = await api.request("/v1/extract-servings", {
          userMessage: message,
          foodMention: mention,
          candidateName: mention,
        });
        const checks = [
            assertion("portion status", response.status === 200, 200, response.status, true),
            assertion("portion description", matches(response.body.portionDescription, portionPattern), portionPattern, response.body.portionDescription),
            assertion("explicit portion", response.body.hasExplicitPortion === true, true, response.body.hasExplicitPortion, true),
        ];
        if (servings != null) {
          const tolerance = Math.max(0.05, Math.abs(servings) * 0.08);
          checks.splice(1, 0, assertion(
            "serving amount",
            Math.abs(Number(response.body.servings) - servings) <= tolerance,
            servings,
            response.body.servings,
            true
          ));
        }
        return {
          checks,
          observed: response.body,
        };
      },
    });
  }

  for (const [message, meal] of servingMealSets[SET].meals) {
    cases.push({
      category: "meal routing",
      message,
      async run(api) {
        const response = await api.request("/v1/extract-meal", { userMessage: message });
        return {
          checks: [
            assertion("meal status", response.status === 200, 200, response.status, true),
            assertion("meal", response.body.meal === meal, meal, response.body.meal, true),
          ],
          observed: response.body,
        };
      },
    });
  }

  for (const [route, message, expected] of mutationSets[SET]) {
    cases.push({
      category: route.includes("water") ? "water CRUD"
        : route.includes("weight") ? "weight CRUD"
          : route.includes("goal") ? "goal CRUD" : "data query",
      message,
      async run(api) {
        const response = await api.request(route, { userMessage: message });
        const checks = [assertion("mutation status", response.status === 200, 200, response.status, true)];
        for (const [key, expectedValue] of Object.entries(expected)) {
          if (["tolerance", "change", "changes", "query"].includes(key)) continue;
          const actual = response.body[key];
          if (typeof expectedValue === "number") {
            checks.push(assertion(
              key,
              Math.abs(Number(actual) - expectedValue) <= (expected.tolerance || 0.25),
              expectedValue,
              actual,
              true
            ));
          } else {
            checks.push(assertion(key, actual === expectedValue, expectedValue, actual, true));
          }
        }
        const changes = Array.isArray(response.body.changes) ? response.body.changes : [];
        for (const changeExpectation of expected.changes || (expected.change ? [expected.change] : [])) {
          const [metric, operation, value] = changeExpectation;
          const found = changes.some((change) =>
            change.metric === metric
            && change.operation === operation
            && Math.abs(Number(change.value) - value) <= 0.25
          );
          checks.push(assertion(`goal ${metric}`, found, changeExpectation, changes, true));
        }
        if (expected.query) {
          const [metric, aggregation, window, days] = expected.query;
          const queries = Array.isArray(response.body.queries) ? response.body.queries : [];
          const found = queries.some((query) =>
            query.metric === metric
            && query.aggregation === aggregation
            && query.window === window
            && (days == null || query.days === days)
          );
          checks.push(assertion("data query", found, expected.query, queries, true));
        }
        return { checks, observed: response.body };
      },
    });
  }

  for (const [name, patterns] of sourceCases) {
    cases.push({
      category: "client capability",
      message: name,
      async run() {
        const checks = patterns.map(([file, pattern]) =>
          assertion(
            `${name}: ${file}`,
            matches(read(file), pattern),
            pattern,
            "source inspection",
            true
          )
        );
        return { checks, observed: patterns.map(([file]) => file) };
      },
    });
  }

  const edgeCases = [
    {
      message: "health endpoint",
      async run(api) {
        const response = await api.request("/health", {}, { method: "GET" });
        return { checks: [assertion("health", response.status === 200 && response.body.status === "ok", "ok", response.body, true)], observed: response.body };
      },
    },
    {
      message: "authenticated session",
      async run(api) {
        return { checks: [assertion("session token", Boolean(api.token), "token", Boolean(api.token), true)], observed: { authenticated: Boolean(api.token) } };
      },
    },
    {
      message: "missing food mention is rejected",
      async run(api) {
        const response = await api.request("/v1/resolve-food-candidate", { userMessage: "food" });
        return { checks: [assertion("safe 400", response.status === 400, 400, response.status, true)], observed: response.body };
      },
    },
    {
      message: "cloud analytics deletion",
      async run(api) {
        const response = await api.request("/v1/privacy/analytics", {}, { method: "DELETE" });
        return { checks: [assertion("privacy delete", response.status === 200 && response.body.ok === true, "HTTP 200 and ok", response, true)], observed: response.body };
      },
    },
    {
      message: "zero-sugar drink remains noncaloric",
      async run(api) {
        const response = await api.request("/v1/resolve-food-candidate", { userMessage: "I had a diet cola", foodMention: "diet cola" });
        const row = inspectDatabaseRow(response.body.candidateId);
        const calories = resolvedCalories(response.body, row);
        return { checks: [
          assertion("diet drink resolved", response.status === 200, 200, response.status, true),
          assertion("diet drink provenance", Boolean(row) || hasTraceableWebProvenance(response.body), "traceable", response.body.source, true),
          assertion("diet drink calories", Number.isFinite(calories) && calories <= 10, "<= 10", calories, true),
        ], observed: response.body };
      },
    },
    {
      message: "common typo retrieval",
      async run(api) {
        const response = await api.request("/v1/resolve-food-candidate", { userMessage: "I ate blueberies", foodMention: "blueberies" });
        return { checks: [
          assertion("typo resolved", response.status === 200, 200, response.status, true),
          assertion("typo identity", matches(response.body.name, "blueberr"), "blueberries", response.body.name, true),
        ], observed: response.body };
      },
    },
    {
      message: "cultural food retrieval",
      async run(api) {
        const term = SET === "train" ? "doro wat" : SET === "validation" ? "baba ganoush" : "shakshuka";
        const identityPattern = SET === "train"
          ? "doro|chicken.*stew"
          : SET === "validation" ? "baba.*ganoush|eggplant" : "shakshuka|egg.*tomato";
        const response = await api.request("/v1/resolve-food-candidate", { userMessage: `I ate ${term}`, foodMention: term });
        return { checks: [
          assertion("cultural food resolved", response.status === 200, 200, response.status, true),
          assertion("cultural food identity", matches(response.body.name, identityPattern), term, response.body.name, true),
        ], observed: response.body };
      },
    },
    {
      message: "bounded unknown-food failure",
      async run(api) {
        const startedAt = Date.now();
        const response = await api.request("/v1/resolve-food-candidate", {
          userMessage: "I ate xqzv lunar paste",
          foodMention: "xqzv lunar paste",
        });
        const durationMs = Date.now() - startedAt;
        return { checks: [
          assertion("no server crash", response.status < 500, "status below 500", response.status, true),
          assertion("bounded response", durationMs <= MAX_REQUEST_MS + 5_000, `<= ${MAX_REQUEST_MS + 5_000}ms`, durationMs, true),
        ], observed: { status: response.status, durationMs, body: response.body } };
      },
    },
    {
      message: "production prompts are food-agnostic",
      async run() {
        const prompts = read("server/prompts.js");
        const screenshotSpecific = /chick-fil-a|duck egg|waffle potato fries|gree yogurt/i.test(prompts);
        return { checks: [assertion("no screenshot-specific prompt exceptions", !screenshotSpecific, "absent", screenshotSpecific, true)], observed: { screenshotSpecific } };
      },
    },
    {
      message: "assistant Markdown is rendered",
      async run() {
        const source = read("Nomva/Views/Chat/ChatView.swift");
        return { checks: [assertion("Markdown rendering", matches(source, "AttributedString\\s*\\(\\s*markdown:"), "AttributedString(markdown:)", "source inspection", true)], observed: {} };
      },
    },
  ];
  cases.push(...edgeCases.map((edgeCase) => ({ category: "resilience and trust", ...edgeCase })));

  if (cases.length !== 200) {
    throw new Error(`Release gate must contain exactly 200 cases, found ${cases.length}`);
  }
  return cases.map((testCase, index) => ({
    id: `${SET === "train" ? "T" : SET === "validation" ? "V" : "H"}${String(index + 1).padStart(3, "0")}`,
    ...testCase,
  }));
}

async function runWithConcurrency(items, worker) {
  const results = new Array(items.length);
  let nextIndex = 0;
  async function consume() {
    while (true) {
      const index = nextIndex;
      nextIndex += 1;
      if (index >= items.length) return;
      results[index] = await worker(items[index], index);
    }
  }
  await Promise.all(Array.from({ length: CONCURRENCY }, consume));
  return results;
}

async function main() {
  if (!fs.existsSync(FOOD_DB_PATH)) {
    throw new Error(`Missing bundled food database: ${FOOD_DB_PATH}`);
  }
  const cases = buildCases();
  if (DRY_RUN) {
    const categories = cases.reduce((counts, testCase) => {
      counts[testCase.category] = (counts[testCase.category] || 0) + 1;
      return counts;
    }, {});
    console.log(JSON.stringify({ set: SET, cases: cases.length, categories }, null, 2));
    closeFoodDatabase();
    return;
  }
  const api = new NomvaAPI();
  await api.register();
  console.log(`Running ${SET} release gate: ${cases.length} cases, concurrency ${CONCURRENCY}`);

  const results = await runWithConcurrency(cases, async (testCase, index) => {
    const startedAt = Date.now();
    let execution;
    try {
      execution = await testCase.run(api);
    } catch (error) {
      execution = {
        checks: [assertion("case execution", false, "completed", error.message, true)],
        observed: { error: error.message },
      };
    }
    const checks = execution.checks || [];
    const passed = checks.length > 0 && checks.every((check) => check.passed);
    const result = {
      id: testCase.id,
      category: testCase.category,
      message: testCase.message,
      passed,
      score: checks.length
        ? Math.round(checks.filter((check) => check.passed).length / checks.length * 1000) / 10
        : 0,
      durationMs: Date.now() - startedAt,
      checks,
      observed: execution.observed,
    };
    console.log(`${String(index + 1).padStart(3, "0")}/200 ${result.id} ${passed ? "PASS" : "FAIL"} ${result.category} | ${result.message}`);
    return result;
  });

  const allChecks = results.flatMap((result) => result.checks);
  const durations = results.map((result) => result.durationMs);
  const passedCases = results.filter((result) => result.passed).length;
  const passedChecks = allChecks.filter((check) => check.passed).length;
  const criticalFailures = allChecks.filter((check) => check.critical && !check.passed).length;
  const byCategory = {};
  for (const result of results) {
    byCategory[result.category] ||= { cases: 0, passed: 0, checks: 0, passedChecks: 0 };
    const bucket = byCategory[result.category];
    bucket.cases += 1;
    bucket.passed += result.passed ? 1 : 0;
    bucket.checks += result.checks.length;
    bucket.passedChecks += result.checks.filter((check) => check.passed).length;
  }
  for (const bucket of Object.values(byCategory)) {
    bucket.caseAccuracy = Math.round(bucket.passed / bucket.cases * 1000) / 10;
    bucket.checkAccuracy = Math.round(bucket.passedChecks / bucket.checks * 1000) / 10;
  }

  const summary = {
    set: SET,
    cases: results.length,
    passedCases,
    failedCases: results.length - passedCases,
    caseAccuracy: Math.round(passedCases / results.length * 1000) / 10,
    checks: allChecks.length,
    passedChecks,
    checkAccuracy: Math.round(passedChecks / allChecks.length * 1000) / 10,
    criticalFailures,
    meets95Gate: passedCases / results.length >= 0.95
      && passedChecks / allChecks.length >= 0.95
      && criticalFailures === 0
      && Object.values(byCategory).every((bucket) => bucket.caseAccuracy >= 95),
    latencyMs: {
      median: percentile(durations, 0.5),
      p95: percentile(durations, 0.95),
      max: Math.max(...durations),
    },
    byCategory,
  };

  const report = {
    runId: `nomva-product-${SET}-200-${new Date().toISOString().replace(/[:.]/g, "-")}`,
    generatedAt: new Date().toISOString(),
    target: BASE_URL,
    methodology: {
      cases: 200,
      dataset: SET,
      note: "Synthetic product scenarios exercise deployed semantic endpoints, server-side database retrieval, the bundled nutrition database, multi-turn references, and production client capability invariants. Training, first validation, and second holdout use separate language and food catalogs; 14 client capability and 10 resilience invariants intentionally remain common release requirements.",
    },
    summary,
    results,
    requests: api.requests,
  };

  fs.mkdirSync(REPORT_DIR, { recursive: true });
  const reportPath = path.join(REPORT_DIR, `${report.runId}.json`);
  const latestPath = path.join(REPORT_DIR, `latest-${SET}-200.json`);
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
  fs.writeFileSync(latestPath, JSON.stringify(report, null, 2));
  console.log(JSON.stringify(summary, null, 2));
  console.log(`Report: ${reportPath}`);
  closeFoodDatabase();
  process.exitCode = summary.meets95Gate ? 0 : 2;
}

main().catch((error) => {
  closeFoodDatabase();
  console.error(error);
  process.exitCode = 1;
});
