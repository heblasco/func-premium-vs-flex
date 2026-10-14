# KQL comparison queries (Application Insights)

Run these queries in **Application Insights > Logs**. Adjust `runId` and the
time window to match your run. Both apps share the same component and are
distinguished by `cloud_RoleName` (the app name) and the custom `plan` dimension
(`flex` / legacy Dedicated `premium` / optional `elastic-premium`).

For the startup runner, use sections 10-12 on **custom events**. The application
sets `runId`, `phase` and `sampleId` on `stress_completed`; auto-collected
`requests` do not automatically inherit these fields. Earlier request queries
require request enrichment or adaptation to filter by role/time instead.

> Tip: set `runId` to the value printed by `run-loadtest.ps1`.

---

## 1. Request summary by plan

```kusto
let runId = "run-YYYYMMDD-HHMMSS";
requests
| where timestamp > ago(1h)
| where customDimensions["runId"] == runId or isempty(runId)
| extend plan = tostring(customDimensions["plan"])
| summarize
    total      = count(),
    errors     = countif(success == false),
    p50_ms     = percentile(duration, 50),
    p90_ms     = percentile(duration, 90),
    p99_ms     = percentile(duration, 99),
    max_ms     = max(duration)
  by plan
| extend error_pct = round(100.0 * errors / total, 2)
| order by plan asc
```

## 2. Latency over time by plan

```kusto
requests
| where timestamp > ago(1h)
| extend plan = tostring(customDimensions["plan"])
| summarize p90_ms = percentile(duration, 90) by plan, bin(timestamp, 30s)
| render timechart
```

## 3. Throughput (requests per second) by plan

```kusto
requests
| where timestamp > ago(1h)
| extend plan = tostring(customDimensions["plan"])
| summarize rps = count() / 30.0 by plan, bin(timestamp, 30s)
| render timechart
```

## 4. Custom workload duration metric (stress_duration_ms)

```kusto
customMetrics
| where timestamp > ago(1h)
| where name == "stress_duration_ms"
| extend plan = tostring(customDimensions["plan"])
| summarize avg_ms = avg(value), p90_ms = percentile(value, 90), samples = count()
    by plan
| order by plan asc
```

## 5. Memory usage (RSS) by plan

```kusto
customMetrics
| where timestamp > ago(1h)
| where name == "stress_rss_bytes"
| extend plan = tostring(customDimensions["plan"])
| summarize avg_rss_mb = round(avg(value) / 1048576, 1), max_rss_mb = round(max(value) / 1048576, 1)
    by plan
```

## 6. Active instance count (scaling) by plan

```kusto
requests
| where timestamp > ago(1h)
| extend plan = tostring(customDimensions["plan"])
| summarize instances = dcount(cloud_RoleInstance) by plan, bin(timestamp, 1m)
| render timechart
```

## 7. Cold-start exploration: per-instance latency

This query summarizes the minimum and median duration per instance in the
selected time window. It does not isolate the first request or prove that a
cold start occurred.

```kusto
requests
| where timestamp > ago(1h)
| extend plan = tostring(customDimensions["plan"])
| order by timestamp asc
| summarize minimum_duration = minif(duration, true), p50_duration = percentile(duration, 50)
    by plan, cloud_RoleInstance
| summarize max_minimum_duration_ms = max(minimum_duration), instances = count() by plan
```

## 8. Errors and exceptions by plan

```kusto
union requests, exceptions
| where timestamp > ago(1h)
| extend plan = tostring(customDimensions["plan"])
| summarize
    failed_requests = countif(itemType == "request" and success == false),
    exceptions      = countif(itemType == "exception")
  by plan
```

## 9. Side-by-side comparison in one table

```kusto
requests
| where timestamp > ago(1h)
| extend plan = tostring(customDimensions["plan"])
| summarize
    requests = count(),
    error_pct = round(100.0 * countif(success == false) / count(), 2),
    p50 = round(percentile(duration, 50), 1),
    p90 = round(percentile(duration, 90), 1),
    p99 = round(percentile(duration, 99), 1),
    distinct_instances = dcount(cloud_RoleInstance)
  by plan
| evaluate pivot(plan)
```

---

## 10. Startup invocation table (server evidence)

Copy the exact shared run ID from `manifest.json`. The client JSONL is the
authoritative record, including failures before the handler. Events can arrive
late or be lost; absence is not evidence of scale-to-zero.

```kusto
let selectedRun = "startup-<uuid>";
customEvents
| where timestamp > ago(24h)
| where name == "stress_completed"
| where tostring(customDimensions.runId) == selectedRun
| extend
    plan = tostring(customDimensions.plan),
    phase = tostring(customDimensions.phase),
    sampleId = tostring(customDimensions.sampleId),
    invocationId = tostring(customDimensions.invocationId),
    instanceId = tostring(customDimensions.instanceId),
    instanceIdSource = tostring(customDimensions.instanceIdSource),
    processBootId = tostring(customDimensions.processBootId),
    firstInProcess = tobool(customDimensions.firstInProcess),
    sequence = tolong(customMeasurements.invocationSequence),
    processUptimeMs = todouble(customMeasurements.processUptimeMs),
    handlerMs = todouble(customMeasurements.durationMs)
| project timestamp, plan, phase, sampleId, invocationId, handlerMs,
          instanceId, instanceIdSource, processBootId, firstInProcess,
          sequence, processUptimeMs
| order by timestamp asc
```

## 11. Startup handler summary by plan and cohort

These are **handler times**, not client latency or startup durations.
Probe tails are intentionally null; use the per-invocation table for idle cycles.
Use client artifacts for HTTP/network errors and end-to-end percentiles.

```kusto
let selectedRun = "startup-<uuid>";
customEvents
| where timestamp > ago(24h) and name == "stress_completed"
| where tostring(customDimensions.runId) == selectedRun
| extend plan = tostring(customDimensions.plan),
         phase = tostring(customDimensions.phase),
         firstInProcess = tobool(customDimensions.firstInProcess),
         handlerMs = todouble(customMeasurements.durationMs),
         boot = tostring(customDimensions.processBootId),
         instanceId = tostring(customDimensions.instanceId)
| where phase != "warmup"
| summarize events = count(),
            handler_min_ms = min(handlerMs),
            handler_p50_ms = percentile(handlerMs, 50),
            handler_p95_ms = percentile(handlerMs, 95),
            handler_max_ms = max(handlerMs),
            observed_processes = dcount(boot),
            observed_host_ids = dcount(instanceId)
    by plan, phase, firstInProcess
| extend handler_p95_ms = iff(phase == "probe", real(null), handler_p95_ms)
| order by plan asc, phase asc, firstInProcess desc
```

KQL percentiles/distinct counts can be approximate and differ from the local
nearest-rank/exact calculations. Do not sum overlapping local `all`/cohort rows.

## 12. Observed hosts over time during burst

```kusto
let selectedRun = "startup-<uuid>";
customEvents
| where timestamp > ago(24h) and name == "stress_completed"
| where tostring(customDimensions.runId) == selectedRun
| where tostring(customDimensions.phase) == "burst"
| extend plan = tostring(customDimensions.plan),
         instanceId = tostring(customDimensions.instanceId),
         idSource = tostring(customDimensions.instanceIdSource)
| summarize observed_host_ids = dcount(instanceId) by plan, idSource, bin(timestamp, 10s)
| render timechart
```

Multiple IDs in a time bin are a **hint**, not proof of concurrent active capacity
or prewarmed allocation; replacement can produce the same pattern. Corroborate
with overlapping activity and platform scaling evidence. If EP scale-out is
not established, label the buffer experiment inconclusive, not successful.

### Notes

- If you do not filter by `runId`, use a narrow time window such as `ago(30m)`
  to avoid mixing runs.
- Use **Azure Load Testing** as the **performance baseline**, with client
  metrics for the `flex-stress` and `premium-stress` samplers. Application
  Insights helps explain server-side behavior.
- Sampling is disabled in `host.json` and set to 100% on the component so
  counts are comparable across plans.
