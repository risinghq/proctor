#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$kiosk-path = "C:\Kiosk"
$logs-path = "$kiosk-path\Logs"
$network-base = "\\192.168.5.30\sidera\Examenes"

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

function Create-FolderStructure {
    if (!(Test-Path $kiosk-path)) {
        New-Item -Path $kiosk-path -ItemType Directory -Force | Out-Null
    }
    
    if (!(Test-Path $logs-path)) {
        New-Item -Path $logs-path -ItemType Directory -Force | Out-Null
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
        } elseif ($logStatus -match "enabled:\s*true") {
            return $true
        }
    } catch {
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

function Set-EdgePolicies {
    param($sid)
    
    $registry-path = "Registry::HKEY_USERS\$sid\Software\Policies\Microsoft\Edge"
    
    if (!(Test-Path $registry-path)) {
        New-Item -Path $registry-path -Force | Out-Null
    }
    
    $policies = @{
        # 'DeveloperToolsAvailability' = 2
        'PrintingEnabled' = 0
        'AllowFileSelectionDialogs' = 0
        'DownloadRestrictions' = 3
        'HideFirstRunExperience' = 1
        'BrowserSignin' = 0
        'SyncDisabled' = 1
        'ContextMenuEnabled' = 0
    }
    
    foreach ($policy in $policies.GetEnumerator()) {
        Set-ItemProperty -Path $registry-path -Name $policy.Key -Value $policy.Value -Type DWord -Force
    }
    
    Set-ItemProperty -Path $registry-path -Name "NewTabPageLocation" -Value "file:///C:/Kiosk/index.html" -Type String -Force
}

function Set-SystemRestrictions {
    param($sid)
    
    $explorer-path = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    if (!(Test-Path $explorer-path)) {
        New-Item -Path $explorer-path -Force | Out-Null
    }
    Set-ItemProperty -Path $explorer-path -Name "NoRun" -Value 1 -Type DWord -Force
    
    $system-path = "Registry::HKEY_USERS\$sid\Software\Policies\Microsoft\Windows\System"
    if (!(Test-Path $system-path)) {
        New-Item -Path $system-path -Force | Out-Null
    }
    Set-ItemProperty -Path $system-path -Name "DisableCMD" -Value 1 -Type DWord -Force
    
    $policies-system-path = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Policies\System"
    if (!(Test-Path $policies-system-path)) {
        New-Item -Path $policies-system-path -Force | Out-Null
    }
    Set-ItemProperty -Path $policies-system-path -Name "DisableTaskMgr" -Value 1 -Type DWord -Force
}

function Set-FirewallRule {
    param($username)
    
    $rule-name = "BlockInternet-$username"
    
    $existing = Get-NetFirewallRule -DisplayName $rule-name -ErrorAction SilentlyContinue
    if ($existing) {
        Remove-NetFirewallRule -DisplayName $rule-name
    }
    
    New-NetFirewallRule -DisplayName $rule-name `
        -Direction Outbound `
        -Action Block `
        -Owner (Get-UserSID $username) `
        -Program "Any" | Out-Null
    
    $smb-rule-name = "AllowSMB-$username"
    $existing-smb = Get-NetFirewallRule -DisplayName $smb-rule-name -ErrorAction SilentlyContinue
    if ($existing-smb) {
        Remove-NetFirewallRule -DisplayName $smb-rule-name
    }
    
    New-NetFirewallRule -DisplayName $smb-rule-name `
        -Direction Outbound `
        -Action Allow `
        -Protocol TCP `
        -RemotePort 445 `
        -RemoteAddress "192.168.5.30" `
        -Owner (Get-UserSID $username) | Out-Null
}

function Create-SyncScript {
    param($dispositivo, $username)
    
    $network-path = "$network-base\Dispositivo $dispositivo"
    
    $sync-script = @"
`$ErrorActionPreference = "Continue"

`$kiosk-path = "C:\Kiosk"
`$logs-path = "`$kiosk-path\Logs"
`$network-path = "$network-path"
`$log-file = "`$logs-path\sync_`$(Get-Date -Format 'yyyyMMdd').log"

function Write-Log {
    param([string]`$level, [string]`$message)
    `$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    `$entry = "[`$timestamp] [`$level] `$message"
    Add-Content -Path `$log-file -Value `$entry
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
        `$network-pdf = Get-MostRecentPDF `$network-path
        `$local-pdf = "`$kiosk-path\Exam.pdf"
        
        if (`$null -eq `$network-pdf) {
            if (Test-Path `$local-pdf) {
                Remove-Item `$local-pdf -Force
                Write-Log "INFO" "PDF local eliminado (no hay PDF en red)"
            }
            return
        }
        
        `$modified = `$network-pdf.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        Write-Log "INFO" "PDF encontrado: `$(`$network-pdf.Name) (Modificado: `$modified)"
        
        Copy-Item -Path `$network-pdf.FullName -Destination `$local-pdf -Force
        Write-Log "INFO" "PDF sincronizado exitosamente"
        
    } catch {
        Write-Log "ERROR" "Fallo en sincronizacion: `$(`$_.Exception.Message)"
    }
}

Sync-ExamPDF
"@
    
    $sync-path = "$kiosk-path\sync-exam.ps1"
    Set-Content -Path $sync-path -Value $sync-script -Force
}

function Create-IndexHTML {
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
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;800&display=swap" rel="stylesheet">
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { 
            font-family: 'Inter', sans-serif; 
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%);
            color: #fff; 
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
            top: 20px;
            right: 20px;
            background: rgba(255,255,255,0.1);
            backdrop-filter: blur(10px);
            border: 1px solid rgba(255,255,255,0.2);
            padding: 12px 24px;
            border-radius: 50px;
            font-weight: 600;
            font-size: 1rem;
            letter-spacing: 0.05em;
            text-transform: uppercase;
        }
        .waiting-container {
            display: flex;
            flex-direction: column;
            align-items: center;
            gap: 2rem;
        }
        h1 { 
            font-weight: 800; 
            font-size: 3.5rem; 
            letter-spacing: -0.02em; 
            margin-bottom: 0.5rem; 
            text-transform: uppercase; 
            background: linear-gradient(90deg, #e94560, #ff6b6b);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }
        p { 
            font-weight: 400; 
            font-size: 1.1rem; 
            color: rgba(255,255,255,0.7); 
            letter-spacing: 0.02em; 
        }
        .loader { 
            width: 50px; 
            height: 50px; 
            border: 3px solid rgba(255,255,255,0.1);
            border-top: 3px solid #e94560; 
            border-radius: 50%; 
            animation: spin 1s linear infinite; 
        }
        .status { 
            font-weight: 400; 
            font-size: 0.9rem; 
            color: rgba(255,255,255,0.5); 
            letter-spacing: 0.05em;
            animation: pulse 2s ease-in-out infinite;
            margin-top: 1rem;
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
            0%, 100% { opacity: 0.5; }
            50% { opacity: 1; }
        }
    </style>
</head>
<body oncontextmenu="return false;">
    <div class="student-badge">$username</div>
    <div class="waiting-container" id="waiting">
        <h1>Examen para certificacion</h1>
        <p>Por favor, espere las instrucciones del docente</p>
        <div class="loader"></div>
        <div class="status">Esperando examen...</div>
    </div>
    <iframe id="pdfFrame"></iframe>
    
    <script>
        function checkPDF() {
            fetch('Exam.pdf?t=' + Date.now(), { method: 'HEAD' })
                .then(response => {
                    if (response.ok) {
                        document.getElementById('pdfFrame').src = 'Exam.pdf?t=' + Date.now();
                        document.getElementById('pdfFrame').style.display = 'block';
                        document.getElementById('waiting').style.display = 'none';
                    } else {
                        document.getElementById('pdfFrame').style.display = 'none';
                        document.getElementById('waiting').style.display = 'flex';
                    }
                })
                .catch(() => {
                    document.getElementById('pdfFrame').style.display = 'none';
                    document.getElementById('waiting').style.display = 'flex';
                });
        }
        
        checkPDF();
        setInterval(checkPDF, 5000);
    </script>
</body>
</html>
"@
    
    $html-path = "$kiosk-path\index.html"
    Set-Content -Path $html-path -Value $html -Force
}

function Create-ScheduledTask {
    param($username)
    
    $task-name = "ExamSync-$username"
    
    $existing = Get-ScheduledTask -TaskName $task-name -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $task-name -Confirm:$false
    }
    
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -File `"$kiosk-path\sync-exam.ps1`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Seconds 30) -RepetitionDuration ([TimeSpan]::MaxValue)
    $principal = New-ScheduledTaskPrincipal -UserId $username -LogonType S4U -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    
    Register-ScheduledTask -TaskName $task-name -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
}

function Create-UninstallScript {
    param($username, $sid)
    
    $uninstall-script = @"
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
`$edge-path = "Registry::HKEY_USERS\$sid\Software\Policies\Microsoft\Edge"
if (Test-Path `$edge-path) {
    Remove-Item -Path `$edge-path -Recurse -Force
}

Write-Host "Restaurando restricciones del sistema..." -ForegroundColor Yellow
`$explorer-path = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
if (Test-Path `$explorer-path) {
    Remove-ItemProperty -Path `$explorer-path -Name "NoRun" -ErrorAction SilentlyContinue
}

`$system-path = "Registry::HKEY_USERS\$sid\Software\Policies\Microsoft\Windows\System"
if (Test-Path `$system-path) {
    Remove-ItemProperty -Path `$system-path -Name "DisableCMD" -ErrorAction SilentlyContinue
}

`$policies-path = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Policies\System"
if (Test-Path `$policies-path) {
    Remove-ItemProperty -Path `$policies-path -Name "DisableTaskMgr" -ErrorAction SilentlyContinue
}

Write-Host ""
`$delete-kiosk = Read-Host "Eliminar carpeta C:\Kiosk? (Y/N)"
if (`$delete-kiosk -eq 'Y') {
    Remove-Item -Path "C:\Kiosk" -Recurse -Force
    Write-Host "Carpeta eliminada" -ForegroundColor Green
}

Write-Host ""
Write-Host "Desinstalacion completada" -ForegroundColor Green
"@
    
    $uninstall-path = "$kiosk-path\uninstall-exam-system.ps1"
    Set-Content -Path $uninstall-path -Value $uninstall-script -Force
}

$alumno = Get-AlumnoUser
$dispositivo = Get-DispositivoNumber $alumno.Name

if (!(Confirm-Installation $alumno.Name $dispositivo)) {
    Write-Host "Instalacion cancelada" -ForegroundColor Yellow
    exit 0
}

Write-Host "Creando estructura de carpetas..." -ForegroundColor Yellow
Create-FolderStructure

Write-Host "Habilitando historial de tareas programadas..." -ForegroundColor Yellow
if (Enable-TaskSchedulerHistory) {
    Write-Host "  Historial de tareas habilitado correctamente" -ForegroundColor Gray
} else {
    Write-Host "  Advertencia: No se pudo habilitar el historial de tareas" -ForegroundColor DarkYellow
}

Write-Host "Obteniendo SID de usuario..." -ForegroundColor Yellow
$sid = Get-UserSID $alumno.Name

Write-Host "Configurando politicas de Edge..." -ForegroundColor Yellow
Set-EdgePolicies $sid

Write-Host "Configurando restricciones del sistema..." -ForegroundColor Yellow
Set-SystemRestrictions $sid

Write-Host "Configurando reglas de firewall..." -ForegroundColor Yellow
Set-FirewallRule $alumno.Name

Write-Host "Generando script de sincronizacion..." -ForegroundColor Yellow
Create-SyncScript $dispositivo $alumno.Name

Write-Host "Generando index.html..." -ForegroundColor Yellow
Create-IndexHTML $alumno.Name

Write-Host "Creando tarea programada..." -ForegroundColor Yellow
Create-ScheduledTask $alumno.Name

Write-Host "Generando script de desinstalacion..." -ForegroundColor Yellow
Create-UninstallScript $alumno.Name $sid

Write-Host ""
Write-Host "Instalacion completada exitosamente" -ForegroundColor Green
Write-Host "Configure modo Kiosk manualmente para abrir: file:///C:/Kiosk/index.html" -ForegroundColor Cyan
