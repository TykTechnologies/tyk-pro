# Resilience Test Failure Analysis

## Problem Summary

The resilience tests in `test-resilience-local.sh` are failing because they're trying to access gateway endpoints using `localhost` URLs instead of the proper Kubernetes ingress hostnames.

**Log Evidence:**
```
22:54:07 INFO Sending API Request to GW 1 alfa, path: http://chart-gw-dp-1.test/open_new/
22:54:07 INFO Sending API Request to GW 1 beta, path: http://localhost:8081/open_new/
```

## Root Cause

The resilience test framework expects **4 separate gateway endpoints**:
- GW 1 alfa: `TYK_TEST_GW_1_ALFA_URL`
- GW 1 beta: `TYK_TEST_GW_1_BETA_URL` ⚠️ **NOT SET**
- GW 2 alfa: `TYK_TEST_GW_2_ALFA_URL`
- GW 2 beta: `TYK_TEST_GW_2_BETA_URL` ⚠️ **NOT SET**

### Current Configuration

**test-resilience-local.sh:77-80** only sets:
```bash
export TYK_TEST_BASE_URL="http://chart-dash.test/"
export TYK_TEST_GW_URL="http://chart-gw.test/"
export TYK_TEST_GW_1_ALFA_URL="http://chart-gw-dp-1.test/"
export TYK_TEST_GW_2_ALFA_URL="http://chart-gw-dp-2.test/"
```

**Missing environment variables:**
- `TYK_TEST_GW_1_BETA_URL`
- `TYK_TEST_GW_2_BETA_URL`

### Fallback Behavior

When beta URLs are not set, the test framework falls back to defaults in `config.py`:

**tyk-analytics/tests/api/config.py:30-34**:
```python
config.GATEWAY_1_ALFA_URL = os.getenv('TYK_TEST_GW_1_ALFA_URL', 'http://localhost:8181/')
config.GATEWAY_1_BETA_URL = os.getenv('TYK_TEST_GW_1_BETA_URL', 'http://localhost:8182/')
config.GATEWAY_2_ALFA_URL = os.getenv('TYK_TEST_GW_2_ALFA_URL', 'http://localhost:8281/')
config.GATEWAY_2_BETA_URL = os.getenv('TYK_TEST_GW_2_BETA_URL', 'http://localhost:8282/')
```

Since `TYK_TEST_GW_1_BETA_URL` is not set, it defaults to `http://localhost:8182/`, but the actual error shows `http://localhost:8081/` which is the base `GATEWAY_URL` fallback.

## Kubernetes Deployment Architecture

The current deployment creates:
- **Data Plane 1**: Single ingress at `chart-gw-dp-1.test` with `replicaCount=1`
- **Data Plane 2**: Single ingress at `chart-gw-dp-2.test` with `replicaCount=2`

**run-tyk-cp-dp.sh:416,423**:
```bash
--set tyk-gateway.gateway.replicaCount=${i} \
--set tyk-gateway.gateway.ingress.hosts[0].host="chart-gw-dp-${i}.test"
```

There are **no separate alfa/beta ingresses**. The Kubernetes service load balances traffic across replicas internally.

## Solutions Implemented

### 1. Fixed Missing Beta URL Environment Variables ✓

Added the missing beta URL exports to point to the same ingress as alfa (test-resilience-local.sh:81-82):

```bash
export TYK_TEST_GW_1_BETA_URL="http://chart-gw-dp-1.test/"
export TYK_TEST_GW_2_BETA_URL="http://chart-gw-dp-2.test/"
```

This way:
- Both GW 1 alfa and GW 1 beta use `http://chart-gw-dp-1.test/`
- Both GW 2 alfa and GW 2 beta use `http://chart-gw-dp-2.test/`
- Kubernetes service handles internal load balancing to replicas

### 2. Fixed k8s-hosts-controller Management ✓

The k8s-hosts-controller was failing silently on macOS due to permission issues. The script tried to manage it but it couldn't write to `/etc/hosts`.

**Solution:** Users now run the controller manually BEFORE running the test script:

```bash
cd ../apps/k8s-hosts-controller
sudo ./k8s-hosts-controller --all-namespaces > /tmp/k8s-hosts-controller.log 2>&1 &
```

**Script Changes:**
- `test-resilience-local.sh`: Removed controller management, added prerequisite checks
- `run-tyk-cp-dp.sh`: Skip controller start when `NO_HOSTS_CONTROLLER=true`
- `run-tyk-cp-dp.sh`: Don't require root when `NO_HOSTS_CONTROLLER=true`

### Why k8s-hosts-controller Failed

On macOS, modifying `/etc/hosts` requires special permissions beyond `sudo`. The controller:
- Started successfully ✓
- Detected all ingresses ✓
- Logged "Updating hosts entries" ✓
- **Silently failed to write** ✗
- **Never logged errors** ✗

This is a macOS security restriction - the writes fail without error reporting.

## Files Involved

1. **tyk-pro/k8s/tyk-stack-ingress/test-resilience-local.sh:77-80** - Missing beta URL exports
2. **tyk-analytics/tests/api/config.py:27-34** - Defines URL fallbacks
3. **tyk-analytics/tests/api/helpers/Requests.py:165-167** - GWRequests initialization
4. **tyk-analytics/tests/api/tests/mdcb_tests/mdcb_base.py:16-19** - Creates gateway objects
5. **tyk-pro/k8s/tyk-stack-ingress/run-tyk-cp-dp.sh:416,423** - Deployment configuration
