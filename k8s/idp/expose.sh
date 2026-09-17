#!/usr/bin/env bash

# Port-forwards a service inside a tenant namespace to localhost, so a Tyk
# gateway running on this machine can reach the stack deployed in the cluster.
#
# A local gateway needs three connections, and two of them are outbound from
# the gateway, which is what this script covers:
#
#   gateway -> dashboard   HTTP, config polling and node registration
#   gateway -> redis       reload signals, published on tyk.cluster.notifications
#
# The third, dashboard -> gateway for key and certificate management, is
# inbound to your machine and needs tyk_api_config on the dashboard instead.
# See the readme.
#
# Usage:
#   ./expose.sh analytics [instance]   dashboard on localhost:3000
#   ./expose.sh redis [instance]       redis on localhost:6379
#
# Environment:
#   LOCAL_PORT  listen on a different local port
#
# Runs in the foreground. Stop it with ctrl-c.

set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"
source "${SCRIPT_DIR}/../tyk-stack-ingress/lib.sh"

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-tyk-idp}"
KUBE_CONTEXT="kind-${KIND_CLUSTER_NAME}"

kc() {
  kubectl --context "$KUBE_CONTEXT" "$@"
}

usage() {
  error "usage: $0 [analytics|redis] [instance]"
  error "  analytics  the Tyk dashboard, on localhost:3000"
  error "  redis      the reload channel, on localhost:6379"
  exit 1
}

######################################
# target
######################################
# Matched on the chart's own naming rather than a fixed name: the dashboard
# service is dashboard-svc-<release>-tyk-dashboard, and the release name
# carries the instance and a hash, so only the suffix is stable.
# grep exits non-zero when nothing matches, and under set -e that ends the
# script before the caller can report which services the namespace does hold.
serviceFor() {
  local target="$1" namespace="$2"

  case "$target" in
    analytics)
      kc -n "$namespace" get svc -o name \
        | sed 's|service/||' | grep -- '-tyk-dashboard$' | head -1 || true
      ;;
    redis)
      # redis-headless carries the same ports; the plain service is the one
      # the charts point their clients at.
      kc -n "$namespace" get svc -o name \
        | sed 's|service/||' | grep -x 'redis' | head -1 || true
      ;;
  esac
}

remotePortFor() {
  case "$1" in
    analytics) echo 3000 ;;
    redis) echo 6379 ;;
  esac
}

# What to put in the gateway's own config once the forward is up.
hintFor() {
  local target="$1" port="$2"

  case "$target" in
    analytics)
      log "point your local gateway at it with:"
      log "  db_app_conf_options.connection_string = http://localhost:${port}"
      log "  policies.policy_connection_string     = http://localhost:${port}"
      ;;
    redis)
      log "point your local gateway at it with:"
      log "  storage.host = localhost"
      log "  storage.port = ${port}"
      ;;
  esac
}

######################################
# instance
######################################
resolveNamespace() {
  local instance="$1"

  if [ -z "$instance" ]; then
    local instances=()
    while IFS= read -r line; do instances+=("$line"); done \
      < <(kc get tykdeploymentinstance -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

    case ${#instances[@]} in
      0)
        error "no TykDeploymentInstance in the cluster"
        error "deploy one first: task -d k8s/idp install"
        exit 1
        ;;
      1) instance="${instances[0]}" ;;
      *)
        error "more than one instance; name the one you want"
        error "  $0 $TARGET <instance>"
        error "the cluster holds: ${instances[*]}"
        exit 1
        ;;
    esac
  fi

  if ! kc get tykdeploymentinstance "$instance" > /dev/null 2>&1; then
    error "no TykDeploymentInstance named '$instance'"
    exit 1
  fi

  INSTANCE="$instance"
  NAMESPACE="$(kc get tykdeploymentinstance "$instance" -o jsonpath='{.status.tenantNamespace}')"

  if [ -z "$NAMESPACE" ]; then
    error "instance '$instance' has no tenant namespace yet"
    exit 1
  fi
}

######################################
# entrypoint
######################################
TARGET="${1-}"
case "$TARGET" in
  analytics | redis) ;;
  *) usage ;;
esac

resolveNamespace "${2-}"

SERVICE="$(serviceFor "$TARGET" "$NAMESPACE")"
if [ -z "$SERVICE" ]; then
  error "no $TARGET service in $NAMESPACE"
  error "the namespace holds: $(kc -n "$NAMESPACE" get svc -o name | sed 's|service/||' | tr '\n' ' ')"
  if [ "$TARGET" = "analytics" ]; then
    error "only the tyk-stack and tyk-control-plane topologies deploy a dashboard"
  fi
  exit 1
fi

REMOTE_PORT="$(remotePortFor "$TARGET")"
LOCAL_PORT="${LOCAL_PORT:-$REMOTE_PORT}"

log "exposing $TARGET from $INSTANCE"
log "  service  $SERVICE in $NAMESPACE"
if [ "$TARGET" = "redis" ]; then
  log "  address  localhost:${LOCAL_PORT}"
else
  log "  url      http://localhost:${LOCAL_PORT}"
fi
hintFor "$TARGET" "$LOCAL_PORT"
log "ctrl-c to stop"

exec kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" port-forward \
  "svc/${SERVICE}" "${LOCAL_PORT}:${REMOTE_PORT}"
