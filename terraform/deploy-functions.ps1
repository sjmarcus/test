#Requires -Version 7
<#
.SYNOPSIS
    Publishes both Function Apps using the same service principal as deploy.ps1.

.DESCRIPTION
    Event Grid validates a function endpoint live when it creates a
    subscription, so the code has to be on the apps before the subscriptions
    can be created. Run this after the first `deploy.ps1 -Apply` (which creates
    the empty apps) and then run `deploy.ps1 -Apply` again.

    It reads the SP from .env.ps1, signs in with the Azure CLI inside a
    throwaway config directory (so your own `az login` and cloud selection are
    left alone), takes the app names from `terraform output`, and zip-deploys:

      function_app/       -> the PowerShell app, as is
      secret_distributor/ -> the .NET app, after `dotnet publish`

    It uses `az functionapp deployment source config-zip` rather than Functions
    Core Tools because the Azure CLI honours the selected cloud (Gov) for
    certain, and Core Tools' sovereign-cloud behaviour is not something this
    repo has verified.

    The SP needs rights to deploy to both apps, which Contributor on the
    resource group includes. Needs: az, dotnet SDK 8+, terraform on PATH.

.PARAMETER Cloud
    Azure CLI cloud name. Default AzureUSGovernment; use AzureCloud for commercial.

.PARAMETER SkipPowerShellApp
    Do not publish function_app/.

.PARAMETER SkipDotnetApp
    Do not publish secret_distributor/.

.EXAMPLE
    ./deploy-functions.ps1
#>
param(
    [string]$Cloud = "AzureUSGovernment",
    [switch]$SkipPowerShellApp,
    [switch]$SkipDotnetApp
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = Split-Path $PSScriptRoot -Parent

function Invoke-Native {
    # Runs a native command, throws with its output if it exits non-zero.
    param([string]$What, [scriptblock]$Command)
    $out = & $Command 2>&1
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE):`n$($out | Out-String)" }
    $out
}

function New-ZipFromFolder {
    # Forward-slash entry names (required on Linux hosts), minus anything that
    # matches $ExcludePattern (tested against the path relative to $Source).
    param([string]$Source, [string]$Destination, [string]$ExcludePattern)

    if (Test-Path $Destination) { Remove-Item $Destination -Force }
    $sourceFull = (Resolve-Path $Source).Path.TrimEnd('\', '/')
    $zip = [System.IO.Compression.ZipFile]::Open($Destination, 'Create')
    try {
        Get-ChildItem -Path $sourceFull -Recurse -File -Force | ForEach-Object {
            $relative = $_.FullName.Substring($sourceFull.Length + 1).Replace('\', '/')
            if ($ExcludePattern -and $relative -match $ExcludePattern) { return }
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $_.FullName, $relative, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    }
    finally { $zip.Dispose() }
}

function Publish-App {
    param([string]$ResourceGroup, [string]$AppName, [string]$ZipPath, [string[]]$ExpectedFunctions)

    Write-Host "Deploying $([IO.Path]::GetFileName($ZipPath)) to $AppName..." -ForegroundColor Cyan
    Invoke-Native "az functionapp deployment source config-zip ($AppName)" {
        az functionapp deployment source config-zip --resource-group $ResourceGroup --name $AppName --src $ZipPath --output none
    } | Out-Null

    # Ask the host itself what it is serving. `az functionapp function list`
    # reads ARM's view, which lags the host (it came back empty for minutes
    # while the host already served every function), and ARM's view is not what
    # Event Grid's endpoint validation hits anyway. The master key is used
    # in-process only and never printed.
    $hostName = (Invoke-Native "az functionapp show ($AppName)" {
        az functionapp show --resource-group $ResourceGroup --name $AppName --query defaultHostName -o tsv
    } | Select-Object -First 1).Trim()
    $masterKey = (Invoke-Native "az functionapp keys list ($AppName)" {
        az functionapp keys list --resource-group $ResourceGroup --name $AppName --query masterKey -o tsv
    } | Select-Object -First 1).Trim()

    # A cold PowerShell worker can take a few minutes to start.
    $found = @()
    $deadline = (Get-Date).AddMinutes(6)
    do {
        try {
            $found = @(Invoke-RestMethod "https://$hostName/admin/functions" -Headers @{ 'x-functions-key' = $masterKey } -TimeoutSec 30 |
                ForEach-Object { $_.name })
        }
        catch { $found = @() }
        $missing = $ExpectedFunctions | Where-Object { $_ -notin $found }
        if (-not $missing) { break }
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)
    $masterKey = $null

    if ($missing) {
        throw "$AppName deployed but these functions are not indexed yet: $($missing -join ', '). " +
              "Found: $($found -join ', '). Check the app's log stream before re-applying Terraform."
    }
    Write-Host "  $AppName is serving: $($found -join ', ')" -ForegroundColor Green
}

$work = Join-Path ([IO.Path]::GetTempPath()) "deploy-functions-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $work | Out-Null
$previousConfigDir = $env:AZURE_CONFIG_DIR

try {
    # --- credentials, same file deploy.ps1 uses --------------------------------
    $envFile = Join-Path $PSScriptRoot ".env.ps1"
    if (-not (Test-Path $envFile)) { throw ".env.ps1 not found in $PSScriptRoot. Copy .env.ps1.example and fill it in." }
    . $envFile
    foreach ($name in 'SpClientId', 'SpClientSecret', 'SpTenantId', 'SpSubscriptionId') {
        if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $name -Scope Script -ValueOnly -ErrorAction SilentlyContinue))) {
            throw "$name is empty in .env.ps1."
        }
    }

    # --- app names from Terraform ----------------------------------------------
    Push-Location $PSScriptRoot
    try {
        $rg         = (terraform output -raw resource_group_name).Trim()
        $psApp      = (terraform output -raw function_app_name).Trim()
        $dotnetApp  = (terraform output -raw distributor_function_app_name 2>$null)
    }
    finally { Pop-Location }
    if (-not $rg -or -not $psApp) { throw "Could not read terraform outputs. Has the first apply created the apps?" }
    if (-not $SkipDotnetApp -and ([string]::IsNullOrWhiteSpace($dotnetApp) -or $dotnetApp -eq 'null')) {
        throw "No distributor app in the outputs (enable_secret_distribution is false?). Re-run with -SkipDotnetApp."
    }

    # --- isolated az session ---------------------------------------------------
    $env:AZURE_CONFIG_DIR = Join-Path $work "azcfg"
    Invoke-Native "az cloud set" { az cloud set --name $Cloud } | Out-Null
    Write-Host "Signing in as $script:SpClientId to $Cloud..." -ForegroundColor Cyan
    # The secret is on the command line for the length of this call; the az CLI
    # has no stdin or env option for it.
    Invoke-Native "az login" {
        az login --service-principal --username $script:SpClientId --password $script:SpClientSecret `
            --tenant $script:SpTenantId --output none
    } | Out-Null
    Invoke-Native "az account set" { az account set --subscription $script:SpSubscriptionId } | Out-Null

    # --- PowerShell app --------------------------------------------------------
    if (-not $SkipPowerShellApp) {
        $zip = Join-Path $work "function_app.zip"
        New-ZipFromFolder -Source (Join-Path $repoRoot "function_app") -Destination $zip `
            -ExcludePattern '^(\.vscode|\.git)/|(^|/)local\.settings\.json$|(^|/)__azurite|(^|/)__blobstorage__'
        Publish-App -ResourceGroup $rg -AppName $psApp -ZipPath $zip `
            -ExpectedFunctions @('OnSecretNearExpiry', 'OnVMPasswordNearExpiry', 'RenewWebhook')
    }

    # --- .NET app --------------------------------------------------------------
    if (-not $SkipDotnetApp) {
        $publishDir = Join-Path $work "publish"
        Write-Host "Building secret_distributor..." -ForegroundColor Cyan
        Invoke-Native "dotnet publish" {
            dotnet publish (Join-Path $repoRoot "secret_distributor\SecretDistributor.csproj") -c Release -o $publishDir --nologo -v quiet
        } | Out-Null
        $zip = Join-Path $work "secret_distributor.zip"
        New-ZipFromFolder -Source $publishDir -Destination $zip -ExcludePattern '(^|/)local\.settings\.json$'
        Publish-App -ResourceGroup $rg -AppName $dotnetApp -ZipPath $zip -ExpectedFunctions @('DistributeSecret')
    }

    Write-Host "`nDone. Now run ./deploy.ps1 -Apply to create the Event Grid subscriptions." -ForegroundColor Green
}
finally {
    $env:AZURE_CONFIG_DIR = $previousConfigDir
    if ($null -eq $previousConfigDir) { Remove-Item Env:\AZURE_CONFIG_DIR -ErrorAction SilentlyContinue }
    $script:SpClientSecret = $null
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
