require("dotenv").config();
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const express = require("express");
const helmet = require("helmet");
const rateLimit = require("express-rate-limit");
const OpenAI = require("openai");
const prompts = require("./prompts");

const app = express();
const PORT = process.env.PORT || 3000;
const MODEL = "gpt-4o-mini";
const publicDir = path.join(__dirname, "public");
const dataDir = path.join(__dirname, "data");
const garminStorePath = path.join(dataDir, "garmin-store.json");
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

// ── Middleware ────────────────────────────────────────────────────────────────

app.use(helmet());
app.use(express.json({ limit: "512kb" }));

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

function defaultGarminStore() {
  return {
    version: 1,
    users: {},
    states: {},
    garminUserIndex: {},
  };
}

function loadGarminStore() {
  try {
    if (!fs.existsSync(garminStorePath)) {
      return defaultGarminStore();
    }
    const raw = fs.readFileSync(garminStorePath, "utf8");
    const parsed = JSON.parse(raw);
    return {
      version: 1,
      users: parsed.users || {},
      states: parsed.states || {},
      garminUserIndex: parsed.garminUserIndex || {},
    };
  } catch (error) {
    console.error("garmin store load error:", error.message);
    return defaultGarminStore();
  }
}

let garminStore = loadGarminStore();

function persistGarminStore() {
  try {
    fs.mkdirSync(dataDir, { recursive: true });
    const tempPath = `${garminStorePath}.tmp`;
    fs.writeFileSync(tempPath, JSON.stringify(garminStore, null, 2));
    fs.renameSync(tempPath, garminStorePath);
  } catch (error) {
    console.error("garmin store persist error:", error.message);
  }
}

function hashDeviceToken(token) {
  return crypto.createHash("sha256").update(String(token)).digest("hex");
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
  console.log(`oauth1 debug: ${method} ${baseUrl} | queryParams=${JSON.stringify(queryParams)} | baseString=${baseString.slice(0, 200)}... | authHeader=${authHeader.slice(0, 120)}...`);

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

function computeAverageActiveCalories(summaries, days = 28) {
  const sample = summaries.slice(0, days);
  if (!sample.length) {
    return { averageActiveCalories: null, sampledDays: 0 };
  }
  const total = sample.reduce((sum, item) => sum + (item.activeCalories || 0), 0);
  return {
    averageActiveCalories: total / sample.length,
    sampledDays: sample.length,
  };
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
  })
);

// API key auth — accepts the shared app secret OR a dev secret.
// Dev secret bypasses any future rate/payment limits.
app.use("/v1", (req, res, next) => {
  const appSecret = process.env.API_SECRET;
  const devSecret = process.env.DEV_SECRET;
  if (!appSecret && !devSecret) return next(); // no secrets = open (local dev)
  const token = req.headers.authorization?.replace("Bearer ", "");
  if (token && (token === appSecret || token === devSecret)) {
    req.isDev = token === devSecret;
    return next();
  }
  return res.status(401).json({ error: "unauthorized" });
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
  const orig = res.json.bind(res);
  res.json = (body) => {
    const ms = Date.now() - start;
    const requestSummary = summarizeRequestBody(req.body);
    console.log(
      `[${new Date().toISOString()}] ${req.method} ${req.path} ` +
      `| dev=${!!req.isDev} | ${ms}ms | ` +
      `request=${JSON.stringify(requestSummary)}`
    );
    return orig(body);
  };
  next();
});

// ── OpenAI client ────────────────────────────────────────────────────────────

const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

async function ask(systemPrompt, userMessage, opts = {}) {
  const maxTokens = opts.maxTokens || 256;
  console.log(`  → OpenAI call (${MODEL}) | promptChars=${userMessage.length} | maxTokens=${maxTokens}`);
  const response = await openai.chat.completions.create({
    model: MODEL,
    temperature: 0.1,
    max_tokens: maxTokens,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content: systemPrompt },
      { role: "user", content: userMessage },
    ],
  });
  const text = response.choices[0]?.message?.content?.trim();
  const usage = response.usage;
  console.log(`  ← OpenAI response | chars=${text?.length || 0} | tokens=${usage?.total_tokens || "?"}`);
  return JSON.parse(text);
}

// ── Routes ───────────────────────────────────────────────────────────────────

// Health check (no auth required)
app.get("/health", (_req, res) => res.json({ status: "ok" }));

// Garmin OAuth 1.0a start (opened from the iOS app in an auth session)
app.get("/garmin/oauth/start", async (req, res) => {
  cleanupExpiredGarminStates();

  if (!garminIsConfigured()) {
    return res.status(503).send("Garmin is not configured on Nomva Cloud yet.");
  }

  const nomvaUserId = normalizeIdentifier(req.query.nomvaUserId || req.query.nomva_user_id);
  const deviceToken = typeof req.query.deviceToken === "string"
    ? req.query.deviceToken
    : typeof req.query.device_token === "string"
      ? req.query.device_token
      : "";
  const returnScheme = sanitizeCallbackScheme(req.query.returnScheme || req.query.return_scheme);

  if (!nomvaUserId || !deviceToken.trim()) {
    return res.status(400).send("Nomva Cloud identity is missing.");
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

    // Step 2: Redirect user to Garmin's authorize page
    const authorizeUrl = `${GARMIN_AUTHORIZE_URL}?oauth_token=${oauth1PercentEncode(requestToken.oauthToken)}`;
    return res.redirect(authorizeUrl);
  } catch (err) {
    console.error("garmin oauth start error:", err.message);
    return res.status(500).send(`Garmin connection failed: ${err.message}`);
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
    console.log(`garmin: connected user ${pending.nomvaUserId}, garmin id ${garminProfile.userId || "unknown"}`);
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
  const summaries = recentGarminSummaries(identity.user, days);
  const average = computeAverageActiveCalories(summaries, 28);

  return res.json({
    configured: garminIsConfigured(),
    connected: Boolean(identity.user?.accessToken),
    connectedAt: identity.user?.connectedAt || null,
    lastWebhookAt: identity.user?.lastWebhookAt || null,
    garminUserIdKnown: Boolean(identity.user?.garminUserId),
    permissions: identity.user?.permissions || [],
    averageActiveCalories: average.averageActiveCalories,
    sampledDays: average.sampledDays,
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

    console.log(`garmin sync: pulling dailies for user ${identity.nomvaUserId}, url=${url}`);

    const garminRes = await garminOAuth1Request("GET", url, [
      ["oauth_token", user.accessToken],
    ], user.tokenSecret || "");

    const text = await garminRes.text();
    console.log(`garmin sync: response status=${garminRes.status}, body=${text.slice(0, 500)}`);

    if (!garminRes.ok) {
      console.error("garmin sync fetch error:", garminRes.status, text);
      return res.status(502).json({ error: "garmin_fetch_failed", status: garminRes.status, detail: text.slice(0, 300) });
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

// Debug: test if tokens work at all by calling user ID endpoint (no query params)
app.get("/v1/garmin/test", async (req, res) => {
  const identity = garminUserForRequest(req);
  if (identity.error) return res.status(400).json({ error: identity.error });
  const user = identity.user;
  if (!user?.accessToken) return res.status(400).json({ error: "not_connected" });

  try {
    const idRes = await garminOAuth1Request("GET", GARMIN_USER_ID_URL, [
      ["oauth_token", user.accessToken],
    ], user.tokenSecret || "");
    const text = await idRes.text();
    console.log(`garmin test: user-id status=${idRes.status} body=${text.slice(0, 300)}`);
    return res.json({ status: idRes.status, body: text.slice(0, 500) });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
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
    const result = await ask(prompts.CLASSIFY_INTENT, enriched);
    res.json({ intent: result.intent || "reply" });
  } catch (err) {
    console.error("classify-intent error:", err.message);
    res.status(500).json({ error: "classification_failed" });
  }
});

// 2. Split foods
app.post("/v1/split-foods", async (req, res) => {
  try {
    const { userMessage } = req.body;
    const result = await ask(prompts.SPLIT_FOODS, `User: ${userMessage}`);
    res.json({ foods: result.foods || [userMessage] });
  } catch (err) {
    console.error("split-foods error:", err.message);
    res.status(500).json({ error: "split_failed" });
  }
});

// 3. Confirm food match
app.post("/v1/confirm-match", async (req, res) => {
  try {
    const { userMessage, foodMention, candidateName, candidateBrand } = req.body;
    const brandStr = candidateBrand ? ` (${candidateBrand})` : "";
    const userPrompt = `User said: "${userMessage}"\nFood mention: "${foodMention}"\nCandidate: "${candidateName}${brandStr}"`;
    const result = await ask(prompts.CONFIRM_MATCH, userPrompt);
    res.json({ isMatch: result.isMatch === true });
  } catch (err) {
    console.error("confirm-match error:", err.message);
    res.status(500).json({ error: "match_failed" });
  }
});

// 4. Extract servings
app.post("/v1/extract-servings", async (req, res) => {
  try {
    const { userMessage, foodMention, candidateName, candidateServingDescription } = req.body;
    const servDesc = candidateServingDescription ? `\nCandidate serving: "${candidateServingDescription}"` : "";
    const userPrompt = `User said: "${userMessage}"\nFood mention: "${foodMention}"\nCandidate: "${candidateName}"${servDesc}`;
    const result = await ask(prompts.EXTRACT_SERVINGS, userPrompt);
    res.json({
      servings: result.servings ?? 1,
      portionDescription: result.portionDescription || "1 serving",
      confident: result.confident ?? false,
    });
  } catch (err) {
    console.error("extract-servings error:", err.message);
    res.status(500).json({ error: "servings_failed" });
  }
});

// 5. Extract meal
app.post("/v1/extract-meal", async (req, res) => {
  try {
    const { userMessage } = req.body;
    const result = await ask(prompts.EXTRACT_MEAL, `User: ${userMessage}`);
    const meal = (result.meal || "none").toLowerCase();
    const valid = ["breakfast", "lunch", "dinner", "snack"];
    res.json({ meal: valid.includes(meal) ? meal : null });
  } catch (err) {
    console.error("extract-meal error:", err.message);
    res.status(500).json({ error: "meal_failed" });
  }
});

// 6. Pick delete targets
app.post("/v1/pick-delete-targets", async (req, res) => {
  try {
    const { userMessage, logSummary } = req.body;
    const userPrompt = `Food log:\n${logSummary}\n\nUser said: ${userMessage}`;
    const result = await ask(prompts.PICK_DELETE_TARGETS, userPrompt);
    res.json({ foodNames: result.foodNames || [] });
  } catch (err) {
    console.error("pick-delete-targets error:", err.message);
    res.status(500).json({ error: "delete_failed" });
  }
});

// 7. Estimate grams
app.post("/v1/estimate-grams", async (req, res) => {
  try {
    const { foodName, portionDescription } = req.body;
    const userPrompt = `Food: ${foodName}\nPortion: ${portionDescription}`;
    const result = await ask(prompts.ESTIMATE_GRAMS, userPrompt);
    const grams = result.grams;
    if (typeof grams !== "number" || grams <= 0) {
      return res.status(422).json({ error: "invalid_grams" });
    }
    res.json({ grams });
  } catch (err) {
    console.error("estimate-grams error:", err.message);
    res.status(500).json({ error: "grams_failed" });
  }
});

// 8. Extract goal
app.post("/v1/extract-goal", async (req, res) => {
  try {
    const { userMessage } = req.body;
    const result = await ask(prompts.EXTRACT_GOAL, `User: ${userMessage}`);
    res.json(result);
  } catch (err) {
    console.error("extract-goal error:", err.message);
    res.status(500).json({ error: "goal_failed" });
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
    const result = await ask(prompts.GENERAL_REPLY, parts.join("\n\n"), { maxTokens: 512 });
    res.json({ text: result.text || "I'm not sure how to answer that." });
  } catch (err) {
    console.error("general-reply error:", err.message);
    res.status(500).json({ error: "reply_failed" });
  }
});

// ── Start ────────────────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log(`Nomva API running on port ${PORT}`);
});
