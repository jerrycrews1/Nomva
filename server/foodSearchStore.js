const fs = require("fs");
const path = require("path");

const FOOD_COLUMNS = `
  f.id, f.fdc_id, f.name, IFNULL(f.brand, '') AS brand, f.source,
  f.serving_g, IFNULL(f.serving_desc, '') AS serving_desc,
  f.calories, f.protein_g, f.carbs_g, f.fat_g, f.fiber_g,
  f.sugar_g, f.sodium_mg,
  f.saturated_fat_g, f.trans_fat_g, f.cholesterol_mg, f.added_sugar_g,
  f.vitamin_d_mcg, f.calcium_mg, f.iron_mg, f.potassium_mg,
  f.vitamin_a_mcg_rae, f.vitamin_c_mg, f.vitamin_b12_mcg,
  f.folate_mcg_dfe, f.magnesium_mg, f.zinc_mg, IFNULL(f.barcode, '') AS barcode,
  IFNULL(f.portion_basis, 'grams') AS portion_basis, IFNULL(f.serving_source, '') AS serving_source
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
  if (token.endsWith("ies") && token.length > 3) {
    return `${token.slice(0, -3)}y`;
  }
  if (token.endsWith("s") && token.length > 3 && !token.endsWith("ss")) {
    return token.slice(0, -1);
  }
  return token;
}

const SEARCH_NOISE_TOKENS = new Set([
  "a", "an", "the", "some", "about", "approximately", "around",
  "i", "my", "had", "ate", "drank", "log", "please",
  "for", "at", "during", "meal", "breakfast", "lunch", "dinner", "snack",
  "side", "of", "served", "serving",
  "small", "medium", "large",
]);

function isPortionToken(token) {
  return /^\d+(?:\.\d+)?$/.test(token)
    || /^\d+(?:\.\d+)?(?:oz|ounce|ounces|g|gram|grams|kg|ml|l|lb|lbs)$/.test(token);
}

function meaningfulSearchTokens(query) {
  return tokenize(query).filter((token) => !SEARCH_NOISE_TOKENS.has(token) && !isPortionToken(token));
}

function searchVariants(query) {
  const original = String(query || "").trim();
  const contentTokens = meaningfulSearchTokens(original);
  const variants = [original, contentTokens.join(" ")];

  // A descriptive modifier may not exist in the database even though the base
  // food is a valid nutritional equivalent. Search every one-token relaxation
  // and let the LLM decide which returned row preserves the user's meaning.
  if (contentTokens.length >= 3 && contentTokens.length <= 8) {
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
  return tokenize(`${row?.name || ""} ${row?.brand || ""}`).map(singularize);
}

function scoreFoodRow(row, originalQuery) {
  const queryTokenList = meaningfulSearchTokens(originalQuery).map(singularize);
  const queryTokens = new Set(queryTokenList);
  const candidateTokenList = rowTokens(row);
  const candidateTokens = new Set(candidateTokenList);
  const nameTokens = tokenize(row?.name || "").map(singularize);
  const name = String(row?.name || "").toLowerCase().trim();
  const normalizedQuery = meaningfulSearchTokens(originalQuery).join(" ");
  const matchedTokens = [...queryTokens].filter((token) => candidateTokens.has(token));
  const coverage = queryTokens.size ? matchedTokens.length / queryTokens.size : 0;
  let score = 0;

  score += matchedTokens.length * 30;
  score += Math.round(coverage * 140);
  if (queryTokens.size && matchedTokens.length === queryTokens.size) {
    score += 80;
  }

  if (name === normalizedQuery) {
    score += 240;
  } else if (normalizedQuery && name.startsWith(`${normalizedQuery} `)) {
    score += 100;
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

  const unmatchedNameTokens = nameTokens.filter((token) => !queryTokens.has(token));
  score -= Math.min(unmatchedNameTokens.length * 3, 30);

  if (!row?.brand) {
    score += 8;
  }
  if (String(row?.source || "").includes("sr_legacy")) {
    score += 8;
  }
  if (String(row?.portionBasis || row?.portion_basis || "") === "grams") {
    score += 5;
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
  };
}

function createFoodSearchStore(options = {}) {
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
    db.prepare("SELECT saturated_fat_g, vitamin_b12_mcg, portion_basis FROM foods LIMIT 1").get();
    db.prepare("SELECT rowid FROM foods_fts LIMIT 1").get();
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
      .map(() => "(lower(f.name) LIKE ? OR lower(IFNULL(f.brand, '')) LIKE ?)")
      .join(" AND ");

    const strictSql = `
      SELECT ${FOOD_COLUMNS}
      FROM foods f
      JOIN foods_fts ON foods_fts.rowid = f.id
      WHERE foods_fts MATCH ?
      ORDER BY bm25(foods_fts, 12.0, 3.0) ASC, LENGTH(f.name) ASC, f.id ASC
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
    const looseParams = [];
    for (const token of tokens) {
      const like = `%${token}%`;
      looseParams.push(like, like);
    }

    const normalized = trimmed.toLowerCase();
    looseParams.push(normalized, `${normalized}%`, `%${normalized}%`, normalized, maxRows);
    const looseRows = db.prepare(looseSql).all(...looseParams);
    const merged = new Map();
    for (const row of [...strictRows, ...looseRows]) {
      if (!merged.has(row.id)) {
        merged.set(row.id, formatFoodRow(row));
      }
    }
    return [...merged.values()];
  }

  function search(query, { limit = 20, offset = 0 } = {}) {
    const merged = new Map();
    for (const variant of searchVariants(query)) {
      for (const row of searchOne(variant, { limit: Math.max((limit + offset) * 8, 160) })) {
        if (!merged.has(row.candidateId)) {
          merged.set(row.candidateId, row);
        }
      }
    }

    return [...merged.values()]
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
      })
      .slice(offset, offset + limit)
      .map((ranked) => ranked.row);
  }

  function inspect(rowId) {
    if (!Number.isInteger(rowId) || rowId <= 0) {
      return null;
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
};
