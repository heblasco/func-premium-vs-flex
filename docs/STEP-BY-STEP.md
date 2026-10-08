# Guía paso a paso: desplegar, lanzar la prueba y monitorizarla

Esta guía te lleva desde cero hasta tener la comparativa Flex Consumption vs
Premium ejecutándose y monitorizada con Application Insights.

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
- Cuota disponible para **EP1** y **Flex Consumption** en la región elegida.

### 0.1 Registrar resource providers (una sola vez por suscripción)

Terraform no los registra (`resource_provider_registrations = "none"`). Si no lo
están ya:

```powershell
foreach ($p in 'Microsoft.Web','Microsoft.App','Microsoft.Storage','Microsoft.Network','Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.LoadTestService') {
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
- La IP pública de tu equipo se detecta automáticamente (`api.ipify.org`) y se
  permite en el firewall del storage y en el endpoint SCM de las funciones.
  Si estás tras proxy corporativo o IPv6, ponla a mano:
  ```hcl
  deployer_ipv4 = "203.0.113.25"
  ```
- Las role assignments de storage se crean **antes** que las funciones y hay una
  espera de 60 s para propagación de RBAC (evita fallos de arranque).

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

## 3. Lanzar la carga en paralelo (Azure Load Testing)

```powershell
cd ..\scripts
.\run-loadtest.ps1 -Users 20 -Ramp 30 -Duration 300 -CpuMs 200 -MemMB 256 -Loops 1
```

El script:
1. Instala/actualiza la extensión `load` de Azure CLI.
2. Lee los outputs de Terraform y obtiene las claves de función.
3. Renderiza `loadtest/load-test-config.generated.yaml` (hosts, claves, subnet,
   `runId`, parámetros de carga).
4. Crea el test `stress-comparison` y **arranca una ejecución** (`runId` con
   marca temporal) con **VNet injection** hacia los private endpoints.

Cada engine ejecuta **los dos thread groups** (`flex-tg` y `premium-tg`) con
configuración idéntica, de modo que ambas apps reciben la **misma carga a la
vez**. Anota el `runId` que imprime el script: es tu clave de correlación.

### 3.1 Escenarios recomendados (comparación justa)

Ejecuta runs separados y compáralos por `runId`:

- **Arranque en frío**: `terraform apply` con `flex_always_ready_count = 0`,
  deja ambas apps inactivas unos minutos y lanza un run corto. Mide la latencia
  de las primeras peticiones (EP1 siempre está caliente; Flex puede escalar a 0).
- **Régimen permanente**: calienta ambas apps (un run previo o `/api/health` en
  bucle), luego aplica carga sostenida y excluye el periodo de calentamiento.
- **Scale-out**: usa el mismo `-Ramp`/`-Users` en ambas y observa el tiempo
  hasta throughput estable y el número de instancias.

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
y agrupa por recurso para separar el plan Flex del App Service Plan EP1.
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
- Sustituye el acceso por clave del *content share* de Premium por las opciones
  más recientes que ofrezca la plataforma.
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
| `func publish` da 403 | Tu IP no está permitida en SCM | Fija `deployer_ipv4` y `terraform apply` |
| Terraform falla creando el contenedor/share | IP del deployer no permitida en storage | Igual que arriba |
| La función Premium no arranca | Content share no accesible | Verifica PE `file`, DNS `privatelink.file` y `WEBSITE_CONTENTOVERVNET=1` |
| Load test sin tráfico a las apps | Subnet de ALT o DNS | Revisa `subnetId`, que la subred no esté delegada y los PE de funciones |
| Conteos de requests dispares en App Insights | Sampling | Ya está desactivado (host.json + componente al 100%); verifica que no haya *daily cap* |
