#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"
$InformationPreference = "Continue"

$kioskPath = "C:\Kiosk"
$logsPath = "$kioskPath\Logs"
$networkBase = "\\192.168.5.30\sidera\Examenes"

function Get-AlumnoUser {
  $users = Get-LocalUser | Where-Object { $_.Name -match '^Alumno-\d{2}$' }

  if ($users.Count -eq 0) {
    Write-Error "ERROR: No se encontro ningun usuario Alumno-XX"
    exit 1
  }

  if ($users.Count -gt 1) {
    Write-Error "ERROR: Se encontraron multiples usuarios Alumno:"
    $users | ForEach-Object { Write-Information "  - $($_.Name)" }
    exit 1
  }

  return $users[0]
}

function Get-DispositivoNumber {
  param($username)

  if ($username -match 'Alumno-(\d{2})') {
    return $matches[1]
  }

  Write-Error "ERROR: No se pudo extraer numero de dispositivo de $username"
  exit 1
}

function Confirm-Installation {
  param($username,$dispositivo)

  Write-Information ""
  Write-Information "Usuario encontrado: $username"
  Write-Information "Dispositivo: $dispositivo"
  Write-Information ""
  $response = Read-Host "Confirmar instalacion? (Y/N)"

  return $response -eq 'Y'
}

function New-FolderStructure {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  if (!(Test-Path $kioskPath)) {
    New-Item -Path $kioskPath -ItemType Directory -Force | Out-Null
  }

  if (!(Test-Path $logsPath)) {
    New-Item -Path $logsPath -ItemType Directory -Force | Out-Null
  }
}

function Enable-TaskSchedulerHistory {
  try {
    $logStatus = & wevtutil get-log Microsoft-Windows-TaskScheduler/Operational | Select-String "enabled:"

    if ($logStatus -match "enabled:\s*false") {
      & wevtutil set-log Microsoft-Windows-TaskScheduler/Operational /enabled:true /quiet

      $verifyStatus = & wevtutil get-log Microsoft-Windows-TaskScheduler/Operational | Select-String "enabled:"
      if ($verifyStatus -match "enabled:\s*true") {
        return $true
      }
    }
    elseif ($logStatus -match "enabled:\s*true") {
      return $true
    }
  }
  catch {
    Write-Warning "No se pudo habilitar el historial de tareas: $($_.Exception.Message)"
    return $false
  }
  return $false
}

function Get-UserSID {
  param($username)

  $user = New-Object System.Security.Principal.NTAccount ($username)
  return $user.Translate([System.Security.Principal.SecurityIdentifier]).Value
}

function Grant-BatchJobLogonRight {
  param($sid)

  try {
    $tempFile = [System.IO.Path]::GetTempFileName()

    $result = & secedit /export /cfg $tempFile /quiet 2>&1

    if (!(Test-Path $tempFile) -or (Get-Item $tempFile).Length -eq 0) {
      throw "secedit export failed: $result"
    }

    Start-Sleep -Milliseconds 500

    $content = Get-Content $tempFile
    $batchLine = $content | Where-Object { $_ -match '^SeBatchLogonRight' }

    if ($batchLine) {
      if ($batchLine -notmatch [regex]::Escape("*$sid")) {
        $newLine = $batchLine + ",*$sid"
        $content = $content -replace [regex]::Escape($batchLine),$newLine
      }
      else {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        return $true
      }
    }
    else {
      $privilegeSection = $false
      $newContent = @()
      foreach ($line in $content) {
        $newContent += $line
        if ($line -match '^\[Privilege Rights\]') {
          $privilegeSection = $true
          $newContent += "SeBatchLogonRight = *$sid"
        }
      }
      if (-not $privilegeSection) {
        $newContent += ""
        $newContent += "[Privilege Rights]"
        $newContent += "SeBatchLogonRight = *$sid"
      }
      $content = $newContent
    }

    Set-Content -Path $tempFile -Value $content -Force -Encoding Unicode

    $dbFile = Join-Path $env:TEMP "secedit_$([guid]::NewGuid().ToString()).sdb"
    & secedit /configure /db $dbFile /cfg $tempFile /quiet

    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    Remove-Item $dbFile -Force -ErrorAction SilentlyContinue

    return $true
  }
  catch {
    Write-Warning "No se pudo otorgar derecho de batch job: $($_.Exception.Message)"
    return $false
  }
}

function Set-EdgePolicy {
  [CmdletBinding(SupportsShouldProcess)]
  [OutputType([bool])]
  param($username)

  try {
    # Obtener el perfil del usuario
    $userProfile = (Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -like "*\$username" }).LocalPath

    if (-not $userProfile) {
      throw "No se encontro el perfil para $username"
    }

    $ntUserPath = Join-Path $userProfile "NTUSER.DAT"

    if (-not (Test-Path $ntUserPath)) {
      throw "No se encontro NTUSER.DAT en $userProfile"
    }

    # Cargar el hive del usuario
    $hiveName = "HKLM\TempHive_$username"
    & reg load $hiveName $ntUserPath 2>&1 | Out-Null

    # Esperar un momento para que se cargue
    Start-Sleep -Milliseconds 500

    # Configurar las políticas de Edge
    $registryPath = "$hiveName\Software\Policies\Microsoft\Edge"

    if (!(Test-Path "Registry::$registryPath")) {
      New-Item -Path "Registry::$registryPath" -Force | Out-Null
    }

    $policies = @{
      'PrintingEnabled' = 0
      'AllowFileSelectionDialogs' = 0
      'DownloadRestrictions' = 3
      'HideFirstRunExperience' = 1
      'BrowserSignin' = 0
      'SyncDisabled' = 1
      'ContextMenuEnabled' = 0
      'SavingBrowserHistoryDisabled' = 1
      'DiskCacheSize' = 1
      'ClearBrowsingDataOnExit' = 1
      'DefaultCookiesSetting' = 4
      'SitePerProcess' = 0
      'AllowFileAccessFromFiles' = 1
    }

    foreach ($policy in $policies.GetEnumerator()) {
      Set-ItemProperty -Path "Registry::$registryPath" -Name $policy.Key -Value $policy.Value -Type DWord -Force
    }

    Set-ItemProperty -Path "Registry::$registryPath" -Name "NewTabPageLocation" -Value "file:///C:/Kiosk/index.html" -Type String -Force

    # Configure ClearBrowsingDataOnExit to clear cache, cookies, and history
    $clearDataPath = "$registryPath\ClearBrowsingDataOnExitList"
    if (!(Test-Path "Registry::$clearDataPath")) {
      New-Item -Path "Registry::$clearDataPath" -Force | Out-Null
    }
    Set-ItemProperty -Path "Registry::$clearDataPath" -Name "browsing_history" -Value "browsing_history" -Type String -Force
    Set-ItemProperty -Path "Registry::$clearDataPath" -Name "download_history" -Value "download_history" -Type String -Force
    Set-ItemProperty -Path "Registry::$clearDataPath" -Name "cookies_and_other_site_data" -Value "cookies_and_other_site_data" -Type String -Force
    Set-ItemProperty -Path "Registry::$clearDataPath" -Name "cached_images_and_files" -Value "cached_images_and_files" -Type String -Force

    # Descargar el hive
    [gc]::Collect()
    Start-Sleep -Milliseconds 500
    & reg unload $hiveName 2>&1 | Out-Null

    return $true
  }
  catch {
    Write-Warning "Error al configurar politicas de Edge: $($_.Exception.Message)"

    # Intentar descargar el hive si hubo error
    try {
      & reg unload $hiveName 2>&1 | Out-Null
    }
    catch {
      Write-Error "Failed to unload registry hive: $($_.Exception.Message)"
    }

    return $false
  }
}

function Set-SystemRestriction {
  [CmdletBinding(SupportsShouldProcess)]
  [OutputType([bool])]
  param($username)

  try {
    # Obtener el perfil del usuario
    $userProfile = (Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -like "*\$username" }).LocalPath

    if (-not $userProfile) {
      throw "No se encontro el perfil para $username"
    }

    $ntUserPath = Join-Path $userProfile "NTUSER.DAT"

    if (-not (Test-Path $ntUserPath)) {
      throw "No se encontro NTUSER.DAT para $username"
    }

    # Cargar el hive del usuario
    $hiveName = "HKLM\TempHive_$username"
    & reg load $hiveName $ntUserPath 2>&1 | Out-Null

    Start-Sleep -Milliseconds 500

    # Configurar restricciones de Explorer
    $explorerPath = "Registry::$hiveName\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    if (!(Test-Path $explorerPath)) {
      New-Item -Path $explorerPath -Force | Out-Null
    }
    Set-ItemProperty -Path $explorerPath -Name "NoRun" -Value 1 -Type DWord -Force

    # Configurar restricciones de System
    $systemPath = "Registry::$hiveName\Software\Policies\Microsoft\Windows\System"
    if (!(Test-Path $systemPath)) {
      New-Item -Path $systemPath -Force | Out-Null
    }
    Set-ItemProperty -Path $systemPath -Name "DisableCMD" -Value 1 -Type DWord -Force

    # Configurar restricciones de Task Manager
    $policiesSystemPath = "Registry::$hiveName\Software\Microsoft\Windows\CurrentVersion\Policies\System"
    if (!(Test-Path $policiesSystemPath)) {
      New-Item -Path $policiesSystemPath -Force | Out-Null
    }
    Set-ItemProperty -Path $policiesSystemPath -Name "DisableTaskMgr" -Value 1 -Type DWord -Force

    # Descargar el hive
    [gc]::Collect()
    Start-Sleep -Milliseconds 500
    & reg unload $hiveName 2>&1 | Out-Null

    return $true
  }
  catch {
    Write-Warning "Error al configurar restricciones: $($_.Exception.Message)"

    # Intentar descargar el hive si hubo error
    try {
      & reg unload $hiveName 2>&1 | Out-Null
    }
    catch {
      Write-Error "Failed to unload registry hive: $($_.Exception.Message)"
    }

    return $false
  }
}

function Set-FirewallRule {
  [CmdletBinding(SupportsShouldProcess)]
  param($username)

  $ruleName = "BlockInternet-$username"

  $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
  if ($existing) {
    Remove-NetFirewallRule -DisplayName $ruleName
  }

  New-NetFirewallRule -DisplayName $ruleName `
     -Direction Outbound `
     -Action Block `
     -Owner (Get-UserSID $username) `
     -Program "Any" | Out-Null

  $smbRuleName = "AllowSMB-$username"
  $existingSmb = Get-NetFirewallRule -DisplayName $smbRuleName -ErrorAction SilentlyContinue
  if ($existingSmb) {
    Remove-NetFirewallRule -DisplayName $smbRuleName
  }

  New-NetFirewallRule -DisplayName $smbRuleName `
     -Direction Outbound `
     -Action Allow `
     -Protocol TCP `
     -RemotePort 445 `
     -RemoteAddress "192.168.5.30" `
     -Owner (Get-UserSID $username) | Out-Null
}

function New-SyncScript {
  [CmdletBinding(SupportsShouldProcess)]
  param($dispositivo)

  $networkPath = "$networkBase\Dispositivo $dispositivo"

  $syncScript = @"
`$ErrorActionPreference = "Continue"

`$kioskPath = "C:\Kiosk"
`$logsPath = "`$kioskPath\Logs"
`$networkPath = "$networkPath"
`$localPdf = "`$kioskPath\Exam.pdf"
`$logFile = "`$logsPath\sync_`$(Get-Date -Format 'yyyyMMdd').log"

function Write-Log {
    param([string]`$level, [string]`$message)
    `$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path `$logFile -Value "[`$timestamp] [`$level] `$message"
}

function Get-NetworkPDF {
    if (!(Test-Path `$networkPath)) { return `$null }

    `$pdfs = Get-ChildItem -Path `$networkPath -Filter "*.pdf" -ErrorAction SilentlyContinue
    if (`$pdfs.Count -eq 0) { return `$null }

    return `$pdfs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# Mirror local state to network state
`$networkPdf = Get-NetworkPDF

if (`$null -eq `$networkPdf) {
    if (Test-Path `$localPdf) {
        Remove-Item `$localPdf -Force
        Write-Log "INFO" "PDF local eliminado (red vacia)"
    }
    exit 0
}

# Network has PDF, check if we need to copy
`$needsCopy = `$false

if (!(Test-Path `$localPdf)) {
    `$needsCopy = `$true
} else {
    `$localHash = (Get-FileHash `$localPdf -Algorithm MD5).Hash
    `$networkHash = (Get-FileHash `$networkPdf.FullName -Algorithm MD5).Hash
    `$needsCopy = `$localHash -ne `$networkHash
}

if (`$needsCopy) {
    try {
        Copy-Item -Path `$networkPdf.FullName -Destination `$localPdf -Force
        Write-Log "INFO" "PDF sincronizado: `$(`$networkPdf.Name)"
    } catch {
        Write-Log "ERROR" "Fallo en sincronizacion: `$(`$_.Exception.Message)"
    }
}
"@

  $syncPath = "$kioskPath\sync-exam.ps1"
  Set-Content -Path $syncPath -Value $syncScript -Force
}

function New-IndexHTML {
  [CmdletBinding(SupportsShouldProcess)]
  param($username)

  $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Examen para certificacion</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            background: #f5f5f5;
            color: #1a1a1a;
            height: 100vh;
            display: flex;
            flex-direction: column;
            justify-content: center;
            align-items: center;
            user-select: none;
            overflow: hidden;
        }
        .badge {
            position: absolute;
            top: 24px;
            right: 24px;
            background: rgba(0, 0, 0, 0.05);
            border: 1px solid rgba(0, 0, 0, 0.1);
            padding: 10px 20px;
            border-radius: 6px;
            font-weight: 600;
            font-size: 0.9rem;
            color: #4a4a4a;
        }
        .waiting {
            display: flex;
            flex-direction: column;
            align-items: center;
            gap: 2rem;
            text-align: center;
        }
        h1 { font-weight: 700; font-size: 2.5rem; color: #000; }
        p { font-size: 1rem; color: #5a5a5a; }
        .loader {
            width: 40px;
            height: 40px;
            border: 3px solid rgba(0, 0, 0, 0.1);
            border-top-color: #4a4a4a;
            border-radius: 50%;
            animation: spin 1s linear infinite;
        }
        .status {
            font-size: 0.85rem;
            color: #6a6a6a;
            animation: pulse 2s ease-in-out infinite;
        }
        iframe {
            position: absolute;
            top: 0;
            left: 0;
            width: 100vw;
            height: 100vh;
            border: none;
            background: #fff;
            display: none;
        }
        @keyframes spin { to { transform: rotate(360deg); } }
        @keyframes pulse { 0%, 100% { opacity: 0.4; } 50% { opacity: 1; } }
    </style>
</head>
<body oncontextmenu="return false;">
    <div class="badge">$username</div>
    <div class="waiting" id="waiting">
        <h1>Examen para certificación</h1>
        <p>Por favor, espere las instrucciones del docente para comenzar el examen</p>
        <div class="loader"></div>
        <div class="status">Esperando examen...</div>
    </div>
    <iframe id="pdf"></iframe>

    <script>
        const iframe = document.getElementById('pdf');
        const waiting = document.getElementById('waiting');
        let pollInterval = null;

        iframe.onload = function() {
            if (iframe.src === '' || iframe.src === 'about:blank') return;

            setTimeout(function() {
                if (iframe.contentWindow.length === 1) {
                    iframe.style.display = 'block';
                    waiting.style.display = 'none';
                    clearInterval(pollInterval);
                    pollInterval = null;
                }
            }, 100);
        };

        function checkForPDF() {
            iframe.src = 'Exam.pdf?t=' + Date.now() + '#toolbar=0&navpanes=0';
        }

        checkForPDF();
        pollInterval = setInterval(checkForPDF, 5000);
    </script>
</body>
</html>
"@

  $htmlPath = "$kioskPath\index.html"
  Set-Content -Path $htmlPath -Value $html -Force
}

function New-ScheduledTask {
  [CmdletBinding(SupportsShouldProcess)]
  param($username)

  $taskName = "ExamSync-$username"

  $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  }

  $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -File `"$kioskPath\sync-exam.ps1`""
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
  $trigger.Repetition.StopAtDurationEnd = $false

  # Use ServiceAccount logon type - works without password and doesn't require batch logon rights
  $principal = New-ScheduledTaskPrincipal -UserId $username -LogonType ServiceAccount -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
}

function New-UninstallScript {
  [CmdletBinding(SupportsShouldProcess)]
  param($username)

  $uninstallScript = @"
#Requires -RunAsAdministrator

`$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Sistema de examenes encontrado para: $username" -ForegroundColor Cyan
Write-Host ""
`$response = Read-Host "Confirmar desinstalacion? (Y/N)"

if (`$response -ne 'Y') {
    Write-Host "Desinstalacion cancelada" -ForegroundColor Yellow
    exit 0
}

Write-Host "Eliminando tarea programada..." -ForegroundColor Yellow
`$task = Get-ScheduledTask -TaskName "ExamSync-$username" -ErrorAction SilentlyContinue
if (`$task) {
    Unregister-ScheduledTask -TaskName "ExamSync-$username" -Confirm:`$false
}

Write-Host "Eliminando reglas de firewall..." -ForegroundColor Yellow
Remove-NetFirewallRule -DisplayName "BlockInternet-$username" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "AllowSMB-$username" -ErrorAction SilentlyContinue

Write-Host "Restaurando politicas de Edge..." -ForegroundColor Yellow
try {
    `$userProfile = (Get-CimInstance Win32_UserProfile | Where-Object { `$_.LocalPath -like "*\$username" }).LocalPath
    if (`$userProfile) {
        `$ntUserPath = Join-Path `$userProfile "NTUSER.DAT"
        if (Test-Path `$ntUserPath) {
            `$hiveName = "HKLM\TempHive_$username"
            & reg load `$hiveName `$ntUserPath 2>&1 | Out-Null
            Start-Sleep -Milliseconds 500

            `$edgePath = "Registry::`$hiveName\Software\Policies\Microsoft\Edge"
            if (Test-Path `$edgePath) {
                Remove-Item -Path `$edgePath -Recurse -Force
            }

            [gc]::Collect()
            Start-Sleep -Milliseconds 500
            & reg unload `$hiveName 2>&1 | Out-Null
        }
    }
} catch {
    Write-Warning "Error al restaurar politicas de Edge: `$(`$_.Exception.Message)"
}

Write-Host "Restaurando restricciones del sistema..." -ForegroundColor Yellow
try {
    `$userProfile = (Get-CimInstance Win32_UserProfile | Where-Object { `$_.LocalPath -like "*\$username" }).LocalPath
    if (`$userProfile) {
        `$ntUserPath = Join-Path `$userProfile "NTUSER.DAT"
        if (Test-Path `$ntUserPath) {
            `$hiveName = "HKLM\TempHive_$username"
            & reg load `$hiveName `$ntUserPath 2>&1 | Out-Null
            Start-Sleep -Milliseconds 500

            `$explorerPath = "Registry::`$hiveName\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
            if (Test-Path `$explorerPath) {
                Remove-ItemProperty -Path `$explorerPath -Name "NoRun" -ErrorAction SilentlyContinue
            }

            `$systemPath = "Registry::`$hiveName\Software\Policies\Microsoft\Windows\System"
            if (Test-Path `$systemPath) {
                Remove-ItemProperty -Path `$systemPath -Name "DisableCMD" -ErrorAction SilentlyContinue
            }

            `$policiesPath = "Registry::`$hiveName\Software\Microsoft\Windows\CurrentVersion\Policies\System"
            if (Test-Path `$policiesPath) {
                Remove-ItemProperty -Path `$policiesPath -Name "DisableTaskMgr" -ErrorAction SilentlyContinue
            }

            [gc]::Collect()
            Start-Sleep -Milliseconds 500
            & reg unload `$hiveName 2>&1 | Out-Null
        }
    }
} catch {
    Write-Warning "Error al restaurar restricciones: `$(`$_.Exception.Message)"
}

Write-Host ""
`$deleteKiosk = Read-Host "Eliminar carpeta C:\Kiosk? (Y/N)"
if (`$deleteKiosk -eq 'Y') {
    Remove-Item -Path "C:\Kiosk" -Recurse -Force
    Write-Host "Carpeta eliminada" -ForegroundColor Green
}

Write-Host ""
Write-Host "Desinstalacion completada" -ForegroundColor Green
"@

  $uninstallPath = "$kioskPath\uninstall-exam-system.ps1"
  Set-Content -Path $uninstallPath -Value $uninstallScript -Force
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

$alumno = Get-AlumnoUser
$dispositivo = Get-DispositivoNumber $alumno.Name

if (!(Confirm-Installation $alumno.Name $dispositivo)) {
  Write-Information "Instalacion cancelada"
  exit 0
}

Write-Information "Creando estructura de carpetas..."
New-FolderStructure

Write-Information "Habilitando historial de tareas programadas..."
if (Enable-TaskSchedulerHistory) {
  Write-Information "  Historial de tareas habilitado correctamente"
}
else {
  Write-Warning "  No se pudo habilitar el historial de tareas"
}

Write-Information "Obteniendo SID de usuario..."
$sid = Get-UserSID $alumno.Name

Write-Information "Otorgando derechos de batch job..."
if (Grant-BatchJobLogonRight $sid) {
  Write-Information "  Derechos otorgados correctamente"
  Write-Information "  Aplicando politicas de seguridad..."
  & gpupdate /force /target:computer | Out-Null
}
else {
  Write-Warning "  No se pudieron otorgar derechos de batch job"
}

Write-Information "Configurando politicas de Edge..."
if (Set-EdgePolicy $alumno.Name) {
  Write-Information "  Politicas de Edge configuradas correctamente"
}
else {
  Write-Warning "  No se pudieron configurar politicas de Edge"
}

Write-Information "Configurando restricciones del sistema..."
if (Set-SystemRestriction $alumno.Name) {
  Write-Information "  Restricciones configuradas correctamente"
}
else {
  Write-Warning "  No se pudieron configurar restricciones"
}

Write-Information "Configurando reglas de firewall..."
Set-FirewallRule $alumno.Name

Write-Information "Generando script de sincronizacion..."
New-SyncScript $dispositivo

Write-Information "Generando index.html..."
New-IndexHTML $alumno.Name

Write-Information "Creando tarea programada..."
New-ScheduledTask $alumno.Name

Write-Information "Generando script de desinstalacion..."
New-UninstallScript $alumno.Name

Write-Information ""
Write-Information "Instalacion completada exitosamente"
Write-Information "Configure modo Kiosk manualmente para abrir: file:///C:/Kiosk/index.html"


