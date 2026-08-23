/* ---------------------------------------------------------------------------
   app.js — fetches the API and renders the page.

   What it does, in order:
     1. Loads stats, products and orders on start.
     2. Wires the three tabs and the order form.
     3. Re-polls stats every 5s so a cutover is visible without a reload: the
        "served by" line changes pod the moment the service selector flips.

   I render with textContent and explicit element creation rather than innerHTML
   with template strings. The values come from a database that a visitor to this
   demo can write to via the order form, so building markup out of them by
   concatenation would be an XSS hole in the one file people are most likely to
   copy out of.
   --------------------------------------------------------------------------- */
'use strict';

const $ = (sel) => document.querySelector(sel);
const money = (n) => '$' + Number(n).toLocaleString('en-US', { minimumFractionDigits: 2,
                                                              maximumFractionDigits: 2 });

async function api(path, opts) {
    const res = await fetch(path, opts);
    if (!res.ok) {
        let detail = res.statusText;
        try { detail = (await res.json()).error || detail; } catch (_) { /* non-JSON error body */ }
        throw new Error(detail);
    }
    return res.json();
}

/* Build one <td>. `cls` is optional and only ever set from literals in this
   file, never from server data. */
function cell(text, cls) {
    const td = document.createElement('td');
    td.textContent = text;
    if (cls) td.className = cls;
    return td;
}

function statCard(key, value) {
    const d = document.createElement('div');
    d.className = 'stat';
    const k = document.createElement('div'); k.className = 'k'; k.textContent = key;
    const v = document.createElement('div'); v.className = 'v'; v.textContent = value;
    d.append(k, v);
    return d;
}

async function loadStats() {
    const s = await api('/api/stats');
    const el = $('#stats');
    el.replaceChildren(
        statCard('Products', s.products),
        statCard('Customers', s.customers),
        statCard('Orders', s.orders),
        statCard('Revenue', money(s.revenue)),
    );
    // The banner is the cutover's tell: pod name changes the instant the
    // service selector moves to the other track.
    $('#served').textContent = `served by ${s.pod} on ${s.node}`;
}

async function loadProducts() {
    const rows = await api('/api/products');
    const body = $('#products tbody');
    body.replaceChildren(...rows.map((p) => {
        const tr = document.createElement('tr');
        tr.append(cell(p.sku), cell(p.name), cell(p.category),
                  cell(money(p.price), 'num'), cell(p.stock, 'num'));
        return tr;
    }));
    const sel = $('#f-product');
    sel.replaceChildren(...rows.map((p) => {
        const o = document.createElement('option');
        o.value = p.id;
        o.textContent = `${p.name} (${money(p.price)}, ${p.stock} in stock)`;
        return o;
    }));
}

async function loadOrders() {
    const rows = await api('/api/orders');
    const body = $('#orders tbody');
    body.replaceChildren(...rows.map((o) => {
        const tr = document.createElement('tr');
        const status = document.createElement('td');
        const badge = document.createElement('span');
        badge.className = 'badge ' + o.status;   // status is CHECK-constrained in the schema
        badge.textContent = o.status;
        status.append(badge);
        tr.append(cell(o.order_id, 'num'), cell(o.customer), cell(o.city), status,
                  cell(o.items, 'num'), cell(money(o.total), 'num'));
        return tr;
    }));
}

async function loadCustomers() {
    const rows = await api('/api/customers');
    $('#f-customer').replaceChildren(...rows.map((c) => {
        const o = document.createElement('option');
        o.value = c.id;
        o.textContent = `${c.name} — ${c.city}`;
        return o;
    }));
}

async function loadSchema() {
    const v = await api('/api/version');
    const s = v.schema && v.schema[0];
    $('#schema-note').textContent = s
        ? `schema v${s.version} — ${s.note}`
        : 'schema: unknown';
}

document.querySelectorAll('.tab').forEach((tab) => {
    tab.addEventListener('click', () => {
        document.querySelectorAll('.tab').forEach((t) => t.classList.remove('active'));
        tab.classList.add('active');
        document.querySelectorAll('.panel').forEach((p) => p.classList.add('hidden'));
        $('#view-' + tab.dataset.view).classList.remove('hidden');
    });
});

$('#order-form').addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const out = $('#order-result');
    out.className = 'result';
    out.textContent = 'placing…';
    try {
        const body = {
            customer_id: Number($('#f-customer').value),
            product_id: Number($('#f-product').value),
            quantity: Number($('#f-qty').value),
        };
        const r = await api('/api/orders', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
        });
        out.className = 'result ok';
        out.textContent = `order #${r.order_id} placed via the ${r.track} track — ` +
                          `it survives the next cutover`;
        await Promise.all([loadStats(), loadProducts(), loadOrders()]);
    } catch (err) {
        out.className = 'result err';
        out.textContent = 'failed: ' + err.message;
    }
});

async function boot() {
    try {
        await Promise.all([loadStats(), loadProducts(), loadOrders(),
                           loadCustomers(), loadSchema()]);
    } catch (err) {
        $('#served').textContent = 'API error: ' + err.message;
    }
}
boot();
setInterval(() => loadStats().catch(() => { /* transient during a cutover; next tick retries */ }),
            5000);
