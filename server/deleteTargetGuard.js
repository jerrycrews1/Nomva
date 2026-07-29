const MEALS = ["breakfast", "lunch", "dinner", "snack"];

function normalizeText(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[’]/g, "'")
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function parseLogEntries(logSummary) {
  return String(logSummary || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line, index) => {
      const match = line.match(/^(.*?)\s*\(([^()]*)\)\s*$/);
      if (!match) {
        return { index, line, name: line, meal: null };
      }

      const name = match[1].trim();
      const parenthetical = match[2].trim();
      const parts = parenthetical.split(",").map((part) => part.trim().toLowerCase()).filter(Boolean);
      let meal = null;
      for (let partIndex = parts.length - 1; partIndex >= 0; partIndex -= 1) {
        if (MEALS.includes(parts[partIndex])) {
          meal = parts[partIndex];
          break;
        }
      }
      return { index, line, name, meal };
    });
}

function scopedMealDeleteTarget(userMessage) {
  const message = String(userMessage || "").trim();
  for (const meal of MEALS) {
    const escapedMeal = escapeRegExp(meal);
    const patterns = [
      new RegExp(`^\\s*(?:delete|remove|clear|empty|wipe)\\s+(?:my\\s+|the\\s+)?${escapedMeal}\\s*(?:foods?|meal|entries?|log)?\\s*$`, "i"),
      new RegExp(`^\\s*(?:delete|remove|clear|empty|wipe)\\s+(?:all\\s+)?(?:foods?|meals?|entries?)\\s+(?:from|for|in)\\s+(?:my\\s+|the\\s+)?${escapedMeal}\\s*$`, "i"),
      new RegExp(`^\\s*(?:delete|remove|clear|empty|wipe)\\s+(?:my\\s+|the\\s+)?${escapedMeal}\\s+(?:foods?|meal|entries?|log)\\s*$`, "i"),
    ];
    if (patterns.some((pattern) => pattern.test(message))) {
      return meal;
    }
  }
  return null;
}

function isWholeDayFoodDelete(userMessage) {
  const message = String(userMessage || "").trim();
  const patterns = [
    /^\s*(?:delete|remove|clear|empty|wipe)\s+(?:all\s+)?(?:my\s+|the\s+)?(?:foods?|meals?|entries?|food\s+log|log)\s*(?:from|for)?\s*(?:today|the\s+day)?\s*$/i,
    /^\s*(?:delete|remove|clear|empty|wipe)\s+(?:everything|all)\s*(?:from|for)?\s*(?:today|the\s+day)?\s*$/i,
    /^\s*(?:delete|remove|clear)\s+the\s+rest\s*$/i,
  ];
  return patterns.some((pattern) => pattern.test(message));
}

function explicitFoodNameTargets(userMessage, entries) {
  const normalizedMessage = normalizeText(userMessage)
    .replace(/\b(?:delete|remove|clear|empty|wipe)\b/g, " ")
    .replace(/\b(?:from|for)\s+(?:today|the day)\b/g, " ")
    .replace(/\b(?:please|my|the|that|this|entry|food|foods?)\b/g, " ")
    .replace(/\s+/g, " ")
    .trim();

  if (!normalizedMessage || /\b(?:but|except|keep|not|instead|it)\b/.test(normalizedMessage)) {
    return null;
  }

  const matches = entries.filter((entry) => {
    const normalizedName = normalizeText(entry.name);
    return normalizedName && normalizedMessage.includes(normalizedName);
  });

  if (matches.length === 1) {
    return matches.map((entry) => entry.name);
  }
  return null;
}

function groupedAssistantTargets(userMessage, entries, recentMessages = []) {
  const normalizedMessage = normalizeText(userMessage);
  const groupedReference = /^(?:no\s+)?(?:delete|remove)\s+(?:that|it|them|those|all(?:\s+of\s+them)?)$/.test(normalizedMessage)
    || /^(?:both|all(?:\s+of\s+them)?|them|those)(?:\s+too)?$/.test(normalizedMessage);
  if (!groupedReference) {
    return null;
  }

  const assistantMessages = recentMessages
    .filter((message) => message?.role === "assistant" && typeof message.content === "string")
    .slice()
    .reverse();

  for (const message of assistantMessages) {
    const normalizedContent = normalizeText(message.content);
    const matches = entries.filter((entry) => {
      const normalizedName = normalizeText(entry.name);
      return normalizedName && normalizedContent.includes(normalizedName);
    });
    if (matches.length) {
      return matches.map((entry) => entry.name);
    }
  }

  return null;
}

function deterministicDeleteTargets({ userMessage, logSummary, recentMessages = [] }) {
  const entries = parseLogEntries(logSummary);
  if (!entries.length) {
    return null;
  }

  if (isWholeDayFoodDelete(userMessage)) {
    return entries.map((entry) => entry.name);
  }

  const meal = scopedMealDeleteTarget(userMessage);
  if (meal) {
    return entries
      .filter((entry) => entry.meal === meal)
      .map((entry) => entry.name);
  }

  const groupedTargets = groupedAssistantTargets(userMessage, entries, recentMessages);
  if (groupedTargets) {
    return groupedTargets;
  }

  return explicitFoodNameTargets(userMessage, entries);
}

module.exports = {
  deterministicDeleteTargets,
  parseLogEntries,
  normalizeText,
  groupedAssistantTargets,
  scopedMealDeleteTarget,
  isWholeDayFoodDelete,
};
