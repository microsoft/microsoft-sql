# Choosing where Data API builder runs

This skill's procedure targets Azure Container Apps. The others are listed so a request for one is
recognized and routed rather than forced onto Container Apps. Sources: the Microsoft Learn
deployment index for Data API builder, and the 2.1.5 runtime behaviour measured for this skill.

| Host | Choose it when | What changes from this skill |
|---|---|---|
| Azure Container Apps | Default: a container, managed ingress and revisions, no cluster | Nothing; this is the procedure |
| Azure App Service | The team already runs App Service, or wants its built-in authentication | Learn deploys a package, not an image. The App Service .NET runtime has no SDK, so restore DAB on the build machine and ship the restored payload; do not run `dotnet tool restore` at startup. The `AppService` provider belongs here, with App Service authentication turned on |
| Azure Kubernetes Service | A cluster already exists and is operated by the team | Same image and configuration. Session affinity for MCP is the cluster's ingress problem |
| Azure Container Instances | A short-lived demonstration | No managed TLS ingress or revisions; not a production target |
| Hosted MCP in a connector namespace | The user wants a hosted SQL MCP endpoint without running DAB | A different product surface with its own quickstart; this skill does not apply |

Whatever the host:

- One image or package per DAB version, with the configuration inside it.
- `production` mode, a real inbound provider, and `runtime.health.roles` set last.
- A managed identity for the database where the host supports one.
- `runtime.mcp.allowed-hosts` lists the public host name whenever MCP is enabled.
- One MCP process per client session, unless multi-replica sessions were tested.
