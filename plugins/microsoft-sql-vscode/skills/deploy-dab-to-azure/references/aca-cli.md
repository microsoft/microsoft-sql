# Azure CLI sequence for Data API builder on Azure Container Apps

## Contents

- 0. Values
- 1. Identity first
- 2. Registry and image
- 3. Environment, then the host name
- 4. Put the host into the configuration, then build
- 5. The app
- 6. Logs
- 7. Roll back
- 8. Clean up what this session created, by name

Bash. Every flag here was read from the Azure CLI's own help, with the `containerapp` extension
installed. Run the steps in order: each one produces a value a later one needs.
Confirm the subscription, region and resource group with the user before step 1.

## 0. Values

```bash
RG=rg-dab-api            # an existing group is fine; record whether this session created it
LOC=eastus2
ID=id-dab-api            # user-assigned managed identity
ACR=acrdabapi$RANDOM     # registry names are global and alphanumeric
ENV=cae-dab-api
APP=dab-api
SQL_SERVER=<logical-server-name>
SQL_DB=<database-name>
TAG=2.1.5-$(date +%Y%m%d%H%M)   # immutable: never reuse a tag
```

## 1. Identity first

```bash
az group create -n $RG -l $LOC
az identity create -g $RG -n $ID
ID_RES=$(az identity show -g $RG -n $ID --query id -o tsv)
ID_CLIENT=$(az identity show -g $RG -n $ID --query clientId -o tsv)
ID_PRINCIPAL=$(az identity show -g $RG -n $ID --query principalId -o tsv)
```

Hand `$ID` to `entra-id-auth` now, so its database user and grant exist before the first revision
connects.

## 2. Registry and image

```bash
az acr create -g $RG -n $ACR --sku Basic          # no --admin-enabled: the identity pulls
az role assignment create --assignee-object-id $ID_PRINCIPAL \
  --assignee-principal-type ServicePrincipal --role AcrPull \
  --scope "$(az acr show -n $ACR --query id -o tsv)"
```

## 3. Environment, then the host name

```bash
az containerapp env create -g $RG -n $ENV -l $LOC
DOMAIN=$(az containerapp env show -g $RG -n $ENV --query properties.defaultDomain -o tsv)
FQDN=$APP.$DOMAIN                  # internal ingress: $APP.internal.$DOMAIN
```

`az containerapp env create` also creates a Log Analytics workspace unless told otherwise
(`--logs-destination`). Say so; it is a billed resource.

## 4. Put the host into the configuration, then build

If MCP is enabled, write `$FQDN` (and any custom domain) into `runtime.mcp.allowed-hosts` as a
literal string after every `dab` CLI edit, then build from the folder holding the `Dockerfile` and
`dab-config.json`:

```bash
az acr build -r $ACR --image dab-api:$TAG .
```

## 5. The app

```bash
az containerapp create -g $RG -n $APP --environment $ENV \
  --image $ACR.azurecr.io/dab-api:$TAG \
  --registry-server $ACR.azurecr.io --registry-identity $ID_RES \
  --user-assigned $ID_RES \
  --ingress external --target-port 5000 \
  --min-replicas 1 --max-replicas 1 \
  --env-vars "DATABASE_CONNECTION_STRING=Server=tcp:$SQL_SERVER.database.windows.net,1433;Database=$SQL_DB;Authentication=Active Directory Managed Identity;User Id=$ID_CLIENT;Encrypt=True;"

az containerapp show -g $RG -n $APP --query properties.configuration.ingress.fqdn -o tsv
```

The last line must print `$FQDN`. If it does not, the configuration lists the wrong host: fix
`allowed-hosts`, build a new tag, and update the app.

`--max-replicas 1` is for an app serving MCP; see the scaling note in SKILL.md. A REST-only app can
scale out.

## 6. Logs

```bash
az containerapp logs show -g $RG -n $APP --type system --tail 50    # pulls, probes, restarts
az containerapp logs show -g $RG -n $APP --type console --tail 50   # DAB's own output
```

## 7. Roll back

```bash
az containerapp update -g $RG -n $APP --image $ACR.azurecr.io/dab-api:<previous-tag>
```

## 8. Clean up what this session created, by name

```bash
az containerapp delete -g $RG -n $APP --yes
az containerapp env delete -g $RG -n $ENV --yes
az acr delete -g $RG -n $ACR --yes
az identity delete -g $RG -n $ID
# az group delete -n $RG  -- only if this session created the group, and the user agreed
```

The workspace created with the environment, the database user and its grants are separate; list
them and ask before deleting.
