# Consultas KQL para la comparativa (Application Insights)

Ejecuta estas consultas en **Application Insights → Logs**. Ajusta `runId` y la
ventana temporal a tu ejecución. Ambas apps comparten el mismo componente y se
distinguen por `cloud_RoleName` (nombre de la app) y la dimensión personalizada
`plan` (`flex` / `premium`).

> Sugerencia: define el `runId` con el valor que imprime `run-loadtest.ps1`.

---

## 1. Resumen de peticiones por plan

```kusto
let runId = "run-YYYYMMDD-HHMMSS";
requests
| where timestamp > ago(1h)
| where customDimensions["runId"] == runId or isempty(runId)
| extend plan = tostring(customDimensions["plan"])
| summarize
    total      = count(),
    errores    = countif(success == false),
    p50_ms     = percentile(duration, 50),
    p90_ms     = percentile(duration, 90),
    p99_ms     = percentile(duration, 99),
    max_ms     = max(duration)
  by plan
| extend error_pct = round(100.0 * errores / total, 2)
| order by plan asc
```

## 2. Latencia en el tiempo (series) por plan

```kusto
requests
| where timestamp > ago(1h)
| extend plan = tostring(customDimensions["plan"])
| summarize p90_ms = percentile(duration, 90) by plan, bin(timestamp, 30s)
| render timechart
```

## 3. Throughput (req/s) por plan

```kusto
requests
| where timestamp > ago(1h)
| extend plan = tostring(customDimensions["plan"])
| summarize rps = count() / 30.0 by plan, bin(timestamp, 30s)
| render timechart
```

## 4. Métrica personalizada de duración del trabajo (stress_duration_ms)

```kusto
customMetrics
| where timestamp > ago(1h)
| where name == "stress_duration_ms"
| extend plan = tostring(customDimensions["plan"])
| summarize avg_ms = avg(value), p90_ms = percentile(value, 90), muestras = count()
    by plan
| order by plan asc
```

## 5. Memoria (RSS) por plan

```kusto
customMetrics
| where timestamp > ago(1h)
| where name == "stress_rss_bytes"
| extend plan = tostring(customDimensions["plan"])
| summarize avg_rss_mb = round(avg(value) / 1048576, 1), max_rss_mb = round(max(value) / 1048576, 1)
    by plan
```

## 6. Número de instancias activas (escalado) por plan

```kusto
requests
| where timestamp > ago(1h)
| extend plan = tostring(customDimensions["plan"])
| summarize instancias = dcount(cloud_RoleInstance) by plan, bin(timestamp, 1m)
| render timechart
```

## 7. Arranque en frío: latencia de las primeras peticiones

```kusto
requests
| where timestamp > ago(1h)
| extend plan = tostring(customDimensions["plan"])
| order by timestamp asc
| summarize primera = minif(duration, true), p50_inicial = percentile(duration, 50)
    by plan, cloud_RoleInstance
| summarize cold_start_ms = max(primera), instancias = count() by plan
```

## 8. Errores y excepciones por plan

```kusto
union requests, exceptions
| where timestamp > ago(1h)
| extend plan = tostring(customDimensions["plan"])
| summarize
    fallos_request = countif(itemType == "request" and success == false),
    excepciones    = countif(itemType == "exception")
  by plan
```

## 9. Comparación directa lado a lado (una tabla)

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
    instancias_max = dcount(cloud_RoleInstance)
  by plan
| evaluate pivot(plan)
```

---

### Notas

- Si no filtras por `runId`, usa una ventana temporal ajustada (`ago(30m)`) para
  no mezclar ejecuciones.
- El **rendimiento de referencia** debe tomarse de **Azure Load Testing**
  (métricas de cliente por sampler `flex-stress` / `premium-stress`);
  Application Insights explica el comportamiento del lado servidor.
- El sampling está desactivado (host.json + componente al 100 %) para que los
  conteos entre planes sean comparables.
