#!/usr/bin/env bash
#
# Diagnostic script for Redis down resilience test issue
# Compares local vs CI configuration and behavior
#

set -euo pipefail
cd "$(dirname "$0")"
source lib.sh

log "=== Redis Down Resilience Test Diagnostic ==="
echo

# Load environment
if [ -f toxiproxy-ci.env ]; then
    source toxiproxy-ci.env
    log "✓ Loaded toxiproxy-ci.env"
else
    err "✗ toxiproxy-ci.env not found"
    exit 1
fi

# 1. Check gateway configuration
log "1. Checking Data Plane 2 Gateway Configuration"
echo "---"
POD=$(kubectl get pods -n tyk-dp-2 -l app=gateway-tyk-data-plane-tyk-gateway -o jsonpath='{.items[0].metadata.name}')
log "Pod: $POD"
echo

log "Environment variables (cache/session related):"
kubectl get pod -n tyk-dp-2 "$POD" -o json | jq -r '.spec.containers[0].env[] | select(.name | contains("CACHE") or contains("SESSION") or contains("QUOTA")) | "\(.name)=\(.value // .valueFrom)"'
echo

# 2. Check Dashboard API connectivity
log "2. Checking Dashboard API Access"
echo "---"
USER_API_KEY=$(kubectl get secret -n tyk tyk-operator-conf -o jsonpath="{.data.TYK_AUTH}" | base64 -d)
log "User API Key: ${USER_API_KEY:0:8}..."

# Test Dashboard API
DASH_RESPONSE=$(curl -s -w "\n%{http_code}" "http://chart-dash.test/admin/apis" \
    -H "Authorization: $USER_API_KEY" | tail -1)

if [ "$DASH_RESPONSE" = "200" ]; then
    log "✓ Dashboard API accessible"
else
    err "✗ Dashboard API returned: $DASH_RESPONSE"
fi
echo

# 3. Check Toxiproxy status
log "3. Checking Toxiproxy Configuration"
echo "---"
log "Toxiproxy URL: $TOXIPROXY_URL"

if curl -s --connect-timeout 5 "$TOXIPROXY_URL/proxies" > /dev/null; then
    log "✓ Toxiproxy accessible"

    log "Redis proxies status:"
    curl -s "$TOXIPROXY_URL/proxies" | jq -r 'to_entries[] | select(.key | contains("redis")) | "\(.key): enabled=\(.value.enabled), \(.value.listen) -> \(.value.upstream)"'
else
    err "✗ Cannot reach Toxiproxy"
fi
echo

# 4. Create a test token and check its quota configuration
log "4. Creating Test Token and Checking Quota Configuration"
echo "---"

# First, create a simple API
API_DEF=$(cat <<'EOF'
{
  "api_definition": {
    "name": "diagnostic-api",
    "slug": "diagnostic-api",
    "api_id": "diagnostic-api",
    "org_id": "$(kubectl get secret -n tyk tyk-operator-conf -o jsonpath="{.data.TYK_ORG}" | base64 -d)",
    "use_keyless": false,
    "use_standard_auth": true,
    "auth": {
      "auth_header_name": "Authorization"
    },
    "version_data": {
      "not_versioned": true,
      "versions": {
        "Default": {
          "name": "Default"
        }
      }
    },
    "proxy": {
      "listen_path": "/diagnostic-api/",
      "target_url": "http://httpbin.tools.svc.cluster.local:8080/",
      "strip_listen_path": true
    }
  }
}
EOF
)

ORG_ID=$(kubectl get secret -n tyk tyk-operator-conf -o jsonpath="{.data.TYK_ORG}" | base64 -d)
API_DEF=$(echo "$API_DEF" | sed "s/\$(kubectl get secret -n tyk tyk-operator-conf -o jsonpath=\"{.data.TYK_ORG}\" | base64 -d)/$ORG_ID/")

API_RESPONSE=$(curl -s "http://chart-dash.test/api/apis" \
    -H "Authorization: $USER_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$API_DEF")

if echo "$API_RESPONSE" | jq -e '.Status == "OK"' > /dev/null 2>&1; then
    log "✓ API created successfully"
    API_ID="diagnostic-api"
else
    err "✗ Failed to create API"
    echo "$API_RESPONSE" | jq '.'
fi
echo

# Create a token with explicit quota
TOKEN_DATA=$(cat <<EOF
{
  "last_check": 0,
  "allowance": 1000,
  "rate": 1000,
  "per": 60,
  "expires": 1783705602,
  "quota_max": 10000,
  "quota_renews": 1551910751,
  "quota_remaining": 10000,
  "quota_renewal_rate": 2520000,
  "access_rights": {
    "diagnostic-api": {
      "api_id": "diagnostic-api",
      "api_name": "diagnostic-api",
      "versions": ["Default"]
    }
  }
}
EOF
)

TOKEN_RESPONSE=$(curl -s "http://chart-dash.test/api/keys" \
    -H "Authorization: $USER_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$TOKEN_DATA")

if echo "$TOKEN_RESPONSE" | jq -e '.key_id' > /dev/null 2>&1; then
    TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.key_id')
    log "✓ Token created: ${TOKEN:0:20}..."

    log "Token quota configuration:"
    echo "$TOKEN_DATA" | jq '{quota_max, quota_remaining, quota_renewal_rate}'
else
    err "✗ Failed to create token"
    echo "$TOKEN_RESPONSE" | jq '.'
fi
echo

# Wait for MDCB to sync
log "Waiting 10s for MDCB to sync..."
sleep 10

# 5. Test with Redis UP
log "5. Testing API Request with Redis UP"
echo "---"
curl -s "$TOXIPROXY_URL/proxies/redis-dp-2" -X POST \
    -H "Content-Type: application/json" \
    -d '{"enabled": true}' > /dev/null

sleep 2
log "Redis DP-2 enabled"

RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" "http://chart-gw-dp-2.test/diagnostic-api/get" \
    -H "Authorization: $TOKEN")

HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE" | cut -d: -f2)
log "Response code: $HTTP_CODE"

if [ "$HTTP_CODE" = "200" ]; then
    log "✓ Request successful with Redis UP"
else
    err "✗ Request failed with Redis UP"
fi
echo

# Check gateway logs for quota messages
log "Gateway logs (last 5 quota-related lines):"
kubectl logs -n tyk-dp-2 "$POD" --tail=50 | grep -i "\[QUOTA\]\|quota" | tail -5
echo

# 6. Test with Redis DOWN
log "6. Testing API Request with Redis DOWN"
echo "---"
curl -s "$TOXIPROXY_URL/proxies/redis-dp-2" -X POST \
    -H "Content-Type: application/json" \
    -d '{"enabled": false}' > /dev/null

sleep 2
log "Redis DP-2 disabled"

RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" "http://chart-gw-dp-2.test/diagnostic-api/get" \
    -H "Authorization: $TOKEN")

HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE" | cut -d: -f2)
log "Response code: $HTTP_CODE"

if [ "$HTTP_CODE" = "403" ]; then
    log "✓ Request BLOCKED with Redis DOWN (expected)"
elif [ "$HTTP_CODE" = "200" ]; then
    err "✗ Request ALLOWED with Redis DOWN (unexpected - THIS IS THE BUG)"
else
    err "✗ Unexpected response code: $HTTP_CODE"
fi
echo

# Check gateway logs
log "Gateway logs after Redis down (last 20 lines):"
kubectl logs -n tyk-dp-2 "$POD" --tail=20
echo

# 7. Re-enable Redis
log "7. Re-enabling Redis"
curl -s "$TOXIPROXY_URL/proxies/redis-dp-2" -X POST \
    -H "Content-Type: application/json" \
    -d '{"enabled": true}' > /dev/null
log "✓ Redis re-enabled"
echo

# 8. Cleanup
log "8. Cleaning up test resources"
curl -s "http://chart-dash.test/api/apis/diagnostic-api" \
    -H "Authorization: $USER_API_KEY" \
    -X DELETE > /dev/null
curl -s "http://chart-dash.test/api/keys/$TOKEN" \
    -H "Authorization: $USER_API_KEY" \
    -X DELETE > /dev/null
log "✓ Cleanup complete"
echo

log "=== Diagnostic Complete ==="
log ""
log "Summary:"
log "- If HTTP code was 200 when Redis is DOWN, the bug is confirmed"
log "- Check gateway logs above for quota-related errors"
log "- Compare with CI logs to see if CI has different behavior"
