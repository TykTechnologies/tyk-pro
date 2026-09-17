#!/usr/bin/env bash

# Checks and installs the prerequisite tooling the IDP environment needs.
#
# Kept apart from setup.sh because installing tools onto a workstation and
# building a cluster are different decisions with different blast radii.
# `check` only reads; `install` writes to the machine, so setup.sh never calls
# it and no cluster task installs a tool as a side effect.
#
# Usage:
#   ./deps.sh          report every prerequisite, then offer to install what is missing
#   ./deps.sh --yes    install anything missing without asking, for a non-interactive run
#
# Nothing installs without a yes. Answering no still reports what is missing and
# exits non-zero when a required tool is absent, so a caller cannot carry on
# into a build that cannot work.

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

# Populated by checkTools so the caller can act on what is absent.
MISSING_REQUIRED=()
MISSING_OPTIONAL=()

checkTools() {
  MISSING_REQUIRED=()
  MISSING_OPTIONAL=()

  log "required"
  for cmd in "${REQUIRED[@]}"; do
    if command -v "$cmd" > /dev/null 2>&1; then
      printf '  %-8s %s\n' "$cmd" "$(versionOf "$cmd")"
    else
      printf '  %-8s MISSING\n' "$cmd"
      MISSING_REQUIRED+=("$cmd")
    fi
  done

  log "optional"
  for cmd in "${OPTIONAL[@]}"; do
    if command -v "$cmd" > /dev/null 2>&1; then
      printf '  %-8s %s\n' "$cmd" "$(versionOf "$cmd")"
    else
      printf '  %-8s not installed\n' "$cmd"
      MISSING_OPTIONAL+=("$cmd")
    fi
  done
}

# Asks once, and treats anything but an explicit yes as no. A run with no
# terminal attached, such as CI, never blocks: it answers no unless ASSUME_YES
# was passed.
confirm() {
  local prompt="$1"

  if [ "$ASSUME_YES" = "true" ]; then
    log "$prompt yes (--yes)"
    return 0
  fi

  if [ ! -t 0 ]; then
    warning "$prompt no terminal to ask on, skipping. Pass --yes to install anyway"
    return 1
  fi

  local answer
  read -r -p "$(printf '%s [y/N] ' "$prompt")" answer
  case "$answer" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
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

# Installs exactly the tools it is given, so an existing tool keeps whatever
# version the machine already has and nobody is moved off a pinned version.
installTools() {
  requireBrew "$*"

  for cmd in "$@"; do
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

######################################
# entrypoint
######################################
ASSUME_YES="false"
case "${1:-}" in
  "") ;;
  --yes | -y) ASSUME_YES="true" ;;
  *)
    error "unknown argument '$1'"
    error "usage: $0 [--yes]"
    exit 1
    ;;
esac

checkTools

if [ ${#MISSING_REQUIRED[@]} -gt 0 ]; then
  if confirm "Install ${MISSING_REQUIRED[*]} through Homebrew?"; then
    installTools "${MISSING_REQUIRED[@]}"
    checkTools
  fi

  if [ ${#MISSING_REQUIRED[@]} -gt 0 ]; then
    error "still missing: ${MISSING_REQUIRED[*]}"
    exit 1
  fi
fi

# Optional tools are offered separately, because declining them leaves a
# working environment. go builds the controller images, ngrok exposes a local
# api-server to a Forge tunnel.
if [ ${#MISSING_OPTIONAL[@]} -gt 0 ]; then
  if confirm "Also install ${MISSING_OPTIONAL[*]}?"; then
    installTools "${MISSING_OPTIONAL[@]}"
  fi
fi

checkDaemon
checkRuntime
