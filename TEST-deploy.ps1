<#
.SYNOPSIS
    TEST DEPLOYMENT - For testing on personal PC
    
.DESCRIPTION
    Creates a test user account and configures kiosk mode for testing
    Uses a local PDF instead of network path
    
.NOTES
    Run as Administrator
    SAFE: Does NOT enable auto-login (so you can still access your main account)
#>

#Requires -RunAsAdministrator

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   TEST DEPLOYMENT (Personal PC)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# CONFIGURATION FOR TESTING
# =============================================================================
$TestUserName = "Alumno - 01"
$TestPassword = "alumno"
$LocalPdfPath = "C:\Users\david\Downloads\sample.pdf"

Write-Host "This test will:" -ForegroundColor Yellow
Write-Host "  1. Create user '$TestUserName' (password: $TestPassword)" -ForegroundColor White
Write-Host "  2. Configure Assigned Access (kiosk mode)" -ForegroundColor White
Write-Host "  3. Use local PDF: $LocalPdfPath" -ForegroundColor White
Write-Host "  4. NOT enable auto-login (safe for your PC)" -ForegroundColor White
Write-Host ""
Write-Host "To test: Log out, then login as '$TestUserName'" -ForegroundColor Magenta
Write-Host ""

$Confirm = Read-Host "Continue? (Y/N)"
if ($Confirm -notmatch "^[Yy]") {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
}

# =============================================================================
# CREATE TEST USER
# =============================================================================
Write-Host ""
Write-Host "Creating test user..." -ForegroundColor Yellow

try {
    $ExistingUser = Get-LocalUser -Name $TestUserName -ErrorAction SilentlyContinue
    if ($ExistingUser) {
        Write-Host "User '$TestUserName' already exists" -ForegroundColor Green
    } else {
        $SecurePass = ConvertTo-SecureString $TestPassword -AsPlainText -Force
        New-LocalUser -Name $TestUserName -Password $SecurePass -Description "Test exam kiosk user" -ErrorAction Stop
        Add-LocalGroupMember -Group "Users" -Member $TestUserName -ErrorAction SilentlyContinue
        Write-Host "Created user: $TestUserName" -ForegroundColor Green
    }
}
catch {
    Write-Host "ERROR creating user: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# =============================================================================
# CREATE DIRECTORIES
# =============================================================================
Write-Host "Creating directories..." -ForegroundColor Yellow

$ScriptsDir = "C:\Scripts"
$KioskDir = "C:\ExamKiosk"

foreach ($Dir in @($ScriptsDir, $KioskDir)) {
    if (-not (Test-Path $Dir)) {
        New-Item -Path $Dir -ItemType Directory -Force | Out-Null
        Write-Host "Created: $Dir" -ForegroundColor Green
    }
}

# =============================================================================
# COPY TEST PDF TO KIOSK FOLDER
# =============================================================================
Write-Host "Setting up test PDF..." -ForegroundColor Yellow

if (Test-Path $LocalPdfPath) {
    Copy-Item -Path $LocalPdfPath -Destination "$KioskDir\Exam.pdf" -Force
    Write-Host "Copied PDF to kiosk folder" -ForegroundColor Green
} else {
    Write-Host "WARNING: PDF not found at $LocalPdfPath" -ForegroundColor Yellow
    Write-Host "Creating a placeholder - you can replace it later" -ForegroundColor Yellow
    
    # Create a simple text file as placeholder
    "Test PDF placeholder - replace with actual PDF" | Out-File "$KioskDir\Exam.txt"
}

# =============================================================================
# GENERATE HTML INTERFACE
# =============================================================================
Write-Host "Generating HTML interface..." -ForegroundColor Yellow

$HtmlContent = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Examen para certificación</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;800&display=swap" rel="stylesheet">
    <style>
        * { box-sizing: border-box; }
        body { 
            margin: 0; 
            overflow: hidden; 
            font-family: 'Inter', sans-serif; 
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%);
            color: #fff; 
            height: 100vh; 
            display: flex; 
            flex-direction: column; 
            justify-content: center; 
            align-items: center; 
            user-select: none;
        }
        .student-badge {
            position: absolute;
            top: 20px;
            right: 20px;
            background: rgba(255,255,255,0.1);
            backdrop-filter: blur(10px);
            border: 1px solid rgba(255,255,255,0.2);
            padding: 12px 24px;
            border-radius: 50px;
            font-weight: 600;
            font-size: 1rem;
            letter-spacing: 0.05em;
            text-transform: uppercase;
        }
        .test-badge {
            position: absolute;
            top: 20px;
            left: 20px;
            background: #e94560;
            padding: 8px 16px;
            border-radius: 8px;
            font-weight: 600;
            font-size: 0.8rem;
        }
        h1 { 
            font-weight: 800; 
            font-size: 3.5rem; 
            letter-spacing: -0.02em; 
            margin-bottom: 0.5rem; 
            background: linear-gradient(90deg, #e94560, #ff6b6b);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        p { font-weight: 400; font-size: 1.1rem; color: rgba(255,255,255,0.7); margin-bottom: 3rem; }
        .loader-container { display: flex; flex-direction: column; align-items: center; gap: 1.5rem; }
        .loader { width: 50px; height: 50px; border: 3px solid rgba(255,255,255,0.1); border-top: 3px solid #e94560; border-radius: 50%; animation: spin 1s linear infinite; }
        .status { font-weight: 400; font-size: 0.9rem; color: rgba(255,255,255,0.5); animation: pulse 2s ease-in-out infinite; }
        iframe { position: absolute; top: 0; left: 0; width: 100vw; height: 100vh; border: none; background: #fff; display: none; }
        @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
        @keyframes pulse { 0%, 100% { opacity: 0.5; } 50% { opacity: 1; } }
    </style>
    <script>
        function check() {
            var xhr = new XMLHttpRequest();
            xhr.open('HEAD', 'Exam.pdf?t=' + Date.now(), true);
            xhr.onload = function() {
                if (xhr.status === 200) {
                    document.getElementById('pdfFrame').src = "Exam.pdf?t=" + Date.now();
                    document.getElementById('pdfFrame').style.display = "block";
                } else { setTimeout(check, 3000); }
            };
            xhr.onerror = function() { setTimeout(check, 3000); };
            xhr.send();
        }
    </script>
</head>
<body onload="check()" oncontextmenu="return false;">
    <div class="test-badge">🧪 TEST MODE</div>
    <div class="student-badge">$TestUserName</div>
    <h1>Examen para certificación</h1>
    <p>Por favor, espere las instrucciones del docente</p>
    <div class="loader-container">
        <div class="loader"></div>
        <div class="status">Esperando examen...</div>
    </div>
    <iframe id="pdfFrame"></iframe>
</body>
</html>
"@

Set-Content -Path "$KioskDir\index.html" -Value $HtmlContent -Force -Encoding UTF8
Write-Host "Generated index.html" -ForegroundColor Green

# =============================================================================
# SET FOLDER PERMISSIONS
# =============================================================================
Write-Host "Setting folder permissions..." -ForegroundColor Yellow

$Acl = Get-Acl $KioskDir
$Acl.SetAccessRuleProtection($true, $false)

$RuleSys = New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$Acl.AddAccessRule($RuleSys)

$RuleAdmin = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$Acl.AddAccessRule($RuleAdmin)

$RuleUser = New-Object System.Security.AccessControl.FileSystemAccessRule("Users", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")
$Acl.AddAccessRule($RuleUser)

Set-Acl $KioskDir $Acl
Write-Host "Permissions set" -ForegroundColor Green

# =============================================================================
# CONFIGURE ASSIGNED ACCESS (KIOSK MODE)
# =============================================================================
Write-Host "Configuring Assigned Access..." -ForegroundColor Yellow

# Get Edge AUMID
$EdgeAUMID = "Microsoft.MicrosoftEdge_8wekyb3d8bbwe!MicrosoftEdge"

# Try to find new Edge
$EdgePackage = Get-AppxPackage -Name "*MicrosoftEdge*" -AllUsers | Where-Object { $_.Name -match "Stable" } | Select-Object -First 1
if ($EdgePackage) {
    $EdgeAUMID = "$($EdgePackage.PackageFamilyName)!MicrosoftEdge"
}

try {
    Clear-AssignedAccess -ErrorAction SilentlyContinue
    Set-AssignedAccess -UserName $TestUserName -AppUserModelId $EdgeAUMID -ErrorAction Stop
    Write-Host "Assigned Access configured" -ForegroundColor Green
}
catch {
    Write-Host "ERROR configuring Assigned Access: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Possible issues:" -ForegroundColor Yellow
    Write-Host "  - Windows Home edition (needs Pro)" -ForegroundColor White
    Write-Host "  - User logged in elsewhere" -ForegroundColor White
    Write-Host "  - Edge not installed correctly" -ForegroundColor White
    exit 1
}

# =============================================================================
# EDGE POLICIES (for kiosk behavior)
# =============================================================================
Write-Host "Applying Edge policies..." -ForegroundColor Yellow

$EdgePath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
if (-not (Test-Path $EdgePath)) { New-Item -Path $EdgePath -Force | Out-Null }

$EdgePolicies = @{
    "DeveloperToolsAvailability" = 2
    "PrintingEnabled" = 0
    "DownloadRestrictions" = 3
    "HideFirstRunExperience" = 1
    "HomepageLocation" = "file:///C:/ExamKiosk/index.html"
    "RestoreOnStartup" = 4
}

foreach ($Policy in $EdgePolicies.GetEnumerator()) {
    Set-ItemProperty -Path $EdgePath -Name $Policy.Key -Value $Policy.Value -Force
}

$EdgeStartupPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge\RestoreOnStartupURLs"
if (-not (Test-Path $EdgeStartupPath)) { New-Item -Path $EdgeStartupPath -Force | Out-Null }
Set-ItemProperty -Path $EdgeStartupPath -Name "1" -Value "file:///C:/ExamKiosk/index.html" -Force

Write-Host "Edge policies applied" -ForegroundColor Green

# =============================================================================
# DO NOT CONFIGURE AUTO-LOGIN (SAFE FOR PERSONAL PC)
# =============================================================================
Write-Host ""
Write-Host "NOTE: Auto-login NOT enabled (safe for personal PC)" -ForegroundColor Magenta

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   TEST DEPLOYMENT COMPLETE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "HOW TO TEST:" -ForegroundColor Yellow
Write-Host "  1. Press Win+L to lock screen (or log out)" -ForegroundColor White
Write-Host "  2. Click 'Other user' on login screen" -ForegroundColor White
Write-Host "  3. Username: $TestUserName" -ForegroundColor White
Write-Host "  4. Password: $TestPassword" -ForegroundColor White
Write-Host "  5. You should see Edge in kiosk mode with the exam page" -ForegroundColor White
Write-Host ""
Write-Host "TO EXIT KIOSK:" -ForegroundColor Yellow
Write-Host "  - Press Ctrl+Alt+Del" -ForegroundColor White
Write-Host "  - Click 'Sign out'" -ForegroundColor White
Write-Host "  - Log back in as your normal user (david)" -ForegroundColor White
Write-Host ""
Write-Host "TO CLEANUP:" -ForegroundColor Yellow
Write-Host "  Run: .\3-restore-laptop.ps1" -ForegroundColor White
Write-Host ""

Read-Host "Press Enter to exit"
