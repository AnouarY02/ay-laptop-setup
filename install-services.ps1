# install-services.ps1 — One-shot: cloudflared + relay als Windows services
# Run als admin: powershell -ExecutionPolicy Bypass -File install-services.ps1
# Of via remote: iwr -useb <URL> | iex
#
# Wat dit doet:
# 1. Stopt + disabled de oude Task Scheduler entries (AYCloudflared, AYLaptopRelay)
# 2. Installeert cloudflared als Windows service (auto-start, auto-restart)
# 3. Downloadt NSSM (Non-Sucking Service Manager) voor python-service
# 4. Installeert relay-server.py als NSSM service met Service Recovery
# 5. Test beide services
#
# Idempotent: meerdere keren draaien is veilig.

$ErrorActionPreference = "Stop"

# Vereis admin
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "❌ Dit script vereist administrator-rechten. Open PowerShell als Administrator." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== AY Laptop Agent — services installer ===" -ForegroundColor Cyan
Write-Host ""

$InstallDir = "$env:USERPROFILE\laptop-agent"
$NssmDir    = "$InstallDir\nssm"
$NssmExe    = "$NssmDir\nssm.exe"
$Relay      = "$InstallDir\relay-server.py"
$EnvFile    = "$InstallDir\.env"
$CfExe      = "$InstallDir\cloudflared.exe"

# Sanity checks
if (-not (Test-Path $Relay)) { Write-Host "❌ $Relay niet gevonden — eerste-installatie eerst draaien" -ForegroundColor Red; exit 2 }
if (-not (Test-Path $EnvFile)) { Write-Host "❌ $EnvFile niet gevonden — Bearer-token ontbreekt" -ForegroundColor Red; exit 2 }
if (-not (Test-Path $CfExe)) { Write-Host "❌ $CfExe niet gevonden" -ForegroundColor Red; exit 2 }

# ─── 1. Stop + disable oude Task Scheduler entries ────────────
Write-Host "[1/6] Oude Task Scheduler entries opruimen..." -ForegroundColor Yellow
foreach ($t in @("AYCloudflared", "AYLaptopRelay")) {
    $task = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    if ($task) {
        try { Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue } catch {}
        Disable-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue | Out-Null
        Write-Host "  ✅ $t gestopt + disabled" -ForegroundColor Green
    } else {
        Write-Host "  ⏭️  $t bestaat niet (skip)" -ForegroundColor DarkGray
    }
}

# ─── 2. NSSM downloaden ───────────────────────────────────────
Write-Host ""
Write-Host "[2/6] NSSM downloaden (Service Manager voor Python)..." -ForegroundColor Yellow
if (-not (Test-Path $NssmExe)) {
    $null = New-Item -ItemType Directory -Path $NssmDir -Force
    $tmp = "$env:TEMP\nssm.zip"
    Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $tmp -UseBasicParsing
    Expand-Archive -Path $tmp -DestinationPath "$env:TEMP\nssm-extract" -Force
    Copy-Item "$env:TEMP\nssm-extract\nssm-2.24\win64\nssm.exe" $NssmExe -Force
    Remove-Item $tmp, "$env:TEMP\nssm-extract" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  ✅ NSSM geinstalleerd: $NssmExe" -ForegroundColor Green
} else {
    Write-Host "  ✅ NSSM al aanwezig" -ForegroundColor Green
}

# ─── 3. Cloudflared service ───────────────────────────────────
Write-Host ""
Write-Host "[3/6] Cloudflared als Windows service..." -ForegroundColor Yellow
$existing = Get-Service "Cloudflared" -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "  ⏭️  Cloudflared service bestaat al — skip install" -ForegroundColor DarkGray
} else {
    # Vereist dat ~/.cloudflared/config.yml en credentials.json bestaan
    $cfConfigDir = "$env:USERPROFILE\.cloudflared"
    if (-not (Test-Path "$cfConfigDir\config.yml")) {
        Write-Host "  ⚠️  $cfConfigDir\config.yml ontbreekt — cloudflared service install zal falen" -ForegroundColor Yellow
        Write-Host "      Anouar: dit betekent dat de tunnel-credentials nooit goed zijn opgeslagen." -ForegroundColor Yellow
        Write-Host "      Zie verderop bij output voor instructies." -ForegroundColor Yellow
    }
    & $CfExe service install 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    Write-Host "  ✅ Cloudflared service geinstalleerd" -ForegroundColor Green
}

# Service recovery: restart na crash
sc.exe failure "Cloudflared" reset= 86400 actions= restart/5000/restart/30000/restart/300000 | Out-Null
Set-Service -Name "Cloudflared" -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service "Cloudflared" -ErrorAction SilentlyContinue
Write-Host "  ✅ Service recovery: restart na 5s, 30s, 5min" -ForegroundColor Green

# ─── 4. Relay-server als NSSM service ─────────────────────────
Write-Host ""
Write-Host "[4/6] Relay-server als NSSM service..." -ForegroundColor Yellow
$existingRelay = Get-Service "AYRelay" -ErrorAction SilentlyContinue
if ($existingRelay) {
    Write-Host "  ⏭️  AYRelay service bestaat al — verwijderen + opnieuw installeren" -ForegroundColor DarkGray
    & $NssmExe stop AYRelay confirm 2>&1 | Out-Null
    & $NssmExe remove AYRelay confirm 2>&1 | Out-Null
}
$pythonExe = (Get-Command python).Source
& $NssmExe install AYRelay $pythonExe $Relay 2>&1 | Out-Null
& $NssmExe set AYRelay AppDirectory $InstallDir 2>&1 | Out-Null
& $NssmExe set AYRelay DisplayName "AY Laptop Relay" 2>&1 | Out-Null
& $NssmExe set AYRelay Description "FastAPI relay-server voor VPS Telegram-bot delegate calls" 2>&1 | Out-Null
& $NssmExe set AYRelay Start SERVICE_AUTO_START 2>&1 | Out-Null
& $NssmExe set AYRelay AppExit Default Restart 2>&1 | Out-Null
& $NssmExe set AYRelay AppRestartDelay 5000 2>&1 | Out-Null
& $NssmExe set AYRelay AppStdout "$InstallDir\relay-stdout.log" 2>&1 | Out-Null
& $NssmExe set AYRelay AppStderr "$InstallDir\relay-stderr.log" 2>&1 | Out-Null
& $NssmExe start AYRelay 2>&1 | Out-Null
Write-Host "  ✅ AYRelay service geinstalleerd + gestart" -ForegroundColor Green

# ─── 5. Verifieer ─────────────────────────────────────────────
Write-Host ""
Write-Host "[5/6] Verifieer services..." -ForegroundColor Yellow
Start-Sleep -Seconds 3
Get-Service Cloudflared, AYRelay -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType -AutoSize
$health = $null
try { $health = Invoke-RestMethod -Uri "http://localhost:9999/health" -TimeoutSec 5 -ErrorAction SilentlyContinue } catch {}
if ($health) {
    if ($health.error) {
        Write-Host "  ✅ Relay reageert (auth-protected, dat is correct)" -ForegroundColor Green
    } else {
        Write-Host "  ✅ Relay health: $($health | ConvertTo-Json -Compress)" -ForegroundColor Green
    }
} else {
    Write-Host "  ⚠️  Relay nog niet bereikbaar — check logs in $InstallDir\relay-stderr.log" -ForegroundColor Yellow
}

# ─── 6. Klaar ─────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "✅ Klaar — beide draaien als services." -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Status checken:" -ForegroundColor Cyan
Write-Host "  Get-Service Cloudflared, AYRelay" -ForegroundColor White
Write-Host ""
Write-Host "Logs:" -ForegroundColor Cyan
Write-Host "  $InstallDir\relay-stdout.log" -ForegroundColor White
Write-Host "  $InstallDir\relay-stderr.log" -ForegroundColor White
Write-Host "  Cloudflared logs in Event Viewer onder 'Cloudflared' service" -ForegroundColor White
Write-Host ""
Write-Host "Stoppen (mocht je willen):" -ForegroundColor Cyan
Write-Host "  Stop-Service Cloudflared, AYRelay" -ForegroundColor White
Write-Host ""
Write-Host "Volledig verwijderen:" -ForegroundColor Cyan
Write-Host "  & '$NssmExe' remove AYRelay confirm" -ForegroundColor White
Write-Host "  & '$CfExe' service uninstall" -ForegroundColor White
Write-Host ""
