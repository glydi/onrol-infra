/* Roles & Permissions — a read-only reference matrix of the REAL roles (what
 * each can actually reach in this console) plus the one real control: assigning
 * a user's role. Access descriptions are derived from the admin:true NAV gating
 * in core.js and the RequireRole / RequireAnyRole gates in router.go; the
 * assignable-role list mirrors handlers.SetUserRole (managers may grant
 * student/instructor/live_host; only a superadmin mints managers/superadmins —
 * the server enforces this regardless, and any error surfaces in the modal).
 * Permissions are role-based in code, so there is deliberately no per-permission
 * editor. Admin-only (managers & superadmins). */
'use strict';

/* Human labels + pill colours for every role the backend knows
 * (middleware/auth.go: roleRank student/instructor/manager/superadmin, plus the
 * parallel RequireAnyRole portal roles live_host/ambassador/employee/franchise). */
const roleName = {
  superadmin: 'Superadmin', manager: 'Manager', instructor: 'Instructor',
  live_host: 'Live host', student: 'Student',
  franchise_partner: 'Franchise partner', ambassador: 'Ambassador', employee: 'Employee',
};
const roleColor = {
  superadmin: 'bad', manager: 'info', instructor: 'good', live_host: 'warn',
  student: 'draft', franchise_partner: 'info', ambassador: 'info', employee: 'info',
};
const rolePillTag = slug => pill(roleColor[slug] || 'info', roleName[slug] || slug);
const roleAccessPill = a => a === 'full' ? pill('good', 'Full')
  : a === 'limited' ? pill('warn', 'Limited') : pill('inactive', 'No access');

/* The reference matrix. `access` = how much of THIS console the role reaches;
 * `can` = what that means; `grant` = which roles it may assign here. */
const roleDefs = [
  { role: 'superadmin', access: 'full',
    can: 'Every section — Academics, Learners, Engagement, Media Library, Team & Access, Reports. Sees all users.',
    grant: 'Any role: student, instructor, live host, manager, superadmin.' },
  { role: 'manager', access: 'full',
    can: 'Full admin — the same sections a superadmin sees. The user list is scoped to their groups on the server.',
    grant: 'Student, instructor, live host. Never manager or superadmin.' },
  { role: 'instructor', access: 'limited',
    can: 'Teaching only — Dashboard, Courses, Live Classes, Assessments, Certificates, Ask Mentor, Reports, Profile. The admin-gated groups (Learners, Engagement, Media Library, Team & Access) are hidden.',
    grant: 'None — cannot open Roles & Permissions.' },
  { role: 'live_host', access: 'none',
    can: 'No console access — sign-in is staff-only. Hosts assigned live sessions (answers Q&A + watches) in the student/live app.',
    grant: 'None.' },
  { role: 'student', access: 'none',
    can: 'No console access. Learner role — the student app only. Default role for new accounts.',
    grant: 'None.' },
  { role: 'franchise_partner', access: 'none',
    can: 'No console access. Separate Franchise Partner portal (records enrollments).',
    grant: 'None.' },
  { role: 'ambassador', access: 'none',
    can: 'No console access. Separate Ambassador portal (submits referrals).',
    grant: 'None.' },
  { role: 'employee', access: 'none',
    can: 'No console access. Accounts / Administration & College Partner portals.',
    grant: 'None.' },
];

/* Roles the signed-in admin may grant — mirrors handlers.SetUserRole. */
const roleAssignable = () => USER.role === 'superadmin'
  ? ['student', 'instructor', 'live_host', 'manager', 'superadmin']
  : ['student', 'instructor', 'live_host'];

registerView('roles', async (content, ctx) => {
  ctx.setCrumbs('Roles & Permissions');
  if (!isAdmin()) {
    content.innerHTML = pageHead({ title: 'Roles & Permissions' }) +
      emptyState('Admins only', 'This section is limited to managers and superadmins.');
    return;
  }
  const users = arr(await api('/manage/users').catch(() => ({})), 'users');
  content.innerHTML =
    pageHead({ title: 'Roles & Permissions', sub: 'The real roles, what each can reach here, and role assignment' }) +
    `<div class="section-title">Role reference</div>` +
    roleMatrixHtml() +
    card(`<div class="stub">Permissions are role-based in code — there is no per-permission editor. This matrix is the source of truth; assigning a role below is the one real control, and the server re-checks every change.</div>`) +
    `<div class="section-title" style="margin-top:24px">Assign roles</div>` +
    `<div class="toolbar"><input id="roleq" class="grow" placeholder="Search users by name, email or role…"><span class="muted">${users.length} user(s)</span></div>` +
    `<div id="roletbl"></div>`;
  roleRenderUsers(content, users, '');
  content.querySelector('#roleq').oninput = e => roleRenderUsers(content, users, e.target.value.trim().toLowerCase());
});

function roleMatrixHtml() {
  return dataTable({
    columns: [
      { label: 'Role', render: d => `<b>${esc(roleName[d.role] || d.role)}</b> <code class="keepcase muted">${esc(d.role)}</code>` },
      { label: 'Console', render: d => roleAccessPill(d.access) },
      { label: 'What they can reach here', render: d => esc(d.can) },
      { label: 'Can grant', render: d => esc(d.grant) },
    ],
    rows: roleDefs,
  });
}

function roleRenderUsers(content, users, q) {
  const host = content.querySelector('#roletbl');
  if (!host) return;
  const byId = id => users.find(u => String(u.id) === String(id));
  const rows = q
    ? users.filter(u => `${u.full_name || ''} ${u.email || ''} ${u.username || ''} ${u.login_id || ''} ${u.role || ''}`.toLowerCase().includes(q))
    : users;
  host.innerHTML = dataTable({
    empty: q ? 'No users match your search.' : 'No users yet.',
    columns: [
      { label: 'Name', render: u => `<b>${esc(u.full_name || '—')}</b>` +
          (u.email ? `<div class="sub">${esc(u.email)}</div>` : (u.username ? `<div class="sub">${esc(u.username)}</div>` : '')) +
          (u.login_id ? `<div class="sub keepcase">ID ${esc(u.login_id)}</div>` : '') },
      { label: 'Role', render: u => rolePillTag(u.role) },
      { label: 'Status', render: u => u.is_active ? pill('active', 'Active') : pill('inactive', 'Inactive') },
      { label: '', cls: 'right', render: u => btn('Change role', { act: 'role', id: u.id, cls: 'btn-sm btn-ghost' }) },
    ],
    rows,
  });
  wire(host, { acts: { role: id => roleChange(byId(id), () => roleRenderUsers(content, users, q)) } });
}

function roleChange(u, done) {
  if (!u) return;
  const opts = roleAssignable();
  formModal({
    title: 'Change role', sub: (u.full_name || u.email || u.id) + ' — currently ' + (roleName[u.role] || u.role),
    fields: [{
      name: 'role', label: 'New role', type: 'select',
      value: opts.includes(u.role) ? u.role : opts[0],
      options: opts.map(r => ({ value: r, label: roleName[r] || r })),
      hint: USER.role === 'superadmin' ? 'Superadmins may assign any role.' : 'Managers may assign student, instructor or live host.',
    }],
    submitLabel: 'Update role',
    async onSubmit(v) {
      // Backend re-enforces (403 if a manager targets manager/superadmin, or the
      // user is out of scope) — the thrown error surfaces in the modal.
      const r = await api('/manage/users/' + u.id + '/role', { method: 'POST', body: { role: v.role } });
      u.role = r.role || v.role;
      toast('Role updated', 'good'); done && done();
    },
  });
}
