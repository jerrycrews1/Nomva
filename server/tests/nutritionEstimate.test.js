const assert = require("node:assert/strict");
const test = require("node:test");

const {
  aggregateNutritionComponents,
  componentEvidence,
  sanitizeNutritionComponents,
} = require("../nutritionEstimate");

function component(overrides = {}) {
  return {
    name: "Rice",
    servingDescription: "1 cup cooked",
    calories: 205,
    proteinG: 4.3,
    carbsG: 44.5,
    fatG: 0.4,
    fiberG: 0.6,
    sugarG: 0.1,
    sodiumMg: 2,
    ...overrides,
  };
}

test("sanitizes and deterministically sums structured nutrition components", () => {
  const components = sanitizeNutritionComponents([
    component(),
    component({
      name: "Chicken",
      servingDescription: "4 oz cooked",
      calories: 187,
      proteinG: 35,
      carbsG: 0,
      fatG: 4,
      fiberG: 0,
      sugarG: 0,
      sodiumMg: 84,
    }),
  ], { required: true });

  assert.deepEqual(aggregateNutritionComponents(components), {
    caloriesPerServing: 392,
    proteinG: 39.3,
    carbsG: 44.5,
    fatG: 4.4,
    fiberG: 0.6,
    sugarG: 0.1,
    sodiumMg: 86,
  });
  assert.match(componentEvidence(components), /Rice \(1 cup cooked\): 205 cal/);
});

test("rejects missing, excessive, malformed, and arithmetically impossible components", () => {
  assert.equal(sanitizeNutritionComponents([], { required: true }), null);
  assert.equal(sanitizeNutritionComponents([component({ name: "" })], { required: true }), null);
  assert.equal(sanitizeNutritionComponents([component({ sodiumMg: null })], { required: true }), null);
  assert.equal(sanitizeNutritionComponents([
    component({ calories: 5, proteinG: 30, carbsG: 0, fatG: 0 }),
  ], { required: true }), null);
  assert.equal(sanitizeNutritionComponents(
    Array.from({ length: 31 }, () => component()),
    { required: true }
  ), null);
});
