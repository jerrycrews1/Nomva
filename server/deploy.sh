#!/usr/bin/env bash
# Upload all server source files to Lightsail and restart pm2.
# Usage: ./deploy.sh
set -euo pipefail

KEY="$HOME/Downloads/Config & Keys/LightsailDefaultKey-us-east-1.pem"
HOST="ubuntu@nomva.nerdquad.com"
REMOTE_DIR="nomva-api"   # relative to ubuntu's home

cd "$(dirname "$0")"

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
  package.json
  package-lock.json
)

echo "→ Uploading ${#FILES[@]} files to $HOST:~/$REMOTE_DIR/"
scp -i "$KEY" "${FILES[@]}" "$HOST:~/$REMOTE_DIR/"

echo "→ Installing any new npm deps + restarting pm2"
ssh -i "$KEY" "$HOST" "cd ~/$REMOTE_DIR && npm install --omit=dev --no-audit --no-fund && pm2 restart nomva-api && pm2 logs nomva-api --lines 40 --nostream"

echo "✓ Deploy complete"
