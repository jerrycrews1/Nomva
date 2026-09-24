const assert = require("node:assert/strict");
const test = require("node:test");
const { highRiskReply } = require("../nutritionSafety");

test("high risk nutrition requests get a deterministic safety response", () => {
  for (const message of [
    "I have bulimia and want to purge after dinner",
    "I'm pregnant; how many calories should I eat to lose weight?",
    "I have a peanut allergy. Is this safe to eat?",
    "Should I change my insulin dose after this meal?",
  ]) {
    assert.match(highRiskReply(message), /clinician|medical|health professional/i);
  }
});

test("ordinary food logging and calorie questions still reach the normal flow", () => {
  for (const message of [
    "Log 500 calories of pasta for dinner",
    "How much protein did I eat this week?",
    "I ate peanuts yesterday",
    "How much water have I logged?",
  ]) {
    assert.equal(highRiskReply(message), null);
  }
});
