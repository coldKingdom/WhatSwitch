#requires -Version 7.6

Set-StrictMode -Version Latest

function New-WhatSwitchSandboxSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$InstallerPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Command,

        [ValidateSet('Cmd', 'PowerShell')]
        [string]$CommandShell = 'Cmd',

        [AllowEmptyString()]
        [string]$FollowUpCommand = '',

        [ValidateSet('Cmd', 'PowerShell')]
        [string]$FollowUpShell = 'Cmd',

        [object[]]$DetectionCandidates = @(),

        [AllowEmptyString()][string]$ExpectedProductName = '',

        [AllowEmptyString()][string]$ExpectedPublisher = '',

        [switch]$EnableNetworking,

        [string]$SessionRoot = (Join-Path ([IO.Path]::GetTempPath()) 'WhatSwitchSandbox')
    )

    $resolvedInstaller = (Resolve-Path -LiteralPath $InstallerPath).Path
    $rootPath = [IO.Path]::GetFullPath($SessionRoot)
    [void](New-Item -ItemType Directory -Path $rootPath -Force)

    # Sessions contain a hard link or copy of the selected installer. Remove only old, validated
    # child directories below our dedicated temp root so abandoned sessions do not retain disk data.
    $rootPrefix = $rootPath.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    Get-ChildItem -LiteralPath $rootPath -Directory -ErrorAction SilentlyContinue |
        Where-Object LastWriteTimeUtc -LT ([DateTime]::UtcNow.AddDays(-1)) |
        ForEach-Object {
            $candidate = [IO.Path]::GetFullPath($_.FullName)
            if ($candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

    $sessionPath = Join-Path $rootPath ([guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $sessionPath)
    try {
        $sourceFile = Get-Item -LiteralPath $resolvedInstaller
        $sandboxInstallerPath = Join-Path $sessionPath $sourceFile.Name

        # A hard link exposes only this file and avoids copying large installers. Fall back to a
        # normal copy when the source and temp directory are on different volumes or filesystems.
        try {
            [void](New-Item -ItemType HardLink -Path $sandboxInstallerPath -Target $resolvedInstaller -ErrorAction Stop)
            $stagingMethod = 'HardLink'
        }
        catch {
            Copy-Item -LiteralPath $resolvedInstaller -Destination $sandboxInstallerPath -Force
            $stagingMethod = 'Copy'
        }

        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
        $encodedFollowUp = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($FollowUpCommand))
        $encodedExpectedProductName = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ExpectedProductName))
        $encodedExpectedPublisher = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ExpectedPublisher))
        $detectionCandidatesJson = if (@($DetectionCandidates).Count) {
            @($DetectionCandidates) | ConvertTo-Json -Depth 20 -Compress
        } else { '[]' }
        $encodedDetectionCandidates = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($detectionCandidatesJson))
        $hasFollowUp = -not [string]::IsNullOrWhiteSpace($FollowUpCommand)
        $controlDirectory = Join-Path $sessionPath 'Control'
        [void](New-Item -ItemType Directory -Path $controlDirectory)
        $controlPath = Join-Path $controlDirectory 'WhatSwitch.control'
        $statusPath = Join-Path $controlDirectory 'WhatSwitch.status'
        $heartbeatPath = Join-Path $controlDirectory 'WhatSwitch.heartbeat'
        $detectionReportPath = Join-Path $controlDirectory 'WhatSwitch.detection.json'
        $selectedDetectionPath = Join-Path $controlDirectory 'WhatSwitch.selected-detection.json'
        [IO.File]::WriteAllText($controlPath, '', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($statusPath, 'Pending', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($heartbeatPath, '', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($detectionReportPath, '{"schemaVersion":1,"status":"pending","candidates":[]}', [Text.UTF8Encoding]::new($false))
        $networkDescription = if ($EnableNetworking) { 'AKTIVERAT' } else { 'AVSTÄNGT' }
        $runner = @"
`$ErrorActionPreference = 'Continue'
`$Host.UI.RawUI.WindowTitle = 'What Switch? Sandbox-test'
Clear-Host
Write-Host 'What Switch? — test av installerkommando' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor DarkCyan
Write-Host 'Den valda installern är mappad skrivskyddat till C:\WhatSwitch.'
Write-Host 'Nätverk: $networkDescription'
Write-Host 'Allt i Sandbox raderas permanent när fönstret stängs.'
Write-Host
`$command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$encodedCommand'))
`$followUpCommand = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$encodedFollowUp'))
`$staticDetectionJson = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$encodedDetectionCandidates'))
`$staticDetectionCandidates = if (`$staticDetectionJson -eq '[]' -or [string]::IsNullOrWhiteSpace(`$staticDetectionJson)) {
    @()
} else {
    @(`$staticDetectionJson | ConvertFrom-Json)
}
`$expectedProductName = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$encodedExpectedProductName'))
`$expectedPublisher = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$encodedExpectedPublisher'))
`$hasFollowUp = `$$($hasFollowUp.ToString().ToLowerInvariant())
`$controlPath = 'C:\WhatSwitchControl\WhatSwitch.control'
`$statusPath = 'C:\WhatSwitchControl\WhatSwitch.status'
`$heartbeatPath = 'C:\WhatSwitchControl\WhatSwitch.heartbeat'
`$detectionReportPath = 'C:\WhatSwitchControl\WhatSwitch.detection.json'
`$selectedDetectionPath = 'C:\WhatSwitchControl\WhatSwitch.selected-detection.json'
`$lastRequest = ''

function Set-WhatSwitchSandboxState {
    param([string]`$State)
    [IO.File]::WriteAllText(`$statusPath, `$State, [Text.UTF8Encoding]::new(`$false))
}

function Update-WhatSwitchHeartbeat {
    try {
        [IO.File]::WriteAllText(`$heartbeatPath, [DateTime]::UtcNow.ToString('O'), [Text.UTF8Encoding]::new(`$false))
    }
    catch { }
}

function Get-WhatSwitchUninstallSnapshot {
    `$items = @()
    foreach (`$path in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        `$items += @(Get-ItemProperty -Path `$path -ErrorAction SilentlyContinue | Where-Object DisplayName | ForEach-Object {
            [pscustomobject]@{
                keyPath = (`$_.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '')
                displayName = [string]`$_.DisplayName
                displayVersion = [string]`$_.DisplayVersion
                publisher = [string]`$_.Publisher
                uninstallString = [string]`$_.UninstallString
                quietUninstallString = [string]`$_.QuietUninstallString
            }
        })
    }
    return @(`$items)
}

function Get-WhatSwitchProgramDirectories {
    `$directories = @()
    foreach (`$root in @(`$env:ProgramFiles, `${env:ProgramFiles(x86)})) {
        if (`$root -and (Test-Path -LiteralPath `$root -PathType Container)) {
            `$directories += @(Get-ChildItem -LiteralPath `$root -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object FullName)
        }
    }
    return @(`$directories | Sort-Object -Unique)
}

function ConvertTo-WhatSwitchRegistryPath {
    param([string]`$Path)
    if (`$Path -match '^HKEY_LOCAL_MACHINE\\') { return 'HKLM:\' + `$Path.Substring(19) }
    if (`$Path -match '^HKEY_CURRENT_USER\\') { return 'HKCU:\' + `$Path.Substring(18) }
    return `$Path
}

function Test-WhatSwitchDetectionRule {
    param(`$Rule)
    if (`$null -eq `$Rule) { return `$false }
    try {
        switch ([string]`$Rule.type) {
            'Msi' {
                `$code = [string]`$Rule.productCode
                return [bool](
                    (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\`$code") -or
                    (Test-Path -LiteralPath "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\`$code")
                )
            }
            'File' {
                `$path = [Environment]::ExpandEnvironmentVariables([string]`$Rule.path)
                `$target = if (`$Rule.fileOrFolder) { Join-Path `$path ([string]`$Rule.fileOrFolder) } else { `$path }
                return Test-Path -LiteralPath `$target
            }
            'Registry' {
                `$path = ConvertTo-WhatSwitchRegistryPath ([string]`$Rule.keyPath)
                if (-not (Test-Path -LiteralPath `$path)) { return `$false }
                if (`$Rule.valueName) {
                    `$value = Get-ItemPropertyValue -LiteralPath `$path -Name ([string]`$Rule.valueName) -ErrorAction SilentlyContinue
                    return `$null -ne `$value
                }
                return `$true
            }
        }
    }
    catch { return `$false }
    return `$false
}

`$beforeUninstall = @(Get-WhatSwitchUninstallSnapshot)
`$beforeProgramDirectories = @(Get-WhatSwitchProgramDirectories)

function Save-WhatSwitchDetectionReport {
    param([ValidateSet('Installed', 'Uninstalled')][string]`$Phase)

    `$dynamicCandidates = @()
    `$afterUninstall = @(Get-WhatSwitchUninstallSnapshot)
    `$beforeKeys = @(`$beforeUninstall | ForEach-Object keyPath)
    foreach (`$entry in `$afterUninstall | Where-Object { `$_.keyPath -notin `$beforeKeys }) {
        `$priority = 200
        if (`$expectedProductName -and (
            `$entry.displayName.IndexOf(`$expectedProductName, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            `$expectedProductName.IndexOf(`$entry.displayName, [StringComparison]::OrdinalIgnoreCase) -ge 0
        )) { `$priority += 40 }
        if (`$expectedPublisher -and `$entry.publisher.IndexOf(`$expectedPublisher, [StringComparison]::OrdinalIgnoreCase) -ge 0) { `$priority += 10 }
        `$dynamicCandidates += [pscustomobject]@{
            id = 'sandbox-registry-' + [guid]::NewGuid().ToString('N')
            type = 'Registry'
            displayName = "Registerpost: `$(`$entry.displayName)"
            source = 'Windows Sandbox'
            priority = `$priority
            verified = `$true
            keyPath = `$entry.keyPath
            valueName = 'DisplayName'
            detectionMethod = 'exists'
            displayVersion = `$entry.displayVersion
            publisher = `$entry.publisher
            uninstallString = `$entry.uninstallString
            quietUninstallString = `$entry.quietUninstallString
        }
    }
    `$afterProgramDirectories = @(Get-WhatSwitchProgramDirectories)
    foreach (`$directory in `$afterProgramDirectories | Where-Object { `$_ -notin `$beforeProgramDirectories }) {
        `$directoryPriority = if (`$expectedProductName -and (Split-Path -Leaf `$directory).IndexOf(`$expectedProductName, [StringComparison]::OrdinalIgnoreCase) -ge 0) { 140 } else { 100 }
        `$dynamicCandidates += [pscustomobject]@{
            id = 'sandbox-file-' + [guid]::NewGuid().ToString('N')
            type = 'File'
            displayName = "Installationsmapp: `$directory"
            source = 'Windows Sandbox'
            priority = `$directoryPriority
            verified = `$true
            path = Split-Path -Parent `$directory
            fileOrFolder = Split-Path -Leaf `$directory
            detectionMethod = 'exists'
            operator = 'exists'
            value = ''
            is32BitOn64System = `$false
        }
    }

    `$allCandidates = @(`$staticDetectionCandidates) + @(`$dynamicCandidates)
    foreach (`$candidate in `$allCandidates) {
        `$verified = Test-WhatSwitchDetectionRule `$candidate
        `$candidate | Add-Member -NotePropertyName verified -NotePropertyValue `$verified -Force
    }
    `$selected = @(`$allCandidates | Where-Object verified | Sort-Object @{ Expression = {
        if (`$_.PSObject.Properties['priority']) { return [int]`$_.priority }
        switch ([string]`$_.type) { 'Msi' { 400 }; 'File' { if (`$_.source -eq 'Katalog') { 300 } else { 100 } }; 'Registry' { 200 }; default { 0 } }
    }; Descending = `$true }) | Select-Object -First 1
    `$report = [pscustomobject]@{
        schemaVersion = 1
        status = `$Phase.ToLowerInvariant()
        testedAt = [DateTime]::UtcNow.ToString('O')
        installedVerified = `$Phase -eq 'Installed' -and `$null -ne `$selected
        uninstalledVerified = `$Phase -eq 'Uninstalled'
        selected = `$selected
        candidates = @(`$allCandidates)
    }
    [IO.File]::WriteAllText(`$detectionReportPath, (`$report | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new(`$false))
    return `$selected
}

# Keep liveness independent of MSI/EXE execution. The main runner is blocked while it waits for an
# installer process, but this background job continues updating the host-visible heartbeat.
`$heartbeatJob = `$null
if (`$hasFollowUp) {
    `$heartbeatJob = Start-Job -ScriptBlock {
        param([string]`$Path)
        while (`$true) {
            try {
                [IO.File]::WriteAllText(`$Path, [DateTime]::UtcNow.ToString('O'), [Text.UTF8Encoding]::new(`$false))
            }
            catch { }
            Start-Sleep -Seconds 1
        }
    } -ArgumentList `$heartbeatPath
}

function Invoke-WhatSwitchTestCommand {
    param([string]`$Text, [string]`$Mode, [string]`$Title)
    Write-Host
    Write-Host `$Title -ForegroundColor Yellow
    Write-Host `$Text -ForegroundColor White
    Write-Host
    `$script:lastExitCode = 0
    try {
        if (`$Mode -eq 'PowerShell') {
            & ([scriptblock]::Create(`$Text))
            if (-not `$?) { `$script:lastExitCode = 1 }
        }
        else {
            & `$env:ComSpec /d /s /c `$Text
            `$script:lastExitCode = `$LASTEXITCODE
        }
    }
    catch {
        `$script:lastExitCode = 1
        Write-Error (`$_ | Out-String)
    }
    Write-Host
    Write-Host ('Processens slutkod: ' + `$script:lastExitCode) -ForegroundColor `$(if (`$script:lastExitCode -eq 0) { 'Green' } else { 'Red' })
}

function Invoke-WhatSwitchInstall {
    Set-WhatSwitchSandboxState 'Installing'
    Invoke-WhatSwitchTestCommand -Text `$command -Mode '$CommandShell' -Title 'Kör installation/testkommando'
    if (`$script:lastExitCode -in 0, 1641, 3010) {
        `$verifiedRule = Save-WhatSwitchDetectionReport -Phase Installed
        if (`$verifiedRule) { Set-WhatSwitchSandboxState 'Installed' }
        else { Set-WhatSwitchSandboxState 'InstalledUnverified' }
    }
    else { Set-WhatSwitchSandboxState ('InstallFailed:' + `$script:lastExitCode) }
}

function Invoke-WhatSwitchUninstall {
    Set-WhatSwitchSandboxState 'Uninstalling'
    Invoke-WhatSwitchTestCommand -Text `$followUpCommand -Mode '$FollowUpShell' -Title 'Kör avinstallationskommando'
    if (`$script:lastExitCode -notin 0, 1641, 3010) {
        Set-WhatSwitchSandboxState ('UninstallFailed:' + `$script:lastExitCode)
        return
    }
    `$selectedRule = `$null
    if (Test-Path -LiteralPath `$selectedDetectionPath -PathType Leaf) {
        `$selectedRule = Get-Content -LiteralPath `$selectedDetectionPath -Raw | ConvertFrom-Json
    }
    elseif (Test-Path -LiteralPath `$detectionReportPath -PathType Leaf) {
        `$selectedRule = (Get-Content -LiteralPath `$detectionReportPath -Raw | ConvertFrom-Json).selected
    }
    if (`$selectedRule -and (Test-WhatSwitchDetectionRule `$selectedRule)) {
        Set-WhatSwitchSandboxState 'UninstallFailed:DetectionStillPresent'
    }
    elseif (`$selectedRule) {
        [void](Save-WhatSwitchDetectionReport -Phase Uninstalled)
        Set-WhatSwitchSandboxState 'Uninstalled'
    }
    else {
        Set-WhatSwitchSandboxState 'UninstallUnverified'
    }
}

Write-Host 'Installationskommando:' -ForegroundColor Yellow
Write-Host `$command -ForegroundColor White
Write-Host
Write-Warning 'Kommandot körs automatiskt om 3 sekunder. Tryck Ctrl+C för att avbryta.'
Start-Sleep -Seconds 3
Set-Location -LiteralPath 'C:\WhatSwitch'
Invoke-WhatSwitchInstall

if (`$hasFollowUp) {
    Write-Host
    Write-Host 'Avinstallationskommandot är förberett i samma Sandbox.' -ForegroundColor Cyan
    Write-Host 'Tryck U för att avinstallera, I för att köra installationen igen eller Q för att sluta lyssna.' -ForegroundColor Cyan
    Write-Host 'När installationen lyckats aktiveras "Testa i Sandbox" på avinstallationskortet i What Switch?.' -ForegroundColor DarkGray
    while (`$true) {
        if (-not `$heartbeatJob -or `$heartbeatJob.State -ne 'Running') { Update-WhatSwitchHeartbeat }
        `$request = Get-Content -LiteralPath `$controlPath -Raw -ErrorAction SilentlyContinue
        if (`$request -and `$request -ne `$lastRequest) {
            `$lastRequest = `$request
            `$requestAction = (`$request -split ':', 2)[0]
            if (`$requestAction -eq 'Install') {
                `$currentState = Get-Content -LiteralPath `$statusPath -Raw -ErrorAction SilentlyContinue
                if (`$currentState -match '^Installed' -or `$currentState -match '^UninstallFailed') {
                    Write-Warning 'Programmet är redan installerat. Avinstallera det innan installationen körs igen.'
                }
                else {
                    Invoke-WhatSwitchInstall
                    Write-Host 'Installationskommandot kördes igen på begäran från What Switch?.' -ForegroundColor Cyan
                }
            }
            else {
                Invoke-WhatSwitchUninstall
                Write-Host 'Avinstallationskommandot kördes på begäran från What Switch?.' -ForegroundColor Cyan
            }
            Write-Host 'Tryck I för att installera igen, U för att avinstallera eller Q.' -ForegroundColor Cyan
        }

        try {
            if ([Console]::KeyAvailable) {
                `$key = [Console]::ReadKey(`$true).Key
                if (`$key -eq [ConsoleKey]::U) {
                    Invoke-WhatSwitchUninstall
                    Write-Host 'Tryck U, I eller Q.' -ForegroundColor Cyan
                }
                elseif (`$key -eq [ConsoleKey]::I) {
                    `$currentState = Get-Content -LiteralPath `$statusPath -Raw -ErrorAction SilentlyContinue
                    if (`$currentState -match '^Installed' -or `$currentState -match '^UninstallFailed') {
                        Write-Warning 'Programmet är redan installerat. Tryck U och avinstallera det först.'
                    }
                    else { Invoke-WhatSwitchInstall }
                    Write-Host 'Tryck U, I eller Q.' -ForegroundColor Cyan
                }
                elseif (`$key -eq [ConsoleKey]::Q) {
                    if (`$heartbeatJob) { Stop-Job -Job `$heartbeatJob -ErrorAction SilentlyContinue }
                    break
                }
            }
        }
        catch { }
        Start-Sleep -Milliseconds 500
    }
}
else {
    Write-Host
    Write-Host 'Inget användbart avinstallationskommando identifierades för den här installern.' -ForegroundColor DarkYellow
}
Write-Host
Write-Host 'PowerShell-fönstret lämnas öppet så att resultatet kan granskas.' -ForegroundColor DarkGray
"@
        $runnerPath = Join-Path $sessionPath 'Run-WhatSwitchTest.ps1'
        [IO.File]::WriteAllText($runnerPath, $runner, [Text.UTF8Encoding]::new($true))

        $document = [Xml.XmlDocument]::new()
        $configuration = $document.CreateElement('Configuration')
        [void]$document.AppendChild($configuration)
        $settings = [ordered]@{
            VGpu = 'Disable'
            Networking = if ($EnableNetworking) { 'Enable' } else { 'Disable' }
            AudioInput = 'Disable'
            VideoInput = 'Disable'
            PrinterRedirection = 'Disable'
            ClipboardRedirection = 'Disable'
            MemoryInMB = '4096'
        }
        foreach ($setting in $settings.GetEnumerator()) {
            $element = $document.CreateElement($setting.Key)
            $element.InnerText = $setting.Value
            [void]$configuration.AppendChild($element)
        }

        $mappedFolders = $document.CreateElement('MappedFolders')
        $mappedFolder = $document.CreateElement('MappedFolder')
        foreach ($mapping in ([ordered]@{
            HostFolder = $sessionPath
            SandboxFolder = 'C:\WhatSwitch'
            ReadOnly = 'true'
        }).GetEnumerator()) {
            $element = $document.CreateElement($mapping.Key)
            $element.InnerText = $mapping.Value
            [void]$mappedFolder.AppendChild($element)
        }
        [void]$mappedFolders.AppendChild($mappedFolder)
        $controlMappedFolder = $document.CreateElement('MappedFolder')
        foreach ($mapping in ([ordered]@{
            HostFolder = $controlDirectory
            SandboxFolder = 'C:\WhatSwitchControl'
            ReadOnly = 'false'
        }).GetEnumerator()) {
            $element = $document.CreateElement($mapping.Key)
            $element.InnerText = $mapping.Value
            [void]$controlMappedFolder.AppendChild($element)
        }
        [void]$mappedFolders.AppendChild($controlMappedFolder)
        [void]$configuration.AppendChild($mappedFolders)

        $logon = $document.CreateElement('LogonCommand')
        $logonCommand = $document.CreateElement('Command')
        $logonCommand.InnerText = 'powershell.exe -NoLogo -NoExit -ExecutionPolicy Bypass -File C:\WhatSwitch\Run-WhatSwitchTest.ps1'
        [void]$logon.AppendChild($logonCommand)
        [void]$configuration.AppendChild($logon)

        $configPath = Join-Path $sessionPath 'WhatSwitchTest.wsb'
        $writerSettings = [Xml.XmlWriterSettings]::new()
        $writerSettings.Indent = $true
        $writerSettings.Encoding = [Text.UTF8Encoding]::new($false)
        $writer = [Xml.XmlWriter]::Create($configPath, $writerSettings)
        try { $document.Save($writer) } finally { $writer.Dispose() }

        [pscustomobject]@{
            PSTypeName = 'WhatSwitch.SandboxSession'
            SessionPath = $sessionPath
            ConfigurationPath = $configPath
            RunnerPath = $runnerPath
            InstallerPath = $sandboxInstallerPath
            SourceInstallerPath = $resolvedInstaller
            Command = $Command
            CommandShell = $CommandShell
            FollowUpCommand = $FollowUpCommand
            FollowUpShell = $FollowUpShell
            ExpectedProductName = $ExpectedProductName
            ExpectedPublisher = $ExpectedPublisher
            ControlPath = $controlPath
            StatusPath = $statusPath
            HeartbeatPath = $heartbeatPath
            DetectionReportPath = $detectionReportPath
            SelectedDetectionPath = $selectedDetectionPath
            NetworkingEnabled = [bool]$EnableNetworking
            StagingMethod = $stagingMethod
        }
    }
    catch {
        if (Test-Path -LiteralPath $sessionPath) {
            $candidate = [IO.Path]::GetFullPath($sessionPath)
            if ($candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        throw
    }
}

function Start-WhatSwitchSandboxTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string]$Command,
        [ValidateSet('Cmd', 'PowerShell')][string]$CommandShell = 'Cmd',
        [AllowEmptyString()][string]$FollowUpCommand = '',
        [ValidateSet('Cmd', 'PowerShell')][string]$FollowUpShell = 'Cmd',
        [object[]]$DetectionCandidates = @(),
        [AllowEmptyString()][string]$ExpectedProductName = '',
        [AllowEmptyString()][string]$ExpectedPublisher = '',
        [switch]$EnableNetworking
    )

    $sandboxExecutable = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
    if (-not (Test-Path -LiteralPath $sandboxExecutable -PathType Leaf)) {
        throw 'Windows Sandbox hittades inte. Aktivera "Windows Sandbox" under Aktivera eller inaktivera Windows-funktioner och starta om datorn.'
    }

    if (Get-Process -Name 'WindowsSandboxClient' -ErrorAction SilentlyContinue | Select-Object -First 1) {
        throw 'En Windows Sandbox-session är redan öppen. Stäng den innan en ny What Switch?-session startas.'
    }

    $session = New-WhatSwitchSandboxSession -InstallerPath $InstallerPath -Command $Command `
        -CommandShell $CommandShell -FollowUpCommand $FollowUpCommand -FollowUpShell $FollowUpShell `
        -DetectionCandidates $DetectionCandidates `
        -ExpectedProductName $ExpectedProductName -ExpectedPublisher $ExpectedPublisher `
        -EnableNetworking:$EnableNetworking
    try {
        $process = Start-Process -FilePath $sandboxExecutable -ArgumentList ('"' + $session.ConfigurationPath + '"') -PassThru
        $session | Add-Member -NotePropertyName ProcessId -NotePropertyValue $process.Id
        $clientProcess = $null
        $clientDeadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            $clientProcess = Get-Process -Name 'WindowsSandboxClient' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($clientProcess) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $clientDeadline)
        $session | Add-Member -NotePropertyName ClientProcessId -NotePropertyValue $(if ($clientProcess) { $clientProcess.Id } else { $null })
        return $session
    }
    catch {
        throw "Windows Sandbox kunde inte startas. Kontrollera att funktionen är aktiverad och att ingen annan Sandbox-session blockerar starten. $($_.Exception.Message)"
    }
}

function Get-WhatSwitchSandboxDetectionReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    if (-not $Session.DetectionReportPath -or -not (Test-Path -LiteralPath $Session.DetectionReportPath -PathType Leaf)) {
        return $null
    }
    try { Get-Content -LiteralPath $Session.DetectionReportPath -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { return $null }
}

function Set-WhatSwitchSandboxDetectionRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$DetectionRule
    )

    if (-not $Session.SelectedDetectionPath) { throw 'Sandbox-sessionen saknar sökväg för vald detektionsregel.' }
    [IO.File]::WriteAllText(
        [string]$Session.SelectedDetectionPath,
        ($DetectionRule | ConvertTo-Json -Depth 20),
        [Text.UTF8Encoding]::new($false)
    )
    Get-Item -LiteralPath $Session.SelectedDetectionPath
}
