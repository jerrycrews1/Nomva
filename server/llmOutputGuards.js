"use strict";

const { normalizeText, parseLogEntries } = require("./deleteTargetGuard");

function currentLogNameMap(logSummary) {
  const map = new Map();
  for (const entry of parseLogEntries(logSummary).slice(0, 250)) {
    const key = normalizeText(entry.name);
    if (key && !map.has(key)) map.set(key, entry.name);
  }
  return map;
}

function validatedDeleteTargets(requestedNames, logSummary) {
  if (!Array.isArray(requestedNames)) return [];
  const available = currentLogNameMap(logSummary);
  const seen = new Set();
  const targets = [];

  for (const value of requestedNames.slice(0, 250)) {
    const key = normalizeText(value);
    const exactName = available.get(key);
    if (!exactName || seen.has(key)) continue;
    seen.add(key);
    targets.push(exactName);
  }
  return targets;
}

function validatedEditSelection(rawSelection, logSummary) {
  const available = currentLogNameMap(logSummary);
  const requestedKey = normalizeText(rawSelection?.foodName);
  const exactName = requestedKey ? available.get(requestedKey) : null;
  const question = typeof rawSelection?.clarificationQuestion === "string"
    ? rawSelection.clarificationQuestion.trim().slice(0, 240)
    : "";

  if (exactName) {
    return { foodName: exactName, clarificationQuestion: null };
  }
  return {
    foodName: null,
    clarificationQuestion: question || "Which logged food should I change?",
  };
}

module.exports = {
  currentLogNameMap,
  validatedDeleteTargets,
  validatedEditSelection,
};
