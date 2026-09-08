# sandbox-oci

Experimental Go CLI for capturing one quiesced Linux/amd64 container rootfs from kind containerd overlayfs, publishing it to a local OCI registry, and restoring it into Docker or a fresh kind cluster.

The first end-to-end lab passed on 2026-09-08 using Windows PowerShell and Docker Desktop's Linux engine: failed push preserved the source, Docker verified the snapshot, and a fresh kind cluster restored it after deletion of the source Pod. See [acceptance results](docs/acceptance.md) and [architecture and limits](docs/architecture.md). This is a controlled PoC, not a general Kubernetes snapshot service.

The rootfs contract is strict: the source pod has exactly one container, no volumes or volume mounts of any kind, no init or ephemeral containers, and no probes. Set `automountServiceAccountToken: false`; this also keeps the automatically projected service-token mount out of the source. Files intentionally written into the rootfs, including secrets, are captured as filesystem content; there is no automatic redaction. The source must be quiesced, include the sync executable, and have no probes that could restart it while the helper pauses it.

The helper is a digest-pinned privileged node Job. It uses the node's containerd socket and `/var/lib/containerd` at those exact paths, rejects a source identity mismatch before capture, and performs the overlayfs operation. The host CLI never deletes the source pod. The lab registry target is local HTTP with TLS disabled and has no credential support; do not use that default for production. Snapshot transport has `--source-registry-insecure` and `--target-registry-insecure` flags, both defaulting to `false`. Setting a flag makes the corresponding helper operation skip TLS certificate verification and permit HTTP fallback: source base-blob fetch for the former, and output push for the latter. These flags do not affect kubelet image pulls or Docker behavior. Credentials and custom CAs are not implemented.

The upstream `imagecommitter` source is reused at commit [`d34f5e19ff0d6c48b0b59b8a5ed6ecc432c2e186`](https://github.com/opensandbox-group/OpenSandbox/tree/d34f5e19ff0d6c48b0b59b8a5ed6ecc432c2e186). See [`NOTICE`](NOTICE) for attribution.

## Local lab

The lab requires Go 1.25, Git, Docker with a running Linux engine, and a
`kubectl` version compatible with the Kubernetes version used by kind. Run the
commands from the repository root. Use Windows PowerShell 5+ on Windows, or
`pwsh` on Linux. The lab is Linux/amd64 only.

`lab.ps1` downloads and caches the pinned kind binary and the pinned upstream
OpenSandbox checkout under `.cache/`, and records pulled image digests under
`artifacts/`. Tool versions, the upstream commit and base image digests are pinned
in `versions.json`; an empty cache requires network access to fetch them again.
Cached kind versions are checked before reuse. The lab does not promise identical
snapshot bytes across runs. The restore check creates a new kind cluster and
uses its isolated containerd image store, so it does not rely on the source
cluster's running Pod or image store.

On Windows PowerShell:

```powershell
./scripts/lab.ps1 -Action bootstrap
./scripts/lab.ps1 -Action build
./scripts/lab.ps1 -Action source
./scripts/test-e2e.ps1
```

The end-to-end script builds the CLI, checks a failed registry push, captures
to the good registry, verifies with a new Docker container using the host image
store, deletes the source, and verifies restore through the isolated image
store of a fresh kind cluster. To prepare the lab and run the test in one
step, use `./scripts/test-e2e.ps1 -Prepare`. The same actions are available
with `pwsh` on Linux. A CI workflow exists, but it has not been run on GitHub
yet.

The E2E run deletes the source Pod as part of its fresh-kind restore check.
Recreate the source fixture before running the failure-path checks. They use a
separate helper image built with the `faulttest` tag; the normal helper image
is unchanged:

```powershell
./scripts/lab.ps1 -Action source
./scripts/lab.ps1 -Action build-test-helper
./scripts/test-failures.ps1
```

The script checks stale source identity rejection, source Pods with volumes,
bounded restore failure for an unavailable digest, SIGTERM automatic resume,
SIGKILL followed by explicit recovery, and repeated explicit recovery. These
checks passed on 2026-09-08 at 11:26 UTC; the machine-readable result is in
`artifacts/failures-result.json`.

To check registry transport against an existing source fixture, run
`./scripts/test-registry.ps1`. It verifies that default target HTTPS rejects the
HTTP lab registry, then opts in and checks the resulting image through Docker.
The recorded pass is in `artifacts/registry-result.json`.

After building both helper variants, `./scripts/test-attribution.ps1` checks
their embedded license and dependency inventory files. See
[helper attribution](docs/attribution.md) for contents and inspection commands.

Cleanup is explicit:

```powershell
./scripts/lab.ps1 -Action cleanup
```

Cleanup removes only the lab's known cluster/node ownership and its ephemeral registry snapshots. The scripts restore the prior `KUBECONFIG`; they do not modify a global token or kubeconfig.

The default source lab objects are context `kind-sandbox-oci-source`, namespace `sandbox-oci`, pod `source`, container `sandbox`, and registry target `sandbox-oci-registry:5000/sandbox-oci-snapshot:demo`. The pinned helper image is read from [`artifacts/helper-image.txt`](artifacts/helper-image.txt). The generated kubeconfig is [`artifacts/kubeconfig`](artifacts/kubeconfig).

SIGTERM gets a bounded resume attempt. SIGKILL does not trigger automatic
recovery and can leave the source paused or a lease behind; run explicit
operator recovery with the original Pod UID and container ID after confirming
the killed helper has stopped. Node-loss recovery is not implemented or tested.

## CLI

Build the CLI with Go (the main binary has no Go API dependencies, but the lab requires `kubectl`; the helper is compiled from the pinned upstream source). Use the `.exe` output name on Windows and the extensionless output name on Linux:

```powershell
# Windows PowerShell
go build -buildvcs=false -o bin/sandbox-oci.exe ./cmd/sandbox-oci

# Linux with pwsh
go build -buildvcs=false -o bin/sandbox-oci ./cmd/sandbox-oci
```

Every command requires an explicit `--context`; `--namespace` defaults to `sandbox-oci`, and `--output` accepts `text` or `json`.

```text
sandbox-oci doctor --context kind-sandbox-oci-source
sandbox-oci snapshot --context kind-sandbox-oci-source --pod source --container sandbox --helper-image <digest-pinned-helper> --source-quiesced --source-registry-insecure --target-registry-insecure --image sandbox-oci-registry:5000/sandbox-oci-snapshot:demo --output json
sandbox-oci restore --context kind-sandbox-oci-restore --pod restored --image localhost:5001/sandbox-oci-snapshot@sha256:<64-hex-digest>
sandbox-oci version
```

`restore` also accepts optional JSON `--command` and `--args` arrays and `--working-dir`. `doctor` checks Kubernetes access, required get/create Job, pod, node, and ServiceAccount permissions, and node Linux/amd64/containerd identity; it does not prove snapshotter selection or host mount availability. `version` reports the pinned source SHA.
