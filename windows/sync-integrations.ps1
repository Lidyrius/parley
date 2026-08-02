# Apply the saved Claude Code/Codex integration choices to this checkout.
# Only Parley-owned junctions and the Parley-local Codex plugin are touched.
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$CredDir = if ($env:PARLEY_CREDS) { Split-Path -Parent $env:PARLEY_CREDS } else { Join-Path $env:APPDATA 'Parley' }
$Creds = if ($env:PARLEY_CREDS) { $env:PARLEY_CREDS } else { Join-Path $CredDir 'credentials.json' }

function Read-Config {
    if (Test-Path $Creds) {
        try { return (Get-Content -Raw -Path $Creds | ConvertFrom-Json) } catch { }
    }
    return [pscustomobject]@{}
}

function Value($data, $name) {
    $p = $data.PSObject.Properties[$name]
    if ($null -eq $p) { return '' }
    return [string]$p.Value
}

function Is-CommandAvailable($name) { return $null -ne (Get-Command $name -ErrorAction SilentlyContinue) }

$data = Read-Config
$detectedClaude = Value $data 'detectedClaudeCode'
$detectedCodex = Value $data 'detectedCodex'
$enabledClaude = Value $data 'claudeCodeEnabled'
$enabledCodex = Value $data 'codexEnabled'
if (-not $detectedClaude -and (Is-CommandAvailable 'claude')) { $detectedClaude = '1' }
if (-not $detectedCodex -and (Is-CommandAvailable 'codex')) { $detectedCodex = '1' }
if (-not $enabledClaude) { $enabledClaude = $detectedClaude }
if (-not $enabledCodex) { $enabledCodex = $detectedCodex }

$pluginRoot = Join-Path $Root 'plugin'
$claudeLink = Join-Path $env:USERPROFILE '.claude\skills\parley'

function Is-OwnedJunction($path, $target) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try { return ((Resolve-Path -LiteralPath $path).Path -eq (Resolve-Path -LiteralPath $target).Path) } catch { return $false }
}

function Install-Claude {
    New-Item -ItemType Directory -Force -Path (Split-Path $claudeLink) | Out-Null
    if (Test-Path -LiteralPath $claudeLink) {
        if (Is-OwnedJunction $claudeLink $pluginRoot) { return }
        Write-Warning "Parley: bestehender Claude-Code-Pfad bleibt unverändert: $claudeLink"
        return
    }
    New-Item -ItemType Junction -Path $claudeLink -Target $pluginRoot | Out-Null
}

function Remove-Claude {
    if (Is-OwnedJunction $claudeLink $pluginRoot) { Remove-Item -LiteralPath $claudeLink -Force }
}

$marketRoot = if ($env:PARLEY_CODEX_MARKETPLACE) { $env:PARLEY_CODEX_MARKETPLACE } else { Join-Path $env:USERPROFILE '.parley\codex-marketplace' }
$marketName = 'parley-local'
$marketPlugin = Join-Path $marketRoot 'plugin'
$marketFile = Join-Path $marketRoot '.agents\plugins\marketplace.json'

function Ensure-CodexMarketplace {
    New-Item -ItemType Directory -Force -Path (Split-Path $marketFile) | Out-Null
    if (Test-Path -LiteralPath $marketPlugin) {
        if (-not (Is-OwnedJunction $marketPlugin $pluginRoot)) {
            Write-Warning "Parley: bestehender Codex-Marketplace-Pfad bleibt unverändert: $marketPlugin"
            return $false
        }
    } else {
        New-Item -ItemType Junction -Path $marketPlugin -Target $pluginRoot | Out-Null
    }
    $market = @{
        name = $marketName
        interface = @{ displayName = 'Parley' }
        plugins = @(@{
            name = 'parley'
            source = @{ source = 'local'; path = './plugin' }
            policy = @{ installation = 'AVAILABLE'; authentication = 'ON_INSTALL' }
            category = 'Productivity'
        })
    }
    $market | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 -Path $marketFile
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -eq $codex) { return $false }
    $existing = (& $codex.Source plugin marketplace list --json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue)
    $marketRootReal = (Resolve-Path -LiteralPath $marketRoot).Path
    $known = @($existing.marketplaces | Where-Object { $_.root -eq $marketRootReal }).Count -gt 0
    if (-not $known) { & $codex.Source plugin marketplace add $marketRoot --json 2>$null | Out-Null }
    return $true
}

function Install-Codex {
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -eq $codex) { Write-Warning 'Parley: Codex ist aktiviert, aber nicht im PATH.'; return }
    if (-not (Ensure-CodexMarketplace)) { return }
    & $codex.Source plugin remove "parley@$marketName" --json 2>$null | Out-Null
    & $codex.Source plugin add "parley@$marketName" --json 2>$null | Out-Null
}

function Remove-Codex {
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -ne $codex) { & $codex.Source plugin remove "parley@$marketName" --json 2>$null | Out-Null }
}

if ($enabledClaude -eq '1' -and $detectedClaude -eq '1') { Install-Claude }
elseif ($enabledClaude -eq '0') { Remove-Claude }
if ($enabledCodex -eq '1' -and $detectedCodex -eq '1') { Install-Codex }
elseif ($enabledCodex -eq '0') { Remove-Codex }
