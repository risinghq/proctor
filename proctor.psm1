# Shared functions for proctor's install and uninstall entry points.
# Pure functions (config resolution, template expansion, XML building) take
# values and return values; every function that touches the system is named
# after what it changes.

function Get-ConfigValue {
    param(
        [hashtable]$Parameters,
        [hashtable]$File,
        [string]$Name,
        [string]$Default
    )

    if ($Parameters.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace([string]$Parameters[$Name])) {
        return ([string]$Parameters[$Name]).Trim()
    }
    if ($File.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace([string]$File[$Name])) {
        return ([string]$File[$Name]).Trim()
    }
    return $Default
}

function Read-ProctorConfigFile {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Config file not found: $Path"
    }

    $json = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $values = @{}
    foreach ($property in $json.PSObject.Properties) {
        $values[$property.Name] = [string]$property.Value
    }
    return $values
}

function Resolve-ProctorConfig {
    [CmdletBinding()]
    param(
        [hashtable]$Parameters = @{},
        [hashtable]$File = @{}
    )

    $server = Get-ConfigValue -Parameters $Parameters -File $File -Name 'Server' -Default $null
    $share = Get-ConfigValue -Parameters $Parameters -File $File -Name 'Share' -Default $null
    $userPrefix = Get-ConfigValue -Parameters $Parameters -File $File -Name 'UserPrefix' -Default 'Alumno'
    $deviceNumber = Get-ConfigValue -Parameters $Parameters -File $File -Name 'DeviceNumber' -Default $null
    $examTitle = Get-ConfigValue -Parameters $Parameters -File $File -Name 'ExamTitle' -Default $null
    $language = Get-ConfigValue -Parameters $Parameters -File $File -Name 'Language' -Default 'es'
    $shareUser = Get-ConfigValue -Parameters $Parameters -File $File -Name 'ShareUser' -Default $null

    # Share accepts either a path under the server ("sidera\Examenes") or a
    # full UNC ("\\server\sidera\Examenes"); in the UNC form the server inside
    # it must agree with -Server.
    if (-not [string]::IsNullOrWhiteSpace($share) -and $share.StartsWith('\\')) {
        $parts = $share.TrimStart('\').Split('\', 2)
        if ($parts.Count -lt 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
            throw "Share must include a path after the server name: '$share'"
        }
        if (-not [string]::IsNullOrWhiteSpace($server) -and $server -ne $parts[0]) {
            throw "Server '$server' does not match the share '$share'"
        }
        $server = $parts[0]
        $share = $parts[1]
    }

    if ([string]::IsNullOrWhiteSpace($server)) {
        throw 'Server is required (parameter or config file)'
    }
    if ([string]::IsNullOrWhiteSpace($share)) {
        throw 'Share is required (parameter or config file)'
    }
    if ([string]::IsNullOrWhiteSpace($deviceNumber) -or $deviceNumber -notmatch '^\d{2}$') {
        throw "DeviceNumber must be two digits, got '$deviceNumber'"
    }
    if ([string]::IsNullOrWhiteSpace($examTitle)) {
        throw 'ExamTitle is required (parameter or config file)'
    }
    if ($language -notin 'es', 'en') {
        throw "Language must be 'es' or 'en', got '$language'"
    }
    if ($userPrefix -notmatch '^[A-Za-z][A-Za-z0-9_-]*$') {
        throw "UserPrefix must start with a letter and contain only letters, digits, '-' or '_': '$userPrefix'"
    }

    $share = $share -replace '/', '\'
    $share = $share.Trim('\')
    $userName = "$userPrefix-$deviceNumber"

    if ($userName.Length -gt 20) {
        throw "User name '$userName' is longer than 20 characters"
    }

    $deviceFolder = '{0} {1}' -f (@{ es = 'Dispositivo'; en = 'Device' })[$language], $deviceNumber

    [pscustomobject]@{
        Server        = $server
        Share         = $share
        UserPrefix    = $userPrefix
        DeviceNumber  = $deviceNumber
        ExamTitle     = $examTitle
        Language      = $language
        UserName      = $userName
        DeviceFolder  = $deviceFolder
        NetworkPath   = "\\$server\$share\$deviceFolder"
        ShareUser     = $shareUser
        KioskDir      = 'C:\Kiosk'
        DataDir       = 'C:\ProgramData\proctor'
        KioskUrl      = 'file:///C:/Kiosk/index.html'
        TaskName      = "ExamSync-$userName"
        BlockRuleName = "BlockInternet-$userName"
    }
}

function Get-UninstallUserName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$UserName,
        [hashtable]$Parameters = @{},
        [hashtable]$File = @{}
    )

    if (-not [string]::IsNullOrWhiteSpace($UserName)) {
        return $UserName
    }

    $prefix = Get-ConfigValue -Parameters $Parameters -File $File -Name 'UserPrefix' -Default 'Alumno'
    $deviceNumber = Get-ConfigValue -Parameters $Parameters -File $File -Name 'DeviceNumber' -Default $null
    if ([string]::IsNullOrWhiteSpace($deviceNumber) -or $deviceNumber -notmatch '^\d{2}$') {
        throw 'DeviceNumber or UserName is required'
    }
    return "$prefix-$deviceNumber"
}

function Expand-ProctorTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][hashtable]$Values
    )

    $result = $Text
    foreach ($key in $Values.Keys) {
        $result = $result.Replace("{{$key}}", [string]$Values[$key])
    }
    if ($result -match '\{\{[A-Za-z]+\}\}') {
        throw "Template token '$($Matches[0])' has no value"
    }
    return $result
}

function Get-LockdownMode {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$EditionId)

    # Server editions (incl. ServerEnterprise) have no supported Assigned
    # Access bridge; check them before the client-edition match.
    if ($EditionId -like 'Server*' -or $EditionId -like 'AzureStack*' -or $EditionId -like 'HyperV*') {
        return 'RegistryLockdown'
    }
    if ($EditionId -match '^Professional|^Education|^IoTEnterprise|^Enterprise') {
        return 'AssignedAccess'
    }
    return 'RegistryLockdown'
}

function Get-WindowsEditionId {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID).EditionID
}

function Get-EdgeInstallPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }
    return $candidates[0]
}

function Get-KioskCommandLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Config)

    '"{0}" --kiosk "{1}" --edge-kiosk-type=fullscreen --no-first-run' -f (Get-EdgeInstallPath), $Config.KioskUrl
}

function ConvertTo-AssignedAccessXml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$KioskUrl,
        [Parameter(Mandatory)][string]$EdgePath
    )

    $arguments = "--kiosk $KioskUrl --edge-kiosk-type=fullscreen --no-first-run"
    $profileId = '{9A2A490F-10F6-4764-974A-43B19E722C23}'

    @"
<?xml version="1.0" encoding="utf-8"?>
<AssignedAccessConfiguration
    xmlns="http://schemas.microsoft.com/AssignedAccess/2017/config"
    xmlns:v4="http://schemas.microsoft.com/AssignedAccess/2021/config">
  <Profiles>
    <Profile Id="$profileId">
      <KioskModeApp v4:ClassicAppPath="$EdgePath" v4:ClassicAppArguments="$arguments" />
    </Profile>
  </Profiles>
  <Configs>
    <Config>
      <Account>$UserName</Account>
      <DefaultProfile Id="$profileId" />
    </Config>
  </Configs>
</AssignedAccessConfiguration>
"@
}

function Enable-TaskHistory {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $log = Get-WinEvent -ListLog 'Microsoft-Windows-TaskScheduler/Operational'
    if (-not $log.IsEnabled) {
        if ($PSCmdlet.ShouldProcess('Microsoft-Windows-TaskScheduler/Operational', 'enable log')) {
            $log.IsEnabled = $true
            $log.SaveChanges()
        }
    }
}

function New-KioskFolder {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)

    if ($PSCmdlet.ShouldProcess($Path, 'create kiosk folders')) {
        New-Item -Path "$Path\Logs" -ItemType Directory -Force | Out-Null
    }
}

function Set-KioskAcl {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$UserName
    )

    if ($PSCmdlet.ShouldProcess($Path, "grant ReadAndExecute to $UserName")) {
        $acl = Get-Acl -Path $Path
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $UserName, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl -Path $Path -AclObject $acl
    }
}

function Set-StudentAccount {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$UserName)

    $user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if ($null -eq $user) {
        if ($PSCmdlet.ShouldProcess($UserName, 'create local account without password')) {
            $user = New-LocalUser -Name $UserName -NoPassword -FullName $UserName `
                -Description 'Proctor exam account' -AccountNeverExpires
        }
    }
    if ($PSCmdlet.ShouldProcess($UserName, 'enable local account')) {
        Enable-LocalUser -Name $UserName
    }
    return (Get-LocalUser -Name $UserName).SID.Value
}

function New-LocalProfile {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Sid,
        [Parameter(Mandatory)][string]$UserName
    )

    $existingProfile = Get-CimInstance Win32_UserProfile -Filter "SID='$Sid'" -ErrorAction SilentlyContinue
    if ($existingProfile) {
        return $existingProfile.LocalPath
    }

    if ($PSCmdlet.ShouldProcess($UserName, 'create profile')) {
        # userenv!CreateProfile builds the profile without an interactive logon.
        if (-not ('Proctor.Native.UserEnv' -as [type])) {
            $signature = @'
[DllImport("userenv.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern int CreateProfile(
    [MarshalAs(UnmanagedType.LPWStr)] string pszUserSid,
    [MarshalAs(UnmanagedType.LPWStr)] string pszUserName,
    [MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszProfilePath,
    uint cchProfilePath);
'@
            Add-Type -MemberDefinition $signature -Name UserEnv -Namespace Proctor.Native
        }
        # MAX_PATH: cchProfilePath above 260 makes the RPC stub fail the call.
        $buffer = New-Object System.Text.StringBuilder -ArgumentList 260
        $hresult = [Proctor.Native.UserEnv]::CreateProfile($Sid, $UserName, $buffer, 260)
        if ($hresult -eq 0) {
            return $buffer.ToString()
        }
        if ($hresult -eq 0x800700B7) {
            $created = Get-CimInstance Win32_UserProfile -Filter "SID='$Sid'" -ErrorAction SilentlyContinue
            if ($created) {
                return $created.LocalPath
            }
        }
        [System.Runtime.InteropServices.Marshal]::ThrowExceptionForHR($hresult)
    }
}

function Set-AutoLogon {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$UserName)

    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    if ($PSCmdlet.ShouldProcess($winlogon, "set auto-logon for $UserName")) {
        Set-ItemProperty -Path $winlogon -Name 'AutoAdminLogon' -Value '1' -Type String
        Set-ItemProperty -Path $winlogon -Name 'DefaultUserName' -Value $UserName -Type String
        Set-ItemProperty -Path $winlogon -Name 'DefaultDomainName' -Value $env:COMPUTERNAME -Type String
        Set-ItemProperty -Path $winlogon -Name 'DefaultPassword' -Value '' -Type String
        Remove-ItemProperty -Path $winlogon -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
    }
}

function Clear-AutoLogon {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    if ($PSCmdlet.ShouldProcess($winlogon, 'clear auto-logon')) {
        Set-ItemProperty -Path $winlogon -Name 'AutoAdminLogon' -Value '0' -Type String
        foreach ($name in 'DefaultUserName', 'DefaultDomainName', 'DefaultPassword', 'AutoLogonCount', 'ForceAutoLogon') {
            Remove-ItemProperty -Path $winlogon -Name $name -ErrorAction SilentlyContinue
        }
    }
}

function Mount-UserHive {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Sid)

    $live = "Registry::HKEY_USERS\$Sid"
    if (Test-Path $live) {
        return @{ Root = $live; HiveName = $null }
    }

    $existingProfile = Get-CimInstance Win32_UserProfile -Filter "SID='$Sid'" -ErrorAction SilentlyContinue
    if (-not $existingProfile) {
        throw "No profile exists for SID $Sid"
    }
    $ntuser = Join-Path $existingProfile.LocalPath 'NTUSER.DAT'
    if (-not (Test-Path $ntuser)) {
        throw "NTUSER.DAT not found at $ntuser"
    }

    $hiveName = "ProctorHive_$Sid"
    & reg.exe load "HKLM\$hiveName" $ntuser | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "reg load failed for $ntuser"
    }
    return @{ Root = "Registry::HKEY_LOCAL_MACHINE\$hiveName"; HiveName = $hiveName }
}

function Dismount-UserHive {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][hashtable]$Hive)

    if ($null -eq $Hive.HiveName) {
        return
    }
    if ($PSCmdlet.ShouldProcess($Hive.HiveName, 'unload registry hive')) {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        & reg.exe unload "HKLM\$($Hive.HiveName)" | Out-Null
    }
}

function Set-EdgePolicy {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$HiveRoot,
        [Parameter(Mandatory)][string]$KioskUrl
    )

    if (-not $PSCmdlet.ShouldProcess("$HiveRoot\Software\Policies\Microsoft\Edge", 'set Edge policies')) {
        return
    }

    $edgeKey = "$HiveRoot\Software\Policies\Microsoft\Edge"
    if (-not (Test-Path $edgeKey)) {
        New-Item -Path $edgeKey -Force | Out-Null
    }

    $policies = @{
        'PrintingEnabled'              = 0
        'AllowFileSelectionDialogs'    = 0
        'DownloadRestrictions'         = 3
        'HideFirstRunExperience'       = 1
        'BrowserSignin'                = 0
        'SyncDisabled'                 = 1
        'ContextMenuEnabled'           = 0
        'SavingBrowserHistoryDisabled' = 1
        'DiskCacheSize'                = 1
        'ClearBrowsingDataOnExit'      = 1
        'DefaultCookiesSetting'        = 4
        'SitePerProcess'               = 0
        'AllowFileAccessFromFiles'     = 1
        'RestoreOnStartup'             = 4
    }
    foreach ($policy in $policies.GetEnumerator()) {
        Set-ItemProperty -Path $edgeKey -Name $policy.Key -Value $policy.Value -Type DWord
    }

    Set-ItemProperty -Path $edgeKey -Name 'NewTabPageLocation' -Value $KioskUrl -Type String

    $clearListKey = "$edgeKey\ClearBrowsingDataOnExitList"
    if (-not (Test-Path $clearListKey)) {
        New-Item -Path $clearListKey -Force | Out-Null
    }
    foreach ($name in 'browsing_history', 'download_history', 'cookies_and_other_site_data', 'cached_images_and_files') {
        Set-ItemProperty -Path $clearListKey -Name $name -Value $name -Type String
    }

    $startupKey = "$edgeKey\RestoreOnStartupURLs"
    if (-not (Test-Path $startupKey)) {
        New-Item -Path $startupKey -Force | Out-Null
    }
    Set-ItemProperty -Path $startupKey -Name '1' -Value $KioskUrl -Type String
}

function Set-ExplorerRestriction {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$HiveRoot)

    if ($PSCmdlet.ShouldProcess($HiveRoot, 'set shell restrictions (NoRun, DisableCMD, DisableTaskMgr)')) {
        $explorerKey = "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
        if (-not (Test-Path $explorerKey)) {
            New-Item -Path $explorerKey -Force | Out-Null
        }
        Set-ItemProperty -Path $explorerKey -Name 'NoRun' -Value 1 -Type DWord

        $systemKey = "$HiveRoot\Software\Policies\Microsoft\Windows\System"
        if (-not (Test-Path $systemKey)) {
            New-Item -Path $systemKey -Force | Out-Null
        }
        Set-ItemProperty -Path $systemKey -Name 'DisableCMD' -Value 1 -Type DWord

        $policiesSystemKey = "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Policies\System"
        if (-not (Test-Path $policiesSystemKey)) {
            New-Item -Path $policiesSystemKey -Force | Out-Null
        }
        Set-ItemProperty -Path $policiesSystemKey -Name 'DisableTaskMgr' -Value 1 -Type DWord
    }
}

function Remove-ExplorerRestriction {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$HiveRoot)

    if ($PSCmdlet.ShouldProcess($HiveRoot, 'remove shell restrictions')) {
        $explorerKey = "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
        if (Test-Path $explorerKey) {
            Remove-ItemProperty -Path $explorerKey -Name 'NoRun' -ErrorAction SilentlyContinue
        }

        $systemKey = "$HiveRoot\Software\Policies\Microsoft\Windows\System"
        if (Test-Path $systemKey) {
            Remove-ItemProperty -Path $systemKey -Name 'DisableCMD' -ErrorAction SilentlyContinue
        }

        $policiesSystemKey = "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Policies\System"
        if (Test-Path $policiesSystemKey) {
            Remove-ItemProperty -Path $policiesSystemKey -Name 'DisableTaskMgr' -ErrorAction SilentlyContinue
        }
    }
}

function Remove-EdgePolicy {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$HiveRoot)

    $edgeKey = "$HiveRoot\Software\Policies\Microsoft\Edge"
    if ((Test-Path $edgeKey) -and $PSCmdlet.ShouldProcess($edgeKey, 'remove Edge policies')) {
        Remove-Item -Path $edgeKey -Recurse -Force
    }
}

function Set-KioskAutorun {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$HiveRoot,
        [Parameter(Mandatory)][string]$CommandLine
    )

    $runKey = "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Run"
    if ($PSCmdlet.ShouldProcess($runKey, 'set ProctorKiosk autorun')) {
        if (-not (Test-Path $runKey)) {
            New-Item -Path $runKey -Force | Out-Null
        }
        Set-ItemProperty -Path $runKey -Name 'ProctorKiosk' -Value $CommandLine -Type String
    }
}

function Remove-KioskAutorun {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$HiveRoot)

    $runKey = "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Run"
    if ((Test-Path $runKey) -and $PSCmdlet.ShouldProcess($runKey, 'remove ProctorKiosk autorun')) {
        Remove-ItemProperty -Path $runKey -Name 'ProctorKiosk' -ErrorAction SilentlyContinue
    }
}

function Set-FirewallLockdown {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Sid,
        [Parameter(Mandatory)][string]$BlockRuleName
    )

    if (-not $PSCmdlet.ShouldProcess($BlockRuleName, 'replace firewall rule')) {
        return
    }

    # One rule: the student gets no outbound at all. The sync task runs as
    # SYSTEM, so an SMB exception would only let the student read other
    # devices' exam folders.
    Get-NetFirewallRule -DisplayName $BlockRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule

    New-NetFirewallRule -DisplayName $BlockRuleName `
        -Direction Outbound `
        -Action Block `
        -LocalUser "D:(A;;CC;;;$Sid)" | Out-Null
}

function Remove-FirewallLockdown {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$BlockRuleName)

    if ($PSCmdlet.ShouldProcess($BlockRuleName, 'remove firewall rule')) {
        Get-NetFirewallRule -DisplayName $BlockRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    }
}

function Set-ProctorDataAcl {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)

    if ($PSCmdlet.ShouldProcess($Path, 'restrict ACL to SYSTEM and Administrators')) {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
            $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -Path $Path -AclObject $acl
    }
}

function Install-ShareCredential {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$DataDir
    )

    if (-not $PSCmdlet.ShouldProcess("$DataDir\share.cred", 'store share credential')) {
        return
    }

    Add-Type -AssemblyName System.Security
    New-Item -Path $DataDir -ItemType Directory -Force | Out-Null
    Set-ProctorDataAcl -Path $DataDir

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Credential.GetNetworkCredential().Password)
    $blob = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    $content = $Credential.UserName + "`n" + [Convert]::ToBase64String($blob)
    Set-Content -Path (Join-Path $DataDir 'share.cred') -Value $content -Encoding ASCII
}

function Remove-ProctorData {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$DataDir)

    if ((Test-Path $DataDir) -and $PSCmdlet.ShouldProcess($DataDir, 'remove proctor data')) {
        Remove-Item $DataDir -Recurse -Force
    }
}

function Invoke-SystemTask {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$ResultPath
    )

    # The MDM WMI bridge only accepts calls from a SYSTEM token, so the apply
    # and clear run inside a one-shot scheduled task and report through a file.
    if (Test-Path $ResultPath) {
        Remove-Item $ResultPath -Force
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass $Arguments"
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' `
        -LogonType ServiceAccount -RunLevel Highest

    if (-not $PSCmdlet.ShouldProcess($TaskName, 'run as SYSTEM')) {
        return
    }

    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal | Out-Null
    try {
        Start-ScheduledTask -TaskName $TaskName
        $deadline = (Get-Date).AddMinutes(2)
        do {
            Start-Sleep -Seconds 2
            $state = (Get-ScheduledTask -TaskName $TaskName).State
        } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)
    }
    finally {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $ResultPath)) {
        throw "System task '$TaskName' produced no result at $ResultPath (last state: $state)"
    }
    $result = (Get-Content -Path $ResultPath -Raw).Trim()
    if ($result -ne 'ok') {
        throw $result
    }
}

function Set-AssignedAccessKiosk {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$HelperPath
    )

    $edgePath = Get-EdgeInstallPath
    $xml = ConvertTo-AssignedAccessXml -UserName $Config.UserName -KioskUrl $Config.KioskUrl -EdgePath $edgePath

    New-Item -Path $Config.DataDir -ItemType Directory -Force | Out-Null
    Set-ProctorDataAcl -Path $Config.DataDir
    $xmlPath = Join-Path $Config.DataDir 'assigned-access.xml'
    Set-Content -Path $xmlPath -Value $xml -Encoding UTF8

    Invoke-SystemTask -TaskName 'ProctorAssignedAccessApply' `
        -Arguments "-File `"$HelperPath`" -Apply `"$xmlPath`" -Result `"$($Config.DataDir)\aa-result.txt`"" `
        -ResultPath "$($Config.DataDir)\aa-result.txt"
}

function Clear-AssignedAccessKiosk {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$DataDir,
        [Parameter(Mandatory)][string]$HelperPath
    )

    New-Item -Path $DataDir -ItemType Directory -Force | Out-Null
    Set-ProctorDataAcl -Path $DataDir

    Invoke-SystemTask -TaskName 'ProctorAssignedAccessClear' `
        -Arguments "-File `"$HelperPath`" -Clear -Result `"$DataDir\aa-clear.txt`"" `
        -ResultPath "$DataDir\aa-clear.txt"
}

function Install-KioskFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SourceRoot
    )

    $values = @{
        ExamTitle   = $Config.ExamTitle
        UserName    = $Config.UserName
        Language    = $Config.Language
        NetworkPath = $Config.NetworkPath
    }

    foreach ($name in 'index.html', 'sync-exam.ps1') {
        $source = Join-Path $SourceRoot "src\$name"
        $content = Get-Content -Path $source -Raw -Encoding UTF8
        # Escaping is per file type: HTML values must not become markup;
        # ps1 templates place tokens inside single-quoted strings, so the
        # only escape needed is a doubled quote.
        $escaped = @{}
        foreach ($key in $values.Keys) {
            if ($name -eq 'index.html') {
                $escaped[$key] = [System.Net.WebUtility]::HtmlEncode([string]$values[$key])
            } else {
                $escaped[$key] = ([string]$values[$key]) -replace "'", "''"
            }
        }
        $filled = Expand-ProctorTemplate -Text $content -Values $escaped
        $destination = Join-Path $Config.KioskDir $name
        if ($PSCmdlet.ShouldProcess($destination, 'write file')) {
            Set-Content -Path $destination -Value $filled -Encoding UTF8
        }
    }
}

function Register-SyncTask {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$ScriptPath
    )

    if (-not $PSCmdlet.ShouldProcess($TaskName, 'register scheduled task')) {
        return
    }

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $trigger.Repetition.StopAtDurationEnd = $false

    # SYSTEM: an S4U token carries no network credentials, and Windows 11 24H2
    # refuses guest and anonymous SMB by default. SYSTEM connects to the share
    # with the credential stored under $DataDir.
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings | Out-Null
}

function Remove-SyncTask {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$TaskName)

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task -and $PSCmdlet.ShouldProcess($TaskName, 'unregister scheduled task')) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
}

function Remove-UserLockdown {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Sid)

    # On a partial install there may be no profile yet; nothing to clean.
    if (-not (Get-CimInstance Win32_UserProfile -Filter "SID='$Sid'" -ErrorAction SilentlyContinue) -and
        -not (Test-Path "Registry::HKEY_USERS\$Sid")) {
        return
    }

    $hive = Mount-UserHive -Sid $Sid
    try {
        Remove-EdgePolicy -HiveRoot $hive.Root
        Remove-ExplorerRestriction -HiveRoot $hive.Root
        Remove-KioskAutorun -HiveRoot $hive.Root
    }
    finally {
        Dismount-UserHive -Hive $hive
    }
}

function Stop-UserSession {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$UserName)

    # quser prints one row per session: USERNAME, optional SESSIONNAME, ID, ...
    $rows = & quser.exe 2>$null | Select-Object -Skip 1
    foreach ($row in $rows) {
        if ($row -match '^\s*>?(\S+)\s+(?:\S+\s+)?(\d+)\s+' -and $Matches[1] -eq $UserName) {
            if ($PSCmdlet.ShouldProcess($UserName, "log off session $($Matches[2])")) {
                & logoff.exe $Matches[2]
            }
        }
    }
}

function Remove-UserProfile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Sid,
        [int]$TimeoutSeconds = 60
    )

    # The User Profile Service unloads a hive some seconds after its last
    # logon session ends; until then deletion fails with 0x80070020.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $userProfile = Get-CimInstance Win32_UserProfile -Filter "SID='$Sid'" -ErrorAction SilentlyContinue
        if ($null -eq $userProfile -or -not $PSCmdlet.ShouldProcess($Sid, 'remove profile')) {
            return
        }
        try {
            $userProfile | Remove-CimInstance -ErrorAction Stop
            return
        }
        catch {
            if ((Get-Date) -ge $deadline) {
                throw "Profile $Sid is still loaded after $TimeoutSeconds s: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds 3
        }
    }
}

function Remove-StudentAccount {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$UserName
    )

    $user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if ($null -eq $user) {
        return
    }

    if (-not $PSCmdlet.ShouldProcess($UserName, 'remove local account and profile')) {
        return
    }

    Stop-UserSession -UserName $UserName
    Remove-UserProfile -Sid $user.SID.Value

    Remove-LocalUser -Name $UserName

    $leftover = "C:\Users\$UserName"
    if (Test-Path $leftover) {
        Remove-Item $leftover -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-KioskFolder {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)

    if ((Test-Path $Path) -and $PSCmdlet.ShouldProcess($Path, 'remove kiosk folder')) {
        Remove-Item $Path -Recurse -Force
    }
}

Export-ModuleMember -Function @(
    'Read-ProctorConfigFile',
    'Resolve-ProctorConfig',
    'Get-UninstallUserName',
    'Expand-ProctorTemplate',
    'Get-LockdownMode',
    'Get-WindowsEditionId',
    'Get-EdgeInstallPath',
    'Get-KioskCommandLine',
    'ConvertTo-AssignedAccessXml',
    'Enable-TaskHistory',
    'New-KioskFolder',
    'Set-KioskAcl',
    'Set-StudentAccount',
    'New-LocalProfile',
    'Set-AutoLogon',
    'Clear-AutoLogon',
    'Mount-UserHive',
    'Dismount-UserHive',
    'Set-EdgePolicy',
    'Remove-EdgePolicy',
    'Set-ExplorerRestriction',
    'Remove-ExplorerRestriction',
    'Set-KioskAutorun',
    'Remove-KioskAutorun',
    'Set-FirewallLockdown',
    'Remove-FirewallLockdown',
    'Set-ProctorDataAcl',
    'Install-ShareCredential',
    'Remove-ProctorData',
    'Invoke-SystemTask',
    'Set-AssignedAccessKiosk',
    'Clear-AssignedAccessKiosk',
    'Install-KioskFile',
    'Register-SyncTask',
    'Remove-SyncTask',
    'Remove-UserLockdown',
    'Remove-StudentAccount',
    'Remove-KioskFolder'
)
