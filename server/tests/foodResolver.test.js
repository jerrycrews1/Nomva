const assert = require("node:assert/strict");
const test = require("node:test");

const {
  applyCandidateDefaultServing,
  candidateCompatibleWithMention,
  deterministicFallbackCandidate,
  genericBrandInvariantFeedback,
  nutritionInvariantFeedback,
  provenanceInvariantFeedback,
  resolveFoodCandidate,
} = require("../foodResolver");

const candidate = {
  rowId: 42,
  candidateId: "db_42",
  name: "Example Food",
  brand: null,
  source: "test",
  servingDescription: "1 cup",
  servingGrams: 100,
  caloriesPerServing: 120,
  proteinG: 5,
  carbsG: 20,
  fatG: 2,
  portionBasis: "grams",
};

function fakeStore(searchImpl = () => [candidate]) {
  return {
    search: searchImpl,
    inspect: (rowId) => rowId === candidate.rowId ? candidate : null,
  };
}

function pick(overrides = {}) {
  return {
    action: "pick",
    rowId: 42,
    servings: 1,
    portionDescription: "1 cup",
    servingUnit: "cup",
    confident: true,
    hasExplicitPortion: false,
    ...overrides,
  };
}

test("selects from one bounded retrieval call", async () => {
  let prompt;
  let calls = 0;
  const result = await resolveFoodCandidate({
    userMessage: "I ate example food",
    foodMention: "example food",
    foodSearchStore: fakeStore(),
    askAgent: async (value) => {
      calls += 1;
      prompt = value;
      return pick();
    },
  });

  assert.match(prompt, /Retrieved candidates:/);
  assert.match(prompt, /rowId 42: Example Food/);
  assert.equal(calls, 1);
  assert.equal(result.status, 200);
  assert.equal(result.body.candidateId, "db_42");
});

test("reconciles the selected portion to database serving arithmetic", async () => {
  const fluidOunceCandidate = {
    ...candidate,
    name: "Milk, NFS",
    servingDescription: "1 fl oz",
    servingGrams: 30.5,
    caloriesPerServing: 15.86,
    proteinG: 1,
    carbsG: 1.5,
    fatG: 0.6,
  };
  const result = await resolveFoodCandidate({
    userMessage: "I had 8 fl oz of milk",
    foodMention: "milk",
    foodSearchStore: {
      search: () => [fluidOunceCandidate],
      inspect: () => fluidOunceCandidate,
    },
    askAgent: async () => pick({
      servings: 1,
      portionDescription: "8 fl oz milk",
      servingUnit: "fl oz",
      hasExplicitPortion: true,
    }),
  });

  assert.equal(result.status, 200);
  assert.equal(result.body.servings, 8);
  assert.equal(result.body.portionDescription, "8 fl oz milk");
});

test("uses the planner's normalized search query without losing original identity", async () => {
  const queries = [];
  const result = await resolveFoodCandidate({
    userMessage: "I ate one whole example food",
    foodMention: "one whole example food",
    searchQuery: "example food",
    foodSearchStore: fakeStore((query) => {
      queries.push(query);
      return [candidate];
    }),
    askAgent: async () => pick(),
  });

  assert.deepEqual(queries, ["example food"]);
  assert.equal(result.status, 200);
});

test("falls back safely when the single model call fails", async () => {
  const result = await resolveFoodCandidate({
    userMessage: "I ate example food",
    foodMention: "example food",
    foodSearchStore: fakeStore(),
    askAgent: async () => { throw new Error("upstream timeout"); },
  });

  assert.equal(result.status, 200);
  assert.equal(result.body.candidateId, "db_42");
  assert.equal(result.body.confident, false);
});

test("rejects a hallucinated row id rather than inspecting it", async () => {
  const result = await resolveFoodCandidate({
    userMessage: "I ate example food",
    foodMention: "example food",
    foodSearchStore: fakeStore(),
    askAgent: async () => pick({ rowId: 999 }),
  });

  assert.equal(result.status, 200);
  assert.equal(result.body.candidateId, "db_42");
});

test("returns no match when retrieval is empty without calling a model", async () => {
  let called = false;
  const result = await resolveFoodCandidate({
    userMessage: "I ate an imaginary food",
    foodMention: "imaginary food",
    foodSearchStore: fakeStore(() => []),
    askAgent: async () => { called = true; return pick(); },
  });

  assert.equal(called, false);
  assert.equal(result.status, 422);
});

test("deterministic fallback accepts a strongly matching ordinary food", () => {
  const selected = deterministicFallbackCandidate("porridge", [{
    candidates: [
      { rowId: 1, name: "Porridge", brand: null },
      { rowId: 2, name: "Porridge oat bar", brand: "Example" },
    ],
  }]);
  assert.equal(selected.rowId, 1);
});

test("deterministic fallback preserves ranked safe rows instead of promoting an exact package", () => {
  const selected = deterministicFallbackCandidate("beef tacos", [{
    candidates: [
      {
        rowId: 1,
        name: "Taco, corn tortilla, beef, cheese",
        brand: null,
        source: "survey_fndds",
        servingDescription: "1 taco",
        caloriesPerServing: 260,
      },
      {
        rowId: 2,
        name: "Beef Tacos",
        brand: "Example Foods",
        source: "branded",
        servingDescription: "311 g",
        caloriesPerServing: 520,
      },
    ],
  }]);
  assert.equal(selected.rowId, 1);
});

test("identity guard rejects wrong brands and unstated animal variants", () => {
  assert.equal(candidateCompatibleWithMention("three Chick-fil-A nuggets", {
    name: "Chicken Nuggets",
    brand: "Wendy's",
  }), false);
  assert.equal(candidateCompatibleWithMention("one egg", {
    name: "Egg, duck, whole, raw",
    brand: null,
  }), false);
  assert.equal(candidateCompatibleWithMention("one whole egg", {
    name: "Egg",
    brand: null,
  }), true);
  assert.equal(candidateCompatibleWithMention("chicken sausage", {
    name: "Sausage, NFS",
    brand: null,
    source: "survey_fndds",
  }), false);
});

test("identity guard rejects a brand-only token collision", () => {
  assert.equal(candidateCompatibleWithMention("doro wat", {
    name: "Lemonade",
    brand: "Doro",
  }), false);
});

test("identity guard accepts an authoritative explicitly unspecified reference", () => {
  assert.equal(candidateCompatibleWithMention("meatballs", {
    name: "Meatballs, NS as to type of meat, with sauce",
    brand: null,
    source: "survey_fndds",
  }), true);
});

test("identity guard treats toast morphology as bread but rejects melba crackers", () => {
  assert.equal(candidateCompatibleWithMention("rye toast", {
    name: "Bread, rye, toasted",
    brand: null,
    source: "sr_legacy",
  }), true);
  assert.equal(candidateCompatibleWithMention("rye toast", {
    name: "Crackers, melba toast, rye",
    brand: null,
    source: "sr_legacy",
  }), false);
});

test("identity guard rejects unrequested preservation and baked-product forms", () => {
  assert.equal(candidateCompatibleWithMention("zucchini", {
    name: "Zucchini, pickled",
    source: "survey_fndds",
    servingDescription: "1 cup",
  }), false);
  assert.equal(candidateCompatibleWithMention("zucchini", {
    name: "Muffin, zucchini",
    source: "survey_fndds",
    servingDescription: "1 medium",
  }), false);
});

test("identity guard does not promote a broad row whose requested identity is only an includes alias", () => {
  assert.equal(candidateCompatibleWithMention("sourdough toast", {
    name: "Bread, french or vienna, toasted (includes sourdough)",
    source: "sr_legacy",
    servingDescription: "1 slice",
  }), false);
});

test("uses a separate survey default only when the user omitted an amount", () => {
  const pork = {
    servingGrams: 30,
    servingDescription: "1 slice",
    defaultServingGrams: 60,
    defaultServingDescription: "1 estimated serving",
    defaultServingSource: "survey_qns",
  };
  const omitted = applyCandidateDefaultServing(pork, {
    servings: 1,
    portionDescription: "1 slice",
    servingUnit: "slice",
    confident: true,
    hasExplicitPortion: false,
  });
  const explicit = applyCandidateDefaultServing(pork, {
    servings: 4.72,
    portionDescription: "5 oz",
    servingUnit: "oz",
    confident: true,
    hasExplicitPortion: true,
  });

  assert.equal(omitted.servings, 2);
  assert.equal(omitted.portionDescription, "1 estimated serving");
  assert.equal(omitted.servingUnit, "serving");
  assert.equal(omitted.confident, false);
  assert.equal(explicit.servings, 4.72);
  assert.equal(explicit.portionDescription, "5 oz");
});

test("rejects a caloric substitute for a diet or zero-sugar soft drink", () => {
  const regularCola = { ...candidate, name: "Cherry Cola", caloriesPerServing: 240 };
  assert.match(
    nutritionInvariantFeedback("20 oz cherry Coke Zero", regularCola, 1),
    /implies 240 calories/
  );
});

test("allows a noncaloric row for a diet or zero-sugar soft drink", () => {
  const dietCola = {
    ...candidate,
    name: "Coke Zero",
    caloriesPerServing: 0.4,
    proteinG: 0,
    carbsG: 0,
    fatG: 0,
  };
  assert.equal(nutritionInvariantFeedback("20 oz cherry Coke Zero", dietCola, 5.9), null);
});

test("attached portion tokens do not weaken a compatible flavored zero-sugar basis", () => {
  assert.equal(candidateCompatibleWithMention("20oz Coke Zero cherry", {
    name: "Coke Zero",
    brand: "Coca-Cola",
    servingDescription: "100 g",
  }), true);
});

test("rejects calories that contradict the row's own macros", () => {
  const corruptBlueberries = {
    ...candidate,
    name: "Blueberries",
    caloriesPerServing: 0.7,
    proteinG: 0.7,
    carbsG: 12.1,
    fatG: 0.7,
  };
  assert.match(
    nutritionInvariantFeedback("blueberries", corruptBlueberries, 1),
    /contradict/
  );
});

test("rejects an unrequested package mass basis as an inferred everyday portion", () => {
  const dryPackageRow = {
    ...candidate,
    name: "Spaghetti",
    brand: "Spaghetti",
    source: "open_food_facts",
    servingDescription: "1 portion (100 g)",
    servingGrams: 100,
    caloriesPerServing: 354,
  };
  assert.match(
    provenanceInvariantFeedback("spaghetti", dryPackageRow, { hasExplicitPortion: false }),
    /not a reliable default portion/
  );
});

test("allows a package row when the user explicitly requested its brand", () => {
  const brandedRow = {
    ...candidate,
    name: "Protein Shake",
    brand: "Example Nutrition",
    source: "branded",
    servingDescription: "11 oz",
  };
  assert.equal(
    provenanceInvariantFeedback("Example Nutrition protein shake", brandedRow, { hasExplicitPortion: false }),
    null
  );
});

test("allows a package row with a natural household serving", () => {
  const packagedBar = {
    ...candidate,
    name: "Granola Bar",
    brand: "Example",
    source: "open_food_facts",
    servingDescription: "1 bar",
  };
  assert.equal(
    provenanceInvariantFeedback("granola bar", packagedBar, { hasExplicitPortion: false }),
    null
  );
});

test("allows plural count descriptions as natural package servings", () => {
  const packagedMeatballs = {
    ...candidate,
    name: "Meatballs",
    brand: "Example",
    source: "branded",
    servingDescription: "3 meatballs",
  };
  assert.equal(
    provenanceInvariantFeedback("meatballs", packagedMeatballs, { hasExplicitPortion: false }),
    null
  );
});

test("rejects an unrequested brand when a compatible generic reference exists", () => {
  const branded = {
    ...candidate,
    name: "Meatballs",
    brand: "Example Foods",
    source: "branded",
    servingDescription: "3 meatballs",
  };
  const generic = {
    ...candidate,
    rowId: 43,
    name: "Meatballs, NS as to type of meat, with sauce",
    source: "survey_fndds",
  };
  assert.match(
    genericBrandInvariantFeedback("meatballs", branded, { hasExplicitPortion: false }, [generic, branded]),
    /unrequested brand/
  );
  assert.equal(
    genericBrandInvariantFeedback("Example Foods meatballs", branded, { hasExplicitPortion: false }, [generic, branded]),
    null
  );
});

test("an explicit amount does not let a crowdsourced row displace USDA", () => {
  const crowdsourced = {
    ...candidate,
    name: "Pork Tenderloin",
    brand: null,
    source: "open_food_facts",
    servingDescription: "112 g",
  };
  const authoritative = {
    ...candidate,
    rowId: 43,
    name: "Pork, tenderloin",
    brand: null,
    source: "survey_fndds",
    servingDescription: "1 slice, any size",
  };

  assert.match(
    genericBrandInvariantFeedback(
      "5 oz pork tenderloin",
      crowdsourced,
      { hasExplicitPortion: true, portionDescription: "5 oz pork tenderloin" },
      [authoritative, crowdsourced]
    ),
    /crowdsourced package/
  );
});

test("source substitution preserves and recomputes an explicit mass", async () => {
  const crowdsourced = {
    ...candidate,
    name: "Pork Tenderloin",
    source: "open_food_facts",
    servingDescription: "112 g",
    servingGrams: 112,
  };
  const authoritative = {
    ...candidate,
    rowId: 43,
    candidateId: "db_43",
    name: "Pork, tenderloin",
    source: "survey_fndds",
    servingDescription: "1 slice, any size",
    servingGrams: 30,
  };
  const result = await resolveFoodCandidate({
    userMessage: "I had 5 oz of pork tenderloin",
    foodMention: "5 oz pork tenderloin",
    foodSearchStore: {
      search: () => [authoritative, crowdsourced],
      inspect: (rowId) => rowId === crowdsourced.rowId ? crowdsourced : authoritative,
    },
    askAgent: async () => pick({
      rowId: crowdsourced.rowId,
      servings: 1.2656,
      portionDescription: "5 oz pork tenderloin",
      servingUnit: "oz",
      hasExplicitPortion: true,
    }),
  });

  assert.equal(result.status, 200);
  assert.equal(result.body.candidateId, "db_43");
  assert.equal(result.body.hasExplicitPortion, true);
  assert.equal(result.body.portionDescription, "5 oz pork tenderloin");
  assert.equal(result.body.servingUnit, "oz");
  assert.ok(Math.abs(result.body.servings - 4.72492) < 0.00001);
});

test("model selection cannot override a compatible authoritative generic row", async () => {
  const generic = {
    ...candidate,
    rowId: 43,
    candidateId: "db_43",
    name: "Meatballs, NS as to type of meat, with sauce",
    source: "survey_fndds",
    servingDescription: "1 cup",
  };
  const branded = {
    ...candidate,
    rowId: 44,
    candidateId: "db_44",
    name: "Meatballs",
    brand: "Example Foods",
    source: "branded",
    servingDescription: "3 meatballs",
  };
  const result = await resolveFoodCandidate({
    userMessage: "I ate meatballs",
    foodMention: "meatballs",
    foodSearchStore: {
      search: () => [generic, branded],
      inspect: (rowId) => rowId === 43 ? generic : rowId === 44 ? branded : null,
    },
    askAgent: async () => pick({ rowId: 44 }),
  });

  assert.equal(result.status, 200);
  assert.equal(result.body.candidateId, "db_43");
  assert.equal(result.body.portionDescription, "1 cup");
});

test("a rejected model pick falls through to the guarded ranked fallback", async () => {
  const unsafe = {
    ...candidate,
    rowId: 42,
    candidateId: "db_42",
    name: "Example Food Powder",
    brand: "Example",
    source: "branded",
    servingDescription: "100 g",
  };
  const safe = {
    ...candidate,
    rowId: 43,
    candidateId: "db_43",
    name: "Example Food",
    source: "survey_fndds",
    servingDescription: "1 cup",
  };
  const result = await resolveFoodCandidate({
    userMessage: "I ate example food",
    foodMention: "example food",
    foodSearchStore: {
      search: () => [unsafe, safe],
      inspect: (rowId) => rowId === 42 ? unsafe : rowId === 43 ? safe : null,
    },
    askAgent: async () => pick({ rowId: 42 }),
  });

  assert.equal(result.status, 200);
  assert.equal(result.body.candidateId, "db_43");
});
