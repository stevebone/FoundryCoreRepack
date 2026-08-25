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
Add-Type -AssemblyName System.Net.Http
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptVersion = "22082026-02"
$configFile = Join-Path $scriptDir "repack.conf"
$manifestFile = Join-Path $scriptDir "repack.manifest"
$manifestTempFile = Join-Path $scriptDir "repack.manifest.tmp"

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
        [int]$DataSetup = 0,
        [int]$GenAISetup = 0,
        [int]$GenAIEnable = 0
    )

    $timestamp = (Get-Date).ToString("o")
    $lines = @()
    $lines += "FirstTimeInstall=1"
    $lines += "LastUpdated=$timestamp"
    $lines += "ServerDataSetup=$DataSetup"
    $lines += "GenAISetup=$GenAISetup"
    $lines += "GenAIEnable=$GenAIEnable"

    $lines | Out-File -FilePath $configFile -Encoding UTF8 -Force
    Write-Host "[Config] repack.conf written: FirstTimeInstall=1, LastUpdated=$timestamp, ServerDataSetup=$DataSetup, GenAISetup=$GenAISetup, GenAIEnable=$GenAIEnable" -ForegroundColor DarkGray
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

        Write-Host "  Downloading: $fileName ($sizeStr)..." -ForegroundColor White

        $maxRetries = 3
        $retryCount = 0
        $downloaded = $false
        while (!$downloaded -and $retryCount -lt $maxRetries) {
            $retryCount++
            if ($retryCount -gt 1) {
                Write-Host "  Attempt $retryCount of $maxRetries..." -ForegroundColor DarkYellow
            }
            try {
                Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 0
                $downloaded = $true
            } catch {
                if ($retryCount -lt $maxRetries) {
                    Write-Host "  Download failed: $($_.Exception.Message)" -ForegroundColor Red
                    Write-Host "  Retrying..." -ForegroundColor DarkYellow
                } else {
                    throw
                }
            }
        }
        Write-Host "  Done." -ForegroundColor Green
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
        "zip"        = [ordered]@{}
        "sql"        = [ordered]@{}
        "other"      = [ordered]@{}
        "gdrive"     = [ordered]@{}
        "data"       = [ordered]@{}
        "genai"      = [ordered]@{}
        "script"     = [ordered]@{}
        "datamirror" = [ordered]@{}
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
                if ($currentSection -eq "datamirror") {
                    # Collect multiple mirror URLs per id into an array
                    if ($sections[$currentSection].Contains($id)) {
                        $sections[$currentSection][$id].Urls += ,$url
                    } else {
                        $sections[$currentSection][$id] = [ordered]@{ Version = $version; Urls = @($url) }
                    }
                } else {
                    $sections[$currentSection][$id] = @{ Version = $version; Url = $url }
                }
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
        "zip"        = @{}
        "sql"        = @{}
        "other"      = @{}
        "gdrive"     = @{}
        "data"       = @{}
        "genai"      = @{}
        "script"     = @{}
        "datamirror" = @{}
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

function Download-ParallelChunks
{
    param(
        [string]$Url,
        [string]$Destination,
        [string]$CookieHeader = "",
        [int]$NumChunks = 4
    )

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan

    try {
        # Probe with GET Range: bytes=0-0 to check range support and get total size
        $probeReq = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
        $probeReq.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue(0, 0)
        if ($CookieHeader) {
            $probeReq.Headers.Add("Cookie", $CookieHeader)
        }
        $probeResp = $client.SendAsync($probeReq, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
        $probeResp.EnsureSuccessStatusCode() | Out-Null

        $statusCode = [int]$probeResp.StatusCode
        $acceptRanges = $probeResp.Headers.AcceptRanges -contains 'bytes'

        $contentRange = $null
        if ($probeResp.Content.Headers.ContentRange) {
            $contentRange = $probeResp.Content.Headers.ContentRange
        }
        $probeResp.Dispose()

        $rangeSupported = ($statusCode -eq 206) -and $acceptRanges

        if (!$rangeSupported -or !$contentRange -or !$contentRange.Length) {
            return $false
        }

        $totalSize = $contentRange.Length

        if ($totalSize -lt 10MB) {
            return $false
        }

        Write-Host "  (parallel: $NumChunks chunks, $([math]::Round($totalSize / 1MB, 1)) MB)" -ForegroundColor DarkGray

        $chunkSize = [math]::Floor($totalSize / $NumChunks)
        $tempDir = [System.IO.Path]::GetDirectoryName($Destination)
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Destination)
        $chunkFiles = @()
        $chunkClients = @()
        $chunkHandlers = @()

        # Phase 1: Start all header requests
        $headerTasks = @()
        for ($i = 0; $i -lt $NumChunks; $i++) {
            $start = $i * $chunkSize
            $end = if ($i -eq $NumChunks - 1) { $totalSize - 1 } else { ($start + $chunkSize - 1) }
            $chunkFile = Join-Path $tempDir "${baseName}_chunk_${i}.tmp"
            $chunkFiles += $chunkFile

            $chunkHandler = New-Object System.Net.Http.HttpClientHandler
            $chunkHandler.AllowAutoRedirect = $true
            $chunkClient = New-Object System.Net.Http.HttpClient($chunkHandler)
            $chunkClient.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
            $chunkClients += $chunkClient
            $chunkHandlers += $chunkHandler

            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
            $req.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue($start, $end)
            if ($CookieHeader) {
                $req.Headers.Add("Cookie", $CookieHeader)
            }

            $headerTasks += $chunkClient.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        }

        # Wait for all headers to arrive
        $headerTaskArray = [System.Threading.Tasks.Task[]]@($headerTasks)
        [System.Threading.Tasks.Task]::WaitAll($headerTaskArray)

        # Verify all chunks got 206 Partial Content
        $allPartial = $true
        for ($i = 0; $i -lt $NumChunks; $i++) {
            try {
                $resp = $headerTasks[$i].Result
                if ([int]$resp.StatusCode -ne 206) {
                    $allPartial = $false
                    break
                }
            } catch {
                $allPartial = $false
                break
            }
        }

        if (!$allPartial) {
            for ($i = 0; $i -lt $chunkClients.Count; $i++) {
                try { $headerTasks[$i].Result.Dispose() } catch {}
                $chunkClients[$i].Dispose()
                $chunkHandlers[$i].Dispose()
            }
            foreach ($cf in $chunkFiles) { Remove-Item $cf -Force -ErrorAction SilentlyContinue }
            return $false
        }

        # Phase 2: Start all stream copies in parallel
        $failed = $false
        $copyTasks = @()
        $streams = @()
        $fileStreams = @()
        for ($i = 0; $i -lt $NumChunks; $i++) {
            try {
                $resp = $headerTasks[$i].Result
                $resp.EnsureSuccessStatusCode() | Out-Null
                $stream = $resp.Content.ReadAsStreamAsync().Result
                $streams += $stream
                $fs = [System.IO.File]::Create($chunkFiles[$i])
                $fileStreams += $fs
                $copyTasks += $stream.CopyToAsync($fs)
            } catch {
                $failed = $true
                Write-Host "  Chunk $i failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        if (!$failed) {
            $copyTaskArray = [System.Threading.Tasks.Task[]]@($copyTasks)
            # Poll for progress instead of blocking WaitAll
            while (!([System.Threading.Tasks.Task]::WaitAll($copyTaskArray, 1000))) {
                $downloadedBytes = 0
                foreach ($cf in $chunkFiles) {
                    if (Test-Path $cf) {
                        $downloadedBytes += (Get-Item $cf).Length
                    }
                }
                $pct = [math]::Round(($downloadedBytes / $totalSize) * 100, 1)
                Write-Host ("`r  {0}% ({1:N1} MB / {2:N1} MB)   " -f $pct, ($downloadedBytes / 1MB), ($totalSize / 1MB)) -NoNewline
            }
            Write-Host ""
        }

        # Cleanup streams and clients
        for ($i = 0; $i -lt $streams.Count; $i++) {
            if ($streams[$i]) { $streams[$i].Close() }
        }
        for ($i = 0; $i -lt $fileStreams.Count; $i++) {
            if ($fileStreams[$i]) { $fileStreams[$i].Close() }
        }
        for ($i = 0; $i -lt $chunkClients.Count; $i++) {
            $chunkClients[$i].Dispose()
            $chunkHandlers[$i].Dispose()
        }

        if ($failed) {
            foreach ($cf in $chunkFiles) { Remove-Item $cf -Force -ErrorAction SilentlyContinue }
            return $false
        }

        # Combine chunks into final file
        $outStream = [System.IO.File]::Create($Destination)
        foreach ($cf in $chunkFiles) {
            $chunkStream = [System.IO.File]::OpenRead($cf)
            $chunkStream.CopyTo($outStream)
            $chunkStream.Close()
            Remove-Item $cf -Force -ErrorAction SilentlyContinue
        }
        $outStream.Close()

        return $true
    }
    catch {
        Write-Host "  Parallel download error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
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

        Write-Host "  Downloading: $fileName from Google Drive..." -ForegroundColor White

        $tempFile = [System.IO.Path]::GetTempFileName()
        $session = $null

        # Step 1: Initial request to get the confirmation page (large files)
        $initialUrl = "https://drive.google.com/uc?export=download&id=$fileId"
        Invoke-WebRequest -Uri $initialUrl -OutFile $tempFile -UseBasicParsing -SessionVariable session -TimeoutSec 0 | Out-Null

        # Read only first 4KB to check if it's HTML (avoid OOM on large files)
        $peekBytes = New-Object byte[] 4096
        $fs = [System.IO.File]::OpenRead($tempFile)
        $bytesRead = $fs.Read($peekBytes, 0, 4096)
        $fs.Close()
        $peekContent = [System.Text.Encoding]::UTF8.GetString($peekBytes, 0, $bytesRead)

        # Check if we got the actual file or an HTML confirmation page
        $isHtml = $peekContent -match '<html' -or $peekContent -match '<!DOCTYPE'

        if ($isHtml) {
            Write-Host "  (confirming)..." -ForegroundColor DarkYellow

            # Read first 64KB for uuid extraction (stream-based to avoid 2GB .NET limit)
            $uuidBytes = New-Object byte[] 65536
            $fsUuid = [System.IO.File]::OpenRead($tempFile)
            $uuidBytesRead = $fsUuid.Read($uuidBytes, 0, 65536)
            $fsUuid.Close()
            $fullContent = [System.Text.Encoding]::UTF8.GetString($uuidBytes, 0, $uuidBytesRead)
            $uuid = $null
            if ($fullContent -match 'name="uuid"\s+value="([^"]+)"') {
                $uuid = $Matches[1]
            }

            # Build the real download URL using the new endpoint
            $downloadUrl = "https://drive.usercontent.google.com/download?id=$fileId&export=download&confirm=t"
            if ($uuid) {
                $downloadUrl += "&uuid=$uuid"
            }

            # Extract cookies from WebSession as raw string for HttpClient (cross-domain)
            $cookieHeader = ""
            if ($session -and $session.Cookies) {
                $cookieParts = @()
                $downloadUri = [Uri]$downloadUrl
                foreach ($cookie in $session.Cookies.GetCookies($downloadUri)) {
                    $cookieParts += "$($cookie.Name)=$($cookie.Value)"
                }
                $gdriveUri = [Uri]"https://drive.google.com/"
                foreach ($cookie in $session.Cookies.GetCookies($gdriveUri)) {
                    $cookieParts += "$($cookie.Name)=$($cookie.Value)"
                }
                $cookieHeader = $cookieParts -join "; "
            }

            $maxRetries = 3
            $retryCount = 0
            $downloaded = $false
            while (!$downloaded -and $retryCount -lt $maxRetries) {
                $retryCount++
                if ($retryCount -gt 1) {
                    Write-Host "  Attempt $retryCount of $maxRetries..." -ForegroundColor DarkYellow
                }
                try {
                    # Try parallel chunked download first
                    if (Download-ParallelChunks -Url $downloadUrl -Destination $tempFile -CookieHeader $cookieHeader) {
                        $downloaded = $true
                    } else {
                        # Fall back to single-stream Invoke-WebRequest
                        Write-Host "  (single-stream)" -ForegroundColor DarkGray
                        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -WebSession $session -UseBasicParsing -TimeoutSec 0 | Out-Null
                        $downloaded = $true
                    }
                } catch {
                    if ($retryCount -lt $maxRetries) {
                        Write-Host "  Download failed: $($_.Exception.Message)" -ForegroundColor Red
                        Write-Host "  Retrying..." -ForegroundColor DarkYellow
                    } else {
                        throw
                    }
                }
            }

            # Verify we got the actual file this time (read only first 4KB)
            $verifyBytes = New-Object byte[] 4096
            $fs2 = [System.IO.File]::OpenRead($tempFile)
            $verifyBytesRead = $fs2.Read($verifyBytes, 0, 4096)
            $fs2.Close()
            $verifyContent = [System.Text.Encoding]::UTF8.GetString($verifyBytes, 0, $verifyBytesRead)

            if ($verifyContent -match '<html' -or $verifyContent -match '<!DOCTYPE') {
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                Write-Host "  FAILED!" -ForegroundColor Red
                if ($verifyContent -match 'Quota exceeded') {
                    Write-Host "  Error: Google Drive quota exceeded for this file (too many downloads in 24h)." -ForegroundColor Red
                } else {
                    Write-Host "  Error: Could not bypass Google Drive confirmation page." -ForegroundColor Red
                }
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

function Download-DataFiles
{
    param(
        $DataFiles,
        $MirrorFiles
    )

    if ($DataFiles.Count -eq 0)
    {
        Write-Host "[Data] No data files to download." -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    Write-Host "[Data] Downloading and extracting $($DataFiles.Count) data file(s)..." -ForegroundColor Cyan

    foreach ($id in $DataFiles.Keys)
    {
        $url = $DataFiles[$id].Url
        $tempZip = Join-Path $scriptDir "$id.zip"
        $downloaded = $false

        # Try Google Drive first
        Write-Host "  [$id]" -ForegroundColor Cyan -NoNewline
        if (Download-GdriveFile -Url $url -Destination $tempZip) {
            $downloaded = $true
        } else {
            # Try mirrors if available
            $mirrors = $null
            if ($MirrorFiles -and $MirrorFiles.Contains($id)) {
                $mirrors = $MirrorFiles[$id].Urls
            }
            if ($mirrors -and $mirrors.Count -gt 0) {
                Write-Host "  [$id] Trying $($mirrors.Count) mirror(s)..." -ForegroundColor DarkYellow
                foreach ($mirrorUrl in $mirrors) {
                    Write-Host "  [$id] Mirror: $mirrorUrl" -ForegroundColor DarkGray
                    if (Download-File -Url $mirrorUrl -Destination $tempZip) {
                        $downloaded = $true
                        break
                    }
                }
            }
        }

        if (!$downloaded) {
            Write-Host "  [$id] FAILED - no source available." -ForegroundColor Red
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

function Setup-GenAI
{
    param(
        [switch]$Force
    )

    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor DarkCyan
    Write-Host "Generative AI Server for Followship Bots GenAI Features" -ForegroundColor Cyan
    Write-Host "!!! Warning: running a GenAI server on your machine can be quite demanding." -ForegroundColor Yellow
    Write-Host "!!! Required: An RTX GPU with cuda capabilities." -ForegroundColor Yellow
    Write-Host "!!! If you do not want to use Llama CPP you can still set up your own GenAI provider, local or cloud." -ForegroundColor Yellow
    Write-Host "Do you want to install a local Llama CPP GenAI provider on your machine?" -ForegroundColor White
    Write-Host "This will also enable GenAI functionality for Followship Bots." -ForegroundColor White
    Write-Host "  1. Yes, I want a local Llama CPP server" -ForegroundColor White
    Write-Host "  2. No, I do not want or I will set it up myself later." -ForegroundColor White
    Write-Host ""
    $genaiChoice = Read-Host "Enter your choice (1/2)"

    $genAIEnable = 0

    switch ($genaiChoice)
    {
        "1"
        {
            Write-Host ""
            Write-Host "[GenAI] Downloading Llama CPP GenAI server files..." -ForegroundColor Cyan
            if (!$Force -and $genaiChanged -eq 0 -and $genaiTotal -gt 0) {
                Write-Host "[GenAI] GenAI files already up-to-date. Skipping download." -ForegroundColor DarkGray
            } elseif ($genaiTotal -eq 0) {
                Write-Host "[GenAI] No GenAI files found in manifest. Skipping download." -ForegroundColor DarkGray
            } else {
                Download-GdriveFiles -Files $sections["genai"]
                Write-Host "[GenAI] GenAI server files downloaded and extracted." -ForegroundColor Green
            }
            $genAIEnable = 1

            # Update GenAI.conf to enable GenAI for Followship Bots
            $genaiConf = Join-Path $scriptDir "Server\worldserver.conf.d\GenAI.conf"
            if (Test-Path $genaiConf) {
                Write-Host "[GenAI] Enabling GenAI in worldserver config..." -ForegroundColor White
                $confContent = Get-Content $genaiConf -Raw
                $confContent = $confContent -replace 'Followship\.Bots\.GenAI\.Enabled\s*=\s*0', 'Followship.Bots.GenAI.Enabled = 1'
                [System.IO.File]::WriteAllText($genaiConf, $confContent, (New-Object System.Text.UTF8Encoding $false))
                Write-Host "[GenAI] GenAI enabled in $genaiConf" -ForegroundColor Green
            } else {
                Write-Host "[GenAI] Config file not found: $genaiConf" -ForegroundColor Red
                Write-Host "[GenAI] You will need to set Followship.Bots.GenAI.Enabled = 1 manually." -ForegroundColor Yellow
            }
        }
        "2"
        {
            Write-Host ""
            Write-Host "[GenAI] You chose not to install a local Llama CPP server." -ForegroundColor Yellow
            Write-Host "[GenAI] You can set up your own GenAI provider later (local or cloud)." -ForegroundColor Yellow
            $genAIEnable = 0
        }
        default
        {
            Write-Host ""
            Write-Host "[GenAI] Invalid choice. Skipping GenAI setup." -ForegroundColor Red
            $genAIEnable = 0
        }
    }

    # Update repack.conf with GenAI status
    Write-Config -FirstTime $isFirstTime -DataSetup $(if ($dataSetupDone) { 1 } else { 0 }) -GenAISetup 1 -GenAIEnable $genAIEnable

    return $genAIEnable
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
$genaiTotal = $sections["genai"].Count

$zipChanged = $changed["zip"].Count
$sqlChanged = $changed["sql"].Count
$otherChanged = $changed["other"].Count
$gdriveChanged = $changed["gdrive"].Count
$dataChanged = $changed["data"].Count
$genaiChanged = $changed["genai"].Count

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
Write-Host "  Data mirrors: $($sections['datamirror'].Count)" -ForegroundColor White
Write-Host "  GenAI files:  $genaiTotal ($genaiChanged changed)" -ForegroundColor White

# Step 4c: Check for script self-update
if ($sections["script"].Count -gt 0) {
    foreach ($id in $sections["script"].Keys) {
        $remoteScriptVersion = $sections["script"][$id].Version
        $remoteScriptUrl = $sections["script"][$id].Url
        if ($remoteScriptVersion -ne $scriptVersion) {
            Write-Host ""
            Write-Host "[Update] Script update available: v=$scriptVersion -> v=$remoteScriptVersion" -ForegroundColor Yellow
            Write-Host "[Update] Downloading new script..." -ForegroundColor Cyan
            $tempScript = Join-Path $scriptDir "FoundryCoreRepack.ps1.new"
            if (Download-File -Url $remoteScriptUrl -Destination $tempScript) {
                $currentScript = $MyInvocation.MyCommand.Path
                Move-Item -Path $tempScript -Destination $currentScript -Force
                Write-Host "[Update] Script updated to version $remoteScriptVersion." -ForegroundColor Green
                Write-Host "[Update] Please restart the launcher to apply the update." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "Press any key to exit..." -ForegroundColor White
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                exit 0
            } else {
                Write-Host "[Update] Failed to download new script. Continuing with current version." -ForegroundColor Red
            }
        } else {
            Write-Host "  Script:       v=$scriptVersion (up-to-date)" -ForegroundColor DarkGray
        }
    }
}

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
            Download-DataFiles -DataFiles $sections["data"] -MirrorFiles $sections["datamirror"]
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

    # Persist ServerDataSetup=1 immediately so it survives even if script exits before GenAI setup
    $existingGenAISetup = if ($config) { [int]$config["GenAISetup"] } else { 0 }
    $existingGenAIEnable = if ($config) { [int]$config["GenAIEnable"] } else { 0 }
    Write-Config -FirstTime $isFirstTime -DataSetup 1 -GenAISetup $existingGenAISetup -GenAIEnable $existingGenAIEnable
}

# Step 8b: GenAI Server Setup
$genAIEnable = 0

if ($config -and $config["GenAISetup"] -eq "1") {
    $genAIEnable = if ($config["GenAIEnable"] -eq "1") { 1 } else { 0 }
    Write-Host ""
    Write-Host "[GenAI] GenAI setup already completed (GenAISetup=1 in repack.conf). Skipping." -ForegroundColor DarkGray
} else {
    $genAIEnable = Setup-GenAI
}

Write-Host ""
Write-Host ("=" * 80) -ForegroundColor DarkCyan

# Step 11: Server Launcher Menu
$serverDir = Join-Path $scriptDir "Server"
$bnetExe = Join-Path $serverDir "bnetserver.exe"
$worldExe = Join-Path $serverDir "worldserver.exe"

$mysqlDir = Join-Path $scriptDir "Dep\mysql"
$mysqldExe = Join-Path $mysqlDir "bin\mysqld.exe"
$myIni = Join-Path $mysqlDir "my.ini"

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

    return $true
}

while ($true) {
    Write-Host ""
    Write-Host "Repack Ready. What do you want to do?" -ForegroundColor Cyan
    Write-Host "  1. Start BnetServer" -ForegroundColor White
    Write-Host "  2. Start WorldServer" -ForegroundColor White
    Write-Host "  3. Start Both Servers" -ForegroundColor White
    Write-Host "  4. Start Llama CPP Server" -ForegroundColor White
    Write-Host "  5. Server Operations" -ForegroundColor White
    Write-Host "  6. Exit" -ForegroundColor White
    Write-Host ""
    $mainChoice = Read-Host "Enter your choice (1/2/3/4/5/6)"

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
            $llamaServer = Join-Path $scriptDir "GenerativeAI\cuda\llama-server.exe"
            if (!(Test-Path $llamaServer)) {
                Write-Host "[GenAI] llama-server.exe not found at: $llamaServer" -ForegroundColor Red
                Write-Host "[GenAI] You need to download the GenAI server files first." -ForegroundColor Yellow
                $genAIEnable = Setup-GenAI -Force
            } else {
                Write-Host "[GenAI] Starting Llama CPP Server (CUDA)..." -ForegroundColor Green
                $genaiCudaDir = Join-Path $scriptDir "GenerativeAI\cuda"
                $genaiArgs = '-m ..\models\Qwen3-4B-Q4_K_M.gguf --chat-template-file ..\models\templates\Qwen3.5-4B.jinja --reasoning off --ctx-size 8192 --gpu-layers 60 --parallel 1 --no-warmup'
                Start-Process -FilePath $llamaServer -ArgumentList $genaiArgs -WorkingDirectory $genaiCudaDir
                Write-Host "[GenAI] Llama CPP Server started in new window." -ForegroundColor Green
            }
        }
        "5" {
            while ($true) {
                Write-Host ""
                Write-Host "Server Operations:" -ForegroundColor Cyan
                Write-Host "  1. Kill MySQL Process" -ForegroundColor White
                Write-Host "  2. Start MySQL Server" -ForegroundColor White
                Write-Host "  3. Back" -ForegroundColor White
                Write-Host ""
                $opsChoice = Read-Host "Enter your choice (1/2/3)"

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
                        if (!(Test-Path $mysqldExe)) {
                            Write-Host "[Ops] mysqld.exe not found at: $mysqldExe" -ForegroundColor Red
                        } else {
                            Write-Host "[Ops] Starting MySQL..." -ForegroundColor Yellow
                            if (Test-Path $myIni) {
                                Push-Location $mysqlDir
                                Start-Process -FilePath $mysqldExe -ArgumentList "--defaults-file=`"$myIni`"" -NoNewWindow -PassThru | Out-Null
                                Pop-Location
                            } else {
                                Push-Location $mysqlDir
                                Start-Process -FilePath $mysqldExe -NoNewWindow -PassThru | Out-Null
                                Pop-Location
                            }
                            Write-Host "[Ops] MySQL started." -ForegroundColor Green
                        }
                    }
                    "3" {
                        break
                    }
                    default {
                        Write-Host "[Ops] Invalid choice." -ForegroundColor Red
                    }
                }
                if ($opsChoice -eq "3") { break }
            }
        }
        "6" {
            Write-Host "[Server] Exiting." -ForegroundColor Yellow
            exit
        }
        default {
            Write-Host "[Server] Invalid choice." -ForegroundColor Red
        }
    }
}
