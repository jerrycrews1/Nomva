const test = require("node:test");
const assert = require("node:assert/strict");

const { deterministicDeleteTargets } = require("../deleteTargetGuard");

test("delete that removes every still-present item from the latest grouped confirmation", () => {
  const result = deterministicDeleteTargets({
    userMessage: "Delete that",
    logSummary: [
      "Salmon (dinner)",
      "Rice (dinner)",
      "Greek Yogurt (breakfast)",
    ].join("\n"),
    recentMessages: [
      { role: "user", content: "Had salmon and rice" },
      { role: "assistant", content: "✓ Salmon (1 serving) — 250 cal\n✓ Rice (1 serving) — 170 cal" },
    ],
  });

  assert.deepEqual(result, ["Salmon", "Rice"]);
});

test("delete that ignores a grouped item that is no longer in the current log", () => {
  const result = deterministicDeleteTargets({
    userMessage: "Delete that",
    logSummary: "Salmon (dinner)",
    recentMessages: [
      { role: "assistant", content: "✓ Salmon (1 serving) — 250 cal\n✓ Rice (1 serving) — 170 cal" },
    ],
  });

  assert.deepEqual(result, ["Salmon"]);
});
