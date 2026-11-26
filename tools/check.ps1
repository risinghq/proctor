param([Parameter(Mandatory)][ValidateSet('lint', 'test')][string]$Task)

Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
foreach ($m in 'PSScriptAnalyzer', 'Pester') {
    if (-not (Get-Module -ListAvailable $m)) {
        Set-PSRepository PSGallery -InstallationPolicy Trusted
        Install-Module $m -Scope CurrentUser -Force
    }
}

if ($Task -eq 'lint') {
    $findings = Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
    $findings | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize | Out-String -Width 200
    if ($findings) { exit 1 }
}
else {
    $result = Invoke-Pester -Path ./tests/Proctor.Tests.ps1 -Output Detailed -PassThru
    if ($result.FailedCount -gt 0) { exit 1 }
}
