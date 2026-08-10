"use strict";

const MAX_BATCH_SIZE = 12;

function boundedText(value, maximumLength) {
  const text = String(value || "").trim();
  return text ? text.slice(0, maximumLength) : "";
}

function sanitizeFoodResolutionBatch(value) {
  if (!Array.isArray(value) || value.length === 0 || value.length > MAX_BATCH_SIZE) {
    return null;
  }

  const items = value.map((raw, requestIndex) => {
    const foodMention = boundedText(raw?.foodMention, 220);
    if (!foodMention) return null;

    const searchQuery = boundedText(raw?.searchQuery, 220) || foodMention;
    const resolutionHint = ["single", "composite", "menu"].includes(raw?.resolutionHint)
      ? raw.resolutionHint
      : "";
    return {
      requestIndex,
      foodMention,
      searchQuery,
      resolutionHint,
    };
  });

  return items.every(Boolean) ? items : null;
}

async function resolveFoodResolutionBatch(items, resolveOne, { concurrency = 3 } = {}) {
  if (!Array.isArray(items) || typeof resolveOne !== "function") {
    throw new TypeError("invalid_food_resolution_batch");
  }

  const results = new Array(items.length);
  let nextIndex = 0;
  const workerCount = Math.min(
    items.length,
    Math.max(1, Math.min(4, Number.isInteger(concurrency) ? concurrency : 3))
  );

  async function worker() {
    while (nextIndex < items.length) {
      const index = nextIndex;
      nextIndex += 1;
      const item = items[index];

      try {
        const outcome = await resolveOne(item);
        results[index] = {
          requestIndex: item.requestIndex,
          candidate: outcome?.status === 200 ? outcome.body : null,
          error: outcome?.status === 200
            ? null
            : boundedText(outcome?.body?.error, 120) || "food_candidate_not_found",
        };
      } catch (_error) {
        results[index] = {
          requestIndex: item.requestIndex,
          candidate: null,
          error: "food_resolution_failed",
        };
      }
    }
  }

  await Promise.all(Array.from({ length: workerCount }, worker));
  return results;
}

module.exports = {
  MAX_BATCH_SIZE,
  resolveFoodResolutionBatch,
  sanitizeFoodResolutionBatch,
};
