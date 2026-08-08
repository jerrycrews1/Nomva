const NUTRITION_COMPONENT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: [
    "name", "servingDescription", "calories", "proteinG", "carbsG", "fatG",
    "fiberG", "sugarG", "sodiumMg",
  ],
  properties: {
    name: { type: "string" },
    servingDescription: { type: "string" },
    calories: { type: "number", minimum: 0, maximum: 5_000 },
    proteinG: { type: "number", minimum: 0, maximum: 500 },
    carbsG: { type: "number", minimum: 0, maximum: 1_000 },
    fatG: { type: "number", minimum: 0, maximum: 500 },
    fiberG: { type: "number", minimum: 0, maximum: 250 },
    sugarG: { type: "number", minimum: 0, maximum: 1_000 },
    sodiumMg: { type: "number", minimum: 0, maximum: 20_000 },
  },
};

function boundedText(value, maximum = 180) {
  const text = String(value || "").trim();
  return text ? text.slice(0, maximum) : null;
}

function finiteWithin(value, minimum, maximum) {
  if (value === null || value === undefined || typeof value === "boolean") return null;
  if (typeof value === "string" && !value.trim()) return null;
  const number = Number(value);
  return Number.isFinite(number) && number >= minimum && number <= maximum ? number : null;
}

function rounded(value, digits = 1) {
  const factor = 10 ** digits;
  return Math.round((value + Number.EPSILON) * factor) / factor;
}

function sanitizeNutritionComponents(value, { required = false, maximum = 30 } = {}) {
  if (!Array.isArray(value)) return required ? null : [];
  if (required && value.length === 0) return null;
  if (value.length > maximum) return null;

  const components = [];
  for (const raw of value) {
    const name = boundedText(raw?.name);
    const servingDescription = boundedText(raw?.servingDescription);
    const calories = finiteWithin(raw?.calories, 0, 5_000);
    const proteinG = finiteWithin(raw?.proteinG, 0, 500);
    const carbsG = finiteWithin(raw?.carbsG, 0, 1_000);
    const fatG = finiteWithin(raw?.fatG, 0, 500);
    const fiberG = finiteWithin(raw?.fiberG, 0, 250);
    const sugarG = finiteWithin(raw?.sugarG, 0, 1_000);
    const sodiumMg = finiteWithin(raw?.sodiumMg, 0, 20_000);
    if (!name || !servingDescription || [
      calories, proteinG, carbsG, fatG, fiberG, sugarG, sodiumMg,
    ].some((number) => number === null)) {
      return null;
    }

    const macroCalories = (proteinG * 4) + (carbsG * 4) + (fatG * 9);
    if (Math.abs(macroCalories - calories) > Math.max(120, calories * 0.45)) return null;
    if (calories <= 10 && macroCalories > 30) return null;

    components.push({
      name,
      servingDescription,
      calories,
      proteinG,
      carbsG,
      fatG,
      fiberG,
      sugarG,
      sodiumMg,
    });
  }
  return components;
}

function aggregateNutritionComponents(components) {
  if (!Array.isArray(components) || components.length === 0) return null;
  const totals = components.reduce((sum, component) => ({
    caloriesPerServing: sum.caloriesPerServing + component.calories,
    proteinG: sum.proteinG + component.proteinG,
    carbsG: sum.carbsG + component.carbsG,
    fatG: sum.fatG + component.fatG,
    fiberG: sum.fiberG + component.fiberG,
    sugarG: sum.sugarG + component.sugarG,
    sodiumMg: sum.sodiumMg + component.sodiumMg,
  }), {
    caloriesPerServing: 0,
    proteinG: 0,
    carbsG: 0,
    fatG: 0,
    fiberG: 0,
    sugarG: 0,
    sodiumMg: 0,
  });

  return {
    caloriesPerServing: rounded(totals.caloriesPerServing),
    proteinG: rounded(totals.proteinG),
    carbsG: rounded(totals.carbsG),
    fatG: rounded(totals.fatG),
    fiberG: rounded(totals.fiberG),
    sugarG: rounded(totals.sugarG),
    sodiumMg: Math.round(totals.sodiumMg),
  };
}

function componentEvidence(components) {
  if (!Array.isArray(components) || components.length === 0) return null;
  const details = components.map((component) => (
    `${component.name} (${component.servingDescription}): ${rounded(component.calories)} cal`
  ));
  return `Estimated component breakdown: ${details.join("; ")}.`;
}

module.exports = {
  NUTRITION_COMPONENT_SCHEMA,
  aggregateNutritionComponents,
  componentEvidence,
  sanitizeNutritionComponents,
};
