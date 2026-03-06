#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"
source lib.sh

if [ -f .env ]; then
  source .env
fi

######################################
# required env variables
######################################
if [[ -z "${TYK_DB_LICENSEKEY:-}" ]]; then
  error "TYK_DB_LICENSEKEY is not set. Please set it in the .env file or export it."
  exit 1
fi
if [[ -z "${TYK_MDCB_LICENSEKEY:-}" ]]; then
  error "TYK_MDCB_LICENSEKEY is not set. Please set it in the .env file or export it."
  exit 1
fi

######################################
# global configurations
######################################
TOXIPROXY_WAIT_TIMEOUT="${TOXIPROXY_WAIT_TIMEOUT:-120s}"
NGINX_TIMEOUT="${NGINX_TIMEOUT:-600s}"
INGRESS_READY_TIMEOUT="${INGRESS_READY_TIMEOUT:-90s}"
TOOLS_NAMESPACE="tools"
TYK_PRO_ROOT="$(cd ../.. && pwd)"
VERSIONS_DIR="./versions"

USE_TOXIPROXY="false"
for param in "$@"; do
  if [[ "$param" == "toxiproxy="* ]]; then
    USE_TOXIPROXY="${param#*=}"
  fi
done

export USE_TOXIPROXY
export TYK_DB_LICENSEKEY
export TYK_MDCB_LICENSEKEY

######################################
# functions
######################################

# read_version_field <version_file> <field_name> [default_value]
# it reads version from version.yaml files for each topology to compute ports and other config
read_version_field() {
  local version_file="${1:?version file required}"
  local field="${2:?field name required}"
  local default="${3:-}"
  local value
  value=$(grep "^${field}:" "$version_file" 2> /dev/null | awk '{print $2}' || true)
  echo "${value:-$default}"
}

deployNginx() {
  NGINX_SVC_TYPE=${NGINX_SVC_TYPE:-"NodePort"}
  NGINX_NAMESPACE="ingress-nginx"

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo add tyk-helm https://helm.tyk.io/public/helm/charts/
  helm repo update

  log "nginx svc type is $NGINX_SVC_TYPE"

  helm upgrade --install nginx ingress-nginx/ingress-nginx \
    --namespace "$NGINX_NAMESPACE" \
    --create-namespace \
    --set controller.service.type="$NGINX_SVC_TYPE" \
    --set controller.hostPort.enabled=true \
    --set controller.hostPort.ports.http=80 \
    --set controller.hostPort.ports.https=443 \
    --set 'controller.tolerations[0].key=node-role.kubernetes.io/master' \
    --set 'controller.tolerations[0].operator=Equal' \
    --set 'controller.tolerations[0].effect=NoSchedule' \
    --set 'controller.tolerations[1].key=node-role.kubernetes.io/control-plane' \
    --set 'controller.tolerations[1].operator=Equal' \
    --set 'controller.tolerations[1].effect=NoSchedule' \
    --wait \
    --timeout="$NGINX_TIMEOUT" \
    --hide-notes
  if [ $? -ne 0 ]; then
    return 1
  fi

  kubectl wait --namespace "$NGINX_NAMESPACE" \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout="$INGRESS_READY_TIMEOUT"
}

deployToxiProxy() {
  kubectl create namespace toxiproxy --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f ../apps/toxiproxy.yaml
  log "Waiting for Toxiproxy deployment to be ready..."
  kubectl wait --namespace toxiproxy --for=condition=available --timeout="$TOXIPROXY_WAIT_TIMEOUT" deployment/toxiproxy || true

  log "Waiting for Toxiproxy LoadBalancer IP..."
  TOXIPROXY_IP=""
  for attempt in $(seq 1 30); do
    TOXIPROXY_IP=$(kubectl get svc toxiproxy -n toxiproxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2> /dev/null || true)
    if [ -n "$TOXIPROXY_IP" ]; then
      break
    fi

    log "Attempt $attempt/30: Waiting for LoadBalancer IP..."
    sleep 2
  done

  if [ -z "$TOXIPROXY_IP" ]; then
    return 1
  fi

  export TOXIPROXY_URL="http://${TOXIPROXY_IP}:8474"
  log "Toxiproxy available at: $TOXIPROXY_URL"
}

# labelService <namespace> <service-name-pattern> <component>
labelService() {
  local namespace="${1:?namespace required}"
  local pattern="${2:?pattern required}"
  local component="${3:?component required}"

  local svc_name
  svc_name=$(kubectl get svc -n "$namespace" -o name 2> /dev/null | grep "$pattern" | head -1)
  if [ -n "$svc_name" ]; then
    kubectl label "$svc_name" -n "$namespace" tyk.io/component="$component" --overwrite > /dev/null
  fi
}

labelControlPlaneServices() {
  local namespace="${1:?namespace required}"

  labelService "$namespace" "dashboard-svc" "dashboard"
  labelService "$namespace" "gateway-svc" "gateway"
  labelService "$namespace" "mdcb-svc" "mdcb"
  labelService "$namespace" "pump-svc" "pump"
  kubectl label svc/redis -n "$namespace" tyk.io/component=redis --overwrite > /dev/null 2>&1 || true
  kubectl label svc/mongo -n "$namespace" tyk.io/component=mongo --overwrite > /dev/null 2>&1 || true
}

labelDataPlaneServices() {
  local dp_index="${1:?dp_index required}"
  local namespace="${2:?namespace required}"

  labelService "$namespace" "gateway-svc" "gateway"
  kubectl label svc/redis -n "$namespace" tyk.io/component=redis --overwrite > /dev/null 2>&1 || true
}

# Port allocation formula:
# ------------------------
# Each version gets a 10000-port band based on versionIndex.
#
# CP ports: base_port + versionIndex * 10000
# DP Redis: 7379 + versionIndex * 10000 + dp_index * 1000
#
# Example allocation:
# v5-8   (VI=0): CP Redis=6379,  MDCB=9091,  DP1 Redis=8379,  DP2 Redis=9379
# v5-11  (VI=1): CP Redis=16379, MDCB=19091, DP1 Redis=18379, DP2 Redis=19379
# master (VI=2): CP Redis=26379, MDCB=29091, DP1 Redis=28379, DP2 Redis=29379
#
# Port bands ensure isolation between concurrent multi-version deployments.
computePorts() {
  for topo_dir in "$VERSIONS_DIR"/*/; do
    [ -d "$topo_dir" ] || continue
    local topo
    topo=$(basename "$topo_dir")
    local version_file="${topo_dir}version.yaml"
    [ -f "$version_file" ] || continue

    local VI
    VI=$(read_version_field "$version_file" "versionIndex" "0")
    if ! [[ "$VI" =~ ^[0-9]+$ ]]; then
      error "Invalid versionIndex '$VI' in $version_file (must be a non-negative integer)"
      return 1
    fi
    local BAND=$((VI * 10000))
    local NUM_DPS
    NUM_DPS=$(read_version_field "$version_file" "numDataPlanes" "2")

    local ports_file="${topo_dir}.ports.yaml"
    {
      echo "redisCP:   $((6379 + BAND))"
      echo "mdcb:      $((9091 + BAND))"
      echo "mongo:     $((27017 + BAND))"
      echo "dashboard: $((3000 + BAND))"
      echo "gateway:   $((8080 + BAND))"
      for i in $(seq 1 "$NUM_DPS"); do
        echo "redisDp${i}: $((7379 + BAND + i * 1000))"
      done
    } > "$ports_file"

    log "Computed ports for $topo (versionIndex=$VI) -> $ports_file"
  done
}

populateToxiProxy() {
  if [ "$USE_TOXIPROXY" != "true" ]; then
    return 0
  fi

  log "Populating Toxiproxy proxies"
  local toxiproxy_url="${1:?toxiproxy_url is required}"

  local cli_path="$TYK_PRO_ROOT/k8s/apps/toxiproxy-agent/cli.py"
  if [ ! -f "$cli_path" ]; then
    error "toxiproxy-agent CLI not found at $cli_path"
    return 1
  fi

  local requirements_path="$TYK_PRO_ROOT/k8s/apps/toxiproxy-agent/requirements.txt"
  if [ -f "$requirements_path" ]; then
    pip install -q -r "$requirements_path" 2> /dev/null || true
  fi

  for topo_dir in "$VERSIONS_DIR"/*/; do
    [ -d "$topo_dir" ] || continue
    local topo
    topo=$(basename "$topo_dir")

    python3 "$cli_path" configure \
      --toxiproxy-url "$toxiproxy_url" \
      --namespace-pattern "tyk-${topo}-dp-*" \
      --control-namespace "tyk-${topo}" \
      --toxiproxy-namespace "toxiproxy" \
      --verbose
  done

  log "Toxiproxy configured successfully"
}

######################################
# main deployment flow
######################################

log "deploying nginx helm chart"
deployNginx || {
  error "failed to deploy nginx helm chart"
  exit 1
}
log "successfully deployed nginx ingress controller"

# toxiproxy (before helmfile, since infra needs proxy before CP starts with toxiproxy URLs)
if [ "$USE_TOXIPROXY" = "true" ]; then
  log "Deploying toxiproxy for resilience tests"
  deployToxiProxy || {
    error "failed to deploy toxiproxy"
    exit 1
  }
fi

# ECR pre-steps: iterate versions and set up private registry access where needed
for topo_dir in "$VERSIONS_DIR"/*/; do
  [ -d "$topo_dir" ] || continue
  topo=$(basename "$topo_dir")
  version_file="${topo_dir}version.yaml"
  [ -f "$version_file" ] || continue

  IMAGE_REPO_TYPE=$(read_version_field "$version_file" "imageRepoType" "official")
  if [[ "$IMAGE_REPO_TYPE" == "ecr" ]]; then
    IMAGE_REPO=$(read_version_field "$version_file" "imageRepo" "tykio")
    MDCB_IMAGE_TAG=$(read_version_field "$version_file" "mdcbTag" "v2.8.0")
    MDCB_IMAGE_NAME="tyk-sink"
    MDCB_VALIDATION_IMAGE_TAG="v10.0.0"
    CP_NS="tyk-${topo}"

    log "Setting up ECR access for version $topo in namespace $CP_NS"
    kubectl create namespace "$CP_NS" 2> /dev/null || true

    kubectl -n "$CP_NS" create secret docker-registry ecrcred \
      --docker-server=754489498669.dkr.ecr.eu-central-1.amazonaws.com \
      --docker-username=AWS \
      --docker-password="$(aws ecr get-login-password --region eu-central-1)" \
      --dry-run=client -o yaml | kubectl apply -f -

    kubectl -n "$CP_NS" patch sa default -p '{"imagePullSecrets":[{"name":"ecrcred"}]}' || true

    log "Pulling MDCB image for ECR version $topo"
    docker pull "$IMAGE_REPO/$MDCB_IMAGE_NAME:$MDCB_IMAGE_TAG"
    docker tag "$IMAGE_REPO/$MDCB_IMAGE_NAME:$MDCB_IMAGE_TAG" "$IMAGE_REPO/$MDCB_IMAGE_NAME:$MDCB_VALIDATION_IMAGE_TAG"
    kind load docker-image "$IMAGE_REPO/$MDCB_IMAGE_NAME:$MDCB_VALIDATION_IMAGE_TAG" --name kind
  fi
done

# pre-compute toxiproxy ports for each version before helmfile apply
log "Pre-computing toxiproxy ports for all versions..."
computePorts

# deploy all versions via helmfile
log "Deploying all versions via Helmfile..."
HELMFILE_ARGS=()
if [ "$USE_TOXIPROXY" = "true" ]; then
  HELMFILE_ARGS+=(--state-values-set "useToxiproxy=true")
fi

helmfile apply -q --suppress-diff --concurrency=0 "${HELMFILE_ARGS[@]+"${HELMFILE_ARGS[@]}"}"
log "Helmfile apply completed"

# label services and namespaces for toxiproxy/resilience test discovery (per version)
for topo_dir in "$VERSIONS_DIR"/*/; do
  [ -d "$topo_dir" ] || continue
  topo=$(basename "$topo_dir")
  version_file="${topo_dir}version.yaml"
  [ -f "$version_file" ] || continue

  NUM_DPS=$(read_version_field "$version_file" "numDataPlanes" "2")
  VI=$(read_version_field "$version_file" "versionIndex" "0")
  BAND=$((VI * 10000))
  CP_NS="tyk-${topo}"

  labelControlPlaneServices "$CP_NS"

  kubectl label namespace "$CP_NS" \
    tyk.io/role=control-plane \
    tyk.io/version="$topo" \
    tyk.io/version-index="$VI" \
    tyk.io/toxiproxy-port-redis="$((6379 + BAND))" \
    tyk.io/toxiproxy-port-mdcb="$((9091 + BAND))" \
    tyk.io/toxiproxy-port-mongo="$((27017 + BAND))" \
    tyk.io/toxiproxy-port-dashboard="$((3000 + BAND))" \
    tyk.io/toxiproxy-port-gateway="$((8080 + BAND))" \
    --overwrite > /dev/null

  for i in $(seq 1 "$NUM_DPS"); do
    DP_NS="tyk-${topo}-dp-${i}"
    DP_REDIS_PORT=$((7379 + BAND + i * 1000))

    labelDataPlaneServices "$i" "$DP_NS"

    kubectl label namespace "$DP_NS" \
      tyk.io/role=data-plane \
      tyk.io/version="$topo" \
      tyk.io/dp-index="$i" \
      tyk.io/toxiproxy-port-redis="$DP_REDIS_PORT" \
      --overwrite > /dev/null
  done
done

# populate toxiproxy after all services are running
if [ "$USE_TOXIPROXY" = "true" ]; then
  populateToxiProxy "$TOXIPROXY_URL" || {
    error "failed to configure toxiproxy"
    exit 1
  }
fi

# tools namespace
log "Creating $TOOLS_NAMESPACE namespace"
kubectl create namespace "$TOOLS_NAMESPACE" 2> /dev/null || true

log "Installing httpbin app in $TOOLS_NAMESPACE namespace"
kubectl apply -f ../apps/httpbin.yaml

log "Installing k6 load testing resources in $TOOLS_NAMESPACE namespace"
kubectl create configmap k6-test-script --from-file=test-script.js=../apps/test-script.js \
  -n "$TOOLS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f ../apps/k6.yaml
log "Successfully installed k6 load testing resources"

log "--> $0 Done"
