#!/usr/bin/env bash

# Loads API definitions into a deployed stack.
#
# Prefers the dashboard, which owns API definitions on a Pro stack and stores
# them durably. Falls back to the gateway's own API when the instance has no
# dashboard, with a warning: the gateway writes definitions as files under
# app_path, which the chart backs with an emptyDir, so they do not survive a
# pod restart.
#
# Usage:
#   ./seed.sh <file> [file...]
#
# Environment:
#   INSTANCE  the TykDeploymentInstance to seed  (default the only one)
#
# Each file is classified by its contents and sent to the matching endpoint:
#   openapi + x-tyk-streaming  ->  /api/apis/streams/
#   openapi                    ->  /api/apis/oas
#   anything else              ->  /api/apis/
#
# Re-running is an update rather than a duplicate: a definition carrying an id
# the stack already has is sent as a PUT.

set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"
source "${SCRIPT_DIR}/../tyk-stack-ingress/lib.sh"

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-tyk-idp}"
KUBE_CONTEXT="kind-${KIND_CLUSTER_NAME}"

kc() {
  kubectl --context "$KUBE_CONTEXT" "$@"
}

######################################
# arguments
######################################
if [ "$#" -eq 0 ]; then
  error "usage: $0 <file> [file...]"
  error "  set INSTANCE=<name> to choose a stack; list them with: task -d k8s/idp instances"
  exit 1
fi

# Checked before anything is sent, so a typo cannot leave a stack half seeded.
FILES=()
missing=()
for f in "$@"; do
  if [ -r "$f" ]; then
    FILES+=("$f")
  else
    missing+=("$f")
  fi
done

if [ ${#missing[@]} -gt 0 ]; then
  error "cannot read: ${missing[*]}"
  exit 1
fi

######################################
# instance
######################################
resolveInstance() {
  local instance="${INSTANCE:-}"

  if [ -z "$instance" ]; then
    local instances=()
    while IFS= read -r line; do instances+=("$line"); done \
      < <(kc get tykdeploymentinstance -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

    case ${#instances[@]} in
      0)
        error "no TykDeploymentInstance in the cluster"
        error "deploy one first: task -d k8s/idp install"
        exit 1
        ;;
      1) instance="${instances[0]}" ;;
      *)
        error "more than one instance; set INSTANCE to the one you want"
        error "the cluster holds: ${instances[*]}"
        exit 1
        ;;
    esac
  fi

  if ! kc get tykdeploymentinstance "$instance" > /dev/null 2>&1; then
    error "no TykDeploymentInstance named '$instance'"
    exit 1
  fi

  INSTANCE="$instance"
  NAMESPACE="$(kc get tykdeploymentinstance "$instance" -o jsonpath='{.status.tenantNamespace}')"

  if [ -z "$NAMESPACE" ]; then
    error "instance '$instance' has no tenant namespace yet"
    exit 1
  fi
}

######################################
# target
######################################
# A Pro stack keeps API definitions in the dashboard's database, so that is
# where they belong. Only when no dashboard exists does the gateway's own API
# come into play.
chooseTarget() {
  DASHBOARD_SVC="$(kc -n "$NAMESPACE" get svc -o name \
    | sed 's|service/||' | grep -- '-tyk-dashboard$' | head -1 || true)"

  if [ -n "$DASHBOARD_SVC" ]; then
    MODE="dashboard"
    SERVICE="$DASHBOARD_SVC"
    REMOTE_PORT=3000
    AUTH="$(kc -n "$NAMESPACE" get secret tyk-operator-conf \
      -o jsonpath='{.data.TYK_AUTH}' 2> /dev/null | base64 -d || true)"

    if [ -z "$AUTH" ]; then
      error "no TYK_AUTH in the tyk-operator-conf secret in $NAMESPACE"
      error "that secret is created by the tyk-bootstrap post-install hook; check it ran"
      exit 1
    fi
    return 0
  fi

  GATEWAY_SVC="$(kc -n "$NAMESPACE" get svc -o name \
    | sed 's|service/||' | grep -- '-tyk-gateway$' | head -1 || true)"

  if [ -z "$GATEWAY_SVC" ]; then
    error "$NAMESPACE has neither a dashboard nor a gateway service"
    error "it holds: $(kc -n "$NAMESPACE" get svc -o name | sed 's|service/||' | tr '\n' ' ')"
    exit 1
  fi

  MODE="gateway"
  SERVICE="$GATEWAY_SVC"
  REMOTE_PORT=8080

  # The release name carries a hash, so the admin secret is found by suffix.
  local secret
  secret="$(kc -n "$NAMESPACE" get secret -o name \
    | sed 's|secret/||' | grep -- '-tyk-gateway$' | head -1 || true)"

  if [ -z "$secret" ]; then
    error "no gateway admin secret in $NAMESPACE"
    exit 1
  fi

  AUTH="$(kc -n "$NAMESPACE" get secret "$secret" -o jsonpath='{.data.APISecret}' | base64 -d)"

  warning "instance '$INSTANCE' has no dashboard, seeding the gateway directly"
  warning "the gateway writes definitions under app_path, which the chart backs with an"
  warning "emptyDir, so they are lost on a pod restart, including one caused by set-gateway"
}

######################################
# port-forward
######################################
freePort() {
  python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
'
}

startForward() {
  LOCAL_PORT="$(freePort)"

  kc -n "$NAMESPACE" port-forward "svc/${SERVICE}" "${LOCAL_PORT}:${REMOTE_PORT}" \
    > /dev/null 2>&1 &
  FORWARD_PID=$!

  # shellcheck disable=SC2064
  trap "kill $FORWARD_PID 2> /dev/null || true" EXIT

  local waited=0
  while [ "$waited" -lt 15 ]; do
    if nc -z 127.0.0.1 "$LOCAL_PORT" 2> /dev/null; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  error "the port-forward to $SERVICE did not come up within 15s"
  exit 1
}

######################################
# seeding
######################################
seedFiles() {
  BASE_URL="http://127.0.0.1:${LOCAL_PORT}" MODE="$MODE" AUTH="$AUTH" \
    python3 - "${FILES[@]}" << 'PY'
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ["BASE_URL"]
MODE = os.environ["MODE"]
AUTH = os.environ["AUTH"]

GREEN, RED, ORANGE, NC = "\033[0;32m", "\033[0;31m", "\033[0;33m", "\033[0m"


def log(msg):
    print(f"{GREEN}[INFO]{NC} {msg}")


def warn(msg):
    print(f"{ORANGE}[WARNING]{NC} {msg}")


def err(msg):
    print(f"{RED}[ERROR]{NC} {msg}")


def call(method, path, body=None):
    """Returns (status, parsed-body-or-text). A 4xx is data, not an exception:
    a 404 from the existence probe is the normal 'create it' answer."""
    url = BASE + path
    data = json.dumps(body).encode() if body is not None else None

    headers = {"Content-Type": "application/json"}
    # The dashboard authenticates a user's API key on Authorization; the
    # gateway's own API uses its admin secret on a header of its own.
    headers["Authorization" if MODE == "dashboard" else "x-tyk-authorization"] = AUTH

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode()
            try:
                return resp.status, json.loads(raw)
            except json.JSONDecodeError:
                return resp.status, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw


def classify(doc):
    """Streams carry x-tyk-streaming alongside the OpenAPI document, so they
    must be tested before the plain OAS case."""
    if "openapi" in doc:
        if "x-tyk-streaming" in doc:
            return "streams"
        return "oas"
    return "classic"


def api_id(doc, kind):
    if kind == "classic":
        return doc.get("api_id") or doc.get("api_definition", {}).get("api_id")
    return doc.get("x-tyk-api-gateway", {}).get("info", {}).get("id")


DASHBOARD_PATHS = {
    "classic": ("/api/apis/", "/api/apis/{id}"),
    "oas": ("/api/apis/oas", "/api/apis/oas/{id}"),
    "streams": ("/api/apis/streams/", "/api/apis/streams/{id}"),
}

created, updated, failed = [], [], []

for path in sys.argv[1:]:
    name = os.path.basename(path)

    try:
        with open(path) as fh:
            doc = json.load(fh)
    except json.JSONDecodeError as e:
        err(f"{name}: not valid JSON ({e})")
        failed.append(name)
        continue

    kind = classify(doc)
    ident = api_id(doc, kind)

    if MODE == "gateway":
        if kind != "classic":
            err(f"{name}: the gateway API takes classic definitions, this is {kind}")
            failed.append(name)
            continue
        create_path, update_path = "/tyk/apis", "/tyk/apis/{id}"
        probe_path = "/tyk/apis/{id}"
    else:
        create_path, update_path = DASHBOARD_PATHS[kind]
        probe_path = update_path

    exists = False
    if ident:
        status, _ = call("GET", probe_path.format(id=ident))
        exists = status == 200

    if exists:
        status, body = call("PUT", update_path.format(id=ident), doc)
        action, bucket = "updated", updated
    else:
        if not ident:
            warn(f"{name}: no api id, so re-running this file creates another copy")
        status, body = call("POST", create_path, doc)
        action, bucket = "created", created

    if 200 <= status < 300:
        log(f"{name}: {action} ({kind}{', id ' + ident if ident else ''})")
        bucket.append(name)
    else:
        detail = body.get("Message", body) if isinstance(body, dict) else body
        err(f"{name}: HTTP {status} {str(detail)[:160]}")
        failed.append(name)

# A gateway holds definitions as files and only serves them after a reload.
if MODE == "gateway" and (created or updated):
    status, _ = call("GET", "/tyk/reload/group")
    if 200 <= status < 300:
        log("gateway reloaded")
    else:
        warn(f"gateway reload returned HTTP {status}; the APIs may not be live yet")

log(f"created {len(created)}, updated {len(updated)}, failed {len(failed)}")
sys.exit(1 if failed else 0)
PY
}

######################################
# entrypoint
######################################
resolveInstance
chooseTarget

log "seeding ${#FILES[@]} file(s) into $INSTANCE"
log "  target   $MODE, $SERVICE in $NAMESPACE"

startForward
seedFiles
