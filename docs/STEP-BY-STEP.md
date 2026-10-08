# Guía paso a paso: desplegar, lanzar la prueba y monitorizarla

Esta guía te lleva desde cero hasta tener la comparativa **Flex Consumption vs
plan reservado (App Service Dedicated P0v3)** ejecutándose y monitorizada con
Application Insights.

> El lado "Premium" corre sobre un **plan Dedicated** (keyless, always-on) en
> lugar de **Elastic Premium**, porque EP requiere un *content share* de Azure
> Files con clave compartida y la suscripción de demo deshabilita las claves por
> policy. Cambia `premium_sku_name` a `EP1` si tu suscripción permite claves.

---

## 0. Prerrequisitos

- **Azure CLI** (`az`), **Terraform ≥ 1.9**, **Node.js 20+**, **Azure Functions
  Core Tools v4** y **PowerShell 7** (recomendado).
- Sesión iniciada y suscripción seleccionada:
  ```powershell
  az login
  az account set --subscription "<tu-subscription-id>"
  az account show --query id -o tsv   # copia este valor
  ```
- Cuota disponible para **Flex Consumption** y **App Service Dedicated** en la
  región elegida.

### 0.1 Registrar resource providers (una sola vez por suscripción)

Terraform no los registra (`resource_provider_registrations = "none"`). Si no lo
están ya (incluye `Microsoft.Batch`, necesario para la inyección en VNet de
Azure Load Testing):

```powershell
foreach ($p in 'Microsoft.Web','Microsoft.App','Microsoft.Storage','Microsoft.Network','Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.LoadTestService','Microsoft.Batch') {
  az provider register --namespace $p
}
```

---

## 1. Desplegar la infraestructura (Terraform)

```powershell
cd infra
Copy-Item terraform.tfvars.example terraform.tfvars
# Edita terraform.tfvars y pon tu subscription_id (y, si quieres, location/SKU).

terraform init
terraform plan      # revisa el plan
terraform apply     # escribe 'yes'
```

**Qué ocurre:**
- Se crea un grupo de recursos `rg-<prefix>-<hex>` con todo dentro.
- El **storage es keyless y privado** (sin acceso público): el contenedor de
  despliegue de Flex se crea por **plano de control** (`azapi`) y el acceso en
  ejecución es por **managed identity** (roles Blob/Queue/Table Data).
- La IP pública de tu equipo se detecta automáticamente (`api.ipify.org`) y se
  permite en el endpoint **SCM/sitio** de las funciones. Si estás tras proxy
  corporativo o IPv6, ponla a mano, o fija un rango si tu IP **rota**:
  ```hcl
  deployer_ipv4       = "203.0.113.25"   # o
  deployer_allow_cidr = "167.220.0.0/16" # permite un rango corporativo
  ```
- Las role assignments de storage se crean **antes** que las funciones y hay una
  espera de 60 s para propagación de RBAC (evita fallos de arranque).

> **Nota (apply en storage privado):** como el storage no es accesible por plano
> de datos desde tu equipo, un `terraform apply`/`plan` completo puede fallar al
> **refrescar** propiedades de storage (static website/queue). Usa
> `terraform apply -refresh=false` para cambios que no toquen el storage.

Al terminar verás los outputs (nombres de apps, hostnames, nombre del recurso de
Load Testing, etc.). Puedes recuperarlos cuando quieras con:

```powershell
terraform output
```

---

## 2. Publicar el código en ambas Function Apps

El **mismo** código Node.js se publica en la app Flex y en la Premium:

```powershell
cd ..\scripts
.\deploy.ps1
```

Internamente:
1. `build.ps1` instala dependencias de producción en `src/`.
2. `func azure functionapp publish` publica en cada app (vía SCM público,
   restringido a tu IP).

### 2.1 Verificar que responden (warm-up)

El endpoint `/api/health` es anónimo:

```powershell
$tf = terraform -chdir=..\infra output -json | ConvertFrom-Json
curl.exe "https://$($tf.flex_default_hostname.value)/api/health"
curl.exe "https://$($tf.premium_default_hostname.value)/api/health"
```

Para probar `/api/stress` (requiere clave de función):

```powershell
$rg = $tf.resource_group_name.value
$key = az functionapp keys list -g $rg -n $tf.flex_app_name.value --query "functionKeys.default" -o tsv
curl.exe "https://$($tf.flex_default_hostname.value)/api/stress?cpuMs=200&memMB=256&loops=1&runId=smoke" -H "x-functions-key: $key"
```

> Parámetros de `/api/stress`: `cpuMs` (0-10000), `memMB` (0-512), `loops`
> (1-50), `runId` (etiqueta para correlacionar en KQL).

---

## 3. Lanzar la carga en paralelo

Tienes **dos** vías. La **carga directa** es la más rápida para ver resultados;
**Azure Load Testing** es la opción "infra" con inyección en VNet.

### 3.A Carga directa (recomendada para la demo)

Golpea ambas apps a la vez desde tu equipo (requiere tu IP/CIDR permitido):

```powershell
cd ..\scripts
.\run-direct-load.ps1 -Workers 12 -Duration 120 -CpuMs 300 -MemMB 128 -Loops 2
```

Imprime una tabla comparativa (peticiones, éxito/error, latencia media/máx,
req/s) y un `runId` (`direct-...`) para correlacionar en App Insights.

### 3.B Azure Load Testing (VNet injection)

```powershell
.\run-loadtest.ps1 -Users 20 -Ramp 30 -Duration 300 -CpuMs 200 -MemMB 256 -Loops 1
```

El script instala la extensión `load`, lee los outputs, obtiene las claves,
renderiza `loadtest/load-test-config.generated.yaml` y crea/arranca el test con
**VNet injection** hacia los private endpoints. Cada engine ejecuta **los dos
thread groups** (`flex-tg` y `premium-tg`) con configuración idéntica.

> **Requisitos ALT:** `Microsoft.LoadTestService` y `Microsoft.Batch`
> registrados (ver 0.1). La primera ejecución con VNet puede tardar unos minutos
> en aprovisionar los engines.
>
> **Caveat conocido:** el JMX toma hilos/duración de variables de entorno
> (`${__env(USERS|DURATION)}`). Según la versión del engine, el conteo de hilos
> puede no resolverse y el run acabar con *NoRequestsSent*. Si te ocurre, usa la
> **carga directa** (3.A) o sustituye en el JMX esos `${__env(...)}` por valores
> literales antes de subir el test.

### 3.1 Escenarios recomendados (comparación justa)

Ejecuta runs separados y compáralos por `runId`:

- **Arranque en frío**: con `flex_always_ready_count = 0`, deja ambas apps
  inactivas unos minutos y lanza un run corto. El Dedicated está siempre
  caliente (`always_on`); Flex puede escalar a 0.
- **Régimen permanente**: calienta ambas apps, luego aplica carga sostenida y
  excluye el periodo de calentamiento.
- **Scale-out**: observa cuántas **instancias** usa cada plan (dimensión
  `hostname` en App Insights). Sube `premium_worker_count` para dar capacidad
  reservada al Dedicated.

---

## 4. Monitorizar la ejecución

### 4.1 Durante el run — Azure Load Testing (fuente primaria de rendimiento)

Portal → **Load Testing** → `lt-<prefix>-<hex>` → test `stress-comparison` →
tu `runId`. Verás por **sampler** (`flex-stress` vs `premium-stress`):
- Response time (p50/p90/p99), throughput (req/s) y % de error.
- Client-side metrics en tiempo real.

### 4.2 Lado servidor — Application Insights

Portal → **Application Insights** `appi-<prefix>-<hex>`:
- **Live Metrics**: carga de CPU/instancias en vivo durante el run.
- **Logs (KQL)**: usa las consultas de [kql-queries.md](kql-queries.md),
  filtrando por tu `runId` y ventana temporal. Compara ambos planes por
  `cloud_RoleName` y la dimensión personalizada `plan`.
- **Performance** / **Failures**: duración de `stress` y errores por plan.

### 4.3 Coste

El coste real en **Cost Management** aparece con retraso (horas / día
siguiente). Filtra por el grupo de recursos o la etiqueta `project=func-premium-vs-flex`
y agrupa por recurso para separar el plan Flex del App Service Plan Dedicated.
Mientras tanto, estima con el modelo descrito en el README (medidores + duración
y escalado observados).

---

## 5. Repetir / ajustar

Cambia parámetros sin recrear infraestructura:

```powershell
.\run-loadtest.ps1 -Users 50 -Duration 600 -CpuMs 400 -MemMB 384
```

O ajusta SKUs/escala en `terraform.tfvars` y vuelve a `terraform apply`.

---

## 6. Endurecer para producción (opcional)

- Pon `public_network_access_enabled = false` en las funciones y despliega el
  código desde un **agente dentro de la VNet** (jump box / self-hosted runner) o
  por pipeline con private endpoint. El endpoint público deja de ser necesario
  porque Azure Load Testing llega por private endpoint.
- Lleva Application Insights/Log Analytics a **Private Link (AMPLS)**.
- El storage ya es **keyless y privado**; mantén los roles de datos al mínimo
  necesario (Blob/Queue/Table Data) por identidad.
- Gestiona el estado de Terraform en un **backend remoto** (Azure Storage).

---

## 7. Limpieza

```powershell
cd infra
terraform destroy
```

Esto elimina **todo** el grupo de recursos y sus costes asociados.

---

## Solución de problemas

| Síntoma | Causa probable | Acción |
|---------|----------------|--------|
| `func publish` da 403 | Tu IP no está permitida en SCM | Fija `deployer_ipv4`/`deployer_allow_cidr` y `terraform apply -refresh=false` |
| `/api/stress` da 401 | Falta la clave de función | Pásala en `x-functions-key` o `?code=` |
| Flex: `listkeys` da *InternalServerError* | `AzureWebJobsStorage` con clave vacía (policy keyless) | Ya resuelto: settings `AzureWebJobsStorage__accountName/credential/clientId` + borrado del connection string (ver `functions_flex.tf`) |
| `terraform apply` falla al refrescar storage | Storage privado no accesible por plano de datos | Usa `terraform apply -refresh=false` |
| Load test *NoRequestsSent* | `${__env(...)}` de hilos no resuelto en el engine | Usa `run-direct-load.ps1` o literales en el JMX |
| Load test sin tráfico a las apps | Subnet de ALT, DNS o `Microsoft.Batch` sin registrar | Revisa `subnetId` (sin delegación), PE de funciones y providers |
| Conteos de requests dispares en App Insights | Sampling | Ya desactivado (host.json + componente al 100%); verifica que no haya *daily cap* |
