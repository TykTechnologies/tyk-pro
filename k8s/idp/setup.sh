#!/usr/bin/env bash

# Sets up an IDP environment: a kind cluster carrying the operators
# idp-controller depends on, plus the idp-controller release itself.
#
# The cluster and its operators come from idp-controller's own hack/cluster.sh
# rather than a copy kept here, so this stays correct when that repo changes
# which operators the controller needs. Point IDP_CONTROLLER_ROOT at a checkout
# of TykTechnologies/idp-controller; the default assumes it sits next to
# tyk-pro.

set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"
source "${SCRIPT_DIR}/../tyk-stack-ingress/lib.sh"

TYK_PRO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

######################################
# configuration
######################################
# A caller-exported value wins over .env, which is the opposite of what plain
# sourcing does: an export is a deliberate per-run choice, while .env holds
# local defaults. Same handling as run-tyk-cp-dp.sh.
CONFIG_VARS=(
  IDP_CONTROLLER_ROOT
  KIND_CLUSTER_NAME
  KIND_IMAGE
  INSTALL_MONITORING
  IDP_NAMESPACE
  IDP_RELEASE
  IDP_IMAGE_TAG
  IDP_CONTROLLER_IMAGE
  IDP_SERVER_IMAGE
  IDP_ADMIN_SECRET
  IDP_API_SECRET
  IDP_SECURITY_SECRET
  DEPLOY_CHART
  HELM_TIMEOUT
  TYK_DB_LICENSEKEY
  TYK_MDCB_LICENSEKEY
)

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

IDP_CONTROLLER_ROOT="${IDP_CONTROLLER_ROOT:-${TYK_PRO_ROOT}/../idp-controller}"

# The IDP stack gets its own cluster rather than sharing the `kind` one that
# k8s/tyk-stack-ingress uses. Both stacks install ingress-nginx and both would
# claim the cluster-scoped IngressClass `nginx`, and idp-controller's cluster
# carries no 80/443 extraPortMappings that the tyk stack's ingress path needs.
# kind reads KIND_CLUSTER_NAME when --name is absent, and hack/cluster.sh
# passes no --name, so the rename needs no change in that repo.
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-tyk-idp}"
KUBE_CONTEXT="kind-${KIND_CLUSTER_NAME}"

INSTALL_MONITORING="${INSTALL_MONITORING:-false}"
IDP_NAMESPACE="${IDP_NAMESPACE:-idp-system}"
IDP_RELEASE="${IDP_RELEASE:-idp-controller}"
DEPLOY_CHART="${DEPLOY_CHART:-true}"
HELM_TIMEOUT="${HELM_TIMEOUT:-600s}"

# Released images and chart, so this needs no Go toolchain: the release
# workflow tags tykio/idp-controller and tykio/idp-server with the git tag, and
# the chart ships its CRDs under deploy/idp-controller/crds/, which helm
# applies. Set IDP_IMAGE_TAG to test a different release.
IDP_IMAGE_TAG="${IDP_IMAGE_TAG:-v0.0.10}"
IDP_CONTROLLER_IMAGE="${IDP_CONTROLLER_IMAGE:-tykio/idp-controller}"
IDP_SERVER_IMAGE="${IDP_SERVER_IMAGE:-tykio/idp-server}"

# Credentials for the tyk-stack secret the chart creates in IDP_NAMESPACE. The
# controller replicates that secret into every tenant namespace, so the Tyk
# charts a tenant deploys read these values. The literal matches the APISecret
# run-tyk-cp-dp.sh hands its data planes, so a test can assume one value across
# both environments.
IDP_ADMIN_SECRET="${IDP_ADMIN_SECRET:-352d20ee67be67f6340b4c0605b044b7}"
IDP_API_SECRET="${IDP_API_SECRET:-352d20ee67be67f6340b4c0605b044b7}"
IDP_SECURITY_SECRET="${IDP_SECURITY_SECRET:-352d20ee67be67f6340b4c0605b044b7}"

######################################
# preflight
######################################
checkDependencies() {
  for cmd in kind kubectl helm docker; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
      error "$cmd is not installed or not in PATH"
      exit 1
    fi
  done
}

resolveIdpControllerRoot() {
  if [ ! -d "$IDP_CONTROLLER_ROOT" ]; then
    error "no idp-controller checkout at '$IDP_CONTROLLER_ROOT'"
    error "clone TykTechnologies/idp-controller and set IDP_CONTROLLER_ROOT to it"
    exit 1
  fi

  IDP_CONTROLLER_ROOT="$(cd "$IDP_CONTROLLER_ROOT" && pwd)"

  for path in hack/cluster.sh deploy/idp-controller/Chart.yaml; do
    if [ ! -e "${IDP_CONTROLLER_ROOT}/${path}" ]; then
      error "'$IDP_CONTROLLER_ROOT' has no ${path}; it does not look like an idp-controller checkout"
      exit 1
    fi
  done

  if [ ! -x "${IDP_CONTROLLER_ROOT}/hack/cluster.sh" ]; then
    error "${IDP_CONTROLLER_ROOT}/hack/cluster.sh is not executable"
    exit 1
  fi

  log "using idp-controller checkout at $IDP_CONTROLLER_ROOT"
}

requireLicenses() {
  # The chart installs without these, but every tenant deploy that follows
  # fails on an empty license, and the failure surfaces far from its cause. Ask
  # for them up front, as run-tyk-cp-dp.sh does.
  if [[ -z "${TYK_DB_LICENSEKEY:-}" ]]; then
    error "TYK_DB_LICENSEKEY is not set. Set it in the .env file or export it."
    error "to build only the cluster and its operators, run with DEPLOY_CHART=false"
    exit 1
  fi
  if [[ -z "${TYK_MDCB_LICENSEKEY:-}" ]]; then
    error "TYK_MDCB_LICENSEKEY is not set. Set it in the .env file or export it."
    error "to build only the cluster and its operators, run with DEPLOY_CHART=false"
    exit 1
  fi
}

warnOnSharedCloudProvider() {
  # idp-controller's nginx-lb.sh runs a cloud-provider-kind container named
  # cloud-provider-kind; run-tyk-cp-dp.sh runs its own as
  # tyk-ci-cloud-provider-kind. Neither detects the other, and both reconcile
  # every LoadBalancer Service on the kind Docker network.
  if docker ps --format '{{.Names}}' | grep -qx 'tyk-ci-cloud-provider-kind'; then
    warning "tyk-ci-cloud-provider-kind is running from k8s/tyk-stack-ingress"
    warning "two cloud-provider-kind controllers will reconcile the same LoadBalancer Services; stop one before relying on LB addresses"
  fi
}

######################################
# cluster
######################################
createCluster() {
  if kind get clusters 2> /dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
    log "kind cluster '$KIND_CLUSTER_NAME' already exists, skipping hack/cluster.sh"
  else
    log "creating kind cluster '$KIND_CLUSTER_NAME' through idp-controller/hack/cluster.sh"
    log "  that installs ArgoCD, cert-manager, ingress-nginx with cloud-provider-kind, and the in-cluster chart repo"

    # cluster.sh ends by re-applying $IDP_CONTROLLER_ROOT/secret.yaml to every
    # namespace labeled platform.tyk.io/tenant-namespace=true. A new cluster
    # has none, so that loop is empty and the file, which is gitignored in that
    # repo, is not needed here. The chart creates the same tyk-stack secret
    # from values below, and the controller replicates it to tenants.
    local env_args=(
      "KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME}"
      "INSTALL_MONITORING=${INSTALL_MONITORING}"
    )
    if [ -n "${KIND_IMAGE:-}" ]; then
      env_args+=("KIND_IMAGE=${KIND_IMAGE}")
    fi

    env "${env_args[@]}" "${IDP_CONTROLLER_ROOT}/hack/cluster.sh"
  fi

  # kind switches the current context on create, but the skip path above leaves
  # whatever was current, which may be the tyk-stack-ingress cluster. Pin the
  # context so the release cannot land in the wrong cluster.
  if ! kubectl config use-context "$KUBE_CONTEXT" > /dev/null 2>&1; then
    error "no kubeconfig context '$KUBE_CONTEXT'; export the kind kubeconfig with: kind export kubeconfig --name $KIND_CLUSTER_NAME"
    exit 1
  fi
  log "kubectl context is $KUBE_CONTEXT"
}

######################################
# idp-controller release
######################################
deployChart() {
  log "deploying $IDP_RELEASE to namespace $IDP_NAMESPACE"
  log "  controller $IDP_CONTROLLER_IMAGE:$IDP_IMAGE_TAG"
  log "  api-server $IDP_SERVER_IMAGE:$IDP_IMAGE_TAG"

  # --set-string throughout: the licenses are JWTs and the secrets are hex, and
  # helm would otherwise coerce a numeric-looking value to a number.
  helm upgrade --install "$IDP_RELEASE" "${IDP_CONTROLLER_ROOT}/deploy/idp-controller/" \
    --kube-context "$KUBE_CONTEXT" \
    --namespace "$IDP_NAMESPACE" \
    --create-namespace \
    --set-string controller.image.repository="$IDP_CONTROLLER_IMAGE" \
    --set-string controller.image.tag="$IDP_IMAGE_TAG" \
    --set-string controller.image.pullPolicy=IfNotPresent \
    --set-string apiServer.image.repository="$IDP_SERVER_IMAGE" \
    --set-string apiServer.image.tag="$IDP_IMAGE_TAG" \
    --set-string apiServer.image.pullPolicy=IfNotPresent \
    --set-string idpControllerSecrets.adminSecret="$IDP_ADMIN_SECRET" \
    --set-string idpControllerSecrets.apiSecret="$IDP_API_SECRET" \
    --set-string idpControllerSecrets.securitySecret="$IDP_SECURITY_SECRET" \
    --set-string idpControllerSecrets.dashLicense="$TYK_DB_LICENSEKEY" \
    --set-string idpControllerSecrets.mdcbLicense="$TYK_MDCB_LICENSEKEY" \
    --wait \
    --timeout "$HELM_TIMEOUT"
}

######################################
# summary
######################################
printSummary() {
  log "--------------------------------------------------"
  log "IDP environment ready"
  log "  cluster    $KIND_CLUSTER_NAME (context $KUBE_CONTEXT)"
  log "  operators  argocd, cert-manager, nginx namespaces"

  if [[ "$DEPLOY_CHART" != "true" ]]; then
    log "  release    skipped (DEPLOY_CHART=$DEPLOY_CHART)"
    log "--------------------------------------------------"
    return 0
  fi

  log "  release    $IDP_RELEASE in $IDP_NAMESPACE at $IDP_IMAGE_TAG"

  # Ask the cluster for the Service name rather than deriving it: the chart's
  # fullname helper only collapses to the release name when the release name
  # contains the chart name, so a custom IDP_RELEASE changes the result.
  local api_svc
  api_svc="$(kubectl --context "$KUBE_CONTEXT" -n "$IDP_NAMESPACE" get svc \
    -l "app.kubernetes.io/instance=${IDP_RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}' 2> /dev/null || true)"

  if [ -n "$api_svc" ]; then
    log "  api-server kubectl --context $KUBE_CONTEXT -n $IDP_NAMESPACE port-forward svc/$api_svc 8080:8080"
  fi

  log "  pods       kubectl --context $KUBE_CONTEXT -n $IDP_NAMESPACE get pods"
  log "  apps       kubectl --context $KUBE_CONTEXT -n argocd get applications"

  if [[ "$(uname -s)" == "Darwin" ]]; then
    # See idp-controller docs/local-development.md: Docker Desktop does not
    # route kind's LoadBalancer IPs to the macOS host.
    warning "on macOS the LoadBalancer IPs cloud-provider-kind assigns are unreachable from the host under Docker Desktop; use port-forwarding, or OrbStack"
  fi

  log "--------------------------------------------------"
}

checkDependencies
resolveIdpControllerRoot
if [[ "$DEPLOY_CHART" == "true" ]]; then
  requireLicenses
fi
warnOnSharedCloudProvider
createCluster
if [[ "$DEPLOY_CHART" == "true" ]]; then
  deployChart
else
  log "DEPLOY_CHART=$DEPLOY_CHART, leaving the idp-controller release out"
fi
printSummary

log "--> $0 done"
