# func-premium-vs-flex

Comparativa reproducible de **coste y rendimiento** entre **Azure Functions Flex
Consumption** y **Elastic Premium (EP1)** sometidas a la **misma carga en
paralelo**, desplegable íntegramente con **Terraform** y alineada con buenas
prácticas del **Well-Architected Framework (WAF)** de Azure.

> Es una **demo**: las SKU son las más pequeñas y económicas posibles, pero lo
> más comparables entre sí (Flex 2048 MB ≈ EP1 ~1 vCPU / 3,5 GB).

## ¿Qué despliega?

- **2 Function Apps** con el **mismo código Node.js** (endpoint `/api/stress`
  que genera carga de **CPU** y **memoria**):
  - `*-flex-*` sobre plan **Flex Consumption (FC1)**.
  - `*-prem-*` sobre plan **Elastic Premium (EP1)**.
- **Red (WAF)**: 1 VNet con subredes dedicadas para integración de cada plan,
  private endpoints y Azure Load Testing; **private endpoints** para storage y
  funciones; **Private DNS**; firewall de storage con *default deny*.
- **Identidad**: una **User-Assigned Managed Identity** por app (acceso keyless
  a storage en Flex; en Premium el *content share* usa clave por limitación de
  plataforma — ver más abajo).
- **Observabilidad**: Log Analytics + **Application Insights** compartido
  (se distingue cada plan por `cloud_RoleName` y la dimensión `plan`).
- **Carga**: recurso **Azure Load Testing** + plan JMeter con **dos thread
  groups independientes** que atacan ambas apps en paralelo.

Todos los recursos llevan un **UID hexadecimal aleatorio de 4 dígitos** para
evitar colisiones de nombres.

## Arquitectura

```
                         ┌───────────────────────────── VNet 10.60.0.0/22 ─────────────────────────────┐
                         │                                                                              │
  Azure Load Testing ───┼──► snet-loadtest (VNet injection) ──► PE funciones (privatelink.azurewebsites)│
   (engines JMeter)      │                                        │              │                      │
                         │   snet-flex-integ ◄── VNet integ ── Flex app          │                      │
                         │   snet-premium-integ ◄ VNet integ ─ Premium app       │                      │
                         │   snet-pe: PE blob/file/queue (storage) ◄─────────────┘                      │
                         └──────────────────────────────────────────────────────────────────────────────┘
        Deployer IP ─(SCM, IP-restringido)─► Function Apps (público solo para publicar código)
   App Insights / Log Analytics ◄── trazas de ambas apps
```

## Prerrequisitos

- Terraform ≥ 1.9, Azure CLI, Node.js 20+, Azure Functions Core Tools v4, `gh`.
- Sesión iniciada: `az login` y una suscripción con cuota para EP1 + Flex.
- Región que soporte **Flex Consumption**, **EP1** y **Azure Load Testing**
  (p. ej. `westeurope`, `eastus`, `swedencentral`).

## Inicio rápido

```powershell
# 1) Infraestructura
cd infra
cp terraform.tfvars.example terraform.tfvars   # edita subscription_id
terraform init
terraform apply

# 2) Publicar el código en ambas apps
..\scripts\deploy.ps1

# 3) Lanzar la carga en paralelo (Flex vs Premium)
..\scripts\run-loadtest.ps1 -Users 20 -Duration 300 -CpuMs 200 -MemMB 256
```

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
| `premium_sku_name` | `EP1` | SKU Elastic Premium (EP1/EP2/EP3) |
| `premium_maximum_elastic_worker_count` | `40` | Workers elásticos máx. Premium |
| `premium_prewarmed_instance_count` | `1` | Instancias pre-warmed Premium |
| `enable_function_private_endpoints` | `true` | PE en las funciones |
| `deployer_ipv4` | auto | IP pública permitida (storage + SCM) |

Lista completa en `infra/variables.tf`.

## Notas de alineación con WAF

- **Seguridad**: private endpoints (storage + funciones), *default deny* en el
  firewall de storage, TLS 1.2 mínimo, HTTPS obligatorio, managed identity.
- **Asimetría documentada**: Elastic Premium **requiere** un *content share* de
  Azure Files con cadena de conexión por **clave** (las identidades no están
  soportadas para el content share en ese plan). Flex Consumption sí es
  totalmente *keyless*. El tráfico del content share se fuerza por la VNet
  (`WEBSITE_CONTENTOVERVNET=1`) hacia el private endpoint `file`. Esta diferencia
  es, en sí misma, un hallazgo relevante de la comparativa.
- **Despliegue de código**: para poder publicar desde el equipo del operador, el
  endpoint público de las funciones queda **restringido por IP** al deployer; el
  tráfico de Azure Load Testing llega por **private endpoint** (no evaluado por
  las restricciones del endpoint público). Para producción, deshabilita el
  acceso público (ver STEP-BY-STEP).

## Metodología de comparación

El coste de Azure Cost Management tiene **retraso** (horas/día siguiente). Para
una comparación honesta se combinan:

1. **Rendimiento** (fuente primaria): métricas de **Azure Load Testing**
   (latencia p50/p90/p99, throughput, % error) por sampler `flex-stress` /
   `premium-stress`, complementadas con las trazas de **Application Insights**.
2. **Coste**: modelo según medidores documentados + duración/escalado observados,
   y validación posterior con Cost Management (etiqueta `project`).

Para una comparación **justa**, ejecuta escenarios separados (arranque en frío,
régimen permanente y scale-out) como se describe en la guía.

## Estructura

```
infra/      Terraform (red, storage, identidad, funciones, monitorización, load test)
src/        Función Node.js compartida (stress + health)
loadtest/   Plan JMeter + plantilla de configuración de Azure Load Testing
scripts/    build.ps1, deploy.ps1, run-loadtest.ps1
docs/       Guía paso a paso + consultas KQL
```

## Limpieza

```powershell
cd infra
terraform destroy
```
