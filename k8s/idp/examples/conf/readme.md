# Example API definitions

Classic API definitions for `seed.sh` to load into a deployed stack. JSON
carries no comments, so the reasoning behind each file lives here.

To load one:

```bash
task -d k8s/idp seed -- ./examples/conf/graphql-udg.json
```

Pass `INSTANCE=<name>` when more than one stack is deployed. List them with
`task -d k8s/idp instances`.

## graphql-udg.json

A Universal Data Graph that stitches two upstreams into one schema:

| Field | Upstream | Kind |
| --- | --- | --- |
| `Query.user` | `jsonplaceholder.typicode.com/users/1` | REST |
| `Query.country` | `countries-graphql` in the tenant namespace | GraphQL |

It needs the `tyk-stack-graphql` topology, which is the one that deploys the
`countries-graphql` upstream. On any other topology the `country` field
resolves against a service that does not exist.

To try it, port-forward the gateway and query it:

```bash
task -d k8s/idp expose -- gateway
curl -s http://localhost:8080/udg/ \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ user { id name email } country(code: \"GB\") { name capital emoji } }"}'
```

The playground is at `http://localhost:8080/udg/playground`.

### Why the two field configs differ

`field_configs` decides where in an upstream response a field's value is read
from, and the right answer differs by upstream kind.

`Query.user` sets `disable_default_mapping: true`. The default mapping looks
for a node named after the field, and jsonplaceholder returns the user object
at the root of the response with no `user` wrapper. Leaving the default in
place reads `$.user`, finds nothing, and resolves the field to `null` while the
request itself still succeeds, so nothing reports an error.

`Query.country` keeps the default mapping and names `["country"]`. A GraphQL
response is keyed by field name under `data`, and the engine strips `data`
before the mapping runs, so the value really is at `$.country`.

### Why `id` is an Int

jsonplaceholder returns `"id": 1` as a JSON number. The engine copies upstream
values through without coercing them, so declaring `id: String` hands the
client an unquoted number where it expects a quoted one.

### Fields that carry no weight

`proxy.target_url` goes unused in `executionEngine` mode, because the data
sources decide where requests go. It has to be present and non-empty all the
same.

`org_id` is ignored by the dashboard, which takes the organisation from the
auth token. It stays in the file because the gateway's own API, the fallback
`seed.sh` uses on a stack with no dashboard, does read it.

### Reaching the upstream

The port and path come from the countries server itself: `server.ts` sets
`graphqlEndpoint: "/graphql"` and reads its port from `PORT`, which the
ProductClass sets to `4000`. The service name is pinned by app-template's
`forceRename`, so it is the same in every tenant.

The topology's own postInstall script names the same upstream fully qualified,
as `http://countries-graphql.${NAMESPACE}.svc.cluster.local:4000/graphql`. This
file uses the bare `countries-graphql` instead, because the topology
substitutes the namespace at runtime and `seed.sh` loads a file verbatim. Both
resolve: the gateway pod runs in the tenant namespace alongside the countries
pod, so its resolver search path completes the short name, and the example
stays tenant-agnostic.
