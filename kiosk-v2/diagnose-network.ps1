<#
.SYNOPSIS
    Network Diagnostic Tool for Kiosk Deployment Issues
    
.DESCRIPTION
    Comprehensive diagnostic script to troubleshoot network folder access issues.
    Tests connectivity, firewall rules, SMB access, and provides detailed logs.
    
.NOTES
    Run as Administrator
    
.EXAMPLE
    .\diagnose-network.ps1
#>

#Requires -RunAsAdministrator

$ServerIP = "192.168.5.30"
$NetworkShare = "\\$ServerIP\sidera\Examenes"
$TestFolder = "$NetworkShare\Dispositivo 01"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   NETWORK DIAGNOSTICS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# TEST 1: BASIC NETWORK CONNECTIVITY
# =============================================================================
Write-Host "[TEST 1] Basic Network Connectivity" -ForegroundColor Yellow
Write-Host "Target: $ServerIP" -ForegroundColor Gray
Write-Host ""

try {
    $ping = Test-Connection -ComputerName $ServerIP -Count 2 -ErrorAction Stop
    Write-Host "✅ PING SUCCESS" -ForegroundColor Green
    Write-Host "   Response time: $($ping[0].ResponseTime)ms" -ForegroundColor Gray
} catch {
    Write-Host "❌ PING FAILED" -ForegroundColor Red
    Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""

# =============================================================================
# TEST 2: FIREWALL RULES
# =============================================================================
Write-Host "[TEST 2] Firewall Rules Analysis" -ForegroundColor Yellow
Write-Host ""

$FirewallRules = Get-NetFirewallRule -DisplayName "Exam Kiosk*" -ErrorAction SilentlyContinue

if ($FirewallRules) {
    Write-Host "Found $($FirewallRules.Count) kiosk firewall rules:" -ForegroundColor Cyan
    foreach ($Rule in $FirewallRules) {
        $Filter = Get-NetFirewallRule -Name $Rule.Name | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        $AddressFilter = Get-NetFirewallRule -Name $Rule.Name | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
        
        Write-Host ""
        Write-Host "  Rule: $($Rule.DisplayName)" -ForegroundColor White
        Write-Host "    Direction: $($Rule.Direction)" -ForegroundColor Gray
        Write-Host "    Action: $($Rule.Action)" -ForegroundColor Gray
        Write-Host "    Enabled: $($Rule.Enabled)" -ForegroundColor Gray
        
        if ($AddressFilter) {
            Write-Host "    Remote Address: $($AddressFilter.RemoteAddress)" -ForegroundColor Gray
        }
        if ($Filter) {
            Write-Host "    Remote Port: $($Filter.RemotePort)" -ForegroundColor Gray
            Write-Host "    Protocol: $($Filter.Protocol)" -ForegroundColor Gray
        }
    }
} else {
    Write-Host "⚠️  No kiosk firewall rules found" -ForegroundColor Yellow
    Write-Host "   (This is OK if you haven't deployed yet)" -ForegroundColor Gray
}

Write-Host ""

# =============================================================================
# TEST 3: PORT CONNECTIVITY (SMB PORT 445)
# =============================================================================
Write-Host "[TEST 3] SMB Port 445 Connectivity" -ForegroundColor Yellow
Write-Host ""

try {
    $tcpClient = New-Object System.Net.Sockets.TcpClient
    $connect = $tcpClient.BeginConnect($ServerIP, 445, $null, $null)
    $wait = $connect.AsyncWaitHandle.WaitOne(3000, $false)
    
    if ($wait) {
        try {
            $tcpClient.EndConnect($connect)
            Write-Host "✅ PORT 445 OPEN" -ForegroundColor Green
            Write-Host "   SMB service is reachable" -ForegroundColor Gray
        } catch {
            Write-Host "❌ PORT 445 BLOCKED" -ForegroundColor Red
            Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "❌ PORT 445 TIMEOUT" -ForegroundColor Red
        Write-Host "   Connection timed out after 3 seconds" -ForegroundColor Red
    }
    $tcpClient.Close()
} catch {
    Write-Host "❌ PORT TEST FAILED" -ForegroundColor Red
    Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""

# =============================================================================
# TEST 4: SMB CLIENT CONFIGURATION
# =============================================================================
Write-Host "[TEST 4] SMB Client Configuration" -ForegroundColor Yellow
Write-Host ""

try {
    $smbConfig = Get-SmbClientConfiguration
    Write-Host "  SMB Client Status:" -ForegroundColor White
    Write-Host "    Enabled: $($smbConfig.EnableSMB1Protocol -or $smbConfig.EnableSMB2Protocol)" -ForegroundColor Gray
    Write-Host "    SMB1: $($smbConfig.EnableSMB1Protocol)" -ForegroundColor Gray
    Write-Host "    Require Security Signature: $($smbConfig.RequireSecuritySignature)" -ForegroundColor Gray
} catch {
    Write-Host "⚠️  Could not read SMB configuration" -ForegroundColor Yellow
}

Write-Host ""

# =============================================================================
# TEST 5: NETWORK SHARE ACCESS
# =============================================================================
Write-Host "[TEST 5] Network Share Access Test" -ForegroundColor Yellow
Write-Host "Path: $NetworkShare" -ForegroundColor Gray
Write-Host ""

try {
    if (Test-Path $NetworkShare -ErrorAction Stop) {
        Write-Host "✅ BASE SHARE ACCESSIBLE" -ForegroundColor Green
        
        # List subfolders
        $folders = Get-ChildItem -Path $NetworkShare -Directory -ErrorAction SilentlyContinue | Select-Object -First 5
        if ($folders) {
            Write-Host "   Found folders:" -ForegroundColor Gray
            foreach ($folder in $folders) {
                Write-Host "     - $($folder.Name)" -ForegroundColor Gray
            }
        }
    } else {
        Write-Host "❌ BASE SHARE NOT ACCESSIBLE" -ForegroundColor Red
    }
} catch {
    Write-Host "❌ SHARE ACCESS FAILED" -ForegroundColor Red
    Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "   Error Type: $($_.Exception.GetType().FullName)" -ForegroundColor Red
}

Write-Host ""

# =============================================================================
# TEST 6: SPECIFIC STUDENT FOLDER
# =============================================================================
Write-Host "[TEST 6] Student Folder Test" -ForegroundColor Yellow
Write-Host "Path: $TestFolder" -ForegroundColor Gray
Write-Host ""

try {
    if (Test-Path $TestFolder -ErrorAction Stop) {
        Write-Host "✅ STUDENT FOLDER ACCESSIBLE" -ForegroundColor Green
        
        # Check for PDFs
        $pdfs = Get-ChildItem -Path $TestFolder -Filter *.pdf -ErrorAction SilentlyContinue
        if ($pdfs) {
            Write-Host "   Found $($pdfs.Count) PDF(s):" -ForegroundColor Gray
            foreach ($pdf in $pdfs) {
                Write-Host "     - $($pdf.Name) ($([math]::Round($pdf.Length/1KB, 2)) KB)" -ForegroundColor Gray
            }
        } else {
            Write-Host "   No PDFs found (this is OK if teacher hasn't added any)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "❌ STUDENT FOLDER NOT ACCESSIBLE" -ForegroundColor Red
    }
} catch {
    Write-Host "❌ STUDENT FOLDER ACCESS FAILED" -ForegroundColor Red
    Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""

# =============================================================================
# TEST 7: DNS RESOLUTION
# =============================================================================
Write-Host "[TEST 7] DNS Resolution" -ForegroundColor Yellow
Write-Host ""

try {
    $dns = Resolve-DnsName -Name $ServerIP -ErrorAction Stop
    Write-Host "✅ DNS RESOLUTION WORKS" -ForegroundColor Green
} catch {
    Write-Host "⚠️  DNS resolution issue (not critical for IP-based access)" -ForegroundColor Yellow
    Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""

# =============================================================================
# TEST 8: CURRENT NETWORK ADAPTER INFO
# =============================================================================
Write-Host "[TEST 8] Network Adapter Information" -ForegroundColor Yellow
Write-Host ""

$adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
foreach ($adapter in $adapters) {
    $ipConfig = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    
    Write-Host "  Adapter: $($adapter.Name)" -ForegroundColor White
    Write-Host "    Status: $($adapter.Status)" -ForegroundColor Gray
    Write-Host "    Speed: $($adapter.LinkSpeed)" -ForegroundColor Gray
    if ($ipConfig) {
        Write-Host "    IP Address: $($ipConfig.IPAddress)" -ForegroundColor Gray
        Write-Host "    Subnet: $($ipConfig.PrefixLength)" -ForegroundColor Gray
    }
    Write-Host ""
}

# =============================================================================
# TEST 9: ROUTE TABLE
# =============================================================================
Write-Host "[TEST 9] Route to Server" -ForegroundColor Yellow
Write-Host ""

try {
    $route = Find-NetRoute -RemoteIPAddress $ServerIP -ErrorAction Stop | Select-Object -First 1
    Write-Host "  Route found:" -ForegroundColor White
    Write-Host "    Next Hop: $($route.NextHop)" -ForegroundColor Gray
    Write-Host "    Interface Index: $($route.InterfaceIndex)" -ForegroundColor Gray
} catch {
    Write-Host "⚠️  Could not find route" -ForegroundColor Yellow
}

Write-Host ""

# =============================================================================
# TEST 10: WINDOWS FIREWALL STATUS
# =============================================================================
Write-Host "[TEST 10] Windows Firewall Status" -ForegroundColor Yellow
Write-Host ""

$profiles = @("Domain", "Private", "Public")
foreach ($profile in $profiles) {
    $fwProfile = Get-NetFirewallProfile -Name $profile
    Write-Host "  $profile Profile:" -ForegroundColor White
    Write-Host "    Enabled: $($fwProfile.Enabled)" -ForegroundColor Gray
    Write-Host "    Default Outbound: $($fwProfile.DefaultOutboundAction)" -ForegroundColor Gray
}

Write-Host ""

# =============================================================================
# SUMMARY AND RECOMMENDATIONS
# =============================================================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   DIAGNOSTICS COMPLETE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "RECOMMENDATIONS:" -ForegroundColor Yellow
Write-Host ""

# Check if ping worked but share didn't
$pingWorked = $null -ne (Test-Connection -ComputerName $ServerIP -Count 1 -Quiet -ErrorAction SilentlyContinue)
$shareWorked = Test-Path $NetworkShare -ErrorAction SilentlyContinue

if ($pingWorked -and -not $shareWorked) {
    Write-Host "Network is reachable but share is not accessible" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Possible causes:" -ForegroundColor White
    Write-Host "  1. Firewall blocking SMB (port 445)" -ForegroundColor Gray
    Write-Host "  2. Share permissions issue" -ForegroundColor Gray
    Write-Host "  3. SMB protocol version mismatch" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Try this:" -ForegroundColor Cyan
    Write-Host "  # Temporarily disable kiosk firewall rules" -ForegroundColor Gray
    Write-Host "  .\restore-kiosk.ps1" -ForegroundColor White
    Write-Host "  # Then test share access again" -ForegroundColor Gray
    Write-Host "  Test-Path '$NetworkShare'" -ForegroundColor White
}

if (-not $pingWorked) {
    Write-Host "Server is not reachable via ping" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Possible causes:" -ForegroundColor White
    Write-Host "  1. Server is offline" -ForegroundColor Gray
    Write-Host "  2. Network cable disconnected" -ForegroundColor Gray
    Write-Host "  3. Wrong IP address" -ForegroundColor Gray
    Write-Host "  4. Firewall blocking ICMP" -ForegroundColor Gray
}

if ($shareWorked) {
    Write-Host "Everything looks good! Share is accessible." -ForegroundColor Green
}

Write-Host ""
Write-Host "For detailed firewall analysis, run:" -ForegroundColor Cyan
Write-Host '  Get-NetFirewallRule | Where-Object {$_.Direction -eq "Outbound" -and $_.Action -eq "Block"}' -ForegroundColor White
Write-Host ""

Read-Host "Press Enter to exit"
