const test = require("node:test");
const assert = require("node:assert/strict");
const { deterministicEditTarget } = require("../editTargetGuard");

test("the reported bottle correction selects Gatorade among several drinks", () => {
  const name = "Gatorade Cool Blue — 12 fl oz (28 oz bottle)";
  assert.deepEqual(deterministicEditTarget({
    userMessage: "I had the whole bottle of Gatorade not just 12 oz",
    logSummary: `${name} (12 fl oz, dinner)\nCELSIUS Grape Rush, 12 fl oz can (1 can, dinner)\nCoca-Cola Zero, 16 fl oz bottle (1 bottle, dinner)`,
  }), { foodName: name, clarificationQuestion: null });
});

test("two Gatorade entries require clarification instead of picking the latest", () => {
  const result = deterministicEditTarget({
    userMessage: "I had the whole bottle of Gatorade not just 12 oz",
    logSummary: "Gatorade Cool Blue (12 fl oz, dinner)\nGatorade Fruit Punch (12 fl oz, dinner)",
  });
  assert.equal(result.foodName, null);
  assert.ok(result.clarificationQuestion);
});
