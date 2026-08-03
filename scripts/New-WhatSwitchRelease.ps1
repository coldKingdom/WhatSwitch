#requires -Version 7.6

[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version = '1.5.0',
    [string]$OutputRoot = (Join-Path $PSScriptRoot '..\deployment')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$outputRootPath = [IO.Path]::GetFullPath($OutputRoot)
$target = Join-Path $outputRootPath "WhatSwitch-$Version"
$zipPath = Join-Path $outputRootPath "WhatSwitch-$Version.zip"
if (Test-Path -LiteralPath $target) { throw "Release-mappen finns redan: $target" }
if (Test-Path -LiteralPath $zipPath) { throw "Release-arkivet finns redan: $zipPath" }

$manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $projectRoot 'WhatSwitch.psd1')
if ([string]$manifest.ModuleVersion -ne $Version) {
    throw "Manifestversionen är $($manifest.ModuleVersion), inte $Version."
}

[void](New-Item -ItemType Directory -Path $target -Force)
[void](New-Item -ItemType Directory -Path (Join-Path $target 'catalog'))
$releaseFiles = @(
    'Invoke-WhatSwitch.ps1',
    'Start-WhatSwitchGui.cmd',
    'Start-WhatSwitchGui.ps1',
    'WhatSwitch.Gui.xaml',
    'WhatSwitch.IntuneWin.ps1',
    'WhatSwitch.Sandbox.ps1',
    'WhatSwitch.Deployment.ps1',
    'WhatSwitch.DeploymentGui.ps1',
    'WhatSwitch.Deployment.xaml',
    'WhatSwitch.psd1',
    'WhatSwitch.psm1',
    'LICENSE'
)
foreach ($relativePath in $releaseFiles) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $relativePath) -Destination (Join-Path $target $relativePath)
}
Copy-Item -LiteralPath (Join-Path $projectRoot 'catalog\catalog.json') -Destination (Join-Path $target 'catalog\catalog.json')

$readMe = @"
WHAT SWITCH? $Version
====================

1. Packa upp hela ZIP-filen till en lokal mapp.
2. Dubbelklicka Start-WhatSwitchGui.cmd.
3. Dra in en EXE, MSI, MSP, MSIX eller AppX.
4. Öppna Deploymentguide för Intune-, Sandbox- och PSADT-export.

Krav:
- Windows 10/11
- PowerShell 7.6 eller senare
- Windows Sandbox för isolerad verifiering (valfritt)
- PSAppDeployToolkit 4.1.8 för PSADT-export

Deploymentguiden kan skapa direkta Intune-paket, PSADT script-only och kompletta
PSADT-paket. Kompletta exporter innehåller .intunewin, portalinställningar, svensk
guide, analys-/Sandbox-resultat och SHA-256-kontrollsummor.

Programmet analyserar installerfiler lokalt. Inga filer laddas upp.
"@
[IO.File]::WriteAllText((Join-Path $target 'LÄS-MIG.txt'), $readMe, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $target 'VERSION'), "$Version`n", [Text.UTF8Encoding]::new($false))

$checksumPath = Join-Path $target 'SHA256SUMS.txt'
$checksumLines = foreach ($file in Get-ChildItem -LiteralPath $target -File -Recurse | Where-Object FullName -NE $checksumPath | Sort-Object FullName) {
    $relative = [IO.Path]::GetRelativePath($target, $file.FullName).Replace('\', '/')
    "$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $relative"
}
[IO.File]::WriteAllLines($checksumPath, @($checksumLines), [Text.UTF8Encoding]::new($false))
Compress-Archive -LiteralPath $target -DestinationPath $zipPath -CompressionLevel Optimal

[pscustomobject]@{
    Version = $Version
    Directory = $target
    Archive = $zipPath
    ArchiveSha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    FileCount = @(Get-ChildItem -LiteralPath $target -File -Recurse).Count
}
