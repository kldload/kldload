#!/usr/bin/gjs -m
/* ---------------------------------------------------------------------------
 * Exercises gridCells() from the kldload-workspace-keys extension.
 *
 * Runs under plain gjs — no gnome-shell, no display — because layout.js
 * deliberately imports nothing. That is the whole point: the arithmetic that
 * decides where four windows land is checked here in milliseconds instead of
 * by squinting at a 4K screen.
 *
 * Usage: gjs -m tests/gnome-grid-layout.test.js
 * Exit:  0 all assertions passed, 1 one or more failed.
 * ------------------------------------------------------------------------- */

import {gridCells} from
    '../live-build/config/includes.chroot/usr/share/gnome-shell/extensions/kldload-workspace-keys@kldload.com/layout.js';

let failures = 0;
const check = (ok, what) => {
    if (!ok) {
        print(`  FAIL: ${what}`);
        failures++;
    }
};

// Odd widths and a non-zero origin are in here on purpose: a top bar makes the
// work area start below y=0, and 1919 is the width that catches naive division.
const AREAS = [
    {x: 0, y: 0, width: 1920, height: 1080},
    {x: 0, y: 45, width: 2560, height: 1395},
    {x: 0, y: 45, width: 3840, height: 2115},
    {x: 13, y: 45, width: 1919, height: 1079},
];

for (const area of AREAS) {
    for (let n = 1; n <= 9; n++) {
        const cells = gridCells(n, area);
        const tag = `${area.width}x${area.height} n=${n}`;

        check(cells.length === n, `${tag}: got ${cells.length} cells, asked for ${n}`);

        let sum = 0;
        for (const c of cells) {
            check(c.width > 0 && c.height > 0, `${tag}: non-positive cell ${JSON.stringify(c)}`);
            check(c.x >= area.x && c.y >= area.y, `${tag}: cell starts outside area`);
            check(c.x + c.width <= area.x + area.width, `${tag}: cell overhangs right edge`);
            check(c.y + c.height <= area.y + area.height, `${tag}: cell overhangs bottom edge`);
            sum += c.width * c.height;
        }

        // Exact tiling: every pixel of the work area is covered exactly once.
        // This is the assertion that catches a seam or an overlap, and it is
        // why the geometry uses cumulative boundaries rather than per-cell widths.
        check(sum === area.width * area.height,
            `${tag}: cells cover ${sum}px, area is ${area.width * area.height}px`);

        // Pairwise overlap — a sum that happens to match could still overlap.
        for (let i = 0; i < cells.length; i++) {
            for (let j = i + 1; j < cells.length; j++) {
                const a = cells[i], b = cells[j];
                const over = a.x < b.x + b.width && b.x < a.x + a.width &&
                             a.y < b.y + b.height && b.y < a.y + a.height;
                check(!over, `${tag}: cells ${i} and ${j} overlap`);
            }
        }
    }

    // The case the operator actually asked for: four windows, four quarters.
    const q = gridCells(4, area);
    check(q.every(c => Math.abs(c.width - area.width / 2) <= 1 &&
                       Math.abs(c.height - area.height / 2) <= 1),
        `${area.width}x${area.height}: four windows are not quarters`);
}

// Degenerate input must return nothing rather than throw — the extension calls
// this with whatever list_windows() gave it.
for (const bad of [0, -3, 1.5, null, undefined, 'four'])
    check(gridCells(bad, AREAS[0]).length === 0, `gridCells(${String(bad)}) should be empty`);

print(failures === 0
    ? 'gnome-grid-layout: all assertions passed'
    : `gnome-grid-layout: ${failures} assertion(s) FAILED`);
imports.system.exit(failures === 0 ? 0 : 1);
