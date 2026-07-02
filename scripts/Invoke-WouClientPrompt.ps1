param(
    [Parameter(Mandatory)][string]$PackageDirectory,
    [datetime]$Deadline = (Get-Date).AddHours(24),
    [int]$PromptIntervalMinutes = 60
)
Add-Type -AssemblyName System.Windows.Forms
while ((Get-Date) -lt $Deadline) {
    $remaining = [math]::Ceiling(($Deadline - (Get-Date)).TotalHours)
    $answer = [System.Windows.Forms.MessageBox]::Show("Windows güncellemeleri kurulacak. Son tarih: $Deadline ($remaining saat kaldı). Şimdi kurulsun mu?", 'WinOfflineUpdate', 'YesNo', 'Information')
    if ($answer -eq 'Yes') { break }
    Start-Sleep -Seconds ($PromptIntervalMinutes * 60)
}
Import-Module (Join-Path $PSScriptRoot '..\src\WinOfflineUpdate.psm1') -Force
$log = Join-Path $PackageDirectory 'install-results.json'
$results = foreach ($pkg in Get-ChildItem -Path $PackageDirectory -File | Where-Object Extension -in '.msu','.cab','.msi','.exe') {
    try {
        $p = Install-WouPackageFile -Path $pkg.FullName
        [pscustomobject]@{ File=$pkg.Name; ExitCode=$p.ExitCode; Success=($p.ExitCode -in 0,3010); TimeUtc=(Get-Date).ToUniversalTime().ToString('o') }
    } catch { [pscustomobject]@{ File=$pkg.Name; ExitCode=$null; Success=$false; Error=$_.Exception.Message; TimeUtc=(Get-Date).ToUniversalTime().ToString('o') } }
}
$results | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -Path $log
