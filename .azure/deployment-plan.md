# Startup comparison implementation plan

Status: Deployed and verified; resources retained

Authorization: the user now requests deploying the resources needed for actual
Azure verification, following Azure WAF and a Rubber Duck-reviewed plan before
execution. Earlier local-only restrictions describe historical decisions below.
Finalize the resource, access, cost and cleanup plan before provisioning.

Approval recorded: deploy the reviewed plan in the confirmed subscription and
Sweden Central. The user selected **keep all resources** after verification,
accepting ongoing costs. Do not delete the runner or EP at completion.

## Current deployment planning

Proposed execution plan, reviewed with Rubber Duck:

1. Preserve the existing Flex/Dedicated apps, private endpoints, monitoring and
   corporate ingress rules. Do not add workstation access or enable storage
   public access. Avoid unrelated Terraform changes and stop on replacements of
   existing resources.
2. Add an opt-in private Ubuntu 24.04 Gen2 verification VM, Standard_D2s_v5,
   managed identity, Trusted Launch, no public NIC IP, no inbound SSH/RDP, managed
   boot diagnostics and automatic shutdown. Use a dedicated `10.60.1.64/26`
   subnet and NSG. Manage it through Azure Run Command.
3. Provide explicit outbound access for package/tool installation using a NAT
   gateway and Standard public IP attached only to the runner subnet. This IP is
   outbound-only, not an inbound endpoint. Permit HTTPS package feeds/ARM and
   required private HTTPS/DNS; preserve the Azure VM agent path.
4. Bootstrap EP identity, private storage/endpoints and integration subnet.
   Deliver only source, lockfile and verification scripts to the runner through
   ARM (checksummed bundle); never transfer Terraform state or operator tokens.
   Install dependencies on Linux and create an immutable ZIP.
5. Runner identity uses container-scoped Blob data access and app-scoped
   deployment/read/key permissions, not subscription Contributor. Use explicit
   resource metadata rather than requiring Terraform state/Core Tools on the VM.
   Deploy the same revision to Flex/Dedicated through private SCM, then upload
   EP's immutable package and provision EP1 with minimum=1, buffer=1, maximum=3.
6. Verify private DNS, Run Command round-trip, authenticated deployment, HTTP
   response schema, package/version consistency and App Insights ingestion.
   Complete Flex/Dedicated smoke before advancing to the riskier EP stage.
7. Run warm baseline, bounded burst and an idle probe, recording every invocation.
   Compare Flex HTTP always-ready 0 versus 1 in separate runs with settling time.
   Revert Flex to its original readiness setting after collection. No observed
   concurrent EP scale-out means an inconclusive buffer experiment, not a pass.
8. Save complete JSONL/manifest/summary files in a private results container in
   the existing Flex storage account. Return compact summaries and artifact
   hashes through Run Command. Do not truncate or discard raw per-request data.
9. Retain all resources as approved. The runner automatically shuts down at
   22:00 UTC; its disk, NAT and EP still incur costs. Keep durable private results.

## Section 7: Azure verification validation proof

- Terraform initialized successfully; existing local backend contains 54
  resources. No state or operator credentials are transferred to the VM.
- `terraform validate`: passed. `terraform test`: 5 mocked scenarios passed,
  including private NIC, non-overlapping subnet and Trusted Launch checks.
- `npm --prefix src test`: 9 passed. Both PowerShell contract suites passed.
  Three Python artifact-integrity/private-DNS tests passed; controller syntax passed.
- Reviewed saved bootstrap plan: 29 Azure resources plus two Terraform helper
  resources are added; the existing Flex/Dedicated apps update in place.
  No existing infrastructure is deleted or replaced.
- Plan uses `-refresh=false` because existing storage data planes are private.
  ARM subnet inventory confirms the new ranges are free. Subscription identity,
  app runtime, corporate restrictions, regional availability and quotas were
  checked separately. This does not claim a full drift refresh.
- Azure reports Node 20 end-of-life on 2026-04-30. The approved verification
  upgrades both existing arms and the new EP arm to supported Node 22.
- Static RBAC: runner has container-scoped Blob Data Contributor on package and
  results containers; custom publication/read/key/sync actions are assigned only
  to individual apps. App storage identities retain their own data-plane roles.
- Policy assignment discovery at subscription scope returns three Defender
  protection assignments. Private/keyless storage, HTTPS, tags, Trusted Launch
  and no public VM ingress are maintained. ARM enforcement remains a live gate;
  absence of other returned assignments is not proof of no inherited policies.
- Remaining deployment gates: VM agent/IMDS/NAT/private DNS, actual SCM OAuth
  publication, EP allocation/private package startup and live telemetry.

### Bootstrap execution, 2026-10-14

Initial apply created 27 of 31 planned additions and upgraded both existing
apps to Node 22; both remain Running. Standard public-IP creation was rejected
with `SubscriptionNotRegisteredForFeature / AllowBringYourOwnPublicIpAddress`.
An equivalent minimal ARM request confirmed this was not a Terraform payload
issue. Feature registration completed immediately; Microsoft.Network was
re-registered to propagate it. No public storage or VM ingress exception was used.

The resumed plan exposed provider normalization of Flex's Application Insights
setting and the automatically generated hidden-link tag. Configuration now uses
the provider's site-config field and ignores only that service-generated tag,
preventing repeated unrelated app updates. The keyless host-storage repair also
tracks application settings so it reruns after relevant configuration changes.

The subscription also stamps `ip_tags.FirstPartyUsage` onto public IPs. Preserve
that platform-managed value to prevent a replacement on every subsequent plan.
The VM is Running at private IP `10.60.1.68`, without a public NIC address;
Trusted Launch and all four scoped runner role assignments were verified live.

Private SCM OAuth publication succeeded for Flex and Dedicated. Initial smoke
found a real ZIP-permission defect: the executor's umask produced root-readable
files, causing Flex HTTP 503 and `host.json` access-denied exceptions. Normalized
ZIP files to 0644 and directories/executables to 0755; added a regression test.
Republished the same corrected ZIP to both arms. Run
`startup-25e2b206-6680-4a8d-afec-1196fdf6f979` completed all 22 HTTP invocations,
with complete private artifacts verified byte-for-byte. Application Insights
contains all 11 correlated `stress_completed` events from each arm.

Corrected immutable package SHA256:
`6b36037adaf50ec5bad5dcad9e015276ec7197a3d2de6bbdd8b93a7bec5feafc`.

EP startup and all three arms are now functional. Its new app-scoped role took
approximately 20 minutes to become consistently effective across ARM child
operations; no permissions were widened. The three-arm burst
`startup-54ac5320-f49a-4ba0-b7d3-32a80c27fa30` completed 6,616 measured requests
without errors. All 6,619 custom events (including warm-ups) were ingested.
Server-side handler intervals overlap on three EP instances, corroborated by
simultaneous EP per-instance CPU averages of 86%, 87% and 88% at 13:11 UTC.
This verifies concurrent scale-out, not which request used the prewarmed buffer.

AzureRM 4.81's Linux Function read implementation does not retain
`content_share_force_disabled` and normalizes empty restriction headers differently.
Keep the desired flag **true**; ignoring it would risk Azure Files injection on
future updates. This is a known remaining in-place plan/readback discrepancy,
not a live Azure Files dependency. Readiness experiments target only Flex and its
keyless repair helper to avoid incidental EP updates. EP basic-auth switches are
explicitly false, matching the live policy-enforced values, and its account-name
setting is owned by the provider's managed-identity storage configuration.

### Final verification and retained state, 2026-10-14

- Completed the selected six-run matrix: 14,137/14,137 HTTP invocations, including
  12 excluded warm-ups; zero errors. Full tables, exact IDs, caveats and private
  Blob locations are in `docs/STARTUP-COMPARISON.md`.
- Repeated readiness=1 warm/burst after the full 15-minute settling convention.
  Earlier successful functional runs remain separate.
- Verified all 6,619 and 6,846 events from the selected bursts in Application
  Insights. Runner-side raw artifacts were uploaded and read back with SHA256
  comparison. Observed client event-loop maximum was 59.93 ms.
- Restored Flex HTTP always-ready to 0 through a reviewed targeted plan.
  The helper replacement is Terraform bookkeeping, not deletion of Azure
  infrastructure. Final nine-request smoke passed on all three apps.
- EP's package hash matches the verified ZIP; live settings contain neither
  WEBSITE_CONTENTSHARE nor WEBSITE_CONTENTAZUREFILECONNECTIONSTRING.
  All three storage accounts remain shared-key-disabled and public-network-disabled.
- Retained VM/NAT/EP/network/identities and complete private results as approved.
  VM shutdown schedule is Enabled at 22:00 UTC. Ongoing cost is explicitly
  documented; VM deallocation does not eliminate EP/NAT/disk charges.
- Remaining limits: a single idle probe per configuration, no guaranteed cold
  start or individual prewarmed-pool attribution, unequal scale ceilings, and
  the documented AzureRM EP readback-only plan discrepancy.
- Final local checks: 9 Node tests, 5 Python checks, 5 Terraform mocked scenarios,
  both PowerShell contract suites, Terraform validation/formatting and diff
  whitespace checks passed. Azure verification itself performed no commit or push.

### Documentation consolidation

`docs/DEPLOYMENT-RUNBOOK.md` is the canonical operational entry point for fresh
deployment, two-phase EP publication, repeat demos, state recovery, artifact
backup and destruction. README and both existing guides link to it. The source,
infrastructure, tests and documentation are included in the same consolidation
commit; generated plans, local state/tfvars, results and private keys are excluded.

### WAF scope and tradeoffs

- Security: managed identities, scoped roles, keyless/private storage, private
  application traffic, no public management ports or secret-bearing artifacts.
- Reliability: staged deployment, integrity checks, explicit readiness gates,
  failure artifacts and no automatic destructive replacement of existing apps.
- Operational excellence: Terraform additions, reviewed plans, immutable packages,
  deployment evidence, Application Insights and explicit cleanup.
- Performance efficiency: same revision/workload, observed actual SKU/readiness,
  client and handler timing separated, bounded concurrency and EP scaling.
- Cost optimization: temporary small executor, capped EP active instances,
  initial functional smoke before longer tests, cleanup approval and raw results
  kept on existing storage.

This is a demo/test environment, not a claim of full production WAF compliance:
the disposable runner is single-instance and has no backup/HA; HTTPS egress to
package feeds is not an enterprise firewall allowlist. Existing app integrations
retain their platform egress until live telemetry proves whether changes are
needed. VM default outbound rules must not be confused with App Service egress.

### Read-only capacity and cost evidence (2026-10-14)

| Resource | Existing / quota | Planned addition | Evidence |
|---|---|---|---|
| Regional VM cores | 0 / 100 | 2 | Native Compute usage API |
| DSv5 cores | 0 / 100 | 2 | Native Compute usage API |
| VMs | 0 / 25000 | 1 | Native Compute usage API |
| Standard IPv4 public IPs | 0 / 1000 | 1, outbound-only | Network usage API |
| NAT gateways | 0 / 500 | 1 | Network usage API |
| NSGs | 4 / 5000 | 2 | Network usage API |
| NICs | 8 / 65536 | 5 including EP private endpoints | Network usage API |
| Storage accounts | 2 / 250 | 1 | Storage usage API |
| EP Linux regional support | Sweden Central supported | EP1, active max 3 | ARM geoRegions, ELASTICLINUX/ELASTICPREMIUM, constraint level 0 |

Standard_D2s_v5 has no SKU restrictions in this region. Ubuntu 24.04 x64 Gen2
image is available. Microsoft.Quota is not registered: `az quota` was tried
first, then native provider usage APIs supplied the figures. EP-specific numeric
headroom is not exposed by the returned Web usage data; negative limits are not
interpreted as unlimited. Final service validation/allocation remains a deployment
gate, and no quota increase will be silently requested.

Public retail pricing (USD, not the customer's bill): D2s_v5 is $0.102/hour;
EP is $0.169/vCPU-hour plus $0.0121/GiB-hour, approximately $0.21135/hour per
EP1 instance. Prewarmed capacity is billed when allocated under traffic, not
assumed continuously allocated during idle. Including approximate networking/
disk overhead, budget roughly $0.4-$0.9/hour incremental while testing, plus
traffic/telemetry and existing resources. This is an estimate, not a hard cap.
Keeping one idle EP1 indefinitely is about $154/month compute at 730 hours,
plus storage/private endpoints; traffic can allocate additional billed instances.

### Rubber Duck disposition

Accepted: do not put Terraform state on the VM; remove script dependencies on
local-only discovery; validate VM agent/private SCM and actual telemetry before
load; stage existing apps before EP; retain complete artifacts before cleanup;
disable unnecessary public-IP autodiscovery during reviewed provisioning.

Not adopted: removing the telemetry SDK would change the workload and break
the custom-event contract, so keep the same package across arms. Disk size is
not equivalent to module-load time. Do not assume Premium's prewarmed buffer is
allocated and billed at idle. No storage firewall exception is proposed.

## Scope

Extend the existing Node.js Azure Functions demo with a reproducible startup
comparison, invocation-level results, and aggregate metrics.
The current infrastructure compares Flex Consumption with Dedicated P0v3,
not Elastic Premium. The user selected expanding the plan to genuine Elastic
Premium before implementation. No Azure deployment or configuration changes
are authorized by this plan yet.

## Repository analysis and recipe

- MODIFY an existing development/demo application; retain Terraform.
- Shared Node.js 20+ HTTP functions (`stress`, `health`) with Application Insights.
- Flex FC1 supports an existing configurable HTTP always-ready count.
- The other app uses Dedicated P0v3 with Always On, not Elastic Premium.
- Existing direct-load and JMeter scenarios remain unchanged.
- Documentation remains in English.

## Proposed implementation

1. [Implemented] Add shared process lifecycle signals to health and stress: boot identifier,
   invocation sequence, first invocation in this process, process uptime, and
   platform instance identifier when available (otherwise a labeled hostname).
   These are not proof of a platform cold start.
2. [Implemented] Add a startup comparison runner with explicit warm-baseline, idle-probe,
   and burst scenarios. Do not issue HTTP preflight requests in idle mode,
   retry failed measurements, restart apps, or change Azure configuration.
3. [Implemented] Use read-only Azure discovery to record actual SKU/readiness configuration.
   Retrieve keys before the idle interval; pass keys only in request headers
   and transient child-process environment. Never persist secrets.
4. [Implemented] Persist invocation JSONL, a run manifest and Markdown/JSON summaries.
   Include failures, correlation IDs, client response latency, connection
   timing, handler duration, client-minus-handler delta, and lifecycle evidence.
   The delta includes network, queueing, host and serialization overhead:
   do not name or interpret it as platform startup duration.
5. [Implemented] Report idle probes individually with sample count and min/median/max.
   Report warm/burst p50/p95/p99 with sample counts and small-sample warnings.
   Keep first-in-process and subsequent-in-process cohorts distinct.
6. [Implemented] Test lifecycle semantics, HTTP measurement/error handling, aggregation,
   and artifact secret exclusion using Node's built-in test runner.
7. [Implemented] Update README, the step-by-step guide and custom-event KQL with run/phase/
   invocation correlation and an explicit limitations section.

## Experimental protocol

- Proposed idle experiment: five cycles with 30 minutes of idle per cycle,
  configurable and recorded. No interval guarantees scale-to-zero.
- First response per cycle is the probe; subsequent serial requests are a
  separate follow-up cohort. Warm-up responses are excluded from measurements.
- Flex ready=0 and ready=1 require separate operator-approved configuration
  runs; Dedicated Always On is the existing reference, not an EP substitute.
- Record workload, readiness settings, concurrency, timing and client runtime.
- Record/flag recent configuration changes where available; document a settling
  period and absence of other app traffic as experiment prerequisites.
- Local invocation logs are authoritative; Application Insights is secondary
  and may be delayed or incomplete.
- No automatic cold-start classification from latency or process identity.
- No throughput/cost-normalization conclusions or guaranteed scale-out claims.

## Rubber Duck review

Reviewed before implementation. Main accepted findings:

- Resolve Dedicated versus actual Elastic Premium scope with the user.
- An idle probe cannot exercise Premium's prewarmed HTTP scale-out buffer.
- Separate process-first evidence from platform cold-start attribution.
- Expose connection timings and client-minus-handler delta without attributing
  that delta entirely to the platform.
- Include per-cycle results, sample counts, failures, and configuration metadata.
- Ignore generated results in Git; preserve existing test paths.

Review suggestions not adopted as factual claims: a new process plus a new
instance and a latency threshold still do not prove cold start; no fixed idle
duration guarantees scale-to-zero. Terraform state and tfvars are not tracked
according to `git ls-files`.

## Expanded scope: actual Elastic Premium

User approved this architecture for local implementation only. The private
executor is pending; live deployment remains blocked.

- Add an opt-in third EP1 app, preserving the existing Flex and Dedicated apps.
  Use `elastic-premium` as its telemetry label; never reuse legacy `premium`.
- Subject name: **EP1 without Azure Files (keyless/private)**. Current Microsoft
  documentation permits this deployment pattern but warns that scaling can be
  limited. It is not a claim about every EP deployment.
- Own user-assigned identity, keyless/private host storage, Blob deployment
  container, blob/queue/table private endpoints, and a sites private endpoint.
  Reuse existing monitoring and private DNS zones.
- Separate non-overlapping VNet integration subnet delegated to
  `Microsoft.Web/serverFarms`; calculate against the existing network layout.
- Proposed settings: one always-ready instance, one prewarmed buffer instance,
  maximum three active instances, subject to explicit cost and quota approval.
  Premium has a billed active baseline; buffered instances are also billable
  when allocated under traffic. A buffer of one does not mean two instances
  are continuously allocated while idle.
- No Azure Files share, no storage shared keys, no SAS package URL, no policy
  exception, no public storage access.
- Set `WEBSITE_RUN_FROM_PACKAGE` to an immutable private blob URL, and
  `WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID` to the app identity.
  Use identity-based `AzureWebJobsStorage` and private routing/DNS.
- Investigate the pinned Terraform provider's EP behavior before choosing the
  site resource. If it injects Azure Files settings, use explicit AzAPI site
  configuration rather than disabling policies or inventing a storage key.
  Verified AzureRM 4.81.0 supports `content_share_force_disabled = true` and
  explicitly suppresses content settings on Elastic Premium when enabled.
  Reuse the existing AzureRM Linux Function App pattern with this option.

### Package deployment and feasibility gates

1. Provision package storage/container/identity/RBAC/private endpoints first.
2. Upload the immutable package from an explicitly identified, authorized
   VNet-connected executor with private DNS and Blob data-plane write access.
   Do not provision an executor or open the storage firewall implicitly.
3. Create/configure the EP site with the immutable URL after the package exists.
   Terraform owns that URL through an input; deployment scripts must not
   create drift by overwriting a Terraform-managed setting.
4. Sync triggers using the ARM control plane, then verify package startup and
   response schema before starting any settling/idle interval.
5. Run a bounded scale-out feasibility check separately from measurements.
   Observe multiple concurrently active instance identifiers, not just a
   cumulative count that could represent worker replacement. Record
   scale-controller evidence where available.
6. If scale-out is not observed, mark the buffer experiment inconclusive.
   Do not claim a prewarmed instance served a particular request based only
   on a hostname, first-in-process flag, or low latency.

### Revised experiment matrix

| Configuration | Idle/first-hit experiment | Burst experiment |
|---|---|---|
| Flex HTTP always-ready=0 | Candidate scale-to-zero behavior | On-demand scale-out |
| Flex HTTP always-ready=1 | Ready baseline | Ready plus on-demand capacity |
| EP1 keyless, minimum=1, buffer=1 | Premium ready baseline | Prewarmed-buffer configuration under scale-out |
| Existing Dedicated P0v3 | Optional Always On reference | Fixed-capacity reference |

The idle experiment does not exercise the Premium prewarmed scale-out buffer.
The burst comparison measures behavior under configured readiness policies,
not causal attribution of each invocation to a prewarmed/always-ready pool.
Use the same code and workload; record SKU/memory/concurrency differences.

### Additional Rubber Duck review

The focused EP feasibility review confirms the documented no-Azure-Files path
and requires explicit package bootstrap, deployment ownership, private executor,
and scale-out gates. Do not treat the provider concern as a verified failure
without inspecting its behavior. Do not interpret two lifetime instance IDs
alone as simultaneous scale-out or charge a permanently allocated idle buffer
contrary to the Premium allocation model.

### Sources

- https://learn.microsoft.com/en-us/azure/azure-functions/storage-considerations#create-an-app-without-azure-files
- https://learn.microsoft.com/en-us/azure/azure-functions/deployment-zip-push
- https://learn.microsoft.com/en-us/azure/azure-functions/functions-premium-plan
- https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan

## Approval and Azure context

Detected read-only: region `swedencentral`, resource group `rg-fnvs-2667`.
The user confirmed the detected subscription and region for the proposed
configuration. Local implementation is approved; pending live-deployment gates:

- Third-app architecture and keyless EP scaling caveat approved for local code.
- Live feasibility/provisioning remains separately gated, not authorized.
- Private deployment executor and its network/identity permissions.
- Bounded EP capacity and associated ongoing cost before provisioning.

## Resource inventory and provisioning limits

No resources are provisioned during local preparation. Proposed opt-in resource
additions: one EP service plan, one function app, one storage account, one Blob
container, one user-assigned identity, one integration subnet, four private
endpoints with DNS zone groups, and scoped RBAC assignments.
Live quota/capacity validation is pending provisioning approval. The Azure context
is confirmed. This is an approved local implementation, not a deployment-ready
or live-validated environment.

## Acceptance criteria

- Existing stress response fields and existing load scripts remain compatible.
- Health requests consume the same process sequence as stress requests.
- Every attempted request, including HTTP failures/timeouts/invalid responses,
  has a persisted record and appears in summary counts.
- Measurements separate client time from handler time and do not fabricate
  startup attribution or missing server values.
- Actual Dedicated configuration is never reported as Elastic Premium.
- Optional EP resources leave existing deployments unchanged when disabled.
- EP runtime/package authentication remains keyless and storage remains private.
- Package retrieval/startup and actual concurrent scale-out are independent
  gates before presenting a successful prewarmed-buffer experiment.
- No keys or raw secret-bearing errors are written into generated artifacts.
- Deterministic local tests pass; real Azure measurements are not fabricated.

## Validation checklist (azure-validate, local-only scope)

- [x] Terraform installed and existing provider initialization available.
- [x] Azure CLI/read-only subscription context detected during planning.
- [x] Format check of new Terraform resource, variables and test definitions.
- [x] Terraform schema/type validation.
- [x] Mocked plan previews: disabled, bootstrap, EP-ready, invalid package hash.
- [x] JavaScript regression tests and PowerShell wrapper/package contract tests.
- [x] Static RBAC verification.
- [ ] Live plan/refresh, policy and quota/capacity checks: deferred, no live
  deployment authorized. Existing private storage may require a private executor.
- [ ] Package upload/startup, trigger sync and concurrent EP scale-out: pending
  private executor, deployment approval and live verification.
- AZD template-variable validation: not applicable (existing plain Terraform).

## Role assignment verification

EP app identity has Blob Data Owner, Queue Data Contributor and Table Data
Contributor scoped to its own host storage, matching the existing repository
host-storage pattern. Blob access includes reading its deployment package.
The optional publisher has only Blob Data Contributor on the package container.
No subscription-wide/RG-wide data roles or keys are introduced. Actual assigned
roles and private connectivity remain live-deployment checks.

## 7. Validation proof

Validation date: 2026-10-14. Executed in the local-only azure-validate phase.

| Check | Command run | Result |
|---|---|---|
| Node behavior and artifact regression | `npm --prefix src test` | 9 passed |
| ARM discovery and refusal gates | `pwsh -NoProfile -File .\scripts\tests\startup-wrapper.tests.ps1` | Passed (mocked commands) |
| EP package/upload contract | `pwsh -NoProfile -File .\scripts\tests\ep-package.tests.ps1` | Passed (mocked upload) |
| Terraform formatting | `terraform -chdir=infra fmt -check functions_elastic_premium.tf variables.tf tests\elastic_premium.tftest.hcl` | Passed |
| Terraform schema | `terraform -chdir=infra validate` | Passed |
| Optional EP scenarios | `terraform -chdir=infra test` | 4 passed, mocked providers |
| Diff whitespace | `git --no-pager diff --check` | Passed |

No Azure resources were provisioned, restarted, or reconfigured. No cloud
benchmark results are claimed. Deployment validation is intentionally incomplete;
do not mark this plan globally `Validated` or invoke deployment without approval.

## Follow-up execution: 2026-10-14

The user requested an actual verification run. Automated checks passed again:
9 Node tests, both PowerShell contract suites, Terraform validation and 4 mocked
Terraform scenarios.

### Actual local Functions HTTP runtime

Azure Functions Core Tools 4.9.0 / Node 22 ran the unchanged application on
localhost. All three runner scenarios executed against the real Functions host,
not an HTTP mock. The host was stopped after verification.

| Scenario | Total invocations | Successful | Measured invocations |
|---|---:|---:|---:|
| Idle protocol, zero idle (functional check only) | 4 | 4 | 4 |
| Warm baseline | 11 | 11 | 10 |
| Two-worker, two-second burst, cpuMs=10 | 95 | 95 | 94 |

Verified first-in-process transitions, HTTP 200 response schema, exclusion of
warm-up from measured summaries, all four artifact files, credential exclusion,
and comparison rendering. These are **local functional results**, not evidence
of Azure cold starts, always-ready allocation or EP scaling.

Persisted results under `loadtest\startup-results\local-e2e`:

- `startup-7256ac32-e8f9-4186-bd74-da62ba609b77` (idle protocol)
- `startup-50094c1c-2ed5-4174-bed1-52f2bca529e4` (warm baseline)
- `startup-c92a8720-db16-4360-952a-0687dad34660` (burst)

Initial local startup with an empty storage connection failed. The HTTP run
succeeded with `UseDevelopmentStorage=true` and file-based local secrets;
without Azurite, the runtime still reported an unhealthy storage check.
Local storage health was not validated and no cloud storage was used.

### Existing Azure apps: blocked by access rules

Read-only ARM checks confirmed both existing apps are running. The low-load
cloud smoke attempted one warm-up per app; both returned HTTP 403, so the runner
correctly aborted before measured load. Failure artifacts are preserved under
`loadtest\startup-results\azure-smoke`.

The existing allowed corporate CIDR does not contain this machine's current
outbound IP. The user declined the proposed temporary /32 allowance and code
publication. No access rules, code deployments, app settings, capacity or Azure
resources were changed. EP remains undeployed. Live functional validation and
cloud performance measurements remain blocked; do not interpret the local
passes as a successful Azure comparison.
