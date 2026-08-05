#!/usr/bin/env bash
# Upload all server source files to Lightsail and restart pm2.
# Usage: ./deploy.sh [--with-db]
#   --with-db  also upload Nomva/Resources/foods.sqlite (large; only needed
#              when the food database itself changed)
set -euo pipefail

KEY="$HOME/Downloads/Config & Keys/LightsailDefaultKey-us-east-1.pem"
HOST="ubuntu@nomva.nerdquad.com"
REMOTE_DIR="nomva-api"   # relative to ubuntu's home

cd "$(dirname "$0")"

CANONICAL_DB="../Nomva/Resources/foods.sqlite"
EXPECTED_DB_SHA=$(grep '^NOMVA_FOOD_DB_SHA256=' ../ci_scripts/food-database.env | cut -d= -f2)

# Files to ship. Add new ones here as the server grows.
FILES=(
  index.js
  prompts.js
  analyticsStore.js
  stateStore.js
  foodSearchStore.js
  foodResolver.js
  foodKnowledgeStore.js
  webFoodResolver.js
  deleteTargetGuard.js
  editTargetGuard.js
  foodMentionGuard.js
  portionGuard.js
  numericGuards.js
  package.json
  package-lock.json
)

# ── Local sanity: never ship with a red unit suite or a stale local DB ──────
if [[ ! -d node_modules ]]; then
  echo "→ node_modules missing — installing"
  npm install --no-audit --no-fund
fi

run_tests() { npm test > /tmp/nomva-deploy-test.log 2>&1; }

echo "→ Running unit tests before deploy"
TESTS_PASSED=0
if run_tests; then
  TESTS_PASSED=1
else
  # Most common local failure: better-sqlite3 built against a different Node
  # version. Rebuild once and retry before giving up.
  if grep -qiE "better.sqlite3|NODE_MODULE_VERSION|invalid ELF|was compiled against" /tmp/nomva-deploy-test.log; then
    echo "→ Tests failed loading better-sqlite3 — rebuilding native module for Node $(node --version)"
    npm rebuild better-sqlite3 --no-audit --no-fund
    if run_tests; then TESTS_PASSED=1; fi
  fi
fi
if [[ "$TESTS_PASSED" != "1" ]]; then
  echo "✗ Unit tests failed — output below:"
  echo "──────────────────────────────────────────────"
  grep -E "^not ok|error:|failureType|Error \[|[#ℹ] (tests|pass|fail)" /tmp/nomva-deploy-test.log | head -25
  echo "──────────────────────────────────────────────"
  echo "  Full log: /tmp/nomva-deploy-test.log"
  exit 1
fi
PASS_COUNT=$(grep -E '^[#ℹ] pass' /tmp/nomva-deploy-test.log | head -1 | sed -E 's/^[#ℹ] pass[[:space:]]*//')
echo "  ✓ ${PASS_COUNT:-all} tests green"

if [[ -f "$CANONICAL_DB" && -n "$EXPECTED_DB_SHA" ]]; then
  LOCAL_SHA=$(shasum -a 256 "$CANONICAL_DB" | cut -d' ' -f1)
  if [[ "$LOCAL_SHA" != "$EXPECTED_DB_SHA" ]]; then
    echo "✗ Local foods.sqlite sha ($LOCAL_SHA) does not match ci_scripts/food-database.env ($EXPECTED_DB_SHA)."
    echo "  Rebuild or re-download the food DB before deploying."
    exit 1
  fi
fi

upload_db() {
  echo "→ Uploading foods.sqlite ($(du -h "$CANONICAL_DB" | cut -f1)) — this can take a while"
  ssh -i "$KEY" "$HOST" "mkdir -p ~/Nomva/Resources"
  scp -i "$KEY" "$CANONICAL_DB" "$HOST:~/Nomva/Resources/foods.sqlite"
}

# Runs the same store bootstrap the server itself runs, INCLUDING .env, so the
# check sees FOODS_DB_PATH exactly the way pm2 does.
verify_remote_db() {
  ssh -i "$KEY" "$HOST" "cd ~/$REMOTE_DIR && node -r dotenv/config -e '
    const { createFoodSearchStore } = require(\"./foodSearchStore\");
    const store = createFoodSearchStore({ dbPath: process.env.FOODS_DB_PATH });
    if (!store.isAvailable) {
      console.error(\"REMOTE FOOD DB CHECK FAILED: \" + store.error);
      process.exit(1);
    }
    console.log(\"remote food db ok: \" + store.dbPath + \" (\" + store.rowCount + \" rows)\");
    store.close();
  '"
}

if [[ "${1:-}" == "--with-db" ]]; then
  upload_db
fi

echo "→ Uploading ${#FILES[@]} files to $HOST:~/$REMOTE_DIR/"
scp -i "$KEY" "${FILES[@]}" "$HOST:~/$REMOTE_DIR/"

# ── Remote DB gate: refuse to restart onto a stale or missing food database ──
echo "→ Verifying the food database on the server"
if ! verify_remote_db; then
  echo "→ Remote food DB missing or failed the schema check — uploading the canonical database"
  upload_db
  verify_remote_db || { echo "✗ Remote DB still failing after upload — not restarting. Investigate on the server."; exit 1; }
fi

echo "→ Installing any new npm deps + restarting pm2"
ssh -i "$KEY" "$HOST" "cd ~/$REMOTE_DIR && npm install --omit=dev --no-audit --no-fund && pm2 restart nomva-api && pm2 logs nomva-api --lines 40 --nostream"

echo "→ Post-deploy health check"
sleep 2
HEALTH=$(curl -sS -m 10 https://nomva.nerdquad.com/health)
echo "  $HEALTH"
echo "$HEALTH" | grep -q '"available":true' || { echo "✗ /health reports the food DB unavailable — investigate before considering this deploy done"; exit 1; }

echo "✓ Deploy complete"
