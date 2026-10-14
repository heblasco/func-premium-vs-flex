# Deployment, rebuild and demo runbook

Use this as the entry point for the **three-arm private demo**: Flex Consumption,
Elastic Premium EP1, and the existing Premium-named **Dedicated P0v3** reference.
Commands use PowerShell 7 from the repository root unless stated otherwise.
They are operator actions, not an unattended deployment script.

| Your situation | Start here |
|---|---|
| First deployment or everything was destroyed through Terraform | [Fresh deployment](#fresh-deployment) |
| Resources exist and you want another demo | [Prepare an existing environment for a demo](#prepare-an-existing-environment-for-a-demo) |
| Source code changed | [Publish a new application revision](#publish-a-new-application-revision) |
| Resources were deleted manually, or the state was lost | [Recover from manual deletion or lost state](#recover-from-manual-deletion-or-lost-state) |
| Reduce costs or remove the environment | [Retention, backup and destruction](#retention-backup-and-destruction) |

The [startup guide](STARTUP-COMPARISON.md) explains measurement semantics, exact
recorded results, artifacts and the alternative external-publisher path.
The [original step-by-step guide](STEP-BY-STEP.md) covers the default two-arm
deployment and Azure Load Testing. Do not mix its public SCM publishing path
with the private executor workflow below.

## Why there is a VM

The Functions do **not** run on, or depend on, this VM. It is a build/publication
and test client inside the VNet, where the private Blob and Function/SCM endpoints
can be reached. It installs locked dependencies, builds one ZIP for all three
arms, performs authenticated tests, and saves complete results.

The VM has no public NIC address or inbound SSH/RDP access. Azure Run Command
provides management; its managed identity has app/container-scoped permissions.
An outbound-only NAT gateway supplies HTTPS access to package feeds and APIs.
Neither operator credentials nor Terraform state are copied to the VM.

WAF does not require a VM. An appropriately configured private CI agent or a
VPN-connected executor with private DNS can replace it. The VM provides a
repeatable client/network path without opening storage to the public internet.
Stopping it does not stop the Functions.

## Prerequisites and inputs

- PowerShell 7, Azure CLI, Terraform >= 1.9 and < 2, Node.js 22+ and OpenSSH
  `ssh-keygen` on the operator machine. Python 3 runs the local Python checks.
  The private controller does not require Functions Core Tools; the legacy
  `deploy.ps1` path does.
- A subscription and region supporting Linux Flex, EP1, Dedicated P0v3 and
  Standard_D2s_v5. Check regional/family quotas and cost approval before creation.
  Sweden Central was verified for the recorded deployment, not guaranteed forever.
- Permission to provision the resources and create scoped role assignments and
  the custom publisher role. Resource Contributor alone does not grant permission
  to create RBAC assignments or role definitions.
- Approved corporate ingress CIDR, VNet address space, and permission to use
  outbound NAT. Do not relax private/keyless storage to bypass failures.
- A saved source revision and `src\package-lock.json`. Terraform alone does not
  publish application code or restore invocation artifacts.

Authenticate and explicitly verify the subscription:

```powershell
az login
az account set --subscription "<subscription-id>"
az account show --query "{id:id,name:name}" -o json
```

Terraform provider auto-registration is disabled. Register missing providers
once per subscription with an authorized identity:

```powershell
$providers = @(
  'Microsoft.Web', 'Microsoft.App', 'Microsoft.Storage', 'Microsoft.Network',
  'Microsoft.ManagedIdentity', 'Microsoft.Compute', 'Microsoft.DevTestLab',
  'Microsoft.Insights', 'Microsoft.OperationalInsights',
  'Microsoft.LoadTestService', 'Microsoft.Batch'
)
foreach ($provider in $providers) {
  az provider register --namespace $provider --wait
  if ($LASTEXITCODE -ne 0) { throw "Provider registration failed: $provider" }
}
```

`Microsoft.Batch` supports VNet-injected Azure Load Testing. The private
verification client does not itself use Azure Load Testing.

### Local files and repeatability

| Input | Treatment |
|---|---|
| Source, scripts, `.tf` files and guides | Commit together; use the same revision for a demo. |
| `infra\terraform.tfvars` | Local and ignored. Back up securely; do not overwrite an existing configuration with the example. |
| `infra\terraform.tfstate` and backup | Currently local and ignored. Protect as sensitive; coordinate a single operator. |
| `infra\.terraform.lock.hcl` | Currently ignored. Preserve for provider-version repeatability; a fresh init may resolve newer allowed providers. |
| VM SSH key pair | Store outside the repository, in a stable location. Only its public-key path goes in tfvars. |
| Raw results and immutable packages | Private Blob data, not Git content or Terraform-managed backups. |

Do not use a temporary assistant/session directory for a reusable key path.
For example, create a key only if it does not already exist:

```powershell
$keyDirectory = Join-Path $HOME '.ssh'
[IO.Directory]::CreateDirectory($keyDirectory) | Out-Null
$keyPath = Join-Path $keyDirectory 'fnvs-verification'
if ((Test-Path -LiteralPath $keyPath) -or (Test-Path -LiteralPath "$keyPath.pub")) {
  throw 'A key already exists. Reuse it deliberately or choose another filename.'
}
ssh-keygen -t ed25519 -f $keyPath
if ($LASTEXITCODE -ne 0) { throw 'Key generation failed.' }
Write-Output "Public-key path: $keyPath.pub"
```

The OS requires a public key even though SSH ingress is denied. A newly generated
key is fine for a fresh rebuild. Changing the key of an existing VM can imply a
replacement: inspect the plan rather than changing it as routine demo setup.

## Fresh deployment

**Only use this bootstrap sequence for an empty/destroyed environment.**
Setting `ep_package_sha256 = null` on an existing deployment plans removal of
EP compute; it is not a harmless reset or a normal code-release step.

### 1. Configure and provision bootstrap resources

Copy `infra\terraform.tfvars.example` to `infra\terraform.tfvars` only when the
destination does not exist. Set subscription, region and approved network values.
The private-controller path requires these settings:

```hcl
subscription_id = "<subscription-id>"
location        = "swedencentral"
name_prefix     = "fnvs"

auto_discover_deployer_ip = false
deployer_allow_cidr       = "<approved-ingress-CIDR>"

enable_verification_runner       = true
verification_ssh_public_key_path = "C:\\Users\\<user>\\.ssh\\fnvs-verification.pub"
enable_elastic_premium           = true
ep_package_sha256                = null

flex_runtime_version       = "22"
premium_node_version       = "22"
premium_sku_name           = "P0v3"
flex_always_ready_count    = 0
ep_minimum_instances       = 1
ep_prewarmed_instances     = 1
ep_maximum_instances       = 3
```

Replace placeholders; do not paste them literally. The private controller
currently validates Node 22 and FC1/P0v3/EP1. Other runtime/SKU combinations need
corresponding controller changes. Leave `ep_publisher_principal_id` unset for
the built-in runner: its container assignment is created automatically.

```powershell
terraform "-chdir=infra" init
terraform "-chdir=infra" validate
terraform "-chdir=infra" plan "-out=tfplan.bin"
# Inspect the plan. Stop on unexpected deletion/replacement or access changes.
terraform "-chdir=infra" apply tfplan.bin
```

Check every command's exit status; do not continue after a failed plan/apply.
This creates the two base apps, networking, monitoring, runner, private results
container and EP storage/identity. EP compute is intentionally deferred.

On a partially failed apply, keep the state, inspect what Azure created, resolve
the specific failure and generate a new plan. Do not reuse a stale saved plan.

### 2. Build once, publish twice, and smoke-test

```powershell
.\scripts\Invoke-PrivateVerification.ps1 -Action build
.\scripts\Invoke-PrivateVerification.ps1 -Action publish
.\scripts\Invoke-PrivateVerification.ps1 -Action run -Targets flex,dedicated -Samples 10
```

`build` transfers source/lockfile/scripts through ARM, installs dependencies in
Linux, normalizes ZIP permissions, uploads the immutable EP package and verifies
its bytes. Record its **new SHA256**. `publish` sends that same ZIP to Flex and
Dedicated through private SCM. A successful infrastructure deployment alone is
not a successful application deployment.

Wait for identity/RBAC propagation if required. A failed smoke blocks further
measurement; inspect its artifacts and fix the cause instead of ignoring errors.

### 3. Create EP from the uploaded package

Set `ep_package_sha256` to the hash printed by the successful build. Do not reuse
an old hash unless that exact blob still exists and has been verified.

```powershell
terraform "-chdir=infra" plan "-refresh=false" "-out=tfplan.bin"
# Review: EP plan/app/private endpoint and scoped publisher assignment.
terraform "-chdir=infra" apply tfplan.bin

.\scripts\Invoke-PrivateVerification.ps1 -Action sync -Targets elastic-premium
.\scripts\Invoke-PrivateVerification.ps1 -Action run -Targets flex,dedicated,elastic-premium -Samples 10
```

The second-phase `-refresh=false` is a constrained workaround when the public
operator cannot read existing private storage data planes. It assumes the
just-created state is current and is **not a full drift assessment**. Check
relevant resources through ARM. Use a private-connected Terraform operator for
normal full refreshes when available.

EP's role took about 20 minutes to propagate in the recorded deployment. Do not
widen permissions or send operator credentials to the runner to avoid waiting.
Allow at least 15 minutes after deployment/configuration changes before taking
the measurements below. Verify App Insights ingestion using the run IDs and
[KQL examples](kql-queries.md).

## Prepare an existing environment for a demo

Do **not** clear the EP hash or rebuild infrastructure merely to rerun tests.
Read the names from Terraform outputs rather than copying historical names:

```powershell
$tf = terraform "-chdir=infra" output -json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Terraform outputs unavailable.' }
$rg = $tf.resource_group_name.value
$vm = $tf.verification_runner.value.vm_name
if (-not $vm) { throw 'The private verification runner is not provisioned.' }

az vm start --resource-group $rg --name $vm
if ($LASTEXITCODE -ne 0) { throw 'Runner startup failed.' }
az vm get-instance-view --resource-group $rg --name $vm `
  --query "instanceView.statuses[].displayStatus" -o tsv

.\scripts\Invoke-PrivateVerification.ps1 -Action run -Targets flex,dedicated,elastic-premium -Samples 10
```

The VM has automatic shutdown at **22:00 UTC**, not automatic startup. Schedule
the demo outside that shutdown window. Do not change the schedule silently.
Smoke/health requests warm the apps: run them before, never during, the idle
protocol. Ensure no other load, publication or configuration changes overlap.
If the VM or its disk was recreated rather than merely deallocated, its local
build/package files are gone. Follow the new-revision publication sequence to
rebuild and synchronize all arms before using the measurement controller.

### Run the matched protocols

Start with the original `flex_always_ready_count` recorded for restoration.
For the comparison, use 0 first, then 1, keeping all other settings constant.

```powershell
.\scripts\Invoke-PrivateVerification.ps1 -Action run -Targets flex,dedicated,elastic-premium -Samples 100
.\scripts\Invoke-PrivateVerification.ps1 -Action run -Targets flex,dedicated,elastic-premium -Scenario burst -Workers 24 -DurationSeconds 180 -CpuMs 200
.\scripts\Invoke-PrivateVerification.ps1 -Action run -Targets flex,dedicated,elastic-premium -Scenario idle-probe -IdleSeconds 300 -Samples 10
```

After editing only `flex_always_ready_count` in tfvars, use a reviewed scoped
plan to avoid incidental EP changes from the provider readback limitation:

```powershell
terraform "-chdir=infra" plan "-refresh=false" `
  "-target=azurerm_function_app_flex_consumption.flex" `
  "-target=terraform_data.flex_fix_host_storage" "-out=tfplan.bin"
terraform "-chdir=infra" apply tfplan.bin
```

Wait at least 15 minutes after each readiness change; repeat the same protocols.
Restore the original count through the same reviewed process, then smoke-test.
Targeting is for this isolated experiment, not general infrastructure maintenance.

Keep run IDs and snapshots separate; do not pool configurations. One five-minute
idle probe is illustrative, not proof of scale-to-zero or cold start. Scale-out
requires overlapping activity/platform evidence; IDs alone do not identify a
prewarmed allocation. The detailed guide records the unequal scaling ceilings
and other limits of the demonstrated setup.

## Publish a new application revision

With an existing running VM, use `build` and `publish` as above, record the new
hash, then update **only the EP package hash** and review/apply/sync. Do not set
the hash to null between releases. Republishing is unnecessary for unchanged
code when only rerunning measurements.

Always publish the same built ZIP to all three arms and run a smoke before
settling. Rebuilding can produce a different ZIP hash even with identical source
because package metadata/timestamps can change.

## Retention, backup and destruction

### Reuse without destroying

After all runs/uploads finish, the runner can be deallocated:

```powershell
az vm deallocate --resource-group $rg --name $vm
```

Deallocation stops VM compute billing, not its disk, NAT, private endpoints, EP
minimum or Dedicated plan charges. The recorded deployment was deliberately
retained. Public retail estimates in the results guide are not a spending cap.

**Do not use `enable_verification_runner = false` as a VM-only cleanup switch.**
It also controls the `startupresults` container and scoped roles. Back up data
and separate its lifecycle in Terraform before selectively removing the runner.
Review any resulting plan for data deletion and app dependencies.

### Back up before deleting

Save the source revision, tfvars, state/provider lockfile and required raw results
outside the resource group being deleted. State can contain sensitive values:
do not commit it, keys, raw tokens or generated plans to Git.

Complete results live in the Flex account's private `startupresults` container.
Local Run Command receipts are **not** complete JSONL backups; command output is
size-limited. Terraform does not restore blobs from its state.

One export option, on a Windows client with VNet/VPN connectivity, private DNS
and container-scoped **Storage Blob Data Reader** permission, is:

```powershell
# Run on that private-connected client, not an unconnected public workstation.
$destination = 'C:\demo-backup\startupresults'
[IO.Directory]::CreateDirectory($destination) | Out-Null
az storage blob download-batch --account-name $tf.flex_storage_account.value `
  --source startupresults --destination $destination --auth-mode login
if ($LASTEXITCODE -ne 0) { throw 'Result export failed; do not destroy storage.' }
```

Supply the account name explicitly if that client does not have Terraform
outputs. Compare downloaded sizes/hashes against each run's `receipt.json`.
Alternatively use an approved private-network export job to independently
retained storage; that export job is not provided by the current controller.
If no verified export exists, either retain the storage or explicitly accept
losing the historical results. Never open its firewall as an export shortcut.

### Destroy the entire demo

Only after backup and explicit approval:

```powershell
terraform "-chdir=infra" plan -destroy "-out=tfplan.bin"
# Inspect every deletion and confirm the target subscription/resource group.
terraform "-chdir=infra" apply tfplan.bin
```

Prefer a private-connected Terraform operator for a full refreshed destroy plan.
If private storage refresh blocks the plan, stop and resolve operator access;
do not blindly skip refresh before deletion.

The provider allows resource-group deletion even when additional resources are
present. Inspect the entire group, including manually added resources, before
approving. Destruction deletes the stored packages/results as well as compute.
Subscription-level provider/feature registrations are not undone by Terraform.

After a successful destroy, start at [Fresh deployment](#fresh-deployment), with
`ep_package_sha256 = null`. Rebuild and publish the code again. The random suffix,
hostnames, identities and keys may change; use the new Terraform outputs.

## Recover from manual deletion or lost state

- **Resources deleted in the portal, state still present:** back up state and
  inventory what remains. If EP's package was deleted, choose the fresh bootstrap
  configuration deliberately; clearing its hash removes any surviving EP compute.
  Run a normal refreshed `terraform plan` to reconcile the configuration with
  Azure. Do not use `-refresh=false` while state still describes deleted resources.
  If surviving private storage prevents refresh, use a private-connected operator.
  Review replacements, rebuild missing packages, publish, and smoke-test.
- **State lost but resources remain:** restore the protected state backup, or
  inventory and import the resources deliberately. Do not initialize an unrelated
  empty state and assume it will take ownership of the existing deployment.
- **Everything and state were deleted:** use the saved source/configuration and
  fresh bootstrap steps. Terraform recreates infrastructure, not deleted data.

## Troubleshooting and acceptance gates

| Symptom | Safe next action |
|---|---|
| Run Command cannot execute | Check VM running state, guest agent, outbound NAT and platform/DNS access. Do not add inbound SSH/public IP as a workaround. |
| Newly granted ARM/Blob access returns 403 | Confirm identity and exact scope, then allow propagation. Stop measurements until preflight succeeds. |
| Standard public IP requires `AllowBringYourOwnPublicIpAddress` | This was subscription-specific. Confirm the error, register the required feature if authorized, wait for Registered, then re-register Microsoft.Network and replan. |
| Flex 503 with `host.json` access denied | Use the provided ZIP builder's non-root-readable permissions; do not reuse the earlier failed package. |
| Missing EP package after rebuild | Build/upload first, use its actual SHA256, apply the EP hash and sync triggers. |
| Repeated EP in-place plan difference | See the AzureRM `content_share_force_disabled` readback limitation in the startup guide. Keep the desired flag true; do not ignore it. |
| No custom events yet | Check ingestion delay and run correlation before concluding failure. JSONL remains authoritative for client attempts. |

If the documented networking feature error actually occurs, an authorized
subscription administrator can use:

```powershell
az feature register --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress
az feature show --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress --query properties.state -o tsv
# Only after the feature reports Registered:
az provider register --namespace Microsoft.Network --wait
```

Acceptance requires private DNS, correct SKU/runtime/package, authenticated HTTP
success, durable checksum-verified artifacts and correlated telemetry. Do not
declare the environment ready merely because Terraform or Run Command returned
an infrastructure success status.
