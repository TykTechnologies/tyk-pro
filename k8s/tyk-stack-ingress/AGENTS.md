## Build & Run

Prerequisites:
- Kind cluster running (create with `./create-cluster.sh`)
- kubectl configured for the cluster
- helm installed
- helmfile installed (for new deployment method)
- python3 with kubernetes library (for toxiproxy-agent)

Deploy Tyk stack:
```bash
# Traditional method (current)
./run-tyk-cp-dp.sh toxiproxy=true

# Helmfile method (new - for multi-version deployments)
# Set env vars first
export TYK_DB_LICENSEKEY=<license>
export TYK_MDCB_LICENSEKEY=<license>
helmfile apply

# Deploy with toxiproxy (use --state-values-set, not --set)
helmfile apply --state-values-set useToxiproxy=true

# Deploy specific version
helmfile -l version=v5-8 apply

# Deploy control plane only
helmfile -l version=v5-8,tier=cp apply
```

Create Kind cluster:
```bash
./create-cluster.sh
```

## Validation

Run these after implementing to get immediate feedback:

**Shell scripts:**
```bash
shellcheck run-tyk-cp-dp.sh lib.sh
```

**Helmfile syntax:**
```bash
TYK_DB_LICENSEKEY=test TYK_MDCB_LICENSEKEY=test helmfile template > /dev/null
TYK_DB_LICENSEKEY=test TYK_MDCB_LICENSEKEY=test helmfile lint
TYK_DB_LICENSEKEY=test TYK_MDCB_LICENSEKEY=test helmfile list
```

**YAML syntax:**
```bash
yamllint manifests/*.yaml
yamllint versions/*/version.yaml
```

**Verify deployment (requires cluster):**
```bash
helmfile list
kubectl get ns | grep tyk
kubectl get pods -n tyk-v5-8
kubectl get pods -n tyk-v5-8-dp-1
```

**Test resilience (requires toxiproxy=true deployment):**
```bash
# From tyk-analytics/tests/api with mirrord
mirrord exec -f tests/.mirrord/mirrord.json -- pytest -s -m resilience
```

## Operational Notes

Required environment variables (set in `.env` file):
- `TYK_DB_LICENSEKEY` - Dashboard license
- `TYK_MDCB_LICENSEKEY` - MDCB license

Optional (configured in `versions/*/version.yaml`):
- `imageRepo` - Docker registry (default: tykio, or ECR URL)
- `dashTag` - Dashboard image tag (default: v5.11.1)
- `gwTag` - Gateway image tag (default: v5.11.1)
- `numDataPlanes` - Number of data planes (default: 2)

ECR images require AWS credentials and `ecrcred` secret creation.

Toxiproxy agent CLI location: `../apps/toxiproxy-agent/cli.py`

## Codebase Patterns

**Helm upgrades** use `--wait --atomic` for reliability

**Service labeling** with `tyk.io/component=<name>`:
- dashboard, gateway, mdcb, pump, redis, mongo

**Namespaces (version-scoped):**
- Control plane: `tyk-<version>` (e.g., `tyk-v5-8`)
- Data planes: `tyk-<version>-dp-<n>` (e.g., `tyk-v5-8-dp-1`)
- Tools: `tools`
- Toxiproxy: `toxiproxy`

**Ingress hostnames:**
- Dashboard: `chart-dash-<version>.test`
- CP Gateway: `chart-gw-<version>.test`
- DP Gateways: `chart-gw-<version>-dp-<n>.test`

**CI test expectations** (from tyk-analytics workflow):
- Tests run with mirrord to access cluster services
- Service URLs use `*.svc.cluster.local` format
- Toxiproxy URL: `http://toxiproxy.toxiproxy.svc:8474`
