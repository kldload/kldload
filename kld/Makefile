# kld — build entry point. One static binary (no cgo, no GUI): the hub runs
# where there is a terminal and nothing else, which is the point of it.
#
#   make            build
#   make install    into $(PREFIX)/bin
#
# .buildnum is a local, gitignored counter bumped once per make run and
# stamped in via -X main.buildNum, the same mechanism wgx and zxplore use.
PREFIX  ?= /usr/local
DESTDIR ?=
BINDIR   = $(DESTDIR)$(PREFIX)/bin
GO      ?= go
GOFLAGS ?= -trimpath

BUILDNUM_FILE = .buildnum
STAMP = -ldflags "-X main.buildNum=$$(cat $(BUILDNUM_FILE) 2>/dev/null || echo 0)"

.DEFAULT_GOAL := build

bump:
	@n=$$(cat $(BUILDNUM_FILE) 2>/dev/null || echo 0); echo $$((n + 1)) > $(BUILDNUM_FILE)

build: bump
	CGO_ENABLED=0 $(GO) build $(GOFLAGS) $(STAMP) -o kld .

check:
	$(GO) vet ./... && test -z "$$(gofmt -l .)" && $(GO) test ./...

install: build
	install -Dm0755 kld $(BINDIR)/kld

clean:
	rm -f kld

.PHONY: bump build check install clean
