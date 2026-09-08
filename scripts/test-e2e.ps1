[CmdletBinding()]
param([switch]$Prepare)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Artifacts = Join-Path $RepoRoot 'artifacts'
$Kube = Join-Path $Artifacts 'kubeconfig'
$OldKube = $env:KUBECONFIG
$DockerArgs = @()
if ($env:OS -eq 'Windows_NT') { $DockerArgs = @('--context','desktop-linux') }
$Binary = Join-Path $RepoRoot 'bin/sandbox-oci'
if ($env:OS -eq 'Windows_NT') { $Binary += '.exe' }
function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit $LASTEXITCODE" }
}
function Source-Kubectl {
    param([string[]]$Arguments)
    Invoke-Checked kubectl (@('--context','kind-sandbox-oci-source','-n','sandbox-oci') + $Arguments)
}
try {
    $env:KUBECONFIG = $Kube
    if ($Prepare) {
        foreach ($action in @('bootstrap','build','source')) { & (Join-Path $PSScriptRoot 'lab.ps1') -Action $action }
    }
    Push-Location $RepoRoot
    try { Invoke-Checked go @('build','-buildvcs=false','-o',$Binary,'./cmd/sandbox-oci') } finally { Pop-Location }
    Invoke-Checked $Binary @('doctor','--context','kind-sandbox-oci-source')
    $Helper = (Get-Content (Join-Path $Artifacts 'helper-image.txt') -Raw).Trim()
    $Common = @('snapshot','--context','kind-sandbox-oci-source','--pod','source','--container','sandbox','--helper-image',$Helper,'--source-quiesced','--source-registry-insecure','--target-registry-insecure','--output','json')
    # A refused local port exercises publication failure after capture/resume.
    $ErrorActionPreference = 'Continue'
    try {
        $Bad = & $Binary @Common --image sandbox-oci-registry:1/sandbox-oci-snapshot:failure --timeout 60s 2> (Join-Path $Artifacts 'expected-push-failure.txt')
        $BadExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = 'Stop' }
    if ($BadExit -eq 0) { throw 'Invalid registry unexpectedly succeeded' }
    $BadLog = Get-Content (Join-Path $Artifacts 'expected-push-failure.txt') -Raw
    if ($BadLog -notmatch 'push:') { throw "Failure did not exercise publication: $BadLog" }
    Source-Kubectl @('exec','source','--','python3','/opt/fixture/verify.py')
    $Before = (Source-Kubectl @('get','pod','source','-o','json')) | ConvertFrom-Json
    $Expected = (Source-Kubectl @('exec','source','--','cat','/workspace/expected.json')) -join "`n"
    $Snapshot = (& $Binary @Common --image sandbox-oci-registry:5000/sandbox-oci-snapshot:e2e) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'Snapshot failed' }
    $Result = $Snapshot | ConvertFrom-Json
    if ($Result.sourcePodUID -ne $Before.metadata.uid) { throw 'Snapshot UID mismatch' }
    [IO.File]::WriteAllText((Join-Path $Artifacts 'snapshot.json'),$Snapshot)
    $Image = 'localhost:5001/sandbox-oci-snapshot@' + $Result.digest
    # Docker's content verification completes before deletion of the original Pod.
    Invoke-Checked docker ($DockerArgs + @('pull',$Image))
    $Config = (& docker @DockerArgs image inspect $Image) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect snapshot image' }
    if (($Config[0].Config.Env -join "`n") -match 'SECRET_CANARY|not-for-image-config') { throw 'Pod environment leaked into image config' }
    Invoke-Checked docker ($DockerArgs + @('run','--rm',$Image,'python3','/opt/fixture/verify.py'))
    $DockerExpected = (& docker @DockerArgs run --rm $Image cat /workspace/expected.json) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $DockerExpected -ne $Expected) { throw 'Docker expected manifest differs from source' }
    $Current = (Source-Kubectl @('get','pod','source','-o','json')) | ConvertFrom-Json
    if ($Current.metadata.uid -ne $Before.metadata.uid) { throw 'Source changed before fixture deletion' }
    Source-Kubectl @('delete','pod','source','--wait=true')
    & (Join-Path $PSScriptRoot 'lab.ps1') -Action restore-cluster
    Invoke-Checked $Binary @('restore','--context','kind-sandbox-oci-restore','--pod','restored','--image',$Image)
    Invoke-Checked kubectl @('--context','kind-sandbox-oci-restore','-n','sandbox-oci','exec','restored','--','python3','/opt/fixture/verify.py')
    $RestoredExpected = (& kubectl --context kind-sandbox-oci-restore -n sandbox-oci exec restored -- cat /workspace/expected.json) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $RestoredExpected -ne $Expected) { throw 'Fresh cluster expected manifest differs' }
    $Report = [ordered]@{ passed=$true; timeUTC=[DateTime]::UtcNow.ToString('o'); image=$Image; sourcePodDeleted=$true; docker=$true; freshKind=$true; failedPushPreservesSource=$true; podEnvironmentExcluded=$true }
    [IO.File]::WriteAllText((Join-Path $Artifacts 'e2e-result.json'),($Report | ConvertTo-Json))
    Write-Output 'PASS: failed push preserves source; Docker and fresh kind restore verified.'
} finally { $env:KUBECONFIG = $OldKube }
