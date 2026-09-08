[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('bootstrap', 'build', 'build-test-helper', 'source', 'restore-cluster', 'cleanup')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
$RepoRoot = Split-Path -Parent $PSScriptRoot
$CacheDir = Join-Path $RepoRoot '.cache'
$ToolsDir = Join-Path $CacheDir 'tools'
$ArtifactsDir = Join-Path $RepoRoot 'artifacts'
$VersionsPath = Join-Path $RepoRoot 'versions.json'
$Kubeconfig = Join-Path $ArtifactsDir 'kubeconfig'
$ImagesPath = Join-Path $ArtifactsDir 'images.json'
$RegistryName = 'sandbox-oci-registry'
$RegistryPort = '127.0.0.1:5001'
$RegistryTarget = 'sandbox-oci-registry:5000'
$SourceCluster = 'sandbox-oci-source'
$RestoreCluster = 'sandbox-oci-restore'

if (-not (Test-Path -LiteralPath $VersionsPath)) {
    throw "Missing versions file: $VersionsPath"
}
$Versions = Get-Content -LiteralPath $VersionsPath -Raw | ConvertFrom-Json
if ($Versions.platform -ne 'linux/amd64') {
    throw "This lab only supports linux/amd64; versions.json specifies $($Versions.platform)."
}

$DockerContextArgs = @()
if ($env:OS -eq 'Windows_NT') {
    $DockerContextArgs = @('--context', 'desktop-linux')
}

function Invoke-LabCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter()][string[]]$Arguments = @()
    )

    try {
        & $Command @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$Command exited with code $LASTEXITCODE."
        }
    }
    catch {
        throw "Command failed: $Command $($Arguments -join ' ')`n$($_.Exception.Message)"
    }
}

function Get-LabOutput {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter()][string[]]$Arguments = @()
    )

    try {
        $output = & $Command @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$Command exited with code $LASTEXITCODE."
        }
        return ($output | Out-String).Trim()
    }
    catch {
        throw "Command failed: $Command $($Arguments -join ' ')`n$($_.Exception.Message)"
    }
}

function Invoke-Docker {
    param([string[]]$Arguments)
    Invoke-LabCommand -Command 'docker' -Arguments ($DockerContextArgs + $Arguments)
}

function Get-DockerOutput {
    param([string[]]$Arguments)
    return Get-LabOutput -Command 'docker' -Arguments ($DockerContextArgs + $Arguments)
}

function Invoke-Kubectl {
    param([string[]]$Arguments)
    Invoke-LabCommand -Command 'kubectl' -Arguments (@('--kubeconfig', $Kubeconfig) + $Arguments)
}

function Invoke-SourceKubectl {
    param([string[]]$Arguments)
    Invoke-LabCommand -Command 'kubectl' -Arguments (@('--kubeconfig', $Kubeconfig, '--context', "kind-$SourceCluster") + $Arguments)
}

function Get-SourceKubectlOutput {
    param([string[]]$Arguments)
    return Get-LabOutput -Command 'kubectl' -Arguments (@('--kubeconfig', $Kubeconfig, '--context', "kind-$SourceCluster") + $Arguments)
}

function Get-KindPath {
    $suffix = if ($env:OS -eq 'Windows_NT') { '.exe' } else { '' }
    return Join-Path $ToolsDir ("kind$suffix")
}

function Get-KindOutput {
    param([string[]]$Arguments)
    return Get-LabOutput -Command (Get-KindPath) -Arguments $Arguments
}

function Invoke-Kind {
    param([string[]]$Arguments)
    Invoke-LabCommand -Command (Get-KindPath) -Arguments $Arguments
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Ensure-Directories {
    New-Item -ItemType Directory -Force -Path $ToolsDir, $ArtifactsDir | Out-Null
}

function Ensure-KindBinary {
    Ensure-Directories
    $kindPath = Get-KindPath
    if (Test-Path -LiteralPath $kindPath) {
        $actualVersion = Get-LabOutput -Command $kindPath -Arguments @('version')
        if ($actualVersion -notmatch ('^kind ' + [regex]::Escape($Versions.kindVersion) + '(\s|$)')) {
            throw "Cached kind does not match versions.json ($($Versions.kindVersion)): $actualVersion. Replace the cached binary at $kindPath before continuing."
        }
        return
    }

    $osName = if ($env:OS -eq 'Windows_NT') { 'windows' } elseif ($IsLinux) { 'linux' } else { throw 'Only Windows and Linux hosts are supported.' }
    $asset = "kind-$osName-amd64"
    $baseUrl = "https://github.com/kubernetes-sigs/kind/releases/download/$($Versions.kindVersion)"
    $downloadPath = "$kindPath.download"
    $checksumPath = "$downloadPath.sha256sum"
    Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$asset" -OutFile $downloadPath
    Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$asset.sha256sum" -OutFile $checksumPath
    $checksumLine = (Get-Content -LiteralPath $checksumPath -Raw).Trim()
    if ($checksumLine -notmatch '^(?<hash>[A-Fa-f0-9]{64})\s+') {
        throw "Unrecognised checksum format in $checksumPath"
    }
    $actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $Matches.hash.ToLowerInvariant()) {
        throw "kind checksum mismatch: expected $($Matches.hash), got $actualHash"
    }
    Move-Item -LiteralPath $downloadPath -Destination $kindPath
    Remove-Item -LiteralPath $checksumPath -Force
    if ($osName -eq 'linux') {
        Invoke-LabCommand -Command 'chmod' -Arguments @('+x', $kindPath)
    }
}

function Ensure-OpenSandboxCache {
    $checkout = Join-Path $CacheDir 'opensandbox'
    $newCheckout = $false
    if (-not (Test-Path -LiteralPath $checkout)) {
        Invoke-LabCommand -Command 'git' -Arguments @('clone', '--no-checkout', 'https://github.com/opensandbox-group/OpenSandbox.git', $checkout)
        $newCheckout = $true
    }
    if (-not (Test-Path -LiteralPath (Join-Path $checkout '.git'))) {
        throw "OpenSandbox cache is not a git checkout: $checkout"
    }
    $dirty = Get-LabOutput -Command 'git' -Arguments @('-C', $checkout, 'status', '--porcelain')
    if ($dirty -and -not $newCheckout) {
        throw "Refusing to overwrite dirty OpenSandbox cache: $checkout"
    }
    Invoke-LabCommand -Command 'git' -Arguments @('-C', $checkout, 'fetch', '--depth', '1', 'origin', $Versions.opensandboxCommit)
    Invoke-LabCommand -Command 'git' -Arguments @('-C', $checkout, 'checkout', '--detach', $Versions.opensandboxCommit)
    $actualCommit = Get-LabOutput -Command 'git' -Arguments @('-C', $checkout, 'rev-parse', 'HEAD')
    if ($actualCommit -ne $Versions.opensandboxCommit) {
        throw "OpenSandbox checkout mismatch: expected $($Versions.opensandboxCommit), got $actualCommit"
    }
}

function Get-ImageDigestReference {
    param([string]$Image)
    $digest = Get-DockerOutput -Arguments @('image', 'inspect', '--format', '{{index .RepoDigests 0}}', $Image)
    if (-not $digest -or $digest -eq '<no value>') {
        throw "Docker did not report a RepoDigest for $Image"
    }
    return $digest
}

function Read-ImageLocks {
    if (-not (Test-Path -LiteralPath $ImagesPath)) {
        throw "Run bootstrap first; missing $ImagesPath"
    }
    return (Get-Content -LiteralPath $ImagesPath -Raw | ConvertFrom-Json)
}

function Ensure-Registry {
    $exists = $false
    try {
        $label = ((Get-DockerOutput -Arguments @('container', 'inspect', '--format', '{{json .Config.Labels}}', $RegistryName)) | ConvertFrom-Json).'io.sandbox-oci.lab'
        $exists = $true
    }
    catch {
        $exists = $false
    }
    if ($exists) {
        if ($label -ne 'true') {
            throw "Refusing to use existing unlabelled registry container: $RegistryName"
        }
        $running = Get-DockerOutput -Arguments @('container', 'inspect', '--format', '{{.State.Running}}', $RegistryName)
        if ($running -ne 'true') {
            Invoke-Docker -Arguments @('start', $RegistryName)
        }
        return
    }
    Invoke-Docker -Arguments @('run', '-d', '--name', $RegistryName, '--label', 'io.sandbox-oci.lab=true', '-p', "$RegistryPort`:5000", $Versions.registryImage)
}

function Ensure-RegistryOnKindNetwork {
    $network = Get-DockerOutput -Arguments @('container', 'inspect', '--format', '{{json .NetworkSettings.Networks.kind}}', $RegistryName)
    if ($network -eq 'null' -or -not $network) {
        Invoke-Docker -Arguments @('network', 'connect', 'kind', $RegistryName)
    }
}

function Test-KindClusterExists {
    param([string]$Name)
    $clusters = Get-KindOutput -Arguments @('get', 'clusters')
    return (($clusters -split "`r?`n") -contains $Name)
}

function New-FreshKindCluster {
    param([string]$Name)
    if (Test-KindClusterExists -Name $Name) {
        throw "Cluster already exists: $Name. Refusing to replace it."
    }
    Invoke-Kind -Arguments @('create', 'cluster', '--name', $Name, '--image', $Versions.nodeImage, '--kubeconfig', $Kubeconfig)
    Ensure-RegistryOnKindNetwork
    Configure-KindRegistry -ClusterName $Name
    $nodeRecords = @()
    foreach ($node in ((Get-KindOutput -Arguments @('get', 'nodes', '--name', $Name)) -split "`r?`n" | Where-Object { $_ })) {
        $nodeRecords += [ordered]@{ name = $node; id = (Get-DockerOutput -Arguments @('container', 'inspect', '--format', '{{.Id}}', $node)) }
    }
    $marker = [ordered]@{ cluster = $Name; nodes = $nodeRecords }
    Write-Utf8NoBom -Path (Join-Path $ArtifactsDir "$Name-nodes.json") -Text (($marker | ConvertTo-Json) + "`n")
}

function Configure-KindRegistry {
    param([string]$ClusterName)
    $nodes = Get-KindOutput -Arguments @('get', 'nodes', '--name', $ClusterName)
    $hostsToml = "server = `"http://$RegistryTarget`"`n`n[host.`"http://$RegistryTarget`"]`n  capabilities = [`"pull`", `"resolve`", `"push`"]`n"
    foreach ($node in ($nodes -split "`r?`n" | Where-Object { $_ })) {
        Invoke-Docker -Arguments @('exec', $node, 'mkdir', '-p', '/etc/containerd/certs.d/sandbox-oci-registry:5000')
        Invoke-Docker -Arguments @('exec', $node, 'mkdir', '-p', '/etc/containerd/certs.d/localhost:5001')
        try {
            $hostsToml | & docker @DockerContextArgs exec -i $node tee /etc/containerd/certs.d/localhost:5001/hosts.toml
            if ($LASTEXITCODE -ne 0) { throw "docker exec tee exited with code $LASTEXITCODE" }
            Invoke-Docker -Arguments @('exec', $node, 'cp', '/etc/containerd/certs.d/localhost:5001/hosts.toml', '/etc/containerd/certs.d/sandbox-oci-registry:5000/hosts.toml')
        }
        catch {
            throw "Failed to configure registry alias on kind node ${node}: $($_.Exception.Message)"
        }
    }
}

function Bootstrap {
    Ensure-Directories
    Ensure-KindBinary
    Ensure-OpenSandboxCache
    foreach ($image in @($Versions.goImage, $Versions.pythonImage, $Versions.registryImage, $Versions.nodeImage)) {
        Invoke-Docker -Arguments @('pull', '--platform', 'linux/amd64', $image)
    }
    $images = [ordered]@{
        go = Get-ImageDigestReference -Image $Versions.goImage
        python = Get-ImageDigestReference -Image $Versions.pythonImage
        registry = Get-ImageDigestReference -Image $Versions.registryImage
        node = Get-ImageDigestReference -Image $Versions.nodeImage
    }
    Write-Utf8NoBom -Path $ImagesPath -Text (($images | ConvertTo-Json) + "`n")
    Ensure-Registry
    New-FreshKindCluster -Name $SourceCluster
}

function Build {
    Ensure-Directories
    $images = Read-ImageLocks
    $helperTag = 'localhost:5001/sandbox-oci-helper:dev'
    $fixtureTag = 'localhost:5001/sandbox-oci-fixture:base'
    Invoke-Docker -Arguments @('build', '--platform', 'linux/amd64', '-f', (Join-Path $RepoRoot 'helper/Dockerfile'), '--build-arg', "GO_IMAGE=$($Versions.goImage)", '-t', $helperTag, $RepoRoot)
    Invoke-Docker -Arguments @('build', '--platform', 'linux/amd64', '-f', (Join-Path $RepoRoot 'testdata/Dockerfile'), '--build-arg', "BASE_IMAGE=$($Versions.pythonImage)", '-t', $fixtureTag, $RepoRoot)
    Invoke-Docker -Arguments @('push', $helperTag)
    Invoke-Docker -Arguments @('push', $fixtureTag)
    $helperDigest = Get-DockerOutput -Arguments @('image', 'inspect', '--format', '{{index .RepoDigests 0}}', $helperTag)
    Write-Utf8NoBom -Path (Join-Path $ArtifactsDir 'helper-image.txt') -Text ($helperDigest + "`n")
}

function Build-TestHelper {
    Ensure-Directories
    $testTag = 'localhost:5001/sandbox-oci-helper:faulttest'
    Invoke-Docker -Arguments @('build', '--platform', 'linux/amd64', '-f', (Join-Path $RepoRoot 'helper/Dockerfile'), '--build-arg', "GO_IMAGE=$($Versions.goImage)", '--build-arg', 'BUILD_TAGS=faulttest', '-t', $testTag, $RepoRoot)
    Invoke-Docker -Arguments @('push', $testTag)
    $digest = Get-DockerOutput -Arguments @('image', 'inspect', '--format', '{{index .RepoDigests 0}}', $testTag)
    Write-Utf8NoBom -Path (Join-Path $ArtifactsDir 'test-helper-image.txt') -Text ($digest + "`n")
}

function Source {
    if (-not (Test-KindClusterExists -Name $SourceCluster)) {
        throw "Source cluster is absent. Run bootstrap first."
    }
    $existingNamespace = Get-SourceKubectlOutput -Arguments @('get', 'namespace', 'sandbox-oci', '--ignore-not-found', '-o', 'name')
    if (-not $existingNamespace) { Invoke-SourceKubectl -Arguments @('create', 'namespace', 'sandbox-oci') }
    Invoke-SourceKubectl -Arguments @('-n', 'sandbox-oci', 'wait', '--for=create', 'serviceaccount/default', '--timeout=60s')
    $existingPod = Get-SourceKubectlOutput -Arguments @('-n', 'sandbox-oci', 'get', 'pod', 'source', '--ignore-not-found', '-o', 'name')
    if ($existingPod) {
        throw 'Source pod already exists. Refusing to replace it.'
    }
    $pod = @'
apiVersion: v1
kind: Pod
metadata:
  name: source
  namespace: sandbox-oci
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  containers:
  - name: sandbox
    image: sandbox-oci-registry:5000/sandbox-oci-fixture:base
    env:
    - name: SECRET_CANARY
      value: not-for-image-config
'@
    try {
        $pod | & kubectl --kubeconfig $Kubeconfig --context "kind-$SourceCluster" create -f -
        if ($LASTEXITCODE -ne 0) { throw 'kubectl create failed.' }
    }
    catch {
        throw "Failed to create source pod manifest: $($_.Exception.Message)"
    }
    Invoke-SourceKubectl -Arguments @('-n', 'sandbox-oci', 'wait', '--for=condition=Ready', 'pod/source', '--timeout=120s')
    Invoke-SourceKubectl -Arguments @('-n', 'sandbox-oci', 'exec', 'source', '-c', 'sandbox', '--', 'python3', '/opt/fixture/mutate.py')
    Invoke-SourceKubectl -Arguments @('-n', 'sandbox-oci', 'exec', 'source', '-c', 'sandbox', '--', 'python3', '/opt/fixture/verify.py')
}

function Restore-Cluster {
    New-FreshKindCluster -Name $RestoreCluster
    Invoke-Kubectl -Arguments @('--context', "kind-$RestoreCluster", 'create', 'namespace', 'sandbox-oci')
    Invoke-Kubectl -Arguments @('--context', "kind-$RestoreCluster", '-n', 'sandbox-oci', 'wait', '--for=create', 'serviceaccount/default', '--timeout=60s')
}

function Remove-OwnedKindCluster {
    param([string]$Name)
    if (-not (Test-KindClusterExists -Name $Name)) { return }
    $markerPath = Join-Path $ArtifactsDir "$Name-nodes.json"
    if (-not (Test-Path -LiteralPath $markerPath)) {
        throw "Refusing to delete $Name without its lab ownership marker: $markerPath"
    }
    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    if ($marker.cluster -ne $Name) {
        throw "Refusing to delete $Name because its ownership marker names $($marker.cluster)."
    }
    $nodes = (Get-KindOutput -Arguments @('get', 'nodes', '--name', $Name)) -split "`r?`n" | Where-Object { $_ }
    if (@($nodes).Count -ne @($marker.nodes).Count) {
        throw "Refusing to delete $Name because its nodes do not match the lab ownership marker."
    }
    foreach ($node in $nodes) {
        $owner = ((Get-DockerOutput -Arguments @('container', 'inspect', '--format', '{{json .Config.Labels}}', $node)) | ConvertFrom-Json).'io.x-k8s.kind.cluster'
        if ($owner -ne $Name) {
            throw "Refusing to delete cluster $Name because node $node is not labelled as its kind node."
        }
        $record = @($marker.nodes | Where-Object { $_.name -eq $node })
        $actualId = Get-DockerOutput -Arguments @('container', 'inspect', '--format', '{{.Id}}', $node)
        if ($record.Count -ne 1 -or $record[0].id -ne $actualId) {
            throw "Refusing to delete $Name because node $node does not match the lab ownership marker."
        }
    }
    Invoke-Kind -Arguments @('delete', 'cluster', '--name', $Name, '--kubeconfig', $Kubeconfig)
}

function Cleanup {
    Remove-OwnedKindCluster -Name $SourceCluster
    Remove-OwnedKindCluster -Name $RestoreCluster
    $existing = Get-DockerOutput -Arguments @('ps', '-a', '--filter', "name=^/$RegistryName$", '--format', '{{.Names}}')
    if (-not $existing) { return }
    try {
        $label = ((Get-DockerOutput -Arguments @('container', 'inspect', '--format', '{{json .Config.Labels}}', $RegistryName)) | ConvertFrom-Json).'io.sandbox-oci.lab'
        if ($label -ne 'true') {
            throw "Refusing to delete existing unlabelled registry container: $RegistryName"
        }
        Invoke-Docker -Arguments @('rm', '-f', $RegistryName)
    }
    catch {
        if ($_.Exception.Message -notmatch 'No such container') { throw }
    }
}

switch ($Action) {
    'bootstrap' { Bootstrap }
    'build' { Build }
    'build-test-helper' { Build-TestHelper }
    'source' { Source }
    'restore-cluster' { Restore-Cluster }
    'cleanup' { Cleanup }
}
