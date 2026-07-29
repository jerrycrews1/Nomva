const test = require("node:test");
const assert = require("node:assert/strict");
const { hasExplicitPortion } = require("../portionGuard");

test("recognizes weight, volume, count, and natural portions", () => {
  for (const phrase of [
    "150 grams plain yogurt",
    "8 fluid ounces almond milk",
    "three quarters cup rice",
    "2 slices of toast",
    "a small handful of almonds",
  ]) {
    assert.equal(hasExplicitPortion(phrase), true, phrase);
  }
});

test("does not call vague or corrective language an explicit portion", () => {
  for (const phrase of [
    "some yogurt",
    "that is too much",
    "it was not right",
    "plain rice",
  ]) {
    assert.equal(hasExplicitPortion(phrase), false, phrase);
  }
});
