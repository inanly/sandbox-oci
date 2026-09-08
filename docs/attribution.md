# Helper image attribution

The current release candidate distributes source; helper images have only been
built in the local lab. When a helper image is built, the image
contains an attribution bundle at `/usr/share/licenses/sandbox-oci`.

The bundle includes:

- this repository's `LICENSE`, `NOTICE`, and `versions.json`;
- the pinned OpenSandbox `LICENSE`;
- license, notice, copyright, patent, and author files found while walking the
  Go modules reported by `go list -deps` for the helper build;
- the Go distribution `LICENSE` and `PATENTS` files;
- license and notice-like files from the Go toolchain source tree;
- Debian CA-certificate copyright and common-license text; and
- `build-info.txt`, produced by `go version -m` for the helper binary.

The module inventory is recorded in
`/usr/share/licenses/sandbox-oci/manifest.json`. It includes module paths,
versions, sums, resolved source directories, replacements, and copied file
paths. The collector is automated and conservative: it may retain notices
that are not individually applicable to every dependency or binary. The bundle
does not constitute a complete legal determination or an SBOM; downstream
distributors remain responsible for reviewing applicable terms and notices.

To inspect a built helper image without running it, use a unique temporary
container name and the image digest:

```text
docker create --name <unique-container-name> <helper-image@sha256:digest>
docker cp <unique-container-name>:/usr/share/licenses/sandbox-oci ./sandbox-oci-attribution
docker rm <unique-container-name>
```

Remove the exact container created for inspection after copying the bundle.
The image is built from the pinned source checkout and repository inputs; this
document does not claim that any particular image has been published or that
the attribution bundle has been independently audited.

On 2026-09-08 at 12:32 UTC, `scripts/test-attribution.ps1` extracted both normal
and fault-test images and verified project files, required bundle files, and
every listed module attribution file. Each image contained 43 dependency modules;
every dependency in the binary build information appeared in the inventory.
Evidence is in the ignored `artifacts/attribution-result.json`. The normal helper
also passed the registry/snapshot/Docker-restore regression after this change.
