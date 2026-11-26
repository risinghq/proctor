$ErrorActionPreference = "Stop"

$kioskPath = "C:\Kiosk"
$logsPath = "$kioskPath\Logs"
$networkPath = '{{NetworkPath}}'
$credFile = "C:\ProgramData\proctor\share.cred"
$localPdf = "$kioskPath\Exam.pdf"
$logFile = "$logsPath\sync_$(Get-Date -Format 'yyyyMMdd').log"

function Write-SyncLog {
    param([string]$level, [string]$message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logFile -Value "[$timestamp] [$level] $message"
}

function Get-ShareCredential {
    if (!(Test-Path $credFile)) { return $null }

    Add-Type -AssemblyName System.Security
    $lines = Get-Content $credFile
    $blob = [Convert]::FromBase64String($lines[1])
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $blob, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    $secure = New-Object System.Security.SecureString
    foreach ($c in [System.Text.Encoding]::UTF8.GetString($bytes).ToCharArray()) {
        $secure.AppendChar($c)
    }
    return New-Object System.Management.Automation.PSCredential -ArgumentList $lines[0], $secure
}

function Get-NetworkPdf {
    param([string]$path)
    if (!(Test-Path $path)) { return $null }

    $pdfs = Get-ChildItem -Path $path -Filter "*.pdf"
    if ($pdfs.Count -eq 0) { return $null }

    return $pdfs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

$drive = $null
try {
    $credential = Get-ShareCredential
    if ($credential) {
        # Mount the share root, not the device folder: a missing device folder
        # is an empty source, an unreachable share is a failure.
        $shareRoot = Split-Path $networkPath -Parent
        $deviceName = Split-Path $networkPath -Leaf
        $drive = New-PSDrive -Name 'ProctorShare' -PSProvider FileSystem -Root $shareRoot -Credential $credential
        $examPath = "ProctorShare:\$deviceName"
    } else {
        $examPath = $networkPath
    }

    if (!(Test-Path $examPath)) {
        # Test-Path alone cannot tell an absent folder from a dead share; the
        # parent must be reachable before the source counts as empty.
        $parent = Split-Path $examPath -Parent
        if (!(Test-Path $parent)) {
            throw "Share not reachable: $parent"
        }
        $networkPdf = $null
    } else {
        $networkPdf = Get-NetworkPdf -path $examPath
    }

    # Mirror local state to network state
    if ($null -eq $networkPdf) {
        if (Test-Path $localPdf) {
            Remove-Item $localPdf -Force
            Write-SyncLog "INFO" "PDF local eliminado (red vacia)"
        }
        exit 0
    }

    $needsCopy = $false

    if (!(Test-Path $localPdf)) {
        $needsCopy = $true
    } else {
        $localHash = (Get-FileHash $localPdf -Algorithm SHA256).Hash
        $networkHash = (Get-FileHash $networkPdf.FullName -Algorithm SHA256).Hash
        $needsCopy = $localHash -ne $networkHash
    }

    if ($needsCopy) {
        Copy-Item -Path $networkPdf.FullName -Destination $localPdf -Force
        Write-SyncLog "INFO" "PDF sincronizado: $($networkPdf.Name)"
    }
} catch {
    try {
        Write-SyncLog "ERROR" "Fallo de sincronizacion: $($_.Exception.Message)"
    } catch {
        Write-Error $_
    }
    exit 1
} finally {
    if ($drive) {
        Remove-PSDrive -Name 'ProctorShare' -Force -ErrorAction SilentlyContinue
    }
}
