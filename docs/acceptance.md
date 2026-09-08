# Acceptance criteria

## Source candidate validation — 2026-09-08

A complete sequential rerun passed after deleting and recreating only the owned
lab clusters and registry. Tool/upstream caches and the host Docker image cache
were retained; this was not an empty-machine installation test.

- End-to-end Docker and fresh-kind restore: passed at 12:19 UTC.
- Failure/recovery suite: passed at 12:20 UTC.
- Registry HTTPS-default/HTTP-opt-in suite: passed at 12:20 UTC.
- Extracted source candidate: every file matched its SHA-256 manifest; Go tests,
  vet and CLI build passed.

Current E2E image digest:
`sha256:e2b88a1d8bd79b16b1141423b1d4455305b0b660231dd35af21fe8d3f05cced5`.
The ignored evidence JSON files below contain the latest run. Earlier digests
and timestamps in this document are historical observations.

## Initial evidence

Subsequent attribution packaging checks passed on 2026-09-08 at 12:32 UTC for
both helper variants, with 43 dependency modules each. The standalone collector
tests and normal-helper registry/snapshot/Docker-restore regression also passed.
See `artifacts/attribution-result.json` and [attribution.md](attribution.md).

The first end-to-end pass completed on 2026-09-08 at 11:08 UTC on Windows PowerShell with Docker Desktop's Linux engine, kind v0.33.0 and Kubernetes v1.34.11. Generated evidence is in `artifacts/e2e-result.json`, `artifacts/snapshot.json` and `artifacts/expected-push-failure.txt` (ignored by Git).

| Check | Actual result |
| --- | --- |
| Added/modified/deleted fixture files, symlinks, permissions, UID/GID, NumPy | Passed in Docker and fresh kind |
| Source Pod deleted before fresh-kind restore | Passed |
| Failed push preserves usable source; subsequent snapshot succeeds | Passed |
| Pod environment canary absent from image configuration | Passed |
| Volume/multiple-container/probe rejection and helper identity result validation | Go unit tests passed |
| `go test ./...` and `go vet ./...` | Passed |
| Linux pinned Go container test/vet/build | Passed |
| Failure-path checks: stale identity, volume rejection, unavailable-digest restore, SIGTERM resume, SIGKILL explicit recovery, repeated recovery | Passed at 2026-09-08 11:26 UTC; see `artifacts/failures-result.json` |
| Normal-helper snapshot after recovery and Docker verification | Passed; digest `sha256:bee87c4f7d2ede16479507328c4b23864f779c72963ae989f8192b6210bc8a66`; see `artifacts/recovery-regression.json` |
| Node-loss recovery | Not tested |
| External pause-race integration | Not tested |
| Linux GitHub Actions | See [remote workflow results](https://github.com/inanly/sandbox-oci/actions/workflows/ci.yml); local evidence below is separate |
| Independent source/target registry flags, default false | Go tests passed |
| Default target HTTPS rejects HTTP; explicit target opt-in permits snapshot and Docker restore | Passed; `artifacts/registry-result.json` |

Registry integration coverage exercises the local HTTP target. It does not prove
custom/self-signed TLS handling or force a source base-blob refetch; those remain
untested. The source/target flag independence is covered by the CLI tests.

Snapshot manifest digest: `sha256:fe8e57181fb878ff7143bf7bc308e6228ef6bd5d4b7c5a5f88cb214a1e4292a5`.
These tests cover the fixture contract, not a byte-for-byte audit of every rootfs path.

## Filesystem fidelity

Given a quiesced single-container Linux/amd64 rootfs, the snapshot and restore flow must preserve:

- added, modified, and deleted base files;
- overlayfs whiteouts for deleted files;
- symbolic links, including link targets;
- file permissions and executable bits;
- numeric UID and GID ownership;
- a NumPy runtime installation and its importable native/runtime files.

## Restore and identity

- A cold restore through Docker must reproduce the source rootfs and verify the published OCI digest in a new container using the host image store.
- A cold restore into a fresh kind containerd environment must reproduce the source rootfs and verify the published OCI digest through kind's isolated image store.
- Publishing to a bad or unavailable registry must fail without making the source container unusable (tested). Restore with an unavailable digest fails within its bounded timeout (tested).
- A snapshot with a mismatched source identity must be rejected before capture.

## Explicit exclusions

- A snapshot request that includes a mounted volume must be rejected rather than silently copying or embedding that volume.
- Secret material intentionally written into the rootfs is captured; there is no automatic redaction.
- Pod environment metadata and the service-account token mount are excluded by scope (`automountServiceAccountToken: false`); live process state is outside the snapshot contract.

## Privilege boundary

Operations requiring kind-node privileges must run through the dedicated privileged node helper. The unprivileged CLI must not require unrestricted host access, and helper failures must be returned as actionable errors.
