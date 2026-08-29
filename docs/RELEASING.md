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

## Cloudflare: two different tokens

The R2 upload and the website deploy need **different token objects**, and they
are not interchangeable.

- **R2** — minted from the R2 page, which returns an *Access Key ID* and a
  *Secret Access Key*. This is what `r2-publish.sh` consumes. Minting a new one
  **revokes the previous secret**: every R2 token on this account shares one
  Access Key ID, only the secret changes, so an older secret starts failing with
  `SignatureDoesNotMatch` the moment a replacement is created.
- **Pages** — minted from My Profile → API Tokens (or Account API Tokens) with
  permission **Account → Cloudflare Pages → Edit**. It is a bearer token with no
  S3 credentials attached.

An R2 token cannot deploy the site. It verifies as `status: active` and then
returns `Authentication error` on every `/pages/…` call, including a plain list,
which reads like a broken token rather than a wrong one. Three were minted
chasing that during the 1.4.2 release before the distinction was spotted.

In practice the Pages token is optional: `kldload-web` is git-connected with
production branch `main`, so pushing deploys it. The token only exists to force
a deployment when auto-deploy lags.

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
