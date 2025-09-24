#!/usr/bin/env bash

set -euo pipefail

if [ -f .env ]; then
  source .env
fi

cd $(dirname $0)
source lib.sh

NUM_DATA_PLANES="${NUM_DATA_PLANES:-2}"
NGINX_TIMEOUT="${NGINX_TIMEOUT:-600s}"
TOXIPROXY_WAIT_TIMEOUT="${TOXIPROXY_WAIT_TIMEOUT:-120s}"
INGRESS_READY_TIMEOUT="${INGRESS_READY_TIMEOUT:-90s}"

# Parse named parameters
USE_TOXIPROXY="false"
for param in "$@"; do
  if [[ "$param" == "toxiproxy="* ]]; then
    USE_TOXIPROXY="${param#*=}"
  fi
done

if [[ -z "${TYK_MDCB_LICENSEKEY}" ]]; then
  error "TYK_MDCB_LICENSEKEY is not set. Please set it in the .env file or export it."
  exit 1
fi

if [[ -z "${TYK_DB_LICENSEKEY}" ]]; then
  error "TYK_DB_LICENSEKEY is not set. Please set it in the .env file or export it."
  exit 1
fi

NGINX_SVC_TYPE=${NGINX_SVC_TYPE:-"NodePort"}
DASH_IMAGE_TAG=${DASH_IMAGE_TAG:-"v5.2.1"}
GW_IMAGE_TAG=${GW_IMAGE_TAG:-"v5.2.1"}
IMAGE_REPO=${IMAGE_REPO:-"tykio"}

export DASH_IMAGE_TAG GW_IMAGE_TAG IMAGE_REPO

if [ "$USE_TOXIPROXY" = "true" ]; then
  log "Deploying with Toxiproxy enabled"
  # Set Toxiproxy-specific environment variables
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

log "deploy nginx helm chart"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add tyk-helm https://helm.tyk.io/public/helm/charts/
helm repo update

helm upgrade --install nginx ingress-nginx/ingress-nginx \
  --namespace tyk \
  --create-namespace \
  --set controller.service.type=$NGINX_SVC_TYPE \
  --wait \
  --timeout=$NGINX_TIMEOUT
if [ $? -ne 0 ]; then
  error "Failed to install/upgrade nginx ingress controller"
  exit 1
fi

log "----- nginx ingress controller successfully installed/upgraded -----"

# Deploy Toxiproxy if enabled
if [ "$USE_TOXIPROXY" = "true" ]; then
  log "----- Installing Toxiproxy -----"
  kubectl apply -f toxiproxy.yaml
  log "Waiting for Toxiproxy to be ready..."
  kubectl wait --namespace tyk --for=condition=available --timeout=$TOXIPROXY_WAIT_TIMEOUT deployment/toxiproxy || true
fi

log "----- Installing tyk-redis for control plane -----"
helm upgrade --install redis tyk-helm/simple-redis -n tyk --wait
if [ $? -ne 0 ]; then
  error "Failed to install tyk-redis for control plane"
  exit 1
fi

log "----- Installing tyk-mongo -----"
helm upgrade --install mongo tyk-helm/simple-mongodb -n tyk
if [ $? -ne 0 ]; then
  error "Failed to install mongo"
  exit 1
fi

log "----- Preparing to install tyk-control-plane and tyk-data-plane -----"

if [[ $IMAGE_REPO == 754489498669.dkr.ecr* ]]; then
  DASH_IMAGE_NAME="tyk-analytics"
  GW_IMAGE_NAME="tyk-ee"
  log "Creating ecrcred secret to access ECR repository $IMAGE_REPO"
  kubectl -n tyk create secret docker-registry ecrcred \
    --docker-server=754489498669.dkr.ecr.eu-central-1.amazonaws.com \
    --docker-username=AWS \
    --docker-password="$(aws ecr get-login-password --region eu-central-1)"
  # make the default SA use it
  kubectl -n tyk patch sa default -p '{"imagePullSecrets":[{"name":"ecrcred"}]}'
else
  log "Using official docker repo"
  GW_IMAGE_NAME="tyk-gateway"
  DASH_IMAGE_NAME="tyk-dashboard"
fi

log "----- Waiting until ingress will be ready -----"
kubectl wait --namespace tyk \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=$INGRESS_READY_TIMEOUT

log "----- Installing tyk-control-plane -----"
log "Using Repo: $IMAGE_REPO Gateway: $GW_IMAGE_TAG, Dashboard: $DASH_IMAGE_TAG"

helm upgrade --install -n tyk tyk-control-plane tyk-helm/tyk-control-plane -f ./control-plane-values.yaml \
  --set global.license.dashboard="$TYK_DB_LICENSEKEY" \
  --set global.storageType="mongo" \
  --set tyk-mdcb.mdcb.license="$TYK_MDCB_LICENSEKEY" \
  --set tyk-gateway.gateway.image.repository="$IMAGE_REPO/$GW_IMAGE_NAME" \
  --set tyk-gateway.gateway.image.tag="$GW_IMAGE_TAG" \
  --set tyk-dashboard.dashboard.image.repository="$IMAGE_REPO/$DASH_IMAGE_NAME" \
  --set tyk-dashboard.dashboard.image.tag="$DASH_IMAGE_TAG" \
  --set global.redis.addrs[0]="$REDIS_URL" \
  --set global.mongo.mongoURL="$MONGO_URL" \
  --set tyk-gateway.gateway.useDashboardAppConfig.dashboardConnectionString="$DASHBOARD_URL" --wait

if [ $? -ne 0 ]; then
  error "Failed to install tyk-control-plane"
  exit 1
fi

# Get the Organization ID and API secret
export ORG_ID=$(kubectl get secret --namespace tyk tyk-operator-conf -o jsonpath="{.data.TYK_ORG}" | base64 --decode)
export USER_API_KEY=$(kubectl get secret --namespace tyk tyk-operator-conf -o jsonpath="{.data.TYK_AUTH}" | base64 --decode)

log "----- Creating secret for data plane in tyk namespace -----"

# Install data planes in a loop
for i in $(seq 1 $NUM_DATA_PLANES); do
  # Set the appropriate Redis URL for this data plane
  if [ "$USE_TOXIPROXY" = "true" ]; then
    if [ "$i" -eq 1 ]; then
      DP_REDIS_URL="toxiproxy.tyk.svc:8379"
    else
      DP_REDIS_URL="toxiproxy.tyk.svc:9379"
    fi
  else
    DP_REDIS_URL="redis.tyk-dp-${i}.svc:6379"
  fi

  log "----- Installing tyk-data-plane in tyk-dp-${i} namespace -----"
  log "----- Using Redis URL: ${DP_REDIS_URL} -----"

  # Create namespace (ignore error if already exists)
  kubectl create namespace tyk-dp-${i} || true

  # Create secret for data plane
  kubectl -n tyk-dp-${i} create secret generic tyk-data-plane-secret \
    --from-literal=orgId="$ORG_ID" \
    --from-literal=userApiKey="$USER_API_KEY" \
    --from-literal=groupID="data-plane-${i}" \
    --from-literal=APISecret="352d20ee67be67f6340b4c0605b044b7" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Install Redis for this data plane
  helm upgrade --install redis tyk-helm/simple-redis -n tyk-dp-${i} --wait

  # Install data plane
  helm upgrade --install -n tyk-dp-${i} tyk-data-plane tyk-helm/tyk-data-plane -f ./data-plane-values.yaml \
    --set tyk-gateway.gateway.replicaCount=${i} \
    --set global.remoteControlPlane.useSecretName="tyk-data-plane-secret" \
    --set global.secrets.useSecretName="tyk-data-plane-secret" \
    --set tyk-gateway.gateway.image.repository="$IMAGE_REPO/$GW_IMAGE_NAME" \
    --set tyk-gateway.gateway.image.tag="$GW_IMAGE_TAG" \
    --set global.redis.addrs[0]="$DP_REDIS_URL" \
    --set global.remoteControlPlane.connectionString="$MDCB_CONNECTIONSTRING" \
    --set tyk-gateway.gateway.ingress.hosts[0].host="chart-gw-dp-${i}.local" \
    --set tyk-gateway.gateway.ingress.className="nginx" --wait

  log "----- Successfully installed tyk-data-plane-${i} -----"

done

log "----- Creating tools namespace -----"
kubectl create namespace tools || true

log "----- Installing Flask upstream app in tools namespace -----"
kubectl apply -f flask-upstream.yaml
if [ $? -ne 0 ]; then
  error "Failed to install Flask upstream app in tools namespace"
  exit 1
fi
log "Flask upstream app deployed successfully at flask-upstream.tools.svc:5000/upstream"

log "----- Installing k6 load testing resources in tools namespace -----"
kubectl apply -f k6.yaml
if [ $? -ne 0 ]; then
  error "Failed to install k6 load testing resources"
  exit 1
fi
log "----- Successfully installed k6 load testing resources -----"
log "To run a test, use the run-k6-test-custom task with parameters"

log "--> $0 Done"
