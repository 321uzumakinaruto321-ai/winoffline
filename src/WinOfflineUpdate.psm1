Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-WouRepository {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    foreach ($name in 'Catalog','Metadata','Packages','Reports','ClientPayload','Logs') {
        New-Item -ItemType Directory -Force -Path (Join-Path $Path $name) | Out-Null
    }
    $config = [ordered]@{
        RepositoryRoot = (Resolve-Path $Path).Path
        CatalogUrl = 'https://go.microsoft.com/fwlink/?LinkID=74689'
        DeadlineHours = 24
        PromptIntervalMinutes = 60
        RebootPolicy = 'Prompt'
        Products = @('Windows 10','Windows 11','Windows Server 2019','Windows Server 2022','Windows Server 2025')
        ComputerListPath = 'computers.txt'
    }
    $config | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -Path (Join-Path $Path 'winoffline.config.json')
    $computerList = Join-Path $Path $config.ComputerListPath
    if (-not (Test-Path $computerList)) {
        @('# Add one target computer per line', '# PC001', '# PC002', '# SRV001') | Set-Content -Encoding UTF8 -Path $computerList
    }
    }
    $config | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -Path (Join-Path $Path 'winoffline.config.json')
    return $config
}

function Get-WouConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $path = Join-Path $RepositoryRoot 'winoffline.config.json'
    if (-not (Test-Path $path)) { throw "Repository config not found: $path" }
    Get-Content -Raw -Path $path | ConvertFrom-Json
}


function Get-WouComputerList {
    [CmdletBinding(DefaultParameterSetName = 'FromConfig')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'FromConfig')][string]$RepositoryRoot,
        [Parameter(Mandatory, ParameterSetName = 'FromFile')][string]$Path,
        [Parameter(ParameterSetName = 'FromConfig')][string[]]$ComputerName,
        [Parameter(ParameterSetName = 'FromFile')][string[]]$AdditionalComputerName
    )
    $names = @()
    if ($PSCmdlet.ParameterSetName -eq 'FromConfig') {
        if ($ComputerName) { $names += $ComputerName }
        $cfg = Get-WouConfig -RepositoryRoot $RepositoryRoot
        $configuredPath = $cfg.ComputerListPath
        if (-not [IO.Path]::IsPathRooted($configuredPath)) { $configuredPath = Join-Path $RepositoryRoot $configuredPath }
        if (Test-Path $configuredPath) { $names += Get-Content -Path $configuredPath }
    } else {
        if (Test-Path $Path) { $names += Get-Content -Path $Path } else { throw "Computer list not found: $Path" }
        if ($AdditionalComputerName) { $names += $AdditionalComputerName }
    }

    $normalized = $names |
        ForEach-Object { if ($_ -ne $null) { $_.ToString().Trim() } } |
        Where-Object { $_ -and -not $_.StartsWith('#') } |
        Sort-Object -Unique

    if (-not $normalized) { throw 'No computers were supplied. Add names to computers.txt or pass -ComputerName.' }
    return @($normalized)
}

function Update-WouCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot,[string]$CatalogUrl)
    $cfg = Get-WouConfig -RepositoryRoot $RepositoryRoot
    if (-not $CatalogUrl) { $CatalogUrl = $cfg.CatalogUrl }
    $target = Join-Path $RepositoryRoot 'Catalog\wsusscn2.cab'
    Invoke-WebRequest -Uri $CatalogUrl -OutFile $target -UseBasicParsing
    Get-Item $target | Select-Object FullName,Length,LastWriteTimeUtc
}

function Invoke-WouClientScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CabPath,
        [string]$OutputPath = (Join-Path $env:TEMP ("WouScan-$env:COMPUTERNAME.json")),
        [string]$Criteria = "IsInstalled=0 and Type='Software'"
    )
    if (-not (Test-Path $CabPath)) { throw "Catalog not found: $CabPath" }
    $session = New-Object -ComObject Microsoft.Update.Session
    $serviceManager = New-Object -ComObject Microsoft.Update.ServiceManager
    $service = $serviceManager.AddScanPackageService('WinOfflineScan', $CabPath, 1)
    try {
        $searcher = $session.CreateUpdateSearcher()
        $searcher.ServerSelection = 3
        $searcher.ServiceID = $service.ServiceID
        $result = $searcher.Search($Criteria)
        $updates = foreach ($u in $result.Updates) {
            $urls = @()
            foreach ($bundled in $u.BundledUpdates) {
                foreach ($content in $bundled.DownloadContents) { if ($content.DownloadUrl) { $urls += $content.DownloadUrl } }
            }
            foreach ($content in $u.DownloadContents) { if ($content.DownloadUrl) { $urls += $content.DownloadUrl } }
            [pscustomobject]@{
                ComputerName = $env:COMPUTERNAME
                Title = $u.Title
                KB = @($u.KBArticleIDs)
                UpdateId = $u.Identity.UpdateID
                RevisionNumber = $u.Identity.RevisionNumber
                MsrcSeverity = $u.MsrcSeverity
                Categories = @($u.Categories | ForEach-Object Name)
                DownloadUrls = @($urls | Sort-Object -Unique)
                RequiresReboot = $u.RebootRequired
            }
        }
        $payload = [ordered]@{
            ComputerName = $env:COMPUTERNAME
            ScanTimeUtc = (Get-Date).ToUniversalTime().ToString('o')
            OS = (Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture)
            MissingUpdates = @($updates)
        }
        $payload | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $OutputPath
        return $payload
    }
    finally {
        try { $serviceManager.RemoveService($service.ServiceID) | Out-Null } catch { }
    }
}

function Invoke-WouFleetScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot,[string[]]$ComputerName,[string]$ComputerListPath,[pscredential]$Credential)
    $cab = Join-Path $RepositoryRoot 'Catalog\wsusscn2.cab'
    if (-not (Test-Path $cab)) { throw 'Run Update-WouCatalog on an online transfer host first.' }
    $scanScript = Join-Path $PSScriptRoot 'WinOfflineUpdate.psm1'
    $targetComputers = if ($ComputerListPath) { Get-WouComputerList -Path $ComputerListPath -AdditionalComputerName $ComputerName } else { Get-WouComputerList -RepositoryRoot $RepositoryRoot -ComputerName $ComputerName }
    $results = foreach ($computer in $targetComputers) {
    param([Parameter(Mandatory)][string]$RepositoryRoot,[Parameter(Mandatory)][string[]]$ComputerName,[pscredential]$Credential)
    $cab = Join-Path $RepositoryRoot 'Catalog\wsusscn2.cab'
    if (-not (Test-Path $cab)) { throw 'Run Update-WouCatalog on an online transfer host first.' }
    $scanScript = Join-Path $PSScriptRoot 'WinOfflineUpdate.psm1'
    $results = foreach ($computer in $ComputerName) {
        $sessionParams = @{ ComputerName = $computer }
        if ($Credential) { $sessionParams.Credential = $Credential }
        $s = New-PSSession @sessionParams
        try {
            Invoke-Command -Session $s -ScriptBlock { New-Item -ItemType Directory -Force -Path 'C:\ProgramData\WinOfflineUpdate' | Out-Null }
            Copy-Item -ToSession $s -Path $cab -Destination 'C:\ProgramData\WinOfflineUpdate\wsusscn2.cab' -Force
            Copy-Item -ToSession $s -Path $scanScript -Destination 'C:\ProgramData\WinOfflineUpdate\WinOfflineUpdate.psm1' -Force
            $remote = Invoke-Command -Session $s -ScriptBlock {
                Import-Module 'C:\ProgramData\WinOfflineUpdate\WinOfflineUpdate.psm1' -Force
                Invoke-WouClientScan -CabPath 'C:\ProgramData\WinOfflineUpdate\wsusscn2.cab' -OutputPath 'C:\ProgramData\WinOfflineUpdate\scan.json'
            }
            $out = Join-Path $RepositoryRoot ("Metadata\$computer.scan.json")
            $remote | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $out
            $remote
        } finally { Remove-PSSession $s }
    }
    return $results
}

function Save-WouMissingPackages {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $packageRoot = Join-Path $RepositoryRoot 'Packages'
    $scanFiles = Get-ChildItem -Path (Join-Path $RepositoryRoot 'Metadata') -Filter '*.scan.json'
    $urls = foreach ($file in $scanFiles) {
        $scan = Get-Content -Raw -Path $file.FullName | ConvertFrom-Json
        foreach ($u in $scan.MissingUpdates) { foreach ($url in $u.DownloadUrls) { $url } }
    }
    foreach ($url in ($urls | Sort-Object -Unique)) {
        $name = [IO.Path]::GetFileName(([Uri]$url).AbsolutePath)
        if (-not $name) { $name = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($url))) + '.bin' }
        $target = Join-Path $packageRoot $name
        if (-not (Test-Path $target)) { Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing }
        [pscustomobject]@{ Url = $url; File = $target; AlreadyPresent = (Test-Path $target) }
    }
}


function Invoke-WouFleetInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string[]]$ComputerName,
        [string]$ComputerListPath,
        [Parameter(Mandatory)][string[]]$ComputerName,
        [pscredential]$Credential,
        [int]$DeadlineHours,
        [int]$PromptIntervalMinutes
    )
    $cfg = Get-WouConfig -RepositoryRoot $RepositoryRoot
    if (-not $PSBoundParameters.ContainsKey('DeadlineHours')) { $DeadlineHours = [int]$cfg.DeadlineHours }
    if (-not $PSBoundParameters.ContainsKey('PromptIntervalMinutes')) { $PromptIntervalMinutes = [int]$cfg.PromptIntervalMinutes }
    $packageRoot = Join-Path $RepositoryRoot 'Packages'
    $promptScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Invoke-WouClientPrompt.ps1'
    $targetComputers = if ($ComputerListPath) { Get-WouComputerList -Path $ComputerListPath -AdditionalComputerName $ComputerName } else { Get-WouComputerList -RepositoryRoot $RepositoryRoot -ComputerName $ComputerName }
    foreach ($computer in $targetComputers) {
    foreach ($computer in $ComputerName) {
        $sessionParams = @{ ComputerName = $computer }
        if ($Credential) { $sessionParams.Credential = $Credential }
        $s = New-PSSession @sessionParams
        try {
            Invoke-Command -Session $s -ScriptBlock { New-Item -ItemType Directory -Force -Path 'C:\ProgramData\WinOfflineUpdate\Packages','C:\ProgramData\WinOfflineUpdate\scripts','C:\ProgramData\WinOfflineUpdate\src' | Out-Null }
            Copy-Item -ToSession $s -Path (Join-Path $PSScriptRoot 'WinOfflineUpdate.psm1') -Destination 'C:\ProgramData\WinOfflineUpdate\src\WinOfflineUpdate.psm1' -Force
            Copy-Item -ToSession $s -Path $promptScript -Destination 'C:\ProgramData\WinOfflineUpdate\scripts\Invoke-WouClientPrompt.ps1' -Force
            Copy-Item -ToSession $s -Path (Join-Path $packageRoot '*') -Destination 'C:\ProgramData\WinOfflineUpdate\Packages' -Force
            Invoke-Command -Session $s -ScriptBlock {
                param($hours,$interval)
                Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','C:\ProgramData\WinOfflineUpdate\scripts\Invoke-WouClientPrompt.ps1','-PackageDirectory','C:\ProgramData\WinOfflineUpdate\Packages','-Deadline',(Get-Date).AddHours($hours).ToString('o'),'-PromptIntervalMinutes',$interval) -WindowStyle Normal
            } -ArgumentList $DeadlineHours,$PromptIntervalMinutes
            [pscustomobject]@{ ComputerName=$computer; DeploymentStarted=$true; DeadlineUtc=(Get-Date).AddHours($DeadlineHours).ToUniversalTime().ToString('o') }
        } finally { Remove-PSSession $s }
    }
}

function New-WouReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $rows = foreach ($file in Get-ChildItem -Path (Join-Path $RepositoryRoot 'Metadata') -Filter '*.scan.json') {
        $scan = Get-Content -Raw -Path $file.FullName | ConvertFrom-Json
        foreach ($u in $scan.MissingUpdates) {
            [pscustomobject]@{
                ComputerName = $scan.ComputerName
                OS = $scan.OS.Caption
                ScanTimeUtc = $scan.ScanTimeUtc
                KB = ($u.KB -join ',')
                Title = $u.Title
                UpdateId = $u.UpdateId
                Severity = $u.MsrcSeverity
                DownloadCount = @($u.DownloadUrls).Count
            }
        }
    }
    $csv = Join-Path $RepositoryRoot ('Reports\missing-updates-{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date))
    $rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csv
    return Get-Item $csv
}

function Install-WouPackageFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($ext) {
        '.msu' { Start-Process wusa.exe -ArgumentList @("`"$Path`"",'/quiet','/norestart') -Wait -PassThru }
        '.cab' { Start-Process dism.exe -ArgumentList @('/Online','/Add-Package',"/PackagePath:$Path",'/Quiet','/NoRestart') -Wait -PassThru }
        '.msi' { Start-Process msiexec.exe -ArgumentList @('/i',"`"$Path`"",'/qn','/norestart') -Wait -PassThru }
        '.exe' { Start-Process $Path -ArgumentList @('/quiet','/norestart') -Wait -PassThru }
        default { throw "Unsupported package type: $Path" }
    }
}

Export-ModuleMember -Function *-Wou*,Install-WouPackageFile
