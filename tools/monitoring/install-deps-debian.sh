#!/usr/bin/env bash
set -euo pipefail

if ! command -v apt-get >/dev/null; then
  echo "This installer is for Debian/Ubuntu." >&2
  exit 1
fi

sudo apt-get update
sudo apt-get install -y \
  bpfcc-tools libbpfcc-dev python3-bpfcc \
  linux-headers-$(uname -r) \
  clang llvm make gcc build-essential \
  python3 python3-venv python3-pip

echo "System deps installed."
