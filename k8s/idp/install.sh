#!/usr/bin/env bash

# Deploys a Tyk stack: picks a TykDeployment from the catalogue, creates a
# TykDeploymentInstance referencing it, and waits for the instance to run.
#
# The platform itself comes from setup.sh. This script only creates the one
# resource that turns a blueprint into pods: ProductClass and TykDeployment
# store configuration and run nothing, while a TykDeploymentInstance makes the
# controller create a tenant namespace and the ArgoCD Applications that install
# the charts.
#
# Usage:
#   ./install.sh              list the catalogue, ask which stack to deploy
#   ./install.sh <topology>   deploy that TykDeployment without asking
#
# Environment:
#   NAME           instance name           (default <topology>-1, or the next free number)
#   OWNER          owner identifier        (default the git user's name, sanitised)
#   DEPLOY_TIMEOUT wait for Running        (default 900s)

set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"
source "${SCRIPT_DIR}/../tyk-stack-ingress/lib.sh"

######################################
# configuration
######################################
CONFIG_VARS=(KIND_CLUSTER_NAME NAME OWNER DEPLOY_TIMEOUT)

for var in "${CONFIG_VARS[@]}"; do
  declare "EXPORTED_${var}=${!var-}"
done

if [ -f .env ]; then
  source .env
fi

for var in "${CONFIG_VARS[@]}"; do
  exported="EXPORTED_${var}"
  if [ -n "${!exported-}" ]; then
    declare "${var}=${!exported}"
  fi
done

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-tyk-idp}"
KUBE_CONTEXT="kind-${KIND_CLUSTER_NAME}"
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-900s}"

# The controller copies OwnerRef.Email onto the platform.tyk.io/owner-user-id
# label verbatim, and a label value cannot contain "@". An address here puts
# the reconciler into a loop that reports nothing on the resource, so strip
# everything a label rejects.
defaultOwner() {
  local raw
  raw="$(git config user.name 2> /dev/null || echo "")"
  [ -n "$raw" ] || raw="$(id -un)"

  printf '%s' "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c '[:alnum:]._-' '-' \
    | sed -e 's/^[^[:alnum:]]*//' -e 's/[^[:alnum:]]*$//'
}

OWNER="${OWNER:-$(defaultOwner)}"

kc() {
  kubectl --context "$KUBE_CONTEXT" "$@"
}

######################################
# catalogue
######################################
requireCatalogue() {
  if ! kc get crd tykdeployments.platform.tyk.io > /dev/null 2>&1; then
    error "the platform.tyk.io CRDs are not installed"
    error "build the platform first: task -d k8s/idp setup"
    exit 1
  fi

  if [ -z "$(kc get tykdeployment -o name 2> /dev/null)" ]; then
    error "no TykDeployment in the catalogue"
    error "build the platform first: task -d k8s/idp setup"
    exit 1
  fi
}

listTopologies() {
  kc get tykdeployment -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort
}

# Prints each topology with the products it deploys, so the choice does not
# need a second lookup.
showCatalogue() {
  log "available stacks"
  kc get tykdeployment -o json | python3 -c '
import json, sys

items = sorted(json.load(sys.stdin)["items"], key=lambda t: t["metadata"]["name"])
for n, t in enumerate(items, 1):
    products = ", ".join(p["name"] for p in t["spec"].get("products", []))
    name = t["metadata"]["name"]
    print(f"  {n:2}. {name:32} {products}")
'
}

# Asks by number, because the names are long and easy to mistype. A run with no
# terminal attached never blocks; it reports how to pass the topology instead.
#
# Sets CHOSEN_TOPOLOGY rather than printing it: a command substitution would
# capture the catalogue listing, the prompt and every error along with the
# answer, leaving the caller staring at a silent failure.
CHOSEN_TOPOLOGY=""

chooseTopology() {
  local topologies=()
  while IFS= read -r line; do topologies+=("$line"); done < <(listTopologies)

  showCatalogue

  if [ ! -t 0 ]; then
    error "no terminal to ask on; pass the topology as an argument"
    error "for example: $0 ${topologies[0]}"
    exit 1
  fi

  local answer
  read -r -p "$(printf 'Deploy which stack? [1-%s] ' "${#topologies[@]}")" answer

  case "$answer" in
    '' )
      error "nothing chosen"
      exit 1
      ;;
    *[!0-9]* )
      error "'$answer' is not a number"
      exit 1
      ;;
  esac

  if [ "$answer" -lt 1 ] || [ "$answer" -gt "${#topologies[@]}" ]; then
    error "$answer is outside 1-${#topologies[@]}"
    exit 1
  fi

  CHOSEN_TOPOLOGY="${topologies[$((answer - 1))]}"
}

requireTopology() {
  local topology="$1"

  if ! kc get tykdeployment "$topology" > /dev/null 2>&1; then
    error "no TykDeployment named '$topology'"
    error "the catalogue holds: $(listTopologies | tr '\n' ' ')"
    exit 1
  fi
}

######################################
# instance
######################################
# Instances are cluster-scoped, so a fixed name collides as soon as you want a
# second copy of the same stack. Count up until a name is free.
nextName() {
  local topology="$1" n=1

  while kc get tykdeploymentinstance "${topology}-${n}" > /dev/null 2>&1; do
    n=$((n + 1))
  done

  printf '%s-%s' "$topology" "$n"
}

createInstance() {
  local topology="$1" name="$2"

  log "deploying $topology as instance $name"
  log "  owner $OWNER"

  kc apply -f - << EOF
apiVersion: platform.tyk.io/v1alpha1
kind: TykDeploymentInstance
metadata:
  name: ${name}
spec:
  humanReadableName: ${topology}
  tykDeploymentRef: ${topology}
  ownerRef:
    email: ${OWNER}
EOF
}

# Waits on the phase rather than on pods: the controller reports Running only
# once every ArgoCD Application it created is synced and healthy.
waitForInstance() {
  local name="$1"

  log "waiting for $name to reach Running, up to $DEPLOY_TIMEOUT"

  local deadline=$((SECONDS + ${DEPLOY_TIMEOUT%s}))
  local phase=""
  while [ $SECONDS -lt $deadline ]; do
    phase="$(kc get tykdeploymentinstance "$name" -o jsonpath='{.status.phase}' 2> /dev/null || true)"

    case "$phase" in
      Running) break ;;
      Failed)
        error "$name reached Failed"
        error "$(kc get tykdeploymentinstance "$name" -o jsonpath='{.status.errorMessage}')"
        exit 1
        ;;
    esac

    sleep 10
  done

  if [ "$phase" != "Running" ]; then
    error "$name is still $phase after $DEPLOY_TIMEOUT"
    error "check it with: kubectl --context $KUBE_CONTEXT describe tykdeploymentinstance $name"
    exit 1
  fi
}

printSummary() {
  local name="$1"

  local namespace
  namespace="$(kc get tykdeploymentinstance "$name" -o jsonpath='{.status.tenantNamespace}')"

  log "--------------------------------------------------"
  log "$name is running in $namespace"
  log "  pods     kubectl --context $KUBE_CONTEXT -n $namespace get pods"
  log "  apps     kubectl --context $KUBE_CONTEXT -n argocd get applications"
  log "  image    task -d k8s/idp set-gateway INSTANCE=$name IMAGE=<repo:tag>"
  log "  remove   kubectl --context $KUBE_CONTEXT delete tykdeploymentinstance $name"
  log "--------------------------------------------------"
}

######################################
# entrypoint
######################################
requireCatalogue

TOPOLOGY="${1-}"
if [ -n "$TOPOLOGY" ]; then
  requireTopology "$TOPOLOGY"
else
  chooseTopology
  TOPOLOGY="$CHOSEN_TOPOLOGY"
fi

NAME="${NAME:-$(nextName "$TOPOLOGY")}"

createInstance "$TOPOLOGY" "$NAME"
waitForInstance "$NAME"
printSummary "$NAME"
