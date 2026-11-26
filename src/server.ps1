param(
    [int]$Port = 8471,
    [string]$KioskDir = 'C:\Kiosk',
    [string]$DataDir = 'C:\ProgramData\proctor'
)

$ErrorActionPreference = 'Stop'

# Exam content lives in the data folder, restricted to SYSTEM and
# Administrators; the student-readable kiosk folder holds only page files.
$kioskPath = $KioskDir
$logsPath = Join-Path $kioskPath 'Logs'
$indexPath = Join-Path $kioskPath 'index.html'
$logFile = Join-Path $logsPath "server_$(Get-Date -Format 'yyyyMMdd').log"

Import-Module (Join-Path $PSScriptRoot 'proctor.psm1') -Force

function Write-ServerLog {
    param([string]$Level, [string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logFile -Value "[$timestamp] [$Level] $Message"
}

function Send-Response {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][int]$StatusCode,
        [byte[]]$Bytes = @(),
        [string]$ContentType = 'text/plain; charset=utf-8'
    )
    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = $ContentType
    if ($Bytes.Length -gt 0) {
        $response.ContentLength64 = $Bytes.Length
        $response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    }
    $response.OutputStream.Close()
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-ServerLog 'INFO' "kiosk server listening on http://127.0.0.1:$Port/"

$script:pdfVersion = $null
$script:pdfVersionKey = $null
$script:lastBadJson = $null

function Get-KioskState {
    # $VersionDir is the one folder the request resolved from current.txt;
    # state and PDF come from that same version, so a sync swapping the
    # pointer can never mix a new PDF with an old schedule.
    param([string]$VersionDir)

    $raw = $null
    $examJsonPath = if ($VersionDir) { Join-Path $VersionDir 'exam.json' } else { $null }
    if ($examJsonPath -and (Test-Path $examJsonPath)) {
        $raw = Get-Content -Path $examJsonPath -Raw -Encoding UTF8
        # Get-Content returns $null for an empty file; an existing file must
        # never read as missing, or a blank schedule would expose the PDF.
        if ($null -eq $raw) { $raw = '' }
    }
    $state = Get-ExamState -Json $raw -Now ([datetimeoffset]::Now)
    if ($state.Malformed -and $raw -ne $script:lastBadJson) {
        Write-ServerLog 'ERROR' 'exam.json is malformed; the exam is blocked until the schedule is fixed'
        $script:lastBadJson = $raw
    }

    # A version folder is complete before it is published and never modified
    # afterwards, so its name alone is a valid cache key for the hash.
    $pdfPath = if ($VersionDir) { Join-Path $VersionDir 'Exam.pdf' } else { $null }
    if ($pdfPath -and (Test-Path $pdfPath)) {
        if ($VersionDir -ne $script:pdfVersionKey) {
            $script:pdfVersionKey = $VersionDir
            $script:pdfVersion = (Get-FileHash -Path $pdfPath -Algorithm SHA256).Hash
        }
    }
    else {
        $script:pdfVersion = $null
        $script:pdfVersionKey = $null
    }
    return $state
}

while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
        $path = $context.Request.Url.AbsolutePath
        if ($path -eq '/' -or $path -eq '/index.html') {
            Send-Response -Context $context -StatusCode 200 `
                -Bytes ([System.IO.File]::ReadAllBytes($indexPath)) `
                -ContentType 'text/html; charset=utf-8'
        }
        elseif ($path -eq '/state') {
            $state = Get-KioskState -VersionDir (Resolve-ExamVersion -DataDir $DataDir)
            $json = @{
                phase            = $state.Phase
                title            = $state.Title
                secondsUntilOpen = $state.SecondsUntilOpen
                secondsLeft      = $state.SecondsLeft
                pdfVersion       = $script:pdfVersion
            } | ConvertTo-Json -Compress
            Send-Response -Context $context -StatusCode 200 `
                -Bytes ([System.Text.Encoding]::UTF8.GetBytes($json)) `
                -ContentType 'application/json; charset=utf-8'
        }
        elseif ($path -eq '/exam.pdf') {
            $versionDir = Resolve-ExamVersion -DataDir $DataDir
            $state = Get-KioskState -VersionDir $versionDir
            $pdfPath = if ($versionDir) { Join-Path $versionDir 'Exam.pdf' } else { $null }
            if ((Test-ExamPdfServable -Phase $state.Phase) -and $pdfPath -and (Test-Path $pdfPath)) {
                Send-Response -Context $context -StatusCode 200 `
                    -Bytes ([System.IO.File]::ReadAllBytes($pdfPath)) `
                    -ContentType 'application/pdf'
            }
            else {
                Send-Response -Context $context -StatusCode 404
            }
        }
        else {
            Send-Response -Context $context -StatusCode 404
        }
    }
    catch {
        Write-ServerLog 'ERROR' "request failed: $($_.Exception.Message)"
        try {
            Send-Response -Context $context -StatusCode 500
        }
        catch {
            Write-ServerLog 'ERROR' "could not send the error response: $($_.Exception.Message)"
        }
    }
}
