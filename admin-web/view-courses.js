/* Courses — the reference section. list → detail (tabs). Copy this pattern. */
'use strict';

registerView('courses', async (content, ctx) => {
  if (ctx.params[0]) return courseDetail(content, ctx, ctx.params[0], ctx.params[1] || 'curriculum');
  ctx.setCrumbs('Courses');
  const courses = arr(await api('/manage/courses'), 'courses');
  content.innerHTML = pageHead({
    title: 'Courses', sub: `${courses.length} total`,
    actions: isAdmin() ? btn('+ New course', { act: 'new', cls: 'btn-primary' }) : '',
  }) + dataTable({
    clickable: true, empty: 'No courses yet.',
    columns: [
      { label: 'Title', render: c => `<b>${esc(c.title || 'Untitled')}</b>` },
      { label: 'Course ID', render: c => `<span class="muted">${esc(c.label || c.id)}</span>` },
      { label: 'Status', render: c => pill(c.status || 'draft') },
      { label: 'Enrollment', render: c => esc(c.enroll_type || '—') },
    ], rows: courses,
  });
  wire(content, {
    rowClick: id => go('#/courses/' + id),
    acts: { new: () => newCourse() },
  });
});

async function newCourse() {
  const insts = await api('/manage/instructors').then(d => arr(d, 'instructors')).catch(() => []);
  formModal({
    title: 'New course', fields: [
      { name: 'title', label: 'Title', required: true, placeholder: 'e.g. AI Generalist Program' },
      { name: 'label', label: 'Course ID (unique slug)', required: true, hint: 'lowercase, no spaces', placeholder: 'ai-generalist' },
      { name: 'description', label: 'Description', type: 'textarea' },
      { name: 'instructor_id', label: 'Instructor', type: 'select', options: [{ value: '', label: '— none —' }, ...insts.map(i => ({ value: i.id, label: i.full_name || i.email || i.id }))] },
      { name: 'enroll_type', label: 'Enrollment', type: 'select', value: 'manual', options: [{ value: 'manual', label: 'Manual (admin enrolls)' }, { value: 'self', label: 'Open (self-enroll)' }, { value: 'closed', label: 'Closed' }] },
    ], submitLabel: 'Create course',
    async onSubmit(v) { const r = await api('/manage/courses', { method: 'POST', body: v }); toast('Course created', 'good'); go('#/courses/' + (r.id || r.course_id || '')); },
  });
}

const COURSE_TABS = [['curriculum', 'Curriculum'], ['live', 'Live Classes'], ['assessments', 'Assessments'], ['students', 'Students'], ['study', 'Study Hub'], ['discussion', 'Discussion'], ['certificates', 'Certificates'], ['settings', 'Settings']];

async function courseDetail(content, ctx, id, tab) {
  const co = await api('/manage/courses/' + id);
  ctx.setCrumbs({ label: 'Courses', href: '#/courses' }, co.title || 'Course');
  content.innerHTML =
    pageHead({ title: co.title || 'Course', sub: `${co.label || id}`, actions: pill(co.status || 'draft') }) +
    `<div class="tabs">${COURSE_TABS.map(([k, l]) => `<div class="tab ${k === tab ? 'active' : ''}" data-t="${k}">${l}</div>`).join('')}</div><div id="tb"></div>`;
  content.querySelectorAll('.tab').forEach(t => t.onclick = () => go(`#/courses/${id}/${t.dataset.t}`));
  const tb = content.querySelector('#tb');
  ({ curriculum: tabCurriculum, students: tabStudents, settings: tabSettings, certificates: tabCertificates, live: tabLive, assessments: tabAssessments, study: tabStudy, discussion: tabDiscussion }[tab] || (() => tb.innerHTML = emptyState('—')))(tb, co, id);
}

/* ---- Curriculum ---- */
function tabCurriculum(tb, co) {
  const mods = co.modules || [];
  const renderMod = m => {
    const labels = m.day_labels || {}, byDay = {};
    (m.lessons || []).forEach(l => { const d = l.day_number ?? 'null'; (byDay[d] = byDay[d] || []).push(l); });
    const keys = Object.keys(byDay).sort((a, b) => a === 'null' ? 1 : b === 'null' ? -1 : a - b);
    const days = keys.map(k => {
      const nm = k === 'null' ? 'Unscheduled' : (labels[k] || 'Day ' + k);
      const items = byDay[k].map(l => `<div class="lesson"><span class="type">${esc(l.type || 'lesson')}</span><span style="flex:1">${esc(l.title || '')}</span>${l.is_published === false ? pill('draft', 'hidden') : ''} ${btn('✕', { act: 'dellesson', id: l.id, cls: 'btn-sm btn-ghost', title: 'Delete lesson' })}</div>`).join('');
      const rename = k === 'null' ? '' : btn('✎', { act: 'day', id: m.id + '|' + k, cls: 'btn-sm btn-ghost', title: 'Rename day' });
      return `<div class="day"><div class="day-name">${esc(nm)} ${rename}</div>${items}</div>`;
    }).join('');
    const subs = (m.submodules || []).map(renderMod).join('');
    return `<div class="module"><div class="module-head open"><span class="chev">▸</span>${esc(m.title || 'Module')}<span class="count">${(m.lessons || []).length} lesson(s)</span>
      ${btn('+ Lesson', { act: 'addlesson', id: m.id, cls: 'btn-sm' })} ${btn('✕', { act: 'delmod', id: m.id, cls: 'btn-sm btn-ghost' })}</div>
      <div class="module-body">${days || '<div class="day"><span class="muted">No lessons yet.</span></div>'}${subs}</div></div>`;
  };
  tb.innerHTML = `<div class="toolbar"><div class="grow"></div>${btn('+ Add module', { act: 'addmod', cls: 'btn-primary' })}</div>` +
    (mods.length ? mods.map(renderMod).join('') : emptyState('No modules yet', 'Add your first module to start building the curriculum.'));
  tb.querySelectorAll('.module-head').forEach(h => h.addEventListener('click', e => { if (e.target.closest('[data-act]')) return; h.classList.toggle('open'); h.nextElementSibling.style.display = h.classList.contains('open') ? '' : 'none'; }));
  wire(tb, { acts: {
    addmod: () => formModal({ title: 'Add module', fields: [{ name: 'title', label: 'Module title', required: true }], async onSubmit(v) { await api('/manage/courses/' + co.id + '/modules', { method: 'POST', body: v }); toast('Module added', 'good'); reloadTab(co.id, 'curriculum'); } }),
    delmod: async mid => { if (await confirmModal('Delete this module and its lessons?', { danger: true, confirmLabel: 'Delete' })) { await api('/manage/modules/' + mid, { method: 'DELETE' }); toast('Module deleted'); reloadTab(co.id, 'curriculum'); } },
    addlesson: mid => formModal({ title: 'Add lesson', fields: [
      { name: 'title', label: 'Title', required: true },
      { name: 'type', label: 'Type', type: 'select', value: 'text', options: [{ value: 'text', label: 'Text / notes' }, { value: 'video', label: 'Video (video id)' }, { value: 'link', label: 'External link' }, { value: 'pdf', label: 'PDF link' }] },
      { name: 'content', label: 'Content', type: 'textarea', hint: 'markdown, a URL, or a video id' },
      { name: 'day_number', label: 'Day number', type: 'number', hint: 'blank = unscheduled' },
    ], async onSubmit(v) {
      const body = { title: v.title, type: v.type, day_number: v.day_number, downloadable: true };
      if (v.type === 'video') body.video_id = v.content; else body.body = v.content;
      await api('/manage/modules/' + mid + '/lessons', { method: 'POST', body }); toast('Lesson added', 'good'); reloadTab(co.id, 'curriculum');
    } }),
    dellesson: async lid => { if (await confirmModal('Delete this lesson?', { danger: true, confirmLabel: 'Delete' })) { await api('/manage/lessons/' + lid, { method: 'DELETE' }); toast('Lesson deleted'); reloadTab(co.id, 'curriculum'); } },
    day: mk => { const [mid, day] = mk.split('|'); formModal({ title: 'Name Day ' + day, fields: [{ name: 'label', label: 'Day name', hint: 'blank restores “Day ' + day + '”' }], async onSubmit(v) { await api('/manage/modules/' + mid + '/day-label', { method: 'POST', body: { day_number: +day, label: v.label } }); toast('Day named', 'good'); reloadTab(co.id, 'curriculum'); } }); },
  } });
}
const reloadTab = (id, tab) => courseDetail(document.getElementById('content'), { setCrumbs }, id, tab);

/* ---- Students (enrolled roster) ---- */
async function tabStudents(tb, co) {
  const students = arr(await api('/manage/courses/' + co.id + '/students'), 'students');
  tb.innerHTML = `<div class="toolbar"><div class="grow"><span class="muted">${students.length} enrolled</span></div>${btn('+ Enroll student', { act: 'enroll', cls: 'btn-primary' })}</div>` +
    dataTable({ empty: 'No students enrolled.', columns: [
      { label: 'Name', render: s => `<b>${esc(s.full_name || s.name || 'Student')}</b>${s.email ? `<div class="sub">${esc(s.email)}</div>` : ''}` },
      { label: 'Batch', render: s => s.batch ? tag('Batch ' + s.batch) : '<span class="muted">—</span>' },
      { label: 'Progress', render: s => { const p = s.percent != null ? s.percent : (s.total ? Math.round(100 * (s.done || 0) / s.total) : 0); return `${p}%`; } },
      { label: 'Status', render: s => pill(s.status || 'active') },
    ], rows: students });
  wire(tb, { acts: { enroll: () => formModal({ title: 'Enroll a student', sub: 'By email, phone, login ID, or user id', fields: [{ name: 'email', label: 'Student identifier', required: true, placeholder: 'email / phone / login id' }], submitLabel: 'Enroll', async onSubmit(v) { await api('/manage/courses/' + co.id + '/enroll', { method: 'POST', body: { email: v.email } }); toast('Enrolled', 'good'); reloadTab(co.id, 'students'); } }) } });
}

/* ---- Settings ---- */
async function tabSettings(tb, co) {
  const insts = await api('/manage/instructors').then(d => arr(d, 'instructors')).catch(() => []);
  tb.innerHTML = card(dl([
    ['Title', esc(co.title)], ['Course ID', esc(co.label || co.id)], ['Status', pill(co.status || 'draft')],
    ['Enrollment', esc(co.enroll_type || '—')], ['Instructor', esc(co.instructor || '—')], ['Description', esc(co.description || '—')],
  ])) + `<div class="toolbar" style="margin-top:16px">
      ${btn('Edit details', { act: 'edit', cls: 'btn-primary' })}
      ${btn(co.status === 'published' ? 'Unpublish' : 'Publish', { act: 'pub' })}
      ${isAdmin() ? btn('Delete course', { act: 'del', cls: 'btn-danger' }) : ''}
    </div>`;
  wire(tb, { acts: {
    edit: () => formModal({ title: 'Edit course', wide: true, fields: [
      { name: 'title', label: 'Title', value: co.title, required: true },
      { name: 'label', label: 'Course ID', value: co.label },
      { name: 'description', label: 'Description', type: 'textarea', value: co.description },
      { name: 'image_url', label: 'Cover image URL', value: co.image_url },
      { name: 'instructor_id', label: 'Instructor', type: 'select', value: co.owner_id || '', options: [{ value: '', label: '— none —' }, ...insts.map(i => ({ value: i.id, label: i.full_name || i.email }))] },
      { name: 'enroll_type', label: 'Enrollment mode', type: 'select', value: co.enroll_type, options: [{ value: 'manual', label: 'Manual / approval' }, { value: 'self', label: 'Open (self-enroll)' }, { value: 'closed', label: 'Closed' }] },
    ], async onSubmit(v) { await api('/manage/courses/' + co.id, { method: 'PATCH', body: v }); toast('Saved', 'good'); reloadTab(co.id, 'settings'); } }),
    pub: async () => { await api('/manage/courses/' + co.id, { method: 'PATCH', body: { status: co.status === 'published' ? 'draft' : 'published' } }); toast('Updated', 'good'); reloadTab(co.id, 'settings'); },
    del: async () => { if (await confirmModal('Permanently delete “' + co.title + '” and all its content?', { danger: true, confirmLabel: 'Delete course' })) { await api('/manage/courses/' + co.id, { method: 'DELETE' }); toast('Course deleted'); go('#/courses'); } },
  } });
}

/* ---- Certificates ---- */
async function tabCertificates(tb, co) {
  const holders = arr(await api('/manage/courses/' + co.id + '/certificates').catch(() => ({})), 'certificates');
  tb.innerHTML = `<div class="toolbar"><div class="grow"><span class="muted">${holders.length} issued</span></div>${btn('Issue to whole course', { act: 'issueall', cls: 'btn-primary' })}</div>` +
    dataTable({ empty: 'No certificates issued yet.', columns: [
      { label: 'Student', render: h => esc(h.full_name || h.name || h.user_id) }, { label: 'Serial', render: h => `<span class="muted">${esc(h.serial || '—')}</span>` }, { label: 'Issued', render: h => esc(fmtDate(h.issued_at || h.created_at)) },
      { label: '', cls: 'right', render: h => btn('Revoke', { act: 'revoke', id: h.user_id, cls: 'btn-sm btn-danger' }) },
    ], rows: holders });
  wire(tb, { acts: {
    issueall: async () => { if (await confirmModal('Issue a certificate to every enrolled student?', { confirmLabel: 'Issue' })) { await api('/manage/courses/' + co.id + '/certificates', { method: 'POST', body: { all: true } }); toast('Issued', 'good'); reloadTab(co.id, 'certificates'); } },
    revoke: async uid => { if (await confirmModal('Revoke this certificate?', { danger: true, confirmLabel: 'Revoke' })) { await api('/manage/courses/' + co.id + '/certificates/' + uid, { method: 'DELETE' }); toast('Revoked'); reloadTab(co.id, 'certificates'); } },
  } });
}

/* ---- Live / Assessments / Study / Discussion (read + primary actions) ---- */
async function tabLive(tb, co) {
  const s = arr(await api('/manage/courses/' + co.id + '/sessions').catch(() => ({})), 'sessions');
  tb.innerHTML = `<p class="stub" style="margin-bottom:12px">Full scheduling lives in <a href="#/live" style="color:var(--accent)">Live Classes</a>.</p>` +
    dataTable({ empty: 'No live classes for this course.', columns: [
      { label: 'Title', render: x => esc(x.title || 'Live class') }, { label: 'Type', render: x => x.media_asset_id ? tag('recorded-as-live') : tag('external') },
      { label: 'Starts', render: x => esc(fmtDateTime(x.starts_at)) },
    ], rows: s });
}
async function tabAssessments(tb, co) {
  const a = arr(await api('/manage/courses/' + co.id + '/assessments').catch(() => ({})), 'assessments');
  tb.innerHTML = dataTable({ empty: 'No quizzes or assignments.', columns: [
    { label: 'Title', render: x => `<b>${esc(x.title)}</b>` }, { label: 'Type', render: x => tag(x.type || 'quiz') },
    { label: 'Questions', render: x => x.question_count ?? x.questions ?? '—' }, { label: 'Status', render: x => pill(x.is_published ? 'published' : 'draft') },
  ], rows: a }) + `<p class="stub" style="margin-top:12px">Build the question builder + grading against <code>/manage/assessments/:id/questions</code> and <code>/manage/submissions/:id/grade</code>.</p>`;
}
async function tabStudy(tb, co) {
  const s = arr(await api('/manage/courses/' + co.id + '/study').catch(() => ({})), 'study');
  tb.innerHTML = dataTable({ empty: 'No study material.', columns: [{ label: 'Title', render: x => esc(x.title) }, { label: 'Kind', render: x => tag(x.kind || '') }], rows: s });
}
async function tabDiscussion(tb, co) {
  const c = arr(await api('/manage/courses/' + co.id + '/comments').catch(() => ({})), 'comments');
  tb.innerHTML = dataTable({ empty: 'No doubts posted.', columns: [
    { label: 'Student', render: x => esc(x.author || x.name) + (x.staff ? ' ' + tag('mentor') : '') }, { label: 'Where', render: x => esc(x.module || 'General') },
    { label: 'Message', render: x => esc((x.body || '').slice(0, 80)) }, { label: '', render: x => x.is_doubt ? pill('warn', 'doubt') : '' },
  ], rows: c });
}
