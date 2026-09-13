# Company IT Deployment & Provisioning Utility (ITTool)

A modular, menu-driven PowerShell automation tool for IT administrators and technicians to rapidly provision, configure, and audit Windows 10 and Windows 11 endpoints.

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
    ├── OpenVPN.exe
    ├── MicroSIP.exe
    ├── Driver software for Windows-72.exe
    └── PrintServer.exe
```

---

## ⚡ Quick Start (Technician Execution)

Technicians can launch the utility directly from a PowerShell console:

```powershell
irm https://short-url.com/ITTool | iex
```

### What happens automatically:
1. **Privilege Elevation Check:** If the technician runs the command from a standard (non-elevated) prompt, the script automatically triggers a UAC prompt and relaunches itself inside an Administrator PowerShell session.
2. **Environment Initialization:** Forces modern TLS protocols (`TLS 1.2` / `TLS 1.3`), ensures `C:\CompanyTools` and `C:\CompanyTools\Logs` exist, and sets up a clean temp directory.
3. **Menu Loop:** Launches the interactive administration console.

---

## 🛠️ Menu Options & Capabilities

| # | Option | Description | Mode |
|---|--------|-------------|------|
| **1** | **Device Information** | Inspects hardware, BIOS serial, CPU, RAM, OS build, IP, MAC. Prompts to rename PC with reboot notice. | Interactive |
| **2** | **Install OpenVPN Client** | Downloads `OpenVPN.exe` from GitHub repo, installs silently (`/S`), and cleans up temp files. | Silent |
| **3** | **Install MicroSIP** | Downloads `MicroSIP.exe` from GitHub repo, installs silently (`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`). | Silent |
| **4** | **Install Google Chrome** | Downloads official Google Chrome Enterprise 64-bit installer and runs silent install (`/silent /install`). | Silent |
| **5** | **Install Mozilla Firefox** | Downloads official Mozilla Firefox 64-bit installer and runs silent install (`-ms`). | Silent |
| **6** | **Install DotMAX Printer Driver** | Downloads `Driver software for Windows-72.exe` (with URL encoding), launches wizard for technician to configure. | Interactive |
| **7** | **Download Print Server** | Deploys `PrintServer.exe` to `C:\CompanyTools\`, creates Desktop shortcut, adds Windows Defender exclusions, and checks Win 11 Smart App Control. | Automated |
| **8** | **Export PC Report** | Exports complete hardware, network, and installed applications inventory to `Desktop\<PC-Name>-Report.txt`. | Automated |
| **9** | **Exit** | Cleans temp directories, logs termination, and closes session cleanly. | Clean exit |

---

## 📝 Logging System

Every operation is recorded in real time to:
```text
C:\CompanyTools\Logs\ITTool.log
```

Log entry format:
```text
[2026-09-13 12:30:15] [USER: CORP\ismail] [DEVICE: WORKSTATION-01] [TYPE: INFO] Action: Chrome Installation | Result: Started
[2026-09-13 12:35:42] [USER: CORP\ismail] [DEVICE: WORKSTATION-01] [TYPE: SUCCESS] Action: Chrome Installation | Result: Completed Successfully (ExitCode: 0)
```
