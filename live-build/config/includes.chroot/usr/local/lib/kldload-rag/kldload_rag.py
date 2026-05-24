#!/usr/bin/env python3
"""kldload RAG Service — Retrieval-Augmented Generation for infrastructure AI."""

import json
import os
import sys
import hashlib
import urllib.request
import urllib.error
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

import chromadb
from bs4 import BeautifulSoup

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8400
CHROMADB_PATH = os.environ.get("CHROMADB_PATH", "/var/lib/kldload-rag/chromadb")
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
# Model names can be overridden via env. kldload-firstboot writes
# /etc/kldload/bob-model.env after it picks a chat model based on
# detected VRAM (qwen2.5:14b on 10GB+, llama3.1:8b on 6-10GB,
# llama3.2:3b on CPU-only). kldload-rag.service sources that file via
# EnvironmentFile=, so this picks up the right model automatically.
# Without the env override, RAG bridges fall back to llama3.1:8b and
# 404 silently on installs where firstboot chose a different model.
EMBED_MODEL    = os.environ.get("BOB_EMBED_MODEL",    "nomic-embed-text")
GENERATE_MODEL = os.environ.get("BOB_GENERATE_MODEL", "llama3.1:8b")
CHUNK_SIZE = 2000  # ~500 tokens
CHUNK_OVERLAP = 200
TOP_K = 5

SYSTEM_PROMPT = """You are a Linux infrastructure expert specializing in OpenZFS, WireGuard, eBPF, Kubernetes, Cilium, and the open source infrastructure stack. Give exact commands, not abstract advice. Always recommend a ZFS snapshot before making changes. If diagnosing a problem, ask for kst output first."""

# ---------------------------------------------------------------------------
# ChromaDB setup
# ---------------------------------------------------------------------------

def get_collection():
    """Return the ChromaDB collection, creating it if needed."""
    os.makedirs(CHROMADB_PATH, exist_ok=True)
    client = chromadb.PersistentClient(path=CHROMADB_PATH)
    return client.get_or_create_collection(
        name="kldload_docs",
        metadata={"hnsw:space": "cosine"},
    )

# ---------------------------------------------------------------------------
# Ollama helpers
# ---------------------------------------------------------------------------

def ollama_embed(texts):
    """Get embeddings from Ollama nomic-embed-text. Returns list of vectors."""
    embeddings = []
    for text in texts:
        payload = json.dumps({"model": EMBED_MODEL, "prompt": text}).encode()
        req = urllib.request.Request(
            f"{OLLAMA_HOST}/api/embeddings",
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode())
        embeddings.append(data["embedding"])
    return embeddings


def ollama_generate_stream(prompt):
    """Stream tokens from Ollama /api/generate. Yields text chunks."""
    payload = json.dumps({
        "model": GENERATE_MODEL,
        "prompt": prompt,
        "stream": True,
    }).encode()
    req = urllib.request.Request(
        f"{OLLAMA_HOST}/api/generate",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        for line in resp:
            line = line.decode().strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if "response" in obj:
                    yield obj["response"]
            except json.JSONDecodeError:
                continue


def ollama_healthy():
    """Check if Ollama is reachable."""
    try:
        req = urllib.request.Request(f"{OLLAMA_HOST}/api/tags")
        with urllib.request.urlopen(req, timeout=5):
            return True
    except Exception:
        return False

# ---------------------------------------------------------------------------
# Text extraction and chunking
# ---------------------------------------------------------------------------

def extract_text_from_html(html_content):
    """Extract text from HTML, stripping nav/sidebar/footer/scripts."""
    soup = BeautifulSoup(html_content, "html.parser")

    # Remove unwanted elements
    for tag in soup.find_all(["nav", "script", "style", "footer"]):
        tag.decompose()
    for el in soup.find_all(class_=lambda c: c and any(
        w in (c if isinstance(c, str) else " ".join(c))
        for w in ["sidebar", "nav", "footer", "menu"]
    )):
        el.decompose()

    # Extract page title
    title_tag = soup.find("title")
    page_title = title_tag.get_text(strip=True) if title_tag else ""

    # Extract sections or fall back to main
    sections = soup.find_all("section")
    if not sections:
        main = soup.find("main")
        if main:
            sections = [main]
        else:
            sections = [soup.body] if soup.body else [soup]

    results = []
    for section in sections:
        heading = section.find(["h1", "h2", "h3", "h4"])
        heading_text = heading.get_text(strip=True) if heading else ""
        text = section.get_text(separator="\n", strip=True)
        if text.strip():
            results.append({
                "text": text,
                "heading": heading_text,
                "title": page_title,
            })
    return results


def chunk_text(text, chunk_size=CHUNK_SIZE, overlap=CHUNK_OVERLAP):
    """Split text into overlapping chunks."""
    chunks = []
    start = 0
    while start < len(text):
        end = start + chunk_size
        chunks.append(text[start:end])
        start = end - overlap
        if start >= len(text):
            break
    return chunks

# ---------------------------------------------------------------------------
# Indexing
# ---------------------------------------------------------------------------

def index_html_content(html_content, source_path, collection):
    """Parse HTML, chunk, embed, and upsert into ChromaDB. Returns chunk count."""
    sections = extract_text_from_html(html_content)
    total_chunks = 0

    for sec in sections:
        chunks = chunk_text(sec["text"])
        if not chunks:
            continue

        embeddings = ollama_embed(chunks)

        ids = []
        metadatas = []
        for i, chunk in enumerate(chunks):
            chunk_id = hashlib.sha256(
                f"{source_path}:{sec['heading']}:{i}".encode()
            ).hexdigest()[:16]
            ids.append(chunk_id)
            metadatas.append({
                "source": str(source_path),
                "heading": sec["heading"],
                "title": sec["title"],
            })

        collection.upsert(
            ids=ids,
            embeddings=embeddings,
            documents=chunks,
            metadatas=metadatas,
        )
        total_chunks += len(chunks)

    return total_chunks


def index_directory(source_dir):
    """Walk a directory for .html files, index them all."""
    collection = get_collection()
    total_chunks = 0
    total_pages = 0
    source_path = Path(source_dir)

    for html_file in sorted(source_path.rglob("*.html")):
        try:
            content = html_file.read_text(encoding="utf-8", errors="replace")
            n = index_html_content(content, str(html_file), collection)
            total_chunks += n
            total_pages += 1
            print(f"  indexed: {html_file} ({n} chunks)")
        except Exception as e:
            print(f"  SKIP: {html_file}: {e}", file=sys.stderr)

    return {"status": "ok", "chunks": total_chunks, "pages": total_pages}


def index_urls(urls):
    """Fetch URLs and index their HTML content."""
    collection = get_collection()
    total_chunks = 0
    total_pages = 0

    for url in urls:
        try:
            req = urllib.request.Request(
                url,
                headers={"User-Agent": "kldload-rag/1.0"},
            )
            with urllib.request.urlopen(req, timeout=30) as resp:
                content = resp.read().decode("utf-8", errors="replace")
            n = index_html_content(content, url, collection)
            total_chunks += n
            total_pages += 1
            print(f"  indexed: {url} ({n} chunks)")
        except Exception as e:
            print(f"  SKIP: {url}: {e}", file=sys.stderr)

    return {"status": "ok", "chunks": total_chunks, "pages": total_pages}

# ---------------------------------------------------------------------------
# Query
# ---------------------------------------------------------------------------

def build_prompt(question, system_context, chunks):
    """Build the full prompt with retrieved context."""
    doc_sections = "\n---\n".join(chunks) if chunks else "(no documentation indexed)"

    return f"""{SYSTEM_PROMPT}

Relevant documentation:
---
{doc_sections}
---

Current system state:
{system_context}

Question: {question}"""

# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class RAGHandler(BaseHTTPRequestHandler):
    """HTTP request handler for the RAG service."""

    def log_message(self, format, *args):
        """Log to stdout."""
        print(f"[{self.log_date_time_string()}] {format % args}")

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        return json.loads(self.rfile.read(length).decode())

    def _send_json(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, status, message):
        self._send_json({"error": message}, status)

    def do_GET(self):
        if self.path == "/health":
            self.handle_health()
        else:
            self._send_error(404, "not found")

    def do_POST(self):
        if self.path == "/query":
            self.handle_query()
        elif self.path == "/index":
            self.handle_index()
        elif self.path == "/index-url":
            self.handle_index_url()
        else:
            self._send_error(404, "not found")

    def handle_health(self):
        try:
            collection = get_collection()
            count = collection.count()
        except Exception:
            count = 0
        self._send_json({
            "status": "ok",
            "chunks": count,
            "ollama": ollama_healthy(),
        })

    def handle_query(self):
        try:
            body = self._read_body()
        except Exception as e:
            self._send_error(400, f"bad request: {e}")
            return

        question = body.get("question", "").strip()
        system_context = body.get("system_context", "")

        if not question:
            self._send_error(400, "missing 'question'")
            return

        # Retrieve relevant chunks
        chunks = []
        try:
            collection = get_collection()
            if collection.count() > 0:
                query_embedding = ollama_embed([question])[0]
                results = collection.query(
                    query_embeddings=[query_embedding],
                    n_results=min(TOP_K, collection.count()),
                )
                if results and results.get("documents"):
                    chunks = results["documents"][0]
        except Exception as e:
            print(f"Warning: retrieval failed: {e}", file=sys.stderr)

        prompt = build_prompt(question, system_context, chunks)

        # Stream response
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        try:
            for token in ollama_generate_stream(prompt):
                chunk_data = f"{len(token.encode()):x}\r\n{token}\r\n"
                self.wfile.write(chunk_data.encode())
                self.wfile.flush()
            # Send terminating chunk
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except Exception as e:
            print(f"Stream error: {e}", file=sys.stderr)

    def handle_index(self):
        try:
            body = self._read_body()
        except Exception as e:
            self._send_error(400, f"bad request: {e}")
            return

        source_dir = body.get("source_dir", "")
        if not source_dir or not os.path.isdir(source_dir):
            self._send_error(400, f"invalid source_dir: {source_dir}")
            return

        print(f"Indexing directory: {source_dir}")
        result = index_directory(source_dir)
        self._send_json(result)

    def handle_index_url(self):
        try:
            body = self._read_body()
        except Exception as e:
            self._send_error(400, f"bad request: {e}")
            return

        urls = body.get("urls", [])
        if not urls:
            self._send_error(400, "missing 'urls'")
            return

        print(f"Indexing {len(urls)} URLs")
        result = index_urls(urls)
        self._send_json(result)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    os.makedirs(CHROMADB_PATH, exist_ok=True)
    server = HTTPServer((LISTEN_HOST, LISTEN_PORT), RAGHandler)
    print(f"kldload RAG service listening on {LISTEN_HOST}:{LISTEN_PORT}")
    print(f"ChromaDB path: {CHROMADB_PATH}")
    print(f"Ollama host: {OLLAMA_HOST}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()


if __name__ == "__main__":
    main()
