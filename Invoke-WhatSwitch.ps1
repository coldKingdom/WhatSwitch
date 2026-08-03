#requires -Version 7.6

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
    [Alias('FullName')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$Path,

    [ValidateSet('Cmd', 'PowerShell')]
    [string]$Shell = 'PowerShell',

    [switch]$BestEffort,
    [switch]$AsJson,
    [switch]$PassThru
)

begin {
    Import-Module (Join-Path $PSScriptRoot 'WhatSwitch.psd1') -Force -ErrorAction Stop
}

process {
    $result = Get-WhatSwitchResult -Path $Path -IncludeBestEffort:$BestEffort
    if ($AsJson) {
        $result | ConvertTo-Json -Depth 20
        return
    }
    if ($PassThru) {
        $result
        return
    }

    Write-Host "`n$($result.Label)" -ForegroundColor Cyan
    Write-Host "File:       $($result.FileName)"
    Write-Host "Confidence: $($result.Confidence)"
    if ($result.ProductName) { Write-Host "Product:    $($result.ProductName) $($result.ProductVersion)" }
    if ($result.CompanyName) { Write-Host "Company:    $($result.CompanyName)" }
    if ($result.Catalog) {
        Write-Host "`nCatalog match: $($result.Catalog.Name)" -ForegroundColor Green
        Write-Host "  Install:   $($result.Catalog.InstallCommand)"
        if ($result.Catalog.UninstallCommand) { Write-Host "  Uninstall: $($result.Catalog.UninstallCommand)" }
        if ($result.Catalog.Note) { Write-Host "  Note:      $($result.Catalog.Note)" }
    }
    if ($result.Commands.Count) {
        Write-Host "`nCommands:" -ForegroundColor Yellow
        foreach ($item in $result.Commands) {
            $value = if ($Shell -eq 'PowerShell') { $item.PowerShellCommand } else { $item.Command }
            Write-Host "  $($item.Label):"
            Write-Host "    $value"
        }
    }
    if ($result.Warning) { Write-Warning $result.Warning }
    if ($result.Notes) { Write-Host "`n$($result.Notes)" }
    if ($result.BestEffort) {
        Write-Host "`nBest-effort candidates (verify before use):" -ForegroundColor DarkYellow
        Write-Host "  Flags:   $($result.BestEffort.Flags -join ', ')"
        Write-Host "  Options: $($result.BestEffort.Options -join ', ')"
    }
}
