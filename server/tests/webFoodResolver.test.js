const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const { loadFoodKnowledgeStore } = require("../foodKnowledgeStore");
const {
  createWebFoodResolver,
  hasUnresolvedLeadingIdentity,
  identityMatchesMention,
  requiresExactMenuResearch,
  sanitizeWebFoodResult,
  shouldBlockStaticFallback,
  shouldTryWebFirst,
  validPublicURL,
  webFoodSanitizeFailureReason,
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
    components: [],
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
  const requests = [];
  const openai = {
    responses: {
      create: async (request) => {
        requests.push(request);
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
  return { resolver, knowledgeStore, calls: () => calls, requests };
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
    components: [
      { name: "Acai base", servingDescription: "1 bowl base", calories: 300, proteinG: 3, carbsG: 60, fatG: 6, fiberG: 8, sugarG: 35, sodiumMg: 15 },
      { name: "Banana and berries", servingDescription: "1 cup", calories: 120, proteinG: 1, carbsG: 30, fatG: 0, fiberG: 5, sugarG: 20, sodiumMg: 2 },
      { name: "Granola", servingDescription: "1/2 cup", calories: 180, proteinG: 4, carbsG: 25, fatG: 7, fiberG: 3, sugarG: 8, sodiumMg: 80 },
      { name: "Nut butter", servingDescription: "1 tbsp", calories: 100, proteinG: 4, carbsG: 4, fatG: 8, fiberG: 1, sugarG: 1, sodiumMg: 60 },
    ],
  })]);

  const result = await setup.resolver.resolve({
    userMessage: "I had a lowers bowl from alohana",
    foodMention: "lowers bowl from alohana",
  });

  assert.equal(result.source, "web_estimate");
  assert.equal(result.quality, "estimated");
  assert.equal(result.confident, false);
  assert.equal(result.caloriesPerServing, 700);
  assert.equal(result.sodiumMg, 157);
  assert.equal(result.components.length, 4);
  assert.match(result.evidence, /Estimated component breakdown/i);
});

test("supports source-backed estimates for recognized uncataloged dishes", async (t) => {
  const setup = harness(t, [response({
    name: "Doro wat",
    brand: "",
    aliases: ["doro wat", "Ethiopian chicken stew"],
    servingDescription: "1 cup",
    servingGrams: 260,
    caloriesPerServing: 360,
    proteinG: 28,
    carbsG: 15,
    fatG: 20,
    fiberG: 3,
    sugarG: 5,
    sodiumMg: 620,
    quality: "estimated",
    confidence: 0.7,
    sourceUrl: "https://www.africanbites.com/doro-wat-ethiopian-chicken-stew/",
    sourceTitle: "Doro Wat Ethiopian Chicken Stew",
    notes: "Estimated for one cup from the source recipe ingredients.",
    portionDescription: "1 cup doro wat",
    servingUnit: "cup",
    hasExplicitPortion: false,
    components: [
      { name: "Chicken", servingDescription: "4 oz cooked", calories: 180, proteinG: 27, carbsG: 0, fatG: 8, fiberG: 0, sugarG: 0, sodiumMg: 70 },
      { name: "Egg", servingDescription: "1 large", calories: 70, proteinG: 6, carbsG: 0.5, fatG: 5, fiberG: 0, sugarG: 0, sodiumMg: 70 },
      { name: "Berbere onion sauce", servingDescription: "1/2 cup", calories: 110, proteinG: 2, carbsG: 14.5, fatG: 7, fiberG: 3, sugarG: 5, sodiumMg: 480 },
    ],
  })]);

  const result = await setup.resolver.resolve({
    userMessage: "I ate doro wat",
    foodMention: "doro wat",
  });

  assert.equal(result.source, "web_estimate");
  assert.match(setup.requests[0].instructions, /recognized generic or cultural composite dish/i);
});

test("rejects unsafe provenance and nutrition that does not reconcile", () => {
  assert.equal(validPublicURL("http://127.0.0.1/private"), null);
  assert.equal(validPublicURL("https://192.168.1.3/food"), null);
  assert.equal(validPublicURL("http://[::1]/private"), null);
  assert.equal(sanitizeWebFoodResult(response({ sourceUrl: "http://localhost/menu" })), null);
  assert.equal(sanitizeWebFoodResult(response({ proteinG: null })), null);
  assert.equal(sanitizeWebFoodResult(response({ caloriesPerServing: 40, proteinG: 50 })), null);
  assert.equal(sanitizeWebFoodResult(response({ caloriesPerServing: 9, carbsG: 20 })), null);
  assert.equal(sanitizeWebFoodResult(response({ quality: "estimated", components: [] })), null);
});

test("estimated totals and evidence are derived from structured components", () => {
  const result = sanitizeWebFoodResult(response({
    name: "Source-backed bowl",
    quality: "estimated",
    confidence: 0.7,
    caloriesPerServing: 999,
    proteinG: 99,
    carbsG: 99,
    fatG: 99,
    fiberG: 99,
    sugarG: 99,
    sodiumMg: 0,
    notes: "An inconsistent free-text total of 999 calories.",
    components: [
      { name: "Chicken", servingDescription: "4 oz", calories: 180, proteinG: 27, carbsG: 0, fatG: 8, fiberG: 0, sugarG: 0, sodiumMg: 70 },
      { name: "Rice", servingDescription: "1 cup", calories: 210, proteinG: 4, carbsG: 45, fatG: 1, fiberG: 1, sugarG: 0, sodiumMg: 5 },
    ],
  }));

  assert.equal(result.caloriesPerServing, 390);
  assert.equal(result.proteinG, 31);
  assert.equal(result.sodiumMg, 75);
  assert.doesNotMatch(result.evidence, /999/);
});

test("reports bounded validation reasons without recording model food content", () => {
  assert.equal(webFoodSanitizeFailureReason(null), "missing_payload");
  assert.equal(webFoodSanitizeFailureReason({ found: false }), "model_no_match");
  assert.equal(webFoodSanitizeFailureReason({
    found: true,
    quality: "estimated",
    components: [],
  }), "missing_estimate_components");
  assert.equal(webFoodSanitizeFailureReason({ found: true, quality: "published" }), "invalid_payload");
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

test("web-first routing covers menu, composite, and database-empty queries", () => {
  assert.equal(shouldTryWebFirst("venti caramel macchiato from Starbucks", [{}]), true);
  assert.equal(shouldTryWebFirst("lowers bowl at Alohana", [{}]), true);
  assert.equal(shouldTryWebFirst("quesadilla with meat beans and cheese", [{}]), true);
  assert.equal(shouldTryWebFirst("unlisted composed dish", []), true);
  assert.equal(shouldTryWebFirst("Greek yogurt", [{ name: "Greek yogurt" }]), false);
  assert.equal(shouldTryWebFirst("egg", []), false);
  assert.equal(shouldTryWebFirst("medium banana", [{ name: "Banana" }]), false);
});

test("exact-size menu research does not mistake generic produce sizes for restaurants", () => {
  assert.equal(requiresExactMenuResearch("venti caramel macchiato from Starbucks"), true);
  assert.equal(requiresExactMenuResearch("large fries from a restaurant"), true);
  assert.equal(requiresExactMenuResearch("20 oz cola at the cafe"), true);
  assert.equal(requiresExactMenuResearch("medium banana"), false);
  assert.equal(requiresExactMenuResearch("lowers bowl from Alohana"), false);
});

test("a generic reference cannot silently drop a leading named identity", () => {
  const genericBowl = [{
    name: "Burrito bowl, chicken",
    brand: null,
    source: "survey_fndds",
  }];
  assert.equal(
    hasUnresolvedLeadingIdentity("Chipotle chicken burrito bowl", genericBowl),
    true
  );
  assert.equal(
    hasUnresolvedLeadingIdentity("chicken burrito bowl", genericBowl),
    false
  );
  assert.equal(
    hasUnresolvedLeadingIdentity("medium banana", [{ name: "Banana", source: "survey_fndds" }]),
    false
  );
});

test("a failed current-menu lookup cannot fall through to the static catalog", () => {
  assert.equal(shouldBlockStaticFallback({
    requiresCurrentMenuSource: true,
    attemptedWebResolution: true,
  }), true);
  assert.equal(shouldBlockStaticFallback({
    requiresCurrentMenuSource: false,
    attemptedWebResolution: true,
  }), false);
  assert.equal(shouldBlockStaticFallback({
    requiresCurrentMenuSource: true,
    attemptedWebResolution: false,
  }), false);
});

test("learned-food identity can be supported by its saved aliases", () => {
  assert.equal(identityMatchesMention(
    "quesadilla with cheese flour tortilla beans meat and corn",
    {
      name: "Loaded quesadilla",
      aliases: ["quesadilla with cheese flour tortilla beans meat and corn"],
    }
  ), true);
});

test("attached portions and one omitted flavor retain a safe base identity", () => {
  assert.equal(identityMatchesMention(
    "20oz Cherry Coke Zero",
    {
      name: "Coke Zero",
      brand: "Coca-Cola",
      aliases: [],
    }
  ), true);
});

test("an unspecified restaurant drink can use its published hot default", () => {
  const publishedHot = {
    name: "Venti Hot Caramel Macchiato with 2% Milk",
    brand: "Starbucks",
    aliases: ["Starbucks Venti Caramel Macchiato"],
    quality: "published",
  };
  assert.equal(
    identityMatchesMention("venti caramel macchiato from Starbucks", publishedHot),
    true
  );
  assert.equal(
    identityMatchesMention("venti iced caramel macchiato from Starbucks", publishedHot),
    false
  );
});
