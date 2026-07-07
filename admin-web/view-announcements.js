/* Announcements — broadcast list + compose. Admin-only. */
'use strict';

registerView('announcements', async (content, ctx) => {
  ctx.setCrumbs('Announcements');
  const items = arr(await api('/manage/announcements').catch(() => ({})), 'announcements');
  content.innerHTML = pageHead({
    title: 'Announcements', sub: `${items.length} posted`,
    actions: isAdmin() ? btn('+ New announcement', { act: 'new', cls: 'btn-primary' }) : '',
  }) + dataTable({
    clickable: true, empty: 'No announcements yet.',
    columns: [
      { label: 'Title', render: a => `<b>${esc(a.title || 'Untitled')}</b>${a.body ? `<div class="sub">${esc((a.body || '').slice(0, 90))}${(a.body || '').length > 90 ? '…' : ''}</div>` : ''}` },
      { label: 'Audience', render: audienceCell },
      { label: 'Author', render: a => esc(a.author || '—') },
      { label: 'When', render: a => `<span class="muted">${esc(timeAgo(a.at) || fmtDate(a.at))}</span>` },
      { label: '', cls: 'right', render: a => isAdmin() ? btn('Delete', { act: 'del', id: a.id, cls: 'btn-sm btn-danger' }) : '' },
    ], rows: items,
  });
  wire(content, {
    rowClick: id => readAnnouncement(items.find(a => String(a.id) === String(id))),
    acts: {
      new: () => newAnnouncement(),
      del: id => delAnnouncement(id),
    },
  });
});

/* Neutral chip describing who an announcement reaches. */
function audienceCell(a) {
  if (a.course) return tag('Course: ' + a.course);
  const aud = a.audience || 'all';
  if (aud === 'batch') return tag('Batch ' + (a.batch_number || '?'));
  if (aud === 'role') return tag(a.role || 'role');
  return pill('info', 'Everyone');
}

const reloadAnnouncements = () => VIEWS.announcements(document.getElementById('content'), { setCrumbs, params: [] });

async function newAnnouncement() {
  const courses = await api('/manage/courses').then(d => arr(d, 'courses')).catch(() => []);
  formModal({
    title: 'New announcement', wide: true, submitLabel: 'Post announcement',
    fields: [
      { name: 'title', label: 'Title', required: true, placeholder: 'e.g. Live class rescheduled' },
      { name: 'body', label: 'Body', type: 'textarea', rows: 6, hint: 'plain text / markdown', placeholder: 'Write the announcement…' },
      { name: 'audience', label: 'Audience', type: 'select', value: 'all', options: [
        { value: 'all', label: 'Everyone' },
        { value: 'course', label: 'A course (enrolled students)' },
        { value: 'batch', label: 'A batch' },
        { value: 'role', label: 'A role' },
      ] },
      { name: 'course_id', label: 'Course', type: 'select', hint: 'used when audience = course', options: [{ value: '', label: '— choose a course —' }, ...courses.map(c => ({ value: c.id, label: c.title || c.label || c.id }))] },
      { name: 'batch_number', label: 'Batch', hint: 'used when audience = batch', placeholder: 'e.g. 12' },
      { name: 'role', label: 'Role', type: 'select', hint: 'used when audience = role', options: [
        { value: '', label: '— choose a role —' },
        { value: 'student', label: 'Students' },
        { value: 'instructor', label: 'Instructors' },
        { value: 'manager', label: 'Managers' },
      ] },
    ],
    async onSubmit(v) {
      const body = { title: v.title, body: v.body || '' };
      if (v.audience === 'course') {
        if (!v.course_id) return 'Choose a course for a course announcement';
        body.course_id = v.course_id;
      } else if (v.audience === 'batch') {
        if (!v.batch_number) return 'Batch is required for a batch announcement';
        body.audience = 'batch'; body.batch_number = String(v.batch_number);
      } else if (v.audience === 'role') {
        if (!v.role) return 'Choose a role for a role announcement';
        body.audience = 'role'; body.role = v.role;
      } else {
        body.audience = 'all';
      }
      await api('/manage/announcements', { method: 'POST', body });
      toast('Announcement posted', 'good');
      reloadAnnouncements();
    },
  });
}

async function delAnnouncement(id) {
  if (!await confirmModal('Delete this announcement? Recipients keep any notification already sent.', { danger: true, confirmLabel: 'Delete' })) return;
  await api('/manage/announcements/' + id, { method: 'DELETE' });
  toast('Announcement deleted');
  reloadAnnouncements();
}

/* Read view — full body + metadata, with a delete affordance for admins. */
function readAnnouncement(a) {
  if (!a) return;
  openModal({
    title: a.title || 'Announcement', wide: true,
    bodyHtml: dl([
      ['Audience', audienceCell(a)],
      ['Author', esc(a.author || '—')],
      ['Posted', esc(fmtDateTime(a.at)) + (timeAgo(a.at) ? ` <span class="muted">(${esc(timeAgo(a.at))})</span>` : '')],
    ]) + `<div class="card" style="margin-top:12px;white-space:pre-wrap">${esc(a.body || '') || '<span class="muted">No body.</span>'}</div>`,
    footHtml: (isAdmin() ? `<button class="btn btn-danger" data-x="del">Delete</button>` : '') + `<button class="btn btn-ghost" data-x="c">Close</button>`,
    onMount(root, close) {
      root.querySelector('[data-x=c]').onclick = close;
      const d = root.querySelector('[data-x=del]');
      if (d) d.onclick = () => { close(); delAnnouncement(a.id); };
    },
  });
}
