#!/usr/bin/env python3
"""kldload RAG Indexer — Walk the kldload corpus and populate ChromaDB.

Indexes:
  * /usr/local/bin/k* and /usr/local/bin/_k*   (kldload CLI scripts)
  * /usr/local/sbin/kldload-*                  (system tools)
  * /usr/local/share/kldload*/**.{md,txt,sh,html,yaml,toml,psd1}
  * /usr/local/share/doc/kldload*/**           (any docs ipt installs)
  * /etc/kldload/**.{toml,yaml,env,conf,md}
  * Any extra paths passed on the command line

For shell/python scripts, we extract:
  * the shebang + first comment block (usually the description / usage)
  * the rest of the file as a second chunk
This keeps the most useful semantic information up front.

Run as root (needed to read protected paths):
    sudo kldload-rag-index            # full re-index
    sudo kldload-rag-index --quiet    # silent (for cron/systemd)
    sudo kldload-rag-index --paths /custom/path1 /custom/path2

Re-runs are safe; we upsert by hashed file+chunk id so updated files
replace stale chunks.
"""

import argparse
import hashlib
import os
import sys
import time
from pathlib import Path

# Re-use the service's chromadb + ollama plumbing
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kldload_rag import (  # noqa: E402
    get_collection,
    ollama_embed,
    ollama_healthy,
    extract_text_from_html,
    chunk_text,
    CHUNK_SIZE,
    CHUNK_OVERLAP,
)

# ---------------------------------------------------------------------------
# Corpus definition
# ---------------------------------------------------------------------------

# Each entry: (root_path_glob, file_glob, description)
DEFAULT_CORPUS = [
    # kldload CLI tools (bash + python scripts)
    ("/usr/local/bin", "k*",          "kldload CLI tools"),
    ("/usr/local/bin", "_k*",         "kldload CLI helper scripts"),
    ("/usr/local/sbin", "kldload-*",  "kldload system tools"),

    # kldload docs/assets/examples
    ("/usr/local/share/kldload",  "**/*.md",   "kldload markdown docs"),
    ("/usr/local/share/kldload",  "**/*.txt",  "kldload text docs"),
    ("/usr/local/share/kldload",  "**/*.sh",   "kldload demo scripts"),
    ("/usr/local/share/kldload",  "**/*.html", "kldload html docs"),
    ("/usr/local/share/kldload",  "**/*.yaml", "kldload yaml examples"),
    ("/usr/local/share/kldload",  "**/*.yml",  "kldload yaml examples"),
    ("/usr/local/share/kldload",  "**/*.toml", "kldload toml examples"),

    ("/usr/local/share/kldload-examples", "**/*", "kldload example workloads"),
    ("/usr/local/share/kldload-ai",       "**/*.txt", "kldload AI prompts/system info"),

    # Distribution-level kldload docs
    ("/usr/local/share/doc",      "kldload*/**", "kldload distributed docs"),
    ("/usr/share/doc",            "kldload*/**", "kldload package docs"),

    # System config samples
    ("/etc/kldload", "**/*.toml", "kldload config samples (toml)"),
    ("/etc/kldload", "**/*.yaml", "kldload config samples (yaml)"),
    ("/etc/kldload", "**/*.env",  "kldload config samples (env)"),
    ("/etc/kldload", "**/*.conf", "kldload config samples (conf)"),
    ("/etc/kldload", "**/*.md",   "kldload config docs"),
]

# Don't index these (binary or noise)
SKIP_SUBSTRINGS = (
    ".pyc", "__pycache__", ".git/", ".bzr/",
    "/cache/", "/tmp/", "node_modules/",
)
# Max file size we will read (avoid embedding huge generated files)
MAX_FILE_BYTES = 256 * 1024  # 256 KB

# ---------------------------------------------------------------------------
# File reading + chunking
# ---------------------------------------------------------------------------

def should_skip(path):
    s = str(path)
    if any(skip in s for skip in SKIP_SUBSTRINGS):
        return True
    try:
        if path.stat().st_size > MAX_FILE_BYTES:
            return True
        if path.stat().st_size == 0:
            return True
    except OSError:
        return True
    return False


def read_script_header(path):
    """For shell/python scripts, return the leading comment block.

    Many kldload scripts put their usage / description in a leading
    comment block right after the shebang. Capturing this separately
    gives the embedder a focused chunk of intent before the implementation.
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = []
            saw_first_nonshebang = False
            for line in f:
                stripped = line.strip()
                # skip shebang
                if not saw_first_nonshebang and stripped.startswith("#!"):
                    saw_first_nonshebang = True
                    continue
                saw_first_nonshebang = True
                # collect contiguous comment block
                if stripped.startswith("#"):
                    lines.append(line.rstrip())
                elif stripped == "":
                    # blank line still allowed inside a comment block
                    if lines:
                        lines.append(line.rstrip())
                else:
                    break
            return "\n".join(lines).strip()
    except Exception:
        return ""


def read_file_text(path):
    """Read a file as text, returning the content (capped at MAX_FILE_BYTES)."""
    try:
        with open(path, "rb") as f:
            raw = f.read(MAX_FILE_BYTES)
        return raw.decode("utf-8", errors="replace")
    except Exception:
        return ""


def make_chunks_for_file(path):
    """Yield (chunk_text, metadata) tuples for a single file.

    Strategy by extension:
      * .html              -> extract sections via BeautifulSoup, chunk each
      * .sh/.py/scripts    -> header comment as chunk #0, full body as chunks
      * everything else    -> raw text, chunked
    """
    suffix = path.suffix.lower()
    base_meta = {
        "source": str(path),
        "filename": path.name,
    }

    # HTML: reuse the service's section extractor
    if suffix == ".html":
        try:
            content = read_file_text(path)
            sections = extract_text_from_html(content)
            for sec in sections:
                for piece in chunk_text(sec["text"]):
                    meta = dict(base_meta, heading=sec.get("heading", ""),
                                title=sec.get("title", ""))
                    yield piece, meta
        except Exception as e:
            print(f"  SKIP html: {path}: {e}", file=sys.stderr)
        return

    # Scripts (shell, python, ps1) and anything kldload-named without
    # an extension. Header-first strategy.
    is_script = (
        suffix in {".sh", ".py", ".ps1", ".bash"} or
        suffix == "" or
        path.name.startswith(("k", "_k", "bob", "kldload-"))
    )
    if is_script:
        header = read_script_header(path)
        if header:
            # Header is its own first chunk (often <CHUNK_SIZE so 1 chunk).
            for piece in chunk_text(header):
                yield piece, dict(base_meta, kind="script-header")
        body = read_file_text(path)
        if body:
            for piece in chunk_text(body):
                yield piece, dict(base_meta, kind="script-body")
        return

    # Fallback: plain text
    body = read_file_text(path)
    if body:
        for piece in chunk_text(body):
            yield piece, dict(base_meta, kind="text")

# ---------------------------------------------------------------------------
# Walking + indexing
# ---------------------------------------------------------------------------

def iter_corpus_files(corpus):
    """Walk DEFAULT_CORPUS entries and yield Path objects."""
    seen = set()
    for root, pattern, _desc in corpus:
        root_path = Path(root)
        if not root_path.exists():
            continue
        try:
            for p in root_path.glob(pattern):
                # if pattern was a recursive glob we still want files only
                if p.is_dir():
                    continue
                if should_skip(p):
                    continue
                resolved = p.resolve()
                if resolved in seen:
                    continue
                seen.add(resolved)
                yield p
        except OSError as e:
            print(f"  SKIP root: {root}: {e}", file=sys.stderr)


def index_paths(extra_paths=None, quiet=False):
    """Walk the configured corpus, embed every chunk, upsert into ChromaDB.

    Returns dict with totals.
    """
    if not ollama_healthy():
        print("ERROR: Ollama isn't reachable. Start ollama.service and retry.",
              file=sys.stderr)
        return {"status": "error", "reason": "ollama-unreachable"}

    collection = get_collection()
    started_at = collection.count()
    log = (lambda *a, **k: None) if quiet else print

    file_count = 0
    chunk_count = 0
    errors = 0
    t0 = time.time()

    corpus = list(DEFAULT_CORPUS)
    if extra_paths:
        for p in extra_paths:
            corpus.append((p, "**/*", f"user extra path: {p}"))

    for path in iter_corpus_files(corpus):
        try:
            chunks = list(make_chunks_for_file(path))
            if not chunks:
                continue
            texts = [c[0] for c in chunks]
            metas = [c[1] for c in chunks]
            ids = [
                hashlib.sha256(f"{path}:{i}".encode()).hexdigest()[:16]
                for i in range(len(chunks))
            ]
            embeddings = ollama_embed(texts)
            collection.upsert(
                ids=ids,
                embeddings=embeddings,
                documents=texts,
                metadatas=metas,
            )
            chunk_count += len(chunks)
            file_count += 1
            log(f"  indexed: {path} ({len(chunks)} chunks)")
        except Exception as e:
            errors += 1
            print(f"  ERROR: {path}: {e}", file=sys.stderr)

    elapsed = time.time() - t0
    ended_at = collection.count()
    summary = {
        "status": "ok",
        "files": file_count,
        "chunks_added_or_updated": chunk_count,
        "chunks_in_store_before": started_at,
        "chunks_in_store_after": ended_at,
        "errors": errors,
        "seconds": round(elapsed, 2),
    }
    if not quiet:
        print()
        for k, v in summary.items():
            print(f"  {k}: {v}")
    return summary


def main():
    p = argparse.ArgumentParser(description="Index the kldload corpus into the RAG vector store.")
    p.add_argument("--quiet", "-q", action="store_true",
                   help="Silent except for errors (use from cron/systemd).")
    p.add_argument("--paths", nargs="*", default=[],
                   help="Extra paths to walk recursively in addition to the default corpus.")
    args = p.parse_args()
    result = index_paths(extra_paths=args.paths, quiet=args.quiet)
    sys.exit(0 if result.get("status") == "ok" else 1)


if __name__ == "__main__":
    main()
