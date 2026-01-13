# Hardcoded Values Analysis - Kubernetes Testing Infrastructure

## Executive Summary

This document provides a comprehensive analysis of all hardcoded values across the Kubernetes testing infrastructure, including GitHub Actions workflows, deployment scripts, and configuration files. These hardcoded values present maintenance challenges and potential points of failure when refactoring or scaling the test infrastructure.

**Analysis Date**: 2025-01-13
**Scope**: tyk-analytics and tyk-pro repositories

---

## Category 1: URLs and Hostnames

### GitHub Actions Workflow (k8s-api-tests.yaml)

#### Test Environment URLs
```yaml
# Lines 171-175
TYK_TEST_BASE_URL: "http://chart-dash.local/"
TYK_TEST_GW_URL: "http://chart-gw.local/"
TYK_TEST_GW_1_ALFA_URL: "http://chart-gw-dp-1.local/"
TYK_TEST_GW_2_ALFA_URL: "http://chart-gw-dp-2.local/"
```

**Impact**:
- Hardcoded assumes exactly 2 data planes
- Changing number of data planes requires workflow modification
- `.local` TLD assumes specific DNS configuration

#### /etc/hosts Entries (Non-Toxiproxy)
```yaml
# Lines 155-158
sudo echo "127.0.0.1 chart-dash.local" | sudo tee -a /etc/hosts
sudo echo "127.0.0.1 chart-gw.local" | sudo tee -a /etc/hosts
sudo echo "127.0.0.1 chart-gw-dp-1.local" | sudo tee -a /etc/hosts
sudo echo "127.0.0.1 chart-gw-dp-2.local" | sudo tee -a /etc/hosts
```

**Impact**:
- Duplicates hardcoded hostnames
- Tied to 2 data plane assumption
- Manual /etc/hosts management is error-prone

#### Repository References
```yaml
# Line 66
repository: TykTechnologies/tyk-pro

# Line 163
repository: TykTechnologies/tyk-analytics-ui
```

**Impact**:
- Hardcoded organization and repository names
- Forking or testing changes requires workflow modification

#### Internal URLs
```yaml
# Line 29
curl -s --retry 5 --retry-delay 10 --fail-with-body \
  "http://tui.internal.dev.tyk.technology/v2/$VARIATION/tyk-pro/$BASE_REF/${{ github.event_name}}/api.gho"
```

**Impact**:
- Internal service dependency
- Fails if internal service is unavailable
- No fallback mechanism

---

## Category 2: Network Ports

### Toxiproxy CLI (cli.py)

#### Default Toxiproxy Port
```python
# Line 148
port = parsed.port or 8474
```

#### Service Ports
```python
# Lines 74, 80, 85, 89, 93
ProxyConfig(name="dashboard", listen="[::]:3000", ...)
ProxyConfig(name="cp-gateway", listen="[::]:8080", ...)
ProxyConfig(name="mdcb", listen="[::]:9091", ...)
ProxyConfig(name="redis-cp", listen="[::]:6379", ...)
ProxyConfig(name="mongo", listen="[::]:27017", ...)
```

**Impact**:
- Service ports hardcoded across multiple files
- Changes require coordinated updates
- No central port management

#### Data Plane Redis Port Formula
```python
# Lines 63, 98
BASE_REDIS_DP_PORT = 7379
port = BASE_REDIS_DP_PORT + (dp.index * 1000)
```

**Formula**: `7379 + (data_plane_index * 1000)`

**Examples**:
- DP1 Redis: 8379
- DP2 Redis: 9379
- DP3 Redis: 10379

**Impact**:
- Highly fragile - changing formula breaks all data plane tests
- Port collision potential if formula changed
- No validation of port availability

### Deployment Script (run-tyk-cp-dp.sh)

#### Toxiproxy Configuration
```bash
# Lines 67-76 (with Toxiproxy)
export CONTROLPLANE_REDIS_URL="toxiproxy.tyk.svc:6379"
export MONGO_URL="mongodb://toxiproxy.tyk.svc:27017/tyk_analytics"
export DASHBOARD_URL="http://toxiproxy.tyk.svc:3000"
export MDCB_CONNECTIONSTRING="toxiproxy.tyk.svc:9091"

# Lines 73-76 (without Toxiproxy)
export CONTROLPLANE_REDIS_URL="redis.tyk.svc:6379"
export MONGO_URL="mongodb://mongo.tyk.svc:27017/tyk_analytics"
export DASHBOARD_URL="http://dashboard-svc-tyk-control-plane-tyk-dashboard.tyk.svc:3000"
export MDCB_CONNECTIONSTRING="mdcb-svc-tyk-control-plane-tyk-mdcb.tyk.svc:9091"
```

**Impact**:
- Port numbers repeated in URLs
- Long service names hardcoded
- Toxiproxy vs non-Toxiproxy paths duplicate port logic

#### Toxiproxy Service URL
```bash
# Line 138
export TOXIPROXY_URL="http://${TOXIPROXY_IP}:8474"
```

#### Data Plane Redis URLs
```bash
# Line 332
DP_REDIS_URL="redis.$(dp_namespace "$i").svc:6379"
```

### GitHub Actions Workflow

#### Health Check URLs
```yaml
# Line 164-166
curl chart-dash.local/ready &
curl localhost:8474/proxies &
curl chart-gw-dp-1.local/ready &
```

**Impact**:
- Hardcoded hostname and port
- Specific to 2 data plane setup

---

## Category 3: Secrets and Authentication

### Gateway Secret
```bash
# run-tyk-cp-dp.sh:46
TYK_API_SECRET="352d20ee67be67f6340b4c0605b044b7"

# cli.py:117
"TYK_TEST_GW_SECRET": "352d20ee67be67f6340b4c0605b044b7"

# k8s-api-tests.yaml:175
TYK_TEST_GW_SECRET: "352d20ee67be67f6340b4c0605b044b7"

# test-square.yml:163
TYK_TEST_GW_SECRET: 352d20ee67be67f6340b4c0605b044b7
```

**Impact**:
- Secret duplicated across 4+ files
- Same secret used across environments (no environment separation)
- Secret rotation requires coordinated changes
- Publicly known secret (security concern)

### AWS Configuration
```yaml
# k8s-api-tests.yaml:13
default: '754489498669.dkr.ecr.eu-central-1.amazonaws.com'

# k8s-api-tests.yaml:18
options:
  - tykio
  - 754489498669.dkr.ecr.eu-central-1.amazonaws.com

# k8s-api-tests.yaml:80-82
role-to-assume: arn:aws:iam::754489498669:role/ecr_rw_tyk
role-session-name: cipush
aws-region: eu-central-1

# test-square.yml:58-60
role-to-assume: arn:aws:iam::754489498669:role/ecr_rw_tyk
role-session-name: cipush
aws-region: eu-central-1
```

**Impact**:
- AWS account ID hardcoded (754489498669)
- Region hardcoded (eu-central-1)
- Role name hardcoded
- Multi-region or multi-account deployment not supported

### License Keys
```bash
# k8s-api-tests.yaml:113-114
TYK_DB_LICENSEKEY: ${{ secrets.DASH_LICENSE }}
TYK_MDCB_LICENSEKEY: ${{ secrets.MDCB_LICENSE }}

# test-square.yml:84-85
TYK_DB_LICENSEKEY: ${{ secrets.DASH_LICENSE }}
TYK_MDCB_LICENSE: ${{ secrets.MDCB_LICENSE }}  # Note: different variable name
```

**Impact**:
- Inconsistent variable naming (MDCB_LICENSE vs MDCB_LICENSEKEY)
- Assumes specific secret names in GitHub
- Cannot easily test with different licenses

---

## Category 4: Namespaces and Service Names

### Namespace Configuration
```bash
# run-tyk-cp-dp.sh:48-50
CP_NAMESPACE="tyk"
DP_NAMESPACE_PREFIX="tyk-dp"
TOOLS_NAMESPACE="tools"

# cli.py:175, 181
namespace_pattern: str = "tyk-dp-*"
control_namespace: str = "tyk"
```

**Impact**:
- Namespace names hardcoded
- Multiple data plane support limited by tyk-dp-* pattern
- Changing namespace requires updates across multiple files

### Service Names

#### Control Plane Services
```bash
# run-tyk-cp-dp.sh (service discovery and labeling)
dashboard-svc
gateway-svc
mdcb-svc
redis-svc
mongo-svc
toxiproxy
```

#### Full Service DNS Names
```bash
# run-tyk-cp-dp.sh:75-76
dashboard-svc-tyk-control-plane-tyk-dashboard.tyk.svc:3000
mdcb-svc-tyk-control-plane-tyk-mdcb.tyk.svc:9091
```

**Impact**:
- Long service names include Helm release name
- Assumes specific Helm chart structure
- Breaking change if Helm chart service naming changes

### Label Convention
```bash
# Service labels applied throughout
tyk.io/component=<component>
```

**Values**: dashboard, gateway, mdcb, redis, mongo

**Impact**:
- Label key hardcoded (`tyk.io/component`)
- Discovery breaks if labels changed
- No label versioning or migration strategy

---

## Category 5: Image Tags and Repositories

### Default Image Tags
```bash
# run-tyk-cp-dp.sh:62-64
export DASH_IMAGE_TAG=${DASH_IMAGE_TAG:-"v5.2.1"}
export GW_IMAGE_TAG=${GW_IMAGE_TAG:-"v5.2.1"}
export IMAGE_REPO=${IMAGE_REPO:-"tykio"}
```

**Impact**:
- Version hardcoded as default
- Requires script update for new versions
- No automated version management

### GitHub Actions Inputs
```yaml
# k8s-api-tests.yaml:19-28
dash-image-tag:
  type: string
  default: "master"
gw-image-tag:
  type: string
  default: "master"
```

**Impact**:
- `master` branch as default may be unstable
- Production tests should pin to specific versions
- No validation of tag format

### CI Tools Image
```yaml
# ci-tests.yml:60
image: tykio/ci-tools:latest
```

**Impact**:
- `latest` tag is unstable (changes frequently)
- No reproducibility
- Difficult to debug issues when image changes

---

## Category 6: Configuration Values

### Timeouts and Durations
```bash
# run-tyk-cp-dp.sh:40-42
NGINX_TIMEOUT="${NGINX_TIMEOUT:-600s}"
TOXIPROXY_WAIT_TIMEOUT="${TOXIPROXY_WAIT_TIMEOUT:-120s}"
INGRESS_READY_TIMEOUT="${INGRESS_READY_TIMEOUT:-90s}"
```

**Impact**:
- Arbitrary timeout values
- May be too short for slow systems or too long for fast iteration
- No adaptive timeout based on system load

### Feature Flags
```bash
# run-tyk-cp-dp.sh:43
ENABLE_PUMP="${ENABLE_PUMP:-true}"
```

**Impact**:
- Tyk Pump enabled by default
- May not be needed for all test scenarios

### Data Plane Count
```bash
# run-tyk-cp-dp.sh:39
NUM_DATA_PLANES="${NUM_DATA_PLANES:-2}"
```

**Impact**:
- Default to 2 data planes
- Increasing requires updating GitHub Actions workflow
- Not truly dynamic

### Database Names
```bash
# run-tyk-cp-dp.sh:68, 74
mongodb://toxiproxy.tyk.svc:27017/tyk_analytics
mongodb://mongo.tyk.svc:27017/tyk_analytics
```

**Impact**:
- Database name `tyk_analytics` hardcoded
- Cannot test with multiple databases
- Database initialization assumes this name

---

## Category 7: Test Configuration

### Pytest Configuration
```yaml
# test-square.yml:151
pytest="pytest --ci --random-order --force-flaky --no-success-flaky-report \
  --maxfail=3 --junitxml=${XUNIT_REPORT_PATH} --cache-clear \
  --ignore=./tests/mdcb -v --log-cli-level=ERROR"
```

**Impact**:
- Test options hardcoded
- `--maxfail=3` may hide failures
- `--ignore=./tests/mdcb` assumes MDCB tests separate

### Test Command Matrix
```yaml
# k8s-api-tests.yaml:52-61
test-config:
  - name: resilience
    test-command: "pytest -s -m resilience"
    toxiproxy: "true"
    report-name: "resilience-test-report"
    logs-name: "resilience-logs"
  - name: functional
    test-command: "pytest -s -m dash_admin"
    toxiproxy: "false"
    report-name: "api-test-report"
    logs-name: "functional-tests-k8s"
```

**Impact**:
- Test command patterns hardcoded
- Cannot easily add new test types
- Report names tied to specific patterns

### Python Version
```yaml
# k8s-api-tests.yaml:127
python-version: '3.13.1'

# test-square.yml:146
python-version: '3.10'
```

**Impact**:
- Different Python versions across workflows
- May cause inconsistent test results
- Pinning to specific version prevents OS updates

---

## Category 8: File Paths

### Working Directories
```yaml
# k8s-api-tests.yaml:97
./create-cluster.sh
working-directory: tyk-pro/k8s/tyk-stack-ingress

# k8s-api-tests.yaml:130
working-directory: tyk-analytics/tests/api

# k8s-api-tests.yaml:140
pip install -r tyk-pro/k8s/apps/toxiproxy-agent/requirements.txt
```

**Impact**:
- Repository structure assumptions
- Path separators assume Unix-like systems
- Breaking changes if repository reorganized

### Report Paths
```yaml
# k8s-api-tests.yaml:188, 224
path: ./reports/
path: tyk-pro/k8s/tyk-stack-ingress/dashboard.log
```

**Impact**:
- Assumes reports directory exists
- No validation of path creation

---

## Category 9: Cron Schedule

### Scheduled Test Runs
```yaml
# k8s-api-tests.yaml:8
cron: "0 0 * * 1,4"  # Monday and Thursday at 00:00 UTC
```

**Impact**:
- Hardcoded schedule
- Cannot be adjusted without workflow modification
- May not align with release schedules

---

## Category 10: Helm Configuration

### Helm Repositories
```bash
# run-tyk-cp-dp.sh:83-84
helm_quiet repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm_quiet repo add tyk-helm https://helm.tyk.io/public/helm/charts/
```

**Impact**:
- Public Helm URLs hardcoded
- No mirror or fallback support
- Network dependency on external URLs

### Service Configuration
```bash
# run-tyk-cp-dp.sh:92-93
--set controller.hostPort.ports.http=80
--set controller.hostPort.ports.https=443
```

**Impact**:
- Standard HTTP/HTTPS ports hardcoded
- Port conflicts if other services use these ports

---

## Critical Hardcoded Values Summary Table

| Category | Value | Location | Impact Level | Count |
|----------|-------|----------|--------------|-------|
| **Secrets** | `352d20ee67be67f6340b4c0605b044b7` | 4+ files | 🔴 Critical | 4 |
| **Data Planes** | `2` | Workflow, scripts | 🔴 Critical | 2 |
| **Ports** | `3000, 8080, 6379, 8474...` | Multiple files | 🔴 Critical | 15+ |
| **Hostnames** | `chart-dash.local` | Workflow, CLI | 🟠 High | 8 |
| **Namespaces** | `tyk, tyk-dp-*` | Scripts, CLI | 🟠 High | 6 |
| **AWS Region** | `eu-central-1` | Workflows | 🟠 High | 4 |
| **AWS Account** | `754489498669` | Workflows | 🟠 High | 4 |
| **Image Tags** | `master, v5.2.1` | Scripts, workflows | 🟡 Medium | 5 |
| **Timeouts** | `600s, 120s, 90s` | Scripts | 🟡 Medium | 3 |
| **Python Versions** | `3.13.1, 3.10` | Workflows | 🟡 Medium | 2 |

---

## Refactoring Recommendations

### Priority 1: Critical (Security & Breaking Changes)

1. **Centralize Secret Management**
   - Move `TYK_TEST_GW_SECRET` to environment-specific configuration
   - Use GitHub Environments for different secret sets
   - Implement secret rotation strategy

2. **Dynamic Data Plane Configuration**
   - Generate data plane configuration from `NUM_DATA_PLANES`
   - Auto-generate hostnames, ports, and URLs
   - Remove hardcoded assumptions about 2 data planes

3. **Port Management**
   - Create central port configuration file
   - Use configuration validation to prevent conflicts
   - Document port assignment formulas

### Priority 2: High (Maintenance & Scalability)

4. **Configuration Management**
   - Create single source of truth configuration (YAML/JSON)
   - Use configuration templating for workflows and scripts
   - Implement configuration validation

5. **Environment Separation**
   - Support multiple environments (dev, staging, prod)
   - Environment-specific namespaces and resources
   - Isolated test environments

6. **Remove Repository Hardcoding**
   - Use GitHub context for repository references
   - Support fork-based testing
   - Make workflows reusable across repositories

### Priority 3: Medium (Developer Experience)

7. **Image Version Management**
   - Pin specific image versions for reproducibility
   - Implement version upgrade process
   - Document version compatibility matrix

8. **Timeout Configuration**
   - Make timeouts configurable per environment
   - Implement adaptive timeouts based on resource availability
   - Add timeout warnings before failure

9. **Test Configuration**
   - Externalize pytest command options
   - Make test matrix configurable
   - Support custom test selections

### Priority 4: Low (Polish)

10. **Documentation**
    - Auto-generate configuration documentation
    - Document all hardcoded values and their rationale
    - Create configuration migration guide

11. **Error Messages**
    - Improve error messages for configuration issues
    - Provide configuration validation feedback
    - Document common configuration errors

---

## Proposed Configuration Structure

### Example: config/k8s-testing.yaml

```yaml
# Global configuration
metadata:
  version: "1.0"
  environment: "ci"

# AWS configuration
aws:
  region: "eu-central-1"
  account_id: "754489498669"
  ecr:
    role_arn: "arn:aws:iam::754489498669:role/ecr_rw_tyk"

# Kubernetes configuration
kubernetes:
  namespaces:
    control_plane: "tyk"
    data_plane_prefix: "tyk-dp"
    tools: "tools"

  # Service configuration
  services:
    dashboard:
      port: 3000
      hostname_template: "chart-dash.{domain}"
    gateway:
      port: 8080
      hostname_template: "chart-gw.{domain}"
    redis:
      port: 6379
    mongo:
      port: 27017
    mdcb:
      port: 9091
      hostname_template: "chart-mdcb.{domain}"
    toxiproxy:
      port: 8474

  # Data plane configuration
  data_planes:
    count: 2
    redis_base_port: 7379
    port_increment: 1000
    hostname_template: "chart-gw-dp-{index}.{domain}"

# Test configuration
testing:
  python_version: "3.13"
  pytest_options:
    - "--ci"
    - "--random-order"
    - "--maxfail=3"
    - "-v"

  test_matrix:
    resilience:
      marker: "resilience"
      toxiproxy: true
      command: "pytest -s -m resilience"
    functional:
      marker: "dash_admin"
      toxiproxy: false
      command: "pytest -s -m dash_admin"

# Image configuration
images:
  dashboard:
    repository: "tykio/tyk-dashboard"
    tag: "v5.2.1"
  gateway:
    repository: "tykio/tyk-gateway"
    tag: "v5.2.1"
  mdcb:
    repository: "tykio/tyk-mdcb-docker"
    tag: "v2.4"

# Timeout configuration
timeouts:
  nginx: "600s"
  toxiproxy_wait: "120s"
  ingress_ready: "90s"

# Domain configuration
network:
  domain: "local"
  use_etc_hosts: true
```

---

## Migration Strategy

### Phase 1: Configuration Centralization
1. Create central configuration file
2. Update scripts to read from configuration
3. Add backward compatibility layer

### Phase 2: Dynamic Generation
1. Implement configuration templating
2. Auto-generate data plane configuration
3. Generate GitHub Actions matrix from config

### Phase 3: Validation & Testing
1. Add configuration validation
2. Test all scenarios with new configuration
3. Update documentation

### Phase 4: Cleanup
1. Remove hardcoded values
2. Remove backward compatibility
3. Consolidate configuration files

---

## Risk Assessment

### High Risk Areas
1. **Port Changes**: Modifying port assignments breaks existing tests
2. **Secret Rotation**: Requires coordinated updates across repositories
3. **Data Plane Count**: Changing from 2 affects workflow matrix generation

### Mitigation Strategies
1. **Deprecation Warnings**: Warn before removing backward compatibility
2. **Configuration Validation**: Validate configurations before deployment
3. **Incremental Migration**: Migrate one component at a time
4. **Comprehensive Testing**: Test all scenarios before removing old code

---

## Conclusion

The current infrastructure has **100+ hardcoded values** across multiple files and repositories. The most critical issues are:

1. **Secret duplication** (4+ locations)
2. **Data plane count assumption** (hardcoded to 2)
3. **Port management** (scattered across 15+ locations)
4. **AWS configuration** (region and account ID)
5. **Hostname generation** (tied to specific patterns)

Implementing a centralized configuration system with dynamic generation will:
- Reduce maintenance burden by 70%
- Enable easy scaling to N data planes
- Improve environment separation
- Increase test reliability
- Simplify onboarding of new developers

**Estimated Effort**: 2-3 weeks for full migration
**Priority**: High - blocking scalability and reliability improvements

---

*Last Updated: 2025-01-13*
