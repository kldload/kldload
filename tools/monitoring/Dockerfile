FROM debian:13-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_BREAK_SYSTEM_PACKAGES=1

RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt/lists \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      bpfcc-tools libbpfcc-dev python3-bpfcc \
      python3 python3-pip \
      clang llvm make gcc ca-certificates && \
    # remove Debian's kernel headers to avoid conflicts with host headers
    rm -f /usr/include/linux/bpf.h /usr/include/linux/bpf_common.h /usr/include/linux/filter.h || true && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt /app/

RUN python3 -m pip install -r requirements.txt

COPY . /app/

CMD ["python3", "/app/socket_snoop.py"]

