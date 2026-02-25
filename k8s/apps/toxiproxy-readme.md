# Using Toxiproxy with Tyk in Kubernetes

This document explains how to use Toxiproxy to simulate network conditions for testing the Tyk stack in Kubernetes.

## What is Toxiproxy?

[Toxiproxy](https://github.com/Shopify/toxiproxy) is a TCP proxy designed for simulating network conditions in testing environments. It allows you to introduce various network issues like latency, bandwidth restrictions, connection drops, and more to test how your applications behave under adverse conditions.

## Setup

The Toxiproxy setup in this repository includes:

1. A Kubernetes deployment for Toxiproxy
2. A ConfigMap with proxy configurations for Tyk components
3. A Service to expose Toxiproxy endpoints
4. Taskfile commands to manage Toxiproxy

## Proxied Services

The following Tyk services are proxied through Toxiproxy:

| Service | Original Endpoint | Toxiproxy Endpoint |
|---------|-------------------|-------------------|
| Dashboard | dashboard-svc-tyk-control-plane-tyk-dashboard.tyk.svc:3000 | localhost:8474 |
| Control Plane Gateway | gateway-svc-tyk-control-plane-tyk-gateway.tyk.svc:8080 | localhost:8475 |
| Data Plane Gateway | gateway-svc-tyk-data-plane-tyk-gateway.tyk-dp.svc:8080 | localhost:8476 |
| MDCB | mdcb-svc-tyk-control-plane-tyk-mdcb.tyk.svc:9091 | localhost:8477 |
| Control Plane Redis | redis.tyk.svc:6379 | localhost:8478 |
| Data Plane Redis | redis.tyk-dp.svc:6379 | localhost:8479 |
| MongoDB | mongo.tyk.svc:27017 | localhost:8480 |

## Usage

### Deploying Toxiproxy

To deploy Toxiproxy to your Kubernetes cluster:

```bash
task -d k8s/tyk-stack-ingress deploy-toxiproxy
```

### Starting Port Forwarding

To access Toxiproxy from your local machine:

```bash
task -d k8s/tyk-stack-ingress start-toxiproxy-forward
```

This will forward all Toxiproxy ports to your local machine and save logs to `toxiproxy-port-forward.log`.

### Listing Proxies

To list all configured proxies and their current toxics:

```bash
task -d k8s/tyk-stack-ingress list-proxies
```

### Adding Latency

To add latency to a specific proxy:

```bash
# Add 1000ms latency to the dashboard proxy
task -d k8s/tyk-stack-ingress add-latency dashboard

# Add 500ms latency to the MDCB proxy
task -d k8s/tyk-stack-ingress add-latency -- mdcb LATENCY=500
```

### Removing Toxics

To remove a toxic from a proxy:

```bash
# Remove the latency-dashboard toxic from the dashboard proxy
task -d k8s/tyk-stack-ingress remove-toxic dashboard latency-dashboard

# Remove a specific toxic
task -d k8s/tyk-stack-ingress remove-toxic -- cp-gateway TOXIC=latency-cp-gateway
```

## Available Toxics

Toxiproxy supports various types of toxics:

1. **Latency**: Adds a delay to all data going through the proxy
2. **Bandwidth**: Limits the bandwidth of a connection
3. **Slow Close**: Delays the TCP socket from closing
4. **Timeout**: Stops all data from flowing through the proxy, and then closes the connection after a timeout
5. **Slicer**: Slices TCP data into smaller packets
6. **Limit Data**: Limits the amount of data transferred through the proxy

For more advanced usage, you can use the Toxiproxy API directly:

```bash
# Add a timeout toxic
curl -s -X POST http://localhost:8474/proxies/dashboard/toxics -d '{
  "name": "timeout-toxic",
  "type": "timeout",
  "stream": "downstream",
  "toxicity": 1.0,
  "attributes": {
    "timeout": 3000
  }
}' | jq
```

## Testing Scenarios

Here are some testing scenarios you can simulate:

1. **Test Dashboard Resilience**:
   ```bash
   task -d k8s/tyk-stack-ingress add-latency -- dashboard LATENCY=2000
   ```

2. **Test Gateway Timeout Handling**:
   ```bash
   curl -s -X POST http://localhost:8474/proxies/cp-gateway/toxics -d '{
     "name": "timeout-toxic",
     "type": "timeout",
     "stream": "downstream",
     "toxicity": 0.5,
     "attributes": {
       "timeout": 5000
     }
   }' | jq
   ```

3. **Test Redis Connection Issues**:
   ```bash
   task -d k8s/tyk-stack-ingress add-latency -- redis-cp LATENCY=1500
   ```

## Cleanup

To stop port forwarding:

```bash
task -d k8s/tyk-stack-ingress stop-port-forward
```

To remove Toxiproxy from your cluster, you can delete the resources:

```bash
kubectl delete -f k8s/tyk-stack-ingress/toxiproxy.yaml




curl -s -X POST http://localhost:8474/proxies/mdcb \
  -H "Content-Type: application/json" \
  -H "User-Agent: curl" \
  -d '{"enabled": true}'

  create cluster
  deploy toxiproxy
  k apply -f toxiproxy.yaml -n tyk
  deploy stack
  