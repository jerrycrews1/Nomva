const assert = require("node:assert/strict");
const test = require("node:test");

const { canonicalFoodToken } = require("../foodTokenNormalizer");

test("normalizes plural food tokens and preparation morphology", () => {
  assert.equal(canonicalFoodToken("berries"), "berry");
  assert.equal(canonicalFoodToken("toasted"), "toast");
  assert.equal(canonicalFoodToken("grilling"), "grill");
  assert.equal(canonicalFoodToken("fried"), "fry");
});
