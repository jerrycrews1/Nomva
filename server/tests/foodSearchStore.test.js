const assert = require("node:assert/strict");
const path = require("node:path");
const test = require("node:test");

const { createFoodSearchStore } = require("../foodSearchStore");

const dbPath = path.join(__dirname, "..", "..", "Nomva", "Resources", "foods.sqlite");
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

test("ranks a literal food above products that merely contain its token", () => {
  const rows = search("corn");
  assert.ok(/^corn(?:,|$)/i.test(rows[0].name), rows[0].name);
  assert.doesNotMatch(rows[0].name, /babyfood|flour|snack/i);
});

test("ignores generic side-dish language", () => {
  const rows = search("side of corn");
  assert.ok(/^corn(?:,|$)/i.test(rows[0].name), rows[0].name);
});

test("treats a plain-food size adjective as portion context", () => {
  const rows = search("medium banana");
  assert.ok(rows.slice(0, 5).some((row) => /^bananas?(?:,|$)/i.test(row.name)), rows.map((row) => row.name).join(" | "));
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
