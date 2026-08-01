const assert = require("node:assert/strict");
const test = require("node:test");

const {
  boundedNumber,
  boundedServings,
  boundedGrams,
  boundedGoalValue,
  sanitizePhotoAnalysis,
  BOUNDS,
} = require("../numericGuards");

test("boundedNumber rejects non-finite and out-of-range values", () => {
  assert.equal(boundedNumber(NaN, BOUNDS.servings), null);
  assert.equal(boundedNumber(Infinity, BOUNDS.servings), null);
  assert.equal(boundedNumber(-Infinity, BOUNDS.servings), null);
  assert.equal(boundedNumber("3", BOUNDS.servings), null);
  assert.equal(boundedNumber(1e307, BOUNDS.servings), null);
  assert.equal(boundedNumber(0, BOUNDS.servings), null);
  assert.equal(boundedNumber(2, BOUNDS.servings), 2);
  assert.equal(boundedNumber(1e307, BOUNDS.servings, 1), 1);
});

test("servings accept normal portions and refuse absurd ones", () => {
  assert.equal(boundedServings(0.33), 0.33);
  assert.equal(boundedServings(3), 3);
  assert.equal(boundedServings(100), 100);
  assert.equal(boundedServings(25000, 1), 1);
  assert.equal(boundedServings(1e307, 1), 1);
  assert.equal(boundedServings(9e99, 1), 1);
});

test("grams refuse a million metric tons", () => {
  assert.equal(boundedGrams(150), 150);
  assert.equal(boundedGrams(1e12), null);
  assert.equal(boundedGrams(0), null);
  assert.equal(boundedGrams(-5), null);
});

test("goal values are bounded per metric", () => {
  assert.equal(boundedGoalValue("calories", 2100), 2100);
  assert.equal(boundedGoalValue("calories", 99999999), null);
  assert.equal(boundedGoalValue("protein", 175), 175);
  assert.equal(boundedGoalValue("protein", 1e20), null);
  assert.equal(boundedGoalValue("water_oz", 90), 90);
  assert.equal(boundedGoalValue("target_weight_lbs", 165), 165);
  assert.equal(boundedGoalValue("unknown_metric", 100), null);
});

test("photo analysis output is sanitized before reaching the client", () => {
  const raw = {
    notFood: false,
    foods: [
      { name: "grilled chicken", portion: "1 breast", grams: 170, calories: 280, protein: 35, carbs: 0, fat: 12, fiber: 0 },
      { name: "mystery blob", portion: "??", grams: 100, calories: 1e308, protein: 10, carbs: 10, fat: 10 },
      { name: "", portion: "1", grams: 100, calories: 100, protein: 1, carbs: 1, fat: 1 },
      { name: "negative food", portion: "1", grams: 100, calories: -50, protein: 1, carbs: 1, fat: 1 },
    ],
  };
  const clean = sanitizePhotoAnalysis(raw);
  assert.equal(clean.foods.length, 1);
  assert.equal(clean.foods[0].name, "grilled chicken");
  assert.equal(clean.foods[0].calories, 280);
});

test("photo analysis tolerates a malformed model payload", () => {
  assert.deepEqual(sanitizePhotoAnalysis(null), { notFood: false, foods: [] });
  assert.deepEqual(sanitizePhotoAnalysis({ notFood: true }), { notFood: true, foods: [] });
  assert.deepEqual(sanitizePhotoAnalysis({ foods: "not an array" }), { notFood: false, foods: [] });
});
