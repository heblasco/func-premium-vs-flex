#Requires -Version 7.0
# Dependency-free contract tests: no Terraform, Azure or HTTP operations execute.
$ErrorActionPreference = 'Stop'
$global:StartupWrapperTest = @{
  Captured = $null; WrongSku = $false; MissingEp = $false; AzureFailure = $false; WrongHost = $false
  Calls = [System.Collections.Generic.List[string]]::new()
}

function terraform {
  $global:LASTEXITCODE = 0
  @{
    resource_group_name = @{ value = 'rg-test' }
    flex_app_name = @{ value = 'test-flex' }
    flex_default_hostname = @{ value = 'flex.example.test' }
    premium_app_name = @{ value = 'test-dedicated' }
    premium_default_hostname = @{ value = 'dedicated.example.test' }
    elastic_premium = @{ value = @{
      app_name = if ($global:StartupWrapperTest.MissingEp) { $null } else { 'test-ep' }
      storage_account = 'epstore'
      hostname = 'ep.example.test'
    } }
  } | ConvertTo-Json -Depth 8
}

function az {
  $global:LASTEXITCODE = if ($global:StartupWrapperTest.AzureFailure) { 1 } else { 0 }
  $command = $args -join ' '
  $global:StartupWrapperTest.Calls.Add($command)
  if ($command.StartsWith('group show')) { return '{"id":"/subscriptions/test-sub/resourceGroups/rg-test"}' }
  if ($command.StartsWith('rest ')) {
    if ($command.Contains('/config/web?')) {
      return '{"properties":{"alwaysOn":true,"minimumElasticInstanceCount":1,"preWarmedInstanceCount":1,"functionAppScaleLimit":3}}'
    }
    $plan = if ($command.Contains('/test-flex?')) { 'flex' } elseif ($command.Contains('/test-ep?')) { 'ep' } else { 'dedicated' }
    return (@{ properties = @{
      serverFarmId = "/plans/$plan"; defaultHostName = if ($global:StartupWrapperTest.WrongHost) { 'wrong.example.test' } else { "$plan.example.test" }
      functionAppConfig = @{ scaleAndConcurrency = @{
        maximumInstanceCount = 40; instanceMemoryMB = 2048
        alwaysReady = @(@{name='http';instanceCount=1})
        triggers = @{http=@{perInstanceConcurrency=16}}
      } }
    } } | ConvertTo-Json -Depth 10)
  }
  if ($command.StartsWith('appservice plan show')) {
    $sku = if ($command.Contains('/plans/flex')) { 'FC1' } elseif ($command.Contains('/plans/ep') -and -not $global:StartupWrapperTest.WrongSku) { 'EP1' } else { 'P0v3' }
    return (@{sku=@{name=$sku;capacity=1}} | ConvertTo-Json)
  }
  if ($command.StartsWith('functionapp config appsettings list')) {
    return ('[{"name":"FUNCTIONS_WORKER_PROCESS_COUNT","value":"1"},{"name":"WEBSITE_RUN_FROM_PACKAGE","value":"https://epstore.blob.core.windows.net/deploymentpackage/' + ('a' * 64) + '.zip"}]')
  }
  if ($command.StartsWith('functionapp keys list')) { return 'test-secret' }
  throw 'Unexpected Azure call in test.'
}

function node {
  $global:StartupWrapperTest.Captured = $env:STARTUP_CONFIG | ConvertFrom-Json -AsHashtable
  $global:LASTEXITCODE = 0
}

$runner = Join-Path $PSScriptRoot '..\run-startup-comparison.ps1'
$infra = Join-Path $PSScriptRoot '..\..\infra'
$original = $env:STARTUP_CONFIG
try {
  $env:STARTUP_CONFIG = 'preserved'
  & $runner -InfraPath $infra -Scenario idle-probe -IdleSeconds 0 -Cycles 1 -Samples 1
  if ($global:StartupWrapperTest.Captured.targets.Count -ne 2) { throw 'Expected Flex and EP.' }
  $ep = $global:StartupWrapperTest.Captured.targets | Where-Object name -eq 'elastic-premium'
  if ($ep.configuration.sku -ne 'EP1' -or $ep.configuration.alwaysReady -ne 1 -or $ep.configuration.prewarmed -ne 1) {
    throw 'Actual EP readiness not captured.'
  }
  if ($ep.configuration.packageSha256 -ne ('a' * 64)) { throw 'Actual package hash not captured.' }
  if ($env:STARTUP_CONFIG -ne 'preserved') { throw 'Environment was not restored.' }
  if ($global:StartupWrapperTest.Calls | Where-Object { $_ -match ' update | set | restart | delete | apply ' }) { throw 'Unexpected mutation.' }
  foreach ($mode in @('WrongSku', 'MissingEp', 'AzureFailure', 'WrongHost')) {
    $global:StartupWrapperTest[$mode] = $true
    $global:StartupWrapperTest.Captured = $null
    $failed = $false
    try { & $runner -InfraPath $infra -IdleSeconds 0 } catch { $failed = $true }
    $global:StartupWrapperTest[$mode] = $false
    if (-not $failed -or $null -ne $global:StartupWrapperTest.Captured) { throw "Failure gate did not stop the runner: $mode" }
  }
  Write-Output 'PASS: ARM discovery, readiness/package snapshot, secret environment restoration and fail-closed gates.'
} finally {
  $env:STARTUP_CONFIG = $original
  Remove-Variable StartupWrapperTest -Scope Global
}
