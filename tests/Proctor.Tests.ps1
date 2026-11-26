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
        $config.KioskUrl | Should -Be 'file:///C:/Kiosk/index.html'
        $config.TaskName | Should -Be 'ExamSync-Alumno-01'
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
            -KioskUrl 'file:///C:/Kiosk/index.html' `
            -EdgePath 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'

        $doc = [xml]$xml
        $config = $doc.AssignedAccessConfiguration
        $app = $config.Profiles.Profile.KioskModeApp
        $app.HasAttribute('AppUserModelId') | Should -BeFalse
        $v4 = 'http://schemas.microsoft.com/AssignedAccess/2021/config'
        $app.GetAttribute('ClassicAppPath', $v4) |
            Should -Be 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
        $app.GetAttribute('ClassicAppArguments', $v4) |
            Should -BeLike '*--kiosk file:///C:/Kiosk/index.html*fullscreen*'
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
