"""kldload dnf pre-transaction boot-environment snapshot plugin.

What it does
    Registers a dnf4 plugin that, immediately before any RPM transaction runs
    (install / upgrade / remove / reinstall / downgrade), invokes
    ``/usr/local/sbin/snapshot-create.sh dnf-pre`` to snapshot the active ZFS
    root boot environment. The resulting ``rpool/ROOT/<be>@dnf-pre-<ts>``
    snapshot is selectable in ZFSBootMenu, so a bad ``dnf update`` is a boot-menu
    rollback rather than a reinstall.

Why it exists
    apt ships an equivalent ``DPkg::Pre-Invoke`` hook and Arch ships a pacman
    ``PreTransaction`` hook; dnf had no such hook, so on EL/Fedora the only
    pre-transaction snapshot came from the opt-in ``kpkg`` wrapper. A plain
    ``sudo dnf update`` — the command operators actually type — left no labelled
    rollback point. This closes that gap so the BE-snapshot guarantee is uniform
    across all three package managers.

Design notes
    * dnf4 only (EL10/Fedora ship dnf-4.x; ``dnf.Plugin.pre_transaction`` is the
      stable dnf4 hook). A dnf5 host would need a libdnf5 actions file instead;
      this plugin is a no-op there because dnf5 does not load dnf4 plugins.
    * pre_transaction() fires ONLY when a real RPM transaction will run, so
      read-only verbs (search/info/list/makecache) never snapshot.
    * The snapshot must NEVER block updates: snapshot-create.sh already exits 0
      on non-ZFS roots, and any unexpected failure here is logged and swallowed
      so a snapshot problem can never leave the box unpatchable. The hourly
      auto/sanoid streams remain as a backstop.

Inputs/outputs
    Reads:  nothing (the helper resolves the BE via ``zpool get bootfs rpool``).
    Writes: a ZFS snapshot + lines in /var/log/kldload/snapshots.log.
"""

from __future__ import annotations

import logging
import subprocess

import dnf  # type: ignore[import-untyped]  # dnf ships no py.typed / stubs

_LOG = logging.getLogger("dnf")

_HELPER = "/usr/local/sbin/snapshot-create.sh"
_CONTEXT = "dnf-pre"


class KldloadBootEnv(dnf.Plugin):  # type: ignore[misc]  # dnf.Plugin is Any (untyped)
    """Snapshot the root boot environment before each dnf RPM transaction."""

    name = "kldload_be"

    def __init__(self, base: "dnf.Base", cli: "dnf.cli.Cli") -> None:
        """Store the dnf base/cli handles (standard dnf4 plugin contract)."""
        super().__init__(base, cli)
        self.base = base
        self.cli = cli

    def pre_transaction(self) -> None:
        """Snapshot the BE just before the resolved transaction is committed.

        Failure modes callers must tolerate: the helper may legitimately no-op
        (non-ZFS root) or fail (pool unavailable). Neither must abort dnf, so we
        log and continue rather than propagate — losing one snapshot is far less
        harmful than blocking a security update.
        """
        try:
            rc = subprocess.call([_HELPER, _CONTEXT])
            if rc != 0:
                self._warn(f"helper exited {rc}; no pre-tx snapshot taken")
        except OSError as exc:
            self._warn(f"helper not runnable ({exc}); no pre-tx snapshot taken")

    @staticmethod
    def _warn(msg: str) -> None:
        """Emit a warning via dnf's logger so it lands in the dnf log + console."""
        _LOG.warning("kldload-be: %s", msg)
