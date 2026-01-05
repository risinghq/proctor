#Requires -RunAsAdministrator

$ErrorActionPreference = "Continue"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "DEBUG: Scheduled Task Registration" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 1. Verify admin status
Write-Host "[1] Verificando permisos de administrador..." -ForegroundColor Yellow
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "    Es Administrador: $isAdmin" -ForegroundColor $(if($isAdmin){"Green"}else{"Red"})
Write-Host ""

# 2. Get Alumno user
Write-Host "[2] Obteniendo usuario Alumno..." -ForegroundColor Yellow
$alumno = Get-LocalUser | Where-Object { $_.Name -match '^Alumno-\d{2}$' } | Select-Object -First 1
if ($alumno) {
    Write-Host "    Usuario encontrado: $($alumno.Name)" -ForegroundColor Green
    Write-Host "    Enabled: $($alumno.Enabled)" -ForegroundColor Gray
    Write-Host "    SID: $($alumno.SID)" -ForegroundColor Gray
} else {
    Write-Host "    ERROR: No se encontro usuario Alumno" -ForegroundColor Red
    exit 1
}
Write-Host ""

# 3. Test basic task creation with current user
Write-Host "[3] Probando tarea con usuario actual ($env:USERNAME)..." -ForegroundColor Yellow
try {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-Command Write-Host 'test'"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
    $settings = New-ScheduledTaskSettingsSet
    
    Register-ScheduledTask -TaskName "DebugTest1" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "    OK: Tarea creada con usuario actual" -ForegroundColor Green
    Unregister-ScheduledTask -TaskName "DebugTest1" -Confirm:$false
} catch {
    Write-Host "    ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# 4. Test task with Alumno user - Interactive logon
Write-Host "[4] Probando tarea con Alumno - LogonType Interactive..." -ForegroundColor Yellow
try {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-Command Write-Host 'test'"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)
    $principal = New-ScheduledTaskPrincipal -UserId $alumno.Name -LogonType Interactive
    $settings = New-ScheduledTaskSettingsSet
    
    Register-ScheduledTask -TaskName "DebugTest2" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "    OK: Tarea creada con Interactive" -ForegroundColor Green
    Unregister-ScheduledTask -TaskName "DebugTest2" -Confirm:$false
} catch {
    Write-Host "    ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# 5. Test task with Alumno user - S4U logon (the problematic one)
Write-Host "[5] Probando tarea con Alumno - LogonType S4U..." -ForegroundColor Yellow
try {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-Command Write-Host 'test'"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)
    $principal = New-ScheduledTaskPrincipal -UserId $alumno.Name -LogonType S4U -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet
    
    Register-ScheduledTask -TaskName "DebugTest3" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "    OK: Tarea creada con S4U" -ForegroundColor Green
    Unregister-ScheduledTask -TaskName "DebugTest3" -Confirm:$false
} catch {
    Write-Host "    ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "    HRESULT: $($_.Exception.HResult)" -ForegroundColor Red
}
Write-Host ""

# 6. Test with repetition trigger and S4U
Write-Host "[6] Probando tarea con repeticion + S4U..." -ForegroundColor Yellow
try {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-Command Write-Host 'test'"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $trigger.Repetition.StopAtDurationEnd = $false
    $principal = New-ScheduledTaskPrincipal -UserId $alumno.Name -LogonType S4U -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    
    Register-ScheduledTask -TaskName "DebugTest4" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "    OK: Tarea creada con repeticion + S4U" -ForegroundColor Green
    Unregister-ScheduledTask -TaskName "DebugTest4" -Confirm:$false
} catch {
    Write-Host "    ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "    HRESULT: $($_.Exception.HResult)" -ForegroundColor Red
}
Write-Host ""

# 7. Check batch logon rights
Write-Host "[7] Verificando derechos de batch logon..." -ForegroundColor Yellow
try {
    $tempFile = [System.IO.Path]::GetTempFileName()
    & secedit /export /cfg $tempFile /quiet 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    
    $content = Get-Content $tempFile
    $batchLine = $content | Where-Object { $_ -match '^SeBatchLogonRight' }
    
    if ($batchLine) {
        Write-Host "    Batch Logon Rights: $batchLine" -ForegroundColor Gray
        $sid = $alumno.SID.Value
        if ($batchLine -match [regex]::Escape("*$sid")) {
            Write-Host "    OK: Alumno tiene derechos de batch logon" -ForegroundColor Green
        } else {
            Write-Host "    ADVERTENCIA: Alumno NO tiene derechos de batch logon" -ForegroundColor Yellow
        }
    } else {
        Write-Host "    ADVERTENCIA: No se encontro configuracion de SeBatchLogonRight" -ForegroundColor Yellow
    }
    
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
} catch {
    Write-Host "    ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# 8. Try with Password (if you want to test with stored credentials)
Write-Host "[8] Probando con Password storage..." -ForegroundColor Yellow
Write-Host "    NOTA: S4U no requiere password, saltando..." -ForegroundColor Gray
Write-Host ""

# 9. Check existing tasks for the user
Write-Host "[9] Verificando tareas existentes para $($alumno.Name)..." -ForegroundColor Yellow
$existingTasks = Get-ScheduledTask | Where-Object { $_.Principal.UserId -eq $alumno.Name }
if ($existingTasks) {
    Write-Host "    Tareas encontradas: $($existingTasks.Count)" -ForegroundColor Gray
    $existingTasks | ForEach-Object {
        Write-Host "      - $($_.TaskName) (State: $($_.State), LogonType: $($_.Principal.LogonType))" -ForegroundColor Gray
    }
} else {
    Write-Host "    No hay tareas existentes para este usuario" -ForegroundColor Gray
}
Write-Host ""

# 10. Check Task Scheduler service
Write-Host "[10] Verificando servicio Task Scheduler..." -ForegroundColor Yellow
$taskScheduler = Get-Service -Name "Schedule"
Write-Host "    Estado: $($taskScheduler.Status)" -ForegroundColor $(if($taskScheduler.Status -eq "Running"){"Green"}else{"Red"})
Write-Host "    StartType: $($taskScheduler.StartType)" -ForegroundColor Gray
Write-Host ""

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "DEBUG COMPLETADO" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
