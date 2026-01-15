#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"
source lib.sh

######################################
# Script: setup.sh
# Purpose: Single command to deploy complete K8s testing infrastructure
# Usage:   setup.sh [--toxiproxy]
######################################

USE_TOXIPROXY="false"
for param in "$@"; do
  if [[ "$param" == "--toxiproxy" ]]; then
    USE_TOXIPROXY="true"
  elif [[ "$param" == "-h" ]] || [[ "$param" == "--help" ]]; then
    echo "Usage: $0 [--toxiproxy]"
    echo ""
    echo "  --toxiproxy    Deploy Toxiproxy for resilience testing"
    echo ""
    echo "This script deploys a complete Kubernetes testing infrastructure:"
    echo "  - Kind cluster with cloud-provider-kind"
    echo "  - Ingress controller (LoadBalancer)"
    echo "  - Tyk control plane (Dashboard, MDCB, Gateway, Redis, MongoDB)"
    echo "  - N data planes (default: 2)"
    echo "  - k8s-hosts-controller (for /etc/hosts management)"
    echo "  - Toxiproxy (optional, for resilience testing)"
    echo ""
    echo "All operations are idempotent - safe to run multiple times."
    exit 0
  fi
done

check_prerequisites() {
  log "Checking prerequisites..."

  local missing=()

  if ! command -v docker > /dev/null 2>&1; then
    missing+=("docker")
  fi

  if ! docker info > /dev/null 2>&1; then
    err "Docker is not running"
    exit 1
  fi

  if ! command -v kubectl > /dev/null 2>&1; then
    missing+=("kubectl")
  fi

  if ! command -v kind > /dev/null 2>&1; then
    missing+=("kind")
  fi

  if [[ -z "${TYK_DB_LICENSEKEY:-}" ]] && [[ -z "${TYK_MDCB_LICENSEKEY:-}" ]]; then
    if [[ ! -f .env ]]; then
      err "License keys not found"
      err "Either set TYK_DB_LICENSEKEY and TYK_MDCB_LICENSEKEY environment variables"
      err "Or create a .env file with these keys"
      exit 1
    fi
  fi

  get_binary_path "hosts-controller-manager.sh" || {
    err "failed to find hosts-controller-manager.sh in $PATH and /usr/local/bin"
  }

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools: ${missing[*]}"
    err "Please install them before running this script"
    exit 1
  fi

  log "Prerequisites check passed"
}

main_dep_check() {
  check_prerequisites
  local num_data_planes="${NUM_DATA_PLANES:-2}"
  if [[ ! "$num_data_planes" =~ ^[0-9]+$ ]] || [[ "$num_data_planes" -lt 1 ]]; then
    err "NUM_DATA_PLANES must be a positive integer (current: $num_data_planes)"
    exit 1
  fi
}

main() {
  echo "#####################################"
  echo "Tyk K8s Testing Infrastructure Setup"
  echo "#####################################"

  if [[ -f .env ]]; then
    log "Loading .env file..."
    source .env
  else
    warning "no .env file found in $(pwd)."
    warnig "the script will fail if required environment variables are not sourced"
  fi

  main_dep_check
  echo ""
  echo "####################################################"
  echo "#  This script requires administrative privileges  #"
  echo "#  to start the k8s-hosts-controller.              #"
  echo "#                                                  #"
  echo "#  The controller manages /etc/hosts entries.      #"
  echo "####################################################"
  echo ""
  check_sudo_access

  echo "########################"
  echo "Creating Kind cluster..."
  echo "########################"
  ./create-cluster.sh || {
    err "Failed to create Kind cluster"
    exit 1
  }

  echo "#######################"
  echo "Deploying Tyk stack..."
  echo "#######################"

  local toxiproxy_param=""
  if [[ "$USE_TOXIPROXY" == "true" ]]; then
    toxiproxy_param="toxiproxy=true"
  fi

  ./run-tyk-cp-dp.sh $toxiproxy_param || {
    err "Failed to deploy Tyk stack"
    exit 1
  }

  log "#################################"
  log "Starting k8s-hosts-controller..."
  log "#################################"
  if hosts-controller-manager.sh restart; then
    echo "####################################################"
    echo "k8s-hosts-controller is now running in the background"
    echo ""
    echo "It manages /etc/hosts entries for K8s ingress hostnames"
    echo "Log file: /tmp/k8s-hosts-controller.log"
    echo ""
    echo "To check status later, run:"
    echo "  hosts-controller-manager.sh status"
    echo ""
    echo "To stop it when done, run:"
    echo "  hosts-controller-manager.sh stop"
    echo ""
    echo "To cleanup /etc/hosts entries, run:"
    echo "  hosts-controller-manager.sh cleanup"
    echo "####################################################"
  else
    err "Failed to start k8s-hosts-controller"
    err "Your cluster is deployed but /etc/hosts entries won't be managed"
    err "You'll need to manually manage hosts entries or fix the issue"
    exit 1
  fi

  echo""
  log "################################################"
  log "Setup complete! Your K8s environment is ready."
  log "################################################"
  echo""
  if [[ "$USE_TOXIPROXY" == "true" ]]; then
    log "Toxiproxy environment variables saved to: $(pwd)/toxiproxy-ci.env"
    log ""
    log "Test configuration:"
    log "  source toxiproxy-ci.env"
  fi

  echo ""
  echo "####################################################"
  echo "When you're done working, don't forget to cleanup:"
  echo ""
  echo "hosts-controller-manager.sh stop"
  echo "hosts-controller-manager.sh cleanup"
  echo "kind delete cluster # deletes the k8s cluster"
  echo "####################################################"
}

main "$@"
