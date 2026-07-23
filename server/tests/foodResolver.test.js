const assert = require("node:assert/strict");
const test = require("node:test");

const { nutritionInvariantFeedback, resolveFoodCandidate } = require("../foodResolver");

const candidate = {
  rowId: 42,
  candidateId: "db_42",
  name: "Example Food",
  brand: null,
  source: "test",
  servingDescription: "1 cup",
  servingGrams: 100,
  caloriesPerServing: 120,
  proteinG: 5,
  carbsG: 20,
  fatG: 2,
  portionBasis: "grams",
};

function fakeStore(searchImpl = () => [candidate]) {
  return {
    search: searchImpl,
    inspect: (rowId) => rowId === candidate.rowId ? candidate : null,
  };
}

function accepted(overrides = {}) {
  return {
    accept: true,
    servings: 1,
    portionDescription: "1 cup",
    servingUnit: "cup",
    confident: true,
    hasExplicitPortion: false,
    retryQuery: null,
    feedback: null,
    ...overrides,
  };
}

test("shows seeded database candidates to the LLM on its first turn", async () => {
  let firstPrompt;
  const result = await resolveFoodCandidate({
    userMessage: "I ate example food",
    foodMention: "example food",
    foodSearchStore: fakeStore(),
    askAgent: async (prompt) => {
      firstPrompt = prompt;
      return { action: "pick", rowId: 42, servings: 1, portionDescription: "1 cup", servingUnit: "cup" };
    },
    verifyPick: async () => accepted(),
  });

  assert.match(firstPrompt, /Round 0 - query "example food"/);
  assert.match(firstPrompt, /rowId 42: Example Food/);
  assert.equal(result.status, 200);
  assert.equal(result.body.candidateId, "db_42");
});

test("does not accept give-up before a second materially different search", async () => {
  const actions = [
    { action: "give_up" },
    { action: "search", query: "better query", offset: 0 },
    { action: "pick", rowId: 42, servings: 1, portionDescription: "1 cup", servingUnit: "cup" },
  ];
  const result = await resolveFoodCandidate({
    userMessage: "I ate example food",
    foodMention: "example food",
    foodSearchStore: fakeStore(),
    askAgent: async () => actions.shift(),
    verifyPick: async () => accepted(),
  });

  assert.equal(result.status, 200);
});

test("returns a transient failure when malformed actions exhaust the bounded loop", async () => {
  const result = await resolveFoodCandidate({
    userMessage: "I ate example food",
    foodMention: "example food",
    foodSearchStore: fakeStore(),
    askAgent: async () => ({ action: "wat" }),
    verifyPick: async () => accepted(),
    maxTurns: 2,
  });

  assert.deepEqual(result, { status: 503, body: { error: "food_resolution_failed" } });
});

test("rejects row IDs that were never returned by retrieval", async () => {
  const result = await resolveFoodCandidate({
    userMessage: "I ate example food",
    foodMention: "example food",
    foodSearchStore: fakeStore(),
    askAgent: async () => ({ action: "pick", rowId: 999 }),
    verifyPick: async () => accepted(),
    maxTurns: 1,
  });

  assert.equal(result.status, 503);
});

test("stops executing redundant searches after two reformulations", async () => {
  const queries = [];
  const actions = [
    { action: "search", query: "second query", offset: 0 },
    { action: "search", query: "third query", offset: 0 },
    { action: "search", query: "fourth query", offset: 0 },
    { action: "pick", rowId: 42, servings: 1, portionDescription: "1 cup", servingUnit: "cup" },
  ];
  const result = await resolveFoodCandidate({
    userMessage: "I ate example food",
    foodMention: "example food",
    foodSearchStore: fakeStore((query) => {
      queries.push(query);
      return [candidate];
    }),
    askAgent: async () => actions.shift(),
    verifyPick: async () => accepted(),
  });

  assert.equal(result.status, 200);
  assert.deepEqual(queries, ["example food", "second query", "third query"]);
});

test("rejects a caloric substitute for a diet or zero-sugar soft drink", async () => {
  const regularCola = { ...candidate, name: "Cherry Cola", caloriesPerServing: 240 };
  assert.match(
    nutritionInvariantFeedback("20 oz cherry Coke Zero", regularCola, 1),
    /implies 240 calories/
  );
});

test("allows a noncaloric row for a diet or zero-sugar soft drink", async () => {
  const dietCola = { ...candidate, name: "Coke Zero", caloriesPerServing: 0.4 };
  assert.equal(nutritionInvariantFeedback("20 oz cherry Coke Zero", dietCola, 5.9), null);
});
