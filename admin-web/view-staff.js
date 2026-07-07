/* Staff & Access — instructors / managers / live-hosts: add, set role, set
 * password, deactivate/delete, and (session) group scoping. Admin-only. */
'use strict';

const STAFF_TABS = [['people', 'Staff'], ['groups', 'Groups']];
const STAFF_ROLES = ['instructor', 'manager', 'superadmin', 'live_host'];
const ROLE_LABEL = { instructor: 'Instructor', manager: 'Manager', superadmin: 'Superadmin', live_host: 'Live host', student: 'Student' };
const ROLE_CLASS = { superadmin: 'bad', manager: 'info', instructor: 'good', live_host: 'warn', student: 'draft' };
const rolePill = r => `<span class="pill ${ROLE_CLASS[r] || 'info'}">${esc(ROLE_LABEL[r] || r || '—')}</span>`;
const roleOpts = roles => roles.map(r => ({ value: r, label: ROLE_LABEL[r] || r }));
// Roles the caller may grant. Backend enforces this too (managers can only
// assign student/instructor/live_host; only a superadmin mints managers/superadmins).
const assignableRoles = () => USER.role === 'superadmin'
  ? ['student', 'instructor', 'live_host', 'manager', 'superadmin']
  : ['student', 'instructor', 'live_host'];
const creatableStaffRoles = () => USER.role === 'superadmin'
  ? ['instructor', 'live_host', 'manager', 'superadmin']
  : ['instructor', 'live_host'];

registerView('staff', async (content, ctx) => {
  ctx.setCrumbs('Staff & Access');
  if (!isAdmin()) {
    content.innerHTML = pageHead({ title: 'Staff & Access' }) + emptyState('Admins only', 'This section is limited to managers and superadmins.');
    return;
  }
  const tab = ctx.params[0] === 'groups' ? 'groups' : 'people';
  content.innerHTML =
    pageHead({ title: 'Staff & Access', sub: 'Instructors, managers & live-hosts — roles, passwords, access' }) +
    `<div class="tabs">${STAFF_TABS.map(([k, l]) => `<div class="tab ${k === tab ? 'active' : ''}" data-t="${k}">${l}</div>`).join('')}</div><div id="tb"></div>`;
  content.querySelectorAll('.tab').forEach(t => t.onclick = () => go('#/staff/' + t.dataset.t));
  (tab === 'groups' ? tabGroups : tabStaff)(content.querySelector('#tb'));
});

/* ---- Staff list: /manage/users filtered to staff roles (shows status; a
 * superset of /manage/instructors, which is active instructors only). ---- */
async function tabStaff(tb) {
  const users = arr(await api('/manage/users').catch(() => ({})), 'users');
  const staff = users.filter(u => STAFF_ROLES.includes(u.role));
  let q = '';
  const byId = id => staff.find(u => String(u.id) === String(id));
  const render = () => {
    const rows = q ? staff.filter(u => `${u.full_name || ''} ${u.email || ''} ${u.username || ''} ${u.login_id || ''}`.toLowerCase().includes(q)) : staff;
    const host = tb.querySelector('#stafftbl');
    host.innerHTML = dataTable({
      empty: q ? 'No staff match your search.' : 'No staff yet — add an instructor, manager or live-host.',
      columns: [
        { label: 'Name', render: u => `<b>${esc(u.full_name || '—')}</b>` + (u.email ? `<div class="sub">${esc(u.email)}</div>` : (u.username ? `<div class="sub">${esc(u.username)}</div>` : '')) + (u.login_id ? `<div class="sub">ID ${esc(u.login_id)}</div>` : '') },
        { label: 'Role', render: u => rolePill(u.role) },
        { label: 'Status', render: u => u.is_active ? pill('active', 'Active') : pill('inactive', 'Inactive') },
        { label: '', cls: 'right', render: u =>
            btn('Role', { act: 'role', id: u.id, cls: 'btn-sm btn-ghost' }) + ' ' +
            btn('Password', { act: 'pw', id: u.id, cls: 'btn-sm btn-ghost' }) + ' ' +
            (u.is_active ? btn('Deactivate', { act: 'off', id: u.id, cls: 'btn-sm btn-ghost' }) + ' ' : '') +
            btn('Delete', { act: 'del', id: u.id, cls: 'btn-sm btn-danger' }) },
      ], rows,
    });
    wire(host, { acts: {
      role: id => setRole(byId(id), () => tabStaff(tb)),
      pw: id => setPassword(byId(id), () => tabStaff(tb)),
      off: async id => { const u = byId(id); if (await confirmModal('Deactivate ' + (u?.full_name || 'this account') + '? They will no longer be able to sign in.', { danger: true, confirmLabel: 'Deactivate' })) { await api('/manage/users/' + id, { method: 'DELETE' }); toast('Account deactivated'); tabStaff(tb); } },
      del: async id => { const u = byId(id); if (await confirmModal('Permanently delete ' + (u?.full_name || 'this account') + '? This removes the account and all its data. This cannot be undone.', { danger: true, confirmLabel: 'Delete forever' })) { await api('/manage/users/' + id + '/permanent', { method: 'DELETE' }); toast('Account deleted'); tabStaff(tb); } },
    } });
  };
  tb.innerHTML =
    `<div class="toolbar"><input id="staffq" class="grow" placeholder="Search staff by name or email…"><button class="btn btn-primary" data-act="add">+ Add staff</button><button class="btn btn-ghost" data-act="group">+ New group</button></div><div id="stafftbl"></div>`;
  tb.querySelector('#staffq').oninput = e => { q = e.target.value.trim().toLowerCase(); render(); };
  tb.querySelector('[data-act=add]').onclick = () => addStaff(() => tabStaff(tb));
  tb.querySelector('[data-act=group]').onclick = () => newGroup(g => { if (g) SESSION_GROUPS.unshift(g); go('#/staff/groups'); });
  render();
}

function addStaff(done) {
  formModal({
    title: 'Add staff member', sub: 'Creates an account. Password defaults to onrol@ai unless you set one.',
    fields: [
      { name: 'full_name', label: 'Full name', required: true, placeholder: 'e.g. Priya Nair' },
      { name: 'role', label: 'Role', type: 'select', value: 'instructor', options: roleOpts(creatableStaffRoles()) },
      { name: 'email', label: 'Email', type: 'email', hint: 'email or phone required', placeholder: 'name@example.com' },
      { name: 'phone', label: 'Phone', hint: 'optional', placeholder: '+91…' },
      { name: 'password', label: 'Password', type: 'password', hint: 'optional — min 8; defaults to onrol@ai' },
    ], submitLabel: 'Create staff',
    async onSubmit(v) {
      if (!String(v.email || '').trim() && !String(v.phone || '').trim()) return 'An email or phone number is required.';
      if (v.password && v.password.length < 8) return 'Password must be at least 8 characters.';
      await api('/manage/users', { method: 'POST', body: { full_name: v.full_name, email: v.email, phone: v.phone, password: v.password, role: v.role } });
      toast('Staff member added', 'good'); done && done();
    },
  });
}

function setRole(u, done) {
  if (!u) return;
  formModal({
    title: 'Set role', sub: u.full_name || u.email || '',
    fields: [{ name: 'role', label: 'Role', type: 'select', value: u.role, options: roleOpts(assignableRoles()) }],
    submitLabel: 'Update role',
    async onSubmit(v) {
      await api('/manage/users/' + u.id + '/role', { method: 'POST', body: { role: v.role } });
      toast('Role updated', 'good'); done && done();
    },
  });
}

function setPassword(u, done) {
  if (!u) return;
  formModal({
    title: 'Set password', sub: u.full_name || u.email || '',
    fields: [{ name: 'password', label: 'New password', type: 'password', required: true, hint: 'min 8 characters' }],
    submitLabel: 'Set password',
    async onSubmit(v) {
      if (!v.password || v.password.length < 8) return 'Password must be at least 8 characters.';
      await api('/manage/users/' + u.id + '/password', { method: 'POST', body: { password: v.password } });
      toast('Password updated', 'good'); done && done();
    },
  });
}

/* ---- Groups: scope + batch-enroll. The API exposes create / add-member /
 * batch-enroll (POST) but no "list groups" endpoint, so we track groups created
 * during this session and act on those. ---- */
const SESSION_GROUPS = []; // { id, name }

async function tabGroups(tb) {
  const render = () => {
    const host = tb.querySelector('#grouplist');
    host.innerHTML = dataTable({
      empty: 'No groups created in this session.',
      columns: [
        { label: 'Group', render: g => `<b>${esc(g.name)}</b><div class="sub">ID ${esc(g.id)}</div>` },
        { label: '', cls: 'right', render: g => btn('Add member', { act: 'mem', id: g.id, cls: 'btn-sm btn-ghost' }) + ' ' + btn('Enroll into course', { act: 'enr', id: g.id, cls: 'btn-sm btn-ghost' }) },
      ], rows: SESSION_GROUPS,
    });
    wire(host, { acts: {
      mem: id => addMember(SESSION_GROUPS.find(g => g.id === id)),
      enr: id => enrollGroup(SESSION_GROUPS.find(g => g.id === id)),
    } });
  };
  tb.innerHTML =
    `<div class="toolbar"><div class="grow"><span class="muted">Groups scope which students a manager oversees and let you enroll a whole cohort into a course at once.</span></div><button class="btn btn-primary" data-act="new">+ New group</button></div>` +
    `<div class="stub" style="margin:-4px 0 14px">Note: the API has no “list groups” endpoint, so this lists groups created during this session — add members or batch-enroll them here.</div><div id="grouplist"></div>`;
  tb.querySelector('[data-act=new]').onclick = () => newGroup(g => { if (g) { SESSION_GROUPS.unshift(g); render(); } });
  render();
}

function newGroup(done) {
  formModal({
    title: 'New group', sub: 'A department / cohort you can scope managers to or batch-enroll.',
    fields: [
      { name: 'name', label: 'Name', required: true, placeholder: 'e.g. Batch A — Data Science' },
      { name: 'type', label: 'Type', type: 'select', value: 'department', options: [
        { value: 'department', label: 'Department' }, { value: 'cohort', label: 'Cohort' }, { value: 'team', label: 'Team' },
      ] },
    ], submitLabel: 'Create group',
    async onSubmit(v) {
      const r = await api('/manage/groups', { method: 'POST', body: { name: v.name, type: v.type } });
      toast('Group created', 'good'); done && done({ id: r.id, name: r.name || v.name });
    },
  });
}

async function addMember(g) {
  if (!g) return;
  const users = arr(await api('/manage/users').catch(() => ({})), 'users');
  formModal({
    title: 'Add member', sub: g.name,
    fields: [
      { name: 'user_id', label: 'User', type: 'select', options: users.map(u => ({ value: u.id, label: `${u.full_name || u.email || u.id} — ${ROLE_LABEL[u.role] || u.role}` })) },
      { name: 'leader', label: 'Make group leader', type: 'toggle', value: false },
    ], submitLabel: 'Add to group',
    async onSubmit(v) {
      if (!v.user_id) return 'Pick a user.';
      await api('/manage/groups/' + g.id + '/members', { method: 'POST', body: { user_id: v.user_id, leader: v.leader } });
      toast('Member added', 'good');
    },
  });
}

async function enrollGroup(g) {
  if (!g) return;
  const courses = arr(await api('/manage/courses').catch(() => ({})), 'courses');
  formModal({
    title: 'Batch-enroll group', sub: g.name,
    fields: [{ name: 'course_id', label: 'Course', type: 'select', options: courses.map(c => ({ value: c.id, label: c.title || c.label || c.id })) }],
    submitLabel: 'Enroll all members',
    async onSubmit(v) {
      if (!v.course_id) return 'Pick a course.';
      const r = await api('/manage/groups/' + g.id + '/batch-enroll', { method: 'POST', body: { course_id: v.course_id } });
      toast((r.newly_enrolled ?? 0) + ' member(s) enrolled', 'good');
    },
  });
}
