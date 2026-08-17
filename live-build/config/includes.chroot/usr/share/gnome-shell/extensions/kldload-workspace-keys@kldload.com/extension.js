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
}
