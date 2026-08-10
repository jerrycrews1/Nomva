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

  const response = await openai.responses.create(request, requestOptions);
  const text = String(response?.output_text || "").trim();
  if (!text) throw new EmptyStructuredResponseError(model, response);

  return {
    response,
    text,
    value: JSON.parse(text),
  };
}

module.exports = {
  EmptyStructuredResponseError,
  requestStructuredJSON,
  supportsReasoningEffort,
};
