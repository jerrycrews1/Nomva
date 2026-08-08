const { boundedServings } = require("./numericGuards");
const {
  identityMatchesMention,
  inferredServingCount,
  resolvedCandidateBody,
} = require("./webFoodResolver");
const {
  NUTRITION_COMPONENT_SCHEMA,
  aggregateNutritionComponents,
  componentEvidence,
  sanitizeNutritionComponents,
} = require("./nutritionEstimate");

const WORLD_FOOD_ESTIMATE_PROMPT = `Resolve one recognized generic or cultural food from stable culinary knowledge without web browsing.

This path is only for foods missing from the nutrition catalog. It is not for a named restaurant item, branded product, menu size, or custom product; return found=false for those because current published evidence is required. Return found=false for invented, unclear, or unfamiliar names. Never infer a dish merely because the words sound food-like.

When the food is a well-established dish, estimate nutrition for ONE ordinary consumed serving using its conventional ingredients and portion. Return one structured component for every material ingredient with its assumed consumed amount and complete nutrition. Aggregate calories and nutrients must equal the component sums. Estimate sugar and sodium too; never use zero as a placeholder for an unknown value. If a complete defensible component estimate is impossible, return found=false. Confidence must be 0.5-0.8 because this is an estimate, never published nutrition. Preserve the exact recognized identity and do not substitute a different regional dish.`;

const nullableNumber = { anyOf: [{ type: "number" }, { type: "null" }] };
const WORLD_FOOD_ESTIMATE_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    found: { type: "boolean" },
    canonicalName: { type: "string" },
    aliases: { type: "array", items: { type: "string" }, maxItems: 12 },
    servingDescription: { type: "string" },
    servingGrams: nullableNumber,
    caloriesPerServing: nullableNumber,
    proteinG: nullableNumber,
    carbsG: nullableNumber,
    fatG: nullableNumber,
    fiberG: nullableNumber,
    sugarG: nullableNumber,
    sodiumMg: nullableNumber,
    components: { type: "array", items: NUTRITION_COMPONENT_SCHEMA, maxItems: 30 },
    confidence: { type: "number", minimum: 0, maximum: 1 },
    assumptions: { type: "string" },
    servings: { type: "number", minimum: 0.1, maximum: 100 },
    portionDescription: { type: "string" },
    servingUnit: { type: "string" },
    hasExplicitPortion: { type: "boolean" },
  },
  required: [
    "found", "canonicalName", "aliases", "servingDescription", "servingGrams",
    "caloriesPerServing", "proteinG", "carbsG", "fatG", "fiberG", "sugarG",
    "sodiumMg", "components", "confidence", "assumptions", "servings", "portionDescription",
    "servingUnit", "hasExplicitPortion",
  ],
};

function finiteWithin(value, minimum, maximum) {
  if (value === null || value === undefined || typeof value === "boolean") return null;
  const number = Number(value);
  return Number.isFinite(number) && number >= minimum && number <= maximum ? number : null;
}

function boundedText(value, maximum) {
  const text = String(value || "").trim();
  return text ? text.slice(0, maximum) : null;
}

function sanitizeWorldFoodEstimate(raw, foodMention) {
  if (!raw || raw.found !== true) return null;
  const canonicalName = boundedText(raw.canonicalName, 180);
  const servingDescription = boundedText(raw.servingDescription, 180);
  const assumptions = boundedText(raw.assumptions, 1_500);
  const components = sanitizeNutritionComponents(raw.components, { required: true });
  const totals = aggregateNutritionComponents(components);
  const calories = totals?.caloriesPerServing ?? null;
  const protein = totals?.proteinG ?? null;
  const carbs = totals?.carbsG ?? null;
  const fat = totals?.fatG ?? null;
  const fiber = totals?.fiberG ?? null;
  const confidence = finiteWithin(raw.confidence, 0.5, 0.8);
  if (!canonicalName || !servingDescription || !assumptions || calories === null
      || protein === null || carbs === null || fat === null || fiber === null
      || confidence === null) {
    return null;
  }

  const macroCalories = (protein * 4) + (carbs * 4) + (fat * 9);
  if (Math.abs(macroCalories - calories) > Math.max(160, calories * 0.45)) return null;

  const servingGrams = raw.servingGrams === null
    ? null
    : finiteWithin(raw.servingGrams, 1, 5_000);
  if (raw.servingGrams !== null && servingGrams === null) {
    return null;
  }

  const modelAliases = [...new Set((Array.isArray(raw.aliases) ? raw.aliases : [])
    .map((value) => boundedText(value, 180))
    .filter(Boolean))].slice(0, 12);
  const candidate = {
    name: canonicalName,
    brand: null,
    aliases: modelAliases,
    servingDescription,
    servingGrams,
    caloriesPerServing: calories,
    proteinG: protein,
    carbsG: carbs,
    fatG: fat,
    fiberG: fiber,
    sugarG: totals.sugarG,
    sodiumMg: totals.sodiumMg,
    quality: "estimated",
    confidence,
    evidence: componentEvidence(components),
    components,
  };
  if (!identityMatchesMention(foodMention, { ...candidate, aliases: [] })) return null;
  return {
    ...candidate,
    aliases: [...new Set([foodMention, ...modelAliases])].slice(0, 20),
  };
}

async function resolveWorldFoodEstimate({
  userMessage = "",
  foodMention,
  askAgent,
  knowledgeStore,
  sourceUrl,
}) {
  const mention = boundedText(foodMention, 220);
  if (!mention || typeof askAgent !== "function") return null;
  const raw = await askAgent([
    `Full user message: "${boundedText(userMessage, 500) || mention}"`,
    `Food mention to resolve: "${mention}"`,
  ].join("\n"));
  const estimate = sanitizeWorldFoodEstimate(raw, mention);
  if (!estimate) return null;

  const candidate = knowledgeStore.upsert({
    ...estimate,
    sourceUrl,
    sourceTitle: "Nomva AI nutrition estimate",
  }, estimate.aliases);
  return resolvedCandidateBody(candidate, {
    servings: boundedServings(raw.servings, inferredServingCount(mention)),
    portionDescription: boundedText(raw.portionDescription, 180) || mention,
    servingUnit: boundedText(raw.servingUnit, 80) || "serving",
    confident: false,
    hasExplicitPortion: raw.hasExplicitPortion === true,
  });
}

function firstNonNull(promises, timeoutMs) {
  const tasks = Array.from(promises || []);
  if (!tasks.length) return Promise.resolve(null);
  return new Promise((resolve) => {
    let complete = false;
    let pending = tasks.length;
    const finish = (value) => {
      if (complete) return;
      complete = true;
      clearTimeout(timer);
      resolve(value);
    };
    const timer = setTimeout(() => finish(null), Math.max(1, Number(timeoutMs) || 15_000));
    for (const task of tasks) {
      Promise.resolve(task)
        .then((value) => {
          if (value !== null && value !== undefined) finish(value);
        })
        .catch(() => {})
        .finally(() => {
          pending -= 1;
          if (pending === 0) finish(null);
        });
    }
  });
}

module.exports = {
  WORLD_FOOD_ESTIMATE_PROMPT,
  WORLD_FOOD_ESTIMATE_SCHEMA,
  firstNonNull,
  resolveWorldFoodEstimate,
  sanitizeWorldFoodEstimate,
};
