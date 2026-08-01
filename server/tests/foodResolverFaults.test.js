const assert = require("node:assert/strict");
const test = require("node:test");

const { resolveFoodCandidate } = require("../foodResolver");

// Minimal in-memory stand-in for the sqlite-backed food store.
function fakeStore(rows) {
  return {
    isAvailable: true,
    search(query) {
      const q = String(query || "").toLowerCase();
      return rows.filter((row) => row.name.toLowerCase().includes(q.split(" ")[0]));
    },
    inspect(rowId) {
      return rows.find((row) => row.rowId === rowId) || null;
    },
  };
}

const YOGURT = {
  rowId: 42,
  candidateId: "db_42",
  name: "Greek yogurt",
  brand: null,
  source: "test",
  servingGrams: 170,
  servingDescription: "170 g",
  caloriesPerServing: 147,
  portionBasis: "grams",
};

test("an empty-completion agent error falls back to the seeded search instead of throwing", async () => {
  const outcome = await resolveFoodCandidate({
    userMessage: "I had greek yogurt",
    foodMention: "greek yogurt",
    foodSearchStore: fakeStore([YOGURT]),
    askAgent: async () => { throw new Error("empty completion from test-model"); },
    verifyPick: async () => { throw new Error("should not be called"); },
  });

  assert.equal(outcome.status, 200);
  assert.equal(outcome.body.rowId, 42);
  assert.equal(outcome.body.confident, false);
  assert.equal(outcome.body.servings, 1);
});

test("a failing verifier does not discard a resolved database row", async () => {
  const outcome = await resolveFoodCandidate({
    userMessage: "I had greek yogurt",
    foodMention: "greek yogurt",
    foodSearchStore: fakeStore([YOGURT]),
    askAgent: async () => ({
      action: "pick",
      rowId: 42,
      servings: 1.5,
      portionDescription: "255 g",
      servingUnit: "gram",
      confident: true,
      hasExplicitPortion: true,
    }),
    verifyPick: async () => { throw new Error("verifier upstream 500"); },
  });

  assert.equal(outcome.status, 200);
  assert.equal(outcome.body.rowId, 42);
  assert.equal(outcome.body.servings, 1.5);
  assert.equal(outcome.body.confident, false, "unverified pick must not claim confidence");
});

test("absurd servings from the model are clamped at the pick boundary", async () => {
  const outcome = await resolveFoodCandidate({
    userMessage: "I had greek yogurt",
    foodMention: "greek yogurt",
    foodSearchStore: fakeStore([YOGURT]),
    askAgent: async () => ({
      action: "pick",
      rowId: 42,
      servings: 1e307,
      portionDescription: "a mountain",
      servingUnit: "serving",
      confident: true,
      hasExplicitPortion: true,
    }),
    verifyPick: async (payload) => ({
      accept: true,
      servings: payload.servings,
      portionDescription: payload.portionDescription,
      servingUnit: payload.servingUnit,
      confident: payload.confident,
      hasExplicitPortion: payload.hasExplicitPortion,
      retryQuery: null,
      feedback: null,
    }),
  });

  assert.equal(outcome.status, 200);
  assert.equal(outcome.body.servings, 1, "1e307 servings must collapse to the fallback of 1");
});

test("an exhausted deadline still returns the deterministic fallback", async () => {
  const outcome = await resolveFoodCandidate({
    userMessage: "I had greek yogurt",
    foodMention: "greek yogurt",
    foodSearchStore: fakeStore([YOGURT]),
    deadlineMs: 0,
    askAgent: async () => { throw new Error("should not be called after deadline"); },
    verifyPick: async () => { throw new Error("should not be called"); },
  });

  assert.equal(outcome.status, 200);
  assert.equal(outcome.body.rowId, 42);
});

test("no usable candidates still yields a clean 422, not an exception", async () => {
  const outcome = await resolveFoodCandidate({
    userMessage: "I had unobtainium stew",
    foodMention: "unobtainium stew",
    foodSearchStore: fakeStore([]),
    askAgent: async () => { throw new Error("empty completion"); },
    verifyPick: async () => { throw new Error("unused"); },
  });

  assert.equal(outcome.status, 422);
  assert.equal(outcome.body.error, "no_matching_food");
});
