"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  entitlementIsActive,
  isLoopbackAddress,
  normalizeEntitlementMode,
  resolveNonAttestedTrust,
  sessionTTLForTrust,
  timingSafeEqualSecret,
} = require("../authPolicy");

test("accepts only an exact configured automation token", () => {
  const valid = resolveNonAttestedTrust({
    headers: { "x-nomva-automation-token": "correct-secret" },
    nodeEnv: "production",
    automationToken: "correct-secret",
  });
  const invalid = resolveNonAttestedTrust({
    headers: { "x-nomva-automation-token": "wrong-secret" },
    nodeEnv: "production",
    automationToken: "correct-secret",
  });
  const unconfigured = resolveNonAttestedTrust({
    headers: { "x-nomva-automation-token": "anything" },
    nodeEnv: "production",
  });

  assert.deepEqual(valid.trust, { mode: "automation", environment: "automation" });
  assert.equal(invalid.error, "invalid_automation_token");
  assert.equal(unconfigured.error, "invalid_automation_token");
  assert.equal(timingSafeEqualSecret("same", "same"), true);
  assert.equal(timingSafeEqualSecret("same", "different"), false);
});

test("never allows simulator auth in production", () => {
  const result = resolveNonAttestedTrust({
    headers: { "x-nomva-app-attest-mode": "simulator" },
    remoteAddress: "127.0.0.1",
    nodeEnv: "production",
    allowSimulatorAuth: true,
  });

  assert.equal(result.error, "simulator_auth_disabled");
});

test("allows simulator auth only from loopback in non-production", () => {
  const local = resolveNonAttestedTrust({
    headers: { "x-nomva-app-attest-mode": "simulator" },
    remoteAddress: "::ffff:127.0.0.1",
    nodeEnv: "development",
    allowSimulatorAuth: true,
  });
  const remote = resolveNonAttestedTrust({
    headers: { "x-nomva-app-attest-mode": "simulator" },
    remoteAddress: "203.0.113.10",
    nodeEnv: "development",
    allowSimulatorAuth: true,
  });

  assert.equal(local.trust.mode, "local_simulator");
  assert.equal(remote.error, "simulator_auth_disabled");
  assert.equal(isLoopbackAddress("::1"), true);
  assert.equal(isLoopbackAddress("10.0.0.2"), false);
});

test("uses short sessions for automation and local tooling", () => {
  assert.equal(sessionTTLForTrust("automation"), 2 * 60 * 60 * 1000);
  assert.equal(sessionTTLForTrust("local_simulator"), 8 * 60 * 60 * 1000);
  assert.equal(sessionTTLForTrust("app_attest"), 24 * 60 * 60 * 1000);
});

test("defaults production entitlement handling to audit mode", () => {
  assert.equal(normalizeEntitlementMode(undefined, "production"), "audit");
  assert.equal(normalizeEntitlementMode(undefined, "development"), "off");
  assert.equal(normalizeEntitlementMode("enforce", "production"), "enforce");
  assert.equal(normalizeEntitlementMode("nonsense", "production"), "audit");
});

test("requires active, unexpired entitlement state", () => {
  const now = Date.parse("2026-08-07T12:00:00Z");
  assert.equal(entitlementIsActive({ status: "active" }, now), true);
  assert.equal(entitlementIsActive({
    status: "active",
    expiresAt: "2026-08-08T12:00:00Z",
  }, now), true);
  assert.equal(entitlementIsActive({
    status: "active",
    expiresAt: "2026-08-06T12:00:00Z",
  }, now), false);
  assert.equal(entitlementIsActive({ status: "missing" }, now), false);
});
