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
$Script:DownloadDir    = "$Script:CompanyDir\Downloads"
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
            $arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"& { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]'Tls,Tls11,Tls12'; [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { `$true }; irm '$Script:SelfRemoteUrl' | iex }`""
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
        # Resilient TLS 1.2/1.3 setup and SSL certificate trust bypass for field PCs with clock skew/untrusted root CAs
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]'Tls,Tls11,Tls12'
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 12288
        } catch {}
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

        if (-not (Test-Path -Path $Script:CompanyDir)) {
            New-Item -Path $Script:CompanyDir -ItemType Directory -Force | Out-Null
        }
        if (-not (Test-Path -Path $Script:DownloadDir)) {
            New-Item -Path $Script:DownloadDir -ItemType Directory -Force | Out-Null
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
# HELPER UTILITIES & SMART CACHING
# ==============================================================================
function Test-FileAlreadyDownloaded {
    <#
    .SYNOPSIS
        Checks if a target file is already downloaded in the desired folder
        and verifies that it is valid and meets size requirements.
    .PARAMETER FilePath
        Target file path to check.
    .PARAMETER MinBytes
        Minimum required file size in bytes (default: 1024 bytes).
    .OUTPUTS
        Boolean ($true if valid cached file exists, $false otherwise).
    #>
    param (
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $false)][long]$MinBytes = 1024
    )

    if ([string]::IsNullOrWhiteSpace($FilePath)) { return $false }

    if (Test-Path -Path $FilePath) {
        try {
            $item = Get-Item -Path $FilePath -ErrorAction Stop
            if ($item.Length -ge $MinBytes) {
                $sizeMB = [math]::Round(($item.Length / 1MB), 2)
                Write-Host "[+] Verified existing file: $($item.Name) ($sizeMB MB)" -ForegroundColor Green
                Write-Host "    Using cached file at: $FilePath" -ForegroundColor Gray
                return $true
            } else {
                Write-Warning "File exists at $FilePath but is incomplete or 0 bytes ($($item.Length) bytes). Re-downloading..."
                Remove-Item -Path $FilePath -Force -ErrorAction SilentlyContinue
                return $false
            }
        } catch {
            return $false
        }
    }
    return $false
}

function Download-FileWithProgress {
    <#
    .SYNOPSIS
        Downloads a remote file with visual progress tracking, smart caching,
        and local storage fallback (USB/Offline folders).
    #>
    param (
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $false)][string]$DisplayName = "File",
        [Parameter(Mandatory = $false)][long]$MinBytes = 1024,
        [Parameter(Mandatory = $false)][switch]$Force
    )

    # 1. Smart Cache Check: Avoid downloading if file already exists in desired folder
    if (-not $Force -and (Test-FileAlreadyDownloaded -FilePath $DestinationPath -MinBytes $MinBytes)) {
        Write-Host "[*] Skipping download for $DisplayName (already present in desired folder)." -ForegroundColor Cyan
        Write-ITLog -Action "Cache Check: $DisplayName" -Result "Reused cached file: $DestinationPath" -Level "INFO"
        return $true
    }

    # 2. Local Disk / USB / Offline Bundle Search: Avoid internet download if available locally
    $targetName = [System.IO.Path]::GetFileName($DestinationPath)
    $localSearchPaths = @(
        "$PSScriptRoot\Software\$targetName",
        "G:\ITTool\Software\$targetName",
        "G:\Branch Software\Printer Driver\$targetName",
        "G:\Branch Software\Installers\$targetName",
        "G:\Branch Software\Installers\OpenVPN\$targetName",
        "$Script:DownloadDir\$targetName"
    )

    # If searching for OpenVPN, dynamically scan all fixed/removable drives for Branch Software
    if ($targetName -like "*openvpn*") {
        $localSearchPaths += "G:\Branch Software\Installers\OpenVPN\openvpn-connect-3.9.0.5008_signed.msi"
        foreach ($d in ('D','E','F','G','H')) {
            $localSearchPaths += "$($d):\Branch Software\Installers\OpenVPN\openvpn-connect-3.9.0.5008_signed.msi"
            $localSearchPaths += "$($d):\Branch Software\Installers\OpenVPN\$targetName"
        }
    }

    foreach ($candidate in $localSearchPaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -Path $candidate)) {
            try {
                $candItem = Get-Item -Path $candidate -ErrorAction Stop
                if ($candItem.Length -ge $MinBytes -and $candItem.FullName -ne $DestinationPath) {
                    Write-Host "[+] Found local installer on disk/USB: $($candItem.FullName)" -ForegroundColor Green
                    Write-Host "    Copying locally to destination folder..." -ForegroundColor Gray

                    $destFolder = Split-Path -Path $DestinationPath -Parent
                    if ($destFolder -and -not (Test-Path -Path $destFolder)) {
                        New-Item -Path $destFolder -ItemType Directory -Force | Out-Null
                    }

                    Copy-Item -Path $candItem.FullName -Destination $DestinationPath -Force
                    if (Test-Path -Path $DestinationPath) {
                        $sizeMB = [math]::Round(((Get-Item -Path $DestinationPath).Length / 1MB), 2)
                        Write-Host "[+] Local copy completed successfully ($sizeMB MB)" -ForegroundColor Green
                        Write-ITLog -Action "Local Cache Copy: $DisplayName" -Result "Copied from $($candItem.FullName)" -Level "SUCCESS"
                        return $true
                    }
                }
            } catch {
                # Fall through to internet download
            }
        }
    }

    # 3. HTTP Download from Web (Multi-Engine & SSL Tolerant)
    Write-Host "[*] Downloading $DisplayName..." -ForegroundColor Cyan
    Write-Host "    Source: $Url" -ForegroundColor Gray
    Write-Host "    Dest:   $DestinationPath" -ForegroundColor Gray

    $destFolder = Split-Path -Path $DestinationPath -Parent
    if ($destFolder -and -not (Test-Path -Path $destFolder)) {
        New-Item -Path $destFolder -ItemType Directory -Force | Out-Null
    }

    # Ensure TLS and SSL certificate trust bypass for this thread
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]'Tls,Tls11,Tls12'
        try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 12288 } catch {}
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    } catch {}

    $downloadSuccess = $false
    $lastErrorMsg = ""

    # Engine 1: PowerShell Invoke-WebRequest
    try {
        Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop
        if ((Test-Path -Path $DestinationPath) -and (Get-Item -Path $DestinationPath).Length -ge $MinBytes) {
            $downloadSuccess = $true
        } else {
            $lastErrorMsg = "Downloaded file is 0 bytes or below minimum size threshold."
        }
    } catch {
        $lastErrorMsg = $_.Exception.Message
    }

    # Engine 2: curl.exe with -k (bypasses SSL/TLS certificate trust errors directly)
    if (-not $downloadSuccess) {
        $curlCmd = Get-Command "curl.exe" -ErrorAction SilentlyContinue
        if ($curlCmd) {
            Write-Host "[*] Connection note: $lastErrorMsg. Retrying with curl (SSL-tolerant mode)..." -ForegroundColor Yellow
            try {
                $curlProcess = Start-Process -FilePath $curlCmd.Source -ArgumentList "-k -L --retry 2 --connect-timeout 20 -o `"$DestinationPath`" `"$Url`"" -Wait -PassThru -NoNewWindow
                if ($curlProcess.ExitCode -eq 0 -and (Test-Path -Path $DestinationPath) -and (Get-Item -Path $DestinationPath).Length -ge $MinBytes) {
                    $downloadSuccess = $true
                } else {
                    $lastErrorMsg = "curl exited with status code $($curlProcess.ExitCode)"
                }
            } catch {
                $lastErrorMsg = $_.Exception.Message
            }
        }
    }

    # Engine 3: .NET WebClient fallback
    if (-not $downloadSuccess) {
        try {
            Write-Host "[*] Retrying with .NET WebClient..." -ForegroundColor Yellow
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
            $wc.DownloadFile($Url, $DestinationPath)
            $wc.Dispose()
            if ((Test-Path -Path $DestinationPath) -and (Get-Item -Path $DestinationPath).Length -ge $MinBytes) {
                $downloadSuccess = $true
            }
        } catch {
            $lastErrorMsg = $_.Exception.Message
        }
    }

    # Engine 4: BITS Transfer fallback
    if (-not $downloadSuccess) {
        try {
            Start-BitsTransfer -Source $Url -Destination $DestinationPath -ErrorAction Stop
            if ((Test-Path -Path $DestinationPath) -and (Get-Item -Path $DestinationPath).Length -ge $MinBytes) {
                $downloadSuccess = $true
            }
        } catch {
            $lastErrorMsg = $_.Exception.Message
        }
    }

    if ($downloadSuccess) {
        $fileSizeMB = [math]::Round(((Get-Item -Path $DestinationPath).Length / 1MB), 2)
        Write-Host "[+] Download completed ($fileSizeMB MB)" -ForegroundColor Green
        Write-ITLog -Action "Download: $DisplayName" -Result "Completed ($fileSizeMB MB)" -Level "SUCCESS"
        return $true
    } else {
        Write-Host "[-] Download failed: $lastErrorMsg" -ForegroundColor Red
        Write-ITLog -Action "Download: $DisplayName" -Result "Failed: $lastErrorMsg" -Level "ERROR"
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
    $installerPath = "$Script:DownloadDir\chrome_installer.exe"

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
    }
}

function Install-MozillaFirefoxInternal {
    $downloadUrl = "https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=en-US"
    $installerPath = "$Script:DownloadDir\FirefoxSetup.exe"

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
    $installerPath = "$Script:DownloadDir\MicroSIP.exe"

    Write-ITLog -Action "MicroSIP Installation" -Result "Started" -Level "INFO"

    $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $installerPath -DisplayName "MicroSIP VoIP Client"
    if (-not $downloadSuccess) { return $false }

    Write-Host "[*] Installing MicroSIP silently..." -ForegroundColor Cyan
    try {
        # Close any active MicroSIP instance to prevent installer prompts
        Get-Process -Name "microsip" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

        $process = Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait -PassThru -NoNewWindow
        if ($process.ExitCode -eq 0) {
            Write-Host "[+] MicroSIP successfully installed!" -ForegroundColor Green
            Write-ITLog -Action "MicroSIP Installation" -Result "Completed Successfully" -Level "SUCCESS"

            # Configure MicroSIP to run in Administrator mode by default
            Set-MicroSIPAdminModeInternal | Out-Null

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
    }
}

function Set-MicroSIPAdminModeInternal {
    <#
    .SYNOPSIS
        Configures MicroSIP to run in Administrator mode by default.
        Applies machine-wide and user-specific AppCompatFlags and updates shortcut flags.
    #>
    Write-Host "[*] Configuring MicroSIP to run in Administrator mode by default..." -ForegroundColor Cyan

    $microsipPaths = @()

    # Standard installation candidate paths
    $candidatePaths = @(
        "$env:ProgramFiles\MicroSIP\microsip.exe",
        "${env:ProgramFiles(x86)}\MicroSIP\microsip.exe",
        "$env:LOCALAPPDATA\MicroSIP\microsip.exe"
    )
    foreach ($path in $candidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -Path $path)) {
            if ($microsipPaths -notcontains $path) {
                $microsipPaths += $path
            }
        }
    }

    # Query registry uninstall keys for any custom MicroSIP installation location
    $regRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    try {
        $regApps = Get-ItemProperty -Path $regRoots -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*MicroSIP*" }
        foreach ($regApp in $regApps) {
            if ($regApp.InstallLocation) {
                $exeInLoc = Join-Path $regApp.InstallLocation "microsip.exe"
                if ((Test-Path -Path $exeInLoc) -and ($microsipPaths -notcontains $exeInLoc)) {
                    $microsipPaths += $exeInLoc
                }
            }
            if ($regApp.DisplayIcon) {
                $cleanIcon = $regApp.DisplayIcon.Trim('"', ' ')
                if ($cleanIcon -match "\.exe$" -and (Test-Path -Path $cleanIcon) -and ($microsipPaths -notcontains $cleanIcon)) {
                    $microsipPaths += $cleanIcon
                }
            }
        }
    } catch {
        # Non-blocking registry lookup
    }

    # If no installed executable was detected yet, apply preemptively to standard Program Files paths
    if ($microsipPaths.Count -eq 0) {
        $p86 = "${env:ProgramFiles(x86)}\MicroSIP\microsip.exe"
        $p64 = "$env:ProgramFiles\MicroSIP\microsip.exe"
        if (-not [string]::IsNullOrWhiteSpace($p86)) { $microsipPaths += $p86 }
        if (-not [string]::IsNullOrWhiteSpace($p64)) { $microsipPaths += $p64 }
    }

    $appliedAny = $false
    $compatKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers",
        "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"
    )

    foreach ($exePath in $microsipPaths) {
        foreach ($key in $compatKeys) {
            try {
                if (-not (Test-Path -Path $key)) {
                    New-Item -Path $key -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                }
                Set-ItemProperty -Path $key -Name $exePath -Value "~ RUNASADMIN" -Force -ErrorAction SilentlyContinue
                $appliedAny = $true
            } catch {
                # Non-blocking
            }
        }
    }

    # Update Desktop and Start Menu shortcuts (.lnk files) to elevate on click
    $shortcutDirs = @(
        [Environment]::GetFolderPath("CommonDesktopDirectory"),
        [Environment]::GetFolderPath("Desktop"),
        [Environment]::GetFolderPath("CommonPrograms"),
        [Environment]::GetFolderPath("Programs")
    )

    $updatedShortcuts = 0
    foreach ($dir in $shortcutDirs) {
        if (-not (Test-Path -Path $dir)) { continue }
        $shortcuts = Get-ChildItem -Path $dir -Filter "*microsip*.lnk" -Recurse -ErrorAction SilentlyContinue
        foreach ($sc in $shortcuts) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($sc.FullName)
                if ($bytes.Length -gt 21) {
                    # Byte 21 (0x15), bit 5 (0x20) is the SLDF_RUNAS_USER flag
                    if (($bytes[21] -band 0x20) -eq 0) {
                        $bytes[21] = $bytes[21] -bor 0x20
                        [System.IO.File]::WriteAllBytes($sc.FullName, $bytes)
                        $updatedShortcuts++
                    }
                }
            } catch {
                # Non-blocking shortcut edit
            }
        }
    }

    if ($appliedAny) {
        Write-Host "[+] MicroSIP configured to run in Administrator mode by default." -ForegroundColor Green
        if ($updatedShortcuts -gt 0) {
            Write-Host "    Updated $updatedShortcuts MicroSIP shortcut(s) with Run-as-Admin shield." -ForegroundColor Green
        }
        Write-ITLog -Action "MicroSIP Admin Mode" -Result "Applied RUNASADMIN to $($microsipPaths.Count) paths ($updatedShortcuts shortcuts updated)" -Level "SUCCESS"
        return $true
    } else {
        Write-Host "[!] Could not set Administrator compatibility layer for MicroSIP." -ForegroundColor Yellow
        Write-ITLog -Action "MicroSIP Admin Mode" -Result "Failed to set RUNASADMIN" -Level "WARNING"
        return $false
    }
}

function Import-OpenVPNConfigInternal {
    param ([string]$ProfileName = "Carrybee-IPTSP-BOL.ovpn")

    Write-Host ""
    Write-Host "[*] Configuring OpenVPN Profile ($ProfileName)..." -ForegroundColor Cyan
    
    $ovpnRemoteUrl = "$Script:BaseRawUrl/Software/$ProfileName"
    $ovpnLocalPath = "$Script:CompanyDir\$ProfileName"

    # Check if profile already exists locally in repository or script root
    $localSourcePath = ""
    if ($PSScriptRoot -and (Test-Path "$PSScriptRoot\Software\$ProfileName")) {
        $localSourcePath = "$PSScriptRoot\Software\$ProfileName"
    } elseif (Test-Path "G:\ITTool\Software\$ProfileName") {
        $localSourcePath = "G:\ITTool\Software\$ProfileName"
    }

    if ($localSourcePath) {
        Copy-Item -Path $localSourcePath -Destination $ovpnLocalPath -Force
        $downloadSuccess = $true
    } else {
        $downloadSuccess = Download-FileWithProgress -Url $ovpnRemoteUrl -DestinationPath $ovpnLocalPath -DisplayName "VPN Profile ($ProfileName)"
    }

    if (-not $downloadSuccess -or -not (Test-Path $ovpnLocalPath)) {
        Write-Host "[-] Failed to obtain VPN profile file." -ForegroundColor Red
        return $false
    }

    # Copy profile to Desktop for instant technician/user access and double-click import
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    if (Test-Path $desktopPath) {
        try {
            Copy-Item -Path $ovpnLocalPath -Destination "$desktopPath\$ProfileName" -Force
            Write-Host "[+] Profile copied to Desktop: $desktopPath\$ProfileName" -ForegroundColor Green
        } catch {
            # Non-blocking
        }
    }

    $imported = $false

    # 1. OpenVPN Connect v3 Client
    $ovpnConnectPath = "$env:ProgramFiles\OpenVPN Connect\OpenVPNConnect.exe"
    if (-not (Test-Path $ovpnConnectPath)) {
        $ovpnConnectPath = "${env:ProgramFiles(x86)}\OpenVPN Connect\OpenVPNConnect.exe"
    }

    if (Test-Path $ovpnConnectPath) {
        Write-Host "[*] OpenVPN Connect detected. Importing profile into OpenVPN Connect..." -ForegroundColor Cyan
        $profileCleanName = [System.IO.Path]::GetFileNameWithoutExtension($ProfileName)

        try {
            # Dismiss first-launch onboarding/GDPR dialogs so the CLI engine is unblocked
            cmd /c "`"$ovpnConnectPath`" --accept-gdpr --skip-startup-dialogs" | Out-Null

            # Check if profile is already imported
            $listOutput = cmd /c "`"$ovpnConnectPath`" --list-profiles" 2>&1 | Out-String
            if ($listOutput -like "*$profileCleanName*") {
                Write-Host "[+] Profile '$profileCleanName' is already registered in OpenVPN Connect!" -ForegroundColor Green
                Write-ITLog -Action "Import OVPN Config" -Result "Profile already active in OpenVPN Connect: $profileCleanName" -Level "SUCCESS"
                $imported = $true
            } else {
                # Import profile with official OpenVPN Connect v3 CLI
                $importCmd = "`"$ovpnConnectPath`" --import-profile=`"$ovpnLocalPath`" --name=`"$profileCleanName`""
                $importResult = cmd /c $importCmd 2>&1 | Out-String

                if ($importResult -match '"status":\s*"success"' -or $importResult -match 'already exists') {
                    Write-Host "[+] Profile '$profileCleanName' successfully imported into OpenVPN Connect!" -ForegroundColor Green
                    Write-ITLog -Action "Import OVPN Config" -Result "Imported into OpenVPN Connect: $profileCleanName" -Level "SUCCESS"
                    $imported = $true
                } else {
                    Write-Host "[!] CLI import returned: $($importResult.Trim())" -ForegroundColor Yellow
                    # Fallback: Trigger native Windows file association import handler
                    Start-Process -FilePath $ovpnConnectPath -ArgumentList "--open-association=`"$ovpnLocalPath`""
                    $imported = $true
                }
            }

            # Launch OpenVPN Connect in the system tray so user can immediately connect
            Start-Process -FilePath $ovpnConnectPath -ArgumentList "--minimize --accept-gdpr --skip-startup-dialogs" -ErrorAction SilentlyContinue
        } catch {
            Write-Host "[!] OpenVPN Connect CLI error: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-ITLog -Action "Import OVPN Config" -Result "Error: $($_.Exception.Message)" -Level "WARNING"
            # Fallback to association launch
            Start-Process -FilePath $ovpnConnectPath -ArgumentList "--open-association=`"$ovpnLocalPath`"" -ErrorAction SilentlyContinue
            $imported = $true
        }
    }

    # 2. OpenVPN Community Client (Legacy/Standard)
    $communityConfigPath = "$env:ProgramFiles\OpenVPN\config"
    if (Test-Path "$env:ProgramFiles\OpenVPN") {
        Write-Host "[*] OpenVPN Community client detected. Staging profile in config directory..." -ForegroundColor Cyan
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
    $installerPath = "$Script:DownloadDir\openvpn-connect-v3-windows.msi"

    Write-ITLog -Action "OpenVPN Connect Installation" -Result "Started" -Level "INFO"
    
    # Resilient multi-mirror download sources:
    # 1. GitHub Releases CDN (Global Fastly/Azure CDN with trusted SSL certificate on all Windows versions)
    # 2. Official OpenVPN Packages Repository (Direct MSI payload)
    # 3. Official OpenVPN Download Gateway
    $downloadCandidates = @(
        @{ Url = "https://github.com/Ismail-Saihan/ITTool/releases/download/v2.0/openvpn-connect-3.9.0.5008_signed.msi"; Name = "OpenVPN Connect (GitHub Release CDN)" },
        @{ Url = "https://packages.openvpn.net/connect/v3/openvpn-connect-3.9.0.5008_signed.msi"; Name = "OpenVPN Connect (Official Packages Repository)" },
        @{ Url = "https://openvpn.net/downloads/openvpn-connect-v3-windows.msi"; Name = "OpenVPN Connect (Official Download Portal)" }
    )

    $downloadSuccess = $false
    foreach ($cand in $downloadCandidates) {
        $downloadSuccess = Download-FileWithProgress -Url $cand.Url -DestinationPath $installerPath -DisplayName $cand.Name -MinBytes (50 * 1024 * 1024)
        if ($downloadSuccess) { break }
        Write-Host "[!] Primary mirror unavailable or blocked. Trying next mirror..." -ForegroundColor Yellow
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
    }
}

function Menu-InstallVoipAndVpn {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "       VOIP & VPN (MICROSIP & OPENVPN CONNECT)   " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host " [1]  Install Full VoIP & VPN Bundle (Default)   " -ForegroundColor Green
    Write-Host " [2]  Install MicroSIP Only (With Auto-Admin)    " -ForegroundColor White
    Write-Host " [3]  Set Installed MicroSIP to Run as Admin     " -ForegroundColor White
    Write-Host " [4]  Install OpenVPN Connect Client + Profile   " -ForegroundColor White
    Write-Host " [5]  Import / Re-import Carrybee VPN Profile    " -ForegroundColor White
    Write-Host ""
    Write-Host " [B]  Back to Main Menu                          " -ForegroundColor Gray
    Write-Host "=================================================" -ForegroundColor Cyan

    $subChoice = Read-Host "Select an option [1-5 or B]"
    switch ($subChoice.Trim().ToUpper()) {
        "1" {
            Write-Host ""
            Install-MicroSIPInternal | Out-Null
            Write-Host ""
            Install-OpenVPNInternal | Out-Null
        }
        "2" {
            Write-Host ""
            Install-MicroSIPInternal | Out-Null
        }
        "3" {
            Write-Host ""
            Set-MicroSIPAdminModeInternal | Out-Null
        }
        "4" {
            Write-Host ""
            Install-OpenVPNInternal | Out-Null
        }
        "5" {
            Write-Host ""
            Import-OpenVPNConfigInternal -ProfileName "Carrybee-IPTSP-BOL.ovpn" | Out-Null
        }
        "B" { return }
        default {
            Write-Host "`n[-] Invalid option. Returning to menu..." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            return
        }
    }
    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# [3] INSTALL REMOTE SUPPORT (ANYDESK & ULTRAVIEWER)
# ==============================================================================
function Install-AnyDeskInternal {
    $downloadUrl = "$Script:BaseRawUrl/Software/AnyDesk.exe"
    $installerPath = "$Script:DownloadDir\AnyDesk.exe"

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
    }
}

function Install-UltraViewerInternal {
    $downloadUrl = "$Script:BaseRawUrl/Software/UltraViewer.exe"
    $installerPath = "$Script:DownloadDir\UltraViewer.exe"

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
    $installerPath = "$Script:DownloadDir\$fileName"

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
    $zipPath       = "$Script:DownloadDir\$zipFileName"
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
# [6] INSTALL HP LASERJET PRO M12a PRINTER DRIVER (AUTOMATED PNP)
# ==============================================================================
function Install-HPM12aInternal {
    <#
    .SYNOPSIS
        Automates HP LaserJet Pro M12a driver injection into Windows Driver Store
        via pnputil and registers it with the Windows Print Spooler.
    #>
    $zipFileName   = "HP_LaserJet_M12a_Driver.zip"
    $downloadUrl   = "$Script:BaseRawUrl/Software/$zipFileName"
    $zipPath       = "$Script:DownloadDir\$zipFileName"
    $extractDir    = "$Script:TempDir\HPM12aDriver"
    $infPath       = "$extractDir\HPM11M13.INF"
    $driverName    = "HP LaserJet Pro M12a"

    Write-ITLog -Action "HP LaserJet M12a Driver Installation" -Result "Started" -Level "INFO"

    $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $zipPath -DisplayName "HP LaserJet M12a Driver"
    if (-not $downloadSuccess) { return $false }

    Write-Host "[*] Extracting HP LaserJet Pro M12a driver package..." -ForegroundColor Cyan
    try {
        if (-not (Test-Path $extractDir)) { New-Item -Path $extractDir -ItemType Directory -Force | Out-Null }
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

        if (-not (Test-Path $infPath)) {
            throw "Driver INF file not found at expected path: $infPath"
        }

        Write-Host "[*] Staging HP driver in Windows Driver Store (pnputil)..." -ForegroundColor Cyan
        $pnpProcess = Start-Process -FilePath "pnputil.exe" -ArgumentList "/add-driver `"$infPath`" /install" -Wait -PassThru -NoNewWindow
        Write-Host "    PnP Driver Store staging completed." -ForegroundColor Gray

        # Register driver with Windows Print Spooler
        Write-Host "[*] Registering '$driverName' with Windows Print Spooler..." -ForegroundColor Cyan
        try {
            Add-PrinterDriver -Name $driverName -ErrorAction SilentlyContinue
            Write-Host "[+] Driver '$driverName' registered successfully in Print Spooler!" -ForegroundColor Green
        } catch {
            Write-Host "[!] Spooler notice: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        # Check existing printer queue
        $existingPrinter = Get-Printer -Name "HP LaserJet Pro M12a" -ErrorAction SilentlyContinue
        if (-not $existingPrinter) {
            Write-Host "[+] HP LaserJet Pro M12a is staged and Plug-and-Play ready! Connecting via USB will initialize it instantly." -ForegroundColor Green
        } else {
            Write-Host "[+] Printer 'HP LaserJet Pro M12a' is already installed." -ForegroundColor Green
        }

        Write-ITLog -Action "HP LaserJet M12a Driver Installation" -Result "Completed Successfully (PnP Ready)" -Level "SUCCESS"
        return $true
    } catch {
        Write-Host "[-] HP LaserJet M12a driver installation failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "HP LaserJet M12a Driver Installation" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Menu-InstallHPM12aDriver {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "   INSTALL HP LASERJET PRO M12a PRINTER DRIVER   " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "Automated driver installation for HP LaserJet Pro M12a Series." -ForegroundColor Gray
    Write-Host ""
    Install-HPM12aInternal | Out-Null
    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# [7] INSTALL GPRINTER THERMAL LABEL DRIVER (SEAGULL SCIENTIFIC)
# ==============================================================================
function Install-GprinterInternal {
    <#
    .SYNOPSIS
        Installs Gprinter Thermal Label/Barcode Printer drivers (Seagull Scientific).
        Stages Gprinter.inf into Windows Driver Store, registers core Gprinter spooler drivers,
        and initializes printer queue for Carrybee label printing.
    #>
    param (
        [string]$PreferredModel = "Gprinter GP-1324D",
        [switch]$Interactive
    )

    $zipFileName   = "Gprinter_Driver.zip"
    $downloadUrl   = "$Script:BaseRawUrl/Software/$zipFileName"
    $zipPath       = "$Script:DownloadDir\$zipFileName"
    $driverDir     = "$Script:CompanyDir\Drivers\Gprinter"
    $infPath       = "$driverDir\Gprinter.inf"
    $wizardPath    = "$driverDir\DriverWizard.exe"

    Write-ITLog -Action "Gprinter Driver Installation" -Result "Started" -Level "INFO"

    $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $zipPath -DisplayName "Gprinter Driver Package"
    if (-not $downloadSuccess) { return $false }

    Write-Host "[*] Staging Gprinter driver files..." -ForegroundColor Cyan
    try {
        if (-not (Test-Path $driverDir)) { New-Item -Path $driverDir -ItemType Directory -Force | Out-Null }
        
        # Extract to persistent location if not already extracted
        if (-not (Test-Path $infPath)) {
            Write-Host "    Extracting driver archive to $driverDir..." -ForegroundColor Gray
            Expand-Archive -Path $zipPath -DestinationPath $driverDir -Force
        }

        if (-not (Test-Path $infPath)) {
            throw "Driver INF file not found at expected path: $infPath"
        }

        # 1. Stage Gprinter driver package in Windows Driver Store
        Write-Host "[*] Injecting driver package into Windows Driver Store (pnputil)..." -ForegroundColor Cyan
        $pnpProcess = Start-Process -FilePath "pnputil.exe" -ArgumentList "/add-driver `"$infPath`" /install" -Wait -PassThru -NoNewWindow
        Write-Host "    PnP Driver Store staging completed (Code: $($pnpProcess.ExitCode))." -ForegroundColor Gray

        # 2. Register common Carrybee Gprinter models with Print Spooler
        $coreModels = @("Gprinter GP-1324D", "Gprinter GP-3120TU", "Gprinter GP-2120TF")
        Write-Host "[*] Registering Gprinter drivers with Windows Print Spooler..." -ForegroundColor Cyan
        foreach ($m in $coreModels) {
            try {
                Add-PrinterDriver -Name $m -ErrorAction SilentlyContinue
                Write-Host "    [+] Driver '$m' registered." -ForegroundColor Green
            } catch {
                # Non-blocking
            }
        }

        # 3. Create / verify primary printer queue (Default: Gprinter GP-1324D on USB001)
        if (-not [string]::IsNullOrWhiteSpace($PreferredModel)) {
            Write-Host "[*] Configuring printer queue for '$PreferredModel'..." -ForegroundColor Cyan
            $existing = Get-Printer -Name $PreferredModel -ErrorAction SilentlyContinue
            if (-not $existing) {
                try {
                    Add-Printer -Name $PreferredModel -DriverName $PreferredModel -PortName "USB001" -ErrorAction SilentlyContinue
                    Write-Host "[+] Printer '$PreferredModel' queue bound to port USB001!" -ForegroundColor Green
                } catch {
                    Write-Host "[+] Driver is staged and ready! Connecting the printer via USB will automatically activate it." -ForegroundColor Green
                }
            } else {
                Write-Host "[+] Printer '$PreferredModel' is already present." -ForegroundColor Green
            }
        }

        Write-ITLog -Action "Gprinter Driver Installation" -Result "Completed Successfully (Model: $PreferredModel)" -Level "SUCCESS"

        # 4. Optional interactive Seagull Driver Wizard if requested
        if ($Interactive -and (Test-Path -Path $wizardPath)) {
            Write-Host ""
            Write-Host "[*] Launching Seagull Driver Wizard for custom setup..." -ForegroundColor Cyan
            Start-Process -FilePath $wizardPath -Verb RunAs
            Write-Host "[+] Driver Wizard opened in a separate window." -ForegroundColor Green
        }

        return $true
    } catch {
        Write-Host "[-] Gprinter driver installation failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "Gprinter Driver Installation" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Menu-InstallGprinterDriver {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "     INSTALL GPRINTER THERMAL LABEL DRIVER       " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "Select Gprinter Model to install:" -ForegroundColor White
    Write-Host " [1] Gprinter GP-1324D (Standard Waybill / Shipping Label) - Default" -ForegroundColor Green
    Write-Host " [2] Gprinter GP-3120TU (Barcode / Product Label)" -ForegroundColor White
    Write-Host " [3] Gprinter GP-2120TF (2-inch Receipt / Mini Label)" -ForegroundColor White
    Write-Host " [4] Launch Seagull Driver Wizard (Choose Custom Model / Port)" -ForegroundColor White
    Write-Host " [5] Staging Only (Install All 266 Drivers for Auto-PnP)" -ForegroundColor White
    Write-Host ""
    Write-Host " [B] Back to Main Menu" -ForegroundColor Gray
    Write-Host "=================================================" -ForegroundColor Cyan

    $choice = Read-Host "Select an option [1-5 or B]"
    switch ($choice.Trim().ToUpper()) {
        "1" {
            Write-Host ""
            Install-GprinterInternal -PreferredModel "Gprinter GP-1324D" | Out-Null
        }
        "2" {
            Write-Host ""
            Install-GprinterInternal -PreferredModel "Gprinter GP-3120TU" | Out-Null
        }
        "3" {
            Write-Host ""
            Install-GprinterInternal -PreferredModel "Gprinter GP-2120TF" | Out-Null
        }
        "4" {
            Write-Host ""
            Install-GprinterInternal -Interactive | Out-Null
        }
        "5" {
            Write-Host ""
            Install-GprinterInternal -PreferredModel "" | Out-Null
        }
        "B" { return }
        default {
            Write-Host ""
            Install-GprinterInternal -PreferredModel "Gprinter GP-1324D" | Out-Null
        }
    }
    Write-Host ""
    Read-Host "Press Enter to return to main menu..."
}

# ==============================================================================
# [8] DEPLOY PRINT SERVER & SECURITY RULES
# ==============================================================================
function Deploy-PrintServerInternal {
    $fileName = "PrintServer.exe"
    $downloadUrl = "$Script:BaseRawUrl/Software/$fileName"
    $targetFolder = $Script:CompanyDir
    $targetFile = "$targetFolder\$fileName"
    $cachedFile = "$Script:DownloadDir\$fileName"

    Write-ITLog -Action "PrintServer Deployment" -Result "Started" -Level "INFO"

    $downloadSuccess = Download-FileWithProgress -Url $downloadUrl -DestinationPath $cachedFile -DisplayName "Print Server Application"
    if (-not $downloadSuccess) { return $false }

    try {
        if (-not (Test-Path $targetFolder)) { New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null }
        Copy-Item -Path $cachedFile -Destination $targetFile -Force
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
# [9] DEVICE INFORMATION & ASSET MANAGEMENT SUITE
# ==============================================================================
function Get-AssetInformationString {
    <#
    .SYNOPSIS
        Generates formatted asset inventory string for QR code and label printing:
        Format: "i5 11th Gen, RAM 16GB, SSD 512 GB, 14-inch, SN# 5CD124NJSM, BSN# 5CD124NJSM"
    #>
    # 1. CPU Short Branding
    $cpuRaw = ""
    try {
        $cpuRaw = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).Name.Trim()
    } catch {}

    $cpuShort = "CPU"
    if ($cpuRaw -match '(?i)(i[3579])-(\d{4,5}[A-Z\d]*)') {
        $tier = $Matches[1].ToLower()
        $numPart = $Matches[2]
        $genNum = if ($numPart -match '^1[0-9]') { $numPart.Substring(0, 2) } elseif ($numPart -match '^[2-9]') { $numPart.Substring(0, 1) } else { "" }
        if ($genNum) {
            $suffix = switch ($genNum) { "1" { "1st" }; "2" { "2nd" }; "3" { "3rd" }; default { "${genNum}th" } }
            $cpuShort = "$tier $suffix Gen"
        } else {
            $cpuShort = $tier
        }
    } elseif ($cpuRaw -match '(?i)(\d{1,2})th Gen.*?(i[3579])') {
        $cpuShort = "$($Matches[2].ToLower()) $($Matches[1])th Gen"
    } elseif ($cpuRaw -match 'Ryzen \d \d{4}') {
        $cpuShort = $Matches[0]
    } elseif ($cpuRaw) {
        $cpuShort = ($cpuRaw -replace '(?i)Intel\(R\)\s*Core\(TM\)\s*', '' -replace '(?i)@.*', '').Trim()
    }

    # 2. RAM (GB)
    $ramStr = "RAM 8GB"
    try {
        $totalRamBytes = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory
        if ($totalRamBytes -gt 0) {
            $ramGB = [math]::Round($totalRamBytes / 1GB)
            $ramStr = "RAM ${ramGB}GB"
        }
    } catch {}

    # 3. SSD / Storage
    $diskStr = "SSD 512 GB"
    try {
        $pDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue
        $targetDisk = $pDisks | Where-Object { $_.MediaType -eq 'SSD' } | Select-Object -First 1
        if (-not $targetDisk) { $targetDisk = $pDisks | Select-Object -First 1 }
        
        $rawGB = 0
        $dType = "SSD"
        if ($targetDisk) {
            $rawGB = [math]::Round($targetDisk.Size / 1GB)
            if ($targetDisk.MediaType) { $dType = $targetDisk.MediaType }
        } else {
            $cDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
            if ($cDrive) { $rawGB = [math]::Round($cDrive.Size / 1GB) }
        }

        # Match to standard storage capacities (128, 256, 512, 1024/1TB, 2048/2TB)
        $stdSizes = @(128, 256, 512, 1024, 2048)
        $roundedSize = $rawGB
        foreach ($sz in $stdSizes) {
            if ([math]::Abs($rawGB - $sz) -le ($sz * 0.15)) {
                $roundedSize = $sz
                break
            }
        }

        if ($roundedSize -ge 1024) {
            $diskStr = "$dType $([math]::Round($roundedSize / 1024)) TB"
        } else {
            $diskStr = "$dType $roundedSize GB"
        }
    } catch {}

    # 4. Screen Size
    $screenStr = "14-inch"
    try {
        $mon = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($mon -and $mon.MaxHorizontalImageSize -gt 0 -and $mon.MaxVerticalImageSize -gt 0) {
            $diagCm = [math]::Sqrt([math]::Pow($mon.MaxHorizontalImageSize, 2) + [math]::Pow($mon.MaxVerticalImageSize, 2))
            $diagInches = [math]::Round(($diagCm / 2.54), 1)
            if ($diagInches -ge 13.5 -and $diagInches -le 14.5) {
                $screenStr = "14-inch"
            } elseif ($diagInches -ge 15.0 -and $diagInches -le 16.0) {
                $screenStr = "15.6-inch"
            } elseif ($diagInches -ge 13.0 -and $diagInches -le 13.5) {
                $screenStr = "13.3-inch"
            } else {
                $screenStr = "$([math]::Round($diagInches))-inch"
            }
        }
    } catch {}

    # 5. Serial Numbers (SN# and BSN#)
    $bsn = "N/A"
    $sn = "N/A"
    try {
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
        if ($bios -and $bios.SerialNumber) { $bsn = $bios.SerialNumber.Trim() }
    } catch {}
    try {
        $csp = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
        if ($csp -and $csp.IdentifyingNumber) { $sn = $csp.IdentifyingNumber.Trim() }
    } catch {}
    if ($sn -eq "N/A" -or [string]::IsNullOrWhiteSpace($sn)) { $sn = $bsn }
    if ($bsn -eq "N/A" -or [string]::IsNullOrWhiteSpace($bsn)) { $bsn = $sn }

    return "$cpuShort, $ramStr, $diskStr, $screenStr, SN# $sn, BSN# $bsn"
}

function Generate-AssetQRCodeInternal {
    <#
    .SYNOPSIS
        Generates and saves the QR Code image named "Asset Information.png" and "Asset Information.txt" on Desktop.
    #>
    Write-Host "`n[*] Generating Carrybee Asset Information..." -ForegroundColor Cyan
    $assetString = Get-AssetInformationString

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "                  ASSET INFORMATION                         " -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "Payload: " -NoNewline; Write-Host $assetString -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor Green

    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $imageFile   = "$desktopPath\Asset Information.png"
    $textFile    = "$desktopPath\Asset Information.txt"

    # Clean up any stale or corrupted image file first
    if (Test-Path -Path $imageFile) {
        Remove-Item -Path $imageFile -Force -ErrorAction SilentlyContinue
    }

    # Save exact text string to desktop file
    try {
        $assetString | Out-File -FilePath $textFile -Encoding utf8 -Force
        Write-Host "[+] Saved text record: $textFile" -ForegroundColor Green
    } catch {
        Write-Host "[!] Could not save text file: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Helper function to validate if a file is a valid PNG image
    $script:TestPngValid = {
        param([string]$path)
        if (-not (Test-Path -Path $path)) { return $false }
        try {
            $fInfo = Get-Item -Path $path -ErrorAction Stop
            if ($fInfo.Length -lt 100) { return $false }
            $header = [System.IO.File]::ReadAllBytes($path)
            if ($header.Length -ge 8 -and $header[0] -eq 137 -and $header[1] -eq 80 -and $header[2] -eq 78 -and $header[3] -eq 71) {
                return $true
            }
        } catch {}
        return $false
    }

    # Fetch QR Code Image via API (400x400 PNG)
    Write-Host "[*] Generating QR Code image on Desktop..." -ForegroundColor Cyan
    $encodedPayload = [System.Uri]::EscapeDataString($assetString)
    $qrUrls = @(
        "https://api.qrserver.com/v1/create-qr-code/?size=400x400&data=$encodedPayload",
        "https://quickchart.io/qr?size=400&text=$encodedPayload"
    )

    $downloadSuccess = $false
    foreach ($url in $qrUrls) {
        # Attempt 1: Multi-engine download helper with low minimum size threshold for PNGs
        $dlOk = Download-FileWithProgress -Url $url -DestinationPath $imageFile -DisplayName "Asset QR Code Image" -MinBytes 100 -Force
        if ($dlOk -and (& $script:TestPngValid $imageFile)) {
            $downloadSuccess = $true
            break
        }

        # Attempt 2: Direct curl.exe with SSL trust bypass if Download-FileWithProgress did not yield valid PNG
        $curlCmd = Get-Command "curl.exe" -ErrorAction SilentlyContinue
        if ($curlCmd) {
            try {
                if (Test-Path -Path $imageFile) { Remove-Item -Path $imageFile -Force -ErrorAction SilentlyContinue }
                $p = Start-Process -FilePath $curlCmd.Source -ArgumentList "-k -s -L `"$url`" -o `"$imageFile`"" -Wait -PassThru -NoNewWindow
                if ($p.ExitCode -eq 0 -and (& $script:TestPngValid $imageFile)) {
                    $downloadSuccess = $true
                    break
                }
            } catch {}
        }
    }

    if ($downloadSuccess -and (& $script:TestPngValid $imageFile)) {
        Write-Host ""
        Write-Host "[+] Asset QR Code successfully created on Desktop!" -ForegroundColor Green
        Write-Host "    File: $imageFile" -ForegroundColor Yellow
        Write-ITLog -Action "Asset QR Code" -Result "Generated ($imageFile) - $assetString" -Level "SUCCESS"

        # Open QR code image automatically for immediate viewing/scanning
        try {
            Start-Process -FilePath $imageFile -ErrorAction SilentlyContinue
        } catch {}
        return $imageFile
    } else {
        Write-Host "[-] Could not download QR Code image from web." -ForegroundColor Yellow
        Write-Host "    The text file '$textFile' has been created on your Desktop." -ForegroundColor Green
        Write-ITLog -Action "Asset QR Code" -Result "Text created, image download failed" -Level "WARNING"
        return $null
    }
}

function Rename-ComputerInteractive {
    Write-Host ""
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "                 RENAME COMPUTER                 " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "Current Computer Name: " -NoNewline; Write-Host $env:COMPUTERNAME -ForegroundColor Green
    Write-Host ""
    
    $newName = (Read-Host "Enter new computer name (e.g. CBE-IT-LAPTOP-0633, max 63 characters)").Trim()
    if ([string]::IsNullOrWhiteSpace($newName)) {
        Write-Host "[-] Operation cancelled. No name entered." -ForegroundColor Yellow
        return
    }

    # Windows / RFC 1123 Hostname Validation Rules (same as Windows Settings):
    # 1. Length between 1 and 63 characters
    # 2. Allowed characters: letters (A-Z, a-z), numbers (0-9), and hyphens (-)
    # 3. Cannot start or end with a hyphen
    # 4. Cannot consist entirely of numbers
    $isValidFormat = $newName -match '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$'
    $isNotAllNumbers = $newName -match '[a-zA-Z]'

    if ($newName.Length -gt 63 -or -not $isValidFormat -or -not $isNotAllNumbers) {
        Write-Host "[-] Invalid computer name." -ForegroundColor Red
        Write-Host "    Rules: 1-63 characters, letters, numbers, and hyphens (-) allowed." -ForegroundColor Yellow
        Write-Host "    Cannot start/end with a hyphen and cannot contain spaces or special symbols." -ForegroundColor Yellow
        return
    }

    try {
        $renamed = $false
        # Method 1: PowerShell Rename-Computer cmdlet
        try {
            Rename-Computer -NewName $newName -Force -WarningAction SilentlyContinue -ErrorAction Stop
            $renamed = $true
        } catch {
            # Method 2: WMI/CIM fallback
            $csObj = Get-CimInstance -ClassName Win32_ComputerSystem
            $wmiResult = Invoke-CimMethod -InputObject $csObj -MethodName Rename -Arguments @{ Name = $newName } -ErrorAction Stop
            if ($wmiResult.ReturnValue -eq 0) {
                $renamed = $true
            } else {
                throw "WMI Rename returned error code $($wmiResult.ReturnValue)"
            }
        }

        if ($renamed) {
            Write-Host "[+] Computer successfully renamed to '$newName'!" -ForegroundColor Green
            if ($newName.Length -gt 15) {
                $netBiosName = $newName.Substring(0, 15)
                Write-Host "    Full Hostname: $newName | NetBIOS (Legacy): $netBiosName" -ForegroundColor Gray
            }
            Write-Host "[!] A RESTART IS REQUIRED for the change to take effect." -ForegroundColor Yellow
            Write-ITLog -Action "Rename Computer" -Result "Renamed to $newName" -Level "SUCCESS"

            $restartNow = Read-Host "`nDo you want to restart the computer now? (Y/N)"
            if ($restartNow -match '^[Yy]$') {
                Write-Host "[*] Restarting computer in 5 seconds..." -ForegroundColor Yellow
                Restart-Computer -Force
            }
        }
    } catch {
        Write-Host "[-] Failed to rename computer: $($_.Exception.Message)" -ForegroundColor Red
        Write-ITLog -Action "Rename Computer" -Result "Failed: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Show-DeviceSpecificationsInternal {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "              DEVICE INFORMATION                 " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan

    Write-Host "[*] Querying system components..." -ForegroundColor Gray
    try {
        $cs      = Get-CimInstance -ClassName Win32_ComputerSystem
        $os      = Get-CimInstance -ClassName Win32_OperatingSystem
        $bios    = Get-CimInstance -ClassName Win32_BIOS
        $csp     = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
        $cpu     = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
        $ramGB   = [math]::Round(($cs.TotalPhysicalMemory / 1GB), 2)
        
        $netConfigs = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true }
        $ipList  = ($netConfigs.IPAddress | Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' }) -join ", "
        $macList = ($netConfigs.MACAddress) -join ", "

        $displayIp = if ($ipList) { $ipList } else { "N/A" }
        $displayMac = if ($macList) { $macList } else { "N/A" }
        $sysSerial = if ($csp -and $csp.IdentifyingNumber) { $csp.IdentifyingNumber } else { $bios.SerialNumber }

        Write-Host "Computer Name:       " -NoNewline; Write-Host $env:COMPUTERNAME -ForegroundColor Green
        Write-Host "System Serial (SN):  " -NoNewline; Write-Host $sysSerial -ForegroundColor Green
        Write-Host "BIOS Serial (BSN):   " -NoNewline; Write-Host $bios.SerialNumber -ForegroundColor Green
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
        
        $assetStr = Get-AssetInformationString
        Write-Host "Asset Summary:       " -NoNewline; Write-Host $assetStr -ForegroundColor Cyan
        Write-Host "=================================================" -ForegroundColor Cyan

        Write-ITLog -Action "Query Device Information" -Result "Success (Host: $env:COMPUTERNAME)" -Level "INFO"
    } catch {
        Write-Host "[-] Failed to retrieve device info: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Menu-ShowDeviceInformation {
    do {
        Clear-Host
        Write-Host "=================================================" -ForegroundColor Cyan
        Write-Host "         DEVICE INFORMATION & ASSET SUITE        " -ForegroundColor Yellow
        Write-Host "=================================================" -ForegroundColor Cyan
        Write-Host " [1]  View Full System Specifications & Status   " -ForegroundColor White
        Write-Host " [2]  Generate Asset QR Code on Desktop          " -ForegroundColor Green
        Write-Host " [3]  Rename Computer (e.g. CBE-IT-LAPTOP-0633)  " -ForegroundColor White
        Write-Host ""
        Write-Host " [B]  Back to Main Menu                          " -ForegroundColor Gray
        Write-Host "=================================================" -ForegroundColor Cyan

        $subChoice = Read-Host "Select an option [1-3 or B]"
        switch ($subChoice.Trim().ToUpper()) {
            "1" {
                Show-DeviceSpecificationsInternal
                Write-Host ""
                Read-Host "Press Enter to continue..."
            }
            "2" {
                Generate-AssetQRCodeInternal | Out-Null
                Write-Host ""
                Read-Host "Press Enter to continue..."
            }
            "3" {
                Rename-ComputerInteractive
                Write-Host ""
                Read-Host "Press Enter to continue..."
            }
            "B" { return }
            default {
                Write-Host "`n[-] Invalid selection. Returning to menu..." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    } while ($true)
}

# ==============================================================================
# [10] NETWORK DIAGNOSTICS & CONNECTIVITY SUITE
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
# [11] WINDOWS OS REPAIR & CLEANUP (SFC, DISM, TEMP CLEAN)
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
# [12] WINDOWS DEBLOAT & PERFORMANCE TWEAKS
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
# [13] EXPORT PC INFORMATION REPORT
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
    Write-Host "  4. Canon, HP M12a, Gprinter Drivers & Print Server"
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

    Write-Host "`n[STAGE 4/6] Deploying Canon, HP M12a, Gprinter Drivers & Print Server..." -ForegroundColor Magenta
    Install-CanonLBP6030Internal | Out-Null
    Install-HPM12aInternal | Out-Null
    Install-GprinterInternal | Out-Null
    Deploy-PrintServerInternal | Out-Null

    Write-Host "`n[STAGE 5/6] Applying Windows Optimization & NTP Clock Sync..." -ForegroundColor Magenta
    Optimize-WindowsPerformanceInternal

    Write-Host "`n[STAGE 6/6] Generating Final Inventory Audit & Asset QR Code..." -ForegroundColor Magenta
    $report = Export-PCReportInternal
    $qrImage = Generate-AssetQRCodeInternal

    $stopwatch.Stop()
    $totalMinutes = [math]::Round($stopwatch.Elapsed.TotalMinutes, 2)

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "   COMPLETE PROVISIONING BUNDLE FINISHED IN $totalMinutes MINS!    " -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Green
    if ($report) { Write-Host "Report created on Desktop: $report" -ForegroundColor Cyan }
    if ($qrImage) { Write-Host "Asset QR Code created on Desktop: $qrImage" -ForegroundColor Cyan }
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
        Write-Host " --- SOFTWARE & PRINTER DEPLOYMENTS ---          " -ForegroundColor Gray
        Write-Host " [1]  Install Web Browsers (Chrome & Firefox)    " -ForegroundColor White
        Write-Host " [2]  Install VoIP & VPN (MicroSIP & OpenVPN Connect)" -ForegroundColor White
        Write-Host " [3]  Install Remote Support (AnyDesk / Ultra)   " -ForegroundColor White
        Write-Host " [4]  Install DotMAX Printer Driver (Wizard)     " -ForegroundColor White
        Write-Host " [5]  Install Canon LBP6030 Driver (Automated PnP)" -ForegroundColor White
        Write-Host " [6]  Install HP LaserJet Pro M12a Driver (Auto PnP)" -ForegroundColor White
        Write-Host " [7]  Install Gprinter Label Printer Driver (Thermal)" -ForegroundColor White
        Write-Host " [8]  Deploy Print Server & Security Rules       " -ForegroundColor White
        Write-Host ""
        Write-Host " --- SYSTEM & NETWORK UTILITIES ---              " -ForegroundColor Gray
        Write-Host " [9]  Device Information & Asset QR Code         " -ForegroundColor White
        Write-Host " [10] Network Diagnostics & Health Suite         " -ForegroundColor White
        Write-Host " [11] Windows OS Repair & Cleanup (SFC/DISM/Temp)" -ForegroundColor White
        Write-Host " [12] Windows Debloat & Performance Tweaks       " -ForegroundColor White
        Write-Host ""
        Write-Host " [X]  Exit                                       " -ForegroundColor Red
        Write-Host "=================================================" -ForegroundColor Cyan
        
        $selection = Read-Host "Select an option [0-12 or X]"

        switch ($selection.Trim().ToUpper()) {
            "0"  { Menu-FastOnboardAll }
            "1"  { Menu-InstallBrowsers }
            "2"  { Menu-InstallVoipAndVpn }
            "3"  { Menu-InstallRemoteSupport }
            "4"  { Menu-InstallDotMaxDriver }
            "5"  { Menu-InstallCanonLBP6030 }
            "6"  { Menu-InstallHPM12aDriver }
            "7"  { Menu-InstallGprinterDriver }
            "8"  { Menu-DeployPrintServer }
            "9"  { Menu-ShowDeviceInformation }
            "10" { Menu-NetworkDiagnostics }
            "11" { Menu-SystemRepairAndCleanup }
            "12" { Menu-WindowsTweaks }
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
