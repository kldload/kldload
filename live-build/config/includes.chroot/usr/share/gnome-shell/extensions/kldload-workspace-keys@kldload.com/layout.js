/* ---------------------------------------------------------------------------
 * kldload workspace keys — grid geometry
 *
 * Splits a rectangle into `count` cells that exactly tile it. Kept in its own
 * file with NO imports for one reason: it is the only part of this extension
 * that can be wrong arithmetically, and a file that imports gi:// cannot be
 * run outside gnome-shell. This one runs under plain `gjs -m`, so layout.test
 * .js exercises every count from 1 to 9 before any of it reaches a session.
 *
 * Inputs:  count (int > 0), area ({x, y, width, height} in pixels — a
 *          Mtk.Rectangle from get_work_area_for_monitor() satisfies this).
 * Outputs: an array of `count` {x, y, width, height} cells, row-major.
 * ------------------------------------------------------------------------- */

/* Even-ish grid: as square as the count allows, remainder on the bottom row.
 *
 * Four windows is the case the operator asked for and the one that has to be
 * exactly right — 2x2, each a true quarter. sqrt gives that for free, and it
 * degrades sensibly either side: 2 windows are half and half, 3 are two on top
 * and one full-width beneath, 6 are 3x2.
 *
 * WHY BOUNDARIES, NOT WIDTHS: computing each cell as round(width / cols) and
 * stepping by it leaves a seam of desktop down the middle on any width not
 * divisible by the column count — 2560 / 3 is the common one — or overhangs
 * the right edge by a pixel or two. Deriving both edges from the same
 * cumulative expression means cell N's right edge IS cell N+1's left edge, so
 * the cells tile the area exactly whatever the resolution. The test asserts
 * that union, which is why it is worth the extra closure.
 */
export function gridCells(count, area) {
    if (!Number.isInteger(count) || count <= 0)
        return [];

    const cols = Math.ceil(Math.sqrt(count));
    const rows = Math.ceil(count / cols);
    const rowEdge = r => area.y + Math.round((r * area.height) / rows);

    const cells = [];
    for (let r = 0; r < rows; r++) {
        // The bottom row carries the remainder and spreads it across the full
        // width, so three windows read as 2-over-1 rather than 2-over-1-and-a-gap.
        const inRow = r === rows - 1 ? count - r * cols : cols;
        const colEdge = c => area.x + Math.round((c * area.width) / inRow);

        for (let c = 0; c < inRow; c++) {
            cells.push({
                x: colEdge(c),
                y: rowEdge(r),
                width: colEdge(c + 1) - colEdge(c),
                height: rowEdge(r + 1) - rowEdge(r),
            });
        }
    }
    return cells;
}
