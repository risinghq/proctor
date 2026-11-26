param(
    [string]$Apply,
    [switch]$Clear,
    [Parameter(Mandatory)][string]$Result
)

# Runs as SYSTEM from a one-shot scheduled task: the MDM WMI bridge refuses
# calls from any other token.
$ErrorActionPreference = 'Stop'

try {
    try {
        $bridge = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_AssignedAccess' -ErrorAction Stop
    }
    catch {
        $bridge = $null
        if (-not $Clear) {
            throw
        }
    }
    if ($null -eq $bridge) {
        if ($Clear) {
            Set-Content -Path $Result -Value 'ok'
            exit 0
        }
        throw 'MDM_AssignedAccess is not available on this edition'
    }

    if ($Clear) {
        Set-CimInstance -InputObject $bridge -Property @{ Configuration = $null }
    }
    else {
        $xml = Get-Content -Path $Apply -Raw -Encoding UTF8
        $encoded = [System.Net.WebUtility]::HtmlEncode($xml)
        Set-CimInstance -InputObject $bridge -Property @{ Configuration = $encoded }
    }

    Set-Content -Path $Result -Value 'ok'
}
catch {
    Set-Content -Path $Result -Value ($_ | Out-String)
    exit 1
}
