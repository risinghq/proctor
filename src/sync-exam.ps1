$ErrorActionPreference = "Stop"

$kioskPath = "C:\Kiosk"
$logsPath = "$kioskPath\Logs"
$networkPath = '{{NetworkPath}}'
# Exam content goes to the data folder: its ACL allows SYSTEM and
# Administrators only, so the student cannot read the PDF before it opens.
$dataPath = "C:\ProgramData\proctor"
$examRoot = "$dataPath\exam"
$credFile = "$dataPath\share.cred"
$logFile = "$logsPath\sync_$(Get-Date -Format 'yyyyMMdd').log"

Import-Module (Join-Path $PSScriptRoot 'proctor.psm1') -Force

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
        $networkExamJson = $null
    } else {
        $networkPdf = Get-NetworkPdf -path $examPath
        # Null means "confirmed absent": the folder is reachable and
        # Test-Path reports the file is gone with no error. Any access or
        # read error throws instead, so a denied exam.json keeps the cached
        # schedule rather than failing open to an unscheduled exam.
        $examJsonShare = Join-Path $examPath 'exam.json'
        $networkExamJson = $null
        if (Test-Path $examJsonShare -ErrorAction Stop) {
            $networkExamJson = Get-Item -Path $examJsonShare -ErrorAction Stop
        }
    }

    # A new version lands in its own folder and becomes visible only when
    # current.txt is swapped, so a request always sees a consistent
    # exam.json/Exam.pdf pair. A failure before the swap changes nothing.
    $currentDir = Resolve-ExamVersion -DataDir $dataPath
    if (Test-ExamVersionChanged -CurrentDir $currentDir -NetworkPdf $networkPdf -NetworkExamJson $networkExamJson) {
        $versionName = Get-Date -Format 'yyyyMMddHHmmssfff'
        $newDir = Join-Path $examRoot $versionName
        try {
            New-Item -Path $newDir -ItemType Directory -Force | Out-Null
            if ($networkPdf) {
                Copy-Item -Path $networkPdf.FullName -Destination (Join-Path $newDir 'Exam.pdf') -Force
                Write-SyncLog "INFO" "Exam.pdf synced: $($networkPdf.Name)"
            }
            if ($networkExamJson) {
                Copy-Item -Path $networkExamJson.FullName -Destination (Join-Path $newDir 'exam.json') -Force
                Write-SyncLog "INFO" "exam.json synced"
            }
        } catch {
            Remove-Item -Path $newDir -Recurse -Force -ErrorAction SilentlyContinue
            throw
        }

        $tmp = Join-Path $examRoot 'current.tmp'
        $pointer = Join-Path $examRoot 'current.txt'
        Set-Content -Path $tmp -Value $versionName -NoNewline -Encoding ASCII
        if (Test-Path $pointer) {
            [System.IO.File]::Replace($tmp, $pointer, $null)
        } else {
            Move-Item -Path $tmp -Destination $pointer -Force
        }
        Write-SyncLog "INFO" "published version $versionName"

        $names = (Get-ChildItem -Path $examRoot -Directory).Name
        foreach ($old in Get-ExamVersionsToPrune -Names $names -Current $versionName) {
            Remove-Item -Path (Join-Path $examRoot $old) -Recurse -Force
        }
    } else {
        Write-SyncLog "INFO" "exam files unchanged"
    }
} catch {
    try {
        Write-SyncLog "ERROR" "Sync failed: $($_.Exception.Message)"
    } catch {
        Write-Error $_
    }
    exit 1
} finally {
    if ($drive) {
        Remove-PSDrive -Name 'ProctorShare' -Force -ErrorAction SilentlyContinue
    }
}
