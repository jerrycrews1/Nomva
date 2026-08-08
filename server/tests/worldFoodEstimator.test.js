const assert = require("node:assert/strict");
const test = require("node:test");

const {
  firstNonNull,
  resolveWorldFoodEstimate,
  sanitizeWorldFoodEstimate,
} = require("../worldFoodEstimator");

function estimate(overrides = {}) {
  return {
    found: true,
    canonicalName: "Doro Wat (Ethiopian Chicken and Egg Stew)",
    aliases: ["doro wot"],
    servingDescription: "1 bowl (about 1.5 cups)",
    servingGrams: 420,
    caloriesPerServing: 480,
    proteinG: 34,
    carbsG: 24,
    fatG: 27,
    fiberG: 5,
    sugarG: 8,
    sodiumMg: 760,
    components: [
      { name: "Chicken", servingDescription: "5 oz cooked", calories: 220, proteinG: 30, carbsG: 0, fatG: 10, fiberG: 0, sugarG: 0, sodiumMg: 180 },
      { name: "Egg", servingDescription: "1 large", calories: 70, proteinG: 6, carbsG: 0.5, fatG: 5, fiberG: 0, sugarG: 0, sodiumMg: 70 },
      { name: "Berbere onion sauce", servingDescription: "3/4 cup", calories: 190, proteinG: 3, carbsG: 23.5, fatG: 12, fiberG: 5, sugarG: 8, sodiumMg: 510 },
    ],
    confidence: 0.72,
    assumptions: "Chicken, one egg, onion sauce, and one ordinary injera-free bowl.",
    servings: 1,
    portionDescription: "1 ordinary bowl",
    servingUnit: "bowl",
    hasExplicitPortion: false,
    ...overrides,
  };
}

test("accepts a coherent recognized cultural dish estimate", () => {
  const result = sanitizeWorldFoodEstimate(estimate(), "doro wat");
  assert.equal(result.name, "Doro Wat (Ethiopian Chicken and Egg Stew)");
  assert.equal(result.quality, "estimated");
  assert.equal(result.confidence, 0.72);
  assert.equal(result.caloriesPerServing, 480);
  assert.equal(result.proteinG, 39);
  assert.equal(result.components.length, 3);
});

test("rejects unknown, mismatched, or internally inconsistent estimates", () => {
  assert.equal(sanitizeWorldFoodEstimate(estimate({ found: false }), "doro wat"), null);
  assert.equal(sanitizeWorldFoodEstimate(estimate({ canonicalName: "Chicken Soup", aliases: [] }), "doro wat"), null);
  assert.equal(sanitizeWorldFoodEstimate(estimate({ components: [] }), "doro wat"), null);
  assert.equal(sanitizeWorldFoodEstimate(estimate({
    components: [
      { name: "Broken", servingDescription: "1 serving", calories: 10, proteinG: 0, carbsG: 0, fatG: 80, fiberG: 0, sugarG: 0, sodiumMg: 0 },
    ],
  }), "doro wat"), null);
});

test("stores and returns a visibly estimated reusable candidate", async () => {
  let stored;
  const result = await resolveWorldFoodEstimate({
    userMessage: "I had doro wat",
    foodMention: "doro wat",
    askAgent: async () => estimate(),
    sourceUrl: "https://nomva.example/food-estimates",
    knowledgeStore: {
      upsert(value) {
        stored = value;
        return { ...value, candidateId: "learned_1", rowId: -1, source: "web_estimate" };
      },
    },
  });

  assert.equal(stored.quality, "estimated");
  assert.equal(result.source, "web_estimate");
  assert.equal(result.confident, false);
  assert.equal(result.portionDescription, "1 ordinary bowl");
});

test("firstNonNull returns the first usable result and remains bounded", async () => {
  const startedAt = Date.now();
  const value = await firstNonNull([
    Promise.resolve(null),
    new Promise((resolve) => setTimeout(() => resolve("resolved"), 10)),
  ], 100);
  assert.equal(value, "resolved");

  const timedOut = await firstNonNull([
    new Promise((resolve) => setTimeout(() => resolve("late"), 100)),
  ], 10);
  assert.equal(timedOut, null);
  assert.ok(Date.now() - startedAt < 100);
});
