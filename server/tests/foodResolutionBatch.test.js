"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  MAX_BATCH_SIZE,
  resolveFoodResolutionBatch,
  sanitizeFoodResolutionBatch,
} = require("../foodResolutionBatch");

test("sanitizes a bounded multi-food request without merging request slots", () => {
  const items = sanitizeFoodResolutionBatch([
    { foodMention: "Greek yogurt", searchQuery: "plain Greek yogurt", resolutionHint: "single" },
    { foodMention: "Blueberries", resolutionHint: "single" },
    { foodMention: "Black coffee", resolutionHint: "single" },
  ]);

  assert.deepEqual(items, [
    {
      requestIndex: 0,
      foodMention: "Greek yogurt",
      searchQuery: "plain Greek yogurt",
      resolutionHint: "single",
    },
    {
      requestIndex: 1,
      foodMention: "Blueberries",
      searchQuery: "Blueberries",
      resolutionHint: "single",
    },
    {
      requestIndex: 2,
      foodMention: "Black coffee",
      searchQuery: "Black coffee",
      resolutionHint: "single",
    },
  ]);
});

test("rejects malformed, empty, or oversized batches", () => {
  assert.equal(sanitizeFoodResolutionBatch([]), null);
  assert.equal(sanitizeFoodResolutionBatch([{ foodMention: "" }]), null);
  assert.equal(
    sanitizeFoodResolutionBatch(Array.from({ length: MAX_BATCH_SIZE + 1 }, () => ({ foodMention: "apple" }))),
    null
  );
});

test("preserves order and cardinality when completion order differs", async () => {
  const items = sanitizeFoodResolutionBatch([
    { foodMention: "slow" },
    { foodMention: "fast" },
    { foodMention: "middle" },
  ]);
  const delays = { slow: 20, fast: 1, middle: 8 };

  const results = await resolveFoodResolutionBatch(items, async (item) => {
    await new Promise((resolve) => setTimeout(resolve, delays[item.foodMention]));
    return {
      status: 200,
      body: { candidateId: `candidate_${item.foodMention}`, name: item.foodMention },
    };
  });

  assert.deepEqual(results.map((result) => result.requestIndex), [0, 1, 2]);
  assert.deepEqual(results.map((result) => result.candidate.name), ["slow", "fast", "middle"]);
});

test("keeps independent slots when two mentions resolve to the same catalog identity", async () => {
  const items = sanitizeFoodResolutionBatch([
    { foodMention: "one apple" },
    { foodMention: "another apple" },
  ]);

  const results = await resolveFoodResolutionBatch(items, async () => ({
    status: 200,
    body: { candidateId: "db_42", name: "Apple" },
  }));

  assert.equal(results.length, 2);
  assert.deepEqual(results.map((result) => result.requestIndex), [0, 1]);
  assert.ok(results.every((result) => result.candidate.candidateId === "db_42"));
});

test("isolates one failed resolution without dropping successful neighbors", async () => {
  const items = sanitizeFoodResolutionBatch([
    { foodMention: "yogurt" },
    { foodMention: "unknown" },
    { foodMention: "coffee" },
  ]);

  const results = await resolveFoodResolutionBatch(items, async (item) => (
    item.foodMention === "unknown"
      ? { status: 422, body: { error: "food_candidate_not_found" } }
      : { status: 200, body: { candidateId: `id_${item.foodMention}`, name: item.foodMention } }
  ));

  assert.equal(results.length, 3);
  assert.equal(results[0].candidate.name, "yogurt");
  assert.equal(results[1].candidate, null);
  assert.equal(results[1].error, "food_candidate_not_found");
  assert.equal(results[2].candidate.name, "coffee");
});
