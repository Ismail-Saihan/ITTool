# Carrybee IT Deployment & Provisioning Utility (ITTool v2.0)

A modular, menu-driven PowerShell automation tool for Carrybee IT administrators and field technicians to rapidly provision, configure, optimize, and audit Windows 10 and Windows 11 endpoints.

---

## 📁 Repository Structure

```text
ITTool/
├── .gitattributes
├── .gitignore
├── README.md
├── ITTool.ps1
└── Software/
    ├── README.md
    ├── AnyDesk.exe
    ├── UltraViewer.exe
    ├── OpenVPN.msi
    ├── Carrybee-IPTSP-BOL.ovpn
    ├── MicroSIP.exe
    ├── Driver software for Windows-72.exe
    ├── Canon_LBP6030_Driver.zip
    ├── HP_LaserJet_M12a_Driver.zip
    ├── Gprinter_Driver.zip
    └── PrintServer.exe
```

---

## ⚡ Quick Start (Technician Execution)

Technicians can launch the utility directly from an elevated or standard PowerShell console:

```powershell
irm https://tinyurl.com/2ynbvdxs | iex
```

*(Or direct Raw GitHub URL:)*
```powershell
irm https://raw.githubusercontent.com/Ismail-Saihan/ITTool/main/ITTool.ps1 | iex
```

> **Note:** The script will automatically verify Administrator privileges and self-elevate via UAC if required.

---

## 🛠️ Menu Options & Capabilities (v2.0)

```text
=================================================
          CARRYBEE IT UTILITY TOOL (v2.0)        
=================================================
 [0]  ⚡ RUN COMPLETE PROVISIONING BUNDLE        

 --- SOFTWARE & PRINTER DEPLOYMENTS ---          
 [1]  Install Web Browsers (Chrome & Firefox)    
 [2]  Install VoIP & VPN (MicroSIP & OpenVPN Connect)
 [3]  Install Remote Support (AnyDesk / Ultra)   
 [4]  Install DotMAX Printer Driver (Wizard)     
 [5]  Install Canon LBP6030 Driver (Automated PnP)
 [6]  Install HP LaserJet Pro M12a Driver (Auto PnP)
 [7]  Install Gprinter Label Printer Driver (Thermal)
 [8]  Deploy Print Server & Security Rules       

 --- SYSTEM & NETWORK UTILITIES ---              
 [9]  Device Information & Asset QR Code         
 [10] Network Diagnostics & Health Suite         
 [11] Windows OS Repair & Cleanup (SFC/DISM/Temp)
 [12] Windows Debloat & Performance Tweaks       

 [X]  Exit                                       
=================================================
```

### Feature Highlights:
- **`[0] ⚡ RUN COMPLETE PROVISIONING BUNDLE`:** Single-click sequential execution of all software installers, printer drivers, Defender exclusions, performance tweaks, and Asset QR code generation in minutes.
- **Smart Download Caching (`Test-FileAlreadyDownloaded`):** Automatically checks `C:\CompanyTools\Downloads` before downloading. If a valid binary is already present, it skips downloading to save bandwidth. Also scans local USB drives/offline media before falling back to GitHub.
- **`[1] Web Browsers`:** Silent unattended installation of Google Chrome Enterprise and Mozilla Firefox x64.
- **`[2] VoIP & VPN Auto-Import`:** Installs MicroSIP configured to run in Administrator mode by default (via machine-wide & user-level AppCompatFlags and shortcut elevation), deploys official OpenVPN Connect v3 Client (or standard OpenVPN), and auto-imports `Carrybee-IPTSP-BOL.ovpn`.
- **`[3] Helpdesk Remote Access`:** Installs AnyDesk and UltraViewer silently for immediate central IT support.
- **`[4] DotMAX Printer Driver`:** Interactive driver setup with automatic window monitoring, graceful timeout, and zombie process cleanup.
- **`[5] Canon LBP6030/6018 Driver`:** Fully automated Plug-and-Play driver injection into the Windows Driver Store (`pnputil`), spooler registration, and USB port pre-binding.
- **`[6] HP LaserJet Pro M12a Driver`:** Automated Plug-and-Play driver injection into the Windows Driver Store (`pnputil`) using clean INF package (3.3 MB vs 112 MB bloatware installer).
- **`[7] Gprinter Thermal Label Driver`:** Seagull Scientific driver package for TSC/TSPL label & barcode printing with automated PnP staging, spooler registration for GP-1324D / GP-3120TU / GP-2120TF, and Driver Wizard assistance.
- **`[8] Print Server Deployment`:** Deploys `PrintServer.exe` to `C:\CompanyTools`, creates Desktop shortcut, configures Windows Defender exclusions, and detects Windows 11 Smart App Control.
- **`[9] Device Information & Asset QR Code Suite`:** Submenu featuring:
  - **View Specs:** Full hardware, OS, network, serial numbers (SN# and BSN#), and asset summary.
  - **Asset QR Code Generator:** Generates `Desktop\Asset Information.png` and `.txt` with exact asset payload (e.g. `i5 11th Gen, RAM 16GB, SSD 512 GB, 14-inch, SN# 5CD124NJSM, BSN# 5CD124NJSM`) for quick barcode/QR scanner audit tagging.
  - **Rename Computer:** Full RFC 1123 hostname support up to 63 characters with hyphens (e.g. `CBE-IT-LAPTOP-0633`) and dual-method WMI fallback.
- **`[10] Network Diagnostics Suite`:** Gateway ping, DNS resolution checks, public IP query, and one-click DNS flush / Winsock stack reset.
- **`[11] Windows OS Repair & Maintenance`:** SFC `/scannow`, DISM component repair, temporary cache cleanup, and SSD S.M.A.R.T. health checks.
- **`[12] Debloat & Performance Tuning`:** High-performance power plan, NTP clock resynchronization, and consumer Appx bloatware removal.

---

## 📝 Logging & Directory Architecture

- **Main Tool Directory:** `C:\CompanyTools`
- **Installer Cache:** `C:\CompanyTools\Downloads`
- **Execution Logs:** `C:\CompanyTools\Logs\ITTool.log`

Every operation is timestamped and recorded in real time for audit compliance.
