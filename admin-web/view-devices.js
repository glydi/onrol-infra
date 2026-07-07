/* Devices — admin oversight of the devices bound to each account. There is NO
 * global device index (devices are stored per-user), so this is a user-centric
 * flow: search/pick a person → see their active devices → revoke one or reset
 * all (free every slot). Admin-only. Backed by /manage/users and
 * /manage/users/:id/devices. Every top-level name is `dev`-prefixed so it can't
 * collide with the other view-*.js files sharing the global script scope, and
 * it uses ONLY the window-exposed core helpers. */
'use strict';

/* pull ?q= out of the raw hash so the search box survives a refresh / deep link.
 * (own copy — the students view has its own hashQuery in the shared scope) */
function devHashQuery(name) {
  const h = location.hash || '';
  const i = h.indexOf('?');
  if (i < 0) return '';
  try { return new URLSearchParams(h.slice(i + 1)).get(name) || ''; } catch (_) { return ''; }
}

const devRoleTag = r => tag(({ student: 'Student', instructor: 'Instructor', manager: 'Admin', superadmin: 'Superadmin', live_host: 'Live host' }[r]) || r || 'user');
const devStatusPill = u => pill(u && u.is_active ? 'active' : 'inactive');
function devUserSub(u) {
  const bits = [];
  if (u.email) bits.push(esc(u.email));
  if (u.phone) bits.push(esc(u.phone));
  if (u.login_id) bits.push('#' + esc(u.login_id));
  else if (u.username) bits.push(esc(u.username));
  return bits.length ? `<div class="sub">${bits.join(' · ')}</div>` : '';
}
/* name / email / phone / login id / username / batch — everything a person might type */
const devHaystack = u => [u.full_name, u.email, u.phone, u.username, u.login_id, u.batch, u.course_label, u.role]
  .filter(Boolean).join(' ').toLowerCase();

const DEV_STUB = 'Devices are managed per-user — there is no global device index endpoint yet, so pick a person to see and free their bound device slots.';

registerView('devices', async (content, ctx) => {
  if (!isAdmin()) { content.innerHTML = pageHead({ title: 'Devices' }) + emptyState('Admins only', 'This section is restricted to managers and admins.'); return; }
  if (ctx.params[0]) return devUserDevices(content, ctx, ctx.params[0]);

  ctx.setCrumbs('Devices');
  const users = arr(await api('/manage/users'), 'users');
  window.__devUsers = users; // cache for the per-user page (no single-user GET endpoint)

  content.innerHTML = pageHead({ title: 'Devices', sub: `${users.length} people` }) +
    `<p class="stub" style="margin:-4px 0 14px">${esc(DEV_STUB)}</p>` +
    `<div class="toolbar">
      <input class="search" id="devSearch" placeholder="Search name, email, phone…" value="${esc(devHashQuery('q'))}">
      <div class="grow"></div><span class="muted" id="devCount"></span>
    </div><div id="devRows"></div>`;

  const rowsEl = content.querySelector('#devRows');
  const searchEl = content.querySelector('#devSearch');
  const render = () => {
    const q = searchEl.value.trim().toLowerCase();
    const rows = users.filter(u => !q || devHaystack(u).includes(q));
    content.querySelector('#devCount').textContent = `${rows.length} of ${users.length}`;
    rowsEl.innerHTML = dataTable({
      clickable: true, empty: 'No matching users.',
      columns: [
        { label: 'Name', render: u => `<b>${esc(u.full_name || 'Unnamed')}</b>${devUserSub(u)}` },
        { label: 'Role', render: u => devRoleTag(u.role) },
        { label: 'Status', render: devStatusPill },
        { label: 'Batch / Course', render: u => u.batch ? tag('Batch ' + u.batch) : (u.course_label ? tag(u.course_label) : '<span class="muted">—</span>') },
        { label: '', cls: 'right', render: () => `<span class="muted">View devices ›</span>` },
      ], rows,
    });
    wire(rowsEl, { rowClick: id => go('#/devices/' + id) });
  };
  searchEl.oninput = render;
  render();
});

/* ---- Per-user devices (list + revoke one + reset all) ---- */
async function devUserDevices(content, ctx, id) {
  let u = (window.__devUsers || []).find(x => String(x.id) === String(id));
  if (!u) { window.__devUsers = arr(await api('/manage/users'), 'users'); u = window.__devUsers.find(x => String(x.id) === String(id)); }

  const title = u ? (u.full_name || 'User') : 'User devices';
  ctx.setCrumbs({ label: 'Devices', href: '#/devices' }, title);

  const devices = arr(await api('/manage/users/' + id + '/devices'), 'devices');
  content.innerHTML =
    pageHead({ title, sub: u ? (u.email || u.login_id || u.username || id) : id, actions: u ? devStatusPill(u) + ' ' + devRoleTag(u.role) : '' }) +
    `<p class="stub" style="margin:-4px 0 14px">${esc(DEV_STUB)}</p>` +
    `<div class="toolbar"><div class="grow"><span class="muted">${devices.length} active device(s)</span></div>${devices.length ? btn('Reset all devices', { act: 'resetall', cls: 'btn-sm btn-danger' }) : ''}</div>` +
    dataTable({
      empty: 'No active devices.', columns: [
        { label: 'Device', render: d => `<b>${esc(d.name || d.model || 'Device')}</b>${d.model && d.name ? `<div class="sub">${esc(d.model)}</div>` : ''}` },
        { label: 'Platform', render: d => d.platform ? tag(d.platform) : '<span class="muted">—</span>' },
        { label: 'Device ID', render: d => `<span class="muted">${esc((d.device_id || '').slice(0, 12))}…</span>` },
        { label: 'First seen', render: d => `<span class="muted">${esc(fmtDate(d.first_seen))}</span>` },
        { label: 'Last seen', render: d => `<span class="muted" title="${esc(fmtDateTime(d.last_seen))}">${esc(timeAgo(d.last_seen) || fmtDate(d.last_seen))}</span>` },
        { label: '', cls: 'right', render: d => btn('Revoke', { act: 'revoke', id: d.id, cls: 'btn-sm btn-danger' }) },
      ], rows: devices,
    });

  const reload = () => devUserDevices(content, ctx, id);
  wire(content, {
    acts: {
      revoke: async did => { if (await confirmModal('Revoke this device? The user is signed out of it and a slot is freed.', { danger: true, confirmLabel: 'Revoke' })) { await api(`/manage/users/${id}/devices/${did}`, { method: 'DELETE' }); toast('Device revoked', 'good'); reload(); } },
      resetall: async () => { if (await confirmModal('Sign this user out of ALL devices? Frees every slot.', { danger: true, confirmLabel: 'Reset all' })) { const r = await api(`/manage/users/${id}/devices`, { method: 'DELETE' }); toast(`Reset ${r.devices_reset ?? 0} device(s)`, 'good'); reload(); } },
    },
  });
}
