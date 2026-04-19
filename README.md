<p align="center">
  <sub>This code is a modern rewrite of an old Windows <a href="https://raw.githubusercontent.com/NicoKnowsTech/NicoKnowsTech/refs/heads/main/NKT_TOOL.bat">repair tool</a> that fixes incorrect command order and improves the user experience.</sub>
</p>

> [!IMPORTANT]
> **Never run scripts you do not trust!** While this script only utilizes built-in Windows commands, running unknown scripts can leak your data or expose your computer to malware. If you are unsure of the source or the code, do not execute it. 

> This tool will attempt to fix common Windows issues; this is a simple method, not the best method. 
> Try looking for more specific problems [here](https://learn.microsoft.com/en-us/answers/). If possible, run the commands yourself or ask someone for help. **Do not run code you do not trust.**

## Instructions
1. Download the `repair.bat` file from the repository.
   * *You can click <a href="https://downgit.github.io/#/home?url=https://github.com/gvqz/winrepair/raw/main/repair.bat" download="repair.bat">here</a> to download the file directly.*
2. Double-click the file. It will open a prompt asking for Administrative privileges.
3. Select a task from the interactive menu by **typing** the corresponding number (**1-6**) and pressing **Enter**:
   * 1: Removes temporary files and prefetch cache.
   * 2: Runs SFC and DISM health restores.
   * 3: Clears the Windows Update cache and resets services.
   * 4: Flushes DNS and resets the IP stack/Winsock.
   * 5: Checks the S.M.A.R.T. status of your physical disks.
   * 6: Executes all of the above tasks in sequence.
4. A `Repair_Log.txt` is automatically generated on the Desktop to document all actions and timestamps.
5. If running a full repair, restart the computer to apply system changes.

---

## Manual Commands (No Download)
If you prefer not to run the script, you can perform these actions manually. Open **Command Prompt (Admin)** or **PowerShell (Admin)** and run these commands:

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
rd /s /q %systemroot%\SoftwareDistribution
net start wuauserv
net start bits
net start cryptsvc
```

### 4. Hardware Disk Health (PowerShell)
```powershell
Get-PhysicalDisk | Select-Object FriendlyName, HealthStatus, OperationalStatus
```

### 5. Quick Clean (Temporary Files)
```cmd
del /q /f /s %TEMP%\*
del /q /f /s C:\Windows\Temp\*
del /q /f /s C:\Windows\Prefetch\*
```
