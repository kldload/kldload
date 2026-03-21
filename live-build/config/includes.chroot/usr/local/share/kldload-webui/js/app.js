/* kldload Web UI — frontend application */
'use strict';

const WS_PORT = 8081;
const WS_SCHEME = location.protocol === 'https:' ? 'wss' : 'ws';
const WS_HOST = location.hostname;

let ws        = null;
let wsReady   = false;

// Wizard state
let wizSelected = { template: 'master', disk: null };

// ── WebSocket ──────────────────────────────────────────────────────────────────

function wsConnect() {
  ws = new WebSocket(`${WS_SCHEME}://${WS_HOST}:${WS_PORT}`);
  ws.onopen = () => {
    wsReady = true;
    setWsStatus(true);
    wsSend({ action: 'system_info' });
    wsSend({ action: 'list_disks' });
    loadGoldenStatus();
  };
  ws.onclose = () => {
    wsReady = false;
    setWsStatus(false);
    setTimeout(wsConnect, 3000);
  };
  ws.onerror = () => { ws.close(); };
  ws.onmessage = (e) => {
    let msg;
    try { msg = JSON.parse(e.data); } catch { return; }
    handleMsg(msg);
  };
}

function wsSend(obj) {
  if (wsReady) ws.send(JSON.stringify(obj));
}

function setWsStatus(ok) {
  const dot   = document.getElementById('ws-status');
  const label = document.getElementById('ws-label');
  if (dot)   { dot.className   = 'ws-dot ' + (ok ? 'connected' : 'disconnected'); }
  if (label) { label.textContent = ok ? 'connected' : 'disconnected'; }
}

// ── Message dispatch ──────────────────────────────────────────────────────────

function handleMsg(msg) {
  switch (msg.type) {
    case 'system_info':    renderSysInfo(msg.data);              break;
    case 'disk_list':      renderDisks(msg.disks);               break;
    case 'wg_data':        renderWG(msg.data);                   break;
    case 'wg_keypair':     renderWGKeypair(msg);                 break;
    case 'wg_add_peer_result':    renderWGAddResult(msg.results);      break;
    case 'wg_remove_peer_result': renderWGRemoveResult(msg.results);   break;
    case 'network_data':   renderNetwork(msg.interfaces);        break;
    case 'vm_list':        renderVMs(msg.vms);                   break;
    case 'zfs_data':       renderZFS(msg);                       break;
    case 'k8s_nodes':      renderK8s(msg.nodes);                 break;
    case 'salt_status':    renderSalt(msg.minions, msg.pending); break;
    case 'node_list':      renderNodeList(msg.nodes, msg.pending); break;
    case 'golden_status':  renderGoldenStatus(msg.status);       break;
    case 'log_content':    renderLog(msg.lines);                 break;
    case 'log_line':
      if (msg.target === 'cluster-deploy') appendClusterLog(msg.line);
      else appendLog(msg.line, msg.target);
      break;
    case 'exec_start':     clearExecLog(msg.target);             break;
    case 'exec_done':
      if (msg.target === 'cluster-deploy') {
        const dEl = document.getElementById('cd-done-msg');
        const tEl = document.getElementById('cd-log-title');
        if (msg.rc === 0) {
          if (dEl) dEl.style.display = '';
          if (tEl) tEl.textContent = 'Cluster deploy complete';
        } else {
          if (tEl) tEl.textContent = `Cluster deploy failed (rc=${msg.rc})`;
        }
      } else doneExecLog(msg.rc, msg.target);
      break;
    case 'poof_done':      alert('Live session scrubbed.');        break;
    case 'audit_started':  renderAuditStarted();                  break;
    case 'audit_done':     renderAuditDone(msg);                  break;
    case 'credentials_data':
      _credData = msg.creds;
      credRender();
      break;
    case 'credentials_saved':
      { const el = document.getElementById('cred-save-status');
        if (el) { el.textContent = 'Saved.'; setTimeout(() => el.textContent = '', 2000); } }
      break;
    case 'credentials_test_result':
      { const el = document.getElementById(`test-result-${msg.provider === 'proxmox' ? msg.id : msg.provider}`);
        if (el) el.textContent = msg.ok ? '✓ connected' : `✗ ${msg.err}`; }
      break;
    case 'wg_planes':
      renderWgPlanes(msg.planes);
      break;
    case 'wg_plane_created':
      hide('wg-add-plane-form');
      break;
    case 'wg_plane_deleted':
      break;
    case 'pong':           break;
    case 'error':          console.error('WS error:', msg.msg);  break;
    case 'db_list':        libRender(msg.items);                 break;
    case 'db_saved':
      libToast(`Saved: ${msg.name}`);
      if (document.getElementById('view-library')?.classList.contains('active')) libInit();
      break;
    case 'db_loaded':      libApplyLoaded(msg.template);         break;
    case 'db_deleted':     libToast('Deleted'); libInit();        break;
    case 'db_nodes':       /* future: render node inventory */    break;
    case 'db_events':      renderDbEvents(msg.events);           break;
    case 'infra_status':   infraRender(msg);                     break;
    case 'cluster_saved':  libToast('Cluster saved');            break;
    case 'ui_mode':        renderUiMode(msg);          break;
    case 'service_list':   svcDbRender(msg.services);  break;
    case 'service_saved':  libToast('Service saved'); svcDbLoad(); break;
    case 'service_deleted':libToast('Deleted'); svcDbLoad();       break;
    case 'db_exported':    dbExportDownload(msg.data);             break;
    case 'db_imported':    libToast(`Imported: ${JSON.stringify(msg.counts)}`); break;
  }
}

// ── Navigation ────────────────────────────────────────────────────────────────

function nav(view) {
  document.querySelectorAll('.view').forEach(el => el.classList.remove('active'));
  document.querySelectorAll('#sidebar li').forEach(li => li.classList.remove('active'));

  const el = document.getElementById('view-' + view);
  if (el) el.classList.add('active');
  const li = document.querySelector(`[data-view="${view}"]`);
  if (li) li.classList.add('active');

  if (view === 'credentials')    credLoad();
  if (view === 'wireguard')      loadWG();
  if (view === 'network')        loadNetwork();
  if (view === 'vms')            loadVMs();
  if (view === 'zfs')            loadZFS();
  if (view === 'k8s')            loadK8s();
  if (view === 'salt')           loadSalt();
  if (view === 'golden')         loadGoldenStatus();
  if (view === 'nodes')          loadNodes();
  if (view === 'cluster-deploy')   cdInit();
  if (view === 'pool-designer')    pdInit();
  if (view === 'cluster-designer') cdsInit();
  if (view === 'firewall')         fwInit();
  if (view === 'services')         { svcInit(); svcDbLoad(); wsSend({ action: 'ui_mode' }); }
  if (view === 'cloud-keys')       ckInit();
  if (view === 'library')          libInit();
  if (view === 'infrastructure') infraLoad();
  if (view === 'events')         eventsLoad();
}

document.querySelectorAll('#sidebar li').forEach(li => {
  li.addEventListener('click', () => nav(li.dataset.view));
});

// ── Dashboard ─────────────────────────────────────────────────────────────────

function renderSysInfo(d) {
  if (!d) return;
  setText('si-hostname', d.hostname    || '?');
  setText('si-profile',  d.kldload_profile || 'live');
  setText('si-cpus',     d.cpus        || '?');
  setText('si-memory',   `${d.memory_free || '?'} / ${d.memory_total || '?'}`);
  setText('si-index',    d.node_index  || '—');
  setText('si-wg1',      d.wg1_ip      || '—');
  setText('si-uptime',   d.uptime      || '');

  // Live mode banner
  const banner = document.getElementById('live-banner');
  if (banner) banner.style.display = d.live_mode ? '' : 'none';

  // Mini WG table on dashboard
  if (d.wg) {
    [0, 1, 2, 3].forEach(n => {
      const iface = d.wg[`wg${n}`] || {};
      setText(`d-wg${n}-ip`, iface.ip    || '—');
      const stEl = document.getElementById(`d-wg${n}-st`);
      if (stEl) {
        stEl.innerHTML = iface.up
          ? '<span class="badge badge-green">up</span>'
          : '<span class="badge badge-red">down</span>';
      }
    });
  }
}

// ── Poof ──────────────────────────────────────────────────────────────────────

function triggerPoof() {
  if (!confirm('Scrub all ephemeral keys and credentials from this live session?')) return;
  wsSend({ action: 'poof', _target: 'log' });
}

// ── WireGuard ─────────────────────────────────────────────────────────────────

function loadWG() { wsSend({ action: 'wg_status' }); wsSend({ action: 'wg_planes_list' }); }

function renderWG(data) {
  if (!data) return;
  [0, 1, 2, 3].forEach(n => {
    const iface = data[`wg${n}`] || {};
    const stEl  = document.getElementById(`wg${n}-state`);
    if (stEl) {
      stEl.textContent = iface.up ? 'up' : 'down';
      stEl.className   = 'wg-badge ' + (iface.up ? 'up' : 'down');
    }
    setText(`wg${n}-ip`,    iface.ip    || '—');
    setText(`wg${n}-peers`, iface.peers != null ? iface.peers : '—');
  });

  // Peer table (wg1)
  const tbody = document.getElementById('wg-peer-tbody');
  if (!tbody) return;
  const peers = (data.wg1 || {}).peer_list || [];
  if (!peers.length) {
    tbody.innerHTML = '<tr><td colspan="6" class="loading">No peers</td></tr>';
    return;
  }
  tbody.innerHTML = peers.map(p => `<tr>
    <td class="mono" title="${esc(p.pubkey || '')}">${esc(p.pubkey_short || p.pubkey || '?')}</td>
    <td>${esc(p.endpoint || '—')}</td>
    <td class="mono">${esc(p.allowed_ips || '—')}</td>
    <td>${esc(p.last_handshake || '—')}</td>
    <td>${esc(p.transfer || '—')}</td>
    <td><button class="btn-danger btn-xs" onclick="wgRemovePeer('wg1','${esc(p.pubkey || '')}')">Remove</button></td>
  </tr>`).join('');
}

// ── WireGuard peer management ─────────────────────────────────────────────────

function openAddPeer() {
  document.getElementById('wg-add-panel').style.display = 'block';
  document.getElementById('wg-add-result').textContent = '';
  document.getElementById('wg-keypair-box').style.display = 'none';
}
function closeAddPeer() {
  document.getElementById('wg-add-panel').style.display = 'none';
}

function wgGenKeypair() {
  wsSend({ action: 'wg_gen_keypair' });
}

function wgAddPeer() {
  const pubkey      = document.getElementById('wg-add-pubkey').value.trim();
  const allowed_ips = document.getElementById('wg-add-aips').value.trim();
  const iface       = document.getElementById('wg-add-iface').value;
  const endpoint    = document.getElementById('wg-add-endpoint').value.trim();
  const res         = document.getElementById('wg-add-result');

  if (!pubkey || !allowed_ips) {
    res.textContent = 'Public key and Allowed IPs are required.';
    res.style.color = 'var(--red)';
    return;
  }
  res.textContent = 'Adding peer…';
  res.style.color = 'var(--muted)';
  wsSend({ action: 'wg_add_peer', iface, pubkey, allowed_ips, endpoint });
}

function wgRemovePeer(iface, pubkey) {
  if (!confirm(`Remove peer ${pubkey.slice(0,16)}… from ${iface}?`)) return;
  wsSend({ action: 'wg_remove_peer', iface, pubkey });
}

function renderWGKeypair(msg) {
  document.getElementById('wg-keypair-box').style.display = 'block';
  document.getElementById('wg-gen-privkey').textContent = msg.privkey || '';
  document.getElementById('wg-gen-pubkey').textContent  = msg.pubkey  || '';
  // Auto-fill public key field
  const pkField = document.getElementById('wg-add-pubkey');
  if (pkField) pkField.value = msg.pubkey || '';
}

function renderWGAddResult(results) {
  const res = document.getElementById('wg-add-result');
  if (!res) return;
  const ok  = results.every(r => r.ok);
  const txt = results.map(r => `${r.iface}: ${r.ok ? 'added' : 'FAILED — ' + (r.error || '?')}`).join('  ');
  res.textContent = txt;
  res.style.color = ok ? 'var(--green)' : 'var(--red)';
  if (ok) {
    document.getElementById('wg-add-pubkey').value    = '';
    document.getElementById('wg-add-aips').value      = '';
    document.getElementById('wg-add-endpoint').value  = '';
    document.getElementById('wg-keypair-box').style.display = 'none';
  }
}

function renderWGRemoveResult(results) {
  const ok = results.every(r => r.ok);
  const txt = results.map(r => `${r.iface}: ${r.ok ? 'removed' : 'FAILED — ' + (r.error || '?')}`).join('  ');
  const div = document.createElement('div');
  div.style.cssText = `position:fixed;bottom:20px;right:20px;background:var(--bg2);border:1px solid ${ok ? 'var(--green)' : 'var(--red)'};border-radius:6px;padding:10px 16px;font-size:0.82rem;color:${ok ? 'var(--green)' : 'var(--red)'};z-index:999`;
  div.textContent = txt;
  document.body.appendChild(div);
  setTimeout(() => div.remove(), 3000);
}

// ── Network ───────────────────────────────────────────────────────────────────

function loadNetwork() { wsSend({ action: 'network_info' }); }

function renderNetwork(ifaces) {
  const tbody = document.getElementById('net-tbody');
  if (!ifaces || !ifaces.length) {
    tbody.innerHTML = '<tr><td colspan="4" class="loading">No interfaces</td></tr>';
    return;
  }
  tbody.innerHTML = ifaces.map(i => `<tr>
    <td>${esc(i.name)}</td>
    <td>${esc((i.addresses || []).join(', ') || '—')}</td>
    <td>${i.state === 'UP'
      ? '<span class="badge badge-green">UP</span>'
      : '<span class="badge badge-red">' + esc(i.state || 'DOWN') + '</span>'}</td>
    <td>${esc(i.mtu || '—')}</td>
  </tr>`).join('');
}

// ── Install Wizard ─────────────────────────────────────────────────────────────

function selectTemplate(el) {
  document.querySelectorAll('.tmpl-card').forEach(c => c.classList.remove('selected'));
  el.classList.add('selected');
  wizSelected.template = el.dataset.tmpl;
}

function selectDisk(el) {
  document.querySelectorAll('.disk-card').forEach(c => c.classList.remove('selected'));
  el.classList.add('selected');
  wizSelected.disk = el.dataset.disk;
}

function wizStep(n) {
  // Validate before advancing
  if (n === 3 && !wizSelected.disk) {
    alert('Please select a target disk.');
    return;
  }
  if (n === 5) {
    const p  = v('inst-pass');
    const p2 = v('inst-pass2');
    if (!v('inst-hostname')) { alert('Hostname is required.'); return; }
    if (!v('inst-user'))     { alert('Username is required.'); return; }
    if (!p)                  { alert('Password is required.'); return; }
    if (p !== p2)            { alert('Passwords do not match.'); return; }
    buildConfirmSummary();
  }

  // Update panes
  document.querySelectorAll('.wizard-pane').forEach(p => p.classList.remove('active'));
  const pane = document.getElementById(`wpane-${n}`);
  if (pane) pane.classList.add('active');

  // Update step indicators
  document.querySelectorAll('.step').forEach((s, i) => {
    s.classList.remove('active', 'done');
    const stepNum = i / 2 + 1; // steps are every other element (separated by step-line divs)
  });
  // Re-query only the .step elements (not .step-line)
  const steps = document.querySelectorAll('.wizard-steps .step');
  steps.forEach((s, i) => {
    const num = i + 1;
    if (num < n)       s.classList.add('done');
    else if (num === n) s.classList.add('active');
  });
}

function buildConfirmSummary() {
  const box = document.getElementById('confirm-summary');
  if (!box) return;
  const nvidia = document.getElementById('inst-nvidia');
  const ebpf   = document.getElementById('inst-ebpf');
  const enc    = document.getElementById('inst-encryption');
  box.innerHTML = `
    <table class="data-table">
      <tr><th>Template</th><td>${esc(wizSelected.template)}</td></tr>
      <tr><th>Disk</th><td>${esc(wizSelected.disk || '—')}</td></tr>
      <tr><th>Hostname</th><td>${esc(v('inst-hostname'))}</td></tr>
      <tr><th>Timezone</th><td>${esc(v('inst-tz'))}</td></tr>
      <tr><th>Username</th><td>${esc(v('inst-user'))}</td></tr>
      <tr><th>ZFS root</th><td>yes (always)</td></tr>
      <tr><th>Encryption</th><td>${enc && enc.checked ? 'yes' : 'no'}</td></tr>
      <tr><th>NVIDIA</th><td>${nvidia && nvidia.checked ? 'yes' : 'no'}</td></tr>
      <tr><th>eBPF</th><td>${ebpf && ebpf.checked ? 'yes' : 'no'}</td></tr>
    </table>`;
}

function refreshDisks() { wsSend({ action: 'list_disks' }); }

function renderDisks(disks) {
  const grid = document.getElementById('disk-cards');
  if (!grid) return;
  if (!disks || !disks.length) {
    grid.innerHTML = '<div class="loading">No disks found</div>';
    return;
  }
  grid.innerHTML = disks.map(d => {
    const removableBadge = d.removable
      ? '<span class="badge badge-yellow">removable</span>'
      : '';
    const selected = wizSelected.disk === d.name ? ' selected' : '';
    return `<div class="disk-card${selected}" data-disk="${esc(d.name)}" onclick="selectDisk(this)">
      <div class="disk-name">${esc(d.name)}</div>
      <div class="disk-size">${esc(d.size)}</div>
      <div class="disk-model">${esc(d.model || '')} ${removableBadge}</div>
    </div>`;
  }).join('');
}

function runInstall() {
  const desktopTemplates = ['desktop'];
  const params = {
    KLDLOAD_DISK:           wizSelected.disk,
    KLDLOAD_TEMPLATE:       wizSelected.template,
    KLDLOAD_PROFILE:        desktopTemplates.includes(wizSelected.template) ? 'desktop' : 'server',
    KLDLOAD_HOSTNAME:       v('inst-hostname'),
    KLDLOAD_USERNAME:       v('inst-user'),
    KLDLOAD_PASSWORD:       v('inst-pass'),
    KLDLOAD_ROOT_PASSWORD:  v('inst-rootpass') || v('inst-pass'),
    KLDLOAD_TIMEZONE:       v('inst-tz') || 'UTC',
    KLDLOAD_SUITE:          'trixie',
    KLDLOAD_STORAGE_MODE:   'zfs',
    KLDLOAD_ENABLE_ZFS:     '1',
    KLDLOAD_ENABLE_NVIDIA:  document.getElementById('inst-nvidia').checked    ? '1' : '0',
    KLDLOAD_ENABLE_EBPF:    document.getElementById('inst-ebpf').checked      ? '1' : '0',
    KLDLOAD_ENCRYPTION:     document.getElementById('inst-encryption').checked ? '1' : '0',
  };

  show('install-progress');
  const logEl = document.getElementById('install-log');
  if (logEl) { logEl.textContent = ''; logEl.classList.remove('hidden'); }

  wsSend({ action: 'install', params, _target: 'install' });
}

// ── Golden Images ─────────────────────────────────────────────────────────────

function loadGoldenStatus() { wsSend({ action: 'golden_status' }); }

function renderGoldenStatus(status) {
  if (!status) return;
  ['master', 'kvm', 'storage', 'vdi'].forEach(tmpl => {
    const el = document.getElementById(`gst-${tmpl}`);
    if (!el) return;
    const s = status[tmpl];
    if (!s) { el.textContent = 'not built'; return; }
    el.innerHTML = s.exists
      ? `<span class="badge badge-green">ready</span> ${esc(s.size || '')}`
      : '<span class="badge badge-red">not built</span>';
  });
}

function buildGolden(tmpl) {
  const logEl = document.getElementById('golden-log');
  if (logEl) { logEl.textContent = ''; logEl.classList.remove('hidden'); }
  wsSend({ action: 'golden', template: tmpl, _target: 'golden' });
}

function stampGolden(tmpl) {
  const count = prompt(`How many clones to stamp from ${tmpl}?`, '1');
  if (!count || isNaN(count)) return;
  const logEl = document.getElementById('golden-log');
  if (logEl) { logEl.textContent = ''; logEl.classList.remove('hidden'); }
  wsSend({ action: 'stamp', template: tmpl, count: parseInt(count, 10), _target: 'golden' });
}

// ── Spawn ─────────────────────────────────────────────────────────────────────

function runSpawn() {
  const params = {
    type:     v('sp-type'),
    template: v('sp-template'),
    host:     v('sp-host'),
    name:     v('sp-name'),
    count:    v('sp-count'),
    cpu:      v('sp-cpu'),
    ram:      v('sp-ram'),
    disk:     v('sp-disk'),
  };
  const logEl = document.getElementById('spawn-log');
  if (logEl) { logEl.textContent = ''; logEl.classList.remove('hidden'); }
  wsSend({ action: 'spawn', params, _target: 'spawn' });
}

// ── VMs ───────────────────────────────────────────────────────────────────────

function loadVMs() { wsSend({ action: 'list_vms' }); }

function renderVMs(vms) {
  const tbody = document.getElementById('vm-tbody');
  if (!vms || !vms.length) {
    tbody.innerHTML = '<tr><td colspan="5" class="loading">No VMs found</td></tr>';
    return;
  }
  tbody.innerHTML = vms.map(vm => {
    const badge = vm.state === 'running'
      ? '<span class="badge badge-green">running</span>'
      : `<span class="badge badge-red">${esc(vm.state)}</span>`;
    return `<tr>
      <td>${esc(vm.name)}</td>
      <td>${badge}</td>
      <td>${esc(vm.vcpus || '—')}</td>
      <td>${esc(vm.ram   || '—')}</td>
      <td class="btn-row" style="padding:4px 12px">
        <button class="btn-secondary btn-sm" onclick="vmOp('${esc(vm.name)}','start')">Start</button>
        <button class="btn-secondary btn-sm" onclick="vmOp('${esc(vm.name)}','stop')">Stop</button>
        <button class="btn-secondary btn-sm" onclick="vmOp('${esc(vm.name)}','force-stop')">Kill</button>
        <button class="btn-secondary btn-sm" onclick="vmClone('${esc(vm.name)}')">Clone</button>
        <button class="btn-secondary btn-sm" onclick="vmReplace('${esc(vm.name)}')">Replace</button>
        <button class="btn-danger btn-sm"    onclick="vmOp('${esc(vm.name)}','delete')">Delete</button>
      </td>
    </tr>`;
  }).join('');
}

function vmOp(name, op) {
  wsSend({ action: 'vm_op', vm: name, op });
}

// ── ZFS ───────────────────────────────────────────────────────────────────────

function loadZFS() { wsSend({ action: 'zfs_list' }); }

function renderZFS(msg) {
  const pb = document.getElementById('pool-tbody');
  pb.innerHTML = (msg.pools || []).map(p => {
    const pct     = p.use_pct != null ? p.use_pct : usePct(p.alloc, p.size);
    const barCls  = pct >= 85 ? 'crit' : pct >= 70 ? 'warn' : '';
    return `<tr>
      <td>${esc(p.name)}</td>
      <td>${esc(p.size)}</td>
      <td>${esc(p.alloc)}</td>
      <td>${esc(p.free)}</td>
      <td>${healthBadge(p.health)}</td>
      <td><div class="usage-bar"><div class="usage-fill ${barCls}" style="width:${pct}%"></div></div><span class="usage-pct">${pct}%</span></td>
    </tr>`;
  }).join('') || '<tr><td colspan="6" class="loading">No pools</td></tr>';

  const db = document.getElementById('ds-tbody');
  db.innerHTML = (msg.datasets || []).map(d =>
    `<tr>
      <td>${esc(d.name)}</td>
      <td>${esc(d.used)}</td>
      <td>${esc(d.avail)}</td>
      <td>${esc(d.refer)}</td>
      <td>${esc(d.mountpoint)}</td>
    </tr>`
  ).join('') || '<tr><td colspan="5" class="loading">No datasets</td></tr>';
}

function healthBadge(h) {
  if (!h) return '<span class="badge badge-yellow">?</span>';
  const cls = h === 'ONLINE' ? 'badge-green' : h === 'DEGRADED' ? 'badge-yellow' : 'badge-red';
  return `<span class="badge ${cls}">${esc(h)}</span>`;
}

function usePct(alloc, total) {
  // parse human sizes like "4.5G", "512M"
  function toBytes(s) {
    if (!s) return 0;
    const m = String(s).match(/^([\d.]+)\s*([KMGTP]?)/i);
    if (!m) return 0;
    const units = { '': 1, K: 1024, M: 1024**2, G: 1024**3, T: 1024**4, P: 1024**5 };
    return parseFloat(m[1]) * (units[m[2].toUpperCase()] || 1);
  }
  const a = toBytes(alloc), t = toBytes(total);
  if (!t) return 0;
  return Math.round((a / t) * 100);
}

// ── Kubernetes ────────────────────────────────────────────────────────────────

function loadK8s() { wsSend({ action: 'k8s_nodes' }); }

function renderK8s(nodes) {
  const tbody = document.getElementById('k8s-tbody');
  if (!nodes || !nodes.length) {
    setText('k8s-node-count',  '0');
    setText('k8s-ready-count', '0');
    setText('k8s-api',  '—');
    setText('k8s-ver',  '—');
    tbody.innerHTML = '<tr><td colspan="5" class="loading">No nodes — cluster not running?</td></tr>';
    return;
  }
  const ready = nodes.filter(n => n.status === 'Ready').length;
  setText('k8s-node-count',  nodes.length);
  setText('k8s-ready-count', ready);
  setText('k8s-api',  nodes[0]?.api_server || '—');
  setText('k8s-ver',  nodes[0]?.version    || '—');

  tbody.innerHTML = nodes.map(n =>
    `<tr>
      <td>${esc(n.name)}</td>
      <td>${n.role === 'control-plane'
        ? '<span class="badge badge-blue">CP</span>'
        : '<span class="badge">worker</span>'}</td>
      <td>${n.status === 'Ready'
        ? '<span class="badge badge-green">Ready</span>'
        : '<span class="badge badge-red">' + esc(n.status) + '</span>'}</td>
      <td>${esc(n.version || '—')}</td>
      <td class="mono">${esc(n.wg2_ip || '—')}</td>
    </tr>`
  ).join('');
}

function runJoin(role) {
  nav('logs');
  wsSend({ action: 'k8s_join', role, _target: 'log' });
}

// ── Salt ─────────────────────────────────────────────────────────────────────

function loadSalt() { wsSend({ action: 'salt_status' }); }

function renderSalt(minions, pending) {
  const online  = (minions || []).filter(m => m.online).length;
  const offline = (minions || []).length - online;
  setText('salt-online',  online);
  setText('salt-offline', offline);
  setText('salt-pending', pending != null ? pending : '—');

  const tbody = document.getElementById('salt-tbody');
  if (!minions || !minions.length) {
    tbody.innerHTML = '<tr><td colspan="5" class="loading">No minions — Salt master not running?</td></tr>';
    return;
  }
  tbody.innerHTML = minions.map(m =>
    `<tr>
      <td>${esc(m.host)}</td>
      <td>${esc(m.role || '—')}</td>
      <td class="mono">${esc(m.wg1_ip || '—')}</td>
      <td>${esc(m.node_index != null ? m.node_index : '—')}</td>
      <td>${m.online
        ? '<span class="badge badge-green">online</span>'
        : '<span class="badge badge-red">offline</span>'}</td>
    </tr>`
  ).join('');
}

function saltHighstate() {
  nav('logs');
  wsSend({ action: 'salt_highstate', target: '*', _target: 'log' });
}

function saltAcceptAll() {
  wsSend({ action: 'salt_accept_all' });
  setTimeout(loadSalt, 2000);
}

// ── Logs ──────────────────────────────────────────────────────────────────────

function loadLog() {
  const log = v('log-select');
  wsSend({ action: 'tail_log', log });
}

function renderLog(lines) {
  const el = document.getElementById('log-content');
  if (!el) return;
  el.textContent = (lines || []).join('\n');
  el.scrollTop = el.scrollHeight;
}

function clearLogView() {
  const el = document.getElementById('log-content');
  if (el) el.textContent = '';
}

// ── Exec log helpers ──────────────────────────────────────────────────────────

function _logEl(target) {
  const map = {
    install: 'install-log',
    spawn:   'spawn-log',
    golden:  'golden-log',
    log:     'log-content',
  };
  return document.getElementById(map[target] || 'log-content');
}

function clearExecLog(target) {
  const el = _logEl(target);
  if (el) el.textContent = '';
}

function appendLog(line, target) {
  const el = _logEl(target);
  if (!el) return;
  el.classList.remove('hidden');
  el.textContent += line + '\n';
  el.scrollTop = el.scrollHeight;
}

function doneExecLog(rc, target) {
  const el = _logEl(target);
  if (!el) return;
  el.textContent += rc === 0 ? '\n✓ Done (exit 0)\n' : `\n✗ Failed (exit ${rc})\n`;
  el.scrollTop = el.scrollHeight;
}

// ── Utilities ─────────────────────────────────────────────────────────────────

function v(id) {
  const el = document.getElementById(id);
  return el ? el.value : '';
}

function setText(id, text) {
  const el = document.getElementById(id);
  if (el) el.textContent = text;
}

function show(id) {
  const el = document.getElementById(id);
  if (el) el.classList.remove('hidden');
}

function hide(id) {
  const el = document.getElementById(id);
  if (el) el.classList.add('hidden');
}

function toggle(id) {
  const el = document.getElementById(id);
  if (el) el.classList.toggle('hidden');
}

function esc(str) {
  if (str == null) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// ── Nodes (fleet view) ────────────────────────────────────────────────────────

let _nodeApplyTarget = '';

function loadNodes() { wsSend({ action: 'node_list' }); }
function mineRefresh() { wsSend({ action: 'mine_refresh', target: '*', _target: 'log' }); }

function renderNodeList(nodes, pending) {
  if (!nodes) return;

  const online  = nodes.filter(n => n.online).length;
  const offline = nodes.length - online;
  setText('nodes-online',        online);
  setText('nodes-offline',       offline);
  setText('nodes-pending-count', pending ? pending.length : 0);

  // Pending key section
  const pendSec  = document.getElementById('nodes-pending-section');
  const pendList = document.getElementById('nodes-pending-list');
  if (pending && pending.length) {
    pendSec.style.display = '';
    pendList.innerHTML = pending.map(name => `
      <div class="pending-item">
        <span class="mono">${esc(name)}</span>
        <button class="btn-primary btn-xs" onclick="nodeAcceptKey('${esc(name)}')">Accept</button>
      </div>`).join('');
  } else {
    pendSec.style.display = 'none';
  }

  const tbody = document.getElementById('nodes-tbody');
  if (!nodes.length) {
    tbody.innerHTML = '<tr><td colspan="10" class="loading">No enrolled nodes — pending keys will appear above</td></tr>';
    return;
  }

  tbody.innerHTML = nodes.map(n => {
    const statusBadge = n.online
      ? '<span class="badge badge-green">online</span>'
      : '<span class="badge badge-red">offline</span>';
    const colorBadge = n.color === 'green'
      ? '<span class="badge badge-green">green</span>'
      : n.color === 'blue'
        ? '<span class="badge badge-blue">blue</span>'
        : '<span class="badge badge-muted">—</span>';
    return `<tr>
      <td class="mono">${esc(n.host)}</td>
      <td>${esc(n.role) || '—'}</td>
      <td>${colorBadge}</td>
      <td class="mono">${esc(n.index) || '—'}</td>
      <td class="mono ip-cell">${esc(n.wg0) || '—'}</td>
      <td class="mono ip-cell">${esc(n.wg1) || '—'}</td>
      <td class="mono ip-cell">${esc(n.wg2) || '—'}</td>
      <td class="mono ip-cell">${esc(n.wg3) || '—'}</td>
      <td>${statusBadge}</td>
      <td><button class="btn-secondary btn-xs" onclick="openApplyPanel('${esc(n.host)}')">Apply State</button></td>
    </tr>`;
  }).join('');
}

function openApplyPanel(host) {
  _nodeApplyTarget = host;
  setText('node-apply-target', host);
  const panel = document.getElementById('node-apply-panel');
  if (panel) panel.style.display = '';
  const inp = document.getElementById('node-apply-state');
  if (inp) { inp.value = ''; inp.focus(); }
  const log = document.getElementById('node-apply-log');
  if (log) { log.textContent = ''; log.style.display = 'none'; }
}

function closeApplyPanel() {
  const panel = document.getElementById('node-apply-panel');
  if (panel) panel.style.display = 'none';
  _nodeApplyTarget = '';
}

function nodeApplyState() {
  const state = (document.getElementById('node-apply-state') || {}).value || '';
  if (!_nodeApplyTarget || !state) return;
  const log = document.getElementById('node-apply-log');
  if (log) { log.textContent = ''; log.style.display = ''; }
  wsSend({ action: 'node_apply', target: _nodeApplyTarget, state, _target: 'node-apply-log' });
}

function nodeAcceptKey(name) {
  wsSend({ action: 'node_accept_key', name });
}

// ── Audit ─────────────────────────────────────────────────────────────────────

function runAudit() {
  const results = document.getElementById('audit-results');
  const summary = document.getElementById('audit-summary');
  const logBox  = document.getElementById('audit-log-box');
  if (results) results.innerHTML = '<div class="audit-running">Running audit… this takes a few seconds.</div>';
  if (summary) summary.classList.add('hidden');
  if (logBox)  logBox.classList.add('hidden');
  wsSend({ action: 'run_audit' });
}

function viewAuditLog() {
  const logBox = document.getElementById('audit-log-box');
  if (!logBox) return;
  const isHidden = logBox.classList.contains('hidden');
  if (isHidden) {
    logBox.classList.remove('hidden');
    wsSend({ action: 'tail_log', log: 'audit' });
  } else {
    logBox.classList.add('hidden');
  }
}

function renderAuditStarted() {
  const el = document.getElementById('audit-results');
  if (el) el.innerHTML = '<div class="audit-running">&#9654; Audit running — scanning packages, binaries, services…</div>';
}

function renderAuditDone(msg) {
  const results  = msg.results  || [];
  const summary  = msg.summary  || {};
  const rc       = msg.rc;

  // Summary bar
  const sumEl = document.getElementById('audit-summary');
  if (sumEl) {
    sumEl.classList.remove('hidden');
    const p = document.getElementById('audit-pass');
    const f = document.getElementById('audit-fail');
    const s = document.getElementById('audit-skip');
    if (p) p.textContent = `${summary.pass || 0} PASS`;
    if (f) { f.textContent = `${summary.fail || 0} FAIL`; f.className = `audit-stat ${summary.fail ? 'fail' : 'pass'}`; }
    if (s) s.textContent = `${summary.skip || 0} SKIP`;
  }

  // Group by category
  const byCategory = {};
  for (const r of results) {
    const cat = r.category || 'misc';
    if (!byCategory[cat]) byCategory[cat] = [];
    byCategory[cat].push(r);
  }

  const container = document.getElementById('audit-results');
  if (!container) return;
  let html = '';

  const cats = Object.keys(byCategory).sort();
  for (const cat of cats) {
    const rows = byCategory[cat];
    const catFail = rows.filter(r => r.status === 'FAIL').length;
    const catLabel = catFail > 0 ? `${cat} <span class="audit-cat-fail">${catFail} failed</span>` : cat;
    html += `<div class="audit-category">`;
    html += `<div class="audit-cat-header">${catLabel}</div>`;
    html += `<table class="audit-table">`;
    for (const r of rows) {
      const cls = r.status === 'PASS' ? 'pass' : r.status === 'FAIL' ? 'fail' : 'skip';
      const icon = r.status === 'PASS' ? '✓' : r.status === 'FAIL' ? '✗' : '–';
      const detail = r.detail ? `<span class="audit-detail">${escHtml(r.detail)}</span>` : '';
      html += `<tr class="audit-row ${cls}">
        <td class="audit-icon">${icon}</td>
        <td class="audit-name">${escHtml(r.name)}</td>
        <td class="audit-det">${detail}</td>
      </tr>`;
    }
    html += `</table></div>`;
  }

  if (!html) {
    html = rc === 0
      ? '<div class="audit-running ok">All checks passed.</div>'
      : '<div class="audit-running fail">No results returned — check audit log.</div>';
  }
  container.innerHTML = html;
}

function escHtml(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

// ── Cluster Deploy ────────────────────────────────────────────────────────────

function cdInit() {
  // nothing to load on view entry; tabs handle it
}

function cdTab(name, btn) {
  document.querySelectorAll('.tab-bar .tab').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  document.getElementById('cd-pane-scc').style.display = name === 'scc' ? '' : 'none';
  document.getElementById('cd-pane-k8s').style.display = name === 'k8s' ? '' : 'none';
}

function cdDeploy(type) {
  const host    = document.getElementById('cd-pve-host')?.value.trim();
  const node    = document.getElementById('cd-pve-node')?.value.trim();
  const tokenId = document.getElementById('cd-pve-token-id')?.value.trim();
  const tokenSec= document.getElementById('cd-pve-token-secret')?.value.trim();

  if (!host || !tokenId || !tokenSec) {
    alert('Proxmox host, token ID, and token secret are required.');
    return;
  }

  const isoName = document.getElementById('cd-iso-name')?.value.trim() || '';

  let lanCidr, domain, cmd;
  if (type === 'scc') {
    lanCidr = document.getElementById('cd-scc-lan-cidr')?.value.trim() || '192.168.0.0/16';
    domain  = document.getElementById('cd-scc-domain')?.value.trim()   || 'cluster.kldload';
    cmd     = 'scc';
  } else {
    lanCidr = document.getElementById('cd-k8s-lan-cidr')?.value.trim() || '192.168.0.0/16';
    domain  = document.getElementById('cd-k8s-domain')?.value.trim()   || 'cluster.kldload';
    cmd     = 'k8s-ha';
  }

  const label = type === 'scc' ? 'SCC (6 nodes)' : 'k8s-ha (14 nodes)';
  if (!confirm(`Start ${label} cluster deploy?\n\nProxmox: ${host}\nThis will create/replace VMs and takes 30–120 minutes.`)) return;

  const logWrap = document.getElementById('cd-log-wrap');
  const logEl   = document.getElementById('cd-log');
  const doneEl  = document.getElementById('cd-done-msg');
  const titleEl = document.getElementById('cd-log-title');
  if (logWrap) logWrap.style.display = '';
  if (logEl)   logEl.textContent = '';
  if (doneEl)  doneEl.style.display = 'none';
  if (titleEl) titleEl.textContent = `Deploying ${label}…`;

  wsSend({
    action:       'cluster_deploy',
    cmd:          cmd,
    proxmox_host: host,
    proxmox_node: node,
    token_id:     tokenId,
    token_secret: tokenSec,
    iso_name:     isoName,
    lan_cidr:     lanCidr,
    cluster_domain: domain,
    node_targets: _cdNodeTargets,
    _target:      'cluster-deploy',
  });
}

// cluster_deploy log lines route to the cd-log box
function appendClusterLog(line) {
  const el = document.getElementById('cd-log');
  if (!el) return;
  el.textContent += line + '\n';
  el.scrollTop = el.scrollHeight;
}

// ── Credentials ───────────────────────────────────────────────────────────────
let _credData = { proxmox: [], aws: {}, azure: {}, gcp: {}, ssh: [] };

function credLoad() { wsSend({ action: 'credentials_load' }); }

function credAddProxmox() {
  const id = 'px-' + Date.now();
  _credData.proxmox.push({ id, host: '', port: 8006, node: 'pve', token_id: '', token_secret: '' });
  credRender();
}

function credAddSSH() {
  _credData.ssh.push({ id: 'ssh-' + Date.now(), host: '', user: 'root', key_path: '/root/.ssh/id_ed25519', label: '' });
  credRender();
}

function credRemove(type, id) {
  _credData[type] = _credData[type].filter(x => x.id !== id);
  credRender();
}

function credRender() {
  const pxEl = document.getElementById('cred-proxmox-list');
  if (pxEl) pxEl.innerHTML = _credData.proxmox.map(p => `
    <div class="cred-card" data-id="${esc(p.id)}">
      <div class="cred-card-head">
        <span class="cred-card-title">${esc(p.host || 'new host')}</span>
        <button class="btn-xs btn-danger" onclick="credRemove('proxmox','${esc(p.id)}')">remove</button>
        <button class="btn-xs" onclick="credTest('proxmox','${esc(p.id)}')">test</button>
      </div>
      <div class="cred-form">
        <div class="cred-row"><label>Host</label><input type="text" value="${esc(p.host)}" oninput="credUpdate('proxmox','${esc(p.id)}','host',this.value)" placeholder="10.0.0.1"/></div>
        <div class="cred-row"><label>Port</label><input type="number" value="${p.port||8006}" oninput="credUpdate('proxmox','${esc(p.id)}','port',this.value)" style="width:80px"/></div>
        <div class="cred-row"><label>Node</label><input type="text" value="${esc(p.node)}" oninput="credUpdate('proxmox','${esc(p.id)}','node',this.value)" placeholder="pve"/></div>
        <div class="cred-row"><label>Token ID</label><input type="text" value="${esc(p.token_id)}" oninput="credUpdate('proxmox','${esc(p.id)}','token_id',this.value)" placeholder="root@pam!kldload"/></div>
        <div class="cred-row"><label>Token Secret</label><input type="password" value="${esc(p.token_secret)}" oninput="credUpdate('proxmox','${esc(p.id)}','token_secret',this.value)" placeholder="••••••••"/></div>
        <div class="cred-row"><label>Label</label><input type="text" value="${esc(p.label||'')}" oninput="credUpdate('proxmox','${esc(p.id)}','label',this.value)" placeholder="home-lab"/></div>
      </div>
      <div id="test-result-${esc(p.id)}" class="cred-test-result"></div>
    </div>`).join('');

  const sshEl = document.getElementById('cred-ssh-list');
  if (sshEl) sshEl.innerHTML = _credData.ssh.map(s => `
    <div class="cred-card" data-id="${esc(s.id)}">
      <div class="cred-card-head">
        <span class="cred-card-title">${esc(s.label || s.host || 'new host')}</span>
        <button class="btn-xs btn-danger" onclick="credRemove('ssh','${esc(s.id)}')">remove</button>
      </div>
      <div class="cred-form">
        <div class="cred-row"><label>Host</label><input type="text" value="${esc(s.host)}" oninput="credUpdate('ssh','${esc(s.id)}','host',this.value)"/></div>
        <div class="cred-row"><label>User</label><input type="text" value="${esc(s.user)}" oninput="credUpdate('ssh','${esc(s.id)}','user',this.value)"/></div>
        <div class="cred-row"><label>Key Path</label><input type="text" value="${esc(s.key_path)}" oninput="credUpdate('ssh','${esc(s.id)}','key_path',this.value)"/></div>
        <div class="cred-row"><label>Label</label><input type="text" value="${esc(s.label)}" oninput="credUpdate('ssh','${esc(s.id)}','label',this.value)"/></div>
      </div>
    </div>`).join('');

  // Flat fields
  const aws = _credData.aws || {};
  const az  = _credData.azure || {};
  const gcp = _credData.gcp || {};
  sv('cred-aws-key',    aws.key    || '');
  sv('cred-aws-secret', aws.secret || '');
  sv('cred-aws-region', aws.region || '');
  sv('cred-az-sub',    az.subscription_id || '');
  sv('cred-az-tenant', az.tenant_id       || '');
  sv('cred-az-client', az.client_id       || '');
  sv('cred-az-secret', az.client_secret   || '');
  sv('cred-az-rg',     az.resource_group  || '');
  sv('cred-gcp-project', gcp.project_id || '');
  sv('cred-gcp-sa',      gcp.service_account_json || '');

  cdPopulateTargets();
}

function sv(id, val) { const el = document.getElementById(id); if (el) el.value = val; }

function credUpdate(type, id, field, val) {
  const item = _credData[type].find(x => x.id === id);
  if (item) item[field] = val;
}

function credTest(provider, id) {
  wsSend({ action: 'credentials_test', provider, id });
}

function credSave() {
  _credData.aws   = { key: v('cred-aws-key'), secret: v('cred-aws-secret'), region: v('cred-aws-region') };
  _credData.azure = { subscription_id: v('cred-az-sub'), tenant_id: v('cred-az-tenant'),
                      client_id: v('cred-az-client'), client_secret: v('cred-az-secret'),
                      resource_group: v('cred-az-rg') };
  _credData.gcp   = { project_id: v('cred-gcp-project'), service_account_json: v('cred-gcp-sa') };
  wsSend({ action: 'credentials_save', creds: _credData });
}

// ── WireGuard user planes ─────────────────────────────────────────────────────

function wgShowAddPlane() { toggle('wg-add-plane-form'); }

function wgCreatePlane() {
  wsSend({ action: 'wg_plane_create',
    label:  v('wgp-label'),
    subnet: v('wgp-subnet'),
    port:   parseInt(v('wgp-port')) || 51824,
  });
}

function wgDeletePlane(iface) {
  if (!confirm(`Delete ${iface}?`)) return;
  wsSend({ action: 'wg_plane_delete', iface });
}

function renderWgPlanes(planes) {
  const el = document.getElementById('wg-user-plane-list');
  if (!el) return;
  const user = planes.filter(p => !p.fixed);
  el.innerHTML = user.length === 0
    ? '<div class="wg-empty">No custom planes defined.</div>'
    : user.map(p => `
      <div class="wg-user-plane-card">
        <div class="wup-iface">${esc(p.iface)}</div>
        <div class="wup-label">${esc(p.role)}</div>
        <div class="wup-subnet">${esc(p.subnet)}</div>
        <div class="wup-port">:${p.port}</div>
        <button class="btn-xs btn-danger" onclick="wgDeletePlane('${esc(p.iface)}')">delete</button>
      </div>`).join('');
}

// ── Cluster Deploy multi-target ───────────────────────────────────────────────

const _cdNodeTargets = {};

function cdSetTarget(node, credId) {
  if (credId) _cdNodeTargets[node] = credId;
  else delete _cdNodeTargets[node];
}

function cdPopulateTargets() {
  // Populate all .cnode-target selects with Proxmox hosts from credentials
  const hosts = (_credData.proxmox || []);
  document.querySelectorAll('.cnode-target').forEach(sel => {
    const node = sel.dataset.node;
    const cur  = _cdNodeTargets[node] || '';
    sel.innerHTML = '<option value="">default</option>' +
      hosts.map(p => `<option value="${esc(p.id)}" ${p.id===cur?'selected':''}>${esc(p.label||p.host)}</option>`).join('');
  });
}

// ── Boot ──────────────────────────────────────────────────────────────────────

wsConnect();

// Auto-refresh dashboard every 30 s
setInterval(() => { if (wsReady) wsSend({ action: 'system_info' }); }, 30000);

// ══ POOL DESIGNER ══════════════════════════════════════════════════════════

const PD = {
  drives: [],
  selected_topo: null,
  vdevs: [],
  slog: [],
  l2arc: [],
};

const PD_MOCK_DRIVES = [
  { id:'nvme0', dev:'nvme0n1', model:'Intel P5520',  size:'1.6 TB', bytes:1.6e12,  type:'nvme', health:'OK' },
  { id:'nvme1', dev:'nvme1n1', model:'Intel P5520',  size:'1.6 TB', bytes:1.6e12,  type:'nvme', health:'OK' },
  { id:'sda',   dev:'sda',     model:'Samsung 870 EVO', size:'1.92 TB', bytes:1.92e12, type:'ssd', health:'OK' },
  { id:'sdb',   dev:'sdb',     model:'Samsung 870 EVO', size:'1.92 TB', bytes:1.92e12, type:'ssd', health:'OK' },
  { id:'sdc',   dev:'sdc',     model:'WD Gold 20TB', size:'20 TB',  bytes:20e12,   type:'hdd', health:'OK' },
  { id:'sdd',   dev:'sdd',     model:'WD Gold 20TB', size:'20 TB',  bytes:20e12,   type:'hdd', health:'OK' },
  { id:'sde',   dev:'sde',     model:'WD Gold 20TB', size:'20 TB',  bytes:20e12,   type:'hdd', health:'OK' },
  { id:'sdf',   dev:'sdf',     model:'WD Gold 20TB', size:'20 TB',  bytes:20e12,   type:'hdd', health:'OK' },
  { id:'sdg',   dev:'sdg',     model:'WD Gold 20TB', size:'20 TB',  bytes:20e12,   type:'hdd', health:'OK' },
  { id:'sdh',   dev:'sdh',     model:'WD Gold 20TB', size:'20 TB',  bytes:20e12,   type:'hdd', health:'OK' },
  { id:'sdi',   dev:'sdi',     model:'WD Gold 20TB', size:'20 TB',  bytes:20e12,   type:'hdd', health:'OK' },
  { id:'sdj',   dev:'sdj',     model:'WD Gold 20TB', size:'20 TB',  bytes:20e12,   type:'hdd', health:'OK' },
];

function pdInit() {
  // Use live detection if available, fall back to mock
  fetch('/api/drives').then(r=>r.json()).then(data=>{
    PD.drives = data.drives || PD_MOCK_DRIVES;
    pdRender();
  }).catch(()=>{
    PD.drives = PD_MOCK_DRIVES;
    pdRender();
  });
}

function pdScanDrives() { pdInit(); }

function pdRender() {
  pdRenderShelf();
  pdRenderTopos();
  pdApplyTopo(PD.selected_topo || pdDefaultTopo());
}

function pdDriveIcon(type) {
  if (type === 'nvme') return '▣';
  if (type === 'ssd')  return '◧';
  return '◫';
}

function pdRenderShelf() {
  const shelf = document.getElementById('pd-drive-shelf');
  const count = document.getElementById('pd-drive-count');
  if (!shelf) return;
  count.textContent = PD.drives.length + ' drives';
  shelf.innerHTML = PD.drives.map(d => {
    const assigned = PD.slog.find(x=>x.id===d.id) ? 'slog' :
                     PD.l2arc.find(x=>x.id===d.id) ? 'l2arc' :
                     PD.vdevs.flat().find(x=>x.id===d.id) ? 'assigned' : '';
    const vtag = PD.vdevs.findIndex(v=>v.find(x=>x.id===d.id));
    return `<div class="pd-drive ${assigned}" title="${d.dev}  ${d.model}  ${d.health}">
      ${vtag>=0 ? `<div class="pd-drive-vdev-tag">v${vtag}</div>` : ''}
      <div class="pd-drive-icon">${pdDriveIcon(d.type)}</div>
      <div class="pd-drive-size">${d.size}</div>
      <div class="pd-drive-model">${d.model}</div>
      <div class="pd-drive-type ${d.type}">${d.type.toUpperCase()}</div>
    </div>`;
  }).join('');
}

function pdGetHDDs()  { return PD.drives.filter(d=>d.type==='hdd'); }
function pdGetSSDs()  { return PD.drives.filter(d=>d.type==='ssd'); }
function pdGetNVMes() { return PD.drives.filter(d=>d.type==='nvme'); }

function pdDefaultTopo() {
  const n = pdGetHDDs().length;
  if (n >= 8) return 'draid2';
  if (n >= 6) return 'raidz2';
  if (n >= 4) return 'raidz1';
  return 'mirror';
}

function pdCalcUsable(n, parity, unitBytes) {
  const usable = (n - parity) * unitBytes;
  return pdFmtBytes(usable);
}

function pdFmtBytes(b) {
  if (b >= 1e15) return (b/1e15).toFixed(1)+' PB';
  if (b >= 1e12) return (b/1e12).toFixed(0)+' TB';
  if (b >= 1e9)  return (b/1e9).toFixed(0)+' GB';
  return b+' B';
}

function pdRenderTopos() {
  const hdds = pdGetHDDs();
  const n = hdds.length;
  const gb = hdds[0] ? hdds[0].bytes : 20e12;
  const raw = pdFmtBytes(n * gb);

  const topos = [];

  if (n >= 3) topos.push({
    id: 'raidz1',
    badge: n >= 6 ? 'warn' : 'rec',
    badgeText: n >= 6 ? 'LOW REDUNDANCY' : 'RECOMMENDED',
    name: 'RAIDZ1',
    desc: `${n-1} data + 1 parity`,
    usable: pdCalcUsable(n, 1, gb),
    raw,
    fault: '1 drive',
    seq: Math.round(n * 0.95 * 250) + ' MB/s',
  });

  if (n >= 4) topos.push({
    id: 'raidz2',
    badge: 'rec',
    badgeText: 'RECOMMENDED',
    name: 'RAIDZ2',
    desc: `${n-2} data + 2 parity`,
    usable: pdCalcUsable(n, 2, gb),
    raw,
    fault: '2 drives',
    seq: Math.round(n * 0.9 * 250) + ' MB/s',
  });

  if (n >= 6) topos.push({
    id: 'raidz3',
    badge: 'info',
    badgeText: 'MAX REDUNDANCY',
    name: 'RAIDZ3',
    desc: `${n-3} data + 3 parity`,
    usable: pdCalcUsable(n, 3, gb),
    raw,
    fault: '3 drives',
    seq: Math.round(n * 0.85 * 250) + ' MB/s',
  });

  if (n >= 2 && n % 2 === 0) topos.push({
    id: 'mirror',
    badge: 'info',
    badgeText: 'HIGH IOPS',
    name: `Mirror ×${n/2}`,
    desc: `${n/2} mirror vdevs of 2`,
    usable: pdCalcUsable(n, n/2, gb),
    raw,
    fault: '1 per vdev',
    seq: Math.round((n/2) * 2 * 250) + ' MB/s',
  });

  if (n >= 6) topos.push({
    id: 'draid2',
    badge: 'rec',
    badgeText: 'RECOMMENDED',
    name: 'dRAID2',
    desc: `distributed RAID-Z2 + spare`,
    usable: pdCalcUsable(n, 2 + 1, gb),
    raw,
    fault: '2 drives + spare',
    seq: Math.round(n * 0.88 * 250) + ' MB/s',
  });

  const sel = PD.selected_topo || pdDefaultTopo();
  const grid = document.getElementById('pd-topo-grid');
  if (!grid) return;
  grid.innerHTML = topos.map(t => `
    <div class="pd-topo-card ${t.badge==='rec'?'recommended':''} ${sel===t.id?'selected':''}"
         onclick="pdSelectTopo('${t.id}')">
      <div class="pd-topo-badge ${t.badge}">${t.badgeText}</div>
      <div class="pd-topo-name">${t.name}</div>
      <div class="pd-topo-desc">${t.desc}</div>
      <div class="pd-topo-stats">
        <div class="pd-topo-stat"><span class="k">Usable </span><span class="v">${t.usable}</span></div>
        <div class="pd-topo-stat"><span class="k">Fault  </span><span class="v">${t.fault}</span></div>
        <div class="pd-topo-stat"><span class="k">Raw    </span><span class="v">${t.raw}</span></div>
        <div class="pd-topo-stat"><span class="k">Seq R/W </span><span class="v">${t.seq}</span></div>
      </div>
    </div>`).join('');
}

function pdSelectTopo(id) {
  PD.selected_topo = id;
  pdApplyTopo(id);
  pdRenderTopos();
}

function pdApplyTopo(id) {
  const hdds = pdGetHDDs();
  const nvmes = pdGetNVMes();
  const ssds  = pdGetSSDs();
  PD.vdevs = [];
  PD.slog  = [];
  PD.l2arc = [];

  // Auto-assign NVMe to SLOG (mirror if 2+)
  if (nvmes.length >= 2) PD.slog = nvmes.slice(0,2);
  else if (nvmes.length === 1) PD.slog = nvmes.slice(0,1);

  // Auto-assign SSDs to L2ARC
  if (ssds.length > 0) PD.l2arc = ssds;

  const n = hdds.length;
  if (id === 'mirror' && n >= 2) {
    for (let i = 0; i < n; i += 2)
      PD.vdevs.push([hdds[i], hdds[i+1]].filter(Boolean));
  } else {
    PD.vdevs = [hdds];
  }

  PD.selected_topo = id;
  pdRenderCanvas(id);
  pdRenderSpecial();
  pdRenderSummary(id);
  pdRenderShelf();
}

function pdVdevTypeName(id, n) {
  if (id === 'raidz1') return 'RAIDZ1';
  if (id === 'raidz2') return 'RAIDZ2';
  if (id === 'raidz3') return 'RAIDZ3';
  if (id === 'mirror') return 'MIRROR';
  if (id === 'draid2') return 'dRAID2';
  return 'STRIPE';
}

function pdParityCount(id) {
  if (id === 'raidz1') return 1;
  if (id === 'raidz2') return 2;
  if (id === 'raidz3') return 3;
  if (id === 'mirror') return 1;
  if (id === 'draid2') return 2;
  return 0;
}

function pdRenderCanvas(id) {
  const canvas = document.getElementById('pd-canvas');
  if (!canvas) return;
  const parity = pdParityCount(id);
  canvas.innerHTML = PD.vdevs.map((drives, vi) => {
    const dp = Math.max(0, drives.length - parity);
    const drivesHtml = drives.map((d, i) => {
      const isParity = i >= dp;
      return `<div class="pd-vdev-drive ${isParity?'parity':''}">
        <div class="pd-vdev-drive-dot"></div>
        ${d.dev}
        ${isParity ? '<span style="font-size:9px;color:#7c4dff;margin-left:2px">P</span>' : ''}
      </div>`;
    }).join('');
    const usable = drives.length > parity
      ? pdFmtBytes((drives.length - parity) * (drives[0]?.bytes||20e12))
      : '—';
    return `<div class="pd-vdev-row">
      <div class="pd-vdev-label">vdev-${vi}</div>
      <div class="pd-vdev-type">${pdVdevTypeName(id, drives.length)}</div>
      <div class="pd-vdev-drives">${drivesHtml}</div>
      <div class="pd-vdev-usable">${usable} usable</div>
    </div>`;
  }).join('');
}

function pdRenderSpecial() {
  const slogEl   = document.getElementById('pd-slog-slots');
  const l2arcEl  = document.getElementById('pd-l2arc-slots');
  if (!slogEl || !l2arcEl) return;

  slogEl.innerHTML = PD.slog.length
    ? PD.slog.map(d=>`<div class="pd-svdev-chip slog">▣ ${d.dev} <span style="color:var(--text-dim)">${d.size}</span></div>`).join('')
    : '<span class="pd-drop-hint">none — sync writes go to pool</span>';

  l2arcEl.innerHTML = PD.l2arc.length
    ? PD.l2arc.map(d=>`<div class="pd-svdev-chip l2arc">◧ ${d.dev} <span style="color:var(--text-dim)">${d.size}</span></div>`).join('')
    : '<span class="pd-drop-hint">none</span>';
}

function pdRenderSummary(id) {
  const hdds   = pdGetHDDs();
  const parity = pdParityCount(id);
  const n      = hdds.length;
  const gb     = hdds[0] ? hdds[0].bytes : 20e12;

  const usableBytes = id === 'mirror'
    ? (n/2) * gb
    : Math.max(0, n - parity) * gb;

  const faultMap = {raidz1:'1 drive',raidz2:'2 drives',raidz3:'3 drives',mirror:'1 per vdev',draid2:'2 + spare',stripe:'none'};
  const seqMBs = id === 'mirror'
    ? Math.round((n/2)*2*250)
    : Math.round(n * 0.9 * 250);

  const set = (id, val, cls) => {
    const el = document.getElementById(id);
    if (!el) return;
    el.textContent = val;
    if (cls) el.className = 'pd-stat-val ' + cls;
  };
  set('pd-usable',     pdFmtBytes(usableBytes), 'accent');
  set('pd-raw',        pdFmtBytes(n * gb));
  set('pd-topo-label', pdVdevTypeName(id, n));
  set('pd-fault',      faultMap[id] || '?', 'green');
  set('pd-seq-iops',   seqMBs + ' MB/s');
}

function pdAddVdev() {
  // Placeholder — will open a drive picker in v2
  alert('Drive picker coming in v2. For now, use topology presets to auto-layout.');
}

function pdReset() {
  PD.selected_topo = null;
  PD.vdevs = [];
  PD.slog  = [];
  PD.l2arc = [];
  pdRender();
}

function pdApplyToInstall() {
  const id   = PD.selected_topo || pdDefaultTopo();
  const hdds = pdGetHDDs();
  const parity = pdParityCount(id);
  const disks = hdds.map(d=>d.dev);
  // Prefill the Install wizard disk step with our selection
  const topoMap = {raidz1:'raidz1',raidz2:'raidz2',raidz3:'raidz3',mirror:'mirror',draid2:'draid2'};
  window._pdConfig = { topology: topoMap[id]||'raidz2', disks };
  nav('install');
  // Show a toast
  setTimeout(()=>{
    const banner = document.createElement('div');
    banner.style.cssText='position:fixed;bottom:24px;right:24px;background:#0a1f14;border:1px solid var(--green);color:var(--green);padding:10px 18px;border-radius:5px;font-size:12px;z-index:999';
    banner.textContent = `✓ Pool layout applied: ${pdVdevTypeName(id,0)} · ${hdds.length} drives`;
    document.body.appendChild(banner);
    setTimeout(()=>banner.remove(), 3500);
  }, 200);
}

// ═══════════════════════════════════════════════════════════
// CLUSTER DESIGNER
// ═══════════════════════════════════════════════════════════

const CDS_ROLE_META = {
  firewall:          { icon: '🔥', label: 'Firewall',        color: 'role-fw',      defaultCpu: 2,  defaultRam: 4,  defaultDisk: 64   },
  master:                    { icon: '◈',  label: 'Cluster Manager', color: 'role-master',  defaultCpu: 4,  defaultRam: 8,  defaultDisk: 128  },
  'cluster-manager-desktop': { icon: '◈',  label: 'Cluster Manager', color: 'role-master',  defaultCpu: 4,  defaultRam: 8,  defaultDisk: 128  },
  'cluster-manager-server':  { icon: '◉',  label: 'Cluster Manager (Server)', color: 'role-master', defaultCpu: 2, defaultRam: 4, defaultDisk: 64 },
  compute:           { icon: '▣',  label: 'Compute',         color: 'role-compute', defaultCpu: 8,  defaultRam: 32, defaultDisk: 256  },
  storage:           { icon: '◧',  label: 'Storage',         color: 'role-storage', defaultCpu: 4,  defaultRam: 16, defaultDisk: 4096 },
  k8s:               { icon: '✦',  label: 'k8s Worker',      color: 'role-k8s',     defaultCpu: 8,  defaultRam: 16, defaultDisk: 256  },
  'k8s-worker':      { icon: '✦',  label: 'k8s Worker',      color: 'role-k8s',     defaultCpu: 8,  defaultRam: 16, defaultDisk: 256  },
  'k8s-control-plane':{ icon: '◈', label: 'k8s Control',    color: 'role-k8s',     defaultCpu: 4,  defaultRam: 16, defaultDisk: 128  },
  etcd:              { icon: '◉',  label: 'etcd',            color: 'role-k8s',     defaultCpu: 4,  defaultRam: 8,  defaultDisk: 32   },
  lb:                { icon: '⇌',  label: 'Load Balancer',   color: 'role-fw',      defaultCpu: 2,  defaultRam: 4,  defaultDisk: 32   },
  monitor:           { icon: '⬡',  label: 'Monitoring',      color: 'role-monitor', defaultCpu: 4,  defaultRam: 16, defaultDisk: 512  },
  monitoring:        { icon: '⬡',  label: 'Monitoring',      color: 'role-monitor', defaultCpu: 4,  defaultRam: 16, defaultDisk: 512  },
};

const CDS_TEMPLATES = {
  scc: {
    name: 'scc-starter',
    groups: [
      { id: 'g1', name: 'fw',         role: 'firewall', count: 2, cpu: 2,  ram: 4,  disk: 64,   wg: [0,1,2,3] },
      { id: 'g2', name: 'cluster-manager', role: 'cluster-manager-desktop', count: 1, cpu: 4,  ram: 8,  disk: 128,  wg: [0,1]     },
      { id: 'g3', name: 'compute',    role: 'compute',  count: 1, cpu: 8,  ram: 32, disk: 256,  wg: [0,1]     },
      { id: 'g4', name: 'monitoring', role: 'monitor',  count: 1, cpu: 4,  ram: 16, disk: 512,  wg: [0,1]     },
      { id: 'g5', name: 'storage',    role: 'storage',  count: 1, cpu: 4,  ram: 16, disk: 4096, wg: [0,2]     },
    ],
  },
  ha16: {
    name: 'ha-production',
    groups: [
      { id: 'g1', name: 'fw',         role: 'firewall', count: 2,  cpu: 4,  ram: 8,  disk: 128,  wg: [0,1,2,3] },
      { id: 'g2', name: 'master',     role: 'master',   count: 2,  cpu: 4,  ram: 16, disk: 256,  wg: [0,1]     },
      { id: 'g3', name: 'k8s-ctrl',   role: 'k8s',      count: 3,  cpu: 8,  ram: 16, disk: 256,  wg: [0,1]     },
      { id: 'g4', name: 'k8s-worker', role: 'k8s',      count: 6,  cpu: 16, ram: 64, disk: 512,  wg: [0,1]     },
      { id: 'g5', name: 'storage',    role: 'storage',  count: 4,  cpu: 4,  ram: 32, disk: 24576,wg: [0,2]     },
      { id: 'g6', name: 'monitoring', role: 'monitor',  count: 1,  cpu: 4,  ram: 16, disk: 1024, wg: [0,1]     },
    ],
  },
  k8s3: {
    name: 'k8s-minimal',
    groups: [
      { id: 'g1', name: 'master',  role: 'master',  count: 1, cpu: 4,  ram: 8,  disk: 128,  wg: [0,1] },
      { id: 'g2', name: 'worker',  role: 'k8s',     count: 2, cpu: 8,  ram: 16, disk: 256,  wg: [0,1] },
    ],
  },
};

let cdsState = {
  name: 'prod-cluster',
  groups: JSON.parse(JSON.stringify(CDS_TEMPLATES.scc.groups)),
};

function cdsInit() {
  cdsRender();
}

// Map of dropdown keys → JSON file paths
const CDS_JSON_TEMPLATES = {
  scc:  '/templates/scc-starter.json',
  ha16: '/templates/ha-production.json',
};

function cdsLoadTemplate(tpl) {
  if (!tpl) return;
  if (CDS_JSON_TEMPLATES[tpl]) {
    fetch(CDS_JSON_TEMPLATES[tpl])
      .then(r => r.ok ? r.json() : Promise.reject(r.status))
      .then(data => cdsApplyTemplate(data))
      .catch(err => {
        console.warn('Template fetch failed, using built-in:', err);
        const t = CDS_TEMPLATES[tpl];
        if (t) cdsApplyTemplate(t);
      });
  } else {
    const t = CDS_TEMPLATES[tpl];
    if (t) cdsApplyTemplate(t);
  }
}

function cdsApplyTemplate(t) {
  cdsState.name   = t.name   || 'cluster';
  cdsState.groups = JSON.parse(JSON.stringify(t.groups || []));

  // Populate metadata fields
  setVal('cds-name',      t.name      || '');
  setVal('cds-domain',    t.domain    || '');
  setVal('cds-wg-cidr',   t.wgCidr   || '');
  setVal('cds-mgmt-cidr', t.mgmtCidr || '');

  // Load firewall rules if present
  if (Array.isArray(t.firewall) && t.firewall.length) {
    fwRules = JSON.parse(JSON.stringify(t.firewall));
    fwRuleSeq = Math.max(...fwRules.map(r => r.id)) + 10;
    const fwEl = document.getElementById('fw-rules-body');
    if (fwEl) fwRenderRules();
  }

  // Load services if present
  if (Array.isArray(t.services) && t.services.length) {
    SVC_CATALOG.forEach(s => { svcState[s.id] = t.services.includes(s.id); });
    const svcEl = document.getElementById('svc-stacks');
    if (svcEl) { svcRenderStacks(); svcRenderPlan(); }
  }

  cdsRender();
  // Flash confirmation
  const sel = document.getElementById('cds-template-sel');
  if (sel) sel.style.outline = '1px solid var(--green)';
  setTimeout(() => { if (sel) sel.style.outline = ''; }, 1200);
}

// Helper — set input value if element exists
function setVal(id, val) {
  const el = document.getElementById(id);
  if (el) el.value = val;
}

function cdsImportTemplate(input) {
  const file = input.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = e => {
    try {
      const data = JSON.parse(e.target.result);
      cdsApplyTemplate(data);
    } catch(err) {
      alert('Invalid template JSON: ' + err.message);
    }
  };
  reader.readAsText(file);
  input.value = '';  // allow re-import of same file
}

function cdsRender() {
  cdsRenderGroups();
  cdsRenderTopo();
  cdsRenderSummary();
}

function cdsRenderGroups() {
  const el = document.getElementById('cds-groups');
  if (!el) return;
  el.innerHTML = cdsState.groups.map((g, i) => {
    const m = CDS_ROLE_META[g.role] || CDS_ROLE_META.compute;
    const wgChecks = [0,1,2,3].map(p =>
      `<label class="cds-wg-check"><input type="checkbox" ${g.wg.includes(p)?'checked':''} onchange="cdsSetWG(${i},${p},this.checked)"><span>wg${p}</span></label>`
    ).join('');
    return `
    <div class="cds-group-card ${m.color}">
      <div class="cds-group-icon">${m.icon}</div>
      <div class="cds-group-field">
        <div class="cds-group-lbl">Name</div>
        <input class="cds-group-input" value="${g.name}" onchange="cdsState.groups[${i}].name=this.value;cdsRenderTopo()">
      </div>
      <div class="cds-group-field">
        <div class="cds-group-lbl">Role</div>
        <select class="cds-group-select" onchange="cdsState.groups[${i}].role=this.value;cdsRender()">
          ${Object.entries(CDS_ROLE_META).map(([k,v])=>`<option value="${k}" ${g.role===k?'selected':''}>${v.label}</option>`).join('')}
        </select>
      </div>
      <div class="cds-group-field">
        <div class="cds-group-lbl">Count</div>
        <input class="cds-group-input" type="number" min="1" max="32" value="${g.count}" onchange="cdsState.groups[${i}].count=+this.value;cdsRender()">
      </div>
      <div class="cds-group-field">
        <div class="cds-group-lbl">vCPU</div>
        <input class="cds-group-input" type="number" min="1" value="${g.cpu}" onchange="cdsState.groups[${i}].cpu=+this.value;cdsRenderSummary()">
      </div>
      <div class="cds-group-field">
        <div class="cds-group-lbl">RAM (GB)</div>
        <input class="cds-group-input" type="number" min="1" value="${g.ram}" onchange="cdsState.groups[${i}].ram=+this.value;cdsRenderSummary()">
      </div>
      <div class="cds-group-field">
        <div class="cds-group-lbl">Storage (GB)</div>
        <input class="cds-group-input" type="number" min="10" value="${g.disk}" onchange="cdsState.groups[${i}].disk=+this.value;cdsRenderSummary()">
      </div>
      <div class="cds-group-field">
        <div class="cds-group-lbl">WG Planes</div>
        <div class="cds-wg-checks">${wgChecks}</div>
      </div>
      <div>
        <div class="cds-pool-link" onclick="nav('pool-designer')">◧ Pool</div>
      </div>
      <button class="cds-del-btn" onclick="cdsDelGroup(${i})">✕</button>
    </div>`;
  }).join('');
}

function cdsRenderTopo() {
  const el = document.getElementById('cds-topo');
  if (!el) return;
  if (!cdsState.groups.length) { el.innerHTML = '<span style="color:var(--text-dim);font-size:11px">No groups defined</span>'; return; }
  el.innerHTML = cdsState.groups.map((g, gi) => {
    const m = CDS_ROLE_META[g.role] || CDS_ROLE_META.compute;
    const nodes = Array.from({length: Math.min(g.count, 8)}, (_,i) => `
      <div class="cds-topo-node ${m.color}">
        <div class="cn-icon">${m.icon}</div>
        <div class="cn-name">${g.name}${g.count>1?'-'+(i+1):''}</div>
        <div style="font-size:8px;color:var(--text-dim)">${g.cpu}c·${g.ram}G</div>
      </div>`).join('');
    const plus = g.count > 8 ? `<div style="align-self:center;font-size:10px;color:var(--text-dim)">+${g.count-8}</div>` : '';
    const connector = gi < cdsState.groups.length-1 ? '<div class="cds-topo-connector"></div>' : '';
    return `<div class="cds-topo-group"><div class="cds-topo-group-lbl">${m.label}</div><div class="cds-topo-nodes">${nodes}${plus}</div></div>${connector}`;
  }).join('');
}

function cdsRenderSummary() {
  const totals = cdsState.groups.reduce((acc, g) => {
    acc.nodes   += g.count;
    acc.cpu     += g.count * g.cpu;
    acc.ram     += g.count * g.ram;
    acc.storage += g.count * g.disk;
    return acc;
  }, {nodes:0, cpu:0, ram:0, storage:0});
  const wgSet = new Set(cdsState.groups.flatMap(g => g.wg));
  const storageStr = totals.storage >= 1024 ? (totals.storage/1024).toFixed(1)+' TB' : totals.storage+' GB';
  setText('cds-total-nodes',   totals.nodes);
  setText('cds-total-cpu',     totals.cpu + ' vCPU');
  setText('cds-total-ram',     totals.ram + ' GB');
  setText('cds-total-storage', storageStr);
  setText('cds-wg-planes',     [...wgSet].sort().map(p=>'wg'+p).join(', ') || '—');
  setText('cds-svc-count',     svcEnabledCount() + ' enabled');
}

function cdsSetWG(groupIdx, plane, checked) {
  const g = cdsState.groups[groupIdx];
  if (!g) return;
  if (checked && !g.wg.includes(plane)) g.wg.push(plane);
  if (!checked) g.wg = g.wg.filter(p => p !== plane);
  cdsRenderSummary();
}

let cdsGroupSeq = 10;
function cdsAddGroup() {
  cdsGroupSeq++;
  cdsState.groups.push({ id:'g'+cdsGroupSeq, name:'node-'+cdsGroupSeq, role:'compute', count:1, cpu:4, ram:8, disk:128, wg:[0,1] });
  cdsRender();
}

function cdsDelGroup(i) {
  cdsState.groups.splice(i, 1);
  cdsRender();
}

function cdsSaveTemplate() {
  const domainEl  = document.getElementById('cds-domain');
  const wgCidrEl  = document.getElementById('cds-wg-cidr');
  const mgmtEl    = document.getElementById('cds-mgmt-cidr');
  const enabledSvcs = SVC_CATALOG.filter(s => svcState[s.id]).map(s => s.id);
  const payload = {
    name:       cdsState.name,
    description: cdsState.name + ' — exported from kldload Cluster Designer',
    domain:     domainEl  ? domainEl.value  : 'internal.example.com',
    wgCidr:     wgCidrEl  ? wgCidrEl.value  : '10.200.0.0/16',
    mgmtCidr:   mgmtEl    ? mgmtEl.value    : '10.100.10.0/24',
    wgPlanes: { wg0: 'Management', wg1: 'Service mesh', wg2: 'Storage/metrics', wg3: 'k8s backplane' },
    groups:   cdsState.groups,
    firewall: fwRules,
    services: enabledSvcs,
  };
  const json = JSON.stringify(payload, null, 2);
  const a = document.createElement('a');
  a.href = 'data:application/json,' + encodeURIComponent(json);
  a.download = (cdsState.name || 'cluster') + '.json';
  a.click();
}

function cdsDeploy() {
  nav('cloud-keys');
  setTimeout(()=>{
    const sel = document.getElementById('ck-cluster-template');
    if (sel) sel.value = 'custom';
  }, 100);
}

// ═══════════════════════════════════════════════════════════
// FIREWALL
// ═══════════════════════════════════════════════════════════

const FW_ZONES = ['external','dmz','internal','wg','mgmt','any'];

let fwRules = [
  { id:1, prio:10, from:'external', to:'dmz',     proto:'tcp',  port:'80,443', action:'ACCEPT', comment:'HTTP/S inbound' },
  { id:2, prio:20, from:'external', to:'dmz',     proto:'tcp',  port:'22',     action:'DROP',   comment:'Block SSH from internet' },
  { id:3, prio:30, from:'mgmt',     to:'any',     proto:'tcp',  port:'22',     action:'ACCEPT', comment:'SSH from management net' },
  { id:4, prio:40, from:'internal', to:'external',proto:'tcp',  port:'80,443', action:'ACCEPT', comment:'Outbound web' },
  { id:5, prio:50, from:'internal', to:'external',proto:'udp',  port:'53',     action:'ACCEPT', comment:'DNS outbound' },
  { id:6, prio:60, from:'wg',       to:'internal',proto:'any',  port:'any',    action:'ACCEPT', comment:'WG mesh → internal' },
  { id:7, prio:70, from:'wg',       to:'mgmt',    proto:'tcp',  port:'4505,4506',action:'ACCEPT',comment:'Salt master (wg0)' },
  { id:8, prio:80, from:'any',      to:'any',     proto:'any',  port:'any',    action:'DROP',   comment:'Default deny' },
];
let fwRuleSeq = 100;

function fwInit() {
  fwRenderRules();
}

function fwRenderRules() {
  const tbody = document.getElementById('fw-rules-body');
  if (!tbody) return;
  tbody.innerHTML = fwRules.map(r => `
    <tr data-id="${r.id}">
      <td>${r.prio}</td>
      <td><span class="fw-zone-tag ${r.from}">${r.from}</span></td>
      <td><span class="fw-zone-tag ${r.to}">${r.to}</span></td>
      <td><input class="fw-edit-input" style="width:60px" value="${r.proto}" onchange="fwUpdate(${r.id},'proto',this.value)"></td>
      <td><input class="fw-edit-input" style="width:80px" value="${r.port}" onchange="fwUpdate(${r.id},'port',this.value)"></td>
      <td class="fw-action-${r.action.toLowerCase()}">${r.action}</td>
      <td style="color:var(--text-dim);font-size:10px">${r.comment}</td>
      <td><button class="fw-del-btn" onclick="fwDelRule(${r.id})">✕</button></td>
    </tr>`).join('');
}

function fwUpdate(id, field, value) {
  const r = fwRules.find(x => x.id === id);
  if (r) r[field] = value;
}

function fwDelRule(id) {
  fwRules = fwRules.filter(r => r.id !== id);
  fwRenderRules();
}

function fwAddRule() {
  fwRuleSeq++;
  fwRules.push({ id: fwRuleSeq, prio: fwRuleSeq, from:'internal', to:'external', proto:'tcp', port:'443', action:'ACCEPT', comment:'new rule' });
  fwRenderRules();
}

function fwShowPreview() {
  const pre = document.getElementById('fw-preview');
  if (!pre) return;
  pre.style.display = 'block';
  const code = document.getElementById('fw-nft-code');
  if (code) code.textContent = fwGenerateNft();
}

function fwCopyNft() {
  navigator.clipboard.writeText(fwGenerateNft()).catch(()=>{});
}

function fwApply() {
  const banner = document.createElement('div');
  banner.style.cssText='position:fixed;bottom:24px;right:24px;background:#0a1f14;border:1px solid var(--green);color:var(--green);padding:10px 18px;border-radius:5px;font-size:12px;z-index:999';
  banner.textContent = `✓ ${fwRules.length} firewall rules queued — apply via Salt or kldload-apply-rules`;
  document.body.appendChild(banner);
  setTimeout(()=>banner.remove(), 4000);
}

function fwGenerateNft() {
  const lines = [
    '#!/usr/sbin/nft -f',
    '# Generated by kldload Web UI — Firewall Designer',
    '# ' + new Date().toISOString(),
    '',
    'flush ruleset',
    '',
    'table inet filter {',
    '  chain input {',
    '    type filter hook input priority 0; policy drop;',
    '    ct state established,related accept',
    '    lo accept',
  ];
  fwRules.forEach(r => {
    if (r.from === 'any' && r.to === 'any') {
      lines.push(`    # rule ${r.prio}: ${r.comment}`);
      if (r.action === 'DROP')   lines.push('    drop');
      if (r.action === 'ACCEPT') lines.push('    accept');
      return;
    }
    const portPart = (r.port && r.port !== 'any') ? ` dport { ${r.port} }` : '';
    const protoPart = (r.proto && r.proto !== 'any') ? `${r.proto} ` : '';
    const actionLc = r.action.toLowerCase() === 'accept' ? 'accept' : 'drop';
    lines.push(`    # ${r.prio}: ${r.from} → ${r.to} ${r.comment}`);
    lines.push(`    ${protoPart}${portPart} ${actionLc}`);
  });
  lines.push('  }', '  chain forward { type filter hook forward priority 0; policy drop; }',
             '  chain output  { type filter hook output priority 0; policy accept; }', '}');
  return lines.join('\n');
}

// ═══════════════════════════════════════════════════════════
// SERVICES
// ═══════════════════════════════════════════════════════════

const SVC_CATALOG = [
  // Security
  { id:'ssh-hardening', cat:'Security', icon:'🔐', name:'SSH Hardening', desc:'Enforces key-only auth, fail2ban, SSH banner.', roles:['all'],       enabled:true },
  { id:'nftables',      cat:'Security', icon:'🛡️', name:'nftables',       desc:'Stateful packet filtering via nftables.', roles:['firewall'], enabled:true },
  { id:'wireguard',     cat:'Security', icon:'⬡',  name:'WireGuard Mesh', desc:'4-plane WireGuard mesh across all nodes.', roles:['all'],       enabled:true },
  { id:'certmanager',   cat:'Security', icon:'📜', name:'cert-manager',   desc:'Automatic TLS cert provisioning via ACME.', roles:['k8s','master'], enabled:false },
  // Automation
  { id:'salt-master',   cat:'Automation', icon:'⬡', name:'Salt Master',   desc:'Configuration management hub. Nodes auto-register.', roles:['master'], enabled:true },
  { id:'salt-minion',   cat:'Automation', icon:'·', name:'Salt Minion',   desc:'Managed node agent — connects to master over wg0.', roles:['all'],    enabled:true },
  { id:'ansible',       cat:'Automation', icon:'▶', name:'Ansible',       desc:'Pre-installed on every node. Drop your playbooks in darksite/playbooks/.', roles:['all'], enabled:true },
  // Monitoring
  { id:'prometheus',    cat:'Monitoring', icon:'📊', name:'Prometheus',   desc:'Metrics collection + alerting. 30-day retention.', roles:['monitor'], enabled:true },
  { id:'grafana',       cat:'Monitoring', icon:'📈', name:'Grafana',      desc:'Dashboards — ZFS, k8s, WireGuard, system.', roles:['monitor'],       enabled:true },
  { id:'node-exporter', cat:'Monitoring', icon:'⊕', name:'node_exporter', desc:'Per-node metrics exposed on :9100.', roles:['all'],                   enabled:true },
  { id:'loki',          cat:'Monitoring', icon:'≡',  name:'Loki',         desc:'Log aggregation. Pairs with Grafana.', roles:['monitor'],             enabled:false },
  // Container / k8s
  { id:'k3s-server',    cat:'Kubernetes', icon:'✦', name:'k3s Server',   desc:'Lightweight k8s control plane.', roles:['k8s'],                       enabled:false },
  { id:'k3s-agent',     cat:'Kubernetes', icon:'✦', name:'k3s Agent',    desc:'k3s worker node.', roles:['k8s','compute'],                            enabled:false },
  { id:'containerd',    cat:'Kubernetes', icon:'▣', name:'containerd',   desc:'Container runtime. Required for k3s.', roles:['k8s','compute'],        enabled:false },
  // Data
  { id:'minio',         cat:'Data', icon:'◧', name:'MinIO',     desc:'S3-compatible object storage on ZFS.', roles:['storage'],                      enabled:false },
  { id:'nfs-server',    cat:'Data', icon:'◧', name:'NFS Server', desc:'NFSv4 exports from ZFS datasets.', roles:['storage'],                         enabled:false },
  { id:'zfs-recv',      cat:'Data', icon:'◧', name:'ZFS Receive', desc:'Replication target — receives zfs send streams via wg2.', roles:['storage'], enabled:true  },
  // Management
  { id:'chrony',        cat:'Management', icon:'⏱', name:'Chrony NTP',  desc:'Time sync. Server on master, clients elsewhere.', roles:['all'],        enabled:true },
  { id:'kldload-firstboot',cat:'Management', icon:'↯', name:'kldload-firstboot', desc:'First-boot provisioning service.', roles:['all'],                   enabled:true },
  { id:'kldload-snapshots',cat:'Management', icon:'◎', name:'ZFS Snapshots', desc:'Automated snapshot + prune for rpool/ROOT/default.', roles:['all'],  enabled:true },
];

let svcState = {};
SVC_CATALOG.forEach(s => { svcState[s.id] = s.enabled; });

function svcInit() {
  svcRenderStacks();
  svcRenderPlan();
}

function svcRenderStacks() {
  const el = document.getElementById('svc-stacks');
  if (!el) return;
  const cats = [...new Set(SVC_CATALOG.map(s => s.cat))];
  el.innerHTML = cats.map(cat => {
    const items = SVC_CATALOG.filter(s => s.cat === cat);
    const cards = items.map(s => {
      const on = svcState[s.id];
      return `
      <div class="svc-card ${on?'enabled':''}" id="svc-card-${s.id}">
        <div class="svc-card-hdr">
          <span class="svc-card-icon">${s.icon}</span>
          <span class="svc-card-name">${s.name}</span>
          <label class="svc-toggle">
            <input type="checkbox" ${on?'checked':''} onchange="svcToggle('${s.id}',this.checked)">
            <span class="svc-toggle-track"></span>
          </label>
        </div>
        <div class="svc-card-desc">${s.desc}</div>
        <div class="svc-card-footer">
          ${s.roles.map(r=>`<span class="svc-role-tag">${r}</span>`).join('')}
          <button class="svc-cfg-btn">⚙ Configure</button>
        </div>
      </div>`;
    }).join('');
    return `<div class="svc-category-hdr">${cat}</div>${cards}`;
  }).join('');
}

function svcToggle(id, on) {
  svcState[id] = on;
  const card = document.getElementById('svc-card-' + id);
  if (card) card.classList.toggle('enabled', on);
  svcRenderPlan();
  // update cluster designer summary
  setText('cds-svc-count', svcEnabledCount() + ' enabled');
}

function svcEnabledCount() {
  return Object.values(svcState).filter(Boolean).length;
}

function svcRenderPlan() {
  const el = document.getElementById('svc-deploy-plan');
  if (!el) return;
  const enabled = SVC_CATALOG.filter(s => svcState[s.id]);
  const roleMap = {};
  enabled.forEach(s => {
    s.roles.forEach(r => {
      if (!roleMap[r]) roleMap[r] = [];
      roleMap[r].push(s.name);
    });
  });
  el.innerHTML = Object.entries(roleMap).map(([role, svcs]) => `
    <div class="svc-deploy-card">
      <div class="svc-deploy-role">${role}</div>
      ${svcs.map(n=>`<div class="svc-deploy-item">${n}</div>`).join('')}
    </div>`).join('');
}

function svcApply() {
  const count = svcEnabledCount();
  const banner = document.createElement('div');
  banner.style.cssText='position:fixed;bottom:24px;right:24px;background:#0a1f14;border:1px solid var(--green);color:var(--green);padding:10px 18px;border-radius:5px;font-size:12px;z-index:999';
  banner.textContent = `✓ ${count} services applied to cluster template`;
  document.body.appendChild(banner);
  setTimeout(()=>banner.remove(), 3500);
}

// ═══════════════════════════════════════════════════════════
// CLOUD DEPLOY
// ═══════════════════════════════════════════════════════════

const CK_PROVIDER_NODES = { scc: 6, ha16: 16, k8s3: 3, custom: null };
const CK_INSTANCE_SPECS = {
  't3.large':           { cpu:2,  ram:8   },
  't3.xlarge':          { cpu:4,  ram:16  },
  'm6i.2xlarge':        { cpu:8,  ram:32  },
  'c6i.4xlarge':        { cpu:16, ram:32  },
  'i3en.3xlarge (NVMe storage)': { cpu:12, ram:96 },
  'n2-standard-4':      { cpu:4,  ram:16  },
  'n2-standard-8':      { cpu:8,  ram:32  },
  'n2-highcpu-8':       { cpu:8,  ram:8   },
  'n2-highmem-8':       { cpu:8,  ram:64  },
  'c2-standard-8':      { cpu:8,  ram:32  },
  'Standard_D4s_v5':    { cpu:4,  ram:16  },
  'Standard_D8s_v5':    { cpu:8,  ram:32  },
  'Standard_F8s_v2':    { cpu:8,  ram:16  },
  'Standard_L8s_v3 (NVMe)': { cpu:8, ram:64 },
};
const CK_COST_PER_VCPU_HOUR = { aws: 0.048, gcp: 0.042, azure: 0.052 };

let ckEnabled = { aws: false, gcp: false, azure: false };

function ckInit() {
  ['aws','gcp','azure'].forEach(p => {
    const el = document.getElementById('ck-'+p);
    if (el) el.classList.toggle('disabled', !ckEnabled[p]);
  });
  ckRenderResources();
}

function ckToggle(provider, on) {
  ckEnabled[provider] = on;
  const el = document.getElementById('ck-' + provider);
  if (el) el.classList.toggle('disabled', !on);
  ckRenderResources();
}

function ckRenderResources() {
  const tbody = document.getElementById('ck-resource-body');
  if (!tbody) return;
  const tpl  = (document.getElementById('ck-cluster-template') || {}).value || 'scc';
  const nodeCount = CK_PROVIDER_NODES[tpl] || (cdsState.groups.reduce((a,g)=>a+g.count,0)) || 6;
  const rows = ['aws','gcp','azure'].filter(p => ckEnabled[p]).map(p => {
    const instanceEl = document.getElementById('ck-'+p+(p==='aws'?'-instance':p==='gcp'?'-machine':'-vm-size'));
    const inst = instanceEl ? instanceEl.value : '';
    const spec = CK_INSTANCE_SPECS[inst] || { cpu:4, ram:16 };
    const totalCpu = spec.cpu * nodeCount;
    const totalRam = spec.ram * nodeCount;
    const storageTB = (128 * nodeCount / 1024).toFixed(1);
    const costPerHr = (spec.cpu * nodeCount * CK_COST_PER_VCPU_HOUR[p]);
    const costMo = Math.round(costPerHr * 730);
    return `<tr>
      <td>${p.toUpperCase()}</td>
      <td>${nodeCount}</td>
      <td>${totalCpu}</td>
      <td>${totalRam} GB</td>
      <td>${storageTB} TB</td>
      <td style="color:var(--accent)">~$${costMo}/mo</td>
    </tr>`;
  });
  tbody.innerHTML = rows.length ? rows.join('') : '<tr><td colspan="6" style="color:var(--text-dim);font-size:11px;padding:12px 10px">Enable at least one cloud provider above</td></tr>';
}

function ckTestAll() {
  ['aws','gcp','azure'].forEach(p => {
    if (!ckEnabled[p]) return;
    const st = document.getElementById('ck-'+p+'-status');
    if (st) { st.className='ck-status checking'; st.textContent='Testing connection…'; }
    setTimeout(() => {
      if (st) { st.className='ck-status ok'; st.textContent='✓ Connected'; }
    }, 1200 + Math.random()*800);
  });
}

function ckDeploy() {
  const active = Object.entries(ckEnabled).filter(([,v])=>v).map(([k])=>k.toUpperCase());
  if (!active.length) { alert('Enable at least one cloud provider first.'); return; }
  const log = document.getElementById('ck-deploy-log');
  if (!log) return;
  log.style.display = 'block';
  log.innerHTML = '';
  const tpl = (document.getElementById('ck-cluster-template')||{}).value || 'scc';
  const nodeCount = CK_PROVIDER_NODES[tpl] || 6;
  const steps = [
    `[INIT]   Cluster template: ${tpl} (${nodeCount} nodes)`,
    `[AUTH]   Validating credentials for: ${active.join(', ')}`,
    ...active.map(p => `[${p}]     Creating VPC / VNet in selected region…`),
    ...active.map(p => `[${p}]     Provisioning ${Math.ceil(nodeCount/active.length)} instances…`),
    `[DNS]    Registering nodes in internal DNS`,
    `[WG]     Generating WireGuard keypairs for all nodes`,
    `[BOOT]   Nodes booting kldload — registering with Cluster Manager…`,
    `[DONE]   ✓ Cluster provisioned. SSH: ssh admin@cluster-manager.${(document.getElementById('cds-domain')||{}).value||'internal.example.com'}`,
  ];
  steps.forEach((line, i) => {
    setTimeout(() => {
      const div = document.createElement('div');
      div.className = 'cd-log-line';
      div.textContent = line;
      if (line.startsWith('[DONE]')) div.style.color = 'var(--green)';
      log.appendChild(div);
      log.scrollTop = log.scrollHeight;
    }, i * 600);
  });
}

// ── Library — save / load / delete templates ───────────────────────────────────

let _libPendingSave = null;

const LIB_TYPE_LABELS = { cluster:'Cluster', pool:'Pool', firewall:'Firewall', service:'Service', vm:'VM', app:'App', generic:'Generic' };
const LIB_TYPE_ICONS  = { cluster:'⬡', pool:'◧', firewall:'⬛', service:'⊞', vm:'▣', app:'⊕', generic:'◈' };

function dbList(type) {
  wsSend({ action: 'db_list', db_type: type || null });
}

function dbLoad(id) {
  wsSend({ action: 'db_load', id });
}

function dbDelete(id) {
  if (!confirm('Delete this template from the library?')) return;
  wsSend({ action: 'db_delete', id });
}

function libInit() {
  const type = document.getElementById('lib-filter')?.value || null;
  dbList(type);
}

function libRender(items) {
  const grid = document.getElementById('lib-grid');
  if (!grid) return;
  if (!items || items.length === 0) {
    grid.innerHTML = '<div class="lib-empty">No saved templates yet. Open a designer and click <strong>Save to Library</strong>.</div>';
    return;
  }
  grid.innerHTML = items.map(t => `
    <div class="lib-card">
      <div class="lib-card-head">
        <span class="lib-type-badge lib-type-${t.type}">${LIB_TYPE_ICONS[t.type]||'◈'} ${LIB_TYPE_LABELS[t.type]||t.type}</span>
        <div class="lib-card-actions">
          <button class="btn-sm btn-primary" onclick="dbLoad('${t.id}')">↗ Load</button>
          <button class="btn-sm btn-danger"  onclick="dbDelete('${t.id}')">✕</button>
        </div>
      </div>
      <div class="lib-card-name">${t.name}</div>
      <div class="lib-card-desc">${t.description || ''}</div>
      <div class="lib-card-meta">${(t.updated_at||'').replace('T',' ').replace('Z','')}</div>
    </div>
  `).join('');
}

function libShowSave(type, getData) {
  _libPendingSave = { type, getData };
  const modal = document.getElementById('lib-save-modal');
  const title = document.getElementById('lib-save-title');
  const nameEl = document.getElementById('lib-save-name');
  const descEl = document.getElementById('lib-save-desc');
  if (title)  title.textContent = `Save ${LIB_TYPE_LABELS[type]||type} to Library`;
  if (nameEl) nameEl.value = '';
  if (descEl) descEl.value = '';
  if (modal)  modal.style.display = 'flex';
  setTimeout(() => nameEl && nameEl.focus(), 50);
}

function libSaveConfirm() {
  if (!_libPendingSave) return;
  const name = document.getElementById('lib-save-name')?.value.trim();
  if (!name) { alert('Please enter a name.'); return; }
  const desc = document.getElementById('lib-save-desc')?.value.trim() || '';
  const data = _libPendingSave.getData();
  wsSend({ action: 'db_save', db_type: _libPendingSave.type, name, description: desc, data });
  libSaveClose();
}

function libSaveClose() {
  const modal = document.getElementById('lib-save-modal');
  if (modal) modal.style.display = 'none';
  _libPendingSave = null;
}

function libApplyLoaded(tpl) {
  if (!tpl || !tpl.data) return;
  const t = tpl.data;
  switch (tpl.type) {
    case 'cluster':
      nav('cluster-designer');
      cdsApplyTemplate(t);
      break;
    case 'pool':
      nav('pool-designer');
      if (t.topology) { PD.selected_topo = t.topology; pdApplyTopo(t.topology); }
      if (t.drives)   { PD.drives = t.drives; pdRenderShelf(); }
      break;
    case 'firewall':
      nav('firewall');
      if (t.rules) { fwRules = t.rules; fwRenderRules(); }
      break;
    case 'service':
      nav('services');
      if (t.services) { Object.assign(svcState, t.services); svcInit(); }
      break;
    default:
      libToast(`Loaded: ${tpl.name} (type: ${tpl.type})`);
      return;
  }
  libToast(`Loaded: ${tpl.name}`);
}

function libToast(msg) {
  let t = document.getElementById('lib-toast');
  if (!t) {
    t = document.createElement('div');
    t.id = 'lib-toast';
    t.className = 'lib-toast';
    document.body.appendChild(t);
  }
  t.textContent = msg;
  t.classList.add('show');
  setTimeout(() => t.classList.remove('show'), 2500);
}

function renderDbEvents(events) {
  const tbody = document.getElementById('events-tbody');
  if (!tbody) return;
  if (!events || !events.length) {
    tbody.innerHTML = '<tr><td colspan="4" class="loading">No events yet</td></tr>';
    return;
  }
  const TYPE_CLS = {
    node_joined: 'badge-green', node_recovered: 'badge-green',
    node_offline: 'badge-red',  cluster_drift: 'badge-yellow',
    save: 'badge-blue',         cluster_save: 'badge-blue',
    vm_clone: 'badge-blue',     vm_replace: 'badge-yellow',
    delete: 'badge-red',
  };
  tbody.innerHTML = events.map(e => {
    const cls = TYPE_CLS[e.type] || 'badge-muted';
    const ts  = (e.ts||'').replace('T',' ').replace('Z','');
    return `<tr>
      <td class="mono" style="font-size:10px;white-space:nowrap">${ts}</td>
      <td><span class="badge ${cls}">${esc(e.type)}</span></td>
      <td class="mono" style="font-size:10px">${esc((e.subject||'').slice(0,16))}</td>
      <td style="font-size:12px">${esc(e.message)}</td>
    </tr>`;
  }).join('');
}

// Per-designer save hooks

function pdSave() {
  libShowSave('pool', () => ({
    topology: PD.selected_topo,
    drives:   PD.drives,
    vdevs:    PD.vdevs,
    slog:     PD.slog,
    l2arc:    PD.l2arc,
  }));
}

function cdsSaveToLib() {
  libShowSave('cluster', () => Object.assign({}, cdsState, {
    firewall: fwRules,
    services: Object.keys(svcState).filter(k => svcState[k]),
  }));
}

function fwSave() {
  libShowSave('firewall', () => ({ rules: fwRules }));
}

function svcSave() {
  libShowSave('service', () => ({ services: svcState }));
}

// ── VM clone / replace ────────────────────────────────────────────────────────

function vmClone(name) {
  const log = document.getElementById('vm-log');
  if (log) { log.textContent = ''; log.style.display = ''; }
  wsSend({ action: 'vm_clone', vm: name });
}

function vmReplace(name) {
  if (!confirm(`Replace VM "${name}"?\n\nThis will clone it to a new VM, then destroy the original.`)) return;
  const log = document.getElementById('vm-log');
  if (log) { log.textContent = ''; log.style.display = ''; }
  wsSend({ action: 'vm_replace', vm: name });
}

// ── Infrastructure view ───────────────────────────────────────────────────────

function infraLoad() {
  wsSend({ action: 'infra_status' });
}

function infraRender(msg) {
  infraRenderClusters(msg.clusters || [], msg.nodes || []);
  infraRenderNodes(msg.nodes || []);
}

function infraRenderClusters(clusters, nodes) {
  const el = document.getElementById('infra-clusters');
  if (!el) return;
  if (!clusters.length) {
    el.innerHTML = '<div class="lib-empty">No clusters saved yet. Use Cluster Designer and click Save to Library or Deploy.</div>';
    return;
  }
  el.innerHTML = clusters.map(c => {
    const desired = c.data && c.data.groups
      ? c.data.groups.reduce((s, g) => s + (g.count || 1), 0) : '?';
    const actual = nodes.filter(n => n.cluster_id === c.id && n.status === 'online').length;
    const healthy = (typeof desired === 'number') ? actual >= desired : null;
    const statusCls = c.status === 'running' ? 'badge-green'
                    : c.status === 'degraded' ? 'badge-yellow' : 'badge-muted';
    const healthIcon = healthy === null ? '?' : healthy ? '✓' : '⚠';
    const healthCls  = healthy === null ? '' : healthy ? 'green' : 'yellow';
    return `<div class="infra-cluster-card">
      <div class="infra-cluster-head">
        <span class="infra-cluster-name">${esc(c.name)}</span>
        <span class="badge ${statusCls}">${esc(c.status)}</span>
      </div>
      <div class="infra-cluster-stats">
        <span>Desired: <strong>${desired}</strong> nodes</span>
        <span>Actual: <strong class="${healthCls}">${actual}</strong> online</span>
        <span class="infra-health-icon ${healthCls}">${healthIcon}</span>
      </div>
      <div class="infra-cluster-meta">${(c.updated_at||'').replace('T',' ').replace('Z','')}</div>
    </div>`;
  }).join('');
}

function infraRenderNodes(nodes) {
  const tbody = document.getElementById('infra-nodes-tbody');
  if (!tbody) return;
  if (!nodes.length) {
    tbody.innerHTML = '<tr><td colspan="8" class="loading">No registered nodes — nodes will appear after first Salt check-in</td></tr>';
    return;
  }
  tbody.innerHTML = nodes.map(n => {
    const badge = n.status === 'online'
      ? '<span class="badge badge-green">online</span>'
      : '<span class="badge badge-red">offline</span>';
    const ago = n.last_seen ? n.last_seen.replace('T',' ').replace('Z','') : '—';
    return `<tr>
      <td class="mono">${esc(n.hostname)}</td>
      <td>${esc(n.role || '—')}</td>
      <td class="mono">${esc(n.cluster_id ? n.cluster_id.slice(0,8) : '—')}</td>
      <td class="mono ip-cell">${esc(n.ip_mgmt || '—')}</td>
      <td class="mono ip-cell">${esc(n.ip_wg0 || '—')}</td>
      <td class="mono ip-cell">${esc(n.ip_wg1 || '—')}</td>
      <td>${badge}</td>
      <td class="mono" style="font-size:10px">${ago}</td>
    </tr>`;
  }).join('');
}

// ── Events view ───────────────────────────────────────────────────────────────

function eventsLoad() {
  wsSend({ action: 'db_events', limit: 200 });
}

// ── UI Mode (live ISO ephemeral vs installed master persistent) ────────────────

function renderUiMode(msg) {
  const banner = document.getElementById('mode-banner');
  const logoEl = document.querySelector('.logo');

  // Apply branding based on role
  if (msg.role === 'master' || msg.role === 'cluster-manager-desktop' || msg.role === 'cluster-manager-server') {
    // Cluster Manager skin
    document.title = 'Cluster Manager';
    if (logoEl) {
      logoEl.innerHTML = 'Cluster <span class="logo-z">Manager</span>';
      logoEl.classList.add('logo-cc');
    }
    document.documentElement.style.setProperty('--accent', '#f59e0b');
    document.documentElement.style.setProperty('--accent-dim', 'rgba(245,158,11,0.15)');
    // Add CC class to body for CSS targeting
    document.body.classList.add('mode-cc');
  } else if (!msg.live) {
    document.title = `kldload — ${msg.hostname || 'node'}`;
  }

  if (!banner) return;
  if (msg.live) {
    banner.innerHTML = `
      <span class="mode-live">◉ LIVE ISO — ephemeral session</span>
      <span class="mode-hint">Designs saved here will be lost on reboot.
        <button class="btn-xs btn-secondary" onclick="dbExport()">↓ Export DB</button>
        <label class="btn-xs btn-secondary" style="cursor:pointer">
          ↑ Import DB<input type="file" accept=".json" style="display:none" onchange="dbImportFile(this)">
        </label>
      </span>`;
    banner.className = 'mode-banner mode-banner-live';
  } else if (msg.role === 'master' || msg.role === 'cluster-manager-desktop' || msg.role === 'cluster-manager-server') {
    banner.innerHTML = `
      <span class="mode-master">◈ CLUSTER MANAGER — ${msg.hostname || 'cluster-manager'} — persistent state on ZFS</span>
      <span class="mode-hint">DB: ${msg.db_path} (${msg.db_size_kb} KB)
        <button class="btn-xs btn-secondary" onclick="dbExport()">↓ Backup DB</button>
      </span>`;
    banner.className = 'mode-banner mode-banner-cc';
  } else {
    banner.innerHTML = `
      <span class="mode-master">◉ NODE — persistent state on ZFS</span>
      <span class="mode-hint">DB: ${msg.db_path} (${msg.db_size_kb} KB)
        <button class="btn-xs btn-secondary" onclick="dbExport()">↓ Backup DB</button>
      </span>`;
    banner.className = 'mode-banner mode-banner-master';
  }
  banner.style.display = '';
}

function dbExport() {
  wsSend({ action: 'db_export' });
}

function dbExportDownload(data) {
  const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
  const a    = document.createElement('a');
  a.href     = URL.createObjectURL(blob);
  a.download = `kldload-state-${new Date().toISOString().slice(0,10)}.json`;
  a.click();
  URL.revokeObjectURL(a.href);
}

function dbImportFile(input) {
  const file = input.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = e => {
    try {
      const data = JSON.parse(e.target.result);
      if (confirm(`Import ${Object.keys(data).join(', ')} from ${file.name}?\n\nExisting records will be kept (merge mode).`)) {
        wsSend({ action: 'db_import', data, merge: true });
      }
    } catch {
      alert('Invalid JSON file');
    }
  };
  reader.readAsText(file);
}

// ── DB-backed Service management ──────────────────────────────────────────────

function svcDbLoad() {
  wsSend({ action: 'service_list' });
}

function svcDbRender(services) {
  const el = document.getElementById('svc-db-list');
  if (!el) return;
  if (!services || !services.length) {
    el.innerHTML = '<div class="lib-empty">No services saved yet. Define a service below and click Save & Deploy.</div>';
    return;
  }
  const STATUS_CLS = {
    running: 'badge-green', deploying: 'badge-blue',
    failed: 'badge-red',    defined: 'badge-muted',
    replacing: 'badge-yellow',
  };
  el.innerHTML = services.map(s => {
    const cls = STATUS_CLS[s.status] || 'badge-muted';
    const targets = Array.isArray(s.node_targets) ? s.node_targets.join(', ') || 'all' : 'all';
    return `<div class="lib-card">
      <div class="lib-card-head">
        <span class="lib-type-badge lib-type-service">⊞ Service</span>
        <div class="lib-card-actions">
          <button class="btn-sm btn-primary" onclick="svcDbDeploy('${s.id}')">▶ Deploy</button>
          <button class="btn-sm btn-secondary" onclick="svcDbEdit('${s.id}')">Edit</button>
          <button class="btn-sm btn-danger" onclick="svcDbDelete('${s.id}')">✕</button>
        </div>
      </div>
      <div class="lib-card-name">${esc(s.name)}</div>
      <div class="lib-card-desc">${esc(s.description || '')}</div>
      <div class="lib-card-meta">
        <span class="badge ${cls}">${esc(s.status)}</span>
        runtime: ${esc(s.runtime)}
        &nbsp;·&nbsp; dataset: <span class="mono">${esc(s.dataset)}</span>
        &nbsp;·&nbsp; targets: ${esc(targets)}
        &nbsp;·&nbsp; replicas: ${s.replicas}
      </div>
    </div>`;
  }).join('');
}

function svcDbDeploy(id) {
  const log = document.getElementById('svc-deploy-log');
  if (log) { log.textContent = ''; log.style.display = ''; }
  wsSend({ action: 'service_deploy', id });
}

function svcDbDelete(id) {
  if (!confirm('Delete this service definition?')) return;
  wsSend({ action: 'service_delete', id });
}

function svcDbEdit(id) {
  wsSend({ action: 'service_load', id });
  // service_data response will populate the form
}

function svcDbSave() {
  const name    = document.getElementById('svc-form-name')?.value.trim();
  const desc    = document.getElementById('svc-form-desc')?.value.trim() || '';
  const image   = document.getElementById('svc-form-image')?.value.trim() || '';
  const runtime = document.getElementById('svc-form-runtime')?.value || 'systemd';
  const targets = (document.getElementById('svc-form-targets')?.value || '')
    .split(',').map(s => s.trim()).filter(Boolean);
  const dataset = document.getElementById('svc-form-dataset')?.value.trim()
    || (name ? `rpool/services/${name}` : '');
  const replicas = parseInt(document.getElementById('svc-form-replicas')?.value || '1', 10);
  const repl_targets = (document.getElementById('svc-form-repl-targets')?.value || '')
    .split(',').map(s => s.trim()).filter(Boolean);

  if (!name) { alert('Service name is required'); return; }

  wsSend({
    action: 'service_save', name, description: desc, image, runtime,
    node_targets: targets, dataset, replicas, repl_targets,
    config: {},
  });
}

// ── Ansible ──────────────────────────────────────────────────────────────────

function ansibleRefresh() {
  wsSend({ action: 'ansible_list' });
}

function ansibleRun() {
  const playbook   = document.getElementById('ansible-playbook-select')?.value;
  const hosts      = document.getElementById('ansible-hosts')?.value.trim() || 'all';
  const extra_vars = document.getElementById('ansible-extra-vars')?.value.trim() || '';
  if (!playbook) { alert('Select a playbook first'); return; }
  appendLog('ansible-log', `▶ Running ${playbook} on ${hosts}…`);
  wsSend({ action: 'ansible_run', playbook, hosts, extra_vars });
}

function appendLog(id, line) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent += line + '\n';
  el.scrollTop = el.scrollHeight;
}

// Handle ansible WS messages
function handleAnsibleMsg(msg) {
  if (msg.type === 'ansible_list') {
    const sel = document.getElementById('ansible-playbook-select');
    const grid = document.getElementById('ansible-playbook-list');
    if (!sel || !grid) return;
    const books = msg.playbooks || [];
    sel.innerHTML = '<option value="">-- select --</option>' +
      books.map(b => `<option value="${esc(b)}">${esc(b)}</option>`).join('');
    grid.innerHTML = books.length
      ? books.map(b => `<div class="lib-card"><div class="lib-name">${esc(b)}</div></div>`).join('')
      : '<div class="loading">No playbooks found in darksite/playbooks/</div>';
  } else if (msg.type === 'ansible_output') {
    appendLog('ansible-log', msg.line || '');
  } else if (msg.type === 'ansible_done') {
    appendLog('ansible-log', `✓ Done (rc=${msg.rc ?? '?'})`);
  }
}
