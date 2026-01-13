#!/usr/bin/env bash
#
# Local resilience test runner
# Usage: ./test-resilience-local.sh [setup|test|status|all]
#
# PREREQUISITES:
# 1. Start k8s-hosts-controller manually BEFORE running this script:
#    cd ../apps/k8s-hosts-controller
#    sudo ./k8s-hosts-controller --all-namespaces > /tmp/k8s-hosts-controller.log 2>&1 &
#
# 2. Verify /etc/hosts entries are synced:
#    grep TYK-K8S-HOSTS /etc/hosts
#
# The controller needs to run with sudo to modify /etc/hosts on macOS.
# This script will NOT manage the controller process.
#

set -euo pipefail
cd "$(dirname "$0")"
source lib.sh

TYK_ANALYTICS_PATH="${TYK_ANALYTICS_PATH:-/Users/buraksekili/projects/w1/tyk-analytics}"
TYK_PRO_ROOT="$(cd ../.. && pwd)"

setup() {
  log "=== Setting up resilience test environment ==="

  if [ ! -f .env ]; then
    err "Missing .env file with TYK_DB_LICENSEKEY and TYK_MDCB_LICENSEKEY"
    exit 1
  fi

  if ! kind get clusters | grep -q "^kind$"; then
    log "Creating Kind cluster..."
    ./create-cluster.sh
  else
    log "Kind cluster already exists"
  fi

  log "Deploying Tyk stack with Toxiproxy..."
  # Deploy without starting k8s-hosts-controller (user must run it manually)
  NO_HOSTS_CONTROLLER=true ./run-tyk-cp-dp.sh toxiproxy=true

  log "Checking for /etc/hosts entries..."
  if ! grep -q "TYK-K8S-HOSTS" /etc/hosts; then
    err "No TYK-K8S-HOSTS entries found in /etc/hosts"
    err ""
    err "Please ensure k8s-hosts-controller is running with:"
    err "  cd $TYK_PRO_ROOT/k8s/apps/k8s-hosts-controller"
    err "  sudo ./k8s-hosts-controller --all-namespaces"
    err ""
    err "Then wait for entries to appear and re-run this script"
    exit 1
  fi

  log "✓ Hosts entries found in /etc/hosts"
  log ""
  log "Expected hosts entries:"
  kubectl get ingress -A -o custom-columns='HOST:.spec.rules[*].host' --no-headers | grep -v '<none>'
}

test_resilience() {
  log "=== Running resilience tests ==="

  if ! grep -q "TYK-K8S-HOSTS" /etc/hosts; then
    err "No TYK-K8S-HOSTS entries in /etc/hosts!"
    err "Please start k8s-hosts-controller manually (see script header)"
    exit 1
  fi

  found=false
  if [ -f toxiproxy-ci.env ]; then
    source toxiproxy-ci.env
    log "Loaded toxiproxy-ci.env"
    found=true
  elif [ -f toxiproxy.env ]; then
    found=true
    source toxiproxy.env
    log "Loaded toxiproxy.env"
  fi

  if [ "$found" = "false" ]; then
    err "toxiproxy env not found"
    exit 1
  fi

  if [ -z "${TOXIPROXY_URL:-}" ]; then
    local toxiproxy_ip
    toxiproxy_ip=$(kubectl get svc toxiproxy -n tyk -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2> /dev/null || true)
    if [ -n "$toxiproxy_ip" ]; then
      export TOXIPROXY_URL="http://${toxiproxy_ip}:8474"
    else
      err "Cannot determine Toxiproxy URL - LoadBalancer IP not assigned"
      exit 1
    fi
  fi

  export TYK_TEST_BASE_URL="http://chart-dash.test/"
  export TYK_TEST_GW_URL="http://chart-gw.test/"
  export TYK_TEST_GW_1_ALFA_URL="http://chart-gw-dp-1.test/"
  export TYK_TEST_GW_2_ALFA_URL="http://chart-gw-dp-2.test/"
  export TYK_TEST_GW_1_BETA_URL="http://chart-gw-dp-1.test/"
  export TYK_TEST_GW_2_BETA_URL="http://chart-gw-dp-2.test/"
  export TYK_TEST_GW_SECRET="352d20ee67be67f6340b4c0605b044b7"
  export USER_API_SECRET=$(kubectl get secret -n tyk tyk-operator-conf -o jsonpath="{.data.TYK_AUTH}" | base64 -d)

  log "TOXIPROXY_URL: $TOXIPROXY_URL"
  log "TYK_TEST_BASE_URL: $TYK_TEST_BASE_URL"

  if ! curl -s --connect-timeout 5 "$TOXIPROXY_URL/proxies" > /dev/null; then
    err "Cannot reach toxiproxy at $TOXIPROXY_URL"
    err "Ensure Toxiproxy LoadBalancer is ready and cloud-provider-kind is running"
    exit 1
  fi

  log "Configured proxies:"
  curl -s "$TOXIPROXY_URL/proxies" | jq -r 'keys[]'

  cd "$TYK_ANALYTICS_PATH/tests/api"
  pip install -q -r requirements.txt
  pytest -s -m resilience --tb=short
}

status() {
  log "=== Status ==="
  echo
  log "Cluster:"
  kubectl cluster-info 2> /dev/null || echo "  Not running"
  echo
  log "Pods in tyk namespace:"
  kubectl get pods -n tyk 2> /dev/null || echo "  None"
  echo
  log "Ingress resources:"
  kubectl get ingress -A 2> /dev/null || echo "  None"
  echo
  log "k8s-hosts-controller:"
  if pgrep -f "k8s-hosts-controller --all-namespaces" > /dev/null; then
    local pid
    pid=$(pgrep -f "k8s-hosts-controller --all-namespaces")
    echo "  Running (PID: $pid)"
  else
    echo "  Not running - please start it manually (see script header)"
  fi
  echo
  log "/etc/hosts entries:"
  if grep -q "TYK-K8S-HOSTS" /etc/hosts 2> /dev/null; then
    grep -A 100 "BEGIN TYK-K8S-HOSTS" /etc/hosts 2> /dev/null | grep -B 100 "END TYK-K8S-HOSTS"
  else
    echo "  No TYK-K8S-HOSTS entries found"
  fi
  echo
  log "Toxiproxy proxies:"
  local toxiproxy_ip
  toxiproxy_ip=$(kubectl get svc toxiproxy -n tyk -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2> /dev/null || true)
  if [ -n "$toxiproxy_ip" ]; then
    curl -s "http://${toxiproxy_ip}:8474/proxies" 2> /dev/null | jq -r 'to_entries[] | "\(.key): \(.value.listen) -> \(.value.upstream)"' || echo "  Not accessible"
  else
    echo "  Toxiproxy LoadBalancer IP not available"
  fi
}

test_resilience
