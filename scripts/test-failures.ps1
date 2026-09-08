[CmdletBinding()]
param()

# This script is intentionally not part of lab.ps1: it exercises failure paths
# against the coordinator-created source cluster and leaves a machine-readable report.
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Artifacts = Join-Path $RepoRoot 'artifacts'
$Kubeconfig = Join-Path $Artifacts 'kubeconfig'
$SourceContext = 'kind-sandbox-oci-source'
$Namespace = 'sandbox-oci'
$Binary = Join-Path $RepoRoot 'bin/sandbox-oci'
if ($env:OS -eq 'Windows_NT') { $Binary += '.exe' }
$DockerArgs = @()
if ($env:OS -eq 'Windows_NT') { $DockerArgs = @('--context','desktop-linux') }
$OldKubeconfig = $env:KUBECONFIG
$RunID = [Guid]::NewGuid().ToString('N').Substring(0,8)
$CreatedJobs = New-Object System.Collections.Generic.List[string]
$GatedJobs = New-Object System.Collections.Generic.List[string]
$SourceMayBePaused = $false
$RecoveryAttempt = 0
$ReportPath = Join-Path $Artifacts 'failures-result.json'
$Results = [ordered]@{ passed=$false; timeUTC=[DateTime]::UtcNow.ToString('o'); run=$RunID; checks=[ordered]@{} }

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit $LASTEXITCODE" }
}
function Invoke-Kubectl {
    param([string[]]$Arguments)
    Invoke-Checked kubectl (@('--kubeconfig',$Kubeconfig,'--request-timeout=15s','--context',$SourceContext,'-n',$Namespace) + $Arguments)
}
function Get-KubectlOutput {
    param([string[]]$Arguments)
    $out = & kubectl --kubeconfig $Kubeconfig --request-timeout=15s --context $SourceContext -n $Namespace @Arguments
    if ($LASTEXITCODE -ne 0) { throw "kubectl $($Arguments -join ' ') failed with exit $LASTEXITCODE" }
    return ($out -join "`n")
}
function Invoke-DockerNode {
    param([string]$Node, [string[]]$Arguments)
    & docker @DockerArgs exec $Node @Arguments
    if ($LASTEXITCODE -ne 0) { throw "docker exec $Node failed with exit $LASTEXITCODE" }
}
function Get-DockerNodeOutput {
    param([string]$Node, [string[]]$Arguments)
    $out = & docker @DockerArgs exec $Node @Arguments
    if ($LASTEXITCODE -ne 0) { throw "docker exec $Node failed with exit $LASTEXITCODE" }
    return ($out -join "`n")
}
function Get-Source {
    return (Get-KubectlOutput @('get','pod','source','-o','json') | ConvertFrom-Json)
}
function Get-SourceIdentity {
    $pod = Get-Source
    $status = @($pod.status.containerStatuses | Where-Object { $_.name -eq 'sandbox' })
    if ($status.Count -ne 1 -or -not $status[0].containerID) { throw 'source sandbox container ID is unavailable' }
    return [ordered]@{ uid=[string]$pod.metadata.uid; id=([string]$status[0].containerID -replace '^containerd://',''); node=[string]$pod.spec.nodeName }
}
function Assert-SourceRunning {
    param($Expected, [string]$Stage)
    $actual = Get-SourceIdentity
    if ($actual.uid -ne $Expected.uid -or $actual.id -ne $Expected.id) { throw "$Stage changed the source identity" }
    $tasks = Get-DockerNodeOutput $Expected.node @('ctr','-n','k8s.io','tasks','ls')
    if ($tasks -notmatch ('(?m)^' + [regex]::Escape($Expected.id) + '\s+\S+\s+RUNNING\b')) { throw "$Stage left the source task non-running: $tasks" }
    Invoke-Kubectl @('exec','source','--pod-running-timeout=15s','--','python3','/opt/fixture/verify.py')
}
function Assert-SourcePaused {
    param($Expected)
    $actual = Get-SourceIdentity
    if ($actual.uid -ne $Expected.uid -or $actual.id -ne $Expected.id) { throw 'helper interruption changed the source identity' }
    $tasks = Get-DockerNodeOutput $Expected.node @('ctr','-n','k8s.io','tasks','ls')
    if ($tasks -notmatch ('(?m)^' + [regex]::Escape($Expected.id) + '\s+\S+\s+PAUSED\b')) { throw "source task is not paused after SIGKILL: $tasks" }
}
function Assert-NoLease {
    param($Expected)
    $leases = Get-DockerNodeOutput $Expected.node @('ctr','-n','k8s.io','leases','list','-q')
    if (($leases -split "`r?`n") -contains ("sandbox-oci-" + $Expected.id)) { throw 'source helper lease remains after recovery' }
}
function Ensure-HelperServiceAccount {
    $found = & kubectl --kubeconfig $Kubeconfig --request-timeout=15s --context $SourceContext -n $Namespace get serviceaccount sandbox-oci-helper --ignore-not-found -o json
    if ($LASTEXITCODE -ne 0) { throw 'cannot inspect sandbox-oci-helper ServiceAccount' }
    if (($found -join "`n").Trim()) { return }
    $sa = '{"apiVersion":"v1","kind":"ServiceAccount","metadata":{"name":"sandbox-oci-helper","labels":{"io.sandbox-oci.lab":"true"}},"automountServiceAccountToken":false}'
    $sa | & kubectl --kubeconfig $Kubeconfig --request-timeout=15s --context $SourceContext -n $Namespace create -f -
    if ($LASTEXITCODE -ne 0) { throw 'cannot create sandbox-oci-helper ServiceAccount' }
}
function New-HelperJob {
    param([string]$Name, [string]$Image, $Source, [string[]]$HelperArgs, [bool]$Gate)
    $env = @(
        @{ name='SOURCE_POD_UID'; value=$Source.uid },
        @{ name='EXPECTED_CONTAINER_ID'; value=$Source.id },
        @{ name='CONTAINERD_NAMESPACE'; value='k8s.io' },
        @{ name='SNAPSHOT_REGISTRY_INSECURE'; value='true' },
        @{ name='SOURCE_IMAGE_REGISTRY_INSECURE'; value='true' }
    )
    if ($Gate) { $env += @{ name='SANDBOX_OCI_TEST_PAUSE_GATE'; value='true' } }
    $job = [ordered]@{
        apiVersion='batch/v1'; kind='Job'; metadata=@{name=$Name;labels=@{'io.sandbox-oci.lab'='true'}}
        spec=@{backoffLimit=0;activeDeadlineSeconds=90;template=@{metadata=@{labels=@{'io.sandbox-oci.lab'='true'}};spec=@{
            serviceAccountName='sandbox-oci-helper';automountServiceAccountToken=$false;nodeName=$Source.node;restartPolicy='Never';terminationGracePeriodSeconds=90
            containers=@(@{name='helper';image=$Image;securityContext=@{privileged=$true};args=$HelperArgs;env=$env;volumeMounts=@(
                @{name='containerd-socket';mountPath='/run/containerd/containerd.sock'},@{name='containerd-state';mountPath='/var/lib/containerd'})})
            volumes=@(@{name='containerd-socket';hostPath=@{path='/run/containerd/containerd.sock';type='Socket'}},@{name='containerd-state';hostPath=@{path='/var/lib/containerd';type='Directory'}})
        }}}
    }
    $json = $job | ConvertTo-Json -Depth 12 -Compress
    $json | & kubectl --kubeconfig $Kubeconfig --request-timeout=15s --context $SourceContext -n $Namespace create -f -
    if ($LASTEXITCODE -ne 0) { throw "cannot create helper Job $Name" }
    $CreatedJobs.Add($Name)
}
function Get-HelperPod {
    param([string]$Job)
    $raw = Get-KubectlOutput @('get','pods','-l',"job-name=$Job",'-o','json') | ConvertFrom-Json
    $pods = @($raw.items)
    if ($pods.Count -gt 1) { throw "multiple pods found for helper Job $Job" }
    if ($pods.Count -eq 1) { return $pods[0] }
    return $null
}
function Wait-Gate {
    param([string]$Job, [int]$Seconds=35)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $pod = Get-HelperPod $Job
        if ($null -ne $pod) {
            $container = @($pod.status.containerStatuses | Where-Object { $_.name -eq 'helper' })[0]
            if ($null -ne $container.state.running) {
                $logs = & kubectl --kubeconfig $Kubeconfig --request-timeout=15s --context $SourceContext -n $Namespace logs $pod.metadata.name -c helper
                if (($logs -join "`n") -match 'TEST_GATE_PAUSED') { return $pod }
            }
            $term = $container.state.terminated
            if ($null -ne $term) { throw "helper exited before gate: $($term.exitCode) $($term.message)" }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "timed out waiting for TEST_GATE_PAUSED from $Job"
}
function Wait-HelperTermination {
    param([string]$Job, [int]$Seconds=35)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $pod = Get-HelperPod $Job
        if ($null -ne $pod) {
            $container = @($pod.status.containerStatuses | Where-Object { $_.name -eq 'helper' })[0]
            if ($null -ne $container.state.terminated) { return $container.state.terminated }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "timed out waiting for helper Job $Job to terminate"
}
function Terminate-ActiveGatedHelpers {
    param($Source)
    foreach ($job in $GatedJobs) {
        # Delete pending Jobs too, so they cannot start after explicit recovery.
        Invoke-Kubectl @('delete','job',$job,'--ignore-not-found=true','--cascade=foreground','--wait=true','--timeout=100s')
    }
}
function Recover-Source {
    param($Source, [string]$HelperImage)
    $script:RecoveryAttempt++
    $job = "sandbox-oci-failure-recover-$RunID-$script:RecoveryAttempt"
    New-HelperJob $job $HelperImage $Source @('unpause','source',$Namespace,('sandbox:sandbox-oci-registry:5000/sandbox-oci-snapshot:recovery')) $false
    $term = Wait-HelperTermination $job
    if ($term.exitCode -ne 0) { throw "recovery helper exited $($term.exitCode): $($term.message)" }
    Assert-SourceRunning $Source 'explicit recovery'
    Assert-NoLease $Source
    $script:SourceMayBePaused = $false
}

try {
    $env:KUBECONFIG = $Kubeconfig
    if (-not (Test-Path -LiteralPath $Binary)) { throw "sandbox-oci binary is missing: $Binary" }
    $Helper = (Get-Content -LiteralPath (Join-Path $Artifacts 'helper-image.txt') -Raw).Trim()
    $TestHelper = (Get-Content -LiteralPath (Join-Path $Artifacts 'test-helper-image.txt') -Raw).Trim()
    if ($Helper -notmatch '@sha256:[a-f0-9]{64}$' -or $TestHelper -notmatch '@sha256:[a-f0-9]{64}$') { throw 'helper image artifacts must be digest pinned' }
    $Results.helperImage = $Helper
    $Results.testHelperImage = $TestHelper
    Ensure-HelperServiceAccount
    $Initial = Get-SourceIdentity

    $stale = "sandbox-oci-failure-stale-$RunID"
    $staleSource = [ordered]@{uid=$Initial.uid;id=($Initial.id + '-stale');node=$Initial.node}
    New-HelperJob $stale $Helper $staleSource @('source',$Namespace,'sandbox:sandbox-oci-registry:5000/sandbox-oci-snapshot:stale') $false
    $staleTerm = Wait-HelperTermination $stale
    if ($staleTerm.exitCode -eq 0 -or (($staleTerm.message + '') -notmatch 'stale source')) { throw 'stale helper identity was not rejected' }
    Assert-SourceRunning $Initial 'stale helper rejection'
    $Results.checks.staleExpectedIDRejected = $true

    $volumePod = "sandbox-oci-failure-volume-$RunID"
    $sourcePod = Get-Source
    $sourceImage = [string]$sourcePod.spec.containers[0].image
    $helpersBefore = @((Get-KubectlOutput @('get','jobs','-l','io.sandbox-oci.lab=true','-o','json') | ConvertFrom-Json).items).Count
    $volume = @{apiVersion='v1';kind='Pod';metadata=@{name=$volumePod};spec=@{automountServiceAccountToken=$false;restartPolicy='Never';containers=@(@{name='sandbox';image=$sourceImage;command=@('sh','-c','sleep 90');volumeMounts=@(@{name='data';mountPath='/data'})});volumes=@(@{name='data';emptyDir=@{}})}} | ConvertTo-Json -Depth 8 -Compress
    $volume | & kubectl --kubeconfig $Kubeconfig --request-timeout=15s --context $SourceContext -n $Namespace create -f -
    if ($LASTEXITCODE -ne 0) { throw 'cannot create volume rejection test Pod' }
    try {
        Invoke-Kubectl @('wait','--for=condition=Ready',"pod/$volumePod",'--timeout=35s')
        $ErrorActionPreference = 'Continue'
        $volumeOutput = & $Binary snapshot --context $SourceContext --pod $volumePod --container sandbox --helper-image $Helper --source-quiesced --image sandbox-oci-registry:5000/sandbox-oci-snapshot:volume --timeout 20s 2>&1
        $volumeExit = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($volumeExit -eq 0 -or (($volumeOutput -join "`n") -notmatch 'volumes and volume mounts are unsupported')) { throw 'CLI did not reject the source Pod volume before helper creation' }
    } finally { Invoke-Kubectl @('delete','pod',$volumePod,'--ignore-not-found=true','--wait=true') }
    $helpersAfter = @((Get-KubectlOutput @('get','jobs','-l','io.sandbox-oci.lab=true','-o','json') | ConvertFrom-Json).items).Count
    if ($helpersAfter -ne $helpersBefore) { throw 'volume rejection created a helper Job' }
    $Results.checks.volumeRejectedBeforeHelper = $true

    $missingPod = "sandbox-oci-failure-missing-$RunID"
    $missing = 'sandbox-oci-registry:5000/sandbox-oci-snapshot@sha256:' + ('0' * 64)
    $ErrorActionPreference = 'Continue'
    & $Binary restore --context $SourceContext --pod $missingPod --image $missing --timeout 25s 2>&1 | Out-Null
    $missingExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($missingExit -eq 0) { throw 'restore unexpectedly succeeded with an unavailable digest' }
    $missingState = Get-KubectlOutput @('get','pod',$missingPod,'-o','json') | ConvertFrom-Json
    $missingReason = [string](@($missingState.status.containerStatuses | Where-Object { $_.name -eq 'sandbox' })[0].state.waiting.reason)
    if ($missingState.spec.containers[0].image -ne $missing -or $missingReason -notmatch 'ErrImagePull|ImagePullBackOff') { throw "unavailable digest did not produce an image-pull failure: $missingReason" }
    Invoke-Kubectl @('delete','pod',$missingPod,'--ignore-not-found=true','--wait=false')
    $Results.checks.unavailableDigestRestoreBounded = $true

    $termJob = "sandbox-oci-failure-term-$RunID"
    $SourceMayBePaused = $true
    $GatedJobs.Add($termJob)
    New-HelperJob $termJob $TestHelper $Initial @('source',$Namespace,'sandbox:sandbox-oci-registry:5000/sandbox-oci-snapshot:term') $true
    $termPod = Wait-Gate $termJob
    $termID = ([string](@($termPod.status.containerStatuses | Where-Object { $_.name -eq 'helper' })[0].containerID) -replace '^containerd://','')
    if (-not $termID) { throw 'gated helper container ID is unavailable' }
    Invoke-DockerNode $Initial.node @('ctr','-n','k8s.io','tasks','kill','--signal','SIGTERM',$termID)
    $termResult = Wait-HelperTermination $termJob
    if ($termResult.exitCode -eq 0) { throw 'SIGTERM helper unexpectedly succeeded' }
    Assert-SourceRunning $Initial 'SIGTERM helper recovery'
    Assert-NoLease $Initial
    $SourceMayBePaused = $false
    $Results.checks.sigtermRecovery = $true

    $killJob = "sandbox-oci-failure-kill-$RunID"
    $SourceMayBePaused = $true
    $GatedJobs.Add($killJob)
    New-HelperJob $killJob $TestHelper $Initial @('source',$Namespace,'sandbox:sandbox-oci-registry:5000/sandbox-oci-snapshot:kill') $true
    $killPod = Wait-Gate $killJob
    $killID = ([string](@($killPod.status.containerStatuses | Where-Object { $_.name -eq 'helper' })[0].containerID) -replace '^containerd://','')
    if (-not $killID) { throw 'gated helper container ID is unavailable' }
    Invoke-DockerNode $Initial.node @('ctr','-n','k8s.io','tasks','kill','--signal','SIGKILL',$killID)
    $killResult = Wait-HelperTermination $killJob
    if ($killResult.exitCode -eq 0) { throw 'SIGKILL helper unexpectedly succeeded' }
    Assert-SourcePaused $Initial
    Recover-Source $Initial $Helper
    # A second explicit recovery must tolerate the already-resumed task and a
    # lease that was removed by the first recovery helper.
    Recover-Source $Initial $Helper
    $Results.checks.sigkillExplicitRecovery = $true
    $Results.checks.recoveryIdempotent = $true

    $Results.passed = $true
    $Results.completedUTC = [DateTime]::UtcNow.ToString('o')
    Write-Output 'PASS: stale identity, volume rejection, bounded missing restore, SIGTERM recovery and SIGKILL recovery verified.'
} catch {
    $Results.error = $_.Exception.Message
    throw
} finally {
    if ($SourceMayBePaused -and $null -ne $Initial -and $Helper) {
        try {
            Terminate-ActiveGatedHelpers $Initial
            Recover-Source $Initial $Helper
        } catch { $Results.recoveryError = $_.Exception.Message }
    }
    foreach ($job in $CreatedJobs) {
        try { Invoke-Kubectl @('delete','job',$job,'--ignore-not-found=true','--wait=false') } catch { }
    }
    [IO.File]::WriteAllText($ReportPath,($Results | ConvertTo-Json -Depth 8))
    $env:KUBECONFIG = $OldKubeconfig
}
