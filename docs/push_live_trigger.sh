#!/bin/bash
#
# push_live_trigger.sh
#
# Runs the full 3-step Data Cloud Ingestion API sequence in one command:
#   1. Get a core Salesforce access token (Client Credentials Flow)
#   2. Exchange it for a Data Cloud (CDP) access token
#   3. Push a live news trigger record via the Ingestion API
#
# No manual copy-pasting of tokens between steps — everything is chained
# automatically. Designed to run cleanly on macOS Terminal (zsh or bash).
#
# ── ONE-TIME SETUP ───────────────────────────────────────────────────────
# Fill in the four values below, OR export them as environment variables
# before running this script (recommended — keeps secrets out of this file
# if you ever commit it anywhere):
#
#   export SF_ORG_DOMAIN="orgfarm-64bdbfd8ec-dev-ed.develop"
#   export SF_CONSUMER_KEY="your_consumer_key"
#   export SF_CONSUMER_SECRET="your_consumer_secret"
#   export SF_CDP_TENANT_DOMAIN="g0zt9mdfmrtdq9jvgy3t0njsgq.c360a.salesforce.com"
#
# ── USAGE ────────────────────────────────────────────────────────────────
#   ./push_live_trigger.sh
#       → pushes the built-in demo default (Edge Communications, funding)
#
#   ./push_live_trigger.sh <account_id> <headline> <trigger_type>
#       → pushes a custom record with today's timestamp, e.g.:
#         ./push_live_trigger.sh 001gK00001FjoEBQAZ \
#           "GenePoint signs new hospital partnership" partnership
#
#   ./push_live_trigger.sh <account_id> <headline> <trigger_type> <source> <timestamp>
#       → full control over every payload field, e.g.:
#         ./push_live_trigger.sh 001gK00001FjoE5QAJ \
#           "Grand Hotels announces three new properties" expansion \
#           "press_release_feed" "2026-08-10T09:00:00Z"
#
# ──────────────────────────────────────────────────────────────────────────

set -e  # stop immediately if any step fails

# ---- Config: env vars take priority, fall back to placeholders below ----
ORG_DOMAIN="${SF_ORG_DOMAIN:-YOUR_ORG_DOMAIN_HERE}"
CONSUMER_KEY="${SF_CONSUMER_KEY:-YOUR_CONSUMER_KEY_HERE}"
CONSUMER_SECRET="${SF_CONSUMER_SECRET:-YOUR_CONSUMER_SECRET_HERE}"
CDP_TENANT_DOMAIN="${SF_CDP_TENANT_DOMAIN:-YOUR_CDP_TENANT_DOMAIN_HERE}"
CONNECTOR_NAME="Live_News_Trigger_Ingestion"
OBJECT_NAME="Live_News_Trigger"

# ---- Payload fields — all 5 are optional positional arguments ----
# $1 = account_id           (default: Edge Communications)
# $2 = headline             (default: funding announcement)
# $3 = trigger_type         (default: funding)
# $4 = source               (default: simulated_news_monitor)
# $5 = published_timestamp  (default: right now, UTC)
ACCOUNT_ID="${1:-001gK00001FjoE1QAJ}"
HEADLINE="${2:-Edge Communications announces new funding round}"
TRIGGER_TYPE="${3:-funding}"
SOURCE="${4:-simulated_news_monitor}"
PUBLISHED_TIMESTAMP="${5:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

# ---- Safety check: fail loudly if placeholders were never filled in ----
if [[ "$ORG_DOMAIN" == "YOUR_ORG_DOMAIN_HERE" || "$CONSUMER_KEY" == "YOUR_CONSUMER_KEY_HERE" ]]; then
  echo "❌ Config not set. Either edit the placeholders at the top of this"
  echo "   script, or export SF_ORG_DOMAIN / SF_CONSUMER_KEY /"
  echo "   SF_CONSUMER_SECRET / SF_CDP_TENANT_DOMAIN before running it."
  exit 1
fi

echo "── Step 1: Requesting core access token ──────────────────────────"
CORE_RESPONSE=$(curl -s "https://${ORG_DOMAIN}.my.salesforce.com/services/oauth2/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=${CONSUMER_KEY}" \
  -d "client_secret=${CONSUMER_SECRET}")

CORE_TOKEN=$(echo "$CORE_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")

if [[ -z "$CORE_TOKEN" ]]; then
  echo "❌ Failed to get core access token. Response was:"
  echo "$CORE_RESPONSE"
  exit 1
fi
echo "✅ Core token acquired."

echo ""
echo "── Step 2: Exchanging for a Data Cloud (CDP) token ────────────────"
CDP_RESPONSE=$(curl -s "https://${ORG_DOMAIN}.my.salesforce.com/services/a360/token" \
  --data-urlencode "grant_type=urn:salesforce:grant-type:external:cdp" \
  --data-urlencode "subject_token=${CORE_TOKEN}" \
  --data-urlencode "subject_token_type=urn:ietf:params:oauth:token-type:access_token")

CDP_TOKEN=$(echo "$CDP_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")

if [[ -z "$CDP_TOKEN" ]]; then
  echo "❌ Failed to get CDP access token. Response was:"
  echo "$CDP_RESPONSE"
  echo ""
  echo "   Common cause: the core token's OAuth scopes are missing the plain"
  echo "   'api' scope (Manage user data via APIs) — cdp_ingest_api and"
  echo "   sfap_api alone are not sufficient for this exchange step."
  exit 1
fi
echo "✅ CDP token acquired."

echo ""
echo "── Step 3: Pushing the live news trigger record ───────────────────"
echo "   Account:    ${ACCOUNT_ID}"
echo "   Headline:   ${HEADLINE}"
echo "   Type:       ${TRIGGER_TYPE}"
echo "   Timestamp:  ${PUBLISHED_TIMESTAMP}"

PUSH_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
  "https://${CDP_TENANT_DOMAIN}/api/v1/ingest/sources/${CONNECTOR_NAME}/${OBJECT_NAME}" \
  -H "Authorization: Bearer ${CDP_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"data\": [{\"account_id\": \"${ACCOUNT_ID}\", \"headline\": \"${HEADLINE}\", \"trigger_type\": \"${TRIGGER_TYPE}\", \"published_timestamp\": \"${PUBLISHED_TIMESTAMP}\", \"source\": \"${SOURCE}\"}]}")

HTTP_STATUS=$(echo "$PUSH_RESPONSE" | grep "HTTP_STATUS" | cut -d: -f2)
BODY=$(echo "$PUSH_RESPONSE" | sed '/HTTP_STATUS/d')

if [[ "$HTTP_STATUS" == "202" ]]; then
  echo "✅ Push accepted (HTTP 202): $BODY"
  echo ""
  echo "Data typically lands in Data Cloud within ~1-2 minutes."
  echo "You can now ask the agent: \"Research <account name> for me\""
else
  echo "❌ Push failed (HTTP $HTTP_STATUS): $BODY"
  exit 1
fi
