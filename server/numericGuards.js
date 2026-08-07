"use strict";

// Central numeric sanity bounds for values extracted from LLM output.
// The model is untrusted input: JSON can carry 1e308, negatives, or absurd
// magnitudes, and the iOS client converts derived calories with Int(Double),
// which traps fatally on NaN/Infinity/out-of-Int64 values. Everything the
// model emits as a number must pass through one of these guards before it
// reaches a response body.

const BOUNDS = {
  servings: { min: 0.05, max: 100 },
  grams: { min: 1, max: 5000 },
  calories: { min: 0, max: 5000 },
  macroGrams: { min: 0, max: 1000 },
  waterOz: { min: 1, max: 300 },
  weightLbs: { min: 50, max: 1000 },
  goalCalories: { min: 500, max: 20000 },
  goalMacroGrams: { min: 1, max: 2000 },
  goalWaterOz: { min: 8, max: 300 },
  goalWeightLbs: { min: 50, max: 1000 },
};

// Returns the value when it is a finite number inside [min, max]; otherwise
// returns fallback (default null). Never clamps silently across orders of
// magnitude: an out-of-range extraction means the model misread the message,
// so the caller should treat it as "not extracted" rather than trust an
// arbitrary boundary value.
function boundedNumber(value, { min, max }, fallback = null) {
  if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
  if (value < min || value > max) return fallback;
  return value;
}

function boundedServings(value, fallback = null) {
  return boundedNumber(value, BOUNDS.servings, fallback);
}

function boundedGrams(value, fallback = null) {
  return boundedNumber(value, BOUNDS.grams, fallback);
}

function boundedGoalValue(metric, value) {
  switch (metric) {
    case "calories":
      return boundedNumber(value, BOUNDS.goalCalories);
    case "water_oz":
      return boundedNumber(value, BOUNDS.goalWaterOz);
    case "target_weight_lbs":
      return boundedNumber(value, BOUNDS.goalWeightLbs);
    case "protein":
    case "carbs":
    case "fat":
    case "fiber":
      return boundedNumber(value, BOUNDS.goalMacroGrams);
    default:
      return null;
  }
}

// Validates one food item from the vision model. Returns a sanitized copy or
// null when the item is unusable. Never forwards unvalidated model JSON.
function sanitizePhotoFood(item) {
  if (!item || typeof item !== "object") return null;
  const name = typeof item.name === "string" ? item.name.trim().slice(0, 120) : "";
  if (!name) return null;

  const calories = boundedNumber(item.calories, BOUNDS.calories);
  if (calories === null) return null;

  const grams = boundedNumber(item.grams, BOUNDS.grams, 100);
  const macro = (value) => boundedNumber(value, BOUNDS.macroGrams, 0);

  return {
    name,
    portion: typeof item.portion === "string" && item.portion.trim()
      ? item.portion.trim().slice(0, 80)
      : "1 serving",
    grams,
    calories,
    protein: macro(item.protein),
    carbs: macro(item.carbs),
    fat: macro(item.fat),
    fiber: item.fiber === undefined || item.fiber === null
      ? null
      : macro(item.fiber),
  };
}

function sanitizePhotoAnalysis(result) {
  const notFood = result?.notFood === true;
  const foods = (Array.isArray(result?.foods) ? result.foods : [])
    .slice(0, 12)
    .map(sanitizePhotoFood)
    .filter(Boolean);
  return { notFood, foods };
}

// Nutrition-label scans intentionally keep unreadable fields nullable. A
// missing value must be reviewed by the user rather than silently becoming a
// model estimate or a printed zero.
function sanitizeNutritionLabelAnalysis(result) {
  if (result?.notNutritionLabel === true) {
    return { notNutritionLabel: true, food: null };
  }

  const raw = result?.food;
  if (!raw || typeof raw !== "object") {
    return { notNutritionLabel: true, food: null };
  }

  const calories = boundedNumber(raw.calories, BOUNDS.calories);
  if (calories === null) {
    return { notNutritionLabel: true, food: null };
  }

  const cleanText = (value, maxLength) => (
    typeof value === "string" ? value.trim().slice(0, maxLength) : ""
  );
  const optionalMacro = (value) => boundedNumber(value, BOUNDS.macroGrams);

  return {
    notNutritionLabel: false,
    food: {
      name: cleanText(raw.name, 120),
      brand: cleanText(raw.brand, 120),
      servingDescription: cleanText(raw.servingDescription, 100) || "1 serving",
      servingGrams: boundedNumber(raw.servingGrams, BOUNDS.grams),
      calories,
      protein: optionalMacro(raw.protein),
      carbs: optionalMacro(raw.carbs),
      fat: optionalMacro(raw.fat),
      fiber: optionalMacro(raw.fiber),
    },
  };
}

module.exports = {
  BOUNDS,
  boundedNumber,
  boundedServings,
  boundedGrams,
  boundedGoalValue,
  sanitizePhotoAnalysis,
  sanitizePhotoFood,
  sanitizeNutritionLabelAnalysis,
};
