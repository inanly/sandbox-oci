[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Artifacts = Join-Path $RepoRoot 'artifacts'
$DockerArgs = @()
if ($env:OS -eq 'Windows_NT') { $DockerArgs = @('--context','desktop-linux') }
$Results = @()
foreach ($kind in @('helper','test-helper')) {
    $image = (Get-Content (Join-Path $Artifacts "$kind-image.txt") -Raw).Trim()
    if ($image -notmatch '@sha256:[a-f0-9]{64}$') { throw 'Expected digest-pinned image' }
    $name = 'sandbox-oci-attribution-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
    $destination = Join-Path $Artifacts $name
    New-Item -ItemType Directory -Path $destination | Out-Null
    & docker @DockerArgs create --name $name $image | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create attribution inspection container' }
    try {
        & docker @DockerArgs cp "${name}:/usr/share/licenses/sandbox-oci/." $destination
        if ($LASTEXITCODE -ne 0) { throw 'Cannot extract image attribution' }
    } finally {
        & docker @DockerArgs rm $name | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Cannot remove inspection container $name" }
    }
    foreach ($file in @('LICENSE','NOTICE','versions.json')) {
        if ((Get-FileHash (Join-Path $RepoRoot $file)).Hash -ne (Get-FileHash (Join-Path $destination "project/$file")).Hash) { throw "Image project $file differs from source" }
    }
    foreach ($file in @('opensandbox/LICENSE','go/LICENSE','go/PATENTS','ca-certificates/copyright','build-info.txt','manifest.json')) {
        if ((Get-Item -LiteralPath (Join-Path $destination $file)).Length -eq 0) { throw "Empty attribution $file" }
    }
    $manifest = Get-Content (Join-Path $destination 'manifest.json') -Raw | ConvertFrom-Json
    if (@($manifest.modules).Count -eq 0) { throw 'Empty dependency inventory' }
    $keys = @()
    foreach ($module in $manifest.modules) {
        $keys += "$($module.path)@$($module.version)"
        if (@($module.files).Count -eq 0) { throw 'Module attribution missing' }
        foreach ($file in $module.files) {
            $path = Join-Path $destination "modules/$($module.path)@$($module.version)/$file"
            if ((Get-Item -LiteralPath $path).Length -eq 0) { throw "Missing or empty module attribution: $file" }
        }
    }
    foreach ($line in (Get-Content (Join-Path $destination 'build-info.txt'))) {
        if ($line -match '^\s*dep\s+(\S+)\s+(\S+)') {
            if ($keys -notcontains "$($Matches[1])@$($Matches[2])") { throw "Binary dependency absent from attribution inventory: $($Matches[1])" }
        }
    }
    $Results += [ordered]@{kind=$kind;image=$image;modules=@($manifest.modules).Count;passed=$true}
}
$report = [ordered]@{passed=$true;timeUTC=[DateTime]::UtcNow.ToString('o');images=$Results}
[IO.File]::WriteAllText((Join-Path $Artifacts 'attribution-result.json'),($report | ConvertTo-Json -Depth 6))
Write-Output 'PASS: both helper images contain project, upstream, toolchain and dependency attribution.'
