[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('build', 'publish', 'run', 'sync')][string]$Action,
    [ValidateSet('flex', 'dedicated', 'elastic-premium')][string[]]$Targets = @('flex', 'dedicated'),
    [ValidateSet('warm-baseline', 'idle-probe', 'burst')][string]$Scenario = 'warm-baseline',
    [int]$Samples = 100,
    [int]$Workers = 12,
    [int]$DurationSeconds = 120,
    [int]$IdleSeconds = 300,
    [int]$CpuMs = 0
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$outputs = terraform "-chdir=$root\infra" output -json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Terraform outputs unavailable.' }
$runner = $outputs.verification_runner.value
if (-not $runner) { throw 'Provision the private runner first.' }
$group = $outputs.resource_group_name.value
$prefix = $runner.vm_id -replace '/providers/Microsoft.Compute/virtualMachines/.*$', '/providers/Microsoft.Web/sites/'
$all = @{
    flex = @{ name = 'flex'; id = "$prefix$($outputs.flex_app_name.value)"; hostname = $outputs.flex_default_hostname.value; sku = 'FC1' }
    dedicated = @{ name = 'dedicated'; id = "$prefix$($outputs.premium_app_name.value)"; hostname = $outputs.premium_default_hostname.value; sku = 'P0v3' }
    'elastic-premium' = @{ name = 'elastic-premium'; id = $outputs.elastic_premium.value.app_id; hostname = $outputs.elastic_premium.value.hostname; sku = 'EP1' }
}
$selected = foreach ($name in $Targets) {
    $target = $all[$name]
    if (-not $target.id) { throw "$name has not been provisioned." }
    $site = az resource show --ids $target.id --api-version 2023-12-01 -o json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Cannot verify $name." }
    $plan = az resource show --ids $site.properties.serverFarmId --api-version 2023-12-01 -o json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $plan.sku.name -ne $target.sku) { throw "Unexpected SKU for $name." }
    $target
}
$config = @{
    runner = $runner; ep = $outputs.elastic_premium.value; targets = @($selected)
    options = @{
        scenario = $Scenario; samples = $Samples; workers = $Workers
        durationSeconds = $DurationSeconds; idleSeconds = $IdleSeconds
        cpuMs = $CpuMs; cycles = 1; timeoutMs = 120000
    }
} | ConvertTo-Json -Depth 20 -Compress
$temporary = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
[IO.Directory]::CreateDirectory($temporary) | Out-Null
try {
    $zipPath = Join-Path $temporary 'source.zip'
    $zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $files = @{
            'private-verification.py' = "$PSScriptRoot\private-verification.py"
            'startup-runner.js' = "$PSScriptRoot\startup-runner.js"
        }
        if ($Action -eq 'build') {
            foreach ($name in @('package.json', 'package-lock.json', 'host.json')) { $files["src/$name"] = "$root\src\$name" }
            Get-ChildItem "$root\src\src" -Recurse -File | ForEach-Object {
                $files["src/" + [IO.Path]::GetRelativePath("$root\src", $_.FullName).Replace('\', '/')] = $_.FullName
            }
        }
        foreach ($name in $files.Keys) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $files[$name], $name) | Out-Null
        }
        $entry = $zip.CreateEntry('config.json')
        $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
        try { $writer.Write($config) } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
    $payload = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zipPath))
    $hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $bootstrap = @'
set -eu
trap 'code=$?; printf "\nVERIFICATION_EXIT=%s\n" "$code"' EXIT
umask 077
mkdir -p /opt/function-verification
cd /opt/function-verification
echo '__PAYLOAD__' | base64 --decode > source.zip
echo '__HASH__  source.zip' | sha256sum --check --status
python3 -m zipfile -e source.zip .
export PATH=/opt/function-verification/node/bin:$PATH
if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]')" != 22 ]; then
  curl --fail --silent --show-error https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt -o SHASUMS256.txt
  archive=$(awk '$2 ~ /^node-v22[.].*-linux-x64.tar.xz$/ {print $2}' SHASUMS256.txt)
  test -n "$archive"
  curl --fail --silent --show-error "https://nodejs.org/dist/latest-v22.x/$archive" -o "$archive"
  grep "  $archive$" SHASUMS256.txt | sha256sum --check --status
  mkdir -p node
  tar -xJf "$archive" -C node --strip-components=1
  rm "$archive"
fi
python3 private-verification.py __ACTION__
'@
    $script = $bootstrap.Replace('__PAYLOAD__', $payload).Replace('__HASH__', $hash).Replace('__ACTION__', $Action)
    if ([Text.Encoding]::UTF8.GetByteCount($script) -gt 60000) { throw 'Source bundle exceeds the bounded Run Command payload.' }
    $scriptPath = Join-Path $temporary 'execute.sh'
    [IO.File]::WriteAllText($scriptPath, $script.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    $raw = az vm run-command invoke -g $group -n $runner.vm_name --command-id RunShellScript --scripts "@$scriptPath" -o json
    if ($LASTEXITCODE -ne 0) { throw 'Azure Run Command invocation failed.' }
    $response = $raw | ConvertFrom-Json
    $receiptDirectory = Join-Path $root 'loadtest\startup-results\azure-private'
    [IO.Directory]::CreateDirectory($receiptDirectory) | Out-Null
    $receipt = Join-Path $receiptDirectory ("{0}-{1}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Action)
    [IO.File]::WriteAllText($receipt, ($response | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    foreach ($message in $response.value) { Write-Output $message.message }
    if (($response.value.message -join "`n") -notmatch '(?m)^VERIFICATION_EXIT=0\s*$') {
        throw "Private verification failed. Run Command response: $receipt"
    }
    Write-Output "Run Command response saved: $receipt"
} finally {
    foreach ($name in @('source.zip', 'execute.sh')) {
        $path = Join-Path $temporary $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    [IO.Directory]::Delete($temporary)
}
