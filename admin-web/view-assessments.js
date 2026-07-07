/* Assessments & Quiz Engine — course-scoped. There is no global list, so start
 * with a course picker, then list → assessment detail (tabs). Mirrors view-courses.
 * Routes: #/assessments  ·  #/assessments/<courseId>  ·  #/assessments/<courseId>/<assessmentId>/<tab> */
'use strict';

const ASMT_TABS = [['questions', 'Questions'], ['submissions', 'Submissions'], ['settings', 'Settings']];
const ASMT_TYPES = [{ value: 'quiz', label: 'Quiz' }, { value: 'assignment', label: 'Assignment' }, { value: 'project', label: 'Project' }];
const ASMT_QTYPES = [{ value: 'mcq', label: 'Multiple choice' }, { value: 'truefalse', label: 'True / False' }, { value: 'short', label: 'Short answer' }, { value: 'essay', label: 'Essay / long answer' }];

registerView('assessments', async (content, ctx) => {
  const courseId = ctx.params[0] || '';
  if (!courseId) return asmtPicker(content, ctx);
  if (ctx.params[1]) return asmtDetail(content, ctx, courseId, ctx.params[1], ctx.params[2] || 'questions');
  return asmtCourseView(content, ctx, courseId);
});

/* ---- small helpers (all asmt-prefixed to avoid clobbering the shared scope) ---- */
const asmtQTypeLabel = t => (ASMT_QTYPES.find(o => o.value === t) || {}).label || t || 'mcq';
const asmtScope = a => a.module ? 'Module: ' + a.module : (a.day_number != null ? 'Day ' + a.day_number : '—');
const asmtScore = s => s == null ? '—' : Math.round(s) + '%';
function asmtStatusPill(s) { const map = { graded: 'good', submitted: 'warn', pending: 'warn', returned: 'info', resubmit: 'info' }; return pill(map[s] || s, s); }
function asmtLocalDT(s) { const d = new Date(s); if (isNaN(d)) return ''; const p = n => String(n).padStart(2, '0'); return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`; }
function asmtFileSize(n) { n = +n || 0; if (n < 1024) return n + ' B'; if (n < 1048576) return (n / 1024).toFixed(1) + ' KB'; return (n / 1048576).toFixed(1) + ' MB'; }
function asmtModuleOptions(co) {
  const out = [{ value: '', label: '— no module —' }];
  const walk = (mods, depth) => (mods || []).forEach(m => { out.push({ value: m.id, label: (depth ? '↳ ' : '') + (m.title || 'Module') }); walk(m.submodules, depth + 1); });
  walk(co && co.modules, 0);
  return out;
}

/* ---- Landing: course picker ---- */
async function asmtPicker(content, ctx) {
  ctx.setCrumbs('Assessments');
  const courses = arr(await api('/manage/courses'), 'courses');
  content.innerHTML =
    pageHead({ title: 'Assessments', sub: 'Quizzes, assignments & the quiz engine — pick a course' }) +
    card(`<label class="fld" style="max-width:440px;margin:0">Jump to a course
      <select id="asmt-course"><option value="">— Select a course —</option>
      ${courses.map(c => `<option value="${esc(c.id)}">${esc(c.title || c.label || c.id)}</option>`).join('')}</select></label>`) +
    `<div class="section-title" style="margin-top:18px">Courses</div>` +
    dataTable({
      clickable: true, empty: 'No courses yet.', columns: [
        { label: 'Title', render: c => `<b>${esc(c.title || 'Untitled')}</b>` },
        { label: 'Course ID', render: c => `<span class="muted">${esc(c.label || c.id)}</span>` },
        { label: 'Status', render: c => pill(c.status || 'draft') },
      ], rows: courses,
    });
  const sel = content.querySelector('#asmt-course');
  if (sel) sel.onchange = e => { if (e.target.value) go('#/assessments/' + e.target.value); };
  wire(content, { rowClick: id => go('#/assessments/' + id) });
}

/* ---- Course view: this course's assessments ---- */
async function asmtCourseView(content, ctx, courseId) {
  const [co, listRes] = await Promise.all([
    api('/manage/courses/' + courseId).catch(() => ({})),
    api('/manage/courses/' + courseId + '/assessments').catch(() => ({})),
  ]);
  const items = arr(listRes, 'assessments');
  ctx.setCrumbs({ label: 'Assessments', href: '#/assessments' }, co.title || 'Course');
  content.innerHTML =
    pageHead({ title: co.title || 'Course', sub: `${items.length} assessment(s)`, actions: btn('+ New assessment', { act: 'new', cls: 'btn-primary' }) }) +
    dataTable({
      clickable: true, empty: 'No quizzes or assignments yet.', columns: [
        { label: 'Title', render: x => `<b>${esc(x.title || 'Untitled')}</b>` },
        { label: 'Type', render: x => tag(x.type || 'quiz') },
        { label: 'Questions', cls: 'right', render: x => String(x.questions ?? x.question_count ?? 0) },
        { label: 'Scope', render: x => esc(asmtScope(x)) },
        { label: 'Due', render: x => esc(x.due_at ? fmtDateTime(x.due_at) : '—') },
        { label: 'Status', render: x => pill(x.is_published ? 'published' : 'draft') },
      ], rows: items,
    });
  wire(content, { rowClick: id => go('#/assessments/' + courseId + '/' + id), acts: { new: () => asmtNewForm(courseId, co) } });
}

async function asmtNewForm(courseId, co) {
  formModal({
    title: 'New assessment', fields: [
      { name: 'title', label: 'Title', required: true, placeholder: 'e.g. Module 1 Quiz' },
      { name: 'type', label: 'Type', type: 'select', value: 'quiz', options: ASMT_TYPES },
      { name: 'module_id', label: 'Attach to module', type: 'select', options: asmtModuleOptions(co), hint: 'optional' },
      { name: 'day_number', label: 'Or a day number', type: 'number', hint: 'used only when no module is picked' },
      { name: 'due_at', label: 'Due date', type: 'datetime', hint: 'optional' },
      { name: 'is_published', label: 'Published (visible to students)', type: 'toggle' },
      { name: 'auto_award', label: 'Auto-grade objective questions on submit', type: 'toggle', value: true },
    ], submitLabel: 'Create assessment',
    async onSubmit(v) {
      const body = { title: v.title, type: v.type, is_published: !!v.is_published, auto_award: !!v.auto_award };
      if (v.module_id) body.module_id = v.module_id;
      else if (v.day_number != null && v.day_number !== '') body.day_number = Number(v.day_number);
      if (v.due_at) body.due_at = new Date(v.due_at).toISOString();
      const r = await api('/manage/courses/' + courseId + '/assessments', { method: 'POST', body });
      toast('Assessment created', 'good');
      go('#/assessments/' + courseId + '/' + (r.id || ''));
    },
  });
}

/* ---- Assessment detail (tabs) ---- */
async function asmtDetail(content, ctx, courseId, assessId, tab) {
  const t = ASMT_TABS.some(([k]) => k === tab) ? tab : 'questions';
  const [co, listRes] = await Promise.all([
    api('/manage/courses/' + courseId).catch(() => ({})),
    api('/manage/courses/' + courseId + '/assessments').catch(() => ({})),
  ]);
  const a = arr(listRes, 'assessments').find(x => String(x.id) === String(assessId));
  const back = { label: co.title || 'Course', href: '#/assessments/' + courseId };
  if (!a) {
    ctx.setCrumbs({ label: 'Assessments', href: '#/assessments' }, back, 'Not found');
    content.innerHTML = pageHead({ title: 'Assessment not found' }) + emptyState('This assessment no longer exists.', 'It may have been deleted.');
    return;
  }
  ctx.setCrumbs({ label: 'Assessments', href: '#/assessments' }, back, a.title || 'Assessment');
  content.innerHTML =
    pageHead({ title: a.title || 'Assessment', sub: `${a.type || 'quiz'} · ${a.questions ?? 0} question(s)`, actions: pill(a.is_published ? 'published' : 'draft') }) +
    `<div class="tabs">${ASMT_TABS.map(([k, l]) => `<div class="tab ${k === t ? 'active' : ''}" data-t="${k}">${l}</div>`).join('')}</div><div id="asmt-tb"></div>`;
  content.querySelectorAll('.tab').forEach(el => el.onclick = () => go(`#/assessments/${courseId}/${assessId}/${el.dataset.t}`));
  const tbEl = content.querySelector('#asmt-tb');
  tbEl.innerHTML = loadingPage();
  try {
    if (t === 'questions') await asmtTabQuestions(tbEl, courseId, a);
    else if (t === 'submissions') await asmtTabSubmissions(tbEl, courseId, a);
    else await asmtTabSettings(tbEl, courseId, co, a);
  } catch (e) { tbEl.innerHTML = card(`<b>Couldn’t load.</b><div class="stub" style="margin-top:8px">${esc(e.message)}</div>`); }
}
const asmtReload = (courseId, assessId, tab) => asmtDetail(document.getElementById('content'), { setCrumbs }, courseId, assessId, tab);

/* ---- Questions tab ---- */
function asmtAnswerHtml(q) {
  const opts = arr(q.options);
  if ((q.type === 'mcq' || q.type === 'truefalse') && opts.length) {
    return `<div style="display:flex;flex-direction:column;gap:3px;margin-top:4px">` + opts.map(o => {
      const ok = String(o) === String(q.correct);
      return `<div style="display:flex;align-items:center;gap:8px${ok ? ';color:var(--good);font-weight:600' : ';color:var(--ink-2)'}">${ok ? '✓' : '○'} ${esc(o)}</div>`;
    }).join('') + `</div>`;
  }
  if (q.type === 'short') return `<div class="muted" style="margin-top:4px">Expected answer: <b>${esc(q.correct || '—')}</b></div>`;
  return `<div class="muted" style="margin-top:4px">Graded manually (essay / long answer).</div>`;
}
function asmtQuestionCard(q, i) {
  return card(`<div style="display:flex;gap:12px;align-items:flex-start">
    <div style="flex:1;min-width:0">
      <div style="font-weight:700">${i + 1}. ${esc(q.prompt || '')} ${tag(asmtQTypeLabel(q.type))}</div>
      ${asmtAnswerHtml(q)}
    </div>
    <div style="flex:none;display:flex;gap:6px">${btn('Edit', { act: 'editq', id: q.id })}${btn('✕', { act: 'delq', id: q.id, cls: 'btn-sm btn-ghost', title: 'Delete question' })}</div>
  </div>`);
}
async function asmtTabQuestions(tb, courseId, a) {
  const qs = arr(await api('/manage/assessments/' + a.id + '/questions'), 'questions');
  tb.innerHTML =
    `<div class="toolbar"><div class="grow"><span class="muted">${qs.length} question(s)</span></div>${btn('✨ AI-generate questions', { act: 'aigen' })} ${btn('+ Add question', { act: 'addq', cls: 'btn-primary' })}</div>` +
    (qs.length ? `<div style="display:flex;flex-direction:column;gap:10px">${qs.map((q, i) => asmtQuestionCard(q, i)).join('')}</div>` : emptyState('No questions yet', 'Add questions manually or draft a set with AI.'));
  wire(tb, {
    acts: {
      addq: () => asmtQuestionForm(courseId, a),
      aigen: () => asmtAiGenerate(courseId, a),
      editq: id => asmtQuestionForm(courseId, a, qs.find(q => String(q.id) === String(id))),
      delq: async id => { if (await confirmModal('Delete this question?', { danger: true, confirmLabel: 'Delete' })) { await api('/manage/questions/' + id, { method: 'DELETE' }); toast('Question deleted'); asmtReload(courseId, a.id, 'questions'); } },
    },
  });
}

function asmtQuestionForm(courseId, a, q) {
  const edit = !!q;
  formModal({
    title: edit ? 'Edit question' : 'Add question', wide: true, fields: [
      { name: 'prompt', label: 'Prompt', type: 'textarea', required: true, value: q && q.prompt, rows: 3, placeholder: 'The question as the student sees it' },
      { name: 'type', label: 'Type', type: 'select', value: (q && q.type) || 'mcq', options: ASMT_QTYPES },
      { name: 'options', label: 'Options', type: 'textarea', rows: 4, value: q ? arr(q.options).join('\n') : '', hint: 'one per line — MCQ only (True/False fills itself)' },
      { name: 'correct', label: 'Correct answer', value: q && q.correct, hint: 'MCQ: exact option text · T/F: true or false · short: expected answer · essay: leave blank' },
    ], submitLabel: edit ? 'Save question' : 'Add question',
    async onSubmit(v) {
      let options = (v.options || '').split('\n').map(s => s.trim()).filter(Boolean);
      if (v.type === 'truefalse' && !options.length) options = ['true', 'false'];
      if (v.type === 'short' || v.type === 'essay') options = [];
      const body = { prompt: v.prompt, type: v.type, options, correct: v.type === 'essay' ? '' : (v.correct || '') };
      if (edit) await api('/manage/questions/' + q.id, { method: 'PATCH', body });
      else await api('/manage/assessments/' + a.id + '/questions', { method: 'POST', body });
      toast(edit ? 'Question saved' : 'Question added', 'good');
      asmtReload(courseId, a.id, 'questions');
    },
  });
}

function asmtAiGenerate(courseId, a) {
  formModal({
    title: '✨ AI-generate questions', sub: 'Drafts are inserted for you to review & edit', wide: true, fields: [
      { name: 'topic', label: 'Topic or source material', type: 'textarea', required: true, rows: 4, placeholder: 'Paste notes, or describe the topic to quiz on' },
      { name: 'count', label: 'How many', type: 'number', value: 5, hint: '1–20' },
      { name: 'difficulty', label: 'Difficulty', type: 'select', value: 'intermediate', options: [{ value: 'beginner', label: 'Beginner' }, { value: 'intermediate', label: 'Intermediate' }, { value: 'advanced', label: 'Advanced' }] },
      { name: 'types', label: 'Question types', type: 'select', value: 'a sensible mix of mcq, truefalse, short, and essay', options: [
        { value: 'a sensible mix of mcq, truefalse, short, and essay', label: 'Mixed' },
        { value: 'mcq', label: 'Multiple choice only' },
        { value: 'truefalse', label: 'True / False only' },
        { value: 'short', label: 'Short answer only' },
        { value: 'essay', label: 'Essay only' },
      ] },
    ], submitLabel: 'Generate',
    async onSubmit(v) {
      const r = await api('/manage/assessments/' + a.id + '/generate', { method: 'POST', body: { topic: v.topic, count: Number(v.count) || 5, difficulty: v.difficulty, types: v.types } });
      toast((r.added || 0) + ' question(s) added', 'good');
      asmtReload(courseId, a.id, 'questions');
    },
  });
}

/* ---- Submissions tab ---- */
async function asmtTabSubmissions(tb, courseId, a) {
  const subs = arr(await api('/manage/assessments/' + a.id + '/submissions'), 'submissions');
  const graded = subs.filter(s => s.status === 'graded').length;
  tb.innerHTML =
    `<div class="toolbar"><div class="grow"><span class="muted">${subs.length} submission(s) · ${graded} graded</span></div></div>` +
    dataTable({
      clickable: true, empty: 'No submissions yet.', columns: [
        { label: 'Student', render: s => `<b>${esc(s.student || 'Student')}</b>${(s.files && s.files.length) ? ` <span class="muted">· ${s.files.length} file(s)</span>` : ''}` },
        { label: 'Submitted', render: s => esc(s.submitted_at ? fmtDateTime(s.submitted_at) : '—') },
        { label: 'Score', cls: 'right', render: s => asmtScore(s.score) },
        { label: 'Status', render: s => asmtStatusPill(s.status || 'submitted') },
        { label: '', cls: 'right', render: s => btn(s.status === 'graded' ? 'Regrade' : 'Grade', { act: 'grade', id: s.id, cls: s.status === 'graded' ? 'btn-sm btn-ghost' : 'btn-sm btn-primary' }) },
      ], rows: subs,
    });
  const open = id => asmtGrade(courseId, a, subs.find(s => String(s.id) === String(id)));
  wire(tb, { rowClick: open, acts: { grade: open } });
}

function asmtGrade(courseId, a, sub) {
  if (!sub) return;
  const bodyHtml = sub.body ? `<div style="white-space:pre-wrap">${esc(sub.body)}</div>` : '—';
  const linkHtml = sub.link ? `<a href="${esc(sub.link)}" target="_blank" rel="noopener" style="color:var(--accent)">${esc(sub.link)}</a>` : '—';
  const files = arr(sub.files);
  const filesHtml = files.length ? files.map(f => `<div class="muted">${esc(f.filename || 'file')} · ${asmtFileSize(f.size)}</div>`).join('') : '—';
  formModal({
    title: 'Grade submission', sub: sub.student || '', wide: true, fields: [
      { name: '_body', label: 'Answer / notes', type: 'static', value: bodyHtml },
      { name: '_link', label: 'Link', type: 'static', value: linkHtml },
      { name: '_files', label: 'Files', type: 'static', value: filesHtml },
      { name: 'score', label: 'Score', type: 'number', required: true, value: sub.score ?? '', hint: '0–100 (percent)' },
      { name: 'feedback', label: 'Feedback to student', type: 'textarea', value: sub.feedback ?? '', rows: 3 },
    ], submitLabel: 'Save grade',
    async onSubmit(v) {
      await api('/manage/submissions/' + sub.id + '/grade', { method: 'POST', body: { score: Number(v.score) || 0, feedback: v.feedback || '' } });
      toast('Graded', 'good');
      asmtReload(courseId, a.id, 'submissions');
    },
  });
}

/* ---- Settings tab ---- */
async function asmtTabSettings(tb, courseId, co, a) {
  tb.innerHTML =
    card(dl([
      ['Title', esc(a.title)],
      ['Type', esc(a.type || 'quiz')],
      ['Status', pill(a.is_published ? 'published' : 'draft')],
      ['Questions', a.questions ?? 0],
      ['Scope', esc(asmtScope(a))],
      ['Due', a.due_at ? esc(fmtDateTime(a.due_at)) : '—'],
      ['Auto-grade objective questions', a.auto_award ? 'On' : 'Off'],
    ])) +
    `<div class="toolbar" style="margin-top:16px">
       ${btn('Edit details', { act: 'edit', cls: 'btn-primary' })}
       ${btn(a.is_published ? 'Unpublish' : 'Publish', { act: 'pub' })}
       ${btn('Delete assessment', { act: 'del', cls: 'btn-danger' })}
     </div>
     <p class="stub" style="margin-top:12px">Scoring is a percentage — every question is worth 1 point and a submission's score is its percent (there is no separate pass mark / time limit / retake limit in this backend).</p>`;
  wire(tb, {
    acts: {
      edit: () => asmtEditForm(courseId, co, a),
      pub: async () => { await api('/manage/assessments/' + a.id, { method: 'PATCH', body: { is_published: !a.is_published } }); toast(a.is_published ? 'Unpublished' : 'Published', 'good'); asmtReload(courseId, a.id, 'settings'); },
      del: async () => { if (await confirmModal('Permanently delete “' + (a.title || 'this assessment') + '” and its questions?', { danger: true, confirmLabel: 'Delete' })) { await api('/manage/assessments/' + a.id, { method: 'DELETE' }); toast('Assessment deleted'); go('#/assessments/' + courseId); } },
    },
  });
}

function asmtEditForm(courseId, co, a) {
  formModal({
    title: 'Edit assessment', wide: true, fields: [
      { name: 'title', label: 'Title', required: true, value: a.title },
      { name: 'type', label: 'Type', type: 'select', value: a.type || 'quiz', options: ASMT_TYPES },
      { name: 'module_id', label: 'Attach to module', type: 'select', value: a.module_id || '', options: asmtModuleOptions(co), hint: 'optional' },
      { name: 'day_number', label: 'Or a day number', type: 'number', value: a.day_number, hint: 'used only when no module is picked' },
      { name: 'due_at', label: 'Due date', type: 'datetime', value: a.due_at ? asmtLocalDT(a.due_at) : '', hint: 'blank clears the due date' },
      { name: 'is_published', label: 'Published (visible to students)', type: 'toggle', value: a.is_published },
      { name: 'auto_award', label: 'Auto-grade objective questions on submit', type: 'toggle', value: a.auto_award },
    ], submitLabel: 'Save changes',
    async onSubmit(v) {
      const body = { title: v.title, type: v.type, is_published: !!v.is_published, auto_award: !!v.auto_award };
      body.due_at = v.due_at ? new Date(v.due_at).toISOString() : '';
      if (v.module_id) body.module_id = v.module_id;
      else if (v.day_number != null && v.day_number !== '') body.day_number = Number(v.day_number);
      else { body.module_id = ''; body.clear_day = true; }
      await api('/manage/assessments/' + a.id, { method: 'PATCH', body });
      toast('Saved', 'good');
      asmtReload(courseId, a.id, 'settings');
    },
  });
}
