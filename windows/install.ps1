# Parley one-command installer / updater for Windows.
#   irm https://raw.githubusercontent.com/Lidyrius/parley/main/windows/install.ps1 | iex
# Downloads the prebuilt app, installs the Claude Code plugin (native Git Bash and/or
# WSL), collects API keys if not yet configured, and starts the tray app.
$ErrorActionPreference = 'Stop'

$Repo = 'Lidyrius/parley'
$AppDir = Join-Path $env:LOCALAPPDATA 'Parley'
$SrcDir = Join-Path $env:USERPROFILE '.parley\src'
$CredDir = Join-Path $env:APPDATA 'Parley'
$Creds = Join-Path $CredDir 'credentials.json'

function Info($m) { Write-Host "> $m" -ForegroundColor Magenta }

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

# 3. Claude Code plugin → %USERPROFILE%\.claude\skills\parley (junction; covers native
#    Git Bash). For WSL, link from within WSL (printed below).
Info 'Installiere Claude-Code-Plugin'
$skills = Join-Path $env:USERPROFILE '.claude\skills'
New-Item -ItemType Directory -Force -Path $skills | Out-Null
$link = Join-Path $skills 'parley'
if (Test-Path $link) { Remove-Item $link -Force -Recurse -ErrorAction SilentlyContinue }
New-Item -ItemType Junction -Path $link -Target (Join-Path $SrcDir 'plugin') | Out-Null

# 4. jq for the Git Bash hook (perl+curl ship with Git for Windows).
$binDir = Join-Path $env:USERPROFILE 'bin'
if (-not (Get-Command jq -ErrorAction SilentlyContinue) -and -not (Test-Path (Join-Path $binDir 'jq.exe'))) {
    Info 'Installiere jq (fuer den Git-Bash-Hook)'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    Invoke-WebRequest 'https://github.com/jqlang/jq/releases/latest/download/jq-windows-amd64.exe' `
        -OutFile (Join-Path $binDir 'jq.exe')
}

# 5. Credentials — ask only if not configured yet (re-run = update, everything kept).
if (-not (Test-Path $Creds) -or -not ((Get-Content $Creds -Raw | ConvertFrom-Json).googleAPIKey)) {
    Info 'Einrichtung: API-Keys (beide praktisch kostenlos)'
    Write-Host '  Google Cloud TTS: console.cloud.google.com -> Cloud Text-to-Speech API aktivieren -> API-Key (1 Mio Zeichen/Monat gratis)'
    Write-Host '  Groq: console.groq.com -> API Keys (kostenloser Developer-Key)'
    $g = Read-Host 'Google TTS API-Key'
    $q = Read-Host 'Groq API-Key'
    $lang = Read-Host 'Sprache [Deutsch]'
    if (-not $lang) { $lang = 'Deutsch' }
    $code = @{ Deutsch='de-DE'; English='en-US'; 'Français'='fr-FR'; 'Español'='es-ES'; Italiano='it-IT'; Nederlands='nl-NL' }[$lang]
    if (-not $code) { $code = 'de-DE' }
    New-Item -ItemType Directory -Force -Path $CredDir | Out-Null
    @{ googleAPIKey=$g; groqAPIKey=$q; language=$lang; googleVoice="$code-Chirp3-HD-Alnilam" } |
        ConvertTo-Json | Set-Content -Path $Creds -Encoding UTF8
}

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
Write-Host 'Neue Claude-Code-Sitzung starten und /parley:voice tippen.'
Write-Host ''
Write-Host 'Nutzt du Claude Code in WSL? Dann dort einmalig ausfuehren:'
Write-Host '  mkdir -p ~/.claude/skills && ln -sfn /mnt/c/Users/'$env:USERNAME'/.parley/src/plugin ~/.claude/skills/parley && sudo apt-get install -y jq'
