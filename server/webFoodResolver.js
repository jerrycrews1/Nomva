const { boundedServings } = require("./numericGuards");
const { foodTokens, normalizeFoodText } = require("./foodKnowledgeStore");

const MENU_CUE = /\b(from|at|restaurant|cafe|coffee shop|menu|short|tall|grande|venti|trenta)\b/i;
const COMPOSITE_CUE = /\b(with|topped|filled|made with|including)\b/i;
const CRITICAL_IDENTITY_TOKENS = new Set([
  "zero", "diet", "decaf", "iced", "hot", "short", "tall", "grande", "venti", "trenta",
]);

function finiteNumber(value) {
  if (value === null || value === undefined || typeof value === "boolean") return null;
  if (typeof value === "string" && !value.trim()) return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function boundedText(value, maxLength = 500) {
  const text = String(value || "").trim();
  return text ? text.slice(0, maxLength) : null;
}

function validPublicURL(value) {
  try {
    const url = new URL(String(value || ""));
    if (!['http:', 'https:'].includes(url.protocol)) return null;
    const hostname = url.hostname.toLowerCase();
    if (!hostname || hostname === "localhost" || hostname.endsWith(".local")) return null;
    if (["::1", "[::1]"].includes(hostname) || /^\[?(?:fc|fd|fe8|fe9|fea|feb)/i.test(hostname)) return null;
    if (/^(127\.|10\.|192\.168\.|169\.254\.)/.test(hostname)) return null;
    if (/^172\.(1[6-9]|2\d|3[01])\./.test(hostname)) return null;
    return url.toString().slice(0, 1_000);
  } catch {
    return null;
  }
}

function numericWithin(value, min, max) {
  const number = finiteNumber(value);
  return number !== null && number >= min && number <= max ? number : null;
}

function sanitizeAliases(value) {
  if (!Array.isArray(value)) return [];
  return [...new Set(value
    .map((alias) => boundedText(alias, 180))
    .filter(Boolean))]
    .slice(0, 20);
}

function singularToken(token) {
  if (token.endsWith("ies") && token.length > 3) return `${token.slice(0, -3)}y`;
  if (token.endsWith("s") && token.length > 3 && !token.endsWith("ss")) return token.slice(0, -1);
  return token;
}

function tokensEquivalent(left, right) {
  const singularLeft = singularToken(left);
  const singularRight = singularToken(right);
  if (singularLeft === singularRight) return true;
  if (Math.abs(singularLeft.length - singularRight.length) > 1) return false;

  let edits = 0;
  let leftIndex = 0;
  let rightIndex = 0;
  while (leftIndex < singularLeft.length && rightIndex < singularRight.length) {
    if (singularLeft[leftIndex] === singularRight[rightIndex]) {
      leftIndex += 1;
      rightIndex += 1;
      continue;
    }
    edits += 1;
    if (edits > 1) return false;
    if (singularLeft.length > singularRight.length) leftIndex += 1;
    else if (singularRight.length > singularLeft.length) rightIndex += 1;
    else {
      leftIndex += 1;
      rightIndex += 1;
    }
  }
  return edits + (leftIndex < singularLeft.length || rightIndex < singularRight.length ? 1 : 0) <= 1;
}

function identityMatchesMention(foodMention, candidate) {
  const mentionTokens = [...new Set(foodTokens(foodMention).map(singularToken))];
  const aliases = Array.isArray(candidate?.aliases) ? candidate.aliases.join(" ") : "";
  const primaryTokens = [...new Set(
    foodTokens(`${candidate?.brand || ""} ${candidate?.name || ""}`).map(singularToken)
  )];
  const candidateTokens = [...new Set(
    [...primaryTokens, ...foodTokens(aliases).map(singularToken)]
  )];
  if (!mentionTokens.length || !candidateTokens.length) return false;

  const matched = mentionTokens.filter((mentionToken) => (
    candidateTokens.some((candidateToken) => tokensEquivalent(mentionToken, candidateToken))
  ));
  const requiredCoverage = mentionTokens.length <= 2 ? 1 : 0.67;
  if (matched.length / mentionTokens.length < requiredCoverage) return false;

  return mentionTokens
    .filter((token) => CRITICAL_IDENTITY_TOKENS.has(token))
    .every((token) => primaryTokens.some((candidateToken) => tokensEquivalent(token, candidateToken)));
}

function sanitizeWebFoodResult(raw) {
  if (!raw || raw.found !== true) return null;
  const name = boundedText(raw.name, 180);
  const sourceUrl = validPublicURL(raw.sourceUrl);
  const quality = raw.quality === "published"
    ? "published"
    : raw.quality === "estimated"
      ? "estimated"
      : null;
  const calories = numericWithin(raw.caloriesPerServing, 0, 5_000);
  const protein = numericWithin(raw.proteinG, 0, 500);
  const carbs = numericWithin(raw.carbsG, 0, 1_000);
  const fat = numericWithin(raw.fatG, 0, 500);
  const fiber = numericWithin(raw.fiberG, 0, 250);
  if (!name || !sourceUrl || !quality || calories === null || protein === null
      || carbs === null || fat === null || fiber === null) {
    return null;
  }

  const macroCalories = (protein * 4) + (carbs * 4) + (fat * 9);
  const allowedDifference = Math.max(120, calories * 0.45);
  if (Math.abs(macroCalories - calories) > allowedDifference) return null;
  if (calories <= 10 && macroCalories > 30) return null;

  const rawConfidence = numericWithin(raw.confidence, 0, 1) ?? 0;
  const confidence = quality === "estimated" ? Math.min(rawConfidence, 0.89) : rawConfidence;
  if (quality === "published" && confidence < 0.65) return null;
  if (quality === "estimated" && confidence < 0.5) return null;

  const servingGrams = raw.servingGrams === null
    ? null
    : numericWithin(raw.servingGrams, 1, 5_000);
  const sugar = raw.sugarG === null ? 0 : numericWithin(raw.sugarG, 0, 1_000);
  const sodium = raw.sodiumMg === null ? 0 : numericWithin(raw.sodiumMg, 0, 20_000);
  if (raw.servingGrams !== null && servingGrams === null) return null;
  if (raw.sugarG !== null && sugar === null) return null;
  if (raw.sodiumMg !== null && sodium === null) return null;

  return {
    name,
    brand: boundedText(raw.brand, 120),
    aliases: sanitizeAliases(raw.aliases),
    servingDescription: boundedText(raw.servingDescription, 180) || "1 serving",
    servingGrams,
    caloriesPerServing: calories,
    proteinG: protein,
    carbsG: carbs,
    fatG: fat,
    fiberG: fiber,
    sugarG: sugar || 0,
    sodiumMg: sodium || 0,
    quality,
    confidence,
    sourceUrl,
    sourceTitle: boundedText(raw.sourceTitle, 300),
    evidence: boundedText(raw.notes, 1_500),
  };
}

function inferredServingCount(text) {
  const normalized = normalizeFoodText(text);
  const numeric = normalized.match(/^(\d+(?:\.\d+)?)\b/);
  if (numeric) {
    const next = normalized.slice(numeric[0].length).trim().split(" ")[0];
    if (!["oz", "ounce", "ounces", "g", "gram", "grams", "ml", "liter", "liters"].includes(next)) {
      return boundedServings(Number(numeric[1]), 1);
    }
  }
  const words = { one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10 };
  const first = normalized.split(" ")[0];
  return words[first] || 1;
}

function inferredServingUnit(candidate) {
  const text = normalizeFoodText(`${candidate.name} ${candidate.servingDescription}`);
  for (const unit of ["bowl", "drink", "sandwich", "burger", "taco", "slice", "piece", "serving"]) {
    if (text.includes(unit)) return unit;
  }
  return "serving";
}

function resolvedCandidateBody(candidate, consumption = {}) {
  const servings = boundedServings(consumption.servings, 1);
  const unit = boundedText(consumption.servingUnit, 80) || inferredServingUnit(candidate);
  const portionDescription = boundedText(consumption.portionDescription, 180)
    || (servings === 1 ? candidate.servingDescription : `${servings} ${unit}s`);
  return {
    candidateId: candidate.candidateId,
    rowId: candidate.rowId,
    name: candidate.name,
    brand: candidate.brand || null,
    source: candidate.source || null,
    servings,
    portionDescription,
    servingUnit: unit,
    confident: typeof consumption.confident === "boolean"
      ? consumption.confident
      : candidate.quality === "published" && candidate.confidence >= 0.8,
    hasExplicitPortion: consumption.hasExplicitPortion === true,
    servingGrams: finiteNumber(candidate.servingGrams),
    servingDescription: candidate.servingDescription || "1 serving",
    caloriesPerServing: finiteNumber(candidate.caloriesPerServing),
    proteinG: finiteNumber(candidate.proteinG),
    carbsG: finiteNumber(candidate.carbsG),
    fatG: finiteNumber(candidate.fatG),
    fiberG: finiteNumber(candidate.fiberG),
    sugarG: finiteNumber(candidate.sugarG),
    sodiumMg: finiteNumber(candidate.sodiumMg),
    portionBasis: candidate.portionBasis || "fixed_serving",
    quality: candidate.quality || null,
    confidence: finiteNumber(candidate.confidence),
    sourceUrl: candidate.sourceUrl || null,
    sourceTitle: candidate.sourceTitle || null,
    evidence: candidate.evidence || null,
  };
}

function webFoodSchema() {
  const nullableNumber = { type: ["number", "null"] };
  return {
    type: "object",
    additionalProperties: false,
    required: [
      "found", "name", "brand", "aliases", "servingDescription", "servingGrams",
      "caloriesPerServing", "proteinG", "carbsG", "fatG", "fiberG", "sugarG",
      "sodiumMg", "quality", "confidence", "sourceUrl", "sourceTitle", "notes",
      "servings", "portionDescription", "servingUnit", "hasExplicitPortion",
    ],
    properties: {
      found: { type: "boolean" },
      name: { type: "string" },
      brand: { type: "string" },
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
      quality: { type: "string", enum: ["published", "estimated", "none"] },
      confidence: { type: "number", minimum: 0, maximum: 1 },
      sourceUrl: { type: "string" },
      sourceTitle: { type: "string" },
      notes: { type: "string" },
      servings: { type: "number", minimum: 0.1, maximum: 100 },
      portionDescription: { type: "string" },
      servingUnit: { type: "string" },
      hasExplicitPortion: { type: "boolean" },
    },
  };
}

function createWebFoodResolver({
  openai,
  knowledgeStore,
  model = "gpt-5.6-luna",
  searchTool = "web_search_preview",
  searchContextSize = "medium",
  onEvent = () => {},
}) {
  async function resolve({ userMessage = "", foodMention, signal, allowCached = true }) {
    const mention = boundedText(foodMention, 220);
    if (!mention) return null;

    if (allowCached) {
      const cached = knowledgeStore.search(mention, { limit: 1, minimumScore: 700 })[0];
      if (cached && identityMatchesMention(mention, cached)) {
        knowledgeStore.noteHit(cached.candidateId);
        const servings = inferredServingCount(mention);
        return resolvedCandidateBody(cached, {
          servings,
          portionDescription: mention,
          servingUnit: inferredServingUnit(cached),
          confident: cached.quality === "published" && cached.confidence >= 0.8,
          hasExplicitPortion: servings !== 1 || MENU_CUE.test(mention),
        });
      }
      if (knowledgeStore.hasFreshMiss(mention)) return null;
    }

    const startedAt = Date.now();
    const instructions = [
      "Resolve exactly one food or drink the user consumed using current public web sources.",
      "Search before answering. Prefer the restaurant, manufacturer, or official nutrition document.",
      "The source URL must directly support the exact nutrition used, or the exact menu item and ingredients used for an estimate; do not cite a generic home page.",
      "Keep nutrition PER ONE ordered menu serving; represent how many the user ate separately in servings.",
      "Preserve stated brand, restaurant, size, preparation, milk, flavor, and modifiers. Never substitute another product.",
      "Include the requested menu size or variant in the canonical food name so different sizes remain distinct catalog entries.",
      "Use quality=published only when a source explicitly publishes nutrition for that exact item and size.",
      "If the exact menu item and ingredients are published but nutrition is not, estimate from those ingredients, set quality=estimated, and state portion assumptions in notes.",
      "If identity, serving, source, or a defensible estimate cannot be established, return found=false and quality=none.",
      "Calories and macros must describe the same serving and reconcile arithmetically.",
    ].join(" ");
    const input = [
      `Full user message: "${boundedText(userMessage, 500) || mention}"`,
      `Food mention to resolve: "${mention}"`,
    ].join("\n");

    let response;
    try {
      response = await openai.responses.create({
        model,
        reasoning: { effort: "low" },
        tools: [{ type: searchTool, search_context_size: searchContextSize }],
        tool_choice: { type: searchTool },
        instructions,
        input,
        max_output_tokens: 1_200,
        text: {
          format: {
            type: "json_schema",
            name: "nomva_web_food",
            strict: true,
            schema: webFoodSchema(),
          },
        },
      }, signal ? { signal } : undefined);
    } catch (error) {
      onEvent({ type: "error", model, durationMs: Date.now() - startedAt, error });
      throw error;
    }

    let raw;
    try {
      raw = JSON.parse(response.output_text || "{}");
    } catch {
      onEvent({ type: "invalid_json", model, durationMs: Date.now() - startedAt, usage: response.usage });
      return null;
    }
    const sanitized = sanitizeWebFoodResult(raw);
    if (!sanitized) {
      if (raw?.found === false) knowledgeStore.rememberMiss(mention);
      onEvent({ type: "no_match", model, durationMs: Date.now() - startedAt, usage: response.usage });
      return null;
    }
    if (!identityMatchesMention(mention, sanitized)) {
      onEvent({ type: "identity_mismatch", model, durationMs: Date.now() - startedAt, usage: response.usage });
      return null;
    }

    const candidate = knowledgeStore.upsert(sanitized, [mention]);
    onEvent({
      type: "resolved",
      model,
      quality: candidate.quality,
      durationMs: Date.now() - startedAt,
      usage: response.usage,
    });
    return resolvedCandidateBody(candidate, {
      servings: boundedServings(raw.servings, inferredServingCount(mention)),
      portionDescription: boundedText(raw.portionDescription, 180) || mention,
      servingUnit: boundedText(raw.servingUnit, 80) || inferredServingUnit(candidate),
      confident: candidate.quality === "published" && candidate.confidence >= 0.8,
      hasExplicitPortion: raw.hasExplicitPortion === true,
    });
  }

  return { resolve };
}

function shouldTryWebFirst(foodMention, candidates = []) {
  const mention = String(foodMention || "");
  const meaningfulCount = normalizeFoodText(mention).split(" ").filter(Boolean).length;
  return MENU_CUE.test(mention)
    || (COMPOSITE_CUE.test(mention) && meaningfulCount >= 3)
    || (candidates.length === 0 && meaningfulCount >= 2);
}

module.exports = {
  createWebFoodResolver,
  identityMatchesMention,
  inferredServingCount,
  resolvedCandidateBody,
  sanitizeWebFoodResult,
  shouldTryWebFirst,
  validPublicURL,
  webFoodSchema,
};
