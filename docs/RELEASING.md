# Releasing kldload

Maintainer notes. Nothing here is needed to *use* kldload — see
[INSTALL.md](INSTALL.md) for that.

## Publishing to R2

R2 is the public source of truth for downloads — a stale bucket means the
website advertises one release and hands the visitor another. After tagging:

```bash
export R2_ACCOUNT_ID=... R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=...
tools/r2-publish.sh --prune live-build/output/kldload-<version>-x86_64.iso
```

It verifies the ISO against its `.sha256` sidecar before uploading, publishes
under both the versioned key and `kldload-free-latest.iso` (server-side copy,
so the image is sent once), then re-reads the published objects over HTTPS and
asserts size and checksum. `--prune` clears older releases out of the bucket
afterwards; `--prune-dry-run` shows what it would remove first. Requires
`rclone`.

## What "released" means

A release is not done until every one of these names the same build:

1. A **tag** at the exact commit the ISO was built from — `git show v1.4.0`
   must be the tree that produced it.
2. A **changelog** entry in operator terms.
3. **Website** pages and screenshots updated for any flow that changed,
   including the advertised download size.
4. **Man pages** lint-clean for any tool whose interface moved.
5. **R2** carrying the ISO and its `.sha256`, under the key the website's
   download button resolves to.
6. A **smoke check** that the changelog version, the ISO filename, the
   download button and the R2 key all agree.

Step 6 exists because the others can each be individually correct and still
disagree with one another, and the failure is invisible from any single one of
them: the site says 1.4.2, the bucket serves 1.4.1, and nothing in either
place is wrong on its own terms.
