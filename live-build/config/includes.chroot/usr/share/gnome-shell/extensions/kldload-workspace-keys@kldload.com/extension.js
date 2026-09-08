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

import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {gridCells} from './layout.js';

const WORKSPACES = 4;

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
    }

    disable() {
        // Remove every binding we added, by the same names we added them
        // under. Leaving one registered survives a lock-screen disable/enable
        // cycle and then throws on the next enable() as a duplicate.
        for (const key of this._bound ?? [])
            Main.wm.removeKeybinding(key);
        this._bound = null;
        this._settings = null;
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
