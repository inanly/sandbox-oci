[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Artifacts = Join-Path $RepoRoot 'artifacts'
$OldKube = $env:KUBECONFIG
$Binary = Join-Path $RepoRoot 'bin/sandbox-oci'
if ($env:OS -eq 'Windows_NT') { $Binary += '.exe' }
$DockerArgs = @()
if ($env:OS -eq 'Windows_NT') { $DockerArgs = @('--context','desktop-linux') }
$Report = [ordered]@{ passed=$false; timeUTC=[DateTime]::UtcNow.ToString('o') }
function Read-Source {
    $raw = & kubectl --context kind-sandbox-oci-source --request-timeout=15s -n sandbox-oci get pod source -o json
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read source' }
    return ($raw -join "`n" | ConvertFrom-Json)
}
function Verify-Source {
    $after = Read-Source
    if ($after.metadata.uid -ne $Before.metadata.uid -or $after.status.containerStatuses[0].containerID -ne $Before.status.containerStatuses[0].containerID) { throw 'Source identity changed' }
    & kubectl --context kind-sandbox-oci-source --request-timeout=15s -n sandbox-oci exec source -- python3 /opt/fixture/verify.py
    if ($LASTEXITCODE -ne 0) { throw 'Source verification failed' }
}
try {
    $env:KUBECONFIG = Join-Path $Artifacts 'kubeconfig'
    Push-Location $RepoRoot
    try {
        & go build -buildvcs=false -o $Binary ./cmd/sandbox-oci
        if ($LASTEXITCODE -ne 0) { throw 'CLI build failed' }
    } finally { Pop-Location }
    $Helper = (Get-Content (Join-Path $Artifacts 'helper-image.txt') -Raw).Trim()
    $Before = Read-Source
    $Tag = 'sandbox-oci-registry:5000/sandbox-oci-snapshot:transport-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
    $Common = @('snapshot','--context','kind-sandbox-oci-source','--pod','source','--container','sandbox','--helper-image',$Helper,'--source-quiesced','--source-registry-insecure','--image',$Tag,'--timeout','60s','--output','json')
    # The source may use HTTP, but the target must remain HTTPS by default.
    $ErrorActionPreference = 'Continue'
    try {
        $failure = & $Binary @Common 2>&1
        $failureExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = 'Stop' }
    $failureText = $failure -join "`n"
    if ($failureExit -eq 0 -or $failureText -notmatch 'push:' -or $failureText -notmatch 'https://' -or $failureText -notmatch 'HTTP response to HTTPS client') {
        throw "Default target transport did not reject HTTP as expected: $failureText"
    }
    Verify-Source
    $Report.defaultTargetRejectsHTTP = $true
    $success = & $Binary @Common --target-registry-insecure
    if ($LASTEXITCODE -ne 0) { throw 'Explicit insecure target snapshot failed' }
    $snapshot = $success -join "`n" | ConvertFrom-Json
    Verify-Source
    $ref = 'localhost:5001/sandbox-oci-snapshot@' + $snapshot.digest
    & docker @DockerArgs pull $ref
    if ($LASTEXITCODE -ne 0) { throw 'Cannot pull explicit HTTP snapshot' }
    & docker @DockerArgs run --rm $ref python3 /opt/fixture/verify.py
    if ($LASTEXITCODE -ne 0) { throw 'Explicit HTTP snapshot verification failed' }
    $Report.explicitInsecureTargetWorks = $true
    $Report.sourcePreserved = $true
    $Report.image = $ref
    $Report.helperImage = $Helper
    $Report.passed = $true
    Write-Output 'PASS: HTTPS default rejects HTTP; explicit opt-in snapshots and restores successfully.'
} catch {
    $Report.error = $_.Exception.Message
    throw
} finally {
    [IO.File]::WriteAllText((Join-Path $Artifacts 'registry-result.json'), ($Report | ConvertTo-Json))
    $env:KUBECONFIG = $OldKube
}
