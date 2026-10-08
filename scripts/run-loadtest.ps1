<#
.SYNOPSIS
  Creates/updates the Azure Load Testing test from the JMeter plan and starts a run.
.DESCRIPTION
  Reads Terraform outputs, fetches each app's default function key, renders
  loadtest/load-test-config.generated.yaml from the template, then uses the
  `az load` extension to create the test and start a run that drives identical
  parallel load against the Flex and Premium apps.
.PARAMETER Users      Virtual users PER thread group (per app). Default 20.
.PARAMETER Ramp       Ramp-up seconds. Default 30.
.PARAMETER Duration   Hold duration seconds. Default 300.
.PARAMETER CpuMs      Busy-loop milliseconds per invocation. Default 200.
.PARAMETER MemMB      Memory allocated per invocation (MB). Default 256.
.PARAMETER Loops      CPU+mem loops per invocation. Default 1.
#>
[CmdletBinding()]
param(
  [int]$Users    = 20,
  [int]$Ramp     = 30,
  [int]$Duration = 300,
  [int]$CpuMs    = 200,
  [int]$MemMB    = 256,
  [int]$Loops    = 1,
  [string]$InfraPath    = (Join-Path $PSScriptRoot '..\infra'),
  [string]$LoadTestPath = (Join-Path $PSScriptRoot '..\loadtest')
)

$ErrorActionPreference = 'Stop'
$InfraPath    = (Resolve-Path $InfraPath).Path
$LoadTestPath = (Resolve-Path $LoadTestPath).Path

Write-Host "Ensuring 'load' az extension is installed..." -ForegroundColor Cyan
az extension add --name load --only-show-errors 2>$null | Out-Null
az extension update --name load --only-show-errors 2>$null | Out-Null

Write-Host "Reading Terraform outputs..." -ForegroundColor Cyan
Push-Location $InfraPath
try { $tf = terraform output -json | ConvertFrom-Json } finally { Pop-Location }

$rg        = $tf.resource_group_name.value
$ltName    = $tf.load_test_name.value
$flexApp   = $tf.flex_app_name.value
$premApp   = $tf.premium_app_name.value
$flexHost  = $tf.flex_default_hostname.value
$premHost  = $tf.premium_default_hostname.value
$subnetId  = $tf.loadtest_subnet_id.value

if (-not $ltName) { throw "Load Testing resource not found. Set enable_load_testing=true and re-apply." }

Write-Host "Fetching function keys..." -ForegroundColor Cyan
$flexKey = az functionapp keys list -g $rg -n $flexApp --query "functionKeys.default" -o tsv
$premKey = az functionapp keys list -g $rg -n $premApp --query "functionKeys.default" -o tsv
if (-not $flexKey -or -not $premKey) { throw "Could not retrieve function keys." }

$runId = "run-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$testId = "stress-comparison"

Write-Host "Rendering load-test config (runId=$runId)..." -ForegroundColor Cyan
$template = Get-Content (Join-Path $LoadTestPath 'load-test-config.yaml') -Raw
$rendered = $template `
  -replace '__FLEX_HOST__', $flexHost `
  -replace '__PREMIUM_HOST__', $premHost `
  -replace '__FLEX_KEY__', $flexKey `
  -replace '__PREMIUM_KEY__', $premKey `
  -replace '__SUBNET_ID__', $subnetId `
  -replace '__RUNID__', $runId

# Apply CLI-provided load parameters.
$rendered = $rendered `
  -replace '(?m)(^\s*-\s*name:\s*USERS\s*\r?\n\s*value:\s*")[^"]*(")',    "`${1}$Users`${2}" `
  -replace '(?m)(^\s*-\s*name:\s*RAMP\s*\r?\n\s*value:\s*")[^"]*(")',     "`${1}$Ramp`${2}" `
  -replace '(?m)(^\s*-\s*name:\s*DURATION\s*\r?\n\s*value:\s*")[^"]*(")', "`${1}$Duration`${2}" `
  -replace '(?m)(^\s*-\s*name:\s*CPUMS\s*\r?\n\s*value:\s*")[^"]*(")',    "`${1}$CpuMs`${2}" `
  -replace '(?m)(^\s*-\s*name:\s*MEMMB\s*\r?\n\s*value:\s*")[^"]*(")',    "`${1}$MemMB`${2}" `
  -replace '(?m)(^\s*-\s*name:\s*LOOPS\s*\r?\n\s*value:\s*")[^"]*(")',    "`${1}$Loops`${2}"

$generated = Join-Path $LoadTestPath 'load-test-config.generated.yaml'
Set-Content -Path $generated -Value $rendered -Encoding UTF8

Write-Host "Creating/updating test '$testId'..." -ForegroundColor Cyan
az load test create `
  --load-test-resource $ltName -g $rg `
  --test-id $testId `
  --load-test-config-file $generated `
  --only-show-errors

Write-Host "Starting run '$runId'..." -ForegroundColor Cyan
az load test-run create `
  --load-test-resource $ltName -g $rg `
  --test-id $testId `
  --test-run-id $runId `
  --description "Flex vs Premium parallel stress" `
  --only-show-errors

Write-Host "`nLoad test run '$runId' started." -ForegroundColor Green
Write-Host "Use this runId as the correlation value in your KQL queries (see docs/kql-queries.md)." -ForegroundColor Yellow
Write-Host "Track progress in the Azure portal -> Load Testing -> $ltName -> $testId -> $runId" -ForegroundColor Yellow
