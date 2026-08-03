#requires -Version 7.6

Describe 'What Switch deployment profiles' {
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../WhatSwitch.psd1') -Force
    . (Join-Path $PSScriptRoot '../WhatSwitch.IntuneWin.ps1')
    . (Join-Path $PSScriptRoot '../WhatSwitch.Deployment.ps1')

    function New-TestAnalysis {
        param([string]$Path, [ValidateSet('msi', 'inno')][string]$Engine = 'inno')
        $file = Get-Item -LiteralPath $Path
        [pscustomobject]@{
            Path = $file.FullName
            FileName = $file.Name
            Engine = $Engine
            ProductName = 'Synthetic App'
            ProductVersion = '1.2.3'
            CompanyName = 'Synthetic Publisher'
            Commands = @(
                [pscustomobject]@{ Label = 'Install (silent)'; Command = "$($file.Name) /S" }
                [pscustomobject]@{ Label = 'Uninstall (silent)'; Command = '"%ProgramFiles%\Synthetic\uninstall.exe" /S' }
            )
            Catalog = $null
            Msi = if ($Engine -eq 'msi') {
                [pscustomobject]@{ ProductCode = '{11111111-2222-3333-4444-555555555555}'; ProductVersion = '1.2.3' }
            } else { $null }
        }
    }
}

    BeforeEach {
        $source = Join-Path $TestDrive 'setup.exe'
        [IO.File]::WriteAllBytes($source, [byte[]](0x4d, 0x5a, 0, 0))
    }

    It 'prioriterar MSI ProductCode framför andra regler' {
        $analysis = New-TestAnalysis -Path $source -Engine msi
        $profile = New-WhatSwitchDeploymentProfile -AnalysisResult $analysis
        $profile.detection.selected.type | Should Be 'Msi'
        $profile.detection.selected.priority | Should Be 400
        $profile.detection.selected.productCode | Should Be '{11111111-2222-3333-4444-555555555555}'
    }

    It 'kräver en bekräftad detektionsregel' {
        $profile = New-WhatSwitchDeploymentProfile -AnalysisResult (New-TestAnalysis -Path $source)
        (Test-WhatSwitchDeploymentProfile -Profile $profile).IsValid | Should Be $false
        $profile.detection.selected = New-WhatSwitchDetectionCandidate -Type File -Id manual -DisplayName 'Manual' -Priority 1 -Source Test -Properties @{ path = 'C:\Program Files'; fileOrFolder = 'Synthetic' }
        $profile.detection.confirmed = $true
        (Test-WhatSwitchDeploymentProfile -Profile $profile).IsValid | Should Be $true
    }

    It 'genererar PSADT v4-anrop för EXE' {
        $analysis = New-TestAnalysis -Path $source
        $profile = New-WhatSwitchDeploymentProfile -AnalysisResult $analysis
        $templatePath = 'C:\Program Files\WindowsPowerShell\Modules\PSAppDeployToolkit\4.1.8\Frontend\v4\Invoke-AppDeployToolkit.ps1'
        $template = Get-Content -LiteralPath $templatePath -Raw
        $script = New-WhatSwitchPsadtScriptContent -Profile $profile -AnalysisResult $analysis
        $script | Should Match 'Open-ADTSession'
        $script | Should Match 'Start-ADTProcess'
        $script | Should Match 'Close-ADTSession'
        $script | Should Match 'Show-ADTInstallationWelcome'
        $script | Should Match 'function Repair-ADTDeployment'
        $script | Should Match 'Remove-ADTHashtableNullOrEmptyValues'
        $script | Should Match '## <Perform Installation tasks here>'
        @($script -split "`r?`n").Count | Should Be (@($template -split "`r?`n").Count + 6)
    }

    It 'ignorerar en felaktig tom kandidat från äldre Sandbox-rapporter' {
        $analysis = New-TestAnalysis -Path $source
        $report = [pscustomobject]@{ candidates = @(
            [pscustomobject]@{ value = @(); Count = 0 }
            [pscustomobject]@{ id = 'valid'; type = 'Registry'; displayName = 'Valid'; source = 'Windows Sandbox'; priority = 200; verified = $true; keyPath = 'HKEY_LOCAL_MACHINE\SOFTWARE\Synthetic' }
        ) }
        $candidates = @(Get-WhatSwitchDetectionCandidates -AnalysisResult $analysis -SandboxReport $report)
        $candidates.Count | Should Be 1
        $candidates[0].type | Should Be 'Registry'
    }

    It 'låter config.psd1 styra MSI-parametrar om inget uttryckligen ändras' {
        $analysis = New-TestAnalysis -Path $source -Engine msi
        $profile = New-WhatSwitchDeploymentProfile -AnalysisResult $analysis
        $profile.commands.install = 'msiexec /i "setup.exe" /qn /norestart'
        $profile.commands.uninstall = 'msiexec /x {11111111-2222-3333-4444-555555555555} /qn /norestart'
        $standard = New-WhatSwitchPsadtScriptContent -Profile $profile -AnalysisResult $analysis
        $standardInstall = $standard -split "`r?`n" | Where-Object { $_ -match 'Start-ADTMsiProcess -Action Install' }
        $standardUninstall = $standard -split "`r?`n" | Where-Object { $_ -match 'Start-ADTMsiProcess -Action Uninstall' }
        $standardInstall | Should Not Match 'ArgumentList'
        $standardUninstall | Should Not Match 'ArgumentList'

        $profile.commands.install = 'msiexec /i "setup.exe" /qn /norestart ALLUSERS=1 COMPANY="Contoso AB"'
        $additional = New-WhatSwitchPsadtScriptContent -Profile $profile -AnalysisResult $analysis
        $additionalLine = $additional -split "`r?`n" | Where-Object { $_ -match 'Start-ADTMsiProcess -Action Install' }
        $additionalLine.Contains("-AdditionalArgumentList @('ALLUSERS=1', 'COMPANY=`"Contoso AB`"')") | Should Be $true

        $profile.commands.install = 'msiexec /i "setup.exe" /qb /norestart ALLUSERS=1'
        $override = New-WhatSwitchPsadtScriptContent -Profile $profile -AnalysisResult $analysis
        $overrideLine = $override -split "`r?`n" | Where-Object { $_ -match 'Start-ADTMsiProcess -Action Install' }
        $overrideLine.Contains("-ArgumentList '/qb /norestart ALLUSERS=1'") | Should Be $true
    }

    It 'använder registerregelns verkliga avinstallationssträng i PSADT' {
        $analysis = New-TestAnalysis -Path $source
        $profile = New-WhatSwitchDeploymentProfile -AnalysisResult $analysis
        $profile.detection.selected = [pscustomobject]@{
            type = 'Registry'
            uninstallString = '"C:\Program Files\Synthetic\unins000.exe"'
            quietUninstallString = ''
        }
        $resolved = Resolve-WhatSwitchUninstallCommand -DetectionRule $profile.detection.selected -FallbackCommand $profile.commands.uninstall
        $resolved | Should Be '"C:\Program Files\Synthetic\unins000.exe" /S'
        $script = New-WhatSwitchPsadtScriptContent -Profile $profile -AnalysisResult $analysis
        $uninstallLine = $script -split "`r?`n" | Where-Object { $_ -match "Start-ADTProcess -FilePath 'C:\\Program Files\\Synthetic\\unins000.exe'" }
        $uninstallLine.Contains("-ArgumentList '/S'") | Should Be $true

        $profile.detection.selected.quietUninstallString = '"C:\Program Files\Synthetic\unins000.exe" /VERYSILENT'
        (Resolve-WhatSwitchUninstallCommand -DetectionRule $profile.detection.selected -FallbackCommand $profile.commands.uninstall) |
            Should Be '"C:\Program Files\Synthetic\unins000.exe" /VERYSILENT'
    }

    It 'exporterar Intune-inställningar, guide och kontrollsummor' {
        $analysis = New-TestAnalysis -Path $source
        $profile = New-WhatSwitchDeploymentProfile -AnalysisResult $analysis
        $profile.detection.selected = New-WhatSwitchDetectionCandidate -Type File -Id manual -DisplayName 'Manual' -Priority 1 -Source Test -Properties @{ path = 'C:\Program Files'; fileOrFolder = 'Synthetic' }
        $profile.detection.confirmed = $true
        $output = Join-Path $TestDrive 'output'
        [void](New-Item -ItemType Directory -Path $output)
        $result = Export-WhatSwitchDeploymentPackage -Profile $profile -AnalysisResult $analysis -OutputDirectory $output
        $result.IntuneWinPath | Should Exist
        (Join-Path $result.Path 'Intune\Intune-Settings.json') | Should Exist
        (Join-Path $result.Path 'Intune\README-SV.md') | Should Exist
        $result.ChecksumPath | Should Exist
    }
}
