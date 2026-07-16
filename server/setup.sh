#!/bin/bash
# Run this on your Lightsail instance after SSH-ing in.
# Usage: bash setup.sh

set -e

echo "=== Nomva API Server Setup ==="

# 1. Install Node.js 20
echo "Installing Node.js..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# 2. Install PM2 (keeps the server alive + auto-restarts)
echo "Installing PM2..."
sudo npm install -g pm2

# 3. Clone or copy the server directory to ~/nomva-api
# (You'll scp the files over — see below)
mkdir -p ~/nomva-api

echo ""
echo "=== Next steps ==="
echo ""
echo "1. From your local machine, copy the server files:"
echo "   scp -r server/* ubuntu@<YOUR_LIGHTSAIL_IP>:~/nomva-api/"
echo ""
echo "2. SSH back in and set up your .env:"
echo "   cd ~/nomva-api"
echo "   cp .env.example .env"
echo "   nano .env   # paste your OpenAI key, STATE_ENCRYPTION_KEY, ANALYTICS_ADMIN_TOKEN, App Attest settings, and Garmin OAuth 1.0a settings from .env.example"
echo ""
echo "3. Install dependencies and start:"
echo "   cd ~/nomva-api && npm install"
echo "   pm2 start index.js --name nomva-api"
echo "   pm2 save"
echo "   pm2 startup   # follow the printed command to enable on boot"
echo ""
echo "4. Set up HTTPS with Let's Encrypt + nginx:"
echo "   sudo apt install -y nginx certbot python3-certbot-nginx"
echo "   # Create nginx config:"
echo "   sudo tee /etc/nginx/sites-available/nomva <<'EOF'"
echo "server {"
echo "    server_name nomva.nerdquad.com;"
echo "    location / {"
echo "        proxy_pass http://127.0.0.1:3000;"
echo "        proxy_set_header Host \$host;"
echo "        proxy_set_header X-Real-IP \$remote_addr;"
echo "    }"
echo "}"
echo "EOF"
echo "   sudo ln -sf /etc/nginx/sites-available/nomva /etc/nginx/sites-enabled/"
echo "   sudo nginx -t && sudo systemctl reload nginx"
echo "   sudo certbot --nginx -d nomva.nerdquad.com"
echo ""
echo "5. In Route 53: create an A record for nomva.nerdquad.com → your Lightsail static IP"
echo ""
echo "6. Open port 443 (HTTPS) in Lightsail Networking tab"
echo ""
echo "7. Test: curl https://nomva.nerdquad.com/health"
echo "   Should return: {\"status\":\"ok\"}"
echo ""
echo "8. Check analytics once traffic exists:"
echo "   ADMIN_TOKEN=\$(grep '^ANALYTICS_ADMIN_TOKEN=' ~/nomva-api/.env | cut -d= -f2-)"
echo "   curl -s -H \"Authorization: Bearer \$ADMIN_TOKEN\" \"https://nomva.nerdquad.com/analytics/summary?hours=24\""
echo ""
echo "9. Capture the current LLM baseline before major prompt/flow changes:"
echo "   cd ~/nomva-api && npm run baseline:llm"
