# buildmon — two binaries from one tree, mirroring wg/ and zxplore:
#   kldload-buildmon      GUI + everything (cgo, Fyne)
#   kldload-buildmon-tui  static, terminal only, no GL/X11/wayland needed
#
#   make            build both
#   make test       vet + test under BOTH build tags
#   make install    into $(PREFIX)/bin
PREFIX  ?= /usr/local
DESTDIR ?=
BINDIR   = $(DESTDIR)$(PREFIX)/bin
GO      ?= go
GOFLAGS ?= -trimpath
BUILDNUM ?= 0
STAMP    = -ldflags "-X main.buildNum=$(BUILDNUM)"

.DEFAULT_GOAL := build

build: kldload-buildmon kldload-buildmon-tui

kldload-buildmon: $(wildcard *.go) go.mod go.sum
	CGO_ENABLED=1 $(GO) build $(GOFLAGS) $(STAMP) -tags gui -o $@ .

kldload-buildmon-tui: $(wildcard *.go) go.mod go.sum
	CGO_ENABLED=0 $(GO) build $(GOFLAGS) $(STAMP) -o $@ .

# WHY the local TMPDIR: `go test` execs the compiled test binary out of
# TMPDIR, and hardened hosts mount /tmp noexec — which fails as an opaque
# "fork/exec ...: permission denied" that looks like a broken suite.
TESTTMP = $(CURDIR)/.testtmp
test:
	@mkdir -p $(TESTTMP)
	$(GO) vet ./...
	$(GO) vet -tags gui ./...
	TMPDIR=$(TESTTMP) $(GO) test -count=1 ./...
	TMPDIR=$(TESTTMP) $(GO) test -count=1 -tags gui ./...

install: build
	install -d $(BINDIR)
	install -m 0755 kldload-buildmon     $(BINDIR)/kldload-buildmon
	install -m 0755 kldload-buildmon-tui $(BINDIR)/kldload-buildmon-tui

clean:
	rm -f kldload-buildmon kldload-buildmon-tui
	rm -rf $(TESTTMP)

.PHONY: build test install clean
