# IDP environment on Kubernetes

This folder builds a local environment for
[idp-controller](https://github.com/TykTechnologies/idp-controller): a kind
cluster carrying the operators the controller depends on, the controller and
api-server themselves, and the catalogue of products users deploy from.

Three files do the work:

- `deps.sh` checks and installs the prerequisite tooling on your workstation.
- `setup.sh` creates the cluster and deploys the idp-controller release.
- `set-image.sh` swaps the image a deployed product runs, and verifies it.
- `Taskfile.yaml` wraps all three, and adds the catalogue and image-building
  steps.

Nothing in `setup.sh` installs a tool, and no cluster task installs one as a
side effect. Run `task deps-install` yourself when something is missing.

## What you get

The environment stacks up in four layers, and each one is useless without the
one before it:

1. **The cluster.** A kind cluster named `tyk-idp`, with one control-plane node
   and one worker.
2. **The operators.** ArgoCD, cert-manager, and ingress-nginx with
   cloud-provider-kind. The controller exits at startup without the cert-manager
   Certificate CRD, and only ArgoCD can actuate the Applications the controller
   creates.
3. **The release.** The controller and api-server in the `idp-system`
   namespace, plus the six CRDs the Helm chart ships.
4. **The catalogue.** 18 ProductClass and 10 TykDeployment resources. The
   api-server reads these straight from the cluster, so without them it answers
   every catalogue request with an empty list.

Running a Tyk gateway or dashboard takes a fifth step that is yours, not the
script's: create a TykDeploymentInstance through the UI or `kubectl`. The
controller turns that into a tenant namespace and a set of ArgoCD Applications,
and ArgoCD installs the Tyk charts.

## Before you start

You need an idp-controller checkout. `setup.sh` looks for one beside
`tyk-pro`, so `~/projects/tyk-pro` and `~/projects/idp-controller` work with no
configuration. To keep it somewhere else, set `IDP_CONTROLLER_ROOT`.

To check your tooling, run:

```bash
task -d k8s/idp deps
```

That reports `docker`, `kind`, `kubectl`, and `helm`, warns when the Docker
daemon is unreachable, and prints your Docker context. When something is
missing, it asks before installing it through Homebrew, and installs only what
is absent, so it never moves you off a version you pinned. Required and
optional tools are asked about separately, because declining the optional ones
still leaves a working environment.

Nothing installs without a yes. Declining a required tool exits non-zero, so a
build cannot carry on without it. For a non-interactive run, `task -d k8s/idp
deps -- --yes` installs what is missing without asking.

### Licenses

The Helm chart writes a `tyk-stack` secret holding the Dashboard and MDCB
licenses, and the controller replicates that secret into every tenant
namespace. Without valid licenses the chart still installs, but the first tenant
you deploy fails on an empty license, far from the cause. `setup.sh` therefore
asks for them up front.

To supply them, copy the template and fill it in:

```bash
cp k8s/idp/.env_template k8s/idp/.env
```

`k8s/*/.env` is gitignored. An exported value beats anything in `.env`, so a
per-run override still works.

To build the cluster and its operators without licenses, run
`task -d k8s/idp operators`.

## Set up the environment

Two paths lead to the same environment. They differ only in where the
controller and api-server images come from.

### With the released images

This path needs no Go toolchain, and it needs a Docker Hub login with access to
`tykio/idp-controller` and `tykio/idp-server`, which are private:

```bash
task -d k8s/idp setup-released
```

That runs `deps`, `install`, and `status` in order, and `install` applies the
catalogue itself. Without access to
those repositories the pods land in `ImagePullBackOff`, and the path in the
next section is the one you want.

### With images you build

This path needs Go and an idp-controller checkout, and it needs no registry
access at all:

```bash
task -d k8s/idp setup
```

That builds both images from the checkout, loads them into kind with
`kind load docker-image`, and deploys the release from them.

### Checking where you are

```bash
task -d k8s/idp status
```

It reports each layer separately, so a half-built environment is visible rather
than silent:

```
==> operators
  argocd         5/5 pods running
  cert-manager   3/3 pods running
  nginx          1/1 pods running

==> idp-controller release
NAME                                         READY   STATUS    RESTARTS   AGE
idp-controller-api-server-65f75c6697-xndcq   1/1     Running   0          17s
idp-controller-controller-76f7f4cf6f-5kk76   1/1     Running   0          17s

==> catalogue
ProductClass:         18
TykDeployment:        10
TykDeploymentInstance: 0
```

### Reaching the api-server

```bash
task -d k8s/idp port-forward
```

The api-server then answers on `http://localhost:8080`. To confirm it serves the
catalogue:

```bash
curl -s http://localhost:8080/api/v1/tykdeployments | jq '.totalCount'
```

## Build and use a local image

`task images` builds both images and loads them into the cluster:

```bash
task -d k8s/idp images
```

Behind that, it runs the idp-controller Makefile twice and loads the results:

```bash
make -C <checkout> docker-build BINARY=controller IMG=idp-controller:local GOARCH=arm64
make -C <checkout> docker-build BINARY=api-server IMG=idp-server:local GOARCH=arm64
kind load docker-image idp-controller:local idp-server:local --name tyk-idp
```

It builds for your own architecture only, because the image runs nowhere except
this kind cluster.

`task install-local` runs `images` and then hands `setup.sh` three overrides:

```bash
IDP_CONTROLLER_IMAGE=idp-controller IDP_SERVER_IMAGE=idp-server IDP_IMAGE_TAG=local ./setup.sh
```

The chart sets `imagePullPolicy: IfNotPresent`, so the kubelet finds the loaded
image on the node and never contacts a registry.

To pick up a code change, run `task install-local` again. The build reuses
Docker's cache, and Helm restarts the pods on the new image digest.

### Pointing at any other image

`IDP_CONTROLLER_IMAGE`, `IDP_SERVER_IMAGE`, and `IDP_IMAGE_TAG` are ordinary
configuration variables, settable by export, by `.env`, or on the command line.
To run a different release:

```bash
IDP_IMAGE_TAG=v0.0.9 task -d k8s/idp install
```

One tag covers both images, which matches how they ship: the release workflow
builds and pushes both from the same git tag.

## Swap the image a deployed product runs

`set-image.sh` points one product's chart at a different container image, then
waits for the workload to actually run it. To try a gateway build against a
running instance:

```bash
task -d k8s/idp set-image INSTANCE=oss-demo IMAGE=my-gateway:local
```

It loads the image into kind when the image is on this host, writes the
override onto the instance's `spec.values`, and waits for a workload in the
tenant namespace to report that image. A wrong key path applies cleanly and
changes nothing, so this last check is the one that proves the override worked.

Three tasks cover the Tyk components, each setting the values path for you:

| Task | Component | Values path |
| --- | --- | --- |
| `set-gateway` | Gateway | `tyk-gateway.gateway.image` |
| `set-analytics` | Dashboard | `tyk-dashboard.dashboard.image` |
| `set-pump` | Pump | `tyk-pump.pump.image` |

`PRODUCT_CLASS` defaults to `tyk-oss`, so pass it for anything else:

```bash
task -d k8s/idp set-analytics INSTANCE=cp-demo PRODUCT_CLASS=tyk-cp-minimal IMAGE=my-dashboard:local
```

Each task checks the ProductClass deploys that component before writing
anything. Asking for a dashboard on `tyk-oss` fails with the components that
chart does carry, rather than writing an override that renders nothing.

`set-image` remains the escape hatch for any other values path, and its `KEY`
carries the subchart prefix. `tyk-oss` is an umbrella chart, so values
bound for its `tyk-gateway` subchart nest under that subchart's name, which is
why the default reads `tyk-gateway.gateway.image`. Confirm a path against
`helm show values <repo>/<chart> --version <version>` before trusting it.

To see what the charts actually received, and to put the default back:

```bash
task -d k8s/idp show-values INSTANCE=oss-demo
task -d k8s/idp clear-image INSTANCE=oss-demo
```

## Run the controller and api-server directly

For a faster loop than rebuilding an image, run both binaries on your host. They
fall back to `~/.kube/config` when they are not running in-cluster, so they talk
to the kind cluster with no extra configuration.

1. Scale the in-cluster controller to zero, so two controllers do not reconcile
   the same resources:

   ```bash
   kubectl --context kind-tyk-idp -n idp-system scale deploy/idp-controller-controller --replicas=0
   ```

2. In the idp-controller checkout, start the controller:

   ```bash
   go run ./cmd/controller/main.go --namespace=idp-system --log-level=debug
   ```

3. In a second terminal, start the api-server:

   ```bash
   go run ./cmd/api-server/main.go --max-instances-per-user=10
   ```

   The default cap is one instance per user, which a test run reaches
   immediately. The local api-server has no auth in front of it, which is why
   running it on your machine is safe: there is no shared endpoint.

4. Optional: to serve the api-server on your host as well, scale its deployment
   down too:

   ```bash
   kubectl --context kind-tyk-idp -n idp-system scale deploy/idp-controller-api-server --replicas=0
   ```

To go back to the in-cluster versions, scale both deployments to 1, or run
`task install-local` again.

Restart the `go run` process to pick up a code change. For the Forge frontend
against a local api-server, see `docs/local-development.md` in the
idp-controller checkout.

## Tasks

Run `task -d k8s/idp --list` for the current set. Grouped by what they touch:

| Task | What it does |
| --- | --- |
| `deps` | Reports every prerequisite and offers to install what is missing |
| `setup` | The whole environment, from images built here |
| `setup-released` | The same, from the released images |
| `operators` | Cluster and operators only, no release |
| `install` | Release from the released images, plus the catalogue |
| `install-local` | Release from images built here, plus the catalogue |
| `catalog-delete` | Removes the ProductClass and TykDeployment resources |
| `status` | Reports each layer |
| `port-forward` | Serves the api-server on `localhost:8080` |
| `set-gateway` | Points the gateway at another image and waits for the workload to run it |
| `set-analytics` | The same for the dashboard |
| `set-pump` | The same for Pump |
| `set-image` | The same for any values path, the escape hatch behind the three above |
| `show-values` | Prints the merged Helm values each Application received |
| `clear-image` | Removes the override, restoring the chart default |
| `logs` | Follows the controller logs |
| `delete` | Deletes the kind cluster |

## Configuration

Every variable below is settable by export, by `.env`, or on the command line.
An exported value beats `.env`.

| Variable | Default | What it controls |
| --- | --- | --- |
| `TYK_DB_LICENSEKEY` | none, required | Dashboard license |
| `TYK_MDCB_LICENSEKEY` | none, required | MDCB license |
| `IDP_CONTROLLER_ROOT` | `../idp-controller` beside `tyk-pro` | The checkout to read the chart and catalogue from |
| `KIND_CLUSTER_NAME` | `tyk-idp` | Cluster name, and `kind-<name>` for the context |
| `IDP_NAMESPACE` | `idp-system` | Namespace for the release |
| `IDP_RELEASE` | `idp-controller` | Helm release name |
| `IDP_IMAGE_TAG` | `v0.0.10` | Tag for both images |
| `IDP_CONTROLLER_IMAGE` | `tykio/idp-controller` | Controller image repository |
| `IDP_SERVER_IMAGE` | `tykio/idp-server` | Api-server image repository |
| `DEPLOY_CHART` | `true` | Set to `false` to stop after the operators |
| `INSTALL_MONITORING` | `false` | Installs kube-prometheus-stack with the tenant dashboards |
| `HELM_TIMEOUT` | `600s` | Timeout for `helm upgrade --install --wait` |

## Troubleshooting

**The pods sit in `ImagePullBackOff`.** The `tykio/idp-controller` and
`tykio/idp-server` repositories are private on Docker Hub. Check the message
with `kubectl -n idp-system describe pod <name>`. To work around it without a
Docker Hub login, run `task install-local`.

**The catalogue is empty.** ProductClass and TykDeployment are cluster-scoped
resources that `install` and `install-local` apply. Re-run either one.

**`kubectl` talks to the wrong cluster.** This stack keeps its own cluster,
separate from the one `k8s/tyk-stack-ingress` uses, because both install
ingress-nginx and both would claim the `nginx` IngressClass. Every task passes
`--context kind-tyk-idp` explicitly; for your own commands, run
`kubectl config use-context kind-tyk-idp`.

**Two cloud-provider-kind containers are running.** `k8s/tyk-stack-ingress`
starts one named `tyk-ci-cloud-provider-kind`, and this stack starts one named
`cloud-provider-kind`. Neither detects the other, and both reconcile every
LoadBalancer Service on the kind Docker network. `setup.sh` warns when it sees
both; stop one before relying on LoadBalancer addresses.

**An Ingress never gets an address.** Ingress resources stay unready until
cloud-provider-kind assigns the ingress-nginx Service a LoadBalancer IP address,
and Helm or ArgoCD waits on that indefinitely. Check the container is running
with `docker ps | grep cloud-provider-kind`.

**An Ingress has an address, but you cannot reach it from macOS.** Docker
Desktop does not route kind's LoadBalancer IP addresses to the host, so the
hostnames the Tyk charts create resolve to an address your machine has no route
to, and the request times out. `deps.sh` reports your Docker context and warns
when it sees this. Port-forwarding works either way; OrbStack routes the
addresses directly if you want the hostnames to resolve.
