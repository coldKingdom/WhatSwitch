#requires -Version 7.6

Set-StrictMode -Version Latest

function New-WhatSwitchIntuneWinPackage {
    <#
    .SYNOPSIS
    Creates an Intune Win32 content package without invoking an external packager.

    .DESCRIPTION
    The package contains a ZIP payload protected with AES-256-CBC and HMAC-SHA256, plus the
    Detection.xml metadata consumed by Microsoft Intune. By default only the selected setup file
    is included. Use IncludeSourceFolder when the installer depends on adjacent files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$SetupFile,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string]$SourceFolder,

        [switch]$IncludeSourceFolder,

        [ValidateNotNullOrEmpty()]
        [string]$ApplicationName = [IO.Path]::GetFileNameWithoutExtension($SetupFile)
    )

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

    $resolvedSetup = (Resolve-Path -LiteralPath $SetupFile -ErrorAction Stop).Path
    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    if ([IO.Path]::GetExtension($resolvedOutput) -ine '.intunewin') {
        $resolvedOutput += '.intunewin'
    }
    $outputDirectory = Split-Path -Parent $resolvedOutput
    if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
        $outputDirectory = (Get-Location).Path
        $resolvedOutput = Join-Path $outputDirectory ([IO.Path]::GetFileName($resolvedOutput))
    }
    [void](New-Item -ItemType Directory -Path $outputDirectory -Force)

    $files = [Collections.Generic.List[object]]::new()
    if ($IncludeSourceFolder) {
        if ([string]::IsNullOrWhiteSpace($SourceFolder)) {
            throw 'SourceFolder krävs när IncludeSourceFolder används.'
        }
        $resolvedSource = (Resolve-Path -LiteralPath $SourceFolder -ErrorAction Stop).Path.TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        )
        $sourcePrefix = $resolvedSource + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedSetup.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Setupfilen måste ligga i den valda källmappen eller i en av dess undermappar.'
        }
        if ($resolvedOutput.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Utdatamappen får inte ligga inuti källmappen eftersom paketet då kan inkludera sig självt.'
        }

        $enumerationOptions = [IO.EnumerationOptions]::new()
        $enumerationOptions.RecurseSubdirectories = $true
        $enumerationOptions.IgnoreInaccessible = $false
        $enumerationOptions.AttributesToSkip = [IO.FileAttributes]::ReparsePoint
        foreach ($path in [IO.Directory]::EnumerateFiles($resolvedSource, '*', $enumerationOptions)) {
            $file = [IO.FileInfo]::new($path)
            $relative = [IO.Path]::GetRelativePath($resolvedSource, $file.FullName).Replace('\', '/')
            $files.Add([pscustomobject]@{ File = $file; EntryName = $relative })
        }
        $setupEntryName = [IO.Path]::GetRelativePath($resolvedSource, $resolvedSetup).Replace('/', '\')
    }
    else {
        $setupItem = Get-Item -LiteralPath $resolvedSetup
        $files.Add([pscustomobject]@{ File = $setupItem; EntryName = $setupItem.Name })
        $setupEntryName = $setupItem.Name
        $resolvedSource = $setupItem.DirectoryName
    }

    if ($files.Count -eq 0) { throw 'Källmappen innehåller inga filer att paketera.' }
    [long]$totalSourceSize = 0
    foreach ($record in $files) { $totalSourceSize += $record.File.Length }
    if ($totalSourceSize -gt 30GB) {
        throw 'Källinnehållet är större än Intunes maximala paketstorlek på 30 GB.'
    }

    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) 'WhatSwitchIntuneWin'
    [void](New-Item -ItemType Directory -Path $temporaryRoot -Force)
    $temporaryPath = Join-Path $temporaryRoot ([guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $temporaryPath)
    $temporaryPrefix = ([IO.Path]::GetFullPath($temporaryRoot)).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

    try {
        $payloadPath = Join-Path $temporaryPath 'payload.zip'
        $payloadStream = [IO.File]::Open($payloadPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $payloadArchive = [IO.Compression.ZipArchive]::new($payloadStream, [IO.Compression.ZipArchiveMode]::Create, $true)
            try {
                foreach ($record in $files) {
                    $entry = $payloadArchive.CreateEntry($record.EntryName, [IO.Compression.CompressionLevel]::Optimal)
                    $entry.LastWriteTime = $record.File.LastWriteTime
                    $sourceStream = $record.File.OpenRead()
                    $entryStream = $entry.Open()
                    try { $sourceStream.CopyTo($entryStream) }
                    finally {
                        $entryStream.Dispose()
                        $sourceStream.Dispose()
                    }
                }
            }
            finally { $payloadArchive.Dispose() }
        }
        finally { $payloadStream.Dispose() }

        $payloadInfo = Get-Item -LiteralPath $payloadPath
        $sha256 = [Security.Cryptography.SHA256]::Create()
        $digestStream = $payloadInfo.OpenRead()
        try { $payloadDigest = $sha256.ComputeHash($digestStream) }
        finally {
            $digestStream.Dispose()
            $sha256.Dispose()
        }

        $aesKey = [byte[]]::new(32)
        $macKey = [byte[]]::new(32)
        $initializationVector = [byte[]]::new(16)
        [Security.Cryptography.RandomNumberGenerator]::Fill($aesKey)
        [Security.Cryptography.RandomNumberGenerator]::Fill($macKey)
        [Security.Cryptography.RandomNumberGenerator]::Fill($initializationVector)

        $encryptedPath = Join-Path $temporaryPath 'IntunePackage.intunewin'
        $encryptedStream = [IO.File]::Open($encryptedPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            # Reserve the first 32 bytes for the HMAC, then write IV + ciphertext.
            $encryptedStream.Position = 32
            $encryptedStream.Write($initializationVector, 0, $initializationVector.Length)
            $aes = [Security.Cryptography.Aes]::Create()
            try {
                $aes.KeySize = 256
                $aes.BlockSize = 128
                $aes.Mode = [Security.Cryptography.CipherMode]::CBC
                $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
                $aes.Key = $aesKey
                $aes.IV = $initializationVector
                $encryptor = $aes.CreateEncryptor()
                $cryptoStream = [Security.Cryptography.CryptoStream]::new(
                    $encryptedStream,
                    $encryptor,
                    [Security.Cryptography.CryptoStreamMode]::Write,
                    $true
                )
                $plainStream = $payloadInfo.OpenRead()
                try {
                    $plainStream.CopyTo($cryptoStream)
                    $cryptoStream.FlushFinalBlock()
                }
                finally {
                    $plainStream.Dispose()
                    $cryptoStream.Dispose()
                    $encryptor.Dispose()
                }
            }
            finally { $aes.Dispose() }

            $encryptedStream.Flush()
            $encryptedStream.Position = 32
            $hmac = [Security.Cryptography.HMACSHA256]::new($macKey)
            try { $mac = $hmac.ComputeHash($encryptedStream) }
            finally { $hmac.Dispose() }
            $encryptedStream.Position = 0
            $encryptedStream.Write($mac, 0, $mac.Length)
            $encryptedStream.Flush()
        }
        finally { $encryptedStream.Dispose() }

        $xmlStream = [IO.MemoryStream]::new()
        $xmlSettings = [Xml.XmlWriterSettings]::new()
        $xmlSettings.Encoding = [Text.UTF8Encoding]::new($false)
        $xmlSettings.Indent = $true
        $xmlWriter = [Xml.XmlWriter]::Create($xmlStream, $xmlSettings)
        try {
            $xmlWriter.WriteStartDocument()
            $xmlWriter.WriteStartElement('ApplicationInfo')
            $xmlWriter.WriteAttributeString('xmlns', 'xsd', $null, 'http://www.w3.org/2001/XMLSchema')
            $xmlWriter.WriteAttributeString('xmlns', 'xsi', $null, 'http://www.w3.org/2001/XMLSchema-instance')
            $xmlWriter.WriteAttributeString('ToolVersion', '1.8.6.0')
            $xmlWriter.WriteElementString('Name', $ApplicationName)
            $xmlWriter.WriteElementString('UnencryptedContentSize', $payloadInfo.Length.ToString([Globalization.CultureInfo]::InvariantCulture))
            $xmlWriter.WriteElementString('FileName', 'IntunePackage.intunewin')
            $xmlWriter.WriteElementString('SetupFile', $setupEntryName)
            $xmlWriter.WriteStartElement('EncryptionInfo')
            $xmlWriter.WriteElementString('EncryptionKey', [Convert]::ToBase64String($aesKey))
            $xmlWriter.WriteElementString('MacKey', [Convert]::ToBase64String($macKey))
            $xmlWriter.WriteElementString('InitializationVector', [Convert]::ToBase64String($initializationVector))
            $xmlWriter.WriteElementString('Mac', [Convert]::ToBase64String($mac))
            $xmlWriter.WriteElementString('ProfileIdentifier', 'ProfileVersion1')
            $xmlWriter.WriteElementString('FileDigest', [Convert]::ToBase64String($payloadDigest))
            $xmlWriter.WriteElementString('FileDigestAlgorithm', 'SHA256')
            $xmlWriter.WriteEndElement()
            $xmlWriter.WriteEndElement()
            $xmlWriter.WriteEndDocument()
            $xmlWriter.Flush()
            $detectionXml = $xmlStream.ToArray()
        }
        finally {
            $xmlWriter.Dispose()
            $xmlStream.Dispose()
        }

        $temporaryPackage = Join-Path $temporaryPath 'package.intunewin'
        $packageStream = [IO.File]::Open($temporaryPackage, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $packageArchive = [IO.Compression.ZipArchive]::new($packageStream, [IO.Compression.ZipArchiveMode]::Create, $true)
            try {
                $metadataEntry = $packageArchive.CreateEntry('IntuneWinPackage/Metadata/Detection.xml', [IO.Compression.CompressionLevel]::NoCompression)
                $metadataStream = $metadataEntry.Open()
                try { $metadataStream.Write($detectionXml, 0, $detectionXml.Length) }
                finally { $metadataStream.Dispose() }

                $contentEntry = $packageArchive.CreateEntry('IntuneWinPackage/Contents/IntunePackage.intunewin', [IO.Compression.CompressionLevel]::NoCompression)
                $contentStream = $contentEntry.Open()
                $encryptedInput = [IO.File]::OpenRead($encryptedPath)
                try { $encryptedInput.CopyTo($contentStream) }
                finally {
                    $encryptedInput.Dispose()
                    $contentStream.Dispose()
                }
            }
            finally { $packageArchive.Dispose() }
        }
        finally { $packageStream.Dispose() }

        Move-Item -LiteralPath $temporaryPackage -Destination $resolvedOutput -Force
        $outputItem = Get-Item -LiteralPath $resolvedOutput
        [pscustomobject]@{
            PSTypeName = 'WhatSwitch.IntuneWinPackage'
            Path = $outputItem.FullName
            SetupFile = $setupEntryName
            SourceFolder = $resolvedSource
            FileCount = $files.Count
            SourceSize = $totalSourceSize
            PackageSize = $outputItem.Length
            Sha256 = (Get-FileHash -LiteralPath $outputItem.FullName -Algorithm SHA256).Hash
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            $candidate = [IO.Path]::GetFullPath($temporaryPath)
            if ($candidate.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
