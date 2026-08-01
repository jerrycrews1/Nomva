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
  deleteTargetGuard.js
  editTargetGuard.js
  foodMentionGuard.js
  portionGuard.js
  numericGuards.js
  package.json
  package-lock.json
)

# ── Local sanity: never ship with a red unit suite or a stale local DB ──────
echo "→ Running unit tests before deploy"
npm test >/dev/null 2>&1 || { echo "✗ Unit tests failed — fix before deploying (run: npm test)"; exit 1; }

if [[ -f "$CANONICAL_DB" && -n "$EXPECTED_DB_SHA" ]]; then
  LOCAL_SHA=$(shasum -a 256 "$CANONICAL_DB" | cut -d' ' -f1)
  if [[ "$LOCAL_SHA" != "$EXPECTED_DB_SHA" ]]; then
    echo "✗ Local foods.sqlite sha ($LOCAL_SHA) does not match ci_scripts/food-database.env ($EXPECTED_DB_SHA)."
    echo "  Rebuild or re-download the food DB before deploying."
    exit 1
  fi
fi

if [[ "${1:-}" == "--with-db" ]]; then
  echo "→ Uploading foods.sqlite ($(du -h "$CANONICAL_DB" | cut -f1)) — this can take a while"
  ssh -i "$KEY" "$HOST" "mkdir -p ~/Nomva/Resources"
  scp -i "$KEY" "$CANONICAL_DB" "$HOST:~/Nomva/Resources/foods.sqlite"
fi

echo "→ Uploading ${#FILES[@]} files to $HOST:~/$REMOTE_DIR/"
scp -i "$KEY" "${FILES[@]}" "$HOST:~/$REMOTE_DIR/"

# ── Remote DB gate: refuse to restart onto a stale or missing food database ──
echo "→ Verifying the food database on the server"
ssh -i "$KEY" "$HOST" "cd ~/$REMOTE_DIR && node -e '
  const { createFoodSearchStore } = require(\"./foodSearchStore\");
  const store = createFoodSearchStore({});
  if (!store.isAvailable) {
    console.error(\"REMOTE FOOD DB CHECK FAILED: \" + store.error);
    console.error(\"Run ./deploy.sh --with-db to upload the current database.\");
    process.exit(1);
  }
  console.log(\"remote food db ok: \" + store.dbPath + \" (\" + store.rowCount + \" rows)\");
  store.close();
'" || exit 1

echo "→ Installing any new npm deps + restarting pm2"
ssh -i "$KEY" "$HOST" "cd ~/$REMOTE_DIR && npm install --omit=dev --no-audit --no-fund && pm2 restart nomva-api && pm2 logs nomva-api --lines 40 --nostream"

echo "→ Post-deploy health check"
sleep 2
HEALTH=$(curl -sS -m 10 https://nomva.nerdquad.com/health)
echo "  $HEALTH"
echo "$HEALTH" | grep -q '"available":true' || { echo "✗ /health reports the food DB unavailable — investigate before considering this deploy done"; exit 1; }

echo "✓ Deploy complete"
