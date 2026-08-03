#requires -Version 7.6

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path,

    [Parameter(DontShow)]
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'What Switch?-GUI:t använder WPF och kan därför bara köras på Windows.'
}

# WPF dialogs and Clipboard require an STA thread. Relaunch invisibly in STA when the caller used
# the normal pwsh apartment state.
if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    $pwshPath = (Get-Process -Id $PID).Path
    $startInfo = [Diagnostics.ProcessStartInfo]::new($pwshPath)
    $startInfo.UseShellExecute = $false
    foreach ($argument in @('-NoLogo', '-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-File', $PSCommandPath)) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    if ($Path) { [void]$startInfo.ArgumentList.Add($Path) }
    if ($ValidateOnly) { [void]$startInfo.ArgumentList.Add('-ValidateOnly') }
    [void][Diagnostics.Process]::Start($startInfo)
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $PSScriptRoot 'WhatSwitch.psd1') -Force -ErrorAction Stop
. (Join-Path $PSScriptRoot 'WhatSwitch.Sandbox.ps1')
. (Join-Path $PSScriptRoot 'WhatSwitch.IntuneWin.ps1')
. (Join-Path $PSScriptRoot 'WhatSwitch.Deployment.ps1')
. (Join-Path $PSScriptRoot 'WhatSwitch.DeploymentGui.ps1')

$xamlPath = Join-Path $PSScriptRoot 'WhatSwitch.Gui.xaml'
$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding utf8
$xmlReader = [Xml.XmlReader]::Create([IO.StringReader]::new($xaml))
try {
    $window = [Windows.Markup.XamlReader]::Load($xmlReader)
}
finally {
    $xmlReader.Dispose()
}

$names = @(
    'InputScroll', 'DropZone', 'DropOutline', 'DropIcon', 'DropTitle', 'DropSubtitle', 'BrowseButton',
    'FileCard', 'FileNameText', 'FilePathText', 'FileSizeText', 'BestEffortCheck', 'SandboxNetworkCheck',
    'ReanalyzeButton', 'ClearButton', 'EmptyState', 'ResultsScroll', 'EngineText',
    'ResultFileText', 'ConfidenceBadge', 'ConfidenceText', 'MetadataCard', 'ProductText',
    'CompanyVersionText', 'CatalogCard', 'CatalogNameText', 'CatalogInstallText',
    'CatalogNoteText', 'WarningCard', 'WarningText', 'ShellSelector', 'DeploymentGuideButton', 'CopyJsonButton',
    'SaveJsonButton', 'CommandPanel', 'NotesText', 'ModifiersText', 'CandidatesExpander',
    'CandidatesText', 'MsiExpander', 'MsiSummaryText', 'MsiGrid', 'StatusText', 'BusyBar'
)
$ui = @{}
foreach ($name in $names) {
    $control = $window.FindName($name)
    if ($null -eq $control) { throw "XAML-kontrollen '$name' saknas." }
    $ui[$name] = $control
}

$state = @{
    Path = $null
    Result = $null
    SandboxSession = $null
    SandboxInstallButtons = [Collections.Generic.List[Windows.Controls.Button]]::new()
    SandboxUninstallButtons = [Collections.Generic.List[Windows.Controls.Button]]::new()
    SandboxRequestPending = $false
    SandboxRequestFromState = ''
    LastSandboxState = ''
    IsBusy = $false
}
$supportedExtensions = '.exe', '.msi', '.msp', '.msix', '.appx', '.msixbundle', '.appxbundle'

function Set-WhatSwitchGuiStatus {
    param([string]$Text, [switch]$Busy, [switch]$Error)

    $ui.StatusText.Text = $Text
    $ui.StatusText.Foreground = if ($Error) { '#FF8F9C' } elseif ($Busy) { '#B8C5E3' } else { '#9AA8C7' }
    $ui.BusyBar.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $window.Cursor = if ($Busy) { [Windows.Input.Cursors]::Wait } else { [Windows.Input.Cursors]::Arrow }
    $state.IsBusy = [bool]$Busy
}

function Set-WhatSwitchDropHighlight {
    param([bool]$Active)

    if ($Active) {
        $ui.DropOutline.Fill = '#16284A'
        $ui.DropOutline.Stroke = '#8AA2FF'
        $ui.DropIcon.Foreground = '#A9B9FF'
        $ui.DropTitle.Text = 'Släpp filen för att analysera'
    }
    else {
        $ui.DropOutline.Fill = '#10192D'
        $ui.DropOutline.Stroke = '#536A9F'
        $ui.DropIcon.Foreground = '#6C8CFF'
        $ui.DropTitle.Text = 'Dra en installer hit'
    }
}

function Format-WhatSwitchFileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N1} KB' -f ($Bytes / 1KB) }
    return "$Bytes byte"
}

function Set-WhatSwitchClipboard {
    param([AllowEmptyString()][string]$Text, [string]$Description = 'Text')
    try {
        [Windows.Clipboard]::SetText($Text)
        Set-WhatSwitchGuiStatus "$Description kopierad till Urklipp."
    }
    catch {
        Set-WhatSwitchGuiStatus "Kunde inte kopiera: $($_.Exception.Message)" -Error
    }
}

function Invoke-WhatSwitchGuiSandboxTest {
    param(
        [Parameter(Mandatory)][string]$Command,
        [ValidateSet('Cmd', 'PowerShell')][string]$CommandShell = 'Cmd',
        [AllowEmptyString()][string]$FollowUpCommand = '',
        [ValidateSet('Cmd', 'PowerShell')][string]$FollowUpShell = 'Cmd'
    )

    if (-not $state.Path) { return }
    $existingSession = $state.SandboxSession
    if ($null -ne $existingSession -and (Test-WhatSwitchGuiSandboxAlive)) {
        $sameInstaller = [string]::Equals(
            $existingSession.SourceInstallerPath,
            $state.Path,
            [StringComparison]::OrdinalIgnoreCase
        )
        $sameCommand = $sameInstaller -and
            [string]::Equals($existingSession.Command, $Command, [StringComparison]::Ordinal) -and
            [string]::Equals($existingSession.CommandShell, $CommandShell, [StringComparison]::OrdinalIgnoreCase)
        if ($sameCommand) {
            $sandboxState = Get-WhatSwitchGuiSandboxState
            if ($sandboxState -in 'Installing', 'Uninstalling', 'Pending') {
                Set-WhatSwitchGuiStatus 'Den aktiva Sandbox-sessionen arbetar redan. Vänta tills kommandot är klart.' -Error
                return
            }
            if ($sandboxState -match '^Installed' -or $sandboxState -match '^UninstallFailed') {
                Set-WhatSwitchGuiStatus 'Programmet är redan installerat i Sandbox. Testa avinstallationen innan du installerar igen.' -Error
                return
            }
            $answer = [Windows.MessageBox]::Show(
                $window,
                'Samma What Switch?-Sandbox är redan aktiv. Vill du köra installationskommandot igen i den sessionen?',
                'Återanvänd aktiv Windows Sandbox',
                [Windows.MessageBoxButton]::YesNo,
                [Windows.MessageBoxImage]::Question,
                [Windows.MessageBoxResult]::No
            )
            if ($answer -eq [Windows.MessageBoxResult]::Yes) {
                Send-WhatSwitchGuiSandboxRequest -Action Install
            }
            return
        }

        [Windows.MessageBox]::Show(
            $window,
            "En What Switch?-Sandbox körs redan med en annan installer eller ett annat kommando.`n`nStäng Sandbox-fönstret innan du startar det här testet.",
            'Windows Sandbox används redan',
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Information
        ) | Out-Null
        return
    }

    $externalSandbox = Get-Process -Name 'WindowsSandboxClient' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($externalSandbox) {
        [Windows.MessageBox]::Show(
            $window,
            "En Windows Sandbox-session som inte startades av den aktuella What Switch?-körningen är redan öppen.`n`nDen kan inte få programmets mappningar i efterhand. Stäng den befintliga Sandboxen och försök igen.",
            'Windows Sandbox används redan',
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Information
        ) | Out-Null
        Set-WhatSwitchGuiStatus 'Stäng den befintliga Windows Sandbox-sessionen innan testet startas.' -Error
        return
    }

    $networkEnabled = [bool]$ui.SandboxNetworkCheck.IsChecked
    $networkText = if ($networkEnabled) {
        'Nätverk är AKTIVERAT. Installern kan nå internet och det lokala nätverket.'
    }
    else {
        'Nätverk är avstängt.'
    }
    $message = @"
En ny, temporär Windows Sandbox startas och kommandot körs automatiskt efter tre sekunder.

$networkText
Endast den valda installerfilen exponeras, via en skrivskyddad mapp. Urklipp och övriga enhetsomdirigeringar är avstängda.
$([string]::IsNullOrWhiteSpace($FollowUpCommand) ? '' : "`nEfter installationen kan avinstallationskommandot köras i samma session, från What Switch? eller Sandbox-konsolen.")

Fortsätt?
"@
    $answer = [Windows.MessageBox]::Show(
        $window,
        $message,
        'Testa kommando i Windows Sandbox',
        [Windows.MessageBoxButton]::YesNo,
        [Windows.MessageBoxImage]::Question,
        [Windows.MessageBoxResult]::No
    )
    if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }

    try {
        Set-WhatSwitchGuiStatus 'Förbereder Windows Sandbox…' -Busy
        $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
        $session = Start-WhatSwitchSandboxTest -InstallerPath $state.Path -Command $Command `
            -CommandShell $CommandShell -FollowUpCommand $FollowUpCommand -FollowUpShell $FollowUpShell `
            -DetectionCandidates @(Get-WhatSwitchDetectionCandidates -AnalysisResult $state.Result) `
            -ExpectedProductName ([string]$state.Result.ProductName) -ExpectedPublisher ([string]$state.Result.CompanyName) `
            -EnableNetworking:$networkEnabled
        $state.SandboxSession = $session
        $state.SandboxRequestPending = $false
        $state.SandboxRequestFromState = ''
        $state.LastSandboxState = ''
        Update-WhatSwitchSandboxButtons
        Set-WhatSwitchGuiStatus "Windows Sandbox startades. Sessionsfiler: $($session.SessionPath)"
    }
    catch {
        Set-WhatSwitchGuiStatus $_.Exception.Message -Error
        [Windows.MessageBox]::Show($window, $_.Exception.Message, 'Windows Sandbox kunde inte startas', 'OK', 'Warning') | Out-Null
    }
}

function Get-WhatSwitchGuiSandboxState {
    $session = $state.SandboxSession
    if ($null -eq $session -or -not $session.StatusPath) { return '' }
    try {
        if (-not (Test-Path -LiteralPath $session.StatusPath -PathType Leaf)) { return '' }
        return ([IO.File]::ReadAllText($session.StatusPath, [Text.Encoding]::UTF8)).Trim()
    }
    catch { return '' }
}

function Test-WhatSwitchGuiSandboxAlive {
    $session = $state.SandboxSession
    if ($null -eq $session -or -not $session.HeartbeatPath) { return $false }
    try {
        if (Test-Path -LiteralPath $session.HeartbeatPath -PathType Leaf) {
            if ((Get-Item -LiteralPath $session.HeartbeatPath).LastWriteTimeUtc -gt [DateTime]::UtcNow.AddSeconds(-4)) {
                return $true
            }
        }
        # The runner cannot update its heartbeat while an installer process owns the console.
        # During that interval, verify the exact Sandbox client captured when this session started.
        $sandboxState = Get-WhatSwitchGuiSandboxState
        if ($sandboxState -in 'Pending', 'Installing', 'Uninstalling') {
            $clientProperty = $session.PSObject.Properties['ClientProcessId']
            if ($clientProperty -and $clientProperty.Value) {
                $client = Get-Process -Id $clientProperty.Value -ErrorAction SilentlyContinue
                return $null -ne $client -and $client.ProcessName -eq 'WindowsSandboxClient'
            }
        }
        return $false
    }
    catch { return $false }
}

function Test-WhatSwitchGuiSandboxReady {
    $session = $state.SandboxSession
    if ($null -eq $session -or $state.SandboxRequestPending) { return $false }
    if ([string]::IsNullOrWhiteSpace($session.FollowUpCommand) -or -not $state.Path) { return $false }
    if (-not [string]::Equals($session.SourceInstallerPath, $state.Path, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $sandboxState = Get-WhatSwitchGuiSandboxState
    if ($sandboxState -notmatch '^Installed' -and $sandboxState -notmatch '^UninstallFailed') { return $false }
    return Test-WhatSwitchGuiSandboxAlive
}

function Update-WhatSwitchSandboxButtons {
    $ready = Test-WhatSwitchGuiSandboxReady
    $sandboxState = Get-WhatSwitchGuiSandboxState
    $session = $state.SandboxSession
    $sessionAlive = $null -ne $session -and (Test-WhatSwitchGuiSandboxAlive)
    foreach ($button in $state.SandboxInstallButtons) {
        $sameActiveCommand = $sessionAlive -and $state.Path -and
            [string]::Equals($session.SourceInstallerPath, $state.Path, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals($session.Command, [string]$button.Tag.Command, [StringComparison]::Ordinal) -and
            [string]::Equals($session.CommandShell, [string]$button.Tag.Shell, [StringComparison]::OrdinalIgnoreCase)
        $blockedByState = $sameActiveCommand -and (
            $sandboxState -in 'Pending', 'Installing', 'Uninstalling' -or
            $sandboxState -match '^Installed' -or
            $sandboxState -match '^UninstallFailed'
        )
        $button.IsEnabled = [bool]$button.Tag.BaseEnabled -and -not $blockedByState
        if ($blockedByState) {
            $button.ToolTip = if ($sandboxState -match '^Installed' -or $sandboxState -match '^UninstallFailed') {
                'Programmet är redan installerat i Sandbox. Testa avinstallationen först.'
            } else {
                'Den aktiva Sandbox-sessionen arbetar redan.'
            }
        }
        else {
            $button.ToolTip = 'Starta installationen i Sandbox. Avinstallation kan sedan testas i samma session.'
        }
    }
    foreach ($button in $state.SandboxUninstallButtons) {
        $button.IsEnabled = $ready
        $button.ToolTip = if ($ready) {
            if ($sandboxState -match '^UninstallFailed') {
                'Avinstallationen misslyckades senast. Försök igen i samma Sandbox-session.'
            } else {
                'Kör avinstallationskommandot i den aktiva Sandbox-sessionen.'
            }
        } elseif ($sandboxState -eq 'Installing') {
            'Väntar på att installationen i Sandbox ska bli klar.'
        } elseif ($sandboxState -match '^InstallFailed') {
            'Installationskommandot rapporterade ett fel; avinstallation aktiveras därför inte.'
        } elseif ($sandboxState -eq 'Uninstalling') {
            'Avinstallation pågår i den aktiva Sandbox-sessionen.'
        } elseif ($sandboxState -eq 'Uninstalled') {
            'Programmet har avinstallerats i den aktiva Sandbox-sessionen.'
        } else {
            'Starta först installationskommandot i Sandbox. Knappen aktiveras när installationen har lyckats.'
        }
    }
}

function Send-WhatSwitchGuiSandboxRequest {
    param([Parameter(Mandatory)][ValidateSet('Install', 'Uninstall')][string]$Action)

    $session = $state.SandboxSession
    if ($null -eq $session -or [string]::IsNullOrWhiteSpace($session.FollowUpCommand)) {
        Set-WhatSwitchGuiStatus 'Det finns ingen aktiv What Switch?-session med ett avinstallationskommando.' -Error
        return
    }
    try {
        if ($Action -eq 'Uninstall' -and -not (Test-WhatSwitchGuiSandboxReady)) {
            throw 'Programmet är inte markerat som installerat i en aktiv What Switch?-Sandbox.'
        }
        if ($Action -eq 'Install' -and -not (Test-WhatSwitchGuiSandboxAlive)) {
            throw 'What Switch?-Sandboxen svarar inte längre.'
        }
        if (-not (Test-Path -LiteralPath $session.ControlPath -PathType Leaf)) {
            throw 'Sessionsfilen finns inte längre. Sandbox-sessionen kan ha stängts.'
        }
        $currentState = Get-WhatSwitchGuiSandboxState
        $request = $Action + ':' + [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText($session.ControlPath, $request, [Text.UTF8Encoding]::new($false))
        $state.SandboxRequestPending = $true
        $state.SandboxRequestFromState = $currentState
        Update-WhatSwitchSandboxButtons
        $description = if ($Action -eq 'Install') { 'Installationskommandot' } else { 'Avinstallationskommandot' }
        Set-WhatSwitchGuiStatus "$description skickades till den aktiva Sandbox-sessionen."
    }
    catch {
        Set-WhatSwitchGuiStatus "Kunde inte begära avinstallation: $($_.Exception.Message)" -Error
    }
}

function Request-WhatSwitchGuiSandboxUninstall {
    Send-WhatSwitchGuiSandboxRequest -Action Uninstall
}

function Add-WhatSwitchCommandCard {
    param(
        [string]$Label,
        [string]$Command,
        [string]$SandboxCommand,
        [ValidateSet('Cmd', 'PowerShell')][string]$SandboxShell = 'Cmd',
        [AllowEmptyString()][string]$SandboxFollowUpCommand = '',
        [ValidateSet('Cmd', 'PowerShell')][string]$SandboxFollowUpShell = 'Cmd',
        [switch]$Catalog,
        [switch]$SandboxInstallAction,
        [switch]$ActiveSandboxUninstall,
        [switch]$DisableSandbox,
        [string]$SandboxDisabledReason = ''
    )

    $border = [Windows.Controls.Border]::new()
    $border.Background = if ($Catalog) { '#102A28' } else { '#10182A' }
    $border.BorderBrush = if ($Catalog) { '#285D54' } else { '#2B3858' }
    $border.BorderThickness = 1
    $border.CornerRadius = 9
    $border.Padding = 12
    $border.Margin = '0,0,0,9'

    $grid = [Windows.Controls.Grid]::new()
    [void]$grid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    $buttonColumn = [Windows.Controls.ColumnDefinition]::new()
    $buttonColumn.Width = 'Auto'
    [void]$grid.ColumnDefinitions.Add($buttonColumn)

    $content = [Windows.Controls.StackPanel]::new()
    $content.Margin = '0,0,12,0'
    $labelText = [Windows.Controls.TextBlock]::new()
    $labelText.Text = $Label
    $labelText.Foreground = if ($Catalog) { '#43D6A3' } else { '#8C9ABD' }
    $labelText.FontSize = 11
    $labelText.FontWeight = 'SemiBold'
    $commandText = [Windows.Controls.TextBlock]::new()
    $commandText.Text = $Command
    $commandText.Foreground = '#F2F5FF'
    $commandText.FontFamily = 'Cascadia Mono, Consolas'
    $commandText.FontSize = 12
    $commandText.TextWrapping = 'Wrap'
    $commandText.Margin = '0,5,0,0'
    [void]$content.Children.Add($labelText)
    [void]$content.Children.Add($commandText)

    $copyButton = [Windows.Controls.Button]::new()
    $copyButton.Content = 'Kopiera'
    $copyButton.Padding = '11,6'
    $copyButton.Margin = '0,0,0,6'
    $copyButton.Tag = $Command
    $copyButton.Add_Click({
        param($sender, $eventArgs)
        Set-WhatSwitchClipboard -Text ([string]$sender.Tag) -Description 'Kommandot'
    })
    $actionPanel = [Windows.Controls.StackPanel]::new()
    $actionPanel.VerticalAlignment = 'Center'
    [void]$actionPanel.Children.Add($copyButton)

    $sandboxButton = [Windows.Controls.Button]::new()
    $sandboxButton.Content = 'Testa i Sandbox'
    $sandboxButton.Padding = '11,6'
    $usableFollowUp = if ($SandboxFollowUpCommand -and $SandboxFollowUpCommand -notmatch '<[^>]+>') {
        $SandboxFollowUpCommand
    } else { '' }
    $hasPlaceholder = $SandboxCommand -match '<[^>]+>'
    $baseEnabled = -not $DisableSandbox -and -not [string]::IsNullOrWhiteSpace($SandboxCommand) -and -not $hasPlaceholder
    $sandboxButton.Tag = [pscustomobject]@{
        Command = $SandboxCommand
        Shell = $SandboxShell
        FollowUpCommand = $usableFollowUp
        FollowUpShell = $SandboxFollowUpShell
        BaseEnabled = $baseEnabled
        ActiveSandboxUninstall = [bool]$ActiveSandboxUninstall
    }
    $sandboxButton.IsEnabled = if ($ActiveSandboxUninstall) {
        $false
    } else {
        $baseEnabled
    }
    $sandboxButton.ToolTip = if ($hasPlaceholder) {
        'Kommandot innehåller en platshållare som måste ersättas innan det kan testas.'
    } elseif ($ActiveSandboxUninstall) {
        'Starta först installationskommandot i Sandbox. Knappen aktiveras när installationen har lyckats.'
    } elseif ($DisableSandbox) {
        if ($SandboxDisabledReason) { $SandboxDisabledReason } else { 'Det finns inget körbart kommando att testa.' }
    } elseif ($usableFollowUp) {
        'Starta installationen i Sandbox. Avinstallation kan sedan begäras i samma session.'
    } else {
        'Starta en isolerad Windows Sandbox och kör detta kommando.'
    }
    $sandboxButton.Add_Click({
        param($sender, $eventArgs)
        if ($sender.Tag.ActiveSandboxUninstall) {
            Request-WhatSwitchGuiSandboxUninstall
        }
        else {
            Invoke-WhatSwitchGuiSandboxTest -Command ([string]$sender.Tag.Command) -CommandShell ([string]$sender.Tag.Shell) `
                -FollowUpCommand ([string]$sender.Tag.FollowUpCommand) -FollowUpShell ([string]$sender.Tag.FollowUpShell)
        }
    })
    if ($SandboxInstallAction) { [void]$state.SandboxInstallButtons.Add($sandboxButton) }
    if ($ActiveSandboxUninstall) { [void]$state.SandboxUninstallButtons.Add($sandboxButton) }
    [void]$actionPanel.Children.Add($sandboxButton)
    [Windows.Controls.Grid]::SetColumn($actionPanel, 1)

    [void]$grid.Children.Add($content)
    [void]$grid.Children.Add($actionPanel)
    $border.Child = $grid
    [void]$ui.CommandPanel.Children.Add($border)
}

function Update-WhatSwitchCommands {
    $ui.CommandPanel.Children.Clear()
    $state.SandboxInstallButtons.Clear()
    $state.SandboxUninstallButtons.Clear()
    if ($null -eq $state.Result) { return }

    $usePowerShell = $ui.ShellSelector.SelectedIndex -eq 0
    $result = $state.Result
    $detectedInstall = $result.Commands | Where-Object Label -Match 'install' | Where-Object Label -NotMatch 'uninstall' | Select-Object -First 1
    $detectedUninstall = $result.Commands | Where-Object Label -Match 'uninstall' | Select-Object -First 1
    $preferredUninstall = if ($result.Catalog -and $result.Catalog.UninstallCommand) {
        $result.Catalog.UninstallCommand
    } elseif ($detectedUninstall) { $detectedUninstall.Command } else { '' }
    $preferredUninstallShell = if ($result.Catalog -and $result.Catalog.UninstallCommand) {
        'Cmd'
    } elseif ($result.Engine -eq 'msix') { 'PowerShell' } else { 'Cmd' }
    if ($result.Catalog) {
        $install = if ($usePowerShell) {
            ConvertTo-WhatSwitchPowerShellCommand $result.Catalog.InstallCommand
        } else { $result.Catalog.InstallCommand }
        Add-WhatSwitchCommandCard -Label 'KATALOG — INSTALLATION' -Command $install `
            -SandboxCommand $result.Catalog.InstallCommand -SandboxShell Cmd `
            -SandboxFollowUpCommand $preferredUninstall -SandboxFollowUpShell $preferredUninstallShell `
            -SandboxInstallAction -Catalog
        if ($result.Catalog.UninstallCommand) {
            $uninstall = if ($usePowerShell) {
                ConvertTo-WhatSwitchPowerShellCommand $result.Catalog.UninstallCommand
            } else { $result.Catalog.UninstallCommand }
            Add-WhatSwitchCommandCard -Label 'KATALOG — AVINSTALLATION' -Command $uninstall `
                -SandboxCommand $result.Catalog.UninstallCommand -SandboxShell Cmd -Catalog -ActiveSandboxUninstall
        }
    }

    foreach ($item in $result.Commands) {
        $command = if ($usePowerShell) { $item.PowerShellCommand } else { $item.Command }
        $sandboxShell = if ($result.Engine -eq 'msix') { 'PowerShell' } else { 'Cmd' }
        $isInstall = $item.Label -match 'install' -and $item.Label -notmatch 'uninstall'
        $isUninstall = $item.Label -match 'uninstall'
        if ($isUninstall) {
            Add-WhatSwitchCommandCard -Label ($item.Label.ToUpperInvariant()) -Command $command `
                -SandboxCommand $item.Command -SandboxShell $sandboxShell -ActiveSandboxUninstall
        }
        else {
            Add-WhatSwitchCommandCard -Label ($item.Label.ToUpperInvariant()) -Command $command `
                -SandboxCommand $item.Command -SandboxShell $sandboxShell `
                -SandboxFollowUpCommand $(if ($isInstall) { $preferredUninstall } else { '' }) `
                -SandboxFollowUpShell $preferredUninstallShell -SandboxInstallAction:$isInstall
        }
    }

    if (-not $result.Catalog -and @($result.Commands).Count -eq 0) {
        Add-WhatSwitchCommandCard -Label 'INGET SÄKERT KOMMANDO' `
            -Command 'Inga tillförlitliga switchar kunde fastställas statiskt.' -DisableSandbox
    }
    Update-WhatSwitchSandboxButtons
}

function Show-WhatSwitchResult {
    param($Result)

    $state.Result = $Result
    $ui.EmptyState.Visibility = 'Collapsed'
    $ui.ResultsScroll.Visibility = 'Visible'
    $ui.EngineText.Text = $Result.Label
    $ui.ResultFileText.Text = $Result.FileName
    $ui.ConfidenceText.Text = ('SÄKERHET: ' + $Result.Confidence.ToUpperInvariant())
    switch ($Result.Confidence) {
        'high' { $ui.ConfidenceBadge.Background = '#16372F'; $ui.ConfidenceText.Foreground = '#65E2B7' }
        'medium' { $ui.ConfidenceBadge.Background = '#3A301A'; $ui.ConfidenceText.Foreground = '#FFD178' }
        'low' { $ui.ConfidenceBadge.Background = '#402A20'; $ui.ConfidenceText.Foreground = '#FFB078' }
        default { $ui.ConfidenceBadge.Background = '#3A202B'; $ui.ConfidenceText.Foreground = '#FF91A5' }
    }

    $hasMetadata = $Result.ProductName -or $Result.CompanyName -or $Result.ProductVersion
    $ui.MetadataCard.Visibility = if ($hasMetadata) { 'Visible' } else { 'Collapsed' }
    $ui.ProductText.Text = if ($Result.ProductName) { $Result.ProductName } else { '—' }
    $publisher = @($Result.CompanyName, $Result.ProductVersion) | Where-Object { $_ }
    $ui.CompanyVersionText.Text = if ($publisher) { $publisher -join ' · ' } else { '—' }

    $ui.CatalogCard.Visibility = if ($Result.Catalog) { 'Visible' } else { 'Collapsed' }
    if ($Result.Catalog) {
        $ui.CatalogNameText.Text = $Result.Catalog.Name
        $ui.CatalogInstallText.Text = $Result.Catalog.InstallCommand
        $ui.CatalogNoteText.Text = $Result.Catalog.Note
    }

    $ui.WarningCard.Visibility = if ($Result.Warning) { 'Visible' } else { 'Collapsed' }
    $ui.WarningText.Text = $Result.Warning
    $ui.NotesText.Text = if ($Result.Notes) { $Result.Notes } else { 'Ingen ytterligare notering.' }
    $ui.ModifiersText.Text = if ($Result.Modifiers) { 'Modifierare: ' + $Result.Modifiers } else { '' }

    $ui.CandidatesExpander.Visibility = if ($Result.BestEffort) { 'Visible' } else { 'Collapsed' }
    if ($Result.BestEffort) {
        $flags = if (@($Result.BestEffort.Flags).Count) { $Result.BestEffort.Flags -join ', ' } else { 'inga' }
        $options = if (@($Result.BestEffort.Options).Count) { $Result.BestEffort.Options -join ', ' } else { 'inga' }
        $ui.CandidatesText.Text = "Flaggor: $flags`n`nAlternativ: $options`n`nVerifiera alltid kandidaterna i en test-VM."
    }

    $hasMsi = $null -ne $Result.Msi
    $ui.MsiExpander.Visibility = if ($hasMsi) { 'Visible' } else { 'Collapsed' }
    if ($hasMsi) {
        $publicProperties = @($Result.Msi.PublicProperties)
        $ui.MsiSummaryText.Text = "ProductCode: $($Result.Msi.ProductCode) · $($publicProperties.Count) publika egenskaper"
        $ui.MsiGrid.ItemsSource = $publicProperties
    }
    else {
        $ui.MsiGrid.ItemsSource = $null
    }

    Update-WhatSwitchCommands
    $ui.ResultsScroll.ScrollToTop()
}

function Clear-WhatSwitchGui {
    $state.Path = $null
    $state.Result = $null
    $ui.FileCard.Visibility = 'Collapsed'
    $ui.EmptyState.Visibility = 'Visible'
    $ui.ResultsScroll.Visibility = 'Collapsed'
    $ui.ReanalyzeButton.IsEnabled = $false
    $ui.ClearButton.IsEnabled = $false
    $ui.DeploymentGuideButton.IsEnabled = $false
    $ui.CommandPanel.Children.Clear()
    $ui.InputScroll.ScrollToTop()
    Set-WhatSwitchGuiStatus 'Redo — dra in en installer för att börja'
}

function Invoke-WhatSwitchGuiAnalysis {
    param([Parameter(Mandatory)][string]$LiteralPath)

    if ($state.IsBusy) { return }
    try {
        $resolvedPath = (Resolve-Path -LiteralPath $LiteralPath -ErrorAction Stop).Path
        $file = Get-Item -LiteralPath $resolvedPath -ErrorAction Stop
        if ($file.PSIsContainer) { throw 'Mappar stöds inte. Släpp en installerfil.' }
        if ($file.Extension.ToLowerInvariant() -notin $supportedExtensions) {
            throw "Filtypen '$($file.Extension)' stöds inte. Välj EXE, MSI, MSP, MSIX eller AppX."
        }

        $state.Path = $resolvedPath
        $ui.FileNameText.Text = $file.Name
        $ui.FilePathText.Text = $resolvedPath
        $ui.FileSizeText.Text = Format-WhatSwitchFileSize $file.Length
        $ui.FileCard.Visibility = 'Visible'
        $ui.ReanalyzeButton.IsEnabled = $false
        $ui.ClearButton.IsEnabled = $false
        $ui.DeploymentGuideButton.IsEnabled = $false
        Set-WhatSwitchGuiStatus "Analyserar $($file.Name)…" -Busy
        $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)

        $result = Get-WhatSwitchResult -Path $resolvedPath -IncludeBestEffort:$ui.BestEffortCheck.IsChecked
        Show-WhatSwitchResult $result
        $ui.ReanalyzeButton.IsEnabled = $true
        $ui.ClearButton.IsEnabled = $true
        $ui.DeploymentGuideButton.IsEnabled = $true
        Set-WhatSwitchGuiStatus "Klart — $($result.Label), säkerhet $($result.Confidence)"
    }
    catch {
        $ui.ReanalyzeButton.IsEnabled = [bool]$state.Path
        $ui.ClearButton.IsEnabled = [bool]$state.Path
        Set-WhatSwitchGuiStatus $_.Exception.Message -Error
        [Windows.MessageBox]::Show($window, $_.Exception.Message, 'What Switch? kunde inte analysera filen', 'OK', 'Warning') | Out-Null
    }
}

$ui.DropZone.Add_DragEnter({
    param($sender, $eventArgs)
    $valid = $eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)
    $eventArgs.Effects = if ($valid) { [Windows.DragDropEffects]::Copy } else { [Windows.DragDropEffects]::None }
    Set-WhatSwitchDropHighlight $valid
    $eventArgs.Handled = $true
})
$ui.DropZone.Add_DragOver({
    param($sender, $eventArgs)
    $eventArgs.Effects = if ($eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
        [Windows.DragDropEffects]::Copy
    } else { [Windows.DragDropEffects]::None }
    $eventArgs.Handled = $true
})
$ui.DropZone.Add_DragLeave({ Set-WhatSwitchDropHighlight $false })
$ui.DropZone.Add_Drop({
    param($sender, $eventArgs)
    Set-WhatSwitchDropHighlight $false
    if (-not $eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { return }
    $dropped = @($eventArgs.Data.GetData([Windows.DataFormats]::FileDrop))
    $candidate = $dropped | Where-Object { [IO.Path]::GetExtension($_).ToLowerInvariant() -in $supportedExtensions } | Select-Object -First 1
    if ($candidate) {
        Invoke-WhatSwitchGuiAnalysis -LiteralPath $candidate
    }
    else {
        Set-WhatSwitchGuiStatus 'Ingen installerfil hittades i det som släpptes.' -Error
    }
})
$ui.BrowseButton.Add_Click({
    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Title = 'Välj en Windows-installer'
    $dialog.Filter = 'Windows-installers|*.exe;*.msi;*.msp;*.msix;*.appx;*.msixbundle;*.appxbundle|Alla filer|*.*'
    $dialog.Multiselect = $false
    if ($dialog.ShowDialog($window)) { Invoke-WhatSwitchGuiAnalysis -LiteralPath $dialog.FileName }
})
$ui.ReanalyzeButton.Add_Click({ if ($state.Path) { Invoke-WhatSwitchGuiAnalysis -LiteralPath $state.Path } })
$ui.ClearButton.Add_Click({ Clear-WhatSwitchGui })
$ui.ShellSelector.Add_SelectionChanged({ if ($state.Result) { Update-WhatSwitchCommands } })
$ui.DeploymentGuideButton.Add_Click({
    if (-not $state.Result -or $state.IsBusy) { return }
    $export = Show-WhatSwitchDeploymentWizard -Owner $window -AnalysisResult $state.Result -GuiState $state `
        -StartSandboxAction {
            param($installCommand, $uninstallCommand)
            Invoke-WhatSwitchGuiSandboxTest -Command ([string]$installCommand) -CommandShell Cmd `
                -FollowUpCommand ([string]$uninstallCommand) -FollowUpShell Cmd
        }
    if ($export) { Set-WhatSwitchGuiStatus "Deploymentpaketet skapades: $($export.Path)" }
})
$ui.CopyJsonButton.Add_Click({
    if ($state.Result) { Set-WhatSwitchClipboard -Text ($state.Result | ConvertTo-Json -Depth 20) -Description 'JSON-resultatet' }
})
$ui.SaveJsonButton.Add_Click({
    if (-not $state.Result) { return }
    $dialog = [Microsoft.Win32.SaveFileDialog]::new()
    $dialog.Title = 'Spara analysresultat'
    $dialog.Filter = 'JSON-fil|*.json'
    $dialog.FileName = ([IO.Path]::GetFileNameWithoutExtension($state.Result.FileName) + '-switchhunt.json')
    if ($dialog.ShowDialog($window)) {
        $state.Result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $dialog.FileName -Encoding utf8
        Set-WhatSwitchGuiStatus "Resultatet sparades till $($dialog.FileName)."
    }
})

$window.Add_ContentRendered({
    if ($Path) { Invoke-WhatSwitchGuiAnalysis -LiteralPath $Path }
})

$sandboxStatusTimer = [Windows.Threading.DispatcherTimer]::new()
$sandboxStatusTimer.Interval = [TimeSpan]::FromMilliseconds(750)
$sandboxStatusTimer.Add_Tick({
    if ($null -eq $state.SandboxSession) { return }
    $sandboxState = Get-WhatSwitchGuiSandboxState
    if ($state.SandboxRequestPending -and $sandboxState -ne $state.SandboxRequestFromState) {
        $state.SandboxRequestPending = $false
        $state.SandboxRequestFromState = ''
    }
    if ($sandboxState -ne $state.LastSandboxState) {
        $state.LastSandboxState = $sandboxState
        switch -Regex ($sandboxState) {
            '^Installed$' { Set-WhatSwitchGuiStatus 'Installationen och detektionsregeln verifierades i Sandbox. Avinstallationsknappen är nu aktiv.' }
            '^InstalledUnverified$' { Set-WhatSwitchGuiStatus 'Installationen avslutades utan fel, men ingen detektionsregel kunde verifieras.' -Error }
            '^InstallFailed:(.+)$' { Set-WhatSwitchGuiStatus "Installationen misslyckades i Sandbox (slutkod $($Matches[1]))." -Error }
            '^Uninstalling$' { Set-WhatSwitchGuiStatus 'Avinstallation pågår i Sandbox…' -Busy }
            '^Uninstalled$' { Set-WhatSwitchGuiStatus 'Avinstallationen lyckades i Sandbox.' }
            '^UninstallUnverified$' { Set-WhatSwitchGuiStatus 'Avinstallationen avslutades utan fel men kunde inte verifieras.' -Error }
            '^UninstallFailed:(.+)$' { Set-WhatSwitchGuiStatus "Avinstallationen misslyckades i Sandbox (slutkod $($Matches[1]))." -Error }
        }
    }
    Update-WhatSwitchSandboxButtons
})
$sandboxStatusTimer.Start()
$window.Add_Closed({ $sandboxStatusTimer.Stop() })

if ($ValidateOnly) {
    if ($Path) {
        Invoke-WhatSwitchGuiAnalysis -LiteralPath $Path
        if ($null -eq $state.Result) { throw 'GUI-valideringen kunde inte rendera ett analysresultat.' }
    }
    $resultSuffix = if ($state.Result) { ", rendered $($state.Result.Engine) result" } else { '' }
    Write-Output "What Switch? GUI validation passed ($($ui.Count) named controls$resultSuffix)."
    return
}

[void]$window.ShowDialog()
