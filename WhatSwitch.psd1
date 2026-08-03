@{
    RootModule = 'WhatSwitch.psm1'
    ModuleVersion = '1.5.0'
    GUID = '05b71bea-b20d-4e4c-9a9e-4dc265f821f0'
    Author = 'What Switch? contributors'
    CompanyName = 'Community'
    Copyright = '(c) What Switch? contributors. MIT licensed.'
    Description = 'Static Windows installer engine detection and silent-command discovery for PowerShell 7.6.'
    PowerShellVersion = '7.6'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
        'Get-WhatSwitchResult'
        'Find-WhatSwitchSwitch'
        'ConvertTo-WhatSwitchPowerShellCommand'
        'Get-WhatSwitchCatalog'
        'New-WhatSwitchDetectionCandidate'
        'Get-WhatSwitchDetectionCandidates'
        'New-WhatSwitchDeploymentProfile'
        'Test-WhatSwitchDeploymentProfile'
        'Export-WhatSwitchDeploymentPackage'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    FileList = @(
        'WhatSwitch.psd1'
        'WhatSwitch.psm1'
        'Invoke-WhatSwitch.ps1'
        'Start-WhatSwitchGui.ps1'
        'Start-WhatSwitchGui.cmd'
        'WhatSwitch.Gui.xaml'
        'WhatSwitch.Sandbox.ps1'
        'WhatSwitch.IntuneWin.ps1'
        'WhatSwitch.Deployment.ps1'
        'WhatSwitch.DeploymentGui.ps1'
        'WhatSwitch.Deployment.xaml'
        'catalog/catalog.json'
    )
    PrivateData = @{
        PSData = @{
            Tags = @('PowerShell', 'Installer', 'MSI', 'MSIX', 'SilentInstall')
            LicenseUri = 'https://github.com/deadarcher/SwitchHunt/blob/main/LICENSE'
            ProjectUri = 'https://github.com/deadarcher/SwitchHunt'
        }
    }
}
