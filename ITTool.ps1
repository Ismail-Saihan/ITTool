# ==============================================================================
# COMPANY IT DEPLOYMENT & PROVISIONING UTILITY
# Target OS: Windows 10 / Windows 11 (x64)
# Execution: irm https://<short-url>/ITTool | iex
# ==============================================================================

[CmdletBinding()]
param()

# --- Config & Global Constants ---
$Script:RepoOwner      = "Ismail-Saihan"
$Script:RepoName       = "ITTool"
$Script:Branch         = "main"
$Script:BaseRawUrl     = "https://raw.githubusercontent.com/$Script:RepoOwner/$Script:RepoName/$Script:Branch"
$Script:SelfRemoteUrl  = "$Script:BaseRawUrl/ITTool.ps1"

# Directory & Log Paths
$Script:CompanyDir     = "C:\CompanyTools"
$Script:LogDir         = "$Script:CompanyDir\Logs"
$Script:LogFile        = "$Script:LogDir\ITTool.log"
$Script:TempDir        = "$env:TEMP\ITTool_$(Get-Random)"

# ==============================================================================
# 0. PRIVILEGE ELEVATION CHECK
# ==============================================================================
function Assert-Administrator {
    <#
    .SYNOPSIS
        Verifies administrator privileges and self-elevates if running as standard user.
    #>
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Write-Warning "Administrator privileges required. Attempting self-elevation..."
        
        # Determine if executed from a physical script file or piped through IEX
        if ($PSCommandPath -and (Test-Path -Path $PSCommandPath)) {
            $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        } else {
            # Invoked via 'irm ... | iex'
            $arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"& { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12, [Net.SecurityProtocolType]::Tls13; irm '$Script:SelfRemoteUrl' | iex }`""
        }

        try {
            Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs
            Exit
        } catch {
            Write-Error "Failed to elevate privileges: $($_.Exception.Message)"
            Pause
            Exit 1
        }
    }
}

# ==============================================================================
# LOGGING SYSTEM
# ==============================================================================
function Initialize-Environment {
    <#
    .SYNOPSIS
        Ensures necessary directory structures and log files exist.
    #>
    try {
        # Force TLS 1.2 and TLS 1.3 for secure downloads
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12, [Net.SecurityProtocolType]::Tls13

        if (-not (Test-Path -Path $Script:LogDir)) {
            New-Item -Path $Script:LogDir -ItemType Directory -Force | Out-Null
        }
        if (-not (Test-Path -Path $Script:TempDir)) {
            New-Item -Path $Script:TempDir -ItemType Directory -Force | Out-Null
        }
    } catch {
        Write-Host "[-] Error initializing environment: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Write-ITLog {
    <#
    .SYNOPSIS
        Records timestamped audit trail to C:\CompanyTools\Logs\ITTool.log
    #>
    param (
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$Result,
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")][string]$Level = "INFO"
    )

    $timeStamp    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $currentUser  = "$env:USERDOMAIN\$env:USERNAME"
    $computerName = $env:COMPUTERNAME

    $logEntry = "[$timeStamp] [USER: $currentUser] [DEVICE: $computerName] [TYPE: $Level] Action: $Action | Result: $Result"

    try {
        $logEntry | Out-File -FilePath $Script:LogFile -Append -Encoding utf8
    } catch {
        Write-Warning "Could not write to log file: $($_.Exception.Message)"
    }
}

# ==============================================================================
# HELPER UTILITIES
# ==============================================================================
function Download-FileWithProgress {
    <#
    .SYNOPSIS
        Downloads a file with BITS/HttpClient with fallback and visual feedback.
    #>
    param (
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $false)][string]$DisplayName = "File"
    )

    Write-Host "[*] Downloading $DisplayName..." -ForegroundColor Cyan
    Write-Host "    Source: $Url" -ForegroundColor Gray
    Write-Host "    Dest:   $DestinationPath" -ForegroundColor Gray

    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", "Company-ITTool-Deployer/1.0")
        
        # Use synchronous download with custom progress display
        $totalBytes = 0
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Method = "HEAD"
        $request.Timeout = 10000
        try {
            $response = $request.GetResponse()
            $totalBytes = $response.ContentLength
            $response.Close()
        } catch {
            $totalBytes = -1
        }

        # Perform download using HttpClient or WebClient
        Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -UseBasicParsing -ErrorAction Stop

        if (Test-Path -Path $DestinationPath) {
            $fileSizeMB = [math]::Round(((Get-Item -Path $DestinationPath).Length / 1MB), 2)
            Write-Host "[+] Download completed ($fileSizeMB MB)" -ForegroundColor Green
            return $true
        } else {
            throw "Downloaded file not found at destination."
        }
    } catch {
        Write-Host "[-] Download failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "Download: $DisplayName" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Cleanup-TempFolder {
    <#
    .SYNOPSIS
        Cleans up temporary downloads.
    #>
    if (Test-Path -Path $Script:TempDir) {
        try {
            Remove-Item -Path $Script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            # Non-blocking cleanup
        }
    }
}

# ==============================================================================
# OPTION 1: DEVICE INFORMATION & RENAME
# ==============================================================================
function Show-DeviceInformation {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "              DEVICE INFORMATION                 " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan

    Write-Host "[*] Querying system components..." -ForegroundColor Gray
    try {
        $cs      = Get-CimInstance -ClassName Win32_ComputerSystem
        $os      = Get-CimInstance -ClassName Win32_OperatingSystem
        $bios    = Get-CimInstance -ClassName Win32_BIOS
        $cpu     = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
        $ramGB   = [math]::Round(($cs.TotalPhysicalMemory / 1GB), 2)
        
        # Network Adapter Details (Active adapters with IP)
        $netConfigs = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true }
        $ipList  = ($netConfigs.IPAddress | Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' }) -join ", "
        $macList = ($netConfigs.MACAddress) -join ", "

        $displayIp = if ($ipList) { $ipList } else { "N/A" }
        $displayMac = if ($macList) { $macList } else { "N/A" }

        Write-Host "Computer Name:       " -NoNewline; Write-Host $env:COMPUTERNAME -ForegroundColor Green
        Write-Host "BIOS Serial Number:  " -NoNewline; Write-Host $bios.SerialNumber -ForegroundColor Green
        Write-Host "Manufacturer:        " -NoNewline; Write-Host $cs.Manufacturer -ForegroundColor White
        Write-Host "Model:               " -NoNewline; Write-Host $cs.Model -ForegroundColor White
        Write-Host "CPU:                 " -NoNewline; Write-Host $cpu.Name.Trim() -ForegroundColor White
        Write-Host "RAM:                 " -NoNewline; Write-Host "$ramGB GB" -ForegroundColor White
        Write-Host "Windows Edition:     " -NoNewline; Write-Host $os.Caption -ForegroundColor White
        Write-Host "Windows Version:     " -NoNewline; Write-Host "$($os.Version) (Build $($os.BuildNumber))" -ForegroundColor White
        Write-Host "Current Username:    " -NoNewline; Write-Host "$env:USERDOMAIN\$env:USERNAME" -ForegroundColor White
        Write-Host "IP Address:          " -NoNewline; Write-Host $displayIp -ForegroundColor Yellow
        Write-Host "MAC Address:         " -NoNewline; Write-Host $displayMac -ForegroundColor Yellow
        Write-Host "=================================================" -ForegroundColor Cyan

        Write-ITLog -Action "Query Device Information" -Result "Success (Host: $env:COMPUTERNAME, Serial: $($bios.SerialNumber))" -Level "INFO"

        Write-Host ""
        $renameChoice = Read-Host "Do you want to change computer name? (Y/N)"
        if ($renameChoice -match '^[Yy]$') {
            $newName = Read-Host "Enter new computer name (max 15 characters, no spaces)"
            if ([string]::IsNullOrWhiteSpace($newName)) {
                Write-Host "[-] Invalid name entered. Aborting rename." -ForegroundColor Red
            } elseif ($newName.Length -gt 15) {
                Write-Host "[-] Error: NetBIOS computer names must be 15 characters or fewer." -ForegroundColor Red
            } else {
                try {
                    Rename-Computer -NewName $newName -Force -ErrorAction Stop
                    Write-Host "[+] Computer successfully renamed to '$newName'." -ForegroundColor Green
                    Write-Host "[!] A RESTART IS REQUIRED for the new computer name to take effect." -ForegroundColor Yellow
                    Write-ITLog -Action "Rename Computer" -Result "Success: OldName=$env:COMPUTERNAME, NewName=$newName" -Level "SUCCESS"
                } catch {
                    Write-Host "[-] Failed to rename computer: $($_.Exception.Message)" -ForegroundColor Red
                    Write-ITLog -Action "Rename Computer" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
                }
            }
        }
    } catch {
        Write-Host "[-] Failed to retrieve device information: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "Query Device Information" -Result "Error: $($_.Exception.Message)" -Level "ERROR"
    }

    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# OPTION 2: INSTALL OPENVPN CLIENT
# ==============================================================================
function Install-OpenVPN {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "            INSTALL OPENVPN CLIENT               " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan

    $downloadUrl = "$Script:BaseRawUrl/Software/OpenVPN.exe"
    $installerPath = "$Script:TempDir\OpenVPN.exe"

    Write-ITLog -Action "OpenVPN Installation" -Result "Started" -Level "INFO"
    
    $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $installerPath -DisplayName "OpenVPN Installer"
    if (-not $downloadSuccess) {
        Write-Host "[-] Installation aborted due to download failure." -ForegroundColor Red
        Read-Host "Press Enter to continue..."
        return
    }

    Write-Host "[*] Executing silent installation (Please wait)..." -ForegroundColor Cyan
    try {
        # OpenVPN community installers standard silent flag is /S
        $process = Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait -PassThru -NoNewWindow
        
        if ($process.ExitCode -eq 0) {
            Write-Host "[+] OpenVPN successfully installed!" -ForegroundColor Green
            Write-ITLog -Action "OpenVPN Installation" -Result "Completed Successfully (ExitCode: 0)" -Level "SUCCESS"
        } else {
            Write-Host "[!] OpenVPN installer finished with exit code: $($process.ExitCode)" -ForegroundColor Yellow
            Write-ITLog -Action "OpenVPN Installation" -Result "Completed with warning (ExitCode: $($process.ExitCode))" -Level "WARNING"
        }
    } catch {
        Write-Host "[-] OpenVPN installation failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "OpenVPN Installation" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
    } finally {
        if (Test-Path -Path $installerPath) {
            Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# OPTION 3: INSTALL MICROSIP
# ==============================================================================
function Install-MicroSIP {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "               INSTALL MICROSIP                  " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan

    $downloadUrl = "$Script:BaseRawUrl/Software/MicroSIP.exe"
    $installerPath = "$Script:TempDir\MicroSIP.exe"

    Write-ITLog -Action "MicroSIP Installation" -Result "Started" -Level "INFO"

    $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $installerPath -DisplayName "MicroSIP Installer"
    if (-not $downloadSuccess) {
        Write-Host "[-] Installation aborted due to download failure." -ForegroundColor Red
        Read-Host "Press Enter to continue..."
        return
    }

    Write-Host "[*] Executing silent installation (/VERYSILENT /NORESTART)..." -ForegroundColor Cyan
    try {
        # MicroSIP is built with Inno Setup. Silent flags: /VERYSILENT /SUPPRESSMSGBOXES /NORESTART or /S
        $process = Start-Process -FilePath $installerPath -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART" -Wait -PassThru -NoNewWindow
        
        if ($process.ExitCode -eq 0) {
            Write-Host "[+] MicroSIP successfully installed!" -ForegroundColor Green
            Write-ITLog -Action "MicroSIP Installation" -Result "Completed Successfully (ExitCode: 0)" -Level "SUCCESS"
        } else {
            Write-Host "[!] MicroSIP installer finished with exit code: $($process.ExitCode)" -ForegroundColor Yellow
            Write-ITLog -Action "MicroSIP Installation" -Result "Finished with exit code: $($process.ExitCode)" -Level "WARNING"
        }
    } catch {
        Write-Host "[-] MicroSIP installation failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "MicroSIP Installation" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
    } finally {
        if (Test-Path -Path $installerPath) {
            Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# OPTION 4: INSTALL GOOGLE CHROME ENTERPRISE
# ==============================================================================
function Install-GoogleChrome {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "            INSTALL GOOGLE CHROME                " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan

    # Official Google Chrome Enterprise 64-bit MSI Installer URL
    $downloadUrl = "https://dl.google.com/chrome/install/latest/chrome_installer.exe"
    $installerPath = "$Script:TempDir\chrome_installer.exe"

    Write-ITLog -Action "Chrome Installation" -Result "Started" -Level "INFO"

    $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $installerPath -DisplayName "Google Chrome Installer"
    if (-not $downloadSuccess) {
        Write-Host "[-] Aborting Chrome installation." -ForegroundColor Red
        Read-Host "Press Enter to continue..."
        return
    }

    Write-Host "[*] Installing Google Chrome silently (/silent /install)..." -ForegroundColor Cyan
    try {
        $process = Start-Process -FilePath $installerPath -ArgumentList "/silent /install" -Wait -PassThru -NoNewWindow

        if ($process.ExitCode -eq 0) {
            Write-Host "[+] Google Chrome installed successfully!" -ForegroundColor Green
            Write-ITLog -Action "Chrome Installation" -Result "Completed Successfully (ExitCode: 0)" -Level "SUCCESS"
        } else {
            Write-Host "[!] Chrome installer finished with exit code: $($process.ExitCode)" -ForegroundColor Yellow
            Write-ITLog -Action "Chrome Installation" -Result "Exited with code: $($process.ExitCode)" -Level "WARNING"
        }
    } catch {
        Write-Host "[-] Chrome installation failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "Chrome Installation" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
    } finally {
        if (Test-Path -Path $installerPath) {
            Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# OPTION 5: INSTALL MOZILLA FIREFOX
# ==============================================================================
function Install-MozillaFirefox {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "            INSTALL MOZILLA FIREFOX              " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan

    # Official Mozilla direct 64-bit installer download endpoint
    $downloadUrl = "https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=en-US"
    $installerPath = "$Script:TempDir\FirefoxSetup.exe"

    Write-ITLog -Action "Firefox Installation" -Result "Started" -Level "INFO"

    $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $installerPath -DisplayName "Mozilla Firefox Installer"
    if (-not $downloadSuccess) {
        Write-Host "[-] Aborting Firefox installation." -ForegroundColor Red
        Read-Host "Press Enter to continue..."
        return
    }

    Write-Host "[*] Installing Mozilla Firefox silently (-ms)..." -ForegroundColor Cyan
    try {
        $process = Start-Process -FilePath $installerPath -ArgumentList "-ms" -Wait -PassThru -NoNewWindow

        if ($process.ExitCode -eq 0) {
            Write-Host "[+] Mozilla Firefox installed successfully!" -ForegroundColor Green
            Write-ITLog -Action "Firefox Installation" -Result "Completed Successfully (ExitCode: 0)" -Level "SUCCESS"
        } else {
            Write-Host "[!] Firefox installer finished with exit code: $($process.ExitCode)" -ForegroundColor Yellow
            Write-ITLog -Action "Firefox Installation" -Result "Exited with code: $($process.ExitCode)" -Level "WARNING"
        }
    } catch {
        Write-Host "[-] Firefox installation failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "Firefox Installation" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
    } finally {
        if (Test-Path -Path $installerPath) {
            Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# OPTION 6: INSTALL DOTMAX PRINTER DRIVER (INTERACTIVE)
# ==============================================================================
function Install-DotMaxDriver {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "       INSTALL DOTMAX PRINTER DRIVER             " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan

    $fileName = "Driver software for Windows-72.exe"
    # Proper URL-encoding for spaces and characters
    $encodedFileName = [System.Uri]::EscapeDataString($fileName)
    $downloadUrl = "$Script:BaseRawUrl/Software/$encodedFileName"
    $installerPath = "$Script:TempDir\$fileName"

    Write-ITLog -Action "DotMAX Driver Installation" -Result "Started (Interactive Mode)" -Level "INFO"

    $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $installerPath -DisplayName "DotMAX Driver"
    if (-not $downloadSuccess) {
        Write-Host "[-] Aborting driver installation." -ForegroundColor Red
        Read-Host "Press Enter to continue..."
        return
    }

    Write-Host ""
    Write-Host "[!] NOTICE: This installer is INTERACTIVE." -ForegroundColor Yellow
    Write-Host "[*] Launching installer wizard now. Complete the on-screen steps..." -ForegroundColor Cyan
    Write-Host "    Waiting for installation to finish..." -ForegroundColor Gray

    try {
        # Interactive mode: do not pass silent switches, do not hide window
        $process = Start-Process -FilePath $installerPath -Wait -PassThru

        Write-Host "[+] DotMAX Printer Driver setup process completed (Exit code: $($process.ExitCode))." -ForegroundColor Green
        Write-ITLog -Action "DotMAX Driver Installation" -Result "Completed (ExitCode: $($process.ExitCode))" -Level "SUCCESS"
    } catch {
        Write-Host "[-] Failed to execute driver installer: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "DotMAX Driver Installation" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
    } finally {
        if (Test-Path -Path $installerPath) {
            Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# OPTION 7: DOWNLOAD PRINT SERVER & CONFIGURE SECURITY
# ==============================================================================
function Install-PrintServer {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "          CONFIGURE PRINT SERVER APP             " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan

    $fileName = "PrintServer.exe"
    $downloadUrl = "$Script:BaseRawUrl/Software/$fileName"
    $targetFolder = $Script:CompanyDir
    $targetFile = "$targetFolder\$fileName"
    $tempFile = "$Script:TempDir\$fileName"

    Write-ITLog -Action "PrintServer Deployment" -Result "Started" -Level "INFO"

    # 1. Download
    $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $tempFile -DisplayName "Print Server Application"
    if (-not $downloadSuccess) {
        Write-Host "[-] Aborting Print Server deployment." -ForegroundColor Red
        Read-Host "Press Enter to continue..."
        return
    }

    try {
        # 2. Ensure C:\CompanyTools folder exists
        if (-not (Test-Path -Path $targetFolder)) {
            New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null
            Write-Host "[+] Created directory: $targetFolder" -ForegroundColor Green
        }

        # 3. Copy file to destination
        Copy-Item -Path $tempFile -Destination $targetFile -Force
        Write-Host "[+] Copied application to: $targetFile" -ForegroundColor Green

        # 4. Create Desktop Shortcut
        $desktopPath = [Environment]::GetFolderPath("Desktop")
        $shortcutPath = "$desktopPath\Print Server.lnk"
        
        $wshShell = New-Object -ComObject WScript.Shell
        $shortcut = $wshShell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $targetFile
        $shortcut.WorkingDirectory = $targetFolder
        $shortcut.Description = "Company Print Server Application"
        $shortcut.IconLocation = "$targetFile,0"
        $shortcut.Save()
        Write-Host "[+] Created Desktop shortcut: $shortcutPath" -ForegroundColor Green

        # 5. Add Windows Defender Exclusions
        Write-Host "[*] Adding Windows Defender exclusions..." -ForegroundColor Cyan
        try {
            # Add exclusion for folder
            Add-MpPreference -ExclusionPath $targetFolder -ErrorAction Stop
            # Add exclusion for file
            Add-MpPreference -ExclusionPath $targetFile -ErrorAction Stop
            Write-Host "[+] Windows Defender exclusions added for folder and executable." -ForegroundColor Green
            Write-ITLog -Action "Defender Exclusion" -Result "Added for $targetFolder and $targetFile" -Level "SUCCESS"
        } catch {
            Write-Host "[!] Note: Could not update Windows Defender preferences ($($_.Exception.Message))." -ForegroundColor Yellow
            Write-ITLog -Action "Defender Exclusion" -Result "Warning: $($_.Exception.Message)" -Level "WARNING"
        }

        # 6. Check Windows 11 Smart App Control (SAC)
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $buildNumber = [int]$os.BuildNumber
        
        # Build 22000+ is Windows 11
        if ($buildNumber -ge 22000) {
            Write-Host "[*] Windows 11 detected. Checking Smart App Control state..." -ForegroundColor Cyan
            
            # Smart App Control state is stored in registry:
            # HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy -> VerifiedAndReputablePolicyState
            # 0 = Off, 1 = Enforced (On), 2 = Evaluation
            $sacState = 0
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy"
            if (Test-Path $regPath) {
                $prop = Get-ItemProperty -Path $regPath -Name "VerifiedAndReputablePolicyState" -ErrorAction SilentlyContinue
                if ($prop -and ($prop.VerifiedAndReputablePolicyState -ne $null)) {
                    $sacState = $prop.VerifiedAndReputablePolicyState
                }
            }

            if ($sacState -eq 1 -or $sacState -eq 2) {
                $sacStatusDesc = if ($sacState -eq 1) { "ENABLED (Enforced)" } else { "in EVALUATION mode" }
                Write-Host ""
                Write-Host "============================================================" -ForegroundColor Red
                Write-Host "              SMART APP CONTROL NOTICE                      " -ForegroundColor Yellow
                Write-Host "============================================================" -ForegroundColor Red
                Write-Host "Smart App Control is currently $sacStatusDesc." -ForegroundColor Yellow
                Write-Host "Windows requires manual disabling by the administrator:" -ForegroundColor White
                Write-Host "  Settings" -ForegroundColor Cyan
                Write-Host "  -> Privacy & Security" -ForegroundColor Cyan
                Write-Host "  -> Windows Security" -ForegroundColor Cyan
                Write-Host "  -> App & Browser Control" -ForegroundColor Cyan
                Write-Host "  -> Smart App Control" -ForegroundColor Cyan
                Write-Host "============================================================" -ForegroundColor Red
                Write-ITLog -Action "Smart App Control Check" -Result "Active ($sacState). Manual disable required if blocked." -Level "WARNING"
            } else {
                Write-Host "[+] Smart App Control is not enforced or disabled." -ForegroundColor Green
            }
        }

        Write-ITLog -Action "PrintServer Deployment" -Result "Completed Successfully" -Level "SUCCESS"
        Write-Host ""
        Write-Host "[+] Print Server successfully configured!" -ForegroundColor Green

    } catch {
        Write-Host "[-] Error deploying Print Server: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "PrintServer Deployment" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
    } finally {
        if (Test-Path -Path $tempFile) {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# OPTION 8: EXPORT PC INFORMATION REPORT
# ==============================================================================
function Export-PCReport {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "         EXPORT PC INVENTORY REPORT              " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan

    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $sanitizedPcName = $env:COMPUTERNAME -replace '[\\/:*?"<>|]', '_'
    $reportFilePath = "$desktopPath\$sanitizedPcName-Report.txt"

    Write-Host "[*] Generating hardware, OS, network, and application inventory..." -ForegroundColor Cyan

    try {
        $cs      = Get-CimInstance -ClassName Win32_ComputerSystem
        $os      = Get-CimInstance -ClassName Win32_OperatingSystem
        $bios    = Get-CimInstance -ClassName Win32_BIOS
        $cpu     = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
        $ramGB   = [math]::Round(($cs.TotalPhysicalMemory / 1GB), 2)
        
        # Disk Information
        $disks   = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
            $free = [math]::Round(($_.FreeSpace / 1GB), 2)
            $size = [math]::Round(($_.Size / 1GB), 2)
            "$($_.DeviceID) ($free GB free of $size GB)"
        }

        # Network details
        $netConfigs = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true }
        $netDetails = $netConfigs | ForEach-Object {
            $ipv4 = ($_.IPAddress | Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' }) -join ", "
            "Adapter: $($_.Description)`n  MAC: $($_.MACAddress)`n  IPv4: $ipv4`n  Gateway: $($_.DefaultIPGateway -join ', ')`n  DNS: $($_.DNSServerSearchOrder -join ', ')"
        }

        # Installed Applications from both 32-bit and 64-bit Registry
        $uninstallKeys = @(
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        $installedApps = Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and ($_.SystemComponent -ne 1) -and ($_.ParentKeyName -eq $null) } |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallDate |
            Sort-Object DisplayName -Unique

        # Format report content
        $reportBuilder = [System.Text.StringBuilder]::new()
        [void]$reportBuilder.AppendLine("================================================================================")
        [void]$reportBuilder.AppendLine("                         COMPANY IT INVENTORY REPORT                            ")
        [void]$reportBuilder.AppendLine("================================================================================")
        [void]$reportBuilder.AppendLine("Generated On:        $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        [void]$reportBuilder.AppendLine("Technician Account:  $env:USERDOMAIN\$env:USERNAME")
        [void]$reportBuilder.AppendLine("")
        [void]$reportBuilder.AppendLine("--- SYSTEM & HARDWARE SPECIFICATIONS ---")
        [void]$reportBuilder.AppendLine("Computer Name:       $env:COMPUTERNAME")
        [void]$reportBuilder.AppendLine("BIOS Serial Number:  $($bios.SerialNumber)")
        [void]$reportBuilder.AppendLine("Manufacturer:        $($cs.Manufacturer)")
        [void]$reportBuilder.AppendLine("Model:               $($cs.Model)")
        [void]$reportBuilder.AppendLine("Processor (CPU):     $($cpu.Name.Trim())")
        [void]$reportBuilder.AppendLine("Installed RAM:       $ramGB GB")
        [void]$reportBuilder.AppendLine("Disks:               $($disks -join ' | ')")
        [void]$reportBuilder.AppendLine("")
        [void]$reportBuilder.AppendLine("--- OPERATING SYSTEM ---")
        [void]$reportBuilder.AppendLine("OS Edition:          $($os.Caption)")
        [void]$reportBuilder.AppendLine("OS Version / Build:  $($os.Version) (Build $($os.BuildNumber))")
        [void]$reportBuilder.AppendLine("OS Architecture:     $($os.OSArchitecture)")
        [void]$reportBuilder.AppendLine("Install Date:        $($os.InstallDate)")
        [void]$reportBuilder.AppendLine("Last Boot Up Time:   $($os.LastBootUpTime)")
        [void]$reportBuilder.AppendLine("")
        [void]$reportBuilder.AppendLine("--- NETWORK CONFIGURATION ---")
        foreach ($net in $netDetails) {
            [void]$reportBuilder.AppendLine($net)
        }
        [void]$reportBuilder.AppendLine("")
        [void]$reportBuilder.AppendLine("--- INSTALLED APPLICATIONS ($($installedApps.Count) Found) ---")
        [void]$reportBuilder.AppendLine(("{0,-50} {1,-20} {2}" -f "Name", "Version", "Publisher"))
        [void]$reportBuilder.AppendLine("-" * 95)
        foreach ($app in $installedApps) {
            $name    = if ($app.DisplayName.Length -gt 48) { $app.DisplayName.Substring(0, 45) + "..." } else { $app.DisplayName }
            $version = if ($app.DisplayVersion) { $app.DisplayVersion } else { "N/A" }
            $pub     = if ($app.Publisher) { $app.Publisher } else { "" }
            [void]$reportBuilder.AppendLine(("{0,-50} {1,-20} {2}" -f $name, $version, $pub))
        }
        [void]$reportBuilder.AppendLine("================================================================================")
        [void]$reportBuilder.AppendLine("End of Report")

        # Save UTF-8 encoded file
        $reportBuilder.ToString() | Out-File -FilePath $reportFilePath -Encoding utf8 -Force
        
        Write-Host "[+] Report generated successfully!" -ForegroundColor Green
        Write-Host "    File Location: $reportFilePath" -ForegroundColor Yellow
        Write-ITLog -Action "Export PC Report" -Result "Saved to $reportFilePath" -Level "SUCCESS"
    } catch {
        Write-Host "[-] Failed to generate inventory report: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "Export PC Report" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
    }

    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# MAIN CONSOLE MENU LOOP
# ==============================================================================
function Show-MainMenu {
    Assert-Administrator
    Initialize-Environment

    do {
        Clear-Host
        Write-Host "=========================================" -ForegroundColor Cyan
        Write-Host "             COMPANY IT TOOL             " -ForegroundColor White
        Write-Host "=========================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  1. Device Information" -ForegroundColor White
        Write-Host "  2. Install OpenVPN Client" -ForegroundColor White
        Write-Host "  3. Install MicroSIP" -ForegroundColor White
        Write-Host "  4. Install Google Chrome" -ForegroundColor White
        Write-Host "  5. Install Mozilla Firefox" -ForegroundColor White
        Write-Host "  6. Install DotMAX Printer Driver" -ForegroundColor White
        Write-Host "  7. Download Print Server" -ForegroundColor White
        Write-Host "  8. Export PC Information Report" -ForegroundColor White
        Write-Host "  9. Exit" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "=========================================" -ForegroundColor Cyan
        
        $selection = Read-Host "Select an option [1-9]"

        switch ($selection.Trim()) {
            "1" { Show-DeviceInformation }
            "2" { Install-OpenVPN }
            "3" { Install-MicroSIP }
            "4" { Install-GoogleChrome }
            "5" { Install-MozillaFirefox }
            "6" { Install-DotMaxDriver }
            "7" { Install-PrintServer }
            "8" { Export-PCReport }
            "9" {
                Write-Host "`n[*] Exiting Company IT Tool. Goodbye!" -ForegroundColor Cyan
                Write-ITLog -Action "Session Terminated" -Result "User exited menu" -Level "INFO"
                Cleanup-TempFolder
                Start-Sleep -Seconds 1
                return
            }
            default {
                Write-Host "`n[-] Invalid selection. Please enter a number between 1 and 9." -ForegroundColor Red
                Start-Sleep -Seconds 1.5
            }
        }
    } while ($true)
}

# --- Entry Point Execution ---
try {
    Show-MainMenu
} finally {
    Cleanup-TempFolder
}
