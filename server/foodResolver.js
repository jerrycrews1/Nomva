const { boundedServings } = require("./numericGuards");
const { databaseServingRatio, parsedPortion } = require("./portionMath");
const { isAuthoritativeReferenceSource } = require("./foodSearchStore");
const { canonicalFoodToken, canonicalFoodTokenSet } = require("./foodTokenNormalizer");
const { identityMatchesMention, resolvedCandidateBody } = require("./webFoodResolver");

const REQUIRED_IDENTITY_TOKENS = canonicalFoodTokenSet([
  "zero", "diet", "sugarfree", "unsweetened", "sweetened", "decaf", "plain",
  "iced", "hot", "grilled", "fried", "raw", "cooked", "roasted", "smoked",
  "vegan", "vegetarian", "nonfat", "lowfat", "skim",
  "chicken", "beef", "pork", "fish", "turkey", "lamb", "duck", "goose", "quail", "venison",
  "small", "medium", "large", "short", "tall", "grande", "venti", "trenta",
]);

const UNEXPECTED_VARIANT_TOKENS = canonicalFoodTokenSet([
  "zero", "diet", "sugarfree", "unsweetened", "sweetened", "decaf",
  "iced", "hot", "grilled", "fried", "roasted", "smoked",
  "vegan", "vegetarian", "nonfat", "lowfat", "skim",
  "duck", "goose", "quail", "turkey", "venison", "lamb",
  "powder", "powdered", "liquid", "frozen", "dried", "dehydrated", "canned",
  "white", "yolk", "meatless", "leaf", "leaves", "oil", "flour", "baby", "infant",
  "chip", "chips", "paste", "sauce", "salad", "filling", "casserole", "pie",
  "sandwich", "stick", "sticks", "reduced", "low", "sodium",
  "bean", "beans", "bit", "bits", "cider", "juice", "dressing", "gravy", "breading",
  "squash", "spinach", "fry", "fries", "tot", "tots", "candied",
  "bread", "bun", "wrap", "sub", "pocket", "pockets", "pasta", "spaghetti",
  "cracker", "crispbread", "melba",
  "pickle", "pickled", "muffin", "cake", "cupcake",
  "noodle", "noodles", "soup", "creamed",
  "ingredient", "use",
]);

const FOOD_SELECTION_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    action: { type: "string", enum: ["pick", "give_up"] },
    rowId: { anyOf: [{ type: "integer" }, { type: "null" }] },
    servings: { type: "number" },
    portionDescription: { type: "string" },
    servingUnit: { type: "string" },
    confident: { type: "boolean" },
    hasExplicitPortion: { type: "boolean" },
  },
  required: [
    "action",
    "rowId",
    "servings",
    "portionDescription",
    "servingUnit",
    "confident",
    "hasExplicitPortion",
  ],
};

function explicitlyRequestedBrand(foodMention, candidate) {
  if (!candidate?.brand) return false;
  const mentionTokens = new Set(normalizedFoodTokens(foodMention));
  const nameTokens = new Set(normalizedFoodTokens(candidate.name || ""));
  const brandOnlyTokens = normalizedFoodTokens(candidate.brand)
    .filter((token) => !nameTokens.has(token)
      && !REQUIRED_IDENTITY_TOKENS.has(token)
      && !["brand", "company", "corporation", "corp", "inc", "llc", "ltd", "foods", "food", "co"].includes(token));
  return brandOnlyTokens.length > 0
    && brandOnlyTokens.some((token) => mentionTokens.has(token));
}

function hasNaturalHouseholdServing(candidate) {
  const serving = String(candidate?.servingDescription || "").toLowerCase();
  return /\b(cups?|tablespoons?|tbsp|teaspoons?|tsp|pieces?|slices?|bottles?|cans?|bars?|packages?|packets?|containers?|sandwich(?:es)?|nuggets?|meatballs?|patt(?:y|ies)|bowls?|glasses)\b/.test(serving);
}

function provenanceInvariantFeedback(foodMention, candidate, selection = {}) {
  const source = String(candidate?.source || "");
  if (!["branded", "open_food_facts"].includes(source)) return null;
  if (explicitlyRequestedBrand(foodMention, candidate)) return null;
  if (selection?.hasExplicitPortion === true) return null;
  if (hasNaturalHouseholdServing(candidate)) return null;

  return "An unrequested packaged-food row with only a mass or generic serving basis is not a reliable default portion for an ordinary food.";
}

function renderFoodSearchRounds(rounds) {
  if (!rounds.length) {
    return "(no search rounds yet)";
  }

  return rounds.map((round, roundIdx) => {
    const header = `Round ${roundIdx} - query "${round.query}" (offset ${round.offset}):`;
    if (!round.candidates.length) {
      return `${header}\n  (no candidates returned)`;
    }
    const candidateLines = round.candidates.map((candidate) => {
      const brand = candidate.brand ? ` | brand: ${candidate.brand}` : "";
      const serving = candidate.servingDescription ? ` | serving: ${candidate.servingDescription}` : "";
      const grams = typeof candidate.servingGrams === "number" ? ` | serving_g: ${Math.round(candidate.servingGrams)}` : "";
      const defaultServing = typeof candidate.defaultServingGrams === "number"
        ? ` | omitted-amount default: ${candidate.defaultServingDescription || "1 estimated serving"} (${Math.round(candidate.defaultServingGrams)} g; ${candidate.defaultServingSource || "unspecified source"})`
        : "";
      const source = candidate.source ? ` | source: ${candidate.source}` : "";
      const aliases = candidate.searchTerms ? ` | aliases: ${String(candidate.searchTerms).slice(0, 180)}` : "";
      const basis = candidate.portionBasis ? ` | basis: ${candidate.portionBasis}` : "";
      const calories = typeof candidate.caloriesPerServing === "number"
        ? ` | calories: ${Math.round(candidate.caloriesPerServing)}`
        : "";
      return `  rowId ${candidate.rowId}: ${candidate.name}${brand}${serving}${grams}${defaultServing}${source}${basis}${calories}${aliases}`;
    });
    return `${header}\n${candidateLines.join("\n")}`;
  }).join("\n\n");
}

function resolvedBody(selectedFood, verification) {
  return resolvedCandidateBody(selectedFood, {
    servings: verification.servings,
    portionDescription: verification.portionDescription,
    servingUnit: verification.servingUnit,
    confident: verification.confident,
    hasExplicitPortion: verification.hasExplicitPortion,
  });
}

function normalizedTokens(value) {
  return new Set(String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .split(/\s+/)
    .filter(Boolean));
}

function normalizedFoodTokens(value) {
  const stopWords = new Set([
    "a", "an", "the", "i", "had", "ate", "drank", "for", "at", "to", "of",
    "with", "and", "about", "one", "two", "three", "four", "five", "six",
    "seven", "eight", "nine", "ten", "oz", "ounce", "ounces", "g", "gram",
    "grams", "cup", "cups", "serving", "servings",
    "whole", "side",
  ]);
  return [...normalizedTokens(String(value || "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, ""))]
    .filter((token) => !stopWords.has(token)
      && !/^\d+(?:\.\d+)?(?:oz|ounce|ounces|g|gram|grams|kg|ml|l|lb|lbs)?$/.test(token));
}

function singularFoodToken(token) {
  return canonicalFoodToken(token);
}

function unrequestedVariantIsImplied(variant, mentionSet) {
  return variant === "bread" && mentionSet.has("toast");
}

function isExplicitlyUnspecifiedReference(candidate) {
  return isAuthoritativeReferenceSource(candidate?.source)
    && /\b(?:nfs|ns)\s+as\s+to\s+(?:type|kind)\b/i.test(String(candidate?.name || ""));
}

function requestedIdentityExistsOnlyInIncludesClause(foodMention, candidate) {
  const rawName = String(candidate?.name || "").toLowerCase();
  const includesIndex = rawName.indexOf("(includes ");
  if (includesIndex < 0) return false;

  const primaryTokens = new Set(normalizedFoodTokens(rawName.slice(0, includesIndex)).map(singularFoodToken));
  const fullTokens = new Set(normalizedFoodTokens(rawName).map(singularFoodToken));
  return normalizedFoodTokens(foodMention)
    .map(singularFoodToken)
    .some((token) => fullTokens.has(token)
      && !primaryTokens.has(token)
      && !(token === "toast" && primaryTokens.has("bread")));
}

function candidateCompatibleWithMention(foodMention, candidate) {
  const mentionTokens = normalizedFoodTokens(foodMention);
  const candidateNameTokens = normalizedFoodTokens(candidate?.name || "");
  const candidateTokens = new Set(normalizedFoodTokens(
    `${candidate?.name || ""} ${candidate?.brand || ""} ${candidate?.servingDescription || ""}`
  ));
  if (!mentionTokens.length || !candidateTokens.size) return false;
  if (requestedIdentityExistsOnlyInIncludesClause(foodMention, candidate)) return false;

  const mentionSet = new Set(mentionTokens);
  const candidateNameSet = new Set(candidateNameTokens);
  const singularMentionTokens = mentionTokens.map(singularFoodToken);
  const singularNameTokens = new Set(candidateNameTokens.map(singularFoodToken));
  if (!singularMentionTokens.some((token) => singularNameTokens.has(token))) {
    // Brand-name collisions are not food identity. A candidate must share at
    // least one token with the product name itself, not only its manufacturer.
    return false;
  }
  for (const modifier of REQUIRED_IDENTITY_TOKENS) {
    if (mentionSet.has(modifier) && !candidateTokens.has(modifier)) return false;
  }
  const unrequestedVariants = [];
  for (const variant of UNEXPECTED_VARIANT_TOKENS) {
    const index = candidateNameTokens.indexOf(variant);
    const negated = index > 0 && ["no", "without"].includes(candidateNameTokens[index - 1]);
    if (candidateNameSet.has(variant)
        && !mentionSet.has(variant)
        && !negated
        && !unrequestedVariantIsImplied(variant, mentionSet)) {
      unrequestedVariants.push(variant);
    }
  }
  if (unrequestedVariants.length > 0
      && !(isExplicitlyUnspecifiedReference(candidate) && unrequestedVariants.length === 1)) {
    return false;
  }

  if (identityMatchesMention(foodMention, candidate)) return true;
  const matched = mentionTokens.filter((token) => candidateTokens.has(token));
  const requiredCoverage = mentionTokens.length <= 2 ? 0.5 : 2 / 3;
  return matched.length > 0 && matched.length / mentionTokens.length >= requiredCoverage;
}

function safeDeterministicFallback(foodMention, searchRounds) {
  const candidate = deterministicFallbackCandidate(foodMention, searchRounds);
  if (!candidate || !candidateCompatibleWithMention(foodMention, candidate)) return null;

  const mentionTokens = normalizedFoodTokens(foodMention).map(singularFoodToken);
  const candidateTokens = new Set(normalizedFoodTokens(
    `${candidate.name || ""} ${candidate.brand || ""} ${candidate.servingDescription || ""}`
  ).map(singularFoodToken));
  const coverage = mentionTokens.filter((token) => candidateTokens.has(token)).length
    / Math.max(1, mentionTokens.length);
  return coverage >= 0.8 ? candidate : null;
}

function deterministicFallbackCandidate(foodMention, searchRounds) {
  const mentionTokens = normalizedFoodTokens(foodMention).map(singularFoodToken);
  if (!mentionTokens.length) {
    return null;
  }

  const candidates = searchRounds.flatMap((round) => round.candidates || []);
  const unique = new Map();
  for (const candidate of candidates) {
    if (!unique.has(candidate.rowId)) unique.set(candidate.rowId, candidate);
  }

  // The search store has already combined lexical relevance, source quality,
  // brand intent, portion quality, and variant penalties. Preserve that ranked
  // order here. Re-scoring exact names in the old fallback promoted packaged
  // products over safer USDA rows and then rejected those products, producing
  // a false no-match whenever the model timed out or declined to choose.
  const fallbackSelection = {
    servings: 1,
    hasExplicitPortion: false,
  };
  for (const candidate of unique.values()) {
    if (!candidateCompatibleWithMention(foodMention, candidate)) continue;
    const candidateTokens = new Set(normalizedFoodTokens(
      `${candidate.name || ""} ${candidate.brand || ""} ${candidate.servingDescription || ""}`
    ).map(singularFoodToken));
    const matched = mentionTokens.filter((token) => candidateTokens.has(token));
    const coverage = matched.length / mentionTokens.length;
    if (coverage < 0.8) continue;
    if (nutritionInvariantFeedback(foodMention, candidate, fallbackSelection.servings)) continue;
    if (provenanceInvariantFeedback(foodMention, candidate, fallbackSelection)) continue;
    return candidate;
  }
  return null;
}

function applyCandidateDefaultServing(candidate, selection) {
  if (!candidate || selection?.hasExplicitPortion === true) return selection;

  const basisGrams = Number(candidate.servingGrams);
  const defaultGrams = Number(candidate.defaultServingGrams);
  if (!Number.isFinite(basisGrams) || basisGrams <= 0
      || !Number.isFinite(defaultGrams) || defaultGrams <= 0) {
    return selection;
  }

  const servings = defaultGrams / basisGrams;
  if (!Number.isFinite(servings) || servings < 0.05 || servings > 100) {
    return selection;
  }

  const portionDescription = String(
    candidate.defaultServingDescription || candidate.servingDescription || "1 estimated serving"
  ).trim();
  return {
    ...selection,
    servings,
    portionDescription,
    servingUnit: portionDescription === candidate.servingDescription
      ? selection.servingUnit
      : "serving",
    confident: false,
  };
}

function candidateServingRatio(candidate, portionDescription) {
  const directRatio = databaseServingRatio(candidate?.servingDescription, portionDescription);
  if (directRatio !== null) return directRatio;

  const consumed = parsedPortion(portionDescription);
  const servingGrams = Number(candidate?.servingGrams);
  if (consumed?.dimension !== "mass" || !Number.isFinite(servingGrams) || servingGrams <= 0) {
    return null;
  }
  const ratio = consumed.baseAmount / servingGrams;
  if (!Number.isFinite(ratio) || ratio < 0.05 || ratio > 100) return null;
  return Math.round(ratio * 1_000_000) / 1_000_000;
}

function servingUnitFromPortion(portionDescription, fallback) {
  const portion = parsedPortion(portionDescription);
  if (!portion?.unit) return fallback;
  return portion.unit === "fl_oz" ? "fl oz" : portion.unit;
}

function selectionForAlternateCandidate(candidate, selection) {
  if (selection?.hasExplicitPortion === true) {
    const servings = candidateServingRatio(candidate, selection.portionDescription);
    return servings === null ? null : {
      ...selection,
      servings,
      servingUnit: servingUnitFromPortion(selection.portionDescription, selection.servingUnit),
    };
  }
  return applyCandidateDefaultServing(candidate, { ...selection });
}

function authoritativeGenericReference(foodMention, candidates, selection = null) {
  return candidates.find((candidate) => {
    if (candidate?.brand
        || !isAuthoritativeReferenceSource(candidate?.source)
        || !candidateCompatibleWithMention(foodMention, candidate)) {
      return false;
    }
    const adapted = selection ? selectionForAlternateCandidate(candidate, selection) : { servings: 1 };
    return adapted && !nutritionInvariantFeedback(foodMention, candidate, adapted.servings);
  }) || null;
}

function fallbackResolvedBody(foodMention, searchRounds) {
  const candidate = safeDeterministicFallback(foodMention, searchRounds);
  const fallbackSelection = applyCandidateDefaultServing(candidate, {
    servings: 1,
    portionDescription: candidate?.servingDescription || "1 serving",
    servingUnit: "serving",
    confident: false,
    hasExplicitPortion: false,
  });
  if (!candidate
      || nutritionInvariantFeedback(foodMention, candidate, fallbackSelection.servings)
      || provenanceInvariantFeedback(foodMention, candidate, fallbackSelection)) {
    return null;
  }
  return resolvedBody(candidate, fallbackSelection);
}

function genericBrandInvariantFeedback(foodMention, selectedFood, selection, candidates) {
  const source = String(selectedFood?.source || "");
  const isWeakerPackageSource = ["branded", "open_food_facts"].includes(source);
  if ((!selectedFood?.brand && !isWeakerPackageSource)
      || explicitlyRequestedBrand(foodMention, selectedFood)) {
    return null;
  }

  const genericReference = authoritativeGenericReference(foodMention, candidates, selection);
  return genericReference
    ? "An unrequested brand or crowdsourced package cannot replace a compatible authoritative generic reference."
    : null;
}

function nutritionInvariantFeedback(foodMention, selectedFood, servings) {
  const mentionTokens = normalizedTokens(foodMention);
  const selectedTokens = normalizedTokens(`${selectedFood?.name || ""} ${selectedFood?.brand || ""}`);
  const hasCriticalModifier = mentionTokens.has("diet")
    || mentionTokens.has("zero")
    || mentionTokens.has("sugarfree")
    || (mentionTokens.has("sugar") && mentionTokens.has("free"));
  const beverageTokens = ["beverage", "coke", "cola", "drink", "soda"];
  const isSoftDrink = beverageTokens.some((token) => mentionTokens.has(token) || selectedTokens.has(token));
  const caloriesPerServing = Number(selectedFood?.caloriesPerServing);
  const proposedServings = Number(servings);

  const protein = Number(selectedFood?.proteinG);
  const carbs = Number(selectedFood?.carbsG);
  const fat = Number(selectedFood?.fatG);
  if ([caloriesPerServing, protein, carbs, fat].every(Number.isFinite)) {
    const macroCalories = (protein * 4) + (carbs * 4) + (fat * 9);
    if (macroCalories >= 20 && caloriesPerServing + 20 < macroCalories * 0.55) {
      return "The row's calories materially contradict its own protein, carbohydrate, and fat values.";
    }
  }

  if (!hasCriticalModifier || !isSoftDrink || !Number.isFinite(caloriesPerServing) || !Number.isFinite(proposedServings)) {
    return null;
  }

  const impliedCalories = caloriesPerServing * proposedServings;
  if (impliedCalories <= 10) {
    return null;
  }

  return `The proposed diet/zero/sugar-free drink portion implies ${Math.round(impliedCalories)} calories. `
    + "Choose a matching noncaloric row and calculate its database servings for the user's actual portion.";
}

async function resolveFoodCandidate({
  userMessage,
  foodMention,
  searchQuery = null,
  foodSearchStore,
  askAgent,
  deadlineMs = null,
  onEvent = () => {},
}) {
  const trimmedMention = String(foodMention || "").trim();
  const trimmedQuery = String(searchQuery || trimmedMention).trim() || trimmedMention;
  const startedAt = Date.now();
  const searchRounds = [{
    query: trimmedQuery,
    offset: 0,
    candidates: foodSearchStore.search(trimmedQuery, { limit: 30, offset: 0 }),
  }];
  const candidates = searchRounds[0].candidates;
  onEvent({ type: "search", turn: 0, query: trimmedQuery, offset: 0, candidateCount: candidates.length });
  if (!candidates.length) {
    return { status: 422, body: { error: "no_matching_food" } };
  }

  const userPrompt = [
    `User said: "${userMessage}"`,
    `Food mention: "${trimmedMention}"`,
    `Database search query: "${trimmedQuery}"`,
    "",
    "Retrieved candidates:",
    renderFoodSearchRounds(searchRounds),
  ].join("\n");

  let result;
  try {
    if (typeof deadlineMs === "number" && Date.now() - startedAt >= deadlineMs) {
      throw new Error("food resolution deadline reached before selection");
    }
    result = await askAgent(userPrompt);
  } catch (error) {
    onEvent({ type: "agent_error", turn: 0, message: error.message });
    const fallback = fallbackResolvedBody(trimmedMention, searchRounds);
    return fallback
      ? { status: 200, body: fallback }
      : { status: 422, body: { error: "no_matching_food" } };
  }

  const action = String(result?.action || "").toLowerCase();
  onEvent({ type: "agent", turn: 0, action, result, searchRoundCount: 1 });
  if (action !== "pick") {
    const fallback = fallbackResolvedBody(trimmedMention, searchRounds);
    return fallback
      ? { status: 200, body: fallback }
      : { status: 422, body: { error: "no_matching_food" } };
  }

  const rowId = Number.isInteger(result.rowId) ? result.rowId : null;
  const retrieved = rowId
    ? candidates.find((candidate) => candidate.rowId === rowId)
    : null;
  const selectedFood = retrieved ? foodSearchStore.inspect(rowId) : null;
  if (!selectedFood || !candidateCompatibleWithMention(trimmedMention, selectedFood)) {
    onEvent({ type: "rejected_pick", turn: 0, rowId, reason: "identity_mismatch" });
    const fallback = fallbackResolvedBody(trimmedMention, searchRounds);
    return fallback
      ? { status: 200, body: fallback }
      : { status: 422, body: { error: "no_matching_food" } };
  }

  const selection = {
    servings: boundedServings(result.servings, 1),
    portionDescription: typeof result.portionDescription === "string" && result.portionDescription.trim()
      ? result.portionDescription.trim()
      : "1 serving",
    servingUnit: typeof result.servingUnit === "string" && result.servingUnit.trim()
      ? result.servingUnit.trim()
      : "serving",
    confident: result.confident === true,
    hasExplicitPortion: result.hasExplicitPortion === true,
  };
  const deterministicServings = candidateServingRatio(selectedFood, selection.portionDescription);
  if (deterministicServings !== null) {
    selection.servings = deterministicServings;
  }
  if (selection.hasExplicitPortion) {
    selection.servingUnit = servingUnitFromPortion(
      selection.portionDescription,
      selection.servingUnit
    );
  }
  Object.assign(selection, applyCandidateDefaultServing(selectedFood, selection));
  const invariantFeedback = nutritionInvariantFeedback(trimmedMention, selectedFood, selection.servings);
  const provenanceFeedback = provenanceInvariantFeedback(trimmedMention, selectedFood, selection);
  const genericBrandFeedback = genericBrandInvariantFeedback(
    trimmedMention,
    selectedFood,
    selection,
    candidates
  );
  if (genericBrandFeedback) {
    const genericReference = authoritativeGenericReference(trimmedMention, candidates, selection);
    const genericSelection = selectionForAlternateCandidate(genericReference, selection);
    if (genericReference && genericSelection
        && !nutritionInvariantFeedback(trimmedMention, genericReference, genericSelection.servings)
        && !provenanceInvariantFeedback(trimmedMention, genericReference, genericSelection)) {
      onEvent({
        type: "substituted_pick",
        turn: 0,
        rejectedRowId: rowId,
        selectedRowId: genericReference.rowId,
        reason: "authoritative_generic_reference",
      });
      return { status: 200, body: resolvedBody(genericReference, genericSelection) };
    }
  }
  if (invariantFeedback || provenanceFeedback || genericBrandFeedback) {
    onEvent({
      type: "rejected_pick",
      turn: 0,
      rowId,
      reason: invariantFeedback
        ? "nutrition_invariant"
        : provenanceFeedback
          ? "provenance_invariant"
          : "generic_brand_invariant",
    });
    const fallback = fallbackResolvedBody(trimmedMention, searchRounds);
    return fallback
      ? { status: 200, body: fallback }
      : { status: 422, body: { error: "no_matching_food" } };
  }

  return { status: 200, body: resolvedBody(selectedFood, selection) };
}

module.exports = {
  FOOD_SELECTION_SCHEMA,
  applyCandidateDefaultServing,
  authoritativeGenericReference,
  candidateServingRatio,
  deterministicFallbackCandidate,
  explicitlyRequestedBrand,
  fallbackResolvedBody,
  genericBrandInvariantFeedback,
  candidateCompatibleWithMention,
  nutritionInvariantFeedback,
  provenanceInvariantFeedback,
  resolveFoodCandidate,
  renderFoodSearchRounds,
};
