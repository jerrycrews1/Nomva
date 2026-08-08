#!/usr/bin/env bash
# Upload all server source files to Lightsail and restart pm2.
# Usage: ./deploy.sh [--with-db]
#   --with-db  also upload Nomva/Resources/foods.sqlite (large; only needed
#              when the food database itself changed)
set -euo pipefail

KEY="$HOME/Downloads/Config & Keys/LightsailDefaultKey-us-east-1.pem"
HOST="ubuntu@nomva.nerdquad.com"
REMOTE_DIR="nomva-api"   # relative to ubuntu's home
REMOTE_NODE_BIN="/home/ubuntu/.local/node24/bin"
REMOTE_NODE="$REMOTE_NODE_BIN/node"
DEPLOY_ID="$(date -u +%Y%m%dT%H%M%SZ)"
REMOTE_STAGE=".${REMOTE_DIR}-deploy-${DEPLOY_ID}"
REMOTE_BACKUP="${REMOTE_DIR}/deploy-backups/${DEPLOY_ID}"

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
  foodLogPlanner.js
  webFoodResolver.js
  worldFoodEstimator.js
  foodTokenNormalizer.js
  nutritionEstimate.js
  portionMath.js
  structuredLLM.js
  llmSchemas.js
  deleteTargetGuard.js
  editTargetGuard.js
  foodMentionGuard.js
  portionGuard.js
  numericGuards.js
  recentFoodSuggestionGuard.js
  authPolicy.js
  appStoreEntitlement.js
  package.json
  package-lock.json
)

CERT_FILES=(
  certs/AppleIncRootCertificate.pem
  certs/AppleRootCA-G2.pem
  certs/AppleRootCA-G3.pem
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

REMOTE_DB_PATH=$(ssh -i "$KEY" "$HOST" "export PATH='$REMOTE_NODE_BIN':\$PATH; cd ~/$REMOTE_DIR && node -r dotenv/config -e '
  const path = require(\"path\");
  process.stdout.write(path.resolve(process.env.FOODS_DB_PATH || \"foods.sqlite\"));
'")
REMOTE_PREVIOUS_NODE=$(ssh -i "$KEY" "$HOST" "/usr/bin/node -e '
  const fs = require(\"fs\");
  const apps = JSON.parse(fs.readFileSync(\"/home/ubuntu/.pm2/dump.pm2\", \"utf8\"));
  const app = apps.find((item) => item.name === \"nomva-api\");
  process.stdout.write(app?.exec_interpreter || \"/usr/bin/node\");
'")
REMOTE_DB_INCOMING="${REMOTE_DB_PATH}.incoming-${DEPLOY_ID}"

upload_db() {
  echo "→ Uploading foods.sqlite ($(du -h "$CANONICAL_DB" | cut -f1)) to the configured production path"
  scp -i "$KEY" "$CANONICAL_DB" "$HOST:$REMOTE_DB_INCOMING"
  ssh -i "$KEY" "$HOST" "export PATH='$REMOTE_NODE_BIN':\$PATH; cd ~/$REMOTE_STAGE && node -e '
    const { createFoodSearchStore } = require(\"./foodSearchStore\");
    const store = createFoodSearchStore({ dbPath: process.argv[1] });
    if (!store.isAvailable) {
      console.error(\"INCOMING FOOD DB CHECK FAILED: \" + store.error);
      process.exit(1);
    }
    console.log(\"incoming food db ok: \" + store.rowCount + \" rows\");
    store.close();
  ' '$REMOTE_DB_INCOMING'"
  ssh -i "$KEY" "$HOST" "set -e
    mkdir -p ~/$REMOTE_BACKUP
    if [[ -f '$REMOTE_DB_PATH' && ! -f ~/$REMOTE_BACKUP/foods.sqlite ]]; then
      cp -p '$REMOTE_DB_PATH' ~/$REMOTE_BACKUP/foods.sqlite
    fi
    mv '$REMOTE_DB_INCOMING' '$REMOTE_DB_PATH'
  "
}

# Runs the same store bootstrap the server itself runs, INCLUDING .env, so the
# check sees FOODS_DB_PATH exactly the way pm2 does.
verify_remote_db() {
  ssh -i "$KEY" "$HOST" "export PATH='$REMOTE_NODE_BIN':\$PATH; cd ~/$REMOTE_STAGE && node -r dotenv/config -e '
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

echo "→ Staging ${#FILES[@]} source files and production dependencies"
ssh -i "$KEY" "$HOST" "rm -rf ~/$REMOTE_STAGE && mkdir -p ~/$REMOTE_STAGE/certs"
scp -i "$KEY" "${FILES[@]}" "$HOST:~/$REMOTE_STAGE/"
scp -i "$KEY" "${CERT_FILES[@]}" "$HOST:~/$REMOTE_STAGE/certs/"
ssh -i "$KEY" "$HOST" "set -e
  export PATH='$REMOTE_NODE_BIN':\$PATH
  cp ~/$REMOTE_DIR/.env ~/$REMOTE_STAGE/.env
  cd ~/$REMOTE_STAGE
  npm install --omit=dev --no-audit --no-fund
  for file in *.js; do node --check \"\$file\"; done
"

echo "→ Backing up the active release"
SOURCE_LIST="${FILES[*]} ${CERT_FILES[*]}"
ssh -i "$KEY" "$HOST" "set -e
  mkdir -p ~/$REMOTE_BACKUP
  cd ~/$REMOTE_DIR
  tar --ignore-failed-read -czf ~/$REMOTE_BACKUP/source.tar.gz $SOURCE_LIST
"

DEPLOY_COMMITTED=0
rollback_on_exit() {
  rc=$?
  if [[ "$rc" != "0" && "$DEPLOY_COMMITTED" != "1" ]]; then
    echo "→ Deployment failed; restoring the previous server release"
    set +e
    ssh -i "$KEY" "$HOST" "set -e
      cd ~/$REMOTE_DIR
      for file in $SOURCE_LIST; do rm -f \"\$file\"; done
      if [[ -f ~/$REMOTE_BACKUP/source.tar.gz ]]; then tar -xzf ~/$REMOTE_BACKUP/source.tar.gz; fi
      if [[ -d ~/$REMOTE_BACKUP/node_modules ]]; then
        rm -rf node_modules
        mv ~/$REMOTE_BACKUP/node_modules node_modules
      fi
      if [[ -f ~/$REMOTE_BACKUP/foods.sqlite ]]; then cp -p ~/$REMOTE_BACKUP/foods.sqlite '$REMOTE_DB_PATH'; fi
      export PATH='$REMOTE_NODE_BIN':\$PATH
      pm2 delete nomva-api >/dev/null 2>&1 || true
      pm2 start index.js --name nomva-api --interpreter '$REMOTE_PREVIOUS_NODE'
      pm2 save
    "
  fi
  exit "$rc"
}
trap rollback_on_exit EXIT

if [[ "${1:-}" == "--with-db" ]]; then
  upload_db
fi

# ── Remote DB gate: refuse to restart onto a stale or missing food database ──
echo "→ Verifying the food database on the server"
if ! verify_remote_db; then
  echo "→ Remote food DB missing or failed the schema check — uploading the canonical database"
  upload_db
  verify_remote_db || { echo "✗ Remote DB still failing after upload — not restarting. Investigate on the server."; exit 1; }
fi

echo "→ Promoting the staged release"
ssh -i "$KEY" "$HOST" "set -e
  cd ~/$REMOTE_DIR
  if [[ -d node_modules ]]; then mv node_modules ~/$REMOTE_BACKUP/node_modules; fi
  mv ~/$REMOTE_STAGE/node_modules ./node_modules
  for file in $SOURCE_LIST; do
    mkdir -p \"\$(dirname \"\$file\")\"
    cp ~/$REMOTE_STAGE/\"\$file\" \"\$file\"
  done
"

echo "→ Restarting pm2 on the promoted release"
ssh -i "$KEY" "$HOST" "set -e
  export PATH='$REMOTE_NODE_BIN':\$PATH
  cd ~/$REMOTE_DIR
  pm2 delete nomva-api >/dev/null 2>&1 || true
  pm2 start index.js --name nomva-api --interpreter '$REMOTE_NODE'
  pm2 save
  pm2 logs nomva-api --lines 40 --nostream
"

echo "→ Post-deploy health check"
sleep 2
HEALTH=$(curl -sS -m 10 https://nomva.nerdquad.com/health)
echo "  $HEALTH"
echo "$HEALTH" | grep -q '"available":true' || { echo "✗ /health reports the food DB unavailable — investigate before considering this deploy done"; exit 1; }

DEPLOY_COMMITTED=1
trap - EXIT
ssh -i "$KEY" "$HOST" "rm -rf ~/$REMOTE_STAGE"
echo "✓ Deploy complete"
