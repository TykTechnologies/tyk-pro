#!/usr/bin/env bash
#
# Compare local setup with CI configuration
#

set -euo pipefail
cd "$(dirname "$0")"
source lib.sh

log "=== CI vs Local Setup Comparison ==="
echo

# 1. Check branch
log "1. Branch Comparison"
echo "---"
CURRENT_BRANCH=$(git branch --show-current)
CI_BRANCH="feat/TT-16222/toxiproxy-config"
log "Local branch: $CURRENT_BRANCH"
log "CI branch:    $CI_BRANCH"

if [ "$CURRENT_BRANCH" != "$CI_BRANCH" ]; then
    err "⚠️  Branch mismatch! You're on $CURRENT_BRANCH, CI uses $CI_BRANCH"
    log "To switch: git checkout $CI_BRANCH"
else
    log "✓ Branch matches CI"
fi
echo

# 2. Check environment variables
log "2. Environment Variables"
echo "---"

if [ -f toxiproxy-ci.env ]; then
    source toxiproxy-ci.env
    log "✓ toxiproxy-ci.env loaded"

    # Expected vars
    EXPECTED_VARS=(
        "TOXIPROXY_URL"
        "TYK_TEST_BASE_URL"
        "TYK_TEST_GW_URL"
        "TYK_TEST_GW_1_ALFA_URL"
        "TYK_TEST_GW_2_ALFA_URL"
        "TYK_TEST_GW_SECRET"
    )

    for var in "${EXPECTED_VARS[@]}"; do
        if [ -n "${!var:-}" ]; then
            log "✓ $var=${!var}"
        else
            err "✗ $var not set"
        fi
    done
else
    err "✗ toxiproxy-ci.env not found"
fi
echo

# 3. Check gateway pods configuration
log "3. Data Plane Gateway Configuration"
echo "---"

POD=$(kubectl get pods -n tyk-dp-2 -l app=gateway-tyk-data-plane-tyk-gateway -o jsonpath='{.items[0].metadata.name}')
if [ -n "$POD" ]; then
    log "Pod: $POD"

    # Check critical env vars
    log "Checking critical environment variables:"

    CACHE_DISABLED=$(kubectl get pod -n tyk-dp-2 "$POD" -o jsonpath='{.spec.containers[0].env[?(@.name=="TYK_GW_LOCALSESSIONCACHE_DISABLECACHESESSIONSTATE")].value}')
    if [ "$CACHE_DISABLED" = "true" ]; then
        log "✓ Session cache disabled: TYK_GW_LOCALSESSIONCACHE_DISABLECACHESESSIONSTATE=true"
    else
        err "✗ Session cache NOT disabled (value: ${CACHE_DISABLED:-not set})"
        err "   This will cause test failures due to caching"
    fi

    GLOBAL_SESSION=$(kubectl get pod -n tyk-dp-2 "$POD" -o jsonpath='{.spec.containers[0].env[?(@.name=="TYK_GW_GLOBALSESSIONLIFETIME")].value}')
    log "  Global session lifetime: ${GLOBAL_SESSION:-not set}"

    # Check image
    IMAGE=$(kubectl get pod -n tyk-dp-2 "$POD" -o jsonpath='{.spec.containers[0].image}')
    log "  Gateway image: $IMAGE"
else
    err "✗ No data plane gateway pods found"
fi
echo

# 4. Check /etc/hosts
log "4. Hosts Configuration"
echo "---"

if grep -q "TYK-K8S-HOSTS" /etc/hosts 2>/dev/null; then
    log "✓ /etc/hosts has TYK-K8S-HOSTS entries (k8s-hosts-controller)"
    HOSTS_COUNT=$(grep "TYK-K8S-HOSTS" /etc/hosts | wc -l)
    log "  Found $HOSTS_COUNT entries"
elif grep -q "chart-dash.test" /etc/hosts 2>/dev/null; then
    log "✓ /etc/hosts has chart-dash.test entry"
else
    err "✗ No Tyk hosts found in /etc/hosts"
    err "  CI uses: python toxiproxy-agent/cli.py configure --output-hosts"
fi
echo

# 5. Check Toxiproxy connectivity
log "5. Toxiproxy Connectivity"
echo "---"

if [ -n "${TOXIPROXY_URL:-}" ]; then
    if curl -s --connect-timeout 5 "$TOXIPROXY_URL/proxies" > /dev/null; then
        log "✓ Toxiproxy accessible at $TOXIPROXY_URL"

        # Check proxies
        PROXY_COUNT=$(curl -s "$TOXIPROXY_URL/proxies" | jq 'length')
        log "  Found $PROXY_COUNT proxies"

        # Check redis-dp-2 specifically
        REDIS_DP2_ENABLED=$(curl -s "$TOXIPROXY_URL/proxies/redis-dp-2" | jq -r '.enabled')
        if [ "$REDIS_DP2_ENABLED" = "true" ]; then
            log "  ✓ redis-dp-2 proxy enabled"
        elif [ "$REDIS_DP2_ENABLED" = "false" ]; then
            err "  ⚠️  redis-dp-2 proxy DISABLED (should be enabled for initial tests)"
        else
            err "  ✗ redis-dp-2 proxy not found"
        fi
    else
        err "✗ Cannot reach Toxiproxy at $TOXIPROXY_URL"
    fi
else
    err "✗ TOXIPROXY_URL not set"
fi
echo

# 6. Check helm chart versions
log "6. Helm Chart Versions"
echo "---"

CONTROL_PLANE_CHART=$(helm list -n tyk -o json | jq -r '.[] | select(.name == "tyk-control-plane") | .chart')
log "Control Plane: $CONTROL_PLANE_CHART"

for i in 1 2; do
    DP_CHART=$(helm list -n tyk-dp-$i -o json | jq -r '.[] | select(.name == "tyk-data-plane") | .chart')
    log "Data Plane $i:  $DP_CHART"
done
echo

# 7. Summary
log "=== Summary ==="
echo

ISSUES=0

if [ "$CURRENT_BRANCH" != "$CI_BRANCH" ]; then
    err "1. Branch mismatch - switch to $CI_BRANCH"
    ((ISSUES++))
fi

if [ "$CACHE_DISABLED" != "true" ]; then
    err "2. Session cache not disabled - this will cause test failures"
    ((ISSUES++))
fi

if [ -z "${TOXIPROXY_URL:-}" ]; then
    err "3. TOXIPROXY_URL not set"
    ((ISSUES++))
fi

if [ $ISSUES -eq 0 ]; then
    log "✓ No configuration issues found"
    log "Your setup matches CI configuration"
else
    err "Found $ISSUES configuration issue(s)"
    err "Fix these before running resilience tests"
    exit 1
fi
