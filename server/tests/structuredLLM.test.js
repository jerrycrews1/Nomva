const assert = require("node:assert/strict");
const test = require("node:test");

const {
  EmptyStructuredResponseError,
  requestStructuredJSON,
  supportsReasoningEffort,
} = require("../structuredLLM");

const schema = {
  type: "object",
  additionalProperties: false,
  properties: { ok: { type: "boolean" } },
  required: ["ok"],
};

function recoverableRequest(create, extra = {}) {
  return requestStructuredJSON({ openai: { responses: { create } }, model: "gpt-5.6-luna",
    instructions: "Return the contract.", input: "test", schemaName: "unit_test", schema,
    timeoutMs: 1200, recoveryAttempts: 1, ...extra });
}

test("a stalled inference is aborted and recovered within one shared deadline", async () => {
  const started = Date.now();
  let calls = 0;
  const result = await recoverableRequest(async (_, options) => {
    assert.equal(options.maxRetries, 0);
    if (++calls === 2) return { output_text: '{"ok":true}' };
    return new Promise((_, reject) => {
      const socket = setTimeout(() => reject(new Error("Abort was not delivered")), 2000);
      options.signal.addEventListener("abort", () => { clearTimeout(socket); reject(options.signal.reason); }, { once: true });
    });
  });
  assert.deepEqual(result.value, { ok: true });
  assert.equal(calls, 2);
  assert.ok(Date.now() - started < 1400);
});

test("upstream failures stop after two attempts and respect long retry hints", async () => {
  for (const hinted of [false, true]) {
    let calls = 0;
    await assert.rejects(recoverableRequest(async () => {
      calls++;
      throw Object.assign(new Error("unavailable"), { status: 503, headers: hinted ? { "retry-after": "30" } : {} });
    }));
    assert.equal(calls, hinted ? 1 : 2);
  }
});

test("cancellation, authentication, and billing failures never replay inference", async () => {
  for (const error of [Object.assign(new Error("auth"), { status: 401 }), Object.assign(new Error("quota"), { status: 429, code: "insufficient_quota" })]) {
    let calls = 0;
    await assert.rejects(recoverableRequest(async () => { calls++; throw error; }));
    assert.equal(calls, 1);
  }
  const controller = new AbortController();
  let calls = 0;
  await assert.rejects(recoverableRequest(async () => { calls++; controller.abort(); throw new Error("cancelled"); }, { signal: controller.signal }));
  assert.equal(calls, 1);
});

test("uses strict Responses API JSON Schema without storing model output", async () => {
  let capturedRequest;
  let capturedOptions;
  const openai = {
    responses: {
      create: async (request, options) => {
        capturedRequest = request;
        capturedOptions = options;
        return {
          output_text: '{"ok":true}',
          usage: { total_tokens: 12 },
        };
      },
    },
  };

  const result = await requestStructuredJSON({
    openai,
    model: "gpt-5.6-luna",
    instructions: "Return the contract.",
    input: "test",
    schemaName: "unit test schema",
    schema,
    reasoningEffort: "none",
    maxOutputTokens: 300,
    timeoutMs: 2_000,
    maxRetries: 0,
    safetyIdentifier: "user_hash",
    cacheKey: "nomva:test:v1",
  });

  assert.deepEqual(result.value, { ok: true });
  assert.equal(capturedRequest.store, false);
  assert.equal(capturedRequest.text.format.type, "json_schema");
  assert.equal(capturedRequest.text.format.strict, true);
  assert.equal(capturedRequest.text.format.name, "unit_test_schema");
  assert.deepEqual(capturedRequest.reasoning, { effort: "none" });
  assert.equal(capturedRequest.safety_identifier, "user_hash");
  assert.equal(capturedRequest.prompt_cache_key, "nomva:test:v1");
  assert.equal(capturedOptions.maxRetries, 0);
  assert.equal(capturedOptions.timeout, 2_000);
});

test("rejects an empty or incomplete structured response", async () => {
  const openai = {
    responses: {
      create: async () => ({
        status: "incomplete",
        incomplete_details: { reason: "max_output_tokens" },
        output_text: "",
      }),
    },
  };

  await assert.rejects(
    requestStructuredJSON({
      openai,
      model: "gpt-5.6-luna",
      instructions: "Return the contract.",
      input: "test",
      schemaName: "unit_test",
      schema,
    }),
    (error) => error instanceof EmptyStructuredResponseError
      && error.code === "llm_empty_structured_response"
  );
});

test("rejects malformed output even though the provider contract should prevent it", async () => {
  const openai = {
    responses: { create: async () => ({ output_text: "not json" }) },
  };

  await assert.rejects(
    requestStructuredJSON({
      openai,
      model: "gpt-5.6-luna",
      instructions: "Return the contract.",
      input: "test",
      schemaName: "unit_test",
      schema,
    }),
    SyntaxError
  );
});

test("omits unsupported reasoning parameters for non-reasoning models", async () => {
  let capturedRequest;
  const openai = {
    responses: {
      create: async (request) => {
        capturedRequest = request;
        return { output_text: '{"ok":true}' };
      },
    },
  };

  const result = await requestStructuredJSON({
    openai,
    model: "gpt-4o-mini",
    instructions: "Return the contract.",
    input: "test",
    schemaName: "unit_test",
    schema,
    reasoningEffort: "none",
  });

  assert.deepEqual(result.value, { ok: true });
  assert.equal(capturedRequest.reasoning, undefined);
  assert.equal(supportsReasoningEffort("gpt-4o-mini"), false);
  assert.equal(supportsReasoningEffort("gpt-5.4-nano"), true);
  assert.equal(supportsReasoningEffort("o3-mini"), true);
});
