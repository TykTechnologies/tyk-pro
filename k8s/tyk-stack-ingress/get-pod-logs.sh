#!/usr/bin/env bash

cd "$(dirname "$0")"
source lib.sh

VERSION="${VERSION:-lts}"
NAMESPACE="${NAMESPACE:-tyk-${VERSION}}"

if [ "$#" -lt 1 ]; then
	echo "Usage: $0 POD_PREFIX [kubectl-logs-options...]"
	echo "  POD_PREFIX: prefix to match pod names (e.g., dashboard, gateway, mdcb)"
	echo ""
	echo "Environment:"
	echo "  VERSION   Tyk version (default: lts)"
	echo "  NAMESPACE Override namespace (default: tyk-\$VERSION)"
	echo ""
	echo "Additional args are passed to kubectl logs (e.g., -f, --tail 100, --previous)"
	exit 1
fi

pattern="$1"
shift

# get all pods and filter using shell glob (safe, no regex injection)
pods=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

if [[ -z "$pods" ]]; then
	error "No pods found in namespace '$NAMESPACE'"
	exit 1
fi

found=0
for pod in $pods; do
	if [[ "$pod" == "$pattern"* ]]; then
		log "Pod: $pod"
		kubectl logs "$pod" -n "$NAMESPACE" "$@"
		echo "---"
		((found++))
	fi
done

if [[ $found -eq 0 ]]; then
	warning "No pods matched pattern '$pattern' in namespace '$NAMESPACE'"
fi
