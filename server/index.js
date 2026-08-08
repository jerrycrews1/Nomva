require("dotenv").config();
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const https = require("https");
const express = require("express");
const helmet = require("helmet");
const rateLimit = require("express-rate-limit");
const OpenAI = require("openai");
const { verifyAttestation, verifyAssertion } = require("node-app-attest");
const prompts = require("./prompts");
const { loadServerState } = require("./stateStore");
const { loadAnalyticsStore } = require("./analyticsStore");
const { createFoodSearchStore, isAuthoritativeReferenceSource } = require("./foodSearchStore");
const { loadFoodKnowledgeStore } = require("./foodKnowledgeStore");
const {
  candidateCompatibleWithMention,
  FOOD_SELECTION_SCHEMA,
  resolveFoodCandidate: runFoodResolver,
} = require("./foodResolver");
const {
  createWebFoodResolver,
  hasUnresolvedLeadingIdentity,
  identityMatchesMention,
  isMenuFoodMention,
  requiresExactMenuResearch,
  resolvedCandidateBody,
  shouldBlockStaticFallback,
  shouldTryWebFirst,
} = require("./webFoodResolver");
const {
  WORLD_FOOD_ESTIMATE_PROMPT,
  WORLD_FOOD_ESTIMATE_SCHEMA,
  firstNonNull,
  resolveWorldFoodEstimate,
} = require("./worldFoodEstimator");
const { deterministicDeleteTargets, parseLogEntries, normalizeText } = require("./deleteTargetGuard");
const { deterministicEditTarget } = require("./editTargetGuard");
const { sanitizeFoodMentions } = require("./foodMentionGuard");
const { hasExplicitPortion } = require("./portionGuard");
const {
  buildGarminUploadWindows,
  computeGarminAverages,
  normalizedGarminWeight,
} = require("./garminMetrics");
const {
  entitlementIsActive,
  normalizeEntitlementMode,
  resolveNonAttestedTrust,
  sessionTTLForTrust,
  timingSafeEqualSecret,
} = require("./authPolicy");
const { createAppStoreEntitlementVerifier } = require("./appStoreEntitlement");
const {
  sanitizeRecentFoodCandidates,
  sanitizeSuggestedFoodIds,
} = require("./recentFoodSuggestionGuard");
const {
  FOOD_LOG_PLAN_SCHEMA,
  FOOD_LOG_PLANNER_PROMPT,
  sanitizeFoodLogPlan,
  shouldUseStructuredFoodPlan,
} = require("./foodLogPlanner");
const {
  EmptyStructuredResponseError,
  requestStructuredJSON,
} = require("./structuredLLM");
const {
  ANALYZE_NUTRITION_LABEL_SCHEMA,
  ANALYZE_PHOTO_SCHEMA,
  structuredOutputForTask,
} = require("./llmSchemas");
const {
  boundedNumber,
  boundedServings,
  boundedGrams,
  boundedGoalValue,
  sanitizePhotoAnalysis,
  sanitizeNutritionLabelAnalysis,
  BOUNDS,
} = require("./numericGuards");

const app = express();
app.set("trust proxy", 1);
const PORT = process.env.PORT || 3000;
const MODEL = process.env.NOMVA_LLM_MODEL || process.env.OPENAI_MODEL || "gpt-4o-mini";
const FOOD_RESOLUTION_MODEL = process.env.NOMVA_FOOD_RESOLUTION_MODEL || "gpt-5.6-luna";
const WEB_FOOD_MODEL = process.env.NOMVA_WEB_FOOD_MODEL || "gpt-5.6-luna";
const WEB_FOOD_PUBLISHED_MODEL = process.env.NOMVA_WEB_FOOD_PUBLISHED_MODEL || "gpt-5.6-sol";
const FOOD_LOG_PLANNING_MODEL = process.env.NOMVA_FOOD_LOG_PLANNING_MODEL || "gpt-5.6-luna";
const WORLD_FOOD_MODEL = process.env.NOMVA_WORLD_FOOD_MODEL || FOOD_LOG_PLANNING_MODEL;
const CONTEXT_MODEL = process.env.NOMVA_CONTEXT_MODEL || "gpt-5.4-mini";
const VISION_MODEL = process.env.NOMVA_VISION_MODEL || "gpt-5.6-luna";
const AI_ESTIMATE_SOURCE_URL = "https://nomva.nerdquad.com/food-estimates";
const publicDir = path.join(__dirname, "public");
const dataDir = process.env.NOMVA_DATA_DIR || path.join(__dirname, "data");
const garminStorePath = path.join(dataDir, "garmin-store.json");
const appSessionStorePath = path.join(dataDir, "app-sessions.json");
const stateDBPath = path.join(dataDir, "nomva-state.sqlite");
const analyticsDBPath = process.env.ANALYTICS_DB_PATH || path.join(dataDir, "nomva-analytics.sqlite");
const foodKnowledgeDBPath = process.env.FOOD_KNOWLEDGE_DB_PATH || path.join(dataDir, "food-knowledge.sqlite");
const APP_ATTEST_BUNDLE_ID = process.env.APP_ATTEST_BUNDLE_ID || "com.nomva.app";
const APP_ATTEST_TEAM_ID = process.env.APP_ATTEST_TEAM_ID || "9UXM4W53T6";
const APP_ATTEST_ALLOW_DEVELOPMENT = process.env.APP_ATTEST_ALLOW_DEVELOPMENT
  ? process.env.APP_ATTEST_ALLOW_DEVELOPMENT === "1"
  : process.env.NODE_ENV !== "production";
const ALLOW_SIMULATOR_AUTH = process.env.ALLOW_SIMULATOR_AUTH === "1";
const NOMVA_AUTOMATION_TOKEN = process.env.NOMVA_AUTOMATION_TOKEN || "";
const ENTITLEMENT_MODE = normalizeEntitlementMode(
  process.env.NOMVA_ENTITLEMENT_MODE,
  process.env.NODE_ENV
);
const APP_STORE_BUNDLE_ID = process.env.APP_STORE_BUNDLE_ID || APP_ATTEST_BUNDLE_ID;
const APP_STORE_APPLE_ID = Number(process.env.APP_STORE_APPLE_ID || 6762495287);
const APP_STORE_PRODUCT_ID = process.env.APP_STORE_PRODUCT_ID || "com.nerdquad.nomva.pro.monthly";
const AI_REQUESTS_PER_DAY = boundedEnvironmentInteger(
  process.env.NOMVA_AI_REQUESTS_PER_DAY,
  1_000,
  100,
  10_000
);
const PHOTO_REQUESTS_PER_DAY = boundedEnvironmentInteger(
  process.env.NOMVA_PHOTO_REQUESTS_PER_DAY,
  100,
  10,
  1_000
);
const ANALYTICS_ADMIN_TOKEN = process.env.ANALYTICS_ADMIN_TOKEN || "";
const VOWNTIL_BREACH_API_TOKEN = process.env.VOWNTIL_BREACH_API_TOKEN || "";
const VOWNTIL_EMAIL_FROM = process.env.VOWNTIL_EMAIL_FROM || "";
const VOWNTIL_EMAIL_REPLY_TO = process.env.VOWNTIL_EMAIL_REPLY_TO || "";
const RESEND_API_KEY = process.env.RESEND_API_KEY || "";
// ── Garmin OAuth 1.0a config ─────────────────────────────────────────────────
const GARMIN_CONSUMER_KEY = process.env.GARMIN_CONSUMER_KEY || process.env.GARMIN_CLIENT_ID || "";
const GARMIN_CONSUMER_SECRET = process.env.GARMIN_CONSUMER_SECRET || process.env.GARMIN_CLIENT_SECRET || "";
const GARMIN_REQUEST_TOKEN_URL = process.env.GARMIN_REQUEST_TOKEN_URL || "https://connectapi.garmin.com/oauth-service/oauth/request_token";
const GARMIN_AUTHORIZE_URL = process.env.GARMIN_AUTHORIZE_URL || "https://connect.garmin.com/oauthConfirm";
const GARMIN_ACCESS_TOKEN_URL = process.env.GARMIN_ACCESS_TOKEN_URL || "https://connectapi.garmin.com/oauth-service/oauth/access_token";
const GARMIN_REDIRECT_URI = process.env.GARMIN_REDIRECT_URI || "https://nomva.nerdquad.com/garmin/callback";
const GARMIN_CALLBACK_SCHEME = process.env.GARMIN_CALLBACK_SCHEME || "nomva";
const GARMIN_WEBHOOK_SHARED_SECRET = process.env.GARMIN_WEBHOOK_SHARED_SECRET || "";
const GARMIN_USER_ID_URL = process.env.GARMIN_USER_ID_URL || "https://healthapi.garmin.com/wellness-api/rest/user/id";
const GARMIN_USER_PERMISSIONS_URL = process.env.GARMIN_USER_PERMISSIONS_URL || "https://healthapi.garmin.com/wellness-api/rest/user/permissions";
const GARMIN_USER_REGISTRATION_URL = process.env.GARMIN_USER_REGISTRATION_URL || "https://healthapi.garmin.com/wellness-api/rest/user/registration";
const GARMIN_BODY_COMPS_URL = process.env.GARMIN_BODY_COMPS_URL || "https://healthapi.garmin.com/wellness-api/rest/bodyComps";

if (process.env.GARMIN_OAUTH_AUTHORIZE_URL || process.env.GARMIN_OAUTH_TOKEN_URL || process.env.GARMIN_OAUTH_SCOPE) {
  console.warn(
    "garmin config warning: GARMIN_OAUTH_* env vars are ignored by the current server integration. " +
    "Use GARMIN_REQUEST_TOKEN_URL, GARMIN_AUTHORIZE_URL, GARMIN_ACCESS_TOKEN_URL, " +
    "GARMIN_CONSUMER_KEY / GARMIN_CONSUMER_SECRET (or GARMIN_CLIENT_ID / GARMIN_CLIENT_SECRET aliases)."
  );
}

function boundedEnvironmentInteger(value, fallback, minimum, maximum) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed)) {
    return fallback;
  }
  return Math.max(minimum, Math.min(maximum, parsed));
}

// ── Middleware ────────────────────────────────────────────────────────────────

app.use(helmet());
app.use(express.json({
  limit: "10mb",
  verify: (req, _res, buf) => {
    req.rawBody = Buffer.from(buf);
  },
}));

const MAX_STANDARD_BODY_BYTES = 256 * 1024;
app.use("/v1", (req, res, next) => {
  const isPhotoAnalysis = req.path === "/analyze-photo";
  if (!isPhotoAnalysis && (req.rawBody?.length || 0) > MAX_STANDARD_BODY_BYTES) {
    return res.status(413).json({ error: "request_too_large" });
  }
  return next();
});

// ── Garmin storage/config helpers ─────────────────────────────────────────────

function garminIsConfigured() {
  return Boolean(
    GARMIN_CONSUMER_KEY &&
    GARMIN_CONSUMER_SECRET &&
    GARMIN_REQUEST_TOKEN_URL &&
    GARMIN_AUTHORIZE_URL &&
    GARMIN_ACCESS_TOKEN_URL &&
    GARMIN_REDIRECT_URI
  );
}

const stateStore = loadServerState({
  dbPath: stateDBPath,
  garminJsonPath: garminStorePath,
  appSessionJsonPath: appSessionStorePath,
});
stateStore.pruneRateLimits();
setInterval(() => stateStore.pruneRateLimits(), 24 * 60 * 60 * 1000).unref();

const analyticsStore = loadAnalyticsStore({
  dbPath: analyticsDBPath,
  enabled: process.env.ANALYTICS_ENABLED !== "0",
  retentionDays: Number(process.env.ANALYTICS_RETENTION_DAYS || 90),
  hashSalt: process.env.ANALYTICS_HASH_SALT || process.env.STATE_ENCRYPTION_KEY,
});
const foodKnowledgeStore = loadFoodKnowledgeStore({
  dbPath: foodKnowledgeDBPath,
});
const foodSearchStore = createFoodSearchStore({
  dbPath: process.env.FOODS_DB_PATH,
  learnedStore: foodKnowledgeStore,
});
const appStoreEntitlementVerifier = createAppStoreEntitlementVerifier({
  bundleId: APP_STORE_BUNDLE_ID,
  appAppleId: APP_STORE_APPLE_ID,
  productId: APP_STORE_PRODUCT_ID,
  enableOnlineChecks: process.env.APP_STORE_ONLINE_CHECKS !== "0",
});
analyticsStore.prune();
setInterval(() => analyticsStore.prune(), 24 * 60 * 60 * 1000).unref();
foodKnowledgeStore.prune();
setInterval(() => foodKnowledgeStore.prune(), 24 * 60 * 60 * 1000).unref();

if (!foodSearchStore.isAvailable) {
  console.warn(`food db warning: server-side food resolution unavailable (${foodSearchStore.error || "unknown error"})`);
}
if (!appStoreEntitlementVerifier.configured) {
  console.warn(
    `app store verification warning: ${appStoreEntitlementVerifier.configurationError?.message || "not configured"}`
  );
}

let garminStore = stateStore.garminStore;
let appAttestStore = stateStore.appAttestStore;

const appAttestChallenges = {};

function persistGarminStore() {
  try {
    stateStore.persist(garminStore, appSessionStore, appAttestStore);
  } catch (error) {
    console.error("garmin store persist error:", error.message);
  }
}

function hashDeviceToken(token) {
  return crypto.createHash("sha256").update(String(token)).digest("hex");
}

function analyticsUserHash(nomvaUserId) {
  return analyticsStore.hashUserId(normalizeIdentifier(nomvaUserId));
}

function analyticsSessionHash(req) {
  const token = req.headers.authorization?.replace(/^Bearer\s+/i, "");
  return token ? hashDeviceToken(token).slice(0, 32) : null;
}

let appSessionStore = stateStore.appSessionStore;
const APP_SESSION_LAST_SEEN_WRITE_INTERVAL_MS = 5 * 60 * 1000;

function persistAppSessionStore() {
  try {
    stateStore.persist(garminStore, appSessionStore, appAttestStore);
  } catch (error) {
    console.error("app session store persist error:", error.message);
  }
}

function persistAppSessionLastSeen(tokenHash, session, now = new Date()) {
  const lastPersistedAt = new Date(session.lastSeenPersistedAt || session.lastSeenAt || 0).getTime();
  if (lastPersistedAt && now.getTime() - lastPersistedAt < APP_SESSION_LAST_SEEN_WRITE_INTERVAL_MS) {
    return;
  }

  session.lastSeenPersistedAt = now.toISOString();
  try {
    stateStore.updateAppSessionLastSeen(tokenHash, session.lastSeenPersistedAt);
  } catch (error) {
    console.error("app session last-seen update error:", error.message);
  }
}

function persistAppAttestStore() {
  try {
    stateStore.persist(garminStore, appSessionStore, appAttestStore);
  } catch (error) {
    console.error("app attest store persist error:", error.message);
  }
}

function appSessionIdentityKey(nomvaUserId, deviceToken) {
  return `${normalizeIdentifier(nomvaUserId)}:${hashDeviceToken(deviceToken)}`;
}

function cleanupExpiredAppSessions() {
  const now = Date.now();
  for (const [tokenHash, session] of Object.entries(appSessionStore.sessions)) {
    const expiresAt = new Date(session.expiresAt || 0).getTime();
    if (!expiresAt || expiresAt <= now) {
      delete appSessionStore.sessions[tokenHash];
    }
  }

  for (const [identityKey, tokenHash] of Object.entries(appSessionStore.identityIndex)) {
    if (!appSessionStore.sessions[tokenHash]) {
      delete appSessionStore.identityIndex[identityKey];
    }
  }
}

function issueAppSession(nomvaUserId, deviceToken, options = {}) {
  cleanupExpiredAppSessions();

  const identityKey = appSessionIdentityKey(nomvaUserId, deviceToken);
  const existingTokenHash = appSessionStore.identityIndex[identityKey];
  if (existingTokenHash) {
    delete appSessionStore.sessions[existingTokenHash];
  }

  const token = crypto.randomBytes(32).toString("base64url");
  const tokenHash = hashDeviceToken(token);
  const now = new Date();
  const trustMode = options.trust?.mode || "unknown";
  const expiresAt = new Date(now.getTime() + sessionTTLForTrust(trustMode));

  appSessionStore.sessions[tokenHash] = {
    nomvaUserId: normalizeIdentifier(nomvaUserId),
    identityKey,
    deviceTokenHash: hashDeviceToken(deviceToken),
    createdAt: now.toISOString(),
    lastSeenAt: now.toISOString(),
    lastSeenPersistedAt: now.toISOString(),
    expiresAt: expiresAt.toISOString(),
    trustMode,
    trustEnvironment: options.trust?.environment || null,
    entitlement: options.entitlement || null,
  };
  appSessionStore.identityIndex[identityKey] = tokenHash;
  persistAppSessionStore();

  return {
    token,
    expiresAt: expiresAt.toISOString(),
    entitlement: options.entitlement || null,
  };
}

function appSessionForRequest(req) {
  cleanupExpiredAppSessions();

  const nomvaUserId = normalizeIdentifier(req.headers["x-nomva-user-id"]);
  const deviceToken = req.headers["x-nomva-device-token"];
  const token = req.headers.authorization?.replace(/^Bearer\s+/i, "");

  if (!nomvaUserId || typeof deviceToken !== "string" || !deviceToken.trim() || !token) {
    return { error: "missing_identity" };
  }

  const tokenHash = hashDeviceToken(token);
  const session = appSessionStore.sessions[tokenHash];
  if (!session) {
    return { error: "invalid_session" };
  }

  if (session.nomvaUserId !== nomvaUserId || session.deviceTokenHash !== hashDeviceToken(deviceToken)) {
    return { error: "invalid_session" };
  }

  const now = new Date();
  session.lastSeenAt = now.toISOString();
  persistAppSessionLastSeen(tokenHash, session, now);

  return {
    nomvaUserId,
    deviceToken,
    tokenHash,
    session,
  };
}

function cleanupExpiredAppAttestChallenges() {
  const now = Date.now();
  for (const [challenge, value] of Object.entries(appAttestChallenges)) {
    const expiresAt = new Date(value.expiresAt || 0).getTime();
    if (!expiresAt || expiresAt <= now) {
      delete appAttestChallenges[challenge];
    }
  }
}

function createAppAttestChallenge(nomvaUserId, deviceToken, purpose = "attestation") {
  cleanupExpiredAppAttestChallenges();
  const challenge = crypto.randomBytes(32).toString("base64url");
  appAttestChallenges[challenge] = {
    identityKey: appSessionIdentityKey(nomvaUserId, deviceToken),
    purpose,
    expiresAt: new Date(Date.now() + (5 * 60 * 1000)).toISOString(),
  };
  return {
    challenge,
    expiresAt: appAttestChallenges[challenge].expiresAt,
  };
}

function consumeAppAttestChallenge(challenge, identityKey, purpose = "attestation") {
  cleanupExpiredAppAttestChallenges();
  const pending = appAttestChallenges[challenge];
  if (!pending || pending.identityKey !== identityKey || pending.purpose !== purpose) {
    return false;
  }
  delete appAttestChallenges[challenge];
  return true;
}

function upsertAppAttestation(identityKey, record) {
  const existing = appAttestStore.identities[identityKey];
  if (existing?.keyId && existing.keyId !== record.keyId) {
    delete appAttestStore.keyIndex[existing.keyId];
  }

  appAttestStore.identities[identityKey] = {
    ...existing,
    ...record,
    updatedAt: new Date().toISOString(),
  };
  appAttestStore.keyIndex[record.keyId] = identityKey;
  persistAppAttestStore();
}

function appAttestIdentityFromRequest(req) {
  const nomvaUserId = normalizeIdentifier(req.headers["x-nomva-user-id"]);
  const deviceToken = typeof req.headers["x-nomva-device-token"] === "string"
    ? req.headers["x-nomva-device-token"]
    : "";

  if (!nomvaUserId || !deviceToken.trim()) {
    return { error: "missing_identity" };
  }

  return {
    nomvaUserId,
    deviceToken,
    identityKey: appSessionIdentityKey(nomvaUserId, deviceToken),
  };
}

function appAttestPayloadForRequest(req, timestamp, nomvaUserId, deviceToken) {
  const rawBody = Buffer.isBuffer(req.rawBody) ? req.rawBody : Buffer.alloc(0);
  const bodyHash = crypto.createHash("sha256").update(rawBody).digest("hex");
  const route = req.originalUrl || req.path;
  return Buffer.from(
    [
      req.method.toUpperCase(),
      route,
      timestamp,
      nomvaUserId,
      hashDeviceToken(deviceToken),
      bodyHash,
    ].join("\n"),
    "utf8"
  );
}

function parseAppAttestHeader(value) {
  if (typeof value !== "string" || !value.trim()) {
    return null;
  }

  try {
    const decoded = Buffer.from(value, "base64").toString("utf8");
    const parsed = JSON.parse(decoded);
    return {
      keyId: typeof parsed.keyId === "string" ? parsed.keyId : "",
      assertion: typeof parsed.assertion === "string" ? parsed.assertion : "",
      timestamp: typeof parsed.timestamp === "string" ? parsed.timestamp : "",
    };
  } catch {
    return null;
  }
}

function appAttestTimestampIsFresh(timestamp) {
  const millis = Date.parse(timestamp);
  if (!Number.isFinite(millis)) {
    return false;
  }
  return Math.abs(Date.now() - millis) <= (5 * 60 * 1000);
}

// ── OAuth 1.0a signing helpers ───────────────────────────────────────────────

function oauth1PercentEncode(str) {
  return encodeURIComponent(String(str))
    .replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
}

function oauth1Nonce() {
  return crypto.randomBytes(16).toString("hex");
}

function oauth1Timestamp() {
  return Math.floor(Date.now() / 1000).toString();
}

function oauth1BaseString(method, url, params) {
  const sorted = [...params].sort((a, b) =>
    a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] < b[1] ? -1 : 1
  );
  const paramStr = sorted
    .map(([k, v]) => `${oauth1PercentEncode(k)}=${oauth1PercentEncode(v)}`)
    .join("&");
  return `${method.toUpperCase()}&${oauth1PercentEncode(url)}&${oauth1PercentEncode(paramStr)}`;
}

function oauth1Sign(method, url, params, consumerSecret, tokenSecret = "") {
  const base = oauth1BaseString(method, url, params);
  const key = `${oauth1PercentEncode(consumerSecret)}&${oauth1PercentEncode(tokenSecret)}`;
  return crypto.createHmac("sha1", key).update(base).digest("base64");
}

function oauth1Header(oauthParams) {
  const parts = oauthParams.map(
    ([k, v]) => `${oauth1PercentEncode(k)}="${oauth1PercentEncode(v)}"`
  );
  return `OAuth ${parts.join(", ")}`;
}

async function garminOAuth1Request(method, url, extraOAuthParams = [], tokenSecret = "") {
  // Separate the base URL from any query string params (OAuth 1.0a requires
  // query params to be included in the signature base string alongside OAuth params,
  // and the base URL used for signing must NOT include the query string).
  const parsed = new URL(url);
  const baseUrl = `${parsed.origin}${parsed.pathname}`;
  const queryParams = [...parsed.searchParams.entries()];

  const oauthParams = [
    ["oauth_consumer_key", GARMIN_CONSUMER_KEY],
    ["oauth_signature_method", "HMAC-SHA1"],
    ["oauth_timestamp", oauth1Timestamp()],
    ["oauth_nonce", oauth1Nonce()],
    ["oauth_version", "1.0"],
    ...extraOAuthParams,
  ];

  // All params (OAuth + query string) go into the signature base string
  const allParams = [...oauthParams, ...queryParams];
  const baseString = oauth1BaseString(method, baseUrl, allParams);
  const signingKey = `${oauth1PercentEncode(GARMIN_CONSUMER_SECRET)}&${oauth1PercentEncode(tokenSecret)}`;
  const signature = crypto.createHmac("sha1", signingKey).update(baseString).digest("base64");
  oauthParams.push(["oauth_signature", signature]);

  const authHeader = oauth1Header(oauthParams);

  const response = await fetch(url, {
    method,
    headers: {
      Authorization: authHeader,
      Accept: "application/json",
    },
  });
  return response;
}

async function getGarminRequestToken() {
  const response = await garminOAuth1Request("POST", GARMIN_REQUEST_TOKEN_URL, [
    ["oauth_callback", GARMIN_REDIRECT_URI],
  ]);
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`Request token failed (${response.status}): ${text}`);
  }
  const params = new URLSearchParams(text);
  return {
    oauthToken: params.get("oauth_token"),
    oauthTokenSecret: params.get("oauth_token_secret"),
  };
}

async function getGarminAccessToken(oauthToken, oauthTokenSecret, oauthVerifier) {
  const response = await garminOAuth1Request(
    "POST",
    GARMIN_ACCESS_TOKEN_URL,
    [
      ["oauth_token", oauthToken],
      ["oauth_verifier", oauthVerifier],
    ],
    oauthTokenSecret
  );
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`Access token failed (${response.status}): ${text}`);
  }
  const params = new URLSearchParams(text);
  return {
    oauthToken: params.get("oauth_token"),
    oauthTokenSecret: params.get("oauth_token_secret"),
  };
}

function normalizeIdentifier(value) {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

function sanitizeCallbackScheme(value) {
  const cleaned = typeof value === "string" ? value.trim() : "";
  return /^[a-z][a-z0-9+\-.]*$/i.test(cleaned) ? cleaned : GARMIN_CALLBACK_SCHEME;
}

function sanitizeMessage(value, fallback) {
  return typeof value === "string" && value.trim()
    ? value.trim().slice(0, 160)
    : fallback;
}

function ensureGarminUserRecord(nomvaUserId, deviceToken) {
  const existing = garminStore.users[nomvaUserId] || {
    createdAt: new Date().toISOString(),
    summaries: {},
  };
  existing.deviceTokenHash = hashDeviceToken(deviceToken);
  existing.updatedAt = new Date().toISOString();
  existing.summaries = existing.summaries || {};
  garminStore.users[nomvaUserId] = existing;
  return existing;
}

function cleanupExpiredGarminStates() {
  const cutoff = Date.now() - (15 * 60 * 1000);
  for (const [state, value] of Object.entries(garminStore.states)) {
    const createdAt = new Date(value.createdAt || 0).getTime();
    if (!createdAt || createdAt < cutoff) {
      delete garminStore.states[state];
    }
  }
}

function buildGarminAppRedirectURL({ scheme, status, message }) {
  const target = new URL(`${sanitizeCallbackScheme(scheme)}://garmin-auth`);
  target.searchParams.set("status", status);
  target.searchParams.set("message", sanitizeMessage(message, status === "success" ? "Garmin connected." : "Garmin connection failed."));
  return target.toString();
}

async function fetchGarminUserJSON(url, accessToken, tokenSecret) {
  const response = await garminOAuth1Request("GET", url, [
    ["oauth_token", accessToken],
  ], tokenSecret);

  const text = await response.text();
  if (!response.ok) {
    throw new Error(text || `garmin_request_failed_${response.status}`);
  }
  if (!text.trim()) {
    return null;
  }
  return JSON.parse(text);
}

async function fetchGarminUserProfile(accessToken, tokenSecret) {
  const [userIdPayload, permissionsPayload] = await Promise.all([
    fetchGarminUserJSON(GARMIN_USER_ID_URL, accessToken, tokenSecret),
    fetchGarminUserJSON(GARMIN_USER_PERMISSIONS_URL, accessToken, tokenSecret).catch(() => null),
  ]);

  const userId = userIdPayload?.userId ? String(userIdPayload.userId) : null;
  const permissions = Array.isArray(permissionsPayload)
    ? permissionsPayload.map((value) => String(value))
    : Array.isArray(permissionsPayload?.permissions)
      ? permissionsPayload.permissions.map((value) => String(value))
      : [];

  return { userId, permissions };
}

async function revokeGarminRegistration(accessToken, tokenSecret) {
  const response = await garminOAuth1Request("DELETE", GARMIN_USER_REGISTRATION_URL, [
    ["oauth_token", accessToken],
  ], tokenSecret);

  if (response.status === 204 || response.status === 404) {
    return;
  }
  if (!response.ok) {
    const text = await response.text();
    throw new Error(text || `garmin_delete_failed_${response.status}`);
  }
}

function extractGarminUserId(payload) {
  const candidates = [
    payload?.userId,
    payload?.user_id,
    payload?.garminUserId,
    payload?.garmin_user_id,
    payload?.externalUserId,
    payload?.external_user_id,
    payload?.sub,
    payload?.subject,
    payload?.connectUserId,
    payload?.ownerId,
  ];

  for (const candidate of candidates) {
    if (candidate !== undefined && candidate !== null && String(candidate).trim()) {
      return String(candidate);
    }
  }
  return null;
}

function safeTimingEqual(a, b) {
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));
  if (left.length !== right.length) {
    return false;
  }
  return crypto.timingSafeEqual(left, right);
}

function clampString(value, maxLength) {
  if (typeof value !== "string") {
    return "";
  }
  return value.trim().replace(/\s+/g, " ").slice(0, maxLength);
}

function escapeHTML(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function isValidEmail(value) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(value || ""));
}

function vowntilBearerToken(req) {
  return req.headers.authorization?.replace(/^Bearer\s+/i, "") || req.headers["x-vowntil-token"] || "";
}

function vowntilTokenIsValid(req) {
  return Boolean(VOWNTIL_BREACH_API_TOKEN && safeTimingEqual(vowntilBearerToken(req), VOWNTIL_BREACH_API_TOKEN));
}

function sanitizeVowntilBreachPayload(body) {
  const partnerEmail = clampString(body?.partnerEmail, 254).toLowerCase();
  const message = clampString(body?.message, 1200);
  const detectedAt = clampString(body?.detectedAt, 80);
  const intendedEnd = clampString(body?.intendedEnd, 80);

  if (!isValidEmail(partnerEmail)) {
    return { error: "invalid_partner_email" };
  }
  if (!message) {
    return { error: "missing_message" };
  }

  return {
    reportID: clampString(body?.reportID, 80),
    sessionID: clampString(body?.sessionID, 80),
    detectedAt,
    intendedEnd,
    presetName: clampString(body?.presetName, 120) || "Vowntil lock",
    selectionMode: clampString(body?.selectionMode, 40),
    applicationCount: Number.isFinite(Number(body?.applicationCount)) ? Number(body.applicationCount) : 0,
    categoryCount: Number.isFinite(Number(body?.categoryCount)) ? Number(body.categoryCount) : 0,
    webDomainCount: Number.isFinite(Number(body?.webDomainCount)) ? Number(body.webDomainCount) : 0,
    partnerName: clampString(body?.partnerName, 120),
    partnerEmail,
    message,
  };
}

function buildVowntilBreachEmail(payload) {
  const partnerGreeting = payload.partnerName ? `Hi ${payload.partnerName},` : "Hi,";
  const subject = "Vowntil accountability notice";
  const summaryLines = [
    `Preset: ${payload.presetName}`,
    `Detected: ${payload.detectedAt || "Unknown"}`,
    `Intended end: ${payload.intendedEnd || "Unknown"}`,
    `Mode: ${payload.selectionMode || "Unknown"}`,
    `Selection: ${payload.applicationCount} apps, ${payload.categoryCount} categories, ${payload.webDomainCount} websites`,
    `Session: ${payload.sessionID || "Unknown"}`,
  ];
  const text = [
    partnerGreeting,
    "",
    "Vowntil recorded that Screen Time access was removed during an active lock.",
    "",
    payload.message,
    "",
    ...summaryLines,
    "",
    "This notice was sent because the Vowntil user configured you as their accountability partner.",
  ].join("\n");
  const html = `
    <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;line-height:1.5;color:#13211d">
      <p>${escapeHTML(partnerGreeting)}</p>
      <p><strong>Vowntil recorded that Screen Time access was removed during an active lock.</strong></p>
      <blockquote style="border-left:4px solid #246854;margin:16px 0;padding:8px 14px;color:#263f37;background:#f4faf6">
        ${escapeHTML(payload.message)}
      </blockquote>
      <ul>
        ${summaryLines.map((line) => `<li>${escapeHTML(line)}</li>`).join("")}
      </ul>
      <p style="color:#5d6f68">This notice was sent because the Vowntil user configured you as their accountability partner.</p>
    </div>
  `;
  return { subject, text, html };
}

function sendResendEmail({ to, subject, text, html }) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      from: VOWNTIL_EMAIL_FROM,
      to: [to],
      subject,
      text,
      html,
      ...(VOWNTIL_EMAIL_REPLY_TO ? { reply_to: VOWNTIL_EMAIL_REPLY_TO } : {}),
    });
    const request = https.request({
      hostname: "api.resend.com",
      path: "/emails",
      method: "POST",
      headers: {
        Authorization: `Bearer ${RESEND_API_KEY}`,
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(body),
      },
    }, (response) => {
      let responseBody = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => {
        responseBody += chunk;
      });
      response.on("end", () => {
        if (response.statusCode >= 200 && response.statusCode < 300) {
          resolve(responseBody);
        } else {
          reject(new Error(`Resend HTTP ${response.statusCode}: ${responseBody.slice(0, 300)}`));
        }
      });
    });
    request.on("error", reject);
    request.setTimeout(15_000, () => {
      request.destroy(new Error("Resend request timed out"));
    });
    request.write(body);
    request.end();
  });
}

function verifyGarminWebhook(req) {
  if (!GARMIN_WEBHOOK_SHARED_SECRET) {
    return true;
  }

  const candidates = [
    req.headers.authorization?.replace(/^Bearer\s+/i, ""),
    req.headers["x-garmin-webhook-secret"],
    req.headers["x-garmin-signature"],
    req.headers["x-webhook-secret"],
    req.query.secret,
  ].filter(Boolean);

  return candidates.some((candidate) => safeTimingEqual(candidate, GARMIN_WEBHOOK_SHARED_SECRET));
}

function looksLikeDailySummary(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }
  return (
    value.calendarDate ||
    value.summaryDate ||
    value.startTimeInSeconds ||
    value.startTimeInMillis ||
    value.startTimeGMT ||
    value.activeKilocalories !== undefined ||
    value.activeCalories !== undefined ||
    value.totalKilocalories !== undefined ||
    value.steps !== undefined
  );
}

function collectDailySummaryCandidates(node, out = [], seen = new Set()) {
  if (!node || typeof node !== "object") {
    return out;
  }

  if (seen.has(node)) {
    return out;
  }
  seen.add(node);

  if (Array.isArray(node)) {
    node.forEach((item) => collectDailySummaryCandidates(item, out, seen));
    return out;
  }

  if (looksLikeDailySummary(node)) {
    out.push(node);
  }

  for (const value of Object.values(node)) {
    if (value && typeof value === "object") {
      collectDailySummaryCandidates(value, out, seen);
    }
  }
  return out;
}

function parseNumber(...values) {
  for (const value of values) {
    if (typeof value === "number" && Number.isFinite(value)) {
      return value;
    }
    if (typeof value === "string" && value.trim() && !Number.isNaN(Number(value))) {
      return Number(value);
    }
  }
  return null;
}

function normalizeSummaryDate(record) {
  const direct = record.calendarDate || record.summaryDate || record.date;
  if (typeof direct === "string" && /^\d{4}-\d{2}-\d{2}$/.test(direct)) {
    return direct;
  }

  const epochSeconds = parseNumber(
    record.startTimeInSeconds,
    record.startTimeEpochSeconds,
    record.startTimeUnix,
    record.summaryStartTimeInSeconds
  );
  if (epochSeconds) {
    return new Date(epochSeconds * 1000).toISOString().slice(0, 10);
  }

  const epochMillis = parseNumber(record.startTimeInMillis, record.startTimeGMT);
  if (epochMillis) {
    return new Date(epochMillis).toISOString().slice(0, 10);
  }

  return null;
}

function normalizedGarminSummary(record) {
  const date = normalizeSummaryDate(record);
  if (!date) {
    return null;
  }

  const activeCalories = parseNumber(
    record.activeKilocalories,
    record.activeCalories,
    record.activeKCalories,
    record.active_calories
  );

  if (activeCalories === null) {
    return null;
  }

  const steps = parseNumber(record.steps, record.totalSteps, record.stepCount);
  const totalCalories = parseNumber(
    record.totalKilocalories,
    record.totalCalories,
    record.totalKCalories,
    record.total_calories
  );

  return {
    date,
    activeCalories,
    steps: steps === null ? null : Math.round(steps),
    totalCalories,
  };
}

function storeGarminSummary(nomvaUserId, summary) {
  const user = garminStore.users[nomvaUserId];
  if (!user) {
    return false;
  }

  user.summaries = user.summaries || {};
  const existing = user.summaries[summary.date];

  // If we already have a summary for this day, only update it if the new one
  // seems more complete (has more calories or steps). This prevents a segmented
  // upload from overwriting a previously stored full-day snapshot.
  if (existing) {
    const isNewer = (summary.activeCalories || 0) > (existing.activeCalories || 0) ||
                    (summary.steps || 0) > (existing.steps || 0);
    
    if (!isNewer) {
      return false; // Keep existing data
    }
  }

  user.summaries[summary.date] = {
    date: summary.date,
    activeCalories: summary.activeCalories,
    steps: summary.steps,
    totalCalories: summary.totalCalories,
    updatedAt: new Date().toISOString(),
  };
  user.lastWebhookAt = new Date().toISOString();
  user.updatedAt = new Date().toISOString();
  return true;
}

function applyGarminPermissionsChange(change) {
  const garminUserId = extractGarminUserId(change);
  const nomvaUserId = garminUserId ? garminStore.garminUserIndex[String(garminUserId)] : null;
  const user = nomvaUserId ? garminStore.users[nomvaUserId] : null;
  if (!user) {
    return false;
  }

  user.permissions = Array.isArray(change?.permissions)
    ? change.permissions.map((value) => String(value))
    : [];
  user.lastPermissionChangeAt = new Date().toISOString();
  user.updatedAt = new Date().toISOString();
  return true;
}

function applyGarminDeregistrationNotice(entry) {
  const garminUserId = extractGarminUserId(entry);
  const nomvaUserId = garminUserId ? garminStore.garminUserIndex[String(garminUserId)] : null;
  const user = nomvaUserId ? garminStore.users[nomvaUserId] : null;
  if (!user) {
    return false;
  }

  if (garminUserId) {
    delete garminStore.garminUserIndex[String(garminUserId)];
    user.lastDisconnectedGarminUserId = String(garminUserId);
  }

  user.garminUserId = null;
  user.accessToken = null;
  user.tokenSecret = null;
  user.permissions = [];
  user.disconnectedAt = new Date().toISOString();
  user.updatedAt = new Date().toISOString();
  return true;
}

function recentGarminSummaries(user, limit = 35) {
  return Object.values(user?.summaries || {})
    .sort((a, b) => b.date.localeCompare(a.date))
    .slice(0, limit);
}

function garminUserForRequest(req) {
  const nomvaUserId = normalizeIdentifier(req.headers["x-nomva-user-id"]);
  const deviceToken = req.headers["x-nomva-device-token"];

  if (!nomvaUserId || typeof deviceToken !== "string" || !deviceToken.trim()) {
    return { error: "missing_identity" };
  }

  const user = garminStore.users[nomvaUserId];
  if (!user) {
    return { nomvaUserId, user: null };
  }

  if (!user.deviceTokenHash || user.deviceTokenHash !== hashDeviceToken(deviceToken)) {
    return { error: "invalid_identity" };
  }

  return { nomvaUserId, user };
}

// ── Static files (privacy, support, logo) ────────────────────────────────────
app.get(["/", "/index.html"], (_req, res) => {
  res.sendFile(path.join(publicDir, "index.html"));
});

app.use(express.static(publicDir));

// Rate limit: 120 requests per minute per IP (generous for a single user)
app.use(
  rateLimit({
    windowMs: 60_000,
    max: 120,
    standardHeaders: true,
    legacyHeaders: false,
    skip: (req) => timingSafeEqualSecret(
      req.headers["x-nomva-automation-token"],
      NOMVA_AUTOMATION_TOKEN
    ),
  })
);

const appAuthLimiter = rateLimit({
  windowMs: 15 * 60_000,
  max: 60,
  standardHeaders: true,
  legacyHeaders: false,
  skip: (req) => timingSafeEqualSecret(
    req.headers["x-nomva-automation-token"],
    NOMVA_AUTOMATION_TOKEN
  ),
});

const vowntilBreachLimiter = rateLimit({
  windowMs: 60_000,
  max: 8,
  standardHeaders: true,
  legacyHeaders: false,
});

const foodWebLookupLimiter = rateLimit({
  windowMs: 60_000,
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
});

app.post("/vowntil/v1/breach", vowntilBreachLimiter, async (req, res) => {
  if (!vowntilTokenIsValid(req)) {
    return res.status(401).json({ error: "invalid_vowntil_token" });
  }

  const payload = sanitizeVowntilBreachPayload(req.body);
  if (payload.error) {
    return res.status(400).json({ error: payload.error });
  }

  if (!RESEND_API_KEY || !VOWNTIL_EMAIL_FROM) {
    return res.status(503).json({ error: "email_not_configured" });
  }

  const email = buildVowntilBreachEmail(payload);
  try {
    await sendResendEmail({
      to: payload.partnerEmail,
      subject: email.subject,
      text: email.text,
      html: email.html,
    });
    return res.json({ status: "sent" });
  } catch (error) {
    console.error("vowntil breach email error:", error.message);
    return res.status(502).json({ error: "email_send_failed" });
  }
});

app.post("/v1/auth/challenge", appAuthLimiter, (req, res) => {
  const nomvaUserId = normalizeIdentifier(req.headers["x-nomva-user-id"] || req.body?.nomvaUserId);
  const deviceToken = typeof req.headers["x-nomva-device-token"] === "string"
    ? req.headers["x-nomva-device-token"]
    : typeof req.body?.deviceToken === "string"
      ? req.body.deviceToken
      : "";

  if (!nomvaUserId || !deviceToken.trim()) {
    return res.status(400).json({ error: "missing_identity" });
  }

  return res.json(createAppAttestChallenge(nomvaUserId, deviceToken));
});

app.post("/v1/auth/verify", appAuthLimiter, (req, res) => {
  const identity = appAttestIdentityFromRequest(req);
  if (identity.error) {
    return res.status(400).json({ error: identity.error });
  }

  const challenge = typeof req.body?.challenge === "string" ? req.body.challenge : "";
  const keyId = typeof req.body?.keyId === "string" ? req.body.keyId : "";
  const attestation = typeof req.body?.attestation === "string" ? req.body.attestation : "";

  if (!challenge || !keyId || !attestation) {
    return res.status(400).json({ error: "invalid_attestation_request" });
  }

  if (!consumeAppAttestChallenge(challenge, identity.identityKey)) {
    return res.status(401).json({ error: "invalid_challenge" });
  }

  try {
    const result = verifyAttestation({
      attestation: Buffer.from(attestation, "base64"),
      challenge,
      keyId,
      bundleIdentifier: APP_ATTEST_BUNDLE_ID,
      teamIdentifier: APP_ATTEST_TEAM_ID,
      allowDevelopmentEnvironment: APP_ATTEST_ALLOW_DEVELOPMENT,
    });

    upsertAppAttestation(identity.identityKey, {
      keyId,
      publicKey: result.publicKey,
      signCount: 0,
      environment: result.environment,
      createdAt: appAttestStore.identities[identity.identityKey]?.createdAt || new Date().toISOString(),
      lastAssertedAt: null,
    });

    return res.sendStatus(204);
  } catch (error) {
    return res.status(401).json({ error: "invalid_attestation" });
  }
});

app.use("/v1", (req, res, next) => {
  if (req.path === "/auth/challenge" || req.path === "/auth/verify") {
    return next();
  }

  const identity = appAttestIdentityFromRequest(req);
  if (identity.error) {
    return res.status(400).json({ error: identity.error });
  }

  const nonAttestedTrust = resolveNonAttestedTrust({
    headers: req.headers,
    remoteAddress: req.socket?.remoteAddress,
    nodeEnv: process.env.NODE_ENV,
    allowSimulatorAuth: ALLOW_SIMULATOR_AUTH,
    automationToken: NOMVA_AUTOMATION_TOKEN,
  });
  if (nonAttestedTrust.error) {
    return res.status(401).json({ error: nonAttestedTrust.error });
  }
  if (nonAttestedTrust.trust) {
    req.nomvaUserId = identity.nomvaUserId;
    req.nomvaDeviceToken = identity.deviceToken;
    req.nomvaAppTrust = nonAttestedTrust.trust;
    return next();
  }

  const attestationHeader = parseAppAttestHeader(req.headers["x-nomva-app-attest"]);
  if (!attestationHeader?.keyId || !attestationHeader.assertion || !attestationHeader.timestamp) {
    return res.status(401).json({ error: "app_attest_required" });
  }

  if (!appAttestTimestampIsFresh(attestationHeader.timestamp)) {
    return res.status(401).json({ error: "stale_app_attest" });
  }

  const stored = appAttestStore.identities[identity.identityKey];
  if (!stored || stored.keyId !== attestationHeader.keyId) {
    return res.status(401).json({ error: "invalid_app_attest" });
  }
  if (process.env.NODE_ENV === "production" && stored.environment !== "production") {
    return res.status(401).json({ error: "invalid_app_attest" });
  }

  try {
    const result = verifyAssertion({
      assertion: Buffer.from(attestationHeader.assertion, "base64"),
      payload: appAttestPayloadForRequest(
        req,
        attestationHeader.timestamp,
        identity.nomvaUserId,
        identity.deviceToken
      ),
      publicKey: stored.publicKey,
      bundleIdentifier: APP_ATTEST_BUNDLE_ID,
      teamIdentifier: APP_ATTEST_TEAM_ID,
      signCount: stored.signCount || 0,
    });

    stored.signCount = result.signCount;
    stored.lastAssertedAt = new Date().toISOString();
    stored.updatedAt = new Date().toISOString();
    persistAppAttestStore();

    req.nomvaUserId = identity.nomvaUserId;
    req.nomvaDeviceToken = identity.deviceToken;
    req.nomvaAppTrust = {
      mode: "app_attest",
      environment: stored.environment || "unknown",
      keyId: stored.keyId,
    };
    return next();
  } catch (_error) {
    return res.status(401).json({ error: "invalid_app_attest" });
  }
});

app.post("/v1/auth/register", appAuthLimiter, async (req, res) => {
  const nomvaUserId = req.nomvaUserId || normalizeIdentifier(req.headers["x-nomva-user-id"] || req.body?.nomvaUserId);
  const deviceToken = req.nomvaDeviceToken || (
    typeof req.headers["x-nomva-device-token"] === "string"
      ? req.headers["x-nomva-device-token"]
      : typeof req.body?.deviceToken === "string"
        ? req.body.deviceToken
        : ""
  );

  if (!nomvaUserId || !deviceToken.trim()) {
    return res.status(400).json({ error: "missing_identity" });
  }

  const evidence = req.body?.entitlementEvidence || {};
  let entitlement;
  try {
    entitlement = await appStoreEntitlementVerifier.evaluate({
      trustMode: req.nomvaAppTrust?.mode,
      appAttestEnvironment: req.nomvaAppTrust?.environment,
      nomvaUserId,
      appTransactionJWS: evidence.appTransactionJWS,
      subscriptionTransactionJWS: evidence.subscriptionTransactionJWS,
    });
  } catch (error) {
    console.error("App Store entitlement verification failed:", error);
    return res.status(503).json({ error: "entitlement_verification_unavailable" });
  }

  if (ENTITLEMENT_MODE === "enforce" && !entitlementIsActive(entitlement)) {
    return res.status(403).json({
      error: "entitlement_required",
      entitlementStatus: entitlement.status,
    });
  }

  const session = issueAppSession(nomvaUserId, deviceToken, {
    trust: req.nomvaAppTrust,
    entitlement,
  });
  return res.json({
    token: session.token,
    expiresAt: session.expiresAt,
    entitlement: session.entitlement,
  });
});

// Require a valid server-issued app session for all other API routes.
app.use("/v1", (req, res, next) => {
  if (req.path.startsWith("/auth/")) {
    return next();
  }

  const session = appSessionForRequest(req);
  if (session.error) {
    return res.status(401).json({ error: session.error });
  }

  req.nomvaUserId = session.nomvaUserId;
  req.nomvaSession = session.session;
  req.nomvaSessionTokenHash = session.tokenHash;
  if (ENTITLEMENT_MODE === "enforce" && !entitlementIsActive(session.session.entitlement)) {
    return res.status(401).json({ error: "entitlement_refresh_required" });
  }
  return next();
});

const AI_ROUTE_PATHS = new Set([
  "/classify-intent",
  "/split-foods",
  "/plan-food-log",
  "/resolve-food-candidate",
  "/search-food-catalog",
  "/build-food-search-query",
  "/choose-food-candidate",
  "/validate-food-candidate",
  "/confirm-match",
  "/extract-servings",
  "/extract-meal",
  "/extract-water-mutation",
  "/extract-weight-mutation",
  "/extract-food-move",
  "/pick-delete-targets",
  "/pick-edit-target",
  "/resolve-edit-request",
  "/estimate-grams",
  "/find-food-step",
  "/extract-goal",
  "/parse-data-query",
  "/general-reply",
  "/suggest-recent-foods",
  "/analyze-photo",
]);

function consumePersistentRequestBudget(req, res, { scope, max, windowMs }) {
  const userHash = hashDeviceToken(req.nomvaUserId).slice(0, 32);
  const result = stateStore.consumeRateLimit({
    scopeKey: `${scope}:${userHash}`,
    windowMs,
    max,
  });
  res.setHeader(`X-Nomva-${scope}-Limit`, String(max));
  res.setHeader(`X-Nomva-${scope}-Remaining`, String(result.remaining));
  res.setHeader(`X-Nomva-${scope}-Reset`, String(Math.ceil(result.resetAt / 1_000)));
  if (!result.allowed) {
    res.setHeader("Retry-After", String(Math.max(1, Math.ceil((result.resetAt - Date.now()) / 1_000))));
  }
  return result.allowed;
}

app.use("/v1", (req, res, next) => {
  if (!AI_ROUTE_PATHS.has(req.path)) {
    return next();
  }
  if (["automation", "local_simulator"].includes(req.nomvaSession?.trustMode)) {
    return next();
  }

  const dailyAllowed = consumePersistentRequestBudget(req, res, {
    scope: "AI-Daily",
    max: AI_REQUESTS_PER_DAY,
    windowMs: 24 * 60 * 60 * 1_000,
  });
  const photoAllowed = req.path !== "/analyze-photo" || consumePersistentRequestBudget(req, res, {
    scope: "Photo-Daily",
    max: PHOTO_REQUESTS_PER_DAY,
    windowMs: 24 * 60 * 60 * 1_000,
  });
  if (!dailyAllowed || !photoAllowed) {
    return res.status(429).json({ error: "daily_ai_limit_reached" });
  }
  return next();
});

// ── Request logging ──────────────────────────────────────────────────────────

function summarizeRequestBody(body = {}) {
  const summary = {};

  if (typeof body.userMessage === "string") {
    summary.userMessageChars = body.userMessage.length;
  }
  if (typeof body.context === "string") {
    summary.contextChars = body.context.length;
  }
  if (Array.isArray(body.recentMessages)) {
    summary.recentMessages = body.recentMessages.length;
  }
  if (typeof body.foodMention === "string") {
    summary.foodMentionChars = body.foodMention.length;
  }
  if (["single", "composite", "menu"].includes(body.resolutionHint)) {
    summary.resolutionHint = body.resolutionHint;
  }
  if (typeof body.candidateName === "string") {
    summary.candidateNameChars = body.candidateName.length;
  }
  if (typeof body.logSummary === "string") {
    summary.logSummaryChars = body.logSummary.length;
  }
  if (typeof body.foodName === "string") {
    summary.foodNameChars = body.foodName.length;
  }
  if (typeof body.portionDescription === "string") {
    summary.portionDescriptionChars = body.portionDescription.length;
  }

  return summary;
}

app.use("/v1", (req, res, next) => {
  const start = Date.now();
  let responseBytes = 0;
  const orig = res.json.bind(res);
  res.json = (body) => {
    const ms = Date.now() - start;
    const requestSummary = summarizeRequestBody(req.body);
    responseBytes = Buffer.byteLength(JSON.stringify(body ?? {}));
    console.log(
      `[${new Date().toISOString()}] ${req.method} ${req.path} ` +
      `| ${ms}ms | ` +
      `request=${JSON.stringify(requestSummary)}`
    );
    return orig(body);
  };
  res.on("finish", () => {
    if (res.locals.skipAnalytics) {
      return;
    }
    const durationMs = Date.now() - start;
    const status = res.statusCode;
    analyticsStore.record({
      source: "server",
      eventType: "server_request",
      userHash: analyticsUserHash(req.nomvaUserId),
      sessionHash: analyticsSessionHash(req),
      route: req.path,
      method: req.method,
      status,
      durationMs,
      bytesIn: Buffer.isBuffer(req.rawBody) ? req.rawBody.length : 0,
      bytesOut: responseBytes || Number(res.getHeader("content-length")) || null,
      success: status >= 200 && status < 400,
      errorCode: status >= 400 ? (res.locals.analyticsErrorCode || `http_${status}`) : null,
      properties: {
        authMode: req.nomvaAppTrust?.mode || null,
        ...summarizeRequestBody(req.body),
      },
    });
  });
  next();
});

// ── OpenAI client ────────────────────────────────────────────────────────────

// Per-attempt timeout and a single SDK-level network retry. Without an
// explicit timeout the SDK waits up to 10 minutes, which lets nginx and the
// iOS client (15-30s budgets) give up first while tokens keep burning.
const LLM_ATTEMPT_TIMEOUT_MS = Number(process.env.NOMVA_LLM_ATTEMPT_TIMEOUT_MS || 10_000);
const openai = new OpenAI({
  apiKey: process.env.OPENAI_API_KEY,
  timeout: LLM_ATTEMPT_TIMEOUT_MS,
  maxRetries: 1,
});
const webFoodOpenAI = new OpenAI({
  apiKey: process.env.OPENAI_API_KEY,
  timeout: Number(process.env.NOMVA_WEB_FOOD_TIMEOUT_MS || 18_000),
  maxRetries: 0,
});

function webFoodResolverForRequest(req, foodMention = "") {
  const configuredSearchContext = String(
    process.env.NOMVA_WEB_FOOD_SEARCH_CONTEXT_SIZE || "low"
  ).toLowerCase();
  const requiresExactSizeResearch = requiresExactMenuResearch(foodMention);
  const selectedModel = requiresExactSizeResearch ? WEB_FOOD_PUBLISHED_MODEL : WEB_FOOD_MODEL;
  return createWebFoodResolver({
    openai: webFoodOpenAI,
    knowledgeStore: foodKnowledgeStore,
    model: selectedModel,
    searchContextSize: ["low", "medium", "high"].includes(configuredSearchContext)
      ? configuredSearchContext
      : "low",
    reasoningEffort: process.env.NOMVA_WEB_FOOD_REASONING_EFFORT || "none",
    onEvent: (event) => {
      const success = event.type === "resolved" || event.type === "no_match";
      analyticsStore.record({
        source: "server",
        eventType: "llm_call",
        userHash: analyticsUserHash(req.nomvaUserId),
        sessionHash: analyticsSessionHash(req),
        route: req.path,
        model: event.model || selectedModel,
        llmTask: "resolve_web_food",
        durationMs: event.durationMs,
        totalTokens: event.usage?.total_tokens || null,
        success,
        errorCode: event.type === "error" ? `openai_${event.error?.status || "error"}` : null,
        properties: {
          resultType: event.type,
          reason: event.reason || null,
          quality: event.quality || null,
        },
      });
    },
  });
}

const backgroundFoodRefreshes = new Map();

function scheduleWebFoodRefresh(req, userMessage, foodMention) {
  const key = String(foodMention || "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
  if (!key || backgroundFoodRefreshes.has(key)) return;

  const abort = new AbortController();
  const timeout = setTimeout(() => abort.abort(), Number(
    process.env.NOMVA_BACKGROUND_FOOD_REFRESH_TIMEOUT_MS || 22_000
  ));
  const task = webFoodResolverForRequest(req, foodMention).resolve({
    userMessage,
    foodMention,
    signal: abort.signal,
    allowCached: false,
  }).catch((error) => {
    if (error?.name !== "AbortError") {
      console.warn("background food refresh warning:", error.message);
    }
  }).finally(() => {
    clearTimeout(timeout);
    backgroundFoodRefreshes.delete(key);
  });
  backgroundFoodRefreshes.set(key, task);
}

class EmptyCompletionError extends Error {
  constructor(model) {
    super(`empty completion from ${model}`);
    this.name = "EmptyCompletionError";
    this.code = "llm_empty_completion";
  }
}

async function ask(systemPrompt, userMessage, opts = {}) {
  const maxTokens = opts.maxTokens || 256;
  const requestModel = opts.model || MODEL;
  const completionBudget = /^gpt-5/i.test(requestModel)
    ? Math.max(maxTokens * 4, 512)
    : maxTokens;
  const structuredOutput = structuredOutputForTask(opts.task);
  if (structuredOutput) {
    return askStructured(
      systemPrompt,
      userMessage,
      structuredOutput.name,
      structuredOutput.schema,
      {
        ...opts,
        model: requestModel,
        maxOutputTokens: opts.maxOutputTokens || completionBudget,
        reasoningEffort: opts.reasoningEffort || structuredOutput.reasoningEffort,
        maxRetries: opts.maxRetries ?? 0,
      }
    );
  }
  const startedAt = Date.now();
  const llmTask = opts.task || "unknown";
  console.log(`  → OpenAI call (${requestModel}) | promptChars=${userMessage.length} | maxTokens=${completionBudget}`);
  try {
    const request = {
      model: requestModel,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userMessage },
      ],
    };
    if (/^gpt-5/i.test(requestModel)) {
      request.max_completion_tokens = completionBudget;
      if (opts.reasoningEffort) request.reasoning_effort = opts.reasoningEffort;
    } else {
      request.temperature = 0.1;
      request.max_tokens = completionBudget;
    }

    // Reasoning-class models routinely return an empty content field when the
    // token budget is consumed by reasoning. One immediate retry (with a
    // larger budget) recovers most of those instead of failing the request.
    let response = null;
    let text = null;
    const maxAttempts = Math.max(1, Math.min(2, Number(opts.maxAttempts || 2)));
    for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
      if (attempt === 1 && /^gpt-5/i.test(requestModel)) {
        request.max_completion_tokens = completionBudget * 2;
      }
      const requestOptions = {};
      if (opts.signal) requestOptions.signal = opts.signal;
      if (opts.timeoutMs) requestOptions.timeout = opts.timeoutMs;
      if (opts.maxRetries !== undefined) requestOptions.maxRetries = opts.maxRetries;
      response = await openai.chat.completions.create(
        { ...request },
        Object.keys(requestOptions).length ? requestOptions : undefined
      );
      text = response.choices?.[0]?.message?.content?.trim() || null;
      if (text) break;
      console.warn(`  ⚠ empty completion (${requestModel}, attempt ${attempt + 1})`);
    }
    if (!text) {
      throw new EmptyCompletionError(requestModel);
    }
    const usage = response.usage;
    console.log(`  ← OpenAI response | chars=${text?.length || 0} | tokens=${usage?.total_tokens || "?"}`);
    const parsed = JSON.parse(text);
    analyticsStore.record({
      source: "server",
      eventType: "llm_call",
      userHash: opts.userHash || null,
      sessionHash: opts.sessionHash || null,
      route: opts.route || null,
      model: requestModel,
      llmTask,
      durationMs: Date.now() - startedAt,
      promptChars: userMessage.length,
      responseChars: text?.length || 0,
      totalTokens: usage?.total_tokens || null,
      success: true,
      properties: {
        maxTokens: completionBudget,
        promptSystemChars: systemPrompt.length,
      },
    });
    return parsed;
  } catch (error) {
    analyticsStore.record({
      source: "server",
      eventType: "llm_call",
      userHash: opts.userHash || null,
      sessionHash: opts.sessionHash || null,
      route: opts.route || null,
      model: requestModel,
      llmTask,
      durationMs: Date.now() - startedAt,
      promptChars: userMessage.length,
      success: false,
      errorCode: error instanceof EmptyCompletionError
        ? "llm_empty_completion"
        : error instanceof SyntaxError || error instanceof TypeError
          ? "llm_json_parse_error"
          : error?.status
            ? `openai_${error.status}`
            : "openai_error",
      properties: {
        maxTokens,
      },
    });
    throw error;
  }
}

async function askStructured(systemPrompt, userMessage, schemaName, schema, opts = {}) {
  const requestModel = opts.model || MODEL;
  const maxOutputTokens = Math.max(64, Number(opts.maxOutputTokens) || 1_000);
  const promptChars = Number.isFinite(opts.promptChars)
    ? Math.max(0, opts.promptChars)
    : typeof userMessage === "string"
      ? userMessage.length
      : 0;
  const startedAt = Date.now();
  const llmTask = opts.task || "unknown";
  console.log(
    `  → OpenAI Responses call (${requestModel}) | promptChars=${promptChars} | schema=${schemaName}`
  );

  try {
    const result = await requestStructuredJSON({
      openai,
      model: requestModel,
      instructions: systemPrompt,
      input: userMessage,
      schemaName,
      schema,
      maxOutputTokens,
      reasoningEffort: opts.reasoningEffort,
      signal: opts.signal,
      timeoutMs: opts.timeoutMs,
      maxRetries: opts.maxRetries,
      safetyIdentifier: opts.userHash,
      cacheKey: opts.cacheKey || `nomva_${llmTask}_v1`,
    });
    const usage = result.response?.usage;
    console.log(
      `  ← OpenAI Responses output | chars=${result.text.length} | tokens=${usage?.total_tokens || "?"}`
    );
    analyticsStore.record({
      source: "server",
      eventType: "llm_call",
      userHash: opts.userHash || null,
      sessionHash: opts.sessionHash || null,
      route: opts.route || null,
      model: requestModel,
      llmTask,
      durationMs: Date.now() - startedAt,
      promptChars,
      responseChars: result.text.length,
      totalTokens: usage?.total_tokens || null,
      success: true,
      properties: {
        api: "responses",
        schemaName,
        maxOutputTokens,
        promptSystemChars: systemPrompt.length,
      },
    });
    return result.value;
  } catch (error) {
    analyticsStore.record({
      source: "server",
      eventType: "llm_call",
      userHash: opts.userHash || null,
      sessionHash: opts.sessionHash || null,
      route: opts.route || null,
      model: requestModel,
      llmTask,
      durationMs: Date.now() - startedAt,
      promptChars,
      success: false,
      errorCode: error instanceof EmptyStructuredResponseError
        ? "llm_empty_structured_response"
        : error instanceof SyntaxError || error instanceof TypeError
          ? "llm_json_parse_error"
          : error?.status
            ? `openai_${error.status}`
            : "openai_error",
      properties: {
        api: "responses",
        schemaName,
        maxOutputTokens,
      },
    });
    throw error;
  }
}

// Distinguishes "the model is unavailable / returned nothing" (503, client
// may auto-retry) from a genuine server fault (500). Never leaks err.message.
function respondLLMFailure(res, err, code) {
  console.error(`${code}:`, err.message);
  const upstreamUnavailable = err instanceof EmptyCompletionError
    || err instanceof EmptyStructuredResponseError
    || err?.status === 429
    || (typeof err?.status === "number" && err.status >= 500)
    || err?.name === "APIConnectionTimeoutError"
    || err?.name === "APIConnectionError";
  if (upstreamUnavailable) {
    return res.status(503).json({ error: "llm_unavailable", source: code });
  }
  return res.status(500).json({ error: code });
}

function llmAnalyticsOptions(req, task, extra = {}) {
  return {
    ...extra,
    task,
    route: req.path,
    userHash: analyticsUserHash(req.nomvaUserId),
    sessionHash: analyticsSessionHash(req),
  };
}

// ── Routes ───────────────────────────────────────────────────────────────────

// Health check (no auth required)
app.get("/health", (_req, res) => res.json({
  status: "ok",
  foodDb: {
    available: foodSearchStore.isAvailable,
    rows: foodSearchStore.rowCount ?? null,
    error: foodSearchStore.error || null,
  },
  foodKnowledge: foodKnowledgeStore.stats(),
  security: {
    appAttestDevelopmentAllowed: APP_ATTEST_ALLOW_DEVELOPMENT,
    automationConfigured: Boolean(NOMVA_AUTOMATION_TOKEN),
    entitlementMode: ENTITLEMENT_MODE,
    appStoreVerificationConfigured: appStoreEntitlementVerifier.configured,
  },
}));

app.get("/food-estimates", (_req, res) => {
  res.type("html").send(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Nomva Nutrition Estimates</title><style>
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;max-width:680px;margin:0 auto;padding:48px 24px;line-height:1.55;color:#1b1b1f;background:#fff}h1{font-size:32px}h2{font-size:20px;margin-top:32px}a{color:#9d3e00}@media(prefers-color-scheme:dark){body{color:#f2f2f5;background:#151518}a{color:#ff9a52}}
</style></head><body><h1>Nomva Nutrition Estimates</h1>
<p>When a meal has no exact database or published menu match, Nomva may estimate one ordinary serving from the foods and portions the user described.</p>
<h2>How estimates work</h2><p>The AI interprets the complete meal, applies common ingredient portions, checks that calories and macronutrients agree, records its assumptions, and caps confidence below published-data confidence. Estimated entries are labeled <strong>estimated</strong> in the app.</p>
<h2>Important limitation</h2><p>Recipes and serving sizes vary. These values are useful logging approximations, not laboratory measurements or medical advice. Edit the entry when you know the recipe, package label, or measured portion.</p></body></html>`);
});

app.get("/analytics/summary", (req, res) => {
  if (!ANALYTICS_ADMIN_TOKEN) {
    return res.sendStatus(404);
  }

  const token = req.headers.authorization?.replace(/^Bearer\s+/i, "") || req.query.token;
  if (!token || !safeTimingEqual(token, ANALYTICS_ADMIN_TOKEN)) {
    return res.status(401).json({ error: "unauthorized" });
  }

  return res.json(analyticsStore.summary({ hours: req.query.hours }));
});

app.post("/v1/analytics/events", (req, res) => {
  const events = Array.isArray(req.body?.events) ? req.body.events.slice(0, 50) : [];
  if (!events.length) {
    return res.json({ ok: true, stored: 0 });
  }

  const userHash = analyticsUserHash(req.nomvaUserId);
  const sessionHash = analyticsSessionHash(req);
  const stored = analyticsStore.recordBatch(events.map((event) => ({
    id: event.id,
    eventTime: event.eventTime,
    source: "ios",
    eventType: event.eventType || "client_network",
    userHash,
    sessionHash,
    route: event.route,
    method: event.method,
    status: event.status,
    durationMs: event.durationMs,
    bytesIn: event.bytesIn,
    bytesOut: event.bytesOut,
    success: event.success,
    errorCode: event.errorCode,
    properties: event.properties,
  })));

  return res.json({ ok: true, stored });
});

app.delete("/v1/privacy/analytics", (req, res) => {
  res.locals.skipAnalytics = true;
  const userHash = analyticsUserHash(req.nomvaUserId);
  const deleted = analyticsStore.deleteUser(userHash);
  return res.json({ ok: true, deleted });
});

// Garmin OAuth 1.0a start (requested by the iOS app after Nomva Cloud auth)
app.post("/v1/garmin/oauth/start", async (req, res) => {
  cleanupExpiredGarminStates();

  if (!garminIsConfigured()) {
    return res.status(503).json({ error: "garmin_not_configured" });
  }

  const nomvaUserId = req.nomvaUserId || normalizeIdentifier(req.body?.nomvaUserId);
  const deviceToken = req.nomvaDeviceToken || (typeof req.body?.deviceToken === "string" ? req.body.deviceToken : "");
  const returnScheme = sanitizeCallbackScheme(req.body?.returnScheme || req.body?.return_scheme);

  if (!nomvaUserId || !deviceToken.trim()) {
    return res.status(400).json({ error: "missing_identity" });
  }

  ensureGarminUserRecord(nomvaUserId, deviceToken);

  try {
    // Step 1: Get a request token from Garmin
    const requestToken = await getGarminRequestToken();
    if (!requestToken.oauthToken) {
      throw new Error("Garmin did not return a request token.");
    }

    // Store the request token secret so we can use it in the callback
    garminStore.states[requestToken.oauthToken] = {
      nomvaUserId,
      deviceTokenHash: hashDeviceToken(deviceToken),
      returnScheme,
      oauthTokenSecret: requestToken.oauthTokenSecret,
      createdAt: new Date().toISOString(),
    };
    persistGarminStore();

    const authorizeUrl = `${GARMIN_AUTHORIZE_URL}?oauth_token=${oauth1PercentEncode(requestToken.oauthToken)}`;
    return res.json({ url: authorizeUrl });
  } catch (err) {
    console.error("garmin oauth start error:", err.message);
    return res.status(500).json({ error: "garmin_start_failed" });
  }
});

// Garmin OAuth 1.0a callback (also handle the old /garmin/oauth/callback path)
app.get(["/garmin/callback", "/garmin/oauth/callback"], async (req, res) => {
  cleanupExpiredGarminStates();

  const oauthToken = req.query.oauth_token;
  const oauthVerifier = req.query.oauth_verifier;

  // Look up by oauth_token (that's what we keyed on in the start step)
  const pending = typeof oauthToken === "string" ? garminStore.states[oauthToken] : null;

  if (!pending) {
    return res.status(400).send("Garmin connection state is invalid or expired.");
  }

  delete garminStore.states[oauthToken];

  if (!oauthVerifier) {
    persistGarminStore();
    return res.redirect(buildGarminAppRedirectURL({
      scheme: pending.returnScheme,
      status: "error",
      message: "Garmin did not authorize the connection.",
    }));
  }

  try {
    // Step 3: Exchange request token + verifier for an access token
    const accessTokenResult = await getGarminAccessToken(
      oauthToken,
      pending.oauthTokenSecret,
      oauthVerifier
    );

    if (!accessTokenResult.oauthToken) {
      throw new Error("Garmin did not return an access token.");
    }

    const user = garminStore.users[pending.nomvaUserId];
    if (!user || user.deviceTokenHash !== pending.deviceTokenHash) {
      persistGarminStore();
      return res.redirect(buildGarminAppRedirectURL({
        scheme: pending.returnScheme,
        status: "error",
        message: "Nomva Cloud could not match this Garmin session to the app.",
      }));
    }

    // Store both token and token secret (needed for all OAuth 1.0a API calls)
    user.accessToken = accessTokenResult.oauthToken;
    user.tokenSecret = accessTokenResult.oauthTokenSecret;
    user.connectedAt = user.connectedAt || new Date().toISOString();
    user.updatedAt = new Date().toISOString();

    // Fetch user profile to get Garmin user ID
    const garminProfile = await fetchGarminUserProfile(user.accessToken, user.tokenSecret);
    user.permissions = garminProfile.permissions;

    if (garminProfile.userId) {
      if (user.garminUserId && user.garminUserId !== garminProfile.userId) {
        delete garminStore.garminUserIndex[user.garminUserId];
      }
      user.garminUserId = garminProfile.userId;
      garminStore.garminUserIndex[garminProfile.userId] = pending.nomvaUserId;
    }

    persistGarminStore();
    console.log("garmin: connection completed successfully");
    return res.redirect(buildGarminAppRedirectURL({
      scheme: pending.returnScheme,
      status: "success",
      message: "Garmin connected to Nomva.",
    }));
  } catch (callbackError) {
    console.error("garmin oauth callback error:", callbackError.message);
    persistGarminStore();
    return res.redirect(buildGarminAppRedirectURL({
      scheme: pending.returnScheme,
      status: "error",
      message: callbackError.message || "Garmin token exchange failed.",
    }));
  }
});

function handleGarminWebhook(req, res) {
  if (!verifyGarminWebhook(req)) {
    return res.status(401).json({ error: "invalid_webhook_secret" });
  }

  const permissionChanges = Array.isArray(req.body?.userPermissionsChange)
    ? req.body.userPermissionsChange
    : [];
  const deregistrations = Array.isArray(req.body?.deregistrations)
    ? req.body.deregistrations
    : [];
  const candidates = collectDailySummaryCandidates(req.body);
  let stored = 0;
  let ignored = 0;
  let permissionUpdates = 0;
  let deregistered = 0;
  const unmappedGarminUsers = new Set();

  for (const change of permissionChanges) {
    if (applyGarminPermissionsChange(change)) {
      permissionUpdates += 1;
      continue;
    }

    const garminUserId = extractGarminUserId(change);
    if (garminUserId) {
      unmappedGarminUsers.add(String(garminUserId));
    }
  }

  for (const entry of deregistrations) {
    if (applyGarminDeregistrationNotice(entry)) {
      deregistered += 1;
      continue;
    }

    const garminUserId = extractGarminUserId(entry);
    if (garminUserId) {
      unmappedGarminUsers.add(String(garminUserId));
    }
  }

  for (const candidate of candidates) {
    const summary = normalizedGarminSummary(candidate);
    if (!summary) {
      ignored += 1;
      continue;
    }

    const garminUserId = extractGarminUserId(candidate) || extractGarminUserId(req.body);
    const nomvaUserId = garminUserId ? garminStore.garminUserIndex[String(garminUserId)] : null;

    if (!nomvaUserId || !storeGarminSummary(nomvaUserId, summary)) {
      ignored += 1;
      if (garminUserId) {
        unmappedGarminUsers.add(String(garminUserId));
      }
      continue;
    }

    const user = garminStore.users[nomvaUserId];
    if (garminUserId && user && !user.garminUserId) {
      user.garminUserId = String(garminUserId);
      garminStore.garminUserIndex[String(garminUserId)] = nomvaUserId;
    }
    stored += 1;
  }

  persistGarminStore();
  return res.json({
    ok: true,
    stored,
    ignored,
    permissionUpdates,
    deregistered,
    unmappedGarminUsers: Array.from(unmappedGarminUsers),
  });
}

// Garmin webhook endpoints for pushed summary, permission, and deregistration data
app.post("/garmin/webhook", handleGarminWebhook);
app.post("/garmin/user-permissions", handleGarminWebhook);
app.post("/garmin/deregistrations", handleGarminWebhook);

app.get("/v1/garmin/status", (req, res) => {
  const identity = garminUserForRequest(req);
  if (identity.error === "missing_identity") {
    return res.status(400).json({ error: "missing_identity" });
  }
  if (identity.error === "invalid_identity") {
    return res.status(401).json({ error: "invalid_identity" });
  }

  const days = Math.max(7, Math.min(90, parseInt(req.query.days || "35", 10) || 35));
  const averageWindowDays = 28;
  const summariesForAverage = recentGarminSummaries(
    identity.user,
    Math.max(days, averageWindowDays + 7)
  );
  const average = computeGarminAverages(summariesForAverage, {
    windowDays: averageWindowDays,
    currentLocalDate: req.query.localDate,
  });
  const summaries = summariesForAverage.slice(0, days);

  return res.json({
    configured: garminIsConfigured(),
    connected: Boolean(identity.user?.accessToken),
    connectedAt: identity.user?.connectedAt || null,
    lastWebhookAt: identity.user?.lastWebhookAt || null,
    garminUserIdKnown: Boolean(identity.user?.garminUserId),
    permissions: identity.user?.permissions || [],
    averageActiveCalories: average.averageActiveCalories,
    sampledDays: average.sampledDays,
    averageWindowDays: average.windowDays,
    averageThroughDate: average.averageThroughDate,
    recentSummaries: summaries,
    latestSummary: summaries[0] || null,
  });
});

// ── Manual pull of today's daily summary from Garmin Wellness API ────────────
const GARMIN_DAILIES_URL = process.env.GARMIN_DAILIES_URL || "https://healthapi.garmin.com/wellness-api/rest/dailies";

app.post("/v1/garmin/sync", async (req, res) => {
  const identity = garminUserForRequest(req);
  if (identity.error === "missing_identity") {
    return res.status(400).json({ error: "missing_identity" });
  }
  if (identity.error === "invalid_identity") {
    return res.status(401).json({ error: "invalid_identity" });
  }

  const user = identity.user;
  if (!user?.accessToken) {
    return res.status(400).json({ error: "garmin_not_connected" });
  }

  try {
    // Query the last 24 hours of uploaded dailies
    const now = Math.floor(Date.now() / 1000);
    const oneDayAgo = now - 86400;
    const url = `${GARMIN_DAILIES_URL}?uploadStartTimeInSeconds=${oneDayAgo}&uploadEndTimeInSeconds=${now}`;

    console.log("garmin sync: pulling recent dailies");

    const garminRes = await garminOAuth1Request("GET", url, [
      ["oauth_token", user.accessToken],
    ], user.tokenSecret || "");

    const text = await garminRes.text();
    console.log(`garmin sync: response status=${garminRes.status}`);

    if (!garminRes.ok) {
      console.error("garmin sync fetch error:", garminRes.status);
      return res.status(502).json({ error: "garmin_fetch_failed", status: garminRes.status });
    }

    let payload;
    try {
      payload = JSON.parse(text);
    } catch {
      return res.status(502).json({ error: "garmin_invalid_json" });
    }

    const candidates = collectDailySummaryCandidates(payload);
    console.log(`garmin sync: found ${candidates.length} daily summary candidates`);
    let stored = 0;
    for (const candidate of candidates) {
      const summary = normalizedGarminSummary(candidate);
      if (summary && storeGarminSummary(identity.nomvaUserId, summary)) {
        stored += 1;
      }
    }

    if (stored > 0) {
      persistGarminStore();
    }

    const summaries = recentGarminSummaries(user, 7);
    return res.json({
      ok: true,
      fetched: candidates.length,
      stored,
      latestSummary: summaries[0] || null,
      recentSummaries: summaries,
    });
  } catch (err) {
    console.error("garmin sync error:", err.message);
    return res.status(500).json({ error: "garmin_sync_failed", detail: err.message });
  }
});

app.post("/v1/garmin/weights/import", async (req, res) => {
  const identity = garminUserForRequest(req);
  if (identity.error === "missing_identity") {
    return res.status(400).json({ error: "missing_identity" });
  }
  if (identity.error === "invalid_identity") {
    return res.status(401).json({ error: "invalid_identity" });
  }
  if (!identity.user?.accessToken) {
    return res.status(400).json({ error: "garmin_not_connected" });
  }

  const uploadLookbackDays = Math.max(
    1,
    Math.min(365, Number.parseInt(req.body?.uploadLookbackDays, 10) || 7)
  );
  const windows = buildGarminUploadWindows({ lookbackDays: uploadLookbackDays });
  const weightsById = new Map();
  let nextWindow = 0;
  let failedWindows = 0;
  let permissionDenied = false;

  async function worker() {
    while (nextWindow < windows.length) {
      const window = windows[nextWindow];
      nextWindow += 1;
      const url = new URL(GARMIN_BODY_COMPS_URL);
      url.searchParams.set("uploadStartTimeInSeconds", String(window.start));
      url.searchParams.set("uploadEndTimeInSeconds", String(window.end));

      try {
        const garminResponse = await garminOAuth1Request("GET", url.toString(), [
          ["oauth_token", identity.user.accessToken],
        ], identity.user.tokenSecret || "");

        if (!garminResponse.ok) {
          failedWindows += 1;
          permissionDenied ||= garminResponse.status === 401 || garminResponse.status === 403;
          continue;
        }

        const payload = JSON.parse(await garminResponse.text() || "[]");
        const records = Array.isArray(payload)
          ? payload
          : Array.isArray(payload?.bodyComps)
            ? payload.bodyComps
            : [];
        for (const record of records) {
          const weight = normalizedGarminWeight(record);
          if (weight) {
            weightsById.set(weight.id, weight);
          }
        }
      } catch (error) {
        failedWindows += 1;
        console.error("garmin weight import window failed:", error.message);
      }
    }
  }

  await Promise.all(Array.from({ length: Math.min(6, windows.length) }, () => worker()));
  if (permissionDenied && failedWindows === windows.length) {
    return res.status(403).json({ error: "garmin_weight_permission_required" });
  }

  const weights = Array.from(weightsById.values())
    .sort((left, right) => left.measuredAt.localeCompare(right.measuredAt));
  return res.json({
    weights,
    uploadLookbackDays,
    fetchedWindows: windows.length - failedWindows,
    failedWindows,
    garminWeightWriteSupported: false,
  });
});

app.delete("/v1/garmin/connection", (req, res) => {
  const identity = garminUserForRequest(req);
  if (identity.error === "missing_identity") {
    return res.status(400).json({ error: "missing_identity" });
  }
  if (identity.error === "invalid_identity") {
    return res.status(401).json({ error: "invalid_identity" });
  }

  if (identity.user?.garminUserId) {
    delete garminStore.garminUserIndex[identity.user.garminUserId];
  }

  Promise.resolve()
    .then(async () => {
      if (identity.user?.accessToken) {
        await revokeGarminRegistration(identity.user.accessToken, identity.user.tokenSecret || "");
      }
    })
    .catch((error) => {
      console.error("garmin deregistration error:", error.message);
    })
    .finally(() => {
      if (identity.nomvaUserId && garminStore.users[identity.nomvaUserId]) {
        delete garminStore.users[identity.nomvaUserId];
      }

      persistGarminStore();
      res.json({ ok: true });
    });
});

// 1. Classify intent
app.post("/v1/classify-intent", async (req, res) => {
  try {
    const { userMessage, recentMessages = [] } = req.body;
    const context = recentMessages
      .slice(-4)
      .map((m) => `${m.role === "user" ? "User" : "Assistant"}: ${m.content}`)
      .join("\n");
    const enriched = context ? `${context}\nUser: ${userMessage}` : `User: ${userMessage}`;
    const result = await ask(prompts.CLASSIFY_INTENT, enriched, llmAnalyticsOptions(req, "classify_intent"));
    res.json({ intent: result.intent || "reply" });
  } catch (err) {
    return respondLLMFailure(res, err, "classification_failed");
  }
});

// 2. Split foods
app.post("/v1/split-foods", async (req, res) => {
  try {
    const { userMessage } = req.body;
    const result = await ask(prompts.SPLIT_FOODS, `User: ${userMessage}`, llmAnalyticsOptions(req, "split_foods"));
    res.json({ foods: sanitizeFoodMentions(userMessage, result.foods) });
  } catch (err) {
    return respondLLMFailure(res, err, "split_failed");
  }
});

// Interpret compound meals as one structured plan before any database work.
// The model owns semantic decisions (dish vs. component, quantity scope); the
// sanitizer enforces the resulting contract without knowing specific foods.
app.post("/v1/plan-food-log", async (req, res) => {
  try {
    const userMessage = String(req.body?.userMessage || "").trim().slice(0, 1_500);
    if (!userMessage) {
      return res.status(400).json({ error: "missing_user_message" });
    }
    if (!shouldUseStructuredFoodPlan(userMessage)) {
      return res.status(422).json({ error: "structured_plan_not_needed" });
    }

    const rawPlan = await askStructured(
      FOOD_LOG_PLANNER_PROMPT,
      `User message: "${userMessage}"`,
      "food_log_plan",
      FOOD_LOG_PLAN_SCHEMA,
      llmAnalyticsOptions(req, "plan_food_log", {
        maxOutputTokens: 2_400,
        model: FOOD_LOG_PLANNING_MODEL,
        reasoningEffort: "low",
        timeoutMs: Number(process.env.NOMVA_FOOD_PLANNING_TIMEOUT_MS || 8_000),
        maxRetries: 0,
        maxAttempts: 1,
      })
    );
    const plan = sanitizeFoodLogPlan(rawPlan);
    if (!plan) {
      return res.status(422).json({ error: "invalid_food_log_plan" });
    }
    for (const item of plan.items) {
      const estimate = item.nutritionEstimate;
      if (item.kind !== "composite" || !estimate) continue;
      try {
        foodKnowledgeStore.upsert({
          name: estimate.canonicalName,
          brand: null,
          aliases: [item.mention, item.searchQuery],
          servingDescription: estimate.servingDescription,
          servingGrams: estimate.servingGrams,
          caloriesPerServing: estimate.caloriesPerServing,
          proteinG: estimate.proteinG,
          carbsG: estimate.carbsG,
          fatG: estimate.fatG,
          fiberG: estimate.fiberG,
          sugarG: estimate.sugarG,
          sodiumMg: estimate.sodiumMg,
          quality: "estimated",
          confidence: estimate.confidence,
          sourceUrl: AI_ESTIMATE_SOURCE_URL,
          sourceTitle: "Nomva AI nutrition estimate",
          evidence: estimate.assumptions,
          components: estimate.components,
        }, [item.mention, item.searchQuery]);
      } catch (error) {
        console.warn("composite estimate cache warning:", error.message);
      }
    }
    return res.json(plan);
  } catch (err) {
    return respondLLMFailure(res, err, "food_log_planning_failed");
  }
});

// 2b. Resolve one food mention through the learned/current catalog, then the
// static nutrition DB when no current menu lookup is needed or available.
app.post("/v1/resolve-food-candidate", async (req, res) => {
  try {
    const {
      userMessage = "",
      foodMention = "",
      searchQuery = "",
      resolutionHint = "",
    } = req.body || {};
    const trimmedMention = String(foodMention).trim();
    const trimmedQuery = String(searchQuery).trim().slice(0, 220) || trimmedMention;
    const normalizedHint = ["single", "composite", "menu"].includes(resolutionHint)
      ? resolutionHint
      : "";
    if (!trimmedMention) {
      return res.status(400).json({ error: "missing_food_mention" });
    }

    // Stop paying for model calls the moment the phone hangs up, and finish
    // within a bounded budget so the client's timeout never fires first.
    const abort = new AbortController();
    res.on("close", () => {
      if (!res.writableEnded) abort.abort();
    });

    const webResolver = webFoodResolverForRequest(req, trimmedMention);
    let attemptedWebResolution = false;
    const explicitlyRequiresCurrentMenuSource = normalizedHint === "menu" || isMenuFoodMention(trimmedMention);

    const tryWebResolution = async () => {
      attemptedWebResolution = true;
      try {
        return await webResolver.resolve({
          userMessage,
          foodMention: trimmedMention,
          signal: abort.signal,
        });
      } catch (error) {
        if (error?.name !== "AbortError") {
          console.warn("web food resolution warning:", error.message);
        }
        return null;
      }
    };

    const tryWorldResolution = async (signal = abort.signal) => {
      try {
        return await resolveWorldFoodEstimate({
          userMessage,
          foodMention: trimmedMention,
          knowledgeStore: foodKnowledgeStore,
          sourceUrl: AI_ESTIMATE_SOURCE_URL,
          askAgent: (input) => askStructured(
            WORLD_FOOD_ESTIMATE_PROMPT,
            input,
            "world_food_estimate",
            WORLD_FOOD_ESTIMATE_SCHEMA,
            llmAnalyticsOptions(req, "estimate_world_food", {
              maxOutputTokens: 1_000,
              model: WORLD_FOOD_MODEL,
              reasoningEffort: process.env.NOMVA_WORLD_FOOD_REASONING_EFFORT || "none",
              signal,
              timeoutMs: Number(process.env.NOMVA_WORLD_FOOD_TIMEOUT_MS || 7_000),
              maxRetries: 0,
              maxAttempts: 1,
            })
          ),
        });
      } catch (error) {
        if (error?.name !== "AbortError") {
          console.warn("world food estimation warning:", error.message);
        }
        return null;
      }
    };

    // A current menu request cannot be satisfied by the static USDA/package
    // catalog. Check the small learned catalog first so repeat orders are fast,
    // and skip the 800k-row local search on cold menu lookups entirely.
    if (explicitlyRequiresCurrentMenuSource) {
      const cachedMenuFood = foodKnowledgeStore.search(
        trimmedMention,
        { limit: 1, minimumScore: 700 }
      )[0];
      if (cachedMenuFood && identityMatchesMention(trimmedMention, cachedMenuFood)) {
        const cachedResult = await webResolver.resolve({
          userMessage,
          foodMention: trimmedMention,
          signal: abort.signal,
        });
        if (cachedResult) return res.json(cachedResult);
      }
    }

    const catalogCandidates = foodSearchStore.isAvailable && !explicitlyRequiresCurrentMenuSource
      ? foodSearchStore.search(trimmedQuery, { limit: 30, offset: 0 })
      : [];
    const requiresCurrentMenuSource = explicitlyRequiresCurrentMenuSource
      || hasUnresolvedLeadingIdentity(trimmedMention, catalogCandidates);
    const initialCandidates = requiresCurrentMenuSource ? [] : catalogCandidates;
    const hasStrongAuthoritativeMatch = initialCandidates
      .slice(0, 20)
      .some((candidate) => isAuthoritativeReferenceSource(candidate.source)
        && !candidate.brand
        && candidateCompatibleWithMention(trimmedMention, candidate));

    // Learned menu items make repeat logs instant, but learned generic rows
    // must not shadow a stronger reference-database row. This keeps the cache
    // useful without allowing one stale enrichment to poison future searches.
    const cachedLearned = foodKnowledgeStore.search(
      trimmedMention,
      { limit: 1, minimumScore: 700 }
    )[0];
    if (cachedLearned
        && identityMatchesMention(trimmedMention, cachedLearned)
        && (["menu", "composite"].includes(normalizedHint) || !hasStrongAuthoritativeMatch)) {
      const cachedResult = await webResolver.resolve({
        userMessage,
        foodMention: trimmedMention,
        signal: abort.signal,
      });
      if (cachedResult) return res.json(cachedResult);
    }

    const hasStrongCatalogMatch = initialCandidates
      .slice(0, 20)
      .some((candidate) => candidateCompatibleWithMention(trimmedMention, candidate)
        && (isAuthoritativeReferenceSource(candidate.source)
          || candidate.source === "web_published"
          || candidate.source === "web_estimate"));
    const defensibleCatalogCandidates = hasStrongCatalogMatch ? initialCandidates : [];
    const webPreferred = ["composite", "menu"].includes(normalizedHint)
      || shouldTryWebFirst(trimmedMention, defensibleCatalogCandidates);
    // Search the web synchronously only when retrieval has no defensible local
    // candidate. Strong catalog matches are selected immediately and refreshed
    // from current public sources in the background for future requests.
    if (!hasStrongCatalogMatch && webPreferred) {
      if (requiresCurrentMenuSource) {
        const webResult = await tryWebResolution();
        if (webResult) return res.json(webResult);
      } else {
        const enrichmentAbort = new AbortController();
        const cancelEnrichment = () => enrichmentAbort.abort();
        abort.signal.addEventListener("abort", cancelEnrichment, { once: true });
        const resolved = await firstNonNull([
          tryWorldResolution(enrichmentAbort.signal),
          tryWebResolution(enrichmentAbort.signal),
        ], Number(process.env.NOMVA_UNKNOWN_FOOD_BUDGET_MS || 15_000));
        cancelEnrichment();
        abort.signal.removeEventListener("abort", cancelEnrichment);
        if (resolved) {
          if (resolved.source === "web_estimate" && resolved.sourceUrl === AI_ESTIMATE_SOURCE_URL) {
            scheduleWebFoodRefresh(req, userMessage, trimmedMention);
          }
          return res.json(resolved);
        }
      }
    }

    if (shouldBlockStaticFallback({ requiresCurrentMenuSource, attemptedWebResolution })) {
      return res.status(422).json({ error: "food_candidate_not_found" });
    }

    if (!foodSearchStore.isAvailable) {
      if (!attemptedWebResolution) {
        const webResult = await tryWebResolution();
        if (webResult) return res.json(webResult);
      }
      return res.status(422).json({ error: "food_candidate_not_found" });
    }

    const outcome = await runFoodResolver({
      userMessage,
      foodMention: trimmedMention,
      searchQuery: trimmedQuery,
      foodSearchStore,
      deadlineMs: Number(process.env.NOMVA_FOOD_RESOLUTION_DEADLINE_MS || 7_000),
      askAgent: (userPrompt) => askStructured(
        prompts.SELECT_FOOD_CANDIDATE,
        userPrompt,
        "food_candidate_selection",
        FOOD_SELECTION_SCHEMA,
        llmAnalyticsOptions(req, "resolve_food_candidate", {
          maxOutputTokens: 700,
          model: FOOD_RESOLUTION_MODEL,
          reasoningEffort: "none",
          signal: abort.signal,
          timeoutMs: Number(process.env.NOMVA_FOOD_SELECTION_TIMEOUT_MS || 7_000),
          maxRetries: 0,
          maxAttempts: 1,
        })
      ),
    });

    if (outcome.status === 200 && webPreferred && !attemptedWebResolution) {
      scheduleWebFoodRefresh(req, userMessage, trimmedMention);
    }

    if (outcome.status === 422 && !attemptedWebResolution) {
      const webResult = await tryWebResolution();
      if (webResult) {
        return res.json(webResult);
      }
    }
    return res.status(outcome.status).json(outcome.body);
  } catch (err) {
    return respondLLMFailure(res, err, "food_resolution_failed");
  }
});

// Manual search already returns the local database immediately. This route is
// its narrow online fallback and only returns validated, reusable catalog rows.
app.post("/v1/search-food-catalog", foodWebLookupLimiter, async (req, res) => {
  const query = String(req.body?.query || "").trim().slice(0, 220);
  if (!query) {
    return res.status(400).json({ error: "missing_food_query" });
  }

  const abort = new AbortController();
  res.on("close", () => {
    if (!res.writableEnded) abort.abort();
  });

  const cached = foodKnowledgeStore
    .search(query, { limit: 8, minimumScore: 600 })
    .filter((candidate) => identityMatchesMention(query, candidate));
  const foods = new Map(cached.map((candidate) => [
    candidate.candidateId,
    resolvedCandidateBody(candidate, {
      servings: 1,
      portionDescription: candidate.servingDescription,
      servingUnit: "serving",
      confident: candidate.quality === "published" && candidate.confidence >= 0.8,
      hasExplicitPortion: false,
    }),
  ]));

  try {
    const resolved = await webFoodResolverForRequest(req, query).resolve({
      userMessage: query,
      foodMention: query,
      signal: abort.signal,
    });
    if (resolved) foods.set(resolved.candidateId, resolved);
    return res.json({ foods: [...foods.values()] });
  } catch (error) {
    if (error?.name !== "AbortError") {
      console.warn("online food catalog warning:", error.message);
    }
    return res.json({ foods: [...foods.values()], onlineUnavailable: true });
  }
});

// 3. Build normalized food search query
app.post("/v1/build-food-search-query", async (req, res) => {
  try {
    const { userMessage, foodMention } = req.body;
    const userPrompt = `User said: "${userMessage}"\nFood mention: "${foodMention}"`;
    const result = await ask(prompts.BUILD_FOOD_SEARCH_QUERY, userPrompt, llmAnalyticsOptions(req, "build_food_search_query"));
    res.json({ query: result.query || foodMention });
  } catch (err) {
    console.error("build-food-search-query error:", err.message);
    res.status(500).json({ error: "search_query_failed" });
  }
});

// 4. Choose best candidate
app.post("/v1/choose-food-candidate", async (req, res) => {
  try {
    const { userMessage, foodMention, candidates = [] } = req.body;
    const candidateLines = candidates.map((candidate) => {
      const brand = candidate.brand ? ` | brand: ${candidate.brand}` : "";
      const serving = candidate.servingDescription ? ` | serving: ${candidate.servingDescription}` : "";
      const source = candidate.source ? ` | source: ${candidate.source}` : "";
      const basis = candidate.portionBasis ? ` | basis: ${candidate.portionBasis}` : "";
      const calories = typeof candidate.caloriesPerServing === "number"
        ? ` | calories: ${Math.round(candidate.caloriesPerServing)}`
        : "";
      return `${candidate.index}: ${candidate.name}${brand}${serving}${source}${basis}${calories}`;
    }).join("\n");
    const userPrompt = `User said: "${userMessage}"\nFood mention: "${foodMention}"\nCandidates:\n${candidateLines}`;
    const result = await ask(prompts.CHOOSE_FOOD_CANDIDATE, userPrompt, llmAnalyticsOptions(req, "choose_food_candidate"));
    const candidateIndex = typeof result.candidateIndex === "number" ? result.candidateIndex : null;
    res.json({ candidateIndex });
  } catch (err) {
    console.error("choose-food-candidate error:", err.message);
    res.status(500).json({ error: "candidate_choice_failed" });
  }
});

// 5. Validate selected candidate
app.post("/v1/validate-food-candidate", async (req, res) => {
  try {
    const { userMessage, foodMention, searchQuery, candidate = {}, servingsInfo = {} } = req.body;
    const brand = candidate.brand ? `\nCandidate brand: ${candidate.brand}` : "";
    const serving = candidate.servingDescription ? `\nCandidate serving: ${candidate.servingDescription}` : "";
    const source = candidate.source ? `\nCandidate source: ${candidate.source}` : "";
    const userPrompt = [
      `User said: "${userMessage}"`,
      `Food mention: "${foodMention}"`,
      `Search query: "${searchQuery}"`,
      `Selected candidate: "${candidate.name || ""}"${brand}${serving}${source}`,
      `Portion basis: ${candidate.portionBasis || "grams"}`,
      `Calories per serving: ${typeof candidate.caloriesPerServing === "number" ? Math.round(candidate.caloriesPerServing) : "unknown"}`,
      `Extracted portion: "${servingsInfo.portionDescription || "1 serving"}"`,
      `Extracted servings: ${typeof servingsInfo.servings === "number" ? servingsInfo.servings : 1}`,
      `Extracted serving unit: "${servingsInfo.servingUnit || "serving"}"`,
      `Extracted confident: ${servingsInfo.confident === true}`,
      `Extracted hasExplicitPortion: ${servingsInfo.hasExplicitPortion === true}`,
    ].join("\n");
    const result = await ask(prompts.VALIDATE_FOOD_CANDIDATE, userPrompt, llmAnalyticsOptions(req, "validate_food_candidate"));
    res.json({
      keepCurrentCandidate: result.keepCurrentCandidate !== false,
      servings: boundedServings(result.servings, boundedServings(servingsInfo.servings, 1)),
      portionDescription: result.portionDescription || servingsInfo.portionDescription || "1 serving",
      servingUnit: result.servingUnit || servingsInfo.servingUnit || "serving",
      confident: result.confident ?? Boolean(servingsInfo.confident),
      hasExplicitPortion: result.hasExplicitPortion ?? Boolean(servingsInfo.hasExplicitPortion),
      replacementSearchQuery: result.replacementSearchQuery || null,
    });
  } catch (err) {
    console.error("validate-food-candidate error:", err.message);
    res.status(500).json({ error: "validate_food_candidate_failed" });
  }
});

// 6. Confirm food match
app.post("/v1/confirm-match", async (req, res) => {
  try {
    const { userMessage, foodMention, candidateName, candidateBrand } = req.body;
    const brandStr = candidateBrand ? ` (${candidateBrand})` : "";
    const userPrompt = `User said: "${userMessage}"\nFood mention: "${foodMention}"\nCandidate: "${candidateName}${brandStr}"`;
    const result = await ask(prompts.CONFIRM_MATCH, userPrompt, llmAnalyticsOptions(req, "confirm_match"));
    res.json({ isMatch: result.isMatch === true });
  } catch (err) {
    console.error("confirm-match error:", err.message);
    res.status(500).json({ error: "match_failed" });
  }
});

// 7. Extract servings
app.post("/v1/extract-servings", async (req, res) => {
  try {
    const { userMessage, foodMention, candidateName, candidateServingDescription } = req.body;
    const servDesc = candidateServingDescription ? `\nCandidate serving: "${candidateServingDescription}"` : "";
    const userPrompt = `User said: "${userMessage}"\nFood mention: "${foodMention}"\nCandidate: "${candidateName}"${servDesc}`;
    const result = await ask(prompts.EXTRACT_SERVINGS, userPrompt, llmAnalyticsOptions(req, "extract_servings"));
    const portionDescription = result.portionDescription || "1 serving";
    const explicitPortion = result.hasExplicitPortion === true
      || hasExplicitPortion(foodMention)
      || hasExplicitPortion(portionDescription);
    res.json({
      servings: boundedServings(result.servings, 1),
      portionDescription,
      servingUnit: result.servingUnit || "serving",
      confident: explicitPortion ? true : (result.confident ?? false),
      hasExplicitPortion: explicitPortion,
    });
  } catch (err) {
    return respondLLMFailure(res, err, "servings_failed");
  }
});

// 8. Extract meal
app.post("/v1/extract-meal", async (req, res) => {
  try {
    const { userMessage } = req.body;
    const result = await ask(prompts.EXTRACT_MEAL, `User: ${userMessage}`, llmAnalyticsOptions(req, "extract_meal"));
    const meal = (result.meal || "none").toLowerCase();
    const valid = ["breakfast", "lunch", "dinner", "snack"];
    res.json({ meal: valid.includes(meal) ? meal : null });
  } catch (err) {
    return respondLLMFailure(res, err, "meal_failed");
  }
});

// 8b. Parse water CRUD
app.post("/v1/extract-water-mutation", async (req, res) => {
  try {
    const { userMessage } = req.body;
    const result = await ask(prompts.EXTRACT_WATER_MUTATION, `User: ${userMessage}`, llmAnalyticsOptions(req, "extract_water_mutation"));
    const action = String(result.action || "reply").toLowerCase();
    const valid = ["add", "delete_all", "update_total", "reply"];
    const amountOz = boundedNumber(result.amountOz, BOUNDS.waterOz);
    res.json({
      action: valid.includes(action) ? action : "reply",
      amountOz,
    });
  } catch (err) {
    return respondLLMFailure(res, err, "water_mutation_failed");
  }
});

// 8c. Parse weight CRUD
app.post("/v1/extract-weight-mutation", async (req, res) => {
  try {
    const { userMessage } = req.body;
    const result = await ask(prompts.EXTRACT_WEIGHT_MUTATION, `User: ${userMessage}`, llmAnalyticsOptions(req, "extract_weight_mutation"));
    const action = String(result.action || "reply").toLowerCase();
    const valid = ["add", "update", "delete", "delete_all", "reply"];
    const dateHintRaw = typeof result.dateHint === "string" ? result.dateHint.toLowerCase() : null;
    const dateHint = ["today", "yesterday", "latest"].includes(dateHintRaw) ? dateHintRaw : null;
    res.json({
      action: valid.includes(action) ? action : "reply",
      weightLbs: boundedNumber(result.weightLbs, BOUNDS.weightLbs),
      dateHint,
    });
  } catch (err) {
    return respondLLMFailure(res, err, "weight_mutation_failed");
  }
});

app.post("/v1/extract-food-move", async (req, res) => {
  try {
    const { userMessage, logSummary = "", recentMessages = [] } = req.body;
    const entries = parseLogEntries(logSummary);
    const history = recentMessages
      .slice(-6)
      .map((message) => `${message.role === "user" ? "User" : "Assistant"}: ${message.content}`)
      .join("\n");
    const prompt = [
      history ? `Recent conversation:\n${history}` : null,
      `Food log:\n${logSummary}`,
      `User said: ${userMessage}`,
    ].filter(Boolean).join("\n\n");
    const result = await ask(
      prompts.EXTRACT_FOOD_MOVE,
      prompt,
      llmAnalyticsOptions(req, "extract_food_move", { model: CONTEXT_MODEL })
    );
    const requestedName = typeof result.foodName === "string" ? result.foodName.trim() : "";
    const matchedEntry = entries.find((entry) => normalizeText(entry.name) === normalizeText(requestedName));
    const destination = String(result.destinationMeal || "").toLowerCase();
    const validMeals = ["breakfast", "lunch", "dinner", "snack"];
    const sourceMeal = String(result.sourceMeal || "").toLowerCase();

    res.json({
      foodName: matchedEntry?.name || null,
      destinationMeal: validMeals.includes(destination) ? destination : null,
      moveAll: result.moveAll === true && validMeals.includes(sourceMeal),
      sourceMeal: validMeals.includes(sourceMeal) ? sourceMeal : null,
      clarificationQuestion: typeof result.clarificationQuestion === "string"
        ? result.clarificationQuestion
        : null,
    });
  } catch (err) {
    return respondLLMFailure(res, err, "food_move_failed");
  }
});

// 9. Pick delete targets
app.post("/v1/pick-delete-targets", async (req, res) => {
  try {
    const { userMessage, logSummary, recentMessages = [] } = req.body;
    const guardedTargets = deterministicDeleteTargets({ userMessage, logSummary, recentMessages });
    if (Array.isArray(guardedTargets)) {
      return res.json({ foodNames: guardedTargets });
    }

    const history = recentMessages
      .slice(-6)
      .map((m) => `${m.role === "user" ? "User" : "Assistant"}: ${m.content}`)
      .join("\n");
    const userPrompt = [
      history ? `Recent conversation:\n${history}` : null,
      `Food log:\n${logSummary}`,
      `User said: ${userMessage}`,
    ].filter(Boolean).join("\n\n");
    const result = await ask(
      prompts.PICK_DELETE_TARGETS,
      userPrompt,
      llmAnalyticsOptions(req, "pick_delete_targets", { model: CONTEXT_MODEL })
    );
    res.json({ foodNames: result.foodNames || [] });
  } catch (err) {
    console.error("pick-delete-targets error:", err.message);
    res.status(500).json({ error: "delete_failed" });
  }
});

// 10. Pick edit target
app.post("/v1/pick-edit-target", async (req, res) => {
  try {
    const { userMessage, logSummary, recentMessages = [] } = req.body;
    const guardedTarget = deterministicEditTarget({ userMessage, logSummary, recentMessages });
    if (guardedTarget) {
      return res.json(guardedTarget);
    }

    const history = recentMessages
      .slice(-4)
      .map((m) => `${m.role === "user" ? "User" : "Assistant"}: ${m.content}`)
      .join("\n");
    const userPrompt = [
      history,
      `Food log:\n${logSummary}`,
      `User said: ${userMessage}`
    ].filter(Boolean).join("\n\n");
    const result = await ask(prompts.PICK_EDIT_TARGET, userPrompt, llmAnalyticsOptions(req, "pick_edit_target"));
    res.json({
      foodName: result.foodName || null,
      clarificationQuestion: result.clarificationQuestion || null,
    });
  } catch (err) {
    console.error("pick-edit-target error:", err.message);
    res.status(500).json({ error: "edit_target_failed" });
  }
});

// 11. Resolve edit request
app.post("/v1/resolve-edit-request", async (req, res) => {
  try {
    const {
      userMessage,
      currentEntryName,
      currentEntryBrand,
      currentPortionDescription,
    } = req.body;
    const brandLine = currentEntryBrand ? `\nCurrent brand: ${currentEntryBrand}` : "";
    const userPrompt = `Current entry: ${currentEntryName}${brandLine}\nCurrent portion: ${currentPortionDescription}\nUser said: ${userMessage}`;
    const result = await ask(prompts.RESOLVE_EDIT_REQUEST, userPrompt, llmAnalyticsOptions(req, "resolve_edit_request"));
    res.json({
      servings: result.servings ?? 1,
      portionDescription: result.portionDescription || "1 serving",
      servingUnit: result.servingUnit || "serving",
      confident: result.confident ?? false,
      hasExplicitPortion: result.hasExplicitPortion === true,
      clarificationQuestion: result.clarificationQuestion || null,
      replacementSearchQuery: result.replacementSearchQuery || null,
    });
  } catch (err) {
    console.error("resolve-edit-request error:", err.message);
    res.status(500).json({ error: "resolve_edit_failed" });
  }
});

// 12. Estimate grams
app.post("/v1/estimate-grams", async (req, res) => {
  try {
    const { foodName, portionDescription, referenceServingDescription, referenceServingGrams } = req.body;
    const promptLines = [
      `Food: ${foodName}`,
      `Portion: ${portionDescription}`,
    ];
    if (referenceServingDescription && typeof referenceServingGrams === "number" && referenceServingGrams > 0) {
      promptLines.push(`Reference serving: ${referenceServingDescription} ≈ ${Math.round(referenceServingGrams)} g`);
    }
    const userPrompt = promptLines.join("\n");
    const result = await ask(prompts.ESTIMATE_GRAMS, userPrompt, llmAnalyticsOptions(req, "estimate_grams"));
    // Out-of-range means the model misread the portion (1e12 g is not a
    // clamping problem, it is a wrong answer) — treat as unparseable.
    const grams = boundedGrams(result.grams);
    if (grams === null) {
      return res.status(422).json({ error: "invalid_grams" });
    }
    res.json({ grams });
  } catch (err) {
    return respondLLMFailure(res, err, "grams_failed");
  }
});

// 12b. Find-food agent loop. The client passes the user's message + food mention
//      + a history of (query, candidates) rounds. The LLM either runs another
//      search, picks a candidate (with portion info), or gives up. The client
//      executes the SQL search itself between turns since the bundled food DB
//      lives on-device.
app.post("/v1/find-food-step", async (req, res) => {
  try {
    const { userMessage = "", foodMention = "", history = [] } = req.body || {};
    const safeHistory = Array.isArray(history) ? history.slice(0, 6) : [];
    const renderedRounds = safeHistory.map((round, roundIdx) => {
      const candidates = Array.isArray(round?.candidates) ? round.candidates.slice(0, 30) : [];
      const candidateLines = candidates.map((candidate, candidateIdx) => {
        const brand = candidate?.brand ? ` | brand: ${candidate.brand}` : "";
        const serving = candidate?.servingDescription ? ` | serving: ${candidate.servingDescription}` : "";
        const source = candidate?.source ? ` | source: ${candidate.source}` : "";
        const basis = candidate?.portionBasis ? ` | basis: ${candidate.portionBasis}` : "";
        const calories = typeof candidate?.caloriesPerServing === "number"
          ? ` | calories: ${Math.round(candidate.caloriesPerServing)}`
          : "";
        const name = candidate?.name || "(unnamed)";
        return `  ${candidateIdx}: ${name}${brand}${serving}${source}${basis}${calories}`;
      });
      const header = `Round ${roundIdx} — query "${round?.query || ""}":`;
      if (candidateLines.length === 0) {
        return `${header}\n  (no candidates returned)`;
      }
      return `${header}\n${candidateLines.join("\n")}`;
    }).join("\n\n");
    const historyBlock = renderedRounds.length > 0 ? renderedRounds : "(no rounds yet — emit a search action with the first query)";
    const userPrompt = [
      `User said: "${userMessage}"`,
      `Food mention: "${foodMention}"`,
      "",
      "History so far:",
      historyBlock,
    ].join("\n");
    const result = await ask(
      prompts.FIND_FOOD_AGENT,
      userPrompt,
      llmAnalyticsOptions(req, "find_food_step", { maxTokens: 320 })
    );
    const action = (result?.action || "").toLowerCase();
    if (action === "search") {
      const query = typeof result.query === "string" ? result.query.trim() : "";
      if (!query) {
        return res.status(422).json({ error: "missing_query" });
      }
      return res.json({ action: "search", query });
    }
    if (action === "pick") {
      const round = Number.isInteger(result.round) ? result.round : null;
      const candidateIndex = Number.isInteger(result.candidateIndex) ? result.candidateIndex : null;
      if (round === null || candidateIndex === null || round < 0 || round >= safeHistory.length) {
        return res.status(422).json({ error: "invalid_pick" });
      }
      const targetRound = safeHistory[round];
      const candidates = Array.isArray(targetRound?.candidates) ? targetRound.candidates : [];
      if (candidateIndex < 0 || candidateIndex >= candidates.length) {
        return res.status(422).json({ error: "invalid_pick_index" });
      }
      return res.json({
        action: "pick",
        round,
        candidateIndex,
        servings: boundedServings(result.servings, 1),
        portionDescription: typeof result.portionDescription === "string" && result.portionDescription.trim()
          ? result.portionDescription.trim()
          : "1 serving",
        servingUnit: typeof result.servingUnit === "string" && result.servingUnit.trim()
          ? result.servingUnit.trim()
          : "serving",
        confident: result.confident === true,
        hasExplicitPortion: result.hasExplicitPortion === true,
      });
    }
    if (action === "give_up") {
      return res.json({ action: "give_up" });
    }
    return res.status(422).json({ error: "invalid_action" });
  } catch (err) {
    console.error("find-food-step error:", err.message);
    res.status(500).json({ error: "find_food_step_failed" });
  }
});

// 13. Extract goal
app.post("/v1/extract-goal", async (req, res) => {
  try {
    const { userMessage } = req.body;
    const result = await ask(prompts.EXTRACT_GOAL, `User: ${userMessage}`, llmAnalyticsOptions(req, "extract_goal"));
    const validMetrics = new Set(["calories", "protein", "carbs", "fat", "fiber", "water_oz", "target_weight_lbs"]);
    const validOperations = new Set(["set", "increase", "decrease"]);
    const changes = (Array.isArray(result.changes) ? result.changes : [])
      .map((change) => ({
        metric: String(change?.metric || "").toLowerCase(),
        operation: String(change?.operation || "").toLowerCase(),
        value: Number(change?.value),
      }))
      .filter((change) =>
        validMetrics.has(change.metric)
        && validOperations.has(change.operation)
        && (
          change.operation === "set"
            ? boundedGoalValue(change.metric, change.value) !== null
            // Relative nudges can legitimately be small (e.g. "add 10g
            // protein"), so bound them by magnitude rather than by the
            // absolute goal range.
            : Number.isFinite(change.value)
              && change.value > 0
              && change.value <= (change.metric === "calories" ? 5000 : 500)
        )
      );
    const legacyAbsoluteFields = {};
    for (const change of changes) {
      if (change.operation === "set" && ["calories", "protein", "carbs", "fat", "fiber"].includes(change.metric)) {
        legacyAbsoluteFields[change.metric] = change.value;
      }
    }
    res.json({ changes, ...legacyAbsoluteFields });
  } catch (err) {
    console.error("extract-goal error:", err.message);
    res.status(500).json({ error: "goal_failed" });
  }
});

app.post("/v1/parse-data-query", async (req, res) => {
  try {
    const { userMessage } = req.body;
    const result = await ask(
      prompts.PARSE_DATA_QUERY,
      `User: ${userMessage}`,
      llmAnalyticsOptions(req, "parse_data_query", { model: CONTEXT_MODEL })
    );
    const metrics = new Set(["calories", "protein", "carbs", "fat", "fiber", "water", "weight"]);
    const aggregations = new Set(["total", "average", "remaining", "latest", "change", "trend"]);
    const windows = new Set(["selected_day", "last_n_days"]);
    const queries = (Array.isArray(result.queries) ? result.queries : [])
      .map((query) => ({
        metric: String(query?.metric || "").toLowerCase(),
        aggregation: String(query?.aggregation || "").toLowerCase(),
        window: String(query?.window || "").toLowerCase(),
        days: Number.isInteger(query?.days) ? Math.max(1, Math.min(query.days, 365)) : null,
      }))
      .filter((query) =>
        metrics.has(query.metric)
        && aggregations.has(query.aggregation)
        && windows.has(query.window)
      );
    res.json({ queries });
  } catch (err) {
    console.error("parse-data-query error:", err.message);
    res.status(500).json({ error: "data_query_failed" });
  }
});

// 9. General reply
app.post("/v1/general-reply", async (req, res) => {
  try {
    const { userMessage, context = "", recentMessages = [] } = req.body;
    const history = recentMessages
      .slice(-4)
      .map((m) => `${m.role === "user" ? "User" : "Assistant"}: ${m.content}`)
      .join("\n");
    const parts = [context, history, `User: ${userMessage}`].filter(Boolean);
    const result = await ask(prompts.GENERAL_REPLY, parts.join("\n\n"), llmAnalyticsOptions(req, "general_reply", { maxTokens: 512 }));
    res.json({ text: result.text || "I'm not sure how to answer that." });
  } catch (err) {
    return respondLLMFailure(res, err, "reply_failed");
  }
});

app.post("/v1/suggest-recent-foods", async (req, res) => {
  const candidates = sanitizeRecentFoodCandidates(req.body?.candidates);
  const fallbackIds = candidates.slice(0, 8).map((candidate) => candidate.id);
  if (candidates.length === 0) {
    return res.json({ candidateIds: [], aiRanked: false });
  }

  const likelyMeal = ["breakfast", "lunch", "dinner", "snack"].includes(req.body?.likelyMeal)
    ? req.body.likelyMeal
    : "snack";
  const localHour = Number.isInteger(req.body?.localHour)
    ? Math.min(Math.max(req.body.localHour, 0), 23)
    : null;
  const weekday = typeof req.body?.weekday === "string"
    ? req.body.weekday.trim().slice(0, 20)
    : "";

  try {
    const result = await ask(
      prompts.RANK_RECENT_FOODS,
      JSON.stringify({
        blankDay: true,
        localContext: { weekday, localHour, likelyMeal },
        candidates,
      }),
      llmAnalyticsOptions(req, "rank_recent_foods", {
        model: CONTEXT_MODEL,
        maxTokens: 96,
        reasoningEffort: "low",
      })
    );
    const rankedIds = sanitizeSuggestedFoodIds(result, candidates, 8);
    return res.json({
      candidateIds: rankedIds.length > 0 ? rankedIds : fallbackIds,
      aiRanked: rankedIds.length > 0,
    });
  } catch (error) {
    console.warn("recent food ranking fell back to local order:", error?.message || error);
    return res.json({ candidateIds: fallbackIds, aiRanked: false });
  }
});

// 10. Analyze food photo (vision)
app.post("/v1/analyze-photo", async (req, res) => {
  const nutritionLabelRequest = req.body?.scanType === "nutrition_label";
  const llmOptions = llmAnalyticsOptions(
    req,
    nutritionLabelRequest ? "analyze_nutrition_label" : "analyze_photo"
  );
  let promptChars = 0;
  try {
    const { imageBase64, userMessage = "", scanType = "meal" } = req.body;
    if (!imageBase64 || typeof imageBase64 !== "string") {
      return res.status(400).json({ error: "missing_image" });
    }
    const isNutritionLabel = scanType === "nutrition_label";
    const systemPrompt = isNutritionLabel
      ? prompts.ANALYZE_NUTRITION_LABEL
      : prompts.ANALYZE_PHOTO;

    // Detect media type from base64 header or default to jpeg
    let mediaType = "image/jpeg";
    let rawBase64 = imageBase64;
    const dataUrlMatch = imageBase64.match(/^data:(image\/\w+);base64,/);
    if (dataUrlMatch) {
      mediaType = dataUrlMatch[1];
      rawBase64 = imageBase64.slice(dataUrlMatch[0].length);
    }

    const userContent = [
      {
        type: "input_image",
        image_url: `data:${mediaType};base64,${rawBase64}`,
        detail: "high",
      },
    ];
    if (userMessage.trim()) {
      userContent.push({ type: "input_text", text: userMessage.trim() });
    }
    promptChars = userMessage.length;

    console.log(`  → OpenAI vision input (${VISION_MODEL}) | imageBytes≈${Math.round(rawBase64.length * 0.75)}`);
    const result = await askStructured(
      systemPrompt,
      [{ role: "user", content: userContent }],
      isNutritionLabel ? "nutrition_label_analysis" : "food_photo_analysis",
      isNutritionLabel ? ANALYZE_NUTRITION_LABEL_SCHEMA : ANALYZE_PHOTO_SCHEMA,
      {
        ...llmOptions,
        model: VISION_MODEL,
        maxOutputTokens: 2_400,
        reasoningEffort: "low",
        timeoutMs: Number(process.env.NOMVA_VISION_TIMEOUT_MS || 25_000),
        maxRetries: 0,
        promptChars,
        cacheKey: isNutritionLabel ? "nomva_nutrition_label_v1" : "nomva_food_photo_v1",
      }
    );

    // The vision model's JSON is untrusted input; validate and clamp every
    // numeric field before it reaches the client.
    res.json(
      isNutritionLabel
        ? sanitizeNutritionLabelAnalysis(result)
        : sanitizePhotoAnalysis(result)
    );
  } catch (err) {
    // No err.message in the response body: internal detail stays in logs.
    return respondLLMFailure(res, err, "photo_analysis_failed");
  }
});

// ── Global Error Handling ──────────────────────────────────────────────────

app.use((err, req, res, next) => {
  if (err?.type === "entity.too.large") {
    return res.status(413).json({ error: "request_too_large" });
  }
  if (err instanceof SyntaxError && err?.status === 400) {
    return res.status(400).json({ error: "invalid_json" });
  }
  console.error("Unhandled API error:", err);
  return res.status(500).json({ error: "internal_server_error" });
});

process.on("uncaughtException", (err) => {
  console.error("Uncaught Exception:", err);
  // PM2 will automatically restart the process if we exit
  process.exit(1);
});

process.on("unhandledRejection", (reason, promise) => {
  console.error("Unhandled Rejection at:", promise, "reason:", reason);
});

// ── Start ────────────────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log(`Nomva API running on port ${PORT}`);
});
