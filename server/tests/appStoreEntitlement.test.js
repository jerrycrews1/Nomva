"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { Environment } = require("@apple/app-store-server-library");
const {
  boundedJWS,
  createAppStoreEntitlementVerifier,
  loadAppleRootCertificates,
} = require("../appStoreEntitlement");

const validJWS = "header.payload.signature";
const now = Date.parse("2026-08-07T12:00:00Z");

function rejectedVerifier() {
  return {
    async verifyAndDecodeTransaction() { throw new Error("wrong environment"); },
    async verifyAndDecodeAppTransaction() { throw new Error("wrong environment"); },
  };
}

function verifierWith({ transaction, appTransaction } = {}) {
  return {
    async verifyAndDecodeTransaction() {
      if (!transaction) throw new Error("bad transaction");
      return transaction;
    },
    async verifyAndDecodeAppTransaction() {
      if (!appTransaction) throw new Error("bad app transaction");
      return appTransaction;
    },
  };
}

test("loads the pinned Apple trust roots", () => {
  const certificates = loadAppleRootCertificates(require("node:path").join(__dirname, "..", "certs"));
  assert.equal(certificates.length, 3);
  assert.ok(certificates.every((certificate) => Buffer.isBuffer(certificate) && certificate.length > 300));
});

test("rejects malformed or oversized JWS input before verification", () => {
  assert.equal(boundedJWS("not-a-jws"), "");
  assert.equal(boundedJWS(`a.${"b".repeat(33_000)}.c`), "");
  assert.equal(boundedJWS(validJWS), validJWS);
});

test("grants an active, unrevoked Nomva subscription", async () => {
  const userId = "d50ec268-e5a1-4ccb-8e32-4e424458f780";
  const verifier = createAppStoreEntitlementVerifier({
    verifiers: {
      production: verifierWith({ transaction: {
        productId: "com.nerdquad.nomva.pro.monthly",
        expiresDate: now + 86_400_000,
        appAccountToken: userId,
      } }),
      sandbox: rejectedVerifier(),
    },
  });

  const result = await verifier.evaluate({
    trustMode: "app_attest",
    appAttestEnvironment: "production",
    nomvaUserId: userId,
    subscriptionTransactionJWS: validJWS,
    now,
  });

  assert.equal(result.status, "active");
  assert.equal(result.source, "app_store_subscription");
  assert.equal(result.environment, Environment.PRODUCTION);
  assert.equal(result.accountBound, true);
});

test("does not accept expired, revoked, wrong-product, or wrong-account subscriptions", async () => {
  const cases = [
    { expiresDate: now - 1 },
    { expiresDate: now + 1_000, revocationDate: now - 1 },
    { expiresDate: now + 1_000, productId: "another.product" },
    {
      expiresDate: now + 1_000,
      appAccountToken: "2ec0b8e9-bf82-4b1c-8fd0-9f9c865c879c",
    },
  ];

  for (const overrides of cases) {
    const verifier = createAppStoreEntitlementVerifier({
      verifiers: {
        production: verifierWith({ transaction: {
          productId: "com.nerdquad.nomva.pro.monthly",
          ...overrides,
        } }),
        sandbox: rejectedVerifier(),
      },
    });
    const result = await verifier.evaluate({
      trustMode: "app_attest",
      appAttestEnvironment: "production",
      nomvaUserId: "d50ec268-e5a1-4ccb-8e32-4e424458f780",
      subscriptionTransactionJWS: validJWS,
      now,
    });
    assert.notEqual(result.status, "active");
  }
});

test("grants TestFlight only when sandbox AppTransaction and production App Attest agree", async () => {
  const verifier = createAppStoreEntitlementVerifier({
    verifiers: {
      production: rejectedVerifier(),
      sandbox: verifierWith({ appTransaction: { receiptType: Environment.SANDBOX } }),
    },
  });
  const testFlight = await verifier.evaluate({
    trustMode: "app_attest",
    appAttestEnvironment: "production",
    appTransactionJWS: validJWS,
    now,
  });
  const developmentBuild = await verifier.evaluate({
    trustMode: "app_attest",
    appAttestEnvironment: "development",
    appTransactionJWS: validJWS,
    now,
  });

  assert.equal(testFlight.status, "active");
  assert.equal(testFlight.source, "testflight");
  assert.equal(developmentBuild.status, "ineligible");
});

test("automation and loopback development receive explicit non-Apple entitlements", async () => {
  const verifier = createAppStoreEntitlementVerifier({ verifiers: {} });
  const automation = await verifier.evaluate({ trustMode: "automation", now });
  const local = await verifier.evaluate({ trustMode: "local_simulator", now });

  assert.equal(automation.source, "automation");
  assert.equal(local.source, "local_development");
});
