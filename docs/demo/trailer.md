# The trailer -- sixty seconds before the machine gets switched on

The screencast opens on a bare machine and a claim. This is the sixty seconds
that make the claim, so that the twenty-eight minutes after it are spent
checking rather than waiting to be told what is being watched -- the argument
`narration.md` already makes about the cold open, moved into a title sequence.

It is a rendered piece, not footage: nothing in it is a screen recording and it
claims nothing the rest of this directory does not prove.

---

## Where it is

It is built in the operator's demoscene workspace, not in this repo:

```
~/demoscene/productions/kldload-trailer/
    NOTES.md       the intent, the six scenes, and the source of every line of type
    score.js       the timeline: scenes, type, labels, cuts, stills
    shaders/       bare.glsl, assemble.glsl, stack.glsl, clone.glsl
    index.html     the page; the engine is the kit at ~/demoscene/kit/
    renders/       stills and video (not committed)
```

Two cuts come out of one score: **0:60**, which is the one that opens the
screencast, and **0:30** (`?cut=30`) for a social post. Render either with the
workspace's own tooling, which its `README.md` documents. The short version:

```
cd ~/demoscene
python3 tools/render_stills.py productions/kldload-trailer/index.html \
    --out productions/kldload-trailer/renders/stills --width 1920 --height 1080
python3 tools/render_video.py  productions/kldload-trailer/index.html \
    --out kldload-trailer.mp4 --width 1920 --height 1080 --fps 60 --aa 2
```

## The six scenes, against the five beats

| Trailer scene | 0:60 | What it asserts | Which beat of the screencast proves it |
|---|---|---|---|
| a machine with nothing on it | 0-10 | there is nothing on the disk and no media in it | beat 1: fiend reboots into the netboot menu |
| assembled from the vendor's own packages | 10-22 | offline, from one staged image, nothing forked | beat 2: the installer runs itself |
| boot environments | 22-34 | ZFS on root, a snapshot before every transaction | the proof-it ending |
| apt rollback | 34-44 | recovery is a clone of the snapshot and a reboot | the proof-it ending |
| six nodes, one image | 44-52 | 2.32 GB golden, every clone 0 B | beat 4, and `zfs list -r rpool/vms` at the end |
| kldload | 52-60 | the name, the licence, the two substrates | -- |

Nothing in the trailer is a number the screencast does not go on to show on
screen. **Two true numbers are deliberately left out of it**: the fifteen
minutes power-on-to-cluster, and the 13.91 GB image. Both are measured, and
both belong to the run itself -- stating them over a title sequence invites the
viewer to check them against footage that has not started yet.

## How it cuts in

The trailer is beat 0. It ends on black with the mark, and the first frame of
the screencast proper is the bare machine on the bench -- the same subject the
trailer opened on, which is why the trailer's last scene is its first scene
lit rather than a card.

If the 0:30 cut is used instead, drop the `boot environments` and `apt
rollback` scenes' whispers rather than the scenes: the break and the recovery
are the two seconds of the piece that people remember.

## What it is not

- Not a screen recording, and not a reconstruction of one. Where the screencast
  shows a terminal, the trailer shows a structure.
- Not an ad for anything that is not in this tree. Every line of type on screen
  is sourced in the production's `NOTES.md`, with the file it came from and the
  date it was read.
- Not signed by anybody but North Star, and it carries no branding taken from
  the website.
