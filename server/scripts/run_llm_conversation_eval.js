#!/usr/bin/env node

require("dotenv").config({ path: require("path").join(__dirname, "..", ".env") });

const fs = require("fs");
const path = require("path");
const OpenAI = require("openai");
const prompts = require("../prompts");

const MODEL = process.env.CONVERSATION_MODEL || process.env.BASELINE_MODEL || process.env.NOMVA_LLM_BASELINE_MODEL || "gpt-4o-mini";
const CASES_PATH = process.env.CONVERSATION_CASES_PATH || path.join(__dirname, "..", "baseline", "llm_conversation_cases.json");
const REPORT_DIR = process.env.CONVERSATION_REPORT_DIR || path.join(__dirname, "..", "baseline", "reports");
const MIN_SCORE = process.env.CONVERSATION_MIN_SCORE ? Number(process.env.CONVERSATION_MIN_SCORE) : null;

if (!process.env.OPENAI_API_KEY) {
  console.error("Missing OPENAI_API_KEY. Add it to server/.env or export it before running conversation evals.");
  process.exit(1);
}

const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

function timestampForFile(date = new Date()) {
  return date.toISOString().replace(/[:.]/g, "-");
}

function normalizeText(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/\b1\/2\b/g, "0.5")
    .replace(/\b1\/4\b/g, "0.25")
    .replace(/\b3\/4\b/g, "0.75")
    .replace(/\bhalf\b/g, "0.5")
    .replace(/\bquarter\b/g, "0.25")
    .replace(/\bthree quarters\b/g, "0.75")
    .replace(/\btablespoons?\b/g, "tbsp")
    .replace(/\bteaspoons?\b/g, "tsp")
    .replace(/\bounces?\b/g, "oz")
    .replace(/\bpieces?\b/g, "piece")
    .replace(/\bnuggets?\b/g, "piece")
    .replace(/\bfries\b/g, "fry")
    .replace(/\bslices\b/g, "slice")
    .replace(/\bcups\b/g, "cup")
    .replace(/\bbowls\b/g, "bowl")
    .replace(/\bsandwiches\b/g, "sandwich")
    .replace(/\b(a|an|the)\b/g, " ")
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
  if (left === "0.5" && /(^|\s)(0.5|1 tbsp|1 cup|0.5 cup|0.5 bowl|0.5 sandwich)(\s|$)/.test(right)) {
    return true;
  }
  if (left === "0.25" && /(^|\s)(0.25|0.25 cup|1 4 cup)(\s|$)/.test(right)) {
    return true;
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

function renderHistory(messages = []) {
  return messages
    .slice(-6)
    .map((m) => `${m.role === "user" ? "User" : "Assistant"}: ${m.content}`)
    .join("\n");
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
  caseResult.checks.push({ name, pass, expected, actual });
}

function summarizeBy(results, key) {
  const groups = {};
  for (const result of results) {
    const groupKey = result[key] || "uncategorized";
    if (!groups[groupKey]) {
      groups[groupKey] = {
        cases: 0,
        passedCases: 0,
        totalChecks: 0,
        passedChecks: 0,
        score: 0,
      };
    }
    const group = groups[groupKey];
    group.cases += 1;
    group.passedCases += result.pass ? 1 : 0;
    group.totalChecks += result.checks.length;
    group.passedChecks += result.checks.filter((check) => check.pass).length;
  }

  for (const group of Object.values(groups)) {
    group.score = group.totalChecks ? group.passedChecks / group.totalChecks : 0;
  }
  return groups;
}

async function evaluateCase(testCase) {
  const message = testCase.message;
  const expect = testCase.expect || {};
  const history = renderHistory(testCase.transcript || []);
  const result = {
    id: testCase.id,
    description: testCase.description,
    difficulty: testCase.difficulty || null,
    category: testCase.category || null,
    message,
    checks: [],
    steps: [],
  };

  if (expect.intent) {
    const enriched = history ? `${history}\nUser: ${message}` : `User: ${message}`;
    const output = await runStep(result, "classify_intent_with_history", prompts.CLASSIFY_INTENT, enriched, 64);
    addCheck(result, "intent", output?.intent === expect.intent, expect.intent, output?.intent ?? null);
  }

  if (expect.editTarget || expect.clarification) {
    const output = await runStep(
      result,
      "pick_edit_target_with_history",
      prompts.PICK_EDIT_TARGET,
      [
        history,
        `Food log:\n${testCase.logSummary || ""}`,
        `User said: ${message}`,
      ].filter(Boolean).join("\n\n"),
      160
    );
    if (expect.editTarget) {
      addCheck(result, "edit_target", textMatches(expect.editTarget, output?.foodName), expect.editTarget, output?.foodName ?? null);
    }
    if (expect.clarification) {
      const hasQuestion = typeof output?.clarificationQuestion === "string" && output.clarificationQuestion.trim().length > 0;
      const hasNoFood = !output?.foodName;
      addCheck(result, "asks_clarification", hasQuestion && hasNoFood, "clarification without guessed food", output);
    }
  }

  if (expect.editRequest) {
    const edit = expect.editRequest;
    const output = await runStep(
      result,
      "resolve_edit_request_with_history",
      prompts.RESOLVE_EDIT_REQUEST,
      [
        history,
        `Current entry: ${edit.currentEntryName}`,
        edit.currentEntryBrand ? `Current brand: ${edit.currentEntryBrand}` : null,
        `Current portion: ${edit.currentPortionDescription}`,
        `User said: ${message}`,
      ].filter(Boolean).join("\n\n"),
      180
    );
    if (Object.prototype.hasOwnProperty.call(edit, "hasExplicitPortion")) {
      addCheck(result, "edit_has_explicit_portion", Boolean(output?.hasExplicitPortion) === Boolean(edit.hasExplicitPortion), Boolean(edit.hasExplicitPortion), Boolean(output?.hasExplicitPortion));
    }
    if (Object.prototype.hasOwnProperty.call(edit, "servings")) {
      addCheck(result, "edit_servings", numericMatches(edit.servings, output?.servings, edit.tolerance ?? 0.15), edit.servings, output?.servings ?? null);
    }
    if (edit.portionDescription) {
      addCheck(result, "edit_portion", textMatches(edit.portionDescription, output?.portionDescription), edit.portionDescription, output?.portionDescription ?? null);
    }
    if (Object.prototype.hasOwnProperty.call(edit, "replacementSearchQuery")) {
      addCheck(result, "edit_replacement_query", textMatches(edit.replacementSearchQuery, output?.replacementSearchQuery || ""), edit.replacementSearchQuery, output?.replacementSearchQuery ?? null);
    }
  }

  if (Array.isArray(expect.deleteTargets)) {
    const output = await runStep(
      result,
      "pick_delete_targets_with_history",
      prompts.PICK_DELETE_TARGETS,
      [
        history,
        `Food log:\n${testCase.logSummary || ""}`,
        `User said: ${message}`,
      ].filter(Boolean).join("\n\n"),
      160
    );
    const actualNames = Array.isArray(output?.foodNames) ? output.foodNames : [];
    const pass = expect.deleteTargets.every((expectedName) =>
      actualNames.some((actualName) => textMatches(expectedName, actualName))
    ) && actualNames.length === expect.deleteTargets.length;
    addCheck(result, "delete_targets", pass, expect.deleteTargets, actualNames);
  }

  const passedChecks = result.checks.filter((check) => check.pass).length;
  result.pass = result.checks.length > 0 && passedChecks === result.checks.length;
  result.score = result.checks.length ? passedChecks / result.checks.length : 0;
  return result;
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
    runId: `llm-conversation-${timestampForFile(startedAt)}`,
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
    byDifficulty: summarizeBy(results, "difficulty"),
    byCategory: summarizeBy(results, "category"),
    cases: results,
  };

  const reportPath = path.join(REPORT_DIR, `${report.runId}.json`);
  const latestPath = path.join(REPORT_DIR, "latest-conversation.json");
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
  fs.writeFileSync(latestPath, JSON.stringify(report, null, 2));

  console.log("");
  console.log(`LLM conversation eval complete: ${(score * 100).toFixed(1)}% (${passedChecks}/${totalChecks} checks)`);
  console.log("By difficulty:");
  for (const [difficulty, group] of Object.entries(report.byDifficulty).sort()) {
    console.log(`  ${difficulty}: ${(group.score * 100).toFixed(1)}% (${group.passedChecks}/${group.totalChecks})`);
  }
  console.log("By category:");
  for (const [category, group] of Object.entries(report.byCategory).sort()) {
    console.log(`  ${category}: ${(group.score * 100).toFixed(1)}% (${group.passedChecks}/${group.totalChecks})`);
  }
  console.log(`Report: ${reportPath}`);

  if (Number.isFinite(MIN_SCORE) && score < MIN_SCORE) {
    console.error(`Conversation score is below CONVERSATION_MIN_SCORE=${MIN_SCORE}.`);
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
