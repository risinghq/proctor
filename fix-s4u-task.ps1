#Requires -RunAsAdministrator

$ErrorActionPreference = "Continue"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "S4U TASK CREATION - TROUBLESHOOTING" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Get Alumno user
$alumno = Get-LocalUser | Where-Object { $_.Name -match '^Alumno-\d{2}$' } | Select-Object -First 1
if (-not $alumno) {
    Write-Host "ERROR: No se encontro usuario Alumno" -ForegroundColor Red
    exit 1
}

$username = $alumno.Name
$sid = $alumno.SID.Value

Write-Host "Usuario: $username" -ForegroundColor Cyan
Write-Host "SID: $sid" -ForegroundColor Cyan
Write-Host ""

# Clean up any existing test tasks
Get-ScheduledTask | Where-Object { $_.TaskName -like "S4UTest*" } | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

# Test 1: Fix batch logon rights with SID and force policy update
Write-Host "[1] Corrigiendo derechos de batch logon con SID..." -ForegroundColor Yellow
try {
    $tempFile = [System.IO.Path]::GetTempFileName()
    & secedit /export /cfg $tempFile /quiet 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    
    $content = Get-Content $tempFile
    $batchLine = $content | Where-Object { $_ -match '^SeBatchLogonRight' }
    
    $needsUpdate = $false
    if ($batchLine) {
        if ($batchLine -notmatch [regex]::Escape("*$sid")) {
            Write-Host "    Agregando SID a batch logon rights..." -ForegroundColor Gray
            $newLine = $batchLine + ",*$sid"
            $content = $content -replace [regex]::Escape($batchLine), $newLine
            $needsUpdate = $true
        } else {
            Write-Host "    SID ya esta en batch logon rights" -ForegroundColor Green
        }
    } else {
        Write-Host "    Creando entrada de batch logon rights..." -ForegroundColor Gray
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
        $needsUpdate = $true
    }
    
    if ($needsUpdate) {
        Set-Content -Path $tempFile -Value $content -Force -Encoding Unicode
        $dbFile = Join-Path $env:TEMP "secedit_$(New-Guid).sdb"
        & secedit /configure /db $dbFile /cfg $tempFile /quiet
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        Remove-Item $dbFile -Force -ErrorAction SilentlyContinue
        
        Write-Host "    Aplicando politicas..." -ForegroundColor Gray
        & gpupdate /force /target:computer | Out-Null
        Start-Sleep -Seconds 2
        Write-Host "    Politicas aplicadas" -ForegroundColor Green
    }
} catch {
    Write-Host "    ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Test 2: Try S4U with Limited RunLevel
Write-Host "[2] Intentando S4U con RunLevel Limited..." -ForegroundColor Yellow
try {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-Command Write-Host 'test'"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)
    $principal = New-ScheduledTaskPrincipal -UserId $username -LogonType S4U -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet
    
    Register-ScheduledTask -TaskName "S4UTest1" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    Write-Host "    OK: S4U con Limited funciona!" -ForegroundColor Green
    Unregister-ScheduledTask -TaskName "S4UTest1" -Confirm:$false
} catch {
    Write-Host "    FALLO: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Test 3: Try S4U with Highest RunLevel
Write-Host "[3] Intentando S4U con RunLevel Highest..." -ForegroundColor Yellow
try {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-Command Write-Host 'test'"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)
    $principal = New-ScheduledTaskPrincipal -UserId $username -LogonType S4U -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet
    
    Register-ScheduledTask -TaskName "S4UTest2" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    Write-Host "    OK: S4U con Highest funciona!" -ForegroundColor Green
    Unregister-ScheduledTask -TaskName "S4UTest2" -Confirm:$false
} catch {
    Write-Host "    FALLO: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Test 4: Try using SID directly instead of username
Write-Host "[4] Intentando S4U usando SID directamente..." -ForegroundColor Yellow
try {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-Command Write-Host 'test'"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)
    $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType S4U -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet
    
    Register-ScheduledTask -TaskName "S4UTest3" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    Write-Host "    OK: S4U con SID funciona!" -ForegroundColor Green
    Unregister-ScheduledTask -TaskName "S4UTest3" -Confirm:$false
} catch {
    Write-Host "    FALLO: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Test 5: Try using schtasks.exe directly
Write-Host "[5] Intentando con schtasks.exe (S4U)..." -ForegroundColor Yellow
try {
    $xmlTask = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <TimeTrigger>
      <StartBoundary>$((Get-Date).AddMinutes(5).ToString("yyyy-MM-ddTHH:mm:ss"))</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$username</UserId>
      <LogonType>S4U</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-Command Write-Host 'test'</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    
    $xmlFile = Join-Path $env:TEMP "S4UTest.xml"
    Set-Content -Path $xmlFile -Value $xmlTask -Force
    
    $result = & schtasks.exe /create /tn "S4UTest4" /xml $xmlFile /f 2>&1
    Remove-Item $xmlFile -Force -ErrorAction SilentlyContinue
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    OK: schtasks.exe funciona con S4U!" -ForegroundColor Green
        & schtasks.exe /delete /tn "S4UTest4" /f | Out-Null
    } else {
        Write-Host "    FALLO: $result" -ForegroundColor Red
    }
} catch {
    Write-Host "    ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Test 6: Check for Group Policy restrictions
Write-Host "[6] Verificando restricciones de Group Policy..." -ForegroundColor Yellow
$gpResult = & gpresult /r /scope:computer 2>&1 | Select-String -Pattern "Scheduled"
if ($gpResult) {
    Write-Host "    Politicas relacionadas con tareas:" -ForegroundColor Gray
    $gpResult | ForEach-Object { Write-Host "      $_" -ForegroundColor Gray }
} else {
    Write-Host "    No se encontraron politicas restrictivas" -ForegroundColor Green
}
Write-Host ""

# Test 7: Try ServiceAccount logon type
Write-Host "[7] Intentando con LogonType ServiceAccount..." -ForegroundColor Yellow
try {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-Command Write-Host 'test'"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)
    $principal = New-ScheduledTaskPrincipal -UserId $username -LogonType ServiceAccount -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet
    
    Register-ScheduledTask -TaskName "S4UTest5" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    Write-Host "    OK: ServiceAccount funciona!" -ForegroundColor Green
    Unregister-ScheduledTask -TaskName "S4UTest5" -Confirm:$false
} catch {
    Write-Host "    FALLO: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Test 8: Check if user needs "Log on as a service" right
Write-Host "[8] Verificando 'Log on as a service' rights..." -ForegroundColor Yellow
try {
    $tempFile = [System.IO.Path]::GetTempFileName()
    & secedit /export /cfg $tempFile /quiet 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    
    $content = Get-Content $tempFile
    $serviceLine = $content | Where-Object { $_ -match '^SeServiceLogonRight' }
    
    if ($serviceLine) {
        Write-Host "    Service Logon Rights: $serviceLine" -ForegroundColor Gray
        if ($serviceLine -match [regex]::Escape("*$sid") -or $serviceLine -match $username) {
            Write-Host "    Usuario tiene derechos de service logon" -ForegroundColor Green
        } else {
            Write-Host "    Usuario NO tiene derechos de service logon" -ForegroundColor Yellow
        }
    } else {
        Write-Host "    No se encontro configuracion de SeServiceLogonRight" -ForegroundColor Gray
    }
    
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
} catch {
    Write-Host "    ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Test 9: Final test - retry S4U after all fixes
Write-Host "[9] PRUEBA FINAL: Reintentando S4U despues de todas las correcciones..." -ForegroundColor Yellow
Start-Sleep -Seconds 2
try {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -Command Write-Host 'test'"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $trigger.Repetition.StopAtDurationEnd = $false
    $principal = New-ScheduledTaskPrincipal -UserId $username -LogonType S4U -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    
    Register-ScheduledTask -TaskName "S4UTest_Final" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    Write-Host "    *** EXITO! S4U FUNCIONA CORRECTAMENTE ***" -ForegroundColor Green
    Write-Host ""
    Write-Host "    Detalles de la tarea creada:" -ForegroundColor Cyan
    $task = Get-ScheduledTask -TaskName "S4UTest_Final"
    Write-Host "      LogonType: $($task.Principal.LogonType)" -ForegroundColor Gray
    Write-Host "      RunLevel: $($task.Principal.RunLevel)" -ForegroundColor Gray
    Write-Host "      State: $($task.State)" -ForegroundColor Gray
    
    Write-Host ""
    $keep = Read-Host "Desea mantener esta tarea de prueba? (Y/N)"
    if ($keep -ne 'Y') {
        Unregister-ScheduledTask -TaskName "S4UTest_Final" -Confirm:$false
        Write-Host "    Tarea eliminada" -ForegroundColor Gray
    }
} catch {
    Write-Host "    FALLO: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "RECOMENDACION: Usar LogonType Interactive como alternativa" -ForegroundColor Yellow
}
Write-Host ""

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "TROUBLESHOOTING COMPLETADO" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
