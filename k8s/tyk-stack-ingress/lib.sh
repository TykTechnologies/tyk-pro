#!/usr/bin/env bash

GREEN='\033[0;32m'
RED='\033[0;31m'
ORANGE='\033[0;33m'
NC='\033[0m'
export SCRIPT_TEMP_DIR=$(mktemp -d -t "tyk-deploy.XXXXXXXXXX")

cleanup() {
    echo "clean up trap"
  if [ -d "$SCRIPT_TEMP_DIR" ]; then
    rm -rf "$SCRIPT_TEMP_DIR"
  fi
}
if [[ -n "${BASH_TRAP_EXIT:-}" ]]; then
  trap "cleanup; ${BASH_TRAP_EXIT}" EXIT INT TERM
else
  trap cleanup EXIT INT TERM
fi

log() {
  echo -e "${GREEN}[INFO]${NC} $@" >&2
}

warning() {
  echo -e "${ORANGE}[WARNING]${NC} $@" >&2
}

err() {
  echo -e "${RED}[ERROR]${NC} $@" >&2
}

sublog() {
  echo -e "${GREEN}[INFO]${NC}      $@" >&2
}

subwarning() {
  echo -e "${ORANGE}[WARNING]${NC}      $@" >&2
}

suberr() {
  echo -e "${RED}[ERROR]${NC}      $@" >&2
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

# kubectl_get_secret_value $namespace $secret_name $key
# all args are required.
kubectl_get_secret_value() {
  local namespace="${1:?namespace required}"
  local secret_name="${2:?secret name required}"
  local key="${3:?key required}"

  local value
  value=$(kubectl get secret \ 
    --namespace "$namespace" "$secret_name" \
    -o jsonpath="{.data.$key}" 2>/dev/null | base64 --decode 2>/dev/null)

  if [[ $? -ne 0 ]]; then
    err "Failed to retrieve secret $secret_name/$key from namespace $namespace"
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
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

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

find_k8s_hosts_controller() {
  local possible_paths=(
    "/usr/local/bin/k8s-hosts-controller"
    "../apps/k8s-hosts-controller/k8s-hosts-controller"
    "../../k8s-hosts-controller/k8s-hosts-controller"
  )

  for path in "${possible_paths[@]}"; do
    if [[ -f "$path" && -x "$path" ]]; then
      echo "$path"
      return 0
    fi
  done

  return 1
}

start_hosts_controller() {
  local namespaces="${1:?namespaces required}"
  local controller_binary
  local startup_wait_time=${STARTUP_WAIT_TIME:-2}

  # Find the controller binary
  if ! controller_binary=$(find_k8s_hosts_controller); then
    err "k8s-hosts-controller binary not found"
    err "Expected locations (relative to k8s/tyk-stack-ingress/):"
    err "  - ../apps/k8s-hosts-controller/k8s-hosts-controller"
    err "  - ../../k8s-hosts-controller/k8s-hosts-controller"
    err "  - /usr/local/bin/k8s-hosts-controller"
    return 1
  fi

  log "Found k8s-hosts-controller at: $controller_binary"

  local manager_script
  local possible_manager_scripts=(
    "/usr/local/bin/hosts-controller-manager.sh"
    "../apps/k8s-hosts-controller/hosts-controller-manager.sh"
    "../../k8s-hosts-controller/hosts-controller-manager.sh"
  )

  for script in "${possible_manager_scripts[@]}"; do
    if [[ -f "$script" && -x "$script" ]]; then
      manager_script="$script"
      break
    fi
  done

  if [[ -n "$manager_script" ]]; then
    log "Starting hosts controller via manager script at $manager_script..."
    CONTROLLER_BINARY="$controller_binary" "$manager_script" start "$namespaces"
    return $?
  fi

  log "hosts-controller-manager.sh not found, using manual process management"

  # Fallback: manual process management
  # Check for existing controller process (single pgrep call to avoid race condition)
  local existing_pid
  if existing_pid=$(pgrep -f "k8s-hosts-controller" 2>/dev/null); then
    log "Hosts controller already running (PID: $existing_pid)"
    log "Skipping startup, using existing instance"
    return 0
  fi

  # Validate sudo access before starting controller
  if ! sudo -v 2>/dev/null; then
    err "Sudo access required for hosts controller"
    return 1
  fi

  log "Starting hosts controller in background..."
  local log_file="/tmp/k8s-hosts-controller.log"
  sudo "$controller_binary" --namespaces "$namespaces" > "$log_file" 2>&1 &
  HOSTS_CONTROLLER_PID=$!

  sleep "$startup_wait_time"
  if ! kill -0 "$HOSTS_CONTROLLER_PID" 2>/dev/null; then
    err "Hosts controller failed to start"
    err "Log file: $log_file"
    return 1
  fi

  log "Hosts controller started (PID: $HOSTS_CONTROLLER_PID)"
  log "Log file: $log_file"

  # Set up cleanup trap with proper chaining
  cleanup_hosts_controller() {
    log "Stopping hosts controller..."
    if [[ -n "${HOSTS_CONTROLLER_PID:-}" ]] && kill -0 "$HOSTS_CONTROLLER_PID" 2>/dev/null; then
      sudo kill "$HOSTS_CONTROLLER_PID" 2>/dev/null || true
    fi
  }

  # Chain cleanup with existing temp directory cleanup
  if [[ -n "${BASH_TRAP_EXIT:-}" ]]; then
    trap "cleanup_hosts_controller; ${BASH_TRAP_EXIT}" EXIT INT TERM
  else
    trap "cleanup_hosts_controller; cleanup" EXIT INT TERM
  fi

  return 0
}
