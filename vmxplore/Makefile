# Makefile — vmxplore build entry points (Phase A, in the kldload repo).
# The static TUI build is the release artifact shape: CGO_ENABLED=0 so the
# family's copy-anywhere story holds. No GUI target yet — 0.x is TUI-only;
# the Fyne surface arrives with the chassis extraction (design doc, Phase B).
#
# Every `make build` stamps main.build with UTC minute + git short hash so
# binaries in the field are distinguishable (`vmx --version`, TUI title bar).

BIN := vmx
STAMP := $(shell date -u +%Y%m%d.%H%M).$(shell git rev-parse --short=7 HEAD 2>/dev/null || echo nogit)

.PHONY: build test vet fmt check clean

build:
	CGO_ENABLED=0 go build -trimpath -ldflags "-X main.build=$(STAMP)" -o $(BIN) .

test:
	go test ./...

vet:
	go vet ./...

fmt:
	gofmt -l .

check: vet test build
	@test -z "$$(gofmt -l .)" || { echo "gofmt drift:"; gofmt -l .; exit 1; }

clean:
	rm -f $(BIN)
