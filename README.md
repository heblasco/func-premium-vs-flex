# func-premium-vs-flex

Comparativa reproducible de **coste y rendimiento** entre **Azure Functions Flex
Consumption** y un plan **reservado always-on (App Service Dedicated, P0v3)**
sometidos a la **misma carga en paralelo**, desplegable íntegramente con
**Terraform** y alineada con buenas prácticas del **Well-Architected Framework
(WAF)** de Azure.

> Es una **demo**: las SKU son las más pequeñas y económicas posibles, pero lo
> más comparables entre sí (Flex 2048 MB ≈ P0v3 ~1 vCPU / 4 GB).

> **Nota sobre Elastic Premium (EP):** el diseño original usaba **Elastic
> Premium (EP1)**. En suscripciones donde una **Azure Policy** deshabilita las
> claves compartidas de storage (`allowSharedKeyAccess=false`) y el acceso
> público (`publicNetworkAccess=Disabled`), EP **no es viable**: requiere un
> *content share* de Azure Files que sólo admite cadena de conexión por clave.
> Por eso el lado "reservado" corre sobre un **plan Dedicated** (keyless,
> always-on). La comparación es, por tanto, **Flex Consumption (serverless)**
> vs **plan reservado de capacidad fija**. Cambia `premium_sku_name` a `EP1` si
> tu suscripción permite claves compartidas.

## ¿Qué despliega?

- **2 Function Apps** con el **mismo código Node.js** (endpoint `/api/stress`
  que genera carga de **CPU** y **memoria**):
  - `*-flex-*` sobre plan **Flex Consumption (FC1)**.
  - `*-prem-*` sobre plan **App Service Dedicated (P0v3, always-on)**.
- **Red (WAF)**: 1 VNet con subredes dedicadas para integración de cada plan,
  private endpoints y Azure Load Testing; **private endpoints** para storage
  (blob/queue/table) y funciones (`sites`); **Private DNS**; storage **sin
  acceso público** (sólo VNet).
- **Identidad**: una **User-Assigned Managed Identity** por app, con acceso
  **100% keyless** a storage (Blob/Queue/Table Data roles). No se usan claves
  compartidas en ninguno de los dos planes.
- **Observabilidad**: Log Analytics + **Application Insights** compartido
  (se distingue cada plan por `cloud_RoleName` y la dimensión `plan`).
- **Carga**: recurso **Azure Load Testing** (JMeter con **dos thread groups
  independientes**; `run-loadtest.ps1` incrusta los valores como literales para
  que funcione en los engines con VNet injection), más un generador de **carga
  directa** en paralelo (`scripts/run-direct-load.ps1`) para resultados inmediatos.

Todos los recursos llevan un **UID hexadecimal aleatorio de 4 dígitos** para
evitar colisiones de nombres.

## Arquitectura

```
                         ┌───────────────────────────── VNet 10.60.0.0/22 ─────────────────────────────┐
                         │                                                                              │
  Azure Load Testing ───┼──► snet-loadtest (VNet injection) ──► PE funciones (privatelink.azurewebsites)│
   (engines JMeter)      │                                        │              │                      │
                         │   snet-flex-integ ◄── VNet integ ── Flex app          │                      │
                         │   snet-premium-integ ◄ VNet integ ─ Dedicated app     │                      │
                         │   snet-pe: PE blob/queue/table (storage) ◄────────────┘                      │
                         └──────────────────────────────────────────────────────────────────────────────┘
        Deployer IP ─(SCM, IP-restringido)─► Function Apps (público solo para publicar código)
   App Insights / Log Analytics ◄── trazas de ambas apps
```

## Prerrequisitos

- Terraform ≥ 1.9, Azure CLI, Node.js 20+, Azure Functions Core Tools v4, `gh`.
- Sesión iniciada: `az login` y una suscripción con cuota para Flex + Dedicated.
- Providers registrados: `Microsoft.LoadTestService` y `Microsoft.Batch`
  (este último para la inyección en VNet de Azure Load Testing). Se registran
  con `az provider register --namespace <ns>`.
- Región que soporte **Flex Consumption**, **App Service** y **Azure Load
  Testing**. `westeurope` puede rechazar recursos nuevos ("not accepting new
  customers"); `swedencentral` es una buena alternativa.

## Inicio rápido

```powershell
# 1) Infraestructura
cd infra
cp terraform.tfvars.example terraform.tfvars   # edita subscription_id / location
terraform init
terraform apply

# 2) Publicar el código en ambas apps
..\scripts\deploy.ps1

# 3a) Carga directa en paralelo (resultados inmediatos; requiere IP/CIDR permitido)
..\scripts\run-direct-load.ps1 -Workers 12 -Duration 120 -CpuMs 300 -MemMB 128 -Loops 2

# 3b) O carga vía Azure Load Testing (inyección en VNet, private endpoints)
..\scripts\run-loadtest.ps1 -Users 20 -Duration 300 -CpuMs 200 -MemMB 256
```

> Si tu IP pública de salida **rota** dentro de un rango corporativo, fija
> `deployer_allow_cidr` (p. ej. `167.220.0.0/16`) en `terraform.tfvars` para que
> la restricción por IP del endpoint público no te bloquee entre despliegues.

La guía detallada paso a paso está en **[docs/STEP-BY-STEP.md](docs/STEP-BY-STEP.md)**
y las consultas de monitorización en **[docs/kql-queries.md](docs/kql-queries.md)**.

## Variables principales (con valores por defecto)

| Variable | Defecto | Descripción |
|----------|---------|-------------|
| `subscription_id` | — (obligatoria) | Suscripción destino |
| `location` | `westeurope` | Región |
| `name_prefix` | `fnvs` | Prefijo de nombres (+ sufijo hex aleatorio) |
| `flex_instance_memory_mb` | `2048` | Memoria por instancia Flex (512/2048/4096) |
| `flex_maximum_instance_count` | `40` | Escalado máximo Flex |
| `flex_always_ready_count` | `0` | Instancias always-ready Flex (0 = escala a cero) |
| `premium_sku_name` | `P0v3` | SKU plan Dedicated (P0v3/P1v3/P2v3/B1/B2/B3) |
| `premium_worker_count` | `1` | Nº de instancias del plan Dedicated |
| `enable_function_private_endpoints` | `true` | PE en las funciones |
| `deployer_ipv4` | auto | IP pública permitida en SCM/sitio (auto-descubierta) |
| `deployer_allow_cidr` | `null` | CIDR permitido en vez de la /32 (IP rotatoria) |

Lista completa en `infra/variables.tf`.

## Notas de alineación con WAF

- **Seguridad**: storage **sin acceso público** (sólo private endpoints
  blob/queue/table desde la VNet), **claves compartidas deshabilitadas**
  (acceso keyless vía managed identity y RBAC de datos), private endpoints en
  las funciones (`sites`), TLS 1.2 mínimo, HTTPS obligatorio.
- **Keyless en ambos planes**: tanto Flex como el plan Dedicated usan
  `AzureWebJobsStorage` por **identidad** (`__accountName` + `managedidentity` +
  `__clientId`). El contenedor de despliegue de Flex se crea por **plano de
  control** (`azapi`) porque el plano de datos es privado.
- **Desviación documentada (Dedicated vs Elastic Premium)**: EP requiere un
  *content share* de Azure Files con clave compartida, incompatible con la
  policy de la suscripción. Se usa un **plan Dedicated** (always-on, run
  from-local, `WEBSITES_ENABLE_APP_SERVICE_STORAGE=false`). Diferencia inherente
  a tener en cuenta: Flex escala a cero y elásticamente; el Dedicated mantiene
  **capacidad fija** (`premium_worker_count`).
- **Despliegue de código**: el endpoint público de las funciones queda
  **restringido por IP** al deployer (o a `deployer_allow_cidr`); el tráfico de
  Azure Load Testing llega por **private endpoint**. Para producción, deshabilita
  el acceso público (ver STEP-BY-STEP).

## Metodología de comparación

El coste de Azure Cost Management tiene **retraso** (horas/día siguiente). Para
una comparación honesta se combinan:

1. **Rendimiento** (fuente primaria): métricas de **Azure Load Testing** o del
   generador de **carga directa**, más las **métricas servidor** de Application
   Insights (`stress_completed` con `durationMs` y `rssMB`) por dimensión `plan`.
2. **Coste**: modelo según medidores documentados + duración/escalado observados,
   y validación posterior con Cost Management (etiqueta `project`).

### Resultado de ejemplo (demo real)

Carga directa, 12 workers/app, 120 s, `cpuMs=300 memMB=128 loops=2`:

| Plan | Peticiones | Avg (cliente) | Avg server (AI) | Instancias | Throughput |
|------|-----------:|--------------:|----------------:|-----------:|-----------:|
| Flex Consumption | 625 | 2359 ms | 667 ms | **6** (scale-out) | 5,2 req/s |
| Dedicated P0v3 (1 worker) | 165 | 8779 ms | 734 ms | **1** (fija) | 1,4 req/s |

Lectura: el **tiempo de cómputo por invocación** es muy parecido (SKU
comparables), pero **Flex escala out** bajo ráfaga mientras el Dedicated de 1
instancia se **satura** y encola las peticiones. Sube `premium_worker_count`
para comparar el scale-out a capacidad reservada.

## Estructura

```
infra/      Terraform (red, storage, identidad, funciones, monitorización, load test)
src/        Función Node.js compartida (stress + health)
loadtest/   Plan JMeter + plantilla de configuración de Azure Load Testing
scripts/    build.ps1, deploy.ps1, run-loadtest.ps1, run-direct-load.ps1
docs/       Guía paso a paso + consultas KQL
```

## Limpieza

```powershell
cd infra
terraform destroy
```
