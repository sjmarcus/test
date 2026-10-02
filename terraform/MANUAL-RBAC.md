# Manual RBAC steps

The deploying service principal (`6a7f01dc-25e9-4a2d-ba52-00307eceff67`,
object id `46dfc00f-839e-4c22-a9e4-b50f9c264fa5`) does not hold
`Microsoft.Authorization/roleAssignments/write`, so it cannot create role
assignments. The four `azurerm_role_assignment` blocks in `main.tf` are
commented out; these are the commands that replace them.

Run these as an account with **Owner** or **User Access Administrator** on
the subscription — not as the deploying SP.

## Pass 1 — before the first apply

These three target resources that already exist.

```bash
KV=/subscriptions/a5882394-9932-4e4a-84e8-2e55c04d3bd2/resourceGroups/rg-webhook-renewal-spike/providers/Microsoft.KeyVault/vaults/kv-wbhkrnw-mb4x3
AA=/subscriptions/a5882394-9932-4e4a-84e8-2e55c04d3bd2/resourceGroups/rg-webhook-renewal-spike/providers/Microsoft.Automation/automationAccounts/aa-webhook-renewal-spike

DEPLOYER=46dfc00f-839e-4c22-a9e4-b50f9c264fa5
FUNC=308c2f1f-c7bc-4646-9404-2b3703125631

# Deployer -> Key Vault (so Terraform can create the placeholder secret)
az role assignment create --assignee "$DEPLOYER" \
  --role "Key Vault Secrets Officer" --scope "$KV"

# Function App -> Key Vault (read/write the webhook URL secret)
az role assignment create --assignee "$FUNC" \
  --role "Key Vault Secrets Officer" --scope "$KV"

# Function App -> Automation Account (create/renew the webhook)
az role assignment create --assignee "$FUNC" \
  --role "Automation Contributor" --scope "$AA"
```

Then apply:

```bash
./deploy.ps1 -Apply
```

Key Vault RBAC is eventually consistent. If the apply 403s on
`azurerm_key_vault_secret.webhook_url`, wait a minute and re-run — that is
propagation delay, not a config problem.

## Pass 2 — after the first apply

The Event Grid system topic's managed identity does not exist until the
topic is created, so this grant cannot be made up front.

```bash
# Get the principal ID the apply just created
terraform state show azurerm_eventgrid_system_topic.kv | grep principal_id

ST=/subscriptions/a5882394-9932-4e4a-84e8-2e55c04d3bd2/resourceGroups/rg-webhook-renewal-spike/providers/Microsoft.Storage/storageAccounts/stwbhkrnwmb4x3

az role assignment create --assignee <system-topic-principal-id> \
  --role "Storage Blob Data Contributor" --scope "$ST"
```

No further apply is needed — the subscription already points at the
dead-letter container; the grant just makes it writable.

## Verifying

```bash
az role assignment list --scope "$KV" --output table
az role assignment list --scope "$AA" --output table
az role assignment list --scope "$ST" --output table
```

## If you tear this down

`terraform destroy` + re-apply regenerates `random_string.suffix`, so
resource names (`kv-wbhkrnw-mb4x3`, `stwbhkrnwmb4x3`, …) and the Function
App principal ID all change. Every scope and assignee above must be
recaptured by hand.

If that happens more than once or twice, grant the SP
`User Access Administrator` scoped to the resource group and uncomment the
blocks in `main.tf` instead:

```bash
az role assignment create --assignee "$DEPLOYER" \
  --role "User Access Administrator" \
  --scope /subscriptions/a5882394-9932-4e4a-84e8-2e55c04d3bd2/resourceGroups/rg-webhook-renewal-spike
```

Note the trade-off: `User Access Administrator` lets the SP grant itself any
role within that scope, including Owner. Acceptable for a disposable spike
RG; not something to carry into a shared or production subscription.

---

## VM password rotation (added for phase 2)

The function's managed identity needs rights on each resource group holding
VMs it rotates passwords for. Per resource group, not subscription-wide.

```bash
FUNC=308c2f1f-c7bc-4646-9404-2b3703125631

az role assignment create --assignee "$FUNC" \
  --role "Virtual Machine Contributor" \
  --scope /subscriptions/a5882394-9932-4e4a-84e8-2e55c04d3bd2/resourceGroups/<vm-resource-group>
```

Repeat for each resource group. The commented `func_vm_contributor` block in
`main.tf` does this in Terraform via `var.vm_resource_group_names`, once the
deploying SP can create role assignments.

### Narrow this before production

`Virtual Machine Contributor` is far broader than the task needs. It permits
deleting VMs, resizing them, and detaching disks. The function only needs:

- `Microsoft.Compute/virtualMachines/read`
- `Microsoft.Compute/virtualMachines/extensions/read`
- `Microsoft.Compute/virtualMachines/extensions/write`

A custom role with those three actions should replace it. As it stands, the
managed identity can destroy any VM in the granted scope, which is a much
larger blast radius than resetting a password warrants.

### Tagging secrets for rotation

A VM password secret is enrolled by tagging it -- no redeploy, no config
change:

```bash
az keyvault secret set-attributes \
  --vault-name kv-wbhkrnw-mb4x3 \
  --name Team1VMPassword \
  --tags VM-NAME=vm-team1-01 ADMIN-NAME=localadmin
```

The handler refuses to act on any secret missing either tag, so an untagged
secret is inert rather than dangerous.

Confirm what the function would act on before enabling anything:

```bash
curl -X POST "https://func-wbhkrnw-mb4x3.azurewebsites.net/api/RotateVMPassword?code=<key>" \
  -H "Content-Type: application/json" \
  -d '{"listOnly":true}'
```

---

## Secret distribution (.NET function)

Deployment is two-pass, same reason as the other Event Grid subscriptions:
the subscription validates the function endpoint live, so the code must exist
before it can be created.

```bash
# 1. Create the app without the subscription
terraform apply -var enable_secret_distribution=true

# ...this fails on sub-secret-new-version. Expected.

# 2. Publish the .NET code
cd ../secret_distributor
func azure functionapp publish <distributor_function_app_name>

# 3. Re-apply -- the subscription can now validate
cd ../terraform && terraform apply -var enable_secret_distribution=true
```

Set `enable_secret_distribution = true` in `terraform.tfvars` rather than
passing `-var` each time.

### Grant

The distribution app needs to READ secrets, not write them:

```bash
DIST=$(terraform output -raw distributor_identity_principal_id)

az role assignment create --assignee "$DIST" \
  --role "Key Vault Secrets Officer" \
  --scope /subscriptions/a5882394-9932-4e4a-84e8-2e55c04d3bd2/resourceGroups/rg-webhook-renewal-spike/providers/Microsoft.KeyVault/vaults/kv-wbhkrnw-mb4x3
```

"Secrets User" (read-only) is enough to read and push, but the handler also
writes `LAST-PUSHED-VERSION` / `LAST-PUSHED-UTC` / `LAST-PUSHED-KEY-ID` tags
back so a later run can tell what GitHub already holds. Those tag writes need
Officer. With Secrets User the push still succeeds and only the bookkeeping is
skipped, which the handler logs as a warning rather than failing on.

### GitHub token

A fine-grained PAT with **Secrets: Read and write** on each target repository.
Read is required too -- sealing a value needs the repo public key.

```bash
az keyvault secret set --vault-name kv-wbhkrnw-mb4x3 \
  --name github-pat --value "<token>"
```

The token expires, which means a rotation system depending on a manually
rotated credential. A GitHub App issues short-lived tokens and is the right
answer once this stops being a demo.

### Tagging a secret for distribution

```bash
az keyvault secret set-attributes \
  --vault-name kv-wbhkrnw-mb4x3 \
  --name Team1VMPassword \
  --tags VM-NAME=vm-rotate-test ADMIN-NAME=xadmin \
         GITHUB-REPO=sjmarcus/test GITHUB-SECRET-NAME=VM_ADMIN_PASSWORD
```

All tags together -- Key Vault replaces the tag collection wholesale, so
omitting the VM ones would break rotation.

Secrets without both GitHub tags are ignored by the distributor, so this is
opt-in per secret and nothing else in the vault is affected.
