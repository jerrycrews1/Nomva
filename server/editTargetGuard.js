const { normalizeText, parseLogEntries } = require("./deleteTargetGuard");

const STOP_WORDS = new Set([
  "a", "an", "the", "my", "that", "this", "it", "was", "is", "were", "to",
  "for", "from", "with", "without", "actually", "make", "change", "edit",
  "fix", "correct", "update", "serving", "servings", "cup", "cups", "oz",
  "ounce", "ounces", "gram", "grams", "g", "cal", "calories", "only",
]);

const COFFEE_FAMILY_TOKENS = new Set([
  "coffee", "mocha", "latte", "espresso", "cappuccino", "americano", "brew",
]);

function tokens(value) {
  return normalizeText(value)
    .split(/\s+/)
    .filter((token) => token && !STOP_WORDS.has(token) && Number.isNaN(Number(token)));
}

function entryTokens(entry) {
  return new Set(tokens(entry.name));
}

function recentAssistantTarget(userMessage, entries, recentMessages = []) {
  const normalizedMessage = normalizeText(userMessage);
  if (!/^(?:no\s+)?(?:delete|remove|undo)\s+(?:that|it)$/.test(normalizedMessage)) {
    return null;
  }

  const assistantMessages = recentMessages
    .filter((message) => message?.role === "assistant" && typeof message.content === "string")
    .slice()
    .reverse();

  for (const message of assistantMessages) {
    const normalizedContent = normalizeText(message.content);
    let bestMatch = null;
    let bestPosition = -1;
    for (const entry of entries) {
      const normalizedName = normalizeText(entry.name);
      const position = normalizedContent.lastIndexOf(normalizedName);
      if (position > bestPosition) {
        bestMatch = entry;
        bestPosition = position;
      }
    }

    if (bestMatch && bestPosition >= 0) {
      return {
        foodName: bestMatch.name,
        clarificationQuestion: null,
      };
    }
  }

  return null;
}

function coffeeFamilyMatches(entries) {
  return entries.filter((entry) => {
    const entryTokenSet = entryTokens(entry);
    return [...COFFEE_FAMILY_TOKENS].some((token) => entryTokenSet.has(token));
  });
}

function deterministicEditTarget({ userMessage, logSummary, recentMessages = [] }) {
  const entries = parseLogEntries(logSummary);
  if (!entries.length) {
    return null;
  }

  const recentTarget = recentAssistantTarget(userMessage, entries, recentMessages);
  if (recentTarget) {
    return recentTarget;
  }

  const messageTokens = new Set(tokens(userMessage));
  if (!messageTokens.size) {
    return null;
  }

  if (messageTokens.has("coffee")) {
    const coffeeMatches = coffeeFamilyMatches(entries);
    if (coffeeMatches.length > 1) {
      return {
        foodName: null,
        clarificationQuestion: "Which coffee entry should I change?",
      };
    }
    if (coffeeMatches.length === 1) {
      return {
        foodName: coffeeMatches[0].name,
        clarificationQuestion: null,
      };
    }
  }

  const matches = entries.filter((entry) => {
    const tokenSet = entryTokens(entry);
    return [...messageTokens].some((token) => tokenSet.has(token));
  });

  if (matches.length === 1) {
    return {
      foodName: matches[0].name,
      clarificationQuestion: null,
    };
  }

  if (matches.length > 1) {
    return {
      foodName: null,
      clarificationQuestion: "Which item should I change?",
    };
  }

  return null;
}

module.exports = {
  deterministicEditTarget,
};
