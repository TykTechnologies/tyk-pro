# How to start k8s environment and tests

### [mandatory] Provide License
Export license to *TYK_DB_LICENSEKEY* env variable (or save it in .env file or rename .env_template file).

### [mandatory] Install Tyk helm charts
<details>
  <summary>Execute only once</summary>

  ```bash
  helm repo add tyk-helm https://helm.tyk.io/public/helm/charts/ &
  helm repo update &
  ```
</details>


### [optional] Choose Docker image
You can choose Dash and GW Docker images you want to use in your env.

*If you want to use different tag* -> set proper value in *DASH_IMAGE_TAG* and *GW_IMAGE_TAG* env variables (or save it in .env file).

*If you want to use private ECR repo* -> set *IMAGE_REPO* env variable (or save it in .env file). Warning: login to AWS needed! [Instruction on how to login](https://tyktech.atlassian.net/wiki/spaces/~554878896/pages/1881243669/How+to+deploy+a+local+Developer+Experience+environment+DX). This allows to use unofficial images like *master*, *pr-XXXX*, etc.
Command to login to ECR
```
aws ecr get-login-password --region eu-central-1 | docker login --username AWS --password-stdin 754489498669.dkr.ecr.eu-central-1.amazonaws.com
```

## Starting Env
1. Provide License (as described above)
2. Create k8s cluster. If you use kind:
```
./create-cluster.sh
```
3. In this folder, run script
```
./run-tyk-stack.sh
```
#### When script is finished you should have the following deployed in your cluster:
- Tyk Dashboard (2 pods)
- Tyk Gateway
- mongo
- redis

## Port Forwarding
Apps are available using port-forwarding.

Dashboard:
```
kubectl -n tyk port-forward service/dashboard-svc-tyk-stack-tyk-dashboard 3000:3000
```

Gateway:
```
kubectl -n tyk port-forward service/gateway-svc-tyk-stack-tyk-gateway 8080:8080
```

## Executing tests

To execute tests:
```
pytest --ci -s -m dash_admin
```

