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

### Simplified Workflow (NEW)

The unified setup scripts provide a simplified developer experience with a single command for both infrastructure setup and testing.

#### Stage 1: One-Time Infrastructure Setup

**Run this once at the start of your day:**

```bash
cd /Users/buraksekili/projects/w1/tyk-pro/k8s/tyk-stack-ingress

# Deploy infrastructure (with or without Toxiproxy)
./setup.sh              # Basic stack
./setup.sh --toxiproxy  # With resilience testing tools
```

**What it does:**
- Creates Kind cluster (idempotent - safe to run again)
- Deploys Tyk control plane (Dashboard, MDCB, Gateway, Redis, MongoDB)
- Deploys N data planes (default: 2)
- Starts k8s-hosts-controller (manages /etc/hosts automatically)
- Optionally deploys Toxiproxy for resilience testing

**All operations are idempotent** - running multiple times is safe!

#### Stage 2: Iterative Testing

**Run this for every code change:**

```bash
cd /Users/buraksekili/projects/w1/tyk-analytics

# Run API tests
./scripts/k8k-test.sh test api

# Run resilience tests
./scripts/k8k-test.sh test resilience

# Run with custom marker
./scripts/k8k-test.sh test api --marker "dash_admin and not slow"
```

**What it does:**
- Locates tyk-pro repository (env var, default path, or temp clone)
- Ensures infrastructure is deployed (calls setup.sh if needed)
- Builds Dashboard Docker image
- Loads image into Kind cluster
- Restarts Dashboard deployment
- Runs pytest with specified markers

**Quick iteration cycle:**
1. Make code changes
2. Run `./scripts/k8k-test.sh test api`
3. See results in ~30-60 seconds

### Local Development Prerequisites

#### Required Tools
- Docker
- Kind (Kubernetes in Docker)
- kubectl
- Helm (used by setup scripts)
- Go 1.21+ (for building Dashboard)
- Python 3.x
- pytest

#### License Keys
Create `k8s/tyk-stack-ingress/.env`:
```bash
TYK_DB_LICENSEKEY=<dashboard-license>
TYK_MDCB_LICENSEKEY=<mdcb-license>
```

#### Optional: Set tyk-pro Location
```bash
# If tyk-pro is not in the default Go workspace
export TYK_PRO_PATH=/path/to/tyk-pro
```

### Running Tests Locally

#### Quick Start (Recommended)

```bash
# 1. Setup infrastructure (once)
cd /Users/buraksekili/projects/w1/tyk-pro/k8s/tyk-stack-ingress
./setup.sh --toxiproxy

# 2. Run tests (for each code change)
cd /Users/buraksekili/projects/w1/tyk-analytics
./scripts/k8k-test.sh test resilience
```

#### Manual Steps (Legacy)

```bash
# 1. Create cluster
cd /Users/buraksekili/projects/w1/tyk-pro/k8s/tyk-stack-ingress
./create-cluster.sh

# 2. Deploy with Toxiproxy
./run-tyk-cp-dp.sh toxiproxy=true

# 3. Load environment
source toxiproxy-ci.env

# 4. Run tests
cd /Users/buraksekili/projects/w1/tyk-analytics
pytest -s -m resilience
```

**Note**: The manual steps are still supported but the unified scripts are recommended for better developer experience.

## New Architecture Overview

The unified testing architecture consists of two primary scripts with clear separation of concerns:

### Script Responsibilities

#### tyk-pro/k8s/tyk-stack-ingress/setup.sh (Infrastructure)

**Purpose**: Deploy complete K8s testing infrastructure

**Interface**:
```bash
setup.sh [--toxiproxy]
```

**Responsibilities**:
1. Validates prerequisites (Docker, kubectl, kind, licenses)
2. Creates Kind cluster with cloud-provider-kind
3. Deploys ingress-nginx with LoadBalancer support
4. Starts k8s-hosts-controller via manager script
5. Deploys Tyk control plane (Dashboard, MDCB, Gateway, Redis, MongoDB)
6. Deploys N data planes (default: 2)
7. Optionally deploys Toxiproxy for resilience testing

**Key Features**:
- Fully idempotent - safe to run multiple times
- Uses existing scripts (create-cluster.sh, run-tyk-cp-dp.sh)
- Checks if k8s-hosts-controller already running
- Uses `helm upgrade --install` for all deployments
- Clear warnings about cleanup procedures

#### tyk-analytics/scripts/k8k-test.sh (Test Orchestration)

**Purpose**: Orchestrate build, deploy, and test workflow

**Interface**:
```bash
k8k-test.sh test api                    # All API tests
k8k-test.sh test resilience             # Resilience tests
k8k-test.sh test api --marker "dash_admin and not slow"  # Custom
```

**Responsibilities**:
1. Locates tyk-pro repository (env var → default → temp clone)
2. Ensures infrastructure is deployed (calls tyk-pro setup.sh)
3. Calls build-dashboard.sh to construct Dashboard image
4. Loads image into Kind cluster
5. Restarts Dashboard deployment
6. Waits for Dashboard to be ready
7. Executes pytest with appropriate markers

**Key Features**:
- Auto-detects CI mode via `TYK_SETUP_CI` environment variable
- CI mode: Pulls images from registry
- Local mode: Builds and loads images
- Logs which tyk-pro location is being used
- Supports custom pytest markers for flexibility

#### tyk-analytics/scripts/build-dashboard.sh (Image Builder)

**Purpose**: Build and load Dashboard Docker image

**Interface**:
```bash
build-dashboard.sh [image-tag]  # Default: dev
```

**Responsibilities**:
1. Builds Dashboard binary using Makefile
2. Creates Docker image with specified tag
3. Loads image into Kind cluster
4. Restarts Dashboard deployment to use new image
5. Waits for rollout to complete

**Key Features**:
- Validates prerequisites (Docker, kind, Go)
- Checks if Dashboard deployment exists before restarting
- Configurable image name and tag
- Comprehensive error handling

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    Developer Workflow                        │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌─────────────────┐      ┌────────────────────────────────┐ │
│  │ tyk-pro         │      │ tyk-analytics                 │ │
│  │                 │      │                               │ │
│  │ setup.sh        │─────>│ k8k-test.sh                   │ │
│  │ (Infrastructure)│      │ (Test Orchestrator)           │ │
│  └─────────────────┘      └────────────────────────────────┘ │
│           │                         │                        │
│           │ calls                   │ calls                  │
│           ▼                         ▼                        │
│  ┌─────────────────┐      ┌────────────────────────────────┐ │
│  │ create-cluster  │      │ build-dashboard.sh             │ │
│  │ run-tyk-cp-dp   │      │ (Image Builder)                │ │
│  │ k8s-hosts-ctl   │      └────────────────────────────────┘ │
│  └─────────────────┘                  │                        │
│           │                            │                        │
│           │                            │ loads                  │
│           ▼                            ▼                        │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │              Kind Cluster (K8s)                          │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │ │
│  │  │ Control Plane│  │ Data Planes  │  │ Toxiproxy    │  │ │
│  │  │ (Dashboard)  │  │ (Gateway)    │  │ (Optional)   │  │ │
│  │  └──────────────┘  └──────────────┘  └──────────────┘  │ │
│  └──────────────────────────────────────────────────────────┘ │
│           │                            ▲                        │
│           │ restarts                   │                        │
│           ▼                            │                        │  ┌─────────────────┐
│  ┌─────────────────────────────────────────────────────────┐ │  │                 │
│  │              k8s-hosts-controller                       │ │  │    pytest       │
│  │         (manages /etc/hosts)                            │ │  │  (Test Runner)  │
│  └─────────────────────────────────────────────────────────┘ │  └─────────────────┘
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

### Benefits of New Architecture

1. **Separation of Concerns**
   - Infrastructure logic stays in tyk-pro
   - Test logic stays in tyk-analytics
   - Each repository owns its domain

2. **Improved Developer Experience**
   - Single command for infrastructure setup
   - Single command for testing
   - Automatic detection of CI vs local mode

3. **Idempotency**
   - All operations safe to run multiple times
   - No need to remember current state

4. **Reusability**
   - Other projects can use tyk-pro infrastructure
   - Test patterns apply to any Tyk component

5. **Clear Communication**
   - Well-defined interfaces (env vars, exit codes)
   - Logs explain what's happening
   - Error messages guide resolution

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
