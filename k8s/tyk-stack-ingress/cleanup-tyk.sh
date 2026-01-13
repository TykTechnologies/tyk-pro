#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"
source lib.sh

# Parse options
KEEP_INFRA="${KEEP_INFRA:-false}"
KEEP_NAMESPACES="${KEEP_NAMESPACES:-false}"

for param in "$@"; do
	case "$param" in
		--keep-infra) KEEP_INFRA="true" ;;
		--keep-namespaces) KEEP_NAMESPACES="true" ;;
		--help|-h)
			echo "Usage: $0 [OPTIONS]"
			echo ""
			echo "Remove all Tyk deployments for clean testing."
			echo ""
			echo "Options:"
			echo "  --keep-infra       Keep Redis and MongoDB (useful for quick redeploys)"
			echo "  --keep-namespaces  Keep namespaces (don't delete tyk-dp-* namespaces)"
			echo "  -h, --help         Show this help"
			exit 0
			;;
	esac
done

log "Starting Tyk cleanup..."

# Find all data plane namespaces
DP_NAMESPACES=$(kubectl get namespaces -o name 2>/dev/null | grep "tyk-dp-" | cut -d/ -f2 || true)

# Uninstall data planes
for ns in $DP_NAMESPACES; do
	log "Cleaning up data plane in $ns..."
	helm uninstall tyk-data-plane -n "$ns" 2>/dev/null || true
	if [ "$KEEP_INFRA" != "true" ]; then
		helm uninstall redis -n "$ns" 2>/dev/null || true
	fi
done

# Uninstall control plane
log "Cleaning up control plane in tyk namespace..."
helm uninstall tyk-control-plane -n tyk 2>/dev/null || true

# Uninstall infrastructure
if [ "$KEEP_INFRA" != "true" ]; then
	log "Removing infrastructure..."
	helm uninstall redis -n tyk 2>/dev/null || true
	helm uninstall mongo -n tyk 2>/dev/null || true
fi

# Remove toxiproxy
log "Removing toxiproxy..."
kubectl delete -f ../apps/toxiproxy.yaml 2>/dev/null || true

# Remove tools
log "Removing tools (httpbin, k6)..."
kubectl delete -f ../apps/httpbin.yaml 2>/dev/null || true
kubectl delete -f ../apps/k6.yaml 2>/dev/null || true
kubectl delete configmap k6-test-script -n tools 2>/dev/null || true

# Delete namespaces if requested
if [ "$KEEP_NAMESPACES" != "true" ]; then
	for ns in $DP_NAMESPACES; do
		log "Deleting namespace $ns..."
		kubectl delete namespace "$ns" --wait=false 2>/dev/null || true
	done
	kubectl delete namespace tools --wait=false 2>/dev/null || true
fi

# Clean up secrets
log "Cleaning up secrets..."
kubectl delete secret tyk-operator-conf -n tyk 2>/dev/null || true

# Remove toxiproxy.env if exists
rm -f toxiproxy.env 2>/dev/null || true

log "Cleanup complete!"
log ""
log "To redeploy, run: ./run-tyk-cp-dp.sh [toxiproxy=true]"
