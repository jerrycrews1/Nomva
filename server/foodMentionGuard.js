function normalize(value) {
  return String(value || "")
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function tokens(value) {
  return new Set(
    normalize(value)
      .split(/\s+/)
      .filter((token) => token.length > 1)
  );
}

function isStrictSubset(left, right) {
  return left.size > 0
    && left.size < right.size
    && [...left].every((token) => right.has(token));
}

function splitExplicitlySeparateParts(value) {
  return String(value || "")
    .split(/\s+(?:topped\s+with|with\s+a\s+side\s+of)\s+/i)
    .map((part) => part.trim())
    .filter(Boolean);
}

function sanitizeFoodMentions(userMessage, rawFoods) {
  const source = Array.isArray(rawFoods)
    ? rawFoods.flatMap(splitExplicitlySeparateParts)
    : [];
  const unique = [];
  const seen = new Set();

  for (const value of source.slice(0, 16)) {
    const food = String(value || "").trim().slice(0, 240);
    const key = normalize(food);
    if (!key || seen.has(key)) {
      continue;
    }
    seen.add(key);
    unique.push(food);
  }

  const withoutOverlaps = unique.filter((food, index) => {
    const ownTokens = tokens(food);
    return !unique.some((other, otherIndex) => (
      otherIndex !== index && isStrictSubset(ownTokens, tokens(other))
    ));
  });

  if (withoutOverlaps.length > 0) {
    return withoutOverlaps;
  }

  const fallback = String(userMessage || "").trim();
  return fallback ? [fallback] : [];
}

module.exports = {
  sanitizeFoodMentions,
  splitExplicitlySeparateParts,
};
