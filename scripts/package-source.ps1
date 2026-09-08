[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$OutputDir = Join-Path $RepoRoot 'artifacts/release-candidate'
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$ZipPath = Join-Path $OutputDir 'sandbox-oci-source.zip'
$Manifest = New-Object System.Collections.Generic.List[object]
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Push-Location $RepoRoot
try {
    $paths = @(& git -c core.quotepath=false ls-files --cached --others --exclude-standard | Sort-Object -Unique)
    if ($LASTEXITCODE -ne 0 -or $paths.Count -eq 0) { throw 'Cannot enumerate source candidates through Git' }
    # Validate all candidates before replacing the generated archive.
    foreach ($path in $paths) {
        if ($path -match '(^|/)(\.git|\.cache|\.gocache|artifacts|bin|__pycache__)(/|$)|(^|/)\.env($|\.)|\.(exe|pyc)$') { throw "Excluded generated or private file selected: $path" }
        $fullPath = [IO.Path]::GetFullPath((Join-Path $RepoRoot $path))
        if (-not $fullPath.StartsWith($RepoRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Path escaped repository: $path" }
        $item = Get-Item -LiteralPath $fullPath
        if ($item.PSIsContainer -or $item.LinkType) { throw "Only ordinary source files may be packaged: $path" }
        # OneDrive files may be reparse points without being filesystem links.
        $parent = $item.Directory
        while ($parent -and $parent.FullName.Length -ge $RepoRoot.Length) {
            if ((Get-Item -LiteralPath $parent.FullName).LinkType) { throw "Linked parent directory is unsupported: $path" }
            $parent = $parent.Parent
        }
        $Manifest.Add([ordered]@{path=$path;sha256=(Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()})
    }
    $stream = [IO.File]::Open($ZipPath,[IO.FileMode]::Create)
    try {
        $zip = New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
        try {
            foreach ($item in $Manifest) {
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,(Join-Path $RepoRoot $item.path),('sandbox-oci/' + $item.path))
            }
        } finally { $zip.Dispose() }
    } finally { $stream.Dispose() }
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $OutputDir 'source-manifest.json'),(ConvertTo-Json -InputObject @($Manifest.ToArray()) -Depth 4),$utf8)
    $hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $OutputDir 'SHA256SUMS'),("$hash  sandbox-oci-source.zip`n"),$utf8)
    Write-Output "Packaged $($Manifest.Count) source files: $ZipPath"
} finally { Pop-Location }
