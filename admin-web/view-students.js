/* Students — the ONE unified roster + ONE student detail page. Admin-only.
 * Replaces the three duplicated Flutter "people" menus. Backed by /manage/users.
 * There is no single-user GET on the API, so detail reads from the cached list
 * (and re-fetches the list if you deep-link / refresh straight into a detail). */
'use strict';

/* Accepted roles for SetUserRole / CreateManagedUser (backend-validated). Managers
 * can only assign student/instructor — the API rejects the rest with a message. */
const ROLE_OPTIONS = [
  { value: 'student', label: 'Student' },
  { value: 'instructor', label: 'Instructor' },
  { value: 'live_host', label: 'Live host' },
  { value: 'manager', label: 'Manager (admin)' },
  { value: 'superadmin', label: 'Superadmin' },
];
const STUDENT_TABS = [['profile', 'Profile'], ['enrollments', 'Enrollments'], ['devices', 'Devices'], ['lead', 'Source lead'], ['actions', 'Actions']];

/* pull a query param out of the raw hash, e.g. #/students?q=foo → hashQuery('q') === 'foo' */
function hashQuery(name) {
  const h = location.hash || '';
  const i = h.indexOf('?');
  if (i < 0) return '';
  try { return new URLSearchParams(h.slice(i + 1)).get(name) || ''; } catch (_) { return ''; }
}
const roleTag = r => tag(({ student: 'Student', instructor: 'Instructor', manager: 'Admin', superadmin: 'Superadmin', live_host: 'Live host' }[r]) || r || 'user');
const statusPill = u => pill(u.is_active ? 'active' : 'inactive');
function userSub(u) {
  const bits = [];
  if (u.email) bits.push(esc(u.email));
  if (u.login_id) bits.push('#' + esc(u.login_id));
  else if (u.username) bits.push(esc(u.username));
  return bits.length ? `<div class="sub">${bits.join(' · ')}</div>` : '';
}
const studentHaystack = u => [u.full_name, u.email, u.username, u.login_id, u.batch, u.course_label, u.role]
  .filter(Boolean).join(' ').toLowerCase();

registerView('students', async (content, ctx) => {
  if (!isAdmin()) { content.innerHTML = pageHead({ title: 'Students' }) + emptyState('Admins only', 'This section is restricted to managers and admins.'); return; }
  if (ctx.params[0]) return studentDetail(content, ctx, ctx.params[0], ctx.params[1] || 'profile');

  ctx.setCrumbs('Students');
  const users = arr(await api('/manage/users'), 'users');
  window.__students = users; // cache for the detail page (no single-user GET endpoint)

  content.innerHTML = pageHead({
    title: 'Students', sub: `${users.length} people`,
    actions: btn('+ New user', { act: 'new', cls: 'btn-primary' }),
  }) + `<div class="toolbar">
      <input class="search" id="stSearch" placeholder="Search name, email, phone…" value="${esc(hashQuery('q'))}">
      <select id="stStatus" style="width:auto;flex:none">
        <option value="">All statuses</option>
        <option value="active">Active</option>
        <option value="inactive">Inactive</option>
      </select>
      <div class="grow"></div><span class="muted" id="stCount"></span>
    </div><div id="stRows"></div>`;

  const rowsEl = content.querySelector('#stRows');
  const searchEl = content.querySelector('#stSearch');
  const statusEl = content.querySelector('#stStatus');
  const render = () => {
    const q = searchEl.value.trim().toLowerCase(), st = statusEl.value;
    const rows = users.filter(u => {
      if (st === 'active' && !u.is_active) return false;
      if (st === 'inactive' && u.is_active) return false;
      return !q || studentHaystack(u).includes(q);
    });
    content.querySelector('#stCount').textContent = `${rows.length} of ${users.length}`;
    rowsEl.innerHTML = dataTable({
      clickable: true, empty: 'No matching users.',
      columns: [
        { label: 'Name', render: u => `<b>${esc(u.full_name || 'Unnamed')}</b>${userSub(u)}` },
        { label: 'Role', render: u => roleTag(u.role) },
        { label: 'Status', render: statusPill },
        { label: 'Batch / Course', render: u => u.batch ? tag('Batch ' + u.batch) : (u.course_label ? tag(u.course_label) : '<span class="muted">—</span>') },
        { label: 'Joined', render: u => `<span class="muted">${esc(fmtDate(u.created_at))}</span>` },
      ], rows,
    });
    wire(rowsEl, { rowClick: id => go('#/students/' + id) });
  };
  searchEl.oninput = render;
  statusEl.onchange = render;
  render();
  wire(content, { acts: { new: () => newUser() } });
});

/* ---- Create ---- */
function newUser() {
  formModal({
    title: 'New user', wide: true, sub: 'A full name and an email OR phone are required.',
    fields: [
      { name: 'full_name', label: 'Full name', required: true },
      { name: 'email', label: 'Email', type: 'email', placeholder: 'optional if phone is given' },
      { name: 'phone', label: 'Phone', placeholder: 'optional if email is given' },
      { name: 'role', label: 'Role', type: 'select', value: 'student', options: ROLE_OPTIONS },
      { name: 'batch', label: 'Batch code', placeholder: 'optional, e.g. B12' },
      { name: 'course_label', label: 'Course label', placeholder: 'optional' },
      { name: 'password', label: 'Password', type: 'password', hint: 'blank = default (onrol@ai)' },
    ], submitLabel: 'Create user',
    async onSubmit(v) {
      if (!v.email && !v.phone) return 'Provide an email or a phone number';
      const body = { full_name: v.full_name, email: v.email, phone: v.phone, role: v.role, course_label: v.course_label };
      if (v.batch && v.batch.trim()) body.batch = v.batch.trim();
      if (v.password) body.password = v.password;
      const r = await api('/manage/users', { method: 'POST', body });
      toast('User created', 'good');
      window.__students = null;
      go('#/students/' + (r.id || ''));
    },
  });
}

/* ---- Detail (tabbed) ---- */
async function studentDetail(content, ctx, id, tab) {
  let u = (window.__students || []).find(x => String(x.id) === String(id));
  if (!u) { window.__students = arr(await api('/manage/users'), 'users'); u = window.__students.find(x => String(x.id) === String(id)); }
  if (!u) { content.innerHTML = pageHead({ title: 'Student' }) + emptyState('User not found', 'They may have been deleted.'); return; }

  ctx.setCrumbs({ label: 'Students', href: '#/students' }, u.full_name || 'Student');
  content.innerHTML =
    pageHead({ title: u.full_name || 'Student', sub: u.email || u.login_id || u.username || id, actions: statusPill(u) + ' ' + roleTag(u.role) }) +
    `<div class="tabs">${STUDENT_TABS.map(([k, l]) => `<div class="tab ${k === tab ? 'active' : ''}" data-t="${k}">${l}</div>`).join('')}</div><div id="tb"></div>`;
  content.querySelectorAll('.tab').forEach(t => t.onclick = () => go(`#/students/${id}/${t.dataset.t}`));
  const tb = content.querySelector('#tb');
  ({ profile: tabProfile, enrollments: tabEnrollments, devices: tabDevices, lead: tabLead, actions: tabActions }[tab] || tabProfile)(tb, u, id);
}
/* re-fetch the roster then re-render the detail (keeps header pills in sync after a mutation) */
async function reloadStudent(id, tab) {
  window.__students = arr(await api('/manage/users'), 'users');
  studentDetail(document.getElementById('content'), { setCrumbs }, id, tab);
}

/* ---- Profile ---- */
function tabProfile(tb, u) {
  tb.innerHTML = card(dl([
    ['Name', esc(u.full_name)],
    ['Email', esc(u.email) || '—'],
    ['Username', esc(u.username || '—')],
    ['Login ID', u.login_id ? `<code>${esc(u.login_id)}</code>` : '—'],
    ['Role', roleTag(u.role)],
    ['Status', statusPill(u)],
    ['Batch', u.batch ? tag('Batch ' + u.batch) : '—'],
    ['Course', esc(u.course_label || '—')],
    ['User ID', `<code>${esc(u.id)}</code>`],
    ['Joined', esc(fmtDate(u.created_at))],
  ]));
}

/* ---- Enrollments (no per-user API yet — enroll from a course's Students tab) ---- */
function tabEnrollments(tb) {
  tb.innerHTML = card(emptyState('Per-student enrollments aren’t exposed yet',
    'Enroll a student from a course’s Students tab. This tab will list a student’s courses + progress once the API adds GET /manage/users/:id/enrollments.'));
}

/* ---- Devices ---- */
async function tabDevices(tb, u, id) {
  const devices = arr(await api('/manage/users/' + id + '/devices'), 'devices');
  tb.innerHTML = `<div class="toolbar"><div class="grow"><span class="muted">${devices.length} active device(s)</span></div>${devices.length ? btn('Reset all devices', { act: 'resetall', cls: 'btn-sm btn-danger' }) : ''}</div>` +
    dataTable({
      empty: 'No active devices.', columns: [
        { label: 'Device', render: d => `<b>${esc(d.name || d.model || 'Device')}</b>${d.platform ? `<div class="sub">${esc(d.platform)}${d.model && d.name ? ' · ' + esc(d.model) : ''}</div>` : ''}` },
        { label: 'Device ID', render: d => `<span class="muted">${esc((d.device_id || '').slice(0, 12))}…</span>` },
        { label: 'First seen', render: d => esc(fmtDate(d.first_seen)) },
        { label: 'Last seen', render: d => `<span class="muted" title="${esc(fmtDateTime(d.last_seen))}">${esc(timeAgo(d.last_seen) || fmtDate(d.last_seen))}</span>` },
        { label: '', cls: 'right', render: d => btn('Revoke', { act: 'revoke', id: d.id, cls: 'btn-sm btn-danger' }) },
      ], rows: devices,
    });
  wire(tb, {
    acts: {
      revoke: async did => { if (await confirmModal('Revoke this device? The user is signed out of it and a slot is freed.', { danger: true, confirmLabel: 'Revoke' })) { await api(`/manage/users/${id}/devices/${did}`, { method: 'DELETE' }); toast('Device revoked', 'good'); tabDevices(tb, u, id); } },
      resetall: async () => { if (await confirmModal('Sign this user out of ALL devices? Frees every slot.', { danger: true, confirmLabel: 'Reset all' })) { const r = await api(`/manage/users/${id}/devices`, { method: 'DELETE' }); toast(`Reset ${r.devices_reset ?? 0} device(s)`, 'good'); tabDevices(tb, u, id); } },
    },
  });
}

/* ---- Source lead (converted CRM lead this account was provisioned from) ---- */
async function tabLead(tb, u, id) {
  const res = await api('/manage/users/' + id + '/converted-lead');
  if (!res.found || !res.lead) { tb.innerHTML = card(emptyState('No source lead', 'This account wasn’t auto-provisioned from a converted CRM lead (no email/phone match).')); return; }
  const l = res.lead;
  tb.innerHTML = card(dl([
    ['Name', esc(l.name)], ['Phone', esc(l.phone) || '—'], ['Email', esc(l.email) || '—'],
    ['Source', esc(l.source || '—')], ['Campaign', esc(l.campaign || '—')],
    ['Status', l.status ? pill(l.status) : '—'], ['Score', l.score != null ? String(l.score) : '—'],
    ['Owner', esc(l.owner || '—')], ['Created', esc(fmtDate(l.created_at))], ['Converted', esc(fmtDate(l.converted_at))],
  ])) + (l.record ? card(`<div class="section-title">Custom fields</div><pre style="white-space:pre-wrap;overflow:auto;font-size:12px;margin:0">${esc(JSON.stringify(l.record, null, 2))}</pre>`) : '');
}

/* ---- Actions ---- */
function tabActions(tb, u, id) {
  tb.innerHTML =
    card(`<div class="section-title" style="margin-top:0">Account</div><div class="toolbar" style="margin:0">
      ${btn('Set password', { act: 'pw', cls: 'btn-primary' })}
      ${btn('Set role', { act: 'role' })}
      ${btn('Set batch', { act: 'batch' })}
    </div>`) +
    card(`<div class="section-title" style="margin-top:0">Danger zone</div><div class="toolbar" style="margin:0">
      ${u.is_active ? btn('Deactivate account', { act: 'deact', cls: 'btn-danger' }) : '<span class="muted">Account is already deactivated.</span>'}
      ${btn('Delete permanently', { act: 'purge', cls: 'btn-danger' })}
    </div><p class="stub" style="margin-top:10px">Deactivate disables sign-in. Delete permanently removes the account and all its data — irreversible.</p>`);
  wire(tb, {
    acts: {
      pw: () => formModal({
        title: 'Set a new password', sub: 'Minimum 8 characters',
        fields: [{ name: 'password', label: 'New password', type: 'password', required: true, hint: 'min 8 chars' }], submitLabel: 'Set password',
        async onSubmit(v) { if ((v.password || '').length < 8) return 'Password must be at least 8 characters'; await api(`/manage/users/${id}/password`, { method: 'POST', body: { password: v.password } }); toast('Password updated', 'good'); },
      }),
      role: () => formModal({
        title: 'Set role', sub: 'Managers can only assign student or instructor.',
        fields: [{ name: 'role', label: 'Role', type: 'select', value: u.role, options: ROLE_OPTIONS }], submitLabel: 'Save role',
        async onSubmit(v) { await api(`/manage/users/${id}/role`, { method: 'POST', body: { role: v.role } }); toast('Role updated', 'good'); reloadStudent(id, 'actions'); },
      }),
      batch: () => formModal({
        title: 'Set batch', sub: 'Batch codes are uppercased. Leave blank to clear.',
        fields: [{ name: 'batch', label: 'Batch code', value: u.batch || '', placeholder: 'e.g. B12' }], submitLabel: 'Save batch',
        async onSubmit(v) { await api(`/manage/users/${id}/batch`, { method: 'POST', body: { batch: (v.batch || '').trim() || null } }); toast('Batch updated', 'good'); reloadStudent(id, 'actions'); },
      }),
      deact: async () => { if (await confirmModal(`Deactivate ${u.full_name || 'this user'}? They won’t be able to sign in.`, { danger: true, confirmLabel: 'Deactivate' })) { await api(`/manage/users/${id}`, { method: 'DELETE' }); toast('Account deactivated'); reloadStudent(id, 'actions'); } },
      purge: async () => { if (await confirmModal(`Permanently delete ${u.full_name || 'this user'} and ALL their data? This cannot be undone.`, { danger: true, confirmLabel: 'Delete forever' })) { await api(`/manage/users/${id}/permanent`, { method: 'DELETE' }); toast('Account deleted'); window.__students = null; go('#/students'); } },
    },
  });
}
