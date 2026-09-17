#!/usr/bin/env bash

# Checks and installs the prerequisite tooling the IDP environment needs.
#
# Kept apart from setup.sh because installing tools onto a workstation and
# building a cluster are different decisions with different blast radii.
# `check` only reads; `install` writes to the machine, so setup.sh never calls
# it and no cluster task installs a tool as a side effect.
#
# Usage:
#   ./deps.sh check             report every prerequisite, non-zero if one is missing
#   ./deps.sh install           install the missing required tools (macOS/Homebrew)
#   ./deps.sh install-optional  install the tools for running the backend from source

set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"
source "${SCRIPT_DIR}/../tyk-stack-ingress/lib.sh"

# setup.sh's own checkDependencies covers these four, so the list has to stay in
# step with it.
REQUIRED=(docker kind kubectl helm)

# Not needed to stand the environment up. `go` runs the controller and
# api-server from source, `ngrok` exposes a local api-server to a Forge tunnel.
# See idp-controller docs/local-development.md.
OPTIONAL=(go ngrok)

######################################
# reporting
######################################
versionOf() {
  case "$1" in
    docker) docker --version 2> /dev/null ;;
    kind) kind --version 2> /dev/null ;;
    kubectl) kubectl version --client 2> /dev/null | head -1 ;;
    helm) helm version --short 2> /dev/null ;;
    go) go version 2> /dev/null ;;
    ngrok) ngrok --version 2> /dev/null ;;
    *) echo "installed" ;;
  esac
}

checkTools() {
  local missing=()

  log "required"
  for cmd in "${REQUIRED[@]}"; do
    if command -v "$cmd" > /dev/null 2>&1; then
      printf '  %-8s %s\n' "$cmd" "$(versionOf "$cmd")"
    else
      printf '  %-8s MISSING\n' "$cmd"
      missing+=("$cmd")
    fi
  done

  log "optional"
  for cmd in "${OPTIONAL[@]}"; do
    if command -v "$cmd" > /dev/null 2>&1; then
      printf '  %-8s %s\n' "$cmd" "$(versionOf "$cmd")"
    else
      printf '  %-8s not installed\n' "$cmd"
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    error "missing required tools: ${missing[*]}"
    error "to install them, run: task -d k8s/idp deps-install"
    exit 1
  fi
}

checkDaemon() {
  if docker info > /dev/null 2>&1; then
    log "docker daemon is reachable"
  else
    error "the docker daemon is not reachable; start Docker Desktop or OrbStack"
    exit 1
  fi
}

checkRuntime() {
  [[ "$(uname -s)" == "Darwin" ]] || return 0

  local context
  context="$(docker context show 2> /dev/null || echo unknown)"
  log "docker context is $context"

  # See idp-controller docs/local-development.md: the Docker Desktop bridge
  # does not route kind's LoadBalancer IPs to macOS, so the Ingress addresses
  # the Tyk charts create stay unreachable from the host. Port-forwarding still
  # works, which is why this warns rather than failing.
  if [[ "$context" != "orbstack" ]]; then
    warning "'$context' does not route kind LoadBalancer IPs to macOS"
    warning "Ingress hostnames will be unreachable from the host; use port-forwarding, or switch to OrbStack"
  fi
}

######################################
# installation
######################################
requireBrew() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    error "automatic install only covers macOS/Homebrew"
    error "install these yourself: $*"
    exit 1
  fi

  if ! command -v brew > /dev/null 2>&1; then
    error "Homebrew is not installed; see https://brew.sh"
    exit 1
  fi
}

installTools() {
  requireBrew "${REQUIRED[*]}"

  # Only ever installs what is absent. An existing tool keeps whatever version
  # the machine already has, so this never moves anyone off a version they
  # pinned on purpose.
  for cmd in "${REQUIRED[@]}"; do
    if command -v "$cmd" > /dev/null 2>&1; then
      log "$cmd is already installed, leaving it alone"
      continue
    fi

    case "$cmd" in
      docker)
        log "installing OrbStack, which routes kind LoadBalancer IPs to macOS"
        brew install --cask orbstack
        ;;
      *)
        log "installing $cmd"
        brew install "$cmd"
        ;;
    esac
  done
}

installOptionalTools() {
  requireBrew "${OPTIONAL[*]}"

  for cmd in "${OPTIONAL[@]}"; do
    if command -v "$cmd" > /dev/null 2>&1; then
      log "$cmd is already installed, leaving it alone"
      continue
    fi
    log "installing $cmd"
    brew install "$cmd"
  done
}

######################################
# entrypoint
######################################
case "${1:-check}" in
  check)
    checkTools
    checkDaemon
    checkRuntime
    ;;
  install)
    installTools
    checkTools
    checkDaemon
    checkRuntime
    ;;
  install-optional)
    installOptionalTools
    ;;
  *)
    error "unknown command '$1'"
    error "usage: $0 [check|install|install-optional]"
    exit 1
    ;;
esac
