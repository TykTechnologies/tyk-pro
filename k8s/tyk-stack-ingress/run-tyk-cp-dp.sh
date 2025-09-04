#!/bin/bash
if [ -f .env ]; then
    source .env
fi

# Parse named parameters
USE_TOXIPROXY="false"
for param in "$@"; do
    if [[ "$param" == "toxiproxy="* ]]; then
        USE_TOXIPROXY="${param#*=}"
    fi
done

if [ "$USE_TOXIPROXY" = "true" ]; then
    echo "Deploying with Toxiproxy enabled"
else
    echo "Deploying without Toxiproxy"
fi

# Create namespaces
kubectl create namespace tyk
kubectl create namespace tyk-dp

echo "Installing ingress-nginx"
kubectl apply -f nginx.yml --wait

# Deploy Toxiproxy if enabled
if [ "$USE_TOXIPROXY" = "true" ]; then
    echo "----- Installing Toxiproxy -----"
    kubectl apply -f toxiproxy.yaml
    echo "Waiting for Toxiproxy to be ready..."
    kubectl wait --namespace tyk --for=condition=available --timeout=120s deployment/toxiproxy || true
fi

echo "----- Installing tyk-redis for control plane -----"
helm install redis tyk-helm/simple-redis -n tyk --wait
if [ $? -ne 0 ]; then
    echo "Failed to install tyk-redis for control plane"
    exit 1
fi

echo "----- Installing tyk-mongo -----"
helm install mongo tyk-helm/simple-mongodb -n tyk
if [ $? -ne 0 ]; then
    echo "Failed to install mongo"
    exit 1
fi

echo "----- Preparing to install tyk-control-plane and tyk-data-plane -----"
if [[ -z "${DASH_IMAGE_TAG}" ]]; then
    export DASH_IMAGE_TAG="v5.2.1"
    echo "=======> Warning: DASH_IMAGE_TAG was not set. Defaulting to 'v5.2.1'."
fi

if [[ -z "${GW_IMAGE_TAG}" ]]; then
    export GW_IMAGE_TAG="v5.2.1"
    echo "=======> Warning: GW_IMAGE_TAG was not set. Defaulting to 'v5.2.1'."
fi

if [[ -z "${IMAGE_REPO}" ]]; then
    export IMAGE_REPO="tykio"
    echo "=======> Warning: IMAGE_REPO was not set. Defaulting to 'tykio'."
fi

if [[ -z "${TYK_MDCB_LICENSEKEY}" ]]; then
    echo "=======> Error: TYK_MDCB_LICENSEKEY is not set. Please set it in the .env file or export it."
    exit 1
fi

if [[ $IMAGE_REPO == 754489498669.dkr.ecr* ]]; then
    DASH_IMAGE_NAME="tyk-analytics"
    GW_IMAGE_NAME="tyk-ee"
    echo "Creating ecrcred secret to access ECR repository $IMAGE_REPO"
kubectl -n tyk create secret docker-registry ecrcred \
  --docker-server=754489498669.dkr.ecr.eu-central-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region eu-central-1)"
# make the default SA use it
kubectl -n tyk patch sa default -p '{"imagePullSecrets":[{"name":"ecrcred"}]}'
else
    echo "Using official docker repo"
    GW_IMAGE_NAME="tyk-gateway"
    DASH_IMAGE_NAME="tyk-dashboard"
fi

echo "----- Waiting until ingress will be ready -----"
kubectl wait --namespace tyk \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s

echo "----- Installing tyk-control-plane -----"
echo "Using Repo: $IMAGE_REPO Gateway: $GW_IMAGE_TAG, Dashboard: $DASH_IMAGE_TAG"

# Install control plane with or without Toxiproxy
if [ "$USE_TOXIPROXY" = "true" ]; then
    # Install with Toxiproxy
    helm -n tyk install tyk-control-plane tyk-helm/tyk-control-plane -f ./control-plane-values.yaml \
        --set global.license.dashboard="$TYK_DB_LICENSEKEY" \
        --set global.storageType="mongo" \
        --set tyk-mdcb.mdcb.license="$TYK_MDCB_LICENSEKEY" \
        --set tyk-gateway.gateway.image.repository="$IMAGE_REPO/$GW_IMAGE_NAME" \
        --set tyk-gateway.gateway.image.tag="$GW_IMAGE_TAG" \
        --set tyk-dashboard.dashboard.image.repository="$IMAGE_REPO/$DASH_IMAGE_NAME" \
        --set tyk-dashboard.dashboard.image.tag="$DASH_IMAGE_TAG" \
        --set global.redis.addrs[0]="toxiproxy.tyk.svc:6379" \
        --set global.mongo.mongoURL="mongodb://toxiproxy.tyk.svc:27017/tyk_analytics" --wait
else
    # Install without Toxiproxy
    helm -n tyk install tyk-control-plane tyk-helm/tyk-control-plane -f ./control-plane-values.yaml \
        --set global.license.dashboard="$TYK_DB_LICENSEKEY" \
        --set global.storageType="mongo" \
        --set tyk-mdcb.mdcb.license="$TYK_MDCB_LICENSEKEY" \
        --set tyk-gateway.gateway.image.repository="$IMAGE_REPO/$GW_IMAGE_NAME" \
        --set tyk-gateway.gateway.image.tag="$GW_IMAGE_TAG" \
        --set tyk-dashboard.dashboard.image.repository="$IMAGE_REPO/$DASH_IMAGE_NAME" \
        --set tyk-dashboard.dashboard.image.tag="$DASH_IMAGE_TAG" --wait
fi

if [ $? -ne 0 ]; then
    echo "Failed to install tyk-control-plane"
    exit 1
fi

echo "----- Installing Redis for data plane -----"
helm install redis tyk-helm/simple-redis -n tyk-dp --wait
if [ $? -ne 0 ]; then
    echo "Failed to install Redis for data plane"
    exit 1
fi

# Get the Organization ID and API secret
export ORG_ID=$(kubectl get secret --namespace tyk tyk-operator-conf -o jsonpath="{.data.TYK_ORG}" | base64 --decode)
export USER_API_KEY=$(kubectl get secret --namespace tyk tyk-operator-conf -o jsonpath="{.data.TYK_AUTH}" | base64 --decode)

echo "----- Creating secret for data plane -----"
# Create a secret with all the necessary data for the data plane
kubectl -n tyk-dp create secret generic tyk-data-plane-secret \
    --from-literal=orgId="$ORG_ID" \
    --from-literal=userApiKey="$USER_API_KEY" \
    --from-literal=groupID="data-plane-1" \
    --from-literal=APISecret="352d20ee67be67f6340b4c0605b044b7"

echo "----- Installing tyk-data-plane in tyk-dp namespace -----"
if [ "$USE_TOXIPROXY" = "true" ]; then
    # Install with Toxiproxy
    helm -n tyk-dp install tyk-data-plane tyk-helm/tyk-data-plane -f ./data-plane-values.yaml \
        --set global.redis.addrs[0]="toxiproxy.tyk.svc:8379" \
        --set global.remoteControlPlane.connectionString="toxiproxy.tyk.svc:9091" \
        --set global.remoteControlPlane.useSecretName="tyk-data-plane-secret" \
        --set global.secrets.useSecretName="tyk-data-plane-secret" \
        --set tyk-gateway.gateway.image.repository="$IMAGE_REPO/$GW_IMAGE_NAME" \
        --set tyk-gateway.gateway.image.tag="$GW_IMAGE_TAG" --wait
else
    # Install without Toxiproxy
    helm -n tyk-dp install tyk-data-plane tyk-helm/tyk-data-plane -f ./data-plane-values.yaml \
        --set global.redis.addrs[0]="redis.tyk-dp.svc:6379" \
        --set global.remoteControlPlane.connectionString="mdcb-svc-tyk-control-plane-tyk-mdcb.tyk.svc:9091" \
        --set global.remoteControlPlane.useSecretName="tyk-data-plane-secret" \
        --set global.secrets.useSecretName="tyk-data-plane-secret" \
        --set tyk-gateway.gateway.image.repository="$IMAGE_REPO/$GW_IMAGE_NAME" \
        --set tyk-gateway.gateway.image.tag="$GW_IMAGE_TAG" --wait
fi

if [ $? -ne 0 ]; then
    echo "Failed to install tyk-data-plane"
    exit 1
fi

echo "Done"