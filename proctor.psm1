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
    $port = Get-ConfigValue -Parameters $Parameters -File $File -Name 'Port' -Default '8471'

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
    if ($port -notmatch '^\d+$' -or [int]$port -lt 1 -or [int]$port -gt 65535) {
        throw "Port must be a number between 1 and 65535, got '$port'"
    }
    $port = [int]$port

    $share = $share -replace '/', '\'
    $share = $share.Trim('\')
    $userName = "$userPrefix-$deviceNumber"

    if ($userName.Length -gt 20) {
        throw "User name '$userName' is longer than 20 characters"
    }

    $deviceFolder = '{0} {1}' -f (@{ es = 'Dispositivo'; en = 'Device' })[$language], $deviceNumber

    [pscustomobject]@{
        Server         = $server
        Share          = $share
        UserPrefix     = $userPrefix
        DeviceNumber   = $deviceNumber
        ExamTitle      = $examTitle
        Language       = $language
        UserName       = $userName
        DeviceFolder   = $deviceFolder
        NetworkPath    = "\\$server\$share\$deviceFolder"
        ShareUser      = $shareUser
        Port           = $port
        KioskDir       = 'C:\Kiosk'
        DataDir        = 'C:\ProgramData\proctor'
        KioskUrl       = "http://127.0.0.1:$port/"
        TaskName       = "ExamSync-$userName"
        ServerTaskName = "ExamServer-$userName"
        BlockRuleName  = "BlockInternet-$userName"
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

function Get-ExamState {
    [CmdletBinding()]
    param(
        # [object] keeps $null distinct from '': a missing file is phase
        # 'none', an existing empty or whitespace file is 'error'. A [string]
        # parameter coerces $null to '' and blurs the two.
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Json,
        [Parameter(Mandatory)]
        [datetimeoffset]$Now
    )

    # Phase 'none' is the unscheduled mode: no exam.json at all. A file that
    # exists but cannot be parsed or validated is phase 'error': the caller
    # logs it once per bad version and the exam never opens on a bad schedule.
    $state = [pscustomobject]@{
        Phase            = 'none'
        Title            = $null
        SecondsUntilOpen = $null
        SecondsLeft      = $null
        Malformed        = $false
    }

    if ($null -eq $Json) {
        return $state
    }
    if ([string]::IsNullOrWhiteSpace($Json)) {
        $state.Phase = 'error'
        $state.Malformed = $true
        return $state
    }

    try {
        $spec = $Json | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $spec -or $spec -isnot [pscustomobject]) {
            throw 'exam.json must be a JSON object'
        }
        # The contract is strict ISO-8601 with an explicit Z or +-HH:MM
        # offset at the top level. PS5.1 leaves the values as strings, so
        # a suffix regex plus TryParseExact rejects culture shapes.
        # PS7 converts ISO strings to DateTime: Utc means Z, Local means
        # +-HH:MM, and Unspecified means the source carried no offset.
        $isoFormats = 'yyyy-MM-ddTHH:mm:ssK', 'yyyy-MM-ddTHH:mm:ss.FFFFFFFK'
        $parsed = @{}
        foreach ($name in 'opensAt', 'closesAt') {
            $prop = $spec.PSObject.Properties[$name]
            if ($null -eq $prop) {
                throw "$name must be an ISO-8601 timestamp with an explicit offset"
            }
            $value = $prop.Value
            if ($value -is [datetime]) {
                if ($value.Kind -eq [datetimekind]::Unspecified) {
                    throw "$name must be an ISO-8601 timestamp with an explicit offset"
                }
                $parsed[$name] = [datetimeoffset]$value
            } else {
                $text = [string]$value
                $instant = [datetimeoffset]::MinValue
                if ($text -notmatch '(Z|[+-]\d{2}:\d{2})$' -or
                    -not [datetimeoffset]::TryParseExact($text, [string[]]$isoFormats,
                        [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None,
                        [ref]$instant)) {
                    throw "$name must be an ISO-8601 timestamp with an explicit offset"
                }
                $parsed[$name] = $instant
            }
        }
        $opensAt = $parsed.opensAt
        $closesAt = $parsed.closesAt
        if ($closesAt -le $opensAt) {
            throw 'closesAt must be after opensAt'
        }
    }
    catch {
        $state.Phase = 'error'
        $state.Malformed = $true
        return $state
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$spec.title)) {
        $state.Title = [string]$spec.title
    }

    if ($Now -lt $opensAt) {
        $state.Phase = 'waiting'
        $state.SecondsUntilOpen = [int][math]::Ceiling(($opensAt - $Now).TotalSeconds)
    }
    elseif ($Now -lt $closesAt) {
        $state.Phase = 'open'
        $state.SecondsLeft = [int][math]::Ceiling(($closesAt - $Now).TotalSeconds)
    }
    else {
        $state.Phase = 'closed'
    }
    return $state
}

function Test-ExamPdfServable {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Phase
    )

    # The PDF is served in 'open' and in 'none' (unscheduled exams keep the
    # show-it-whenever-present behavior). It is never served while waiting,
    # closed, or on a broken schedule.
    return $Phase -eq 'open' -or $Phase -eq 'none'
}

function Resolve-ExamVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$DataDir)

    # current.txt names the version folder the sync last published; a request
    # reads exam.json and Exam.pdf only from the folder it resolves to.
    $pointer = Join-Path $DataDir 'exam\current.txt'
    if (-not (Test-Path $pointer)) {
        return $null
    }
    $name = (Get-Content -Path $pointer -Raw).Trim()
    $dir = Join-Path (Join-Path $DataDir 'exam') $name
    if ([string]::IsNullOrWhiteSpace($name) -or -not (Test-Path $dir -PathType Container)) {
        return $null
    }
    return $dir
}

function Get-ExamVersionsToPrune {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string[]]$Names,
        [Parameter(Mandatory)][string]$Current
    )

    # Keeps the current version and the one before it; version names are
    # timestamps, so a sort is a chronological order.
    $sorted = @($Names | Sort-Object)
    $keep = @($sorted | Where-Object { $_ -le $Current } | Sort-Object -Descending | Select-Object -First 2)
    return @($sorted | Where-Object { $_ -notin $keep })
}

function Test-ExamVersionChanged {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$CurrentDir,
        $NetworkPdf,
        $NetworkExamJson
    )

    # A file absent from a reachable share must be absent locally, so a
    # presence change also counts as a change.
    foreach ($pair in @(@($NetworkPdf, 'Exam.pdf'), @($NetworkExamJson, 'exam.json'))) {
        $networkFile = $pair[0]
        $localPath = if ($CurrentDir) { Join-Path $CurrentDir $pair[1] } else { $null }
        if ($null -eq $networkFile) {
            if ($localPath -and (Test-Path $localPath)) { return $true }
        } else {
            if (-not ($localPath -and (Test-Path $localPath))) { return $true }
            $localHash = (Get-FileHash $localPath -Algorithm SHA256).Hash
            $networkHash = (Get-FileHash $networkFile.FullName -Algorithm SHA256).Hash
            if ($localHash -ne $networkHash) { return $true }
        }
    }
    return $false
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
        # PowerShell's registry provider keeps key handles open until they are
        # collected, and reg unload fails while any handle remains.
        foreach ($attempt in 1..5) {
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
            & reg.exe unload "HKLM\$($Hive.HiveName)" 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                return
            }
            Start-Sleep -Seconds 1
        }
        throw "reg unload failed for HKLM\$($Hive.HiveName)"
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
        # The page comes from the kiosk server; nothing should load file://.
        'AllowFileAccessFromFiles'     = 0
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

function Save-ProctorInstallInfo {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Config,
        [bool]$UrlAclCreated = $false,
        $UrlAclSddl = $false
    )

    # The port lives here so uninstall removes the URL ACL install added,
    # even when uninstall is called with only -UserName. urlAclCreated
    # records whether the reservation is Proctor's to delete.
    $path = Join-Path $Config.DataDir 'install.json'
    if ($PSCmdlet.ShouldProcess($path, 'write install metadata')) {
        New-Item -Path $Config.DataDir -ItemType Directory -Force | Out-Null
        Set-ProctorDataAcl -Path $Config.DataDir
        @{ port = $Config.Port; urlAclCreated = $UrlAclCreated; urlAclSddl = $UrlAclSddl } | ConvertTo-Json |
            Set-Content -Path $path -Encoding UTF8
    }
}

function Read-ProctorInstallInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataDir)

    # Missing metadata means an install predates it and the caller falls back
    # to the configured port. An existing but unreadable file must fail loud:
    # guessing the port can leave the real URL ACL behind.
    # Absence must be confirmed, not inferred from an error: an access error
    # on the file or its folder is a failure, never "no metadata".
    $path = Join-Path $DataDir 'install.json'
    if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) {
        return $null
    }
    try {
        $info = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Cannot read install metadata at $path : $($_.Exception.Message). Pass -Port explicitly or fix the file."
    }
    $port = 0
    if ($null -eq $info -or $null -eq $info.port -or
        -not [int]::TryParse([string]$info.port, [ref]$port) -or
        $port -lt 1 -or $port -gt 65535) {
        throw "Install metadata at $path has an invalid port '$($info.port)'. Pass -Port explicitly or fix the file."
    }
    # Older installs record no urlAclCreated; a missing flag must read as
    # false so uninstall never deletes a reservation it cannot prove is ours.
    $aclProperty = $info.PSObject.Properties['urlAclCreated']
    if ($null -eq $aclProperty) {
        $info | Add-Member -NotePropertyName urlAclCreated -NotePropertyValue $false
    }
    elseif ($aclProperty.Value -isnot [bool]) {
        throw "Install metadata at $path has an invalid urlAclCreated '$($info.urlAclCreated)'; it must be true or false. Fix the file."
    }
    $sddlProperty = $info.PSObject.Properties['urlAclSddl']
    if ($null -eq $sddlProperty) {
        $info | Add-Member -NotePropertyName urlAclSddl -NotePropertyValue $false
    }
    else {
        $sddl = $sddlProperty.Value
        $isValid = ($sddl -is [string] -and -not [string]::IsNullOrWhiteSpace($sddl)) -or
            ($sddl -is [bool] -and -not $sddl)
        if (-not $isValid) {
            throw "Install metadata at $path has an invalid urlAclSddl '$sddl'; it must be an SDDL string or false. Fix the file."
        }
    }
    if ($info.urlAclCreated -eq $true -and $info.urlAclSddl -isnot [string]) {
        throw "Install metadata at $path records urlAclCreated but no urlAclSddl. Fix the file."
    }
    return $info
}

function Remove-ProctorData {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$DataDir)

    if ((Test-Path -LiteralPath $DataDir -ErrorAction Stop) -and $PSCmdlet.ShouldProcess($DataDir, 'remove proctor data')) {
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

    # The server and its module carry no template tokens and are copied as-is.
    foreach ($source in 'src\server.ps1', 'proctor.psm1') {
        $name = Split-Path $source -Leaf
        $destination = Join-Path $Config.KioskDir $name
        if ($PSCmdlet.ShouldProcess($destination, 'write file')) {
            Copy-Item -Path (Join-Path $SourceRoot $source) -Destination $destination -Force
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

function Register-ServerTask {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][int]$Port
    )

    if (-not $PSCmdlet.ShouldProcess($TaskName, 'register scheduled task')) {
        return
    }

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $TaskName
        }
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`" -Port $Port"
    $trigger = New-ScheduledTaskTrigger -AtStartup

    # SYSTEM decides the phase: the student account can neither change the
    # clock the phase calculation trusts nor read the exam window early.
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero)

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings | Out-Null
}

function Remove-ProctorTask {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$TaskName)

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task -and $PSCmdlet.ShouldProcess($TaskName, 'unregister scheduled task')) {
        if ($task.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $TaskName
        }
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
}

function Get-UrlAclReservation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Prefix)

    # $null when no reservation exists; otherwise the prefix and the account
    # it grants, for the caller's ownership decision and error messages.
    $show = & netsh.exe http show urlacl "url=$Prefix" 2>$null
    if ($show -notmatch 'Reserved URL') {
        return $null
    }
    $user = ($show | Select-String -Pattern 'User:\s*(\S.*)' | Select-Object -First 1).Matches.Groups[1].Value
    $sddl = ($show | Select-String -Pattern 'SDDL:\s*(\S.*)' | Select-Object -First 1).Matches.Groups[1].Value
    return [pscustomobject]@{ Prefix = $Prefix; User = $user; Sddl = ([string]$sddl).Trim() }
}

function Get-ProctorUrlAclSddl {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # The exact ACL Proctor writes on the URL reservation: grant GENERIC
    # EXECUTE (listen) to SYSTEM and nothing else. Ownership checks compare
    # against this string, so it is also passed to netsh on create.
    return 'D:(A;;GX;;;SY)'
}

function Get-UrlAclPlan {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [bool]$Exists,
        [string]$Sddl,
        $PriorInfo,
        [Parameter(Mandatory)][int]$Port
    )

    # Proctor owns the reservation only when a previous install recorded
    # that it created it for this same port and the current ACL still is
    # exactly what install wrote. Anything else that exists may belong to
    # another application or an administrator.
    if (-not $Exists) {
        return 'Create'
    }
    if ($null -ne $PriorInfo -and $PriorInfo.urlAclCreated -eq $true -and
        [int]$PriorInfo.port -eq $Port -and
        [string]$PriorInfo.urlAclSddl -eq $Sddl) {
        return 'Keep'
    }
    return 'Fail'
}

function Test-PortChangeAllowed {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        $PriorInfo,
        [Parameter(Mandatory)][int]$Port
    )

    # A recorded port is the port of a previous install: reinstalling on a
    # different one would orphan its URL reservation, so it must refuse.
    if ($null -eq $PriorInfo) {
        return $true
    }
    return [int]$PriorInfo.port -eq $Port
}

function Add-KioskUrlAcl {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][ValidateSet('Create', 'Keep')][string]$Plan
    )

    # Returns $true when the reservation exists and is Proctor's after the
    # call. 'Keep' means the caller already proved the existing reservation
    # is Proctor's through install.json, so it must not be rewritten.
    if (-not $PSCmdlet.ShouldProcess($Prefix, 'reserve URL for SYSTEM')) {
        return $false
    }
    if ($Plan -eq 'Keep') {
        return $true
    }
    & netsh.exe http add urlacl "url=$Prefix" "sddl=$(Get-ProctorUrlAclSddl)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "netsh could not reserve $Prefix for SYSTEM"
    }
    return $true
}

function Test-UrlAclRemoval {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        $InstallInfo,
        [string]$Sddl
    )

    # Uninstall may delete the URL reservation only when this install wrote
    # it and the ACL is still the exact SDDL install recorded; anything else
    # belongs to another application or an administrator.
    return ($null -ne $InstallInfo -and $InstallInfo.urlAclCreated -eq $true -and
        [string]$InstallInfo.urlAclSddl -eq $Sddl)
}

function Remove-KioskUrlAcl {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Prefix)

    if ($PSCmdlet.ShouldProcess($Prefix, 'remove URL reservation')) {
        # The caller proves ownership through install.json before calling.
        $show = & netsh.exe http show urlacl "url=$Prefix" 2>$null
        if ($show -match 'Reserved URL') {
            & netsh.exe http delete urlacl "url=$Prefix" | Out-Null
        }
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

    # Batch and service logons do not appear in quser but still hold the hive.
    $owned = Get-Process -IncludeUserName -ErrorAction SilentlyContinue |
        Where-Object { $_.UserName -and ($_.UserName -split '\\')[-1] -eq $UserName }
    foreach ($process in $owned) {
        if ($PSCmdlet.ShouldProcess("$($process.Name) ($($process.Id))", 'stop student process')) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
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
                $loaded = @("Registry::HKEY_USERS\$Sid", "Registry::HKEY_LOCAL_MACHINE\ProctorHive_$Sid") | Where-Object { Test-Path $_ }
                throw "Profile $Sid is still loaded after $TimeoutSeconds s (hives loaded: $($loaded -join ', ')): $($_.Exception.Message)"
            }
            & reg.exe unload "HKU\$Sid" 2>$null | Out-Null
            & reg.exe unload "HKU\$($Sid)_Classes" 2>$null | Out-Null
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

    if ((Test-Path -LiteralPath $Path -ErrorAction Stop) -and $PSCmdlet.ShouldProcess($Path, 'remove kiosk folder')) {
        Remove-Item $Path -Recurse -Force
    }
}

Export-ModuleMember -Function @(
    'Get-ConfigValue',
    'Read-ProctorConfigFile',
    'Resolve-ProctorConfig',
    'Get-UninstallUserName',
    'Expand-ProctorTemplate',
    'Get-ExamState',
    'Test-ExamPdfServable',
    'Resolve-ExamVersion',
    'Get-ExamVersionsToPrune',
    'Test-ExamVersionChanged',
    'Test-UrlAclRemoval',
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
    'Save-ProctorInstallInfo',
    'Read-ProctorInstallInfo',
    'Remove-ProctorData',
    'Invoke-SystemTask',
    'Set-AssignedAccessKiosk',
    'Clear-AssignedAccessKiosk',
    'Install-KioskFile',
    'Register-SyncTask',
    'Register-ServerTask',
    'Remove-ProctorTask',
    'Get-UrlAclReservation',
    'Get-ProctorUrlAclSddl',
    'Get-UrlAclPlan',
    'Test-PortChangeAllowed',
    'Add-KioskUrlAcl',
    'Remove-KioskUrlAcl',
    'Remove-UserLockdown',
    'Remove-StudentAccount',
    'Remove-KioskFolder'
)
