#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"
source lib.sh

######################################
# Script: setup.sh
# Purpose: Single command to deploy complete K8s testing infrastructure
# Usage:   setup.sh [--toxiproxy]
######################################

# Parse arguments
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

######################################
# Prerequisites Check
######################################
check_prerequisites() {
  log "Checking prerequisites..."

  local missing=()

  # Check Docker
  if ! command -v docker > /dev/null 2>&1; then
    missing+=("docker")
  elif ! docker info > /dev/null 2>&1; then
    err "Docker is not running"
    exit 1
  fi

  # Check kubectl
  if ! command -v kubectl > /dev/null 2>&1; then
    missing+=("kubectl")
  fi

  # Check kind
  if ! command -v kind > /dev/null 2>&1; then
    missing+=("kind")
  fi

  # Check for license keys
  if [[ -z "${TYK_DB_LICENSEKEY:-}" ]] && [[ -z "${TYK_MDCB_LICENSEKEY:-}" ]]; then
    if [[ ! -f .env ]]; then
      err "License keys not found"
      err "Either set TYK_DB_LICENSEKEY and TYK_MDCB_LICENSEKEY environment variables"
      err "Or create a .env file with these keys"
      exit 1
    fi
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools: ${missing[*]}"
    err "Please install them before running this script"
    exit 1
  fi

  log "Prerequisites check passed"
}

######################################
# Main Deployment Flow
######################################
main() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Tyk K8s Testing Infrastructure Setup"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Source .env file if exists
  if [[ -f .env ]]; then
    log "Loading .env file..."
    source .env
  fi

  # Check prerequisites
  check_prerequisites

  # Create Kind cluster (idempotent)
  log ""
  log "Step 1: Creating Kind cluster..."
  ./create-cluster.sh || {
    err "Failed to create Kind cluster"
    exit 1
  }

  # Deploy Tyk stack
  log ""
  log "Step 2: Deploying Tyk stack..."
  if [[ "$USE_TOXIPROXY" == "true" ]]; then
    log "Toxiproxy: ENABLED"
  else
    log "Toxiproxy: DISABLED"
  fi

  # Pass through the toxiproxy flag to run-tyk-cp-dp.sh
  local toxiproxy_param=""
  if [[ "$USE_TOXIPROXY" == "true" ]]; then
    toxiproxy_param="toxiproxy=true"
  fi

  ./run-tyk-cp-dp.sh $toxiproxy_param || {
    err "Failed to deploy Tyk stack"
    exit 1
  }

  # Start k8s-hosts-controller
  log ""
  log "Step 3: Starting k8s-hosts-controller..."

  # Build comma-separated list of namespaces
  local namespaces="tyk"
  for i in $(seq 1 "${NUM_DATA_PLANES:-2}"); do
    namespaces="${namespaces},tyk-dp-${i}"
  done

  if start_hosts_controller "$namespaces"; then
    warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warning "k8s-hosts-controller is now running in the background"
    warning ""
    warning "It manages /etc/hosts entries for K8s ingress hostnames"
    warning "Log file: /tmp/k8s-hosts-controller.log"
    warning ""
    warning "To check status later, run:"
    warning "  hosts-controller-manager.sh status"
    warning ""
    warning "To stop it when done, run:"
    warning "  hosts-controller-manager.sh stop"
    warning ""
    warning "To cleanup /etc/hosts entries, run:"
    warning "  hosts-controller-manager.sh cleanup"
    warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  else
    err "Failed to start k8s-hosts-controller"
    err "Your cluster is deployed but /etc/hosts entries won't be managed"
    err "You'll need to manually manage hosts entries or fix the issue"
    exit 1
  fi

  # Success message
  log ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "✓ Setup complete! Your K8s environment is ready."
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log ""
  log "Cluster status:"
  log "  kubectl get nodes"
  log ""
  log "View pods:"
  log "  kubectl get pods -A"
  log ""
  log "View services:"
  log "  kubectl get svc -A"
  log ""
  if [[ "$USE_TOXIPROXY" == "true" ]]; then
    log "Toxiproxy environment variables saved to: toxiproxy-ci.env"
    log ""
    log "Test configuration:"
    log "  source toxiproxy-ci.env"
  fi

  # Final cleanup reminder
  warning ""
  warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  warning "When you're done working, don't forget to cleanup:"
  warning ""
  warning "  hosts-controller-manager.sh stop"
  warning "  hosts-controller-manager.sh cleanup"
  warning ""
  warning "To delete the Kind cluster:"
  warning "  kind delete cluster"
  warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main "$@"
