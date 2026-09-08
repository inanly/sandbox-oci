# Upstream discussion draft

## Reusing `imagecommitter` for a small portability PoC

This is a draft for maintainer discussion; it has not been posted upstream.

This project reuses the OpenSandbox `imagecommitter` implementation at the
pinned commit [`d34f5e19ff0d6c48b0b59b8a5ed6ecc432c2e186`](https://github.com/opensandbox-group/OpenSandbox/tree/d34f5e19ff0d6c48b0b59b8a5ed6ecc432c2e186),
with attribution and the upstream notices retained in [`NOTICE`](../NOTICE).
The surrounding code is a deliberately small lifecycle adapter: it resolves
one containerd container, acquires a per-container lease, pauses a quiesced
source, delegates image creation to `imagecommitter`, resumes the source, and
returns the resulting digest.

The working portability proof is a controlled Linux/amd64 kind environment
using containerd overlayfs and a disposable local OCI registry. The same
snapshot is checked through Docker and restored into a fresh kind cluster. The
scope is intentionally limited to one quiesced container rootfs; Kubernetes
Pod configuration, volumes, controllers, incremental snapshots, and process
continuation are outside this PoC. The implementation and current boundaries
are described in [`architecture.md`](architecture.md), with the recorded lab
outcome in [`acceptance.md`](acceptance.md).

One integration detail surfaced while making the helper portable: the helper
needs to fetch base blobs that may be absent from the node's containerd content
store, then push the resulting image. The CLI therefore exposes
`--source-registry-insecure` and `--target-registry-insecure`, both defaulting
to `false`. When enabled, the corresponding helper operation skips TLS
certificate verification and permits HTTP fallback. These switches affect only
the helper's source base-blob fetch and output push; they do not change
kubelet image pulls or Docker behavior. The lab examples set both to `true`
for its HTTP registry. Credential and custom-CA configuration are not
implemented yet.

Would a focused contribution around this portability adapter, its narrow
contract, and the registry-reference behavior be useful to the project? If so,
guidance on the preferred integration boundary and test/documentation shape
would help us prepare a small, reviewable follow-up. This draft makes no claim
about an upstream roadmap or a requested feature.
