const test = require("node:test");
const assert = require("node:assert/strict");
const { computeGarminAverages } = require("../garminMetrics");

test("averages available completed days inside the requested calendar window", () => {
  const result = computeGarminAverages([
    { date: "2026-08-03", activeCalories: 21 },
    { date: "2026-08-02", activeCalories: 460 },
    { date: "2026-08-01", activeCalories: 340 },
    { date: "2026-07-20", activeCalories: 400 },
  ], {
    currentLocalDate: "2026-08-03",
    windowDays: 28,
  });

  assert.equal(result.averageActiveCalories, 400);
  assert.equal(result.sampledDays, 3);
  assert.equal(result.windowDays, 28);
  assert.equal(result.averageThroughDate, "2026-08-02");
});

test("excludes the current partial day", () => {
  const result = computeGarminAverages([
    { date: "2026-08-03", activeCalories: 20 },
    { date: "2026-08-02", activeCalories: 500 },
  ], { currentLocalDate: "2026-08-03" });

  assert.equal(result.averageActiveCalories, 500);
  assert.equal(result.sampledDays, 1);
});

test("does not fill a sparse 28-day window with stale records", () => {
  const result = computeGarminAverages([
    { date: "2026-08-02", activeCalories: 500 },
    { date: "2026-07-31", activeCalories: 300 },
    { date: "2026-06-11", activeCalories: 1_200 },
  ], {
    currentLocalDate: "2026-08-03",
    windowDays: 28,
  });

  assert.equal(result.averageActiveCalories, 400);
  assert.equal(result.sampledDays, 2);
});

test("keeps a valid zero-activity completed day in coverage", () => {
  const result = computeGarminAverages([
    { date: "2026-08-02", activeCalories: 0 },
    { date: "2026-08-01", activeCalories: 400 },
  ], { currentLocalDate: "2026-08-03" });

  assert.equal(result.averageActiveCalories, 200);
  assert.equal(result.sampledDays, 2);
});

test("returns explicit empty coverage when no completed days are available", () => {
  const result = computeGarminAverages([
    { date: "2026-08-03", activeCalories: 25 },
  ], { currentLocalDate: "2026-08-03" });

  assert.deepEqual(result, {
    averageActiveCalories: null,
    sampledDays: 0,
    windowDays: 28,
    averageThroughDate: null,
  });
});

test("ignores a malformed local calendar date without throwing", () => {
  assert.doesNotThrow(() => {
    computeGarminAverages([], {
      currentLocalDate: "2026-99-99",
      windowDays: 28,
    });
  });
});
