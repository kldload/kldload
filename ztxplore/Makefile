# ztxplore — build entry point. Two binaries from one tree, mirroring the
# rest of the console family: `ztx` (GUI+TUI, cgo) and `ztx-tui` (static,
# terminal only, for the headless hypervisors the lab actually runs on).
#
#   make            build both
#   make install    into $(PREFIX)/bin + launcher + icon
#   make test       vet + the suite
#
# .buildnum is a local, gitignored counter bumped once per make run and
# stamped in via -X main.buildNum, so --version reads "0.1.0 b7" and any
# installed binary can be traced to a build.
PREFIX  ?= /usr/local
DESTDIR ?=
BINDIR   = $(DESTDIR)$(PREFIX)/bin
APPDIR   = $(DESTDIR)$(PREFIX)/share/applications
ICONDIR  = $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps
GO      ?= go
GOFLAGS ?= -trimpath

BUILDNUM_FILE = .buildnum
STAMP = -ldflags "-X main.buildNum=$$(cat $(BUILDNUM_FILE) 2>/dev/null || echo 0)"

.PHONY: all build test vet install clean bump

all: build

bump:
	@n=$$(cat $(BUILDNUM_FILE) 2>/dev/null || echo 0); echo $$((n+1)) > $(BUILDNUM_FILE)

build: bump
	CGO_ENABLED=0 $(GO) build $(GOFLAGS) $(STAMP) -o ztx-tui .
	$(GO) build $(GOFLAGS) -tags gui $(STAMP) -o ztx .

# TMPDIR is redirected because `go test` execs its compiled binary out of it
# and hardened hosts mount /tmp noexec, which fails as an opaque
# "permission denied" that reads like a broken suite.
test: vet
	mkdir -p .testtmp
	TMPDIR=$$PWD/.testtmp $(GO) test -count=1 ./...
	TMPDIR=$$PWD/.testtmp $(GO) test -count=1 -tags gui ./...

vet:
	gofmt -l . | tee /dev/stderr | (! read)
	$(GO) vet ./...
	$(GO) vet -tags gui ./...

install: build
	install -Dm0755 ztx     $(BINDIR)/ztx
	install -Dm0755 ztx-tui $(BINDIR)/ztx-tui
	install -Dm0644 assets/ztxplore.svg $(ICONDIR)/ztxplore.svg
	install -Dm0644 contrib/ztxplore.desktop $(APPDIR)/ztxplore.desktop

clean:
	rm -f ztx ztx-tui
	rm -rf .testtmp
