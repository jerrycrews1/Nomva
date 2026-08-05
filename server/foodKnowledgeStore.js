const fs = require("fs");
const path = require("path");
const Database = require("better-sqlite3");

const LEARNED_ROW_OFFSET = 1_500_000_000;

const QUERY_NOISE = new Set([
  "a", "an", "the", "i", "had", "ate", "drank", "log", "add", "please",
  "from", "at", "for", "of", "with", "and", "some", "about", "my", "one",
  "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
]);

function normalizeFoodText(value) {
  return String(value || "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

function foodTokens(value) {
  return normalizeFoodText(value)
    .split(" ")
    .filter((token) => token && !QUERY_NOISE.has(token));
}

function finiteOrNull(value) {
  if (value === null || value === undefined || typeof value === "boolean") return null;
  if (typeof value === "string" && !value.trim()) return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function boundedText(value, maxLength = 500) {
  const text = String(value || "").trim();
  return text ? text.slice(0, maxLength) : null;
}

function parseAliases(value) {
  try {
    const aliases = JSON.parse(value || "[]");
    return Array.isArray(aliases) ? aliases.filter((alias) => typeof alias === "string") : [];
  } catch {
    return [];
  }
}

function canonicalKey(food) {
  return normalizeFoodText([
    food.brand,
    food.name,
    food.servingDescription,
  ].filter(Boolean).join(" "));
}

function tokenEditDistanceAtMostOne(left, right) {
  if (left === right) return true;
  if (Math.abs(left.length - right.length) > 1) return false;
  let mismatches = 0;
  let leftIndex = 0;
  let rightIndex = 0;
  while (leftIndex < left.length && rightIndex < right.length) {
    if (left[leftIndex] === right[rightIndex]) {
      leftIndex += 1;
      rightIndex += 1;
      continue;
    }
    mismatches += 1;
    if (mismatches > 1) return false;
    if (left.length > right.length) leftIndex += 1;
    else if (right.length > left.length) rightIndex += 1;
    else {
      leftIndex += 1;
      rightIndex += 1;
    }
  }
  return mismatches + (leftIndex < left.length || rightIndex < right.length ? 1 : 0) <= 1;
}

function scoreRow(row, query) {
  const normalizedQuery = normalizeFoodText(query);
  const queryTokens = [...new Set(foodTokens(query))];
  if (!normalizedQuery || !queryTokens.length) return 0;

  const aliases = parseAliases(row.aliases_json);
  const searchableValues = [row.name, row.brand, row.serving_desc, ...aliases]
    .map(normalizeFoodText)
    .filter(Boolean);
  const candidateTokens = new Set(foodTokens(searchableValues.join(" ")));
  let exactMatches = 0;
  let fuzzyMatches = 0;
  for (const token of queryTokens) {
    if (candidateTokens.has(token)) {
      exactMatches += 1;
    } else if ([...candidateTokens].some((candidate) => tokenEditDistanceAtMostOne(token, candidate))) {
      fuzzyMatches += 1;
    }
  }

  const coverage = (exactMatches + (fuzzyMatches * 0.65)) / queryTokens.length;
  if (coverage < 0.5) return 0;

  let score = Math.round(coverage * 500) + (exactMatches * 45) + (fuzzyMatches * 12);
  if (searchableValues.includes(normalizedQuery)) score += 800;
  if (searchableValues.some((value) => value.startsWith(`${normalizedQuery} `))) score += 180;
  if (queryTokens.every((token) => candidateTokens.has(token))) score += 220;
  score += row.quality === "published" ? 30 : 10;
  score += Math.round((finiteOrNull(row.confidence) || 0) * 40);
  return score;
}

function formatLearnedRow(row, searchScore = 0) {
  if (!row) return null;
  const quality = row.quality === "published" ? "published" : "estimated";
  return {
    rowId: LEARNED_ROW_OFFSET + row.id,
    candidateId: `learned_${row.id}`,
    fdcId: null,
    name: row.name,
    brand: row.brand || null,
    source: quality === "published" ? "web_published" : "web_estimate",
    servingGrams: finiteOrNull(row.serving_g),
    servingDescription: row.serving_desc || "1 serving",
    caloriesPerServing: finiteOrNull(row.calories) || 0,
    proteinG: finiteOrNull(row.protein_g) || 0,
    carbsG: finiteOrNull(row.carbs_g) || 0,
    fatG: finiteOrNull(row.fat_g) || 0,
    fiberG: finiteOrNull(row.fiber_g) || 0,
    sugarG: finiteOrNull(row.sugar_g) || 0,
    sodiumMg: finiteOrNull(row.sodium_mg) || 0,
    saturatedFatG: null,
    transFatG: null,
    cholesterolMg: null,
    addedSugarG: null,
    vitaminDMcg: null,
    calciumMg: null,
    ironMg: null,
    potassiumMg: null,
    vitaminAMcgRAE: null,
    vitaminCMg: null,
    vitaminB12Mcg: null,
    folateMcgDFE: null,
    magnesiumMg: null,
    zincMg: null,
    barcode: null,
    portionBasis: "fixed_serving",
    servingSource: "explicit_serving",
    quality,
    confidence: finiteOrNull(row.confidence) || 0,
    sourceUrl: row.source_url || null,
    sourceTitle: row.source_title || null,
    evidence: row.evidence || null,
    aliases: parseAliases(row.aliases_json),
    updatedAt: row.updated_at,
    expiresAt: row.expires_at,
    searchScore,
  };
}

function loadFoodKnowledgeStore(options = {}) {
  const dbPath = options.dbPath || path.join(__dirname, "data", "food-knowledge.sqlite");
  const now = typeof options.now === "function" ? options.now : () => new Date();
  fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  const db = new Database(dbPath);
  db.pragma("journal_mode = WAL");
  db.pragma("synchronous = NORMAL");
  db.exec(`
    CREATE TABLE IF NOT EXISTS learned_foods (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      canonical_key TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      brand TEXT,
      aliases_json TEXT NOT NULL DEFAULT '[]',
      serving_desc TEXT NOT NULL,
      serving_g REAL,
      calories REAL NOT NULL,
      protein_g REAL NOT NULL,
      carbs_g REAL NOT NULL,
      fat_g REAL NOT NULL,
      fiber_g REAL NOT NULL,
      sugar_g REAL,
      sodium_mg REAL,
      quality TEXT NOT NULL CHECK (quality IN ('published', 'estimated')),
      confidence REAL NOT NULL,
      source_url TEXT NOT NULL,
      source_title TEXT,
      evidence TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      hit_count INTEGER NOT NULL DEFAULT 0
    );

    CREATE INDEX IF NOT EXISTS idx_learned_foods_expires
      ON learned_foods(expires_at);

    CREATE TABLE IF NOT EXISTS food_lookup_misses (
      normalized_query TEXT PRIMARY KEY,
      created_at TEXT NOT NULL,
      expires_at TEXT NOT NULL
    );
  `);

  const selectActive = db.prepare(`
    SELECT * FROM learned_foods
    WHERE expires_at > ?
  `);
  const selectById = db.prepare("SELECT * FROM learned_foods WHERE id = ? LIMIT 1");
  const incrementHit = db.prepare("UPDATE learned_foods SET hit_count = hit_count + 1 WHERE id = ?");
  const selectMiss = db.prepare(`
    SELECT normalized_query FROM food_lookup_misses
    WHERE normalized_query = ? AND expires_at > ?
    LIMIT 1
  `);
  const upsertMiss = db.prepare(`
    INSERT INTO food_lookup_misses (normalized_query, created_at, expires_at)
    VALUES (?, ?, ?)
    ON CONFLICT(normalized_query) DO UPDATE SET
      created_at = excluded.created_at,
      expires_at = excluded.expires_at
  `);
  const deleteMiss = db.prepare("DELETE FROM food_lookup_misses WHERE normalized_query = ?");
  const pruneFoods = db.prepare("DELETE FROM learned_foods WHERE expires_at <= ?");
  const pruneMisses = db.prepare("DELETE FROM food_lookup_misses WHERE expires_at <= ?");
  const upsertFood = db.prepare(`
    INSERT INTO learned_foods (
      canonical_key, name, brand, aliases_json, serving_desc, serving_g,
      calories, protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg,
      quality, confidence, source_url, source_title, evidence,
      created_at, updated_at, expires_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(canonical_key) DO UPDATE SET
      name = excluded.name,
      brand = excluded.brand,
      aliases_json = excluded.aliases_json,
      serving_desc = excluded.serving_desc,
      serving_g = excluded.serving_g,
      calories = excluded.calories,
      protein_g = excluded.protein_g,
      carbs_g = excluded.carbs_g,
      fat_g = excluded.fat_g,
      fiber_g = excluded.fiber_g,
      sugar_g = excluded.sugar_g,
      sodium_mg = excluded.sodium_mg,
      quality = excluded.quality,
      confidence = excluded.confidence,
      source_url = excluded.source_url,
      source_title = excluded.source_title,
      evidence = excluded.evidence,
      updated_at = excluded.updated_at,
      expires_at = excluded.expires_at
  `);
  const selectByKey = db.prepare("SELECT * FROM learned_foods WHERE canonical_key = ? LIMIT 1");
  const updateAliases = db.prepare("UPDATE learned_foods SET aliases_json = ? WHERE canonical_key = ?");

  function search(query, { limit = 10, minimumScore = 260 } = {}) {
    const current = now().toISOString();
    const ranked = selectActive.all(current)
      .map((row) => ({ row, score: scoreRow(row, query) }))
      .filter(({ score }) => score >= minimumScore)
      .sort((left, right) => right.score - left.score)
      .slice(0, Math.max(1, Math.min(limit, 50)));
    return ranked.map(({ row, score }) => formatLearnedRow(row, score));
  }

  function inspect(rowId) {
    const numeric = Number(rowId);
    if (numeric < LEARNED_ROW_OFFSET) return null;
    const id = numeric - LEARNED_ROW_OFFSET;
    if (!Number.isInteger(id) || id <= 0) return null;
    return formatLearnedRow(selectById.get(id));
  }

  function upsert(food, aliases = [], ttlDays = null) {
    const key = canonicalKey(food);
    if (!key || !food?.name || !food?.sourceUrl) {
      throw new Error("invalid learned food");
    }

    const existing = selectByKey.get(key);
    const uniqueAliases = [...new Set([
      ...(existing ? parseAliases(existing.aliases_json) : []),
      ...aliases,
      ...(Array.isArray(food.aliases) ? food.aliases : []),
      food.name,
      [food.brand, food.name].filter(Boolean).join(" "),
    ].map((alias) => boundedText(alias, 180)).filter(Boolean))].slice(0, 30);

    // A later model estimate may add useful aliases, but it must never
    // overwrite nutrition that was already tied to a published source.
    if (existing?.quality === "published" && food.quality !== "published") {
      updateAliases.run(JSON.stringify(uniqueAliases), key);
      for (const alias of aliases) deleteMiss.run(normalizeFoodText(alias));
      return formatLearnedRow(selectByKey.get(key));
    }

    const timestamp = now();
    const quality = food.quality === "published" ? "published" : "estimated";
    const lifetimeDays = ttlDays || (quality === "published" ? 180 : 30);
    const expiresAt = new Date(timestamp.getTime() + lifetimeDays * 86_400_000);
    upsertFood.run(
      key,
      boundedText(food.name, 180),
      boundedText(food.brand, 120),
      JSON.stringify(uniqueAliases),
      boundedText(food.servingDescription, 180) || "1 serving",
      finiteOrNull(food.servingGrams),
      finiteOrNull(food.caloriesPerServing),
      finiteOrNull(food.proteinG) || 0,
      finiteOrNull(food.carbsG) || 0,
      finiteOrNull(food.fatG) || 0,
      finiteOrNull(food.fiberG) || 0,
      finiteOrNull(food.sugarG),
      finiteOrNull(food.sodiumMg),
      quality,
      Math.min(1, Math.max(0, finiteOrNull(food.confidence) || 0)),
      boundedText(food.sourceUrl, 1_000),
      boundedText(food.sourceTitle, 300),
      boundedText(food.evidence, 1_500),
      existing?.created_at || timestamp.toISOString(),
      timestamp.toISOString(),
      expiresAt.toISOString()
    );
    for (const alias of [food.name, ...aliases]) {
      deleteMiss.run(normalizeFoodText(alias));
    }
    return formatLearnedRow(selectByKey.get(key));
  }

  function noteHit(candidateId) {
    const match = String(candidateId || "").match(/^learned_(\d+)$/);
    if (match) incrementHit.run(Number(match[1]));
  }

  function hasFreshMiss(query) {
    const key = normalizeFoodText(query);
    return Boolean(key && selectMiss.get(key, now().toISOString()));
  }

  function rememberMiss(query, ttlHours = 12) {
    const key = normalizeFoodText(query);
    if (!key) return;
    const created = now();
    const expires = new Date(created.getTime() + ttlHours * 3_600_000);
    upsertMiss.run(key, created.toISOString(), expires.toISOString());
  }

  function prune() {
    const timestamp = now().toISOString();
    return {
      foods: pruneFoods.run(timestamp).changes,
      misses: pruneMisses.run(timestamp).changes,
    };
  }

  function stats() {
    const timestamp = now().toISOString();
    return {
      activeFoods: db.prepare("SELECT COUNT(*) AS count FROM learned_foods WHERE expires_at > ?").get(timestamp).count,
      cachedMisses: db.prepare("SELECT COUNT(*) AS count FROM food_lookup_misses WHERE expires_at > ?").get(timestamp).count,
    };
  }

  return {
    dbPath,
    search,
    inspect,
    upsert,
    noteHit,
    hasFreshMiss,
    rememberMiss,
    prune,
    stats,
    close() { db.close(); },
  };
}

module.exports = {
  LEARNED_ROW_OFFSET,
  canonicalKey,
  foodTokens,
  formatLearnedRow,
  loadFoodKnowledgeStore,
  normalizeFoodText,
  scoreRow,
};
