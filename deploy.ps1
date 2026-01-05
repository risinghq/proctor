#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$kioskPath = "C:\Kiosk"
$logsPath = "$kioskPath\Logs"
$networkBase = "\\192.168.5.30\sidera\Examenes"

function Get-AlumnoUser {
    $users = Get-LocalUser | Where-Object { $_.Name -match '^Alumno-\d{2}$' }
    
    if ($users.Count -eq 0) {
        Write-Host "ERROR: No se encontro ningun usuario Alumno-XX" -ForegroundColor Red
        exit 1
    }
    
    if ($users.Count -gt 1) {
        Write-Host "ERROR: Se encontraron multiples usuarios Alumno:" -ForegroundColor Red
        $users | ForEach-Object { Write-Host "  - $($_.Name)" }
        exit 1
    }
    
    return $users[0]
}

function Get-DispositivoNumber {
    param($username)
    
    if ($username -match 'Alumno-(\d{2})') {
        return $matches[1]
    }
    
    Write-Host "ERROR: No se pudo extraer numero de dispositivo de $username" -ForegroundColor Red
    exit 1
}

function Confirm-Installation {
    param($username, $dispositivo)
    
    Write-Host ""
    Write-Host "Usuario encontrado: $username" -ForegroundColor Cyan
    Write-Host "Dispositivo: $dispositivo" -ForegroundColor Cyan
    Write-Host ""
    $response = Read-Host "Confirmar instalacion? (Y/N)"
    
    return $response -eq 'Y'
}

function New-FolderStructure {
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
    
    $user = New-Object System.Security.Principal.NTAccount($username)
    return $user.Translate([System.Security.Principal.SecurityIdentifier]).Value
}

function Grant-BatchJobLogonRight {
    param($username, $sid)
    
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
                $content = $content -replace [regex]::Escape($batchLine), $newLine
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

function Set-EdgePolicies {
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
            'PrintingEnabled'           = 0
            'AllowFileSelectionDialogs' = 0
            'DownloadRestrictions'      = 3
            'HideFirstRunExperience'    = 1
            'BrowserSignin'             = 0
            'SyncDisabled'              = 1
            'ContextMenuEnabled'        = 0
            'SavingBrowserHistoryDisabled' = 1
            'DiskCacheSize'             = 1
            'ClearBrowsingDataOnExit'   = 1
            'DefaultCookiesSetting'     = 4
            'SitePerProcess'            = 0
            'AllowFileAccessFromFiles'  = 1
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
        catch {}
        
        return $false
    }
}

function Set-SystemRestrictions {
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
        catch {}
        
        return $false
    }
}

function Set-FirewallRule {
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
    param($dispositivo, $username)
    
    $networkPath = "$networkBase\Dispositivo $dispositivo"
    
    $syncScript = @"
`$ErrorActionPreference = "Continue"

`$kioskPath = "C:\Kiosk"
`$logsPath = "`$kioskPath\Logs"
`$networkPath = "$networkPath"
`$logFile = "`$logsPath\sync_`$(Get-Date -Format 'yyyyMMdd').log"

function Write-Log {
    param([string]`$level, [string]`$message)
    `$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    `$entry = "[`$timestamp] [`$level] `$message"
    Add-Content -Path `$logFile -Value `$entry
}

function Get-MostRecentPDF {
    param(`$path)
    
    if (!(Test-Path `$path)) {
        return `$null
    }
    
    `$pdfs = Get-ChildItem -Path `$path -Filter "*.pdf" -ErrorAction SilentlyContinue
    
    if (`$pdfs.Count -eq 0) {
        return `$null
    }
    
    return `$pdfs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Sync-ExamPDF {
    Write-Log "INFO" "Sincronizacion iniciada"
    
    try {
        `$networkPdf = Get-MostRecentPDF `$networkPath
        `$localPdf = "`$kioskPath\Exam.pdf"
        
        if (`$null -eq `$networkPdf) {
            if (Test-Path `$localPdf) {
                Remove-Item `$localPdf -Force
                Write-Log "INFO" "PDF local eliminado (no hay PDF en red)"
            }
            return
        }
        
        `$modified = `$networkPdf.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        Write-Log "INFO" "PDF encontrado: `$(`$networkPdf.Name) (Modificado: `$modified)"
        
        Copy-Item -Path `$networkPdf.FullName -Destination `$localPdf -Force
        Write-Log "INFO" "PDF sincronizado exitosamente"
        
    } catch {
        Write-Log "ERROR" "Fallo en sincronizacion: `$(`$_.Exception.Message)"
    }
}

Sync-ExamPDF
"@
    
    $syncPath = "$kioskPath\sync-exam.ps1"
    Set-Content -Path $syncPath -Value $syncScript -Force
}

function New-IndexHTML {
    param($username)
    
    $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Examen para certificacion</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { 
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; 
            background: linear-gradient(135deg, #f5f5f5 0%, #e8e8e8 100%);
            color: #1a1a1a; 
            height: 100vh; 
            display: flex; 
            flex-direction: column; 
            justify-content: center; 
            align-items: center; 
            user-select: none;
            -webkit-user-select: none;
            overflow: hidden;
        }
        .student-badge {
            position: absolute;
            top: 24px;
            right: 24px;
            background: rgba(0, 0, 0, 0.05);
            backdrop-filter: blur(10px);
            border: 1px solid rgba(0, 0, 0, 0.1);
            padding: 10px 20px;
            border-radius: 6px;
            font-weight: 600;
            font-size: 0.9rem;
            letter-spacing: 0.5px;
            color: #4a4a4a;
        }
        .waiting-container {
            display: flex;
            flex-direction: column;
            align-items: center;
            gap: 2rem;
            max-width: 600px;
            text-align: center;
        }
        h1 { 
            font-weight: 700; 
            font-size: 2.5rem; 
            letter-spacing: -0.5px; 
            margin-bottom: 0.5rem; 
            color: #000000;
        }
        p { 
            font-weight: 400; 
            font-size: 1rem; 
            color: #5a5a5a; 
            letter-spacing: 0.01em; 
            line-height: 1.6;
        }
        .loader { 
            width: 40px; 
            height: 40px; 
            border: 3px solid rgba(0, 0, 0, 0.1);
            border-top: 3px solid #4a4a4a; 
            border-radius: 50%; 
            animation: spin 1s linear infinite; 
            margin-top: 1rem;
        }
        .status { 
            font-weight: 500; 
            font-size: 0.85rem; 
            color: #6a6a6a; 
            letter-spacing: 0.3px;
            animation: pulse 2s ease-in-out infinite;
            margin-top: 0.5rem;
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
        @keyframes spin { 
            0% { transform: rotate(0deg); } 
            100% { transform: rotate(360deg); } 
        }
        @keyframes pulse {
            0%, 100% { opacity: 0.4; }
            50% { opacity: 1; }
        }
    </style>
</head>
<body oncontextmenu="return false;">
    <div class="student-badge">$username</div>
    <div class="waiting-container" id="waiting">
        <h1>Examen para certificación</h1>
        <p>Por favor, espere las instrucciones del docente para comenzar el examen</p>
        <div class="loader"></div>
        <div class="status">Esperando examen...</div>
    </div>
    <iframe id="pdfFrame" src="about:blank"></iframe>
    
    <script>
        const iframe = document.getElementById('pdfFrame');
        const waiting = document.getElementById('waiting');
        let pdfExists = false;
        let isChecking = false;
        
        console.log('[INIT] Page loaded - starting PDF monitoring system');
        
        // Main iframe load handler - uses contentWindow.length to detect PDF
        iframe.onload = function() {
            console.log('[ONLOAD] Iframe loaded, src:', iframe.src);
            
            // Ignore about:blank
            if (iframe.src.includes('about:blank')) {
                console.log('[ONLOAD] about:blank detected - skipping');
                return;
            }
            
            // Wait for iframe to fully render
            setTimeout(function() {
                const length = iframe.contentWindow.length;
                console.log('[ONLOAD] contentWindow.length:', length);
                
                if (length === 1) {
                    // PDF loaded successfully
                    console.log('[ONLOAD] PDF detected - showing');
                    iframe.style.display = 'block';
                    waiting.style.display = 'none';
                    pdfExists = true;
                } else {
                    // Error page (PDF missing)
                    console.log('[ONLOAD] PDF missing - showing waiting screen');
                    iframe.style.display = 'none';
                    waiting.style.display = 'flex';
                    pdfExists = false;
                }
                
                isChecking = false;
            }, 100);
        };
        
        // Error handler - fires when iframe fails to load (backup detection)
        iframe.onerror = function() {
            console.log('[ONERROR] Iframe error event - PDF missing');
            iframe.style.display = 'none';
            waiting.style.display = 'flex';
            pdfExists = false;
            isChecking = false;
        };
        
        // Check function - reloads iframe to detect changes
        function checkPDF() {
            if (isChecking) {
                console.log('[CHECK] Already checking - skipping');
                return;
            }
            
            console.log('[CHECK] Checking for PDF (current state: pdfExists =', pdfExists + ')');
            isChecking = true;
            
            // Reload with cache-busting timestamp
            iframe.src = 'Exam.pdf?t=' + Date.now() + '#toolbar=0&navpanes=0&scrollbar=0';
        }
        
        // Start checking immediately
        checkPDF();
        
        // Check every 5 seconds
        setInterval(checkPDF, 5000);
        
        console.log('[INIT] Monitoring started - checking every 5 seconds');
    </script>
</body>
</html>
"@
    
    $htmlPath = "$kioskPath\index.html"
    Set-Content -Path $htmlPath -Value $html -Force
}

function New-ScheduledTask {
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
    Write-Host "Instalacion cancelada" -ForegroundColor Yellow
    exit 0
}

Write-Host "Creando estructura de carpetas..." -ForegroundColor Yellow
New-FolderStructure

Write-Host "Habilitando historial de tareas programadas..." -ForegroundColor Yellow
if (Enable-TaskSchedulerHistory) {
    Write-Host "  Historial de tareas habilitado correctamente" -ForegroundColor Gray
}
else {
    Write-Host "  Advertencia: No se pudo habilitar el historial de tareas" -ForegroundColor DarkYellow
}

Write-Host "Obteniendo SID de usuario..." -ForegroundColor Yellow
$sid = Get-UserSID $alumno.Name

Write-Host "Otorgando derechos de batch job..." -ForegroundColor Yellow
if (Grant-BatchJobLogonRight $alumno.Name $sid) {
    Write-Host "  Derechos otorgados correctamente" -ForegroundColor Gray
    Write-Host "  Aplicando politicas de seguridad..." -ForegroundColor Gray
    & gpupdate /force /target:computer | Out-Null
}
else {
    Write-Host "  Advertencia: No se pudieron otorgar derechos de batch job" -ForegroundColor DarkYellow
}

Write-Host "Configurando politicas de Edge..." -ForegroundColor Yellow
if (Set-EdgePolicies $alumno.Name) {
    Write-Host "  Politicas de Edge configuradas correctamente" -ForegroundColor Gray
}
else {
    Write-Host "  Advertencia: No se pudieron configurar politicas de Edge" -ForegroundColor DarkYellow
}

Write-Host "Configurando restricciones del sistema..." -ForegroundColor Yellow
if (Set-SystemRestrictions $alumno.Name) {
    Write-Host "  Restricciones configuradas correctamente" -ForegroundColor Gray
}
else {
    Write-Host "  Advertencia: No se pudieron configurar restricciones" -ForegroundColor DarkYellow
}

Write-Host "Configurando reglas de firewall..." -ForegroundColor Yellow
Set-FirewallRule $alumno.Name

Write-Host "Generando script de sincronizacion..." -ForegroundColor Yellow
New-SyncScript $dispositivo $alumno.Name

Write-Host "Generando index.html..." -ForegroundColor Yellow
New-IndexHTML $alumno.Name

Write-Host "Creando tarea programada..." -ForegroundColor Yellow
New-ScheduledTask $alumno.Name

Write-Host "Generando script de desinstalacion..." -ForegroundColor Yellow
New-UninstallScript $alumno.Name

Write-Host ""
Write-Host "Instalacion completada exitosamente" -ForegroundColor Green
Write-Host "Configure modo Kiosk manualmente para abrir: file:///C:/Kiosk/index.html" -ForegroundColor Cyan
