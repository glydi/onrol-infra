/* Groups — student groups for scoped enrollment/announcements. Admin-only.
 * Dedicated section lifted out of the Staff → Groups tab. The API exposes only
 * create / add-member / batch-enroll (all POST) and has NO "list groups" GET,
 * so we keep a session-scoped in-memory list of the groups created here and act
 * on those. Names are prefixed `grp*` to avoid collisions with view-staff.js
 * (which defines its own SESSION_GROUPS / newGroup / addMember / enrollGroup).
 * Uses ONLY the window-exposed helpers from core.js. */
'use strict';

/* Session-scoped memory of groups this admin created: { id, name, type, added }.
 * `added` counts members added during this session (best-effort UI feedback). */
const grpSESSION = [];

const grpTYPE_LABEL = { department: 'Department', cohort: 'Cohort', team: 'Team' };
const grpTypeOpts = () => [
  { value: 'department', label: 'Department' },
  { value: 'cohort', label: 'Cohort' },
  { value: 'team', label: 'Team' },
];

registerView('groups', async (content, ctx) => {
  ctx.setCrumbs('Groups');
  if (!isAdmin()) {
    content.innerHTML = pageHead({ title: 'Groups' }) +
      emptyState('Admins only', 'This section is limited to managers and superadmins.');
    return;
  }

  content.innerHTML =
    pageHead({
      title: 'Groups',
      sub: 'Student groups for scoped enrollment & announcements',
      actions: btn('+ New group', { act: 'new', cls: 'btn-primary' }),
    }) +
    `<div class="stub" style="margin:-2px 0 14px">The API has no “list groups” endpoint yet, so this shows only the groups you create in this session. A persistent list needs a backend <code>GET /manage/groups</code>.</div>` +
    `<div id="grpList"></div>`;

  const render = () => {
    const host = content.querySelector('#grpList');
    if (!host) return;
    host.innerHTML = dataTable({
      empty: 'No groups created in this session — create one to add members or batch-enroll a cohort.',
      columns: [
        { label: 'Group', render: g => `<b>${esc(g.name)}</b>` + (g.type ? ' ' + tag(grpTYPE_LABEL[g.type] || g.type) : '') + `<div class="sub">ID ${esc(g.id)}</div>` },
        { label: 'Members added', render: g => g.added ? String(g.added) : '<span class="muted">—</span>' },
        { label: '', cls: 'right', render: g =>
            btn('Add member', { act: 'mem', id: g.id, cls: 'btn-sm btn-ghost' }) + ' ' +
            btn('Enroll into course', { act: 'enr', id: g.id, cls: 'btn-sm btn-ghost' }) },
      ],
      rows: grpSESSION,
    });
    wire(host, { acts: {
      mem: id => grpAddMember(grpFind(id), render),
      enr: id => grpEnrollGroup(grpFind(id)),
    } });
  };

  // Header "+ New group" (pageHead action lives outside #grpList, wire directly).
  const newBtn = content.querySelector('[data-act=new]');
  if (newBtn) newBtn.onclick = () => grpNewGroup(g => { if (g) { grpSESSION.unshift(g); render(); } });

  render();
});

const grpFind = id => grpSESSION.find(g => String(g.id) === String(id));

/* Create a group → POST /manage/groups  body: { name, type, parent_id? }
 * Returns { id, name } (201). Capture the id into the session list. */
function grpNewGroup(done) {
  const parentOpts = [{ value: '', label: '— none (top-level) —' },
    ...grpSESSION.map(g => ({ value: g.id, label: g.name }))];
  formModal({
    title: 'New group', sub: 'A department / cohort you can scope managers to or batch-enroll.',
    fields: [
      { name: 'name', label: 'Name', required: true, placeholder: 'e.g. Batch A — Data Science' },
      { name: 'type', label: 'Type', type: 'select', value: 'department', options: grpTypeOpts() },
      ...(grpSESSION.length ? [{ name: 'parent_id', label: 'Parent group', type: 'select', value: '', hint: 'optional — makes this a sub-group', options: parentOpts }] : []),
    ],
    submitLabel: 'Create group',
    async onSubmit(v) {
      const body = { name: v.name, type: v.type };
      if (v.parent_id) body.parent_id = v.parent_id;
      const r = await api('/manage/groups', { method: 'POST', body });
      toast('Group created', 'good');
      done && done({ id: r.id, name: r.name || v.name, type: v.type, added: 0 });
    },
  });
}

/* Add a member → POST /manage/groups/:id/members  body: { user_id, leader }
 * Picks a user from GET /manage/users; `leader` maps to role_in_group=leader. */
async function grpAddMember(g, done) {
  if (!g) return;
  let users = [];
  try { users = arr(await api('/manage/users'), 'users'); }
  catch (e) { toast(e.message || 'Could not load users', 'bad'); return; }
  if (!users.length) { toast('No users to add.'); return; }
  formModal({
    title: 'Add member', sub: g.name,
    fields: [
      { name: 'user_id', label: 'User', type: 'select', options: users.map(u => ({ value: u.id, label: `${u.full_name || u.email || u.username || u.id}${u.role ? ' — ' + u.role : ''}` })) },
      { name: 'leader', label: 'Make group leader', type: 'toggle', value: false },
    ],
    submitLabel: 'Add to group',
    async onSubmit(v) {
      if (!v.user_id) return 'Pick a user.';
      await api('/manage/groups/' + g.id + '/members', { method: 'POST', body: { user_id: v.user_id, leader: v.leader } });
      g.added = (g.added || 0) + 1;
      toast(v.leader ? 'Leader added' : 'Member added', 'good');
      done && done();
    },
  });
}

/* Batch-enroll → POST /manage/groups/:id/batch-enroll  body: { course_id }
 * Picks a course from GET /manage/courses; returns { newly_enrolled }. */
async function grpEnrollGroup(g) {
  if (!g) return;
  let courses = [];
  try { courses = arr(await api('/manage/courses'), 'courses'); }
  catch (e) { toast(e.message || 'Could not load courses', 'bad'); return; }
  if (!courses.length) { toast('No courses available.'); return; }
  formModal({
    title: 'Enroll group into course', sub: g.name,
    fields: [{ name: 'course_id', label: 'Course', type: 'select', options: courses.map(c => ({ value: c.id, label: c.title || c.label || c.id })) }],
    submitLabel: 'Enroll all members',
    async onSubmit(v) {
      if (!v.course_id) return 'Pick a course.';
      const r = await api('/manage/groups/' + g.id + '/batch-enroll', { method: 'POST', body: { course_id: v.course_id } });
      toast((r.newly_enrolled ?? 0) + ' member(s) enrolled', 'good');
    },
  });
}
