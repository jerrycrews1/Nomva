class EmptyStructuredResponseError extends Error {
  constructor(model, response = null) {
    const reason = response?.incomplete_details?.reason || response?.status || "empty_output";
    super(`empty structured response from ${model} (${reason})`);
    this.name = "EmptyStructuredResponseError";
    this.code = "llm_empty_structured_response";
    this.responseStatus = response?.status || null;
  }
}

function boundedIdentifier(value, fallback) {
  const normalized = String(value || "")
    .replace(/[^a-zA-Z0-9_-]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 64);
  return normalized || fallback;
}

function supportsReasoningEffort(model) {
  return /^(gpt-5|o[1-9])/i.test(String(model || ""));
}

async function requestStructuredJSON({
  openai,
  model,
  instructions,
  input,
  schemaName,
  schema,
  maxOutputTokens = 1_000,
  reasoningEffort = null,
  signal = undefined,
  timeoutMs = undefined,
  maxRetries = 0,
  recoveryAttempts = 0,
  safetyIdentifier = null,
  cacheKey = null,
}) {
  if (!openai?.responses?.create) throw new TypeError("Responses API client is unavailable");
  if (!model || !instructions || !schema || typeof schema !== "object") {
    throw new TypeError("Structured response configuration is incomplete");
  }

  const request = {
    model,
    instructions,
    input: typeof input === "string" ? input : input || "",
    max_output_tokens: Math.max(64, Math.min(8_000, Number(maxOutputTokens) || 1_000)),
    store: false,
    text: {
      format: {
        type: "json_schema",
        name: boundedIdentifier(schemaName, "nomva_response"),
        strict: true,
        schema,
      },
    },
  };
  if (reasoningEffort && supportsReasoningEffort(model)) {
    request.reasoning = { effort: reasoningEffort };
  }
  if (safetyIdentifier) request.safety_identifier = String(safetyIdentifier).slice(0, 64);
  if (cacheKey) request.prompt_cache_key = String(cacheKey).slice(0, 64);

  const requestOptions = { maxRetries: Math.max(0, Math.min(2, Number(maxRetries) || 0)) };
  if (signal) requestOptions.signal = signal;
  if (timeoutMs) requestOptions.timeout = timeoutMs;

  const response = recoveryAttempts > 0 && timeoutMs > 0
    ? await requestWithinDeadline(openai, request, requestOptions, Math.min(1, recoveryAttempts))
    : await openai.responses.create(request, requestOptions);
  const text = String(response?.output_text || "").trim();
  if (!text) throw new EmptyStructuredResponseError(model, response);

  return {
    response,
    text,
    value: JSON.parse(text),
  };
}

// Only inference is repeated. Both attempts share one wall-clock budget and
// cancellation signal; SDK retries are disabled so they cannot multiply it.
async function requestWithinDeadline(openai, request, options, recoveryAttempts) {
  const deadline = Date.now() + options.timeout;
  const overall = AbortSignal.timeout(options.timeout);
  const parent = options.signal ? AbortSignal.any([options.signal, overall]) : overall;
  for (let attempt = 0; ; attempt += 1) {
    parent.throwIfAborted();
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new DOMException("Request deadline exceeded", "TimeoutError");
    const allowance = attempt < recoveryAttempts ? Math.max(1, Math.floor(remaining * 0.6)) : remaining;
    const signal = AbortSignal.any([parent, AbortSignal.timeout(allowance)]);
    try {
      return await openai.responses.create(request, { ...options, signal, timeout: allowance, maxRetries: 0 });
    } catch (error) {
      if (parent.aborted || attempt >= recoveryAttempts) throw error;
      const transient = signal.aborted || ["APIConnectionError", "APIConnectionTimeoutError"].includes(error.name)
        || [408, 409].includes(error.status) || error.status >= 500
        || (error.status === 429 && ["rate_limit_exceeded", "slow_down"].includes(error.code));
      if (!transient) throw error;
      const header = error.headers?.get?.("retry-after") ?? error.headers?.["retry-after"];
      const hintedDelay = header == null ? 0 : Number.isFinite(Number(header))
        ? Number(header) * 1000 : Date.parse(header) - Date.now();
      const delay = Math.max(250, Number.isFinite(hintedDelay) ? hintedDelay : 0) + Math.random() * 100;
      if (delay >= deadline - Date.now()) throw error;
      await require("node:timers/promises").setTimeout(delay, undefined, { signal: parent });
    }
  }
}

module.exports = {
  EmptyStructuredResponseError,
  requestStructuredJSON,
  supportsReasoningEffort,
};
