# TODO

Open work on the IDP environment, most useful first.

## 1. Report the idp-controller bugs

Three found while building this, all in TykTechnologies/idp-controller:

- An email in `ownerRef.email` puts the reconciler into a failing loop. The
  controller copies the value onto the `platform.tyk.io/owner-user-id` label
  at `reconciler.go:60`, and a label value cannot contain `@`. Nothing
  sanitizes it, and the failure appears only in the controller log.
- Server-side apply destroys a TykDeploymentInstance. These instances are
  client-side applied when created, so the first `--server-side` apply
  migrates every field to the applying manager, and the next apply that omits
  `humanReadableName`, `tykDeploymentRef` and `ownerRef` deletes them.
- `simple-tyk-oss` pairs a cluster-mode Redis with a gateway that is not told
  about it. The gateway health endpoint returns `MOVED`, while ArgoCD reports
  the deployment Healthy. The `tyk-oss` ProductClass sets no Redis values,
  where `tyk-oss-sharded` sets `enableCluster: true`.

## 2. Remove the expired licences from `master.env`

`TYK_DB_LICENSEKEY` and `TYK_MDCB_LICENSE` are committed to the repo root and
expired on 2023-12-21.
