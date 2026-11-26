BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\proctor.psm1') -Force
}

Describe 'Resolve-ProctorConfig' {
    It 'applies defaults and derives account, folder and share path' {
        $config = Resolve-ProctorConfig -Parameters @{
            Server       = '192.168.5.30'
            Share        = 'sidera\Examenes'
            DeviceNumber = '01'
            ExamTitle    = 'Examen'
        }

        $config.UserPrefix | Should -Be 'Alumno'
        $config.Language | Should -Be 'es'
        $config.UserName | Should -Be 'Alumno-01'
        $config.DeviceFolder | Should -Be 'Dispositivo 01'
        $config.NetworkPath | Should -Be '\\192.168.5.30\sidera\Examenes\Dispositivo 01'
        $config.Port | Should -Be 8471
        $config.KioskUrl | Should -Be 'http://127.0.0.1:8471/'
        $config.TaskName | Should -Be 'ExamSync-Alumno-01'
        $config.ServerTaskName | Should -Be 'ExamServer-Alumno-01'
    }

    It 'lets parameters override the config file' {
        $config = Resolve-ProctorConfig -Parameters @{
            Server       = '10.0.0.5'
            DeviceNumber = '03'
        } -File @{
            Server       = '192.168.5.30'
            Share        = 'exams'
            DeviceNumber = '01'
            ExamTitle    = 'Midterm'
            Language     = 'en'
        }

        $config.Server | Should -Be '10.0.0.5'
        $config.DeviceNumber | Should -Be '03'
        $config.Share | Should -Be 'exams'
        $config.ExamTitle | Should -Be 'Midterm'
        $config.Language | Should -Be 'en'
        $config.DeviceFolder | Should -Be 'Device 03'
        $config.NetworkPath | Should -Be '\\10.0.0.5\exams\Device 03'
    }

    It 'takes the share user from the config file' {
        $config = Resolve-ProctorConfig -Parameters @{
            Server       = 'files'
            Share        = 'exams'
            DeviceNumber = '01'
            ExamTitle    = 'Exam'
        } -File @{
            shareUser = 'lector'
        }

        $config.ShareUser | Should -Be 'lector'
        (Resolve-ProctorConfig -Parameters @{
            Server       = 'files'
            Share        = 'exams'
            DeviceNumber = '01'
            ExamTitle    = 'Exam'
        }).ShareUser | Should -BeNullOrEmpty
    }

    It 'takes the server out of a full UNC share' {
        $config = Resolve-ProctorConfig -Parameters @{
            Share        = '\\files\Examenes'
            DeviceNumber = '02'
            ExamTitle    = 'Examen'
        }

        $config.Server | Should -Be 'files'
        $config.Share | Should -Be 'Examenes'
        $config.NetworkPath | Should -Be '\\files\Examenes\Dispositivo 02'
    }

    It 'rejects a server that disagrees with the UNC share' {
        {
            Resolve-ProctorConfig -Parameters @{
                Server       = '10.0.0.5'
                Share        = '\\files\Examenes'
                DeviceNumber = '02'
                ExamTitle    = 'Examen'
            }
        } | Should -Throw '*does not match*'
    }

    It 'normalizes forward slashes and trailing separators in the share' {
        $config = Resolve-ProctorConfig -Parameters @{
            Server       = 'files'
            Share        = 'sidera/Examenes/'
            DeviceNumber = '02'
            ExamTitle    = 'Examen'
        }

        $config.NetworkPath | Should -Be '\\files\sidera\Examenes\Dispositivo 02'
    }

    It 'rejects a missing server' {
        { Resolve-ProctorConfig -Parameters @{
                Share        = 'exams'
                DeviceNumber = '01'
                ExamTitle    = 'Exam'
            } } | Should -Throw '*Server is required*'
    }

    It 'rejects a missing share' {
        { Resolve-ProctorConfig -Parameters @{
                Server       = 'files'
                DeviceNumber = '01'
                ExamTitle    = 'Exam'
            } } | Should -Throw '*Share is required*'
    }

    It 'rejects a missing exam title' {
        { Resolve-ProctorConfig -Parameters @{
                Server       = 'files'
                Share        = 'exams'
                DeviceNumber = '01'
            } } | Should -Throw '*ExamTitle is required*'
    }

    It 'rejects a device number that is not two digits' {
        { Resolve-ProctorConfig -Parameters @{
                Server       = 'files'
                Share        = 'exams'
                DeviceNumber = '1'
                ExamTitle    = 'Exam'
            } } | Should -Throw '*two digits*'

        { Resolve-ProctorConfig -Parameters @{
                Server       = 'files'
                Share        = 'exams'
                DeviceNumber = '123'
                ExamTitle    = 'Exam'
            } } | Should -Throw '*two digits*'
    }

    It 'rejects an unsupported language' {
        { Resolve-ProctorConfig -Parameters @{
                Server       = 'files'
                Share        = 'exams'
                DeviceNumber = '01'
                ExamTitle    = 'Exam'
                Language     = 'fr'
            } } | Should -Throw "*'es' or 'en'*"
    }

    It 'builds the kiosk URL from the configured port' {
        $config = Resolve-ProctorConfig -Parameters @{
            Server       = 'files'
            Share        = 'exams'
            DeviceNumber = '01'
            ExamTitle    = 'Exam'
            Port         = '9000'
        }

        $config.Port | Should -Be 9000
        $config.KioskUrl | Should -Be 'http://127.0.0.1:9000/'
    }

    It 'rejects a port outside the TCP range' {
        { Resolve-ProctorConfig -Parameters @{
                Server       = 'files'
                Share        = 'exams'
                DeviceNumber = '01'
                ExamTitle    = 'Exam'
                Port         = '70000'
            } } | Should -Throw '*Port*'
    }
}

Describe 'Get-ExamState' {
    BeforeAll {
        $script:spec = '{ "title": "Midterm", "opensAt": "2026-03-10T09:00:00+00:00", "closesAt": "2026-03-10T11:00:00+00:00" }'
    }

    It 'is none when there is no exam.json' {
        $state = Get-ExamState -Json $null -Now ([datetimeoffset]'2026-03-10T09:30:00+00:00')
        $state.Phase | Should -Be 'none'
        $state.Malformed | Should -BeFalse
    }

    It 'is error when the file is empty' {
        $state = Get-ExamState -Json '' -Now ([datetimeoffset]'2026-03-10T09:30:00+00:00')
        $state.Phase | Should -Be 'error'
        $state.Malformed | Should -BeTrue
    }

    It 'is error when the file is whitespace only' {
        $state = Get-ExamState -Json "   `n  " -Now ([datetimeoffset]'2026-03-10T09:30:00+00:00')
        $state.Phase | Should -Be 'error'
        $state.Malformed | Should -BeTrue
    }

    It 'is error when the file is malformed' {
        $state = Get-ExamState -Json '{ not json' -Now ([datetimeoffset]'2026-03-10T09:30:00+00:00')
        $state.Phase | Should -Be 'error'
        $state.Malformed | Should -BeTrue
    }

    It 'is error when a date does not parse' {
        $bad = '{ "opensAt": "soon", "closesAt": "2026-03-10T11:00:00+00:00" }'
        $state = Get-ExamState -Json $bad -Now ([datetimeoffset]'2026-03-10T09:30:00+00:00')
        $state.Phase | Should -Be 'error'
        $state.Malformed | Should -BeTrue
    }

    It 'is error when a timestamp carries no offset' {
        $bad = '{ "opensAt": "2026-03-10T08:00:00", "closesAt": "2026-03-10T12:00:00" }'
        $state = Get-ExamState -Json $bad -Now ([datetimeoffset]'2026-03-10T09:30:00+00:00')
        $state.Phase | Should -Be 'error'
        $state.Malformed | Should -BeTrue
    }

    It 'is error when the schedule fields are not top-level' {
        $bad = '{ "metadata": { "opensAt": "2026-03-10T08:00:00+00:00", "closesAt": "2026-03-10T12:00:00+00:00" } }'
        $state = Get-ExamState -Json $bad -Now ([datetimeoffset]'2026-03-10T09:30:00+00:00')
        $state.Phase | Should -Be 'error'
        $state.Malformed | Should -BeTrue
    }

    It 'is error when a timestamp is not ISO-8601' {
        $bad = '{ "opensAt": "March 10 2026 08:00 +00:00", "closesAt": "2026-03-10T12:00:00+00:00" }'
        $state = Get-ExamState -Json $bad -Now ([datetimeoffset]'2026-03-10T09:30:00+00:00')
        $state.Phase | Should -Be 'error'
        $state.Malformed | Should -BeTrue
    }

    It 'is error when the window closes before it opens' {
        $bad = '{ "opensAt": "2026-03-10T11:00:00+00:00", "closesAt": "2026-03-10T09:00:00+00:00" }'
        $state = Get-ExamState -Json $bad -Now ([datetimeoffset]'2026-03-10T09:30:00+00:00')
        $state.Phase | Should -Be 'error'
        $state.Malformed | Should -BeTrue
    }

    It 'is waiting just before opensAt and counts the seconds to it' {
        $state = Get-ExamState -Json $spec -Now ([datetimeoffset]'2026-03-10T08:59:30+00:00')
        $state.Phase | Should -Be 'waiting'
        $state.SecondsUntilOpen | Should -Be 30
        $state.Title | Should -Be 'Midterm'
    }

    It 'is open at opensAt' {
        $state = Get-ExamState -Json $spec -Now ([datetimeoffset]'2026-03-10T09:00:00+00:00')
        $state.Phase | Should -Be 'open'
        $state.SecondsLeft | Should -Be 7200
    }

    It 'is open inside the window and counts the seconds left' {
        $state = Get-ExamState -Json $spec -Now ([datetimeoffset]'2026-03-10T10:00:00+00:00')
        $state.Phase | Should -Be 'open'
        $state.SecondsLeft | Should -Be 3600
    }

    It 'is closed at closesAt' {
        $state = Get-ExamState -Json $spec -Now ([datetimeoffset]'2026-03-10T11:00:00+00:00')
        $state.Phase | Should -Be 'closed'
        $state.SecondsLeft | Should -BeNullOrEmpty
    }

    It 'is closed after closesAt' {
        $state = Get-ExamState -Json $spec -Now ([datetimeoffset]'2026-03-10T11:00:01+00:00')
        $state.Phase | Should -Be 'closed'
    }

    It 'compares instants across offsets' {
        $state = Get-ExamState -Json $spec -Now ([datetimeoffset]'2026-03-10T06:00:00-03:00')
        $state.Phase | Should -Be 'open'
    }
}

Describe 'Test-ExamPdfServable' {
    It 'serves the PDF in phase <Phase>' -TestCases @(
        @{ Phase = 'open' },
        @{ Phase = 'none' }
    ) {
        param([string]$Phase)
        Test-ExamPdfServable -Phase $Phase | Should -BeTrue
    }

    It 'hides the PDF in phase <Phase>' -TestCases @(
        @{ Phase = 'waiting' },
        @{ Phase = 'closed' },
        @{ Phase = 'error' }
    ) {
        param([string]$Phase)
        Test-ExamPdfServable -Phase $Phase | Should -BeFalse
    }
}

Describe 'Resolve-ExamVersion' {
    BeforeAll {
        $script:dataDir = Join-Path ([System.IO.Path]::GetTempPath()) ('proctor-ver-' + [guid]::NewGuid())
        $script:examDir = Join-Path $dataDir 'exam'
        New-Item -Path $examDir -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        Remove-Item -Path $dataDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns null when current.txt is missing' {
        Resolve-ExamVersion -DataDir $dataDir | Should -BeNullOrEmpty
    }

    It 'returns null when current.txt names a folder that does not exist' {
        '20260310090000000' | Set-Content -Path (Join-Path $examDir 'current.txt')
        Resolve-ExamVersion -DataDir $dataDir | Should -BeNullOrEmpty
    }

    It 'resolves the version folder current.txt names' {
        $versionDir = Join-Path $examDir '20260310090000000'
        New-Item -Path $versionDir -ItemType Directory | Out-Null
        Resolve-ExamVersion -DataDir $dataDir | Should -Be $versionDir
    }
}

Describe 'Get-ExamVersionsToPrune' {
    It 'keeps the current version and the one before it' {
        $names = '20260310080000000', '20260310090000000', '20260310100000000'
        Get-ExamVersionsToPrune -Names $names -Current '20260310100000000' |
            Should -Be '20260310080000000'
    }

    It 'prunes nothing when only two versions exist' {
        $names = '20260310090000000', '20260310100000000'
        Get-ExamVersionsToPrune -Names $names -Current '20260310100000000' |
            Should -BeNullOrEmpty
    }

    It 'prunes every folder but the current one' {
        $names = '20260310080000000', '20260310090000000', '20260310100000000'
        $prune = Get-ExamVersionsToPrune -Names $names -Current '20260310090000000'
        $prune | Should -HaveCount 1
        $prune | Should -Contain '20260310100000000'
    }
}

Describe 'Test-ExamVersionChanged' {
    BeforeAll {
        $script:dataDir = Join-Path ([System.IO.Path]::GetTempPath()) ('proctor-chg-' + [guid]::NewGuid())
        New-Item -Path $dataDir -ItemType Directory -Force | Out-Null
        'pdf-a' | Set-Content -Path (Join-Path $dataDir 'a.pdf')
        'pdf-b' | Set-Content -Path (Join-Path $dataDir 'b.pdf')
        '{ }' | Set-Content -Path (Join-Path $dataDir 'exam.json')
    }

    AfterAll {
        Remove-Item -Path $dataDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'is true when there is no current version' {
        $pdf = Get-Item (Join-Path $dataDir 'a.pdf')
        Test-ExamVersionChanged -CurrentDir $null -NetworkPdf $pdf -NetworkExamJson $null |
            Should -BeTrue
    }

    It 'is false when the version matches the share files byte for byte' {
        $versionDir = Join-Path $dataDir 'v1'
        New-Item -Path $versionDir -ItemType Directory | Out-Null
        Copy-Item (Join-Path $dataDir 'a.pdf') (Join-Path $versionDir 'Exam.pdf')
        Copy-Item (Join-Path $dataDir 'exam.json') (Join-Path $versionDir 'exam.json')
        $pdf = Get-Item (Join-Path $dataDir 'a.pdf')
        $json = Get-Item (Join-Path $dataDir 'exam.json')
        Test-ExamVersionChanged -CurrentDir $versionDir -NetworkPdf $pdf -NetworkExamJson $json |
            Should -BeFalse
    }

    It 'is true when the share has no exam.json but the version does' {
        $versionDir = Join-Path $dataDir 'v2'
        New-Item -Path $versionDir -ItemType Directory | Out-Null
        Copy-Item (Join-Path $dataDir 'a.pdf') (Join-Path $versionDir 'Exam.pdf')
        Copy-Item (Join-Path $dataDir 'exam.json') (Join-Path $versionDir 'exam.json')
        $pdf = Get-Item (Join-Path $dataDir 'a.pdf')
        Test-ExamVersionChanged -CurrentDir $versionDir -NetworkPdf $pdf -NetworkExamJson $null |
            Should -BeTrue
    }

    It 'is true when the PDF content differs' {
        $versionDir = Join-Path $dataDir 'v3'
        New-Item -Path $versionDir -ItemType Directory | Out-Null
        Copy-Item (Join-Path $dataDir 'a.pdf') (Join-Path $versionDir 'Exam.pdf')
        $pdf = Get-Item (Join-Path $dataDir 'b.pdf')
        Test-ExamVersionChanged -CurrentDir $versionDir -NetworkPdf $pdf -NetworkExamJson $null |
            Should -BeTrue
    }
}

Describe 'Get-UrlAclPlan' {
    It 'creates the reservation when none exists' {
        Get-UrlAclPlan -Exists $false -PriorInfo $null -Port 8471 | Should -Be 'Create'
    }

    It 'keeps a reservation Proctor recorded for the same port and SDDL' {
        $info = [pscustomobject]@{ port = 8471; urlAclCreated = $true; urlAclSddl = 'D:(A;;GX;;;SY)' }
        Get-UrlAclPlan -Exists $true -Sddl 'D:(A;;GX;;;SY)' -PriorInfo $info -Port 8471 | Should -Be 'Keep'
    }

    It 'fails a foreign reservation <Name>' -TestCases @(
        @{ Name = 'with no install metadata'; Info = $null; Sddl = 'D:(A;;GX;;;SY)' },
        @{ Name = 'when a previous install did not create it'; Info = [pscustomobject]@{ port = 8471; urlAclCreated = $false; urlAclSddl = $false }; Sddl = 'D:(A;;GX;;;SY)' },
        @{ Name = 'recorded on a different port'; Info = [pscustomobject]@{ port = 9000; urlAclCreated = $true; urlAclSddl = 'D:(A;;GX;;;SY)' }; Sddl = 'D:(A;;GX;;;SY)' },
        @{ Name = 'when the SDDL changed'; Info = [pscustomobject]@{ port = 8471; urlAclCreated = $true; urlAclSddl = 'D:(A;;GX;;;SY)' }; Sddl = 'D:(A;;GX;;;SY)(A;;GX;;;BA)' }
    ) {
        param($Info, [string]$Sddl)
        Get-UrlAclPlan -Exists $true -Sddl $Sddl -PriorInfo $Info -Port 8471 | Should -Be 'Fail'
    }
}

Describe 'Test-PortChangeAllowed' {
    It 'allows the port when there is no previous install' {
        Test-PortChangeAllowed -PriorInfo $null -Port 8471 | Should -BeTrue
    }

    It 'allows reinstalling on the recorded port' {
        $info = [pscustomobject]@{ port = 8471 }
        Test-PortChangeAllowed -PriorInfo $info -Port 8471 | Should -BeTrue
    }

    It 'refuses a different port' {
        $info = [pscustomobject]@{ port = 8471 }
        Test-PortChangeAllowed -PriorInfo $info -Port 9000 | Should -BeFalse
    }
}

Describe 'Test-UrlAclRemoval' {
    It 'is true when the install created the reservation and the SDDL still matches' {
        $info = [pscustomobject]@{ urlAclCreated = $true; urlAclSddl = 'D:(A;;GX;;;SY)' }
        Test-UrlAclRemoval -InstallInfo $info -Sddl 'D:(A;;GX;;;SY)' | Should -BeTrue
    }

    It 'is false <Name>' -TestCases @(
        @{ Name = 'when the SDDL changed'; Info = [pscustomobject]@{ urlAclCreated = $true; urlAclSddl = 'D:(A;;GX;;;SY)' }; Sddl = 'D:(A;;GX;;;SY)(A;;GX;;;BA)' },
        @{ Name = 'when the reservation is gone'; Info = [pscustomobject]@{ urlAclCreated = $true; urlAclSddl = 'D:(A;;GX;;;SY)' }; Sddl = $null },
        @{ Name = 'when the install did not create it'; Info = [pscustomobject]@{ urlAclCreated = $false; urlAclSddl = $false }; Sddl = 'D:(A;;GX;;;SY)' },
        @{ Name = 'when there is no metadata'; Info = $null; Sddl = 'D:(A;;GX;;;SY)' }
    ) {
        param($Info, [string]$Sddl)
        Test-UrlAclRemoval -InstallInfo $Info -Sddl $Sddl | Should -BeFalse
    }
}

Describe 'Read-ProctorInstallInfo' {
    BeforeAll {
        $script:dataDir = Join-Path ([System.IO.Path]::GetTempPath()) ('proctor-test-' + [guid]::NewGuid())
        New-Item -Path $dataDir -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        Remove-Item -Path $dataDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns null when the metadata file is absent' {
        Read-ProctorInstallInfo -DataDir $dataDir | Should -BeNullOrEmpty
    }

    It 'throws on an access error even when errors are non-terminating' {
        $ErrorActionPreference = 'Continue'
        '{ "port": 8472 }' | Set-Content -Path (Join-Path $dataDir 'install.json')
        Mock -ModuleName proctor Get-Content { throw [System.UnauthorizedAccessException]'access denied' }
        { Read-ProctorInstallInfo -DataDir $dataDir } | Should -Throw
    }

    It 'returns the recorded port' {
        '{ "port": 8472 }' | Set-Content -Path (Join-Path $dataDir 'install.json')
        (Read-ProctorInstallInfo -DataDir $dataDir).port | Should -Be 8472
    }

    It 'throws when the file is invalid JSON' {
        '{ bad json' | Set-Content -Path (Join-Path $dataDir 'install.json')
        { Read-ProctorInstallInfo -DataDir $dataDir } | Should -Throw '*Pass -Port explicitly*'
    }

    It 'throws on an invalid port <Json>' -TestCases @(
        @{ Json = '{}' },
        @{ Json = '{ "port": "not-a-port" }' },
        @{ Json = '{ "port": 0 }' },
        @{ Json = '{ "port": 70000 }' }
    ) {
        param([string]$Json)
        $Json | Set-Content -Path (Join-Path $dataDir 'install.json')
        { Read-ProctorInstallInfo -DataDir $dataDir } | Should -Throw '*invalid port*'
    }

    It 'reads urlAclCreated <Json>' -TestCases @(
        @{ Json = '{ "port": 8472, "urlAclCreated": true, "urlAclSddl": "D:(A;;GX;;;SY)" }'; Expected = $true },
        @{ Json = '{ "port": 8472, "urlAclCreated": false }'; Expected = $false }
    ) {
        param([string]$Json, [bool]$Expected)
        $Json | Set-Content -Path (Join-Path $dataDir 'install.json')
        (Read-ProctorInstallInfo -DataDir $dataDir).urlAclCreated | Should -Be $Expected
    }

    It 'reads a missing urlAclCreated as false' {
        '{ "port": 8472 }' | Set-Content -Path (Join-Path $dataDir 'install.json')
        (Read-ProctorInstallInfo -DataDir $dataDir).urlAclCreated | Should -BeFalse
    }

    It 'throws on a non-boolean urlAclCreated <Json>' -TestCases @(
        @{ Json = '{ "port": 8472, "urlAclCreated": "yes" }' },
        @{ Json = '{ "port": 8472, "urlAclCreated": 1 }' }
    ) {
        param([string]$Json)
        $Json | Set-Content -Path (Join-Path $dataDir 'install.json')
        { Read-ProctorInstallInfo -DataDir $dataDir } | Should -Throw '*invalid urlAclCreated*'
    }

    It 'reads urlAclSddl recorded next to urlAclCreated' {
        '{ "port": 8472, "urlAclCreated": true, "urlAclSddl": "D:(A;;GX;;;SY)" }' |
            Set-Content -Path (Join-Path $dataDir 'install.json')
        $info = Read-ProctorInstallInfo -DataDir $dataDir
        $info.urlAclSddl | Should -Be 'D:(A;;GX;;;SY)'
    }

    It 'reads a missing urlAclSddl as false' {
        '{ "port": 8472, "urlAclCreated": false }' | Set-Content -Path (Join-Path $dataDir 'install.json')
        (Read-ProctorInstallInfo -DataDir $dataDir).urlAclSddl | Should -BeFalse
    }

    It 'throws when urlAclCreated is true but urlAclSddl is missing or not a string' {
        '{ "port": 8472, "urlAclCreated": true }' | Set-Content -Path (Join-Path $dataDir 'install.json')
        { Read-ProctorInstallInfo -DataDir $dataDir } | Should -Throw '*urlAclSddl*'

        '{ "port": 8472, "urlAclCreated": true, "urlAclSddl": 4 }' |
            Set-Content -Path (Join-Path $dataDir 'install.json')
        { Read-ProctorInstallInfo -DataDir $dataDir } | Should -Throw '*urlAclSddl*'
    }
}

Describe 'Get-UninstallUserName' {
    It 'returns the explicit user name' {
        Get-UninstallUserName -UserName 'Alumno-07' | Should -Be 'Alumno-07'
    }

    It 'derives the user name from prefix and device' {
        Get-UninstallUserName -Parameters @{ DeviceNumber = '04' } |
            Should -Be 'Alumno-04'
    }

    It 'requires a device number or a user name' {
        { Get-UninstallUserName } | Should -Throw
    }
}

Describe 'Expand-ProctorTemplate' {
    It 'replaces every token' {
        $result = Expand-ProctorTemplate -Text 'a={{A}} b={{B}}' -Values @{ A = '1'; B = '2' }
        $result | Should -Be 'a=1 b=2'
    }

    It 'throws when a token is left over' {
        { Expand-ProctorTemplate -Text 'a={{A}}' -Values @{} } | Should -Throw '*{{A}}*'
    }
}

Describe 'Get-LockdownMode' {
    It 'uses Assigned Access on Pro, Education and Enterprise' {
        Get-LockdownMode -EditionId 'Professional' | Should -Be 'AssignedAccess'
        Get-LockdownMode -EditionId 'ProfessionalN' | Should -Be 'AssignedAccess'
        Get-LockdownMode -EditionId 'ProfessionalWorkstation' | Should -Be 'AssignedAccess'
        Get-LockdownMode -EditionId 'Education' | Should -Be 'AssignedAccess'
        Get-LockdownMode -EditionId 'Enterprise' | Should -Be 'AssignedAccess'
        Get-LockdownMode -EditionId 'EnterpriseS' | Should -Be 'AssignedAccess'
        Get-LockdownMode -EditionId 'IoTEnterprise' | Should -Be 'AssignedAccess'
    }

    It 'uses the registry lockdown on Home and Server' {
        Get-LockdownMode -EditionId 'Core' | Should -Be 'RegistryLockdown'
        Get-LockdownMode -EditionId 'CoreSingleLanguage' | Should -Be 'RegistryLockdown'
        Get-LockdownMode -EditionId 'ServerStandard' | Should -Be 'RegistryLockdown'
        Get-LockdownMode -EditionId 'ServerDatacenter' | Should -Be 'RegistryLockdown'
        Get-LockdownMode -EditionId 'ServerEnterprise' | Should -Be 'RegistryLockdown'
        Get-LockdownMode -EditionId 'ServerRdsh' | Should -Be 'RegistryLockdown'
    }
}

Describe 'ConvertTo-AssignedAccessXml' {
    It 'produces a valid single-app kiosk configuration for the account' {
        $xml = ConvertTo-AssignedAccessXml -UserName 'Alumno-01' `
            -KioskUrl 'http://127.0.0.1:8471/' `
            -EdgePath 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'

        $doc = [xml]$xml
        $config = $doc.AssignedAccessConfiguration
        $app = $config.Profiles.Profile.KioskModeApp
        $app.HasAttribute('AppUserModelId') | Should -BeFalse
        $v4 = 'http://schemas.microsoft.com/AssignedAccess/2021/config'
        $app.GetAttribute('ClassicAppPath', $v4) |
            Should -Be 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
        $app.GetAttribute('ClassicAppArguments', $v4) |
            Should -BeLike '*--kiosk http://127.0.0.1:8471/*fullscreen*'
        $config.Configs.Config.Account | Should -Be 'Alumno-01'
    }
}

Describe 'kiosk file templates' {
    BeforeAll {
        function Get-TemplateValue {
            @{
                ExamTitle   = 'Examen de prueba'
                UserName    = 'Alumno-01'
                Language    = 'es'
                NetworkPath = '\\files\Examenes\Dispositivo 01'
            }
        }
    }

    It 'fills index.html with no token left over' {
        $raw = Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\src\index.html') -Raw -Encoding UTF8
        $filled = Expand-ProctorTemplate -Text $raw -Values (Get-TemplateValue)

        $filled | Should -BeLike '*Examen de prueba*'
        $filled | Should -BeLike "*const LANG = 'es'*"
        $filled | Should -BeLike '*<div class="badge">Alumno-01</div>*'
    }

    It 'fills sync-exam.ps1 with the device share path' {
        $raw = Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\src\sync-exam.ps1') -Raw -Encoding UTF8
        $filled = Expand-ProctorTemplate -Text $raw -Values (Get-TemplateValue)

        $filled | Should -BeLike "*'\\files\Examenes\Dispositivo 01'*"
    }

    It 'renders a hostile exam title as inert text in index.html' {
        $config = [pscustomobject]@{
            ExamTitle   = '</title><script>alert(1)</script>'
            UserName    = 'Alumno-01'
            Language    = 'es'
            NetworkPath = '\\files\Examenes\Dispositivo 01'
            KioskDir    = $TestDrive
        }
        Install-KioskFile -Config $config -SourceRoot (Join-Path $PSScriptRoot '..')

        $html = Get-Content -Path (Join-Path $TestDrive 'index.html') -Raw -Encoding UTF8
        $html | Should -BeLike '*&lt;/title&gt;&lt;script&gt;alert(1)&lt;/script&gt;*'
        $html | Should -Not -BeLike '*<script>alert(1)</script>*'
    }

    It 'renders a quote and dollar in NetworkPath as a parseable literal' {
        $networkPath = '\\files\Exam''enes\Dispo$sitivo 01'
        $config = [pscustomobject]@{
            ExamTitle   = 'Examen'
            UserName    = 'Alumno-01'
            Language    = 'es'
            NetworkPath = $networkPath
            KioskDir    = $TestDrive
        }
        Install-KioskFile -Config $config -SourceRoot (Join-Path $PSScriptRoot '..')

        $script = Get-Content -Path (Join-Path $TestDrive 'sync-exam.ps1') -Raw -Encoding UTF8
        $errors = $null
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0

        $assignment = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.VariablePath.UserPath -eq 'networkPath'
            }, $true)
        $assignment.Right.Expression.Value | Should -Be $networkPath
    }

    It 'keeps page strings for both languages' {
        $raw = Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\src\index.html') -Raw -Encoding UTF8

        $raw | Should -BeLike '*es:*'
        $raw | Should -BeLike '*en:*'
        $raw | Should -BeLike '*Waiting for the exam*'
        $raw | Should -BeLike '*Esperando examen*'
    }
}
