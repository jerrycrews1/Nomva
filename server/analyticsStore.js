const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const Database = require("better-sqlite3");

function numberOrNull(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function intOrNull(value) {
  const number = numberOrNull(value);
  return number === null ? null : Math.round(number);
}

function textOrNull(value, maxLength = 256) {
  if (value === undefined || value === null) {
    return null;
  }
  const text = String(value).trim();
  return text ? text.slice(0, maxLength) : null;
}

function boolToInt(value) {
  if (value === undefined || value === null) {
    return null;
  }
  return value ? 1 : 0;
}

function percentile(values, p) {
  if (!values.length) {
    return null;
  }
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[index];
}

function normalizePath(value) {
  const text = textOrNull(value, 180);
  if (!text) {
    return null;
  }
  return text.split("?")[0];
}

function loadAnalyticsStore(options) {
  const enabled = options.enabled !== false;
  const dbPath = options.dbPath;
  const retentionDays = Math.max(1, Number(options.retentionDays || 90));
  const hashSalt = String(options.hashSalt || "nomva-analytics");

  if (!enabled) {
    return {
      enabled: false,
      hashUserId() { return null; },
      record() {},
      recordBatch() { return 0; },
      prune() {},
      deleteUser() { return 0; },
      summary() { return { enabled: false }; },
    };
  }

  fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  const db = new Database(dbPath);
  db.pragma("journal_mode = WAL");
  db.pragma("synchronous = NORMAL");
  db.exec(`
    CREATE TABLE IF NOT EXISTS analytics_events (
      id TEXT PRIMARY KEY,
      event_time TEXT NOT NULL,
      received_at TEXT NOT NULL,
      source TEXT NOT NULL,
      event_type TEXT NOT NULL,
      user_hash TEXT,
      session_hash TEXT,
      route TEXT,
      method TEXT,
      status INTEGER,
      duration_ms REAL,
      bytes_in INTEGER,
      bytes_out INTEGER,
      model TEXT,
      llm_task TEXT,
      prompt_chars INTEGER,
      response_chars INTEGER,
      total_tokens INTEGER,
      success INTEGER,
      error_code TEXT,
      properties_json TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_analytics_events_time
      ON analytics_events(event_time);

    CREATE INDEX IF NOT EXISTS idx_analytics_events_type_time
      ON analytics_events(event_type, event_time);

    CREATE INDEX IF NOT EXISTS idx_analytics_events_route_time
      ON analytics_events(route, event_time);

    CREATE INDEX IF NOT EXISTS idx_analytics_events_user
      ON analytics_events(user_hash);
  `);

  const insert = db.prepare(`
    INSERT OR IGNORE INTO analytics_events (
      id,
      event_time,
      received_at,
      source,
      event_type,
      user_hash,
      session_hash,
      route,
      method,
      status,
      duration_ms,
      bytes_in,
      bytes_out,
      model,
      llm_task,
      prompt_chars,
      response_chars,
      total_tokens,
      success,
      error_code,
      properties_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  const pruneStatement = db.prepare(`
    DELETE FROM analytics_events
    WHERE event_time < ?
  `);
  const deleteUserStatement = db.prepare(`
    DELETE FROM analytics_events
    WHERE user_hash = ?
  `);

  function hashUserId(value) {
    const text = textOrNull(value, 512);
    if (!text) {
      return null;
    }
    return crypto
      .createHmac("sha256", hashSalt)
      .update(text)
      .digest("hex")
      .slice(0, 32);
  }

  function sanitizeProperties(properties) {
    if (!properties || typeof properties !== "object" || Array.isArray(properties)) {
      return {};
    }

    const allowed = {};
    for (const [key, value] of Object.entries(properties)) {
      const safeKey = textOrNull(key, 64);
      if (!safeKey) {
        continue;
      }

      if (typeof value === "string") {
        allowed[safeKey] = value.slice(0, 160);
      } else if (typeof value === "number" && Number.isFinite(value)) {
        allowed[safeKey] = value;
      } else if (typeof value === "boolean") {
        allowed[safeKey] = value;
      } else if (value === null) {
        allowed[safeKey] = null;
      }
    }
    return allowed;
  }

  function record(event) {
    const now = new Date().toISOString();
    const eventTime = textOrNull(event.eventTime || event.timestamp, 64) || now;
    const id = textOrNull(event.id, 80) || crypto.randomUUID();
    const properties = sanitizeProperties(event.properties);

    return insert.run(
      id,
      eventTime,
      now,
      textOrNull(event.source, 48) || "server",
      textOrNull(event.eventType || event.type, 64) || "event",
      textOrNull(event.userHash, 128),
      textOrNull(event.sessionHash, 128),
      normalizePath(event.route || event.path),
      textOrNull(event.method, 16)?.toUpperCase() || null,
      intOrNull(event.status),
      numberOrNull(event.durationMs),
      intOrNull(event.bytesIn),
      intOrNull(event.bytesOut),
      textOrNull(event.model, 64),
      textOrNull(event.llmTask, 64),
      intOrNull(event.promptChars),
      intOrNull(event.responseChars),
      intOrNull(event.totalTokens),
      boolToInt(event.success),
      textOrNull(event.errorCode, 96),
      JSON.stringify(properties)
    );
  }

  function recordBatch(events) {
    if (!Array.isArray(events)) {
      return 0;
    }

    const write = db.transaction((items) => {
      let stored = 0;
      for (const event of items) {
        stored += record(event).changes;
      }
      return stored;
    });

    return write(events);
  }

  function prune() {
    const cutoff = new Date(Date.now() - retentionDays * 24 * 60 * 60 * 1000).toISOString();
    pruneStatement.run(cutoff);
  }

  function deleteUser(userHash) {
    const normalized = textOrNull(userHash, 128);
    if (!normalized) {
      return 0;
    }
    return deleteUserStatement.run(normalized).changes;
  }

  function summarizeGroup(rows) {
    return rows.map((row) => {
      const durations = row.durations
        ? row.durations.split(",").map(Number).filter((value) => Number.isFinite(value))
        : [];
      return {
        key: row.key,
        count: row.count,
        successRate: row.success_count === null ? null : row.success_count / row.count,
        avgMs: row.avg_ms,
        p50Ms: percentile(durations, 50),
        p95Ms: percentile(durations, 95),
        errorCount: row.error_count || 0,
      };
    });
  }

  function summary({ hours = 24 } = {}) {
    const safeHours = Math.max(1, Math.min(24 * 30, Number(hours) || 24));
    const since = new Date(Date.now() - safeHours * 60 * 60 * 1000).toISOString();

    const totals = db.prepare(`
      SELECT
        COUNT(*) AS events,
        SUM(CASE WHEN event_type = 'server_request' THEN 1 ELSE 0 END) AS server_requests,
        SUM(CASE WHEN event_type = 'client_network' THEN 1 ELSE 0 END) AS client_network_events,
        SUM(CASE WHEN event_type = 'llm_call' THEN 1 ELSE 0 END) AS llm_calls
      FROM analytics_events
      WHERE event_time >= ?
    `).get(since);

    const networkRows = db.prepare(`
      SELECT
        route AS key,
        COUNT(*) AS count,
        AVG(duration_ms) AS avg_ms,
        SUM(CASE WHEN success = 1 THEN 1 ELSE 0 END) AS success_count,
        SUM(CASE WHEN success = 0 THEN 1 ELSE 0 END) AS error_count,
        GROUP_CONCAT(duration_ms) AS durations
      FROM analytics_events
      WHERE event_time >= ?
        AND event_type IN ('server_request', 'client_network')
        AND route IS NOT NULL
      GROUP BY route
      ORDER BY count DESC
      LIMIT 25
    `).all(since);

    const serverRoutes = db.prepare(`
      SELECT
        route AS key,
        COUNT(*) AS count,
        AVG(duration_ms) AS avg_ms,
        SUM(CASE WHEN success = 1 THEN 1 ELSE 0 END) AS success_count,
        SUM(CASE WHEN success = 0 THEN 1 ELSE 0 END) AS error_count,
        GROUP_CONCAT(duration_ms) AS durations
      FROM analytics_events
      WHERE event_time >= ?
        AND event_type = 'server_request'
        AND route IS NOT NULL
      GROUP BY route
      ORDER BY count DESC
      LIMIT 25
    `).all(since);

    const clientRoutes = db.prepare(`
      SELECT
        route AS key,
        COUNT(*) AS count,
        AVG(duration_ms) AS avg_ms,
        SUM(CASE WHEN success = 1 THEN 1 ELSE 0 END) AS success_count,
        SUM(CASE WHEN success = 0 THEN 1 ELSE 0 END) AS error_count,
        GROUP_CONCAT(duration_ms) AS durations
      FROM analytics_events
      WHERE event_time >= ?
        AND event_type = 'client_network'
        AND route IS NOT NULL
      GROUP BY route
      ORDER BY count DESC
      LIMIT 25
    `).all(since);

    const llm = db.prepare(`
      SELECT
        COALESCE(llm_task, 'unknown') AS key,
        COUNT(*) AS count,
        AVG(duration_ms) AS avg_ms,
        SUM(CASE WHEN success = 1 THEN 1 ELSE 0 END) AS success_count,
        SUM(CASE WHEN success = 0 THEN 1 ELSE 0 END) AS error_count,
        GROUP_CONCAT(duration_ms) AS durations
      FROM analytics_events
      WHERE event_time >= ?
        AND event_type = 'llm_call'
      GROUP BY COALESCE(llm_task, 'unknown')
      ORDER BY count DESC
      LIMIT 25
    `).all(since);

    const statusCodes = db.prepare(`
      SELECT status, COUNT(*) AS count
      FROM analytics_events
      WHERE event_time >= ?
        AND status IS NOT NULL
        AND event_type IN ('server_request', 'client_network')
      GROUP BY status
      ORDER BY count DESC
      LIMIT 20
    `).all(since);

    return {
      enabled: true,
      since,
      hours: safeHours,
      totals,
      routes: summarizeGroup(networkRows),
      serverRoutes: summarizeGroup(serverRoutes),
      clientRoutes: summarizeGroup(clientRoutes),
      llm: summarizeGroup(llm),
      statusCodes,
    };
  }

  return {
    enabled,
    hashUserId,
    record,
    recordBatch,
    prune,
    deleteUser,
    summary,
  };
}

module.exports = {
  loadAnalyticsStore,
};
