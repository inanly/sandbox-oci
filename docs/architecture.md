# PoC architecture

The host Go CLI invokes `kubectl` with an explicit context. It rejects unsupported
source Pods, records their UID and container ID, and schedules a digest-pinned
privileged helper Job on the same node. No controller or CRD is installed.

The helper resolves that exact container through containerd, acquires a
per-container lease, runs `sync`, pauses execution, and delegates image creation
to the pinned OpenSandbox `imagecommitter` library. It resumes the source before
pushing the image and returns its digest through the Pod termination message.
The CLI validates the result and checks the original identity again.

The normal helper image does not include test controls. A separate `faulttest`
build tag adds a pause gate to the helper so the failure-path script can send
signals while the source is paused; it is built and published independently of
the normal helper image. `scripts/test-failures.ps1` uses the existing source
fixture and checks stale-container identity rejection, volume rejection, bounded
restore failure for an unavailable digest, SIGTERM recovery, SIGKILL followed by
explicit recovery, and repeated explicit recovery.

The base image configuration is preserved. Kubernetes Pod environment overrides,
commands, networking, credentials and volumes are not reconstructed. Restore
creates a new Pod from a digest, optionally with explicit command/args/workdir.
Applications restart; this is not process continuation.

## Controlled environment

The first supported target is Linux/amd64 kind with containerd overlayfs and a
single quiesced container. The helper needs the node containerd socket and state
directory. It has node-level privilege, even though the host CLI does not run as
administrator. Use only the disposable lab or a similarly controlled environment.

The lab registry has two names: `localhost:5001` for the host and
`sandbox-oci-registry:5000` for containers. Source images must use the latter so
the helper can fetch base blobs missing from containerd's content store.
containerd may retain an earlier image reference when different names resolve to
the same cached image; use a fresh lab node when changing this configuration.
The snapshot command defaults `--source-registry-insecure` and
`--target-registry-insecure` to `false`. The lab examples set both to `true`:
each flag skips TLS certificate verification and permits HTTP fallback for its
corresponding helper operation. The source flag covers source base-blob fetch;
the target flag covers output push. Neither flag changes kubelet image pulls or
Docker behavior. Credential and custom-CA configuration are not implemented.

Transport follows the pinned upstream resolver: HTTPS is attempted first, and
an insecure opt-in allows HTTP fallback on scheme mismatch or connection refusal.
The resolver's redirect policy is unchanged; these flags do not enforce an
HTTPS-only redirect chain.

## Recovery limits

Normal errors and SIGTERM trigger a bounded attempt to resume the source using a
fresh context. The Job allows 90 seconds of termination grace. A persistent lease
prevents this tool's concurrent helpers from capturing the same container.
SIGKILL, node loss or runtime failure can still leave a paused task or stale
lease. These cases require operator recovery; automatic crash recovery is not
implemented. In particular, SIGKILL recovery is not automatic. The internal
helper `unpause` mode requires the original Pod UID and container ID and must
only run after the original helper has stopped. The fault-path script does not
test node loss.

To prepare and run the failure checks in the disposable lab:

```powershell
./scripts/lab.ps1 -Action bootstrap
./scripts/lab.ps1 -Action build
./scripts/lab.ps1 -Action source
./scripts/lab.ps1 -Action build-test-helper
./scripts/test-failures.ps1
```

The checks passed on 2026-09-08 at 11:26 UTC. The script writes its
machine-readable result to `artifacts/failures-result.json`. A normal-helper
snapshot after recovery also passed Docker verification with digest
`sha256:bee87c4f7d2ede16479507328c4b23864f779c72963ae989f8192b6210bc8a66`
(`artifacts/recovery-regression.json`). If a helper is killed, an operator must use
the original source identity with the helper's explicit `unpause` mode before
reusing that container; the recovery helper also removes the per-container
lease. Do not run recovery while the original helper is still active.

## Next bounded milestone

- Run the checked-in Linux GitHub Actions workflow and address platform issues.
- Prepare a small upstream discussion describing the reuse, portability proof
  and registry-reference finding; publication remains a separate action.

The unpublished discussion draft is [`upstream-discussion.md`](upstream-discussion.md).

Keep controllers, GPU, CRIU, volumes and incremental snapshots out of this pass.
