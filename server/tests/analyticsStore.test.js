const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { loadAnalyticsStore } = require("../analyticsStore");

test("deletes only analytics linked to the requested user hash", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "nomva-analytics-"));
  const store = loadAnalyticsStore({
    enabled: true,
    dbPath: path.join(directory, "analytics.sqlite"),
    hashSalt: "test-salt",
  });
  const firstUser = store.hashUserId("first-user");
  const secondUser = store.hashUserId("second-user");

  store.record({ eventType: "client_network", userHash: firstUser });
  store.record({ eventType: "server_request", userHash: firstUser });
  store.record({ eventType: "server_request", userHash: secondUser });

  assert.equal(store.deleteUser(firstUser), 2);
  assert.equal(store.deleteUser(firstUser), 0);
  assert.equal(store.summary({ hours: 1 }).totals.events, 1);
});

test("disabled analytics exposes a safe no-op delete", () => {
  const store = loadAnalyticsStore({ enabled: false });
  assert.equal(store.deleteUser("anything"), 0);
});
