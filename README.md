# WinOfflineUpdate

WinOfflineUpdate is a PowerShell-based starter implementation for centrally managing Windows updates in a closed network without WSUS. It uses WinRM for remote access, the Microsoft offline scan catalog (`wsusscn2.cab`) for missing-update detection, and a repository layout that deduplicates update payload downloads.

## Supported targets

Designed for Windows 10 1909+, Windows 11, Windows Server 2019, Windows Server 2022, and Windows Server 2025 where PowerShell remoting/WinRM is enabled and the operator has local administrator rights on clients.

## Workflow

1. On an internet-connected transfer host, create a repository and download the latest offline scan catalog automatically:
   ```powershell
   Import-Module .\src\WinOfflineUpdate.psm1
   New-WouRepository -Path D:\WouRepo
   Update-WouCatalog -RepositoryRoot D:\WouRepo
   Set-Content -Path D:\WouRepo\computers.txt -Value @('PC001','PC002','SRV001')
   ```
2. Move the repository to the closed-network central server.
3. Scan clients from the central server:
   ```powershell
   Invoke-WouFleetScan -RepositoryRoot D:\WouRepo
   New-WouReport -RepositoryRoot D:\WouRepo
   ```
4. Move only the repository metadata back to the online transfer host and download unique missing update packages once:
   ```powershell
   Save-WouMissingPackages -RepositoryRoot D:\WouRepo
   ```
5. Move the repository back to the closed-network server and deploy packages with WinRM. The included prompt script gives users defer/deadline choices without using Task Scheduler:
   ```powershell
   Invoke-WouFleetInstall -RepositoryRoot D:\WouRepo -DeadlineHours 24 -PromptIntervalMinutes 60
   ```

## Computer list format

By default, fleet commands read target computers from `computers.txt` in the repository root, which `New-WouRepository` creates as a template. Add one computer name per line; blank lines and lines beginning with `#` are ignored. You can override the file with `-ComputerListPath` or append ad-hoc names with `-ComputerName`. See `computers.example.txt` for the same format.

## What is included

- `src/WinOfflineUpdate.psm1`: repository creation, catalog download, offline client scan, fleet scan over WinRM, unique package download, WinRM deployment, CSV missing-update report, and package install helpers.
- `scripts/Invoke-WouClientPrompt.ps1`: interactive client prompt loop with a deadline and installation result JSON output.

## Notes and limitations

- `wsusscn2.cab` supports offline security update detection. It is not a full WSUS replacement and may not cover every driver, feature update, or Microsoft product update.
- Update installation order, supersedence cleanup, reboot orchestration, and a web/desktop UI are intentionally left as next implementation steps.
- The PSWindowsUpdate module can be added later for online Windows Update Agent operations, but this project does not require manual database download steps.
