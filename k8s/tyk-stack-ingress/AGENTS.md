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
helmfile -l version=lts apply

# Deploy control plane only
helmfile -l version=lts,tier=cp apply

# Deploy one topology at a specific version (via the script, which resolves
# images and writes the .ports.yaml/.images.yaml that helmfile reads)
TOPOLOGY=master GW_IMAGE_TAG=release-5.8 DASH_IMAGE_TAG=release-5.8 \
  IMAGE_REPO_TYPE=ecr ./run-tyk-cp-dp.sh toxiproxy=true
```

Note: a bare `helmfile apply` needs `versions/<topo>/.ports.yaml` and
`.images.yaml` to exist, so run `run-tyk-cp-dp.sh` at least once first. Helmfile
also honours `TOPOLOGY` and skips the topologies it does not select.

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
kubectl get pods -n tyk-lts
kubectl get pods -n tyk-lts-dp-1
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
- `imageRepoType` - `official` or `ecr`; selects the image names to use
- `dashTag` - Dashboard image tag
- `gwTag` - Gateway image tag
- `mdcbTag` - MDCB image tag
- `numDataPlanes` - Number of data planes (default: 2)
- `versionIndex` - Toxiproxy port band for this topology

Optional environment variables, which override `version.yaml`:
- `TOPOLOGY` - deploy only this `versions/<name>` topology (default: all of them)
- `IMAGE_REPO`, `IMAGE_REPO_TYPE` - registry for gateway and dashboard
- `GW_IMAGE_TAG`, `DASH_IMAGE_TAG` - gateway and dashboard tags
- `MDCB_IMAGE_REPO`, `MDCB_IMAGE_REPO_TYPE`, `MDCB_IMAGE_TAG` - MDCB, which
  versions independently and usually stays on an official release while the
  gateway and dashboard move

Exporting any image override requires `TOPOLOGY`, since one set of tags cannot
describe several version lines - the script fails rather than applying them
everywhere. The same values read from `.env` are treated as local defaults: used
when one topology is selected, skipped with a warning otherwise.

`run-tyk-cp-dp.sh` resolves these into `versions/<topo>/.images.yaml` (gitignored,
like `.ports.yaml`) and logs every effective image; `helmfile.yaml.gotmpl` reads
that file rather than `version.yaml`. Keeping resolution in one place is what
stops the script's ECR setup and the helm render from disagreeing - and the tags
being unreadable from helmfile is what made the CI version matrix silently inert
(TT-17949).

ECR images require AWS credentials. The script creates the `ecrcred` secret and
attaches it to the `default` ServiceAccount in the control plane namespace *and*
each data plane namespace - the DP gateways pull the same private image, and no
Tyk chart here enables a dedicated ServiceAccount.

Toxiproxy agent CLI location: `../apps/toxiproxy-agent/cli.py`

## Codebase Patterns

**Helm upgrades** use `--wait --atomic` for reliability

**Service labeling** with `tyk.io/component=<name>`:
- dashboard, gateway, mdcb, pump, redis, mongo

**Namespaces (version-scoped):**
- Control plane: `tyk-<version>` (e.g., `tyk-lts`)
- Data planes: `tyk-<version>-dp-<n>` (e.g., `tyk-lts-dp-1`)
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
