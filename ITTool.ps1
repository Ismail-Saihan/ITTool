# ==============================================================================
# COMPANY IT DEPLOYMENT & PROVISIONING UTILITY (v2.0)
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
# 0. PRIVILEGE ELEVATION CHECK & SELF-RESTART
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
# LOGGING SYSTEM & ENVIRONMENT SETUP
# ==============================================================================
function Initialize-Environment {
    <#
    .SYNOPSIS
        Ensures necessary directory structures and log files exist.
    #>
    try {
        # Force TLS 1.2 and TLS 1.3 for secure web requests
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12, [Net.SecurityProtocolType]::Tls13

        if (-not (Test-Path -Path $Script:CompanyDir)) {
            New-Item -Path $Script:CompanyDir -ItemType Directory -Force | Out-Null
        }
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
        Downloads a remote file with visual status and validation.
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
    if (Test-Path -Path $Script:TempDir) {
        try {
            Remove-Item -Path $Script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            # Non-blocking
        }
    }
}

# ==============================================================================
# [1] INSTALL BROWSERS (CHROME & FIREFOX)
# ==============================================================================
function Install-GoogleChromeInternal {
    $downloadUrl = "https://dl.google.com/chrome/install/latest/chrome_installer.exe"
    $installerPath = "$Script:TempDir\chrome_installer.exe"

    Write-ITLog -Action "Chrome Installation" -Result "Started" -Level "INFO"

    $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $installerPath -DisplayName "Google Chrome Enterprise"
    if (-not $downloadSuccess) { return $false }

    Write-Host "[*] Installing Google Chrome silently..." -ForegroundColor Cyan
    try {
        $process = Start-Process -FilePath $installerPath -ArgumentList "/silent /install" -Wait -PassThru -NoNewWindow
        if ($process.ExitCode -eq 0) {
            Write-Host "[+] Google Chrome installed successfully!" -ForegroundColor Green
            Write-ITLog -Action "Chrome Installation" -Result "Completed Successfully (ExitCode: 0)" -Level "SUCCESS"
            return $true
        } else {
            Write-Host "[!] Chrome installer returned code: $($process.ExitCode)" -ForegroundColor Yellow
            Write-ITLog -Action "Chrome Installation" -Result "Exit code: $($process.ExitCode)" -Level "WARNING"
            return $false
        }
    } catch {
        Write-Host "[-] Chrome installation failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "Chrome Installation" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        if (Test-Path $installerPath) { Remove-Item $installerPath -Force -ErrorAction SilentlyContinue }
    }
}

function Install-MozillaFirefoxInternal {
    $downloadUrl = "https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=en-US"
    $installerPath = "$Script:TempDir\FirefoxSetup.exe"

    Write-ITLog -Action "Firefox Installation" -Result "Started" -Level "INFO"

    $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $installerPath -DisplayName "Mozilla Firefox 64-bit"
    if (-not $downloadSuccess) { return $false }

    Write-Host "[*] Installing Mozilla Firefox silently..." -ForegroundColor Cyan
    try {
        $process = Start-Process -FilePath $installerPath -ArgumentList "-ms" -Wait -PassThru -NoNewWindow
        if ($process.ExitCode -eq 0) {
            Write-Host "[+] Mozilla Firefox installed successfully!" -ForegroundColor Green
            Write-ITLog -Action "Firefox Installation" -Result "Completed Successfully (ExitCode: 0)" -Level "SUCCESS"
            return $true
        } else {
            Write-Host "[!] Firefox installer returned code: $($process.ExitCode)" -ForegroundColor Yellow
            Write-ITLog -Action "Firefox Installation" -Result "Exit code: $($process.ExitCode)" -Level "WARNING"
            return $false
        }
    } catch {
        Write-Host "[-] Firefox installation failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "Firefox Installation" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        if (Test-Path $installerPath) { Remove-Item $installerPath -Force -ErrorAction SilentlyContinue }
    }
}

function Menu-InstallBrowsers {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "          INSTALL WEB BROWSERS BUNDLE            " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "Installing Google Chrome and Mozilla Firefox..." -ForegroundColor Gray
    Write-Host ""
    Install-GoogleChromeInternal | Out-Null
    Write-Host ""
    Install-MozillaFirefoxInternal | Out-Null
    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# [2] INSTALL VOIP & VPN (MICROSIP & OPENVPN + PROFILE)
# ==============================================================================
function Install-MicroSIPInternal {
    $downloadUrl = "$Script:BaseRawUrl/Software/MicroSIP.exe"
    $installerPath = "$Script:TempDir\MicroSIP.exe"

    Write-ITLog -Action "MicroSIP Installation" -Result "Started" -Level "INFO"

    $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $installerPath -DisplayName "MicroSIP VoIP Client"
    if (-not $downloadSuccess) { return $false }

    Write-Host "[*] Installing MicroSIP silently..." -ForegroundColor Cyan
    try {
        # Close any active MicroSIP instance to prevent installer prompts
        Get-Process -Name "microsip" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

        # MicroSIP is packaged with NSIS. The silent switch is strictly /S (case-sensitive)
        $process = Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait -PassThru -NoNewWindow
        if ($process.ExitCode -eq 0) {
            Write-Host "[+] MicroSIP successfully installed!" -ForegroundColor Green
            Write-ITLog -Action "MicroSIP Installation" -Result "Completed Successfully" -Level "SUCCESS"
            return $true
        } else {
            Write-Host "[!] MicroSIP finished with code: $($process.ExitCode)" -ForegroundColor Yellow
            Write-ITLog -Action "MicroSIP Installation" -Result "Exit code: $($process.ExitCode)" -Level "WARNING"
            return $false
        }
    } catch {
        Write-Host "[-] MicroSIP installation failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "MicroSIP Installation" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        if (Test-Path $installerPath) { Remove-Item $installerPath -Force -ErrorAction SilentlyContinue }
    }
}

function Import-OpenVPNConfigInternal {
    param ([string]$ProfileName = "Carrybee-IPTSP-BOL.ovpn")

    Write-Host ""
    Write-Host "[*] Configuring OpenVPN Profile ($ProfileName)..." -ForegroundColor Cyan
    
    $ovpnRemoteUrl = "$Script:BaseRawUrl/Software/$ProfileName"
    $ovpnLocalPath = "$Script:CompanyDir\$ProfileName"

    $downloadSuccess = Download-FileWithProgress -Url $ovpnRemoteUrl -DestinationPath $ovpnLocalPath -DisplayName "VPN Profile ($ProfileName)"
    if (-not $downloadSuccess) { return $false }

    $imported = $false

    # 1. OpenVPN Connect v3
    $ovpnConnectPath = "$env:ProgramFiles\OpenVPN Connect\OpenVPNConnect.exe"
    if (Test-Path $ovpnConnectPath) {
        Write-Host "[*] OpenVPN Connect detected. Launching profile import..." -ForegroundColor Cyan
        try {
            Start-Process -FilePath $ovpnConnectPath -ArgumentList "--import-profile=`"$ovpnLocalPath`""
            Write-Host "[+] Profile sent to OpenVPN Connect successfully!" -ForegroundColor Green
            Write-ITLog -Action "Import OVPN Config" -Result "Imported into OpenVPN Connect ($ProfileName)" -Level "SUCCESS"
            $imported = $true
        } catch {
            Write-Host "[!] Error triggering OpenVPN Connect import: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-ITLog -Action "Import OVPN Config" -Result "Error: $($_.Exception.Message)" -Level "WARNING"
        }
    }

    # 2. OpenVPN Community Client
    $communityConfigPath = "$env:ProgramFiles\OpenVPN\config"
    if (Test-Path "$env:ProgramFiles\OpenVPN") {
        Write-Host "[*] OpenVPN Community detected. Copying profile to config folder..." -ForegroundColor Cyan
        try {
            if (-not (Test-Path $communityConfigPath)) { New-Item -Path $communityConfigPath -ItemType Directory -Force | Out-Null }
            Copy-Item -Path $ovpnLocalPath -Destination "$communityConfigPath\$ProfileName" -Force
            Write-Host "[+] Profile copied to $communityConfigPath\$ProfileName!" -ForegroundColor Green
            Write-ITLog -Action "Import OVPN Config" -Result "Copied to OpenVPN Community config" -Level "SUCCESS"
            $imported = $true
        } catch {
            Write-Host "[!] Error copying to OpenVPN config: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    return $imported
}

function Install-OpenVPNInternal {
    # Official OpenVPN Connect Client v3 (Corporate Client)
    $downloadUrl = "https://openvpn.net/downloads/openvpn-connect-v3-windows.msi"
    $installerPath = "$Script:TempDir\openvpn-connect-v3-windows.msi"

    Write-ITLog -Action "OpenVPN Connect Installation" -Result "Started" -Level "INFO"
    
    $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $installerPath -DisplayName "OpenVPN Connect Client"
    if (-not $downloadSuccess) {
        # Fallback to repository mirror if available
        $downloadUrl = "$Script:BaseRawUrl/Software/OpenVPN.msi"
        $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $installerPath -DisplayName "OpenVPN Client (Mirror)"
    }

    if (-not $downloadSuccess) { return $false }

    Write-Host "[*] Installing OpenVPN Connect Client silently (MSI)..." -ForegroundColor Cyan
    try {
        # Terminate any running instances before updating/installing
        Get-Process -Name "OpenVPNConnect", "ovpnconnector" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$installerPath`" /qn /norestart REBOOT=ReallySuppress" -Wait -PassThru -NoNewWindow
        
        if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
            Write-Host "[+] OpenVPN Connect Client successfully installed!" -ForegroundColor Green
            Write-ITLog -Action "OpenVPN Connect Installation" -Result "Completed Successfully (ExitCode: $($process.ExitCode))" -Level "SUCCESS"
        } else {
            Write-Host "[!] OpenVPN Connect finished with code: $($process.ExitCode)" -ForegroundColor Yellow
            Write-ITLog -Action "OpenVPN Connect Installation" -Result "Exit code: $($process.ExitCode)" -Level "WARNING"
        }

        # Auto-import Carrybee OVPN profile into OpenVPN Connect
        Import-OpenVPNConfigInternal -ProfileName "Carrybee-IPTSP-BOL.ovpn" | Out-Null
        return $true
    } catch {
        Write-Host "[-] OpenVPN Connect installation failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "OpenVPN Connect Installation" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        if (Test-Path $installerPath) { Remove-Item $installerPath -Force -ErrorAction SilentlyContinue }
    }
}

function Menu-InstallVoipAndVpn {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "         INSTALL VOIP & VPN BUNDLE               " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "Installing MicroSIP and OpenVPN Connect Client with Carrybee profile..." -ForegroundColor Gray
    Write-Host ""
    Install-MicroSIPInternal | Out-Null
    Write-Host ""
    Install-OpenVPNInternal | Out-Null
    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# [3] INSTALL REMOTE SUPPORT (ANYDESK & ULTRAVIEWER)
# ==============================================================================
function Install-AnyDeskInternal {
    $downloadUrl = "$Script:BaseRawUrl/Software/AnyDesk.exe"
    $installerPath = "$Script:TempDir\AnyDesk.exe"

    Write-ITLog -Action "AnyDesk Installation" -Result "Started" -Level "INFO"

    $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $installerPath -DisplayName "AnyDesk Remote Support"
    if (-not $downloadSuccess) { return $false }

    Write-Host "[*] Installing AnyDesk silently..." -ForegroundColor Cyan
    try {
        $targetProgFiles = ${env:ProgramFiles(x86)}
        if ([string]::IsNullOrWhiteSpace($targetProgFiles)) { $targetProgFiles = $env:ProgramFiles }
        $installLocation = Join-Path $targetProgFiles 'AnyDesk'

        $process = Start-Process -FilePath $installerPath -ArgumentList "--install `"$installLocation`" --start-with-win --silent" -Wait -PassThru -NoNewWindow
        if ($process.ExitCode -eq 0) {
            Write-Host "[+] AnyDesk installed successfully!" -ForegroundColor Green
            Write-ITLog -Action "AnyDesk Installation" -Result "Completed Successfully" -Level "SUCCESS"
            return $true
        } else {
            Write-Host "[!] AnyDesk finished with code: $($process.ExitCode)" -ForegroundColor Yellow
            Write-ITLog -Action "AnyDesk Installation" -Result "Exit code: $($process.ExitCode)" -Level "WARNING"
            return $false
        }
    } catch {
        Write-Host "[-] AnyDesk installation failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "AnyDesk Installation" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        if (Test-Path $installerPath) { Remove-Item $installerPath -Force -ErrorAction SilentlyContinue }
    }
}

function Install-UltraViewerInternal {
    $downloadUrl = "$Script:BaseRawUrl/Software/UltraViewer.exe"
    $installerPath = "$Script:TempDir\UltraViewer.exe"

    Write-ITLog -Action "UltraViewer Installation" -Result "Started" -Level "INFO"

    $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $installerPath -DisplayName "UltraViewer Support"
    if (-not $downloadSuccess) { return $false }

    Write-Host "[*] Installing UltraViewer silently..." -ForegroundColor Cyan
    try {
        $process = Start-Process -FilePath $installerPath -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART" -Wait -PassThru -NoNewWindow
        if ($process.ExitCode -eq 0) {
            Write-Host "[+] UltraViewer installed successfully!" -ForegroundColor Green
            Write-ITLog -Action "UltraViewer Installation" -Result "Completed Successfully" -Level "SUCCESS"
            return $true
        } else {
            Write-Host "[!] UltraViewer finished with code: $($process.ExitCode)" -ForegroundColor Yellow
            Write-ITLog -Action "UltraViewer Installation" -Result "Exit code: $($process.ExitCode)" -Level "WARNING"
            return $false
        }
    } catch {
        Write-Host "[-] UltraViewer installation failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "UltraViewer Installation" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        if (Test-Path $installerPath) { Remove-Item $installerPath -Force -ErrorAction SilentlyContinue }
    }
}

function Menu-InstallRemoteSupport {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "         INSTALL REMOTE SUPPORT TOOLS            " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "Installing AnyDesk and UltraViewer for Helpdesk access..." -ForegroundColor Gray
    Write-Host ""
    Install-AnyDeskInternal | Out-Null
    Write-Host ""
    Install-UltraViewerInternal | Out-Null
    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# [4] INSTALL DOTMAX PRINTER DRIVER
# ==============================================================================
function Menu-InstallDotMaxDriver {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "       INSTALL DOTMAX PRINTER DRIVER             " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan

    $fileName = "Driver software for Windows-72.exe"
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
    Write-Host "    Waiting for installation window to close..." -ForegroundColor Gray
    Write-Host "    (You can also press ENTER here at any time once you finish)" -ForegroundColor DarkGray

    try {
        # Launch without -Wait so PowerShell retains monitoring control
        $process = Start-Process -FilePath $installerPath -PassThru

        # Allow the GUI window to initialize
        Start-Sleep -Seconds 3

        # Active monitoring loop:
        # Detects when the installer window closes or if the user presses Enter
        while (-not $process.HasExited) {
            # Check if user pressed a key in console
            try {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq [ConsoleKey]::Enter -or $key.Key -eq [ConsoleKey]::Spacebar) {
                        Write-Host "`n[*] Manual continuation signaled by user." -ForegroundColor Cyan
                        break
                    }
                }
            } catch {}

            $process.Refresh()

            # If the installer's main GUI window handle is destroyed (closed by user)
            if ($process.MainWindowHandle -eq [System.IntPtr]::Zero) {
                Start-Sleep -Seconds 1
                $process.Refresh()
                if ($process.MainWindowHandle -eq [System.IntPtr]::Zero) {
                    Write-Host "`n[+] Installer window closed." -ForegroundColor Green
                    break
                }
            }

            Start-Sleep -Milliseconds 800
        }

        # Terminate any lingering background zombie processes of the installer
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }

        # Clean up any secondary worker processes left behind
        Get-Process | Where-Object { 
            ($_.Path -and $_.Path -like "*$fileName*") -or 
            ($_.ProcessName -match "Windows-72|Driver software")
        } | Stop-Process -Force -ErrorAction SilentlyContinue

        Write-Host "[+] DotMAX Printer Driver setup completed!" -ForegroundColor Green
        Write-ITLog -Action "DotMAX Driver Installation" -Result "Completed Successfully" -Level "SUCCESS"
    } catch {
        Write-Host "[-] Failed to execute driver installer: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "DotMAX Driver Installation" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
    } finally {
        if (Test-Path $installerPath) { Remove-Item $installerPath -Force -ErrorAction SilentlyContinue }
    }

    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# [5] INSTALL CANON LBP6030 / 6018 DRIVER (AUTOMATED PNP)
# ==============================================================================
function Install-CanonLBP6030Internal {
    <#
    .SYNOPSIS
        Automates Canon LBP6030/6040/6018L XPS driver injection into Windows Driver Store
        via pnputil and registers it with the Windows Print Spooler.
    #>
    $zipFileName   = "Canon_LBP6030_Driver.zip"
    $downloadUrl   = "$Script:BaseRawUrl/Software/$zipFileName"
    $zipPath       = "$Script:TempDir\$zipFileName"
    $extractDir    = "$Script:TempDir\CanonDriver"
    $infPath       = "$extractDir\cnnx0_cb3_len-GB.inf"
    $driverName    = "Canon LBP6030/6040/6018L XPS"

    Write-ITLog -Action "Canon LBP6030 Driver Installation" -Result "Started" -Level "INFO"

    $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $zipPath -DisplayName "Canon LBP6030 Driver"
    if (-not $downloadSuccess) { return $false }

    Write-Host "[*] Extracting Canon driver payload..." -ForegroundColor Cyan
    try {
        if (-not (Test-Path $extractDir)) { New-Item -Path $extractDir -ItemType Directory -Force | Out-Null }
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

        if (-not (Test-Path $infPath)) {
            throw "Driver INF file not found at $infPath"
        }

        # 1. Inject driver package into Windows Driver Store
        Write-Host "[*] Injecting driver into Windows Driver Store (pnputil)..." -ForegroundColor Cyan
        $pnpOutput = & pnputil.exe /add-driver $infPath /install
        Write-Host "    PnP Driver Store injection completed." -ForegroundColor Gray

        # 2. Register printer driver with Print Spooler
        Write-Host "[*] Registering driver with Windows Print Spooler..." -ForegroundColor Cyan
        try {
            Add-PrinterDriver -Name $driverName -ErrorAction SilentlyContinue
            Write-Host "[+] Driver '$driverName' registered successfully!" -ForegroundColor Green
        } catch {
            Write-Host "[!] Note on Add-PrinterDriver: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        # 3. Pre-create printer queue if desired
        Write-Host "[*] Checking printer queue status..." -ForegroundColor Cyan
        $existingPrinter = Get-Printer -Name "Canon LBP6030" -ErrorAction SilentlyContinue
        if (-not $existingPrinter) {
            try {
                Add-Printer -Name "Canon LBP6030" -DriverName $driverName -PortName "USB001" -ErrorAction SilentlyContinue
                Write-Host "[+] Printer 'Canon LBP6030' queue bound to port USB001!" -ForegroundColor Green
            } catch {
                Write-Host "[+] Driver is staged and ready! Connecting the printer via USB will automatically initialize it." -ForegroundColor Green
            }
        } else {
            Write-Host "[+] Printer 'Canon LBP6030' is already present." -ForegroundColor Green
        }

        Write-ITLog -Action "Canon LBP6030 Driver Installation" -Result "Completed Successfully" -Level "SUCCESS"
        return $true

    } catch {
        Write-Host "[-] Canon LBP6030 driver installation failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "Canon LBP6030 Driver Installation" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Menu-InstallCanonLBP6030 {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "     INSTALL CANON LBP6030 / 6018 DRIVER         " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "Automated Plug-and-Play Driver Injection via pnputil..." -ForegroundColor Gray
    Write-Host ""
    Install-CanonLBP6030Internal | Out-Null
    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# [6] DEPLOY PRINT SERVER & SECURITY RULES
# ==============================================================================
function Deploy-PrintServerInternal {
    $fileName = "PrintServer.exe"
    $downloadUrl = "$Script:BaseRawUrl/Software/$fileName"
    $targetFolder = $Script:CompanyDir
    $targetFile = "$targetFolder\$fileName"
    $tempFile = "$Script:TempDir\$fileName"

    Write-ITLog -Action "PrintServer Deployment" -Result "Started" -Level "INFO"

    $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $tempFile -DisplayName "Print Server Application"
    if (-not $downloadSuccess) { return $false }

    try {
        if (-not (Test-Path $targetFolder)) { New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null }
        Copy-Item -Path $tempFile -Destination $targetFile -Force
        Write-Host "[+] Copied application to: $targetFile" -ForegroundColor Green

        # Create Desktop Shortcut
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

        # Defender Exclusions
        Write-Host "[*] Adding Windows Defender exclusions..." -ForegroundColor Cyan
        try {
            Add-MpPreference -ExclusionPath $targetFolder -ErrorAction Stop
            Add-MpPreference -ExclusionPath $targetFile -ErrorAction Stop
            Write-Host "[+] Windows Defender exclusions added for folder and executable." -ForegroundColor Green
            Write-ITLog -Action "Defender Exclusion" -Result "Added for $targetFolder and $targetFile" -Level "SUCCESS"
        } catch {
            Write-Host "[!] Defender exclusion update warning ($($_.Exception.Message))." -ForegroundColor Yellow
        }

        # Windows 11 Smart App Control (SAC)
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        if ([int]$os.BuildNumber -ge 22000) {
            Write-Host "[*] Windows 11 detected. Checking Smart App Control state..." -ForegroundColor Cyan
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
                Write-Host "If Print Server is blocked, manually disable SAC:" -ForegroundColor White
                Write-Host "  Settings -> Privacy & Security -> Windows Security" -ForegroundColor Cyan
                Write-Host "  -> App & Browser Control -> Smart App Control" -ForegroundColor Cyan
                Write-Host "============================================================" -ForegroundColor Red
            }
        }

        Write-ITLog -Action "PrintServer Deployment" -Result "Completed Successfully" -Level "SUCCESS"
        Write-Host "[+] Print Server successfully configured!" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "[-] Error deploying Print Server: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "PrintServer Deployment" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
    }
}

function Menu-DeployPrintServer {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "          CONFIGURE PRINT SERVER APP             " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan
    Deploy-PrintServerInternal | Out-Null
    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# [6] DEVICE INFORMATION & RENAME
# ==============================================================================
function Menu-ShowDeviceInformation {
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

        Write-ITLog -Action "Query Device Information" -Result "Success (Host: $env:COMPUTERNAME)" -Level "INFO"

        Write-Host ""
        $renameChoice = Read-Host "Do you want to change computer name? (Y/N)"
        if ($renameChoice -match '^[Yy]$') {
            $newName = Read-Host "Enter new computer name (max 15 characters, no spaces)"
            if ([string]::IsNullOrWhiteSpace($newName) -or $newName.Length -gt 15) {
                Write-Host "[-] Invalid name (must be 1-15 characters). Aborted." -ForegroundColor Red
            } else {
                try {
                    Rename-Computer -NewName $newName -Force -ErrorAction Stop
                    Write-Host "[+] Computer successfully renamed to '$newName'." -ForegroundColor Green
                    Write-Host "[!] A RESTART IS REQUIRED for the change to take effect." -ForegroundColor Yellow
                    Write-ITLog -Action "Rename Computer" -Result "Renamed to $newName" -Level "SUCCESS"
                } catch {
                    Write-Host "[-] Failed to rename computer: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
    } catch {
        Write-Host "[-] Failed to retrieve device info: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# [7] NETWORK DIAGNOSTICS & CONNECTIVITY SUITE
# ==============================================================================
function Menu-NetworkDiagnostics {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "       NETWORK DIAGNOSTICS & HEALTH SUITE        " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan

    # 1. Local Adapters
    Write-Host "[*] Active Network Adapters:" -ForegroundColor Cyan
    $adapters = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true }
    foreach ($adapter in $adapters) {
        $ip = ($adapter.IPAddress | Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' }) -join ", "
        $gw = $adapter.DefaultIPGateway -join ", "
        $dns = $adapter.DNSServerSearchOrder -join ", "
        Write-Host "  - $($adapter.Description)" -ForegroundColor White
        Write-Host "    IPv4: $ip | Gateway: $gw | DNS: $dns" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "[*] Running Connectivity Tests..." -ForegroundColor Cyan

    # Ping Gateway
    $gateway = ($adapters | Where-Object { $_.DefaultIPGateway } | Select-Object -First 1).DefaultIPGateway[0]
    if ($gateway) {
        $gwTest = Test-Connection -ComputerName $gateway -Count 2 -Quiet -ErrorAction SilentlyContinue
        Write-Host "  Default Gateway ($gateway): " -NoNewline
        if ($gwTest) { Write-Host "[ONLINE]" -ForegroundColor Green } else { Write-Host "[OFFLINE / NO REPLY]" -ForegroundColor Red }
    }

    # Ping Google DNS
    $internetTest = Test-Connection -ComputerName "8.8.8.8" -Count 2 -Quiet -ErrorAction SilentlyContinue
    Write-Host "  Internet Ping (8.8.8.8):       " -NoNewline
    if ($internetTest) { Write-Host "[ONLINE]" -ForegroundColor Green } else { Write-Host "[OFFLINE]" -ForegroundColor Red }

    # Test DNS Resolution
    Write-Host "  DNS Resolution (google.com):   " -NoNewline
    try {
        $resolved = [System.Net.Dns]::GetHostAddresses("google.com")
        if ($resolved) { Write-Host "[SUCCESS: $($resolved[0].IPAddressToString)]" -ForegroundColor Green }
    } catch {
        Write-Host "[FAILED]" -ForegroundColor Red
    }

    # Public IP
    Write-Host "  Public IP Address:             " -NoNewline
    try {
        $publicIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 5 -ErrorAction Stop).Trim()
        Write-Host "[$publicIp]" -ForegroundColor Yellow
    } catch {
        Write-Host "[Unable to reach ipify]" -ForegroundColor Gray
    }

    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Quick Fix Actions:" -ForegroundColor White
    Write-Host "  1. Flush DNS & Renew DHCP IP"
    Write-Host "  2. Full Network Stack Reset (Winsock + TCP/IP)"
    Write-Host "  3. Return to Main Menu"
    $netChoice = Read-Host "Select an action [1-3]"

    switch ($netChoice.Trim()) {
        "1" {
            Write-Host "`n[*] Flushing DNS cache..." -ForegroundColor Cyan
            Clear-DnsClientCache -ErrorAction SilentlyContinue
            ipconfig /flushdns | Out-Null
            Write-Host "[*] Re-registering DNS..." -ForegroundColor Cyan
            ipconfig /registerdns | Out-Null
            Write-Host "[+] DNS Cache flushed and re-registered!" -ForegroundColor Green
            Write-ITLog -Action "Network Flush" -Result "Flushed DNS and renewed DHCP" -Level "SUCCESS"
            Start-Sleep -Seconds 2
        }
        "2" {
            Write-Host "`n[*] Resetting Winsock & TCP/IP stack..." -ForegroundColor Cyan
            netsh winsock reset | Out-Null
            netsh int ip reset | Out-Null
            Write-Host "[+] Network stack reset complete! (Restart recommended)" -ForegroundColor Green
            Write-ITLog -Action "Network Reset" -Result "Executed netsh winsock & int ip reset" -Level "SUCCESS"
            Start-Sleep -Seconds 2
        }
    }
}

# ==============================================================================
# [8] WINDOWS OS REPAIR & CLEANUP (SFC, DISM, TEMP CLEAN)
# ==============================================================================
function Menu-SystemRepairAndCleanup {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "      WINDOWS OS REPAIR & MAINTENANCE SUITE      " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "  1. Deep Temp & Windows Update Cache Cleanup"
    Write-Host "  2. Check Hardware & SSD S.M.A.R.T. Health"
    Write-Host "  3. Run System File Checker (sfc /scannow)"
    Write-Host "  4. Run DISM Component Store Repair"
    Write-Host "  5. Return to Main Menu"
    Write-Host "=================================================" -ForegroundColor Cyan

    $opt = Read-Host "Select an option [1-5]"
    switch ($opt.Trim()) {
        "1" {
            Write-Host "`n[*] Purging Temporary Files..." -ForegroundColor Cyan
            $tempPaths = @(
                "$env:TEMP\*",
                "C:\Windows\Temp\*",
                "C:\Windows\SoftwareDistribution\Download\*"
            )
            foreach ($path in $tempPaths) {
                try {
                    Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
                } catch {}
            }
            Write-Host "[+] Cache and temporary folders purged!" -ForegroundColor Green
            Write-ITLog -Action "Temp Cleanup" -Result "Cleared Windows and User Temp directories" -Level "SUCCESS"
            Start-Sleep -Seconds 2
        }
        "2" {
            Write-Host "`n[*] Checking Physical Storage Disks..." -ForegroundColor Cyan
            try {
                Get-PhysicalDisk | Select-Object DeviceId, FriendlyName, MediaType, OperationalStatus, HealthStatus | Format-Table -AutoSize
            } catch {
                Write-Host "[-] Could not query disk health: $($_.Exception.Message)" -ForegroundColor Red
            }
            Read-Host "`nPress Enter to continue..."
        }
        "3" {
            Write-Host "`n[*] Executing SFC scan (This may take several minutes)..." -ForegroundColor Cyan
            Start-Process -FilePath "sfc.exe" -ArgumentList "/scannow" -Wait -NoNewWindow
            Write-ITLog -Action "SFC Scan" -Result "Completed" -Level "INFO"
            Read-Host "`nPress Enter to continue..."
        }
        "4" {
            Write-Host "`n[*] Executing DISM Health Restoration (Please wait)..." -ForegroundColor Cyan
            Start-Process -FilePath "DISM.exe" -ArgumentList "/Online /Cleanup-Image /RestoreHealth" -Wait -NoNewWindow
            Write-ITLog -Action "DISM Repair" -Result "Completed" -Level "INFO"
            Read-Host "`nPress Enter to continue..."
        }
    }
}

# ==============================================================================
# [9] WINDOWS DEBLOAT & PERFORMANCE TWEAKS
# ==============================================================================
function Optimize-WindowsPerformanceInternal {
    Write-Host "[*] Applying High Performance Power Scheme..." -ForegroundColor Cyan
    try {
        # High Performance GUID
        powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
        Write-Host "[+] Power scheme set to High Performance." -ForegroundColor Green
    } catch {
        Write-Host "[!] Could not set High Performance plan." -ForegroundColor Yellow
    }

    Write-Host "[*] Resynchronizing System Time (NTP)..." -ForegroundColor Cyan
    try {
        Start-Service w32time -ErrorAction SilentlyContinue
        w32tm /resync /force | Out-Null
        Write-Host "[+] System clock successfully synchronized." -ForegroundColor Green
    } catch {
        Write-Host "[!] Could not resync clock ($($_.Exception.Message))." -ForegroundColor Yellow
    }

    Write-Host "[*] Removing consumer bloatware packages..." -ForegroundColor Cyan
    $bloatPatterns = @("*XboxApp*", "*Solitaire*", "*bingweather*", "*ZuneVideo*", "*GetHelp*", "*MicrosoftStickyNotes*")
    foreach ($pattern in $bloatPatterns) {
        Get-AppxPackage -AllUsers $pattern -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    }
    Write-Host "[+] Consumer bloatware packages removed." -ForegroundColor Green
    Write-ITLog -Action "Performance Tuning" -Result "Applied power plan, NTP sync, and Appx debloat" -Level "SUCCESS"
}

function Menu-WindowsTweaks {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "        WINDOWS PERFORMANCE & DEBLOAT            " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan
    Optimize-WindowsPerformanceInternal
    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# [10] EXPORT PC INFORMATION REPORT
# ==============================================================================
function Export-PCReportInternal {
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
        
        $disks   = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
            $free = [math]::Round(($_.FreeSpace / 1GB), 2)
            $size = [math]::Round(($_.Size / 1GB), 2)
            "$($_.DeviceID) ($free GB free of $size GB)"
        }

        $netConfigs = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true }
        $netDetails = $netConfigs | ForEach-Object {
            $ipv4 = ($_.IPAddress | Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' }) -join ", "
            "Adapter: $($_.Description)`n  MAC: $($_.MACAddress)`n  IPv4: $ipv4`n  Gateway: $($_.DefaultIPGateway -join ', ')`n  DNS: $($_.DNSServerSearchOrder -join ', ')"
        }

        $uninstallKeys = @(
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        $installedApps = Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and ($_.SystemComponent -ne 1) -and ($_.ParentKeyName -eq $null) } |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallDate |
            Sort-Object DisplayName -Unique

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
        foreach ($net in $netDetails) { [void]$reportBuilder.AppendLine($net) }
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

        $reportBuilder.ToString() | Out-File -FilePath $reportFilePath -Encoding utf8 -Force
        
        Write-Host "[+] Report generated successfully!" -ForegroundColor Green
        Write-Host "    File Location: $reportFilePath" -ForegroundColor Yellow
        Write-ITLog -Action "Export PC Report" -Result "Saved to $reportFilePath" -Level "SUCCESS"
        return $reportFilePath
    } catch {
        Write-Host "[-] Failed to generate report: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "Export PC Report" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
        return $null
    }
}

function Menu-ExportReport {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "         EXPORT PC INVENTORY REPORT              " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan
    Export-PCReportInternal | Out-Null
    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# [0] FAST ONBOARD: RUN COMPLETE PROVISIONING BUNDLE (ALL-IN-ONE)
# ==============================================================================
function Menu-FastOnboardAll {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "      FAST ONBOARD: RUN COMPLETE PROVISIONING BUNDLE       " -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "This will automatically execute the complete setup sequence:" -ForegroundColor White
    Write-Host "  1. Google Chrome & Mozilla Firefox"
    Write-Host "  2. MicroSIP VoIP & OpenVPN (+ Carrybee OVPN profile)"
    Write-Host "  3. AnyDesk & UltraViewer Remote Support"
    Write-Host "  4. Print Server deployment & Defender exclusions"
    Write-Host "  5. Windows Performance Tweaks & NTP Time Resync"
    Write-Host "  6. Automatic PC Inventory Report Export"
    Write-Host "============================================================" -ForegroundColor Cyan
    
    $confirm = Read-Host "Proceed with automated provisioning? (Y/N)"
    if ($confirm -notmatch '^[Yy]$') { return }

    Write-ITLog -Action "Fast Onboard" -Result "Started All-in-One Deployment" -Level "INFO"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host "`n[STAGE 1/6] Deploying Web Browsers..." -ForegroundColor Magenta
    Install-GoogleChromeInternal | Out-Null
    Install-MozillaFirefoxInternal | Out-Null

    Write-Host "`n[STAGE 2/6] Deploying VoIP & VPN..." -ForegroundColor Magenta
    Install-MicroSIPInternal | Out-Null
    Install-OpenVPNInternal | Out-Null

    Write-Host "`n[STAGE 3/6] Deploying Remote Support Tools..." -ForegroundColor Magenta
    Install-AnyDeskInternal | Out-Null
    Install-UltraViewerInternal | Out-Null

    Write-Host "`n[STAGE 4/6] Deploying Canon Driver, Print Server & Security..." -ForegroundColor Magenta
    Install-CanonLBP6030Internal | Out-Null
    Deploy-PrintServerInternal | Out-Null

    Write-Host "`n[STAGE 5/6] Applying Windows Optimization & NTP Clock Sync..." -ForegroundColor Magenta
    Optimize-WindowsPerformanceInternal

    Write-Host "`n[STAGE 6/6] Generating Final Inventory Audit..." -ForegroundColor Magenta
    $report = Export-PCReportInternal

    $stopwatch.Stop()
    $totalMinutes = [math]::Round($stopwatch.Elapsed.TotalMinutes, 2)

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "   COMPLETE PROVISIONING BUNDLE FINISHED IN $totalMinutes MINS!    " -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Green
    if ($report) { Write-Host "Report created on Desktop: $report" -ForegroundColor Cyan }
    Write-ITLog -Action "Fast Onboard" -Result "Completed in $totalMinutes minutes" -Level "SUCCESS"

    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

function Show-CompanyBanner {
    $banner = @'
   ____      _      ____   ____   __   __  ____   _____  _____ 
  / ___|    / \    |  _ \ |  _ \  \ \ / / | __ ) | ____|| ____|
 | |       / _ \   | |_) || |_) |  \ V /  |  _ \ |  _|  |  _|  
 | |___   / ___ \  |  _ < |  _ <    | |   | |_) || |___ | |___ 
  \____| /_/   \_\ |_| \_\|_| \_\   |_|   |____/ |_____||_____|
                  CARRYBEE IT DEPLOYMENT SUITE
'@
    Write-Host $banner -ForegroundColor Cyan
}

# ==============================================================================
# MAIN CONSOLE MENU LOOP
# ==============================================================================
function Show-MainMenu {
    Assert-Administrator
    Initialize-Environment

    do {
        Clear-Host
        Show-CompanyBanner
        Write-Host "=================================================" -ForegroundColor Cyan
        Write-Host "          CARRYBEE IT UTILITY TOOL (v2.0)        " -ForegroundColor Yellow
        Write-Host "=================================================" -ForegroundColor Cyan
        Write-Host " [0]  ⚡ RUN COMPLETE PROVISIONING BUNDLE        " -ForegroundColor Green
        Write-Host ""
        Write-Host " --- SOFTWARE DEPLOYMENTS ---                    " -ForegroundColor Gray
        Write-Host " [1]  Install Web Browsers (Chrome & Firefox)    " -ForegroundColor White
        Write-Host " [2]  Install VoIP & VPN (MicroSIP & OpenVPN Connect)" -ForegroundColor White
        Write-Host " [3]  Install Remote Support (AnyDesk / Ultra)   " -ForegroundColor White
        Write-Host " [4]  Install DotMAX Printer Driver (Wizard)     " -ForegroundColor White
        Write-Host " [5]  Install Canon LBP6030 Driver (Automated PnP)" -ForegroundColor White
        Write-Host " [6]  Deploy Print Server & Security Rules       " -ForegroundColor White
        Write-Host ""
        Write-Host " --- SYSTEM & NETWORK UTILITIES ---              " -ForegroundColor Gray
        Write-Host " [7]  Device Information & Rename PC             " -ForegroundColor White
        Write-Host " [8]  Network Diagnostics & Health Suite         " -ForegroundColor White
        Write-Host " [9]  Windows OS Repair & Cleanup (SFC/DISM/Temp)" -ForegroundColor White
        Write-Host " [10] Windows Debloat & Performance Tweaks       " -ForegroundColor White
        Write-Host " [11] Export PC Inventory Report                 " -ForegroundColor White
        Write-Host ""
        Write-Host " [X]  Exit                                       " -ForegroundColor Red
        Write-Host "=================================================" -ForegroundColor Cyan
        
        $selection = Read-Host "Select an option [0-11 or X]"

        switch ($selection.Trim().ToUpper()) {
            "0"  { Menu-FastOnboardAll }
            "1"  { Menu-InstallBrowsers }
            "2"  { Menu-InstallVoipAndVpn }
            "3"  { Menu-InstallRemoteSupport }
            "4"  { Menu-InstallDotMaxDriver }
            "5"  { Menu-InstallCanonLBP6030 }
            "6"  { Menu-DeployPrintServer }
            "7"  { Menu-ShowDeviceInformation }
            "8"  { Menu-NetworkDiagnostics }
            "9"  { Menu-SystemRepairAndCleanup }
            "10" { Menu-WindowsTweaks }
            "11" { Menu-ExportReport }
            "X"  {
                Write-Host "`n[*] Exiting Carrybee IT Tool. Goodbye!" -ForegroundColor Cyan
                Write-ITLog -Action "Session Terminated" -Result "User exited menu" -Level "INFO"
                Cleanup-TempFolder
                Start-Sleep -Seconds 1
                return
            }
            default {
                Write-Host "`n[-] Invalid selection. Please enter a valid number or X." -ForegroundColor Red
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
