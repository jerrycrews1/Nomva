"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");

function availablePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close((error) => error ? reject(error) : resolve(port));
    });
  });
}

function waitForServer(child, expectedLine) {
  return new Promise((resolve, reject) => {
    let output = "";
    const timeout = setTimeout(() => reject(new Error(`Server did not start. Output: ${output}`)), 10_000);
    const consume = (chunk) => {
      output += chunk.toString();
      if (output.includes(expectedLine)) {
        clearTimeout(timeout);
        resolve();
      }
    };
    child.stdout.on("data", consume);
    child.stderr.on("data", consume);
    child.once("exit", (code) => {
      clearTimeout(timeout);
      reject(new Error(`Server exited with ${code}. Output: ${output}`));
    });
  });
}

test("production accepts scoped automation auth and rejects simulator spoofing", { timeout: 20_000 }, async (t) => {
  const port = await availablePort();
  const dataDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "nomva-auth-integration-"));
  const automationToken = "integration-secret-with-more-than-32-characters";
  const child = spawn(process.execPath, ["index.js"], {
    cwd: path.join(__dirname, ".."),
    env: {
      ...process.env,
      PORT: String(port),
      NODE_ENV: "production",
      NOMVA_DATA_DIR: dataDirectory,
      STATE_ENCRYPTION_KEY: "integration-state-encryption-key",
      OPENAI_API_KEY: "unused-integration-key",
      ANALYTICS_ENABLED: "0",
      APP_ATTEST_ALLOW_DEVELOPMENT: "0",
      ALLOW_SIMULATOR_AUTH: "1",
      NOMVA_AUTOMATION_TOKEN: automationToken,
      NOMVA_ENTITLEMENT_MODE: "audit",
      APP_STORE_ONLINE_CHECKS: "0",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  t.after(() => {
    if (!child.killed) child.kill("SIGTERM");
  });
  await waitForServer(child, `Nomva API running on port ${port}`);

  const baseHeaders = {
    "Content-Type": "application/json",
    "X-Nomva-User-ID": "integration-user",
    "X-Nomva-Device-Token": "integration-device",
  };
  const register = (extraHeaders) => fetch(`http://127.0.0.1:${port}/v1/auth/register`, {
    method: "POST",
    headers: { ...baseHeaders, ...extraHeaders },
    body: "{}",
  });

  const spoofed = await register({ "X-Nomva-App-Attest-Mode": "simulator" });
  assert.equal(spoofed.status, 401);
  assert.equal((await spoofed.json()).error, "simulator_auth_disabled");

  const wrongToken = await register({ "X-Nomva-Automation-Token": "wrong" });
  assert.equal(wrongToken.status, 401);
  assert.equal((await wrongToken.json()).error, "invalid_automation_token");

  const oversized = await fetch(`http://127.0.0.1:${port}/v1/auth/register`, {
    method: "POST",
    headers: {
      ...baseHeaders,
      "X-Nomva-Automation-Token": automationToken,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ padding: "x".repeat(300_000) }),
  });
  assert.equal(oversized.status, 413);
  assert.equal((await oversized.json()).error, "request_too_large");

  const accepted = await register({ "X-Nomva-Automation-Token": automationToken });
  assert.equal(accepted.status, 200);
  const session = await accepted.json();
  assert.equal(session.entitlement.status, "active");
  assert.equal(session.entitlement.source, "automation");
  const lifetime = Date.parse(session.expiresAt) - Date.now();
  assert.ok(lifetime > 60 * 60 * 1000 && lifetime <= 2 * 60 * 60 * 1000);

  const status = await fetch(`http://127.0.0.1:${port}/v1/garmin/status`, {
    headers: {
      ...baseHeaders,
      "X-Nomva-Automation-Token": automationToken,
      Authorization: `Bearer ${session.token}`,
    },
  });
  assert.equal(status.status, 200);
});
