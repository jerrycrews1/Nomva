const fs = require("fs");
const path = require("path");
const { canonicalFoodToken, canonicalFoodTokenSet } = require("./foodTokenNormalizer");

const FOOD_COLUMNS = `
  f.id, f.fdc_id, f.name, IFNULL(f.brand, '') AS brand, f.source,
  IFNULL(f.search_terms, '') AS search_terms,
  f.serving_g, IFNULL(f.serving_desc, '') AS serving_desc,
  f.calories, f.protein_g, f.carbs_g, f.fat_g, f.fiber_g,
  f.sugar_g, f.sodium_mg,
  f.saturated_fat_g, f.trans_fat_g, f.cholesterol_mg, f.added_sugar_g,
  f.vitamin_d_mcg, f.calcium_mg, f.iron_mg, f.potassium_mg,
  f.vitamin_a_mcg_rae, f.vitamin_c_mg, f.vitamin_b12_mcg,
  f.folate_mcg_dfe, f.magnesium_mg, f.zinc_mg, IFNULL(f.barcode, '') AS barcode,
  IFNULL(f.portion_basis, 'grams') AS portion_basis, IFNULL(f.serving_source, '') AS serving_source,
  f.default_serving_g, IFNULL(f.default_serving_desc, '') AS default_serving_desc,
  IFNULL(f.default_serving_source, '') AS default_serving_source
`;

function tokenize(text) {
  return String(text || "")
    .toLowerCase()
    .replaceAll("%", "")
    .split(/[^a-z0-9]+/i)
    .map((token) => token.trim())
    .filter(Boolean);
}

function singularize(token) {
  return canonicalFoodToken(token);
}

const SEARCH_NOISE_TOKENS = new Set([
  "a", "an", "the", "some", "about", "approximately", "around",
  "i", "my", "had", "ate", "drank", "log", "please",
  "for", "at", "during", "meal", "breakfast", "lunch", "dinner", "snack",
  "side", "of", "served", "serving", "servings", "portion", "portions",
  "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
  "half", "quarter", "dozen", "fl", "fluid", "oz", "ounce", "ounces", "g", "gram",
  "grams", "kg", "ml", "milliliter", "milliliters", "l", "liter", "liters", "lb",
  "lbs", "pound", "pounds", "cup", "cups", "tablespoon", "tablespoons", "tbsp",
  "teaspoon", "teaspoons", "tsp",
]);

const REQUIRED_IDENTITY_TOKENS = canonicalFoodTokenSet([
  "zero", "diet", "sugarfree", "unsweetened", "sweetened", "decaf", "plain",
  "iced", "hot", "grilled", "fried", "raw", "cooked", "roasted", "smoked",
  "vegan", "vegetarian", "nonfat", "lowfat", "skim",
  "chicken", "beef", "pork", "fish", "turkey", "lamb", "duck", "goose", "quail", "venison",
  "small", "medium", "large", "short", "tall", "grande", "venti", "trenta",
]);

const PORTION_SIZE_TOKENS = canonicalFoodTokenSet([
  "small", "medium", "large", "short", "tall", "grande", "venti", "trenta",
]);

const UNEXPECTED_VARIANT_TOKENS = canonicalFoodTokenSet([
  "zero", "diet", "sugarfree", "unsweetened", "sweetened", "decaf",
  "iced", "hot", "grilled", "fried", "roasted", "smoked",
  "vegan", "vegetarian", "nonfat", "lowfat", "skim",
  "duck", "goose", "quail", "turkey", "venison", "lamb",
  "powder", "powdered", "liquid", "frozen", "dried", "dehydrated",
  "canned",
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

const BRAND_NOISE_TOKENS = canonicalFoodTokenSet([
  ...SEARCH_NOISE_TOKENS,
  ...REQUIRED_IDENTITY_TOKENS,
  "brand", "company", "corporation", "corp", "inc", "llc", "ltd", "foods",
  "food", "co", "the",
]);

// These describe a reference row without adding a distinct ingredient or
// product identity. Other unrequested name tokens represent extra specificity,
// so a meat salad or flavored oatmeal cannot beat the plain base food merely
// because both share one broad word.
const NEUTRAL_REFERENCE_TOKENS = canonicalFoodTokenSet([
  "nfs", "ns", "as", "to", "of", "with", "and", "or", "type", "form", "whole", "mixed", "raw",
  "cooked", "fresh", "regular", "plain", "generic", "green", "fish",
  "cheese", "fruit", "vegetable", "meat", "food",
]);

function isPortionToken(token) {
  return /^\d+(?:\.\d+)?$/.test(token)
    || /^\d+(?:\.\d+)?(?:oz|ounce|ounces|g|gram|grams|kg|ml|l|lb|lbs)$/.test(token);
}

function meaningfulSearchTokens(query) {
  return tokenize(query).filter((token) => !SEARCH_NOISE_TOKENS.has(token) && !isPortionToken(token));
}

function identitySearchTokens(query) {
  const contentTokens = meaningfulSearchTokens(query);
  const identityTokens = contentTokens.filter((token) => !PORTION_SIZE_TOKENS.has(token));
  return identityTokens.length ? identityTokens : contentTokens;
}

function searchVariants(query) {
  const original = String(query || "").trim();
  const contentTokens = meaningfulSearchTokens(original);
  const variants = [original, contentTokens.join(" ")];

  // Nutrition catalogs usually name ordinary toast as bread plus a toasted
  // preparation. Searching the equivalent bread form prevents unrelated
  // products whose names merely contain "toast" from owning the result set.
  if (contentTokens.includes("toast")) {
    variants.push(contentTokens.map((token) => token === "toast" ? "bread" : token).join(" "));
  }

  // A descriptive modifier may not exist in the database even though the base
  // food is a valid nutritional equivalent. Search every one-token relaxation
  // and let the LLM decide which returned row preserves the user's meaning.
  if (contentTokens.length >= 2 && contentTokens.length <= 8) {
    for (let omitted = 0; omitted < contentTokens.length; omitted += 1) {
      variants.push(contentTokens.filter((_, index) => index !== omitted).join(" "));
    }
  }

  const unique = [];
  const seen = new Set();
  for (const variant of variants) {
    const normalized = String(variant || "").trim();
    const key = normalized.toLowerCase();
    if (normalized && !seen.has(key)) {
      seen.add(key);
      unique.push(normalized);
    }
  }
  return unique;
}

function rowTokens(row) {
  return tokenize(
    `${row?.name || ""} ${row?.brand || ""} ${row?.servingDescription || row?.serving_desc || ""}`
  ).map(singularize);
}

function isAuthoritativeReferenceSource(source) {
  return ["foundation", "survey_fndds", "sr_legacy"].includes(String(source || ""));
}

function explicitlyRequestedBrand(row, originalQuery) {
  if (!row?.brand) return false;
  const queryTokens = new Set(meaningfulSearchTokens(originalQuery).map(singularize));
  const nameTokens = new Set(tokenize(row.name || "").map(singularize));
  const brandOnlyTokens = tokenize(row.brand)
    .map(singularize)
    .filter((token) => !nameTokens.has(token) && !BRAND_NOISE_TOKENS.has(token));
  return brandOnlyTokens.length > 0
    && brandOnlyTokens.some((token) => queryTokens.has(token));
}

function nutritionContradictsCalories(row) {
  const calories = Number(row?.caloriesPerServing ?? row?.calories);
  const protein = Number(row?.proteinG ?? row?.protein_g);
  const carbs = Number(row?.carbsG ?? row?.carbs_g);
  const fat = Number(row?.fatG ?? row?.fat_g);
  if (![calories, protein, carbs, fat].every(Number.isFinite)) return false;
  const macroCalories = (protein * 4) + (carbs * 4) + (fat * 9);
  return macroCalories >= 20 && calories + 20 < macroCalories * 0.55;
}

function hasNaturalServingDescription(row) {
  const serving = String(row?.servingDescription || row?.serving_desc || "").toLowerCase();
  return /\b(cups?|tablespoons?|tbsp|teaspoons?|tsp|pieces?|slices?|bottles?|cans?|bars?|packages?|packets?|containers?|sandwich(?:es)?|nuggets?|meatballs?|patt(?:y|ies)|bowls?|glasses|fruit)\b/.test(serving);
}

function candidateSatisfiesQueryToken(queryToken, candidateTokens) {
  return candidateTokens.has(queryToken)
    || (queryToken === "toast" && candidateTokens.has("bread"));
}

function candidateTokenIsRequested(candidateToken, queryTokens) {
  return queryTokens.has(candidateToken)
    || (candidateToken === "bread" && queryTokens.has("toast"));
}

function scoreFoodRow(row, originalQuery) {
  const contentTokenList = meaningfulSearchTokens(originalQuery).map(singularize);
  const queryTokenList = identitySearchTokens(originalQuery).map(singularize);
  const queryTokens = new Set(queryTokenList);
  const candidateTokenList = rowTokens(row);
  const candidateTokens = new Set(candidateTokenList);
  const nameTokens = tokenize(row?.name || "").map(singularize);
  const rawName = String(row?.name || "").trim().toLowerCase();
  const name = tokenize(row?.name || "").map(singularize).join(" ");
  const normalizedQuery = queryTokenList.join(" ");
  const semanticName = nameTokens
    .map((token) => token === "bread" && queryTokens.has("toast") ? "toast" : token)
    .join(" ");
  const matchedTokens = [...queryTokens].filter((token) => candidateSatisfiesQueryToken(token, candidateTokens));
  const coverage = queryTokens.size ? matchedTokens.length / queryTokens.size : 0;
  let score = 0;

  score += matchedTokens.length * 30;
  score += Math.round(coverage * 140);
  if (queryTokens.size && matchedTokens.length === queryTokens.size) {
    score += 80;
  }
  const requestedSizes = contentTokenList.filter((token) => PORTION_SIZE_TOKENS.has(token));
  score += requestedSizes.filter((token) => candidateTokens.has(token)).length * 20;

  if (name === normalizedQuery || semanticName === normalizedQuery) {
    score += 240;
  } else if (normalizedQuery && rawName.startsWith(`${normalizedQuery},`)) {
    // A comma normally introduces preparation or state details ("corn, raw"),
    // while a space often creates a different food ("corn dog"). Preserve that
    // distinction after tokenization so broad food queries stay literal.
    score += 100;
  } else if (normalizedQuery && name.startsWith(`${normalizedQuery} `)) {
    score += 100;
  } else if (queryTokenList.length >= 2 && queryTokenList.length <= 8) {
    // Reward an exact base-product name when one optional descriptor (usually
    // a flavor) is absent. Required identity modifiers can never be relaxed.
    const hasExactSafeRelaxation = queryTokenList.some((token, index) => {
      if (REQUIRED_IDENTITY_TOKENS.has(token)) return false;
      return queryTokenList.filter((_, tokenIndex) => tokenIndex !== index).join(" ") === name;
    });
    if (hasExactSafeRelaxation) score += 180;
  }

  const includesIndex = rawName.indexOf("(includes ");
  if (includesIndex >= 0) {
    const primaryNameTokens = new Set(
      tokenize(rawName.slice(0, includesIndex)).map(singularize)
    );
    const includedOnlyMatches = queryTokenList.filter((token) => (
      !candidateSatisfiesQueryToken(token, primaryNameTokens)
      && candidateSatisfiesQueryToken(token, candidateTokens)
    ));
    score -= includedOnlyMatches.length * 180;
  }

  for (let index = 0; index < queryTokenList.length - 1; index += 1) {
    const left = queryTokenList[index];
    const right = queryTokenList[index + 1];
    for (let candidateIndex = 0; candidateIndex < candidateTokenList.length - 1; candidateIndex += 1) {
      if (candidateTokenList[candidateIndex] === left && candidateTokenList[candidateIndex + 1] === right) {
        score += 40;
        break;
      }
    }
  }

  const unmatchedNameTokens = nameTokens.filter((token) => !candidateTokenIsRequested(token, queryTokens));
  score -= Math.min(unmatchedNameTokens.length * 10, 120);
  const unrequestedSpecificTokens = unmatchedNameTokens.filter((token) => (
    !NEUTRAL_REFERENCE_TOKENS.has(token)
      && !/^\d+$/.test(token)
  ));
  if (isAuthoritativeReferenceSource(row?.source)) {
    score -= Math.min(unrequestedSpecificTokens.length * 45, 180);
  }
  if ((nameTokens.includes("no") || nameTokens.includes("without"))
      && !queryTokens.has("no")
      && !queryTokens.has("without")) {
    // An unrequested exclusion is a materially different product, even when
    // every positive query token matches (for example, a dish "with no bun").
    score -= 260;
  }
  const primarySearchTerm = String(row?.searchTerms || row?.search_terms || "")
    .split("|")[0]
    .trim()
    .toLowerCase();
  if (isAuthoritativeReferenceSource(row?.source)
      && normalizedQuery
      && tokenize(primarySearchTerm).map(singularize).join(" ") === normalizedQuery) {
    // FNDDS aliases begin with the food's survey category. This is useful for
    // retrieval ranking, but it is deliberately not treated as identity by the
    // resolver's safety checks.
    score += 130;
  }
  const explicitlyUnspecifiedType = /\b(?:nfs|ns)\s+as\s+to\s+(?:type|kind)\b/i.test(rawName);
  if ((nameTokens.includes("nfs") || nameTokens.includes("ns"))
      && !queryTokens.has("nfs")
      && !queryTokens.has("ns")
      && (unrequestedSpecificTokens.length === 0
        || (explicitlyUnspecifiedType && unrequestedSpecificTokens.length <= 1))) {
    score += 150;
  }

  for (const modifier of REQUIRED_IDENTITY_TOKENS) {
    if (queryTokens.has(modifier) && !candidateSatisfiesQueryToken(modifier, candidateTokens)) {
      score -= 320;
    }
  }
  for (const missing of queryTokenList.filter((token) => !candidateSatisfiesQueryToken(token, candidateTokens))) {
    if (!REQUIRED_IDENTITY_TOKENS.has(missing)) {
      score -= queryTokenList.length <= 2 ? 220 : 80;
    }
  }
  for (const variant of UNEXPECTED_VARIANT_TOKENS) {
    const index = nameTokens.indexOf(variant);
    const negated = index > 0 && ["no", "without"].includes(nameTokens[index - 1]);
    if (candidateTokens.has(variant) && !candidateTokenIsRequested(variant, queryTokens) && !negated) {
      score -= 300;
    }
  }

  const brandWasRequested = explicitlyRequestedBrand(row, originalQuery);
  if (!row?.brand) {
    score += 8;
  } else {
    score += brandWasRequested ? 90 : -180;
  }
  const source = String(row?.source || "");
  if (source === "foundation") {
    score += 280;
  } else if (source === "survey_fndds") {
    score += 260;
  } else if (source.includes("sr_legacy")) {
    score += 200;
  }
  if (source === "web_published") {
    score += brandWasRequested ? 100 : -170;
  } else if (source === "web_estimate") {
    score += brandWasRequested ? 50 : -220;
  } else if (source === "open_food_facts") {
    // Open Food Facts is valuable for an explicitly named package, but a
    // crowdsourced package row is a weak default for an ordinary generic food.
    // In particular, package nutrition often describes an uncooked 100 g basis.
    score += brandWasRequested ? 35 : -170;
  }
  if (nutritionContradictsCalories(row)) score -= 500;
  if (String(row?.portionBasis || row?.portion_basis || "") === "grams") {
    score += 5;
  }
  if (hasNaturalServingDescription(row)) {
    score += 45;
  }

  return score;
}

function buildMatchQuery(query) {
  const tokens = tokenize(query);
  if (!tokens.length) {
    return "";
  }
  if (tokens.length === 1) {
    return `${tokens[0]}*`;
  }
  const phrase = tokens.join(" ");
  const allTerms = tokens.map((token) => `${token}*`).join(" AND ");
  return `"${phrase}" OR ${allTerms}`;
}

function resolveFoodsDbPath(customPath) {
  const candidates = [
    customPath,
    process.env.FOODS_DB_PATH,
    path.join(__dirname, "..", "Nomva", "Resources", "foods.sqlite"),
    path.join(__dirname, "..", "Resources", "foods.sqlite"),
  ].filter(Boolean);

  return candidates.find((candidatePath) => fs.existsSync(candidatePath)) || null;
}

function formatFoodRow(row) {
  if (!row) {
    return null;
  }

  return {
    rowId: row.id,
    candidateId: `db_${row.id}`,
    fdcId: row.fdc_id ?? null,
    name: row.name,
    brand: row.brand || null,
    source: row.source || null,
    searchTerms: row.search_terms || null,
    servingGrams: typeof row.serving_g === "number" ? row.serving_g : null,
    servingDescription: row.serving_desc || null,
    caloriesPerServing: typeof row.calories === "number" ? row.calories : null,
    proteinG: typeof row.protein_g === "number" ? row.protein_g : null,
    carbsG: typeof row.carbs_g === "number" ? row.carbs_g : null,
    fatG: typeof row.fat_g === "number" ? row.fat_g : null,
    fiberG: typeof row.fiber_g === "number" ? row.fiber_g : null,
    sugarG: typeof row.sugar_g === "number" ? row.sugar_g : null,
    sodiumMg: typeof row.sodium_mg === "number" ? row.sodium_mg : null,
    saturatedFatG: typeof row.saturated_fat_g === "number" ? row.saturated_fat_g : null,
    transFatG: typeof row.trans_fat_g === "number" ? row.trans_fat_g : null,
    cholesterolMg: typeof row.cholesterol_mg === "number" ? row.cholesterol_mg : null,
    addedSugarG: typeof row.added_sugar_g === "number" ? row.added_sugar_g : null,
    vitaminDMcg: typeof row.vitamin_d_mcg === "number" ? row.vitamin_d_mcg : null,
    calciumMg: typeof row.calcium_mg === "number" ? row.calcium_mg : null,
    ironMg: typeof row.iron_mg === "number" ? row.iron_mg : null,
    potassiumMg: typeof row.potassium_mg === "number" ? row.potassium_mg : null,
    vitaminAMcgRAE: typeof row.vitamin_a_mcg_rae === "number" ? row.vitamin_a_mcg_rae : null,
    vitaminCMg: typeof row.vitamin_c_mg === "number" ? row.vitamin_c_mg : null,
    vitaminB12Mcg: typeof row.vitamin_b12_mcg === "number" ? row.vitamin_b12_mcg : null,
    folateMcgDFE: typeof row.folate_mcg_dfe === "number" ? row.folate_mcg_dfe : null,
    magnesiumMg: typeof row.magnesium_mg === "number" ? row.magnesium_mg : null,
    zincMg: typeof row.zinc_mg === "number" ? row.zinc_mg : null,
    barcode: row.barcode || null,
    portionBasis: row.portion_basis || "grams",
    servingSource: row.serving_source || null,
    defaultServingGrams: typeof row.default_serving_g === "number" ? row.default_serving_g : null,
    defaultServingDescription: row.default_serving_desc || null,
    defaultServingSource: row.default_serving_source || null,
  };
}

function createFoodSearchStore(options = {}) {
  const learnedStore = options.learnedStore || null;
  let Database;
  try {
    Database = require("better-sqlite3");
  } catch (error) {
    return {
      isAvailable: false,
      dbPath: null,
      error: error.message,
      search() {
        return [];
      },
      inspect() {
        return null;
      },
    };
  }

  const dbPath = resolveFoodsDbPath(options.dbPath);
  if (!dbPath) {
    return {
      isAvailable: false,
      dbPath: null,
      error: "foods.sqlite not found",
      search() {
        return [];
      },
      inspect() {
        return null;
      },
    };
  }

  let db;
  try {
    db = new Database(dbPath, { readonly: true, fileMustExist: true });
    db.pragma("query_only = ON");
  } catch (error) {
    return {
      isAvailable: false,
      dbPath,
      error: error.message,
      search() {
        return [];
      },
      inspect() {
        return null;
      },
    };
  }

  // Schema self-check at boot. A stale foods.sqlite (e.g. the pre-31-column
  // build) opens successfully and only fails when the first user query runs,
  // turning a packaging mistake into a total silent food-search outage. Probe
  // the newest columns and the FTS index now so a bad file is refused loudly.
  let rowCount = null;
  try {
    db.prepare("SELECT saturated_fat_g, vitamin_b12_mcg, portion_basis, search_terms, default_serving_g FROM foods LIMIT 1").get();
    db.prepare("SELECT rowid, search_terms FROM foods_fts LIMIT 1").get();
    rowCount = db.prepare("SELECT COUNT(*) AS n FROM foods").get()?.n ?? null;
    if (!rowCount) {
      throw new Error("foods table is empty");
    }
  } catch (error) {
    try { db.close(); } catch { /* ignore */ }
    return {
      isAvailable: false,
      dbPath,
      error: `foods.sqlite failed schema check (stale or truncated build?): ${error.message}`,
      search() {
        return [];
      },
      inspect() {
        return null;
      },
    };
  }

  function searchOne(query, { limit = 120 } = {}) {
    const trimmed = String(query || "").trim();
    const matchQuery = buildMatchQuery(trimmed);
    const tokens = tokenize(trimmed);
    if (!trimmed || !tokens.length || !matchQuery) {
      return [];
    }

    const whereClause = tokens
      .map(() => "(lower(f.name) LIKE ? OR lower(IFNULL(f.brand, '')) LIKE ? OR lower(IFNULL(f.search_terms, '')) LIKE ?)")
      .join(" AND ");

    const strictSql = `
      SELECT ${FOOD_COLUMNS}
      FROM foods f
      JOIN foods_fts ON foods_fts.rowid = f.id
      WHERE foods_fts MATCH ?
      ORDER BY bm25(foods_fts, 12.0, 3.0, 1.5) ASC, LENGTH(f.name) ASC, f.id ASC
      LIMIT ?
    `;

    const referenceSql = `
      SELECT ${FOOD_COLUMNS}
      FROM foods f
      JOIN foods_fts ON foods_fts.rowid = f.id
      WHERE foods_fts MATCH ?
        AND f.source IN ('foundation', 'survey_fndds', 'sr_legacy')
      ORDER BY bm25(foods_fts, 12.0, 3.0, 1.5) ASC, LENGTH(f.name) ASC, f.id ASC
      LIMIT ?
    `;

    const referenceNameWhere = tokens
      .map(() => "lower(f.name) LIKE ?")
      .join(" AND ");
    const referenceNameSql = `
      SELECT ${FOOD_COLUMNS}
      FROM foods f
      WHERE f.source IN ('foundation', 'survey_fndds', 'sr_legacy')
        AND ${referenceNameWhere}
      ORDER BY
        CASE
          WHEN lower(f.name) = ? THEN 0
          WHEN lower(f.name) LIKE '%, nfs%' OR lower(f.name) LIKE '%, ns %' THEN 1
          WHEN lower(f.name) LIKE ? THEN 2
          WHEN lower(f.name) LIKE ? THEN 3
          ELSE 4
        END ASC,
        LENGTH(f.name) ASC,
        f.id ASC
      LIMIT ?
    `;

    const looseSql = `
      SELECT ${FOOD_COLUMNS}
      FROM foods f
      WHERE ${whereClause}
      ORDER BY
        CASE
          WHEN lower(f.name) = ? THEN 0
          WHEN lower(f.name) LIKE ? THEN 1
          WHEN lower(f.name) LIKE ? THEN 2
          WHEN lower(IFNULL(f.brand, '')) = ? THEN 3
          ELSE 4
        END ASC,
        LENGTH(f.name) ASC,
        f.id ASC
      LIMIT ?
    `;

    const maxRows = Math.max(40, Math.min(400, limit));
    const strictRows = db.prepare(strictSql).all(matchQuery, maxRows);
    const referenceRows = db.prepare(referenceSql).all(matchQuery, Math.min(maxRows, 120));
    const normalized = trimmed.toLowerCase();
    const referenceNameRows = db.prepare(referenceNameSql).all(
      ...tokens.map((token) => `%${token}%`),
      normalized,
      `${normalized},%`,
      `${normalized} %`,
      Math.min(maxRows, 120)
    );
    const looseParams = [];
    for (const token of tokens) {
      const like = `%${token}%`;
      looseParams.push(like, like, like);
    }

    looseParams.push(normalized, `${normalized}%`, `%${normalized}%`, normalized, maxRows);
    const looseRows = db.prepare(looseSql).all(...looseParams);
    const merged = new Map();
    for (const row of [...referenceNameRows, ...referenceRows, ...strictRows, ...looseRows]) {
      if (!merged.has(row.id)) {
        merged.set(row.id, formatFoodRow(row));
      }
    }
    return [...merged.values()];
  }

  function search(query, { limit = 20, offset = 0 } = {}) {
    const merged = new Map();
    if (learnedStore) {
      for (const row of learnedStore.search(query, {
        limit: Math.max(limit + offset, 20),
        minimumScore: 500,
      })) {
        merged.set(row.candidateId, row);
      }
    }
    for (const variant of searchVariants(query)) {
      for (const row of searchOne(variant, { limit: Math.max((limit + offset) * 8, 160) })) {
        if (!merged.has(row.candidateId)) {
          merged.set(row.candidateId, row);
        }
      }
    }

    const ranked = [...merged.values()]
      .map((row) => ({ row, score: scoreFoodRow(row, query) }))
      .sort((a, b) => {
        if (a.score !== b.score) {
          return b.score - a.score;
        }
        const aServing = String(a.row.servingDescription || "");
        const bServing = String(b.row.servingDescription || "");
        const aQuality = aServing === "100g" ? 0 : 1;
        const bQuality = bServing === "100g" ? 0 : 1;
        if (aQuality !== bQuality) {
          return bQuality - aQuality;
        }
        return String(a.row.name || "").localeCompare(String(b.row.name || ""));
      });

    const duplicateCounts = new Map();
    const diversified = [];
    for (const item of ranked) {
      const identity = `${tokenize(item.row.name).map(singularize).join(" ")}|${String(item.row.brand || "").toLowerCase()}`;
      const count = duplicateCounts.get(identity) || 0;
      if (count >= 3) continue;
      duplicateCounts.set(identity, count + 1);
      diversified.push(item);
    }
    return diversified.slice(offset, offset + limit).map((item) => item.row);
  }

  function inspect(rowId) {
    if (!Number.isInteger(rowId) || rowId <= 0) {
      return null;
    }

    const learned = learnedStore?.inspect(rowId);
    if (learned) {
      return learned;
    }

    const row = db.prepare(`
      SELECT ${FOOD_COLUMNS}
      FROM foods f
      WHERE f.id = ?
      LIMIT 1
    `).get(rowId);

    return formatFoodRow(row);
  }

  return {
    isAvailable: true,
    dbPath,
    rowCount,
    search,
    inspect,
    close() {
      db.close();
    },
  };
}

module.exports = {
  createFoodSearchStore,
  explicitlyRequestedBrand,
  isAuthoritativeReferenceSource,
  nutritionContradictsCalories,
  scoreFoodRow,
};
