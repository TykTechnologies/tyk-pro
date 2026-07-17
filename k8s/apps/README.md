# Kubernetes Applications

This directory contains Kubernetes manifests for auxiliary applications that support the Tyk stack but are not core components.

## Files

- `httpbin.yaml` - Go implementation of httpbin.org for testing HTTP requests and responses
  - Based on the [go-httpbin](https://github.com/mccutchen/go-httpbin) project
  - Includes readiness and liveness probes to ensure the application is healthy
  - Provides various endpoints for testing different HTTP features (/get, /post, /status, etc.)
  - Runs on port 8080

- `k6.yaml` - k6 load testing tool configuration for performance testing
  - References the external script file `test-script.js`
  - When applying this manifest, use: `kubectl create configmap k6-test-script --from-file=test-script.js=./k8s/apps/test-script.js -n tools`

- `test-script.js` - The k6 load testing script used by k6.yaml
  - Contains the actual test logic for performance testing
  - Configurable via environment variables (API_NAME, TEST_DURATION, TARGET_NAMESPACE)
  - Tests the httpbin /get endpoint and verifies the response structure

- `toxiproxy.yaml` - ToxiProxy for simulating network conditions and testing resilience
  - See `toxiproxy-readme.md` for more details on usage