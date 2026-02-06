#!/usr/bin/env bash

GREEN='\033[0;32m'
LIGHT_BLUE='\033[1;34m'
RED='\033[0;31m'
ORANGE='\033[0;33m'
NC='\033[0m'
export SCRIPT_TEMP_DIR=$(mktemp -d -t "tyk-deploy.XXXXXXXXXX")

cleanup() {
  if [ -d "$SCRIPT_TEMP_DIR" ]; then
    rm -rf "$SCRIPT_TEMP_DIR"
  fi
}
if [[ -n "${BASH_TRAP_EXIT:-}" ]]; then
  trap "cleanup; ${BASH_TRAP_EXIT}" EXIT INT TERM
else
  trap cleanup EXIT INT TERM
fi

full_path=$(realpath "$0")
display_name="tyk-pro/${full_path##*/tyk-pro/}"

log() {
  echo -e "${LIGHT_BLUE}[$display_name]${NC} $@" >&2
}

warning() {
  echo -e "${ORANGE}[$display_name] $@ ${NC}" >&2
}

err() {
  echo -e "${RED}[$display_name] $@ ${NC}" >&2
}

sublog() {
  echo -e "${LIGHT_BLUE}[$display_name]${NC}    $@" >&2
}

subwarning() {
  echo -e "${ORANGE}[WARNING]  $@ ${NC}" >&2
}

suberr() {
  echo -e "${RED}[ERROR]   $@ ${NC}" >&2
}

helm_quiet() {
  local log_file="$SCRIPT_TEMP_DIR/helm-$(date +%s%N).log"

  if [[ ! -d "$SCRIPT_TEMP_DIR" ]] || [[ ! -w "$SCRIPT_TEMP_DIR" ]]; then
    suberr "temp directory $SCRIPT_TEMP_DIR is not accessible :("
    return 1
  fi

  if ! helm "$@" > "$log_file" 2>&1; then
    local msg="Helm command failed: \""
    if [[ -f "$log_file" ]]; then
      msg+="$(cat "$log_file")\""
      suberr "$msg"
    else
      suberr "Log file $log_file could not be created"
    fi
    return 1
  fi

  return 0
}

retry() {
  set +e
  actual_retry "$@"
  local rc=$?
  set -e
  return $rc
}

actual_retry() {
  local retries="$1"
  shift

  if [[ ! "$retries" =~ ^[0-9]+$ ]] || [[ "$retries" -lt 1 ]]; then
    err "Invalid retry count: '$retries'. Must be a positive integer."
    return 1
  fi

  local count=0
  local delay=1
  local max_delay=60
  local rc=0

  until "$@"; do
    rc=$?
    count=$((count + 1))

    if [[ $count -lt $retries ]]; then
      warning "Retry $count/$retries exited $rc, retrying in $delay seconds..."
      sleep "$delay"

      delay=$((delay * 2))
      if [[ $delay -gt $max_delay ]]; then
        delay=$max_delay
      fi
    else
      err "Retry $count/$retries exited $rc, no more retries left."
      return $rc
    fi
  done

  return 0
}

get_binary_path() {
  local bin_name="$1"

  if [[ -z "$bin_name" ]]; then
    echo "bin_name is missing, usage: get_binary_path <bin_name>; e.g, get_binary_path kubectl"
    return 1
  fi

  if command -v "$bin_name" > /dev/null 2>&1; then
    command -v "$bin_name"
    return 0
  fi

  local fallback_path="/usr/local/bin/$bin_name"
  if [[ -x "$fallback_path" ]]; then
    return 0
  fi

  return 1
}

# kubectl_get_secret_value $namespace $secret_name $key
# all args are required.
kubectl_get_secret_value() {
  local namespace="${1:?namespace required}"
  local secret_name="${2:?secret name required}"
  local key="${3:?key required}"

  local value
  value=$(kubectl get secret --namespace "$namespace" "$secret_name" \
    -o jsonpath="{.data.$key}" 2> /dev/null | base64 --decode 2> /dev/null)
  if [[ $? -ne 0 ]]; then
    err "Failed to retrieve secret \"$namespace/$secret_name\" field: $key"
    return 1
  fi

  if [[ -z "$value" ]]; then
    err "Secret $secret_name/$key in namespace $namespace is empty"
    return 1
  fi

  echo "$value"
  return 0
}

# wait_for_loadbalancer_ip $namespace $service_name $max-attempts
wait_for_loadbalancer_ip() {
  local namespace="${1:?namespace required}"
  local service_name="${2:?service name required}"
  local max_attempts="${3:-5}"
  local ip=""

  log "Waiting for LoadBalancer IP for service $service_name in namespace $namespace..."

  _get_lb_ip() {
    ip=$(kubectl get svc "$service_name" -n "$namespace" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2> /dev/null || true)

    if [[ -n "$ip" ]]; then
      return 0
    fi

    return 1
  }

  if retry "$max_attempts" _get_lb_ip; then
    log "LoadBalancer IP acquired: $ip"
    echo "$ip"
    return 0
  fi

  err "Timeout waiting for LoadBalancer IP for service $service_name after $max_attempts attempts"
  return 1
}

retrieve_control_plane_secrets() {
  local namespace="${1:-$CP_NAMESPACE}"
  local secret_name="tyk-operator-conf"
  local max_retries=10

  log "Retrieving control plane secrets from $namespace/$secret_name..."

  _get_secrets() {
    local org_id
    local user_api_key

    org_id=$(kubectl_get_secret_value "$namespace" "$secret_name" "TYK_ORG") || return 1
    user_api_key=$(kubectl_get_secret_value "$namespace" "$secret_name" "TYK_AUTH") || return 1

    export ORG_ID="$org_id"
    export USER_API_KEY="$user_api_key"

    log "Successfully retrieved control plane secrets:"
    log "  ORG_ID: ${ORG_ID:0:10}... (truncated)"
    log "  USER_API_KEY: ${USER_API_KEY:0:10}... (truncated)"

    return 0
  }

  if ! retry "$max_retries" _get_secrets; then
    err "Failed to retrieve control plane secrets after $max_retries attempts"
    echo "This usually means:"
    echo "  - control plane helm installation failed"
    echo "  - tyk-operator-conf secret was not created"
    echo "  - the secret exists but is empty"
    return 1
  fi

  return 0
}

check_sudo_access() {
  if [[ $EUID -eq 0 ]]; then
    log "Running as root, sudo not required."
    return 0
  fi

  if sudo -n true 2> /dev/null; then
    log "Sudo access available (cached or NOPASSWD)."
    return 0
  fi

  if ! sudo -v; then
    err "Sudo access required but could not be acquired"
    err "Please ensure you have sudo privileges"
    exit 1
  fi

  log "Sudo access granted"
  return 0
}
