# `docker rollback` — why the obvious implementation does not work

**Status: NOT IMPLEMENTED.** This records a dead end so the next attempt does
not spend a night rediscovering it. Investigated 2026-08-18 on fiend.

## The idea

`apt rollback` works because `kldload-pkg-wrapper` is symlinked over `apt`,
`dnf` and `pacman`: it snapshots the root before any transaction that changes
the system, and `apt rollback` returns to that snapshot. Docker is the obvious
next candidate. `docker rm -f`, `docker rmi` and `docker system prune` are
irreversible, are typed from muscle memory, and every image layer and volume on
a kldload host already lives on ZFS.

So: wrap `docker`, snapshot `rpool/var/lib/docker` recursively before a
destructive verb, and add `docker rollback`.

## Why it fails

**`zfs rollback` cannot restore a dataset that was destroyed.** It reverts the
*contents* of a dataset that still exists. Docker's ZFS graph driver does not
empty a layer — it destroys the dataset, recursively, which takes that
dataset's snapshots with it.

Measured, in order:

1. `docker pull postgres:16-alpine` — datasets under the docker root went from
   1 to 12. One per layer, as expected.
2. Wrapper snapshots `rpool/var/lib/docker@docker-pre-<stamp>` with `-r`, so
   all 12 datasets get a snapshot.
3. `docker rm -f magictrick2` — the container's layer dataset **and its
   snapshot** are both gone afterwards.
4. `docker rollback` restores the container metadata (that lives on the root
   dataset, which still exists) but not the layer.
5. `docker start` then fails with
   `error creating zfs mount: … no such file or directory`, because the layer
   the container needs no longer exists in any form.

There is a second trap that makes this look like it works. A snapshot taken
*directly* on a single layer dataset — not recursively from the parent — can
block docker's destroy, and **docker swallows the failure**: `docker rm -f`
prints the container name and exits 0 while the dataset survives. So a hand-run
experiment appears to prove the approach, and the wrapper's recursive snapshots
then behave differently.

## What would actually be needed

Any working version has to prevent the destroy or copy the data out before it,
not undo it afterwards:

- **`zfs hold` on each layer snapshot.** The destroy then fails loudly instead
  of succeeding, which is honest but turns `docker rm` into an error the
  operator has to clear by hand — and docker may leave its own metadata
  inconsistent when its destroy fails.
- **`zfs send` the tree to a holding dataset** before the destructive verb.
  Correct and complete, but it is a full copy: seconds-to-minutes and real
  space on every `docker rm`, for a command people run constantly.
- **Clone the layers aside**, then destroy. Cheap in space, but the clones pin
  the origin snapshots and the bookkeeping to promote them back is substantial.

None of these is a wrapper-sized change, which is why this is a design note and
not a tool.

## What still holds

The parts of the pitch that survive this, and are separately verified:

- Every image layer *is* a ZFS dataset — one `docker pull` created eleven.
- Volumes live on ZFS too, under the same root, and survive `docker rm -f`
  (docker does not remove anonymous volumes without `-v`).
- A snapshot taken deliberately, before deliberate work, restores exactly what
  it captured. What does not work is *automatically* undoing docker's own
  destroys.
