#!/usr/bin/env node

require("dotenv").config();

const path = require("node:path");
const OpenAI = require("openai");

const prompts = require("../prompts");
const { createFoodSearchStore } = require("../foodSearchStore");
const { FOOD_SELECTION_SCHEMA, resolveFoodCandidate } = require("../foodResolver");
const { requestStructuredJSON } = require("../structuredLLM");

const model = process.env.NOMVA_FOOD_RESOLUTION_MODEL || process.env.OPENAI_MODEL || "gpt-5.6-luna";
const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
const store = createFoodSearchStore({
  dbPath: process.env.FOODS_DB_PATH || path.join(__dirname, "..", "..", "Nomva", "Resources", "foods.sqlite"),
});

const cases = [
  ["I had a 20oz Coke Zero cherry", "20oz Coke Zero cherry", /coke zero|coca.?cola zero/i, /20.*(?:oz|ounce)/i, 0, 10],
  ["Cherry Coke Zero", "Cherry Coke Zero", /coke zero|coca.?cola zero/i, null, 0, 10],
  ["I ate a sloppy joe", "sloppy joe", /sloppy joe/i, null, 150, 600],
  ["I had a side of corn", "corn", /^corn(?:\s|,|$)|sweet corn/i, null, 40, 250],
  ["Greek yogurt for breakfast", "Greek yogurt", /greek yogurt|yogurt, greek/i, null, 50, 300],
  ["A cup of blueberries", "1 cup blueberries", /blueberr/i, /1\s*cup/i, 50, 150],
  ["Black coffee", "black coffee", /coffee/i, null, 0, 15],
  ["One whole egg", "one whole egg", /egg/i, /(?:1|one).*egg/i, 50, 120],
  ["Some raw spinach", "some raw spinach", /spinach/i, null, 5, 80],
  ["Three chicken nuggets", "three chicken nuggets", /chicken.*nugget|nugget.*chicken/i, /(?:3|three).*nugget/i, 80, 220],
  ["About five waffle fries", "about five waffle fries", /waffle.*fr/i, /(?:5|five)/i, 40, 200],
  ["A peanut butter and jelly sandwich", "peanut butter and jelly sandwich", /peanut butter.*(?:jelly|sandwich)|sandwich.*peanut butter/i, null, 200, 600],
  ["Six ounces of grilled chicken breast", "6 oz grilled chicken breast", /chicken.*breast/i, /6\s*(?:oz|ounce)/i, 200, 450],
  ["One cup cooked brown rice", "1 cup cooked brown rice", /brown rice|rice, brown/i, /(?:1|one).*cup/i, 150, 400],
  ["A medium banana", "medium banana", /banana/i, null, 70, 150],
  ["A bowl of plain oatmeal", "plain oatmeal", /oatmeal|oats/i, null, 100, 400],
  ["Two scrambled eggs", "two scrambled eggs", /egg/i, /(?:2|two).*egg/i, 100, 300],
  ["One cup unsweetened almond milk", "1 cup unsweetened almond milk", /almond.*milk|milk.*almond/i, /1\s*cup/i, 15, 150],
  ["A vanilla protein shake", "vanilla protein shake", /protein.*shake|shake.*protein/i, null, 80, 400],
  ["A can of diet cola", "diet cola", /diet.*(?:cola|coke)|(?:cola|coke).*diet/i, null, 0, 10],
];

async function askJSON(systemPrompt, userPrompt, maxTokens) {
  const request = {
    model,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content: systemPrompt },
      { role: "user", content: userPrompt },
    ],
  };
  if (/^gpt-5/i.test(model)) {
    request.max_completion_tokens = Math.max(maxTokens * 4, 512);
  } else {
    request.max_tokens = maxTokens;
    request.temperature = 0.1;
  }
  const response = await openai.chat.completions.create(request);
  return JSON.parse(response.choices[0]?.message?.content || "{}");
}

async function selectFood(userPrompt) {
  const { value } = await requestStructuredJSON({
    openai,
    model,
    instructions: prompts.SELECT_FOOD_CANDIDATE,
    input: userPrompt,
    schemaName: "food_candidate_selection",
    schema: FOOD_SELECTION_SCHEMA,
    reasoningEffort: "none",
    maxOutputTokens: 700,
    timeoutMs: 10_000,
    maxRetries: 0,
    cacheKey: "nomva_food_candidate_smoke_v1",
  });
  return value;
}

async function run() {
  if (!store.isAvailable) {
    throw new Error(store.error || "food database unavailable");
  }

  const split = await askJSON(
    prompts.SPLIT_FOODS,
    'User: Ate a sloppy joe for dinner with a side of corn',
    180
  );
  const splitFoods = Array.isArray(split.foods) ? split.foods : [];
  const splitPassed = splitFoods.length === 2
    && splitFoods.some((food) => /sloppy joe/i.test(food))
    && splitFoods.some((food) => /corn/i.test(food));
  console.log(`${splitPassed ? "PASS" : "FAIL"} split | ${JSON.stringify(splitFoods)}`);

  const filter = (process.env.SMOKE_FILTER || "").trim().toLowerCase();
  const selectedCases = filter
    ? cases.filter(([userMessage]) => userMessage.toLowerCase().includes(filter))
    : cases;
  let passed = filter ? 0 : (splitPassed ? 1 : 0);
  const results = [];
  for (const [userMessage, foodMention, identityPattern, portionPattern, minCalories, maxCalories] of selectedCases) {
    const startedAt = Date.now();
    const trace = [];
    const outcome = await resolveFoodCandidate({
      userMessage,
      foodMention,
      foodSearchStore: store,
      askAgent: selectFood,
      onEvent: (event) => trace.push(event),
    });
    const identity = `${outcome.body?.name || ""} ${outcome.body?.brand || ""}`;
    const identityPassed = outcome.status === 200 && identityPattern.test(identity);
    const portionPassed = !portionPattern || portionPattern.test(outcome.body?.portionDescription || "");
    const selectedRow = outcome.body?.rowId ? store.inspect(outcome.body.rowId) : null;
    const impliedCalories = selectedRow && typeof outcome.body?.servings === "number"
      ? selectedRow.caloriesPerServing * outcome.body.servings
      : null;
    const caloriesPassed = typeof impliedCalories === "number"
      && impliedCalories >= minCalories
      && impliedCalories <= maxCalories;
    const didPass = identityPassed && portionPassed && caloriesPassed;
    if (didPass) passed += 1;
    const result = {
      passed: didPass,
      userMessage,
      status: outcome.status,
      selected: identity.trim(),
      portion: outcome.body?.portionDescription || null,
      servings: outcome.body?.servings || null,
      impliedCalories: typeof impliedCalories === "number" ? Math.round(impliedCalories * 10) / 10 : null,
      expectedCalories: [minCalories, maxCalories],
      durationMs: Date.now() - startedAt,
    };
    results.push(result);
    console.log(`${didPass ? "PASS" : "FAIL"} ${userMessage} | ${result.selected || outcome.body?.error} | ${result.portion || ""} | ${result.impliedCalories ?? "?"} cal | ${result.durationMs}ms`);
    if (!didPass) {
      console.log(`  trace=${JSON.stringify(trace)}`);
    }
  }

  const total = selectedCases.length + (filter ? 0 : 1);
  const score = Math.round((passed / total) * 1000) / 10;
  console.log(JSON.stringify({ model, passed, total, score, results }, null, 2));
  process.exitCode = score >= 95 ? 0 : 1;
}

run().finally(() => store.close?.()).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
