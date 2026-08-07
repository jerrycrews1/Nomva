const assert = require("node:assert/strict");
const test = require("node:test");

const {
  sanitizeRecentFoodCandidates,
  sanitizeSuggestedFoodIds,
} = require("../recentFoodSuggestionGuard");

test("recent food candidates keep only bounded real history rows", () => {
  const candidates = sanitizeRecentFoodCandidates([
    {
      id: "entry_1",
      name: "Greek yogurt",
      brand: "Example",
      recentCount: 7,
      isFavorite: true,
      lastLoggedAt: "2026-08-05T15:00:00Z",
      mealCounts: { breakfast: 6, lunch: 1, invented: 99 },
    },
    { id: "entry 2 with spaces", name: "Invalid ID" },
    { id: "entry_1", name: "Duplicate" },
    { id: "entry_3", name: "" },
  ]);

  assert.equal(candidates.length, 1);
  assert.equal(candidates[0].name, "Greek yogurt");
  assert.deepEqual(candidates[0].mealCounts, { breakfast: 6, lunch: 1 });
});

test("AI ranking cannot invent or duplicate food IDs", () => {
  const candidates = sanitizeRecentFoodCandidates([
    { id: "entry_1", name: "Coffee" },
    { id: "entry_2", name: "Eggs" },
  ]);
  const ids = sanitizeSuggestedFoodIds(
    { candidateIds: ["invented", "entry_2", "entry_2", "entry_1"] },
    candidates
  );

  assert.deepEqual(ids, ["entry_2", "entry_1"]);
});
