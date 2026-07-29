#!/usr/bin/env node

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const ROOT = path.join(__dirname, "..");
const DEFAULT_BASE_URL = "https://nomva.nerdquad.com";
const BASE_URL = process.env.NOMVA_POWER_TEST_BASE_URL || DEFAULT_BASE_URL;
const REPORT_DIR = process.env.NOMVA_POWER_TEST_REPORT_DIR
  || path.join(ROOT, "reports", "power-test");
const MAX_LATENCY_MS = Number(process.env.NOMVA_POWER_TEST_MAX_LATENCY_MS || 20_000);
const MAX_JOURNEY_LATENCY_MS = Number(
  process.env.NOMVA_POWER_TEST_MAX_JOURNEY_LATENCY_MS || 5_000
);

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function normalize(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function matches(value, pattern) {
  return new RegExp(pattern, "i").test(String(value || ""));
}

function read(relativePath) {
  return fs.readFileSync(path.join(ROOT, relativePath), "utf8");
}

function percentile(values, percentileValue) {
  if (!values.length) return null;
  const sorted = [...values].sort((left, right) => left - right);
  const index = Math.min(
    sorted.length - 1,
    Math.max(0, Math.ceil(percentileValue * sorted.length) - 1)
  );
  return sorted[index];
}

function addCheck(checks, name, passed, expected, actual, severity = "major") {
  checks.push({
    name,
    passed: Boolean(passed),
    severity,
    expected,
    actual,
  });
}

function pathValue(object, dottedPath) {
  return dottedPath.split(".").reduce((value, key) => value?.[key], object);
}

class NomvaAPI {
  constructor(baseURL) {
    this.baseURL = baseURL.replace(/\/$/, "");
    this.userId = `codex-power-test-${Date.now()}`;
    this.deviceToken = `power-test-device-${Date.now()}`;
    this.token = null;
    this.requests = [];
  }

  commonHeaders() {
    const headers = {
      "Content-Type": "application/json",
      "X-Nomva-User-ID": this.userId,
      "X-Nomva-Device-Token": this.deviceToken,
      "X-Nomva-App-Attest-Mode": "simulator",
    };
    if (this.token) headers.Authorization = `Bearer ${this.token}`;
    return headers;
  }

  async request(route, body, options = {}) {
    const startedAt = Date.now();
    let attempts = 0;
    while (attempts < 4) {
      attempts += 1;
      const response = await fetch(`${this.baseURL}${route}`, {
        method: options.method || "POST",
        headers: this.commonHeaders(),
        body: options.method === "GET" ? undefined : JSON.stringify(body || {}),
      });
      const durationMs = Date.now() - startedAt;
      const raw = await response.text();
      let json = null;
      try {
        json = raw ? JSON.parse(raw) : {};
      } catch {
        json = { raw };
      }

      if (response.status === 429 && attempts < 4) {
        const retryAfterSeconds = Number(response.headers.get("retry-after") || 61);
        await sleep(Math.max(1, retryAfterSeconds) * 1000);
        continue;
      }

      this.requests.push({
        route,
        status: response.status,
        durationMs,
        attempts,
      });

      if (!response.ok && !options.allowFailure) {
        const error = new Error(
          `${route} returned ${response.status}: ${JSON.stringify(json)}`
        );
        error.status = response.status;
        error.body = json;
        error.durationMs = durationMs;
        throw error;
      }
      return {
        status: response.status,
        body: json,
        durationMs,
      };
    }
    throw new Error(`${route} exhausted retries`);
  }

  async register() {
    const response = await this.request("/v1/auth/register", {
      nomvaUserId: this.userId,
      deviceToken: this.deviceToken,
    });
    this.token = response.body.token;
    if (!this.token) throw new Error("Nomva Cloud did not issue a session token");
    return response;
  }

  async post(route, body, options) {
    return this.request(route, body, options);
  }
}

const personas = [];
let nextPersonaId = 1;

function addPersona(cohort, profile, journey) {
  personas.push({
    id: nextPersonaId,
    personaId: `U${String(nextPersonaId).padStart(3, "0")}`,
    cohort,
    profile,
    ...journey,
  });
  nextPersonaId += 1;
}

function foodJourney({
  message,
  meal = null,
  foods,
  feedback,
  difficulty = "medium",
}) {
  return {
    kind: "food",
    difficulty,
    message,
    expected: { meal, foods },
    feedback,
  };
}

function mutationJourney({
  message,
  route,
  expected,
  body = {},
  feedback,
  difficulty = "medium",
  classifyIntent = null,
}) {
  return {
    kind: "mutation",
    difficulty,
    message,
    route,
    requestBody: body,
    expected,
    feedback,
    classifyIntent,
  };
}

function sourceJourney({
  title,
  checks,
  feedback,
  difficulty = "medium",
}) {
  return {
    kind: "source",
    difficulty,
    message: title,
    sourceChecks: checks,
    feedback,
  };
}

const everydayFoodCases = [
  {
    profile: "New calorie tracker who eats a plain breakfast",
    message: "Log breakfast: Greek yogurt, blueberries, and black coffee",
    meal: "breakfast",
    foods: [
      { concept: "Greek yogurt", pattern: "greek.*yogurt|yogurt.*greek", calories: [40, 350] },
      { concept: "blueberries", pattern: "blueberr", calories: [30, 180] },
      { concept: "black coffee", pattern: "coffee", calories: [0, 20] },
    ],
  },
  {
    profile: "Parent logging a homemade dinner in one sentence",
    message: "Dinner was a sloppy joe with a side of corn",
    meal: "dinner",
    foods: [
      { concept: "sloppy joe", pattern: "sloppy.*joe", calories: [150, 700] },
      { concept: "corn", pattern: "corn", calories: [30, 300] },
    ],
  },
  {
    profile: "Office worker using short meal shorthand",
    message: "Breakfast: two scrambled eggs, toast, and bacon",
    meal: "breakfast",
    foods: [
      { concept: "scrambled eggs", pattern: "egg", calories: [90, 350], portion: "2|two" },
      { concept: "toast", pattern: "toast|bread", calories: [40, 250] },
      { concept: "bacon", pattern: "bacon", calories: [30, 400] },
    ],
  },
  {
    profile: "Gym beginner logging a basic meal prep lunch",
    message: "For lunch I had grilled chicken breast, white rice, and broccoli",
    meal: "lunch",
    foods: [
      { concept: "grilled chicken breast", pattern: "chicken.*breast|breast.*chicken", calories: [80, 500] },
      { concept: "white rice", pattern: "rice", calories: [80, 450] },
      { concept: "broccoli", pattern: "broccoli", calories: [10, 180] },
    ],
  },
  {
    profile: "Home cook logging a whole-food dinner",
    message: "I ate salmon, a sweet potato, and asparagus for dinner",
    meal: "dinner",
    foods: [
      { concept: "salmon", pattern: "salmon", calories: [90, 500] },
      { concept: "sweet potato", pattern: "sweet.*potato|potato.*sweet", calories: [50, 350] },
      { concept: "asparagus", pattern: "asparagus", calories: [5, 150] },
    ],
  },
  {
    profile: "Busy commuter logging lunch without punctuation",
    message: "turkey sandwich and an apple for lunch",
    meal: "lunch",
    foods: [
      { concept: "turkey sandwich", pattern: "turkey.*sandwich|sandwich.*turkey", calories: [150, 750] },
      { concept: "apple", pattern: "apple", calories: [30, 180] },
    ],
  },
  {
    profile: "Runner logging a pre-run breakfast",
    message: "Oatmeal with banana and peanut butter for breakfast",
    meal: "breakfast",
    foods: [
      { concept: "oatmeal", pattern: "oatmeal|oat", calories: [80, 450] },
      { concept: "banana", pattern: "banana", calories: [50, 200] },
      { concept: "peanut butter", pattern: "peanut.*butter", calories: [70, 350] },
    ],
  },
  {
    profile: "Student logging a simple Mexican-style dinner",
    message: "Dinner: 2 beef tacos, rice, and black beans",
    meal: "dinner",
    foods: [
      { concept: "beef tacos", pattern: "taco", calories: [150, 900], portion: "2|two" },
      { concept: "rice", pattern: "rice", calories: [80, 450] },
      { concept: "black beans", pattern: "black.*bean|bean.*black", calories: [70, 400] },
    ],
  },
  {
    profile: "Family cook logging a mixed Italian dinner",
    message: "I had spaghetti and meatballs plus a side salad",
    meal: null,
    foods: [
      { concept: "spaghetti", pattern: "spaghetti|pasta", calories: [120, 700] },
      { concept: "meatballs", pattern: "meatball", calories: [80, 700] },
      { concept: "side salad", pattern: "salad", calories: [10, 450] },
    ],
  },
  {
    profile: "Teen logging a cereal breakfast",
    message: "A bowl of Cheerios with milk and strawberries for breakfast",
    meal: "breakfast",
    foods: [
      { concept: "Cheerios", pattern: "cheerio", calories: [70, 350] },
      { concept: "milk", pattern: "milk", calories: [30, 300] },
      { concept: "strawberries", pattern: "strawberr", calories: [15, 180] },
    ],
  },
];

for (const testCase of everydayFoodCases) {
  addPersona(
    "Everyday meal logging",
    testCase.profile,
    foodJourney({
      ...testCase,
      feedback: "Make one-sentence multi-food logging reliably complete without follow-up cleanup.",
      difficulty: "medium",
    })
  );
}

const brandedFoodCases = [
  ["Soda drinker tracking zero-calorie beverages", "I had a 20 oz Cherry Coke Zero", null, [{ concept: "Cherry Coke Zero", pattern: "coke.*zero|coca.*cola.*zero", calories: [0, 10], portion: "20.*oz|20.*ounce" }]],
  ["Chick-fil-A customer counting a partial order", "For lunch I had 3 Chick-fil-A nuggets", "lunch", [{ concept: "Chick-fil-A nuggets", pattern: "chick.*fil|chicken.*nugget", calories: [60, 180], portion: "3|three" }]],
  ["Chick-fil-A customer sharing fries", "I ate about 5 Chick-fil-A waffle fries", null, [{ concept: "Chick-fil-A waffle fries", pattern: "waffle.*fr", calories: [15, 180], portion: "5|five" }]],
  ["Coffee-shop customer logging a standard menu drink", "Grande caffè mocha from Starbucks for lunch", "lunch", [{ concept: "Starbucks grande caffè mocha", pattern: "mocha|caff", calories: [120, 550] }]],
  ["Fast-food customer logging a named sandwich", "I had a McDonald's Big Mac for dinner", "dinner", [{ concept: "McDonald's Big Mac", pattern: "big.*mac", calories: [400, 800] }]],
  ["Wendy's customer using a piece count", "Six Wendy's chicken nuggets", null, [{ concept: "Wendy's chicken nuggets", pattern: "wendy|chicken.*nugget", calories: [120, 450], portion: "6|six" }]],
  ["High-protein shopper logging a branded yogurt", "Oikos Triple Zero vanilla Greek yogurt", null, [{ concept: "Oikos Triple Zero Greek yogurt", pattern: "oikos|greek.*yogurt", calories: [50, 250] }]],
  ["High-protein shopper logging a bottled shake", "One Fairlife Core Power chocolate shake", null, [{ concept: "Fairlife Core Power", pattern: "fairlife|core.*power|protein.*shake", calories: [80, 350] }]],
  ["Parent logging a packaged snack", "I ate one strawberry Pop-Tart", null, [{ concept: "strawberry Pop-Tart", pattern: "pop.*tart", calories: [120, 300], portion: "1|one" }]],
  ["Drive-through customer logging breakfast", "Breakfast was a sausage Egg McMuffin and hash brown", "breakfast", [{ concept: "Sausage Egg McMuffin", pattern: "mcmuffin", calories: [250, 700] }, { concept: "hash brown", pattern: "hash.*brown", calories: [80, 400] }]],
];

for (const [profile, message, meal, foods] of brandedFoodCases) {
  addPersona(
    "Branded and packaged foods",
    profile,
    foodJourney({
      message,
      meal,
      foods,
      feedback: "Preserve brand, product variant, and real serving size instead of silently choosing a generic substitute.",
      difficulty: "hard",
    })
  );
}

const diverseFoodCases = [
  ["Indian-food regular", "Chicken tikka masala with basmati rice for dinner", "dinner", [{ concept: "chicken tikka masala", pattern: "tikka.*masala|masala", calories: [150, 800] }, { concept: "basmati rice", pattern: "basmati|rice", calories: [80, 450] }]],
  ["Vegetarian Indian-food regular", "Lunch was dal, naan, and cucumber raita", "lunch", [{ concept: "dal", pattern: "dal|lentil", calories: [70, 500] }, { concept: "naan", pattern: "naan", calories: [100, 500] }, { concept: "raita", pattern: "raita|yogurt", calories: [20, 300] }]],
  ["Vietnamese-food fan", "A large bowl of chicken pho", null, [{ concept: "chicken pho", pattern: "pho", calories: [250, 1_100] }]],
  ["Japanese-food fan", "Dinner: spicy tuna roll and miso soup", "dinner", [{ concept: "spicy tuna roll", pattern: "tuna.*roll|sushi", calories: [120, 700] }, { concept: "miso soup", pattern: "miso.*soup", calories: [20, 250] }]],
  ["Mexican-food fan", "Three carnitas street tacos with salsa verde", null, [{ concept: "carnitas street tacos", pattern: "carnitas|taco", calories: [250, 1_100], portion: "3|three" }, { concept: "salsa verde", pattern: "salsa", calories: [5, 200] }]],
  ["Mediterranean brunch eater", "Shakshuka with one piece of pita for breakfast", "breakfast", [{ concept: "shakshuka", pattern: "shakshuka|egg", calories: [100, 650] }, { concept: "pita", pattern: "pita", calories: [50, 350] }]],
  ["Ethiopian-food fan", "I had doro wat with injera", null, [{ concept: "doro wat", pattern: "doro|chicken.*stew", calories: [120, 800] }, { concept: "injera", pattern: "injera", calories: [50, 450] }]],
  ["Korean-food fan", "Bibimbap with tofu for dinner", "dinner", [{ concept: "tofu bibimbap", pattern: "bibimbap", calories: [250, 1_000] }]],
  ["Thai-food fan who avoids meat", "Tofu pad thai for lunch", "lunch", [{ concept: "tofu pad thai", pattern: "pad.*thai", calories: [250, 1_100] }]],
  ["Middle Eastern-food fan", "Falafel, hummus, tabbouleh, and pita", null, [{ concept: "falafel", pattern: "falafel", calories: [80, 650] }, { concept: "hummus", pattern: "hummus", calories: [50, 450] }, { concept: "tabbouleh", pattern: "tabbouleh|tabouli", calories: [30, 400] }, { concept: "pita", pattern: "pita", calories: [50, 350] }]],
];

for (const [profile, message, meal, foods] of diverseFoodCases) {
  addPersona(
    "Cultural foods and dietary variety",
    profile,
    foodJourney({
      message,
      meal,
      foods,
      feedback: "Broaden culturally diverse prepared-food coverage and ask a useful portion question only when the database truly cannot support a reasonable default.",
      difficulty: "hard",
    })
  );
}

const portionFoodCases = [
  ["Macro tracker weighing yogurt", "150 g plain nonfat Greek yogurt", [{ concept: "plain nonfat Greek yogurt", pattern: "greek.*yogurt|yogurt.*greek", calories: [60, 180], portion: "150.*g|150.*gram" }]],
  ["Bodybuilder weighing cooked protein", "6 oz grilled chicken breast", [{ concept: "grilled chicken breast", pattern: "chicken.*breast", calories: [180, 420], portion: "6.*oz|6.*ounce" }]],
  ["Diabetic user measuring starch", "Half a cup of cooked brown rice", [{ concept: "cooked brown rice", pattern: "brown.*rice|rice.*brown", calories: [70, 220], portion: "half|1/2|0.5" }]],
  ["Peanut-butter fan using tablespoons", "2 tbsp creamy peanut butter", [{ concept: "creamy peanut butter", pattern: "peanut.*butter", calories: [140, 260], portion: "2.*tbsp|2.*table" }]],
  ["Snack eater using an imprecise handful", "A small handful of almonds", [{ concept: "almonds", pattern: "almond", calories: [70, 300] }]],
  ["Keto user eating a fractional avocado", "One third of a medium avocado", [{ concept: "avocado", pattern: "avocado", calories: [60, 180], portion: "third|1/3|0.33" }]],
  ["Cook using fluid ounces", "8 fl oz unsweetened almond milk", [{ concept: "unsweetened almond milk", pattern: "almond.*milk", calories: [15, 100], portion: "8.*oz|8.*ounce|1.*cup" }]],
  ["Baker logging a fraction", "One and a half blueberry muffins", [{ concept: "blueberry muffins", pattern: "blueberr.*muffin|muffin", calories: [180, 850], portion: "1.5|one and a half" }]],
  ["User logging restaurant share", "I ate a quarter of a large pepperoni pizza", [{ concept: "pepperoni pizza", pattern: "pepperoni.*pizza|pizza.*pepperoni", calories: [250, 1_200], portion: "quarter|1/4|0.25" }]],
  ["User measuring a mixed dish by weight", "320 grams homemade beef chili", [{ concept: "beef chili", pattern: "chili", calories: [180, 700], portion: "320.*g|320.*gram" }]],
];

for (const [profile, message, foods] of portionFoodCases) {
  addPersona(
    "Portions and measurements",
    profile,
    foodJourney({
      message,
      foods,
      feedback: "Keep the user's stated amount visible and scale nutrition from the selected database serving without unit distortion.",
      difficulty: "hard",
    })
  );
}

const salmonRiceHistory = [
  { role: "user", content: "Had salmon and rice" },
  { role: "assistant", content: "✓ Salmon (1 serving) — 250 cal\n✓ Rice (1 serving) — 170 cal" },
];
const afterRiceDeleteHistory = [
  ...salmonRiceHistory,
  { role: "user", content: "Delete that" },
  { role: "assistant", content: "Removed: Rice." },
];
const coffeeCorrectionHistory = [
  { role: "user", content: "I had coffee for lunch" },
  { role: "assistant", content: "✓ Black coffee (1 serving) — 4 cal" },
  { role: "user", content: "It was a grande mocha from Starbucks" },
  { role: "assistant", content: "✓ Updated Black coffee to Caff Mocha Chilled Espresso Beverage" },
];

const contextCases = [
  mutationJourney({
    message: "Delete that",
    route: "/v1/pick-delete-targets",
    body: { recentMessages: salmonRiceHistory, logSummary: "Salmon (dinner)\nRice (dinner)" },
    expected: [{ path: "foodNames", arrayPatterns: ["salmon", "rice"] }],
    feedback: "Treat a grouped assistant confirmation as one action when the user says “that.”",
    difficulty: "ridiculous",
    classifyIntent: "delete_food",
  }),
  mutationJourney({
    message: "Both",
    route: "/v1/pick-delete-targets",
    body: { recentMessages: afterRiceDeleteHistory, logSummary: "Salmon (dinner)" },
    expected: [{ path: "foodNames", arrayPatterns: ["salmon"] }],
    feedback: "Resolve short follow-ups from the actual remaining state, not stale conversation text.",
    difficulty: "ridiculous",
    classifyIntent: "delete_food",
  }),
  mutationJourney({
    message: "the other one too",
    route: "/v1/pick-delete-targets",
    body: { recentMessages: afterRiceDeleteHistory, logSummary: "Salmon (dinner)" },
    expected: [{ path: "foodNames", arrayPatterns: ["salmon"] }],
    feedback: "Use the previous delete result to identify the remaining item.",
    difficulty: "ridiculous",
    classifyIntent: "delete_food",
  }),
  mutationJourney({
    message: "No, delete that",
    route: "/v1/pick-delete-targets",
    body: { recentMessages: coffeeCorrectionHistory, logSummary: "Caff Mocha Chilled Espresso Beverage (lunch)" },
    expected: [{ path: "foodNames", arrayPatterns: ["mocha|caff"] }],
    feedback: "A direct delete correction must mutate data instead of replying with a nutrition recap.",
    difficulty: "ridiculous",
    classifyIntent: "delete_food",
  }),
  mutationJourney({
    message: "Actually it was black coffee",
    route: "/v1/resolve-edit-request",
    body: {
      currentEntryName: "Coffee",
      currentPortionDescription: "1 serving",
      recentMessages: coffeeCorrectionHistory,
    },
    expected: [
      { path: "replacementSearchQuery", pattern: "black.*coffee" },
      { path: "hasExplicitPortion", equals: true },
    ],
    feedback: "Identity corrections should replace the original row atomically.",
    difficulty: "hard",
    classifyIntent: "edit_food",
  }),
  mutationJourney({
    message: "Actually only about 5 fries",
    route: "/v1/resolve-edit-request",
    body: {
      currentEntryName: "Chick-Fil-A, Waffle Potato Fries, Large",
      currentEntryBrand: "Chick-Fil-A",
      currentPortionDescription: "1 large",
    },
    expected: [
      { path: "portionDescription", pattern: "5.*fr" },
      { path: "hasExplicitPortion", equals: true },
    ],
    feedback: "A quantity correction should edit the existing item, not add a duplicate.",
    difficulty: "hard",
    classifyIntent: "edit_food",
  }),
  mutationJourney({
    message: "Make the nuggets six instead",
    route: "/v1/resolve-edit-request",
    body: {
      currentEntryName: "Chicken Nuggets",
      currentPortionDescription: "3 nuggets",
    },
    expected: [
      { path: "servings", approximately: 6, tolerance: 0.2 },
      { path: "portionDescription", pattern: "6.*nugget" },
    ],
    feedback: "Keep edit target and portion in one turn.",
    difficulty: "hard",
    classifyIntent: "edit_food",
  }),
  mutationJourney({
    message: "Change the yogurt to two servings",
    route: "/v1/pick-edit-target",
    body: {
      recentMessages: [],
      logSummary: "Greek Yogurt (1 serving, breakfast)\nBlueberries (1 cup, breakfast)",
    },
    expected: [{ path: "foodName", pattern: "greek.*yogurt|yogurt" }],
    feedback: "Named edits should never require a redundant clarification.",
    difficulty: "medium",
    classifyIntent: "edit_food",
  }),
  mutationJourney({
    message: "Delete breakfast",
    route: "/v1/pick-delete-targets",
    body: {
      recentMessages: [],
      logSummary: "Greek Yogurt (breakfast)\nBlueberries (breakfast)\nBlack coffee (breakfast)\nChicken Salad (lunch)",
    },
    expected: [{ path: "foodNames", arrayPatterns: ["greek.*yogurt", "blueberr", "coffee"] }],
    feedback: "Bulk meal deletion should be one operation with an accurate count.",
    difficulty: "hard",
    classifyIntent: "delete_food",
  }),
  sourceJourney({
    title: "Move the yogurt from snack to lunch in chat",
    checks: [
      {
        file: "Nomva/Services/FoodLoggingService.swift",
        missingPattern: "case\\s+moveEntry|case\\s+moveFood|case\\s+setMeal",
        expectedCapability: "a chat action that can change an existing entry's meal",
      },
    ],
    feedback: "Add a first-class AI meal reassignment action; drag-and-drop alone does not cover conversational corrections.",
    difficulty: "hard",
  }),
];

const contextProfiles = [
  "User deleting a two-item message by reference",
  "User correcting an incomplete prior delete",
  "User using natural follow-up wording",
  "User rejecting the most recent corrected item",
  "User correcting beverage identity",
  "User correcting an exaggerated portion",
  "User changing a count in place",
  "User editing a named breakfast item",
  "User bulk-deleting one meal",
  "User correcting a meal assignment in chat",
];

for (let index = 0; index < contextCases.length; index += 1) {
  addPersona("Multi-turn corrections and food CRUD", contextProfiles[index], contextCases[index]);
}

const hydrationAndWeightCases = [
  ["Hydration beginner adding ounces", mutationJourney({ message: "I drank 16 oz of water", route: "/v1/extract-water-mutation", expected: [{ path: "action", equals: "add" }, { path: "amountOz", approximately: 16, tolerance: 0.2 }], classifyIntent: "log_water", feedback: "Keep quick water logging immediate and show the new total." })],
  ["Metric hydration user", mutationJourney({ message: "Add 500 ml of water", route: "/v1/extract-water-mutation", expected: [{ path: "action", equals: "add" }, { path: "amountOz", approximately: 16.9, tolerance: 0.7 }], classifyIntent: "log_water", feedback: "Accept metric input while respecting the user's preferred display unit." })],
  ["Bottle-based hydration user", mutationJourney({ message: "Had another 24 ounce bottle of water", route: "/v1/extract-water-mutation", expected: [{ path: "action", equals: "add" }, { path: "amountOz", approximately: 24, tolerance: 0.3 }], classifyIntent: "log_water", feedback: "Remember a user's usual bottle size for future “another bottle” messages." })],
  ["Hydration user correcting the daily total", mutationJourney({ message: "Set today's water total to 72 oz", route: "/v1/extract-water-mutation", expected: [{ path: "action", equals: "update_total" }, { path: "amountOz", approximately: 72, tolerance: 0.2 }], classifyIntent: "log_water", feedback: "Make set-total distinct from add-water and confirm the resulting total." })],
  ["Hydration user clearing an accidental log", mutationJourney({ message: "Delete all water from today", route: "/v1/extract-water-mutation", expected: [{ path: "action", equals: "delete_all" }, { path: "amountOz", equals: null }], classifyIntent: "log_water", feedback: "Clear only the selected date and make that date explicit in the reply." })],
  ["Pounds user logging a weigh-in", mutationJourney({ message: "I weigh 181.4 pounds today", route: "/v1/extract-weight-mutation", expected: [{ path: "action", equals: "add" }, { path: "weightLbs", approximately: 181.4, tolerance: 0.2 }, { path: "dateHint", equals: "today" }], classifyIntent: "log_weight", feedback: "Log precise decimals and the intended date in one turn." })],
  ["Kilograms user logging a weigh-in", mutationJourney({ message: "Log 82 kg today", route: "/v1/extract-weight-mutation", expected: [{ path: "action", equals: "add" }, { path: "weightLbs", approximately: 180.8, tolerance: 0.8 }, { path: "dateHint", equals: "today" }], classifyIntent: "log_weight", feedback: "Store consistently but display in the user's chosen unit." })],
  ["User correcting today's weight", mutationJourney({ message: "Change today's weight to 179.8", route: "/v1/extract-weight-mutation", expected: [{ path: "action", equals: "update" }, { path: "weightLbs", approximately: 179.8, tolerance: 0.2 }, { path: "dateHint", equals: "today" }], classifyIntent: "log_weight", feedback: "Update rather than duplicate the existing date." })],
  ["User deleting yesterday's weigh-in", mutationJourney({ message: "Delete yesterday's weight", route: "/v1/extract-weight-mutation", expected: [{ path: "action", equals: "delete" }, { path: "dateHint", equals: "yesterday" }], classifyIntent: "log_weight", feedback: "Confirm the exact date and value removed." })],
  ["Long-term user clearing weight history", mutationJourney({ message: "Clear all my weight entries", route: "/v1/extract-weight-mutation", expected: [{ path: "action", equals: "delete_all" }], classifyIntent: "log_weight", feedback: "Require a destructive confirmation in the client before deleting all historical weights." })],
];

for (const [profile, journey] of hydrationAndWeightCases) {
  addPersona("Hydration and weight CRUD", profile, journey);
}

const goalAndQueryCases = [
  ["Calorie-focused user", mutationJourney({ message: "Set my calorie goal to 2100", route: "/v1/extract-goal", expected: [{ path: "calories", approximately: 2100, tolerance: 0.2 }], classifyIntent: "set_goal", feedback: "Show old and new goal values and make them undoable." })],
  ["Protein-focused lifter", mutationJourney({ message: "Change protein to 175 grams", route: "/v1/extract-goal", expected: [{ path: "protein", approximately: 175, tolerance: 0.2 }], classifyIntent: "set_goal", feedback: "Update one macro without changing the others." })],
  ["Power user setting every macro", mutationJourney({ message: "Set 2400 calories, 190g protein, 250g carbs, 70g fat, and 35g fiber", route: "/v1/extract-goal", expected: [{ path: "calories", approximately: 2400 }, { path: "protein", approximately: 190 }, { path: "carbs", approximately: 250 }, { path: "fat", approximately: 70 }, { path: "fiber", approximately: 35 }], classifyIntent: "set_goal", feedback: "Show a compact diff before applying a multi-field goal change." })],
  ["User making a relative calorie change", mutationJourney({ message: "Lower my calorie goal by 200", route: "/v1/extract-goal", body: { currentGoals: { calories: 2200 } }, expected: [{ path: "calories", approximately: 2000, tolerance: 0.2 }], classifyIntent: "set_goal", feedback: "Pass current goals into relative-change parsing; isolated extraction cannot calculate “by 200.”", difficulty: "hard" })],
  ["Hydration-goal user", sourceJourney({ title: "Set my water goal to 90 ounces through chat", checks: [{ file: "Nomva/Views/Chat/ChatView.swift", pattern: "case\\s+\"water_oz\"", expectedCapability: "a chat action for changing the hydration goal" }], feedback: "Let chat update the hydration goal instead of only water entries.", difficulty: "hard" })],
  ["Weight-goal user", sourceJourney({ title: "Change my target weight to 165 pounds through chat", checks: [{ file: "Nomva/Views/Chat/ChatView.swift", pattern: "case\\s+\"target_weight_lbs\"", expectedCapability: "a chat action for target weight" }], feedback: "Separate target-weight goals from daily macro goals and support both in chat.", difficulty: "hard" })],
  ["User asking what remains today", mutationJourney({ message: "How many calories and grams of protein do I have left today?", route: "/v1/general-reply", body: { context: "GOALS: 2000 cal, 150g protein. SELECTED DAY: 1250 cal, 92g protein. Remaining: 750 cal and 58g protein.", recentMessages: [] }, expected: [{ path: "text", pattern: "750" }, { path: "text", pattern: "58.*protein|protein.*58" }], classifyIntent: "query_data", feedback: "Answer with the requested numbers first, without a lecture." })],
  ["Hydration user checking progress", mutationJourney({ message: "How much water do I have left today?", route: "/v1/general-reply", body: { context: "HYDRATION: goal 64 oz. Today: 40 oz.", recentMessages: [] }, expected: [{ path: "text", pattern: "24.*oz|24.*ounce" }], classifyIntent: "query_data", feedback: "Use hydration state directly and avoid arithmetic ambiguity." })],
  ["Trend-focused user asking about weight", mutationJourney({ message: "Am I losing weight over the last two weeks?", route: "/v1/general-reply", body: { context: "WEIGHT HISTORY: Jul 12 182.0 lbs; Jul 19 180.8 lbs; Jul 26 179.9 lbs.", recentMessages: [] }, expected: [{ path: "text", pattern: "los|down|decreas|2.1" }], classifyIntent: "query_data", feedback: "Give the trend, time window, and caveat in a short answer." })],
  ["Macro user asking about a week", mutationJourney({ message: "What was my average protein for the last 7 days?", route: "/v1/general-reply", body: { context: "DAILY HISTORY: 140g, 150g, 130g, 160g, 145g, 155g, 150g protein.", recentMessages: [] }, expected: [{ path: "text", pattern: "147|approximately 147|about 147" }], classifyIntent: "query_data", feedback: "Calculate aggregates from structured data instead of improvising." })],
];

for (const [profile, journey] of goalAndQueryCases) {
  addPersona("Goals, macros, and data questions", profile, journey);
}

const messyFoodCases = [
  ["Fast typist making a common typo", "Gree yogurt and blueberies", [{ concept: "Greek yogurt", pattern: "greek.*yogurt|yogurt.*greek", calories: [40, 350] }, { concept: "blueberries", pattern: "blueberr", calories: [30, 180] }]],
  ["Voice-dictation user with filler words", "Uh I had like two eggs and maybe a piece of toast", [{ concept: "eggs", pattern: "egg", calories: [80, 320], portion: "2|two" }, { concept: "toast", pattern: "toast|bread", calories: [40, 250] }]],
  ["User with no punctuation", "lunch chicken rice avocado", [{ concept: "chicken", pattern: "chicken", calories: [70, 500] }, { concept: "rice", pattern: "rice", calories: [70, 450] }, { concept: "avocado", pattern: "avocado", calories: [40, 350] }]],
  ["User using abbreviations", "6oz chx breast + 1c rice", [{ concept: "chicken breast", pattern: "chicken.*breast", calories: [180, 420], portion: "6.*oz|6.*ounce" }, { concept: "rice", pattern: "rice", calories: [100, 450], portion: "1.*cup|1c" }]],
  ["User correcting autocorrect", "I had a bowel of oatmeal", [{ concept: "bowl of oatmeal", pattern: "oatmeal|oat", calories: [80, 450] }]],
  ["Spanish-English bilingual user", "Comí dos huevos con toast for breakfast", [{ concept: "two eggs", pattern: "egg|huevo", calories: [80, 320], portion: "2|two|dos" }, { concept: "toast", pattern: "toast|bread", calories: [40, 250] }]],
  ["British-English user", "Porridge with 200 ml semi-skimmed milk", [{ concept: "porridge", pattern: "porridge|oatmeal|oat", calories: [80, 450] }, { concept: "semi-skimmed milk", pattern: "milk", calories: [50, 180], portion: "200.*ml" }]],
  ["User entering fractions as symbols", "½ cup cottage cheese", [{ concept: "cottage cheese", pattern: "cottage.*cheese", calories: [60, 220], portion: "½|1/2|0.5|half" }]],
  ["User logging a zero-calorie typo", "20oz chery coke zerro", [{ concept: "Cherry Coke Zero", pattern: "coke.*zero|coca.*cola.*zero", calories: [0, 10], portion: "20.*oz|20.*ounce" }]],
  ["User logging a sentence with irrelevant context", "Running late, but I grabbed a banana and a black coffee before work", [{ concept: "banana", pattern: "banana", calories: [50, 200] }, { concept: "black coffee", pattern: "coffee", calories: [0, 20] }]],
];

for (const [profile, message, foods] of messyFoodCases) {
  addPersona(
    "Messy language, voice, and locale",
    profile,
    foodJourney({
      message,
      foods,
      feedback: "Normalize spelling, speech filler, abbreviations, and locale-specific food language before retrieval while preserving critical modifiers.",
      difficulty: "ridiculous",
    })
  );
}

const workflowCases = [
  sourceJourney({
    title: "Search and manually log a food when chat is unavailable",
    checks: [
      { file: "Nomva/Views/Log/ManualFoodSearchView.swift", pattern: "searchFoodsForManualEntry", expectedCapability: "manual food search" },
      { file: "Nomva/Views/Log/ManualFoodDetailView.swift", pattern: "Button\\(\"Log It\"\\)", expectedCapability: "manual log confirmation" },
    ],
    feedback: "Keep manual logging fully functional and easy to reach as a dependable fallback.",
  }),
  sourceJourney({
    title: "Create and reuse a custom food",
    checks: [
      { file: "Nomva/Views/CustomFood/CustomFoodCreateView.swift", pattern: "saveCustomFood", expectedCapability: "custom food creation" },
      { file: "Nomva/Services/FoodLoggingService.swift", pattern: "buildCustomCandidates", expectedCapability: "custom food retrieval in chat" },
    ],
    feedback: "After saving, surface the custom food immediately in search, chat, and recent foods.",
  }),
  sourceJourney({
    title: "Move a food from snack to breakfast by drag and VoiceOver",
    checks: [
      { file: "Nomva/Views/Log/DailyLogView.swift", pattern: "\\.draggable\\(", expectedCapability: "drag source" },
      { file: "Nomva/Views/Log/DailyLogView.swift", pattern: "\\.dropDestination\\(", expectedCapability: "meal drop target" },
      { file: "Nomva/Views/Log/DailyLogView.swift", pattern: "Button\\(\"Move to", expectedCapability: "accessible move action" },
    ],
    feedback: "Keep drag-and-drop, but also add an obvious Move action because drag is undiscoverable for many users.",
  }),
  sourceJourney({
    title: "Edit and delete an existing food manually",
    checks: [
      { file: "Nomva/Views/Log/FoodEntryEditView.swift", pattern: "saveChanges", expectedCapability: "entry editing" },
      { file: "Nomva/Views/Log/FoodEntryEditView.swift", pattern: "Delete Entry", expectedCapability: "entry deletion" },
    ],
    feedback: "Show the recalculated calories before save and offer undo after deletion.",
  }),
  sourceJourney({
    title: "Review a food photo before logging",
    checks: [
      { file: "Nomva/Views/Chat/PhotoFoodReviewView.swift", pattern: "Tap each item to adjust servings and meal time", expectedCapability: "per-item review" },
      { file: "Nomva/Views/Chat/PhotoFoodReviewView.swift", pattern: "loggedIndices", expectedCapability: "selective photo logging" },
    ],
    feedback: "Never auto-save uncertain photo estimates; preserve per-item correction before commit.",
  }),
  sourceJourney({
    title: "Scan a barcode that is not in the local database",
    checks: [
      { file: "Nomva/Views/Chat/ChatView.swift", pattern: "Search by Name", expectedCapability: "barcode recovery guidance" },
      { file: "Nomva/Views/Chat/ChatView.swift", pattern: "showCustomFoodCreate|CustomFoodCreateView", expectedCapability: "one-tap custom-food recovery from barcode failure" },
    ],
    feedback: "Offer Create Custom Food with the barcode prefilled, not just a dead-end message.",
  }),
  sourceJourney({
    title: "Export a coach report and a full backup",
    checks: [
      { file: "Nomva/Views/Settings/ExportSettingsView.swift", pattern: "Generate CSV Report", expectedCapability: "coach CSV" },
      { file: "Nomva/Views/Settings/ExportSettingsView.swift", pattern: "Export JSON Backup", expectedCapability: "full JSON backup" },
      { file: "Nomva/Services/ExportService.swift", pattern: "waterEntries:", expectedCapability: "hydration included in the coach CSV" },
      { file: "Nomva/Services/SyncMigrationService.swift", pattern: "customFoods:|chatMessages:|userProfiles:", expectedCapability: "all user-created records included in the full backup" },
    ],
    feedback: "Include hydration, meal names, units, goals, and data provenance in exports.",
  }),
  sourceJourney({
    title: "Quick-add a frequently eaten food",
    checks: [
      { file: "Nomva/Views/Components/RecentFoodsView.swift", pattern: "Quick add", expectedCapability: "recent food quick-add" },
      { file: "Nomva/Views/Components/RecentFoodsView.swift", pattern: "favorite|pinned", expectedCapability: "pinned favorite foods" },
    ],
    feedback: "Let users pin favorites and choose the meal before quick-add commits.",
  }),
  sourceJourney({
    title: "Open a widget directly to water, weight, or food logging",
    checks: [
      { file: "Nomva/Shared/NomvaWidgetShared.swift", pattern: "case hydration", expectedCapability: "hydration deep link" },
      { file: "Nomva/Shared/NomvaWidgetShared.swift", pattern: "case weightLog", expectedCapability: "weight deep link" },
      { file: "Nomva/Shared/NomvaWidgetShared.swift", pattern: "case manualSearch", expectedCapability: "food search deep link" },
    ],
    feedback: "Preserve the user's intended date and destination through every deep link.",
  }),
  sourceJourney({
    title: "Save and reuse a full meal template",
    checks: [
      { file: "Nomva/Models/DataModels.swift", pattern: "class MealTemplate", expectedCapability: "meal template model" },
      { file: "Nomva/Services/FoodLoggingService.swift", missingPattern: "mealTemplates\\.", expectedCapability: "meal template use in logging" },
    ],
    feedback: "Finish or remove the dormant meal-template feature; the model is passed into chat but currently unused.",
    difficulty: "hard",
  }),
];

const workflowProfiles = [
  "Offline-first user who distrusts chat",
  "User with a homemade protein bar",
  "User whose food landed in the wrong meal",
  "User correcting a manual entry",
  "User taking a photo of a mixed plate",
  "User scanning a niche packaged product",
  "User sharing data with a dietitian",
  "Repeat-breakfast power user",
  "Widget-first user",
  "Meal-prep user repeating saved meals",
];

for (let index = 0; index < workflowCases.length; index += 1) {
  addPersona("Non-chat workflows and speed", workflowProfiles[index], workflowCases[index]);
}

const resilienceCases = [
  sourceJourney({
    title: "Install a TestFlight build without being asked to pay",
    checks: [
      { file: "Nomva/Services/SubscriptionPolicy.swift", pattern: "sandboxReceipt", expectedCapability: "TestFlight complimentary access" },
      { file: "Nomva/Views/Settings/PaywallView.swift", pattern: "Continue Testing", expectedCapability: "TestFlight continuation" },
    ],
    feedback: "Keep TestFlight access automatic and never surface purchase or restore as the primary tester path.",
  }),
  sourceJourney({
    title: "Restore purchases after an App Store failure",
    checks: [
      { file: "Nomva/Services/SubscriptionPolicy.swift", pattern: "The App Store couldn't restore purchases right now", expectedCapability: "friendly StoreKit error" },
      { file: "Nomva/Services/SubscriptionPolicy.swift", absentPattern: "SKInternalErrorDomain", expectedCapability: "no internal error domain in user copy" },
    ],
    feedback: "Keep raw platform error domains out of buttons and persistent UI.",
  }),
  sourceJourney({
    title: "Try AI logging while offline",
    checks: [
      { file: "Nomva/Services/FoodLoggingService.swift", pattern: "No internet connection|You’re offline|You're offline", expectedCapability: "offline-specific feedback" },
      { file: "Nomva/Views/Log/ManualFoodSearchView.swift", pattern: "searchFoodsForManualEntry", expectedCapability: "offline manual fallback" },
      { file: "Nomva/Views/Chat/ChatView.swift", missingPattern: "showManualSearch|ManualFoodSearchView", expectedCapability: "one-tap manual fallback from the chat error" },
    ],
    feedback: "Offer a one-tap local-search fallback from the chat error.",
  }),
  sourceJourney({
    title: "Switch iCloud sync on and recover from a failure",
    checks: [
      { file: "Nomva/NomvaApp.swift", pattern: "fell back to local-only data", expectedCapability: "safe local fallback" },
      { file: "Nomva/Views/Settings/iCloudSyncSettingsView.swift", pattern: "backup before switching sync modes", expectedCapability: "migration explanation" },
    ],
    feedback: "Show last successful sync and a recoverable conflict summary, not only a mode toggle.",
  }),
  sourceJourney({
    title: "Use VoiceOver to understand nutrition and move food",
    checks: [
      { file: "Nomva/Views/Components/MacroRingsView.swift", pattern: "accessibilityLabel", expectedCapability: "nutrition summary labels" },
      { file: "Nomva/Views/Log/DailyLogView.swift", pattern: "accessibilityActions", expectedCapability: "accessible food move actions" },
      { file: "Nomva/Views/Log/DailyLogView.swift", pattern: "accessibilityElement\\(children: \\.ignore\\)", expectedCapability: "one coherent VoiceOver element per food row" },
    ],
    feedback: "Audit reading order and eliminate duplicate labels for each food row.",
  }),
  sourceJourney({
    title: "Use very large Dynamic Type",
    checks: [
      { file: "Nomva/Views/Chat/ChatView.swift", absentPattern: "dynamicTypeSize\\(", expectedCapability: "no hard cap on chat Dynamic Type" },
      { file: "Nomva/Views/Components/NomvaUI.swift", absentPattern: "minimumScaleFactor\\(0\\.", expectedCapability: "layouts that wrap instead of shrinking excessively" },
    ],
    feedback: "Test every primary screen at accessibility sizes and let controls grow vertically.",
  }),
  sourceJourney({
    title: "Use reduced motion and avoid decorative animation",
    checks: [
      { file: "Nomva/Views/Components/MacroRingsView.swift", pattern: "accessibilityReduceMotion", expectedCapability: "reduced-motion behavior" },
      { file: "Nomva/Views/Chat/ChatView.swift", missingPattern: "accessibilityReduceMotion", expectedCapability: "reduced-motion handling in chat" },
    ],
    feedback: "Apply reduced-motion handling consistently to chat insertion, progress rings, and sheets.",
  }),
  sourceJourney({
    title: "Delete the wrong food and immediately undo",
    checks: [
      { file: "Nomva/Views/Log/DailyLogView.swift", pattern: "undoManager", expectedCapability: "model undo registration" },
      { file: "Nomva/Views/Log/DailyLogView.swift", missingPattern: "Button\\(\"Undo\"|Text\\(\"Undo\"|Label\\(\"Undo\"", expectedCapability: "visible undo affordance" },
    ],
    feedback: "Add a visible, time-limited Undo after food, water, and weight deletion.",
  }),
  sourceJourney({
    title: "Understand what AI data leaves the phone",
    checks: [
      { file: "Nomva/Views/Settings/LLMProviderSettingsView.swift", pattern: "Nomva Cloud", expectedCapability: "AI processing disclosure" },
      { file: "Nomva/Views/Settings/LLMProviderSettingsView.swift", pattern: "on-device or private iCloud data store", expectedCapability: "local-storage disclosure" },
      { file: "Nomva/Views/Settings/LLMProviderSettingsView.swift", pattern: "Relevant recent food, water, weight, and goal summaries", expectedCapability: "disclosure that log context can be sent for AI questions" },
    ],
    feedback: "Add retention duration and deletion controls beside the AI disclosure.",
  }),
  sourceJourney({
    title: "Use the app one-handed and expect fast feedback",
    checks: [
      { file: "Nomva/Views/Chat/ChatView.swift", pattern: "isProcessing", expectedCapability: "loading state" },
      { file: "Nomva/Services/RemoteAPIProvider.swift", pattern: "timeout: TimeInterval = 15", expectedCapability: "bounded API wait" },
      { file: "Nomva/Views/Chat/ChatView.swift", pattern: "cancelActiveRequest|activeRequestTask\\?\\.cancel|Label\\(\"Retry\"", expectedCapability: "cancel or retry for an in-flight chat request" },
    ],
    feedback: "Stream progress by stage, allow cancel/retry, and target a sub-five-second median for ordinary logging.",
    difficulty: "hard",
  }),
];

const resilienceProfiles = [
  "External TestFlight tester",
  "Subscriber recovering purchases",
  "Commuter with no signal",
  "Multi-device iCloud user",
  "Blind VoiceOver user",
  "Low-vision Dynamic Type user",
  "Motion-sensitive user",
  "Error-prone user who needs undo",
  "Privacy-conscious user",
  "Impatient one-handed user",
];

for (let index = 0; index < resilienceCases.length; index += 1) {
  addPersona("Resilience, accessibility, and trust", resilienceProfiles[index], resilienceCases[index]);
}

if (personas.length !== 100) {
  throw new Error(`Power test must contain exactly 100 personas, found ${personas.length}`);
}

const FOOD_DB_PATH = path.join(ROOT, "Nomva", "Resources", "foods.sqlite");

function findMention(splitFoods, food) {
  const conceptTokens = normalize(food.concept).split(" ").filter((token) => token.length > 2);
  const ranked = splitFoods
    .map((mention) => {
      const mentionText = normalize(mention);
      const overlap = conceptTokens.filter((token) => mentionText.includes(token)).length;
      return { mention, overlap };
    })
    .sort((left, right) => right.overlap - left.overlap);
  return ranked[0]?.overlap > 0 ? ranked[0].mention : null;
}

function inspectResolvedFood(resolved) {
  const rowId = Number(resolved.rowId)
    || Number(String(resolved.candidateId || "").replace(/^db_/, ""));
  if (!Number.isFinite(rowId)) return null;
  try {
    const raw = execFileSync("sqlite3", [
      "-json",
      FOOD_DB_PATH,
      `SELECT id, name, brand, serving_desc, calories AS caloriesPerServing
       FROM foods
       WHERE id = ${Math.trunc(rowId)}
       LIMIT 1;`,
    ], { encoding: "utf8" });
    return JSON.parse(raw || "[]")[0] || null;
  } catch {
    return null;
  }
}

async function runFoodPersona(api, persona) {
  const checks = [];
  const timings = [];

  const intentResult = await api.post("/v1/classify-intent", {
    userMessage: persona.message,
    recentMessages: [],
  });
  timings.push(intentResult.durationMs);
  addCheck(
    checks,
    "intent",
    intentResult.body.intent === "log_food",
    "log_food",
    intentResult.body.intent
  );

  const splitResult = await api.post("/v1/split-foods", {
    userMessage: persona.message,
  });
  timings.push(splitResult.durationMs);
  const splitFoods = Array.isArray(splitResult.body.foods)
    ? splitResult.body.foods
    : [];
  addCheck(
    checks,
    "food_count",
    splitFoods.length === persona.expected.foods.length,
    persona.expected.foods.length,
    splitFoods
  );

  if (persona.expected.meal) {
    const mealResult = await api.post("/v1/extract-meal", {
      userMessage: persona.message,
    });
    timings.push(mealResult.durationMs);
    addCheck(
      checks,
      "meal",
      mealResult.body.meal === persona.expected.meal,
      persona.expected.meal,
      mealResult.body.meal
    );
  }

  const resolutions = [];
  for (const food of persona.expected.foods) {
    const mention = findMention(splitFoods, food);
    addCheck(
      checks,
      `split_${normalize(food.concept).replace(/\s+/g, "_")}`,
      Boolean(mention),
      food.concept,
      splitFoods
    );
    if (!mention) continue;

    const resolvedResult = await api.post(
      "/v1/resolve-food-candidate",
      {
        userMessage: persona.message,
        foodMention: mention,
      },
      { allowFailure: true }
    );
    timings.push(resolvedResult.durationMs);
    const resolved = resolvedResult.body || {};
    const identity = `${resolved.name || ""} ${resolved.brand || ""}`.trim();
    const inspected = resolvedResult.status === 200
      ? inspectResolvedFood(resolved)
      : null;
    const impliedCalories = inspected && Number.isFinite(Number(resolved.servings))
      ? inspected.caloriesPerServing * Number(resolved.servings)
      : null;

    addCheck(
      checks,
      `resolve_${normalize(food.concept).replace(/\s+/g, "_")}`,
      resolvedResult.status === 200,
      "HTTP 200 with a database-backed candidate",
      { status: resolvedResult.status, body: resolved },
      "critical"
    );
    if (resolvedResult.status === 200) {
      addCheck(
        checks,
        `identity_${normalize(food.concept).replace(/\s+/g, "_")}`,
        matches(identity, food.pattern),
        food.pattern,
        identity,
        "critical"
      );
      addCheck(
        checks,
        `database_row_${normalize(food.concept).replace(/\s+/g, "_")}`,
        Boolean(inspected),
        "candidate exists in the app's bundled database",
        resolved.candidateId,
        "critical"
      );
      addCheck(
        checks,
        `calories_${normalize(food.concept).replace(/\s+/g, "_")}`,
        Number.isFinite(impliedCalories)
          && impliedCalories >= food.calories[0]
          && impliedCalories <= food.calories[1],
        food.calories,
        impliedCalories == null ? null : Math.round(impliedCalories * 10) / 10,
        "critical"
      );
      if (food.portion) {
        addCheck(
          checks,
          `portion_${normalize(food.concept).replace(/\s+/g, "_")}`,
          matches(resolved.portionDescription, food.portion),
          food.portion,
          resolved.portionDescription,
          "major"
        );
      }
    }

    resolutions.push({
      concept: food.concept,
      mention,
      status: resolvedResult.status,
      identity,
      portionDescription: resolved.portionDescription || null,
      servings: resolved.servings ?? null,
      impliedCalories: impliedCalories == null
        ? null
        : Math.round(impliedCalories * 10) / 10,
      durationMs: resolvedResult.durationMs,
    });
  }

  return {
    checks,
    timings,
    observed: {
      intent: intentResult.body.intent,
      splitFoods,
      resolutions,
    },
  };
}

function evaluateExpected(checks, output, expected) {
  for (const expectation of expected) {
    const actual = pathValue(output, expectation.path);
    if (Object.prototype.hasOwnProperty.call(expectation, "equals")) {
      addCheck(
        checks,
        expectation.path,
        actual === expectation.equals,
        expectation.equals,
        actual
      );
    } else if (Object.prototype.hasOwnProperty.call(expectation, "approximately")) {
      const tolerance = expectation.tolerance ?? 0.2;
      addCheck(
        checks,
        expectation.path,
        Number.isFinite(Number(actual))
          && Math.abs(Number(actual) - expectation.approximately) <= tolerance,
        `${expectation.approximately} ± ${tolerance}`,
        actual
      );
    } else if (expectation.pattern) {
      addCheck(
        checks,
        expectation.path,
        matches(actual, expectation.pattern),
        expectation.pattern,
        actual
      );
    } else if (expectation.arrayPatterns) {
      const values = Array.isArray(actual) ? actual : [];
      const everyPatternFound = expectation.arrayPatterns.every((pattern) =>
        values.some((value) => matches(value, pattern))
      );
      addCheck(
        checks,
        expectation.path,
        everyPatternFound && values.length === expectation.arrayPatterns.length,
        expectation.arrayPatterns,
        values,
        "critical"
      );
    }
  }
}

async function runMutationPersona(api, persona) {
  const checks = [];
  const timings = [];
  let intent = null;

  if (persona.classifyIntent) {
    const recentMessages = persona.requestBody.recentMessages || [];
    const intentResult = await api.post("/v1/classify-intent", {
      userMessage: persona.message,
      recentMessages,
    });
    timings.push(intentResult.durationMs);
    intent = intentResult.body.intent;
    addCheck(
      checks,
      "intent",
      intent === persona.classifyIntent,
      persona.classifyIntent,
      intent
    );
  }

  const result = await api.post(persona.route, {
    userMessage: persona.message,
    ...persona.requestBody,
  }, { allowFailure: true });
  timings.push(result.durationMs);
  addCheck(
    checks,
    "http_status",
    result.status === 200,
    200,
    result.status,
    "critical"
  );
  if (result.status === 200) {
    evaluateExpected(checks, result.body, persona.expected);
  }

  return {
    checks,
    timings,
    observed: {
      intent,
      status: result.status,
      output: result.body,
    },
  };
}

function runSourcePersona(persona) {
  const checks = [];
  const observations = [];
  for (const sourceCheck of persona.sourceChecks) {
    const content = read(sourceCheck.file);
    if (sourceCheck.pattern) {
      const found = matches(content, sourceCheck.pattern);
      addCheck(
        checks,
        sourceCheck.expectedCapability,
        found,
        `present in ${sourceCheck.file}`,
        found ? "present" : "missing",
        "major"
      );
      observations.push({
        file: sourceCheck.file,
        capability: sourceCheck.expectedCapability,
        present: found,
      });
    }
    if (sourceCheck.missingPattern) {
      const found = matches(content, sourceCheck.missingPattern);
      addCheck(
        checks,
        sourceCheck.expectedCapability,
        found,
        `present in ${sourceCheck.file}`,
        found ? "present" : "missing",
        "major"
      );
      observations.push({
        file: sourceCheck.file,
        capability: sourceCheck.expectedCapability,
        present: found,
      });
    }
    if (sourceCheck.absentPattern) {
      const found = matches(content, sourceCheck.absentPattern);
      addCheck(
        checks,
        sourceCheck.expectedCapability,
        !found,
        `absent from ${sourceCheck.file}`,
        found ? "present" : "absent",
        "major"
      );
      observations.push({
        file: sourceCheck.file,
        capability: sourceCheck.expectedCapability,
        present: !found,
      });
    }
  }
  return {
    checks,
    timings: [],
    observed: { sourceChecks: observations },
  };
}

function personaScore(checks) {
  if (!checks.length) return 0;
  const weights = { critical: 3, major: 2, minor: 1 };
  const possible = checks.reduce(
    (sum, check) => sum + (weights[check.severity] || 1),
    0
  );
  const earned = checks.reduce(
    (sum, check) => sum + (check.passed ? (weights[check.severity] || 1) : 0),
    0
  );
  return Math.round((earned / possible) * 1000) / 10;
}

function resultStatus(score) {
  if (score >= 95) return "pass";
  if (score >= 75) return "friction";
  return "fail";
}

function buildSummary(results, requests) {
  const totalChecks = results.reduce((sum, result) => sum + result.checks.length, 0);
  const passedChecks = results.reduce(
    (sum, result) => sum + result.checks.filter((check) => check.passed).length,
    0
  );
  const weightedScore = Math.round(
    results.reduce((sum, result) => sum + result.score, 0) / results.length * 10
  ) / 10;
  const durations = results.flatMap((result) => result.timings);
  const journeyDurations = results
    .filter((result) => result.timings.length > 0)
    .map((result) => result.durationMs);
  const foodJourneyDurations = results
    .filter((result) => Array.isArray(result.observed?.resolutions))
    .map((result) => result.durationMs);
  const byCohort = {};
  for (const result of results) {
    byCohort[result.cohort] ||= {
      users: 0,
      pass: 0,
      friction: 0,
      fail: 0,
      scores: [],
    };
    const bucket = byCohort[result.cohort];
    bucket.users += 1;
    bucket[result.status] += 1;
    bucket.scores.push(result.score);
  }
  for (const bucket of Object.values(byCohort)) {
    bucket.score = Math.round(
      bucket.scores.reduce((sum, value) => sum + value, 0)
      / bucket.scores.length * 10
    ) / 10;
    delete bucket.scores;
  }

  return {
    personas: results.length,
    perfectPersonas: results.filter((result) => result.score === 100).length,
    passPersonas: results.filter((result) => result.status === "pass").length,
    frictionPersonas: results.filter((result) => result.status === "friction").length,
    failedPersonas: results.filter((result) => result.status === "fail").length,
    totalChecks,
    passedChecks,
    checkAccuracy: totalChecks
      ? Math.round((passedChecks / totalChecks) * 1000) / 10
      : 0,
    averagePersonaScore: weightedScore,
    latencyMs: {
      requests: durations.length,
      median: percentile(durations, 0.5),
      p90: percentile(durations, 0.9),
      p95: percentile(durations, 0.95),
      max: durations.length ? Math.max(...durations) : null,
      overTarget: durations.filter((duration) => duration > MAX_LATENCY_MS).length,
      target: MAX_LATENCY_MS,
    },
    journeyLatencyMs: {
      journeys: journeyDurations.length,
      median: percentile(journeyDurations, 0.5),
      p90: percentile(journeyDurations, 0.9),
      p95: percentile(journeyDurations, 0.95),
      max: journeyDurations.length ? Math.max(...journeyDurations) : null,
      overTarget: journeyDurations.filter(
        (duration) => duration > MAX_JOURNEY_LATENCY_MS
      ).length,
      target: MAX_JOURNEY_LATENCY_MS,
    },
    foodJourneyLatencyMs: {
      journeys: foodJourneyDurations.length,
      median: percentile(foodJourneyDurations, 0.5),
      p90: percentile(foodJourneyDurations, 0.9),
      p95: percentile(foodJourneyDurations, 0.95),
      max: foodJourneyDurations.length
        ? Math.max(...foodJourneyDurations)
        : null,
      overTarget: foodJourneyDurations.filter(
        (duration) => duration > MAX_JOURNEY_LATENCY_MS
      ).length,
      target: MAX_JOURNEY_LATENCY_MS,
    },
    byCohort,
    topRequests: requests,
  };
}

function aggregateRequests(results) {
  const buckets = new Map();
  for (const result of results) {
    const failed = result.checks.some((check) => !check.passed);
    const slow = result.timings.some((duration) => duration > MAX_LATENCY_MS);
    if (!failed && !slow) continue;
    const key = result.feedback;
    const current = buckets.get(key) || {
      request: key,
      affectedUsers: 0,
      failures: 0,
      slowUsers: 0,
      personas: [],
    };
    current.affectedUsers += 1;
    current.failures += failed ? 1 : 0;
    current.slowUsers += slow ? 1 : 0;
    current.personas.push(result.personaId);
    buckets.set(key, current);
  }
  return [...buckets.values()]
    .sort((left, right) =>
      right.affectedUsers - left.affectedUsers
      || right.failures - left.failures
    );
}

async function main() {
  if (process.argv.includes("--catalog-only")) {
    const counts = personas.reduce((summary, persona) => {
      summary[persona.cohort] = (summary[persona.cohort] || 0) + 1;
      return summary;
    }, {});
    console.log(JSON.stringify({
      personas: personas.length,
      cohorts: counts,
      ids: personas.map((persona) => persona.personaId),
    }, null, 2));
    return;
  }

  if (!fs.existsSync(FOOD_DB_PATH)) {
    throw new Error(`Bundled food database unavailable: ${FOOD_DB_PATH}`);
  }

  const api = new NomvaAPI(BASE_URL);
  const auth = await api.register();
  console.log(`Authenticated power-test client in ${auth.durationMs}ms`);

  const onlyPersona = process.env.NOMVA_POWER_TEST_ONLY?.trim();
  const onlyPersonaIds = new Set(
    String(onlyPersona || "")
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean)
  );
  const selectedPersonas = onlyPersonaIds.size
    ? personas.filter((persona) => onlyPersonaIds.has(persona.personaId))
    : personas;
  if (!selectedPersonas.length) {
    throw new Error(`Unknown persona requested by NOMVA_POWER_TEST_ONLY: ${onlyPersona}`);
  }

  const results = [];
  for (const persona of selectedPersonas) {
    const startedAt = Date.now();
    let execution;
    try {
      if (persona.kind === "food") {
        execution = await runFoodPersona(api, persona);
      } else if (persona.kind === "mutation") {
        execution = await runMutationPersona(api, persona);
      } else {
        execution = runSourcePersona(persona);
      }
    } catch (error) {
      execution = {
        checks: [{
          name: "journey_execution",
          passed: false,
          severity: "critical",
          expected: "journey completes",
          actual: error.message,
        }],
        timings: error.durationMs ? [error.durationMs] : [],
        observed: { error: error.message },
      };
    }

    const score = personaScore(execution.checks);
    const result = {
      id: persona.id,
      personaId: persona.personaId,
      cohort: persona.cohort,
      profile: persona.profile,
      difficulty: persona.difficulty,
      journey: persona.message,
      feedback: persona.feedback,
      score,
      status: resultStatus(score),
      durationMs: Date.now() - startedAt,
      timings: execution.timings,
      checks: execution.checks,
      observed: execution.observed,
    };
    results.push(result);
    console.log(
      `${result.personaId} ${result.status.toUpperCase().padEnd(8)} `
      + `${String(result.score).padStart(5)} | ${result.profile}`
    );
  }

  let finalResults = results;
  let priorRequests = [];
  const mergeInto = process.env.NOMVA_POWER_TEST_MERGE_INTO?.trim();
  if (mergeInto) {
    const priorReport = JSON.parse(fs.readFileSync(mergeInto, "utf8"));
    const replacements = new Map(
      results.map((result) => [result.personaId, result])
    );
    finalResults = priorReport.personas.map(
      (result) => replacements.get(result.personaId) || result
    );
    for (const result of results) {
      if (!priorReport.personas.some((prior) => prior.personaId === result.personaId)) {
        finalResults.push(result);
      }
    }
    priorRequests = Array.isArray(priorReport.requests)
      ? priorReport.requests
      : [];
  }

  const requests = aggregateRequests(finalResults);
  const report = {
    runId: `nomva-100-user-power-test-${new Date().toISOString().replace(/[:.]/g, "-")}`,
    generatedAt: new Date().toISOString(),
    target: BASE_URL,
    methodology: {
      personas: finalResults.length,
      note: "Synthetic personas exercised deployed Nomva Cloud endpoints, the bundled food database, and production source paths. Simulator validation is recorded separately in the companion report.",
      scoreBands: {
        pass: "95-100",
        friction: "75-94.9",
        fail: "0-74.9",
      },
    },
    summary: buildSummary(finalResults, requests),
    personas: finalResults,
    requests: [...priorRequests, ...api.requests],
  };

  fs.mkdirSync(REPORT_DIR, { recursive: true });
  const reportPath = path.join(REPORT_DIR, `${report.runId}.json`);
  const latestPath = path.join(REPORT_DIR, "latest-100-user-power-test.json");
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
  fs.writeFileSync(latestPath, JSON.stringify(report, null, 2));

  console.log("");
  console.log(JSON.stringify(report.summary, null, 2));
  console.log(`Report: ${reportPath}`);
}

main()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
