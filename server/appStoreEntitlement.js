"use strict";

const fs = require("fs");
const path = require("path");
const { X509Certificate } = require("crypto");
const {
  Environment,
  SignedDataVerifier,
} = require("@apple/app-store-server-library");

const MAX_JWS_LENGTH = 32_768;

function boundedJWS(value) {
  if (typeof value !== "string") {
    return "";
  }
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > MAX_JWS_LENGTH || trimmed.split(".").length !== 3) {
    return "";
  }
  return trimmed;
}

function normalizedUUID(value) {
  const normalized = String(value || "").trim().toLowerCase();
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(normalized)
    ? normalized
    : "";
}

function isoDate(milliseconds) {
  return Number.isFinite(milliseconds) ? new Date(milliseconds).toISOString() : null;
}

function loadAppleRootCertificates(certDirectory) {
  const filenames = fs.readdirSync(certDirectory)
    .filter((filename) => /\.(cer|der|pem)$/i.test(filename))
    .sort();
  if (!filenames.length) {
    throw new Error("No Apple root certificates were found.");
  }

  return filenames.map((filename) => {
    const certificate = new X509Certificate(fs.readFileSync(path.join(certDirectory, filename)));
    return certificate.raw;
  });
}

function defaultVerifiers({ certDirectory, bundleId, appAppleId, enableOnlineChecks }) {
  const roots = loadAppleRootCertificates(certDirectory);
  return {
    production: new SignedDataVerifier(
      roots,
      enableOnlineChecks,
      Environment.PRODUCTION,
      bundleId,
      appAppleId
    ),
    sandbox: new SignedDataVerifier(
      roots,
      enableOnlineChecks,
      Environment.SANDBOX,
      bundleId
    ),
  };
}

async function verifyInEitherEnvironment(verifiers, method, jws) {
  const failures = [];
  for (const [environment, verifier] of [
    [Environment.PRODUCTION, verifiers.production],
    [Environment.SANDBOX, verifiers.sandbox],
  ]) {
    try {
      return {
        environment,
        payload: await verifier[method](jws),
      };
    } catch (error) {
      failures.push(error);
    }
  }
  throw new AggregateError(failures, `Apple rejected the signed ${method} payload.`);
}

function activeAutomationEntitlement(now = Date.now()) {
  return {
    status: "active",
    source: "automation",
    environment: "automation",
    verifiedAt: new Date(now).toISOString(),
    expiresAt: null,
  };
}

function createAppStoreEntitlementVerifier(options = {}) {
  const productId = options.productId || "com.nerdquad.nomva.pro.monthly";
  const bundleId = options.bundleId || "com.nomva.app";
  const appAppleId = Number(options.appAppleId || 6762495287);
  const certDirectory = options.certDirectory || path.join(__dirname, "certs");
  let verifiers = options.verifiers;
  let configurationError = null;

  if (!verifiers) {
    try {
      verifiers = defaultVerifiers({
        certDirectory,
        bundleId,
        appAppleId,
        enableOnlineChecks: options.enableOnlineChecks !== false,
      });
    } catch (error) {
      configurationError = error;
    }
  }

  async function evaluate({
    trustMode,
    appAttestEnvironment,
    nomvaUserId,
    appTransactionJWS,
    subscriptionTransactionJWS,
    now = Date.now(),
  } = {}) {
    if (trustMode === "automation") {
      return activeAutomationEntitlement(now);
    }
    if (trustMode === "local_simulator") {
      return {
        status: "active",
        source: "local_development",
        environment: "development",
        verifiedAt: new Date(now).toISOString(),
        expiresAt: null,
      };
    }
    if (!verifiers) {
      return {
        status: "unconfigured",
        source: null,
        environment: null,
        verifiedAt: null,
        expiresAt: null,
      };
    }

    const subscriptionJWS = boundedJWS(subscriptionTransactionJWS);
    const appJWS = boundedJWS(appTransactionJWS);
    const hadSuppliedEvidence = Boolean(subscriptionTransactionJWS || appTransactionJWS);
    const verificationErrors = [];

    if (subscriptionJWS) {
      try {
        const verified = await verifyInEitherEnvironment(
          verifiers,
          "verifyAndDecodeTransaction",
          subscriptionJWS
        );
        const transaction = verified.payload;
        const expiresAt = Number(transaction.expiresDate);
        const expectedAccountToken = normalizedUUID(nomvaUserId);
        const suppliedAccountToken = transaction.appAccountToken
          ? normalizedUUID(transaction.appAccountToken)
          : "";
        const accountTokenMatches = !suppliedAccountToken
          || (expectedAccountToken && suppliedAccountToken === expectedAccountToken);
        const active = transaction.productId === productId
          && Number.isFinite(expiresAt)
          && expiresAt > now
          && !transaction.revocationDate
          && transaction.isUpgraded !== true
          && accountTokenMatches;

        if (active) {
          return {
            status: "active",
            source: "app_store_subscription",
            environment: verified.environment,
            verifiedAt: new Date(now).toISOString(),
            expiresAt: isoDate(expiresAt),
            accountBound: Boolean(suppliedAccountToken),
          };
        }
      } catch (error) {
        verificationErrors.push(error);
      }
    }

    if (appJWS) {
      try {
        const verified = await verifyInEitherEnvironment(
          verifiers,
          "verifyAndDecodeAppTransaction",
          appJWS
        );
        const isTestFlight = verified.environment === Environment.SANDBOX
          && verified.payload.receiptType === Environment.SANDBOX
          && appAttestEnvironment === "production";
        if (isTestFlight) {
          return {
            status: "active",
            source: "testflight",
            environment: verified.environment,
            verifiedAt: new Date(now).toISOString(),
            expiresAt: null,
          };
        }

        return {
          status: "ineligible",
          source: "app_store_install",
          environment: verified.environment,
          verifiedAt: new Date(now).toISOString(),
          expiresAt: null,
        };
      } catch (error) {
        verificationErrors.push(error);
      }
    }

    return {
      status: hadSuppliedEvidence ? "invalid" : "missing",
      source: null,
      environment: null,
      verifiedAt: null,
      expiresAt: null,
      errorCount: verificationErrors.length,
    };
  }

  return {
    configured: Boolean(verifiers),
    configurationError,
    evaluate,
  };
}

module.exports = {
  MAX_JWS_LENGTH,
  boundedJWS,
  createAppStoreEntitlementVerifier,
  loadAppleRootCertificates,
  normalizedUUID,
};
