#!/usr/bin/env bash

# Applies a catalogue of ProductClass and TykDeployment resources from a local
# folder.
#
# Every file is validated before any is applied, so a typo cannot leave the
# cluster holding half a catalogue. The apply itself is still one kubectl call
# rather than a transaction: if the cluster fails partway through, some files
# land without the rest. Re-running is safe, because apply is idempotent.
#
# Usage:
#   ./catalog.sh [folder]           validate every file, then apply them all
#   ./catalog.sh --check [folder]   validate every file, apply nothing
#   ./catalog.sh --list [folder]    print the files that would be applied
#   ./catalog.sh --delete [folder]  delete the resources the files define
#
# With no folder, the dev catalogue in the idp-controller checkout is used,
# which is what setup has always applied.
#
# Environment:
#   CALLER_DIR                directory a relative folder resolves against (default $PWD)
#   CATALOG_DEPLOYMENTS_FILE  receives the names of the TykDeployments applied
#
# The folder is searched recursively for .yaml and .yml files, in byte order,
# so two machines apply the same folder in the same order. Each file must pass:
#   kubectl apply --dry-run=server   malformed YAML, and resources the CRDs reject
#   kind                             only ProductClass and TykDeployment
#   uniqueness                       no kind and name defined twice
#   references                       every ProductClass a TykDeployment needs exists

set -euo pipefail

# Captured before the cd below, which would otherwise change what a relative
# folder means.
CALLER_DIR="${CALLER_DIR:-$PWD}"

cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"
source "${SCRIPT_DIR}/../tyk-stack-ingress/lib.sh"

TYK_PRO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

######################################
# configuration
######################################
# An export beats .env, the opposite of plain sourcing. Same handling as
# setup.sh.
CONFIG_VARS=(IDP_CONTROLLER_ROOT KIND_CLUSTER_NAME)

for var in "${CONFIG_VARS[@]}"; do
  declare "EXPORTED_${var}=${!var-}"
done

if [ -f .env ]; then
  source .env
fi

for var in "${CONFIG_VARS[@]}"; do
  exported="EXPORTED_${var}"
  if [ -n "${!exported-}" ]; then
    declare "${var}=${!exported}"
  fi
done

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-tyk-idp}"
KUBE_CONTEXT="kind-${KIND_CLUSTER_NAME}"

kc() {
  kubectl --context "$KUBE_CONTEXT" "$@"
}

usage() {
  error "usage: $0 [--check | --list | --delete] [folder]"
}

######################################
# arguments
######################################
MODE="apply"
case "${1-}" in
  --check) MODE="check"; shift ;;
  --list) MODE="list"; shift ;;
  --delete) MODE="delete"; shift ;;
  -*)
    usage
    exit 1
    ;;
esac

if [ "$#" -gt 1 ]; then
  usage
  exit 1
fi

# Sets FOLDER rather than printing it: a command substitution would capture
# the error messages along with the path, and fail silently.
useDefaultFolder() {
  IDP_CONTROLLER_ROOT="${IDP_CONTROLLER_ROOT:-${TYK_PRO_ROOT}/../idp-controller}"

  if [ ! -d "$IDP_CONTROLLER_ROOT" ]; then
    error "no idp-controller checkout at '$IDP_CONTROLLER_ROOT'"
    error "clone TykTechnologies/idp-controller and set IDP_CONTROLLER_ROOT to it,"
    error "or pass a catalogue folder"
    exit 1
  fi

  FOLDER="$(cd "$IDP_CONTROLLER_ROOT" && pwd)/gitops/environments/dev"
}

FOLDER="${1-}"
if [ -z "$FOLDER" ]; then
  useDefaultFolder
elif [ "${FOLDER#/}" = "$FOLDER" ]; then
  FOLDER="${CALLER_DIR}/${FOLDER}"
fi

######################################
# discovery
######################################
# Needs no cluster, so a wrong path fails before anything is contacted.
FILES=()

discover() {
  if [ ! -e "$FOLDER" ]; then
    error "no such folder: $FOLDER"
    exit 1
  fi

  if [ ! -d "$FOLDER" ]; then
    error "not a folder: $FOLDER"
    exit 1
  fi

  if [ ! -r "$FOLDER" ] || [ ! -x "$FOLDER" ]; then
    error "cannot read folder: $FOLDER"
    exit 1
  fi

  FOLDER="$(cd "$FOLDER" && pwd)"

  # -L follows a symlinked file or subfolder, which is how a catalogue split
  # across checkouts is usually assembled. An unreadable subfolder fails the
  # run rather than being skipped, because skipping it would apply a partial
  # catalogue.
  local errors listing
  errors="$(mktemp)"
  if ! listing="$(find -L "$FOLDER" -type f \( -name '*.yaml' -o -name '*.yml' \) 2> "$errors" \
    | LC_ALL=C sort)"; then
    error "cannot read everything under $FOLDER"
    sed 's/^/  /' "$errors"
    rm -f "$errors"
    exit 1
  fi
  rm -f "$errors"

  while IFS= read -r line; do
    [ -n "$line" ] && FILES+=("$line")
  done <<< "$listing"

  if [ ${#FILES[@]} -eq 0 ]; then
    error "no .yaml or .yml files under $FOLDER"
    exit 1
  fi
}

######################################
# preflight
######################################
requireCluster() {
  if ! kubectl config get-contexts "$KUBE_CONTEXT" > /dev/null 2>&1; then
    error "no kubeconfig context '$KUBE_CONTEXT'"
    error "build the platform first: task -d k8s/idp setup"
    exit 1
  fi

  if ! kc get --raw /readyz > /dev/null 2>&1; then
    error "cannot reach the cluster behind '$KUBE_CONTEXT'"
    error "check it is running with: kind get clusters"
    exit 1
  fi

  # The dry run needs the CRDs to validate against, and without them the
  # apply has nowhere to put the resources anyway.
  local crd
  for crd in productclasses.platform.tyk.io tykdeployments.platform.tyk.io; do
    if ! kc get crd "$crd" > /dev/null 2>&1; then
      error "the platform.tyk.io CRDs are not installed"
      error "build the platform first: task -d k8s/idp setup"
      exit 1
    fi
  done
}

######################################
# validation
######################################
# The dry run is per file so that each failure names its file. Its JSON output
# then feeds the checks the API server cannot make, because they span files or
# depend on what is already in the cluster.
validate() {
  WORK="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$WORK'" EXIT

  log "validating ${#FILES[@]} file(s) from $FOLDER"

  local index="${WORK}/index" n=0 f rc
  : > "$index"
  for f in "${FILES[@]}"; do
    n=$((n + 1))
    rc=0
    kc apply --dry-run=server -o json -f "$f" > "${WORK}/${n}.json" 2> "${WORK}/${n}.err" || rc=$?
    printf '%s\t%s\t%s\t%s\n' "${f#"$FOLDER"/}" "$rc" "${WORK}/${n}.json" "${WORK}/${n}.err" >> "$index"
  done

  if ! kc get productclass -o json > "${WORK}/cluster.json" 2> "${WORK}/cluster.err"; then
    error "could not list the ProductClasses already in the cluster"
    sed 's/^/  /' "${WORK}/cluster.err"
    exit 1
  fi

  DEPLOYMENTS_OUT="${CATALOG_DEPLOYMENTS_FILE:-}" \
    python3 - "$index" "${WORK}/cluster.json" << 'PY'
import json
import os
import sys

GREEN, RED, ORANGE, NC = "\033[0;32m", "\033[0;31m", "\033[0;33m", "\033[0m"


def log(msg):
    print(f"{GREEN}[INFO]{NC} {msg}")


def warn(msg):
    print(f"{ORANGE}[WARNING]{NC} {msg}")


def err(msg):
    print(f"{RED}[ERROR]{NC} {msg}")


GROUP = "platform.tyk.io"
KINDS = ("ProductClass", "TykDeployment")

index_path, cluster_path = sys.argv[1], sys.argv[2]

files = []
with open(index_path) as fh:
    for line in fh:
        name, rc, out, errpath = line.rstrip("\n").split("\t")
        files.append({"name": name, "rc": int(rc), "out": out, "err": errpath})

problems = {f["name"]: [] for f in files}
warnings = {f["name"]: [] for f in files}
objects = []  # (file, object), from files the dry run accepted

for f in files:
    if f["rc"] != 0:
        with open(f["err"]) as fh:
            detail = [l.rstrip() for l in fh if l.strip()]
        # kubectl's wording for an empty file reads like a usage mistake.
        if detail == ["error: no objects passed to apply"]:
            detail = ["holds no resources"]
        problems[f["name"]].extend(detail or [f"kubectl exited {f['rc']}"])
        continue

    with open(f["out"]) as fh:
        doc = json.load(fh)
    items = doc["items"] if doc.get("kind") == "List" else [doc]

    for obj in items:
        group = obj.get("apiVersion", "").split("/")[0]
        kind = obj.get("kind", "")
        if group != GROUP or kind not in KINDS:
            problems[f["name"]].append(
                f"{obj.get('apiVersion', '?')} {kind or '?'} "
                f"'{obj.get('metadata', {}).get('name', '?')}' is not a ProductClass or TykDeployment"
            )
            continue
        objects.append((f["name"], obj))

# A second definition of the same resource silently replaces the first on
# apply, so whichever file sorts later would win without anyone noticing.
seen = {}
for name, obj in objects:
    key = (obj["kind"], obj["metadata"]["name"])
    seen.setdefault(key, []).append(name)

for (kind, rname), where in seen.items():
    if len(where) > 1:
        for name in sorted(set(where)):
            others = ", ".join(w for w in where if w != name) or name
            problems[name].append(f"{kind} '{rname}' is also defined in {others}")

# The api-server accepts a TykDeployment naming a ProductClass that does not
# exist, and the controller only finds out when someone deploys it. Check
# against what the folder brings plus what the cluster already holds.
with open(cluster_path) as fh:
    known = {i["metadata"]["name"] for i in json.load(fh)["items"]}
known |= {obj["metadata"]["name"] for _, obj in objects if obj["kind"] == "ProductClass"}

for name, obj in objects:
    if obj["kind"] != "TykDeployment":
        continue
    td = obj["metadata"]["name"]
    spec = obj.get("spec", {})

    for ref in spec.get("products", []):
        if ref.get("name") not in known:
            problems[name].append(f"TykDeployment '{td}' needs ProductClass '{ref.get('name')}', "
                                  "which is in neither the folder nor the cluster")

    # The controller validates only the products it is about to deploy, so an
    # addon's products matter only while the addon is on. One that defaults to
    # off still deploys; it fails when someone switches the addon on.
    for addon in spec.get("addons", []):
        for ref in addon.get("products", []):
            if ref.get("name") in known:
                continue
            msg = (f"TykDeployment '{td}' addon '{addon.get('name')}' needs ProductClass "
                   f"'{ref.get('name')}', which is in neither the folder nor the cluster")
            if addon.get("default") == "Enabled":
                problems[name].append(msg)
            else:
                warnings[name].append(msg + "; deploying with that addon on will fail")

counts = {}
for name, obj in objects:
    counts.setdefault(name, []).append(f"{obj['kind']} {obj['metadata']['name']}")

for f in files:
    name = f["name"]
    if problems[name]:
        err(f"{name}")
        for p in problems[name]:
            print(f"  {p}")
    else:
        log(f"{name}: {', '.join(counts.get(name, []))}")
    for w in warnings[name]:
        warn(f"{name}: {w}")

failed = [f["name"] for f in files if problems[f["name"]]]
log(f"{len(files) - len(failed)} valid, {len(failed)} failed")

if failed:
    err("nothing applied")
    sys.exit(1)

out = os.environ.get("DEPLOYMENTS_OUT")
if out:
    with open(out, "w") as fh:
        for _, obj in objects:
            if obj["kind"] == "TykDeployment":
                fh.write(obj["metadata"]["name"] + "\n")
PY
}

######################################
# apply
######################################
applyAll() {
  local args=() f
  for f in "${FILES[@]}"; do
    args+=(-f "$f")
  done

  # ProductClass and TykDeployment are cluster-scoped, so no namespace applies.
  log "applying ${#FILES[@]} file(s) from $FOLDER"
  kc apply "${args[@]}"
}

######################################
# entrypoint
######################################
discover

if [ "$MODE" = "list" ]; then
  printf '%s\n' "${FILES[@]}"
  exit 0
fi

requireCluster

# Deleting needs no validation: a file that would fail it either defines
# nothing in the cluster or defines something that should go anyway.
if [ "$MODE" = "delete" ]; then
  args=()
  for f in "${FILES[@]}"; do
    args+=(-f "$f")
  done
  log "deleting what ${#FILES[@]} file(s) from $FOLDER define"
  kc delete --ignore-not-found "${args[@]}"
  exit 0
fi

validate

if [ "$MODE" = "check" ]; then
  log "--check given, nothing applied"
  exit 0
fi

applyAll
