<p align="center">
  <sub>This code is a modern rewrite of an old Windows <a href="https://raw.githubusercontent.com/NicoKnowsTech/NicoKnowsTech/refs/heads/main/NKT_TOOL.bat">repair tool</a> that fixes incorrect command order and improves the user experience.</sub>
</p>

> [!IMPORTANT]
> **Never run scripts you do not trust!** While this script only utilizes built-in Windows commands, running unknown scripts can leak your data or expose your computer to malware. If you are unsure of the source or the code, do not execute it. 

> This tool will attempt to fix common Windows issues; this is a simple method, not the best method. 
> Try looking for more specific problems [here](https://learn.microsoft.com/en-us/answers/). If possible, run the commands yourself or ask someone for help. **Do not run code you do not trust.**

## Instructions
1. Download the `repair.bat` file from the repository.
   * *You can click <a href="https://github.com/gvqz/winrepair/releases/download/v3/repair.bat" download="repair.bat">here</a> to download the file directly.*
2. Double-click the file. It will open a prompt asking for Administrative privileges.
3. Select a task from the interactive menu by **typing** the corresponding number/letter and pressing **Enter**:
   * **0**: Reviews System Health (Disk space, pending reboots, uptime, pending updates, S.M.A.R.T. status).
   * **1**: Removes temporary files and resets the Microsoft Store cache.
   * **2**: Runs DISM RestoreHealth, SFC scan, and optional Component Store cleanup.
   * **3**: Clears the Windows Update cache and resets update services.
   * **4**: Flushes DNS and resets the IP stack/Winsock.
   * **5**: Exports System Error events from the last 24 hours to a readable text file.
   * **6**: Opens standard Windows Disk Cleanup.
   * **7**: Runs a read-only disk error scan (`chkdsk /scan`).
   * **8**: Executes all of the above tasks in a full repair sequence.
   * **D**: Removes old driver packages for non-present devices.
   * **R**: Creates a System Restore Point.
   * **G**: Opens the online command guide.
   * **Q**: Quits the script.
4. A `WinRepair_Logs` folder is automatically generated on the Desktop. It contains:
   * `ActionLog.txt`: Timestamped log of all actions taken by the script.
   * `Last_Run_Summary.txt`: Overview of the last run and any tasks that failed.
   * `RecentErrors.txt`: Exported Windows System errors (if option 5 or 8 was run).
   * `Battery_Report.html` & `Driver_Store_Cleanup.txt`: Additional health and cleanup reports.
5. If running a full repair or resetting the network/update stack, restart the computer to apply system changes.

---

## Manual Commands (No Download)
If you prefer not to run the script, you can perform these actions manually. Open **Command Prompt (Admin)** and run these commands:

### 1. System File & Image Repair
```cmd
dism /online /cleanup-image /restorehealth
sfc /scannow
```

### 2. Network Reset
```cmd
ipconfig /flushdns
netsh winsock reset
netsh int ip reset
```

### 3. Windows Update Reset
```cmd
net stop wuauserv
net stop bits
net stop cryptsvc
:: Rename folders so Windows rebuilds them safely (alternative to deleting)
ren %systemroot%\SoftwareDistribution SoftwareDistribution.old
ren %systemroot%\System32\catroot2 catroot2.old
net start wuauserv
net start bits
net start cryptsvc
```

### 4. Hardware Disk Health (uses PowerShell)
```cmd
powershell "Get-PhysicalDisk | Select-Object FriendlyName, HealthStatus, OperationalStatus"
```

### 5. Quick Clean (Temporary Files)
```cmd
del /q /f /s %TEMP%\*
del /q /f /s C:\Windows\Temp\*
:: Reset Microsoft Store cache (Run in Run dialog or regular CMD)
wsreset.exe
```
