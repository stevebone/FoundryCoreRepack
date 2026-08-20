<#
.SYNOPSIS
    Foundry Core Repack Launcher
.DESCRIPTION
    Downloads and prepares a full TrinityCore server installation from a manifest file.
    Supports first-time install and update modes.
#>

param(
    [string]$ManifestUrl = "https://raw.githubusercontent.com/stevebone/FoundryCoreRepack/refs/heads/main/repack.manifest"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFile = Join-Path $scriptDir "repack.conf"
$manifestFile = Join-Path $scriptDir "repack.manifest"
$manifestTempFile = Join-Path $scriptDir "repack.manifest.tmp"
$sqlRoot = Join-Path $scriptDir "sql"

# ============================================================
# Functions
# ============================================================

function Show-Banner
{
    $banner = @'
 _____                     _               ____               
|  ___|__  _   _ _ __   __| |_ __ _   _   / ___|___  _ __ ___ 
| |_ / _ \| | | | '_ \ / _` | '__| | | | | |   / _ \| '__/ _ \
|  _| (_) | |_| | | | | (_| | |  | |_| | | |__| (_) | | |  __/
|_|  \___/ \__,_|_| |_|\__,_|_|   \__, |  \____\___/|_|  \___|
                                  |___/                       
'@
    Write-Host ""
    Write-Host $banner -ForegroundColor Cyan
    Write-Host "  ==============================================" -ForegroundColor Cyan
    Write-Host "                   Repack Launcher               " -ForegroundColor Yellow
    Write-Host "  ==============================================" -ForegroundColor Cyan
    Write-Host ""
}

function Read-Config
{
    if (Test-Path $configFile)
    {
        $config = @{}
        Get-Content $configFile | ForEach-Object {
            $line = $_.Trim()
            if ($line -and !$line.StartsWith("#") -and $line.Contains("="))
            {
                $parts = $line -split "=", 2
                $config[$parts[0].Trim()] = $parts[1].Trim()
            }
        }
        return $config
    }
    return $null
}

function Write-Config
{
    param(
        [bool]$FirstTime,
        [int]$DbSetup = 0,
        [int]$DataSetup = 0,
        [int]$UpdatesCleaned = 0
    )

    $timestamp = (Get-Date).ToString("o")
    $lines = @()
    $lines += "FirstTimeInstall=1"
    $lines += "LastUpdated=$timestamp"
    $lines += "MySqlDBSetup=$DbSetup"
    $lines += "ServerDataSetup=$DataSetup"
    $lines += "UpdatesCleaned=$UpdatesCleaned"

    $lines | Out-File -FilePath $configFile -Encoding UTF8 -Force
    Write-Host "[Config] repack.conf written: FirstTimeInstall=1, LastUpdated=$timestamp, MySqlDBSetup=$DbSetup, ServerDataSetup=$DataSetup, UpdatesCleaned=$UpdatesCleaned" -ForegroundColor DarkGray
}

function Download-File
{
    param(
        [string]$Url,
        [string]$Destination
    )

    $fileName = [System.IO.Path]::GetFileName([System.Uri]$Url)

    try
    {
        $dir = Split-Path -Parent $Destination
        if ($dir -and !(Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        # Get size first via HEAD request
        $headResp = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing
        $size = $headResp.Headers["Content-Length"]
        $sizeStr = if ($size -ge 1MB) { "{0:N2} MB" -f ($size / 1MB) }
                   elseif ($size -ge 1KB) { "{0:N2} KB" -f ($size / 1KB) }
                   else { "$size B" }

        Write-Host "  Downloading: $fileName ($sizeStr)..." -NoNewline -ForegroundColor White

        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
        Write-Host " Done." -ForegroundColor Green
        return $true
    }
    catch
    {
        Write-Host " FAILED!" -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Parse-Manifest
{
    param([string]$ManifestPath)

    if (!(Test-Path $ManifestPath))
    {
        Write-Host "[Error] Manifest file not found: $ManifestPath" -ForegroundColor Red
        return $null
    }

    $sections = @{
        "zip"    = @{}
        "sql"    = @{}
        "other"  = @{}
        "gdrive" = @{}
        "data"   = @{}
    }

    $currentSection = ""
    Get-Content $ManifestPath | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) {
            return
        }

        if ($line -match '^\[(.+)\]$')
        {
            $currentSection = $Matches[1].ToLower()
            return
        }

        if ($currentSection -and $sections.ContainsKey($currentSection)) {
            # Parse: identifier=[version, url]
            if ($line -match '^(\w+)\s*=\s*\[(.+?),\s*(.+)\]$') {
                $id = $Matches[1].Trim()
                $version = $Matches[2].Trim()
                $url = $Matches[3].Trim()
                $sections[$currentSection][$id] = @{ Version = $version; Url = $url }
            } else {
                Write-Host "[Manifest] Warning: Could not parse line: $line" -ForegroundColor DarkYellow
            }
        }
    }

    return $sections
}

function Compare-Manifest
{
    param(
        $LocalSections,
        $RemoteSections
    )

    $changed = @{
        "zip"    = @{}
        "sql"    = @{}
        "other"  = @{}
        "gdrive" = @{}
        "data"   = @{}
    }

    if (!$LocalSections) {
        Write-Host "[Manifest] No local manifest found - all files will be downloaded." -ForegroundColor DarkYellow
    }

    foreach ($sectionName in $RemoteSections.Keys) {
        $remoteFiles = $RemoteSections[$sectionName]
        $localFiles = if ($LocalSections) { $LocalSections[$sectionName] } else { @{} }

        foreach ($id in $remoteFiles.Keys) {
            $remoteVer = $remoteFiles[$id].Version
            $localEntry = $localFiles[$id]

            if (!$localEntry) {
                Write-Host "[Manifest] $sectionName/${id}: NEW (not in local)" -ForegroundColor DarkYellow
                $changed[$sectionName][$id] = $remoteFiles[$id]
            } elseif ($localEntry.Version -ne $remoteVer) {
                Write-Host "[Manifest] $sectionName/${id}: CHANGED (local='$($localEntry.Version)' remote='$remoteVer')" -ForegroundColor DarkYellow
                $changed[$sectionName][$id] = $remoteFiles[$id]
            } else {
                Write-Host "[Manifest] $sectionName/${id}: up-to-date (v=$remoteVer)" -ForegroundColor DarkGray
            }
        }
    }

    return $changed
}

function Get-SqlRelativePath
{
    param([string]$Url)

    $uri = [System.Uri]$Url
    $segments = $uri.Segments | ForEach-Object { $_.TrimEnd("/") }

    # GitHub raw URL pattern: .../repo/<commit-hash>/path/to/file.sql
    # Find the commit hash segment (40-char hex)
    $commitIndex = -1
    for ($i = 0; $i -lt $segments.Count; $i++)
    {
        if ($segments[$i] -match '^[0-9a-f]{40}$')
        {
            $commitIndex = $i
            break
        }
    }

    if ($commitIndex -ge 0 -and $commitIndex + 1 -lt $segments.Count)
    {
        $relativeSegments = $segments[($commitIndex + 1)..($segments.Count - 1)]
        $relativePath = ($relativeSegments -join "/")
        # If path already starts with sql/, use it as-is; otherwise prepend sql/
        if ($relativePath.StartsWith("sql/")) {
            return $relativePath
        } else {
            return "sql/$relativePath"
        }
    }

    # Non-GitHub URL: just use filename under sql/
    $fileName = [System.IO.Path]::GetFileName($uri)
    return "sql/$fileName"
}

function Download-ZipFiles
{
    param($Files)

    if ($Files.Count -eq 0)
    {
        Write-Host "[ZIP] No zip files to download." -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    Write-Host "[ZIP] Downloading and extracting $($Files.Count) zip file(s)..." -ForegroundColor Cyan

    foreach ($id in $Files.Keys)
    {
        $url = $Files[$id].Url
        $fileName = [System.IO.Path]::GetFileName([System.Uri]$url)
        $tempZip = Join-Path $scriptDir $fileName

        Write-Host "  [$id]" -ForegroundColor Cyan -NoNewline
        if (!(Download-File -Url $url -Destination $tempZip)) {
            continue
        }

        Write-Host "  Extracting: $fileName..." -NoNewline -ForegroundColor White
        try
        {
            Expand-Archive -Path $tempZip -DestinationPath $scriptDir -Force
            Write-Host " Done." -ForegroundColor Green
        }
        catch
        {
            Write-Host " FAILED!" -ForegroundColor Red
            Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        }

        if (Test-Path $tempZip) {
            Remove-Item $tempZip -Force
        }
    }
}

function Download-SqlFiles
{
    param($Files)

    if ($Files.Count -eq 0)
    {
        Write-Host "[SQL] No SQL files to download." -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    Write-Host "[SQL] Downloading $($Files.Count) SQL file(s)..." -ForegroundColor Cyan

    foreach ($id in $Files.Keys)
    {
        $url = $Files[$id].Url
        $relativePath = Get-SqlRelativePath -Url $url
        $destination = Join-Path $scriptDir $relativePath

        # Normalize path separators
        $destination = $destination -replace '/', '\'

        Write-Host "  [$id]" -ForegroundColor Cyan -NoNewline
        Download-File -Url $url -Destination $destination | Out-Null
    }
}

function Download-OtherFiles
{
    param($Files)

    if ($Files.Count -eq 0)
    {
        Write-Host "[Other] No other files to download." -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    Write-Host "[Other] Downloading $($Files.Count) file(s)..." -ForegroundColor Cyan

    foreach ($id in $Files.Keys)
    {
        $url = $Files[$id].Url
        $fileName = [System.IO.Path]::GetFileName([System.Uri]$url)
        $destination = Join-Path $scriptDir $fileName
        Write-Host "  [$id]" -ForegroundColor Cyan -NoNewline
        Download-File -Url $url -Destination $destination | Out-Null
    }
}

function Get-GdriveFileId
{
    param([string]$Url)

    # Match patterns like:
    # https://drive.google.com/file/d/FILE_ID/view?usp=sharing
    # https://drive.google.com/file/d/FILE_ID/edit
    if ($Url -match '/file/d/([a-zA-Z0-9_-]+)') {
        return $Matches[1]
    }
    # Match open?id=FILE_ID pattern
    if ($Url -match '[?&]id=([a-zA-Z0-9_-]+)') {
        return $Matches[1]
    }
    # Fallback: match id= anywhere in the URL
    if ($Url -match 'id=([a-zA-Z0-9_-]+)') {
        return $Matches[1]
    }
    return $null
}

function Download-GdriveFile
{
    param(
        [string]$Url,
        [string]$Destination
    )

    $fileId = Get-GdriveFileId -Url $Url
    if (!$fileId) {
        Write-Host "  FAILED! Could not extract file ID from Google Drive URL." -ForegroundColor Red
        return $false
    }

    $fileName = Split-Path -Leaf $Destination

    try
    {
        $dir = Split-Path -Parent $Destination
        if ($dir -and !(Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        Write-Host "  Downloading: $fileName from Google Drive..." -NoNewline -ForegroundColor White

        $tempFile = [System.IO.Path]::GetTempFileName()
        $session = $null

        # Step 1: Initial request to get the confirmation page (large files)
        $initialUrl = "https://drive.google.com/uc?export=download&id=$fileId"
        Invoke-WebRequest -Uri $initialUrl -OutFile $tempFile -UseBasicParsing -SessionVariable session | Out-Null

        $rawBytes = [System.IO.File]::ReadAllBytes($tempFile)
        $content = [System.Text.Encoding]::UTF8.GetString($rawBytes)

        # Check if we got the actual file or an HTML confirmation page
        $isHtml = $content -match '<html' -or $content -match '<!DOCTYPE'

        if ($isHtml) {
            Write-Host " (confirming)..." -NoNewline -ForegroundColor DarkYellow

            # Extract uuid from the HTML form
            $uuid = $null
            if ($content -match 'name="uuid"\s+value="([^"]+)"') {
                $uuid = $Matches[1]
            }

            # Build the real download URL using the new endpoint
            $downloadUrl = "https://drive.usercontent.google.com/download?id=$fileId&export=download&confirm=t"
            if ($uuid) {
                $downloadUrl += "&uuid=$uuid"
            }

            Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -WebSession $session -UseBasicParsing | Out-Null

            # Verify we got the actual file this time
            $rawBytes = [System.IO.File]::ReadAllBytes($tempFile)
            $content = [System.Text.Encoding]::UTF8.GetString($rawBytes)

            if ($content -match '<html' -or $content -match '<!DOCTYPE') {
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                Write-Host " FAILED!" -ForegroundColor Red
                Write-Host "  Error: Could not bypass Google Drive confirmation page." -ForegroundColor Red
                return $false
            }
        }

        # Move temp file to destination
        Move-Item -Path $tempFile -Destination $Destination -Force
        $size = (Get-Item $Destination).Length
        $sizeStr = if ($size -ge 1MB) { "{0:N2} MB" -f ($size / 1MB) }
                   elseif ($size -ge 1KB) { "{0:N2} KB" -f ($size / 1KB) }
                   else { "$size B" }
        Write-Host " Done ($sizeStr)." -ForegroundColor Green
        return $true
    }
    catch
    {
        Write-Host " FAILED!" -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Download-GdriveFiles
{
    param($Files)

    if ($Files.Count -eq 0)
    {
        Write-Host "[GDrive] No Google Drive files to download." -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    Write-Host "[GDrive] Downloading and extracting $($Files.Count) zip file(s) from Google Drive..." -ForegroundColor Cyan

    foreach ($id in $Files.Keys)
    {
        $url = $Files[$id].Url
        $tempZip = Join-Path $scriptDir "$id.zip"

        Write-Host "  [$id]" -ForegroundColor Cyan -NoNewline
        if (!(Download-GdriveFile -Url $url -Destination $tempZip)) {
            continue
        }

        Write-Host "  Extracting: $id.zip..." -NoNewline -ForegroundColor White
        try
        {
            Expand-Archive -Path $tempZip -DestinationPath $scriptDir -Force
            Write-Host " Done." -ForegroundColor Green
        }
        catch
        {
            Write-Host " FAILED!" -ForegroundColor Red
            Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        }

        if (Test-Path $tempZip) {
            Remove-Item $tempZip -Force
        }
    }
}

# ============================================================
# Main
# ============================================================

Show-Banner

# Step 2: Check for repack.conf
$config = Read-Config
$isFirstTime = $null -eq $config

if ($isFirstTime)
{
    Write-Host ">> First-time installation detected." -ForegroundColor Yellow
    Write-Host ">> repack.conf not found. This will be a full install." -ForegroundColor Yellow
}
else
{
    $lastUpdated = $config["LastUpdated"]
    Write-Host ">> Update mode. Previous install detected." -ForegroundColor Yellow
    if ($lastUpdated) {
        Write-Host ">> Last updated: $lastUpdated" -ForegroundColor DarkGray
    }
}

Write-Host ""

# Step 3: Parse local manifest (if exists) before downloading remote
$localSections = $null
if (Test-Path $manifestFile) {
    Write-Host "[Manifest] Found existing local manifest. Parsing for version comparison..." -ForegroundColor DarkGray
    $localSections = Parse-Manifest -ManifestPath $manifestFile
}

# Step 3b: Download remote manifest to temp file
Write-Host "[Manifest] Downloading remote repack.manifest..." -ForegroundColor Cyan
if (!(Download-File -Url $ManifestUrl -Destination $manifestTempFile))
{
    Write-Host "[Error] Failed to download manifest. Aborting." -ForegroundColor Red
    exit 1
}

# Step 4: Parse remote manifest
$sections = Parse-Manifest -ManifestPath $manifestTempFile
if ($null -eq $sections)
{
    Write-Host "[Error] Failed to parse manifest. Aborting." -ForegroundColor Red
    exit 1
}

# Step 4b: Compare local vs remote
$changed = Compare-Manifest -LocalSections $localSections -RemoteSections $sections

$zipTotal = $sections["zip"].Count
$sqlTotal = $sections["sql"].Count
$otherTotal = $sections["other"].Count
$gdriveTotal = $sections["gdrive"].Count
$dataTotal = $sections["data"].Count

$zipChanged = $changed["zip"].Count
$sqlChanged = $changed["sql"].Count
$otherChanged = $changed["other"].Count
$gdriveChanged = $changed["gdrive"].Count
$dataChanged = $changed["data"].Count

$zipSkipped = $zipTotal - $zipChanged
$sqlSkipped = $sqlTotal - $sqlChanged
$otherSkipped = $otherTotal - $otherChanged
$gdriveSkipped = $gdriveTotal - $gdriveChanged

Write-Host ""
Write-Host "[Manifest] Parsed successfully:" -ForegroundColor Cyan
Write-Host "  ZIP files:    $zipTotal ($zipChanged changed, $zipSkipped up-to-date)" -ForegroundColor White
Write-Host "  SQL files:    $sqlTotal ($sqlChanged changed, $sqlSkipped up-to-date)" -ForegroundColor White
Write-Host "  Other files:  $otherTotal ($otherChanged changed, $otherSkipped up-to-date)" -ForegroundColor White
Write-Host "  GDrive files: $gdriveTotal ($gdriveChanged changed, $gdriveSkipped up-to-date)" -ForegroundColor White
Write-Host "  Data files:   $dataTotal" -ForegroundColor White

# Step 5: Download only changed files
Download-ZipFiles -Files $changed["zip"]
Download-GdriveFiles -Files $changed["gdrive"]
Download-SqlFiles -Files $changed["sql"]
Download-OtherFiles -Files $changed["other"]

# Save remote manifest as local for next run's comparison
Move-Item -Path $manifestTempFile -Destination $manifestFile -Force

# Step 6: Summary
Write-Host ""
Write-Host ("=" * 80) -ForegroundColor DarkCyan
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "  ZIP files:    $zipChanged downloaded, $zipSkipped skipped" -ForegroundColor White
Write-Host "  GDrive files: $gdriveChanged downloaded, $gdriveSkipped skipped" -ForegroundColor White
Write-Host "  SQL files:    $sqlChanged downloaded, $sqlSkipped skipped" -ForegroundColor White
Write-Host "  Other files:  $otherChanged downloaded, $otherSkipped skipped" -ForegroundColor White
Write-Host ""

Write-Host ""
if ($isFirstTime) {
    Write-Host ">> First-time installation complete!" -ForegroundColor Green
} else {
    Write-Host ">> Update complete!" -ForegroundColor Green
}

Write-Host ("=" * 80) -ForegroundColor DarkCyan

# Step 8: Server Data Setup
$dataSetupDone = $false
if (!$isFirstTime -and $config["ServerDataSetup"] -eq "1") {
    $dataSetupDone = $true
}

if ($dataSetupDone) {
    Write-Host ""
    Write-Host "[Data] Server data already set up (ServerDataSetup=1 in repack.conf). Skipping." -ForegroundColor DarkGray
} else {
    Write-Host ""
    Write-Host "Server Data Setup" -ForegroundColor Cyan
    Write-Host "How do you want to add the Server Data like Maps, Vmaps, MMaps, DB2 etc?" -ForegroundColor Yellow
    Write-Host "  1. Automatic Download - use this option if your internet is fast or your computer is low end" -ForegroundColor White
    Write-Host "  2. Extraction from game client (requires client on this machine)" -ForegroundColor White
    Write-Host "  3. Manual: I will add them myself later in the Data directory." -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "Enter your choice (1/2/3)"

    $dataDir = Join-Path $scriptDir "Data"
    $extractorsDir = Join-Path $scriptDir "Extractors"

    switch ($choice)
    {
    "1"
    {
        Write-Host ""
        Write-Host "[Data] Downloading data files from Google Drive..." -ForegroundColor Cyan
        if ($dataTotal -eq 0) {
            Write-Host "[Data] No data files found in manifest. Skipping." -ForegroundColor DarkGray
        } else {
            Download-GdriveFiles -Files $changed["data"]
            Write-Host "[Data] Data files downloaded and extracted." -ForegroundColor Green
        }
    }
    "2"
    {
        Write-Host ""
        Write-Host "[Data] Extraction from game client" -ForegroundColor Cyan
        $clientPath = Read-Host "Enter the FULL path to your World of Warcraft game client installation"
        if (!(Test-Path $clientPath)) {
            Write-Host "[Error] Path not found: $clientPath" -ForegroundColor Red
            Write-Host "[Data] Skipping extraction." -ForegroundColor DarkGray
            break
        }

        if (!(Test-Path $dataDir)) {
            New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
        }

        $mapExtractor = Join-Path $extractorsDir "mapextractor.exe"
        $vmapExtractor = Join-Path $extractorsDir "vmap4extractor.exe"
        $vmapAssembler = Join-Path $extractorsDir "vmap4assembler.exe"
        $mmapsGenerator = Join-Path $extractorsDir "mmaps_generator.exe"

        $buildingsDir = Join-Path $extractorsDir "Buildings"
        $vmapsDir = Join-Path $dataDir "vmaps"
        $mmapsDir = Join-Path $dataDir "mmaps"

        # Helper: check if a directory exists and has files
        function Test-DirHasFiles($path) {
            return (Test-Path $path) -and (Get-ChildItem -Path $path -Recurse -File | Measure-Object).Count -gt 0
        }

        # Step 1: map_extractor (output: Data/*.map, Data/*.db2, etc.)
        Write-Host ""
        Write-Host "[Data] Step 1/4: mapextractor" -ForegroundColor Cyan
        if (Test-DirHasFiles $dataDir) {
            Write-Host "[Data] Skipping mapextractor - Data directory already has files." -ForegroundColor DarkGray
        } elseif (Test-Path $mapExtractor) {
            & $mapExtractor "-i" $clientPath "-o" $dataDir
            Write-Host "[Data] mapextractor complete." -ForegroundColor Green
        } else {
            Write-Host "[Data] mapextractor.exe not found in $extractorsDir. Skipping." -ForegroundColor Red
        }

        # Step 2: vmap4_extractor (output: extractors/Buildings/)
        Write-Host ""
        Write-Host "[Data] Step 2/4: vmap4extractor" -ForegroundColor Cyan
        if (Test-DirHasFiles $buildingsDir) {
            Write-Host "[Data] Skipping vmap4extractor - Buildings directory already has files." -ForegroundColor DarkGray
        } elseif (Test-Path $vmapExtractor) {
            Push-Location $extractorsDir
            & $vmapExtractor "-d" $clientPath
            Pop-Location
            Write-Host "[Data] vmap4extractor complete." -ForegroundColor Green
        } else {
            Write-Host "[Data] vmap4extractor.exe not found in $extractorsDir. Skipping." -ForegroundColor Red
        }

        # Step 3: vmap4_assembler (output: Data/vmaps/)
        Write-Host ""
        Write-Host "[Data] Step 3/4: vmap4assembler" -ForegroundColor Cyan
        if (Test-DirHasFiles $vmapsDir) {
            Write-Host "[Data] Skipping vmap4assembler - vmaps directory already has files." -ForegroundColor DarkGray
        } elseif (Test-Path $vmapAssembler) {
            if (!(Test-Path $vmapsDir)) {
                New-Item -ItemType Directory -Path $vmapsDir -Force | Out-Null
            }
            & $vmapAssembler $buildingsDir $vmapsDir
            Write-Host "[Data] vmap4assembler complete." -ForegroundColor Green
        } else {
            Write-Host "[Data] vmap4assembler.exe not found in $extractorsDir. Skipping." -ForegroundColor Red
        }

        # Step 4: mmaps_generator (output: Data/mmaps/)
        Write-Host ""
        Write-Host "[Data] Step 4/4: mmaps_generator" -ForegroundColor Cyan
        if (Test-DirHasFiles $mmapsDir) {
            Write-Host "[Data] Skipping mmaps_generator - mmaps directory already has files." -ForegroundColor DarkGray
        } elseif (Test-Path $mmapsGenerator) {
            & $mmapsGenerator "--input" $dataDir "--output" $dataDir
            Write-Host "[Data] mmaps_generator complete." -ForegroundColor Green
        } else {
            Write-Host "[Data] mmaps_generator.exe not found in $extractorsDir. Skipping." -ForegroundColor Red
        }

        Write-Host ""
        Write-Host "[Data] Extraction complete. Files saved to $dataDir" -ForegroundColor Green
    }
    "3"
    {
        Write-Host ""
        if (!(Test-Path $dataDir)) {
            New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
        }
        Write-Host "[Data] You chose to add data files manually later." -ForegroundColor Yellow
        Write-Host "[Data] Place your Maps, Vmaps, MMaps, DB2 files in: $dataDir" -ForegroundColor Yellow
    }
    default
    {
        Write-Host ""
        Write-Host "[Data] Invalid choice. Skipping data setup." -ForegroundColor Red
    }
}
    $dataSetupDone = $true
}

# Step 9: MySQL Startup
Write-Host ""
Write-Host ("=" * 80) -ForegroundColor DarkCyan
Write-Host "Starting MySQL for Database setup." -ForegroundColor Cyan

$mysqlDir = Join-Path $scriptDir "Dep\mysql"
$mysqldExe = Join-Path $mysqlDir "bin\mysqld.exe"
$myIni = Join-Path $mysqlDir "my.ini"

if (Test-Path $mysqldExe) {
    if (Test-Path $myIni) {
        Write-Host "[MySQL] Starting mysqld with config: $myIni" -ForegroundColor White
        Push-Location $mysqlDir
        Start-Process -FilePath $mysqldExe -ArgumentList "--defaults-file=`"$myIni`"" -NoNewWindow -PassThru | Out-Null
        Pop-Location
        Write-Host "[MySQL] mysqld started." -ForegroundColor Green
    } else {
        Write-Host "[MySQL] Config file not found: $myIni" -ForegroundColor Red
        Write-Host "[MySQL] Starting mysqld without config..." -ForegroundColor Yellow
        Push-Location $mysqlDir
        Start-Process -FilePath $mysqldExe -NoNewWindow -PassThru | Out-Null
        Pop-Location
        Write-Host "[MySQL] mysqld started (no config)." -ForegroundColor Green
    }
} else {
    Write-Host "[MySQL] mysqld.exe not found at: $mysqldExe" -ForegroundColor Red
    Write-Host "[MySQL] Skipping MySQL startup." -ForegroundColor DarkGray
}

# Step 10: Database Setup
$mysqlExe = Join-Path $mysqlDir "bin\mysql.exe"
$setupSql = Join-Path $scriptDir "Sql\setup\create_mysql.sql"
$dbSetupDone = $false
if (!$isFirstTime -and $config["MySqlDBSetup"] -eq "1") {
    $dbSetupDone = $true
}

if ($dbSetupDone) {
    Write-Host ""
    Write-Host "[DB] Database already set up (MySqlDBSetup=1 in repack.conf). Skipping." -ForegroundColor DarkGray
} elseif (Test-Path $mysqlExe) {
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor DarkCyan
    Write-Host "Setting up database..." -ForegroundColor Cyan
    Write-Host "Waiting for MySQL to be ready..." -ForegroundColor White

    $mysqlReady = $false
    $maxRetries = 60
    $retryCount = 0

    while (!$mysqlReady -and $retryCount -lt $maxRetries) {
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $result = & $mysqlExe -u root -proot -e "SELECT 1;" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $mysqlReady = $true
            } else {
                $retryCount++
                if ($retryCount -le 3 -or $retryCount % 10 -eq 0) {
                    Write-Host "[DB] Waiting... ($retryCount/$maxRetries) $result" -ForegroundColor DarkGray
                }
                Start-Sleep -Seconds 1
            }
        } catch {
            $retryCount++
            if ($retryCount -le 3 -or $retryCount % 10 -eq 0) {
                Write-Host "[DB] Waiting... ($retryCount/$maxRetries) $($_.Exception.Message)" -ForegroundColor DarkGray
            }
            Start-Sleep -Seconds 1
        }
        $ErrorActionPreference = $prevEAP
    }

    if ($mysqlReady) {
        Write-Host "[DB] MySQL is ready!" -ForegroundColor Green

        if (Test-Path $setupSql) {
            Write-Host "[DB] Running SQL setup file: $setupSql" -ForegroundColor White
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            Get-Content $setupSql -Raw | & $mysqlExe -u root -proot 2>&1 | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
            $ErrorActionPreference = $prevEAP
            Write-Host "[DB] Database setup complete!" -ForegroundColor Green
            $dbSetupDone = $true
        } else {
            Write-Host "[DB] Setup SQL file not found: $setupSql" -ForegroundColor Red
        }
    } else {
        Write-Host "[DB] MySQL did not become ready after $maxRetries seconds." -ForegroundColor Red
        Write-Host "[DB] Skipping database setup." -ForegroundColor DarkGray
    }
} else {
    Write-Host ""
    Write-Host "[DB] mysql.exe not found at: $mysqlExe" -ForegroundColor Red
    Write-Host "[DB] Skipping database setup." -ForegroundColor DarkGray
}

# Update repack.conf with DB setup and data setup status
$updatesCleanedVal = if ($config -and $config["UpdatesCleaned"] -eq "1") { 1 } else { 0 }
Write-Config -FirstTime $isFirstTime -DbSetup $(if ($dbSetupDone) { 1 } else { 0 }) -DataSetup $(if ($dataSetupDone) { 1 } else { 0 }) -UpdatesCleaned $updatesCleanedVal

Write-Host ""
Write-Host ("=" * 80) -ForegroundColor DarkCyan

# Step 11: Server Launcher Menu
$serverDir = Join-Path $scriptDir "Server"
$bnetExe = Join-Path $serverDir "bnetserver.exe"
$worldExe = Join-Path $serverDir "worldserver.exe"

function Run-UpdatesCleanup
{
    $mysqlExeCheck = Join-Path $mysqlDir "bin\mysql.exe"
    $cleanupSql = Join-Path $scriptDir "sql\Fixes\updates_cleanup.sql"

    if (!(Test-Path $cleanupSql)) {
        Write-Host "[Updates] Cleanup SQL file not found: $cleanupSql" -ForegroundColor Red
        return
    }

    Write-Host "[Updates] Running updates cleanup SQL..." -ForegroundColor Cyan

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    Get-Content $cleanupSql -Raw | & $mysqlExeCheck -u root -proot 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    $ErrorActionPreference = $prevEAP

    Write-Host "[Updates] Cleanup complete." -ForegroundColor Green
}

function Ensure-MySQLRunning
{
    Write-Host "Checking if MySQL is running..." -ForegroundColor White
    $mysqlProc = Get-Process -Name "mysqld" -ErrorAction SilentlyContinue
    if ($mysqlProc) {
        Write-Host "[MySQL] MySQL is already running." -ForegroundColor Green
    } else {
        Write-Host "MySQL is not running. Attempting to start the MySQL server." -ForegroundColor Yellow

        if (!(Test-Path $mysqldExe)) {
            Write-Host "[MySQL] mysqld.exe not found at: $mysqldExe" -ForegroundColor Red
            return $false
        }

        if (Test-Path $myIni) {
            Push-Location $mysqlDir
            Start-Process -FilePath $mysqldExe -ArgumentList "--defaults-file=`"$myIni`"" -NoNewWindow -PassThru | Out-Null
            Pop-Location
        } else {
            Push-Location $mysqlDir
            Start-Process -FilePath $mysqldExe -NoNewWindow -PassThru | Out-Null
            Pop-Location
        }

        Write-Host "[MySQL] Waiting for MySQL to be ready..." -ForegroundColor White
        $mysqlExeCheck = Join-Path $mysqlDir "bin\mysql.exe"
        $mysqlReady = $false
        $maxRetries = 60
        $retryCount = 0

        while (!$mysqlReady -and $retryCount -lt $maxRetries) {
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $result = & $mysqlExeCheck -u root -proot -e "SELECT 1;" 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $mysqlReady = $true
                } else {
                    $retryCount++
                    Start-Sleep -Seconds 1
                }
            } catch {
                $retryCount++
                Start-Sleep -Seconds 1
            }
            $ErrorActionPreference = $prevEAP
        }

        if (!$mysqlReady) {
            Write-Host "[MySQL] MySQL did not become ready after $maxRetries seconds." -ForegroundColor Red
            return $false
        }

        Write-Host "[MySQL] MySQL is ready!" -ForegroundColor Green
    }

    # Run updates cleanup once (if not already done per config)
    $currentConfig = Read-Config
    if (!$currentConfig -or $currentConfig["UpdatesCleaned"] -ne "1") {
        Run-UpdatesCleanup
        Write-Config -FirstTime $isFirstTime -DbSetup $(if ($dbSetupDone) { 1 } else { 0 }) -DataSetup $(if ($dataSetupDone) { 1 } else { 0 }) -UpdatesCleaned 1
        Write-Host "[Updates] UpdatesCleaned flag set to 1 in repack.conf." -ForegroundColor DarkGray
    }

    return $true
}

while ($true) {
    Write-Host ""
    Write-Host "Repack Ready. What do you want to do?" -ForegroundColor Cyan
    Write-Host "  1. Start BnetServer" -ForegroundColor White
    Write-Host "  2. Start WorldServer" -ForegroundColor White
    Write-Host "  3. Start Both Servers" -ForegroundColor White
    Write-Host "  4. Server Operations" -ForegroundColor White
    Write-Host "  5. Exit" -ForegroundColor White
    Write-Host ""
    $mainChoice = Read-Host "Enter your choice (1/2/3/4/5)"

    switch ($mainChoice) {
        "1" {
            if (!(Ensure-MySQLRunning)) {
                Write-Host "[Server] Cannot start BnetServer without MySQL." -ForegroundColor Red
                break
            }
            if (Test-Path $bnetExe) {
                Write-Host "[Server] Starting BnetServer..." -ForegroundColor Green
                Start-Process -FilePath $bnetExe -WorkingDirectory $serverDir
            } else {
                Write-Host "[Server] bnetserver.exe not found at: $bnetExe" -ForegroundColor Red
            }
        }
        "2" {
            if (!(Ensure-MySQLRunning)) {
                Write-Host "[Server] Cannot start WorldServer without MySQL." -ForegroundColor Red
                break
            }
            if (Test-Path $worldExe) {
                Write-Host "[Server] Starting WorldServer..." -ForegroundColor Green
                Start-Process -FilePath $worldExe -WorkingDirectory $serverDir
            } else {
                Write-Host "[Server] worldserver.exe not found at: $worldExe" -ForegroundColor Red
            }
        }
        "3" {
            if (!(Ensure-MySQLRunning)) {
                Write-Host "[Server] Cannot start servers without MySQL." -ForegroundColor Red
                break
            }
            if (Test-Path $bnetExe) {
                Write-Host "[Server] Starting BnetServer..." -ForegroundColor Green
                Start-Process -FilePath $bnetExe -WorkingDirectory $serverDir
            } else {
                Write-Host "[Server] bnetserver.exe not found at: $bnetExe" -ForegroundColor Red
            }
            if (Test-Path $worldExe) {
                Write-Host "[Server] Starting WorldServer..." -ForegroundColor Green
                Start-Process -FilePath $worldExe -WorkingDirectory $serverDir
            } else {
                Write-Host "[Server] worldserver.exe not found at: $worldExe" -ForegroundColor Red
            }
        }
        "4" {
            while ($true) {
                Write-Host ""
                Write-Host "Server Operations:" -ForegroundColor Cyan
                Write-Host "  1. Kill MySQL Process" -ForegroundColor White
                Write-Host "  2. Back" -ForegroundColor White
                Write-Host ""
                $opsChoice = Read-Host "Enter your choice (1/2)"

                switch ($opsChoice) {
                    "1" {
                        $mysqlProc = Get-Process -Name "mysqld" -ErrorAction SilentlyContinue
                        if ($mysqlProc) {
                            Write-Host "[Ops] Stopping MySQL process..." -ForegroundColor Yellow
                            $mysqlProc | Stop-Process -Force
                            Write-Host "[Ops] MySQL process stopped." -ForegroundColor Green
                        } else {
                            Write-Host "[Ops] MySQL process is not running." -ForegroundColor DarkGray
                        }
                    }
                    "2" {
                        break
                    }
                    default {
                        Write-Host "[Ops] Invalid choice." -ForegroundColor Red
                    }
                }
                if ($opsChoice -eq "2") { break }
            }
        }
        "5" {
            Write-Host "[Server] Exiting." -ForegroundColor Yellow
            exit
        }
        default {
            Write-Host "[Server] Invalid choice." -ForegroundColor Red
        }
    }
}
