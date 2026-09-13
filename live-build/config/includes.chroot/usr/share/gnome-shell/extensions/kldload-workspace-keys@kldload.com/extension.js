/* ---------------------------------------------------------------------------
 * kldload workspace keys — "move this window there AND go with it"
 *
 * What it does, in order:
 *   1. On enable, registers four keybindings (one per static workspace).
 *   2. Each moves the focused window to that workspace and activates the
 *      workspace, so the operator arrives with the window.
 *   3. On disable, removes them again. No timers, no signals, no state.
 *
 * WHY THIS EXISTS: GNOME can already SEND a window to a numbered workspace
 * without following — that is what move-to-workspace-1..4 does. What it cannot
 * do is send it and go along. From mutter 48 src/core/keybindings.c,
 * handle_move_to_workspace():
 *
 *     meta_window_change_workspace (window, workspace);
 *     if (flip)
 *       meta_workspace_activate_with_focus (workspace, window, ...);
 *
 * `flip` is true only when the binding index is negative, i.e. for the
 * DIRECTIONAL variants (move-to-workspace-left/right/up/down). The numbered
 * variants take the else branch and never activate. The directional ones do
 * follow, but they are relative to the current workspace, so they cannot
 * express a fixed compass layout where Left is always workspace 2 — which is
 * the layout this desktop uses.
 *
 * So the missing half needs shell-side code. Shell.Eval was disabled in GNOME
 * 41 (it returns false here), leaving an extension as the only supported route
 * — this is the same thing every "move window and follow" extension does.
 *
 * Inputs:  keybindings from the extension's own GSettings schema, which
 *          /etc/dconf/db/local.d/00-kldload-desktop populates alongside the
 *          rest of the keymap so one file describes the whole map.
 * Outputs: none. It moves windows.
 *
 * Notes:
 *   - always-on-all-workspaces windows are skipped, matching mutter's own
 *     `if (window->always_sticky) return;` guard. Moving a sticky window to
 *     one workspace would be a silent contradiction of what the user asked
 *     the window to be.
 *   - With no focused window the workspace is still activated, so the key is
 *     never a no-op that leaves the operator wondering whether it registered.
 * ------------------------------------------------------------------------- */

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {gridCells} from './layout.js';

const WORKSPACES = 4;

// The resolver that answers "which four dashboards". Kept out of here on
// purpose: which dashboard belongs on which workspace is an operator decision
// that changes, and a shell extension is the worst place to edit a URL.
const CC_TOOL = '/usr/local/bin/kldload-command-center';
// One Chrome profile per window, and the prefix the tool's `stop` matches on.
const CC_APP_PREFIX = 'com.kldload.cc';
// A window that never appears must not hang the launch loop. Ten seconds is
// far longer than Chrome takes to map its first frame and short enough that a
// failure is obvious rather than a desktop that seems to have frozen.
const CC_WINDOW_TIMEOUT_MS = 10000;

export default class KldloadWorkspaceKeys extends Extension {
    enable() {
        this._settings = this.getSettings();
        this._bound = [];

        for (let i = 1; i <= WORKSPACES; i++) {
            const key = `move-follow-${i}`;
            // ActionMode.NORMAL only: the binding must not fire while the
            // overview or a modal dialog owns the keyboard, where "the focused
            // window" is not what the operator is looking at.
            Main.wm.addKeybinding(
                key,
                this._settings,
                Meta.KeyBindingFlags.NONE,
                Shell.ActionMode.NORMAL,
                () => this._moveAndFollow(i - 1));
            this._bound.push(key);
        }

        // Super+G. Stock GNOME tiles a window to a HALF and stops there —
        // toggle-tiled-left/right are the only tiling actions mutter exposes,
        // and there is no binding, in any version, that arranges more than one
        // window. Four windows at a quarter each is a thing an operator asks
        // for constantly and has to do by hand every time.
        Main.wm.addKeybinding(
            'tile-grid',
            this._settings,
            Meta.KeyBindingFlags.NONE,
            Shell.ActionMode.NORMAL,
            () => this._tileGrid());
        this._bound.push('tile-grid');

        // Ctrl+Delete. The operator's ask was a mode rather than a permanent
        // rearrangement: "for the command center ... ctrl+del, and have that
        // launch the tiling command center, then you turn it off when you
        // exit" (2026-09-13).
        Main.wm.addKeybinding(
            'command-center',
            this._settings,
            Meta.KeyBindingFlags.NONE,
            Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW,
            () => this._toggleCommandCenter());
        this._bound.push('command-center');

        this._ccOpen = false;
        this._ccBusy = false;
    }

    disable() {
        // Remove every binding we added, by the same names we added them
        // under. Leaving one registered survives a lock-screen disable/enable
        // cycle and then throws on the next enable() as a duplicate.
        for (const key of this._bound ?? [])
            Main.wm.removeKeybinding(key);
        this._bound = null;
        this._settings = null;
        // Deliberately does NOT close the command-center windows. disable()
        // runs on lock, on a shell restart and on an extension reload, and
        // tearing down the operator's wall display because the screen locked
        // would be its own bug. The windows are ordinary windows; the tool's
        // `stop` verb closes them whenever the operator wants.
        this._ccOpen = false;
        this._ccBusy = false;
    }

    /* ── Command center ──────────────────────────────────────────────────
     *
     * Ctrl+Delete opens one dashboard per workspace and Ctrl+Delete closes
     * them. That is the whole interface.
     *
     * WHY THE LAUNCH IS SEQUENTIAL AND SWITCHES WORKSPACE BETWEEN EACH:
     * Wayland has no "open this window over there". The alternatives are to
     * match windows after the fact by app id — which Chrome derives
     * differently depending on version and whether the session is Wayland or
     * X11, and which the comment block in kldload-chrome-app has been wrong
     * about in both directions — or to put each window where new windows
     * already go. New windows open on the ACTIVE workspace. So the extension
     * activates workspace N, launches one window, waits for it to actually
     * appear, and moves on. Placement becomes a consequence instead of a
     * request, and there is no app id to guess.
     *
     * Failure modes a reader should know about: the resolver not answering
     * (Grafana down) aborts before anything is opened and says so; a window
     * that never maps times out after CC_WINDOW_TIMEOUT_MS and the loop
     * continues, so one bad dashboard costs one workspace rather than the
     * whole wall.
     */
    _toggleCommandCenter() {
        // Guard re-entry: the launch takes seconds and Ctrl+Delete is exactly
        // the kind of key an impatient operator presses twice.
        if (this._ccBusy)
            return;
        if (this._ccOpen)
            this._stopCommandCenter();
        else
            this._startCommandCenter();
    }

    _stopCommandCenter() {
        this._ccOpen = false;
        try {
            Gio.Subprocess.new([CC_TOOL, 'stop'], Gio.SubprocessFlags.NONE);
        } catch (e) {
            logError(e, 'kldload command center: could not run the stop verb');
        }
    }

    _startCommandCenter() {
        this._ccBusy = true;
        this._ccUrls()
            .then(urls => {
                if (urls.length < WORKSPACES) {
                    Main.notify('kldload command center',
                        `resolver returned ${urls.length} of ${WORKSPACES} dashboards — not opening`);
                    this._ccBusy = false;
                    return;
                }
                return this._ccLaunchAll(urls).then(() => {
                    this._ccOpen = true;
                    this._ccBusy = false;
                    // Land back where the operator started, not on the last
                    // workspace the loop happened to touch.
                    global.workspace_manager
                        .get_workspace_by_index(0)
                        .activate(global.get_current_time());
                });
            })
            .catch(e => {
                this._ccBusy = false;
                logError(e, 'kldload command center');
                Main.notify('kldload command center', `failed: ${e.message}`);
            });
    }

    /* Ask the resolver for the four URLs. Resolves to an array of strings;
     * rejects when the tool fails, which is the Grafana-is-down case. stdout
     * only — the tool puts its diagnostics on stderr precisely so this parse
     * cannot be poisoned by a warning. */
    _ccUrls() {
        return new Promise((resolve, reject) => {
            let proc;
            try {
                proc = Gio.Subprocess.new([CC_TOOL, 'urls'],
                    Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
            } catch (e) {
                reject(e);
                return;
            }
            proc.communicate_utf8_async(null, null, (p, res) => {
                try {
                    const [, stdout] = p.communicate_utf8_finish(res);
                    if (!p.get_successful()) {
                        reject(new Error(`${CC_TOOL} urls exited non-zero`));
                        return;
                    }
                    resolve((stdout ?? '').split('\n').map(l => l.trim()).filter(l => l.length > 0));
                } catch (e) {
                    reject(e);
                }
            });
        });
    }

    /* Walk the workspaces, one window each, in order. */
    _ccLaunchAll(urls) {
        let chain = Promise.resolve();
        for (let i = 0; i < WORKSPACES; i++) {
            const index = i;
            chain = chain.then(() => {
                const ws = global.workspace_manager.get_workspace_by_index(index);
                if (!ws)
                    return null;
                ws.activate(global.get_current_time());
                return this._ccLaunchOne(urls[index], index);
            });
        }
        return chain;
    }

    /* Launch one dashboard window and resolve once it has mapped, or once the
     * timeout fires. Never rejects: one dashboard that will not open must not
     * take the other three with it. */
    _ccLaunchOne(url, index) {
        return new Promise(resolve => {
            let done = false;
            let handler = 0;
            let timer = 0;

            const finish = win => {
                if (done)
                    return;
                done = true;
                if (handler)
                    global.display.disconnect(handler);
                if (timer)
                    GLib.source_remove(timer);
                if (win) {
                    // Maximize rather than fullscreen: fullscreen hides the
                    // top bar, and the top bar is how the operator sees which
                    // workspace they are on — which is the entire point of
                    // spreading these over four of them.
                    win.maximize(Meta.MaximizeFlags.BOTH);
                }
                resolve();
            };

            handler = global.display.connect('window-created', (_d, win) => {
                if (win.get_window_type() === Meta.WindowType.NORMAL)
                    finish(win);
            });

            timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, CC_WINDOW_TIMEOUT_MS, () => {
                timer = 0;
                finish(null);
                return GLib.SOURCE_REMOVE;
            });

            try {
                Gio.Subprocess.new(
                    ['/usr/local/bin/kldload-chrome-app', `${CC_APP_PREFIX}.${index + 1}`, url],
                    Gio.SubprocessFlags.NONE);
            } catch (e) {
                logError(e, 'kldload command center: launch failed');
                finish(null);
            }
        });
    }

    /* Move the focused window to workspace `index` (0-based) and go there.
     * Returns nothing; failure modes are "no such workspace" (ignored) and
     * "no focused window" (activate anyway). */
    _moveAndFollow(index) {
        const wsManager = global.workspace_manager;
        const workspace = wsManager.get_workspace_by_index(index);
        if (!workspace)
            return;

        const win = global.display.focus_window;
        const time = global.get_current_time();

        if (win && !win.is_always_on_all_workspaces()) {
            // Change first, activate second — the same order mutter uses, with
            // the same reason: the window is never unmapped in between.
            win.change_workspace(workspace);
            workspace.activate_with_focus(win, time);
        } else {
            workspace.activate(time);
        }
    }

    /* Lay every ordinary window on the active workspace and current monitor
     * into an even grid — four windows become four exact quarters.
     *
     * Args:    none. Operates on the focused monitor's work area, so the top
     *          bar and any dock are already excluded.
     * Returns: nothing. A workspace with no eligible windows is a no-op.
     *
     * Failure modes a caller should know about: windows that refuse resizing
     * (a modal dialog, a splash) are left out of the count entirely rather
     * than assigned a cell they will not occupy — otherwise the grid reserves
     * a hole for a window that never moves into it.
     */
    _tileGrid() {
        const display = global.display;
        const workspace = global.workspace_manager.get_active_workspace();
        const monitor = display.get_current_monitor();
        const area = workspace.get_work_area_for_monitor(monitor);

        const windows = workspace.list_windows().filter(w =>
            w.get_monitor() === monitor &&
            w.get_window_type() === Meta.WindowType.NORMAL &&
            !w.is_skip_taskbar() &&
            !w.minimized &&
            w.allows_resize());

        if (windows.length === 0)
            return;

        // Stacking order, so the arrangement matches what the operator sees
        // rather than the order mutter happens to hold the list in.
        const ordered = display.sort_windows_by_stacking(windows);
        const cells = gridCells(ordered.length, area);

        ordered.forEach((win, i) => {
            // Read the two GObject properties rather than call a maximize
            // getter: mutter 18 (GNOME 50) has is_maximized() and no
            // get_maximized(), the reverse of older releases, so any getter I
            // pick breaks half the 45-to-50 range this extension claims.
            // maximized_horizontally/vertically have been present throughout.
            // Introspected on fiend against mutter-18, 2026-09-07 — the first
            // spelling I reached for did not exist.
            if (win.maximized_horizontally || win.maximized_vertically)
                win.unmaximize(Meta.MaximizeFlags.BOTH);
            if (win.is_fullscreen())
                win.unmake_fullscreen();

            const cell = cells[i];
            win.move_resize_frame(true, cell.x, cell.y, cell.width, cell.height);
        });
    }
}
