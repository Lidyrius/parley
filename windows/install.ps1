# Parley one-command installer / updater for Windows.
#   irm https://raw.githubusercontent.com/Lidyrius/parley/main/windows/install.ps1 | iex
# Downloads the prebuilt app, detects Claude Code/Codex, installs the selected client
# integrations, and starts the tray app.
$ErrorActionPreference = 'Stop'

$Repo = 'Lidyrius/parley'
$AppDir = Join-Path $env:LOCALAPPDATA 'Parley'
$SrcDir = Join-Path $env:USERPROFILE '.parley\src'
$CredDir = Join-Path $env:APPDATA 'Parley'
$Creds = Join-Path $CredDir 'credentials.json'

function Info($m) { Write-Host "> $m" -ForegroundColor Magenta }

$isUpdate = $false
if (Test-Path $Creds) {
    try { $isUpdate = ((Get-Content -Raw $Creds | ConvertFrom-Json).onboarded -eq '1') } catch { }
}
if ($isUpdate) { Info 'Parley ist bereits eingerichtet — führe Update aus (Einstellungen bleiben).' }

# 1. Source (plugin + scripts) — clone or update.
if (Test-Path (Join-Path $SrcDir '.git')) {
    Info 'Aktualisiere Parley-Quellen'
    git -C $SrcDir pull --ff-only 2>$null | Out-Null
} else {
    Info "Hole Parley nach $SrcDir"
    New-Item -ItemType Directory -Force -Path (Split-Path $SrcDir) | Out-Null
    git clone --depth 1 "https://github.com/$Repo" $SrcDir | Out-Null
}

# 2. Prebuilt app from the latest win-v* release.
Info 'Lade Parley.exe (aktuelles Windows-Release)'
$zip = Join-Path $env:TEMP 'Parley-win-x64.zip'
$rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases" |
    Where-Object { $_.tag_name -like 'win-v*' } | Select-Object -First 1
if (-not $rel) { throw 'Kein Windows-Release gefunden.' }
$asset = $rel.assets | Where-Object name -eq 'Parley-win-x64.zip' | Select-Object -First 1
Invoke-WebRequest $asset.browser_download_url -OutFile $zip
Get-Process Parley -ErrorAction SilentlyContinue | Stop-Process -Force
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
Expand-Archive -Path $zip -DestinationPath $AppDir -Force
Remove-Item $zip -Force

# 3. Detect clients in the installer environment and persist non-secret context for the
#    visual onboarding. Existing enabled choices are kept on updates.
$detectedClaude = if (Get-Command claude -ErrorAction SilentlyContinue) { '1' } else { '0' }
$detectedCodex = if (Get-Command codex -ErrorAction SilentlyContinue) { '1' } else { '0' }
New-Item -ItemType Directory -Force -Path $CredDir | Out-Null
$context = if (Test-Path $Creds) { try { Get-Content -Raw $Creds | ConvertFrom-Json } catch { [pscustomobject]@{} } } else { [pscustomobject]@{} }
$context | Add-Member -NotePropertyName detectedClaudeCode -NotePropertyValue $detectedClaude -Force
$context | Add-Member -NotePropertyName detectedCodex -NotePropertyValue $detectedCodex -Force
$context | Add-Member -NotePropertyName sourceDir -NotePropertyValue $SrcDir -Force
$context | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 -Path $Creds

Info 'Prüfe Claude-Code- und Codex-Integration'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $SrcDir 'windows\sync-integrations.ps1')

# 4. jq for the Git Bash hook (perl+curl ship with Git for Windows).
$binDir = Join-Path $env:USERPROFILE 'bin'
if (-not (Get-Command jq -ErrorAction SilentlyContinue) -and -not (Test-Path (Join-Path $binDir 'jq.exe'))) {
    Info 'Installiere jq (fuer den Git-Bash-Hook)'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    Invoke-WebRequest 'https://github.com/jqlang/jq/releases/latest/download/jq-windows-amd64.exe' `
        -OutFile (Join-Path $binDir 'jq.exe')
}

# 5. No CLI onboarding — the app opens its own setup window. It also applies any
#    client selection changed there through sync-integrations.ps1.

# 6. Autostart + launch.
Info 'Starte Parley'
$startup = [Environment]::GetFolderPath('Startup')
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut((Join-Path $startup 'Parley.lnk'))
$sc.TargetPath = Join-Path $AppDir 'Parley.exe'
$sc.Save()
Start-Process (Join-Path $AppDir 'Parley.exe')

Write-Host ''
Write-Host 'Parley installiert.' -ForegroundColor Green
Write-Host 'Das Einrichtungsfenster oeffnet sich automatisch. Danach eine neue Sitzung starten.'
if ($detectedClaude -eq '1') { Write-Host 'Claude Code: /parley:voice' }
if ($detectedCodex -eq '1') { Write-Host 'Codex: $parley-voice' }
if ($detectedClaude -eq '0' -and $detectedCodex -eq '0') { Write-Host 'Kein Client erkannt — offizielle Installationslinks stehen im Setup.' }
Write-Host ''
Write-Host 'Nutzt du Claude Code in WSL? Dann dort einmalig ausfuehren:'
Write-Host "  mkdir -p ~/.claude/skills && ln -sfn /mnt/c/Users/$env:USERNAME/.parley/src/plugin ~/.claude/skills/parley && sudo apt-get install -y jq"
