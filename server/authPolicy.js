"use strict";

const crypto = require("crypto");

const AUTOMATION_HEADER = "x-nomva-automation-token";
const DEFAULT_APP_SESSION_TTL_MS = 24 * 60 * 60 * 1000;
const DEFAULT_AUTOMATION_SESSION_TTL_MS = 2 * 60 * 60 * 1000;
const DEFAULT_LOCAL_SESSION_TTL_MS = 8 * 60 * 60 * 1000;

function timingSafeEqualSecret(left, right) {
  if (typeof left !== "string" || typeof right !== "string" || !left || !right) {
    return false;
  }

  const leftBuffer = Buffer.from(left, "utf8");
  const rightBuffer = Buffer.from(right, "utf8");
  if (leftBuffer.length !== rightBuffer.length) {
    return false;
  }
  return crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

function normalizeRemoteAddress(value) {
  const address = String(value || "").trim().toLowerCase();
  return address.startsWith("::ffff:") ? address.slice(7) : address;
}

function isLoopbackAddress(value) {
  const address = normalizeRemoteAddress(value);
  return address === "127.0.0.1" || address === "::1" || address === "localhost";
}

function resolveNonAttestedTrust({
  headers = {},
  remoteAddress,
  nodeEnv,
  allowSimulatorAuth = false,
  automationToken = "",
} = {}) {
  const suppliedAutomationToken = headers[AUTOMATION_HEADER];
  if (suppliedAutomationToken !== undefined) {
    if (timingSafeEqualSecret(suppliedAutomationToken, automationToken)) {
      return {
        trust: {
          mode: "automation",
          environment: "automation",
        },
      };
    }
    return { error: "invalid_automation_token" };
  }

  if (headers["x-nomva-app-attest-mode"] !== "simulator") {
    return { trust: null };
  }

  const localSimulatorAllowed = nodeEnv !== "production"
    && allowSimulatorAuth
    && isLoopbackAddress(remoteAddress);
  if (!localSimulatorAllowed) {
    return { error: "simulator_auth_disabled" };
  }

  return {
    trust: {
      mode: "local_simulator",
      environment: "development",
    },
  };
}

function sessionTTLForTrust(trustMode, overrides = {}) {
  if (trustMode === "automation") {
    return overrides.automation ?? DEFAULT_AUTOMATION_SESSION_TTL_MS;
  }
  if (trustMode === "local_simulator") {
    return overrides.local ?? DEFAULT_LOCAL_SESSION_TTL_MS;
  }
  return overrides.app ?? DEFAULT_APP_SESSION_TTL_MS;
}

function normalizeEntitlementMode(value, nodeEnv = process.env.NODE_ENV) {
  const normalized = String(value || "").trim().toLowerCase();
  if (["off", "audit", "enforce"].includes(normalized)) {
    return normalized;
  }
  return nodeEnv === "production" ? "audit" : "off";
}

function entitlementIsActive(entitlement, now = Date.now()) {
  if (entitlement?.status !== "active") {
    return false;
  }

  if (!entitlement.expiresAt) {
    return true;
  }

  const expiresAt = Date.parse(entitlement.expiresAt);
  return Number.isFinite(expiresAt) && expiresAt > now;
}

module.exports = {
  AUTOMATION_HEADER,
  entitlementIsActive,
  isLoopbackAddress,
  normalizeEntitlementMode,
  resolveNonAttestedTrust,
  sessionTTLForTrust,
  timingSafeEqualSecret,
};
