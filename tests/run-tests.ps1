#requires -Version 7.6

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../WhatSwitch.psd1') -Force
. (Join-Path $PSScriptRoot '../WhatSwitch.Sandbox.ps1')
. (Join-Path $PSScriptRoot '../WhatSwitch.IntuneWin.ps1')
. (Join-Path $PSScriptRoot '../WhatSwitch.Deployment.ps1')
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('whatswitch-tests-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot)
$failures = [Collections.Generic.List[string]]::new()

function Assert-Equal {
    param($Actual, $Expected, [string]$Because)
    if ($Actual -cne $Expected) {
        $failures.Add("$Because. Expected '$Expected', got '$Actual'.")
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Because)
    if (-not $Condition) { $failures.Add($Because) }
}

function New-FakePe {
    param([string]$Name, [string[]]$Markers)
    $header = [byte[]]::new(512)
    $header[0] = 0x4d
    $header[1] = 0x5a
    $payload = [Text.Encoding]::ASCII.GetBytes(($Markers -join "`0"))
    $all = [byte[]]::new($header.Length + $payload.Length)
    [Array]::Copy($header, $all, $header.Length)
    [Array]::Copy($payload, 0, $all, $header.Length, $payload.Length)
    $path = Join-Path $testRoot $Name
    [IO.File]::WriteAllBytes($path, $all)
    return $path
}

try {
    Assert-Equal (ConvertTo-WhatSwitchPowerShellCommand 'setup.exe /S') '.\setup.exe /S' 'A local executable should get a relative-path prefix'
    Assert-Equal (ConvertTo-WhatSwitchPowerShellCommand 'msiexec /i app.msi /qn') 'msiexec /i app.msi /qn' 'A PATH command should stay unchanged'
    Assert-Equal (ConvertTo-WhatSwitchPowerShellCommand '"%ProgramFiles%\App\uninstall.exe" /S') '& "$env:ProgramFiles\App\uninstall.exe" /S' 'Quoted paths and environment variables should become PowerShell syntax'

    $inno = Get-WhatSwitchResult -Path (New-FakePe 'sample-inno.exe' @('Inno Setup Setup Data'))
    Assert-Equal $inno.Engine 'inno' 'Inno marker detection should work'
    Assert-True ($inno.Commands[0].PowerShellCommand.StartsWith('.\sample-inno.exe')) 'Generated Inno commands should be PowerShell-ready'

    $nsis = Get-WhatSwitchResult -Path (New-FakePe 'AnyDesk.exe' @('NullsoftInst'))
    Assert-Equal $nsis.Engine 'nsis' 'NSIS marker detection should work'
    Assert-Equal $nsis.Catalog.Name 'AnyDesk' 'Catalog lookup should use the filename'
    Assert-Equal $nsis.Catalog.InstallCommand 'AnyDesk.exe --install "C:\Program Files (x86)\AnyDesk" --start-with-win --create-shortcuts --silent' 'Catalog placeholders should be literal substitutions'

    $burn = Get-WhatSwitchResult -Path (New-FakePe 'bundle.exe' @('.wixburn'))
    Assert-Equal $burn.Engine 'wix-burn' 'WiX Burn fallback marker detection should work'

    $engineCases = @(
        @{ File = 'shield.exe'; Marker = 'InstallShield'; Expected = 'installshield' }
        @{ File = 'advanced.exe'; Marker = 'Advanced Installer 21.8.2'; Expected = 'advanced-installer' }
        @{ File = 'squirrel.exe'; Marker = 'Squirrel'; Expected = 'squirrel' }
        @{ File = 'aware.exe'; Marker = 'InstallAware'; Expected = 'installaware' }
        @{ File = 'bitrock.exe'; Marker = 'InstallBuilder'; Expected = 'installbuilder' }
        @{ File = 'wise.exe'; Marker = 'WiseMain'; Expected = 'wise' }
        @{ File = 'archive.exe'; Marker = 'Rar!'; Expected = 'sfx-winrar' }
    )
    foreach ($case in $engineCases) {
        $detected = Get-WhatSwitchResult -Path (New-FakePe $case.File @($case.Marker))
        Assert-Equal $detected.Engine $case.Expected "$($case.Expected) marker detection should work"
    }

    $customPath = New-FakePe 'custom.exe' @('_CorExeMain', '--silent')
    $customBytes = [Collections.Generic.List[byte]]::new([IO.File]::ReadAllBytes($customPath))
    $customBytes.Add(0)
    $customBytes.Add(0)
    # `serverPath` has exactly one uppercase character. This used to trigger a StrictMode
    # PropertyNotFoundException when the scanner counted a one-item pipeline via `.Count`.
    $customBytes.AddRange([Text.Encoding]::Unicode.GetBytes('ApiServerAddress serverPath'))
    [IO.File]::WriteAllBytes($customPath, $customBytes.ToArray())
    $custom = Get-WhatSwitchResult -Path $customPath -IncludeBestEffort
    Assert-Equal $custom.Engine 'dotnet' 'Managed executable detection should work'
    Assert-True ($custom.BestEffort.Flags -contains '--silent') 'Best-effort scanning should find a strong flag'
    Assert-True ($custom.BestEffort.Options -contains 'ApiServerAddress') 'Best-effort scanning should find a compound option'

    $plainPath = Join-Path $testRoot 'readme.txt'
    [IO.File]::WriteAllText($plainPath, 'not an installer')
    $plain = Get-WhatSwitchResult -Path $plainPath
    Assert-Equal $plain.Engine 'not-installer' 'Non-installer input should be rejected'

    $msiPath = Join-Path $testRoot 'synthetic.msi'
    [IO.File]::WriteAllBytes($msiPath, [byte[]](0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1, 0, 0, 0, 0))
    $msi = Get-WhatSwitchResult -Path $msiPath
    Assert-Equal $msi.Engine 'msi' 'Compound-file signature detection should work even when deep parsing fails'
    Assert-True ($msi.Commands.Count -eq 4) 'MSI should expose the full operation matrix'

    $msixPath = Join-Path $testRoot 'synthetic.msix'
    [IO.File]::WriteAllBytes($msixPath, [byte[]](0x50, 0x4b, 0x03, 0x04, 0, 0, 0, 0))
    $msix = Get-WhatSwitchResult -Path $msixPath
    Assert-Equal $msix.Engine 'msix' 'MSIX extension plus ZIP signature detection should work'

    $catalog = @(Get-WhatSwitchCatalog)
    Assert-True ($catalog.Count -ge 39) 'The generated catalog should load all upstream entries'

    $sandboxSource = New-FakePe 'sandbox-test.exe' @('Inno Setup')
    $sandboxSession = New-WhatSwitchSandboxSession -InstallerPath $sandboxSource `
        -Command 'sandbox-test.exe /VERYSILENT /NORESTART' `
        -FollowUpCommand 'sandbox-test.exe /uninstall /VERYSILENT' `
        -SessionRoot (Join-Path $testRoot 'SandboxSessions')
    [xml]$sandboxConfiguration = Get-Content -LiteralPath $sandboxSession.ConfigurationPath -Raw -Encoding utf8
    Assert-Equal $sandboxConfiguration.Configuration.Networking 'Disable' 'Sandbox networking should be disabled by default'
    Assert-Equal $sandboxConfiguration.Configuration.ClipboardRedirection 'Disable' 'Sandbox clipboard redirection should be disabled'
    $sandboxMappings = @($sandboxConfiguration.Configuration.MappedFolders.MappedFolder)
    $contentMapping = $sandboxMappings | Where-Object SandboxFolder -EQ 'C:\WhatSwitch'
    $controlMapping = $sandboxMappings | Where-Object SandboxFolder -EQ 'C:\WhatSwitchControl'
    Assert-Equal $contentMapping.ReadOnly 'true' 'The sandbox staging folder should be mapped read-only'
    Assert-Equal $contentMapping.SandboxFolder 'C:\WhatSwitch' 'The sandbox should use a predictable working folder'
    Assert-Equal $controlMapping.ReadOnly 'false' 'Only the isolated status/control folder should be writable by the sandbox'
    Assert-True (Test-Path -LiteralPath $sandboxSession.RunnerPath -PathType Leaf) 'The sandbox runner script should be generated'
    Assert-True (Test-Path -LiteralPath $sandboxSession.InstallerPath -PathType Leaf) 'Only the selected installer should be staged for the sandbox'
    Assert-True (Test-Path -LiteralPath $sandboxSession.ControlPath -PathType Leaf) 'The sandbox session should expose a host-side control file'
    Assert-True (Test-Path -LiteralPath $sandboxSession.StatusPath -PathType Leaf) 'The sandbox session should expose an installation status file'
    Assert-True (Test-Path -LiteralPath $sandboxSession.HeartbeatPath -PathType Leaf) 'The sandbox session should expose a heartbeat file'
    Assert-Equal $sandboxSession.FollowUpCommand 'sandbox-test.exe /uninstall /VERYSILENT' 'The uninstall command should stay attached to the installation session'
    $runnerTokens = $null
    $runnerErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($sandboxSession.RunnerPath, [ref]$runnerTokens, [ref]$runnerErrors)
    Assert-True ($runnerErrors.Count -eq 0) 'The generated Windows Sandbox runner should be valid PowerShell'
    $runnerText = Get-Content -LiteralPath $sandboxSession.RunnerPath -Raw -Encoding utf8
    Assert-True ($runnerText.Contains('WhatSwitch.status')) 'The runner should report installation state to the GUI'
    Assert-True ($runnerText.Contains('WhatSwitch.heartbeat')) 'The runner should report that the sandbox session is still active'
    Assert-True ($runnerText.Contains('Start-Job -ScriptBlock')) 'Heartbeat should continue while an installer process blocks the main runner'
    Assert-True ($runnerText.Contains("requestAction -eq 'Install'")) 'The active sandbox should accept another install request without opening a second session'
    Assert-True ($runnerText.Contains('Save-WhatSwitchDetectionReport')) 'The sandbox runner should discover and verify real detection rules'
    Assert-True ($runnerText.Contains("staticDetectionJson -eq '[]'")) 'An empty detection list should stay empty in Windows PowerShell 5.1'
    Assert-True ($runnerText.Contains('UninstallFailed:DetectionStillPresent')) 'The sandbox should reject a successful uninstall exit code when detection still matches'
    Assert-True (Test-Path -LiteralPath $sandboxSession.DetectionReportPath -PathType Leaf) 'The sandbox session should expose a detection report'

    $intuneSource = Join-Path $testRoot 'IntuneSource'
    [void](New-Item -ItemType Directory -Path (Join-Path $intuneSource 'support') -Force)
    $intuneSetup = Join-Path $intuneSource 'setup.exe'
    [IO.File]::WriteAllBytes($intuneSetup, [Text.Encoding]::UTF8.GetBytes('synthetic setup'))
    [IO.File]::WriteAllText((Join-Path $intuneSource 'support\settings.json'), '{"silent":true}', [Text.UTF8Encoding]::new($false))
    $intuneOutput = Join-Path $testRoot 'Synthetic.intunewin'
    $intunePackage = New-WhatSwitchIntuneWinPackage -SetupFile $intuneSetup -SourceFolder $intuneSource `
        -IncludeSourceFolder -OutputPath $intuneOutput -ApplicationName 'Synthetic App'
    Assert-True (Test-Path -LiteralPath $intuneOutput -PathType Leaf) 'The Intune package should be written to disk'
    Assert-Equal $intunePackage.FileCount 2 'Source-folder packaging should include setup and support files'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $outerArchive = [IO.Compression.ZipFile]::OpenRead($intuneOutput)
    try {
        $metadataEntry = $outerArchive.GetEntry('IntuneWinPackage/Metadata/Detection.xml')
        $contentEntry = $outerArchive.GetEntry('IntuneWinPackage/Contents/IntunePackage.intunewin')
        Assert-True ($null -ne $metadataEntry) 'The Intune package should contain Detection.xml'
        Assert-True ($null -ne $contentEntry) 'The Intune package should contain the encrypted payload'
        $metadataReader = [IO.StreamReader]::new($metadataEntry.Open(), [Text.Encoding]::UTF8)
        try { [xml]$detectionXml = $metadataReader.ReadToEnd() } finally { $metadataReader.Dispose() }
        $encryptedMemory = [IO.MemoryStream]::new()
        $contentStream = $contentEntry.Open()
        try { $contentStream.CopyTo($encryptedMemory) } finally { $contentStream.Dispose() }
        $encryptedBytes = $encryptedMemory.ToArray()
        $encryptedMemory.Dispose()
    }
    finally { $outerArchive.Dispose() }

    Assert-Equal $detectionXml.ApplicationInfo.Name 'Synthetic App' 'Detection.xml should preserve the application name'
    Assert-Equal $detectionXml.ApplicationInfo.SetupFile 'setup.exe' 'Detection.xml should identify the setup file'
    $macKey = [Convert]::FromBase64String($detectionXml.ApplicationInfo.EncryptionInfo.MacKey)
    $expectedMac = [Convert]::FromBase64String($detectionXml.ApplicationInfo.EncryptionInfo.Mac)
    [byte[]]$authenticatedBytes = $encryptedBytes[32..($encryptedBytes.Length - 1)]
    $hmac = [Security.Cryptography.HMACSHA256]::new($macKey)
    try { $actualMac = $hmac.ComputeHash($authenticatedBytes) } finally { $hmac.Dispose() }
    Assert-True ([Security.Cryptography.CryptographicOperations]::FixedTimeEquals($expectedMac, $actualMac)) 'The encrypted payload HMAC should validate'

    $encryptionKey = [Convert]::FromBase64String($detectionXml.ApplicationInfo.EncryptionInfo.EncryptionKey)
    [byte[]]$iv = $encryptedBytes[32..47]
    [byte[]]$ciphertext = $encryptedBytes[48..($encryptedBytes.Length - 1)]
    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $encryptionKey
        $aes.IV = $iv
        $aes.Mode = [Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
        $decryptor = $aes.CreateDecryptor()
        try { $payloadBytes = $decryptor.TransformFinalBlock($ciphertext, 0, $ciphertext.Length) }
        finally { $decryptor.Dispose() }
    }
    finally { $aes.Dispose() }
    $expectedDigest = [Convert]::FromBase64String($detectionXml.ApplicationInfo.EncryptionInfo.FileDigest)
    $actualDigest = [Security.Cryptography.SHA256]::HashData($payloadBytes)
    Assert-True ([Security.Cryptography.CryptographicOperations]::FixedTimeEquals($expectedDigest, $actualDigest)) 'The decrypted payload digest should validate'

    $payloadMemory = [IO.MemoryStream]::new($payloadBytes, $false)
    $payloadArchive = [IO.Compression.ZipArchive]::new($payloadMemory, [IO.Compression.ZipArchiveMode]::Read)
    try {
        Assert-True ($null -ne $payloadArchive.GetEntry('setup.exe')) 'The decrypted payload should contain the setup file'
        Assert-True ($null -ne $payloadArchive.GetEntry('support/settings.json')) 'The decrypted payload should preserve support-file paths'
    }
    finally {
        $payloadArchive.Dispose()
        $payloadMemory.Dispose()
    }

    $sevenZipMsiPath = 'C:\Users\andre\Downloads\7z2602-x64.msi'
    if (Test-Path -LiteralPath $sevenZipMsiPath -PathType Leaf) {
        $sevenZipMsi = Get-WhatSwitchResult -Path $sevenZipMsiPath
        Assert-Equal $sevenZipMsi.Engine 'msi' 'The 7-Zip MSI should remain an MSI result'
        Assert-True ($null -eq $sevenZipMsi.Catalog) 'The 7-Zip MSI must not inherit the EXE catalog command'
        $sevenZipProfile = New-WhatSwitchDeploymentProfile -AnalysisResult $sevenZipMsi
        Assert-Equal $sevenZipProfile.detection.selected.type 'Msi' 'The 7-Zip MSI should use MSI ProductCode detection'
        Assert-Equal $sevenZipProfile.detection.selected.productCode $sevenZipMsi.Msi.ProductCode 'The deployment profile should preserve the MSI ProductCode'
        $sevenZipPsadt = New-WhatSwitchPsadtScriptContent -Profile $sevenZipProfile -AnalysisResult $sevenZipMsi
        $sevenZipMsiActions = @($sevenZipPsadt -split "`r?`n" | Where-Object { $_ -match 'Start-ADTMsiProcess -Action (Install|Uninstall)' })
        Assert-True (-not ($sevenZipMsiActions -match 'ArgumentList')) 'Default MSI commands should use PSADT config.psd1 without overriding ArgumentList'
    }

    $deploymentProfile = New-WhatSwitchDeploymentProfile -AnalysisResult $inno
    $legacySandboxReport = [pscustomobject]@{
        candidates = @(
            [pscustomobject]@{ value = @(); Count = 0 }
            [pscustomobject]@{ id = 'valid-registry'; type = 'Registry'; displayName = 'Valid registry'; priority = 200; source = 'Windows Sandbox'; verified = $true; keyPath = 'HKEY_LOCAL_MACHINE\SOFTWARE\Synthetic'; valueName = 'DisplayName'; uninstallString = '"C:\Program Files\Synthetic\unins000.exe"'; quietUninstallString = '' }
        )
    }
    $legacyCandidates = @(Get-WhatSwitchDetectionCandidates -AnalysisResult $inno -SandboxReport $legacySandboxReport)
    Assert-Equal $legacyCandidates.Count 1 'Malformed legacy Sandbox candidates should be ignored instead of crashing the GUI'
    Assert-Equal $legacyCandidates[0].type 'Registry' 'Valid candidates after a malformed entry should still be loaded'
    Assert-Equal (Resolve-WhatSwitchUninstallCommand -DetectionRule $legacyCandidates[0] -FallbackCommand '"%ProgramFiles%\<App>\unins000.exe" /VERYSILENT') `
        '"C:\Program Files\Synthetic\unins000.exe" /VERYSILENT' 'A discovered registry uninstall path should replace the placeholder and keep its silent arguments'
    $manualDetection = New-WhatSwitchDetectionCandidate -Type File -Id 'manual-test' -DisplayName 'Synthetic file rule' `
        -Priority 1 -Source 'Test' -Properties @{ path = 'C:\Program Files'; fileOrFolder = 'Synthetic'; detectionMethod = 'exists' }
    $deploymentProfile.detection.selected = $manualDetection
    $deploymentProfile.detection.confirmed = $true
    $profileValidation = Test-WhatSwitchDeploymentProfile -Profile $deploymentProfile
    Assert-True $profileValidation.IsValid 'A complete deployment profile should validate'
    Assert-Equal $deploymentProfile.schemaVersion 1 'Deployment profiles should use schema version 1'
    Assert-Equal $deploymentProfile.commands.installBehavior 'System' 'System should be the default Intune install context'

    $deploymentOutput = Join-Path $testRoot 'DeploymentExports'
    [void](New-Item -ItemType Directory -Path $deploymentOutput)
    $directExport = Export-WhatSwitchDeploymentPackage -Profile $deploymentProfile -AnalysisResult $inno -OutputDirectory $deploymentOutput
    Assert-True (Test-Path -LiteralPath $directExport.IntuneWinPath -PathType Leaf) 'Direct deployment export should create an Intune package'
    Assert-True (Test-Path -LiteralPath (Join-Path $directExport.Path 'Intune\Intune-Settings.json')) 'Direct export should include Intune settings'
    Assert-True (Test-Path -LiteralPath (Join-Path $directExport.Path 'Intune\README-SV.md')) 'Direct export should include a Swedish Intune guide'
    Assert-True (Test-Path -LiteralPath $directExport.ChecksumPath) 'Direct export should include SHA-256 checksums'

    if (Test-Path -LiteralPath $script:WhatSwitchPsadtModulePath -PathType Leaf) {
        $deploymentProfile.metadata.version = '1.0.1'
        $deploymentProfile.export.mode = 'PsadtScriptOnly'
        $scriptOnlyExport = Export-WhatSwitchDeploymentPackage -Profile $deploymentProfile -AnalysisResult $inno -OutputDirectory $deploymentOutput
        $scriptOnlySource = Join-Path $scriptOnlyExport.Path 'Source'
        Assert-True (Test-Path -LiteralPath (Join-Path $scriptOnlySource 'Invoke-AppDeployToolkit.exe')) 'PSADT script-only should include the v4 frontend executable'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $scriptOnlySource 'PSAppDeployToolkit'))) 'PSADT script-only should not bundle the toolkit module'
        $generatedPsadt = Get-Content -LiteralPath (Join-Path $scriptOnlySource 'Invoke-AppDeployToolkit.ps1') -Raw
        Assert-True ($generatedPsadt.Contains('Open-ADTSession')) 'Generated PSADT scripts should use v4 session APIs'
        Assert-True ($generatedPsadt.Contains('Start-ADTProcess')) 'Generated EXE deployments should use Start-ADTProcess'
        Assert-True ($generatedPsadt.Contains('Show-ADTInstallationWelcome')) 'Generated PSADT scripts should preserve the official pre-install phase'
        Assert-True ($generatedPsadt.Contains('function Repair-ADTDeployment')) 'Generated PSADT scripts should preserve the official repair function'
        Assert-True ($generatedPsadt.Contains('Remove-ADTHashtableNullOrEmptyValues')) 'Generated PSADT scripts should preserve the official initialization and validation logic'
        Assert-True ($generatedPsadt.Contains('## <Perform Installation tasks here>')) 'Generated PSADT scripts should retain the official customization markers'

        $deploymentProfile.metadata.version = '1.0.2'
        $deploymentProfile.export.mode = 'PsadtComplete'
        $completeExport = Export-WhatSwitchDeploymentPackage -Profile $deploymentProfile -AnalysisResult $inno -OutputDirectory $deploymentOutput
        Assert-True (Test-Path -LiteralPath (Join-Path $completeExport.Path 'Source\PSAppDeployToolkit\PSAppDeployToolkit.psd1')) 'Complete PSADT export should bundle the toolkit module'
        Assert-True (Test-Path -LiteralPath (Join-Path $completeExport.Path 'Source\PSAppDeployToolkit-LICENSE.txt')) 'Complete PSADT export should include the toolkit license'
    }

    if ($IsWindows) {
        $xamlPath = Join-Path $PSScriptRoot '../WhatSwitch.Gui.xaml'
        $guiScriptPath = Join-Path $PSScriptRoot '../Start-WhatSwitchGui.ps1'
        [xml]$guiDocument = Get-Content -LiteralPath $xamlPath -Raw -Encoding utf8
        $namespaceManager = [Xml.XmlNamespaceManager]::new($guiDocument.NameTable)
        $namespaceManager.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
        $namedControls = @($guiDocument.SelectNodes('//*[@x:Name]', $namespaceManager))
        Assert-True ($namedControls.Count -ge 35) 'The GUI should expose its named controls in valid XML'
        $warningGrid = $guiDocument.SelectSingleNode('//*[@x:Name="WarningCard"]/*[local-name()="Grid"]', $namespaceManager)
        Assert-True ($null -ne $warningGrid) 'The warning card should use a width-constrained Grid so wrapped text is not clipped'
        $inputScroll = $guiDocument.SelectSingleNode('//*[@x:Name="InputScroll"]', $namespaceManager)
        Assert-True ($null -ne $inputScroll) 'The input panel should be vertically scrollable at the minimum window height'
        $responsiveToolbar = $guiDocument.SelectSingleNode('//*[local-name()="WrapPanel"]/*[@x:Name="ShellSelector"]', $namespaceManager)
        Assert-True ($null -ne $responsiveToolbar) 'The result toolbar should use a wrapping layout at the minimum window width'
        $darkExpanderStyle = $guiDocument.SelectSingleNode('//*[local-name()="Style" and @TargetType="Expander"]/*[local-name()="Setter" and @Property="HeaderTemplate"]', $namespaceManager)
        Assert-True ($null -ne $darkExpanderStyle) 'Expander titles should have an explicit dark-theme header template'
        $centeredComboBox = $guiDocument.SelectSingleNode('//*[local-name()="Style" and @TargetType="ComboBox"]/*[local-name()="Setter" and @Property="VerticalContentAlignment" and @Value="Center"]', $namespaceManager)
        Assert-True ($null -ne $centeredComboBox) 'ComboBox selected text should be vertically centered'
        $guiScript = Get-Content -LiteralPath $guiScriptPath -Raw -Encoding utf8
        Assert-True (-not $guiScript.Contains('$ui.DropZone.Add_MouseLeftButtonUp')) 'The drop zone must not re-raise BrowseButton.Click after the file dialog closes'
        Assert-True ($guiScript.Contains("'Testa i Sandbox'")) 'Command cards should expose the Windows Sandbox test action'
        Assert-True ($guiScript.Contains('ActiveSandboxUninstall')) 'The existing uninstall card button should target the active sandbox session'
        Assert-True ($guiScript.Contains("Programmet är redan installerat i Sandbox")) 'The GUI should prevent a second install before uninstall'
        Assert-True ($guiScript.Contains("Get-Process -Name 'WindowsSandboxClient'")) 'The GUI should detect a pre-existing external Windows Sandbox session'
        Assert-True ($guiScript.Contains('Show-WhatSwitchDeploymentWizard')) 'The GUI should expose the unified deployment guide'
        Assert-True ($null -ne $guiDocument.SelectSingleNode('//*[@x:Name="DeploymentGuideButton"]', $namespaceManager)) 'The result toolbar should expose the deployment guide button'
        [xml]$deploymentGuiDocument = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../WhatSwitch.Deployment.xaml') -Raw -Encoding utf8
        $deploymentNamespace = [Xml.XmlNamespaceManager]::new($deploymentGuiDocument.NameTable)
        $deploymentNamespace.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
        Assert-True ($null -ne $deploymentGuiDocument.SelectSingleNode('//*[@x:Name="WizardTabs"]', $deploymentNamespace)) 'The deployment guide should contain the six-step wizard'
        Assert-True ($null -ne $deploymentGuiDocument.SelectSingleNode('//*[@x:Name="DetectionCombo"]', $deploymentNamespace)) 'The deployment guide should require a selected detection rule'
        $readableComboForeground = $deploymentGuiDocument.SelectSingleNode('//*[local-name()="Style" and @TargetType="ComboBox"]/*[local-name()="Setter" and @Property="Foreground" and @Value="#101626"]', $deploymentNamespace)
        Assert-True ($null -ne $readableComboForeground) 'Deployment guide ComboBoxes should use dark text on their native light background'
        $lightTextBlocks = $deploymentGuiDocument.SelectSingleNode('//*[local-name()="Style" and @TargetType="TextBlock"]/*[local-name()="Setter" and @Property="Foreground" and @Value="#F5F7FF"]', $deploymentNamespace)
        Assert-True ($null -ne $lightTextBlocks) 'Deployment guide headings and inherited text should never use the black WPF default'
        $lightStepTitles = $deploymentGuiDocument.SelectSingleNode('//*[local-name()="Style" and @x:Key="StepTitle"]/*[local-name()="Setter" and @Property="Foreground" and @Value="#F5F7FF"]', $deploymentNamespace)
        Assert-True ($null -ne $lightStepTitles) 'Deployment guide step headings should explicitly use light text'
        $readableComboItems = $deploymentGuiDocument.SelectSingleNode('//*[local-name()="Style" and @TargetType="ComboBoxItem"]/*[local-name()="Setter" and @Property="Foreground" and @Value="#101626"]', $deploymentNamespace)
        Assert-True ($null -ne $readableComboItems) 'Deployment guide ComboBox items should use dark text on their light background'
        $darkStepItems = $deploymentGuiDocument.SelectSingleNode('//*[local-name()="Style" and @TargetType="ListBoxItem"]/*[local-name()="Setter" and @Property="Foreground" and @Value="#E9EDFA"]', $deploymentNamespace)
        Assert-True ($null -ne $darkStepItems) 'Deployment guide step titles should use explicit light text'
        $deploymentGuiScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../WhatSwitch.DeploymentGui.ps1') -Raw -Encoding utf8
        Assert-True ($deploymentGuiScript.Contains('Ingen regel ännu – kör Sandbox-testet')) 'An empty detection list should show an explicit Sandbox placeholder'
        Assert-True ($deploymentGuiScript.Contains('$controls.DetectionCombo.IsEnabled = $false')) 'An empty detection list should not open an empty dropdown'
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

if ($failures.Count) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "$($failures.Count) test(s) failed."
}

Write-Host 'All What Switch? PowerShell tests passed.' -ForegroundColor Green
