const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const {
  LEARNED_ROW_OFFSET,
  loadFoodKnowledgeStore,
} = require("../foodKnowledgeStore");

function fixture(overrides = {}) {
  return {
    name: "Venti Caramel Macchiato",
    brand: "Starbucks",
    aliases: ["Starbucks venti caramel macchiato"],
    servingDescription: "1 hot venti (20 fl oz)",
    servingGrams: 591,
    caloriesPerServing: 310,
    proteinG: 13,
    carbsG: 45,
    fatG: 9,
    fiberG: 0,
    sugarG: 42,
    sodiumMg: 150,
    quality: "published",
    confidence: 0.98,
    sourceUrl: "https://www.starbucks.com/menu/product/413/hot/nutrition",
    sourceTitle: "Starbucks Caramel Macchiato",
    evidence: "Official nutrition for the selected size.",
    components: [],
    ...overrides,
  };
}

function storeForTest(t, now = undefined) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "nomva-food-knowledge-"));
  const store = loadFoodKnowledgeStore({
    dbPath: path.join(directory, "catalog.sqlite"),
    ...(now ? { now } : {}),
  });
  t.after(() => {
    store.close();
    fs.rmSync(directory, { recursive: true, force: true });
  });
  return store;
}

test("stores aliases and retrieves punctuation and one-edit variants", (t) => {
  const store = storeForTest(t);
  const inserted = store.upsert(fixture(), ["lower priority alias", "venti caramel macchiato from Starbucks"]);

  assert.match(inserted.candidateId, /^learned_/);
  assert.ok(inserted.rowId > LEARNED_ROW_OFFSET);
  assert.equal(store.inspect(1), null);
  assert.equal(store.inspect(inserted.rowId).name, "Venti Caramel Macchiato");

  const exact = store.search("venti caramel macchiato from Starbucks");
  const typo = store.search("venti caramel machiato from Starbucks");
  assert.equal(exact[0].candidateId, inserted.candidateId);
  assert.equal(typo[0].candidateId, inserted.candidateId);
});

test("expires learned foods and negative lookup cache entries", (t) => {
  let current = new Date("2026-08-01T12:00:00Z");
  const store = storeForTest(t, () => current);
  store.upsert(fixture(), ["starbucks macchiato"], 1);
  store.rememberMiss("imaginary cafe plate", 1);

  assert.equal(store.search("starbucks macchiato").length, 1);
  assert.equal(store.hasFreshMiss("imaginary cafe plate"), true);

  current = new Date("2026-08-03T12:00:00Z");
  assert.equal(store.search("starbucks macchiato").length, 0);
  assert.equal(store.hasFreshMiss("imaginary cafe plate"), false);
  assert.deepEqual(store.prune(), { foods: 1, misses: 1 });
});

test("published nutrition cannot be downgraded by a later estimate", (t) => {
  const store = storeForTest(t);
  const published = store.upsert(fixture(), ["original alias"]);
  const afterEstimate = store.upsert(fixture({
    caloriesPerServing: 900,
    quality: "estimated",
    confidence: 0.7,
    sourceUrl: "https://example.com/estimate",
  }), ["new spoken alias"]);

  assert.equal(afterEstimate.candidateId, published.candidateId);
  assert.equal(afterEstimate.quality, "published");
  assert.equal(afterEstimate.caloriesPerServing, 310);
  assert.equal(store.search("new spoken alias")[0].candidateId, published.candidateId);
});

test("a successful insert clears an earlier miss for the same query", (t) => {
  const store = storeForTest(t);
  store.rememberMiss("venti caramel macchiato from Starbucks");
  assert.equal(store.hasFreshMiss("venti caramel macchiato from Starbucks"), true);

  store.upsert(fixture(), ["venti caramel macchiato from Starbucks"]);
  assert.equal(store.hasFreshMiss("venti caramel macchiato from Starbucks"), false);
  assert.equal(store.stats().activeFoods, 1);
});

test("persists structured components for reusable estimates", (t) => {
  const store = storeForTest(t);
  const components = [{
    name: "Coffee",
    servingDescription: "1 cup",
    calories: 4,
    proteinG: 0.3,
    carbsG: 0,
    fatG: 0,
    fiberG: 0,
    sugarG: 0,
    sodiumMg: 5,
  }];
  const inserted = store.upsert(fixture({
    name: "Estimated coffee",
    brand: null,
    quality: "estimated",
    confidence: 0.7,
    sourceUrl: "https://example.com/coffee",
    components,
  }));

  assert.deepEqual(store.inspect(inserted.rowId).components, components);
});
