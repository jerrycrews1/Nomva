#!/usr/bin/env node

require("dotenv").config({ path: require("path").join(__dirname, "..", ".env") });

const fs = require("fs");
const path = require("path");
const OpenAI = require("openai");
const prompts = require("../prompts");
const { deterministicDeleteTargets } = require("../deleteTargetGuard");
const { deterministicEditTarget } = require("../editTargetGuard");

const args = new Set(process.argv.slice(2));
function argValue(name, fallback) {
  const prefix = `${name}=`;
  const found = process.argv.slice(2).find((arg) => arg.startsWith(prefix));
  return found ? found.slice(prefix.length) : fallback;
}

const SPLIT = argValue("--split", "train");
const COUNT = Number(argValue("--count", "1000"));
const MODEL = argValue("--model", process.env.CHAT_CRUD_MODEL || process.env.BASELINE_MODEL || process.env.NOMVA_LLM_BASELINE_MODEL || "gpt-4o-mini");
const CONCURRENCY = Math.max(1, Number(argValue("--concurrency", "6")));
const MIN_SCORE = Number(argValue("--min-score", "95"));
const WRITE_CASES = argValue("--write-cases", "");
const CASES_PATH = argValue("--cases", "");
const REPORT_DIR = argValue("--report-dir", path.join(__dirname, "..", "baseline", "reports"));
const WRITE_CASES_ONLY = args.has("--write-cases-only");

function createRng(seed) {
  let state = seed >>> 0;
  return function rng() {
    state = (state * 1664525 + 1013904223) >>> 0;
    return state / 0x100000000;
  };
}

function choice(rng, values) {
  return values[Math.floor(rng() * values.length)];
}

function sample(rng, values, count) {
  const copy = [...values];
  const picked = [];
  while (picked.length < count && copy.length) {
    picked.push(copy.splice(Math.floor(rng() * copy.length), 1)[0]);
  }
  return picked;
}

function normalizeText(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/\b1\/2\b/g, "0.5")
    .replace(/\bhalf\b/g, "0.5")
    .replace(/\btablespoons?\b/g, "tbsp")
    .replace(/\bteaspoons?\b/g, "tsp")
    .replace(/\bounces?\b/g, "oz")
    .replace(/\bnuggets?\b/g, "nugget")
    .replace(/\bfries\b/g, "fry")
    .replace(/\bslices\b/g, "slice")
    .replace(/\bcups\b/g, "cup")
    .replace(/\b(a|an|the|my)\b/g, " ")
    .replace(/[^a-z0-9.\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function textMatches(expected, actual) {
  const left = normalizeText(expected);
  const right = normalizeText(actual);
  if (!left || !right) return false;
  return left.includes(right) || right.includes(left);
}

function arrayMatches(expected, actual) {
  const actualValues = Array.isArray(actual) ? actual : [];
  return expected.every((expectedItem) =>
    actualValues.some((actualItem) => textMatches(expectedItem, actualItem))
  ) && actualValues.length === expected.length;
}

function numericMatches(expected, actual, tolerance = 0.15) {
  const expectedNumber = Number(expected);
  const actualNumber = Number(actual);
  return Number.isFinite(expectedNumber) &&
    Number.isFinite(actualNumber) &&
    Math.abs(expectedNumber - actualNumber) <= tolerance;
}

const foods = [
  "Greek yogurt", "blueberries", "black coffee", "banana", "oatmeal",
  "chicken breast", "white rice", "avocado toast", "scrambled eggs",
  "turkey sandwich", "breakfast burrito", "protein shake", "apple",
  "peanut butter and jelly sandwich", "mac and cheese", "fish and chips",
  "bacon egg and cheese sandwich", "chicken nuggets", "waffle fries",
];

const meals = ["breakfast", "lunch", "dinner", "snack"];

function withCase(id, task, category, difficulty, message, expect, extra = {}) {
  return { id, task, category, difficulty, message, expect, ...extra };
}

function genClassify(rng, id) {
  const templates = [
    ["log_food", `I had ${choice(rng, foods)} and ${choice(rng, foods)}`],
    ["log_food", `${choice(rng, foods)}`],
    ["delete_food", `delete ${choice(rng, foods)} from today`],
    ["delete_food", `clear all foods from today`],
    ["edit_food", `actually that was ${choice(rng, ["half", "2 cups", "small", "3 slices"])}`],
    ["query_data", `how many calories do I have left today?`],
    ["query_data", `how much water did I drink today?`],
    ["log_water", `I drank ${choice(rng, ["16 oz", "2 cups", "500 ml", "a bottle"])} of water`],
    ["log_weight", `change today's weight to ${choice(rng, ["180.5", "174", "82 kg"])}`],
    ["set_goal", `set protein to ${choice(rng, [140, 160, 180])}g and calories to ${choice(rng, [1900, 2100, 2400])}`],
    ["reply", choice(rng, ["thanks", "hello", "what can you do?"])],
  ];
  const [intent, message] = choice(rng, templates);
  return withCase(id, "classify_intent", "intent", "medium", message, { intent });
}

function genSplitFoods(rng, id) {
  const cases = [
    [`Log breakfast: Greek yogurt, blueberries, and black coffee`, ["Greek yogurt", "blueberries", "black coffee"]],
    [`I had peanut butter and jelly sandwich`, ["peanut butter and jelly sandwich"]],
    [`For lunch I had mac and cheese and a protein shake`, ["mac and cheese", "protein shake"]],
    [`I ate eggs and toast`, ["eggs", "toast"]],
    [`Dinner was fish and chips, salad, and iced tea`, ["fish and chips", "salad", "iced tea"]],
    [`I had a bacon egg and cheese sandwich`, ["bacon egg and cheese sandwich"]],
  ];
  const [message, foodList] = choice(rng, cases);
  return withCase(id, "split_foods", "food_log", "hard", message, { foods: foodList });
}

function genMeal(rng, id) {
  const meal = choice(rng, meals);
  const cases = [
    [`For ${meal} I had ${choice(rng, foods)}`, meal],
    [`Log ${meal}: ${choice(rng, foods)}`, meal],
    [`I had a breakfast burrito for dinner`, "dinner"],
    [`I had a lunchable as a snack`, "snack"],
    [`I had a breakfast burrito`, null],
    [`delete breakfast burrito`, null],
    [`my ${meal} was ${choice(rng, foods)}`, meal],
  ];
  const [message, expectedMeal] = choice(rng, cases);
  return withCase(id, "extract_meal", "food_log", "hard", message, { meal: expectedMeal });
}

function genWater(rng, id) {
  const cases = [
    ["I drank 16 oz of water", { action: "add", amountOz: 16 }],
    ["log 2 cups water", { action: "add", amountOz: 16 }],
    ["add 500 ml water", { action: "add", amountOz: 16.9, tolerance: 0.5 }],
    ["had a bottle of water", { action: "add", amountOz: 16.9, tolerance: 0.5 }],
    ["set my water total to 64 oz", { action: "update_total", amountOz: 64 }],
    ["clear today's water", { action: "delete_all", amountOz: null }],
  ];
  const [message, waterMutation] = choice(rng, cases);
  return withCase(id, "extract_water_mutation", "water_crud", "medium", message, { waterMutation });
}

function genWeight(rng, id) {
  const cases = [
    ["I weigh 181.4 lbs today", { action: "add", weightLbs: 181.4, dateHint: "today" }],
    ["log 82 kg", { action: "add", weightLbs: 180.8, dateHint: null, tolerance: 0.8 }],
    ["change today's weight to 180", { action: "update", weightLbs: 180, dateHint: "today" }],
    ["delete yesterday's weight", { action: "delete", weightLbs: null, dateHint: "yesterday" }],
    ["clear all my weights", { action: "delete_all", weightLbs: null, dateHint: null }],
  ];
  const [message, weightMutation] = choice(rng, cases);
  return withCase(id, "extract_weight_mutation", "weight_crud", "medium", message, { weightMutation });
}

function genGoal(rng, id) {
  const protein = choice(rng, [140, 150, 180, 200]);
  const calories = choice(rng, [1800, 2000, 2200, 2400]);
  const carbs = choice(rng, [150, 200, 250]);
  const fat = choice(rng, [55, 70, 80]);
  const cases = [
    [`set my calorie goal to ${calories}`, { calories }],
    [`set protein to ${protein}g`, { protein }],
    [`I want ${calories} calories, ${protein}g protein, ${carbs}g carbs, ${fat}g fat`, { calories, protein, carbs, fat }],
    [`change carbs to ${carbs} and fat to ${fat}`, { carbs, fat }],
    [`set fiber to 35g`, { fiber: 35 }],
  ];
  const [message, goal] = choice(rng, cases);
  return withCase(id, "extract_goal", "goal_crud", "medium", message, { goal });
}

function genDeleteTargets(rng, id) {
  const log = [
    "Greek Yogurt (breakfast)",
    "Blueberries, raw (breakfast)",
    "Black coffee (breakfast)",
    "Breakfast Burrito (lunch)",
    "Chicken Nuggets (lunch)",
    "Waffle Fries (lunch)",
    "Caff Mocha Chilled Espresso Beverage (snack)",
  ];
  const history = [
    { role: "user", content: "I had coffee for lunch" },
    { role: "assistant", content: "✓ Black coffee (1 serving) — 4 cal" },
    { role: "user", content: "It was a mocha grande from Starbucks" },
    { role: "assistant", content: "Removed Black coffee.\n✓ Caff Mocha Chilled Espresso Beverage (1 grande mocha) — 202 cal" },
  ];
  const cases = [
    ["delete all foods from today", log.map((line) => line.replace(/\s+\(.+\)$/, ""))],
    ["delete breakfast", ["Greek Yogurt", "Blueberries, raw", "Black coffee"]],
    ["delete breakfast burrito", ["Breakfast Burrito"]],
    ["delete that", ["Caff Mocha Chilled Espresso Beverage"]],
    ["remove the fries", ["Waffle Fries"]],
    ["delete coffee but keep the mocha", ["Black coffee"]],
  ];
  const [message, deleteTargets] = choice(rng, cases);
  return withCase(id, "pick_delete_targets", "food_delete", "hard", message, { deleteTargets }, {
    recentMessages: history,
    logSummary: log.join("\n"),
  });
}

function genEditTarget(rng, id) {
  const log = [
    "Greek Yogurt (1 serving, breakfast)",
    "Black coffee (1 serving, lunch)",
    "Caff Mocha Chilled Espresso Beverage (1 grande mocha, lunch)",
    "Waffle Fries (5 fries, lunch)",
    "Chicken Nuggets (3 nuggets, lunch)",
  ];
  const history = [
    { role: "user", content: "I had coffee for lunch" },
    { role: "assistant", content: "✓ Black coffee (1 serving) — 4 cal" },
    { role: "user", content: "It was a mocha grande from Starbucks" },
    { role: "assistant", content: "Removed Black coffee.\n✓ Caff Mocha Chilled Espresso Beverage (1 grande mocha) — 202 cal" },
  ];
  const cases = [
    ["no delete that", "Caff Mocha Chilled Espresso Beverage"],
    ["actually the fries were medium", "Waffle Fries"],
    ["make the nuggets 6", "Chicken Nuggets"],
    ["that yogurt was 2 servings", "Greek Yogurt"],
    ["fix the coffee", null],
  ];
  const [message, editTarget] = choice(rng, cases);
  const expect = editTarget ? { editTarget } : { clarification: true };
  return withCase(id, "pick_edit_target", "food_edit", "hard", message, expect, {
    recentMessages: history,
    logSummary: log.join("\n"),
  });
}

function genEditRequest(rng, id) {
  const cases = [
    ["It was black coffee", "Coffee", null, "1 serving", { hasExplicitPortion: true, portionDescription: "1 serving", replacementSearchQuery: "black coffee" }],
    ["actually only about 5 fries", "Chick-Fil-A, Waffle Potato Fries, Large", "Chick-Fil-A", "1 large", { hasExplicitPortion: true, servings: 5, portionDescription: "5 fries", replacementSearchQuery: "waffle fries" }],
    ["make it half a cup", "Rice, cooked", null, "1 cup", { hasExplicitPortion: true, servings: 0.5, portionDescription: "1/2 cup" }],
    ["not chicken curry, it was tofu curry", "Chicken Curry", null, "1 bowl", { hasExplicitPortion: true, portionDescription: "1 bowl", replacementSearchQuery: "tofu curry" }],
    ["that's not right", "Chicken Nuggets", null, "3 nuggets", { hasExplicitPortion: false }],
  ];
  const [message, currentEntryName, currentEntryBrand, currentPortionDescription, editRequest] = choice(rng, cases);
  return withCase(id, "resolve_edit_request", "food_edit", "ridiculous", message, { editRequest }, {
    currentEntryName,
    currentEntryBrand,
    currentPortionDescription,
  });
}

function genSearchQuery(rng, id) {
  const cases = [
    ["I had three Chick-fil-A nuggets", "three Chick-fil-A nuggets", "chicken nuggets"],
    ["I had about 5 Chick-fil-A fries", "about 5 Chick-fil-A fries", "waffle fries"],
    ["I had one egg", "one egg", "whole egg"],
    ["I ate some spinach", "some spinach", "fresh spinach"],
    ["Log breakfast: Gree Yogurt", "Gree Yogurt", "Greek yogurt"],
    ["I had a large Chick-fil-A waffle fries", "large Chick-fil-A waffle fries", "Chick-Fil-A waffle potato fries large"],
  ];
  const [message, foodMention, query] = choice(rng, cases);
  return withCase(id, "build_food_search_query", "food_search", "hard", message, { searchQuery: { foodMention, query } });
}

function genServings(rng, id) {
  const cases = [
    ["I had three Chick-fil-A nuggets", "three Chick-fil-A nuggets", "Chick-Fil-A Nuggets", null, { servings: 3, portionDescription: "3 nuggets", servingUnit: "nugget", hasExplicitPortion: true }],
    ["I had half a cup of rice", "half a cup of rice", "Rice, cooked", null, { servings: 0.5, portionDescription: "1/2 cup", servingUnit: "cup", hasExplicitPortion: true }],
    ["I ate some spinach", "some spinach", "Spinach, raw", null, { servings: 1, portionDescription: "1 cup", servingUnit: "cup", hasExplicitPortion: false }],
    ["That was only 2 slices", "2 slices", "Bacon", null, { servings: 2, portionDescription: "2 slices", servingUnit: "slice", hasExplicitPortion: true }],
    ["I had a small handful of almonds", "small handful of almonds", "Almonds", null, { hasExplicitPortion: true }],
  ];
  const [message, foodMention, candidateName, candidateServingDescription, servings] = choice(rng, cases);
  return withCase(id, "extract_servings", "portion", "hard", message, { servings }, {
    foodMention,
    candidateName,
    candidateServingDescription,
  });
}

function makeCases(split, count) {
  const seed = split === "validation" ? 0x51f15eed : 0xc0ffee;
  const rng = createRng(seed);
  const generators = [
    genClassify,
    genSplitFoods,
    genMeal,
    genWater,
    genWeight,
    genGoal,
    genDeleteTargets,
    genEditTarget,
    genEditRequest,
    genSearchQuery,
    genServings,
  ];
  const cases = [];
  for (let index = 0; index < count; index += 1) {
    const generator = generators[index % generators.length];
    cases.push(generator(rng, `${split}-${String(index + 1).padStart(4, "0")}`));
  }
  return cases;
}

function renderHistory(messages = []) {
  return messages.map((m) => `${m.role === "user" ? "User" : "Assistant"}: ${m.content}`).join("\n");
}

function promptForCase(testCase) {
  const message = testCase.message;
  switch (testCase.task) {
    case "classify_intent":
      return [prompts.CLASSIFY_INTENT, `User: ${message}`, 64];
    case "split_foods":
      return [prompts.SPLIT_FOODS, `User: ${message}`, 128];
    case "extract_meal":
      return [prompts.EXTRACT_MEAL, `User: ${message}`, 64];
    case "extract_water_mutation":
      return [prompts.EXTRACT_WATER_MUTATION, `User: ${message}`, 96];
    case "extract_weight_mutation":
      return [prompts.EXTRACT_WEIGHT_MUTATION, `User: ${message}`, 96];
    case "extract_goal":
      return [prompts.EXTRACT_GOAL, `User: ${message}`, 128];
    case "pick_delete_targets":
      return [prompts.PICK_DELETE_TARGETS, [
        renderHistory(testCase.recentMessages || []),
        `Food log:\n${testCase.logSummary || ""}`,
        `User said: ${message}`,
      ].filter(Boolean).join("\n\n"), 160];
    case "pick_edit_target":
      return [prompts.PICK_EDIT_TARGET, [
        renderHistory(testCase.recentMessages || []),
        `Food log:\n${testCase.logSummary || ""}`,
        `User said: ${message}`,
      ].filter(Boolean).join("\n\n"), 160];
    case "resolve_edit_request":
      return [prompts.RESOLVE_EDIT_REQUEST, [
        `Current entry: ${testCase.currentEntryName}`,
        testCase.currentEntryBrand ? `Current brand: ${testCase.currentEntryBrand}` : null,
        `Current portion: ${testCase.currentPortionDescription}`,
        `User said: ${message}`,
      ].filter(Boolean).join("\n\n"), 180];
    case "build_food_search_query":
      return [prompts.BUILD_FOOD_SEARCH_QUERY, `User said: "${message}"\nFood mention: "${testCase.expect.searchQuery.foodMention}"`, 96];
    case "extract_servings":
      return [prompts.EXTRACT_SERVINGS, [
        `User message: ${message}`,
        `Food mention: ${testCase.foodMention}`,
        `Candidate name: ${testCase.candidateName}`,
        testCase.candidateServingDescription ? `Candidate serving: ${testCase.candidateServingDescription}` : null,
      ].filter(Boolean).join("\n"), 128];
    default:
      throw new Error(`Unknown task ${testCase.task}`);
  }
}

function addCheck(checks, name, pass, expected, actual) {
  checks.push({ name, pass, expected, actual });
}

function gradeCase(testCase, output) {
  const checks = [];
  const expect = testCase.expect || {};

  if (expect.intent) addCheck(checks, "intent", output?.intent === expect.intent, expect.intent, output?.intent ?? null);
  if (expect.foods) addCheck(checks, "foods", arrayMatches(expect.foods, output?.foods), expect.foods, output?.foods ?? null);
  if (Object.prototype.hasOwnProperty.call(expect, "meal")) {
    const actual = output?.meal === "none" ? null : output?.meal ?? null;
    addCheck(checks, "meal", actual === expect.meal, expect.meal, actual);
  }
  if (expect.waterMutation) {
    const expected = expect.waterMutation;
    addCheck(checks, "water_action", output?.action === expected.action, expected.action, output?.action ?? null);
    if (Object.prototype.hasOwnProperty.call(expected, "amountOz")) {
      const pass = expected.amountOz === null
        ? output?.amountOz == null
        : numericMatches(expected.amountOz, output?.amountOz, expected.tolerance ?? 0.2);
      addCheck(checks, "water_amount", pass, expected.amountOz, output?.amountOz ?? null);
    }
  }
  if (expect.weightMutation) {
    const expected = expect.weightMutation;
    addCheck(checks, "weight_action", output?.action === expected.action, expected.action, output?.action ?? null);
    if (Object.prototype.hasOwnProperty.call(expected, "weightLbs")) {
      const pass = expected.weightLbs === null
        ? output?.weightLbs == null
        : numericMatches(expected.weightLbs, output?.weightLbs, expected.tolerance ?? 0.2);
      addCheck(checks, "weight_lbs", pass, expected.weightLbs, output?.weightLbs ?? null);
    }
    if (Object.prototype.hasOwnProperty.call(expected, "dateHint")) {
      addCheck(checks, "weight_date_hint", (output?.dateHint ?? null) === expected.dateHint, expected.dateHint, output?.dateHint ?? null);
    }
  }
  if (expect.goal) {
    for (const [key, value] of Object.entries(expect.goal)) {
      addCheck(checks, `goal_${key}`, numericMatches(value, output?.[key], 0.2), value, output?.[key] ?? null);
    }
  }
  if (expect.deleteTargets) addCheck(checks, "delete_targets", arrayMatches(expect.deleteTargets, output?.foodNames), expect.deleteTargets, output?.foodNames ?? null);
  if (expect.editTarget) addCheck(checks, "edit_target", textMatches(expect.editTarget, output?.foodName), expect.editTarget, output?.foodName ?? null);
  if (expect.clarification) {
    const asks = !output?.foodName && typeof output?.clarificationQuestion === "string" && output.clarificationQuestion.trim().length > 0;
    addCheck(checks, "clarification", asks, "clarification without target", output);
  }
  if (expect.editRequest) {
    const expected = expect.editRequest;
    if (Object.prototype.hasOwnProperty.call(expected, "hasExplicitPortion")) {
      addCheck(checks, "edit_has_explicit_portion", Boolean(output?.hasExplicitPortion) === Boolean(expected.hasExplicitPortion), expected.hasExplicitPortion, output?.hasExplicitPortion ?? null);
    }
    if (Object.prototype.hasOwnProperty.call(expected, "servings")) {
      addCheck(checks, "edit_servings", numericMatches(expected.servings, output?.servings, expected.tolerance ?? 0.15), expected.servings, output?.servings ?? null);
    }
    if (expected.portionDescription) addCheck(checks, "edit_portion", textMatches(expected.portionDescription, output?.portionDescription), expected.portionDescription, output?.portionDescription ?? null);
    if (expected.replacementSearchQuery) addCheck(checks, "edit_replacement_query", textMatches(expected.replacementSearchQuery, output?.replacementSearchQuery || ""), expected.replacementSearchQuery, output?.replacementSearchQuery ?? null);
  }
  if (expect.searchQuery) addCheck(checks, "search_query", textMatches(expect.searchQuery.query, output?.query), expect.searchQuery.query, output?.query ?? null);
  if (expect.servings) {
    const expected = expect.servings;
    if (Object.prototype.hasOwnProperty.call(expected, "servings")) addCheck(checks, "servings", numericMatches(expected.servings, output?.servings, 0.15), expected.servings, output?.servings ?? null);
    if (expected.portionDescription) addCheck(checks, "portion", textMatches(expected.portionDescription, output?.portionDescription), expected.portionDescription, output?.portionDescription ?? null);
    if (expected.servingUnit) addCheck(checks, "serving_unit", textMatches(expected.servingUnit, output?.servingUnit), expected.servingUnit, output?.servingUnit ?? null);
    if (Object.prototype.hasOwnProperty.call(expected, "hasExplicitPortion")) addCheck(checks, "has_explicit_portion", Boolean(output?.hasExplicitPortion) === Boolean(expected.hasExplicitPortion), expected.hasExplicitPortion, output?.hasExplicitPortion ?? null);
  }
  const passed = checks.filter((check) => check.pass).length;
  const score = checks.length ? (passed / checks.length) * 100 : 0;
  return { checks, score, pass: score === 100 };
}

function parseJsonObject(raw) {
  const parsed = JSON.parse(raw);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Model did not return a JSON object.");
  }
  return parsed;
}

async function ask(openai, testCase) {
  if (testCase.task === "pick_delete_targets") {
    const guardedTargets = deterministicDeleteTargets({
      userMessage: testCase.message,
      logSummary: testCase.logSummary || "",
    });
    if (Array.isArray(guardedTargets)) {
      return {
        output: { foodNames: guardedTargets },
        raw: JSON.stringify({ foodNames: guardedTargets }),
        durationMs: 0,
        totalTokens: 0,
        deterministic: true,
      };
    }
  }
  if (testCase.task === "pick_edit_target") {
    const guardedTarget = deterministicEditTarget({
      userMessage: testCase.message,
      logSummary: testCase.logSummary || "",
      recentMessages: testCase.recentMessages || [],
    });
    if (guardedTarget) {
      return {
        output: guardedTarget,
        raw: JSON.stringify(guardedTarget),
        durationMs: 0,
        totalTokens: 0,
        deterministic: true,
      };
    }
  }

  const [systemPrompt, userMessage, maxTokens] = promptForCase(testCase);
  const completionBudget = /^gpt-5/i.test(MODEL) ? Math.max(maxTokens * 4, 512) : maxTokens;
  const request = {
    model: MODEL,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content: systemPrompt },
      { role: "user", content: userMessage },
    ],
  };
  if (/^gpt-5/i.test(MODEL)) {
    request.max_completion_tokens = completionBudget;
  } else {
    request.temperature = 0.1;
    request.max_tokens = completionBudget;
  }
  const startedAt = Date.now();
  const response = await openai.chat.completions.create(request);
  const raw = response.choices[0]?.message?.content?.trim() || "{}";
  return {
    output: parseJsonObject(raw),
    raw,
    durationMs: Date.now() - startedAt,
    totalTokens: response.usage?.total_tokens || null,
  };
}

async function runWithConcurrency(cases, worker) {
  let cursor = 0;
  const results = new Array(cases.length);
  const workers = Array.from({ length: Math.min(CONCURRENCY, cases.length) }, async () => {
    while (cursor < cases.length) {
      const index = cursor;
      cursor += 1;
      results[index] = await worker(cases[index], index);
      if ((index + 1) % 50 === 0) {
        console.log(`Ran ${index + 1}/${cases.length}`);
      }
    }
  });
  await Promise.all(workers);
  return results;
}

function summarize(results) {
  const totalChecks = results.reduce((sum, result) => sum + result.checks.length, 0);
  const passedChecks = results.reduce((sum, result) => sum + result.checks.filter((check) => check.pass).length, 0);
  const byCategory = {};
  const byTask = {};
  for (const result of results) {
    for (const [bucket, key] of [[byCategory, result.category], [byTask, result.task]]) {
      bucket[key] ||= { cases: 0, totalChecks: 0, passedChecks: 0, score: 0 };
      bucket[key].cases += 1;
      bucket[key].totalChecks += result.checks.length;
      bucket[key].passedChecks += result.checks.filter((check) => check.pass).length;
    }
  }
  for (const bucket of [byCategory, byTask]) {
    for (const group of Object.values(bucket)) {
      group.score = group.totalChecks ? (group.passedChecks / group.totalChecks) * 100 : 0;
    }
  }
  return {
    cases: results.length,
    passedCases: results.filter((result) => result.pass).length,
    totalChecks,
    passedChecks,
    score: totalChecks ? (passedChecks / totalChecks) * 100 : 0,
    byCategory,
    byTask,
  };
}

async function main() {
  const cases = CASES_PATH
    ? JSON.parse(fs.readFileSync(CASES_PATH, "utf8"))
    : makeCases(SPLIT, COUNT);

  if (WRITE_CASES) {
    fs.mkdirSync(path.dirname(WRITE_CASES), { recursive: true });
    fs.writeFileSync(WRITE_CASES, JSON.stringify(cases, null, 2));
  }
  if (WRITE_CASES_ONLY) {
    console.log(`Wrote ${cases.length} cases to ${WRITE_CASES}`);
    return;
  }
  if (!process.env.OPENAI_API_KEY) {
    throw new Error("Missing OPENAI_API_KEY. Add it to server/.env or run on the Lightsail server.");
  }

  fs.mkdirSync(REPORT_DIR, { recursive: true });
  const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
  const startedAt = new Date();
  const results = await runWithConcurrency(cases, async (testCase) => {
    try {
      const modelResult = await ask(openai, testCase);
      const grade = gradeCase(testCase, modelResult.output);
      return {
        id: testCase.id,
        task: testCase.task,
        category: testCase.category,
        difficulty: testCase.difficulty,
        message: testCase.message,
        output: modelResult.output,
        raw: modelResult.raw,
        durationMs: modelResult.durationMs,
        totalTokens: modelResult.totalTokens,
        ...grade,
      };
    } catch (error) {
      return {
        id: testCase.id,
        task: testCase.task,
        category: testCase.category,
        difficulty: testCase.difficulty,
        message: testCase.message,
        output: null,
        error: error.message,
        checks: [{ name: "model_call", pass: false, expected: "valid JSON response", actual: error.message }],
        score: 0,
        pass: false,
      };
    }
  });

  const summary = summarize(results);
  const report = {
    runId: `chat-crud-${SPLIT}-${startedAt.toISOString().replace(/[:.]/g, "-")}`,
    split: SPLIT,
    model: MODEL,
    startedAt: startedAt.toISOString(),
    finishedAt: new Date().toISOString(),
    summary,
    cases: results,
  };
  const reportPath = path.join(REPORT_DIR, `${report.runId}.json`);
  const latestPath = path.join(REPORT_DIR, `latest-chat-crud-${SPLIT}.json`);
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
  fs.writeFileSync(latestPath, JSON.stringify(report, null, 2));

  console.log("");
  console.log(`Chat CRUD ${SPLIT} score: ${summary.score.toFixed(1)}/100 (${summary.passedChecks}/${summary.totalChecks} checks, ${summary.passedCases}/${summary.cases} perfect cases)`);
  console.log("By task:");
  for (const [task, group] of Object.entries(summary.byTask).sort()) {
    console.log(`  ${task}: ${group.score.toFixed(1)}/100 (${group.passedChecks}/${group.totalChecks})`);
  }
  console.log(`Report: ${reportPath}`);
  if (summary.score < MIN_SCORE) {
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
