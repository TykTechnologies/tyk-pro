#!/usr/bin/env bash

# Port-forwards a Tyk service inside a tenant namespace to localhost.
#
# analytics serves the dashboard to a browser, or to a gateway running on this
# machine for config polling and node registration. gateway serves the
# in-cluster gateway, so its proxy and admin API can be called directly.
#
# A local gateway needs more than the dashboard: the stack's Redis for reload
# signals, and a route from the dashboard back to it for key management. See
# the readme.
#
# Usage:
#   ./expose.sh analytics [instance]   dashboard on localhost:3000
#   ./expose.sh gateway [instance]     gateway on localhost:8080
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
  error "usage: $0 [analytics|gateway] [instance]"
  error "  analytics  the Tyk dashboard, on localhost:3000"
  error "  gateway    the Tyk gateway, on localhost:8080"
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
    gateway)
      kc -n "$namespace" get svc -o name \
        | sed 's|service/||' | grep -- '-tyk-gateway$' | head -1 || true
      ;;
  esac
}

remotePortFor() {
  case "$1" in
    analytics) echo 3000 ;;
    gateway) echo 8080 ;;
  esac
}

# What to do with the forward once it is up. analytics is something a gateway
# on this machine consumes, so it prints config; gateway is something you call,
# so it prints requests.
hintFor() {
  local target="$1" port="$2"

  case "$target" in
    analytics)
      log "open http://localhost:${port} in a browser, or point a local gateway at it:"
      log "  db_app_conf_options.connection_string = http://localhost:${port}"
      log "  policies.policy_connection_string     = http://localhost:${port}"
      ;;
    gateway)
      log "check it with:"
      log "  curl http://localhost:${port}/hello"

      # Printed as a command rather than a value: the admin secret would
      # otherwise sit in terminal scrollback and in any log this output reaches.
      local secret
      secret="$(kc -n "$NAMESPACE" get secret -o name \
        | sed 's|secret/||' | grep -- '-tyk-gateway$' | head -1 || true)"
      if [ -n "$secret" ]; then
        log "the admin API needs an x-tyk-authorization header, read it with:"
        log "  kubectl --context $KUBE_CONTEXT -n $NAMESPACE get secret $secret \\"
        log "    -o jsonpath='{.data.APISecret}' | base64 -d"
      fi
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
  analytics | gateway) ;;
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
log "  url      http://localhost:${LOCAL_PORT}"
hintFor "$TARGET" "$LOCAL_PORT"
log "ctrl-c to stop"

exec kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" port-forward \
  "svc/${SERVICE}" "${LOCAL_PORT}:${REMOTE_PORT}"
