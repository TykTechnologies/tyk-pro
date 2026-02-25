#!/bin/bash

# Check if a parameter was provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 POD_NAME_START"
    exit 1
fi

# Check if NAMESPACE is already defined, if not, set to "tyk"
if [ -z "$NAMESPACE" ]; then
    NAMESPACE="tyk"
fi

# Pod name pattern to search for, taken from the first command line argument
POD_NAME_START="$1"

# Find pods by name starting with the provided argument and get logs
kubectl get pods -n $NAMESPACE --no-headers=true | awk "/^$POD_NAME_START/{print \$1}" | while read pod_name; do
    echo "Showing logs for pod: $pod_name"
    kubectl logs "$pod_name" -n $NAMESPACE
    echo "------------------------------------------------"
done