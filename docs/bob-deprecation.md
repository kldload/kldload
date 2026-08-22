# Bob is deprecated — Open WebUI replaces him

**Status: DEPRECATED, not yet removed.** Decided 2026-08-13. Nothing is
broken today; this records the decision so the next person does not
extend Bob by accident.

## What changed

Open WebUI now ships as the AI interface (`kldload-ai-webui`, reachable
from the desktop tile at `http://ollama:8080/`). It covers, better, the
half of Bob most people used:

| Bob | Open WebUI |
|---|---|
| chat UI | yes |
| `bob-voice` | voice/video call, local Whisper + TTS |
| `bob-model`, `bob-models` | model picker, pull/switch in the UI |
| `kldload-rag*` + chromadb | built-in RAG, 9 vector DBs, `#` collections |
| vision | yes |

## What Open WebUI does NOT replace

The half that acts on the machine — `bob-bash`, `bob-do`, `bob-desktop`,
`bob-sys`. Open WebUI runs in a container: its Tools execute inside that
container, so with `--network host` they can reach a service on
localhost but cannot exec on the host, open a terminal in your session,
or touch the desktop. Replacing those needs a host-side bridge, which is
a smaller Bob by another name.

The operator's call (2026-08-13) is that an assistant which KNOWS
kldload, ZFS, WireGuard and the utils is the goal — not one that acts on
the box. That is RAG over the shipped docs, which Open WebUI already
does.

## Intended end state

**There is no end state with a Bob in it. Decided 2026-08-21.**

The plan below was built and then backed out (revert of 5590c4f5,
8c879da6, edbbcab5 — `kldload-corpus`, `kldload-bob-setup`, the persona
file and the toolbar tile):

> "Bob" becomes a knowledge collection plus a named model inside Open
> WebUI: index `kldload-docs.txt` and `kldload-manual.txt`, embed with
> `nomic-embed-text` from the darksite, and add a model entry named Bob
> whose system prompt points at that collection.

It worked, and it was still the wrong shape. Open WebUI already ships a
chat UI, a model picker and its own retrieval; wrapping a second
assistant identity around them meant another setup step, another thing
to grey out until a model exists, another surface to keep working across
upgrades — for no capability the operator did not already have by
opening Open WebUI and asking. The knowledge-attach step also needed a
274 MB embedder pulled before it did anything at all.

So: **Open WebUI is the AI feature.** Ship it, point the tile at it, and
stop building assistants on top of it. Anything that reads "make Bob
do X" is out of scope by decision, not by oversight.

## What removal involves — 75 references, 7 files

Not a delete. The files come out easily; the wiring does not:

    profiles.sh          18   installer
    tests/smoke-server.sh 14   asserts the RAG stack exists
    builder/build-iso.sh  13
    kldload-autodeploy    12
    tests/smoke-build.sh  12
    kldload-firstboot      5
    kldload-console        1

A staged removal of the FILES (11 `bob-*` binaries, `bob-ui`, `/etc/bob`,
the four `kldload-rag*` units and `/usr/local/lib/kldload-rag`) is on the
`chore/remove-bob` branch. It is deliberately unmerged: the reference
cleanup touches the install path, and doing it in a hurry is how a
subtle installer bug gets blamed on something else weeks later.

## Keep, do not delete

- **`bobctl`** — toggles the model in/out of VRAM so games get the card.
  A real feature independent of Bob, referenced from four places. Worth
  renaming, not removing.
- **`bob-chat.desktop`** — this IS the Ollama tile now (`Name=Ollama`,
  `Icon=ollama`). The dock pins in `50-kldload-installed-favorites`
  reference it BY FILENAME, so renaming the file drops it from the dash.
- **`bob-gaming.desktop`** — the VRAM toggle tile, execs `bobctl`.
- **`/usr/local/share/kldload-ai/*.txt`** — the corpus Bob-as-RAG needs.

## On the website

29 files, 149 occurrences — but a blind replace is wrong. Some are not
the assistant: `Bob's key` is the Alice-and-Bob cryptography convention
and `/home/bob` is an example path. Only AI-assistant mentions should
change.

## Also worth fixing while in here

~~`kldload-autodeploy` pulls `qwen3:14b` (~9 GB) unconditionally and never
checks what is already on disk, while the darksite ships `llama3.2:3b`.~~
**Fixed.** autodeploy now takes any model already present (pulled or in the
darksite) over its own VRAM-tier choice, and as of 2026-08-15 the darksite
bakes `llama3.2:3b` deliberately — small enough to run on CPU, which the
14b could not, so the offline assistant now works on every machine rather
than only on ones with ≥8 GB of VRAM.

One trap that came with it: the darksite now holds exactly two manifests,
one chat and one embedding model. Both of autodeploy's discovery paths had
to learn to skip `nomic-embed-text`, or an air-gapped box could configure
the assistant with an embedding model that cannot answer a prompt.
