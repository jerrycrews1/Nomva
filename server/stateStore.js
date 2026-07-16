const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const Database = require("better-sqlite3");

const STATE_ENCRYPTION_SECRET = process.env.STATE_ENCRYPTION_KEY || "";

if (!STATE_ENCRYPTION_SECRET) {
  throw new Error("STATE_ENCRYPTION_KEY is required to start Nomva Cloud.");
}

const STATE_ENCRYPTION_KEY = crypto
  .createHash("sha256")
  .update(STATE_ENCRYPTION_SECRET)
  .digest();

function encryptSecret(value) {
  if (value === undefined || value === null || value === "") {
    return null;
  }

  if (typeof value !== "string") {
    throw new Error("Secret values must be strings.");
  }

  if (value.startsWith("enc:gcm:v1:")) {
    return value;
  }

  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", STATE_ENCRYPTION_KEY, iv);
  const ciphertext = Buffer.concat([cipher.update(value, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();

  return [
    "enc:gcm:v1",
    iv.toString("base64"),
    tag.toString("base64"),
    ciphertext.toString("base64"),
  ].join(":");
}

function decryptSecret(value) {
  if (value === undefined || value === null || value === "") {
    return undefined;
  }

  if (typeof value !== "string" || !value.startsWith("enc:gcm:v1:")) {
    return value;
  }

  const [, , , ivB64, tagB64, ciphertextB64] = value.split(":");
  if (!ivB64 || !tagB64 || !ciphertextB64) {
    throw new Error("Invalid encrypted secret payload.");
  }

  const decipher = crypto.createDecipheriv(
    "aes-256-gcm",
    STATE_ENCRYPTION_KEY,
    Buffer.from(ivB64, "base64")
  );
  decipher.setAuthTag(Buffer.from(tagB64, "base64"));

  const plaintext = Buffer.concat([
    decipher.update(Buffer.from(ciphertextB64, "base64")),
    decipher.final(),
  ]);

  return plaintext.toString("utf8");
}

function defaultGarminStore() {
  return {
    version: 1,
    users: {},
    states: {},
    garminUserIndex: {},
  };
}

function defaultAppSessionStore() {
  return {
    version: 1,
    sessions: {},
    identityIndex: {},
  };
}

function defaultAppAttestStore() {
  return {
    version: 1,
    identities: {},
    keyIndex: {},
  };
}

function ensureSchema(db) {
  db.pragma("journal_mode = WAL");
  db.pragma("synchronous = NORMAL");
  db.exec(`
    CREATE TABLE IF NOT EXISTS garmin_users (
      nomva_user_id TEXT PRIMARY KEY,
      created_at TEXT,
      updated_at TEXT,
      device_token_hash TEXT,
      garmin_user_id TEXT,
      access_token TEXT,
      token_secret TEXT,
      connected_at TEXT,
      last_webhook_at TEXT,
      disconnected_at TEXT,
      last_permission_change_at TEXT,
      last_disconnected_garmin_user_id TEXT,
      permissions_json TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_garmin_users_garmin_user_id
      ON garmin_users(garmin_user_id);

    CREATE TABLE IF NOT EXISTS garmin_states (
      state TEXT PRIMARY KEY,
      nomva_user_id TEXT NOT NULL,
      device_token_hash TEXT,
      return_scheme TEXT,
      oauth_token_secret TEXT,
      created_at TEXT
    );

    CREATE TABLE IF NOT EXISTS garmin_summaries (
      nomva_user_id TEXT NOT NULL,
      summary_date TEXT NOT NULL,
      active_calories REAL,
      steps INTEGER,
      total_calories REAL,
      updated_at TEXT,
      PRIMARY KEY (nomva_user_id, summary_date)
    );

    CREATE TABLE IF NOT EXISTS app_sessions (
      token_hash TEXT PRIMARY KEY,
      nomva_user_id TEXT NOT NULL,
      identity_key TEXT NOT NULL,
      device_token_hash TEXT,
      created_at TEXT,
      last_seen_at TEXT,
      expires_at TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_app_sessions_identity_key
      ON app_sessions(identity_key);

    CREATE TABLE IF NOT EXISTS app_attestations (
      identity_key TEXT PRIMARY KEY,
      key_id TEXT NOT NULL,
      public_key TEXT NOT NULL,
      sign_count INTEGER NOT NULL,
      created_at TEXT,
      updated_at TEXT,
      last_asserted_at TEXT
    );

    CREATE UNIQUE INDEX IF NOT EXISTS idx_app_attestations_key_id
      ON app_attestations(key_id);
  `);
}

function hasRows(db, tableName) {
  const row = db.prepare(`SELECT COUNT(*) AS count FROM ${tableName}`).get();
  return (row?.count || 0) > 0;
}

function loadJSON(pathname) {
  try {
    if (!pathname || !fs.existsSync(pathname)) {
      return null;
    }
    return JSON.parse(fs.readFileSync(pathname, "utf8"));
  } catch {
    return null;
  }
}

function normalizeGarminStore(raw) {
  return {
    version: 1,
    users: raw?.users || {},
    states: raw?.states || {},
    garminUserIndex: raw?.garminUserIndex || {},
  };
}

function normalizeAppSessionStore(raw) {
  return {
    version: 1,
    sessions: raw?.sessions || {},
    identityIndex: raw?.identityIndex || {},
  };
}

function persistStateSnapshot(db, garminStore, appSessionStore, appAttestStore) {
  const write = db.transaction((garminState, appState, attestState) => {
    db.prepare("DELETE FROM garmin_states").run();
    db.prepare("DELETE FROM garmin_summaries").run();
    db.prepare("DELETE FROM garmin_users").run();
    db.prepare("DELETE FROM app_sessions").run();
    db.prepare("DELETE FROM app_attestations").run();

    const insertGarminUser = db.prepare(`
      INSERT INTO garmin_users (
        nomva_user_id,
        created_at,
        updated_at,
        device_token_hash,
        garmin_user_id,
        access_token,
        token_secret,
        connected_at,
        last_webhook_at,
        disconnected_at,
        last_permission_change_at,
        last_disconnected_garmin_user_id,
        permissions_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);

    const insertGarminSummary = db.prepare(`
      INSERT INTO garmin_summaries (
        nomva_user_id,
        summary_date,
        active_calories,
        steps,
        total_calories,
        updated_at
      ) VALUES (?, ?, ?, ?, ?, ?)
    `);

    const insertGarminState = db.prepare(`
      INSERT INTO garmin_states (
        state,
        nomva_user_id,
        device_token_hash,
        return_scheme,
        oauth_token_secret,
        created_at
      ) VALUES (?, ?, ?, ?, ?, ?)
    `);

    const insertAppSession = db.prepare(`
      INSERT INTO app_sessions (
        token_hash,
        nomva_user_id,
        identity_key,
        device_token_hash,
        created_at,
        last_seen_at,
        expires_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
    `);

    const insertAppAttestation = db.prepare(`
      INSERT INTO app_attestations (
        identity_key,
        key_id,
        public_key,
        sign_count,
        created_at,
        updated_at,
        last_asserted_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
    `);

    for (const [nomvaUserId, user] of Object.entries(garminState.users || {})) {
      insertGarminUser.run(
        nomvaUserId,
        user.createdAt || null,
        user.updatedAt || null,
        user.deviceTokenHash || null,
        user.garminUserId || null,
        encryptSecret(user.accessToken || null),
        encryptSecret(user.tokenSecret || null),
        user.connectedAt || null,
        user.lastWebhookAt || null,
        user.disconnectedAt || null,
        user.lastPermissionChangeAt || null,
        user.lastDisconnectedGarminUserId || null,
        JSON.stringify(Array.isArray(user.permissions) ? user.permissions : [])
      );

      for (const [summaryDate, summary] of Object.entries(user.summaries || {})) {
        insertGarminSummary.run(
          nomvaUserId,
          summaryDate,
          summary.activeCalories ?? null,
          summary.steps ?? null,
          summary.totalCalories ?? null,
          summary.updatedAt || null
        );
      }
    }

    for (const [state, pending] of Object.entries(garminState.states || {})) {
      insertGarminState.run(
        state,
        pending.nomvaUserId || null,
        pending.deviceTokenHash || null,
        pending.returnScheme || null,
        encryptSecret(pending.oauthTokenSecret || null),
        pending.createdAt || null
      );
    }

    const reverseIdentityIndex = Object.entries(appState.identityIndex || {}).reduce((map, [identityKey, tokenHash]) => {
      map[tokenHash] = identityKey;
      return map;
    }, {});

    for (const [tokenHash, session] of Object.entries(appState.sessions || {})) {
      insertAppSession.run(
        tokenHash,
        session.nomvaUserId || null,
        session.identityKey || reverseIdentityIndex[tokenHash] || null,
        session.deviceTokenHash || null,
        session.createdAt || null,
        session.lastSeenAt || null,
        session.expiresAt || null
      );
    }

    for (const [identityKey, attestation] of Object.entries(attestState.identities || {})) {
      insertAppAttestation.run(
        identityKey,
        attestation.keyId,
        attestation.publicKey,
        attestation.signCount ?? 0,
        attestation.createdAt || null,
        attestation.updatedAt || null,
        attestation.lastAssertedAt || null
      );
    }
  });

  write(garminStore, appSessionStore, appAttestStore);
}

function maybeMigrateJSON(db, options) {
  const hasExistingData =
    hasRows(db, "garmin_users") ||
    hasRows(db, "garmin_states") ||
    hasRows(db, "garmin_summaries") ||
    hasRows(db, "app_sessions") ||
    hasRows(db, "app_attestations");

  if (hasExistingData) {
    return;
  }

  const garminStore = normalizeGarminStore(loadJSON(options.garminJsonPath));
  const appSessionStore = normalizeAppSessionStore(loadJSON(options.appSessionJsonPath));
  const appAttestStore = defaultAppAttestStore();

  if (
    Object.keys(garminStore.users).length === 0 &&
    Object.keys(garminStore.states).length === 0 &&
    Object.keys(appSessionStore.sessions).length === 0
  ) {
    return;
  }

  persistStateSnapshot(db, garminStore, appSessionStore, appAttestStore);
}

function loadGarminStoreFromDB(db) {
  const store = defaultGarminStore();

  const users = db.prepare(`
    SELECT
      nomva_user_id,
      created_at,
      updated_at,
      device_token_hash,
      garmin_user_id,
      access_token,
      token_secret,
      connected_at,
      last_webhook_at,
      disconnected_at,
      last_permission_change_at,
      last_disconnected_garmin_user_id,
      permissions_json
    FROM garmin_users
  `).all();

  for (const row of users) {
    const permissions = (() => {
      try {
        return JSON.parse(row.permissions_json || "[]");
      } catch {
        return [];
      }
    })();

    store.users[row.nomva_user_id] = {
      createdAt: row.created_at || undefined,
      updatedAt: row.updated_at || undefined,
      deviceTokenHash: row.device_token_hash || undefined,
      garminUserId: row.garmin_user_id || undefined,
      accessToken: decryptSecret(row.access_token),
      tokenSecret: decryptSecret(row.token_secret),
      connectedAt: row.connected_at || undefined,
      lastWebhookAt: row.last_webhook_at || undefined,
      disconnectedAt: row.disconnected_at || undefined,
      lastPermissionChangeAt: row.last_permission_change_at || undefined,
      lastDisconnectedGarminUserId: row.last_disconnected_garmin_user_id || undefined,
      permissions,
      summaries: {},
    };

    if (row.garmin_user_id) {
      store.garminUserIndex[row.garmin_user_id] = row.nomva_user_id;
    }
  }

  const summaries = db.prepare(`
    SELECT
      nomva_user_id,
      summary_date,
      active_calories,
      steps,
      total_calories,
      updated_at
    FROM garmin_summaries
  `).all();

  for (const row of summaries) {
    const user = store.users[row.nomva_user_id];
    if (!user) {
      continue;
    }
    user.summaries[row.summary_date] = {
      date: row.summary_date,
      activeCalories: row.active_calories,
      steps: row.steps,
      totalCalories: row.total_calories,
      updatedAt: row.updated_at || undefined,
    };
  }

  const states = db.prepare(`
    SELECT
      state,
      nomva_user_id,
      device_token_hash,
      return_scheme,
      oauth_token_secret,
      created_at
    FROM garmin_states
  `).all();

  for (const row of states) {
    store.states[row.state] = {
      nomvaUserId: row.nomva_user_id,
      deviceTokenHash: row.device_token_hash || undefined,
      returnScheme: row.return_scheme || undefined,
      oauthTokenSecret: decryptSecret(row.oauth_token_secret),
      createdAt: row.created_at || undefined,
    };
  }

  return store;
}

function loadAppSessionStoreFromDB(db) {
  const store = defaultAppSessionStore();

  const sessions = db.prepare(`
    SELECT
      token_hash,
      nomva_user_id,
      identity_key,
      device_token_hash,
      created_at,
      last_seen_at,
      expires_at
    FROM app_sessions
  `).all();

  for (const row of sessions) {
    store.sessions[row.token_hash] = {
      nomvaUserId: row.nomva_user_id,
      identityKey: row.identity_key,
      deviceTokenHash: row.device_token_hash || undefined,
      createdAt: row.created_at || undefined,
      lastSeenAt: row.last_seen_at || undefined,
      lastSeenPersistedAt: row.last_seen_at || undefined,
      expiresAt: row.expires_at || undefined,
    };
    if (row.identity_key) {
      store.identityIndex[row.identity_key] = row.token_hash;
    }
  }

  return store;
}

function loadAppAttestStoreFromDB(db) {
  const store = defaultAppAttestStore();

  const rows = db.prepare(`
    SELECT
      identity_key,
      key_id,
      public_key,
      sign_count,
      created_at,
      updated_at,
      last_asserted_at
    FROM app_attestations
  `).all();

  for (const row of rows) {
    store.identities[row.identity_key] = {
      keyId: row.key_id,
      publicKey: row.public_key,
      signCount: row.sign_count ?? 0,
      createdAt: row.created_at || undefined,
      updatedAt: row.updated_at || undefined,
      lastAssertedAt: row.last_asserted_at || undefined,
    };
    store.keyIndex[row.key_id] = row.identity_key;
  }

  return store;
}

function loadServerState(options) {
  fs.mkdirSync(path.dirname(options.dbPath), { recursive: true });
  const db = new Database(options.dbPath);
  ensureSchema(db);
  maybeMigrateJSON(db, options);

  const updateAppSessionLastSeen = db.prepare(`
    UPDATE app_sessions
    SET last_seen_at = ?
    WHERE token_hash = ?
  `);

  return {
    garminStore: loadGarminStoreFromDB(db),
    appSessionStore: loadAppSessionStoreFromDB(db),
    appAttestStore: loadAppAttestStoreFromDB(db),
    persist(garminStore, appSessionStore, appAttestStore) {
      persistStateSnapshot(db, garminStore, appSessionStore, appAttestStore);
    },
    updateAppSessionLastSeen(tokenHash, lastSeenAt) {
      updateAppSessionLastSeen.run(lastSeenAt, tokenHash);
    },
  };
}

module.exports = {
  loadServerState,
};
