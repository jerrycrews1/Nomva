const PREPARATION_ROOTS = new Map([
  ["baked", "bake"],
  ["baking", "bake"],
  ["boiled", "boil"],
  ["boiling", "boil"],
  ["broiled", "broil"],
  ["broiling", "broil"],
  ["fried", "fry"],
  ["frying", "fry"],
  ["grilled", "grill"],
  ["grilling", "grill"],
  ["poached", "poach"],
  ["poaching", "poach"],
  ["roasted", "roast"],
  ["roasting", "roast"],
  ["sauteed", "saute"],
  ["sauteing", "saute"],
  ["scrambled", "scramble"],
  ["scrambling", "scramble"],
  ["smoked", "smoke"],
  ["smoking", "smoke"],
  ["steamed", "steam"],
  ["steaming", "steam"],
  ["toasted", "toast"],
  ["toasting", "toast"],
]);

function singularFoodToken(value) {
  const token = String(value || "").toLowerCase();
  if (token.endsWith("ies") && token.length > 3) return `${token.slice(0, -3)}y`;
  if (token.endsWith("s") && token.length > 3 && !token.endsWith("ss")) {
    return token.slice(0, -1);
  }
  return token;
}

function canonicalFoodToken(value) {
  const singular = singularFoodToken(value);
  return PREPARATION_ROOTS.get(singular) || singular;
}

function canonicalFoodTokenSet(values) {
  return new Set(Array.from(values || [], canonicalFoodToken));
}

module.exports = {
  canonicalFoodToken,
  canonicalFoodTokenSet,
  singularFoodToken,
};
