"use strict";

// Converts a human portion description into a comparable physical amount.
// This is deliberately deterministic: model output describes the portion,
// while database-serving arithmetic remains an application invariant.

const FRACTIONS = new Map([
  ["\u00bc", " 1/4"], ["\u00bd", " 1/2"], ["\u00be", " 3/4"],
  ["\u2150", " 1/7"], ["\u2151", " 1/9"], ["\u2152", " 1/10"],
  ["\u2153", " 1/3"], ["\u2154", " 2/3"], ["\u2155", " 1/5"],
  ["\u2156", " 2/5"], ["\u2157", " 3/5"], ["\u2158", " 4/5"],
  ["\u2159", " 1/6"], ["\u215a", " 5/6"], ["\u215b", " 1/8"],
  ["\u215c", " 3/8"], ["\u215d", " 5/8"], ["\u215e", " 7/8"],
]);

const NUMBER_WORDS = {
  a: 1,
  an: 1,
  one: 1,
  two: 2,
  three: 3,
  four: 4,
  five: 5,
  six: 6,
  seven: 7,
  eight: 8,
  nine: 9,
  ten: 10,
  eleven: 11,
  twelve: 12,
  thirteen: 13,
  fourteen: 14,
  fifteen: 15,
  sixteen: 16,
  seventeen: 17,
  eighteen: 18,
  nineteen: 19,
  twenty: 20,
};

const UNIT_DEFINITIONS = [
  { pattern: "fluid\\s+ounces?|fl\\.?\\s*oz\\.?", unit: "fl_oz", dimension: "volume", factor: 29.5735295625 },
  { pattern: "millilit(?:er|re)s?|ml", unit: "ml", dimension: "volume", factor: 1 },
  { pattern: "lit(?:er|re)s?|l", unit: "l", dimension: "volume", factor: 1000 },
  { pattern: "tablespoons?|tbsp\\.?|tbs\\.?", unit: "tbsp", dimension: "volume", factor: 14.78676478125 },
  { pattern: "teaspoons?|tsp\\.?", unit: "tsp", dimension: "volume", factor: 4.92892159375 },
  { pattern: "cups?", unit: "cup", dimension: "volume", factor: 236.5882365 },
  { pattern: "kilograms?|kgs?", unit: "kg", dimension: "mass", factor: 1000 },
  { pattern: "grams?|g", unit: "g", dimension: "mass", factor: 1 },
  { pattern: "pounds?|lbs?", unit: "lb", dimension: "mass", factor: 453.59237 },
  { pattern: "ounces?|oz\\.?", unit: "oz", dimension: "mass", factor: 28.349523125 },
  { pattern: "servings?|portions?", unit: "serving", dimension: "count", factor: 1 },
  { pattern: "pieces?", unit: "piece", dimension: "count", factor: 1 },
  { pattern: "slices?", unit: "slice", dimension: "count", factor: 1 },
  { pattern: "nuggets?", unit: "nugget", dimension: "count", factor: 1 },
  { pattern: "eggs?", unit: "egg", dimension: "count", factor: 1 },
  { pattern: "tacos?", unit: "taco", dimension: "count", factor: 1 },
  { pattern: "sandwich(?:es)?", unit: "sandwich", dimension: "count", factor: 1 },
  { pattern: "fill?ets?|filets?", unit: "fillet", dimension: "count", factor: 1 },
  { pattern: "patt(?:y|ies)", unit: "patty", dimension: "count", factor: 1 },
  { pattern: "bowls?", unit: "bowl", dimension: "count", factor: 1 },
  { pattern: "bottles?", unit: "bottle", dimension: "count", factor: 1 },
  { pattern: "cans?", unit: "can", dimension: "count", factor: 1 },
  { pattern: "packets?", unit: "packet", dimension: "count", factor: 1 },
  { pattern: "packages?|pkgs?", unit: "package", dimension: "count", factor: 1 },
  { pattern: "bars?", unit: "bar", dimension: "count", factor: 1 },
  { pattern: "muffins?", unit: "muffin", dimension: "count", factor: 1 },
  { pattern: "cookies?", unit: "cookie", dimension: "count", factor: 1 },
  { pattern: "meatballs?", unit: "meatball", dimension: "count", factor: 1 },
  { pattern: "ears?", unit: "ear", dimension: "count", factor: 1 },
  { pattern: "fruits?", unit: "fruit", dimension: "count", factor: 1 },
  { pattern: "pitas?", unit: "pita", dimension: "count", factor: 1 },
  { pattern: "tortillas?", unit: "tortilla", dimension: "count", factor: 1 },
  { pattern: "quesadillas?", unit: "quesadilla", dimension: "count", factor: 1 },
];

const NUMBER_PATTERN = [
  "\\d+(?:\\.\\d+)?\\s+\\d+\\s*\\/\\s*\\d+",
  "\\d+\\s*\\/\\s*\\d+",
  "\\d+(?:\\.\\d+)?",
  "(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty)\\s+and\\s+(?:a\\s+)?half",
  "(?:a\\s+)?half",
  "(?:a\\s+)?quarter",
  "a|an|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty",
].join("|");

function normalizedDescription(value) {
  let text = String(value || "").toLowerCase();
  for (const [character, replacement] of FRACTIONS) {
    text = text.replaceAll(character, replacement);
  }
  return text.normalize("NFKC").replace(/[\u2044]/g, "/").replace(/\s+/g, " ").trim();
}

function numericAmount(value) {
  const text = String(value || "").trim().toLowerCase().replace(/\s+/g, " ");
  const mixed = text.match(/^(\d+(?:\.\d+)?)\s+(\d+)\s*\/\s*(\d+)$/);
  if (mixed) {
    const denominator = Number(mixed[3]);
    return denominator > 0 ? Number(mixed[1]) + Number(mixed[2]) / denominator : null;
  }
  const fraction = text.match(/^(\d+)\s*\/\s*(\d+)$/);
  if (fraction) {
    const denominator = Number(fraction[2]);
    return denominator > 0 ? Number(fraction[1]) / denominator : null;
  }
  if (/^\d+(?:\.\d+)?$/.test(text)) return Number(text);

  const wordAndHalf = text.match(/^(\w+)\s+and\s+(?:a\s+)?half$/);
  if (wordAndHalf && NUMBER_WORDS[wordAndHalf[1]] !== undefined) {
    return NUMBER_WORDS[wordAndHalf[1]] + 0.5;
  }
  if (/^(?:a\s+)?half$/.test(text)) return 0.5;
  if (/^(?:a\s+)?quarter$/.test(text)) return 0.25;
  return NUMBER_WORDS[text] ?? null;
}

function parsedPortion(description) {
  const text = normalizedDescription(description);
  if (!text) return null;

  let best = null;
  for (const definition of UNIT_DEFINITIONS) {
    const expression = new RegExp(
      `(?:^|\\b)(${NUMBER_PATTERN})\\s*(?:-|of\\s+)?(?:a\\s+|an\\s+)?(?:${definition.pattern})(?=$|\\b)`,
      "i"
    );
    const match = expression.exec(text);
    if (!match) continue;
    const amount = numericAmount(match[1]);
    if (!Number.isFinite(amount) || amount <= 0) continue;
    if (!best || match.index < best.index || (match.index === best.index && match[0].length > best.length)) {
      best = {
        amount,
        unit: definition.unit,
        dimension: definition.dimension,
        baseAmount: amount * definition.factor,
        index: match.index,
        length: match[0].length,
      };
    }
  }

  if (!best) return null;
  const { index, length, ...portion } = best;
  return portion;
}

function databaseServingRatio(databaseServingDescription, consumedPortionDescription) {
  const database = parsedPortion(databaseServingDescription);
  const consumed = parsedPortion(consumedPortionDescription);
  if (!database || !consumed || database.dimension !== consumed.dimension) return null;
  if (database.dimension === "count" && database.unit !== consumed.unit) return null;

  const ratio = consumed.baseAmount / database.baseAmount;
  if (!Number.isFinite(ratio) || ratio < 0.05 || ratio > 100) return null;
  return Math.round(ratio * 1_000_000) / 1_000_000;
}

module.exports = {
  databaseServingRatio,
  numericAmount,
  parsedPortion,
};
