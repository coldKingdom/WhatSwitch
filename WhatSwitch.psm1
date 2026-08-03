#requires -Version 7.6

Set-StrictMode -Version Latest

$script:CatalogCache = @{}
$script:DefaultCatalogPath = Join-Path $PSScriptRoot 'catalog/catalog.json'

function New-WhatSwitchCommand {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Command
    )

    [pscustomobject]@{
        PSTypeName = 'WhatSwitch.Command'
        Label = $Label
        Command = $Command
        PowerShellCommand = if ($Command) { ConvertTo-WhatSwitchPowerShellCommand -Command $Command } else { '' }
    }
}

function ConvertTo-WhatSwitchPowerShellCommand {
    <#
    .SYNOPSIS
    Rewrites a CMD-oriented installer command for PowerShell.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][AllowEmptyString()][string]$Command
    )

    process {
        if ([string]::IsNullOrWhiteSpace($Command)) { return $Command }

        $converted = [regex]::Replace(
            $Command,
            '%([A-Za-z_][A-Za-z0-9_()]*)%',
            { param($match) '$env:' + $match.Groups[1].Value }
        )

        if ($converted.StartsWith('"', [System.StringComparison]::Ordinal)) {
            return '& ' + $converted
        }

        $head = ($converted -split '\s+', 2)[0]
        $pathCommands = 'msiexec', 'sc', 'net', 'reg', 'wusa', 'rundll32', 'dism', 'powershell', 'pwsh', 'cmd'
        $headWithoutExtension = [System.IO.Path]::GetFileNameWithoutExtension($head)
        if ($head -match '\.exe$' -and $head -notmatch '[\\/]' -and $headWithoutExtension -notin $pathCommands) {
            return '.\' + $converted
        }

        return $converted
    }
}

function Read-WhatSwitchBytes {
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][long]$MaximumBytes
    )

    $stream = [System.IO.File]::Open($LiteralPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $length = [int][Math]::Min($stream.Length, $MaximumBytes)
        $buffer = [byte[]]::new($length)
        $offset = 0
        while ($offset -lt $length) {
            $read = $stream.Read($buffer, $offset, $length - $offset)
            if ($read -eq 0) { break }
            $offset += $read
        }
        if ($offset -ne $length) { [Array]::Resize([ref]$buffer, $offset) }
        Write-Output -NoEnumerate $buffer
    }
    finally {
        $stream.Dispose()
    }
}

function Test-WhatSwitchPrefix {
    param([byte[]]$Bytes, [byte[]]$Signature)

    if ($Bytes.Length -lt $Signature.Length) { return $false }
    for ($index = 0; $index -lt $Signature.Length; $index++) {
        if ($Bytes[$index] -ne $Signature[$index]) { return $false }
    }
    return $true
}

function Get-WhatSwitchUInt16 {
    param([byte[]]$Bytes, [int]$Offset)
    if ($Offset -lt 0 -or $Offset + 2 -gt $Bytes.Length) { throw 'Offset is outside the byte buffer.' }
    return [uint16]($Bytes[$Offset] -bor ($Bytes[$Offset + 1] -shl 8))
}

function Get-WhatSwitchUInt32 {
    param([byte[]]$Bytes, [int]$Offset)
    if ($Offset -lt 0 -or $Offset + 4 -gt $Bytes.Length) { throw 'Offset is outside the byte buffer.' }
    return [uint32](
        [uint32]$Bytes[$Offset] -bor
        ([uint32]$Bytes[$Offset + 1] -shl 8) -bor
        ([uint32]$Bytes[$Offset + 2] -shl 16) -bor
        ([uint32]$Bytes[$Offset + 3] -shl 24)
    )
}

function Test-WhatSwitchPeSection {
    param([byte[]]$Bytes, [Parameter(Mandatory)][string]$Name)

    try {
        if ($Bytes.Length -lt 64 -or $Bytes[0] -ne 0x4d -or $Bytes[1] -ne 0x5a) { return $false }
        $peOffset = [int](Get-WhatSwitchUInt32 -Bytes $Bytes -Offset 0x3c)
        if ($peOffset -le 0 -or $peOffset + 24 -gt $Bytes.Length) { return $false }
        if ((Get-WhatSwitchUInt32 -Bytes $Bytes -Offset $peOffset) -ne 0x00004550) { return $false }

        $sectionCount = [Math]::Min([int](Get-WhatSwitchUInt16 -Bytes $Bytes -Offset ($peOffset + 6)), 96)
        $optionalHeaderSize = [int](Get-WhatSwitchUInt16 -Bytes $Bytes -Offset ($peOffset + 20))
        $sectionOffset = $peOffset + 24 + $optionalHeaderSize
        for ($section = 0; $section -lt $sectionCount; $section++) {
            $offset = $sectionOffset + ($section * 40)
            if ($offset + 8 -gt $Bytes.Length) { return $false }
            $nameBytes = $Bytes[$offset..($offset + 7)]
            $zero = [Array]::IndexOf($nameBytes, [byte]0)
            if ($zero -ge 0) { $nameBytes = $nameBytes[0..([Math]::Max(0, $zero - 1))] }
            $sectionName = [Text.Encoding]::ASCII.GetString($nameBytes).Trim([char]0)
            if ($sectionName -ceq $Name) { return $true }
        }
    }
    catch {
        return $false
    }
    return $false
}

function Test-WhatSwitchSecretName {
    param([AllowEmptyString()][string]$Name)

    if (-not $Name) { return $false }
    $secret = 'PASSWORD|PASSPHRASE|PWD|SECRET|APIKEY|API_KEY|AUTHKEY|AUTHTOKEN|TOKEN|CREDENTIAL|PRIVATEKEY|SERIALNUM|SERIALNO|SERIALKEY|PIDKEY|CDKEY|PRODUCTKEY|PRODKEY|LICEN[CS]EKEY|LICEN[CS]ECODE|REGCODE|UNLOCKCODE|ACTIVATIONCODE|ACTIVATIONKEY'
    $notSecret = 'ACCEPT|AGREE|EULA|PATH|FILE|FOLDER|_?DIR\b|URL|SERVER|HOST|PORT|ENABLE|DISABLE|SHOW|HIDE|COUNT|TYPE|MODE|EXPIR|CHECK|VALIDAT'
    return $Name -match $secret -and $Name -notmatch $notSecret
}

function Invoke-WhatSwitchComMethod {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [object[]]$Arguments = @()
    )
    $InputObject.GetType().InvokeMember($Name, [Reflection.BindingFlags]::InvokeMethod, $null, $InputObject, $Arguments)
}

function Get-WhatSwitchComProperty {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [object[]]$Arguments = @()
    )
    $InputObject.GetType().InvokeMember($Name, [Reflection.BindingFlags]::GetProperty, $null, $InputObject, $Arguments)
}

function Get-WhatSwitchMsiAnalysis {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath)

    if (-not $IsWindows) { return $null }

    $installer = $database = $view = $record = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer -ErrorAction Stop
        $database = Invoke-WhatSwitchComMethod -InputObject $installer -Name OpenDatabase -Arguments @($LiteralPath, 0)
        $view = Invoke-WhatSwitchComMethod -InputObject $database -Name OpenView -Arguments @('SELECT `Property`, `Value` FROM `Property`')
        [void](Invoke-WhatSwitchComMethod -InputObject $view -Name Execute)

        $raw = [ordered]@{}
        while ($true) {
            $record = Invoke-WhatSwitchComMethod -InputObject $view -Name Fetch
            if ($null -eq $record) { break }
            $name = [string](Get-WhatSwitchComProperty -InputObject $record -Name StringData -Arguments @(1))
            $value = [string](Get-WhatSwitchComProperty -InputObject $record -Name StringData -Arguments @(2))
            if ($name) { $raw[$name] = $value }
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($record)
            $record = $null
        }

        $hidden = @([string]$raw['MsiHiddenProperties'] -split '[;,]' | ForEach-Object Trim | Where-Object { $_ })
        $secure = @([string]$raw['SecureCustomProperties'] -split '[;,]' | ForEach-Object Trim | Where-Object { $_ })
        $properties = foreach ($pair in $raw.GetEnumerator()) {
            $isPublic = $pair.Key -cmatch '^[A-Z][A-Z0-9_]*$'
            [pscustomobject]@{
                Name = $pair.Key
                Value = $pair.Value
                IsPublic = $isPublic
                IsSecure = $pair.Key -in $secure
                IsSecret = $pair.Key -in $hidden -or (Test-WhatSwitchSecretName -Name $pair.Key)
            }
        }

        [pscustomobject]@{
            ProductName = $raw['ProductName']
            ProductVersion = $raw['ProductVersion']
            Manufacturer = $raw['Manufacturer']
            ProductCode = $raw['ProductCode']
            UpgradeCode = $raw['UpgradeCode']
            InstallDirectory = @('INSTALLDIR', 'INSTALLLOCATION', 'APPDIR', 'TARGETDIR') |
                Where-Object { $raw.Contains($_) -and $raw[$_] } |
                Select-Object -First 1 |
                ForEach-Object { $raw[$_] }
            Properties = @($properties)
            PublicProperties = @($properties | Where-Object IsPublic)
            SensitiveProperties = @($properties | Where-Object IsSecret)
        }
    }
    catch {
        Write-Verbose "MSI property analysis was unavailable: $($_.Exception.Message)"
        return $null
    }
    finally {
        foreach ($item in @($record, $view, $database, $installer)) {
            if ($null -ne $item -and [Runtime.InteropServices.Marshal]::IsComObject($item)) {
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($item)
            }
        }
    }
}

function Get-WhatSwitchCatalog {
    <#
    .SYNOPSIS
    Returns the curated installer catalog bundled with What Switch?.
    #>
    [CmdletBinding()]
    param(
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$CatalogPath = $script:DefaultCatalogPath
    )

    $resolved = (Resolve-Path -LiteralPath $CatalogPath).Path
    $stamp = (Get-Item -LiteralPath $resolved).LastWriteTimeUtc.Ticks
    $key = "$resolved|$stamp"
    if (-not $script:CatalogCache.ContainsKey($key)) {
        $document = Get-Content -LiteralPath $resolved -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
        $script:CatalogCache.Clear()
        $script:CatalogCache[$key] = @($document.entries)
    }
    return $script:CatalogCache[$key]
}

function Find-WhatSwitchCatalogEntry {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$ProductName,
        [AllowEmptyString()][string]$FileName,
        [string]$CatalogPath = $script:DefaultCatalogPath
    )

    foreach ($entry in Get-WhatSwitchCatalog -CatalogPath $CatalogPath) {
        try {
            if ($ProductName -and $entry.match.product -and $ProductName -match $entry.match.product) { return $entry }
            if ($FileName -and $entry.match.file -and $FileName -match $entry.match.file) { return $entry }
        }
        catch {
            Write-Verbose "Skipped invalid catalog expression for '$($entry.name)': $($_.Exception.Message)"
        }
    }
    return $null
}

function Find-WhatSwitchSwitch {
    <#
    .SYNOPSIS
    Performs a noisy, opt-in scan for switch-shaped strings in an installer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$Path,

        [ValidateRange(1, 256)]
        [int]$MaximumScanMB = 96
    )

    process {
        $literalPath = (Resolve-Path -LiteralPath $Path).Path
        $bytes = Read-WhatSwitchBytes -LiteralPath $literalPath -MaximumBytes ([long]$MaximumScanMB * 1MB)
        $ascii = [Text.Encoding]::Latin1.GetString($bytes)
        $wide = [Text.Encoding]::Unicode.GetString($bytes)
        $text = $ascii + "`n" + $wide

        $tokens = 'silent', 'verysilent', 'quiet', 'unattended', 'passive', 'norestart', 'noreboot',
            '/silent', '/verysilent', '/quiet', '/qn', '/qb', '/passive', '/norestart', '/exenoui',
            '--silent', '--quiet', '--unattended', '/SUPPRESSMSGBOXES', '/SP-'
        $flags = foreach ($token in $tokens) {
            $escaped = [regex]::Escape($token)
            if ($text -match "(?i)(?<![\w/-])$escaped(?![\w])") { $token }
        }

        $keyword = 'server|port|hostname|host|username|password|silent|unattended|uninstall|install|datadir|directory|path|url|ipaddress|address|account|mode|token|secret|license|proxy|timeout|reboot|norestart|quiet|registry|subkey|service|config|sync|certificate|database|endpoint|apikey|apiurl'
        $options = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($match in [regex]::Matches($wide, '[A-Za-z][A-Za-z0-9_]{3,40}')) {
            $id = $match.Value
            # Do not count a filtering pipeline via `.Count` here. With StrictMode enabled, a
            # one-match pipeline can surface as the scalar [char] itself and property access then
            # throws PropertyNotFoundStrict. An explicit counter is stable for zero, one and many.
            $upperCount = 0
            foreach ($character in $id.ToCharArray()) {
                if ([char]::IsUpper($character)) { $upperCount++ }
            }
            $compound = $id.Contains('_') -or ($upperCount -ge 2 -and $id -cne $id.ToUpperInvariant())
            if ($compound -and $id -match $keyword -and $id -notmatch '^(Get|Set|On|Create|Detect|Handle|Execute|Apply|Is|Has|Should|Can|Validate|Update|Initialize|Convert|Format|Parse|Load|Save|Read|Write|Add|Remove|Open|Close|Show|Hide|Enable|Disable)') {
                [void]$options.Add($id)
                if ($options.Count -ge 120) { break }
            }
        }

        [pscustomobject]@{
            PSTypeName = 'WhatSwitch.SwitchCandidates'
            Path = $literalPath
            Flags = @($flags | Sort-Object -Unique)
            Options = @($options | Sort-Object)
            IsBestEffort = $true
        }
    }
}

function Get-WhatSwitchResult {
    <#
    .SYNOPSIS
    Statically identifies a Windows installer and returns silent-install commands.

    .DESCRIPTION
    Reads installer bytes without executing or uploading the file. MSI metadata is queried through
    the Windows Installer database API when available. PowerShell 7.6 or newer is required.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName, Position = 0)]
        [Alias('FullName')]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$Path,

        [ValidateRange(1, 256)]
        [int]$MaximumScanMB = 32,

        [string]$CatalogPath = $script:DefaultCatalogPath,

        [switch]$IncludeBestEffort
    )

    process {
        $literalPath = (Resolve-Path -LiteralPath $Path).Path
        $file = Get-Item -LiteralPath $literalPath
        $bytes = Read-WhatSwitchBytes -LiteralPath $literalPath -MaximumBytes ([long]$MaximumScanMB * 1MB)
        $fileName = $file.Name
        $isCfb = Test-WhatSwitchPrefix -Bytes $bytes -Signature ([byte[]](0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1))
        $isPe = Test-WhatSwitchPrefix -Bytes $bytes -Signature ([byte[]](0x4d, 0x5a))
        $isZip = Test-WhatSwitchPrefix -Bytes $bytes -Signature ([byte[]](0x50, 0x4b, 0x03, 0x04))

        $ascii = [Text.Encoding]::Latin1.GetString($bytes)
        $wide = if ($isPe) { [Text.Encoding]::Unicode.GetString($bytes) } else { '' }
        $contains = { param([string]$Value) $ascii.IndexOf($Value, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $wide.IndexOf($Value, [StringComparison]::OrdinalIgnoreCase) -ge 0 }

        $versionInfo = if ($isPe) { [Diagnostics.FileVersionInfo]::GetVersionInfo($literalPath) } else { $null }
        $product = if ($versionInfo -and $versionInfo.ProductName) { $versionInfo.ProductName.Trim() } else { $null }
        $version = if ($versionInfo -and $versionInfo.ProductVersion) { $versionInfo.ProductVersion.Trim() } else { $null }
        $company = if ($versionInfo -and $versionInfo.CompanyName) { $versionInfo.CompanyName.Trim() } else { $null }
        $msiAnalysis = $null
        $engineVersion = $null
        $customProperties = @()
        $warning = $null
        $modifiers = $null
        $notes = $null
        $commands = @()

        if ($isCfb) {
            $engine = 'msi'
            $label = 'Windows Installer (MSI)'
            $confidence = 'high'
            $msiAnalysis = Get-WhatSwitchMsiAnalysis -LiteralPath $literalPath -Verbose:$($PSBoundParameters.ContainsKey('Verbose'))
            if ($msiAnalysis) {
                $product = $msiAnalysis.ProductName
                $version = $msiAnalysis.ProductVersion
                $company = $msiAnalysis.Manufacturer
            }
            $target = if ($msiAnalysis -and $msiAnalysis.ProductCode) { $msiAnalysis.ProductCode } else { '"' + $fileName + '"' }
            $commands = @(
                New-WhatSwitchCommand 'Install (silent)' "msiexec /i `"$fileName`" /qn /norestart"
                New-WhatSwitchCommand 'Repair (silent)' "msiexec /f $target /qn /norestart"
                New-WhatSwitchCommand 'Uninstall (silent)' "msiexec /x $target /qn /norestart"
                New-WhatSwitchCommand 'Admin install (extract)' "msiexec /a `"$fileName`" TARGETDIR=`"C:\Path`" /qn"
            )
            $modifiers = '/qn (no UI) · /qb (basic UI) · /norestart · /l*v "C:\out.log" · PROP=VALUE'
            $notes = 'MSI uses msiexec. The file is opened read-only for metadata; the installer is never executed.'
        }
        elseif ($isZip -and ($file.Extension -match '^\.(msix|appx|msixbundle|appxbundle)$' -or (& $contains 'AppxManifest.xml') -or (& $contains 'AppxBundleManifest.xml'))) {
            $engine = 'msix'
            $label = 'MSIX / AppX package'
            $confidence = 'high'
            $commands = @(
                New-WhatSwitchCommand 'Install (current user)' "Add-AppxPackage -Path `"$fileName`""
                New-WhatSwitchCommand 'Provision (all users / image)' "Add-AppxProvisionedPackage -Online -PackagePath `"$fileName`" -SkipLicense"
                New-WhatSwitchCommand 'Uninstall' 'Get-AppxPackage *<Name>* | Remove-AppxPackage'
            )
            $modifiers = 'PowerShell-native; the package cmdlets are non-interactive.'
            $notes = 'The package must be signed and trusted. Add-AppxPackage installs for the current user; provisioning stages it for all users.'
        }
        elseif (-not $isPe) {
            $engine = 'not-installer'
            $label = 'Not a Windows installer'
            $confidence = 'none'
            $notes = 'No PE, MSI/OLE, or MSIX/AppX signature was found.'
        }
        elseif ((Test-WhatSwitchPeSection -Bytes $bytes -Name '.wixburn') -or (& $contains '.wixburn')) {
            $engine = 'wix-burn'; $label = 'WiX Burn bundle'; $confidence = 'high'
            $commands = @(
                New-WhatSwitchCommand 'Install (silent)' "$fileName /install /quiet /norestart"
                New-WhatSwitchCommand 'Repair (silent)' "$fileName /repair /quiet /norestart"
                New-WhatSwitchCommand 'Uninstall (silent)' "$fileName /uninstall /quiet /norestart"
                New-WhatSwitchCommand 'Extract / layout' "$fileName /layout `"C:\Path`" /quiet"
            )
            $modifiers = '/passive · /quiet · /norestart · /log "C:\out.log"'
            $notes = 'Burn switches are engine-defined. Custom bootstrapper applications can still override normal UI behavior.'
        }
        elseif ((& $contains 'Inno Setup') -or (& $contains 'Inno Setup Setup Data')) {
            $engine = 'inno'; $label = 'Inno Setup'; $confidence = 'high'
            $commands = @(
                New-WhatSwitchCommand 'Install (silent)' "$fileName /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-"
                New-WhatSwitchCommand 'Uninstall (silent)' '"%ProgramFiles%\<App>\unins000.exe" /VERYSILENT /SUPPRESSMSGBOXES'
            )
            $modifiers = '/SILENT · /VERYSILENT · /SUPPRESSMSGBOXES · /NORESTART · /ALLUSERS · /CURRENTUSER · /DIR="C:\Path" · /LOG="C:\out.log"'
            $warning = 'If a SYSTEM-context install hangs, try /ALLUSERS. Some Inno packages show an install-mode page before silent mode starts.'
            $notes = 'The uninstall path is a placeholder; read the registered UninstallString after a test install.'
        }
        elseif (& $contains 'NullsoftInst') {
            $engine = 'nsis'; $label = 'NSIS (Nullsoft Scriptable Install System)'; $confidence = 'medium'
            $commands = @(
                New-WhatSwitchCommand 'Install (silent)' "$fileName /S"
                New-WhatSwitchCommand 'Uninstall (silent)' '"%ProgramFiles%\<App>\Uninstall.exe" /S'
            )
            $modifiers = '/D=C:\Path sets the target and must be last and unquoted.'
            $notes = '/S is case-sensitive. Silent support can be changed by the package author.'
        }
        elseif (& $contains 'InstallShield') {
            $engine = 'installshield'; $label = 'InstallShield'; $confidence = 'medium'
            $commands = @(New-WhatSwitchCommand 'Install (silent)' "$fileName /s /v`"/qn`"")
            $modifiers = '/v"..." forwards arguments to the inner msiexec.'
            $notes = 'Older InstallScript packages can require a recorded setup.iss response file.'
        }
        elseif (& $contains 'Advanced Installer') {
            $engine = 'advanced-installer'; $label = 'Advanced Installer package'; $confidence = 'high'
            $match = [regex]::Match($ascii, 'Advanced Installer\s+([\d][\d.]*)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($match.Success) { $engineVersion = 'Advanced Installer ' + $match.Groups[1].Value }
            $propertyMatches = [regex]::Matches($ascii + "`n" + $wide, '\[([A-Z][A-Z0-9_]{2,})\]')
            $customProperties = @($propertyMatches | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '^(AI_|ARP|WIX_|MSI|SET_|CTRL)' } | Sort-Object -Unique)
            $commands = @(
                New-WhatSwitchCommand 'Install (silent)' "$fileName /exenoui /qn"
                New-WhatSwitchCommand 'Uninstall (silent)' "$fileName /x /exenoui /qn"
                New-WhatSwitchCommand 'Extract the MSI' "$fileName /extract `"C:\Path`""
            )
            $modifiers = '/exenoui · /exebasicui · /exelog · /exenoupdates · /noprereqs · /extract · msiexec arguments'
            $notes = 'Extract the embedded MSI and analyze it separately for the complete public-property list.'
        }
        elseif (& $contains 'Squirrel') {
            $engine = 'squirrel'; $label = 'Squirrel installer'; $confidence = 'medium'
            $commands = @(
                New-WhatSwitchCommand 'Install (silent)' "$fileName --silent"
                New-WhatSwitchCommand 'Uninstall (silent)' '"%LocalAppData%\<App>\Update.exe" --uninstall -s'
            )
            $modifiers = 'Squirrel is normally per-user and should run in the user context.'
            $notes = 'The uninstaller path contains a placeholder for the application directory.'
        }
        elseif (& $contains 'InstallAware') {
            $engine = 'installaware'; $label = 'InstallAware setup'; $confidence = 'medium'
            $commands = @(New-WhatSwitchCommand 'Install (silent)' "$fileName /s")
            $modifiers = '/s · NAME="value" · /l "C:\Windows\Temp\setup.log"'
        }
        elseif ((& $contains 'InstallBuilder') -or (& $contains 'BitRock')) {
            $engine = 'installbuilder'; $label = 'BitRock InstallBuilder'; $confidence = 'medium'
            $commands = @(New-WhatSwitchCommand 'Install (silent)' "$fileName --mode unattended")
            $modifiers = '--mode unattended · --unattendedmodeui none|minimal · --prefix "C:\App"'
        }
        elseif ((& $contains 'WiseMain') -or (& $contains 'Wise Installation')) {
            $engine = 'wise'; $label = 'Wise Installation (legacy)'; $confidence = 'low'
            $commands = @(New-WhatSwitchCommand 'Install (silent)' "$fileName /s")
            $modifiers = '/s is documented, but legacy builds can require /S or a response file.'
        }
        elseif (& $contains '_CorExeMain') {
            $engine = 'dotnet'; $label = 'Custom installer (.NET)'; $confidence = 'low'
            $notes = 'This managed executable defines its own switches. Use -IncludeBestEffort to scan for candidates, then verify them in a disposable VM.'
        }
        elseif ($ascii.IndexOf('Rar!', [StringComparison]::Ordinal) -ge 0) {
            $engine = 'sfx-winrar'; $label = 'WinRAR self-extracting archive'; $confidence = 'medium'
            $commands = @(New-WhatSwitchCommand 'Extract (silent)' "$fileName /S")
            $notes = 'The inner installer has its own silent command.'
        }
        elseif ($ascii.IndexOf([Text.Encoding]::Latin1.GetString([byte[]](0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c)), [StringComparison]::Ordinal) -ge 0) {
            $engine = 'sfx-7z'; $label = '7-Zip self-extracting archive'; $confidence = 'low'
            $notes = 'Extract the archive and identify the inner installer. There is no universal 7-Zip SFX silent-install command.'
        }
        else {
            $engine = 'unknown-exe'; $label = 'Unrecognized installer (custom or packed EXE)'; $confidence = 'none'
            $notes = 'No supported engine signature was found. Use -IncludeBestEffort to scan for candidate switches.'
        }

        $catalogEntry = Find-WhatSwitchCatalogEntry -ProductName $product -FileName $fileName -CatalogPath $CatalogPath
        if ($catalogEntry) {
            # A product-name match is not enough when the curated command targets a different
            # package shape. Example: the 7-Zip MSI reports product name "7-Zip", but the catalog
            # entry is explicitly for the EXE and uses `{file} /S`. Mirror the web implementation's
            # guard: weak engines may use the catalog as a fallback; otherwise msiexec-vs-EXE must
            # agree with the detected engine.
            $weakEngine = $engine -in 'unknown-exe', 'dotnet', 'sfx-7z', 'sfx-winrar' -or $confidence -in 'low', 'none'
            $catalogUsesMsi = ([string]$catalogEntry.install).Trim() -match '^msiexec(?:\.exe)?\b'
            $detectedMsi = $engine -eq 'msi'
            if (-not $weakEngine -and $catalogUsesMsi -ne $detectedMsi) {
                $catalogEntry = $null
            }
        }
        $catalog = $null
        if ($catalogEntry) {
            $catalog = [pscustomobject]@{
                Name = $catalogEntry.name
                InstallCommand = if ($catalogEntry.install) { ([string]$catalogEntry.install).Replace('{file}', $fileName) } else { $null }
                UninstallCommand = if ($catalogEntry.uninstall) { ([string]$catalogEntry.uninstall).Replace('{file}', $fileName) } else { $null }
                DetectionPath = $catalogEntry.detect
                Note = $catalogEntry.note
            }
        }

        $candidateScan = if ($IncludeBestEffort -and $confidence -in 'low', 'none') {
            Find-WhatSwitchSwitch -Path $literalPath -MaximumScanMB ([Math]::Min($MaximumScanMB, 96))
        } else { $null }

        [pscustomobject]@{
            PSTypeName = 'WhatSwitch.Result'
            Path = $literalPath
            FileName = $fileName
            FileSize = $file.Length
            Engine = $engine
            Label = $label
            Confidence = $confidence
            ProductName = $product
            ProductVersion = $version
            CompanyName = $company
            EngineVersion = $engineVersion
            Commands = @($commands)
            Modifiers = $modifiers
            Warning = $warning
            Notes = $notes
            Catalog = $catalog
            CustomProperties = @($customProperties)
            Msi = $msiAnalysis
            BestEffort = $candidateScan
            BytesScanned = $bytes.Length
            WasTruncated = $file.Length -gt $bytes.Length
            AnalyzerVersion = '1.5.0'
        }
    }
}

. (Join-Path $PSScriptRoot 'WhatSwitch.IntuneWin.ps1')
. (Join-Path $PSScriptRoot 'WhatSwitch.Deployment.ps1')

Export-ModuleMember -Function @(
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
