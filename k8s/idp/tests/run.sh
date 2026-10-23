#!/usr/bin/env bash

# Tests catalog.sh and the CATALOG path through install.sh.
#
# Cases fall into two tiers. Offline cases exercise discovery and argument
# handling, and need nothing but this checkout. Cluster cases need the kind
# cluster with the platform.tyk.io CRDs, because every YAML check runs through
# a server-side dry run; without one they are skipped, not failed.
#
# Usage:
#   ./tests/run.sh
#
# Environment:
#   TEST_CLUSTER=require   fail instead of skipping when there is no cluster
#   IDP_CONTROLLER_ROOT    checkout holding the default dev catalogue
#
# Every fixture resource is named catalog-test-*, and anything carrying that
# prefix is deleted before and after the run, so a failed run leaves nothing
# behind in the shared cluster.

set -uo pipefail

cd "$(dirname "$0")/.."
IDP_DIR="$(pwd)"
FIXTURES="${IDP_DIR}/tests/fixtures"
source "${IDP_DIR}/../tyk-stack-ingress/lib.sh"

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-tyk-idp}"
KUBE_CONTEXT="kind-${KIND_CLUSTER_NAME}"
IDP_CONTROLLER_ROOT="${IDP_CONTROLLER_ROOT:-$(cd ../.. && pwd)/../idp-controller}"
# catalog.sh prints the checkout's resolved path, so compare against the same.
if [ -d "$IDP_CONTROLLER_ROOT" ]; then
  IDP_CONTROLLER_ROOT="$(cd "$IDP_CONTROLLER_ROOT" && pwd)"
fi
export IDP_CONTROLLER_ROOT KIND_CLUSTER_NAME

kc() {
  kubectl --context "$KUBE_CONTEXT" "$@"
}

PASSED=0
FAILED=0
SKIPPED=0
FAILURES=()
CURRENT=""

######################################
# helpers
######################################
# Runs a command, keeping its exit code in RC and its output, stripped of
# colour codes, in OUT.
run() {
  OUT="$("$@" 2>&1 < /dev/null)"
  RC=$?
  OUT="$(printf '%s' "$OUT" | sed $'s/\033\\[[0-9;]*m//g')"
}

fail() {
  FAILED=$((FAILED + 1))
  FAILURES+=("$CURRENT: $1")
  error "$CURRENT: $1"
  printf '%s\n' "$OUT" | sed 's/^/    | /'
}

assert_exit() {
  [ "$RC" -eq "$1" ] || { fail "exit $RC, wanted $1"; return 1; }
}

assert_contains() {
  printf '%s' "$OUT" | grep -qF -- "$1" || { fail "output lacks: $1"; return 1; }
}

assert_lacks() {
  if printf '%s' "$OUT" | grep -qF -- "$1"; then
    fail "output has: $1"
    return 1
  fi
}

assert_exists() {
  kc get "$1" "$2" > /dev/null 2>&1 || { fail "$1 $2 is not in the cluster"; return 1; }
}

assert_absent() {
  if kc get "$1" "$2" > /dev/null 2>&1; then
    fail "$1 $2 is in the cluster"
    return 1
  fi
}

# Each case is a function; a case passes when no assertion in it failed.
check() {
  CURRENT="$1"
  local before=$FAILED
  "$1"
  if [ "$FAILED" -eq "$before" ]; then
    PASSED=$((PASSED + 1))
    log "$1"
  fi
}

cluster_check() {
  if [ "$HAVE_CLUSTER" = "true" ]; then
    check "$1"
  else
    CURRENT="$1"
    if [ "${TEST_CLUSTER:-}" = "require" ]; then
      OUT=""
      fail "no cluster, and TEST_CLUSTER=require"
    else
      SKIPPED=$((SKIPPED + 1))
      warning "$1: SKIP (no cluster)"
    fi
  fi
}

haveCluster() {
  kubectl config get-contexts "$KUBE_CONTEXT" > /dev/null 2>&1 \
    && kc get --raw /readyz > /dev/null 2>&1 \
    && kc get crd productclasses.platform.tyk.io > /dev/null 2>&1 \
    && kc get crd tykdeployments.platform.tyk.io > /dev/null 2>&1
}

cleanup() {
  [ "$HAVE_CLUSTER" = "true" ] || return 0
  local names
  names="$(kc get productclass,tykdeployment -o name 2> /dev/null | grep '/catalog-test-' || true)"
  if [ -n "$names" ]; then
    # shellcheck disable=SC2086
    kc delete --ignore-not-found $names > /dev/null
  fi
  # The wrong-kind fixture is the one resource outside the catalogue kinds,
  # and a catalog.sh that lost its kind check would leave it behind.
  kc -n default delete configmap catalog-test-configmap --ignore-not-found > /dev/null
}

instanceCount() {
  kc get tykdeploymentinstance --no-headers 2> /dev/null | wc -l | tr -d ' '
}

######################################
# offline cases
######################################
# One run covers discovery: subfolders two deep, both extensions, other files
# ignored, a fixed order, and a relative folder resolved against where task
# ran rather than against k8s/idp.
test_finds_nested_files_from_relative_folder() {
  run env CALLER_DIR="$FIXTURES" ./catalog.sh --list valid-nested
  assert_exit 0 || return
  local want
  want="$(printf '%s\n' \
    "$FIXTURES/valid-nested/a-classes/catalog-test-chart.yaml" \
    "$FIXTURES/valid-nested/topologies/catalog-test-multi.yaml" \
    "$FIXTURES/valid-nested/topologies/nested/catalog-test-extra.yml" \
    "$FIXTURES/valid-nested/topologies/nested/deeper/catalog-test-stack.yaml")"
  [ "$OUT" = "$want" ] || fail "wrong files or order"
}

test_missing_folder() {
  run ./catalog.sh --list "$FIXTURES/does-not-exist"
  assert_exit 1 || return
  assert_contains "no such folder: $FIXTURES/does-not-exist"
}

test_empty_folder() {
  local dir
  dir="$(mktemp -d)"
  run ./catalog.sh --list "$dir"
  rmdir "$dir"
  assert_exit 1 || return
  assert_contains "no .yaml or .yml files under"
}

test_folder_without_yaml() {
  run ./catalog.sh --list "$FIXTURES/no-yaml"
  assert_exit 1 || return
  assert_contains "no .yaml or .yml files under"
}

test_file_instead_of_folder() {
  run ./catalog.sh --list "$FIXTURES/no-yaml/definition.json"
  assert_exit 1 || return
  assert_contains "not a folder"
}

test_unreadable_subfolder() {
  if [ "$(id -u)" -eq 0 ]; then
    warning "$CURRENT: SKIP (root reads every folder)"
    return 0
  fi
  local dir
  dir="$(mktemp -d)"
  mkdir "$dir/locked"
  cp "$FIXTURES/only-classes/catalog-test-lonely.yaml" "$dir/"
  chmod 000 "$dir/locked"
  run ./catalog.sh --list "$dir"
  chmod 755 "$dir/locked"
  rm -rf "$dir"
  assert_exit 1 || return
  assert_contains "cannot read everything under"
}

test_rejects_unknown_flag() {
  run ./catalog.sh --apply-everything
  assert_exit 1 || return
  assert_contains "usage:"
}

# Discovery passes, so this reaches the cluster check, which must fail before
# any file is sent anywhere.
test_no_cluster_fails_clearly() {
  run env KIND_CLUSTER_NAME=catalog-test-absent ./catalog.sh "$FIXTURES/valid-nested"
  assert_exit 1 || return
  assert_contains "no kubeconfig context 'kind-catalog-test-absent'" || return
  assert_contains "build the platform first"
}

test_default_lists_dev_catalogue() {
  if [ ! -d "$IDP_CONTROLLER_ROOT/gitops/environments/dev" ]; then
    OUT=""
    fail "no dev catalogue at $IDP_CONTROLLER_ROOT; set IDP_CONTROLLER_ROOT"
    return
  fi
  run ./catalog.sh --list
  assert_exit 0 || return
  assert_contains "$IDP_CONTROLLER_ROOT/gitops/environments/dev/product-classes/" || return
  assert_contains "$IDP_CONTROLLER_ROOT/gitops/environments/dev/topologies/"
}

######################################
# cluster cases
######################################
# One folder covers loading: files from nested folders, a file holding two
# resources, and a second load that changes nothing.
test_loads_valid_folder() {
  run ./catalog.sh "$FIXTURES/valid-nested"
  assert_exit 0 || return
  assert_contains "4 valid, 0 failed" || return
  assert_exists productclass catalog-test-chart || return
  assert_exists productclass catalog-test-extra || return
  assert_exists productclass catalog-test-multi || return
  assert_exists tykdeployment catalog-test-stack || return
  assert_exists tykdeployment catalog-test-multi || return
  run ./catalog.sh "$FIXTURES/valid-nested"
  assert_exit 0 || return
  assert_contains "unchanged" || return
  assert_lacks "created"
}

test_malformed_yaml() {
  run ./catalog.sh "$FIXTURES/malformed"
  assert_exit 1 || return
  assert_contains "[ERROR] b-broken.yaml" || return
  assert_contains "1 valid, 1 failed" || return
  assert_absent productclass catalog-test-fine
}

test_invalid_deployment_schema() {
  run ./catalog.sh "$FIXTURES/invalid-schema"
  assert_exit 1 || return
  assert_contains "[ERROR] catalog-test-schema.yaml" || return
  assert_absent tykdeployment catalog-test-schema
}

test_invalid_deployment_dangling_ref() {
  run ./catalog.sh "$FIXTURES/dangling-ref"
  assert_exit 1 || return
  assert_contains "[ERROR] catalog-test-dangling.yaml" || return
  assert_contains "needs ProductClass 'catalog-test-nowhere'" || return
  assert_absent tykdeployment catalog-test-dangling
}

test_disabled_addon_ref_only_warns() {
  run ./catalog.sh --check "$FIXTURES/addon-dangling"
  assert_exit 0 || return
  assert_contains "[WARNING] catalog-test-addons.yaml" || return
  assert_contains "addon 'portal' needs ProductClass 'catalog-test-off-missing'"
}

test_enabled_addon_ref_fails() {
  run ./catalog.sh --check "$FIXTURES/addon-enabled-dangling"
  assert_exit 1 || return
  assert_contains "[ERROR] catalog-test-enabled.yaml" || return
  assert_contains "addon 'portal' needs ProductClass 'catalog-test-on-missing'"
}

test_ref_satisfied_by_cluster() {
  run ./catalog.sh "$FIXTURES/only-classes"
  assert_exit 0 || return
  local dir
  dir="$(mktemp -d)"
  cat > "$dir/catalog-test-uses-cluster.yaml" << 'EOF'
apiVersion: platform.tyk.io/v1alpha1
kind: TykDeployment
metadata:
  name: catalog-test-uses-cluster
spec:
  products:
    - name: catalog-test-lonely
EOF
  run ./catalog.sh --check "$dir"
  rm -rf "$dir"
  assert_exit 0
}

test_wrong_kind() {
  run ./catalog.sh "$FIXTURES/wrong-kind"
  assert_exit 1 || return
  assert_contains "ConfigMap 'catalog-test-configmap' is not a ProductClass or TykDeployment" || return
  assert_absent configmap catalog-test-configmap
}

test_duplicate_resource() {
  run ./catalog.sh "$FIXTURES/duplicate"
  assert_exit 1 || return
  assert_contains "ProductClass 'catalog-test-twice' is also defined in second.yml" || return
  assert_contains "ProductClass 'catalog-test-twice' is also defined in first.yaml" || return
  assert_absent productclass catalog-test-twice
}

test_empty_file() {
  run ./catalog.sh "$FIXTURES/empty-file"
  assert_exit 1 || return
  assert_contains "[ERROR] only-comments.yaml" || return
  assert_contains "holds no resources" || return
  assert_absent productclass catalog-test-present
}

test_atomic_failure() {
  run ./catalog.sh "$FIXTURES/atomic"
  assert_exit 1 || return
  assert_absent productclass catalog-test-atomic || return
  assert_contains "nothing applied"
}

test_check_applies_nothing() {
  run ./catalog.sh --check "$FIXTURES/valid-nested"
  assert_exit 0 || return
  assert_contains "nothing applied" || return
  assert_absent productclass catalog-test-chart
}

test_delete_removes_folder_resources() {
  run ./catalog.sh "$FIXTURES/valid-nested"
  assert_exit 0 || return
  run ./catalog.sh --delete "$FIXTURES/valid-nested"
  assert_exit 0 || return
  assert_absent productclass catalog-test-chart || return
  assert_absent tykdeployment catalog-test-stack
}

test_default_flow_validates() {
  run ./catalog.sh --check
  assert_exit 0 || return
  assert_contains "0 failed"
}

test_install_stops_on_bad_catalogue() {
  local before
  before="$(instanceCount)"
  run env CATALOG="$FIXTURES/atomic" ./install.sh simple-tyk-oss
  assert_exit 1 || return
  assert_contains "nothing was deployed" || return
  [ "$(instanceCount)" = "$before" ] || fail "an instance was created"
}

# With no terminal, install.sh prints the menu and stops before creating
# anything, which shows what it would have offered.
test_install_offers_only_folder_stacks() {
  local before
  before="$(instanceCount)"
  run env CATALOG="$FIXTURES/valid-nested" ./install.sh
  assert_exit 1 || return
  assert_contains "catalog-test-stack" || return
  assert_lacks "simple-tyk-oss" || return
  assert_contains "no terminal to ask on" || return
  [ "$(instanceCount)" = "$before" ] || fail "an instance was created"
}

######################################
# entrypoint
######################################
HAVE_CLUSTER="false"
if haveCluster; then
  HAVE_CLUSTER="true"
  log "cluster $KUBE_CONTEXT reachable, running every case"
else
  warning "no cluster with the platform.tyk.io CRDs at $KUBE_CONTEXT, running offline cases only"
fi

trap cleanup EXIT
cleanup

log "offline"
check test_finds_nested_files_from_relative_folder
check test_missing_folder
check test_empty_folder
check test_folder_without_yaml
check test_file_instead_of_folder
check test_unreadable_subfolder
check test_rejects_unknown_flag
check test_no_cluster_fails_clearly
check test_default_lists_dev_catalogue

log "cluster"
for t in \
  test_loads_valid_folder \
  test_malformed_yaml \
  test_invalid_deployment_schema \
  test_invalid_deployment_dangling_ref \
  test_disabled_addon_ref_only_warns \
  test_enabled_addon_ref_fails \
  test_ref_satisfied_by_cluster \
  test_wrong_kind \
  test_duplicate_resource \
  test_empty_file \
  test_atomic_failure \
  test_check_applies_nothing \
  test_delete_removes_folder_resources \
  test_default_flow_validates \
  test_install_stops_on_bad_catalogue \
  test_install_offers_only_folder_stacks; do
  # Each case starts from a cluster holding no fixture resources, so one
  # case's leftovers cannot satisfy or break the next.
  cleanup
  cluster_check "$t"
done

echo
log "passed $PASSED, failed $FAILED, skipped $SKIPPED"
if [ "$FAILED" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do
    error "  $f"
  done
  exit 1
fi
