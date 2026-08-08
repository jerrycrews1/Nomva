"use strict";

process.env.STATE_ENCRYPTION_KEY ||= "nomva-state-store-test-key";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const Database = require("better-sqlite3");
const { loadServerState } = require("../stateStore");

test("migrates legacy auth tables and round-trips trust metadata", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "nomva-state-"));
  const dbPath = path.join(directory, "state.sqlite");
  const legacyDB = new Database(dbPath);
  legacyDB.exec(`
    CREATE TABLE app_sessions (
      token_hash TEXT PRIMARY KEY,
      nomva_user_id TEXT NOT NULL,
      identity_key TEXT NOT NULL,
      device_token_hash TEXT,
      created_at TEXT,
      last_seen_at TEXT,
      expires_at TEXT
    );
    CREATE TABLE app_attestations (
      identity_key TEXT PRIMARY KEY,
      key_id TEXT NOT NULL,
      public_key TEXT NOT NULL,
      sign_count INTEGER NOT NULL,
      created_at TEXT,
      updated_at TEXT,
      last_asserted_at TEXT
    );
  `);
  legacyDB.close();

  const state = loadServerState({ dbPath });
  state.appSessionStore.sessions.tokenHash = {
    nomvaUserId: "user-id",
    identityKey: "identity-key",
    deviceTokenHash: "device-hash",
    createdAt: "2026-08-07T10:00:00.000Z",
    lastSeenAt: "2026-08-07T10:01:00.000Z",
    expiresAt: "2026-08-08T10:00:00.000Z",
    trustMode: "app_attest",
    trustEnvironment: "production",
    entitlement: {
      status: "active",
      source: "testflight",
      environment: "Sandbox",
      verifiedAt: "2026-08-07T10:00:00.000Z",
      expiresAt: null,
    },
  };
  state.appSessionStore.identityIndex["identity-key"] = "tokenHash";
  state.appAttestStore.identities["identity-key"] = {
    keyId: "key-id",
    publicKey: "public-key",
    signCount: 1,
    environment: "production",
  };
  state.appAttestStore.keyIndex["key-id"] = "identity-key";
  state.persist(state.garminStore, state.appSessionStore, state.appAttestStore);

  const reloaded = loadServerState({ dbPath });
  assert.equal(reloaded.appSessionStore.sessions.tokenHash.trustMode, "app_attest");
  assert.equal(reloaded.appSessionStore.sessions.tokenHash.trustEnvironment, "production");
  assert.equal(reloaded.appSessionStore.sessions.tokenHash.entitlement.source, "testflight");
  assert.equal(reloaded.appAttestStore.identities["identity-key"].environment, "production");

  const migratedDB = new Database(dbPath, { readonly: true });
  const sessionColumns = migratedDB.pragma("table_info(app_sessions)").map((column) => column.name);
  const attestationColumns = migratedDB.pragma("table_info(app_attestations)").map((column) => column.name);
  migratedDB.close();
  assert.ok(sessionColumns.includes("trust_mode"));
  assert.ok(sessionColumns.includes("entitlement_status"));
  assert.ok(attestationColumns.includes("environment"));
});

test("persists fixed-window API budgets and resets at the next window", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "nomva-rate-limit-"));
  const state = loadServerState({ dbPath: path.join(directory, "state.sqlite") });
  const options = {
    scopeKey: "ai:user-hash",
    windowMs: 60_000,
    max: 2,
    now: 120_001,
  };

  assert.deepEqual(state.consumeRateLimit(options), {
    allowed: true,
    remaining: 1,
    resetAt: 180_000,
  });
  assert.equal(state.consumeRateLimit(options).allowed, true);
  assert.equal(state.consumeRateLimit(options).allowed, false);
  assert.equal(state.consumeRateLimit({ ...options, now: 180_001 }).allowed, true);
});
