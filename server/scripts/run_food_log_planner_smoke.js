require("dotenv").config();

const assert = require("node:assert/strict");
const OpenAI = require("openai");
const {
  FOOD_LOG_PLANNER_PROMPT,
  sanitizeFoodLogPlan,
} = require("../foodLogPlanner");

const model = process.env.NOMVA_FOOD_LOG_PLANNING_MODEL || "gpt-5.6-sol";
const openai = new OpenAI({
  apiKey: process.env.OPENAI_API_KEY,
  timeout: 20_000,
  maxRetries: 0,
});

const cases = [
  {
    name: "compound meal with trailing global quantity",
    message: "I had quesadillas with cheese, flour tortillas, refried beans, meat, and corn dipped in sour cream. Had 3 servings. Of everything",
    check(plan) {
      assert.equal(plan.quantityScope, "all_items");
      assert.equal(plan.globalServings, 3);
      assert.ok(plan.items.length >= 2 && plan.items.length <= 4);
      assert.ok(plan.items.every((item) => item.servings === 3));
      const mentions = plan.items.map((item) => item.mention.toLowerCase());
      assert.ok(mentions.some((mention) => mention.includes("quesadilla")));
      assert.ok(mentions.some((mention) => mention.includes("sour cream")));
      assert.ok(plan.items.find((item) => item.kind === "composite")?.nutritionEstimate);
      const standaloneItems = plan.items
        .filter((item) => item.kind !== "composite")
        .map((item) => item.mention.toLowerCase());
      assert.equal(standaloneItems.filter((mention) => mention === "cheese").length, 0);
      assert.equal(standaloneItems.filter((mention) => mention.includes("flour tortilla")).length, 0);
    },
  },
  {
    name: "ordinary list with global quantity",
    message: "I had soup, salad, and bread. Two servings of everything.",
    check(plan) {
      assert.equal(plan.quantityScope, "all_items");
      assert.equal(plan.globalServings, 2);
      assert.equal(plan.items.length, 3);
      assert.ok(plan.items.every((item) => item.servings === 2));
    },
  },
  {
    name: "each applies across foods",
    message: "Greek yogurt and blueberries, two servings each",
    check(plan) {
      assert.equal(plan.items.length, 2);
      assert.ok(plan.items.every((item) => item.servings === 2));
    },
  },
  {
    name: "per-food quantities stay separate",
    message: "I had 2 eggs, one slice of toast, and an 8 ounce orange juice",
    check(plan) {
      assert.notEqual(plan.quantityScope, "all_items");
      assert.equal(plan.items.length, 3);
      assert.ok(plan.items.some((item) => item.mention.toLowerCase().includes("egg") && item.servings === 2));
      assert.ok(plan.items.some((item) => item.mention.toLowerCase().includes("toast") && item.servings === 1));
      assert.ok(plan.items.some((item) => /8\s*(?:fl(?:uid)?\s*)?(?:oz|ounces?)/i.test(item.portionDescription)));
    },
  },
  {
    name: "dish ingredients are not double counted",
    message: "A turkey and cheese sandwich with a side of chips",
    check(plan) {
      assert.equal(plan.items.length, 2);
      const mentions = plan.items.map((item) => item.mention.toLowerCase());
      assert.ok(mentions.some((mention) => mention.includes("sandwich")));
      assert.ok(mentions.some((mention) => mention.includes("chip")));
      assert.equal(mentions.some((mention) => mention === "turkey" || mention === "cheese"), false);
      assert.ok(plan.items.find((item) => item.kind === "composite")?.nutritionEstimate);
    },
  },
  {
    name: "measured add-in remains independent",
    message: "Two cups of coffee with 2 tablespoons of creamer",
    check(plan) {
      assert.equal(plan.items.length, 2);
      assert.ok(plan.items.some((item) => item.mention.toLowerCase().includes("coffee")));
      assert.ok(plan.items.some((item) => item.mention.toLowerCase().includes("creamer")));
    },
  },
  {
    name: "counts after food names remain attached",
    message: "I had pizza and wings. Pizza was two slices and the wings were six pieces.",
    check(plan) {
      assert.notEqual(plan.quantityScope, "all_items");
      assert.equal(plan.items.length, 2);
      assert.ok(plan.items.some((item) => item.mention.toLowerCase().includes("pizza") && item.servings === 2));
      assert.ok(plan.items.some((item) => item.mention.toLowerCase().includes("wing") && item.servings === 6));
    },
  },
  {
    name: "branded menu combination keeps identity",
    message: "A grande oat milk latte and a cake pop from Starbucks",
    check(plan) {
      assert.equal(plan.items.length, 2);
      const joined = plan.items.map((item) => `${item.mention} ${item.searchQuery}`).join(" ").toLowerCase();
      assert.match(joined, /starbucks/);
      assert.match(joined, /grande/);
      assert.match(joined, /oat/);
      assert.match(joined, /cake pop/);
      assert.ok(plan.items.every((item) => item.kind === "menu"));
      assert.ok(plan.items.every((item) => item.nutritionEstimate === null));
    },
  },
];

async function runCase(testCase) {
  const startedAt = Date.now();
  const response = await openai.chat.completions.create({
    model,
    response_format: { type: "json_object" },
    reasoning_effort: "low",
    messages: [
      { role: "system", content: FOOD_LOG_PLANNER_PROMPT },
      { role: "user", content: `User message: "${testCase.message}"` },
    ],
    max_completion_tokens: 3_600,
  });
  const raw = JSON.parse(response.choices?.[0]?.message?.content || "{}");
  const plan = sanitizeFoodLogPlan(raw);
  assert.ok(plan, `${testCase.name}: model returned no usable plan`);
  try {
    testCase.check(plan);
  } catch (error) {
    console.error(`Failed case: ${testCase.name}`);
    console.error(`Sanitized plan: ${JSON.stringify(plan, null, 2)}`);
    throw error;
  }
  return {
    name: testCase.name,
    durationMs: Date.now() - startedAt,
    items: plan.items.map((item) => `${item.portionDescription} ${item.mention}`),
    tokens: response.usage?.total_tokens || null,
  };
}

async function main() {
  if (!process.env.OPENAI_API_KEY) throw new Error("OPENAI_API_KEY is required");
  const filter = String(process.env.NOMVA_SMOKE_FILTER || "").trim().toLowerCase();
  const selectedCases = filter
    ? cases.filter((testCase) => testCase.name.toLowerCase().includes(filter))
    : cases;
  if (!selectedCases.length) throw new Error(`No smoke cases matched: ${filter}`);
  const results = [];
  for (let index = 0; index < selectedCases.length; index += 2) {
    results.push(...await Promise.all(selectedCases.slice(index, index + 2).map(runCase)));
  }
  console.log(JSON.stringify({ model, passed: results.length, results }, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
