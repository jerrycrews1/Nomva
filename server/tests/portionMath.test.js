const assert = require("node:assert/strict");
const test = require("node:test");

const {
  databaseServingRatio,
  numericAmount,
  parsedPortion,
} = require("../portionMath");

test("parses decimals, fractions, mixed fractions, unicode fractions, and number words", () => {
  assert.equal(numericAmount("1.5"), 1.5);
  assert.equal(numericAmount("3/4"), 0.75);
  assert.equal(numericAmount("1 1/2"), 1.5);
  assert.equal(parsedPortion("1\u00bd cups").amount, 1.5);
  assert.equal(parsedPortion("one and a half cups").amount, 1.5);
  assert.equal(parsedPortion("half a cup").amount, 0.5);
  assert.equal(parsedPortion("half cup").amount, 0.5);
});

test("matches fluid ounces before mass ounces", () => {
  const portion = parsedPortion("about 8 fl oz milk");
  assert.equal(portion.dimension, "volume");
  assert.equal(portion.unit, "fl_oz");
  assert.equal(portion.amount, 8);
});

test("converts compatible volume units into database servings", () => {
  assert.equal(databaseServingRatio("1 fl oz", "8 fl oz milk"), 8);
  assert.equal(databaseServingRatio("1 cup", "1/2 cup"), 0.5);
  assert.equal(databaseServingRatio("1 cup", "8 fl oz"), 1);
});

test("converts compatible mass units into database servings", () => {
  assert.equal(databaseServingRatio("100 g", "6 oz"), 1.700971);
  assert.equal(databaseServingRatio("1 oz", "56.69904625 g"), 2);
});

test("converts matching countable units", () => {
  assert.equal(databaseServingRatio("4 nuggets", "3 nuggets"), 0.75);
  assert.equal(databaseServingRatio("1 sandwich", "two sandwiches"), 2);
});

test("does not invent conversions across dimensions or different count units", () => {
  assert.equal(databaseServingRatio("100 g", "1 cup"), null);
  assert.equal(databaseServingRatio("1 serving", "8 fl oz"), null);
  assert.equal(databaseServingRatio("1 piece", "2 slices"), null);
  assert.equal(databaseServingRatio("not specified", "1 cup"), null);
});

test("rejects unsafe ratios", () => {
  assert.equal(databaseServingRatio("100 g", "1 g"), null);
  assert.equal(databaseServingRatio("1 g", "101 g"), null);
});
