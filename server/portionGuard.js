const NUMBER_WORD = String.raw`(?:one|two|three|four|five|six|seven|eight|nine|ten|half|quarter|third)`;
const NUMBER = String.raw`(?:\d+(?:[./]\d+)?|[¼½¾⅓⅔]|${NUMBER_WORD})`;
const UNIT = String.raw`(?:g|gram(?:s)?|kg|kilogram(?:s)?|fl(?:uid)?\s*oz|fluid\s*ounce(?:s)?|oz|ounce(?:s)?|lb|pound(?:s)?|ml|milliliter(?:s)?|millilitre(?:s)?|l|liter(?:s)?|litre(?:s)?|cup(?:s)?|tbsp|tablespoon(?:s)?|tsp|teaspoon(?:s)?|slice(?:s)?|piece(?:s)?|serving(?:s)?|bowl(?:s)?|plate(?:s)?|glass(?:es)?|can(?:s)?|bottle(?:s)?|packet(?:s)?|scoop(?:s)?|handful(?:s)?)`;

const EXPLICIT_AMOUNT = new RegExp(String.raw`\b${NUMBER}\s*${UNIT}\b`, "i");
const WRITTEN_FRACTION = /\b(?:one|two|three)\s+(?:and\s+)?(?:a\s+)?(?:half|quarter|third|fourth|eighth)s?\b/i;
const NATURAL_PORTION = /\b(?:small|large|heaping|rounded)?\s*(?:handful|bite|sip|scoop|bowl|plate|glass|can|bottle|packet|container)\b/i;

function hasExplicitPortion(value) {
  const text = String(value || "").trim();
  return EXPLICIT_AMOUNT.test(text)
    || WRITTEN_FRACTION.test(text)
    || NATURAL_PORTION.test(text);
}

module.exports = {
  hasExplicitPortion,
};
