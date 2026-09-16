#!/usr/bin/env node
"use strict";

// Exercises deployed HTTP routes, real retrieval and the real model. It does
// not substitute language/schema scores for the separate Swift persistence/UI gate.
const fs = require("node:fs");
const crypto = require("node:crypto");
const assert = require("node:assert/strict");
const arg = (name, fallback) => process.argv.find((v) => v.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const baseURL = arg("base-url", process.env.NOMVA_EVAL_BASE_URL || "http://127.0.0.1:18445").replace(/\/$/, "");
const reportPath = arg("report", "/tmp/nomva-food-journey-gate.json");
const selectedCase = arg("case", "all");
const cases = [
  { id: "screenshot-dinner", meal: "dinner", message: "One chicken breast skinless boneless, half cup broccoli, and one piece of cornbread for dinner", foods: [
    { name: /chicken.*breast|breast.*chicken/i, grams: [100, 250], calories: [150, 450], forbidden: /breaded|fried|sandwich|salad/i },
    { name: /^broccoli\b/i, grams: [30, 95], calories: [5, 50], forbidden: /soup|cheese|salad|raab/i },
    { name: /^cornbread(?:,|$)/i, grams: [25, 90], calories: [75, 300], forbidden: /stuffing|chicken/i },
  ] },
  { id: "fraction-and-grams", meal: "lunch", message: "For lunch I ate 150 g cooked rice, half a cup of broccoli, and two eggs", foods: [
    { name: /rice/i, grams: [149, 151], calories: [150, 250], forbidden: /uncooked|dry|cake|cereal/i },
    { name: /^broccoli\b/i, grams: [30, 95], calories: [5, 50], forbidden: /soup|cheese|salad|raab/i },
    { name: /^eggs?\b/i, grams: [80, 130], calories: [110, 210], forbidden: /white only|yolk only|substitute/i },
  ] },
  { id: "ordinary-breakfast", meal: "breakfast", message: "Breakfast was two scrambled eggs, one slice whole wheat toast, and one banana", foods: [
    { name: /eggs?.*scrambled|scrambled.*eggs?/i, grams: [80, 150], calories: [120, 280] },
    { name: /bread|toast/i, grams: [20, 55], calories: [50, 160], forbidden: /muffin|cracker|melba/i },
    { name: /^bananas?\b/i, grams: [70, 180], calories: [60, 165], forbidden: /chip|bread|cake|dried/i },
  ] },
  { id: "measured-snack", meal: "snack", message: "For a snack I had 30 g almonds and 170 g plain Greek yogurt", foods: [
    { name: /^almonds?\b/i, grams: [29, 31], calories: [150, 200], forbidden: /milk|butter|chocolate/i },
    { name: /yogurt.*greek|greek.*yogurt/i, grams: [169, 171], calories: [80, 200], forbidden: /vanilla|strawberry|blueberry/i },
  ] },
  { id: "single-common-food", meal: "dinner", message: "I ate one skinless boneless chicken breast for dinner", foods: [
    { name: /chicken.*breast|breast.*chicken/i, grams: [100, 250], calories: [150, 450], forbidden: /breaded|fried|sandwich|salad/i },
  ] },
];

async function main() {
  const remote = !["127.0.0.1", "localhost"].includes(new URL(baseURL).hostname);
  if (remote && !process.env.NOMVA_AUTOMATION_TOKEN) throw new Error("Remote validation requires the existing automation credential in the environment");
  const user = crypto.randomUUID(), device = crypto.randomBytes(24).toString("hex");
  const headers = { "content-type": "application/json", "x-nomva-user-id": user, "x-nomva-device-token": device };
  if (remote) headers["x-nomva-automation-token"] = process.env.NOMVA_AUTOMATION_TOKEN;
  else headers["x-nomva-app-attest-mode"] = "simulator";
  const request = async (route, body, acceptedStatuses = [200]) => {
    const start = performance.now();
    const response = await fetch(baseURL + route, { method: "POST", headers, body: JSON.stringify(body), signal: AbortSignal.timeout(20_000) });
    const result = { status: response.status, ms: Math.round(performance.now() - start), body: await response.json() };
    assert.ok(acceptedStatuses.includes(response.status), `${route} returned HTTP ${response.status}`);
    return result;
  };
  const auth = await request("/v1/auth/register", { nomvaUserId: user, deviceToken: device });
  assert.ok(auth.body.token, "registration must issue a session");
  headers.authorization = `Bearer ${auth.body.token}`;
  const selected = cases.filter((c) => selectedCase === "all" || c.id === selectedCase);
  assert.ok(selected.length, "unknown case name");
  const results = [];
  for (const test of selected) {
    const result = { id: test.id, message: test.message, passed: false };
    const start = performance.now();
    try {
      result.intent = await request("/v1/classify-intent", { userMessage: test.message, recentMessages: [] });
      assert.equal(result.intent.body.intent, "log_food");
      result.plan = await request("/v1/plan-food-log", { userMessage: test.message, recentMessages: [], pendingFoods: [] }, [200, 422]);
      if (result.plan.status === 422) {
        assert.equal(result.plan.body.error, "structured_plan_not_needed");
        // The single-food API contract deliberately bypasses the compound-meal planner.
        result.split = await request("/v1/split-foods", { userMessage: test.message });
        const items = [];
        for (const mention of result.split.body.foods) {
          const query = await request("/v1/build-food-search-query", { userMessage: test.message, foodMention: mention });
          items.push({ mention, searchQuery: query.body.query, kind: "single" });
        }
        result.plan = { ...result.plan, singleFoodRoute: true, body: { meal: test.meal, items } };
      }
      assert.equal(result.plan.body.meal, test.meal);
      assert.equal(result.plan.body.items.length, test.foods.length, "every food must have its own planned slot");
      result.resolution = await request("/v1/resolve-food-candidates", { userMessage: test.message,
        items: result.plan.body.items.map((item) => ({ foodMention: item.mention, searchQuery: item.searchQuery, resolutionHint: item.kind })) });
      const slots = result.resolution.body.results;
      assert.equal(slots.length, test.foods.length);
      assert.equal(new Set(slots.map((slot) => slot.requestIndex)).size, slots.length);
      const foods = slots.map((slot) => {
        assert.equal(slot.error, null, `unresolved slot ${slot.requestIndex}`);
        assert.ok(slot.candidate, `missing candidate ${slot.requestIndex}`);
        const candidate = slot.candidate;
        const grams = candidate.servingGrams * candidate.servings;
        const calories = candidate.caloriesPerServing * candidate.servings;
        assert.ok(Number.isFinite(grams) && grams > 0 && Number.isFinite(calories) && calories > 0);
        return { ...candidate, grams, calories };
      });
      for (const expected of test.foods) {
        const matches = foods.filter((food) => expected.name.test(food.name));
        assert.equal(matches.length, 1, `wrong or duplicated food: ${expected.name}`);
        const food = matches[0];
        assert.ok(!food.brand, `An ordinary unbranded food cannot silently become ${food.brand}`);
        if (expected.forbidden) assert.ok(!expected.forbidden.test(food.name), `wrong variant: ${food.name}`);
        assert.ok(food.grams >= expected.grams[0] && food.grams <= expected.grams[1], `${food.name}: ${food.grams} g outside ${expected.grams}`);
        assert.ok(food.calories >= expected.calories[0] && food.calories <= expected.calories[1], `${food.name}: ${food.calories} calories outside ${expected.calories}`);
      }
      result.ms = Math.round(performance.now() - start);
      assert.ok(result.ms < 20_000, `ordinary meal exceeded 20 seconds (${result.ms} ms)`);
      result.passed = true;
    } catch (error) { result.error = error.message; }
    result.ms ??= Math.round(performance.now() - start);
    results.push(result);
    console.log(`${result.passed ? "PASS" : "FAIL"} ${result.id} ${result.ms}ms${result.error ? `: ${result.error}` : ""}`);
    fs.writeFileSync(reportPath, JSON.stringify({ baseURL, verifiedAt: new Date().toISOString(), results }, null, 2) + "\n");
  }
  if (results.some((result) => !result.passed)) process.exitCode = 1;
}
main().catch((error) => { console.error(error.message); process.exitCode = 1; });
