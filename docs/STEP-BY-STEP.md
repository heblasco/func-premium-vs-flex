# Step-by-step guide: deploy, run the test, and monitor it

This guide takes you from an empty environment to a running **Flex Consumption
vs reserved-capacity plan (App Service Dedicated P0v3)** comparison monitored
with Application Insights.

> The "Premium" side runs on a **Dedicated plan** (keyless, always-on), not
> **Elastic Premium**. EP requires an Azure Files content share with a shared
> key, which the demo subscription disables through policy. Switching to EP
> requires infrastructure changes; `EP1` is not a supported value for
> `premium_sku_name` in this project.

---

## 0. Prerequisites

- **Azure CLI** (`az`), **Terraform >= 1.9**, **Node.js 20+**, **Azure Functions
  Core Tools v4**, and **PowerShell 7** (recommended).
- Sign in and select your subscription:
  ```powershell
  az login
  az account set --subscription "<your-subscription-id>"
  az account show --query id -o tsv   # Copy this value
  ```
- Available **Flex Consumption** and **App Service Dedicated** quota in the
  selected region.

### 0.1 Register resource providers (once per subscription)

Terraform does not register them (`resource_provider_registrations = "none"`).
If they are not already registered, run the following. It includes
`Microsoft.Batch`, which Azure Load Testing requires for VNet injection:

```powershell
foreach ($p in 'Microsoft.Web','Microsoft.App','Microsoft.Storage','Microsoft.Network','Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.LoadTestService','Microsoft.Batch') {
  az provider register --namespace $p
}
```

---

## 1. Deploy the infrastructure with Terraform

```powershell
cd infra
Copy-Item terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set subscription_id and optionally location/SKUs.

terraform init
terraform plan      # Review the plan
terraform apply     # Enter 'yes'
```

**What happens:**
- A resource group named `rg-<prefix>-<hex>` is created to contain the resources.
- **Storage is keyless and private**, with no public access. The Flex deployment
  container is created through the **control plane** (`azapi`); runtime access
  uses **managed identity** and Blob/Queue/Table data roles.
- Your machine's public IP is detected automatically (`api.ipify.org`) and
  allowed on the functions' **SCM/site endpoints**. If you use a corporate proxy
  or IPv6, set it manually, or specify a range if your IP **rotates**:
  ```hcl
  deployer_ipv4       = "203.0.113.25"   # Or use a CIDR:
  deployer_allow_cidr = "167.220.0.0/16" # Allow a corporate range
  ```
- Storage role assignments are created **before** the functions, followed by
  a 60-second RBAC propagation wait to avoid startup failures.

> **Applying changes with private storage:** your machine cannot access the
> storage data plane, so a full `terraform apply` or `plan` may fail while
> **refreshing** storage properties (static website/queue). For changes that
> do not affect storage, `terraform apply -refresh=false` skips that refresh;
> it also skips drift detection, so review the plan carefully.

When deployment completes, Terraform displays outputs such as app names,
hostnames, and the Load Testing resource name. Retrieve them again with:

```powershell
terraform output
```

---

## 2. Publish the code to both Function Apps

The **same** Node.js code is published to the Flex and Dedicated apps:

```powershell
cd ..\scripts
.\deploy.ps1
```

Internally:
1. `build.ps1` installs production dependencies in `src/`.
2. `func azure functionapp publish` publishes to each app through the public
   SCM endpoint, restricted to your IP.

### 2.1 Verify connectivity and warm up the apps

The `/api/health` endpoint is anonymous:

```powershell
$tf = terraform -chdir=..\infra output -json | ConvertFrom-Json
curl.exe "https://$($tf.flex_default_hostname.value)/api/health"
curl.exe "https://$($tf.premium_default_hostname.value)/api/health"
```

To test `/api/stress`, which requires a function key:

```powershell
$rg = $tf.resource_group_name.value
$key = az functionapp keys list -g $rg -n $tf.flex_app_name.value --query "functionKeys.default" -o tsv
curl.exe "https://$($tf.flex_default_hostname.value)/api/stress?cpuMs=200&memMB=256&loops=1&runId=smoke" -H "x-functions-key: $key"
```

> `/api/stress` parameters: `cpuMs` (0-10000), `memMB` (0-512), `loops`
> (1-50), and `runId` (a label for KQL correlation).

---

## 3. Run parallel load

There are **two** options. **Direct load** provides the quickest results;
**Azure Load Testing** uses managed test engines with VNet injection.

### 3.A Direct load (recommended for the demo)

Send requests to both apps simultaneously from your machine. Your IP/CIDR
must be allowed:

```powershell
cd ..\scripts
.\run-direct-load.ps1 -Workers 12 -Duration 120 -CpuMs 300 -MemMB 128 -Loops 2
```

The script prints a comparison table (requests, successes/errors, average and
maximum latency, and requests per second), plus a `runId` (`direct-...`) for
Application Insights correlation.

### 3.B Azure Load Testing with VNet injection

```powershell
.\run-loadtest.ps1 -Users 20 -Ramp 30 -Duration 300 -CpuMs 200 -MemMB 256 -Loops 1
```

The script installs the `load` extension, reads Terraform outputs, retrieves
function keys, **renders a JMX file with every value embedded as a literal**
(`loadtest/stress-comparison.generated.jmx`), generates
`loadtest/load-test-config.generated.yaml`, and creates or updates and starts
the test using **VNet injection** to reach the private endpoints. Each engine
runs **both thread groups** (`flex-tg` and `premium-tg`) with identical settings.

> **Azure Load Testing prerequisites:** register `Microsoft.LoadTestService`
> and `Microsoft.Batch` (see section 0.1). The first VNet-injected run may take
> a few minutes to provision its engines.
>
> **Why literals instead of `${__env(...)}`:** Azure Load Testing engines
> **do not resolve** the JMeter `${__env(NAME)}` function in this plan.
> ThreadGroup counters end the run immediately (*NoRequestsSent*), and the
> sampler host remains `${__env(FLEX_HOST)}`, producing
> *"Illegal character found in host: '{'"*. `run-loadtest.ps1` therefore replaces
> **all** `${__env(...)}` tokens (threads, duration, host, key, cpuMs, memMB,
> loops, and runId) with actual values before uploading the test. The generated
> JMX is excluded by `.gitignore` and uploaded privately to Azure Load Testing.
> This allows the run to reach `DONE` after sending actual traffic.

### 3.1 Recommended scenarios for a fair comparison

Use separate runs and compare them by `runId`:

- **Cold start**: with `flex_always_ready_count = 0`, leave both apps idle for
  a few minutes and start a short run. Dedicated stays warm (`always_on`);
  Flex can scale to zero.
- **Steady state**: warm up both apps, apply sustained load, and exclude the
  warm-up period.
- **Scale-out**: observe each plan's **instance count**, using the `hostname`
  dimension in Application Insights. Increase `premium_worker_count` to give
  Dedicated more reserved capacity.

---

## 4. Monitor the run

### 4.1 During the run: Azure Load Testing (primary performance source)

In the portal, open **Load Testing**, select `lt-<prefix>-<hex>`, open the
`stress-comparison` test, and select your `runId`. For each **sampler**
(`flex-stress` vs `premium-stress`), inspect:
- Response time (p50/p90/p99), throughput (requests per second), and error rate.
- Real-time client-side metrics.

### 4.2 Server-side monitoring: Application Insights

In the portal, open **Application Insights** and select `appi-<prefix>-<hex>`:
- **Live Metrics**: live CPU load and instance activity during the run.
- **Logs (KQL)**: use [these queries](kql-queries.md), filtering by `runId`
  and time window. Compare plans using `cloud_RoleName` and the custom `plan`
  dimension.
- **Performance** / **Failures**: `stress` duration and errors by plan.

### 4.3 Cost

Actual **Cost Management** data arrives with a delay of hours or until the
following day. Filter by resource group or the
`project=func-premium-vs-flex` tag and group by resource to separate Flex from
the Dedicated App Service plan. Until then, estimate costs using the approach
described in the README: meters plus observed duration and scaling.

---

## 5. Repeat or adjust

Change workload parameters without recreating infrastructure:

```powershell
.\run-loadtest.ps1 -Users 50 -Duration 600 -CpuMs 400 -MemMB 384
```

Alternatively, adjust SKUs or scaling in `terraform.tfvars` and run
`terraform apply` again.

---

## 6. Production hardening (optional)

- Set `public_network_access_enabled = false` on the functions and publish
  code from an **agent inside the VNet** (jump box or self-hosted runner), or a
  pipeline with private endpoint connectivity. Public endpoints are unnecessary
  for Azure Load Testing because it uses private endpoints.
- Move Application Insights and Log Analytics behind **Private Link (AMPLS)**.
- Storage is already **keyless and private**. Keep each identity's data roles
  limited to the required Blob/Queue/Table access.
- Store Terraform state in a **remote backend** such as Azure Storage.

---

## 7. Cleanup

From the repository root:

```powershell
cd infra
terraform destroy
```

This removes the **entire** resource group and stops its ongoing resource
charges.

---

## Troubleshooting

| Symptom | Likely cause | Action |
|---------|--------------|--------|
| `func publish` returns 403 | Your IP is not allowed on SCM | Set `deployer_ipv4`/`deployer_allow_cidr` and run `terraform apply -refresh=false` for this non-storage change |
| `/api/stress` returns 401 | Missing function key | Pass it in `x-functions-key` or `?code=` |
| Flex `listkeys` returns *InternalServerError* | `AzureWebJobsStorage` has an empty key under the keyless policy | Handled by the identity-based `AzureWebJobsStorage__accountName/credential/clientId` settings and removal of the connection string; see `functions_flex.tf` |
| `terraform apply` fails while refreshing storage | The private storage data plane is unreachable | For non-storage changes, use `terraform apply -refresh=false` and review the plan carefully |
| Load test reports *NoRequestsSent* / *Illegal character found in host '{'* | The engine did not resolve `${__env(...)}` | `run-loadtest.ps1` embeds literal values in the generated JMX. Use the script rather than uploading `stress-comparison.jmx` manually |
| Load test sends no traffic to the apps | Load Testing subnet/DNS configuration or missing `Microsoft.Batch` registration | Check `subnetId` (no delegation), function private endpoints, and provider registration |
| Inconsistent request counts in Application Insights | Sampling | Sampling is already disabled in `host.json` and set to 100% on the component; check for a daily cap |
