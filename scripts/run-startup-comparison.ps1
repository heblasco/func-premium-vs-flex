#Requires -Version 7.0
<#
.SYNOPSIS
  Measures startup/readiness without changing Azure resources or warming idle probes.
.DESCRIPTION
  Reads actual ARM configuration before the idle interval. Persists per-invocation
  results, not keys. Requires the updated stress code and an allowed network path.
#>
[CmdletBinding()]
param(
  [ValidateSet('idle-probe', 'warm-baseline', 'burst')][string]$Scenario = 'idle-probe',
  [ValidateSet('flex', 'dedicated', 'elastic-premium')][string[]]$Targets = @('flex', 'elastic-premium'),
  [ValidateRange(1,100)][int]$Cycles = 5,
  [ValidateRange(0,86400)][int]$IdleSeconds = 1800,
  [ValidateRange(1,10000)][int]$Samples = 20,
  [ValidateRange(1,128)][int]$Workers = 12,
  [ValidateRange(1,3600)][int]$DurationSeconds = 120,
  [ValidateRange(1,230)][int]$TimeoutSeconds = 120,
  [ValidateRange(0,10000)][int]$CpuMs = 0,
  [ValidateRange(0,512)][int]$MemMB = 0,
  [ValidateRange(1,50)][int]$Loops = 1,
  [string]$InfraPath = (Join-Path $PSScriptRoot '..\infra'),
  [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\loadtest\startup-results')
)
$ErrorActionPreference = 'Stop'

function Read-AzJson([string[]]$CliArgs) {
  $json = & az @CliArgs --only-show-errors -o json
  if ($LASTEXITCODE -ne 0) { throw 'Azure configuration discovery failed. No probes were sent.' }
  return ($json | ConvertFrom-Json -AsHashtable)
}

$tfJson = terraform "-chdir=$((Resolve-Path $InfraPath).Path)" output -json
if ($LASTEXITCODE -ne 0) { throw 'Could not read Terraform outputs.' }
$tf = $tfJson | ConvertFrom-Json -AsHashtable
$rg = $tf.resource_group_name.value
if (-not $rg) { throw 'Missing resource group output.' }
$group = Read-AzJson @('group', 'show', '--name', $rg)
$subscription = $group.id.Split('/')[2]
$targetConfigs = foreach ($target in $Targets) {
  $name = switch ($target) {
    'flex' { $tf.flex_app_name.value }
    'dedicated' { $tf.premium_app_name.value }
    'elastic-premium' { $tf.elastic_premium.value.app_name }
  }
  $expectedHost = switch ($target) {
    'flex' { $tf.flex_default_hostname.value }
    'dedicated' { $tf.premium_default_hostname.value }
    'elastic-premium' { $tf.elastic_premium.value.hostname }
  }
  if (-not $name) { throw "Target '$target' is not deployed. No fallback to Dedicated is allowed." }
  # Use ARM properties directly; CLI SDK projections can rename serverFarmId
  # and omit Flex functionAppConfig.
  $siteId = "$($group.id)/providers/Microsoft.Web/sites/$name"
  $arm = Read-AzJson @('rest', '--method', 'get', '--url', "https://management.azure.com${siteId}?api-version=2023-12-01")
  $site = $arm.properties
  if (-not $expectedHost -or $site.defaultHostName -ne $expectedHost) {
    throw "Target '$target' hostname does not match Terraform state. Check the selected Azure subscription."
  }
  $web = Read-AzJson @('rest', '--method', 'get', '--url', "https://management.azure.com${siteId}/config/web?api-version=2023-12-01")
  $config = $web.properties
  $plan = Read-AzJson @('appservice', 'plan', 'show', '--ids', $site.serverFarmId)
  $sku = $plan.sku.name
  if (($target -eq 'flex' -and $sku -ne 'FC1') -or
      ($target -eq 'elastic-premium' -and $sku -notmatch '^EP[123]$') -or
      ($target -eq 'dedicated' -and $sku -notmatch '^(P[0-9].*|B[123]|S[123])$')) {
    throw "Actual SKU '$sku' does not match target '$target'."
  }
  $scale = $arm.properties.functionAppConfig.scaleAndConcurrency
  if ($target -eq 'flex' -and -not $scale) { throw 'Flex scale configuration is unavailable; refusing to assume always-ready=0.' }
  $ready = if ($target -eq 'flex') {
    $httpReady = @($scale.alwaysReady | Where-Object name -eq 'http')
    if ($httpReady.Count) { $httpReady[0].instanceCount } else { 0 }
  } elseif ($target -eq 'elastic-premium') { $config.minimumElasticInstanceCount } else { $null }
  if ($target -eq 'elastic-premium' -and ($null -eq $ready -or $null -eq $config.preWarmedInstanceCount)) {
    throw 'EP readiness settings are unavailable.'
  }
  $appSettings = Read-AzJson @('functionapp', 'config', 'appsettings', 'list', '--subscription', $subscription,
    '-g', $rg, '-n', $name, '--query', "[?name=='FUNCTIONS_WORKER_PROCESS_COUNT' || name=='WEBSITE_RUN_FROM_PACKAGE'].{name:name,value:value}")
  $workerCount = ($appSettings | Where-Object name -eq 'FUNCTIONS_WORKER_PROCESS_COUNT').value
  $packageHash = $null
  if ($target -eq 'elastic-premium') {
    $packageUrl = ($appSettings | Where-Object name -eq 'WEBSITE_RUN_FROM_PACKAGE').value
    $expectedPrefix = "https://$($tf.elastic_premium.value.storage_account).blob.core.windows.net/deploymentpackage/"
    if (-not $packageUrl -or -not $packageUrl.StartsWith($expectedPrefix) -or
        $packageUrl.Substring($expectedPrefix.Length) -notmatch '^([a-f0-9]{64})\.zip$') {
      throw 'EP must run the immutable private Blob package configured by this project (no SAS).'
    }
    $packageHash = $Matches[1]
  }
  $key = & az functionapp keys list --subscription $subscription -g $rg -n $name --query 'functionKeys.default' --only-show-errors -o tsv
  if ($LASTEXITCODE -ne 0 -or -not $key) { throw "Cannot retrieve key for $target." }
  @{
    name = $target; url = "https://$($site.defaultHostName)/api/stress"; key = "$key".Trim(); resourceId = $siteId
    expectedPlan = if ($target -eq 'dedicated') { 'premium' } else { $target }
    configuration = @{
      sku = $sku; alwaysReady = $ready; prewarmed = if ($target -eq 'elastic-premium') { $config.preWarmedInstanceCount } else { $null }
      alwaysOn = $config.alwaysOn
      maximumInstances = if ($target -eq 'flex') { $scale.maximumInstanceCount } elseif ($target -eq 'elastic-premium') { $config.functionAppScaleLimit } else { $plan.sku.capacity }
      memoryMB = $scale.instanceMemoryMB; httpConcurrency = $scale.triggers.http.perInstanceConcurrency
      workerProcesses = $workerCount; lastModifiedUtc = $arm.properties.lastModifiedTimeUtc
      packageSha256 = $packageHash
    }
  }
}
$settings = @{
  targets = @($targetConfigs)
  options = @{
    scenario = $Scenario; cycles = $Cycles; idleSeconds = $IdleSeconds; samples = $Samples
    workers = $Workers; durationSeconds = $DurationSeconds; timeoutMs = $TimeoutSeconds * 1000
    cpuMs = $CpuMs; memMB = $MemMB; loops = $Loops
  }
}
Write-Host "Scenario: $Scenario. No resource changes, HTTP preflight, or retries. Results: $OutputDirectory"
$previous = $env:STARTUP_CONFIG
try {
  $env:STARTUP_CONFIG = $settings | ConvertTo-Json -Depth 10 -Compress
  & node (Join-Path $PSScriptRoot 'startup-runner.js') $OutputDirectory
  if ($LASTEXITCODE -ne 0) { throw 'Comparison failed or contains errors. Inspect the persisted invocation log and summary.' }
} finally {
  $env:STARTUP_CONFIG = $previous
  $settings = $null
  $targetConfigs = $null
  $key = $null
}
