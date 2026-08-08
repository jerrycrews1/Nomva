const test = require("node:test");
const assert = require("node:assert/strict");

const {
  sanitizeFoodLogPlan,
  shouldUseStructuredFoodPlan,
} = require("../foodLogPlanner");

function compositeEstimate(overrides = {}) {
  return {
    canonicalName: "Loaded quesadilla",
    servingDescription: "1 loaded quesadilla",
    servingGrams: 320,
    caloriesPerServing: 640,
    proteinG: 32,
    carbsG: 66,
    fatG: 28,
    fiberG: 10,
    sugarG: 6,
    sodiumMg: 980,
    components: [
      { name: "Flour tortilla", servingDescription: "1 large", calories: 220, proteinG: 6, carbsG: 36, fatG: 5, fiberG: 2, sugarG: 1, sodiumMg: 400 },
      { name: "Cheese", servingDescription: "2 oz", calories: 180, proteinG: 11, carbsG: 2, fatG: 14, fiberG: 0, sugarG: 0.5, sodiumMg: 300 },
      { name: "Meat", servingDescription: "3 oz cooked", calories: 150, proteinG: 15, carbsG: 1, fatG: 9, fiberG: 0, sugarG: 0, sodiumMg: 180 },
      { name: "Beans and corn", servingDescription: "1/2 cup", calories: 90, proteinG: 4, carbsG: 17, fatG: 1, fiberG: 4, sugarG: 3, sodiumMg: 100 },
    ],
    confidence: 0.86,
    assumptions: "One 10-inch tortilla with ordinary portions of cheese, beans, meat, and corn.",
    ...overrides,
  };
}

test("global quantity scope is enforced across every planned food", () => {
  const plan = sanitizeFoodLogPlan({
    meal: "dinner",
    quantityScope: "all_items",
    globalServings: 3,
    items: [
      {
        mention: "meat and bean quesadilla with cheese and flour tortilla",
        searchQuery: "meat bean cheese quesadilla",
        kind: "composite",
        servings: 1,
        portionDescription: "1 quesadilla",
        servingUnit: "quesadilla",
        confident: true,
        hasExplicitPortion: false,
      },
      {
        mention: "corn",
        searchQuery: "corn",
        kind: "single",
        servings: 1,
        portionDescription: "1 serving",
        servingUnit: "serving",
        confident: false,
        hasExplicitPortion: false,
      },
      {
        mention: "sour cream",
        searchQuery: "sour cream",
        kind: "single",
        servings: 1,
        portionDescription: "1 serving",
        servingUnit: "serving",
        confident: false,
        hasExplicitPortion: false,
      },
    ],
  });

  assert.equal(plan.meal, "dinner");
  assert.equal(plan.quantityScope, "all_items");
  assert.equal(plan.globalServings, 3);
  assert.deepEqual(plan.items.map((item) => item.servings), [3, 3, 3]);
  assert.deepEqual(plan.items.map((item) => item.portionDescription), [
    "3 quesadillas",
    "3 servings",
    "3 servings",
  ]);
  assert.ok(plan.items.every((item) => item.hasExplicitPortion));
});

test("per-item amounts remain attached to their own foods", () => {
  const plan = sanitizeFoodLogPlan({
    meal: "none",
    quantityScope: "per_item",
    globalServings: null,
    items: [
      {
        mention: "tea",
        searchQuery: "black tea",
        kind: "single",
        servings: 2,
        portionDescription: "2 cups",
        servingUnit: "cup",
        confident: true,
        hasExplicitPortion: true,
      },
      {
        mention: "honey",
        searchQuery: "honey",
        kind: "single",
        servings: 1,
        portionDescription: "1 tablespoon",
        servingUnit: "tablespoon",
        confident: true,
        hasExplicitPortion: true,
      },
    ],
  });

  assert.deepEqual(plan.items.map((item) => item.servings), [2, 1]);
  assert.deepEqual(plan.items.map((item) => item.portionDescription), ["2 cups", "1 tablespoon"]);
});

test("normalizes a contradictory counted portion from the model", () => {
  const plan = sanitizeFoodLogPlan({
    quantityScope: "per_item",
    items: [
      {
        mention: "2 eggs",
        kind: "single",
        servings: 2,
        portionDescription: "1 egg",
        servingUnit: "egg",
        hasExplicitPortion: true,
      },
    ],
  });

  assert.equal(plan.items[0].servings, 2);
  assert.equal(plan.items[0].portionDescription, "2 eggs");
});

test("normalizes a contradictory generic serving description", () => {
  const plan = sanitizeFoodLogPlan({
    quantityScope: "per_item",
    items: [{
      mention: "Greek yogurt",
      kind: "single",
      servings: 2,
      portionDescription: "1 serving",
      servingUnit: "serving",
      hasExplicitPortion: true,
    }],
  });

  assert.equal(plan.items[0].servings, 2);
  assert.equal(plan.items[0].portionDescription, "2 servings");
});

test("accepts bounded self-consistent composite nutrition as an estimate", () => {
  const plan = sanitizeFoodLogPlan({
    quantityScope: "none",
    items: [{
      mention: "quesadilla with cheese beans meat and corn",
      searchQuery: "loaded quesadilla cheese beans meat corn",
      kind: "composite",
      servings: 1,
      nutritionEstimate: compositeEstimate(),
    }],
  });

  assert.equal(plan.items[0].nutritionEstimate.canonicalName, "Loaded quesadilla");
  assert.equal(plan.items[0].nutritionEstimate.caloriesPerServing, 640);
  assert.equal(plan.items[0].nutritionEstimate.proteinG, 36);
  assert.equal(plan.items[0].nutritionEstimate.sodiumMg, 980);
  assert.equal(plan.items[0].nutritionEstimate.components.length, 4);
  assert.equal(plan.items[0].nutritionEstimate.confidence, 0.8);
});

test("drops impossible estimates and any estimate attached to a non-composite", () => {
  const impossible = sanitizeFoodLogPlan({
    items: [{
      mention: "assembled meal",
      kind: "composite",
      nutritionEstimate: compositeEstimate({ components: [] }),
    }],
  });
  const single = sanitizeFoodLogPlan({
    items: [{
      mention: "apple",
      kind: "single",
      nutritionEstimate: compositeEstimate(),
    }],
  });

  assert.equal(impossible.items[0].nutritionEstimate, null);
  assert.equal(single.items[0].nutritionEstimate, null);
});

test("planner sanitizer rejects empty plans, duplicates, and absurd serving counts", () => {
  assert.equal(sanitizeFoodLogPlan({ items: [] }), null);

  const plan = sanitizeFoodLogPlan({
    meal: "brunch",
    quantityScope: "all_items",
    globalServings: 1e300,
    items: [
      { mention: "Greek yogurt", kind: "single", servings: 1 },
      { mention: "  greek   yogurt ", kind: "single", servings: 2 },
    ],
  });

  assert.equal(plan.meal, null);
  assert.equal(plan.items.length, 1);
  assert.equal(plan.items[0].servings, 1);
});

test("structured planner handles relational, conjunctive, or scoped meal language", () => {
  assert.equal(shouldUseStructuredFoodPlan("one banana"), false);
  assert.equal(shouldUseStructuredFoodPlan("Venti caramel macchiato from Starbucks"), false);
  assert.equal(shouldUseStructuredFoodPlan("tea with honey"), true);
  assert.equal(shouldUseStructuredFoodPlan("salmon and rice"), true);
  assert.equal(shouldUseStructuredFoodPlan("mac and cheese"), true);
  assert.equal(shouldUseStructuredFoodPlan("soup and bread, two servings of everything"), true);
});

test("removes standalone components already represented by a composite dish", () => {
  const plan = sanitizeFoodLogPlan({
    quantityScope: "none",
    items: [
      {
        mention: "quesadilla with cheese, flour tortilla, beans, and meat",
        kind: "composite",
      },
      { mention: "flour tortilla", kind: "single" },
      { mention: "cheese", kind: "single" },
    ],
  });

  assert.deepEqual(
    plan.items.map((item) => item.mention),
    ["quesadilla with cheese, flour tortilla, beans, and meat"]
  );
});

test("uses a composite search identity when its display wording is concise", () => {
  const plan = sanitizeFoodLogPlan({
    quantityScope: "none",
    items: [
      {
        mention: "loaded quesadilla",
        searchQuery: "quesadilla with cheese flour tortilla beans and meat",
        kind: "composite",
      },
      { mention: "flour tortilla", kind: "single" },
    ],
  });

  assert.deepEqual(
    plan.items.map((item) => item.mention),
    ["loaded quesadilla"]
  );
});

test("preserves a side named inside a composite description", () => {
  const plan = sanitizeFoodLogPlan({
    quantityScope: "none",
    items: [
      {
        mention: "turkey and cheese sandwich with a side of chips",
        kind: "composite",
      },
      { mention: "chips", kind: "single" },
    ],
  });

  assert.deepEqual(
    plan.items.map((item) => item.mention),
    ["turkey and cheese sandwich with a side of chips", "chips"]
  );
});

test("preserves a separately planned dip named inside a composite description", () => {
  const plan = sanitizeFoodLogPlan({
    quantityScope: "none",
    items: [
      {
        mention: "corn dipped in sour cream",
        kind: "composite",
      },
      { mention: "sour cream", kind: "single" },
    ],
  });

  assert.deepEqual(
    plan.items.map((item) => item.mention),
    ["corn dipped in sour cream", "sour cream"]
  );
});
