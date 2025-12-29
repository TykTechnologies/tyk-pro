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
if [[ -z "${TYK_MDCB_LICENSEKEY}" ]]; then
  error "TYK_MDCB_LICENSEKEY is not set. Please set it in the .env file or export it."
  exit 1
fi
if [[ -z "${TYK_DB_LICENSEKEY}" ]]; then
  error "TYK_DB_LICENSEKEY is not set. Please set it in the .env file or export it."
  exit 1
fi

######################################
# global configurations
######################################
NUM_DATA_PLANES="${NUM_DATA_PLANES:-2}"
NGINX_TIMEOUT="${NGINX_TIMEOUT:-600s}"
TOXIPROXY_WAIT_TIMEOUT="${TOXIPROXY_WAIT_TIMEOUT:-120s}"
INGRESS_READY_TIMEOUT="${INGRESS_READY_TIMEOUT:-90s}"
ENABLE_PUMP="${ENABLE_PUMP:-true}"
TYK_PRO_ROOT="$(cd ../.. && pwd)"

CP_NAMESPACE="tyk"
DP_NAMESPACE_PREFIX="tyk-dp"
TOOLS_NAMESPACE="tools"
dp_namespace() {
  echo "${DP_NAMESPACE_PREFIX}-${1}"
}

USE_TOXIPROXY="false"
for param in "$@"; do
  if [[ "$param" == "toxiproxy="* ]]; then
    USE_TOXIPROXY="${param#*=}"
  fi
done

export DASH_IMAGE_TAG=${DASH_IMAGE_TAG:-"v5.2.1"}
export GW_IMAGE_TAG=${GW_IMAGE_TAG:-"v5.2.1"}
export IMAGE_REPO=${IMAGE_REPO:-"tykio"}
if [ "$USE_TOXIPROXY" = "true" ]; then
  log "Deploying with Toxiproxy enabled"
  export REDIS_URL="toxiproxy.tyk.svc:6379"
  export MONGO_URL="mongodb://toxiproxy.tyk.svc:27017/tyk_analytics"
  export DASHBOARD_URL="http://toxiproxy.tyk.svc:3000"
  export MDCB_CONNECTIONSTRING="toxiproxy.tyk.svc:9091"
else
  log "Deploying without Toxiproxy"
  export REDIS_URL="redis.tyk.svc:6379"
  export MONGO_URL="mongodb://mongo.tyk.svc:27017/tyk_analytics"
  export DASHBOARD_URL="http://dashboard-svc-tyk-control-plane-tyk-dashboard.tyk.svc:3000"
  export MDCB_CONNECTIONSTRING="mdcb-svc-tyk-control-plane-tyk-mdcb.tyk.svc:9091"
fi

deployNginx() {
  NGINX_SVC_TYPE=${NGINX_SVC_TYPE:-"NodePort"}

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo add tyk-helm https://helm.tyk.io/public/helm/charts/
  helm repo update

  log "nginx svc type is $NGINX_SVC_TYPE"

  helm upgrade --install nginx ingress-nginx/ingress-nginx \
    --namespace "$CP_NAMESPACE" \
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
    --timeout="$NGINX_TIMEOUT"
  if [ $? -ne 0 ]; then
    return 1
  fi

  kubectl wait --namespace "$CP_NAMESPACE" \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout="$INGRESS_READY_TIMEOUT"
}

deployToxiProxy() {
  kubectl apply -f ../apps/toxiproxy.yaml
  log "Waiting for Toxiproxy deployment to be ready..."
  kubectl wait --namespace "$CP_NAMESPACE" --for=condition=available --timeout="$TOXIPROXY_WAIT_TIMEOUT" deployment/toxiproxy || true

  log "Waiting for Toxiproxy LoadBalancer IP..."
  TOXIPROXY_IP=""
  for attempt in $(seq 1 30); do
    TOXIPROXY_IP=$(kubectl get svc toxiproxy -n "$CP_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2> /dev/null || true)
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

deployControlPlaneRedis() {
  log "----- Installing tyk-redis for control plane -----"
  helm upgrade --install redis tyk-helm/simple-redis -n "$CP_NAMESPACE" --wait

  if [ $? -ne 0 ]; then
    return 1
  fi
}

deployMongo() {
  log "----- Installing tyk-mongo -----"
  helm upgrade --install mongo tyk-helm/simple-mongodb -n "$CP_NAMESPACE" --wait

  if [ $? -ne 0 ]; then
    return 1
  fi
}

# labelService <namespace> <service-name-pattern> <component>
labelService() {
  local namespace="${1:?namespace required}"
  local pattern="${2:?pattern required}"
  local component="${3:?component required}"

  local svc_name
  svc_name=$(kubectl get svc -n "$namespace" -o name 2> /dev/null | grep "$pattern" | head -1)
  if [ -n "$svc_name" ]; then
    kubectl label "$svc_name" -n "$namespace" tyk.io/component="$component" --overwrite
    log "Labeled $svc_name with tyk.io/component=$component"
  fi
}

labelControlPlaneServices() {
  log "Labeling control plane services for discovery..."
  local namespace="$CP_NAMESPACE"

  labelService "$namespace" "dashboard-svc" "dashboard"
  labelService "$namespace" "gateway-svc" "gateway"
  labelService "$namespace" "mdcb-svc" "mdcb"
  labelService "$namespace" "pump-svc" "pump"
}

labelDataPlaneServices() {
  local dp_index="${1:?dp_index required}"
  log "Labeling data plane $dp_index services for discovery..."
  local namespace
  namespace=$(dp_namespace "$dp_index")

  labelService "$namespace" "gateway-svc" "gateway"
  kubectl label svc/redis -n "$namespace" tyk.io/component=redis --overwrite
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

  python3 "$cli_path" configure \
    --toxiproxy-url "$toxiproxy_url" \
    --namespace-pattern "${DP_NAMESPACE_PREFIX}-*" \
    --control-namespace "$CP_NAMESPACE" \
    --verbose \
    --output-env github-actions > toxiproxy-ci.env
  if [ $? -ne 0 ]; then
    return 1
  fi

  log "Toxiproxy configured successfully"
  log "Environment variables saved to toxiproxy-ci.env"
}

log "deploying nginx helm chart"
deployNginx || {
  error "failed to deploy nginx helm chart"
  exit 1
}
log "successfully deployed nginx ingress controller"

# note that infra needs to be deployed before deploying and populating toxiproxy
# since toxiproxy works as a proxy for infra workloads.
deployControlPlaneRedis || {
  error "failed to deploy redis"
  exit 1
}

deployMongo || {
  error "failed to deploy mongo"
  exit 1
}

kubectl label svc/redis -n "$CP_NAMESPACE" tyk.io/component=redis --overwrite > /dev/null 2>&1
kubectl label svc/mongo -n "$CP_NAMESPACE" tyk.io/component=mongo --overwrite > /dev/null 2>&1

if [ "$USE_TOXIPROXY" = "true" ]; then
  log "deploying toxiproxy for resilience tests"
  deployToxiProxy || {
    error "failed to deploy toxiproxy"
    exit 1
  }
  log "Configuring toxiproxy for control plane dependencies (redis, mongo)..."
  populateToxiProxy "$TOXIPROXY_URL" || {
    error "failed to populate toxiproxy"
    exit 1
  }
fi

log "----- Preparing to install tyk-control-plane and tyk-data-plane -----"

if [[ $IMAGE_REPO == 754489498669.dkr.ecr* ]]; then
  DASH_IMAGE_NAME="tyk-analytics"
  GW_IMAGE_NAME="tyk-ee"
  MDCB_IMAGE_NAME="tyk-sink"
  MDCB_IMAGE_TAG=${MDCB_IMAGE_TAG:-"master"}
  MDCB_VALIDATION_IMAGE_TAG="v10.0.0" # a valid semver to pass version validation
  log "Creating ecrcred secret to access ECR repository $IMAGE_REPO"
  kubectl -n "$CP_NAMESPACE" create secret docker-registry ecrcred \
    --docker-server=754489498669.dkr.ecr.eu-central-1.amazonaws.com \
    --docker-username=AWS \
    --docker-password="$(aws ecr get-login-password --region eu-central-1)"
  # make the default SA use it
  kubectl -n "$CP_NAMESPACE" patch sa default -p '{"imagePullSecrets":[{"name":"ecrcred"}]}'
  log "Pulling MDCB image"
  # due to version validation in MDCB chart we need to have the image locally available
  # Pull the master image but tag it with a valid semantic version to pass validation
  docker pull "$IMAGE_REPO/$MDCB_IMAGE_NAME:$MDCB_IMAGE_TAG"
  docker tag "$IMAGE_REPO/$MDCB_IMAGE_NAME:$MDCB_IMAGE_TAG" "$IMAGE_REPO/$MDCB_IMAGE_NAME:$MDCB_VALIDATION_IMAGE_TAG"
  kind load docker-image "$IMAGE_REPO/$MDCB_IMAGE_NAME:$MDCB_VALIDATION_IMAGE_TAG" --name kind
else
  log "Using official docker repo"
  GW_IMAGE_NAME="tyk-gateway"
  DASH_IMAGE_NAME="tyk-dashboard"
  MDCB_IMAGE_NAME="tyk-mdcb-docker"
  MDCB_VALIDATION_IMAGE_TAG=${MDCB_IMAGE_TAG:-"v2.8.0"}
fi

log "----- Installing tyk-control-plane -----"
log "Using Repo: $IMAGE_REPO Gateway: $GW_IMAGE_TAG, Dashboard: $DASH_IMAGE_TAG"

helm upgrade --install -n "$CP_NAMESPACE" tyk-control-plane tyk-helm/tyk-control-plane -f ./manifests/control-plane-values.yaml \
  --set global.license.dashboard="$TYK_DB_LICENSEKEY" \
  --set global.storageType="mongo" \
  --set tyk-mdcb.mdcb.license="$TYK_MDCB_LICENSEKEY" \
  --set tyk-gateway.gateway.image.repository="$IMAGE_REPO/$GW_IMAGE_NAME" \
  --set tyk-gateway.gateway.image.tag="$GW_IMAGE_TAG" \
  --set tyk-dashboard.dashboard.image.repository="$IMAGE_REPO/$DASH_IMAGE_NAME" \
  --set tyk-dashboard.dashboard.image.tag="$DASH_IMAGE_TAG" \
  --set tyk-mdcb.mdcb.image.repository="$IMAGE_REPO/$MDCB_IMAGE_NAME" \
  --set tyk-mdcb.mdcb.image.tag="$MDCB_VALIDATION_IMAGE_TAG" \
  --set global.redis.addrs[0]="$REDIS_URL" \
  --set global.mongo.mongoURL="$MONGO_URL" \
  --set global.components.pump="$ENABLE_PUMP" \
  --set tyk-gateway.gateway.useDashboardAppConfig.dashboardConnectionString="$DASHBOARD_URL" \
  --wait \
  --atomic
if [ $? -ne 0 ]; then
  error "Failed to install tyk-control-plane"
  exit 1
fi

labelControlPlaneServices

export ORG_ID=$(kubectl get secret --namespace "$CP_NAMESPACE" tyk-operator-conf -o jsonpath="{.data.TYK_ORG}" | base64 --decode)
export USER_API_KEY=$(kubectl get secret --namespace "$CP_NAMESPACE" tyk-operator-conf -o jsonpath="{.data.TYK_AUTH}" | base64 --decode)

log "----- Creating secret for data plane in tyk namespace -----"

# Install data planes in a loop
for i in $(seq 1 "$NUM_DATA_PLANES"); do
  # Set the appropriate Redis URL for this data plane
  # port scheme: dp-1 -> 8379, dp-2 -> 9379, dp-3 -> 10379, etc. (7379 + i*1000)
  if [ "$USE_TOXIPROXY" = "true" ]; then
    DP_REDIS_PORT=$((7379 + i * 1000))
    DP_REDIS_URL="toxiproxy.tyk.svc:${DP_REDIS_PORT}"
  else
    DP_REDIS_URL="redis.$(dp_namespace "$i").svc:6379"
  fi

  log "----- Installing tyk-data-plane in $(dp_namespace "$i") namespace -----"
  log "----- Using Redis URL: ${DP_REDIS_URL} -----"

  kubectl create namespace "$(dp_namespace "$i")" || true

  kubectl -n "$(dp_namespace "$i")" create secret generic tyk-data-plane-secret \
    --from-literal=orgId="$ORG_ID" \
    --from-literal=userApiKey="$USER_API_KEY" \
    --from-literal=groupID="data-plane-${i}" \
    --from-literal=APISecret="352d20ee67be67f6340b4c0605b044b7" \
    --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install redis tyk-helm/simple-redis -n "$(dp_namespace $i)" --wait
  kubectl label svc/redis -n "$(dp_namespace "$i")" tyk.io/component=redis --overwrite > /dev/null 2>&1
  populateToxiProxy "$TOXIPROXY_URL"

  helm upgrade --install -n "$(dp_namespace "$i")" tyk-data-plane tyk-helm/tyk-data-plane -f ./manifests/data-plane-values.yaml \
    --set tyk-gateway.gateway.replicaCount=${i} \
    --set global.remoteControlPlane.useSecretName="tyk-data-plane-secret" \
    --set global.secrets.useSecretName="tyk-data-plane-secret" \
    --set tyk-gateway.gateway.image.repository="$IMAGE_REPO/$GW_IMAGE_NAME" \
    --set tyk-gateway.gateway.image.tag="$GW_IMAGE_TAG" \
    --set global.redis.addrs[0]="$DP_REDIS_URL" \
    --set global.remoteControlPlane.connectionString="$MDCB_CONNECTIONSTRING" \
    --set tyk-gateway.gateway.ingress.hosts[0].host="chart-gw-dp-${i}.local" \
    --set tyk-gateway.gateway.ingress.className="nginx" --wait
  labelDataPlaneServices "$i"
  populateToxiProxy "$TOXIPROXY_URL"

  log "----- Successfully installed tyk-data-plane in $(dp_namespace "$i") -----"
done

log "----- Creating $TOOLS_NAMESPACE namespace -----"
kubectl create namespace "$TOOLS_NAMESPACE" || true

log "----- Installing httpbin app in $TOOLS_NAMESPACE namespace -----"
kubectl apply -f ../apps/httpbin.yaml
if [ $? -ne 0 ]; then
  error "Failed to install httpbin app in $TOOLS_NAMESPACE namespace"
  exit 1
fi
log "httpbin app deployed successfully at httpbin.$TOOLS_NAMESPACE.svc:8080/get"

log "----- Installing k6 load testing resources in $TOOLS_NAMESPACE namespace -----"
# Create ConfigMap from the external script file
kubectl create configmap k6-test-script --from-file=test-script.js=../apps/test-script.js -n "$TOOLS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
if [ $? -ne 0 ]; then
  error "Failed to create k6 test script ConfigMap"
  exit 1
fi

# Apply the k6 deployment
kubectl apply -f ../apps/k6.yaml
if [ $? -ne 0 ]; then
  error "Failed to install k6 load testing resources"
  exit 1
fi
log "----- Successfully installed k6 load testing resources -----"
log "To run a test, use the run-k6-test-custom task with parameters"

log "--> $0 Done"
