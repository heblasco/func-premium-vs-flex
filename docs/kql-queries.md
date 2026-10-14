# KQL comparison queries (Application Insights)

Run these queries in **Application Insights > Logs**. Adjust `runId` and the
time window to match your run. Both apps share the same component and are
distinguished by `cloud_RoleName` (the app name) and the custom `plan` dimension
(`flex` / `premium`).

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

### Notes

- If you do not filter by `runId`, use a narrow time window such as `ago(30m)`
  to avoid mixing runs.
- Use **Azure Load Testing** as the **performance baseline**, with client
  metrics for the `flex-stress` and `premium-stress` samplers. Application
  Insights helps explain server-side behavior.
- Sampling is disabled in `host.json` and set to 100% on the component so
  counts are comparable across plans.
