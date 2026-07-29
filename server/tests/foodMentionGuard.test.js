const test = require("node:test");
const assert = require("node:assert/strict");
const { sanitizeFoodMentions } = require("../foodMentionGuard");

test("removes exact duplicate food mentions", () => {
  assert.deepEqual(
    sanitizeFoodMentions("I had vegetable soup", [
      "vegetable soup",
      "Vegetable Soup",
    ]),
    ["vegetable soup"]
  );
});

test("keeps the complete dish and removes an overlapping ingredient mention", () => {
  assert.deepEqual(
    sanitizeFoodMentions("I had tofu noodle soup", [
      "tofu noodle soup",
      "tofu",
    ]),
    ["tofu noodle soup"]
  );
});

test("preserves independently measurable foods", () => {
  assert.deepEqual(
    sanitizeFoodMentions("I had salmon, rice, and broccoli", [
      "salmon",
      "rice",
      "broccoli",
    ]),
    ["salmon", "rice", "broccoli"]
  );
});

test("separates an explicitly described topping without food-specific rules", () => {
  assert.deepEqual(
    sanitizeFoodMentions("I had a base food topped with a crunchy topping", [
      "a base food topped with a crunchy topping",
      "a crunchy topping",
    ]),
    ["a base food", "a crunchy topping"]
  );
});

test("separates a side even when the model returns one combined phrase", () => {
  assert.deepEqual(
    sanitizeFoodMentions("I had an entree with a side of vegetables", [
      "an entree with a side of vegetables",
    ]),
    ["an entree", "vegetables"]
  );
});

test("falls back to the user's message when the model returns no foods", () => {
  assert.deepEqual(
    sanitizeFoodMentions("plain yogurt", []),
    ["plain yogurt"]
  );
});
