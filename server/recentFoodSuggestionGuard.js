"use strict";

const MEALS = new Set(["breakfast", "lunch", "dinner", "snack"]);

function boundedInteger(value, fallback = 0) {
  if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
  return Math.min(Math.max(Math.round(value), 0), 10_000);
}

function cleanText(value, maxLength) {
  return typeof value === "string" ? value.trim().slice(0, maxLength) : "";
}

function sanitizeRecentFoodCandidates(rawCandidates) {
  if (!Array.isArray(rawCandidates)) return [];

  const seen = new Set();
  const candidates = [];
  for (const raw of rawCandidates.slice(0, 50)) {
    if (!raw || typeof raw !== "object") continue;
    const id = cleanText(raw.id, 80);
    const name = cleanText(raw.name, 120);
    if (!id || !name || !/^[A-Za-z0-9_-]+$/.test(id) || seen.has(id)) continue;

    const mealCounts = {};
    if (raw.mealCounts && typeof raw.mealCounts === "object") {
      for (const meal of MEALS) {
        const count = boundedInteger(raw.mealCounts[meal]);
        if (count > 0) mealCounts[meal] = count;
      }
    }

    seen.add(id);
    candidates.push({
      id,
      name,
      brand: cleanText(raw.brand, 120),
      recentCount: boundedInteger(raw.recentCount, 1),
      sameWeekdayCount: boundedInteger(raw.sameWeekdayCount),
      isFavorite: raw.isFavorite === true,
      lastLoggedAt: cleanText(raw.lastLoggedAt, 40),
      mealCounts,
    });
    if (candidates.length >= 30) break;
  }
  return candidates;
}

function sanitizeSuggestedFoodIds(result, candidates, limit = 8) {
  const allowed = new Set(candidates.map((candidate) => candidate.id));
  const rawIds = Array.isArray(result?.candidateIds) ? result.candidateIds : [];
  const seen = new Set();

  return rawIds
    .filter((id) => typeof id === "string" && allowed.has(id) && !seen.has(id) && seen.add(id))
    .slice(0, Math.max(1, Math.min(limit, 12)));
}

module.exports = {
  sanitizeRecentFoodCandidates,
  sanitizeSuggestedFoodIds,
};
