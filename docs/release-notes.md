# Experimental initial release notes

This document records the scope and previously observed evidence for the
experimental initial release of `sandbox-oci`. It is release documentation
only; source is available at [inanly/sandbox-oci](https://github.com/inanly/sandbox-oci).
No tagged GitHub release has been created.

This candidate distributes source only. Build it with
`./scripts/package-source.ps1`; the ignored `artifacts/release-candidate/`
directory contains the ZIP, a per-file SHA-256 manifest, and `SHA256SUMS`.
The archive includes Git's nonignored source candidates, including uncommitted
files. Review the manifest before publishing. ZIP byte-for-byte reproducibility
is not promised because source timestamps are preserved.

Helper images now include project/upstream licenses, Go dependency attribution,
toolchain and CA-certificate notices, plus a dependency inventory and build
information. Extraction checks passed for both helper variants (43 modules each)
on 2026-09-08 at 12:32 UTC. See [attribution.md](attribution.md).
Images remain local; no public binary or image release has been created.

The project captures one quiesced Linux/amd64 container rootfs from kind's
containerd overlayfs, publishes it to an OCI registry, and restores it through
Docker or a fresh kind cluster. The supported contract is a single container
with no volumes, volume mounts, init containers, ephemeral containers, or
probes. The helper is privileged and digest-pinned. Controllers, SaaS, UI,
GPU, RAM checkpoints, and user-volume snapshots are outside scope.

Previously recorded checks include `go test ./...`, `go vet ./...`, a Windows
PowerShell E2E run using Docker Desktop's Linux engine, failed-push source
preservation, Docker verification, source deletion followed by fresh-kind
restore, failure-path recovery checks, and local HTTP registry transport
checks. The detailed evidence and timestamps are in
[acceptance.md](acceptance.md) and the ignored JSON files under `artifacts/`.

The source candidate was subsequently verified on 2026-09-08 at 12:19–12:20 UTC:
E2E, failure/recovery and registry suites all passed after recreating the owned
clusters and registry, with tool and host image caches retained. Extracted ZIP
files matched the manifest, and their Go tests, vet and build passed.
GitHub Actions runs are available in the [workflow history](https://github.com/inanly/sandbox-oci/actions/workflows/ci.yml).
Node-loss recovery, an external pause race, custom or
self-signed TLS handling, and a forced source base-blob refetch remain
untested.
