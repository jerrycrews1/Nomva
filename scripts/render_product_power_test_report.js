#!/usr/bin/env node

"use strict";

const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
const INPUT = process.argv[2]
  || path.join(ROOT, "reports", "power-test", "latest-100-user-power-test.json");
const OUTPUT = process.argv[3]
  || path.join(ROOT, "reports", "power-test", "NOMVA_100_USER_POWER_TEST_REPORT.md");
const JOURNEY_TARGET_MS = 5_000;

function percentile(values, percentileValue) {
  if (!values.length) return null;
  const sorted = [...values].sort((left, right) => left - right);
  const index = Math.min(
    sorted.length - 1,
    Math.max(0, Math.ceil(percentileValue * sorted.length) - 1)
  );
  return sorted[index];
}

function latencySummary(values) {
  return {
    journeys: values.length,
    median: percentile(values, 0.5),
    p90: percentile(values, 0.9),
    p95: percentile(values, 0.95),
    max: values.length ? Math.max(...values) : null,
    overTarget: values.filter((value) => value > JOURNEY_TARGET_MS).length,
    target: JOURNEY_TARGET_MS,
  };
}

function seconds(milliseconds) {
  return milliseconds == null ? "n/a" : `${(milliseconds / 1_000).toFixed(1)}s`;
}

function cell(value) {
  return String(value ?? "")
    .replace(/\|/g, "\\|")
    .replace(/\r?\n/g, " ")
    .trim();
}

function statusLabel(status) {
  return status === "pass" ? "PASS" : status === "friction" ? "FRICTION" : "FAIL";
}

const report = JSON.parse(fs.readFileSync(INPUT, "utf8"));
if (!Array.isArray(report.personas) || report.personas.length !== 100) {
  throw new Error(
    `Expected exactly 100 personas, found ${report.personas?.length ?? 0}`
  );
}

const remoteJourneys = report.personas
  .filter((persona) => persona.timings.length > 0)
  .map((persona) => persona.durationMs);
const foodJourneys = report.personas
  .filter((persona) => Array.isArray(persona.observed?.resolutions))
  .map((persona) => persona.durationMs);

report.summary.journeyLatencyMs = latencySummary(remoteJourneys);
report.summary.foodJourneyLatencyMs = latencySummary(foodJourneys);
report.handsOnValidation = {
  environment: "Signed Debug build, iPhone 16 Pro simulator, iOS 18.3.1",
  findings: [
    {
      journey: "Log dinner: salmon, rice, and broccoli",
      result: "All three foods logged to Dinner with plausible values.",
      elapsed: "Response was present by the 15.4-second observation.",
    },
    {
      journey: "How many calories do I have left today?",
      result: "Answer returned in about 3.0 seconds, but raw Markdown markers were visible.",
      elapsed: "3.0 seconds",
    },
    {
      journey: "Move the rice from dinner to lunch",
      result: "Chat said 'Updated Rice' but Rice remained in Dinner.",
      elapsed: "4.6 seconds",
    },
    {
      journey: "Move Salmon with the food-row accessibility action",
      result: "The explicit Move to Lunch action changed the meal correctly.",
      elapsed: "Immediate",
    },
    {
      journey: "Inspect a food row with the accessibility tree",
      result: "One food was exposed as several repeated elements, each with duplicate actions.",
      elapsed: "Immediate",
    },
  ],
};

fs.writeFileSync(INPUT, JSON.stringify(report, null, 2));

const cohorts = Object.entries(report.summary.byCohort);
const failures = report.personas
  .filter((persona) => persona.status !== "pass")
  .sort((left, right) => left.score - right.score);
const slowest = report.personas
  .filter((persona) => persona.durationMs > 0)
  .sort((left, right) => right.durationMs - left.durationMs)
  .slice(0, 10);

const lines = [];
lines.push("# Nomva 100-User Product Power Test");
lines.push("");
lines.push(`Generated: ${new Date().toISOString()}`);
lines.push("");
lines.push("## Verdict");
lines.push("");
lines.push(
  `Nomva scored **${report.summary.averagePersonaScore}/100 at the user-journey level**. `
  + `${report.summary.passPersonas}/100 personas passed completely, `
  + `${report.summary.frictionPersonas}/100 encountered material friction, and `
  + `${report.summary.failedPersonas}/100 failed.`
);
lines.push("");
lines.push(
  `The individual check pass rate was **${report.summary.checkAccuracy}%** `
  + `(${report.summary.passedChecks}/${report.summary.totalChecks}), but that number `
  + "overstates product readiness because a single failed action can ruin an otherwise "
  + "long journey. The user-level score is the decision metric."
);
lines.push("");
lines.push(
  "**Bottom line:** basic food recognition is substantially better, but AI chat is not "
  + "yet a 95/100 product. It is strong at straightforward logging and weak at compound "
  + "mutations, goal changes, deterministic calculations, recovery, and accessibility."
);
lines.push("");
lines.push("## Test Design");
lines.push("");
lines.push("- Exactly 100 synthetic user personas across 10 cohorts, 10 users per cohort.");
lines.push("- 724 graded assertions and 260 requests against the deployed Nomva server.");
lines.push("- Food results verified against the bundled `foods.sqlite`, not model text alone.");
lines.push("- Multi-turn context, food CRUD, water CRUD, weight CRUD, goals, queries, portions, brands, cultural foods, messy language, offline recovery, exports, accessibility, privacy, and speed.");
lines.push("- A signed current Debug build was also exercised in an iPhone 16 Pro simulator.");
lines.push("- This is simulated usability testing, not a claim that 100 external humans participated.");
lines.push("");
lines.push("## Scorecard");
lines.push("");
lines.push("| Metric | Result | Target |");
lines.push("|---|---:|---:|");
lines.push(`| Average persona score | ${report.summary.averagePersonaScore}/100 | 95+ |`);
lines.push(`| Fully passing personas | ${report.summary.passPersonas}/100 | 95+ |`);
lines.push(`| Individual checks | ${report.summary.checkAccuracy}% | 95%+ |`);
lines.push(`| Request latency p50 | ${seconds(report.summary.latencyMs.median)} | diagnostic only |`);
lines.push(`| Request latency p95 | ${seconds(report.summary.latencyMs.p95)} | diagnostic only |`);
lines.push(`| Full remote journey p50 | ${seconds(report.summary.journeyLatencyMs.median)} | <5s |`);
lines.push(`| Full remote journey p95 | ${seconds(report.summary.journeyLatencyMs.p95)} | <10s |`);
lines.push(`| Food-log journey p50 | ${seconds(report.summary.foodJourneyLatencyMs.median)} | <5s |`);
lines.push(`| Food-log journey p95 | ${seconds(report.summary.foodJourneyLatencyMs.p95)} | <10s |`);
lines.push(`| Food journeys over 5s | ${report.summary.foodJourneyLatencyMs.overTarget}/${report.summary.foodJourneyLatencyMs.journeys} | <5% |`);
lines.push("");
lines.push("## Cohort Results");
lines.push("");
lines.push("| Cohort | Users | Pass | Friction | Fail | Score |");
lines.push("|---|---:|---:|---:|---:|---:|");
for (const [name, cohort] of cohorts) {
  lines.push(
    `| ${cell(name)} | ${cohort.users} | ${cohort.pass} | ${cohort.friction} | `
    + `${cohort.fail} | ${cohort.score} |`
  );
}
lines.push("");
lines.push("## What Users Would Add");
lines.push("");
lines.push("1. **First-class chat actions for every editable object.** Add typed actions for moving food between meals, setting hydration goals, changing target weight, and managing favorites/templates. Do not route these through a generic food edit.");
lines.push("2. **Cancel, retry, and progress by stage.** Show whether Nomva is understanding, searching, or saving. A stalled request needs a visible escape hatch.");
lines.push("3. **One-tap recovery.** A failed barcode should open Create Custom Food with the code prefilled. A failed chat search should open local food search with the extracted query.");
lines.push("4. **Pinned favorites and real meal templates.** Frequent users need one-tap repeats with a meal choice. The existing `MealTemplate` data currently reaches the service but is unused.");
lines.push("5. **Visible Undo.** Food, water, and weight deletions need a short-lived Undo banner.");
lines.push("6. **Complete export and backup.** Include hydration, meal names, units, goals, custom foods, chat history, profiles, templates, and source provenance.");
lines.push("");
lines.push("## What Users Would Change");
lines.push("");
lines.push("1. **Make mutations transactional and verifiable.** The model should propose a typed action; app code should validate it, commit it, verify the postcondition, and only then compose the confirmation. This prevents the observed 'Updated Rice' false success.");
lines.push("2. **Parallelize multi-food resolution.** Foods are currently resolved serially. All 50 food journeys exceeded the 5-second target; median was "
  + `${seconds(report.summary.foodJourneyLatencyMs.median)} and p95 was ${seconds(report.summary.foodJourneyLatencyMs.p95)}.`);
lines.push("3. **Use deterministic math after semantic parsing.** The LLM can identify the requested metric and date range, but code must calculate averages, totals, and relative goal changes. The weekly-protein answer and 'lower by 200' goal failed.");
lines.push("4. **Treat an assistant confirmation as a transaction group.** 'Delete that' after a multi-item confirmation must target the whole prior action unless the user names one item.");
lines.push("5. **Improve retrieval deadlines and fallback.** Starbucks mocha and porridge hit 21-25 second 503 paths. Return a safe fallback or clarification within a bounded deadline.");
lines.push("6. **Handle composite dishes without double counting.** 'Tofu bibimbap' was split into bibimbap plus tofu even though the selected bibimbap already represented a complete dish.");
lines.push("7. **Render assistant content correctly.** The simulator displayed literal `**` markers. Either render supported Markdown or require plain text from the server.");
lines.push("8. **Fix VoiceOver grouping and reduced motion.** A food row currently appears as several repeated accessibility elements with duplicate actions.");
lines.push("9. **Clarify AI data use.** State that recent log context can be sent for AI answers, plus retention and deletion behavior.");
lines.push("");
lines.push("## What Users Would Remove");
lines.push("");
lines.push("1. **Remove false-success replies.** Never say 'updated', 'removed', or 'moved' from model intent alone.");
lines.push("2. **Remove raw Markdown from plain-text bubbles.** It reads like implementation debris.");
lines.push("3. **Remove silent fallback to Snack when meal inference fails.** Preserve an explicit meal, use the selected meal, or ask.");
lines.push("4. **Remove screenshot-specific food exceptions over time.** The service explicitly special-cases Chick-fil-A nuggets/fries, egg, spinach, blueberries, and coffee. Replace these with generic ranking features and a data-driven portion ontology.");
lines.push("5. **Remove or finish dormant meal-template plumbing.** Shipping a model and passing it into chat without using it adds complexity without user value.");
lines.push("");
lines.push("## Architecture Diagnosis");
lines.push("");
lines.push("The correct boundary is not 'LLM everywhere' or 'bypass the LLM.' It is:");
lines.push("");
lines.push("- **LLM:** understand language, resolve references, split foods, preserve modifiers, and reformulate searches.");
lines.push("- **Search/database:** retrieve and rank real nutrition records with provenance.");
lines.push("- **Deterministic app code:** perform arithmetic, units, transactions, CRUD postconditions, retries, idempotency, and confirmations.");
lines.push("");
lines.push("The current system blurs those boundaries. It asks the model to do arithmetic, serializes independent food searches, and lets a generic edit path acknowledge a meal move it cannot represent. At the same time, it contains food-specific shortcuts that make known regressions pass without generalizing.");
lines.push("");
lines.push("The older 200/200 CRUD suites both report 100%, but they grade isolated parser endpoints. Delete/edit cases also invoke the same deterministic guards used in production. They are useful unit tests, not an end-to-end product-readiness score.");
lines.push("");
lines.push("## Hands-On Simulator Findings");
lines.push("");
lines.push("| Journey | Observed result | Timing |");
lines.push("|---|---|---:|");
for (const finding of report.handsOnValidation.findings) {
  lines.push(
    `| ${cell(finding.journey)} | ${cell(finding.result)} | ${cell(finding.elapsed)} |`
  );
}
lines.push("");
lines.push("## Highest-Risk Persona Failures");
lines.push("");
lines.push("| User | Score | Cohort | Journey | User request |");
lines.push("|---|---:|---|---|---|");
for (const persona of failures) {
  lines.push(
    `| ${persona.personaId} | ${persona.score} | ${cell(persona.cohort)} | `
    + `${cell(persona.journey)} | ${cell(persona.feedback)} |`
  );
}
lines.push("");
lines.push("## Slowest Journeys");
lines.push("");
lines.push("| User | Time | Score | Journey |");
lines.push("|---|---:|---:|---|");
for (const persona of slowest) {
  lines.push(
    `| ${persona.personaId} | ${seconds(persona.durationMs)} | ${persona.score} | `
    + `${cell(persona.journey)} |`
  );
}
lines.push("");
lines.push("## All 100 Users");
lines.push("");
lines.push("| # | User | Persona | Difficulty | Journey | Score | Result | What this user wants |");
lines.push("|---:|---|---|---|---|---:|---|---|");
for (const persona of report.personas) {
  lines.push(
    `| ${persona.id} | ${persona.personaId} | ${cell(persona.profile)} | `
    + `${cell(persona.difficulty)} | ${cell(persona.journey)} | ${persona.score} | `
    + `${statusLabel(persona.status)} | ${cell(persona.feedback)} |`
  );
}
lines.push("");
lines.push("## Evidence Files");
lines.push("");
lines.push("- Raw 100-persona results: `reports/power-test/latest-100-user-power-test.json`");
lines.push("- Reproducible harness: `scripts/run_product_power_test_100_users.js`");
lines.push("- Report generator: `scripts/render_product_power_test_report.js`");
lines.push("- Existing isolated CRUD validation: `server/baseline/reports/latest-chat-crud-validation.json`");
lines.push("");
lines.push("## Recommended Release Gate");
lines.push("");
lines.push("Do not call AI chat 95/100 ready until a fresh, unseen 100-persona run meets all of these at once:");
lines.push("");
lines.push("- Average persona score at least 95.");
lines.push("- At least 95 fully passing personas.");
lines.push("- Zero false-success mutations.");
lines.push("- Zero critical arithmetic or relative-goal errors.");
lines.push("- Food-log p50 under 5 seconds and p95 under 10 seconds.");
lines.push("- The same thresholds hold in one clean validation run with new scenarios.");

fs.mkdirSync(path.dirname(OUTPUT), { recursive: true });
fs.writeFileSync(OUTPUT, `${lines.join("\n")}\n`);

console.log(JSON.stringify({
  input: INPUT,
  output: OUTPUT,
  personas: report.personas.length,
  averagePersonaScore: report.summary.averagePersonaScore,
  passPersonas: report.summary.passPersonas,
  foodJourneyLatencyMs: report.summary.foodJourneyLatencyMs,
}, null, 2));
