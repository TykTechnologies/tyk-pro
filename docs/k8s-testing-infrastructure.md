# Kubernetes Testing Infrastructure Documentation

## Overview

This document describes how Kubernetes-related API tests are run in tyk-analytics and how the Kubernetes environment is set up on CI. This infrastructure spans two repositories:

- **tyk-analytics**: Contains test code and CI workflows
- **tyk-pro**: Contains K8s deployment scripts and infrastructure configuration

---

## CI Workflow (GitHub Actions)

### Primary CI Configuration

**File**: `tyk-analytics/.github/workflows/k8s-api-tests.yaml`

#### Triggers

The K8s tests workflow triggers on:
- Branches with "**k8s**" in the name
- Scheduled runs: Monday and Thursday at 00:00 UTC
- Manual workflow dispatch

#### Test Matrix

The CI runs two test configurations in parallel:

1. **Resilience Tests** (`test_type: resilience`)
   - Uses Toxiproxy for fault injection
   - Command: `pytest -s -m resilience`
   - Requires Toxiproxy deployment

2. **Functional Tests** (`test_type: functional`)
   - Dashboard API tests
   - Command: `pytest -s -m dash_admin`
   - Does not require Toxiproxy

#### CI Execution Steps

```yaml
1. Checkout repositories
   - tyk-analytics (main)
   - tyk-pro (for deployment scripts)

2. Setup Kubernetes
   - Install Kind (Kubernetes in Docker)
   - Create cluster with cloud-provider-kind
   - Install Helm

3. Deploy Tyk Stack
   - Run run-tyk-cp-dp.sh with toxiproxy=true
   - Deploy control plane components
   - Deploy data planes
   - Configure service labels

4. Setup Test Environment
   - Install Python dependencies
   - Generate Toxiproxy environment variables
   - Configure /etc/hosts entries

5. Execute Tests
   - Run pytest with appropriate markers
   - Collect and report results
```

---

## Kubernetes Environment Setup

### Deployment Architecture

The deployment follows this component hierarchy:

```
Kind Cluster (Single-node)
├── Control Plane (tyk namespace)
│   ├── Dashboard (GraphQL API)
│   ├── Gateway (Control Plane Gateway)
│   ├── MDCB (Multi-Data Control Bus)
│   ├── Redis (Control Plane Redis)
│   └── MongoDB (Dashboard Storage)
├── Data Planes (tyk-dp-1, tyk-dp-2, ...)
│   ├── Gateway (Data Plane Gateway)
│   └── Redis (Data Plane Redis)
└── Testing Infrastructure
    ├── Toxiproxy (Fault Injection)
    ├── HTTPBin (Testing Endpoint)
    └── K6 (Load Testing)
```

### Key Deployment Scripts (tyk-pro)

#### 1. run-tyk-cp-dp.sh

**Location**: `k8s/tyk-stack-ingress/run-tyk-cp-dp.sh`

**Purpose**: Main orchestration script for deploying the complete Tyk stack

**Key Functions**:
- Creates Kind cluster with LoadBalancer support
- Deploys control plane using Helm charts
- Deploys multiple data planes (configurable via `NUM_DATA_PLANES`)
- Labels services for Toxiproxy discovery
- Optionally deploys Toxiproxy for resilience testing

**Usage**:
```bash
# Deploy with Toxiproxy
./run-tyk-cp-dp.sh toxiproxy=true

# Deploy without Toxiproxy
./run-tyk-cp-dp.sh
```

#### 2. test-resilience-local.sh

**Location**: `k8s/tyk-stack-ingress/test-resilience-local.sh`

**Purpose**: Local development wrapper for running resilience tests

**Key Functions**:
- Verifies or creates Kind cluster
- Deploys Tyk stack with Toxiproxy
- Loads environment variables from toxiproxy-ci.env
- Executes pytest from tyk-analytics
- Provides debugging utilities (status, logs, cleanup)

**Usage**:
```bash
# Run all resilience tests
./test-resilience-local.sh

# Check deployment status
./test-resilience-local.sh status

# View logs
./test-resilience-local.sh logs
```

#### 3. create-cluster.sh

**Location**: `k8s/tyk-stack-ingress/create-cluster.sh`

**Purpose**: Creates Kind cluster with proper configuration

**Configuration**:
- Single control-plane node
- Port mappings for external access
- Host network access
- Cloud-provider-kind for LoadBalancer IPs

---

## Service Discovery and Toxiproxy Integration

### Service Labeling Convention

Services are labeled during deployment for automatic discovery:

```bash
# Service labels applied in run-tyk-cp-dp.sh
labelService "$namespace" "dashboard-svc" "dashboard"
labelService "$namespace" "gateway-svc" "gateway"
labelService "$namespace" "mdcb-svc" "mdcb"
labelService "$namespace" "redis-svc" "redis"
labelService "$namespace" "mongo-svc" "mongo"
```

**Label Format**: `tyk.io/component=<component-name>`

### Toxiproxy Agent CLI

**Location**: `k8s/apps/toxiproxy-agent/`

**Components**:
- `cli.py` - Main CLI entry point
- `discovery.py` - Kubernetes service discovery logic
- `toxiproxy.yaml` - Kubernetes deployment manifest

**Discovery Process**:

```
1. Query K8s API for services with tyk.io/component label
2. Group services by namespace (cp vs data planes)
3. Extract service addresses (cluster DNS or LoadBalancer IPs)
4. Generate proxy configurations with unique ports
5. Create proxies via Toxiproxy API
6. Output environment variables to toxiproxy-ci.env
```

**Proxy Naming Convention**:
- Control plane: `<component>-cp` (e.g., redis-cp, mongo-cp)
- Data planes: `<component>-dp<n>` (e.g., redis-dp1, redis-dp2)

**Port Assignment Formula**:
```
Base port + (data_plane_index * 1000)

Examples:
- DP1 Redis: 7379 + (1 * 1000) = 8379
- DP2 Redis: 7379 + (2 * 1000) = 9379
```

---

## Test Structure

### Test Markers

**File**: `tyk-analytics/tests/api/pytest.ini`

**Available Markers**:
- `local` - Tests requiring local environment
- `mdcb` - Multi-Data Control Bus tests
- `resilience` - Fault injection tests using Toxiproxy
- `dash_admin` - Dashboard admin API tests
- `dash_api` - Dashboard API tests
- `dind` - Docker-in-Docker tests
- `upgrade` - Upgrade flow tests
- `graphql` - GraphQL feature tests
- `portal` - Portal feature tests
- `streams` - Tyk Streams feature tests
- `ee` - Enterprise Edition feature tests
- `opentelemetry` - OpenTelemetry tests

### Resilience Test Suite

**Location**: `tyk-analytics/tests/api/resilience/`

**Test Files**:
- `cp_down_test.py` - Control plane component failure tests
  - Redis failure scenarios
  - Gateway failure scenarios
  - Dashboard failure scenarios
  - Uses K6 for load during failures

- `dp_redis_down_test.py` - Data plane Redis failure tests
  - Data plane Redis disconnection
  - Connection recovery validation

- `mdcb_down_test.py` - MDCB failure tests
  - MDCB component failures
  - Multi-data plane behavior

**Utilities**:
- `toxiproxy_connector.py` - Toxiproxy API client
  - Proxy creation and deletion
  - Toxic management (slow_close, latency, timeout)
  - Proxy state inspection

- `k6_connector.py` - K6 load testing integration
  - Kubernetes Job submission
  - ConfigMap management
  - Result retrieval

---

## Environment Variables

### Configuration Sources

Environment variables come from multiple sources:

#### 1. Generated by Toxiproxy CLI

**File**: `k8s/tyk-stack-ingress/toxiproxy-ci.env` (generated)

```bash
TOXIPROXY_URL=http://<loadbalancer-ip>:8474
redis-cp=http://<ip>:<port>
mongo=http://<ip>:<port>
dashboard=http://<ip>:<port>
mdcb=http://<ip>:<port>
gateway-cp=http://<ip>:<port>
# Data plane URLs with port offsets
```

#### 2. License Keys

**File**: `.env` in deployment directory

```bash
TYK_DB_LICENSEKEY=<dashboard-license>
TYK_MDCB_LICENSEKEY=<mdcb-license>
```

#### 3. Hardcoded in CI

**File**: `.github/workflows/k8s-api-tests.yaml`

```bash
TYK_TEST_BASE_URL=http://chart-dash.local/
TYK_TEST_GW_URL=http://chart-gw.local/
TYK_TEST_GW_1_ALFA_URL=http://chart-gw-dp-1.local/
TYK_TEST_GW_2_ALFA_URL=http://chart-gw-dp-2.local/
TYK_TEST_GW_SECRET=352d20ee67be67f6340b4c0605b044b7
```

#### 4. Dynamic from K8s Secrets

```bash
USER_API_SECRET=$(kubectl get secret -n tyk tyk-operator-conf \
  -o jsonpath="{.data.TYK_AUTH}" | base64 -d)
```

---

## DNS and Ingress Configuration

### /etc/hosts Management

**Problem**: Kind cluster ingress hostnames need local DNS resolution

**Solution**: k8s-hosts-controller (Go application)

**Location**: `k8s/apps/k8s-hosts-controller/`

**How It Works**:
1. Watches Kubernetes Ingress resources
2. Extracts hostnames from ingress specs
3. Adds entries to /etc/hosts automatically
4. Requires sudo privileges on macOS

**Entry Format**:
```
# TYK-K8S-HOSTS - START
127.0.0.1 chart-dash.local chart-dash.test
127.0.0.1 chart-gw.local chart-gw.test
127.0.0.1 chart-gw-dp-1.local chart-gw-dp-1.test
# TYK-K8S-HOSTS - END
```

---

## Development Workflow

### Local Development Prerequisites

1. **Required Tools**:
   - Docker
   - Kind (Kubernetes in Docker)
   - kubectl
   - Helm
   - Python 3.x
   - pytest

2. **License Keys**:
   - TYK_DB_LICENSEKEY (Dashboard)
   - TYK_MDCB_LICENSEKEY (MDCB)
   - Place in `k8s/tyk-stack-ingress/.env`

3. **Hosts Controller** (macOS):
   ```bash
   cd /Users/buraksekili/projects/w1/k8s-hosts-controller
   sudo ./k8s-hosts-controller
   ```

### Running Tests Locally

**Quick Start**:
```bash
cd /Users/buraksekili/projects/w1/tyk-pro/k8s/tyk-stack-ingress
./test-resilience-local.sh
```

**Manual Steps**:
```bash
# 1. Create cluster
./create-cluster.sh

# 2. Deploy with Toxiproxy
./run-tyk-cp-dp.sh toxiproxy=true

# 3. Load environment
source toxiproxy-ci.env

# 4. Run tests
cd /Users/buraksekili/projects/w1/tyk-analytics
pytest -s -m resilience
```

### Debugging Tips

**Check Service Labels**:
```bash
kubectl get svc -A \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,LABELS:.metadata.labels.tyk\.io/component'
```

**List Toxiproxy Proxies**:
```bash
TOXIPROXY_IP=$(kubectl get svc toxiproxy -n tyk \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s "http://${TOXIPROXY_IP}:8474/proxies" | jq
```

**View Environment Variables**:
```bash
cd k8s/tyk-stack-ingress
./test-resilience-local.sh status
```

**Check Cluster Status**:
```bash
kubectl get nodes
kubectl get pods -A
kubectl get svc -A
```

---

## Architecture Diagrams

### Data Flow: Deployment to Tests

```
[CI Trigger]
    ↓
[Checkout Repos]
    ↓
[Create Kind Cluster] ← create-cluster.sh
    ↓
[Deploy Tyk Stack] ← run-tyk-cp-dp.sh
    ├─ Helm Charts (control-plane-values.yaml, data-plane-values.yaml)
    ├─ Service Labeling (tyk.io/component)
    └─ Toxiproxy Deployment (if enabled)
    ↓
[Service Discovery] ← toxiproxy-agent/cli.py
    ├─ Query K8s API for labeled services
    ├─ Create Toxiproxy proxies
    └─ Generate toxiproxy-ci.env
    ↓
[Configure Test Environment]
    ├─ Source toxiproxy-ci.env
    ├─ Set /etc/hosts entries
    └─ Install Python dependencies
    ↓
[Execute Tests] ← pytest
    ├─ Connect via Toxiproxy
    ├─ Inject faults
    └─ Validate behavior
```

### Service Connectivity

```
┌──────────────────────────────────────────────────────────────┐
│                     Kind Cluster                              │
│                                                               │
│  ┌──────────────────┐        ┌──────────────────┐           │
│  │   Control Plane  │        │   Toxiproxy      │           │
│  │   (tyk ns)       │◄──────►│   (tyk ns)       │           │
│  │                  │ Proxy │                  │           │
│  │ ┌──────────────┐ │       │ ┌──────────────┐ │           │
│  │ │ Dashboard    │ │       │ │ redis-cp     │ │           │
│  │ │ Gateway      │ │       │ │ mongo        │ │           │
│  │ │ MDCB         │ │       │ │ dashboard    │ │           │
│  │ │ Redis        │ │       │ │ mdcb         │ │           │
│  │ │ MongoDB      │ │       │ │ gateway-cp   │ │           │
│  │ └──────────────┘ │       │ └──────────────┘ │           │
│  └──────────────────┘        └────────▲─────────┘           │
│                                       │                      │
│                                       │ HTTP API             │
│                                       │ (Port 8474)          │
└───────────────────────────────────────┼──────────────────────┘
                                        │
┌───────────────────────────────────────┼──────────────────────┐
│                   Tests                │                      │
│                                       │                      │
│  ┌──────────────┐                     │                      │
│  │  pytest      │─────────────────────┘                      │
│  │              │     Toxiproxy Connector                     │
│  │ ┌──────────┐ │                                           │
│  │ │ toxiproxy│ │                                           │
│  │ │ connector│ │                                           │
│  │ └──────────┘ │                                           │
│  └──────────────┘                                           │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

---

## Current Pain Points

### 1. Repository Coupling
- tyk-analytics CI depends on tyk-pro scripts
- Complex cross-repository dependencies
- Changes require coordination between repos

### 2. Hardcoded Values
- URLs scattered across CI, scripts, and tests
- Ports hardcoded in multiple places
- Service names tightly coupled

### 3. Configuration Complexity
- Multiple configuration sources (.env, CI env, generated env)
- Manual setup required for local development
- Difficult to track configuration flow

### 4. Test Infrastructure Fragility
- Tests break when service labels change
- Proxy naming convention tightly coupled
- Port assignment formula changes break tests

### 5. Documentation Gaps
- Scattered knowledge across repositories
- Prerequisites not clearly documented
- Troubleshooting incomplete

---

## File Reference

### tyk-analytics
```
.github/workflows/
├── k8s-api-tests.yaml          # Main K8s CI workflow
└── ci-tests.yml                # General CI tests (no K8s)

tests/api/
├── pytest.ini                  # Test configuration and markers
├── requirements.txt            # Python dependencies
└── resilience/
    ├── cp_down_test.py         # Control plane failure tests
    ├── dp_redis_down_test.py   # Data plane Redis tests
    ├── mdcb_down_test.py       # MDCB failure tests
    └── utils/
        ├── toxiproxy_connector.py  # Toxiproxy API client
        └── k6_connector.py         # K6 integration
```

### tyk-pro
```
.github/workflows/
└── test-square.yml             # CI for tyk-pro

k8s/tyk-stack-ingress/
├── run-tyk-cp-dp.sh            # Main deployment script
├── test-resilience-local.sh    # Local test runner
├── create-cluster.sh           # Kind cluster creation
├── lib.sh                      # Shared functions
├── manifests/
│   ├── control-plane-values.yaml  # Control plane Helm values
│   └── data-plane-values.yaml     # Data plane Helm values
└── toxiproxy-ci.env            # Generated (not in git)

k8s/apps/
├── toxiproxy-agent/
│   ├── cli.py                  # Toxiproxy configuration CLI
│   ├── discovery.py            # K8s service discovery
│   ├── requirements.txt        # Python dependencies
│   └── toxiproxy.yaml          # K8s deployment manifest
└── k8s-hosts-controller/       # /etc/hosts management
    └── main.go
```

---

## Next Steps for Refactoring

Potential improvements to address identified pain points:

1. **Consolidate Infrastructure Code**
   - Move K8s deployment scripts into tyk-analytics
   - Reduce cross-repository dependencies
   - Single source of truth for test infrastructure

2. **Configuration Management**
   - Centralized configuration files
   - Environment variable templating
   - Configuration validation

3. **Enhance Test Infrastructure**
   - Containerized test environment
   - Better test isolation
   - Parallel test execution support

4. **Simplify Local Development**
   - One-command local setup
   - Reduced prerequisites
   - Better developer experience

5. **Improve Observability**
   - Structured logging
   - Test result standardization
   - Enhanced debugging capabilities

---

*Last Updated: 2025-01-13*
