# k8s-hosts-controller

A Kubernetes controller that watches Ingress resources and automatically syncs their hostnames and LoadBalancer IPs to `/etc/hosts`. This enables local development environments to access Kubernetes services via hostnames without manual `/etc/hosts` management or port-forwards.

## Problem

When running resilience tests with Toxiproxy in local Kubernetes environments (Kind/minikube), using `kubectl port-forward` causes issues:

1. When Toxiproxy disables a proxy, the port-forward process terminates
2. When the proxy is re-enabled, port-forward remains dead
3. Tests fail with "Connection refused" errors

## Solution

This controller eliminates port-forwards by:

1. Using NGINX Ingress Controller with LoadBalancer service type
2. Watching Ingress resources in specified namespaces
3. Extracting hostnames from `spec.rules[].host`
4. Extracting IPs from `status.loadBalancer.ingress[0].ip`
5. Updating `/etc/hosts` with hostname-to-IP mappings

## Prerequisites

- Go 1.22+
- Kind cluster with [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind) for LoadBalancer support
- sudo access (for writing to `/etc/hosts`)

## Usage

### Build

```bash
go build -o k8s-hosts-controller .
```

### Run

Watch specific namespaces:
```bash
sudo ./k8s-hosts-controller --namespaces tyk,tyk-dp-1,tyk-dp-2
```

Watch all namespaces:
```bash
sudo ./k8s-hosts-controller --all-namespaces
```

### Cleanup

Remove all managed entries from `/etc/hosts`:
```bash
sudo ./k8s-hosts-controller --cleanup
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--namespaces` | Comma-separated namespaces to watch | (required unless `--all-namespaces`) |
| `--all-namespaces` | Watch all namespaces | `false` |
| `--hosts-file` | Path to hosts file | `/etc/hosts` |
| `--marker` | Marker for managed entries | `TYK-K8S-HOSTS` |
| `--cleanup` | Remove all managed entries and exit | `false` |
| `--verbose` | Enable verbose logging | `false` |

## How It Works

The controller uses `controller-runtime` to watch Ingress resources:

1. **Create/Update**: When an Ingress is created or updated:
   - Extracts hostnames from `spec.rules[].host`
   - Extracts IP from `status.loadBalancer.ingress[0].ip`
   - If no IP yet, requeues after 30 seconds
   - Updates `/etc/hosts` with entries in a marked block

2. **Delete**: When an Ingress is deleted:
   - Removes the corresponding entries from `/etc/hosts`

3. **Shutdown**: On SIGTERM/SIGINT:
   - Cleans up all managed entries from `/etc/hosts`

### Hosts File Format

Entries are managed within marked blocks:
```
# existing entries...

#### BEGIN TYK-K8S-HOSTS ####
# Ingress: tyk/dashboard-ingress
172.18.0.100	chart-dash.local
# Ingress: tyk/gateway-ingress
172.18.0.100	chart-gw.local
#### END TYK-K8S-HOSTS ####
```

## Integration with Resilience Tests

The `run-tyk-cp-dp.sh` script automatically:

1. Deploys NGINX Ingress with LoadBalancer type
2. Builds and starts k8s-hosts-controller
3. Waits for hosts entries to sync

To run resilience tests locally:

```bash
cd k8s/tyk-stack-ingress

# Setup (creates cluster, deploys stack, starts hosts controller)
./test-resilience-local.sh setup

# Run tests
./test-resilience-local.sh test

# Cleanup
./test-resilience-local.sh cleanup
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      Local Machine                               │
│                                                                  │
│  ┌────────────────────┐      ┌─────────────────────────────┐   │
│  │ k8s-hosts-controller│      │       /etc/hosts            │   │
│  │                    │─────▶│ 172.18.0.100 chart-dash.local│   │
│  │ Watches Ingress    │      │ 172.18.0.100 chart-gw.local  │   │
│  └─────────┬──────────┘      └─────────────────────────────┘   │
│            │                                                     │
│            │ K8s API                                             │
│            ▼                                                     │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                   Kind Cluster                           │   │
│  │                                                          │   │
│  │  ┌────────────────┐    ┌─────────────────────────────┐  │   │
│  │  │ NGINX Ingress  │    │        Ingress Resources     │  │   │
│  │  │ (LoadBalancer) │◀───│ chart-dash.local → dashboard │  │   │
│  │  │ 172.18.0.100   │    │ chart-gw.local → gateway     │  │   │
│  │  └────────────────┘    └─────────────────────────────┘  │   │
│  │                                                          │   │
│  │  ┌────────────────┐    ┌─────────────────────────────┐  │   │
│  │  │   Toxiproxy    │    │      Tyk Components         │  │   │
│  │  │ (LoadBalancer) │───▶│ Dashboard, Gateway, MDCB    │  │   │
│  │  └────────────────┘    │ Redis, MongoDB              │  │   │
│  │                         └─────────────────────────────┘  │   │
│  │                                                          │   │
│  │  ┌────────────────────────────────────────────────────┐ │   │
│  │  │         cloud-provider-kind                        │ │   │
│  │  │   (Assigns LoadBalancer IPs to services)          │ │   │
│  │  └────────────────────────────────────────────────────┘ │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Troubleshooting

### No LoadBalancer IP assigned

Ensure `cloud-provider-kind` is running:
```bash
# Check if it's running
docker ps | grep cloud-provider-kind

# If not, the create-cluster.sh script starts it automatically
```

### Hosts entries not updating

1. Check controller logs for errors
2. Verify Ingress resources have LoadBalancer IPs:
   ```bash
   kubectl get ingress -A -o wide
   ```
3. Ensure controller has sudo access

### Permission denied writing to /etc/hosts

Run the controller with sudo:
```bash
sudo ./k8s-hosts-controller --namespaces tyk
```
