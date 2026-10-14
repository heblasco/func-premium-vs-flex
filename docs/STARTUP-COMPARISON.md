# Startup and readiness comparison

This experiment compares **Flex Consumption (HTTP always-ready=0 and =1)** with
**Elastic Premium EP1 without Azure Files (keyless/private)**. The existing
**Dedicated P0v3 Always On** app remains available as a separate reference.
EP is opt-in and disabled by default. The existing stress/load scripts are unchanged.

**Deployment and demo entry point:** follow the
[deployment, rebuild and demo runbook](DEPLOYMENT-RUNBOOK.md) for the complete
private-VM workflow, prerequisites, reconstruction, backups and cleanup. This
guide focuses on experiment semantics, alternative publishing and measured results.

## What is actually measured?

| Signal | Meaning | Not evidence of |
|---|---|---|
| Client latency | Time from sending the HTTP request until the whole body arrives | Pure cold-start duration |
| Handler duration | Existing `durationMs` inside the stress handler | Host/container initialization |
| Client minus handler | Network, connection, routing, queueing, host and response overhead | Platform startup alone |
| First in process | First instrumented health/stress invocation in this Node process | A platform cold start |
| Process boot ID | Random identity for this loaded worker process | A new physical instance |
| Instance ID | `WEBSITE_INSTANCE_ID`, or explicitly labeled hostname fallback | Membership in an always-ready/prewarmed pool |

**Premium always-ready and prewarmed are different:** the minimum keeps an app
ready before traffic; the prewarmed buffer supports HTTP scale-out under load.
An idle first-hit test does **not** exercise that buffer. Flex always-ready
capacity is assigned to the `http` scale group, with on-demand capacity beyond it.

This app has no custom initialization delay. Health requests increment the same
process counter as stress requests, so a health check cannot leave a misleading
"first stress invocation" marker. Uninstrumented platform initialization can
still have happened before either endpoint executes.

## 1. Prepare the optional real EP arm

**Azure verification was completed on 2026-10-14** using the optional private
executor below, including real EP package startup and concurrent scale-out.
See the recorded evidence and limitations at the end of this guide.
Nothing in the measurement runner creates, restarts, or reconfigures Azure resources.

The optional topology adds one independent EP1 plan/app, user-assigned identity,
storage account, Blob package container, integration subnet/NSG, three storage
private endpoints and (by default) one app private endpoint. Existing apps and
their state addresses remain unchanged. The
[architecture diagram](assets/architecture.png) includes this optional third arm,
the private verification VM, outbound-only NAT, private package publication and
durable results. Its [editable Excalidraw source](assets/architecture.excalidraw)
is maintained alongside the image.

### Keyless EP caveat and prerequisites

Microsoft supports [EP without Azure Files](https://learn.microsoft.com/en-us/azure/azure-functions/storage-considerations#create-an-app-without-azure-files)
using a private external Blob package and managed identity, but warns that
**scaling can be limited**. Results describe this specific configuration, not
all Premium deployments. Shared writable content, portal editing and file-system
log streaming are not available; use Application Insights.

Before any deployment, approve cost/quota in the intended subscription/region.
EP has a continuously billed active minimum; prewarmed instances are billed
when allocated under traffic. The default maximum of three bounds active EP
scale-out, not an exact money budget. Storage/private endpoints also incur costs,
including during the bootstrap stage.

An external publishing executor using the original PowerShell wrappers needs:

- Connectivity to the VNet (or an appropriately peered/routed network) and private
  DNS resolution for the storage Blob endpoint.
- Entra **Storage Blob Data Contributor** on the deployment container; set
  `ep_publisher_principal_id` to its object ID to grant this scoped role.
- Node.js, PowerShell 7, Azure CLI and Terraform with access to the project state.

Alternatively, enable the project's private verification VM described below;
it uses explicit metadata and managed identity, not Terraform state on the VM.
Neither path enables public storage access or needs a storage policy exemption.
RBAC propagation can exceed the initial 60-second wait; the live EP role took
approximately 20 minutes to become consistently effective.
Do not bypass authentication/network controls if an upload returns 403.

### Two-stage bootstrap (operator actions, not run automatically)

This subsection uses an **external private executor**. For the built-in VM,
follow the [fresh deployment sequence](DEPLOYMENT-RUNBOOK.md#fresh-deployment)
instead; do not mix the two publishing paths.

From the repository root, first edit `infra\terraform.tfvars`:

```hcl
enable_elastic_premium = true
ep_publisher_principal_id = "<private-executor-object-id>"
# Leave ep_package_sha256 unset/null until the package has been uploaded.
ep_minimum_instances = 1
ep_prewarmed_instances = 1
ep_maximum_instances = 3
```

```powershell
terraform -chdir=infra plan
terraform -chdir=infra apply
```

This creates bootstrap storage/network/identity resources but **not EP compute**.
From the private executor, restore production dependencies and upload:

```powershell
.\scripts\build.ps1
.\scripts\publish-ep-package.ps1
```

The script packages only `host.json`, package manifests, application source and
installed dependencies. The immutable blob name is the ZIP's SHA256. It uses
`--auth-mode login --overwrite false`, never an account key or SAS. An already
existing blob produces an explicit failure, not an overwrite.

Set the printed `ep_package_sha256` in `terraform.tfvars`, review/apply again.
This creates EP compute and sets `WEBSITE_RUN_FROM_PACKAGE` to that blob URL,
with `WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID` selecting the user-assigned
identity. AzureRM's `content_share_force_disabled=true` prevents Azure Files
settings from being injected. Terraform is the sole owner of the package URL.
For each subsequent code release, upload a new immutable ZIP and change the hash.

Sync triggers through ARM after applying the package URL:

```powershell
$ep = terraform -chdir=infra output -json elastic_premium | ConvertFrom-Json
az rest --method post --url "https://management.azure.com$($ep.app_id)/syncfunctiontriggers?api-version=2023-12-01"
if ($LASTEXITCODE -ne 0) { throw "EP trigger synchronization failed." }
```

Publish the **same source revision and dependencies** to Flex/Dedicated with
`scripts\deploy.ps1`; that existing command deliberately does not deploy EP.
Ensure all apps use the same supported Node major version before comparing.
The EP arm uses `premium_node_version`, as the existing Dedicated arm does.
Record any intentional runtime change in the experiment notes.

Verify startup/package retrieval, the updated response schema, and the
application keys **before** starting the settling/idle experiment. A separate
bounded burst should demonstrate multiple concurrently active EP instance IDs.
A cumulative count of two IDs can be a replacement, not scale-out. If concurrent
scale-out cannot be established, report the prewarmed-buffer experiment as
**inconclusive**, including the no-Azure-Files caveat; do not invent attribution.

Wait at least 15 minutes after deployment/configuration changes before measuring;
this is an experiment convention, not an Azure readiness guarantee. No deployments,
restarts, other load tests, health probes or availability tests should interfere.

## 2. Run a predeclared protocol

All commands below run from the repository root using PowerShell 7. The wrapper
reads ARM configuration/SKU/readiness and retrieves keys **before** the interval.
It fails if the requested EP app is missing or is actually Dedicated.
No HTTP preflight is performed in `idle-probe`; there are no measurement retries.

### Idle first hit and serial follow-ups

```powershell
.\scripts\run-startup-comparison.ps1 -Scenario idle-probe `
  -Targets flex,elastic-premium -Cycles 5 -IdleSeconds 1800 -Samples 20
```

Approximately 2.5 hours of idle time, plus invocation time. Each cycle waits,
probes both targets, then sends 20 serial follow-ups per target. The next wait
starts only after both targets finish. An idle period, even 30 minutes, never
guarantees Flex has scaled to zero. `-IdleSeconds 0` checks the runner only;
it is not a cold-start experiment. Default probe work is `cpuMs=0 memMB=0 loops=1`.

### Warm baseline

```powershell
.\scripts\run-startup-comparison.ps1 -Scenario warm-baseline -Samples 100
```

One explicitly labeled warm-up per target, excluded from summary metrics,
followed by serial measured calls. A failed warm-up aborts the measured phase
and leaves its failure in the invocation log/manifest.

### Burst beyond the ready baseline

```powershell
.\scripts\run-startup-comparison.ps1 -Scenario burst `
  -Workers 12 -DurationSeconds 120 -CpuMs 200 -MemMB 0 -Loops 1
```

One excluded warm-up, then 12 concurrent workers **per target** for 120 seconds.
In-flight requests can finish after that deadline, up to their timeout.
This is a bounded starting workload, **not a guarantee of scale-out**.
Record and adjust concurrency/load if needed, using a new run rather than
silently mixing protocols. Both targets share the client; the manifest records
maximum client event-loop delay. Large client delay/saturation invalidates
latency interpretation; use a suitably sized executor and repeat.

Optionally add `-Targets flex,elastic-premium,dedicated`, or run existing
infrastructure only with `-Targets flex,dedicated`.

For the Flex A/B comparison, first collect with `flex_always_ready_count=0`.
Then explicitly change it to `1` in Terraform, review/apply, settle, and repeat
the identical protocol. These are different runs, not pooled samples. The
runner itself never changes readiness settings. Flex memory, HTTP concurrency,
worker processes, EP minimum/buffer and SKU are recorded where the platform
exposes them; absent fields remain null, not invented defaults.

## 3. Read the invocation table and compare runs

Each run creates a unique ignored directory under `loadtest\startup-results`:

| File | Contents |
|---|---|
| `invocations.jsonl` | Every response/failure: target, cycle, phase, HTTP status/error, latency, server duration, delta, IDs and lifecycle |
| `summary.md` | Aggregate table plus raw per-cycle idle probes |
| `summary.json` | Same summary metrics for further analysis |
| `manifest.json` | Actual pre-run configuration, protocol, client runtime, configuration hash, start/end/status and limitations |

The summary has attempts, successes, errors, min/p50/p95/p99/max client latency,
median handler/delta times, observed host identifiers and processes. Latency
percentiles use **successful, schema-validated responses only**, nearest-rank
calculation. Errors remain explicit; missing server data is null, never zero.
Rows split into `all`, `first-in-process`, `subsequent`, and `failed` cohorts;
do not sum overlapping `all` and cohort rows.

Idle probes report individual cycles and min/median/max, not tail percentiles.
Tail estimates for fewer than 100 successes are unstable; 100 still does not
make p99 statistically reliable. Keep the sample size visible and repeat.
Warm-up failures are visible in JSONL/manifest even though warm-up is excluded
from the performance summary.

```powershell
node .\scripts\startup-runner.js --compare `
  .\loadtest\startup-results\startup-<run-A> `
  .\loadtest\startup-results\startup-<run-B> |
  Set-Content .\loadtest\startup-results\comparison.md
```

This renders the runs and configuration side by side in separate table sections;
it never pools different readiness configurations. Match workload, runtime,
protocol and network path before interpreting differences. Changing a setting
during a run invalidates the pre-run snapshot. Package equality across different
hosting deployment mechanisms remains an operator prerequisite.

Each invocation uses a new connection (no cookies/affinity or keep-alive).
`lookupMs`, `connectMs`, `tlsMs` and `ttfbMs` are cumulative offsets from request
start; null means the event did not occur. This makes network overhead visible
but does not eliminate DNS caching/TLS/session/network confounds. Do not call
small deltas "cold starts", or use this readiness experiment to claim equal
compute capacity or cost efficiency.

**Local logs are authoritative** for attempts and end-to-end latency.
Application Insights is secondary, asynchronous and potentially incomplete.
Use the startup queries in [kql-queries.md](kql-queries.md) with the shared `runId`
and unique `sampleId`; auto-collected `requests` do not automatically inherit
these custom event dimensions.

## Local regression checks

```powershell
npm --prefix src test
pwsh -NoProfile -File .\scripts\tests\startup-wrapper.tests.ps1
pwsh -NoProfile -File .\scripts\tests\ep-package.tests.ps1
python .\scripts\tests\private-verification.test.py
terraform -chdir=infra validate
terraform -chdir=infra test
```

Terraform tests use mocked providers and do not deploy resources. Local HTTP
tests exercise lifecycle, no-preflight ordering, concurrency, timeouts, invalid
responses, failure accounting, percentiles and artifact secret exclusion.
They do not verify EP package startup, platform scale-out or prewarmed behavior.

## References

- [Premium: always-ready and prewarmed instances](https://learn.microsoft.com/en-us/azure/azure-functions/functions-premium-plan)
- [Flex always-ready instances](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#always-ready-instances)
- [EP without Azure Files and its limitations](https://learn.microsoft.com/en-us/azure/azure-functions/storage-considerations#create-an-app-without-azure-files)
- [External deployment packages and managed identity](https://learn.microsoft.com/en-us/azure/azure-functions/deployment-zip-push)

## Private Azure verification executor

The optional `enable_verification_runner` Terraform switch creates a private
Ubuntu VM with managed identity, Trusted Launch, no public NIC address and no
inbound management ports. Run Command is the management path. A dedicated NAT
gateway provides explicit HTTPS egress for dependencies and Azure APIs. The
runner shuts down daily at 22:00 UTC; disks, NAT and EP continue to incur charges.

Provide `verification_ssh_public_key_path` (public key only), enable EP bootstrap,
and review/apply the Terraform plan. Keep private keys and Terraform state local.
Use supported Node 22 on every arm for this verification:
`flex_runtime_version = "22"` and `premium_node_version = "22"`.

```powershell
.\scripts\Invoke-PrivateVerification.ps1 -Action build
.\scripts\Invoke-PrivateVerification.ps1 -Action publish
.\scripts\Invoke-PrivateVerification.ps1 -Action run -Samples 100
```

Build transfers only source, the lockfile and scripts over ARM, installs locked
dependencies on Linux, and uploads a checksummed immutable EP ZIP using the VM
identity. Publication reuses that exact ZIP for Flex and Dedicated through private
SCM. Set `ep_package_sha256` to the reported hash, review/apply the EP compute
plan, then sync and include the third arm:

```powershell
.\scripts\Invoke-PrivateVerification.ps1 -Action sync -Targets elastic-premium
.\scripts\Invoke-PrivateVerification.ps1 -Action run -Targets flex,dedicated,elastic-premium
.\scripts\Invoke-PrivateVerification.ps1 -Action run -Targets flex,dedicated,elastic-premium -Scenario burst -Workers 12 -DurationSeconds 120 -CpuMs 200
```

The executor validates private DNS, actual SKU/runtime and readiness settings.
Function keys remain in memory and a child-process environment, never in result
files. Every JSONL, manifest and summary is uploaded to the private `startupresults`
container in Flex storage; each upload is downloaded inside the VNet and its
SHA256 verified. Compact receipts are also saved locally under
`loadtest\startup-results\azure-private`. Run Command has a small output limit:
the complete private Blob artifacts, not command output, are authoritative.

The operator must review/apply readiness changes separately, let the apps settle,
collect matched runs, and restore the original Flex setting. An idle probe or
new process alone never confirms a cold start or a prewarmed allocation.

### Terraform readback limitation

AzureRM 4.81 does not retain `content_share_force_disabled` when reading the
Linux Function resource and normalizes empty IP-restriction headers differently.
A subsequent full plan can therefore show an in-place EP update despite the
correct live configuration. Keep `content_share_force_disabled = true`; do not
ignore this flag, because that could enable Azure Files settings on an update.
For the readiness-only experiment, review a targeted plan without refreshing
private storage from a public workstation:

```powershell
terraform -chdir=infra plan -refresh=false `
  -target=azurerm_function_app_flex_consumption.flex `
  -target=terraform_data.flex_fix_host_storage -out=tfplan.bin
```

Targeting is a scoped experiment workaround, not a full drift assessment. Review
the saved plan before applying it. Publishing basic authentication remains
disabled on EP; publication and Blob access use managed identity.

## Recorded Azure verification: 2026-10-14

The six selected runs below completed **14,137 of 14,137 HTTP invocations**:
14,125 measured requests and 12 excluded warm-ups, with zero errors.
Initial smoke failures and preliminary runs are retained separately; they are
not silently included in these successful comparison results. A final
post-restoration smoke also completed all nine requests successfully.

All arms received the same Node 22 package:
`6b36037adaf50ec5bad5dcad9e015276ec7197a3d2de6bbdd8b93a7bec5feafc`.
The client was the private D2s_v5 VM in Sweden Central. Maximum client event-loop
delay across the selected runs was 59.93 ms; small latency differences should
not be interpreted as hosting advantages.
The recorded Flex worker-process count used the platform default of one when
the setting was absent; the executor now records null for an unreported count.

### Observed client latency

Warm runs use 100 measured sequential requests per arm, zero CPU/memory work,
and fresh connections. Idle runs contain **one probe after 300 seconds without
test traffic**, followed by ten requests per arm. Probe values are individual
observations, not percentiles or guarantees.

| Flex configuration | Target | Warm p50 ms | Warm p95 ms | Five-minute idle probe ms |
|---|---|---:|---:|---:|
| HTTP always-ready 0 | Flex FC1 | 32.42 | 57.46 | 2,869.76 |
| HTTP always-ready 0 | EP1 minimum 1 / buffer 1 | 36.63 | 61.94 | 84.48 |
| HTTP always-ready 0 | Dedicated P0v3 Always On | 32.21 | 55.04 | 54.25 |
| HTTP always-ready 1 | Flex FC1 | 30.98 | 69.22 | 86.99 |
| HTTP always-ready 1 | EP1 minimum 1 / buffer 1 | 30.80 | 52.91 | 65.20 |
| HTTP always-ready 1 | Dedicated P0v3 Always On | 30.73 | 49.29 | 46.29 |

The zero-ready Flex probe was first in its instrumented process, but reported
740.7 seconds of process uptime. Therefore its 2.87-second client latency is
**not established as a fresh-process cold start**. The always-ready=1 probe was
not first in process. These observations demonstrate the instrumentation and a
readiness-associated difference in this trial, not a universal latency promise.

### Bounded CPU burst

Each arm received 24 concurrent client workers for 180 seconds, with 200 ms CPU
work per invocation and no deliberate memory allocation. Handler p50 was 200 ms
throughout. The client uses a closed-loop workload: throughput changes with
response time, so attempt counts differ.

| Flex configuration | Target | Successful measured requests | Client p50 ms | Client p95 ms | Observed host IDs |
|---|---|---:|---:|---:|---:|
| HTTP always-ready 0 | Flex FC1 | 3,436 | 1,025.64 | 3,264.49 | 5 |
| HTTP always-ready 0 | EP1 | 2,287 | 1,493.28 | 4,887.50 | 3 |
| HTTP always-ready 0 | Dedicated P0v3 | 893 | 4,837.65 | 4,869.61 | 1 |
| HTTP always-ready 1 | Flex FC1 | 3,627 | 898.20 | 3,053.15 | 6 |
| HTTP always-ready 1 | EP1 | 2,323 | 1,619.44 | 5,089.22 | 3 |
| HTTP always-ready 1 | Dedicated P0v3 | 893 | 4,840.26 | 4,886.67 | 1 |

In the first three-arm burst, all 6,619 custom events including warm-ups reached
Application Insights. Their server-side handler intervals overlap on three EP
instances for 144.74 seconds. EP platform CPU metrics independently show three
instances at 86%, 87% and 88% in the same 13:11 UTC minute. This corroborates real
concurrent scale-out despite the no-Azure-Files configuration. The second selected
burst also has all 6,846 correlated custom events.

**Prewarmed-pool attribution remains unproven.** Neither these metrics nor the
application IDs identify which invocation consumed the prewarmed buffer.
Flex's ceiling was 40, EP's was 3, and Dedicated remained at 1; do not interpret
the throughput table as equal-capacity or cost-efficiency benchmarking.

### Exact run IDs and retained artifacts

| Flex readiness | Protocol | Run ID |
|---|---|---|
| 0 | Warm | `startup-ea2685bd-d5a8-4b5b-aa4a-c9592f9d7fc8` |
| 0 | Burst | `startup-54ac5320-f49a-4ba0-b7d3-32a80c27fa30` |
| 0 | Idle | `startup-80e35416-0cdb-459b-a37c-745a0f038db8` |
| 1 | Warm | `startup-9344de8b-d72f-4e5b-88d3-de00aa5af79b` |
| 1 | Burst | `startup-391e650b-7074-4e21-bdf0-5f0f0d2bbb60` |
| 1 | Idle | `startup-352f37e3-f363-41e6-8ca2-f52cf8f3413d` |

The selected readiness=1 warm/burst runs were repeated after the full 15-minute
settling convention; earlier functional runs are retained but not substituted
for these figures. The selected idle run was collected after the earlier burst
and more than 15 minutes after the configuration change.

Full artifacts are at
`https://fnvsflex2667sa.blob.core.windows.net/startupresults/<run-id>/`:
`invocations.jsonl`, `manifest.json`, `summary.json`, `summary.md`, and
`receipt.json` containing checksums. Access requires VNet connectivity and Blob
data permissions; there is no public/SAS access. Each raw file was uploaded and
read back inside the VNet to verify its SHA256. Local compact receipts and
supporting telemetry are under `loadtest\startup-results\azure-private`.

The user chose to retain all resources. Flex was restored to HTTP always-ready=0.
EP remains minimum=1, prewarmed=1, maximum=3. The runner has no public NIC IP;
automatic shutdown is enabled at 22:00 UTC, with no automatic startup.
Retained EP, NAT, private endpoints and disk continue to incur charges even when
the VM stops. EP1's single baseline alone is approximately $0.21135/hour
($154/month at 730 hours); the earlier total incremental estimate was
$0.4-$0.9/hour during testing, excluding existing resources and variable usage.

Verified private endpoints (function-key authentication required):

- Flex: <https://fnvs-flex-2667.azurewebsites.net/api/stress>
- EP: <https://fnvs-ep-2667.azurewebsites.net/api/stress>
- Dedicated: <https://fnvs-prem-2667.azurewebsites.net/api/stress>
