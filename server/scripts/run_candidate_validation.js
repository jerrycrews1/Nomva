#!/usr/bin/env node
"use strict";

// Runs the current source against real models in an isolated server instance.
// Credentials stay in the configured environment; all identities/data are synthetic.
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const net = require("node:net");
const crypto = require("node:crypto");
const { spawn } = require("node:child_process");
const root = path.resolve(__dirname, "../..");
const config = process.argv.find((x) => x.startsWith("--config="))?.slice(9);
if (config) require("dotenv").config({ path: config, quiet: true });
if (!process.env.OPENAI_API_KEY) throw new Error("Configure OPENAI_API_KEY in the execution environment.");

async function freePort() {
  const server = net.createServer();
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const port = server.address().port;
      server.close(() => resolve(port));
    });
  });
}

async function main() {
  const data = fs.mkdtempSync(path.join(os.tmpdir(), "nomva-synthetic-validation-"));
  const reports = path.join(root, "reports/reliability-live");
  fs.mkdirSync(reports, { recursive: true });
  const port = await freePort();
  const baseURL = `http://127.0.0.1:${port}`;
  const automation = crypto.randomBytes(32).toString("hex");
  const environment = {
    ...process.env, PORT: String(port), NOMVA_BIND_HOST: "127.0.0.1", NODE_ENV: "production",
    NOMVA_DATA_DIR: data, STATE_ENCRYPTION_KEY: crypto.randomBytes(32).toString("hex"),
    FOOD_KNOWLEDGE_DB_PATH: path.join(data, "food-knowledge.sqlite"),
    ANALYTICS_DB_PATH: path.join(data, "analytics.sqlite"), ANALYTICS_ENABLED: "0",
    NOMVA_AUTOMATION_TOKEN: automation, NOMVA_ENTITLEMENT_MODE: "audit", APP_STORE_ONLINE_CHECKS: "0",
    NOMVA_EVAL_BASE_URL: baseURL, NOMVA_EVAL_FOOD_DB_PATH: process.env.FOODS_DB_PATH,
    NOMVA_EVAL_CONCURRENCY: "2",
  };
  const output = fs.openSync(path.join(reports, "candidate-server.log"), "w");
  const child = spawn(process.execPath, ["index.js"], { cwd: path.join(root, "server"), env: environment, stdio: ["ignore", output, output] });
  fs.closeSync(output);
  try {
    let ready = false;
    for (let attempt = 0; attempt < 60; attempt++) {
      if (child.exitCode !== null) throw new Error(`Candidate server exited: ${child.exitCode}`);
      try { ready = (await fetch(`${baseURL}/health`, { signal: AbortSignal.timeout(1_000) })).ok; } catch {}
      if (ready) break;
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    if (!ready) throw new Error("Candidate server was not ready within 30 seconds.");
    const headers = { "Content-Type": "application/json", "X-Nomva-User-ID": `synthetic-reliability-${Date.now()}`,
      "X-Nomva-Device-Token": "synthetic-reliability-device", "X-Nomva-Automation-Token": automation };
    async function post(route, body) {
      const start = Date.now();
      const response = await fetch(baseURL + route, { method: "POST", headers, body: JSON.stringify(body), signal: AbortSignal.timeout(45_000) });
      return { status: response.status, body: await response.json(), durationMs: Date.now() - start };
    }
    const registration = await post("/v1/auth/register", {});
    if (registration.status !== 200) throw new Error(`Synthetic registration failed: ${registration.status}`);
    headers.Authorization = `Bearer ${registration.body.token}`;
    const cases = [
      { id: "separate-foods", route: "/v1/plan-food-log", body: { userMessage: "I ate one apple and one banana" }, check: (b) => b.items?.length === 2 },
      { id: "repeated-servings", route: "/v1/plan-food-log", body: { userMessage: "I ate one plain bagel and then another identical plain bagel" }, check: (b) => b.items?.reduce((n, x) => n + x.servings, 0) === 2 },
      { id: "pending-food-only", route: "/v1/plan-food-log", body: { userMessage: "It was a 6-inch turkey sandwich", pendingFoods: ["sandwich"], recentMessages: [
        { role: "user", content: "I had an apple and a sandwich" }, { role: "assistant", content: "Logged Apple. Sandwich was not added; describe the sandwich." },
      ] }, check: (b) => b.items?.length === 1 && /sandwich/i.test(b.items[0].mention) && !/apple/i.test(b.items[0].mention) },
      { id: "nonexistent-delete", route: "/v1/pick-delete-targets", body: { userMessage: "delete my banana", logSummary: "White rice (lunch)" }, check: (b) => Array.isArray(b.foodNames) && b.foodNames.length === 0 },
      { id: "specific-coaching", route: "/v1/general-reply", body: { userMessage: "What is one practical way to improve this lunch?", context: "SELECTED DAY: Lunch was white rice and black beans, 450 cal and 15 g protein. No other records or goals are supplied." }, check: (b) => typeof b.text === "string" && /rice|beans/i.test(b.text), manualReview: true },
      { id: "honest-missing-weight", route: "/v1/general-reply", body: { userMessage: "How much did my weight change?", context: "No weight history is supplied. Weight queries are handled on the device." }, check: (b) => typeof b.text === "string" && !/\d+(?:\.\d+)?\s*(lb|kg|pounds|kilograms)/i.test(b.text), manualReview: true },
      { id: "no-false-mutation", route: "/v1/general-reply", body: { userMessage: "Did you save that lunch?", context: "No save receipt is available." }, check: (b) => typeof b.text === "string" && !/\b(I saved|I logged|I've saved|I've logged|successfully saved)\b/i.test(b.text), manualReview: true },
    ];
    const results = [];
    for (const testCase of cases) {
      const response = await post(testCase.route, testCase.body);
      const passed = response.status === 200 && testCase.check(response.body);
      results.push({ id: testCase.id, passed, manualReview: !!testCase.manualReview, ...response });
      console.log(`${testCase.id}: ${passed ? "PASS" : "FAIL"} (${response.durationMs} ms)`);
    }
    const report = { generatedAt: new Date().toISOString(), runtime: process.version, target: "isolated candidate on loopback",
      models: { main: process.env.NOMVA_LLM_MODEL || process.env.OPENAI_MODEL || "gpt-4o-mini", context: process.env.NOMVA_CONTEXT_MODEL || "gpt-5.4-mini", planner: process.env.NOMVA_FOOD_LOG_PLANNING_MODEL || "gpt-5.6-luna" },
      sourceHashes: Object.fromEntries(["index.js", "prompts.js", "foodLogPlanner.js", "webFoodResolver.js"].map((file) => [file, crypto.createHash("sha256").update(fs.readFileSync(path.join(root, "server", file))).digest("hex")])), results };
    fs.writeFileSync(path.join(reports, "targeted-chat.json"), JSON.stringify(report, null, 2));
    const holdoutLog = fs.openSync(path.join(reports, "holdout2.log"), "w");
    const evaluator = spawn(process.execPath, ["scripts/run_product_release_gate_200.js", "--set=holdout2"], { cwd: root, env: environment, stdio: ["ignore", holdoutLog, holdoutLog] });
    fs.closeSync(holdoutLog);
    const code = await new Promise((resolve, reject) => { evaluator.once("error", reject); evaluator.once("exit", resolve); });
    console.log(`${process.env.NOMVA_EVAL_CASE_IDS ? "Focused holdout" : "200-case holdout"} exit: ${code}`);
    process.exitCode = results.every((r) => r.passed) && code === 0 ? 0 : 2;
  } finally {
    child.kill("SIGTERM");
    await new Promise((resolve) => { if (child.exitCode !== null) resolve(); else child.once("exit", resolve); });
    fs.rmSync(data, { recursive: true, force: true });
  }
}

main().catch((error) => { console.error(error.message); process.exitCode = 1; });
