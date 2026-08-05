# Rebrand Playbook — renaming `kldload` → `<NEWNAME>`

> **Status:** DRAFT / instructions for whoever (human or agent) executes the rename.
> **Status of the name itself:** NOT chosen. Fill the token map in §1 first, then
> the rest is mechanical-but-dangerous. This touches the installer, systemd units,
> paths, and the CA — a careless sweep **breaks the matrix and bricks installs**.
> Treat it like an installer change: branch, stage, gate every step with
> `smoke-build` + a full `smoke-test` lifecycle, and grep the built squashfs.

---

## 0. Principles

1. **Pick three tokens up front and lock them** (§1): the brand word, the CLI
   prefix, and the env-var namespace. Everything keys off these.
2. **Sed is not enough.** Most shipped tools are *extensionless*, the env
   namespace is *upcased by a bridge*, and files/units must be `git mv`d, not
   just edited. Use `git grep`/`git ls-files` over **all tracked files**, never
   an `*.sh` glob.
3. **Case matters.** At least five casings exist in-tree: `kldload`, `KLDLOAD`,
   `KLDload` (e.g. the `KLDload rpool` GPT partlabel + os-release), `Kldload`,
   `kld`. Sweep each deliberately; don't collapse them blindly.
4. **Don't rename what isn't ours.** Leave upstream namespaces alone —
   `org.zfsbootmenu:*` ZFS properties, upstream package names, the FreeBSD
   `kldload(8)` command if referenced in prose. Renaming those breaks boot.
5. **Gate on the real checks** (§5). The rename is "done" when the squashfs and a
   booted VM say so, not when `git grep` is empty.

---

## 1. Token map (fill this in, then everything below references it)

| Old | New | Notes |
|---|---|---|
| `kldload` (brand) | `<newname>` | os-release, docs, prose, domain |
| `KLDLOAD_` (env namespace) | `<NEW_>` | **see the bridge warning in §2** |
| `kld` / `kld-` (CLI + unit prefix) | `<pfx>` | `kldload-*` tools/units |
| short tools `kbe kst ksnap kpkg kclone kdf kdir …` | keep or re-prefix? | decide; these are the operator muscle-memory names |
| `debz-` (legacy Debian unit/answer prefix) | `<pfx>-`? | dangling second prefix; fold in or leave |
| `KLDload` (partlabel/os-release casing) | `<Newname>` | `storage-zfs.sh` GPT partlabel `KLDload rpool` |
| `kldload.com` / `kldload.ca` | `<newdomain>` | note the stale `.ca` in tracked os-release |
| CA `CN=kldload` / MOK subject | `CN=<newname>` | `kldload-ca`, install-target MOK subj |
| paths `/etc/kldload /var/log/kldload /usr/lib/kldload-installer /usr/local/share/kldload* /var/lib/kldload*` | `/etc/<pfx> …` | migration note in §4 |
| `/etc/kldload-build-id` | `/etc/<pfx>-build-id` | os-release should also carry the version |

**Discover the true surface before mapping:**
```bash
# counts per casing across ALL tracked files (not just *.sh)
for t in kldload KLDLOAD KLDload Kldload kld; do
  printf '%-8s %s\n' "$t" "$(git grep -l "$t" | wc -l)"
done
git grep -c -iE 'kldload' | awk -F: '{s+=$2} END{print "total kldload hits:", s}'
```

---

## 2. The three landmines (read before touching code)

- **The env-var bridge upcases keys.** The webui composes `role`, `nvidia`,
  `zfs_passphrase`, … in browser JS; `kldload-webui` (`_run_install`) upcases and
  prefixes them → `KLDLOAD_ROLE` etc.; the installer + firstboot consume
  `KLDLOAD_*`. **The JS keys, the bridge's prefix, and every `KLDLOAD_*`
  consumer must move in one commit** or install silently loses its config. Grep:
  `git grep -n 'KLDLOAD_' -- ':!docs'` and pair with the JS side in
  `usr/local/share/*/free/index.html`.
- **Files + units must be `git mv`d.** `kldload-*.service/.timer/.path`,
  `usr/lib/kldload-installer/`, the `kld*` tools, `.desktop` files (and their
  `StartupWMClass`/exec), the CA dir. After moving units, every `WantedBy`
  symlink, `After=`, and `ExecStart=` path must follow.
- **The CA CN + MOK subject are identity, not cosmetics.** Changing `CN=kldload`
  regenerates the trust root — fine on fresh installs, but any pre-existing
  install's trust store won't recognize the new CN. Since the product model is
  reinstall-to-upgrade, that's acceptable — but call it out in release notes.

---

## 3. Order of operations (on a branch)

1. `git switch -c chore/rebrand-<newname>`
2. **Env namespace first** (highest blast radius): JS keys → bridge → all
   `KLDLOAD_*` consumers, one commit. `smoke-build`, then a full
   `smoke-test fedora core` — config must survive the bridge.
3. **CLI tools + units**: `git mv` the `kld*`/`kldload-*` files, fix the
   symlink/`ExecStart`/`After` web, update the `profiles.sh` symlink-into-PATH
   loop and the `smoke-build` shebang inventory. Re-run gates.
4. **Paths**: `/etc/kldload` → `/etc/<pfx>` etc., in code and in every unit/hook
   that writes them. Watch `kldload-firstboot`, `profiles.sh`, `bootstrap.sh`.
5. **Branding**: os-release (ID/NAME/PRETTY_NAME/HOME_URL + add version), build-id,
   GPT partlabel, CA CN, webui titles, wallpaper/greeting strings.
6. **Docs**: README, `ci/README.md`, `docs/*`, `--help` banners, man pages.
7. **Build/release**: `deploy.sh`, `builder/build-iso.sh` (ISO name, os-release
   block), darksite scripts, `KLDLOAD_VERSION`/`ISO_NAME_OVERRIDE`.

Keep the **legacy `debz-`/`kldload-` names as compat symlinks** for one release
only if any external automation depends on them; otherwise drop them and note it.

---

## 4. Mechanical method

```bash
# case-sensitive passes, most-specific first, over ALL tracked files
git ls-files -z | xargs -0 sed -i \
  -e 's/KLDLOAD_/<NEW_>/g' \
  -e 's/kldload-installer/<pfx>-installer/g' \
  -e 's/KLDload/<Newname>/g' \
  -e 's/kldload/<newname>/g'
# then the CLI/short-tool renames explicitly (kbe→…, kst→…) if re-prefixing
# then: git mv every file whose NAME contains kldload/kld/debz
git ls-files | grep -iE 'kldload|/kld|/debz' | while read -r f; do
  git mv "$f" "$(echo "$f" | sed 's/kldload/<newname>/g; s|/kld|/<pfx>|; s/debz/<pfx>/')"
done
```
Do the file-content sweep and the file-*name* sweep in **separate commits** so a
bad rename is easy to bisect. After each: `shfmt -w -i 4`, `shellcheck -S error`,
`bash -n` over the shebang inventory.

---

## 5. Verification gates (the rename is not done until ALL pass)

1. `git grep -iE 'kldload|debz'` → only intentional/compat hits remain (and the
   FreeBSD-command references, if any).
2. All 228+ shell scripts: `bash -n`, `shellcheck -S error`, `shfmt` clean.
3. `./deploy.sh smoke-build` green (its shebang-wide gates now cover the renamed
   extensionless tools automatically).
4. **Full lifecycle**: `sudo ./deploy.sh smoke-test fedora core` — install →
   reboot → smoke-auto. The rename touches units/paths/installer = matrix change.
5. **Mount the built squashfs and grep for the old name** in the shipped rootfs
   (the b652 discipline) — os-release, units, tools, CA all show `<newname>`.
6. Boot it; confirm ZFS root imports, webui cert CN is `<newname>`, units green.

---

## 6. External cutover (coordinate as one flip, after code is merged)

- **GitHub**: rename org/repo (GitHub keeps redirects), update the SSH remote,
  branch protections, CI runner paths (`ci/README.md` references `fiend` paths).
- **Domain**: new domain; keep `kldload.*` redirecting for a while. Fix the stale
  `kldload.ca` in os-release either way.
- **R2 / releases**: bucket + the `*-latest.iso` download key the website resolves
  — **stale R2 = wrong download**. Re-upload under the new key, flip the website
  link in the same change.
- **Website repo**: pages + screenshots (anything showing the old name/branding).
- **Private ops notes**: internal runbooks and working notes reference `kldload`;
  update after the code cutover so the new name is used everywhere. The **commit identity**
  (`kldload <anthony@kldload.com>`) is a separate decision — tied to the person/
  email, not the product; change only if the email domain moves.

---

## 7. Rollback

It's a branch — `git switch main`. If merged and a brick is found post-cutover:
the versionlock/reinstall model means fixing forward + re-cutting the ISO is
faster than reverting a rename. Keep the pre-rename tag (`git tag pre-rebrand`).
