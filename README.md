# Company IT Deployment & Provisioning Utility (ITTool v2.0)

A modular, menu-driven PowerShell automation tool for IT administrators and field technicians to rapidly provision, configure, optimize, and audit Windows 10 and Windows 11 endpoints.

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
    └── PrintServer.exe
```

---

## ⚡ Quick Start (Technician Execution)

Technicians can launch the utility directly from a PowerShell console:

```powershell
irm https://tinyurl.com/2ynbvdxs | iex
```

*(Or direct Raw GitHub URL:)*
```powershell
irm https://raw.githubusercontent.com/Ismail-Saihan/ITTool/main/ITTool.ps1 | iex
```

---

## 🛠️ Menu Options & Capabilities (v2.0)

```text
=================================================
            COMPANY IT TOOL (v2.0)               
=================================================
 [0]  ⚡ RUN COMPLETE PROVISIONING BUNDLE        

 --- SOFTWARE DEPLOYMENTS ---                    
 [1]  Install Web Browsers (Chrome & Firefox)    
 [2]  Install VoIP & VPN (MicroSIP & OpenVPN)    
 [3]  Install Remote Support (AnyDesk / Ultra)   
 [4]  Install DotMAX Printer Driver (Wizard)     
 [5]  Deploy Print Server & Security Rules       

 --- SYSTEM & NETWORK UTILITIES ---              
 [6]  Device Information & Rename PC             
 [7]  Network Diagnostics & Health Suite         
 [8]  Windows OS Repair & Cleanup (SFC/DISM/Temp)
 [9]  Windows Debloat & Performance Tweaks       
 [10] Export PC Inventory Report                 

 [X]  Exit                                       
=================================================
```

### Feature Highlights:
- **`[0] ⚡ RUN COMPLETE PROVISIONING BUNDLE`:** Single-click sequential execution of all software installers, Defender exclusions, performance tweaks, and automated report generation in under 4 minutes.
- **`[2] VoIP & VPN Auto-Import`:** Installs MicroSIP and OpenVPN, and automatically imports `Carrybee-IPTSP-BOL.ovpn` into OpenVPN Connect v3 or OpenVPN Community.
- **`[3] Helpdesk Remote Access`:** Installs AnyDesk and UltraViewer silently for immediate central IT support.
- **`[7] Network Diagnostics Suite`:** Gateway ping, DNS tests, public IP check, and one-click DNS flush / Winsock stack repair.
- **`[8] Windows OS Repair & Maintenance`:** SFC scannow, DISM component restore, temp cache cleanup, and SSD S.M.A.R.T. health checks.
- **`[9] Debloat & Performance Tuning`:** High-performance power plan, NTP clock resynchronization, and consumer app debloating.
- **`[10] PC Inventory Audit`:** Exports full hardware specs, network config, and installed software to `Desktop\<PC-Name>-Report.txt`.

---

## 📝 Logging System

Every operation is recorded in real time to:
```text
C:\CompanyTools\Logs\ITTool.log
```
