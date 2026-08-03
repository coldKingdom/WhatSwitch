#requires -Version 7.6

Set-StrictMode -Version Latest

$script:WhatSwitchPsadtModulePath = 'C:\Program Files\WindowsPowerShell\Modules\PSAppDeployToolkit\4.1.8\PSAppDeployToolkit.psd1'
$script:WhatSwitchPsadtVersion = '4.1.8'

function ConvertTo-WhatSwitchSafeFileName {
    param([Parameter(Mandatory)][string]$Value)

    $invalid = [IO.Path]::GetInvalidFileNameChars()
    $builder = [Text.StringBuilder]::new()
    foreach ($character in $Value.ToCharArray()) {
        [void]$builder.Append($(if ($character -in $invalid) { '-' } else { $character }))
    }
    $safe = ($builder.ToString() -replace '\s+', '-').Trim(' ', '.', '-')
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'Application' }
    return $safe
}

function Get-WhatSwitchPreferredCommands {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$AnalysisResult)

    $detectedInstall = @($AnalysisResult.Commands) |
        Where-Object { $_.Label -match 'install' -and $_.Label -notmatch 'uninstall|repair|admin' } |
        Select-Object -First 1
    $detectedUninstall = @($AnalysisResult.Commands) |
        Where-Object { $_.Label -match 'uninstall' } |
        Select-Object -First 1

    [pscustomobject]@{
        Install = if ($AnalysisResult.Catalog -and $AnalysisResult.Catalog.InstallCommand) {
            [string]$AnalysisResult.Catalog.InstallCommand
        } elseif ($detectedInstall) { [string]$detectedInstall.Command } else { '' }
        Uninstall = if ($AnalysisResult.Catalog -and $AnalysisResult.Catalog.UninstallCommand) {
            [string]$AnalysisResult.Catalog.UninstallCommand
        } elseif ($detectedUninstall) { [string]$detectedUninstall.Command } else { '' }
    }
}

function New-WhatSwitchDetectionCandidate {
    param(
        [Parameter(Mandatory)][ValidateSet('Msi', 'File', 'Registry')][string]$Type,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][int]$Priority,
        [Parameter(Mandatory)][string]$Source,
        [hashtable]$Properties = @{},
        [bool]$Verified = $false
    )

    $candidate = [ordered]@{
        id = $Id
        type = $Type
        displayName = $DisplayName
        priority = $Priority
        source = $Source
        verified = $Verified
    }
    foreach ($entry in $Properties.GetEnumerator()) { $candidate[$entry.Key] = $entry.Value }
    [pscustomobject]$candidate
}

function Get-WhatSwitchDetectionCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$AnalysisResult,
        $SandboxReport
    )

    $candidates = [Collections.Generic.List[object]]::new()
    if ($AnalysisResult.Engine -eq 'msi' -and $AnalysisResult.Msi -and $AnalysisResult.Msi.ProductCode) {
        $productCode = [string]$AnalysisResult.Msi.ProductCode
        $version = [string]$AnalysisResult.Msi.ProductVersion
        $display = "MSI ProductCode $productCode"
        if ($version) { $display += " (version minst $version)" }
        $candidates.Add((New-WhatSwitchDetectionCandidate -Type Msi -Id 'msi-product-code' `
            -DisplayName $display -Priority 400 -Source 'MSI-metadata' -Properties @{
                productCode = $productCode
                productVersion = $version
                operator = $(if ($version) { 'greaterThanOrEqual' } else { 'exists' })
            }))
    }

    if ($AnalysisResult.Catalog -and $AnalysisResult.Catalog.DetectionPath) {
        $detectionPath = [Environment]::ExpandEnvironmentVariables([string]$AnalysisResult.Catalog.DetectionPath)
        $leaf = Split-Path -Leaf $detectionPath
        $parent = Split-Path -Parent $detectionPath
        if ($leaf -and $parent) {
            $candidates.Add((New-WhatSwitchDetectionCandidate -Type File -Id 'catalog-file' `
                -DisplayName "Fil finns: $detectionPath" -Priority 300 -Source 'Katalog' -Properties @{
                    path = $parent
                    fileOrFolder = $leaf
                    detectionMethod = 'exists'
                    operator = 'exists'
                    value = ''
                    is32BitOn64System = $false
                }))
        }
    }

    if ($SandboxReport -and $SandboxReport.candidates) {
        foreach ($item in @($SandboxReport.candidates)) {
            if ($null -eq $item -or -not $item.PSObject.Properties['type']) { continue }
            $type = [string]$item.type
            if ($type -notin 'Registry', 'File') { continue }
            $priority = if ($item.PSObject.Properties['priority']) { [int]$item.priority } elseif ($type -eq 'Registry') { 200 } else { 100 }
            $properties = @{}
            foreach ($property in $item.PSObject.Properties) {
                if ($property.Name -notin 'id', 'type', 'displayName', 'priority', 'source', 'verified') {
                    $properties[$property.Name] = $property.Value
                }
            }
            $candidates.Add((New-WhatSwitchDetectionCandidate -Type $type `
                -Id $(if ($item.PSObject.Properties['id'] -and $item.id) { [string]$item.id } else { 'sandbox-' + [guid]::NewGuid().ToString('N') }) `
                -DisplayName $(if ($item.PSObject.Properties['displayName'] -and $item.displayName) { [string]$item.displayName } else { "$type från Sandbox" }) `
                -Priority $priority -Source 'Windows Sandbox' -Properties $properties `
                -Verified $(if ($item.PSObject.Properties['verified']) { [bool]$item.verified } else { $false })))
        }
    }

    @($candidates | Sort-Object -Property @{ Expression = 'priority'; Descending = $true }, displayName -Unique)
}

function New-WhatSwitchDeploymentProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$AnalysisResult)

    $commands = Get-WhatSwitchPreferredCommands -AnalysisResult $AnalysisResult
    $candidates = @(Get-WhatSwitchDetectionCandidates -AnalysisResult $AnalysisResult)
    $fileStem = [IO.Path]::GetFileNameWithoutExtension([string]$AnalysisResult.FileName)
    $name = if ($AnalysisResult.ProductName) { [string]$AnalysisResult.ProductName } else { $fileStem }
    $version = if ($AnalysisResult.ProductVersion) { [string]$AnalysisResult.ProductVersion } else { '1.0.0' }
    $publisher = if ($AnalysisResult.CompanyName) { [string]$AnalysisResult.CompanyName } else { 'Okänd utgivare' }
    $architecture = if ($AnalysisResult.FileName -match '(?i)(arm64|aarch64)') {
        @('arm64')
    } elseif ($AnalysisResult.FileName -match '(?i)(x64|amd64|64-bit)') {
        @('x64')
    } else { @('x86', 'x64') }

    [pscustomobject][ordered]@{
        schemaVersion = 1
        generatedBy = 'What Switch? 1.5.0'
        metadata = [pscustomobject][ordered]@{
            name = $name
            version = $version
            publisher = $publisher
            sourceFile = [string]$AnalysisResult.Path
            sourceFileName = [string]$AnalysisResult.FileName
        }
        commands = [pscustomobject][ordered]@{
            install = [string]$commands.Install
            uninstall = [string]$commands.Uninstall
            installBehavior = 'System'
        }
        requirements = [pscustomobject][ordered]@{
            architecture = [object[]]$architecture
            minimumOperatingSystem = 'Windows 10 1607'
        }
        returnCodes = @(
            [pscustomobject]@{ code = 0; type = 'success' }
            [pscustomobject]@{ code = 1707; type = 'success' }
            [pscustomobject]@{ code = 3010; type = 'softReboot' }
            [pscustomobject]@{ code = 1641; type = 'hardReboot' }
            [pscustomobject]@{ code = 1618; type = 'retry' }
        )
        detection = [pscustomobject][ordered]@{
            confirmed = $false
            selected = $(if ($candidates.Count) { $candidates[0] } else { $null })
            candidates = $candidates
        }
        sandbox = [pscustomobject][ordered]@{
            status = 'notRun'
            installedVerified = $false
            uninstalledVerified = $false
            reportPath = ''
            testedAt = $null
        }
        export = [pscustomobject][ordered]@{
            mode = 'Direct'
            includeSourceFolder = $false
            psadtVersion = $script:WhatSwitchPsadtVersion
        }
    }
}

function Test-WhatSwitchDeploymentProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [switch]$ThrowOnError
    )

    $errors = [Collections.Generic.List[string]]::new()
    if ([int]$Profile.schemaVersion -ne 1) { $errors.Add('Profilens schemaVersion måste vara 1.') }
    if ([string]::IsNullOrWhiteSpace([string]$Profile.metadata.name)) { $errors.Add('Programnamn saknas.') }
    if ([string]::IsNullOrWhiteSpace([string]$Profile.metadata.version)) { $errors.Add('Programversion saknas.') }
    if (-not (Test-Path -LiteralPath ([string]$Profile.metadata.sourceFile) -PathType Leaf)) { $errors.Add('Källfilen finns inte.') }
    if ([string]::IsNullOrWhiteSpace([string]$Profile.commands.install)) { $errors.Add('Installationskommando saknas.') }
    if ([string]::IsNullOrWhiteSpace([string]$Profile.commands.uninstall)) { $errors.Add('Avinstallationskommando saknas.') }
    if ([string]$Profile.commands.installBehavior -notin 'System', 'User') { $errors.Add('Körkontext måste vara System eller User.') }
    if ([string]$Profile.export.mode -notin 'Direct', 'PsadtScriptOnly', 'PsadtComplete') { $errors.Add('Ogiltigt exportläge.') }
    $selectedDetection = $Profile.detection.selected
    $productCode = if ($selectedDetection -and $selectedDetection.PSObject.Properties['productCode']) { [string]$selectedDetection.productCode } else { '' }
    $filePath = if ($selectedDetection -and $selectedDetection.PSObject.Properties['path']) { [string]$selectedDetection.path } else { '' }
    $registryPath = if ($selectedDetection -and $selectedDetection.PSObject.Properties['keyPath']) { [string]$selectedDetection.keyPath } else { '' }
    if (-not $Profile.detection.confirmed -or $null -eq $selectedDetection) {
        $errors.Add('En detektionsregel måste väljas och bekräftas före export.')
    }
    elseif ([string]$selectedDetection.type -eq 'Msi' -and [string]::IsNullOrWhiteSpace($productCode)) {
        $errors.Add('MSI-detektering kräver ProductCode.')
    }
    elseif ([string]$selectedDetection.type -eq 'File' -and [string]::IsNullOrWhiteSpace($filePath)) {
        $errors.Add('Fildetektering kräver en sökväg.')
    }
    elseif ([string]$selectedDetection.type -eq 'Registry' -and [string]::IsNullOrWhiteSpace($registryPath)) {
        $errors.Add('Registerdetektering kräver keyPath.')
    }
    if ($errors.Count -and $ThrowOnError) { throw ($errors -join [Environment]::NewLine) }
    [pscustomobject]@{ IsValid = $errors.Count -eq 0; Errors = @($errors) }
}

function Split-WhatSwitchCommandLine {
    param([Parameter(Mandatory)][string]$Command)

    $value = $Command.Trim()
    if ($value -match '^"([^"]+)"\s*(.*)$') {
        return [pscustomobject]@{ FilePath = $Matches[1]; Arguments = $Matches[2] }
    }
    if ($value -match '^(\S+)\s*(.*)$') {
        return [pscustomobject]@{ FilePath = $Matches[1]; Arguments = $Matches[2] }
    }
    [pscustomobject]@{ FilePath = $value; Arguments = '' }
}

function Resolve-WhatSwitchUninstallCommand {
    [CmdletBinding()]
    param(
        $DetectionRule,
        [AllowEmptyString()][string]$FallbackCommand = ''
    )

    if ($null -eq $DetectionRule) { return $FallbackCommand }
    $quiet = if ($DetectionRule.PSObject.Properties['quietUninstallString']) { [string]$DetectionRule.quietUninstallString } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($quiet)) { return $quiet.Trim() }
    $registered = if ($DetectionRule.PSObject.Properties['uninstallString']) { [string]$DetectionRule.uninstallString } else { '' }
    if ([string]::IsNullOrWhiteSpace($registered)) { return $FallbackCommand }

    $registered = $registered.Trim()
    $registeredParts = Split-WhatSwitchCommandLine -Command $registered
    if (-not [string]::IsNullOrWhiteSpace([string]$registeredParts.Arguments)) { return $registered }
    if (-not [string]::IsNullOrWhiteSpace($FallbackCommand)) {
        $fallbackParts = Split-WhatSwitchCommandLine -Command $FallbackCommand
        if (-not [string]::IsNullOrWhiteSpace([string]$fallbackParts.Arguments)) {
            return $registered + ' ' + ([string]$fallbackParts.Arguments).Trim()
        }
    }
    $registered
}

function ConvertTo-WhatSwitchPsSingleQuotedString {
    param([AllowEmptyString()][string]$Value)
    "'" + $Value.Replace("'", "''") + "'"
}

function Get-WhatSwitchPsadtMsiArgumentSuffix {
    param([AllowEmptyString()][string]$Remainder)

    if ([string]::IsNullOrWhiteSpace($Remainder)) { return '' }
    $tokens = @([regex]::Matches($Remainder, '(?:[^\s"]+|"[^"]*")+') | ForEach-Object Value)
    # These are semantic equivalents of the defaults in PSADT 4.1.8 Config\config.psd1.
    # Keeping them would unnecessarily replace the centrally configured MSI parameters.
    $additionalTokens = @($tokens | Where-Object { $_ -notmatch '(?i)^(?:/qn|/quiet|/norestart|REBOOT=ReallySuppress)$' })
    if (-not $additionalTokens.Count) { return '' }

    $overridesConfig = @($additionalTokens | Where-Object {
        $_ -match '(?i)^(?:/q\S*|/passive|/promptrestart|/forcerestart|/l\S*|/log|REBOOT=)'
    }).Count -gt 0
    if ($overridesConfig) {
        return ' -ArgumentList ' + (ConvertTo-WhatSwitchPsSingleQuotedString $Remainder)
    }

    $expressions = @($additionalTokens | ForEach-Object { ConvertTo-WhatSwitchPsSingleQuotedString $_ })
    ' -AdditionalArgumentList @(' + ($expressions -join ', ') + ')'
}

function Set-WhatSwitchPsadtTemplateAssignment {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Expression
    )

    $pattern = '(?m)^(\s*' + [regex]::Escape($Name) + '\s*=\s*).*$'
    $regex = [regex]::new($pattern)
    if ($regex.Matches($Content).Count -ne 1) {
        throw "PSADT-mallen innehåller inte exakt en tilldelning för '$Name'."
    }
    $evaluator = [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $match.Groups[1].Value + $Expression
    }
    $regex.Replace($Content, $evaluator, 1)
}

function Add-WhatSwitchPsadtTemplateTask {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Action
    )

    $markerLine = "    ## <$Marker>"
    $firstIndex = $Content.IndexOf($markerLine, [StringComparison]::Ordinal)
    if ($firstIndex -lt 0 -or $Content.IndexOf($markerLine, $firstIndex + $markerLine.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "PSADT-mallen innehåller inte exakt en markör för '$Marker'."
    }
    $newLine = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $replacement = $markerLine + $newLine + $newLine +
        '    ## Generated by What Switch? — the surrounding PSADT template is unchanged.' + $newLine +
        '    ' + $Action
    $Content.Substring(0, $firstIndex) + $replacement + $Content.Substring($firstIndex + $markerLine.Length)
}

function New-WhatSwitchPsadtScriptContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)]$AnalysisResult,
        [AllowEmptyString()][string]$TemplateContent = ''
    )

    $name = ConvertTo-WhatSwitchPsSingleQuotedString ([string]$Profile.metadata.name)
    $vendor = ConvertTo-WhatSwitchPsSingleQuotedString ([string]$Profile.metadata.publisher)
    $version = ConvertTo-WhatSwitchPsSingleQuotedString ([string]$Profile.metadata.version)
    $sourceFileName = [string]$Profile.metadata.sourceFileName
    $sourceLiteral = ConvertTo-WhatSwitchPsSingleQuotedString $sourceFileName
    $installParts = Split-WhatSwitchCommandLine -Command ([string]$Profile.commands.install)
    $resolvedUninstallCommand = Resolve-WhatSwitchUninstallCommand -DetectionRule $Profile.detection.selected `
        -FallbackCommand ([string]$Profile.commands.uninstall)
    $uninstallParts = Split-WhatSwitchCommandLine -Command $resolvedUninstallCommand
    $requireAdminLiteral = if ([string]$Profile.commands.installBehavior -eq 'System') { '$true' } else { '$false' }
    if ([string]::IsNullOrWhiteSpace($TemplateContent)) {
        $templatePath = Join-Path (Split-Path -Parent $script:WhatSwitchPsadtModulePath) 'Frontend\v4\Invoke-AppDeployToolkit.ps1'
        if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw "PSADT v4-mallen saknas: $templatePath" }
        $TemplateContent = [IO.File]::ReadAllText($templatePath)
    }

    if ($AnalysisResult.Engine -eq 'msi') {
        $installAction = "Start-ADTMsiProcess -Action Install -FilePath $sourceLiteral"
        $installRemainder = ([string]$Profile.commands.install -replace '(?i)^msiexec(?:\.exe)?\s+/i\s+(?:"[^"]+"|\S+)\s*', '').Trim()
        $installAction += Get-WhatSwitchPsadtMsiArgumentSuffix -Remainder $installRemainder
        if ($AnalysisResult.Msi -and $AnalysisResult.Msi.ProductCode) {
            $code = ConvertTo-WhatSwitchPsSingleQuotedString ([string]$AnalysisResult.Msi.ProductCode)
            $uninstallAction = "Start-ADTMsiProcess -Action Uninstall -ProductCode $code"
            $uninstallRemainder = ($resolvedUninstallCommand -replace '(?i)^msiexec(?:\.exe)?\s+/x\s+(?:"[^"]+"|\S+)\s*', '').Trim()
            $uninstallAction += Get-WhatSwitchPsadtMsiArgumentSuffix -Remainder $uninstallRemainder
        } else {
            $uninstallAction = "Start-ADTMsiProcess -Action Uninstall -FilePath $sourceLiteral"
        }
    }
    else {
        $installFile = if ([IO.Path]::GetFileName([string]$installParts.FilePath) -ieq $sourceFileName) {
            $sourceFileName
        } else { [string]$installParts.FilePath }
        $installAction = 'Start-ADTProcess -FilePath ' + (ConvertTo-WhatSwitchPsSingleQuotedString $installFile)
        if ($installParts.Arguments) {
            $installAction += ' -ArgumentList ' + (ConvertTo-WhatSwitchPsSingleQuotedString ([string]$installParts.Arguments))
        }
        if ($installFile -match '%[^%]+%') { $installAction += ' -ExpandEnvironmentVariables' }

        $uninstallAction = 'Start-ADTProcess -FilePath ' + (ConvertTo-WhatSwitchPsSingleQuotedString ([string]$uninstallParts.FilePath))
        if ($uninstallParts.Arguments) {
            $uninstallAction += ' -ArgumentList ' + (ConvertTo-WhatSwitchPsSingleQuotedString ([string]$uninstallParts.Arguments))
        }
        if ($uninstallParts.FilePath -match '%[^%]+%') { $uninstallAction += ' -ExpandEnvironmentVariables' }
    }

    $architectures = @($Profile.requirements.architecture)
    $architecture = if ($architectures.Count -eq 1) { [string]$architectures[0] } else { '' }
    $successCodes = @($Profile.returnCodes | Where-Object type -EQ 'success' | ForEach-Object { [int]$_.code })
    $rebootCodes = @($Profile.returnCodes | Where-Object type -In 'softReboot', 'hardReboot' | ForEach-Object { [int]$_.code })
    if (-not $successCodes.Count) { $successCodes = @(0) }
    if (-not $rebootCodes.Count) { $rebootCodes = @(1641, 3010) }

    $content = $TemplateContent
    $assignments = [ordered]@{
        AppVendor = $vendor
        AppName = $name
        AppVersion = $version
        AppArch = ConvertTo-WhatSwitchPsSingleQuotedString $architecture
        AppSuccessExitCodes = '@(' + ($successCodes -join ', ') + ')'
        AppRebootExitCodes = '@(' + ($rebootCodes -join ', ') + ')'
        AppScriptDate = ConvertTo-WhatSwitchPsSingleQuotedString ([DateTime]::Today.ToString('yyyy-MM-dd'))
        AppScriptAuthor = ConvertTo-WhatSwitchPsSingleQuotedString 'What Switch?'
        RequireAdmin = $requireAdminLiteral
    }
    foreach ($assignment in $assignments.GetEnumerator()) {
        $content = Set-WhatSwitchPsadtTemplateAssignment -Content $content -Name $assignment.Key -Expression $assignment.Value
    }
    $content = Add-WhatSwitchPsadtTemplateTask -Content $content -Marker 'Perform Installation tasks here' -Action $installAction
    $content = Add-WhatSwitchPsadtTemplateTask -Content $content -Marker 'Perform Uninstallation tasks here' -Action $uninstallAction
    $content
}

function New-WhatSwitchPsadtSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)]$AnalysisResult,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$IncludeToolkit
    )

    if (-not (Test-Path -LiteralPath $script:WhatSwitchPsadtModulePath -PathType Leaf)) {
        throw "PSAppDeployToolkit $script:WhatSwitchPsadtVersion hittades inte på '$script:WhatSwitchPsadtModulePath'."
    }
    Import-Module $script:WhatSwitchPsadtModulePath -Force -ErrorAction Stop
    $parent = Split-Path -Parent $Destination
    $name = Split-Path -Leaf $Destination
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $created = New-ADTTemplate -Destination $parent -Name $name -Version 4 -Force -PassThru
    $filesPath = Join-Path $created.FullName 'Files'
    $placeholder = Join-Path $filesPath 'Add Setup Files Here.txt'
    if (Test-Path -LiteralPath $placeholder) { Remove-Item -LiteralPath $placeholder -Force }
    Copy-Item -LiteralPath ([string]$Profile.metadata.sourceFile) -Destination (Join-Path $filesPath ([string]$Profile.metadata.sourceFileName)) -Force
    if ($Profile.export.includeSourceFolder) {
        $sourceParent = Split-Path -Parent ([string]$Profile.metadata.sourceFile)
        foreach ($item in Get-ChildItem -LiteralPath $sourceParent -Force) {
            if ([string]::Equals($item.FullName, [string]$Profile.metadata.sourceFile, [StringComparison]::OrdinalIgnoreCase)) { continue }
            Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $filesPath $item.Name) -Recurse -Force
        }
    }

    $deploymentScriptPath = Join-Path $created.FullName 'Invoke-AppDeployToolkit.ps1'
    $templateText = [IO.File]::ReadAllText($deploymentScriptPath)
    $scriptText = New-WhatSwitchPsadtScriptContent -Profile $Profile -AnalysisResult $AnalysisResult -TemplateContent $templateText
    [IO.File]::WriteAllText($deploymentScriptPath, $scriptText, [Text.UTF8Encoding]::new($false))

    if (-not $IncludeToolkit) {
        $moduleFolder = Join-Path $created.FullName 'PSAppDeployToolkit'
        if (Test-Path -LiteralPath $moduleFolder) { Remove-Item -LiteralPath $moduleFolder -Recurse -Force }
    }
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $script:WhatSwitchPsadtModulePath) 'COPYING.Lesser') `
        -Destination (Join-Path $created.FullName 'PSAppDeployToolkit-LICENSE.txt') -Force
    Get-Item -LiteralPath $created.FullName
}

function ConvertTo-WhatSwitchIntuneSettings {
    param([Parameter(Mandatory)]$Profile)

    $psadt = [string]$Profile.export.mode -ne 'Direct'
    [pscustomobject][ordered]@{
        displayName = [string]$Profile.metadata.name
        description = "Deploymentpaket genererat av What Switch? 1.5.0"
        publisher = [string]$Profile.metadata.publisher
        appVersion = [string]$Profile.metadata.version
        installCommand = $(if ($psadt) { 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent' } else { [string]$Profile.commands.install })
        uninstallCommand = $(if ($psadt) { 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent' } else { [string]$Profile.commands.uninstall })
        installBehavior = [string]$Profile.commands.installBehavior
        deviceRestartBehavior = 'App install may force a device restart'
        requirements = $Profile.requirements
        detectionRule = $Profile.detection.selected
        returnCodes = $Profile.returnCodes
        sandboxVerification = $Profile.sandbox
    }
}

function New-WhatSwitchIntuneGuideText {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)]$Settings)

    $architectures = @($Profile.requirements.architecture) -join ', '
    $verified = if ($Profile.sandbox.installedVerified) { 'Ja' } else { 'Nej – granska regeln extra noggrant' }
    $detectionJson = $Profile.detection.selected | ConvertTo-Json -Depth 10
    @"
# Intune-guide – $($Profile.metadata.name) $($Profile.metadata.version)

Paketet skapades lokalt av What Switch? 1.5.0. Ingen data har laddats upp.

## 1. Appinformation

- Namn: $($Profile.metadata.name)
- Utgivare: $($Profile.metadata.publisher)
- Version: $($Profile.metadata.version)

## 2. Program

- Installationskommando: ``$($Settings.installCommand)``
- Avinstallationskommando: ``$($Settings.uninstallCommand)``
- Installationsbeteende: $($Settings.installBehavior)
- Omstartsbeteende: Appinstallationen kan framtvinga omstart

## 3. Krav

- Arkitektur: $architectures
- Minsta operativsystem: $($Profile.requirements.minimumOperatingSystem)

## 4. Detektionsregel

Sandbox-verifierad installation: $verified

```json
$detectionJson
```

Lägg in regeln som MSI-, fil- eller registerregel enligt typen ovan. Om flera regler läggs till i Intune måste samtliga vara sanna.

## 5. Returkoder

- 0 och 1707: Lyckades
- 3010: Mjuk omstart
- 1641: Hård omstart
- 1618: Försök igen

## 6. Tilldelning

Tilldelningar till grupper görs manuellt efter att paketet och inställningarna har granskats.
"@
}

function Write-WhatSwitchChecksums {
    param([Parameter(Mandatory)][string]$RootPath)

    $checksumPath = Join-Path $RootPath 'SHA256SUMS.txt'
    $lines = foreach ($file in Get-ChildItem -LiteralPath $RootPath -File -Recurse | Where-Object FullName -NE $checksumPath | Sort-Object FullName) {
        $relative = [IO.Path]::GetRelativePath($RootPath, $file.FullName).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $relative"
    }
    [IO.File]::WriteAllLines($checksumPath, @($lines), [Text.UTF8Encoding]::new($false))
    Get-Item -LiteralPath $checksumPath
}

function Export-WhatSwitchDeploymentPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)]$AnalysisResult,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$SandboxReportPath
    )

    [void](Test-WhatSwitchDeploymentProfile -Profile $Profile -ThrowOnError)
    $safeName = ConvertTo-WhatSwitchSafeFileName ([string]$Profile.metadata.name)
    $safeVersion = ConvertTo-WhatSwitchSafeFileName ([string]$Profile.metadata.version)
    $root = Join-Path $OutputDirectory "$safeName-$safeVersion"
    if (Test-Path -LiteralPath $root) { throw "Exportmappen finns redan: $root" }
    [void](New-Item -ItemType Directory -Path $root -Force)
    $intuneDirectory = Join-Path $root 'Intune'
    [void](New-Item -ItemType Directory -Path $intuneDirectory)

    $sourceDirectory = Join-Path $root 'Source'
    $mode = [string]$Profile.export.mode
    if ($mode -eq 'Direct') {
        [void](New-Item -ItemType Directory -Path $sourceDirectory)
        if ($Profile.export.includeSourceFolder) {
            $sourceParent = Split-Path -Parent ([string]$Profile.metadata.sourceFile)
            foreach ($item in Get-ChildItem -LiteralPath $sourceParent -Force) {
                Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $sourceDirectory $item.Name) -Recurse -Force
            }
        }
        else {
            Copy-Item -LiteralPath ([string]$Profile.metadata.sourceFile) -Destination (Join-Path $sourceDirectory ([string]$Profile.metadata.sourceFileName))
        }
        $setupFile = Join-Path $sourceDirectory ([string]$Profile.metadata.sourceFileName)
    }
    else {
        [void](New-WhatSwitchPsadtSource -Profile $Profile -AnalysisResult $AnalysisResult `
            -Destination $sourceDirectory -IncludeToolkit:($mode -eq 'PsadtComplete'))
        $setupFile = Join-Path $sourceDirectory 'Invoke-AppDeployToolkit.exe'
    }

    $packagePath = Join-Path $intuneDirectory "$safeName-$safeVersion.intunewin"
    $package = New-WhatSwitchIntuneWinPackage -SetupFile $setupFile -SourceFolder $sourceDirectory `
        -IncludeSourceFolder -OutputPath $packagePath -ApplicationName ([string]$Profile.metadata.name)
    $settings = ConvertTo-WhatSwitchIntuneSettings -Profile $Profile
    [IO.File]::WriteAllText((Join-Path $root 'DeploymentProfile.json'), ($Profile | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $intuneDirectory 'Intune-Settings.json'), ($settings | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $root 'Analysis.json'), ($AnalysisResult | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $intuneDirectory 'README-SV.md'), (New-WhatSwitchIntuneGuideText -Profile $Profile -Settings $settings), [Text.UTF8Encoding]::new($false))
    if ($SandboxReportPath -and (Test-Path -LiteralPath $SandboxReportPath -PathType Leaf)) {
        Copy-Item -LiteralPath $SandboxReportPath -Destination (Join-Path $root 'SandboxVerification.json')
    }
    $checksums = Write-WhatSwitchChecksums -RootPath $root

    [pscustomobject]@{
        Path = $root
        IntuneWinPath = $package.Path
        Mode = $mode
        PackageSize = $package.PackageSize
        ChecksumPath = $checksums.FullName
    }
}
