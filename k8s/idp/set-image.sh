#!/usr/bin/env bash

# Points one product's Helm chart at a different container image, and proves
# the running workload picked it up.
#
# The override lands on the TykDeploymentInstance as a spec.values entry, which
# is the layer end-users own: ChartRef.Values sets the base, spec.values sits on
# top, and ChartRef.SystemValuesBlock always wins over both. From there the
# controller merges the layers, patches the ArgoCD Application, and ArgoCD
# re-renders the chart.
#
# Usage:
#   ./set-image.sh set <instance> <repo:tag>   point a product's chart at an image
#   ./set-image.sh show <instance>             print the values each Application got
#   ./set-image.sh clear <instance>            drop the override, restoring the default
#
# Environment:
#   PRODUCT_CLASS  ProductClass to target       (default tyk-oss)
#   KEY            dotted values path to set    (default tyk-gateway.gateway.image)
#   COMPONENT      component KEY addresses      (unset; set by the set-* tasks)
#   ROLLOUT_TIMEOUT                             (default 180s)
#
# The default KEY carries the subchart prefix on purpose. tyk-oss is an umbrella
# chart, and values bound for its tyk-gateway subchart must nest under that
# subchart's name, so the doubled-looking tyk-gateway.gateway is correct.

set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"
source "${SCRIPT_DIR}/../tyk-stack-ingress/lib.sh"

######################################
# configuration
######################################
# Same precedence as setup.sh: a caller-exported value beats .env, because an
# export is a deliberate per-run choice while .env holds local defaults.
CONFIG_VARS=(KIND_CLUSTER_NAME PRODUCT_CLASS KEY COMPONENT ROLLOUT_TIMEOUT)

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
PRODUCT_CLASS="${PRODUCT_CLASS:-tyk-oss}"
KEY="${KEY:-tyk-gateway.gateway.image}"
COMPONENT="${COMPONENT:-}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"

INSTANCE_LABEL="platform.tyk.io/deployment-instance"

kc() {
  kubectl --context "$KUBE_CONTEXT" "$@"
}

######################################
# validation
######################################
requireInstance() {
  local instance="$1"

  if ! kc get tykdeploymentinstance "$instance" > /dev/null 2>&1; then
    error "no TykDeploymentInstance named '$instance' in $KUBE_CONTEXT"
    error "list them with: kubectl --context $KUBE_CONTEXT get tykdeploymentinstance"
    exit 1
  fi
}

requireProductInTopology() {
  local instance="$1"

  local topology
  topology="$(kc get tykdeploymentinstance "$instance" -o jsonpath='{.spec.tykDeploymentRef}')"

  # An override naming a ProductClass the topology does not include is merged
  # into nothing: the reconciler only looks up overrides for products it is
  # already deploying, so the entry sits on the instance and changes no chart.
  if ! kc get tykdeployment "$topology" \
    -o jsonpath='{.spec.products[*].name}' | tr ' ' '\n' | grep -qx "$PRODUCT_CLASS"; then
    error "topology '$topology' does not include ProductClass '$PRODUCT_CLASS'"
    error "its products are: $(kc get tykdeployment "$topology" -o jsonpath='{.spec.products[*].name}')"
    error "set PRODUCT_CLASS to one of them"
    exit 1
  fi
}

# Components each Tyk umbrella chart carries, copied from the dependency lists
# in the tyk-charts Chart.yaml files. A component that moves between umbrellas
# makes this stale, but the failure is a wrong rejection rather than a bad
# deploy. An unlisted chart returns nothing and is skipped by requireComponent.
componentsOf() {
  case "$1" in
    tyk-oss) echo "gateway pump" ;;
    tyk-stack) echo "gateway pump dashboard" ;;
    tyk-control-plane) echo "gateway pump dashboard" ;;
    tyk-data-plane) echo "gateway pump" ;;
    *) echo "" ;;
  esac
}

# Fails when the ProductClass deploys no chart carrying the component KEY
# addresses. Without it, asking for a dashboard on a gateway-only chart writes
# an override that renders nothing and reports no error.
requireComponent() {
  [ -n "$COMPONENT" ] || return 0

  local chart_names
  chart_names="$(kc get productclass "$PRODUCT_CLASS" \
    -o jsonpath='{.spec.chartRefs[*].chartName}' 2> /dev/null || true)"

  local known="" available=""
  for chart in $chart_names; do
    local components
    components="$(componentsOf "$chart")"
    [ -n "$components" ] || continue
    known="yes"
    available="$available $components"

    if printf '%s' "$components" | tr ' ' '\n' | grep -qx "$COMPONENT"; then
      return 0
    fi
  done

  # The table only speaks about the charts it lists, so a ProductClass built
  # entirely from charts it does not know gets a pass rather than a refusal.
  if [ -z "$known" ]; then
    warning "no chart in ProductClass '$PRODUCT_CLASS' is in the component table; skipping the $COMPONENT check"
    return 0
  fi

  error "ProductClass '$PRODUCT_CLASS' deploys no $COMPONENT"
  error "its charts carry:$(printf '%s' "$available" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
  error "set PRODUCT_CLASS to one that carries a $COMPONENT"
  exit 1
}

# Emits the dotted path of every key in a YAML block. Matching a bare leaf is
# not enough: every tyk-* ProductClass pins tyk-bootstrap...postInstall.image,
# so a leaf-only check warns on "image" for a gateway override that the system
# block never touches.
yamlPaths() {
  awk '
    {
      line = $0
      sub(/#.*/, "", line)
      if (line ~ /^[[:space:]]*$/) next

      indent = match(line, /[^ ]/) - 1
      key = line
      sub(/^[[:space:]]*/, "", key)
      if (key !~ /^[A-Za-z0-9_.-]+:/) next
      sub(/:.*/, "", key)

      depth = int(indent / 2)
      path[depth] = key
      for (d = depth + 1; d in path; d++) delete path[d]

      out = path[0]
      for (d = 1; d <= depth; d++) out = out "." path[d]
      print out
    }'
}

warnOnSystemPin() {
  # SystemValuesBlock always wins over spec.values, so a key pinned there
  # swallows the override with no error anywhere.
  local system_block
  system_block="$(kc get productclass "$PRODUCT_CLASS" \
    -o jsonpath='{.spec.chartRefs[*].systemValuesBlock}' 2> /dev/null || true)"

  if printf '%s' "$system_block" | yamlPaths | grep -qx "$KEY"; then
    warning "ProductClass '$PRODUCT_CLASS' pins '$KEY' in its systemValuesBlock"
    warning "that layer always wins over spec.values, so this override will have no effect"
    warning "inspect it with: kubectl --context $KUBE_CONTEXT get productclass $PRODUCT_CLASS -o jsonpath='{.spec.chartRefs[*].systemValuesBlock}'"
  fi
}

######################################
# image handling
######################################
loadImage() {
  local image="$1"

  # Only an image built on this host needs loading. A public tag the nodes can
  # pull themselves is left alone, and a missing local image is not an error
  # because it may well live in a registry.
  if docker image inspect "$image" > /dev/null 2>&1; then
    log "loading $image into kind cluster '$KIND_CLUSTER_NAME'"
    kind load docker-image "$image" --name "$KIND_CLUSTER_NAME"
  else
    log "$image is not in the local docker daemon; the nodes will pull it"
  fi
}

# Turns a dotted path plus an image into the nested YAML the chart expects:
#   tyk-gateway.gateway.image + my-gw:local
# becomes
#   tyk-gateway:
#     gateway:
#       image:
#         repository: my-gw
#         tag: local
#         pullPolicy: IfNotPresent
renderValues() {
  local repo="$1" tag="$2"

  printf '%s\n' "$KEY" | tr '.' '\n' | awk -v repo="$repo" -v tag="$tag" '
    { printf "%*s%s:\n", (NR-1)*2, "", $0; depth = NR }
    END {
      printf "%*srepository: %s\n", depth * 2, "", repo
      printf "%*stag: %s\n", depth * 2, "", tag
      # IfNotPresent so a kind-loaded image is used as-is. Always would send
      # the kubelet to a registry that has never heard of a local build.
      printf "%*spullPolicy: IfNotPresent\n", depth * 2, ""
    }'
}

######################################
# verification
######################################
# Finds the workload running a given image in the tenant namespace. Scanning by
# image rather than by name keeps this independent of the chart's naming, and
# the Application-to-workload mapping is not recorded anywhere to look up.
findWorkload() {
  local namespace="$1" image="$2"

  kc -n "$namespace" get deploy,statefulset \
    -o jsonpath="{range .items[?(@.spec.template.spec.containers[0].image=='${image}')]}{.kind}/{.metadata.name}{'\n'}{end}" \
    2> /dev/null | head -1
}

verifyRollout() {
  local instance="$1" image="$2"

  local namespace
  namespace="$(kc get tykdeploymentinstance "$instance" -o jsonpath='{.status.tenantNamespace}')"
  if [ -z "$namespace" ]; then
    warning "instance '$instance' has no tenant namespace yet; nothing to verify"
    return 0
  fi

  # Three things happen after the apply: the controller re-merges and patches
  # the Application, ArgoCD re-renders and applies it, and the workload rolls.
  # Reading the image before all three finish reports the old one, so wait for
  # the workload to appear rather than checking once.
  log "waiting for a workload in $namespace to run $image"

  local deadline=$((SECONDS + ${ROLLOUT_TIMEOUT%s}))
  local workload=""
  while [ $SECONDS -lt $deadline ]; do
    workload="$(findWorkload "$namespace" "$image")"
    [ -n "$workload" ] && break
    sleep 5
  done

  if [ -z "$workload" ]; then
    error "no workload in $namespace is running $image after $ROLLOUT_TIMEOUT"
    error "the override reached the instance but did not change the rendered chart"
    error "the most likely cause is a KEY the chart does not read; the current default is:"
    error "  KEY=$KEY"
    error "compare it against: helm show values <repo>/<chart> --version <version>"
    error "and see what ArgoCD received with: $0 show $instance"
    exit 1
  fi

  log "$workload is running $image"
  kc -n "$namespace" rollout status "$workload" --timeout="$ROLLOUT_TIMEOUT"
}

######################################
# patching
######################################
# Rewrites spec.values, keeping every entry that targets another ProductClass.
# An empty $2 removes this ProductClass's entry instead of setting one.
#
# A JSON merge patch rather than server-side apply: the instances the api-server
# and kubectl create are client-side applied, and the first --server-side apply
# migrates their fields to whichever manager applies. That manager then owns
# humanReadableName, tykDeploymentRef and ownerRef, and the next apply that
# omits them deletes them, leaving an instance the reconciler cannot validate.
# A merge patch touches only the key it names.
patchValues() {
  local instance="$1" values="$2"

  local current
  current="$(kc get tykdeploymentinstance "$instance" -o jsonpath='{.spec.values}')"
  [ -n "$current" ] || current='[]'

  local patch
  patch="$(VALUES="$values" PRODUCT_CLASS="$PRODUCT_CLASS" CURRENT="$current" python3 -c '
import json, os

current = json.loads(os.environ["CURRENT"])
product = os.environ["PRODUCT_CLASS"]
values = os.environ["VALUES"]

kept = [e for e in current if e.get("productClass") != product]
if values.strip():
    kept.append({"productClass": product, "values": values.rstrip("\n") + "\n"})

print(json.dumps({"spec": {"values": kept}}))
')"

  kc patch tykdeploymentinstance "$instance" --type=merge -p "$patch" > /dev/null
}

######################################
# subcommands
######################################
setImage() {
  local instance="${1-}" image="${2-}"

  if [ -z "$instance" ] || [ -z "$image" ]; then
    error "usage: $0 set <instance> <repo:tag>"
    exit 1
  fi

  # repo:tag is split on the last colon, so a bare repository would silently
  # become a tag and produce a nonsense reference.
  case "$image" in
    *:*) ;;
    *)
      error "image '$image' has no tag; pass it as repo:tag"
      exit 1
      ;;
  esac

  local repo="${image%:*}" tag="${image##*:}"

  requireInstance "$instance"
  requireProductInTopology "$instance"
  requireComponent
  warnOnSystemPin
  loadImage "$image"

  local values
  values="$(renderValues "$repo" "$tag")"

  log "pointing $PRODUCT_CLASS at $image on instance $instance"
  log "  key $KEY"

  patchValues "$instance" "$values"

  verifyRollout "$instance" "$image"
}

showValues() {
  local instance="${1-}"

  if [ -z "$instance" ]; then
    error "usage: $0 show <instance>"
    exit 1
  fi

  requireInstance "$instance"

  local apps
  apps="$(kc -n argocd get applications -l "${INSTANCE_LABEL}=${instance}" -o name)"
  if [ -z "$apps" ]; then
    warning "instance '$instance' has no ArgoCD Applications yet"
    return 0
  fi

  for app in $apps; do
    local product
    product="$(kc -n argocd get "$app" -o jsonpath='{.metadata.annotations.platform\.tyk\.io/product-class}')"
    log "--- ${app#application.argoproj.io/} (${product}) ---"
    kc -n argocd get "$app" -o jsonpath='{.spec.source.helm.values}'
    echo
  done
}

clearImage() {
  local instance="${1-}"

  if [ -z "$instance" ]; then
    error "usage: $0 clear <instance>"
    exit 1
  fi

  requireInstance "$instance"

  log "removing the $PRODUCT_CLASS override from instance $instance"
  patchValues "$instance" ""

  local namespace
  namespace="$(kc get tykdeploymentinstance "$instance" -o jsonpath='{.status.tenantNamespace}')"

  log "the chart default returns on the next sync; watch it with:"
  log "  kubectl --context $KUBE_CONTEXT -n $namespace get deploy -o wide"
}

######################################
# entrypoint
######################################
case "${1:-}" in
  set)
    shift
    setImage "$@"
    ;;
  show)
    shift
    showValues "$@"
    ;;
  clear)
    shift
    clearImage "$@"
    ;;
  *)
    error "usage: $0 [set <instance> <repo:tag>|show <instance>|clear <instance>]"
    exit 1
    ;;
esac
