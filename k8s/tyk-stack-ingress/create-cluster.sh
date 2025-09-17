#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"

source lib.sh

KIND_NETWORK_NAME=${KIND_NETWORK_NAME:-kind}
KIND_CLOUD_PROVIDER_KIND_VERSION="v0.7.0"

function check_dependencies() {
  for cmd in kind docker; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
      error "$cmd is not installed or not in PATH"
      exit 1
    fi
  done
}

function create_kind_cluster() {
  local cluster_name=${1:-kind}

  if kind get clusters | grep -q "^${cluster_name}$"; then
    log "Kind cluster '$cluster_name' already exists. Skipping creation."
    return 0
  fi

  log "Creating kind cluster '$cluster_name'"

  cat << EOF | kind create cluster --name="$cluster_name" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF
}

function run_cloud_provider_kind() {
  local container_name="tyk-ci-cloud-provider-kind"

  if docker ps --format "{{.Names}}" | grep -q "$container_name"; then
    log "container '$container_name' is already running. recreating it"

    docker rm -f "$container_name"
    sleep 2
  fi

  log "running container '$container_name' for cloud-provider-kind/cloud-controller-manager image"

  docker run --network "$KIND_NETWORK_NAME" \
    --name "$container_name" \
    --detach \
    -v /var/run/docker.sock:/var/run/docker.sock \
    registry.k8s.io/cloud-provider-kind/cloud-controller-manager:"${KIND_CLOUD_PROVIDER_KIND_VERSION}" -enable-lb-port-mapping
}

check_dependencies
create_kind_cluster
run_cloud_provider_kind

log "--> $0 done"
