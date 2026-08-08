const { boundedServings } = require("./numericGuards");
const {
  NUTRITION_COMPONENT_SCHEMA,
  aggregateNutritionComponents,
  componentEvidence,
  sanitizeNutritionComponents,
} = require("./nutritionEstimate");

const MEALS = new Set(["breakfast", "lunch", "dinner", "snack"]);
const ITEM_KINDS = new Set(["single", "composite", "menu"]);
const QUANTITY_SCOPES = new Set(["none", "per_item", "all_items"]);

const FOOD_LOG_PLANNER_PROMPT = `Interpret one message describing food or drink the user consumed.

Return a non-overlapping plan of the foods that should be logged. Preserve the user's meaning instead of merely splitting at commas or conjunctions.

Rules:
- Keep restaurant, brand, menu size, preparation, flavor, milk, and other nutrition-critical modifiers.
- Distinguish a complete dish from independently consumed sides, toppings, dips, and drinks.
- Never return both a complete dish and ingredients already represented inside that dish. That double-counts nutrition.
- If ingredients describe how a dish was assembled, keep them in one composite item. Separately consumed sides or measurable accompaniments remain separate items.
- Interpret quantity scope across the whole message. A trailing phrase such as "two servings of everything" applies to every planned item: use quantityScope=all_items and globalServings=2.
- A quantity grammatically attached to only one food applies only to that food: use quantityScope=per_item and keep each item's own amount.
- If no amount is stated, use one natural serving, mark it non-explicit, and use quantityScope=none.
- servings is a count of the natural portion in portionDescription, not calories, grams, or ounces converted into an arbitrary serving count.
- kind=menu for a named restaurant/manufacturer menu item, composite for a dish described by components, and single otherwise.
- searchQuery should be concise but must retain every modifier needed to identify the food correctly.
- For every composite item, estimate nutrition for ONE ordinary natural serving from the described ingredients and common portion knowledge. Return one structured component for every material ingredient with its assumed consumed amount and complete nutrition. Ambiguous ingredients may use a reasonable default, but confidence must reflect that uncertainty.
- Composite aggregate calories and nutrients must equal the component sums. Estimate sugar and sodium too; never use zero as a placeholder for an unknown value. If a complete defensible component estimate is impossible, use nutritionEstimate=null. Use confidence 0.5-0.8. This is an explicitly labeled estimate, never published nutrition.
- For menu and single items, nutritionEstimate must be null; those are resolved from current menu sources or the nutrition database instead.
- Return at most 12 items. Do not invent foods.

Examples:
- "I had soup and bread. Two servings of everything" means two planned items, both with two servings, quantityScope=all_items, globalServings=2.
- "A turkey and cheese sandwich with a side of chips" means one composite sandwich plus chips; do not also return turkey and cheese as separate foods.
- "Tea with one tablespoon honey" means tea plus honey because the add-in has its own explicit measurement.

Respond with ONLY a JSON object:
{"meal":"<breakfast|lunch|dinner|snack|none>","quantityScope":"<none|per_item|all_items>","globalServings":<number|null>,"items":[{"mention":"<food wording>","searchQuery":"<concise search wording>","kind":"<single|composite|menu>","servings":<number>,"portionDescription":"<amount and unit>","servingUnit":"<singular unit>","confident":<boolean>,"hasExplicitPortion":<boolean>,"nutritionEstimate":<null|{"canonicalName":"<short useful name>","servingDescription":"<one natural serving>","servingGrams":<number|null>,"caloriesPerServing":<number>,"proteinG":<number>,"carbsG":<number>,"fatG":<number>,"fiberG":<number>,"sugarG":<number>,"sodiumMg":<number>,"components":[{"name":"<ingredient>","servingDescription":"<assumed amount>","calories":<number>,"proteinG":<number>,"carbsG":<number>,"fatG":<number>,"fiberG":<number>,"sugarG":<number>,"sodiumMg":<number>}],"confidence":<number>,"assumptions":"<portion and ingredient assumptions>"}>}]}`;

const NUTRITION_ESTIMATE_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    canonicalName: { type: "string" },
    servingDescription: { type: "string" },
    servingGrams: { anyOf: [{ type: "number" }, { type: "null" }] },
    caloriesPerServing: { type: "number" },
    proteinG: { type: "number" },
    carbsG: { type: "number" },
    fatG: { type: "number" },
    fiberG: { type: "number" },
    sugarG: { anyOf: [{ type: "number" }, { type: "null" }] },
    sodiumMg: { anyOf: [{ type: "number" }, { type: "null" }] },
    components: { type: "array", items: NUTRITION_COMPONENT_SCHEMA, maxItems: 30 },
    confidence: { type: "number" },
    assumptions: { type: "string" },
  },
  required: [
    "canonicalName",
    "servingDescription",
    "servingGrams",
    "caloriesPerServing",
    "proteinG",
    "carbsG",
    "fatG",
    "fiberG",
    "sugarG",
    "sodiumMg",
    "components",
    "confidence",
    "assumptions",
  ],
};

const FOOD_LOG_PLAN_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    meal: { type: "string", enum: ["breakfast", "lunch", "dinner", "snack", "none"] },
    quantityScope: { type: "string", enum: ["none", "per_item", "all_items"] },
    globalServings: { anyOf: [{ type: "number" }, { type: "null" }] },
    items: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          mention: { type: "string" },
          searchQuery: { type: "string" },
          kind: { type: "string", enum: ["single", "composite", "menu"] },
          servings: { type: "number" },
          portionDescription: { type: "string" },
          servingUnit: { type: "string" },
          confident: { type: "boolean" },
          hasExplicitPortion: { type: "boolean" },
          nutritionEstimate: {
            anyOf: [NUTRITION_ESTIMATE_SCHEMA, { type: "null" }],
          },
        },
        required: [
          "mention",
          "searchQuery",
          "kind",
          "servings",
          "portionDescription",
          "servingUnit",
          "confident",
          "hasExplicitPortion",
          "nutritionEstimate",
        ],
      },
    },
  },
  required: ["meal", "quantityScope", "globalServings", "items"],
};

function boundedText(value, maxLength = 220) {
  const text = String(value || "").trim();
  return text ? text.slice(0, maxLength) : null;
}

function normalize(value) {
  return String(value || "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

function tokenSet(value) {
  return new Set(normalize(value).split(" ").filter((token) => token.length > 1));
}

function isStrictSubset(left, right) {
  return left.size > 0
    && left.size < right.size
    && [...left].every((token) => right.has(token));
}

function hasIndependentRelationship(compositeMention, itemMention) {
  const escaped = normalize(itemMention)
    .split(" ")
    .filter(Boolean)
    .map((token) => token.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
    .join("\\s+");
  if (!escaped) return false;
  const relationship = new RegExp(
    `\\b(?:side\\s+of|plus|alongside|topped\\s+with|dipped\\s+in|dip(?:ped)?\\s+with)\\s+(?:[^,.;]+\\s+)?${escaped}\\b`,
    "i"
  );
  return relationship.test(compositeMention);
}

function removeCompositeOverlaps(items) {
  const composites = items.filter((item) => item.kind === "composite");
  if (!composites.length) return items;
  return items.filter((item) => {
    if (item.kind === "composite") return true;
    const itemTokens = tokenSet(item.mention);
    return !composites.some((composite) => {
      const compositeIdentity = `${composite.mention} ${composite.searchQuery}`;
      return isStrictSubset(itemTokens, tokenSet(compositeIdentity))
        && !hasIndependentRelationship(compositeIdentity, item.mention);
    });
  });
}

function finiteNumber(value) {
  if (value === null || value === undefined || typeof value === "boolean") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function numberWithin(value, minimum, maximum) {
  const number = finiteNumber(value);
  return number !== null && number >= minimum && number <= maximum ? number : null;
}

function sanitizeCompositeEstimate(rawEstimate) {
  if (!rawEstimate || typeof rawEstimate !== "object") return null;
  const canonicalName = boundedText(rawEstimate.canonicalName, 180);
  const servingDescription = boundedText(rawEstimate.servingDescription, 180);
  const assumptions = boundedText(rawEstimate.assumptions, 1_500);
  const components = sanitizeNutritionComponents(rawEstimate.components, { required: true });
  const totals = aggregateNutritionComponents(components);
  const calories = totals?.caloriesPerServing ?? null;
  const protein = totals?.proteinG ?? null;
  const carbs = totals?.carbsG ?? null;
  const fat = totals?.fatG ?? null;
  const fiber = totals?.fiberG ?? null;
  if (!canonicalName || !servingDescription || !assumptions || calories === null
      || protein === null || carbs === null || fat === null || fiber === null) {
    return null;
  }

  const macroCalories = (protein * 4) + (carbs * 4) + (fat * 9);
  if (Math.abs(macroCalories - calories) > Math.max(160, calories * 0.45)) return null;

  const rawConfidence = numberWithin(rawEstimate.confidence, 0.5, 1);
  if (rawConfidence === null) return null;
  const rawServingGrams = rawEstimate.servingGrams;
  const servingGrams = rawServingGrams === null || rawServingGrams === undefined
    ? null
    : numberWithin(rawServingGrams, 1, 5_000);
  if (rawServingGrams !== null && rawServingGrams !== undefined && servingGrams === null) return null;

  return {
    canonicalName,
    servingDescription,
    servingGrams,
    caloriesPerServing: calories,
    proteinG: protein,
    carbsG: carbs,
    fatG: fat,
    fiberG: fiber,
    sugarG: totals.sugarG,
    sodiumMg: totals.sodiumMg,
    confidence: Math.min(rawConfidence, 0.8),
    assumptions: componentEvidence(components),
    components,
  };
}

function singularUnit(value) {
  const unit = boundedText(value, 80) || "serving";
  const lower = unit.toLowerCase();
  const known = {
    servings: "serving",
    portions: "portion",
    cups: "cup",
    bowls: "bowl",
    plates: "plate",
    pieces: "piece",
    slices: "slice",
    tablespoons: "tablespoon",
    teaspoons: "teaspoon",
    quesadillas: "quesadilla",
  };
  return known[lower] || unit;
}

function describedServingCount(servings, unit) {
  const count = Number.isInteger(servings)
    ? String(servings)
    : servings.toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
  return `${count} ${unit}${servings === 1 ? "" : "s"}`;
}

function sanitizeFoodLogPlan(raw) {
  if (!raw || !Array.isArray(raw.items)) return null;

  const mealValue = boundedText(raw.meal, 20)?.toLowerCase();
  const meal = MEALS.has(mealValue) ? mealValue : null;
  const rawScope = boundedText(raw.quantityScope, 20)?.toLowerCase();
  const quantityScope = QUANTITY_SCOPES.has(rawScope) ? rawScope : "none";
  const parsedGlobalServings = finiteNumber(raw.globalServings);
  const globalServings = quantityScope === "all_items" && parsedGlobalServings !== null
    ? boundedServings(parsedGlobalServings, 1)
    : null;

  const seen = new Set();
  const items = [];
  for (const rawItem of raw.items.slice(0, 12)) {
    const mention = boundedText(rawItem?.mention, 220);
    if (!mention) continue;
    const identity = normalize(mention);
    if (!identity || seen.has(identity)) continue;
    seen.add(identity);

    const itemServings = boundedServings(finiteNumber(rawItem.servings), 1);
    const servings = globalServings ?? itemServings;
    const servingUnit = singularUnit(rawItem.servingUnit);
    const rawPortion = boundedText(rawItem.portionDescription, 180);
    const countedUnitNeedsNormalization = servings !== 1;
    const portionDescription = globalServings !== null || countedUnitNeedsNormalization
      ? describedServingCount(servings, servingUnit)
      : rawPortion || `1 ${servingUnit}`;
    const rawKind = boundedText(rawItem.kind, 20)?.toLowerCase();
    const kind = ITEM_KINDS.has(rawKind) ? rawKind : "single";

    items.push({
      mention,
      searchQuery: boundedText(rawItem.searchQuery, 220) || mention,
      kind,
      servings,
      portionDescription,
      servingUnit,
      confident: globalServings !== null || rawItem.confident === true,
      hasExplicitPortion: globalServings !== null || rawItem.hasExplicitPortion === true,
      nutritionEstimate: kind === "composite"
        ? sanitizeCompositeEstimate(rawItem.nutritionEstimate)
        : null,
    });
  }

  const nonOverlappingItems = removeCompositeOverlaps(items);
  if (!nonOverlappingItems.length) return null;
  return {
    meal,
    quantityScope,
    globalServings,
    items: nonOverlappingItems,
  };
}

function shouldUseStructuredFoodPlan(message) {
  const text = String(message || "");
  if (!text.trim()) return false;
  const relationshipCue = /\b(with|plus|alongside|topped|filled|made|including|side|dip|dipped)\b/i.test(text);
  const conjunctionCue = /\s+and\s+/i.test(text);
  const globalScopeCue = /\b(?:servings?|portions?|plates?|bowls?)\b[^.!?]{0,30}\b(?:everything|all|each)\b|\b(?:everything|all|each)\b[^.!?]{0,30}\b(?:servings?|portions?|plates?|bowls?)\b/i.test(text);
  const listCue = /[,;]/.test(text) && /\b(and|plus|also)\b/i.test(text);
  return relationshipCue || conjunctionCue || globalScopeCue || listCue;
}

module.exports = {
  FOOD_LOG_PLAN_SCHEMA,
  FOOD_LOG_PLANNER_PROMPT,
  sanitizeFoodLogPlan,
  shouldUseStructuredFoodPlan,
};
