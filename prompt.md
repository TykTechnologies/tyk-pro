# Align Local and CI Test Environments with Ingress-Based DNS Sync

## Problem Statement

Resilience tests use Toxiproxy to simulate component failures. In local development, `kubectl port-forward` is sometimes used to access services, but port-forwards terminate when connections break. This causes inconsistent behavior between local and CI environments.

**Solution:** Standardize on NGINX Ingress with LoadBalancer service type in both environments, and create a controller that automatically syncs Ingress resources to `/etc/hosts`.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Host Machine                             │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                  k8s-hosts-controller                    │  │
│  │                                                          │  │
│  │  Watches: networking.k8s.io/v1/Ingress                   │  │
│  │  Extracts: spec.rules[].host                             │  │
│  │            status.loadBalancer.ingress[0].ip             │  │
│  │  Updates: /etc/hosts                                     │  │
│  └────────────────────────┬─────────────────────────────────┘  │
│                           │                                    │
│                           ▼                                    │
│  ┌──────────────┐     ┌─────────────────────────────────────┐  │
│  │ /etc/hosts   │     │          Test Client                │  │
│  │              │     │  (pytest, curl, etc.)               │  │
│  │ 172.18.0.x   │     └──────────────┬──────────────────────┘  │
│  │ chart-*.local│                    │                         │
│  └──────────────┘                    │ HTTP :80                │
│                                      ▼                         │
│                       ┌─────────────────────────────────────┐  │
│                       │      Kind Cluster                   │  │
│                       │  ┌─────────────────────────────┐    │  │
│                       │  │ NGINX Ingress (LoadBalancer)│    │  │
│                       │  │ IP: 172.18.0.x              │    │  │
│                       │  └──────────────┬──────────────┘    │  │
│                       │                 │                    │  │
│                       │    ┌────────────┼────────────┐       │  │
│                       │    ▼            ▼            ▼       │  │
│                       │ Dashboard    Gateway     Gateway     │  │
│                       │ (CP)        (CP)        (DP-1/2)     │  │
│                       └─────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Phase 1: Infrastructure Prerequisites

### Action 1: Ensure LoadBalancer Support in Kind

The `create-cluster.sh` script already runs `cloud-provider-kind` which provides LoadBalancer IP assignment.


## Phase 2: Ingress Hosts Controller (Go Binary)

### Project: `k8s-hosts-controller`

A Kubernetes controller that watches Ingress resources and automatically syncs hostnames to `/etc/hosts`.

### Design Principles

1. **Zero configuration for hostnames** - discovers everything from Ingress resources
2. **Fully dynamic** - automatically handles Ingress create/update/delete
3. **Clean lifecycle** - removes entries on Ingress deletion and tool shutdown
4. **Controller pattern** - uses controller-runtime for proper reconciliation

### How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                     Reconciliation Flow                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Ingress Created/Updated                                     │
│     ┌─────────────────────────────────────────────────────┐     │
│     │ Ingress: dashboard-ingress                          │     │
│     │ spec.rules[0].host: chart-dash.local                │     │
│     │ status.loadBalancer.ingress[0].ip: 172.18.0.200     │     │
│     └─────────────────────────────────────────────────────┘     │
│                           │                                     │
│                           ▼                                     │
│     ┌─────────────────────────────────────────────────────┐     │
│     │ /etc/hosts                                          │     │
│     │ #### BEGIN TYK-K8S-HOSTS ####                       │     │
│     │ 172.18.0.200 chart-dash.local  # tyk/dashboard-ing  │     │
│     │ #### END TYK-K8S-HOSTS ####                         │     │
│     └─────────────────────────────────────────────────────┘     │
│                                                                 │
│  2. Ingress Deleted                                             │
│     → Remove corresponding entry from /etc/hosts                │
│                                                                 │
│  3. Controller Shutdown (SIGTERM/SIGINT)                        │
│     → Remove ALL entries within markers                         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Dependencies

```go
// go.mod
module github.com/TykTechnologies/k8s-hosts-controller

go 1.22

require (
    k8s.io/api v0.29.0
    k8s.io/apimachinery v0.29.0
    k8s.io/client-go v0.29.0
    sigs.k8s.io/controller-runtime v0.17.0
)
```

### CLI Interface

```bash
# Watch namespaces and sync Ingress hostnames to /etc/hosts
k8s-hosts-controller --namespaces "tyk,tyk-dp-1,tyk-dp-2"

# Watch all namespaces
k8s-hosts-controller --all-namespaces

# Cleanup only (remove all managed entries)
k8s-hosts-controller --cleanup
```

### Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--namespaces` | Comma-separated list of namespaces to watch | Required unless `--all-namespaces` |
| `--all-namespaces` | Watch all namespaces | `false` |
| `--hosts-file` | Path to hosts file | `/etc/hosts` |
| `--marker` | Marker prefix for managed entries | `TYK-K8S-HOSTS` |
| `--cleanup` | Remove all managed entries and exit | `false` |
| `--kubeconfig` | Path to kubeconfig | `~/.kube/config` or in-cluster |
| `--context` | Kubernetes context to use | Current context |
| `--verbose` | Enable verbose logging | `false` |

### Core Implementation

#### Project Structure

```
k8s-hosts-controller/
├── main.go
├── pkg/
│   ├── controller/
│   │   └── ingress_controller.go
│   └── hosts/
│       └── manager.go
└── go.mod
```

#### main.go

```go
package main

import (
	"flag"
	"os"
	"strings"

	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	"github.com/TykTechnologies/k8s-hosts-controller/pkg/controller"
	"github.com/TykTechnologies/k8s-hosts-controller/pkg/hosts"
)

var scheme = runtime.NewScheme()

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(networkingv1.AddToScheme(scheme))
}

func main() {
	var (
		namespaces    string
		allNamespaces bool
		hostsFile     string
		marker        string
		cleanup       bool
		verbose       bool
	)

	flag.StringVar(&namespaces, "namespaces", "", "Comma-separated namespaces to watch")
	flag.BoolVar(&allNamespaces, "all-namespaces", false, "Watch all namespaces")
	flag.StringVar(&hostsFile, "hosts-file", "/etc/hosts", "Path to hosts file")
	flag.StringVar(&marker, "marker", "TYK-K8S-HOSTS", "Marker for managed entries")
	flag.BoolVar(&cleanup, "cleanup", false, "Remove all managed entries and exit")
	flag.BoolVar(&verbose, "verbose", false, "Enable verbose logging")
	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseDevMode(verbose)))
	log := ctrl.Log.WithName("setup")

	// Initialize hosts manager
	hostsManager := hosts.NewManager(hostsFile, marker)

	// Cleanup mode
	if cleanup {
		if err := hostsManager.Cleanup(); err != nil {
			log.Error(err, "Failed to cleanup hosts file")
			os.Exit(1)
		}
		log.Info("Cleaned up hosts file")
		os.Exit(0)
	}

	// Validate flags
	if !allNamespaces && namespaces == "" {
		log.Error(nil, "Either --namespaces or --all-namespaces must be specified")
		os.Exit(1)
	}

	// Build manager options
	opts := ctrl.Options{
		Scheme: scheme,
		Metrics: metricsserver.Options{
			BindAddress: "0", // Disable metrics server
		},
	}

	// Configure namespace filtering
	if !allNamespaces {
		nsList := strings.Split(namespaces, ",")
		nsMap := make(map[string]cache.Config)
		for _, ns := range nsList {
			ns = strings.TrimSpace(ns)
			if ns != "" {
				nsMap[ns] = cache.Config{}
			}
		}
		opts.Cache = cache.Options{
			DefaultNamespaces: nsMap,
		}
		log.Info("Watching namespaces", "namespaces", nsList)
	} else {
		log.Info("Watching all namespaces")
	}

	// Create manager
	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), opts)
	if err != nil {
		log.Error(err, "Unable to create manager")
		os.Exit(1)
	}

	// Setup controller
	if err := controller.NewIngressReconciler(
		mgr.GetClient(),
		hostsManager,
	).SetupWithManager(mgr); err != nil {
		log.Error(err, "Unable to create controller")
		os.Exit(1)
	}

	// Cleanup on shutdown
	ctx := ctrl.SetupSignalHandler()
	go func() {
		<-ctx.Done()
		log.Info("Shutting down, cleaning up hosts entries...")
		if err := hostsManager.Cleanup(); err != nil {
			log.Error(err, "Failed to cleanup hosts file on shutdown")
		}
	}()

	log.Info("Starting controller")
	if err := mgr.Start(ctx); err != nil {
		log.Error(err, "Problem running manager")
		os.Exit(1)
	}
}
```

#### pkg/controller/ingress_controller.go

```go
package controller

import (
	"context"

	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	"github.com/TykTechnologies/k8s-hosts-controller/pkg/hosts"
)

// IngressReconciler reconciles Ingress objects
type IngressReconciler struct {
	client.Client
	hostsManager *hosts.Manager
}

// NewIngressReconciler creates a new IngressReconciler
func NewIngressReconciler(client client.Client, hostsManager *hosts.Manager) *IngressReconciler {
	return &IngressReconciler{
		Client:       client,
		hostsManager: hostsManager,
	}
}

// Reconcile handles Ingress events
func (r *IngressReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := log.FromContext(ctx)

	// Fetch the Ingress
	ingress := &networkingv1.Ingress{}
	err := r.Get(ctx, req.NamespacedName, ingress)

	if errors.IsNotFound(err) {
		// Ingress was deleted - remove entries
		log.Info("Ingress deleted, removing hosts entries", "ingress", req.NamespacedName)
		if err := r.hostsManager.RemoveIngress(req.NamespacedName.String()); err != nil {
			log.Error(err, "Failed to remove hosts entries")
			return ctrl.Result{}, err
		}
		return ctrl.Result{}, nil
	}

	if err != nil {
		log.Error(err, "Failed to get Ingress")
		return ctrl.Result{}, err
	}

	// Extract LoadBalancer IP
	ip := extractLoadBalancerIP(ingress)
	if ip == "" {
		log.V(1).Info("Ingress has no LoadBalancer IP yet", "ingress", req.NamespacedName)
		return ctrl.Result{}, nil
	}

	// Extract hostnames
	hostnames := extractHostnames(ingress)
	if len(hostnames) == 0 {
		log.V(1).Info("Ingress has no hostnames", "ingress", req.NamespacedName)
		return ctrl.Result{}, nil
	}

	// Update hosts file
	log.Info("Updating hosts entries",
		"ingress", req.NamespacedName,
		"ip", ip,
		"hostnames", hostnames,
	)

	if err := r.hostsManager.UpdateIngress(req.NamespacedName.String(), ip, hostnames); err != nil {
		log.Error(err, "Failed to update hosts file")
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, nil
}

// SetupWithManager sets up the controller with the Manager
func (r *IngressReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&networkingv1.Ingress{}).
		Complete(r)
}

// extractLoadBalancerIP gets the IP from Ingress status
func extractLoadBalancerIP(ingress *networkingv1.Ingress) string {
	if ingress.Status.LoadBalancer.Ingress == nil {
		return ""
	}

	for _, ing := range ingress.Status.LoadBalancer.Ingress {
		if ing.IP != "" {
			return ing.IP
		}
	}

	return ""
}

// extractHostnames gets all hostnames from Ingress rules
func extractHostnames(ingress *networkingv1.Ingress) []string {
	var hostnames []string
	seen := make(map[string]bool)

	for _, rule := range ingress.Spec.Rules {
		if rule.Host != "" && !seen[rule.Host] {
			hostnames = append(hostnames, rule.Host)
			seen[rule.Host] = true
		}
	}

	return hostnames
}
```

#### pkg/hosts/manager.go

```go
package hosts

import (
	"fmt"
	"os"
	"strings"
	"sync"
)

const (
	markerBegin = "#### BEGIN %s ####"
	markerEnd   = "#### END %s ####"
)

// Manager handles /etc/hosts file modifications
type Manager struct {
	hostsFile string
	marker    string
	mu        sync.Mutex

	// Track entries by Ingress key (namespace/name)
	entries map[string][]HostEntry
}

// HostEntry represents a single hostname → IP mapping
type HostEntry struct {
	IP       string
	Hostname string
}

// NewManager creates a new hosts file manager
func NewManager(hostsFile, marker string) *Manager {
	return &Manager{
		hostsFile: hostsFile,
		marker:    marker,
		entries:   make(map[string][]HostEntry),
	}
}

// UpdateIngress adds or updates hosts entries for an Ingress
func (m *Manager) UpdateIngress(ingressKey, ip string, hostnames []string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	// Update in-memory state
	entries := make([]HostEntry, 0, len(hostnames))
	for _, hostname := range hostnames {
		entries = append(entries, HostEntry{IP: ip, Hostname: hostname})
	}
	m.entries[ingressKey] = entries

	return m.writeHostsFile()
}

// RemoveIngress removes hosts entries for an Ingress
func (m *Manager) RemoveIngress(ingressKey string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	delete(m.entries, ingressKey)
	return m.writeHostsFile()
}

// Cleanup removes all managed entries
func (m *Manager) Cleanup() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.entries = make(map[string][]HostEntry)
	return m.writeHostsFile()
}

// writeHostsFile writes the current state to the hosts file
func (m *Manager) writeHostsFile() error {
	// Read current file
	content, err := os.ReadFile(m.hostsFile)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to read hosts file: %w", err)
	}

	// Remove existing managed block
	beginMarker := fmt.Sprintf(markerBegin, m.marker)
	endMarker := fmt.Sprintf(markerEnd, m.marker)

	lines := strings.Split(string(content), "\n")
	var newLines []string
	inBlock := false

	for _, line := range lines {
		if strings.Contains(line, beginMarker) {
			inBlock = true
			continue
		}
		if strings.Contains(line, endMarker) {
			inBlock = false
			continue
		}
		if !inBlock {
			newLines = append(newLines, line)
		}
	}

	// Remove trailing empty lines
	for len(newLines) > 0 && strings.TrimSpace(newLines[len(newLines)-1]) == "" {
		newLines = newLines[:len(newLines)-1]
	}

	// Build new block if we have entries
	if len(m.entries) > 0 {
		var block strings.Builder
		block.WriteString("\n" + beginMarker + "\n")

		for ingressKey, entries := range m.entries {
			for _, entry := range entries {
				// Include ingress key as comment for traceability
				block.WriteString(fmt.Sprintf("%s %s  # %s\n", entry.IP, entry.Hostname, ingressKey))
			}
		}

		block.WriteString(endMarker)
		newLines = append(newLines, block.String())
	}

	// Write atomically
	finalContent := strings.Join(newLines, "\n")
	if !strings.HasSuffix(finalContent, "\n") {
		finalContent += "\n"
	}

	tmpFile := m.hostsFile + ".k8s-hosts-controller.tmp"
	if err := os.WriteFile(tmpFile, []byte(finalContent), 0644); err != nil {
		return fmt.Errorf("failed to write temp file: %w", err)
	}

	if err := os.Rename(tmpFile, m.hostsFile); err != nil {
		os.Remove(tmpFile) // Cleanup on failure
		return fmt.Errorf("failed to rename temp file: %w", err)
	}

	return nil
}
```

### Output Example

```
$ sudo k8s-hosts-controller --namespaces "tyk,tyk-dp-1,tyk-dp-2" --verbose

2024-01-15T10:30:00Z INFO  setup  Watching namespaces  {"namespaces": ["tyk", "tyk-dp-1", "tyk-dp-2"]}
2024-01-15T10:30:00Z INFO  setup  Starting controller
2024-01-15T10:30:01Z INFO  controller  Updating hosts entries  {"ingress": "tyk/dashboard-ingress", "ip": "172.18.0.200", "hostnames": ["chart-dash.local"]}
2024-01-15T10:30:01Z INFO  controller  Updating hosts entries  {"ingress": "tyk/gateway-ingress", "ip": "172.18.0.200", "hostnames": ["chart-gw.local"]}
2024-01-15T10:30:01Z INFO  controller  Updating hosts entries  {"ingress": "tyk-dp-1/gateway-ingress", "ip": "172.18.0.200", "hostnames": ["chart-gw-dp-1.local"]}
2024-01-15T10:30:01Z INFO  controller  Updating hosts entries  {"ingress": "tyk-dp-2/gateway-ingress", "ip": "172.18.0.200", "hostnames": ["chart-gw-dp-2.local"]}
^C
2024-01-15T10:35:00Z INFO  setup  Shutting down, cleaning up hosts entries...
```

### /etc/hosts Result

```
# Existing entries...
127.0.0.1 localhost
::1 localhost

#### BEGIN TYK-K8S-HOSTS ####
172.18.0.200 chart-dash.local  # tyk/dashboard-ingress
172.18.0.200 chart-gw.local  # tyk/gateway-ingress
172.18.0.200 chart-mdcb.local  # tyk/mdcb-ingress
172.18.0.200 chart-gw-dp-1.local  # tyk-dp-1/gateway-ingress
172.18.0.200 chart-gw-dp-2.local  # tyk-dp-2/gateway-ingress
#### END TYK-K8S-HOSTS ####
```

---

## Phase 3: Integration with Existing Scripts

### Update `run-tyk-cp-dp.sh`

Add hosts sync at the end of deployment:

```bash
startHostsSync() {
  log "Starting k8s-hosts-controller controller..."

  # Build namespace list
  local namespaces="$CP_NAMESPACE"
  for i in $(seq 1 "$NUM_DATA_PLANES"); do
    namespaces="${namespaces},$(dp_namespace "$i")"
  done

  # Use sudo if not root
  local sudo_cmd=""
  if [ "$(id -u)" -ne 0 ]; then
    sudo_cmd="sudo"
  fi

  # Run in background, store PID for cleanup
  $sudo_cmd k8s-hosts-controller --namespaces "$namespaces" &
  echo $! > /tmp/k8s-hosts-controller.pid

  # Wait for initial sync
  sleep 3
  log "Hosts sync controller started"
}

# Call at the end of deployment
startHostsSync
```

### Update `test-resilience-local.sh`

```bash
setup() {
    # ... existing cluster setup ...

    log "Starting k8s-hosts-controller controller..."
    sudo k8s-hosts-controller --namespaces "tyk,tyk-dp-1,tyk-dp-2" &
    echo $! > /tmp/k8s-hosts-controller.pid

    # Wait for entries to be synced
    sleep 5
}

cleanup() {
    log "Stopping k8s-hosts-controller..."
    if [ -f /tmp/k8s-hosts-controller.pid ]; then
        sudo kill "$(cat /tmp/k8s-hosts-controller.pid)" 2>/dev/null || true
        rm -f /tmp/k8s-hosts-controller.pid
    fi

    # Ensure cleanup
    sudo k8s-hosts-controller --cleanup

    # ... existing cleanup ...
}
```

### CI Workflow Integration (`.github/workflows/k8s-api-tests.yaml`)

```yaml
- name: Setup hosts sync tool
  run: |
    go install github.com/TykTechnologies/k8s-hosts-controller@latest

- name: Start hosts sync
  run: |
    sudo $(go env GOPATH)/bin/k8s-hosts-controller \
      --namespaces "tyk,tyk-dp-1,tyk-dp-2" &
    echo $! | sudo tee /tmp/k8s-hosts-controller.pid
    sleep 5  # Wait for initial sync

- name: Run tests
  run: |
    cd tests/api
    pytest -s -m resilience

- name: Cleanup hosts sync
  if: always()
  run: |
    if [ -f /tmp/k8s-hosts-controller.pid ]; then
    # TODO: log errors here
    sudo kill "$(cat /tmp/k8s-hosts-controller.pid)" 2>/dev/null || true
    fi
    # TODO: log errors here
    sudo $(go env GOPATH)/bin/k8s-hosts-controller --cleanup || true
```

---

## Summary Checklist

1. [ ] **Update `run-tyk-cp-dp.sh`**: Default `NGINX_SVC_TYPE` to `LoadBalancer`
2. [ ] **Create `k8s-hosts-controller` tool**:
   - [ ] Initialize Go module with controller-runtime
   - [ ] Implement Ingress controller/reconciler
   - [ ] Implement hosts file manager with markers
   - [ ] Handle graceful shutdown with cleanup
   - [ ] Add --cleanup flag for manual cleanup
3. [ ] **Integrate with scripts**:
   - [ ] Add hosts sync start to `run-tyk-cp-dp.sh`
   - [ ] Update `test-resilience-local.sh`
   - [ ] Update CI workflow
4. [ ] **Documentation**:
   - [ ] Update README with new setup
   - [ ] Document the k8s-hosts-controller tool

---

## Expected Outcome

| Feature | Behavior |
|---------|----------|
| New Ingress created | Hostname → IP added to /etc/hosts |
| Ingress IP changes | Entry updated automatically |
| Ingress deleted | Entry removed from /etc/hosts |
| Tool shutdown | All managed entries removed |
| `--cleanup` flag | Manual cleanup of all entries |

Both local and CI environments use the same tool with identical behavior, ensuring consistent test execution.
