# How to start Tyk Control Plane and Data Plane in Kubernetes

This guide explains how to set up a Tyk environment with a Control Plane and multiple Data Planes in Kubernetes.

### [mandatory] Provide Licenses
Export licenses to environment variables (or save them in .env file or rename .env_template file):
- *TYK_DB_LICENSEKEY* - Dashboard license
- *TYK_MDCB_LICENSEKEY* - MDCB license (required for Control Plane setup)

### [mandatory] Install Tyk helm charts
<details>
  <summary>Execute only once</summary>

  ```bash
  helm repo add tyk-helm https://helm.tyk.io/public/helm/charts/ &
  helm repo update &
  ```
</details>

### [optional] Choose Docker image
You can choose Dashboard and Gateway Docker images you want to use in your env.

*If you want to use different tag* -> set proper value in *DASH_IMAGE_TAG* and *GW_IMAGE_TAG* env variables (or save it in .env file).

*If you want to use private ECR repo* -> set *IMAGE_REPO* env variable (or save it in .env file). Warning: login to AWS needed! [Instruction on how to login](https://tyktech.atlassian.net/wiki/spaces/~554878896/pages/1881243669/How+to+deploy+a+local+Developer+Experience+environment+DX). This allows to use unofficial images like *master*, *pr-XXXX*, etc.
Command to login to ECR
```
aws ecr get-login-password --region eu-central-1 | docker login --username AWS --password-stdin 754489498669.dkr.ecr.eu-central-1.amazonaws.com
```

## Starting Control Plane and Data Planes
1. Provide Licenses (as described above)
2. Create k8s cluster. If you use kind:
```
./create-cluster.sh
```
3. In this folder, run the script:
```
./run-tyk-cp-dp.sh
```

You can also enable Toxiproxy for testing network issues:
```
./run-tyk-cp-dp.sh toxiproxy=true
```

#### When script is finished you should have the following deployed in your cluster:
- **Control Plane (tyk namespace)**:
  - Tyk Dashboard
  - Tyk Gateway
  - Tyk MDCB
  - Tyk Pump
  - MongoDB
  - Redis
  - Nginx Ingress Controller
- **Data Plane 1 (tyk-dp-1 namespace)**:
  - Tyk Gateway (1 replica)
  - Redis
  - Ingress
- **Data Plane 2 (tyk-dp-2 namespace)**:
  - Tyk Gateway (2 replicas)
  - Redis
  - Ingress
- **Tools (tools namespace)**:
  - Flask Upstream - A simple Flask application that serves as an upstream service for API testing
  - k6 Runner - A load testing tool for sending traffic to the gateways

#### Ingress Configuration
The script automatically configures:
- Nginx ingress controller with LoadBalancer service type
- Ingress resources for all services with `nginx` ingress class

## Port Forwarding
Apps are available using port-forwarding.

**Control Plane Dashboard**:
```
kubectl -n tyk port-forward service/dashboard-svc-tyk-control-plane-tyk-dashboard 3000:3000
```

**Control Plane Gateway**:
```
kubectl -n tyk port-forward service/gateway-svc-tyk-control-plane-tyk-gateway 8080:8080
```

**Data Plane 1 Gateway**:
```
kubectl -n tyk-dp-1 port-forward service/gateway-svc-tyk-data-plane-tyk-gateway 8081:8080
```

**Data Plane 2 Gateway**:
```
kubectl -n tyk-dp-2 port-forward service/gateway-svc-tyk-data-plane-tyk-gateway 8082:8080
```

**Toxiproxy API** (if enabled):
```
kubectl -n tyk port-forward service/toxiproxy 8474:8474
```
**Pump Metrics** (for Prometheus):
```
kubectl -n tyk port-forward service/pump-svc-tyk-control-plane-tyk-pump 9090:9090
```

## Accessing Services via Ingress

**Note** that in order to use the following approach re-run `run-tyk-cp-dp.sh` script again as follows:

```bash
NGINX_SVC_TYPE="LoadBalancer" ./k8s/tyk-stack-ingress/run-tyk-cp-dp.sh
```

This will instruct script to update the nginx to use LoadBalancer, and with the help of
`cloud-provider-kind` container, we'll have access to Ingresses locally via the given hosts in Ingress resource.

**All Ingresses:**
- Data Plane 1 Gateway: `chart-gw-dp-1.local`
- Data Plane 2 Gateway: `chart-gw-dp-2.local`
- Control Plane Gateway: `chart-gw.local`
- Dashboard: `chart-dash.local`
- MDCB: `chart-mdcb.local`

### Accessing Services via curl
Get the LoadBalancer IP and test all endpoints:

```bash
# Get LoadBalancer IP
INGRESS_IP=$(kubectl -n tyk get service nginx-ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Data Plane Gateways health checks
curl -H "Host: chart-gw-dp-1.local" http://$INGRESS_IP/hello
curl -H "Host: chart-gw-dp-2.local" http://$INGRESS_IP/hello

# Control Plane Gateway health check
curl -H "Host: chart-gw.local" http://$INGRESS_IP/hello

# MDCB health check
curl -H "Host: chart-mdcb.local" http://$INGRESS_IP/health
```

## Using Task Commands

This project includes a Taskfile.yaml that provides convenient commands for managing the Tyk environment. You can use [Task](https://taskfile.dev/) to run these commands.

### Available Commands

| Command | Description | Usage |
|---------|-------------|-------|
| `create-cluster` | Creates a Kind Kubernetes cluster with port mappings for ingress | `task -d k8s/tyk-stack-ingress create-cluster` |
| `deploy` | Deploys Tyk control plane and data plane in the Kubernetes cluster | `task -d k8s/tyk-stack-ingress deploy` |
| `deploy-with-toxiproxy` | Deploys Tyk control plane and data plane with Toxiproxy for network simulation | `task -d k8s/tyk-stack-ingress deploy-with-toxiproxy` |
| `get-dp-secret` | Gets the tyk-data-plane-secret from the tyk-dp namespace in human-readable format | `task -d k8s/tyk-stack-ingress get-dp-secret` |
| `start-port-forward` | Port-forwards all Tyk services and saves logs to a file | `task -d k8s/tyk-stack-ingress start-port-forward` |
| `stop-port-forward` | Stops all kubectl port-forward processes | `task -d k8s/tyk-stack-ingress stop-port-forward` |
| `start-toxiproxy-forward` | Port-forwards the Toxiproxy API and all proxies to localhost | `task -d k8s/tyk-stack-ingress start-toxiproxy-forward` |
| `run-k6-test` | Runs k6 test with custom parameters | `task -d k8s/tyk-stack-ingress run-k6-test target_namespace=tyk-dp-1 api_name=test duration=30s dashboard=false` |
| `run-k6-with-dashboard` | Runs k6 test with dashboard enabled | `task -d k8s/tyk-stack-ingress run-k6-with-dashboard TARGET_NAMESPACE=tyk-dp-1 API_NAME=test DURATION=30s` |
| `clean` | Deletes all Tyk namespaces and resources from the Kubernetes cluster | `task -d k8s/tyk-stack-ingress clean` |

### Port Forwarding with Task

Instead of manually running port-forward commands, you can use the `start-port-forward` task to automatically port-forward all services:

```bash
task -d k8s/tyk-stack-ingress start-port-forward
```

This will port-forward:
- Dashboard to localhost:3000
- Control Plane Gateway to localhost:8080
- MDCB to localhost:9091
- Data Plane Gateway to localhost:8181
- Pump to localhost:9090

All port-forwarding logs will be saved to `tyk-port-forward.log`.

To stop all port-forwarding:

```bash
task -d k8s/tyk-stack-ingress stop-port-forward
```

### Using Toxiproxy

If you deployed with Toxiproxy, you can use the `start-toxiproxy-forward` task to port-forward the Toxiproxy API and all proxied services:

```bash
task -d k8s/tyk-stack-ingress start-toxiproxy-forward
```

This makes the Toxiproxy API available at http://localhost:8474, where you can control network conditions for testing.

## Load Testing with k6

The deployment includes a k6 load testing pod in the `tools` namespace that can be used to send traffic to any of the data plane gateways. This is useful for testing API performance, stability, and behavior under load.

### Flask Upstream Service

The deployment includes a simple Flask application in the `tools` namespace that serves as an upstream service for API testing. This service exposes an endpoint at `/upstream` that returns a JSON response. When creating APIs in the Tyk Dashboard, you can use this service as the upstream target with the URL:

```
http://flask-upstream.tools.svc:5000
```

### Running Load Tests

You can run load tests using the following task commands:

#### Basic Load Test

```bash
task -d k8s/tyk-stack-ingress run-k6-test
```

This runs a basic load test against the default data plane gateway.

#### Custom Load Test

```bash
task -d k8s/tyk-stack-ingress run-k6-test target_namespace=tyk-dp-1 api_name=test duration=30s
```

Parameters:
- `target_namespace`: The namespace of the gateway to test (default: tyk-dp-1)
- `api_name`: The name of the API to test (default: test)
- `duration`: How long to run the test (default: 30s)
- `dashboard`: Whether to enable the k6 dashboard (default: false)

#### Load Test with Dashboard

```bash
task -d k8s/tyk-stack-ingress run-k6-test-with-dashboard target_namespace=tyk-dp-1 api_name=test duration=30s dashboard=true
```

This runs a load test with the k6 dashboard enabled, which provides real-time metrics visualization. The dashboard will be available at http://localhost:5665.

## Executing tests

To execute tests:
```
pytest --ci -s -m dash_admin
```

## Troubleshooting

### Checking logs
To check logs for a specific component:

**Dashboard**:
```
kubectl -n tyk logs -l app.kubernetes.io/component=dashboard
```

**Control Plane Gateway**:
```
kubectl -n tyk logs -l app.kubernetes.io/component=gateway
```

**MDCB**:
```
kubectl -n tyk logs -l app.kubernetes.io/component=mdcb
```

**Data Plane Gateway**:
```
kubectl -n tyk-dp-1 logs -l app.kubernetes.io/component=gateway
kubectl -n tyk-dp-2 logs -l app.kubernetes.io/component=gateway
```

### Cleaning Up

To remove all Tyk resources and namespaces from your cluster:

```bash
task -d k8s/tyk-stack-ingress clean
```

