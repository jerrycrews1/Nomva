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
      const source = candidate.source ? ` | source: ${candidate.source}` : "";
      const basis = candidate.portionBasis ? ` | basis: ${candidate.portionBasis}` : "";
      const calories = typeof candidate.caloriesPerServing === "number"
        ? ` | calories: ${Math.round(candidate.caloriesPerServing)}`
        : "";
      return `  rowId ${candidate.rowId}: ${candidate.name}${brand}${serving}${grams}${source}${basis}${calories}`;
    });
    return `${header}\n${candidateLines.join("\n")}`;
  }).join("\n\n");
}

function renderFoodInspections(inspections) {
  if (!inspections.length) {
    return "(no inspections yet)";
  }

  return inspections.map((food) => {
    const brand = food.brand ? `\n  brand: ${food.brand}` : "";
    const serving = food.servingDescription ? `\n  serving: ${food.servingDescription}` : "";
    const grams = typeof food.servingGrams === "number" ? `\n  serving_g: ${Math.round(food.servingGrams)}` : "";
    const source = food.source ? `\n  source: ${food.source}` : "";
    const basis = food.portionBasis ? `\n  basis: ${food.portionBasis}` : "";
    const calories = typeof food.caloriesPerServing === "number" ? `\n  calories_per_serving: ${Math.round(food.caloriesPerServing)}` : "";
    const macros = [
      typeof food.proteinG === "number" ? `${Math.round(food.proteinG)}g protein` : null,
      typeof food.carbsG === "number" ? `${Math.round(food.carbsG)}g carbs` : null,
      typeof food.fatG === "number" ? `${Math.round(food.fatG)}g fat` : null,
    ].filter(Boolean).join(", ");
    const macroLine = macros ? `\n  macros: ${macros}` : "";
    return `rowId ${food.rowId}: ${food.name}${brand}${serving}${grams}${source}${basis}${calories}${macroLine}`;
  }).join("\n\n");
}

function renderFoodVerifierFeedback(notes) {
  if (!notes.length) {
    return "(no verifier feedback yet)";
  }
  return notes.map((note, index) => `${index + 1}. ${note}`).join("\n");
}

function resolvedBody(selectedFood, verification) {
  return {
    candidateId: selectedFood.candidateId,
    rowId: selectedFood.rowId,
    name: selectedFood.name,
    brand: selectedFood.brand,
    source: selectedFood.source,
    servings: verification.servings,
    portionDescription: verification.portionDescription,
    servingUnit: verification.servingUnit,
    confident: verification.confident,
    hasExplicitPortion: verification.hasExplicitPortion,
  };
}

function normalizedTokens(value) {
  return new Set(String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .split(/\s+/)
    .filter(Boolean));
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
  foodSearchStore,
  askAgent,
  verifyPick,
  maxTurns = 5,
  onEvent = () => {},
}) {
  const trimmedMention = String(foodMention || "").trim();
  const searchRounds = [{
    query: trimmedMention,
    offset: 0,
    candidates: foodSearchStore.search(trimmedMention, { limit: 20, offset: 0 }),
  }];
  const inspections = [];
  const inspectedRows = new Map();
  const verifierFeedback = [];
  const seenSearches = new Set([`${trimmedMention.toLowerCase()}::0`]);

  for (let turn = 0; turn < maxTurns; turn += 1) {
    const userPrompt = [
      `User said: "${userMessage}"`,
      `Food mention: "${trimmedMention}"`,
      "",
      "Search rounds:",
      renderFoodSearchRounds(searchRounds),
      "",
      "Inspections:",
      renderFoodInspections(inspections),
      "",
      "Verifier feedback:",
      renderFoodVerifierFeedback(verifierFeedback),
    ].join("\n");

    const result = await askAgent(userPrompt);
    const action = String(result?.action || "").toLowerCase();
    onEvent({ type: "agent", turn, action, result, searchRoundCount: searchRounds.length });

    if (action === "search") {
      const query = typeof result.query === "string" ? result.query.trim() : "";
      const offset = Number.isInteger(result.offset) && result.offset >= 0 ? result.offset : 0;
      if (!query) {
        verifierFeedback.push("Invalid search action: query was missing.");
        continue;
      }

      if (searchRounds.length >= 3) {
        verifierFeedback.push(
          "The seeded search plus two reformulations are enough. Pick the best realistic row already returned or give up; do not search again."
        );
        continue;
      }

      const searchKey = `${query.toLowerCase()}::${offset}`;
      if (seenSearches.has(searchKey)) {
        verifierFeedback.push(`Search "${query}" with offset ${offset} was already tried.`);
        continue;
      }

      seenSearches.add(searchKey);
      searchRounds.push({
        query,
        offset,
        candidates: foodSearchStore.search(query, { limit: 20, offset }),
      });
      onEvent({ type: "search", turn, query, offset, candidateCount: searchRounds.at(-1).candidates.length });
      continue;
    }

    if (action === "inspect") {
      const rowId = Number.isInteger(result.rowId) ? result.rowId : null;
      if (!rowId) {
        verifierFeedback.push("Invalid inspect action: rowId was missing.");
        continue;
      }

      const seenInSearch = searchRounds.some((round) => round.candidates.some((candidate) => candidate.rowId === rowId));
      if (!seenInSearch && !inspectedRows.has(rowId)) {
        verifierFeedback.push(`Inspect rowId ${rowId} failed: use a rowId that appeared in the search results.`);
        continue;
      }

      if (!inspectedRows.has(rowId)) {
        const inspected = foodSearchStore.inspect(rowId);
        if (!inspected) {
          verifierFeedback.push(`Inspect rowId ${rowId} failed: row not found.`);
          continue;
        }
        inspectedRows.set(rowId, inspected);
        inspections.push(inspected);
      }
      continue;
    }

    if (action === "pick") {
      const rowId = Number.isInteger(result.rowId) ? result.rowId : null;
      const servings = typeof result.servings === "number" && result.servings > 0 ? result.servings : 1;
      const portionDescription = typeof result.portionDescription === "string" && result.portionDescription.trim()
        ? result.portionDescription.trim()
        : "1 serving";
      const servingUnit = typeof result.servingUnit === "string" && result.servingUnit.trim()
        ? result.servingUnit.trim()
        : "serving";
      const confident = result.confident === true;
      const hasExplicitPortion = result.hasExplicitPortion === true;

      if (!rowId) {
        verifierFeedback.push("Invalid pick action: rowId was missing.");
        continue;
      }

      const seenInSearch = searchRounds.some((round) => round.candidates.some((candidate) => candidate.rowId === rowId));
      if (!seenInSearch && !inspectedRows.has(rowId)) {
        verifierFeedback.push(`Pick rowId ${rowId} failed: use a rowId that appeared in the search results.`);
        continue;
      }

      const selectedFood = inspectedRows.get(rowId) || foodSearchStore.inspect(rowId);
      if (!selectedFood) {
        verifierFeedback.push(`Pick rowId ${rowId} failed: row not found.`);
        continue;
      }

      const verification = await verifyPick({
        userMessage,
        foodMention: trimmedMention,
        selectedFood,
        servings,
        portionDescription,
        servingUnit,
        confident,
        hasExplicitPortion,
      });
      onEvent({ type: "verification", turn, rowId, selectedName: selectedFood.name, verification });

      if (verification.accept) {
        const invariantFeedback = nutritionInvariantFeedback(
          trimmedMention,
          selectedFood,
          verification.servings
        );
        if (invariantFeedback) {
          verifierFeedback.push(invariantFeedback);
          continue;
        }
        return { status: 200, body: resolvedBody(selectedFood, verification) };
      }

      const noteParts = [verification.feedback || `Row ${rowId} was not a realistic nutrition basis for the mention.`];
      if (verification.retryQuery) {
        noteParts.push(`Suggested retry query: "${verification.retryQuery}".`);
      }
      verifierFeedback.push(noteParts.join(" "));
      continue;
    }

    if (action === "give_up") {
      if (searchRounds.length < 2) {
        verifierFeedback.push("Do not give up after only the seeded search. Try one materially different database query.");
        continue;
      }
      return { status: 422, body: { error: "no_matching_food" } };
    }

    verifierFeedback.push(`Invalid action "${action || "(missing)"}". Use search, inspect, pick, or give_up.`);
  }

  return { status: 503, body: { error: "food_resolution_failed" } };
}

module.exports = {
  nutritionInvariantFeedback,
  resolveFoodCandidate,
  renderFoodSearchRounds,
};
