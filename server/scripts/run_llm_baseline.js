#!/usr/bin/env node

require("dotenv").config({ path: require("path").join(__dirname, "..", ".env") });

const fs = require("fs");
const path = require("path");
const OpenAI = require("openai");
const prompts = require("../prompts");

const MODEL = process.env.NOMVA_LLM_MODEL || process.env.BASELINE_MODEL || process.env.NOMVA_LLM_BASELINE_MODEL || "gpt-4o-mini";
const CASES_PATH = process.env.BASELINE_CASES_PATH || path.join(__dirname, "..", "baseline", "llm_baseline_cases.json");
const REPORT_DIR = process.env.BASELINE_REPORT_DIR || path.join(__dirname, "..", "baseline", "reports");
const MIN_SCORE = process.env.BASELINE_MIN_SCORE ? Number(process.env.BASELINE_MIN_SCORE) : null;

if (!process.env.OPENAI_API_KEY) {
  console.error("Missing OPENAI_API_KEY. Add it to server/.env or export it before running the baseline.");
  process.exit(1);
}

const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

function timestampForFile(date = new Date()) {
  return date.toISOString().replace(/[:.]/g, "-");
}

function percentile(values, p) {
  if (!values.length) {
    return null;
  }
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[index];
}

function average(values) {
  if (!values.length) {
    return null;
  }
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function normalizeText(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function textMatches(expected, actual) {
  const left = normalizeText(expected);
  const right = normalizeText(actual);
  if (!left || !right) {
    return false;
  }
  return left.includes(right) || right.includes(left);
}

function numericMatches(expected, actual, tolerance = 0.1) {
  const actualNumber = Number(actual);
  const expectedNumber = Number(expected);
  return Number.isFinite(actualNumber) &&
    Number.isFinite(expectedNumber) &&
    Math.abs(actualNumber - expectedNumber) <= tolerance;
}

function jsonObject(raw) {
  const parsed = JSON.parse(raw);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Model did not return a JSON object.");
  }
  return parsed;
}

async function ask(task, systemPrompt, userMessage, maxTokens = 256) {
  const startedAt = Date.now();
  const completionBudget = /^gpt-5/i.test(MODEL)
    ? Math.max(maxTokens * 4, 512)
    : maxTokens;
  const request = {
    model: MODEL,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content: systemPrompt },
      { role: "user", content: userMessage },
    ],
  };
  if (/^gpt-5/i.test(MODEL)) {
    request.max_completion_tokens = completionBudget;
  } else {
    request.temperature = 0.1;
    request.max_tokens = completionBudget;
  }

  const response = await openai.chat.completions.create(request);

  const raw = response.choices[0]?.message?.content?.trim() || "{}";
  return {
    task,
    raw,
    json: jsonObject(raw),
    durationMs: Date.now() - startedAt,
    totalTokens: response.usage?.total_tokens || null,
  };
}

async function runStep(caseResult, task, systemPrompt, userPrompt, maxTokens) {
  try {
    const result = await ask(task, systemPrompt, userPrompt, maxTokens);
    caseResult.steps.push({
      task,
      ok: true,
      durationMs: result.durationMs,
      totalTokens: result.totalTokens,
      output: result.json,
    });
    return result.json;
  } catch (error) {
    caseResult.steps.push({
      task,
      ok: false,
      durationMs: null,
      totalTokens: null,
      error: error.message,
    });
    return null;
  }
}

function addCheck(caseResult, name, pass, expected, actual) {
  caseResult.checks.push({
    name,
    pass,
    expected,
    actual,
  });
}

async function evaluateCase(testCase) {
  const message = testCase.message;
  const expect = testCase.expect || {};
  const result = {
    id: testCase.id,
    message,
    checks: [],
    steps: [],
  };

  if (expect.intent) {
    const output = await runStep(
      result,
      "classify_intent",
      prompts.CLASSIFY_INTENT,
      `User: ${message}`,
      64
    );
    const actual = output?.intent || null;
    addCheck(result, "intent", actual === expect.intent, expect.intent, actual);
  }

  if (Array.isArray(expect.foods)) {
    const output = await runStep(
      result,
      "split_foods",
      prompts.SPLIT_FOODS,
      `User: ${message}`,
      128
    );
    const actualFoods = Array.isArray(output?.foods) ? output.foods : [];
    const pass = expect.foods.every((expectedFood) =>
      actualFoods.some((actualFood) => textMatches(expectedFood, actualFood))
    );
    addCheck(result, "foods", pass, expect.foods, actualFoods);
  }

  if (Array.isArray(expect.searchQueries)) {
    for (const searchCase of expect.searchQueries) {
      const output = await runStep(
        result,
        "build_food_search_query",
        prompts.BUILD_FOOD_SEARCH_QUERY,
        `User said: "${message}"\nFood mention: "${searchCase.foodMention}"`,
        96
      );
      const actual = output?.query || null;
      addCheck(
        result,
        `search_query_${searchCase.foodMention}`,
        textMatches(searchCase.query, actual),
        searchCase.query,
        actual
      );
    }
  }

  if (Object.prototype.hasOwnProperty.call(expect, "meal")) {
    const output = await runStep(
      result,
      "extract_meal",
      prompts.EXTRACT_MEAL,
      `User: ${message}`,
      64
    );
    const actualMeal = output?.meal === "none" ? null : output?.meal || null;
    addCheck(result, "meal", actualMeal === expect.meal, expect.meal, actualMeal);
  }

  if (expect.waterMutation) {
    const output = await runStep(
      result,
      "extract_water_mutation",
      prompts.EXTRACT_WATER_MUTATION,
      `User: ${message}`,
      96
    );
    addCheck(result, "water_action", output?.action === expect.waterMutation.action, expect.waterMutation.action, output?.action ?? null);
    if (Object.prototype.hasOwnProperty.call(expect.waterMutation, "amountOz")) {
      addCheck(
        result,
        "water_amount_oz",
        numericMatches(expect.waterMutation.amountOz, output?.amountOz, expect.waterMutation.tolerance ?? 0.6),
        expect.waterMutation.amountOz,
        output?.amountOz ?? null
      );
    }
  }

  if (expect.weightMutation) {
    const output = await runStep(
      result,
      "extract_weight_mutation",
      prompts.EXTRACT_WEIGHT_MUTATION,
      `User: ${message}`,
      96
    );
    addCheck(result, "weight_action", output?.action === expect.weightMutation.action, expect.weightMutation.action, output?.action ?? null);
    if (Object.prototype.hasOwnProperty.call(expect.weightMutation, "weightLbs")) {
      addCheck(
        result,
        "weight_lbs",
        numericMatches(expect.weightMutation.weightLbs, output?.weightLbs, expect.weightMutation.tolerance ?? 0.6),
        expect.weightMutation.weightLbs,
        output?.weightLbs ?? null
      );
    }
    if (Object.prototype.hasOwnProperty.call(expect.weightMutation, "dateHint")) {
      addCheck(result, "weight_date_hint", (output?.dateHint ?? null) === expect.weightMutation.dateHint, expect.weightMutation.dateHint, output?.dateHint ?? null);
    }
  }

  if (expect.deleteTargets) {
    const output = await runStep(
      result,
      "pick_delete_targets",
      prompts.PICK_DELETE_TARGETS,
      `Food log:\n${expect.deleteTargets.logSummary}\n\nUser said: ${message}`,
      128
    );
    const actualNames = Array.isArray(output?.foodNames) ? output.foodNames : [];
    const pass = expect.deleteTargets.foodNames.every((expectedName) =>
      actualNames.some((actualName) => textMatches(expectedName, actualName))
    );
    addCheck(result, "delete_targets", pass, expect.deleteTargets.foodNames, actualNames);
  }

  if (expect.editTarget) {
    const output = await runStep(
      result,
      "pick_edit_target",
      prompts.PICK_EDIT_TARGET,
      [
        expect.editTarget.recentMessages || "",
        `Food log:\n${expect.editTarget.logSummary}`,
        `User said: ${message}`,
      ].filter(Boolean).join("\n\n"),
      128
    );
    addCheck(
      result,
      "edit_target",
      textMatches(expect.editTarget.foodName, output?.foodName),
      expect.editTarget.foodName,
      output?.foodName ?? null
    );
  }

  if (expect.editRequest) {
    const output = await runStep(
      result,
      "resolve_edit_request",
      prompts.RESOLVE_EDIT_REQUEST,
      [
        `Current entry: ${expect.editRequest.currentEntryName}`,
        expect.editRequest.currentEntryBrand ? `Current brand: ${expect.editRequest.currentEntryBrand}` : null,
        `Current portion: ${expect.editRequest.currentPortionDescription}`,
        `User said: ${message}`,
      ].filter(Boolean).join("\n"),
      160
    );
    if (Object.prototype.hasOwnProperty.call(expect.editRequest, "hasExplicitPortion")) {
      addCheck(result, "edit_has_explicit_portion", Boolean(output?.hasExplicitPortion) === Boolean(expect.editRequest.hasExplicitPortion), Boolean(expect.editRequest.hasExplicitPortion), Boolean(output?.hasExplicitPortion));
    }
    if (Object.prototype.hasOwnProperty.call(expect.editRequest, "servings")) {
      addCheck(result, "edit_servings", numericMatches(expect.editRequest.servings, output?.servings, expect.editRequest.tolerance ?? 0.1), expect.editRequest.servings, output?.servings ?? null);
    }
    if (expect.editRequest.portionDescription) {
      addCheck(result, "edit_portion", textMatches(expect.editRequest.portionDescription, output?.portionDescription), expect.editRequest.portionDescription, output?.portionDescription ?? null);
    }
    if (Object.prototype.hasOwnProperty.call(expect.editRequest, "replacementSearchQuery")) {
      addCheck(result, "edit_replacement_query", textMatches(expect.editRequest.replacementSearchQuery, output?.replacementSearchQuery || ""), expect.editRequest.replacementSearchQuery, output?.replacementSearchQuery ?? null);
    }
  }

  if (expect.goal) {
    const output = await runStep(
      result,
      "extract_goal",
      prompts.EXTRACT_GOAL,
      `User: ${message}`,
      128
    );
    for (const [key, expectedValue] of Object.entries(expect.goal)) {
      addCheck(
        result,
        `goal_${key}`,
        numericMatches(expectedValue, output?.[key], 0.1),
        expectedValue,
        output?.[key] ?? null
      );
    }
  }

  if (expect.reply) {
    const output = await runStep(
      result,
      "general_reply",
      prompts.GENERAL_REPLY,
      `User: ${message}`,
      256
    );
    const actual = typeof output?.text === "string" ? output.text.trim() : "";
    addCheck(result, "reply_non_empty", actual.length > 0, "non-empty reply", actual);
  }

  if (Array.isArray(expect.servings)) {
    for (const servingCase of expect.servings) {
      const servingPrompt = [
        `User said: "${message}"`,
        `Food mention: "${servingCase.foodMention}"`,
        `Candidate: "${servingCase.candidateName}"`,
        servingCase.candidateServingDescription
          ? `Candidate serving: "${servingCase.candidateServingDescription}"`
          : null,
      ].filter(Boolean).join("\n");
      const output = await runStep(result, "extract_servings", prompts.EXTRACT_SERVINGS, servingPrompt, 128);
      addCheck(
        result,
        `servings_${servingCase.foodMention}`,
        numericMatches(servingCase.servings, output?.servings, servingCase.tolerance ?? 0.1),
        servingCase.servings,
        output?.servings ?? null
      );
      if (Object.prototype.hasOwnProperty.call(servingCase, "hasExplicitPortion")) {
        addCheck(
          result,
          `explicit_portion_${servingCase.foodMention}`,
          Boolean(output?.hasExplicitPortion) === Boolean(servingCase.hasExplicitPortion),
          Boolean(servingCase.hasExplicitPortion),
          Boolean(output?.hasExplicitPortion)
        );
      }
      if (servingCase.portionDescription) {
        addCheck(
          result,
          `portion_${servingCase.foodMention}`,
          textMatches(servingCase.portionDescription, output?.portionDescription),
          servingCase.portionDescription,
          output?.portionDescription ?? null
        );
      }
    }
  }

  if (Array.isArray(expect.candidateValidation)) {
    for (const validationCase of expect.candidateValidation) {
      const candidateLines = [
        `User said: "${message}"`,
        `Food mention: "${validationCase.foodMention}"`,
        `Search query: "${validationCase.searchQuery}"`,
        `Selected candidate: "${validationCase.candidateName}"`,
        validationCase.brand ? `Candidate brand: ${validationCase.brand}` : null,
        validationCase.servingDescription ? `Candidate serving: ${validationCase.servingDescription}` : null,
        validationCase.source ? `Candidate source: ${validationCase.source}` : null,
        `Portion basis: ${validationCase.portionBasis}`,
        `Calories per serving: ${validationCase.caloriesPerServing}`,
        `Extracted portion: "${validationCase.extractedPortionDescription}"`,
        `Extracted servings: ${validationCase.extractedServings}`,
        `Extracted confident: ${validationCase.extractedConfident === true}`,
        `Extracted hasExplicitPortion: ${validationCase.extractedHasExplicitPortion === true}`,
      ].filter(Boolean).join("\n");
      const output = await runStep(
        result,
        "validate_food_candidate",
        prompts.VALIDATE_FOOD_CANDIDATE,
        candidateLines,
        160
      );
      if (Object.prototype.hasOwnProperty.call(validationCase, "keepCurrentCandidate")) {
        addCheck(
          result,
          `candidate_keep_${validationCase.foodMention}`,
          Boolean(output?.keepCurrentCandidate) === Boolean(validationCase.keepCurrentCandidate),
          Boolean(validationCase.keepCurrentCandidate),
          Boolean(output?.keepCurrentCandidate)
        );
      }
      if (Object.prototype.hasOwnProperty.call(validationCase, "hasExplicitPortion")) {
        addCheck(
          result,
          `candidate_explicit_${validationCase.foodMention}`,
          Boolean(output?.hasExplicitPortion) === Boolean(validationCase.hasExplicitPortion),
          Boolean(validationCase.hasExplicitPortion),
          Boolean(output?.hasExplicitPortion)
        );
      }
      if (Object.prototype.hasOwnProperty.call(validationCase, "servings")) {
        addCheck(
          result,
          `candidate_servings_${validationCase.foodMention}`,
          numericMatches(validationCase.servings, output?.servings, validationCase.tolerance ?? 0.1),
          validationCase.servings,
          output?.servings ?? null
        );
      }
      if (validationCase.portionDescription) {
        addCheck(
          result,
          `candidate_portion_${validationCase.foodMention}`,
          textMatches(validationCase.portionDescription, output?.portionDescription),
          validationCase.portionDescription,
          output?.portionDescription ?? null
        );
      }
      if (Object.prototype.hasOwnProperty.call(validationCase, "replacementSearchQuery")) {
        addCheck(
          result,
          `candidate_replacement_${validationCase.foodMention}`,
          textMatches(validationCase.replacementSearchQuery, output?.replacementSearchQuery || ""),
          validationCase.replacementSearchQuery,
          output?.replacementSearchQuery ?? null
        );
      }
    }
  }

  if (Array.isArray(expect.grams)) {
    for (const gramCase of expect.grams) {
      const gramPrompt = [
        `Food: ${gramCase.foodName}`,
        `Portion: ${gramCase.portionDescription}`,
        gramCase.referenceServingDescription && typeof gramCase.referenceServingGrams === "number"
          ? `Reference serving: ${gramCase.referenceServingDescription} ≈ ${Math.round(gramCase.referenceServingGrams)} g`
          : null,
      ].filter(Boolean).join("\n");
      const output = await runStep(result, "estimate_grams", prompts.ESTIMATE_GRAMS, gramPrompt, 64);
      addCheck(
        result,
        `grams_${gramCase.foodName}`,
        numericMatches(gramCase.grams, output?.grams, gramCase.tolerance ?? 15),
        gramCase.grams,
        output?.grams ?? null
      );
    }
  }

  const passedChecks = result.checks.filter((check) => check.pass).length;
  result.pass = result.checks.length > 0 && passedChecks === result.checks.length;
  result.score = result.checks.length ? passedChecks / result.checks.length : 0;
  return result;
}

function buildStepStats(results) {
  const grouped = new Map();
  for (const result of results) {
    for (const step of result.steps) {
      if (!grouped.has(step.task)) {
        grouped.set(step.task, []);
      }
      grouped.get(step.task).push(step);
    }
  }

  const stats = {};
  for (const [task, steps] of grouped.entries()) {
    const durations = steps
      .map((step) => step.durationMs)
      .filter((value) => Number.isFinite(value));
    const tokens = steps
      .map((step) => step.totalTokens)
      .filter((value) => Number.isFinite(value));
    stats[task] = {
      count: steps.length,
      ok: steps.filter((step) => step.ok).length,
      avgMs: average(durations),
      p50Ms: percentile(durations, 50),
      p95Ms: percentile(durations, 95),
      avgTokens: average(tokens),
      totalTokens: tokens.reduce((sum, value) => sum + value, 0),
    };
  }
  return stats;
}

async function main() {
  const cases = JSON.parse(fs.readFileSync(CASES_PATH, "utf8"));
  fs.mkdirSync(REPORT_DIR, { recursive: true });

  const startedAt = new Date();
  const results = [];
  for (const testCase of cases) {
    console.log(`Running ${testCase.id}...`);
    results.push(await evaluateCase(testCase));
  }

  const totalChecks = results.reduce((sum, result) => sum + result.checks.length, 0);
  const passedChecks = results.reduce(
    (sum, result) => sum + result.checks.filter((check) => check.pass).length,
    0
  );
  const score = totalChecks ? passedChecks / totalChecks : 0;
  const report = {
    runId: `llm-baseline-${timestampForFile(startedAt)}`,
    startedAt: startedAt.toISOString(),
    finishedAt: new Date().toISOString(),
    model: MODEL,
    casesPath: CASES_PATH,
    summary: {
      cases: results.length,
      passedCases: results.filter((result) => result.pass).length,
      totalChecks,
      passedChecks,
      score,
    },
    stepStats: buildStepStats(results),
    cases: results,
  };

  const reportPath = path.join(REPORT_DIR, `${report.runId}.json`);
  const latestPath = path.join(REPORT_DIR, "latest.json");
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
  fs.writeFileSync(latestPath, JSON.stringify(report, null, 2));

  console.log("");
  console.log(`LLM baseline complete: ${(score * 100).toFixed(1)}% (${passedChecks}/${totalChecks} checks)`);
  console.log(`Report: ${reportPath}`);

  if (Number.isFinite(MIN_SCORE) && score < MIN_SCORE) {
    console.error(`Baseline score is below BASELINE_MIN_SCORE=${MIN_SCORE}.`);
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
