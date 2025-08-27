#!/bin/bash
if [ -f .env ]; then
    source .env
fi

kubectl create namespace tyk

echo "Instaling ingress-nginx"
kubectl apply -f nginx.yml --wait

echo "----- Installing tyk-redis -----"
helm install redis tyk-helm/simple-redis -n tyk --wait
if [ $? -ne 0 ]; then
    echo "Failed to install tyk-redis"
    exit 1
fi

echo "----- Installing tyk-mongo -----"
helm install mongo tyk-helm/simple-mongodb -n tyk
if [ $? -ne 0 ]; then
    echo "Failed to install mongo"
    exit 1
fi

echo "----- Preparing to install tyk-stack -----"
if [[ -z "${DASH_IMAGE_TAG}" ]]; then
    export DASH_IMAGE_TAG="v5.2.1"
    echo "=======> Warning: DASH_IMAGE_TAG was not set. Defaulting to 'v5.2.1'."
fi

if [[ -z "${GW_IMAGE_TAG}" ]]; then
    export GW_IMAGE_TAG="v5.2.1"
    echo "=======> Warning: DASH_IMAGE_TAG was not set. Defaulting to 'v5.2.1'."
fi

if [[ -z "${IMAGE_REPO}" ]]; then
    export IMAGE_REPO="tykio"
    echo "=======> Warning: IMAGE_TAG was not set. Defaulting to 'tykio'."
fi

if [[ $IMAGE_REPO == 754489498669.dkr.ecr* ]]; then
    #we need to pull the image and load it into kind this way until TT-11705 is not fixed
    docker pull 754489498669.dkr.ecr.eu-central-1.amazonaws.com/tyk-analytics:$DASH_IMAGE_TAG
    docker tag 754489498669.dkr.ecr.eu-central-1.amazonaws.com/tyk-analytics:$DASH_IMAGE_TAG 754489498669.dkr.ecr.eu-central-1.amazonaws.com/tyk-analytics:v10
    kind load docker-image 754489498669.dkr.ecr.eu-central-1.amazonaws.com/tyk-analytics:v10
    DASH_IMAGE_TAG="v10"
    DASH_IMAGE_NAME="tyk-analytics"
    GW_IMAGE_NAME="tyk"
    echo "Creating ecrcred secret to access ECR repository $IMAGE_REPO"
    kubectl create secret docker-registry ecrcred -n tyk \
    --docker-server=754489498669.dkr.ecr.eu-central-1.amazonaws.com \
    --docker-username=AWS \
    --docker-password=$(aws ecr get-login-password --region eu-central-1)
else
    echo "Using oficial docker repo"
    GW_IMAGE_NAME="tyk-gateway"
    DASH_IMAGE_NAME="tyk-dashboard"
fi

echo "----- Waiting until ingress will be ready -----"
kubectl wait --namespace tyk \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s

echo "----- Installing tyk-stack -----"
echo "Using Repo: $IMAGE_REPO Gateway: $GW_IMAGE_TAG, Dashboard: $DASH_IMAGE_TAG"
helm -n tyk install tyk-stack tyk-helm/tyk-stack -f ./values-tyk-stack.yaml --set global.license.dashboard="$TYK_DB_LICENSEKEY" \
    --set tyk-gateway.gateway.image.repository="$IMAGE_REPO/$GW_IMAGE_NAME" \
    --set tyk-gateway.gateway.image.tag="$GW_IMAGE_TAG" \
    --set tyk-dashboard.dashboard.image.repository="$IMAGE_REPO/$DASH_IMAGE_NAME" \
    --set tyk-dashboard.dashboard.image.tag="$DASH_IMAGE_TAG" --wait

if [ $? -ne 0 ]; then
    echo "Failed to install tyk-stack"
    exit 1
fi

echo "Done"