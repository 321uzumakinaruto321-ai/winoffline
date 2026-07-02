# WinOfflineUpdate

WinOfflineUpdate is a PowerShell starter project for centrally scanning, downloading, deduplicating, reporting, and deploying Windows updates in a closed network without WSUS. It is designed around a portable repository that is moved between an internet-connected transfer host and the closed-network central server.

## Supported targets

- Windows 10 1909 and later
- Windows 11
- Windows Server 2019
- Windows Server 2022
- Windows Server 2025

Client requirements:

- WinRM/PowerShell Remoting enabled from the central server to clients.
- Operator account has local administrator rights on clients.
- Windows Update Agent COM components are available on clients.
- Update package installation tools are present on clients (`wusa.exe`, `dism.exe`, `msiexec.exe`, or the package's silent `.exe` installer).

## Repository layout

`New-WouRepository` creates this portable structure:

| Path | Purpose |
| --- | --- |
| `Catalog/wsusscn2.cab` | Microsoft offline scan catalog downloaded on the online transfer host. |
| `Metadata/*.scan.json` | Per-computer missing-update scan output collected from the closed network. |
| `Packages/` | Downloaded update payloads. A payload URL is downloaded only once even if many computers need it. |
| `Reports/` | CSV reports generated from scan metadata. |
| `ClientPayload/` | Reserved for future client-side payload packaging. |
| `Logs/` | Reserved for operational logs. |
| `computers.txt` | Default target computer list. One computer per line; blank lines and lines starting with `#` are ignored. |
| `winoffline.config.json` | Repository configuration, including catalog URL, prompt deadline defaults, and computer-list path. |

## Computer list

Fleet commands read target computers from the repository's `computers.txt` by default. Create or edit it like this:

```powershell
Set-Content -Path D:\WouRepo\computers.txt -Value @(
    'PC001'
    'PC002'
    'SRV001'
)
```

You can also pass a custom list file with `-ComputerListPath`, or add temporary extra targets with `-ComputerName`:

```powershell
Invoke-WouFleetScan -RepositoryRoot D:\WouRepo -ComputerListPath D:\Targets\pilot.txt
Invoke-WouFleetInstall -RepositoryRoot D:\WouRepo -ComputerName TEST-PC01
```

See `computers.example.txt` for the expected format.

## End-to-end workflow

### 1. Prepare the repository on an online transfer host

```powershell
Import-Module .\src\WinOfflineUpdate.psm1
New-WouRepository -Path D:\WouRepo
Update-WouCatalog -RepositoryRoot D:\WouRepo
Set-Content -Path D:\WouRepo\computers.txt -Value @('PC001','PC002','SRV001')
```

`Update-WouCatalog` downloads the latest Microsoft offline scan catalog automatically; there is no manual database download step.

### 2. Move the repository to the closed-network central server

Copy the full `D:\WouRepo` folder to the central server in the closed network.

### 3. Scan clients from the central server

```powershell
Import-Module .\src\WinOfflineUpdate.psm1
Invoke-WouFleetScan -RepositoryRoot D:\WouRepo
New-WouReport -RepositoryRoot D:\WouRepo
```

The scan uses WinRM to copy the catalog and module to each listed computer, runs an offline Windows Update Agent scan, and stores each result under `Metadata/<computer>.scan.json`.

### 4. Download missing packages once on the online transfer host

Move the repository metadata back to the online transfer host, then run:

```powershell
Import-Module .\src\WinOfflineUpdate.psm1
Save-WouMissingPackages -RepositoryRoot D:\WouRepo
```

`Save-WouMissingPackages` reads all scan metadata, extracts unique update download URLs, and saves each payload once under `Packages/`.

### 5. Deploy and install in the closed network

Move the repository back to the central server, then run:

```powershell
Import-Module .\src\WinOfflineUpdate.psm1
Invoke-WouFleetInstall -RepositoryRoot D:\WouRepo -DeadlineHours 24 -PromptIntervalMinutes 60
```

The deployment command copies the module, prompt script, and downloaded packages to each target over WinRM and starts the client prompt process.

## User defer/deadline behavior

`scripts/Invoke-WouClientPrompt.ps1` displays an interactive prompt on the client. The user can defer until the configured deadline. When the deadline is reached, installation proceeds without using Task Scheduler. Installation results are written to `install-results.json` in the client package directory.

## Reporting

`New-WouReport` creates a CSV under `Reports/` with these fields:

- Computer name
- OS caption
- Scan time
- KB IDs
- Update title
- Update ID
- MSRC severity
- Download URL count

The client prompt also records per-package install status, exit code, success flag, timestamp, and errors when a package fails.

## Module commands

| Command | Description |
| --- | --- |
| `New-WouRepository` | Creates the portable repository, default config, and `computers.txt` template. |
| `Get-WouConfig` | Reads `winoffline.config.json`. |
| `Get-WouComputerList` | Reads and normalizes computer names from `computers.txt`, a custom file, and optional extra names. |
| `Update-WouCatalog` | Downloads `wsusscn2.cab` from Microsoft. |
| `Invoke-WouClientScan` | Runs a local offline scan with the catalog. |
| `Invoke-WouFleetScan` | Scans all listed computers over WinRM. |
| `Save-WouMissingPackages` | Downloads unique missing update package URLs once. |
| `Invoke-WouFleetInstall` | Copies packages to listed computers and starts the defer/deadline prompt. |
| `New-WouReport` | Exports a missing-update CSV report. |
| `Install-WouPackageFile` | Installs `.msu`, `.cab`, `.msi`, or silent `.exe` packages. |

## Troubleshooting

If `Import-Module .\src\WinOfflineUpdate.psm1` reports parser errors such as an unexpected `}` or duplicate `$ComputerName`, verify that your local branch has the latest committed file and that a failed PR conflict resolution did not leave a partially merged module. The committed module has balanced function braces and only one `$ComputerName` parameter in each fleet command; the static tests under `tests/` check for these cases.

## Notes and limitations

- `wsusscn2.cab` supports offline security update detection. It is not a full WSUS replacement and may not cover every driver, feature update, or Microsoft product update.
- Update ordering, supersedence cleanup, reboot orchestration, package-to-host targeting, and web/desktop UI features are future improvements.
- The current deployment helper copies the downloaded package set to each target. A future version should map only the packages required by each computer.
- The PSWindowsUpdate module can be integrated later for additional Windows Update Agent operations, but this project does not require users to manually download a database.
