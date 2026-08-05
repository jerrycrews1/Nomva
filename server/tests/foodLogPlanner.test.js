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
  assert.equal(plan.items[0].nutritionEstimate.confidence, 0.8);
});

test("drops impossible estimates and any estimate attached to a non-composite", () => {
  const impossible = sanitizeFoodLogPlan({
    items: [{
      mention: "assembled meal",
      kind: "composite",
      nutritionEstimate: compositeEstimate({ caloriesPerServing: 50, fatG: 100 }),
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

test("structured planner is reserved for relational or scoped meal language", () => {
  assert.equal(shouldUseStructuredFoodPlan("one banana"), false);
  assert.equal(shouldUseStructuredFoodPlan("Venti caramel macchiato from Starbucks"), false);
  assert.equal(shouldUseStructuredFoodPlan("tea with honey"), true);
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
