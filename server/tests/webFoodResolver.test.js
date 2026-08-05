const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const { loadFoodKnowledgeStore } = require("../foodKnowledgeStore");
const {
  createWebFoodResolver,
  identityMatchesMention,
  sanitizeWebFoodResult,
  shouldTryWebFirst,
  validPublicURL,
} = require("../webFoodResolver");

function response(overrides = {}) {
  return {
    found: true,
    name: "Venti Caramel Macchiato",
    brand: "Starbucks",
    aliases: ["Starbucks venti caramel macchiato"],
    servingDescription: "1 hot venti (20 fl oz)",
    servingGrams: 591,
    caloriesPerServing: 310,
    proteinG: 13,
    carbsG: 45,
    fatG: 9,
    fiberG: 0,
    sugarG: 42,
    sodiumMg: 150,
    quality: "published",
    confidence: 0.98,
    sourceUrl: "https://www.starbucks.com/menu/product/413/hot/nutrition",
    sourceTitle: "Starbucks Caramel Macchiato",
    notes: "Official nutrition for the hot venti size.",
    servings: 1,
    portionDescription: "1 venti caramel macchiato",
    servingUnit: "drink",
    hasExplicitPortion: true,
    ...overrides,
  };
}

function harness(t, outputs) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "nomva-web-food-"));
  const knowledgeStore = loadFoodKnowledgeStore({ dbPath: path.join(directory, "catalog.sqlite") });
  let calls = 0;
  const openai = {
    responses: {
      create: async () => {
        const output = outputs[Math.min(calls, outputs.length - 1)];
        calls += 1;
        if (output instanceof Error) throw output;
        return { output_text: JSON.stringify(output), usage: { total_tokens: 123 } };
      },
    },
  };
  const resolver = createWebFoodResolver({ openai, knowledgeStore });
  t.after(() => {
    knowledgeStore.close();
    fs.rmSync(directory, { recursive: true, force: true });
  });
  return { resolver, knowledgeStore, calls: () => calls };
}

test("accepts, labels, and caches published restaurant nutrition", async (t) => {
  const setup = harness(t, [response()]);
  const first = await setup.resolver.resolve({
    userMessage: "I had a venti caramel macchiato from Starbucks",
    foodMention: "venti caramel macchiato from Starbucks",
  });
  const second = await setup.resolver.resolve({
    userMessage: "venti caramel macchiato from Starbucks",
    foodMention: "venti caramel macchiato from Starbucks",
  });

  assert.equal(first.source, "web_published");
  assert.equal(first.caloriesPerServing, 310);
  assert.equal(first.quality, "published");
  assert.equal(second.candidateId, first.candidateId);
  assert.equal(setup.calls(), 1);
  assert.equal(setup.knowledgeStore.stats().activeFoods, 1);
});

test("keeps ingredient-based menu nutrition visibly estimated", async (t) => {
  const setup = harness(t, [response({
    name: "Lower's Bowl",
    brand: "Alohana Acai Bowls",
    aliases: ["lowers bowl from alohana", "lower's bowl alohana"],
    servingDescription: "1 bowl",
    servingGrams: null,
    caloriesPerServing: 700,
    proteinG: 16,
    carbsG: 95,
    fatG: 29,
    fiberG: 14,
    sugarG: 45,
    sodiumMg: 220,
    quality: "estimated",
    confidence: 0.78,
    sourceUrl: "https://www.alohanaacaioc.com/menu.pdf",
    sourceTitle: "Alohana menu",
    notes: "Estimated from the published ingredients and assumed portions.",
    portionDescription: "1 Lower's Bowl",
    servingUnit: "bowl",
  })]);

  const result = await setup.resolver.resolve({
    userMessage: "I had a lowers bowl from alohana",
    foodMention: "lowers bowl from alohana",
  });

  assert.equal(result.source, "web_estimate");
  assert.equal(result.quality, "estimated");
  assert.equal(result.confident, false);
  assert.match(result.evidence, /Estimated/i);
});

test("rejects unsafe provenance and nutrition that does not reconcile", () => {
  assert.equal(validPublicURL("http://127.0.0.1/private"), null);
  assert.equal(validPublicURL("https://192.168.1.3/food"), null);
  assert.equal(validPublicURL("http://[::1]/private"), null);
  assert.equal(sanitizeWebFoodResult(response({ sourceUrl: "http://localhost/menu" })), null);
  assert.equal(sanitizeWebFoodResult(response({ proteinG: null })), null);
  assert.equal(sanitizeWebFoodResult(response({ caloriesPerServing: 40, proteinG: 50 })), null);
  assert.equal(sanitizeWebFoodResult(response({ caloriesPerServing: 9, carbsG: 20 })), null);
});

test("rejects a plausible wrong-brand product and missing critical size", async (t) => {
  assert.equal(identityMatchesMention(
    "three Chick-fil-A nuggets",
    response({ name: "Chicken Nuggets", brand: "Wendy's" })
  ), false);
  assert.equal(identityMatchesMention(
    "venti caramel macchiato from Starbucks",
    response({ name: "Grande Caramel Macchiato" })
  ), false);

  const setup = harness(t, [response({ name: "Chicken Nuggets", brand: "Wendy's" })]);
  const result = await setup.resolver.resolve({
    userMessage: "I ate three Chick-fil-A nuggets",
    foodMention: "Chick-fil-A nuggets",
  });
  assert.equal(result, null);
  assert.equal(setup.knowledgeStore.stats().activeFoods, 0);
});

test("caches explicit no-match answers without poisoning transient failures", async (t) => {
  const noMatch = harness(t, [{ found: false }]);
  assert.equal(await noMatch.resolver.resolve({ foodMention: "imaginary cafe plate" }), null);
  assert.equal(await noMatch.resolver.resolve({ foodMention: "imaginary cafe plate" }), null);
  assert.equal(noMatch.calls(), 1);
  assert.equal(noMatch.knowledgeStore.hasFreshMiss("imaginary cafe plate"), true);

  const transient = harness(t, [new Error("upstream timeout")]);
  await assert.rejects(
    transient.resolver.resolve({ foodMention: "temporary menu item" }),
    /upstream timeout/
  );
  assert.equal(transient.knowledgeStore.hasFreshMiss("temporary menu item"), false);
});

test("web-first routing is limited to menu-like or database-empty queries", () => {
  assert.equal(shouldTryWebFirst("venti caramel macchiato from Starbucks", [{}]), true);
  assert.equal(shouldTryWebFirst("lowers bowl at Alohana", [{}]), true);
  assert.equal(shouldTryWebFirst("unlisted composed dish", []), true);
  assert.equal(shouldTryWebFirst("Greek yogurt", [{ name: "Greek yogurt" }]), false);
  assert.equal(shouldTryWebFirst("egg", []), false);
});
