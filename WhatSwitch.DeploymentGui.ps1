#requires -Version 7.6

Set-StrictMode -Version Latest

function Show-WhatSwitchDeploymentWizard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Windows.Window]$Owner,
        [Parameter(Mandatory)]$AnalysisResult,
        [Parameter(Mandatory)][hashtable]$GuiState,
        [Parameter(Mandatory)][scriptblock]$StartSandboxAction
    )

    $xamlPath = Join-Path $PSScriptRoot 'WhatSwitch.Deployment.xaml'
    $reader = [Xml.XmlReader]::Create([IO.StringReader]::new((Get-Content -LiteralPath $xamlPath -Raw -Encoding utf8)))
    try { $wizard = [Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Dispose() }
    $wizard.Owner = $Owner

    $controlNames = @(
        'StepList', 'WizardTabs', 'AppNameBox', 'VersionBox', 'PublisherBox', 'SourceFileBox',
        'InstallCommandBox', 'UninstallCommandBox', 'InstallBehaviorCombo', 'SandboxStatusText',
        'RunSandboxButton', 'RefreshDetectionButton', 'DetectionCombo', 'DetectionJsonBox', 'ApplyDetectionJsonButton',
        'ConfirmDetectionCheck', 'ArchitectureX86Check', 'ArchitectureX64Check', 'ArchitectureArm64Check',
        'MinimumOsCombo', 'DirectModeRadio', 'PsadtScriptModeRadio', 'PsadtCompleteModeRadio',
        'IncludeSourceFolderCheck', 'PsadtStatusText', 'SummaryText', 'ValidationCard', 'ValidationText',
        'WizardStatusText', 'CancelWizardButton', 'BackWizardButton', 'NextWizardButton', 'ExportWizardButton'
    )
    $controls = @{}
    foreach ($name in $controlNames) {
        $controls[$name] = $wizard.FindName($name)
        if ($null -eq $controls[$name]) { throw "Deploymentguidens XAML-kontroll '$name' saknas." }
    }

    $profile = New-WhatSwitchDeploymentProfile -AnalysisResult $AnalysisResult
    $wizardState = @{ LastSuggestedUninstallCommand = [string]$profile.commands.uninstall }
    $controls.AppNameBox.Text = [string]$profile.metadata.name
    $controls.VersionBox.Text = [string]$profile.metadata.version
    $controls.PublisherBox.Text = [string]$profile.metadata.publisher
    $controls.SourceFileBox.Text = [string]$profile.metadata.sourceFile
    $controls.InstallCommandBox.Text = [string]$profile.commands.install
    $controls.UninstallCommandBox.Text = [string]$profile.commands.uninstall
    $controls.ArchitectureX86Check.IsChecked = 'x86' -in @($profile.requirements.architecture)
    $controls.ArchitectureX64Check.IsChecked = 'x64' -in @($profile.requirements.architecture)
    $controls.ArchitectureArm64Check.IsChecked = 'arm64' -in @($profile.requirements.architecture)
    $controls.PsadtStatusText.Text = if (Test-Path -LiteralPath $script:WhatSwitchPsadtModulePath -PathType Leaf) {
        "PSAppDeployToolkit $script:WhatSwitchPsadtVersion hittades lokalt och kan paketeras."
    } else {
        "PSAppDeployToolkit $script:WhatSwitchPsadtVersion saknas. Komplett PSADT-export kan inte skapas."
    }

    function Get-ComboContent {
        param($ComboBox)
        if ($ComboBox.SelectedItem -and $ComboBox.SelectedItem.Content) { return [string]$ComboBox.SelectedItem.Content }
        return ''
    }

    function Sync-ProfileFromWizard {
        $profile.metadata.name = $controls.AppNameBox.Text.Trim()
        $profile.metadata.version = $controls.VersionBox.Text.Trim()
        $profile.metadata.publisher = $controls.PublisherBox.Text.Trim()
        $profile.commands.install = $controls.InstallCommandBox.Text.Trim()
        $profile.commands.uninstall = $controls.UninstallCommandBox.Text.Trim()
        $profile.commands.installBehavior = Get-ComboContent $controls.InstallBehaviorCombo
        $architectures = [Collections.Generic.List[string]]::new()
        if ($controls.ArchitectureX86Check.IsChecked) { $architectures.Add('x86') }
        if ($controls.ArchitectureX64Check.IsChecked) { $architectures.Add('x64') }
        if ($controls.ArchitectureArm64Check.IsChecked) { $architectures.Add('arm64') }
        $profile.requirements.architecture = [object[]]@($architectures)
        $profile.requirements.minimumOperatingSystem = Get-ComboContent $controls.MinimumOsCombo
        $profile.export.mode = if ($controls.PsadtCompleteModeRadio.IsChecked) {
            'PsadtComplete'
        } elseif ($controls.PsadtScriptModeRadio.IsChecked) { 'PsadtScriptOnly' } else { 'Direct' }
        $profile.export.includeSourceFolder = [bool]$controls.IncludeSourceFolderCheck.IsChecked
        $selectedDetection = $controls.DetectionCombo.SelectedItem
        $profile.detection.selected = if ($selectedDetection -and
            $selectedDetection.PSObject.Properties['isPlaceholder'] -and
            [bool]$selectedDetection.isPlaceholder) { $null } else { $selectedDetection }
        $profile.detection.confirmed = [bool]$controls.ConfirmDetectionCheck.IsChecked
    }

    function Update-DetectionDetails {
        $candidate = $controls.DetectionCombo.SelectedItem
        $controls.ConfirmDetectionCheck.IsChecked = $false
        if ($null -eq $candidate -or
            ($candidate.PSObject.Properties['isPlaceholder'] -and [bool]$candidate.isPlaceholder)) {
            $controls.DetectionJsonBox.Text = ''
            return
        }
        $controls.DetectionJsonBox.Text = $candidate | ConvertTo-Json -Depth 12
        $currentUninstall = $controls.UninstallCommandBox.Text.Trim()
        $mayReplace = [string]::IsNullOrWhiteSpace($currentUninstall) -or
            $currentUninstall -eq $wizardState.LastSuggestedUninstallCommand -or
            $currentUninstall -match '<[^>]+>'
        if ($mayReplace) {
            $resolvedUninstall = Resolve-WhatSwitchUninstallCommand -DetectionRule $candidate `
                -FallbackCommand ([string]$wizardState.LastSuggestedUninstallCommand)
            if (-not [string]::IsNullOrWhiteSpace($resolvedUninstall)) {
                $controls.UninstallCommandBox.Text = $resolvedUninstall
                $wizardState.LastSuggestedUninstallCommand = $resolvedUninstall
            }
        }
    }

    function Set-DetectionCandidates {
        param($SandboxReport)
        $previousId = if ($controls.DetectionCombo.SelectedItem) { [string]$controls.DetectionCombo.SelectedItem.id } else { '' }
        $candidates = @(Get-WhatSwitchDetectionCandidates -AnalysisResult $AnalysisResult -SandboxReport $SandboxReport)
        $profile.detection.candidates = $candidates
        if ($candidates.Count -eq 0) {
            $placeholder = [pscustomobject]@{
                id = ''
                displayName = 'Ingen regel ännu – kör Sandbox-testet'
                isPlaceholder = $true
            }
            $controls.DetectionCombo.ItemsSource = @($placeholder)
            $controls.DetectionCombo.SelectedIndex = 0
            $controls.DetectionCombo.IsEnabled = $false
            Update-DetectionDetails
            return
        }
        $controls.DetectionCombo.IsEnabled = $true
        $controls.DetectionCombo.ItemsSource = $candidates
        $selected = $candidates | Where-Object id -EQ $previousId | Select-Object -First 1
        if (-not $selected -and $SandboxReport -and $SandboxReport.PSObject.Properties['selected'] -and $SandboxReport.selected) {
            $selected = $candidates | Where-Object id -EQ ([string]$SandboxReport.selected.id) | Select-Object -First 1
        }
        if (-not $selected) { $selected = $candidates | Select-Object -First 1 }
        $controls.DetectionCombo.SelectedItem = $selected
        Update-DetectionDetails
    }

    function Refresh-SandboxReport {
        try {
        $controls.SandboxStatusText.Foreground = '#9FE1CF'
        $session = $GuiState.SandboxSession
        if ($null -eq $session) {
            $controls.SandboxStatusText.Text = 'Sandbox-test har inte körts.'
            Set-DetectionCandidates $null
            return
        }
        $report = Get-WhatSwitchSandboxDetectionReport -Session $session
        $sandboxState = if ($session.StatusPath -and (Test-Path -LiteralPath $session.StatusPath)) {
            (Get-Content -LiteralPath $session.StatusPath -Raw -Encoding utf8).Trim()
        } else { 'Okänd' }
        if ($report -and $report.status -ne 'pending') {
            $profile.sandbox.status = [string]$report.status
            $profile.sandbox.installedVerified = [bool]$report.installedVerified
            $profile.sandbox.uninstalledVerified = [bool]$report.uninstalledVerified
            $profile.sandbox.reportPath = [string]$session.DetectionReportPath
            $profile.sandbox.testedAt = $report.testedAt
            $verificationText = if ($report.installedVerified) { 'Installationen är verifierad.' } else { 'Ingen regel kunde verifiera installationen.' }
            $controls.SandboxStatusText.Text = "Sandbox-status: $sandboxState. $verificationText"
            Set-DetectionCandidates $report
        }
        else {
            $controls.SandboxStatusText.Text = "Sandbox-status: $sandboxState. Klicka på Hämta Sandbox-resultat när installationen är klar."
            Set-DetectionCandidates $null
        }
        }
        catch {
            $controls.SandboxStatusText.Text = "Sandbox-resultatet kunde inte läsas: $($_.Exception.Message)"
            $controls.SandboxStatusText.Foreground = '#FF9EAA'
            return
        }
    }

    function Get-WizardStepErrors {
        param([int]$Step)
        Sync-ProfileFromWizard
        $errors = [Collections.Generic.List[string]]::new()
        switch ($Step) {
            0 {
                if (-not $profile.metadata.name) { $errors.Add('Programnamn saknas.') }
                if (-not $profile.metadata.version) { $errors.Add('Programversion saknas.') }
                if (-not $profile.metadata.publisher) { $errors.Add('Utgivare saknas.') }
            }
            1 {
                if (-not $profile.commands.install) { $errors.Add('Installationskommando saknas.') }
                if (-not $profile.commands.uninstall) { $errors.Add('Avinstallationskommando saknas.') }
            }
            2 {
                if ($null -eq $profile.detection.selected) { $errors.Add('Välj en detektionsregel.') }
                if (-not $profile.detection.confirmed) { $errors.Add('Detektionsregeln måste granskas och bekräftas.') }
            }
            3 {
                if (@($profile.requirements.architecture).Count -eq 0) { $errors.Add('Välj minst en arkitektur.') }
            }
            4 {
                if ($profile.export.mode -eq 'PsadtComplete' -and -not (Test-Path -LiteralPath $script:WhatSwitchPsadtModulePath -PathType Leaf)) {
                    $errors.Add("PSAppDeployToolkit $script:WhatSwitchPsadtVersion saknas lokalt.")
                }
            }
        }
        return @($errors)
    }

    function Update-Summary {
        Sync-ProfileFromWizard
        $detection = if ($profile.detection.selected) { [string]$profile.detection.selected.displayName } else { 'SAKNAS' }
        $architectures = @($profile.requirements.architecture) -join ', '
        $sandboxText = if ($profile.sandbox.installedVerified) { 'Verifierad installation' } else { 'Inte verifierad' }
        $controls.SummaryText.Text = @"
Program:        $($profile.metadata.name) $($profile.metadata.version)
Utgivare:       $($profile.metadata.publisher)
Kontext:        $($profile.commands.installBehavior)
Arkitektur:     $architectures
Minsta OS:      $($profile.requirements.minimumOperatingSystem)
Exportläge:     $($profile.export.mode)
Detektering:    $detection
Sandbox:        $sandboxText

Installera:
$($profile.commands.install)

Avinstallera:
$($profile.commands.uninstall)
"@
        $validation = Test-WhatSwitchDeploymentProfile -Profile $profile
        $controls.ValidationCard.Visibility = if ($validation.IsValid) { 'Collapsed' } else { 'Visible' }
        $controls.ValidationText.Text = @($validation.Errors) -join "`n"
        $controls.ExportWizardButton.IsEnabled = $validation.IsValid
    }

    function Set-WizardStep {
        param([int]$Index)
        $controls.WizardTabs.SelectedIndex = $Index
        $controls.StepList.SelectedIndex = $Index
        $controls.BackWizardButton.IsEnabled = $Index -gt 0
        $controls.NextWizardButton.Visibility = if ($Index -lt 5) { 'Visible' } else { 'Collapsed' }
        $controls.ExportWizardButton.Visibility = if ($Index -eq 5) { 'Visible' } else { 'Collapsed' }
        $controls.WizardStatusText.Text = "Steg $($Index + 1) av 6"
        if ($Index -eq 2) { Refresh-SandboxReport }
        if ($Index -eq 5) { Update-Summary }
    }

    Set-DetectionCandidates $null
    $controls.DetectionCombo.Add_SelectionChanged({ Update-DetectionDetails })
    $controls.ApplyDetectionJsonButton.Add_Click({
        try {
            $edited = $controls.DetectionJsonBox.Text | ConvertFrom-Json -ErrorAction Stop
            if ([string]$edited.type -notin 'Msi', 'File', 'Registry') { throw 'Regeltypen måste vara Msi, File eller Registry.' }
            if (-not $edited.PSObject.Properties['id']) { $edited | Add-Member id ('manual-' + [guid]::NewGuid().ToString('N')) }
            if (-not $edited.PSObject.Properties['displayName']) { $edited | Add-Member displayName 'Manuellt redigerad regel' }
            $edited | Add-Member source 'Manuell redigering' -Force
            $edited | Add-Member verified $false -Force
            $edited | Add-Member priority 500 -Force
            $profile.detection.candidates = @($profile.detection.candidates) + @($edited)
            $controls.DetectionCombo.IsEnabled = $true
            $controls.DetectionCombo.ItemsSource = @($profile.detection.candidates)
            $controls.DetectionCombo.SelectedItem = $edited
            $controls.ConfirmDetectionCheck.IsChecked = $false
        }
        catch {
            [Windows.MessageBox]::Show($wizard, "Regelns JSON är ogiltig.`n`n$($_.Exception.Message)", 'Ogiltig detektionsregel', 'OK', 'Warning') | Out-Null
        }
    })
    $controls.ConfirmDetectionCheck.Add_Checked({
        Sync-ProfileFromWizard
        if ($GuiState.SandboxSession -and $profile.detection.selected) {
            try { [void](Set-WhatSwitchSandboxDetectionRule -Session $GuiState.SandboxSession -DetectionRule $profile.detection.selected) }
            catch { $controls.SandboxStatusText.Text = "Regeln kunde inte skickas till Sandbox: $($_.Exception.Message)" }
        }
    })
    $controls.RunSandboxButton.Add_Click({
        Sync-ProfileFromWizard
        if (-not $profile.commands.install -or -not $profile.commands.uninstall) {
            [Windows.MessageBox]::Show($wizard, 'Installations- och avinstallationskommando måste vara ifyllda.', 'Kommandon saknas', 'OK', 'Warning') | Out-Null
            return
        }
        & $StartSandboxAction $profile.commands.install $profile.commands.uninstall
        Refresh-SandboxReport
    })
    $controls.RefreshDetectionButton.Add_Click({
        try { Refresh-SandboxReport }
        catch { $controls.SandboxStatusText.Text = "Sandbox-resultatet kunde inte läsas: $($_.Exception.Message)" }
    })
    $controls.CancelWizardButton.Add_Click({ $wizard.Close() })
    $controls.BackWizardButton.Add_Click({ Set-WizardStep ($controls.WizardTabs.SelectedIndex - 1) })
    $controls.NextWizardButton.Add_Click({
        $step = $controls.WizardTabs.SelectedIndex
        $errors = @(Get-WizardStepErrors $step)
        if ($errors.Count) {
            [Windows.MessageBox]::Show($wizard, ($errors -join "`n"), 'Kontrollera steget', 'OK', 'Warning') | Out-Null
            return
        }
        Set-WizardStep ($step + 1)
    })
    $controls.ExportWizardButton.Add_Click({
        Sync-ProfileFromWizard
        $validation = Test-WhatSwitchDeploymentProfile -Profile $profile
        if (-not $validation.IsValid) {
            [Windows.MessageBox]::Show($wizard, (@($validation.Errors) -join "`n"), 'Exporten kan inte starta', 'OK', 'Warning') | Out-Null
            return
        }
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = [Windows.Forms.FolderBrowserDialog]::new()
        try {
            $dialog.Description = 'Välj mappen där den kompletta deploymentmappen ska skapas.'
            $defaultOutput = Join-Path $PSScriptRoot 'deployment'
            [void](New-Item -ItemType Directory -Path $defaultOutput -Force)
            $dialog.InitialDirectory = $defaultOutput
            $dialog.UseDescriptionForTitle = $true
            if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
            $controls.ExportWizardButton.IsEnabled = $false
            $controls.WizardStatusText.Text = 'Skapar deploymentpaket…'
            $wizard.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
            $export = Export-WhatSwitchDeploymentPackage -Profile $profile -AnalysisResult $AnalysisResult `
                -OutputDirectory $dialog.SelectedPath -SandboxReportPath ([string]$profile.sandbox.reportPath)
            [Windows.MessageBox]::Show(
                $wizard,
                "Deploymentpaketet skapades.`n`nLäge: $($export.Mode)`nIntune-paket: $($export.IntuneWinPath)`nKontrollsummor: $($export.ChecksumPath)",
                'Deployment klar', 'OK', 'Information'
            ) | Out-Null
            $wizard.Tag = $export
            $wizard.DialogResult = $true
        }
        catch {
            $controls.WizardStatusText.Text = 'Exporten misslyckades.'
            $controls.ExportWizardButton.IsEnabled = $true
            [Windows.MessageBox]::Show($wizard, $_.Exception.Message, 'Exporten misslyckades', 'OK', 'Warning') | Out-Null
        }
        finally { $dialog.Dispose() }
    })

    Set-WizardStep 0
    [void]$wizard.ShowDialog()
    return $wizard.Tag
}
