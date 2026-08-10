# Makefile — vmxplore build entry points (Phase A, in the kldload repo).
#
# Two binaries from one tree (the zxplore/wgxplore pattern):
#   vmxplore — the full build: native GUI (Fyne) + TUI (--tui). Needs cgo+GL.
#   vmx      — STATIC terminal-only build (CGO_ENABLED=0): zero runtime deps,
#              scp it to any libvirt box. Headless hosts build just this
#              (`make tui`) with nothing but the Go toolchain.
#
# BUILD dependencies (cgo + OpenGL — for the GUI binary only):
#   Fedora/RHEL:   dnf install -y golang gcc pkgconf-pkg-config \
#                    mesa-libGL-devel libX11-devel libXcursor-devel \
#                    libXrandr-devel libXinerama-devel libXi-devel \
#                    libXxf86vm-devel wayland-devel libxkbcommon-devel \
#                    fontconfig-devel
#   Debian/Ubuntu: apt-get install -y golang gcc pkg-config \
#                    libgl1-mesa-dev xorg-dev libwayland-dev \
#                    libxkbcommon-dev libfontconfig1-dev
#
# .buildnum is a local, gitignored counter that self-increments once per
# `make build` and stamps both binaries via -X main.buildNum → "0.2.2 b<N>"
# in --version and the GUI status bar. .DEFAULT_GOAL is set explicitly so
# `bump` being written first can't become the default goal (the zxplore/
# wgxplore Makefile bug, 2026-08-03).
.DEFAULT_GOAL := build

BIN_TUI := vmx
BIN_GUI := vmxplore

BUILDNUM_FILE = .buildnum
STAMPFLAGS    = -ldflags "-X main.buildNum=$$(cat $(BUILDNUM_FILE) 2>/dev/null || echo 0)"

PREFIX  ?= /usr/local
DESTDIR ?=
BINDIR   = $(DESTDIR)$(PREFIX)/bin
MANDIR   = $(DESTDIR)$(PREFIX)/share/man/man1
APPDIR   = $(DESTDIR)$(PREFIX)/share/applications
ICONDIR  = $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps
DOCDIR   = $(DESTDIR)$(PREFIX)/share/doc/vmxplore

.PHONY: build bump tui gui test vet fmt check clean install uninstall

bump:
	@n=$$(cat $(BUILDNUM_FILE) 2>/dev/null || echo 0); echo $$((n + 1)) > $(BUILDNUM_FILE)

build: bump tui gui

tui:
	CGO_ENABLED=0 go build -trimpath $(STAMPFLAGS) -o $(BIN_TUI) .

gui:
	go build -trimpath -tags gui $(STAMPFLAGS) -o $(BIN_GUI) .

test:
	go test ./...

vet:
	go vet ./...
	go vet -tags gui ./...

fmt:
	gofmt -l .

check: vet test build
	@test -z "$$(gofmt -l .)" || { echo "gofmt drift:"; gofmt -l .; exit 1; }

clean:
	rm -f $(BIN_TUI) $(BIN_GUI)

install: build
	install -d $(BINDIR) $(MANDIR) $(APPDIR) $(ICONDIR) $(DOCDIR)
	install -m 0755 $(BIN_GUI) $(BINDIR)/$(BIN_GUI)
	install -m 0755 $(BIN_TUI) $(BINDIR)/$(BIN_TUI)
	install -m 0644 docs/vmxplore.1                 $(MANDIR)/vmxplore.1
	install -m 0644 packaging/vmxplore.svg          $(ICONDIR)/vmxplore.svg
	install -m 0644 packaging/vmxplore.desktop      $(APPDIR)/vmxplore.desktop
	install -m 0644 packaging/vmxplore-tui.desktop  $(APPDIR)/vmxplore-tui.desktop
	@if [ -f README.md ]; then install -m 0644 README.md $(DOCDIR); fi
	@echo "vmxplore installed to $(PREFIX)/bin"

uninstall:
	rm -f $(BINDIR)/$(BIN_GUI) $(BINDIR)/$(BIN_TUI) \
	  $(APPDIR)/vmxplore.desktop $(APPDIR)/vmxplore-tui.desktop \
	  $(ICONDIR)/vmxplore.svg
	rm -rf $(DOCDIR)
