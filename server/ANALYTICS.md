# Nomva Analytics and LLM Baseline

This server records privacy-safe operational analytics for production debugging and LLM quality tracking.

## What Is Recorded

- Server request route, method, status, latency, request/response byte counts, auth mode, and safe request shape counts.
- iOS-observed network route, method, status, latency, byte counts, and URLSession error codes.
- LLM task name, model, latency, prompt/response character counts, token count, success state, and error code.
- User and session identifiers are one-way hashed before storage.

Raw chat text, food names from real users, images, barcodes, and meal details are not stored in analytics.

## Environment

```bash
ANALYTICS_ENABLED=1
ANALYTICS_RETENTION_DAYS=90
ANALYTICS_ADMIN_TOKEN=replace-with-a-long-random-admin-token
ANALYTICS_HASH_SALT=
ANALYTICS_DB_PATH=
```

If `ANALYTICS_HASH_SALT` is blank, the server reuses `STATE_ENCRYPTION_KEY` for analytics hashes. The default database path is `./data/nomva-analytics.sqlite`.

## Summary Endpoint

```bash
ADMIN_TOKEN=$(grep '^ANALYTICS_ADMIN_TOKEN=' ~/nomva-api/.env | cut -d= -f2-)
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  "https://nomva.nerdquad.com/analytics/summary?hours=24"
```

The endpoint returns totals, combined route latency stats, separate server/client route latency stats, LLM latency stats, and status-code counts.

## LLM Baseline

Run this before major LLM behavior changes:

```bash
cd ~/nomva-api
npm run baseline:llm
```

Reports are written to:

```text
baseline/reports/latest.json
baseline/reports/llm-baseline-<timestamp>.json
```

Set `BASELINE_MIN_SCORE=0.85` if you want CI or deploy scripts to fail below a required score.
