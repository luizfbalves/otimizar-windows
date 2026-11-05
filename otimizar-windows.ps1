<#
.SYNOPSIS
  Limpeza e otimizacao do Windows 11 (temps, caches, bloatware, startup, registro orfao).

.DESCRIPTION
  Cada etapa pergunta antes de rodar (s/n). Use -Yes para rodar tudo sem perguntar,
  -Only/-Skip para escolher etapas e -DryRun para so medir sem apagar nada.
  Pede admin sozinho. Gera log em Documentos\otimizar-windows-<data>.log

  Etapas:
    Temp        Temporarios do usuario/Windows (>2 dias), CrashDumps, WER, Lixeira
    DevCaches   npm, pip, pnpm, yarn, uv, Docker build cache + imagens soltas
    GpuCache    Cache de shaders NVIDIA/AMD/DirectX (jogos recompilam na 1a vez)
    HuggingFace Modelos/datasets/token em ~/.cache/huggingface
    Cursor      Caches, versoes antigas do agente, projetos inexistentes, chats antigos
    Registry    Entradas de "Programas instalados" apontando p/ pastas que nao existem
    Bloatware   Remove apps da Store (Bing, Solitaire, Widgets, Teams, Outlook novo, Phone Link...)
    Copilot     Desinstala o app Copilot
    Policies    Bloqueia reinstalacao de bloat, sugestoes/anuncios, Widgets, Copilot
    Services    Desativa MapsBroker e Localizacao (lfsvc)
    Startup     Desativa tarefas de telemetria do Edge/SoftLanding e autostart do Docker
    Report      Lista o que inicia com o Windows e programas instalados (so leitura)

.EXAMPLE
  # direto da internet (PowerShell):
  irm https://raw.githubusercontent.com/luizfbalves/otimizar-windows/main/otimizar-windows.ps1 | iex
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/luizfbalves/otimizar-windows/main/otimizar-windows.ps1))) -DryRun

.EXAMPLE
  .\otimizar-windows.ps1                 # interativo
  .\otimizar-windows.ps1 -DryRun         # so mostra tamanhos
  .\otimizar-windows.ps1 -Yes -Skip Cursor,Services
  .\otimizar-windows.ps1 -Only Temp,DevCaches -Yes
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$DryRun,
    [string[]]$Only,
    [string[]]$Skip,
    [int]$CursorKeepDays = 30
)

$ErrorActionPreference = 'Continue'

# ---------- elevacao ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $self = $PSCommandPath
    if (-not $self) {
        # executado via irm | iex ou scriptblock: baixa uma copia local para relancar como admin
        $self = Join-Path $env:TEMP 'otimizar-windows.ps1'
        Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/luizfbalves/otimizar-windows/main/otimizar-windows.ps1' -OutFile $self
    }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$self`"")
    if ($Yes)    { $argList += '-Yes' }
    if ($DryRun) { $argList += '-DryRun' }
    if ($Only)   { $argList += '-Only'; $argList += ($Only -join ',') }
    if ($Skip)   { $argList += '-Skip'; $argList += ($Skip -join ',') }
    $argList += '-CursorKeepDays'; $argList += $CursorKeepDays
    $exe = (Get-Process -Id $PID).Path
    Start-Process $exe -Verb RunAs -ArgumentList $argList
    return
}

$stamp  = Get-Date -Format 'yyyy-MM-dd_HHmm'
$docs   = [Environment]::GetFolderPath('MyDocuments')
$backup = Join-Path $docs "otimizar-windows-backup-$stamp"
Start-Transcript -Path (Join-Path $docs "otimizar-windows-$stamp.log") -Force | Out-Null
$freeStart = (Get-PSDrive C).Free

# ---------- helpers ----------
function Title($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Info($t)  { Write-Host "  $t" }
function Done($t)  { Write-Host "  [ok] $t" -ForegroundColor Green }
function Warn($t)  { Write-Host "  [!] $t" -ForegroundColor Yellow }

function Want($step, $desc) {
    if ($Only -and ($Only -notcontains $step)) { return $false }
    if ($Skip -and ($Skip -contains $step))    { return $false }
    Title "$step - $desc"
    if ($Yes -or $DryRun) { return $true }
    $r = Read-Host '  Executar? (s/n)'
    return ($r -match '^(s|y)')
}

function SizeGB($path) {
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    $s = (Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    return [math]::Round(($s / 1GB), 2)
}

function Clear-Folder($path, [int]$olderThanDays = 0) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $gb = SizeGB $path
    if ($DryRun) { Info ("{0,7:N2} GB  {1}" -f $gb, $path); return }
    $cut = (Get-Date).AddDays(-$olderThanDays)
    Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue |
        Where-Object { $olderThanDays -eq 0 -or $_.LastWriteTime -lt $cut } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    Done ("{0,7:N2} GB antes  {1}" -f $gb, $path)
}

function Remove-Folder($path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $gb = SizeGB $path
    if ($DryRun) { Info ("{0,7:N2} GB  {1}" -f $gb, $path); return }
    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    Done ("{0,7:N2} GB  removido {1}" -f $gb, $path)
}

function Has($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

function Set-Reg($key, $name, $value, $type = 'DWord') {
    if ($DryRun) { Info "$key\$name = $value"; return }
    if (-not (Test-Path $key)) { New-Item $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name $name -Value $value -Type $type -ErrorAction SilentlyContinue
}

$uninstallKeys = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

if ($DryRun) { Warn 'MODO DRY-RUN: nada sera apagado ou alterado.' }

# ---------- 1. Temp ----------
if (Want 'Temp' 'Arquivos temporarios, dumps de crash, relatorios de erro, Lixeira') {
    Clear-Folder $env:TEMP 2
    Clear-Folder "$env:SystemRoot\Temp" 2
    Clear-Folder "$env:LOCALAPPDATA\CrashDumps"
    Clear-Folder "$env:ProgramData\Microsoft\Windows\WER\ReportArchive"
    Clear-Folder "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
    Clear-Folder "$env:LOCALAPPDATA\Microsoft\Windows\WER"
    if (-not $DryRun) {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Done 'Lixeira esvaziada'
    }
}

# ---------- 2. DevCaches ----------
if (Want 'DevCaches' 'Caches de npm, pip, pnpm, yarn, uv e Docker (tudo e rebaixado sob demanda)') {
    if ($DryRun) {
        Clear-Folder "$env:LOCALAPPDATA\npm-cache"
        Clear-Folder "$env:LOCALAPPDATA\pip\Cache"
        Clear-Folder "$env:LOCALAPPDATA\pnpm\store"
        Clear-Folder "$env:LOCALAPPDATA\pnpm-cache"
        Clear-Folder "$env:LOCALAPPDATA\Yarn\Cache"
        Clear-Folder "$env:LOCALAPPDATA\uv\cache"
        if (Has docker) { docker system df 2>$null }
    } else {
        if (Has npm)  { npm cache clean --force 2>&1 | Out-Null; Done 'npm cache' }
        if (Has pip)  { pip cache purge 2>&1 | Select-Object -Last 1 | ForEach-Object { Done "pip: $_" } }
        elseif (Has py) { py -m pip cache purge 2>&1 | Select-Object -Last 1 | ForEach-Object { Done "pip: $_" } }
        if (Has pnpm) { pnpm store prune 2>&1 | Select-Object -Last 1 | ForEach-Object { Done "pnpm: $_" } }
        Clear-Folder "$env:LOCALAPPDATA\pnpm-cache"
        if (Has yarn) { yarn cache clean 2>&1 | Out-Null; Done 'yarn cache' }
        if (Has uv)   { uv cache prune 2>&1 | Select-Object -Last 1 | ForEach-Object { Done "uv: $_" } }
        if (Has docker) {
            docker info 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                docker builder prune -af 2>&1 | Select-Object -Last 1 | ForEach-Object { Done "docker build cache: $_" }
                docker image prune -f 2>&1 | Select-Object -Last 1 | ForEach-Object { Done "docker imagens soltas: $_" }
            } else { Warn 'Docker instalado mas nao esta rodando - pulei o prune' }
        }
    }
}

# ---------- 3. GpuCache ----------
if (Want 'GpuCache' 'Cache de shaders da GPU (jogos podem engasgar na 1a abertura)') {
    Clear-Folder "$env:LOCALAPPDATA\NVIDIA\DXCache"
    Clear-Folder "$env:LOCALAPPDATA\NVIDIA\GLCache"
    Clear-Folder "$env:LOCALAPPDATA\NVIDIA\OptixCache"
    Clear-Folder "$env:ProgramData\NVIDIA Corporation\NV_Cache"
    Clear-Folder "$env:LOCALAPPDATA\AMD\DxCache"
    Clear-Folder "$env:LOCALAPPDATA\AMD\DxcCache"
    Clear-Folder "$env:LOCALAPPDATA\AMD\GLCache"
    Clear-Folder "$env:LOCALAPPDATA\AMD\VkCache"
    Clear-Folder "$env:LOCALAPPDATA\D3DSCache"
}

# ---------- 4. HuggingFace ----------
if (Want 'HuggingFace' 'Apaga modelos/datasets/token do HuggingFace') {
    $hf = if ($env:HF_HOME) { $env:HF_HOME } else { "$env:USERPROFILE\.cache\huggingface" }
    Remove-Folder $hf
    Remove-Folder "$env:USERPROFILE\.huggingface"
}

# ---------- 5. Cursor ----------
$cursorDir = "$env:APPDATA\Cursor"
if ((Test-Path $cursorDir) -and (Want 'Cursor' "Caches do Cursor + chats com mais de $CursorKeepDays dias (com backup)")) {
    if (Get-Process Cursor -ErrorAction SilentlyContinue) {
        Warn 'Feche o Cursor antes. Pulando esta etapa.'
    } else {
        foreach ($d in 'CachedData','Cache','Code Cache','GPUCache','DawnGraphiteCache','DawnWebGPUCache','logs','Crashpad','CachedExtensionVSIXs','CachedProfilesData','Service Worker\CacheStorage','Service Worker\ScriptCache') {
            Remove-Folder (Join-Path $cursorDir $d)
        }
        # versoes antigas do cursor-agent (mantem a mais nova)
        $ver = "$cursorDir\User\globalStorage\anysphere.cursor-agent-worker\agent-cli\.local\share\cursor-agent\versions"
        if (Test-Path $ver) {
            Get-ChildItem $ver -Directory | Sort-Object Name -Descending | Select-Object -Skip 1 | ForEach-Object { Remove-Folder $_.FullName }
        }
        # workspaceStorage de pastas locais que nao existem mais
        $ws = "$cursorDir\User\workspaceStorage"
        if (Test-Path $ws) {
            $n = 0
            Get-ChildItem $ws -Directory | ForEach-Object {
                $j = Get-Content "$($_.FullName)\workspace.json" -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                $uri = if ($j.folder) { $j.folder } elseif ($j.workspace) { $j.workspace } else { $null }
                if ($uri -and $uri -match '^file:///') {
                    $p = [uri]::UnescapeDataString(($uri -replace '^file:///', '')) -replace '/', '\'
                    if (-not (Test-Path -LiteralPath $p)) {
                        $n++
                        if (-not $DryRun) { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
                    }
                }
            }
            Done "$n projetos inexistentes no workspaceStorage"
        }
        # chats antigos (state.vscdb) - precisa de Python
        $db = "$cursorDir\User\globalStorage\state.vscdb"
        $pyExe = $null
        foreach ($c in @('py','python','python3')) {
            $cmd = Get-Command $c -ErrorAction SilentlyContinue
            if ($cmd) { & $cmd.Source -c "import sqlite3" 2>$null; if ($LASTEXITCODE -eq 0) { $pyExe = $cmd.Source; break } }
        }
        if (-not (Test-Path $db)) { }
        elseif (-not $pyExe) { Warn 'Python nao encontrado - pulei a limpeza de chats antigos' }
        else {
            $gc = @'
import sqlite3, re, json, time, sys, base64
DB, DAYS, DRY = sys.argv[1], int(sys.argv[2]), sys.argv[3] == '1'
db = sqlite3.connect(DB); now = time.time() * 1000
comp = {}
for k, v in db.execute("select key, value from cursorDiskKV where key like 'composerData:%'"):
    try:
        j = json.loads(v); comp[k.split(':', 1)[1]] = j.get('lastUpdatedAt') or j.get('createdAt') or 0
    except Exception:
        comp[k.split(':', 1)[1]] = now
keep = {c for c, t in comp.items() if t and (now - t) / 86400000 < DAYS}
drop = set(comp) - keep
dele = [k for (k,) in db.execute("select key from cursorDiskKV where key not like 'agentKv:%'")
        if len(k.split(':')) > 1 and k.split(':')[1] in drop]
dset = set(dele)
blobs = {k[13:] for (k,) in db.execute("select key from cursorDiskKV where key like 'agentKv:blob:%'")}
hexre = re.compile(rb'[0-9a-f]{64}'); b64re = re.compile(rb'[A-Za-z0-9+/]{44,}={0,2}')
def refs(b):
    out = {h.decode() for h in hexre.findall(b) if h.decode() in blobs}
    i = b.find(b'\x20')
    while i != -1 and i + 33 <= len(b):
        h = b[i+1:i+33].hex()
        if h in blobs: out.add(h)
        i = b.find(b'\x20', i + 1)
    return out
def scan(b):
    out = refs(b)
    for m in b64re.findall(b):
        try: out |= refs(base64.b64decode(m + b'=' * (-len(m) % 4)))
        except Exception: pass
    return out
def asb(v): return v if isinstance(v, bytes) else str(v).encode('utf-8', 'ignore')
roots = set()
for k, v in db.execute("select key, value from cursorDiskKV where key not like 'agentKv:blob:%'"):
    if k not in dset and v is not None: roots |= scan(asb(v))
for k, v in db.execute("select key, value from ItemTable"):
    if v is not None: roots |= scan(asb(v))
seen = set(roots); stack = list(roots)
while stack:
    r = db.execute("select value from cursorDiskKV where key=?", ('agentKv:blob:' + stack.pop(),)).fetchone()
    if r and r[0] is not None:
        for n in scan(asb(r[0])) - seen: seen.add(n); stack.append(n)
dead = [h for h in blobs if h not in seen]
print(f"chats: {len(comp)} manter {len(keep)} apagar {len(drop)} | blobs: {len(blobs)} apagar {len(dead)}")
if DRY: sys.exit()
db.execute("begin")
db.executemany("delete from cursorDiskKV where key=?", [(k,) for k in dele])
db.executemany("delete from cursorDiskKV where key=?", [('agentKv:blob:' + h,) for h in dead])
db.commit(); db.execute("vacuum"); db.close()
r = sqlite3.connect(DB).execute("pragma integrity_check").fetchone()[0]
print("integrity:", r)
'@
            $gcFile = Join-Path $env:TEMP "cursor_gc_$stamp.py"
            Set-Content -Path $gcFile -Value $gc -Encoding ASCII
            $before = SizeGB $db
            if (-not $DryRun) {
                New-Item -ItemType Directory -Force $backup | Out-Null
                Copy-Item $db (Join-Path $backup 'cursor-state.vscdb') -Force
                Remove-Item "$db.backup" -Force -ErrorAction SilentlyContinue
                Info "Backup do banco do Cursor em $backup"
            }
            $pyArgs = @()
            if ((Split-Path $pyExe -Leaf) -eq 'py.exe') { $pyArgs += '-3' }
            & $pyExe @pyArgs -I $gcFile $db $CursorKeepDays $(if ($DryRun) { '1' } else { '0' })
            Remove-Item $gcFile -Force -ErrorAction SilentlyContinue
            Done ("state.vscdb: {0:N2} GB -> {1:N2} GB" -f $before, (SizeGB $db))
        }
    }
}

# ---------- 6. Registry orfao ----------
if (Want 'Registry' 'Remove entradas de programas desinstalados que ficaram no registro (com backup .reg)') {
    $orphans = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | ForEach-Object {
        $loc = ("" + $_.InstallLocation).Trim().Trim('"')
        $un  = "" + $_.UninstallString
        $exe = if ($un -match '^"([^"]+)"') { $matches[1] } elseif ($un -match '^(\S+\.exe)') { $matches[1] } else { $null }
        if ($un -match 'msiexec' -or -not $exe) { return }          # MSI: deixa o Windows Installer cuidar
        $locMissing = $loc -and -not (Test-Path -LiteralPath $loc)
        $exeMissing = -not (Test-Path -LiteralPath $exe)
        if ($exeMissing -and ($locMissing -or -not $loc)) { $_ }
    }
    if (-not $orphans) { Done 'Nenhuma entrada orfa' }
    foreach ($o in $orphans) {
        $regPath = $o.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
        if ($DryRun) { Info "orfao: $($o.DisplayName)  ($regPath)"; continue }
        New-Item -ItemType Directory -Force $backup | Out-Null
        $file = Join-Path $backup (($o.PSChildName -replace '[^\w\.-]', '_') + '.reg')
        reg export "$regPath" "$file" /y | Out-Null
        Remove-Item -LiteralPath $o.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        Done "removido: $($o.DisplayName)"
    }
}

# ---------- 7. Bloatware ----------
$bloat = @(
    'Microsoft.BingNews','Microsoft.BingWeather','Microsoft.BingSports','Microsoft.BingFinance',
    'Microsoft.MicrosoftSolitaireCollection','Microsoft.GetHelp','Microsoft.Getstarted',
    'Microsoft.WindowsFeedbackHub','Microsoft.WindowsMaps','Microsoft.People',
    'microsoft.windowscommunicationsapps','Microsoft.ZuneVideo','Microsoft.Windows.DevHome',
    'Microsoft.MicrosoftOfficeHub','Microsoft.PowerAutomateDesktop','Microsoft.549981C3F5F10',
    'MicrosoftWindows.Client.WebExperience','Microsoft.WidgetsPlatformRuntime','Microsoft.StartExperiencesApp',
    'MSTeams','MicrosoftTeams','Microsoft.OutlookForWindows','Clipchamp.Clipchamp','Microsoft.Todos',
    'Microsoft.YourPhone','MicrosoftWindows.CrossDevice','Microsoft.Copilot','Microsoft.Windows.Ai.Copilot.Provider',
    'Microsoft.MixedReality.Portal','Microsoft.SkypeApp','Microsoft.Microsoft3DViewer','Microsoft.Print3D',
    'Microsoft.MicrosoftJournal','Microsoft.Office.OneNote','MicrosoftCorporationII.MicrosoftFamily',
    'king.com.CandyCrushSaga','king.com.CandyCrushSodaSaga','Disney.37853FC22B2CE','Facebook.Facebook',
    'BytedancePte.Ltd.TikTok','AmazonVideo.PrimeVideo','Microsoft.LinkedIn'
)
if (Want 'Bloatware' 'Remove apps da Store pre-instalados (Bing, Paciencia, Widgets, Teams, Outlook novo, Phone Link...)') {
    Info 'Mantidos: Xbox/Gaming, Fotos, Calculadora, Bloco de Notas, Captura, Camera, Media Player, Store, Terminal'
    Get-Process PhoneExperienceHost,CrossDeviceService,CrossDeviceResume,WidgetBoard,WidgetService,MicrosoftStartFeedProvider,ms-teams,olk -ErrorAction SilentlyContinue |
        ForEach-Object { if (-not $DryRun) { Stop-Process $_ -Force -ErrorAction SilentlyContinue } }
    foreach ($n in $bloat) {
        $pkgs = Get-AppxPackage -AllUsers -Name $n -ErrorAction SilentlyContinue
        foreach ($p in $pkgs) {
            if ($DryRun) { Info "removeria: $($p.Name)"; continue }
            try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop; Done "removido: $($p.Name)" }
            catch {
                try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop; Done "removido (usuario): $($p.Name)" }
                catch { Warn "falhou: $($p.Name)" }
            }
        }
    }
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $bloat -contains $_.DisplayName } | ForEach-Object {
        if ($DryRun) { Info "desprovisionaria: $($_.DisplayName)"; return }
        Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
        Done "desprovisionado: $($_.DisplayName)"
    }
}

# ---------- 8. Copilot ----------
if (Want 'Copilot' 'Desinstala o app Copilot (versao Edge/win32)') {
    $cp = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'Copilot' -or $_.PSChildName -eq 'Microsoft Copilot' }
    if (-not $cp) { Done 'Copilot nao instalado' }
    foreach ($c in $cp) {
        if ($c.UninstallString -match '^"([^"]+)"\s*(.*)$') {
            $exe = $matches[1]; $args2 = $matches[2] + ' --force-uninstall'
            if ($DryRun) { Info "desinstalaria: $exe $args2"; continue }
            if (Test-Path $exe) { Start-Process $exe -ArgumentList $args2 -Wait; Done 'Copilot desinstalado' }
        }
    }
}

# ---------- 9. Policies ----------
if (Want 'Policies' 'Bloqueia reinstalacao de bloat, anuncios/sugestoes, Widgets, Copilot e chat do Teams') {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Communications' 'ConfigureChatAutoInstall' 0
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($n in 'SilentInstalledAppsEnabled','ContentDeliveryAllowed','OemPreInstalledAppsEnabled','PreInstalledAppsEnabled',
                   'PreInstalledAppsEverEnabled','SystemPaneSuggestionsEnabled','SoftLandingEnabled','SubscribedContent-338388Enabled',
                   'SubscribedContent-338389Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled','SubscribedContent-310093Enabled') {
        Set-Reg $cdm $n 0
    }
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
    Done 'Politicas aplicadas (valem apos reiniciar)'
}

# ---------- 10. Services ----------
if (Want 'Services' 'Desativa MapsBroker (mapas offline) e lfsvc (localizacao)') {
    foreach ($svc in 'MapsBroker','lfsvc') {
        if (-not (Get-Service $svc -ErrorAction SilentlyContinue)) { continue }
        if ($DryRun) { Info "desativaria: $svc ($((Get-Service $svc).StartType))"; continue }
        Stop-Service $svc -Force -ErrorAction SilentlyContinue
        Set-Service $svc -StartupType Disabled
        Done "$svc -> Disabled"
    }
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'String'
}

# ---------- 11. Startup ----------
if (Want 'Startup' 'Desativa tarefas de telemetria do Edge/SoftLanding e o autostart do Docker Desktop') {
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.State -ne 'Disabled' -and ($_.TaskName -like 'PlatformExperiencesHelper*' -or $_.TaskPath -like '\SoftLanding\*')
    } | ForEach-Object {
        if ($DryRun) { Info "desativaria: $($_.TaskPath)$($_.TaskName)"; return }
        Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath | Out-Null
        Done "tarefa desativada: $($_.TaskName)"
    }
    $dset = "$env:APPDATA\Docker\settings-store.json"
    if (Test-Path $dset) {
        if ($DryRun) { Info 'desligaria AutoStart do Docker Desktop' }
        else {
            Copy-Item $dset "$dset.bak" -Force
            $j = Get-Content $dset -Raw | ConvertFrom-Json
            $j | Add-Member -NotePropertyName AutoStart -NotePropertyValue $false -Force
            $j | ConvertTo-Json -Depth 20 | Set-Content $dset -Encoding UTF8
            Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'Docker Desktop' -ErrorAction SilentlyContinue
            Done 'Docker Desktop nao inicia mais com o Windows'
        }
    }
}

# ---------- 12. Report ----------
if (Want 'Report' 'Mostra o que ainda inicia com o Windows e os programas instalados (so leitura)') {
    Write-Host "`n  -- Run / pasta Inicializar --" -ForegroundColor DarkCyan
    foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
        $i = Get-Item $k -ErrorAction SilentlyContinue
        if ($i) { $i.GetValueNames() | ForEach-Object { Info "$_ => $($i.GetValue($_))" } }
    }
    Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup","$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup" -ErrorAction SilentlyContinue |
        ForEach-Object { Info "pasta Inicializar: $($_.Name)" }
    Write-Host "`n  -- Servicos automaticos de terceiros --" -ForegroundColor DarkCyan
    Get-CimInstance Win32_Service | Where-Object { $_.StartMode -eq 'Auto' -and $_.PathName -and $_.PathName -notmatch '(?i)\\windows\\' } |
        ForEach-Object { Info ("{0,-28} {1}" -f $_.Name, $_.State) }
    Write-Host "`n  -- Programas instalados (revise e desinstale o que nao usa) --" -ForegroundColor DarkCyan
    Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and $_.DisplayName -notmatch 'Redistributable|Update for|KB\d+' } |
        Sort-Object DisplayName -Unique |
        ForEach-Object { Info ("{0,-60} {1,8} MB" -f $_.DisplayName, [math]::Round($_.EstimatedSize / 1KB)) }
}

# ---------- fim ----------
$freed = ((Get-PSDrive C).Free - $freeStart) / 1GB
Write-Host ("`n=== Concluido. Liberado: {0:N2} GB | Livre no C: {1:N1} GB ===" -f $freed, ((Get-PSDrive C).Free / 1GB)) -ForegroundColor Green
if (Test-Path $backup) { Write-Host "Backups (registro/Cursor) em: $backup" }
Write-Host 'Reinicie o PC para todas as politicas valerem.'
Stop-Transcript | Out-Null
if (-not $Yes) { Read-Host "`nEnter para fechar" | Out-Null }
