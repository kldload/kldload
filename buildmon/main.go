// =============================================================================
// kldload-buildmon — what the machine is doing, and whether the install worked.
//
// WHAT IT DOES:
//   Reads the post-install build state, audits the install logs and the booted
//   system, runs the health checks, and manages optional components — in one
//   window, or as plain text on a terminal.
//
// WHY IT EXISTS:
//   Two jobs that used to have no good home. The first is telling the operator
//   not to reboot while a multi-hour post-install build is still running; the
//   old display was a bash script repainting a terminal in place, which
//   corrupted itself the moment a second copy started (.145, 2026-08-15). The
//   second is answering "did this install actually work" — on the same day, an
//   install shipped with no kernel because one `E: Unable to locate package`
//   line sat in the middle of a 387 KB log that nobody reads.
//
// USAGE:
//   kldload-buildmon              open the window (falls back to text)
//   kldload-buildmon tui          force the text view
//   kldload-buildmon audit        print the install audit and exit
//   kldload-buildmon --version
//
// EXIT STATUS:
//   0  ran, and (for `audit`) found nothing critical
//   1  `audit` found at least one CRITICAL finding
//   2  could not start
//
// FILES:
//   /var/lib/kldload/phases/NN-<name>     the phase plan
//   /var/lib/kldload/{all-ready,current-phase,firstboot-done}
//   /var/log/installer/*.log, /var/log/kldload/*.log
//
// Notes:
//   - `audit` is the CI-friendly entry point: no display needed, and its exit
//     status is the answer, so a smoke test can call it directly.
// =============================================================================

package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"time"
)

// buildNum is stamped at build time with -X main.buildNum.
var buildNum = "0"

const version = "0.1.0"

func main() {
	var (
		stateDir = flag.String("state-dir", DefaultStateDir, "where the build records its phases")
		root     = flag.String("root", "/", "filesystem root to audit (for testing against a mounted target)")
		showVer  = flag.Bool("version", false, "print version and exit")
		bundleTo = flag.String("o", "", "bundle: write the archive here instead of the default path")
	)
	flag.Usage = usage
	flag.Parse()

	if *showVer {
		fmt.Printf("kldload-buildmon %s b%s\n", version, buildNum)
		return
	}

	opt := GatherOpts{StateDir: *stateDir, Root: *root, Timeout: 60 * time.Second}

	switch strings.ToLower(flag.Arg(0)) {
	case "audit":
		os.Exit(runAudit(opt))
	case "bundle":
		path, err := WriteBundle(opt, *bundleTo)
		if err != nil {
			fmt.Fprintln(os.Stderr, "buildmon: support bundle:", err)
			os.Exit(2)
		}
		fmt.Println(path)
	case "tui":
		if err := RunTUI(opt); err != nil {
			fmt.Fprintln(os.Stderr, "buildmon:", err)
			os.Exit(2)
		}
	case "", "gui":
		// A GUI build on a machine with no display, or a terminal-only build,
		// must not simply fail — this runs at login on every kind of profile.
		if err := RunGUI(opt); err != nil {
			fmt.Fprintln(os.Stderr, "buildmon: no GUI available:", err)
			fmt.Fprintln(os.Stderr, "buildmon: falling back to the text view")
			if err := RunTUI(opt); err != nil {
				fmt.Fprintln(os.Stderr, "buildmon:", err)
				os.Exit(2)
			}
		}
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `kldload-buildmon %s b%s — build progress and install audit

USAGE
  kldload-buildmon [flags] [command]

COMMANDS
  (none) | gui   open the window; falls back to the text view when there is
                 no display or this binary was built without a GUI
  tui            force the text view
  bundle         collect a support bundle — the audit verdict, the installer
                 and first-boot logs, the boot chain, storage, network and
                 hardware — into one .tar.gz, and print its path. Secrets are
                 recorded as present-with-mode and never copied; collected
                 text is scrubbed for credentials on the way in.
  audit          print the install audit and exit; status 1 if anything
                 CRITICAL was found (use this one from scripts and CI)

FLAGS
  --state-dir DIR  where the build records its phases (default %s)
  --root DIR       filesystem root to audit; point it at a mounted target to
                   audit an install from outside it (default /)
  --version        print version and exit

EXAMPLES
  kldload-buildmon                      watch the post-install build
  kldload-buildmon audit                did this install actually work?
  kldload-buildmon --root /mnt audit    audit a target mounted at /mnt

EXIT STATUS
  0  ran; audit found nothing critical
  1  audit found at least one CRITICAL finding
  2  could not start
`, version, buildNum, DefaultStateDir)
}

// runAudit prints the audit as text and returns the process exit status.
func runAudit(opt GatherOpts) int {
	findings := Audit(opt.Root)
	if len(findings) == 0 {
		fmt.Println("Install audit: nothing to report.")
		return 0
	}
	crit := 0
	for _, f := range findings {
		if f.Severity == SevCritical {
			crit++
		}
		where := f.Source
		if f.Line > 0 {
			where = fmt.Sprintf("%s:%d", f.Source, f.Line)
		}
		fmt.Printf("%-8s %s\n         %s\n         %s\n\n",
			f.Severity, where, f.Message, f.Why)
	}
	fmt.Printf("%d finding(s), %d critical.\n", len(findings), crit)
	if crit > 0 {
		return 1
	}
	return 0
}
