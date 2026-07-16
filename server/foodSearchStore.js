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

function foodFamilySearchVariants(query) {
  const tokens = tokenize(query).filter((token) => token !== "a" && token !== "about");
  const singularTokens = new Set(tokens.map(singularize));
  const variants = [];

  const mentionsChickFilA = singularTokens.has("chick") && singularTokens.has("fil");
  const mentionsChicken = singularTokens.has("chicken") || mentionsChickFilA;
  const mentionsNuggets = singularTokens.has("nugget");
  const mentionsFries = singularTokens.has("fry") || singularTokens.has("frie");
  const mentionsWaffle = singularTokens.has("waffle") || mentionsChickFilA;

  if (mentionsNuggets && mentionsChicken) {
    variants.push("chicken nuggets");
  } else if (mentionsNuggets && tokens.length === 1) {
    variants.push("chicken nuggets");
  }

  if (mentionsFries && mentionsWaffle) {
    variants.push("waffle fries");
  } else if (mentionsFries && tokens.length <= 2) {
    variants.push("french fries");
  }

  if (singularTokens.has("egg")) {
    variants.push("whole egg");
  }

  if (singularTokens.has("spinach")) {
    variants.push("spinach raw");
  }

  return variants;
}

function searchVariants(query) {
  const variants = [String(query || "").trim(), ...foodFamilySearchVariants(query)];
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
  const queryTokens = new Set(tokenize(originalQuery).filter((token) => token !== "a" && token !== "about").map(singularize));
  const candidateTokens = new Set(rowTokens(row));
  const name = String(row?.name || "").toLowerCase();
  const brand = String(row?.brand || "").toLowerCase();
  const basis = String(row?.portionBasis || row?.portion_basis || "");
  const hasBrand = Boolean(brand);
  let score = 0;

  for (const token of queryTokens) {
    if (candidateTokens.has(token)) {
      score += 12;
    }
  }

  const mentionsChickFilA = queryTokens.has("chick") && queryTokens.has("fil");
  if (mentionsChickFilA && brand.includes("chick-fil")) {
    score += 20;
  }

  if (
    mentionsChickFilA &&
    queryTokens.has("nugget") &&
    candidateTokens.has("chicken") &&
    candidateTokens.has("nugget")
  ) {
    score += basis === "grams" ? 70 : 32;
    if (!hasBrand && name === "chicken nuggets") {
      score += 45;
    } else if (hasBrand && !brand.includes("chick-fil")) {
      score -= 36;
    }
  }

  if (
    mentionsChickFilA &&
    queryTokens.has("fry") &&
    candidateTokens.has("waffle") &&
    candidateTokens.has("fry")
  ) {
    score += basis === "grams" ? 70 : 20;
    if (!hasBrand && name === "waffle fries") {
      score += 45;
    } else if (hasBrand && !brand.includes("chick-fil")) {
      score -= 24;
    }
  }

  if (basis === "grams") {
    score += 14;
  }

  if (
    mentionsChickFilA &&
    queryTokens.has("fry") &&
    ["small", "medium", "large"].some((token) => candidateTokens.has(token)) &&
    !["small", "medium", "large"].some((token) => queryTokens.has(token))
  ) {
    score -= 80;
  }

  for (const bad of ["pretzel", "catfish", "salmon", "cereal", "kids", "meal", "salad", "dressing", "seasoned", "sweet"]) {
    if (candidateTokens.has(bad) && !queryTokens.has(bad)) {
      score -= 50;
    }
  }

  if (name === String(originalQuery || "").toLowerCase()) {
    score += 30;
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

  function searchOne(query, { limit = 20, offset = 0 } = {}) {
    const trimmed = String(query || "").trim();
    const matchQuery = buildMatchQuery(trimmed);
    const tokens = tokenize(trimmed);
    if (!trimmed || !tokens.length || !matchQuery) {
      return [];
    }

    const whereClause = tokens
      .map(() => "(lower(f.name) LIKE ? OR lower(IFNULL(f.brand, '')) LIKE ?)")
      .join(" AND ");

    const sql = `
      WITH strict AS (
        SELECT ${FOOD_COLUMNS}, bm25(foods_fts, 12.0, 3.0) AS rank_score, 0 AS match_tier
        FROM foods f
        JOIN foods_fts ON foods_fts.rowid = f.id
        WHERE foods_fts MATCH ?
        LIMIT 120
      ),
      loose AS (
        SELECT ${FOOD_COLUMNS}, NULL AS rank_score, 1 AS match_tier
        FROM foods f
        WHERE ${whereClause}
        LIMIT 120
      ),
      merged AS (
        SELECT * FROM strict
        UNION ALL
        SELECT * FROM loose
        WHERE id NOT IN (SELECT id FROM strict)
      )
      SELECT *
      FROM merged
      ORDER BY
        CASE
          WHEN lower(name) = ? THEN 0
          WHEN lower(name) LIKE ? THEN 1
          WHEN lower(name) LIKE ? THEN 2
          WHEN lower(brand) = ? THEN 3
          ELSE 4
        END ASC,
        match_tier ASC,
        CASE WHEN rank_score IS NULL THEN 1000000000 ELSE rank_score END ASC,
        LENGTH(name) ASC,
        id ASC
      LIMIT ? OFFSET ?
    `;

    const params = [matchQuery];
    for (const token of tokens) {
      const like = `%${token}%`;
      params.push(like, like);
    }

    const normalized = trimmed.toLowerCase();
    params.push(normalized, `${normalized}%`, `%${normalized}%`, normalized, limit, offset);
    return db.prepare(sql).all(...params).map(formatFoodRow);
  }

  function search(query, { limit = 20, offset = 0 } = {}) {
    const merged = new Map();
    for (const variant of searchVariants(query)) {
      for (const row of searchOne(variant, { limit: Math.max(limit * 6, 120), offset })) {
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
      .slice(0, limit)
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
    search,
    inspect,
  };
}

module.exports = {
  createFoodSearchStore,
};
