const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const {
  createFoodSearchStore,
  isAuthoritativeReferenceSource,
} = require("../foodSearchStore");
const { loadFoodKnowledgeStore } = require("../foodKnowledgeStore");

const dbPath = process.env.NOMVA_TEST_FOOD_DB_PATH
  || path.join(__dirname, "..", "..", "Nomva", "Resources", "foods.sqlite");
const store = createFoodSearchStore({ dbPath });

test.after(() => {
  store.close?.();
});

function search(query, limit = 20) {
  assert.equal(store.isAvailable, true, store.error || "food database unavailable");
  return store.search(query, { limit });
}

function combinedIdentity(row) {
  return `${row.name || ""} ${row.brand || ""}`.toLowerCase();
}

test("finds an exact common prepared food ahead of sauces and seasonings", () => {
  const rows = search("sloppy joe");
  assert.ok(rows.length > 0);
  assert.equal(rows[0].name.toLowerCase(), "sloppy joe");
});

test("relaxes a missing flavor modifier without losing a zero-sugar modifier", () => {
  const rows = search("Cherry Coke Zero");
  const index = rows.findIndex((row) => combinedIdentity(row).includes("coke zero"));
  assert.ok(index >= 0 && index < 5, `Coke Zero rank was ${index}`);
});

test("removes attached portion tokens for retrieval", () => {
  const rows = search("20oz Coke Zero cherry");
  assert.ok(rows.slice(0, 5).some((row) => combinedIdentity(row).includes("coke zero")));
});

test("prefers authoritative generic produce over an unrequested brand", () => {
  const rows = search("1 cup blueberries");
  assert.equal(rows[0].name, "Blueberries, raw");
  assert.equal(isAuthoritativeReferenceSource(rows[0].source), true);
  assert.ok(rows[0].caloriesPerServing >= 80 && rows[0].caloriesPerServing <= 100);
});

test("authoritative generic food outranks a learned generic duplicate", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "nomva-ranking-"));
  const learnedStore = loadFoodKnowledgeStore({ dbPath: path.join(directory, "knowledge.sqlite") });
  learnedStore.upsert({
    name: "Blueberries",
    brand: null,
    servingDescription: "1 cup",
    servingGrams: 148,
    caloriesPerServing: 90,
    proteinG: 1,
    carbsG: 22,
    fatG: 0.5,
    fiberG: 3.5,
    quality: "published",
    confidence: 0.9,
    sourceUrl: "https://example.com/blueberries",
  }, ["blueberries"]);
  const learnedSearch = createFoodSearchStore({ dbPath, learnedStore });

  try {
    const rows = learnedSearch.search("blueberries", { limit: 5 });
    assert.equal(rows[0].name, "Blueberries, raw");
    assert.equal(isAuthoritativeReferenceSource(rows[0].source), true);
  } finally {
    learnedSearch.close();
    learnedStore.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("ranks a literal food above products that merely contain its token", () => {
  const rows = search("corn");
  assert.ok(/^corn(?:,|$)/i.test(rows[0].name), rows[0].name);
  assert.doesNotMatch(rows[0].name, /babyfood|flour|snack/i);
});

test("uses FNDDS for a natural cooked oatmeal serving", () => {
  const rows = search("oatmeal");
  assert.equal(rows[0].source, "survey_fndds");
  assert.match(rows[0].name, /^Oatmeal, NFS$/i);
  assert.match(rows[0].servingDescription, /cup.*cooked/i);
  assert.ok(rows[0].caloriesPerServing >= 140 && rows[0].caloriesPerServing <= 240);
});

test("uses a one-ounce FNDDS portion for unspecified almonds", () => {
  const rows = search("almonds");
  assert.equal(rows[0].source, "survey_fndds");
  assert.match(rows[0].name, /^Almonds, NFS$/i);
  assert.equal(rows[0].servingDescription, "1 oz");
});

test("generic produce does not default to a derived snack or sauce", () => {
  const sweetPotato = search("sweet potato")[0];
  const salmon = search("salmon")[0];
  assert.match(sweetPotato.name, /^Sweet potato, NFS$/i);
  assert.doesNotMatch(sweetPotato.name, /chip|fries|paste|casserole/i);
  assert.match(salmon.name, /^Fish, salmon, NFS$/i);
  assert.doesNotMatch(salmon.name, /salad|sauce|nugget/i);
});

test("ignores generic side-dish language", () => {
  const rows = search("side of corn");
  assert.ok(/^corn(?:,|$)/i.test(rows[0].name), rows[0].name);
});

test("treats a plain-food size adjective as portion context", () => {
  const rows = search("medium banana");
  assert.ok(rows.slice(0, 5).some((row) => /^bananas?(?:,|$)/i.test(row.name)), rows.map((row) => row.name).join(" | "));
});

test("a generic side food prefers a simple base over an unrequested ingredient", () => {
  const row = search("side salad")[0];
  assert.match(row.name, /mixed salad greens|lettuce.*salad/i, row.name);
  assert.doesNotMatch(row.name, /beef|cabbage|chicken|crab|lobster|pea|salmon|shrimp/i);
});

test("an unbranded generic request prefers an authoritative unspecified row", () => {
  const row = search("meatballs")[0];
  assert.equal(row.source, "survey_fndds");
  assert.equal(row.brand, null);
  assert.match(row.name, /^Meatballs, NS as to type of meat/i);
  assert.doesNotMatch(row.name, /meatless/i);
});

test("a requested animal protein subtype cannot collapse to an unspecified meat", () => {
  const row = search("chicken sausage")[0];
  assert.match(row.name, /chicken.*sausage|sausage.*chicken/i);
  assert.doesNotMatch(row.name, /^Sausage, NFS$/i);
});

test("rye toast resolves to toasted bread instead of melba crackers", () => {
  const row = search("rye toast")[0];
  assert.match(row.name, /^Bread, rye, toasted$/i);
  assert.doesNotMatch(row.name, /cracker|crispbread|melba/i);
  assert.ok(row.caloriesPerServing >= 60 && row.caloriesPerServing <= 120);
});

test("plain produce does not resolve to an unrequested pickled or baked form", () => {
  const row = search("zucchini")[0];
  assert.match(row.name, /^Zucchini$/i);
  assert.doesNotMatch(row.name, /pickled|muffin|cake/i);
});

test("sourdough toast stays a bread product rather than an English muffin", () => {
  const row = search("sourdough toast")[0];
  assert.match(row.name, /sourdough/i);
  assert.doesNotMatch(row.name, /cracker|crispbread|melba|muffin/i);
});

test("preserves separate natural and unspecified FNDDS portions", () => {
  const pork = search("pork tenderloin")[0];
  assert.equal(pork.source, "survey_fndds");
  assert.equal(pork.servingGrams, 30);
  assert.equal(pork.servingDescription, "1 slice, any size");
  assert.equal(pork.defaultServingGrams, 60);
  assert.equal(pork.defaultServingDescription, "1 estimated serving");
  assert.equal(pork.defaultServingSource, "survey_qns");

  const milk = search("milk")[0];
  assert.equal(milk.defaultServingGrams, milk.servingGrams);
  assert.equal(milk.defaultServingDescription, milk.servingDescription);
});

test("preserves pagination after merging relaxed queries", () => {
  const first = search("greek yogurt", 5);
  const second = store.search("greek yogurt", { limit: 5, offset: 5 });
  assert.equal(first.length, 5);
  assert.equal(second.length, 5);
  assert.equal(first.some((left) => second.some((right) => left.rowId === right.rowId)), false);
});

for (const query of [
  "blueberries",
  "black coffee",
  "whole egg",
  "spinach raw",
  "chicken nuggets",
  "waffle fries",
  "peanut butter sandwich",
  "grilled chicken breast",
  "brown rice",
  "sweet potato",
]) {
  test(`returns relevant candidates for ${query}`, () => {
    const queryTokens = query.toLowerCase().split(/\s+/);
    const rows = search(query);
    assert.ok(rows.length > 0);
    assert.ok(
      rows.slice(0, 5).some((row) => queryTokens.every((token) => combinedIdentity(row).includes(token))),
      `top candidates did not preserve all tokens for ${query}`
    );
  });
}
