# Contributing

This is an experimental Linux/amd64 rootfs portability project. Keep changes
within the documented scope in the README and architecture notes.

Before opening a change, run the focused checks that apply and report their
actual results:

```text
go test ./...
go vet ./...
```

The kind, Docker, and registry lab mutates shared resources. One coordinator
must own those mutations; contributors should not run competing lab jobs
against the same clusters, registry, or source Pod. Run the full lab in the
documented order and clean it up when finished.

Use the fixture images and test data for local checks. Do not put real
credentials, private registry data, or secrets in fixtures, artifacts, or
commits. The fixture may contain deliberate canaries for tests, but those are
not production secrets.

Generated tool caches, upstream checkouts, kubeconfigs, images, and lab
artifacts are local state and must remain uncommitted.
