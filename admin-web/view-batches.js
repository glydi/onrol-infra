/* Batches — course-scoped student batch codes. Landing = course picker;
 * course view buckets the course-label queue by batch (users.batch). Mirrors
 * view-courses.js and uses ONLY the helpers core.js exposes on window. */
'use strict';

registerView('batches', async (content, ctx) => {
  // Admin-only: managers/superadmins. Everyone else gets an empty state.
  if (!isAdmin()) {
    ctx.setCrumbs('Batches');
    content.innerHTML = pageHead({ title: 'Batches' }) + emptyState('Admins only', 'Batch management is available to managers.');
    return;
  }
  if (ctx.params[0]) return batchCourseView(content, ctx, ctx.params[0]);

  ctx.setCrumbs('Batches');
  const courses = arr(await api('/manage/courses'), 'courses');
  content.innerHTML = pageHead({ title: 'Batches', sub: 'Pick a course to manage its student batches' }) +
    `<p class="stub" style="margin-bottom:12px">A batch here is the batch code stamped on each student (<code>users.batch</code>), grouped within a course’s label queue. Trainer, schedule and date fields would need new backend columns — only batch codes, student counts and the course queue are wired.</p>` +
    dataTable({
      clickable: true, empty: 'No courses yet.', columns: [
        { label: 'Course', render: c => `<b>${esc(c.title || 'Untitled')}</b>` },
        { label: 'Course ID', render: c => `<span class="muted">${esc(c.label || c.id)}</span>` },
        { label: 'Status', render: c => pill(c.status || 'draft') },
      ], rows: courses,
    });
  wire(content, { rowClick: id => go('#/batches/' + id) });
});

/* ---- Course view: the course-label queue bucketed by batch code ---- */
async function batchCourseView(content, ctx, courseId) {
  const [coRes, bRes] = await Promise.allSettled([
    api('/manage/courses/' + courseId),
    api('/manage/courses/' + courseId + '/batches'),
  ]);
  if (bRes.status !== 'fulfilled') throw new Error(bRes.reason?.message || 'Couldn’t load batches');
  const co = coRes.status === 'fulfilled' ? coRes.value : {};
  const data = bRes.value || {};
  const label = data.label || co.label || '';
  const buckets = arr(data, 'batches');

  ctx.setCrumbs({ label: 'Batches', href: '#/batches' }, co.title || label || 'Course');

  const named = buckets.filter(b => b.batch != null && b.batch !== '');
  const queue = buckets.find(b => b.batch == null || b.batch === '');
  const queueCount = queue ? (queue.count ?? (queue.students || []).length) : 0;
  const total = buckets.reduce((n, b) => n + (b.count ?? (b.students || []).length), 0);
  // Flat list (each student tagged with its current batch) for the assign picker + move lookups.
  const allStudents = buckets.reduce((acc, b) => acc.concat((b.students || []).map(s => Object.assign({}, s, { batch: b.batch }))), []);

  content.innerHTML =
    pageHead({
      title: 'Batches', sub: label ? ('Course queue: ' + label) : (co.title || courseId),
      actions: btn('Assign students to a batch', { act: 'assign', cls: 'btn-primary' }),
    }) +
    statCards([{ n: named.length, l: 'Batches' }, { n: total, l: 'Students' }, { n: queueCount, l: 'In queue' }]) +
    `<p class="stub" style="margin:4px 0 12px">Auto-allocation was removed backend-side (<code>POST /manage/users/auto-batch</code> now returns 410) — assign a batch code to students instead, which stamps <code>users.batch</code>. Trainer/schedule/date fields aren’t available here.</p>` +
    (label
      ? (buckets.length ? buckets.map(batchBucketCard).join('') : emptyState('No students in this course’s queue yet.', 'Students appear here once their course label matches this course.'))
      : `<p class="stub">This course has no label set, so it has no student queue to bucket. Set the course’s Course ID (label) so its students appear here.</p>`);

  wire(content, {
    acts: {
      assign: () => batchAssignModal(courseId, label, allStudents),
      move: uid => {
        const s = allStudents.find(x => String(x.id) === String(uid)) || {};
        batchMoveStudent(courseId, uid, s.name, s.batch);
      },
    },
  });
}

function batchBucketCard(b) {
  const isQueue = b.batch == null || b.batch === '';
  const name = isQueue ? 'Unassigned queue' : ('Batch ' + b.batch);
  const studs = b.students || [];
  const table = dataTable({
    empty: 'No students.', columns: [
      { label: 'Name', render: s => `<b>${esc(s.name || 'Student')}</b>${s.email ? `<div class="sub">${esc(s.email)}</div>` : ''}` },
      { label: 'Login ID', render: s => s.login_id ? `<span class="muted">${esc(s.login_id)}</span>` : '<span class="muted">—</span>' },
      { label: 'Access', render: s => s.days_left == null ? '<span class="muted">no limit</span>' : (s.days_left <= 0 ? pill('warn', 'ended') : esc(s.days_left + 'd left')) },
      { label: '', cls: 'right', render: s => btn('Move', { act: 'move', id: s.id, cls: 'btn-sm' }) },
    ], rows: studs,
  });
  return card(`<div class="section-title" style="margin-bottom:8px">${esc(name)} <span class="count">${studs.length}</span></div>${table}`);
}

/* Bulk assign: pick students from the course queue + a batch code → batch-assign. */
function batchAssignModal(courseId, label, students) {
  const list = (students || []).map(s => `<label class="fld" style="flex-direction:row;align-items:center;gap:10px;margin:0;padding:6px 0">
      <input type="checkbox" data-uid="${esc(s.id)}">
      <span style="flex:1"><b>${esc(s.name || 'Student')}</b>${s.email ? ` <span class="muted">${esc(s.email)}</span>` : ''}</span>
      ${s.batch ? tag('Batch ' + s.batch) : '<span class="muted">queue</span>'}
    </label>`).join('');
  openModal({
    title: 'Assign students to a batch', sub: label ? ('Course queue: ' + label) : '', wide: true,
    bodyHtml: `<label class="fld">Batch code <span class="hint">uppercase, e.g. A or 2026-JAN</span><input id="f_batchcode" type="text" placeholder="A" autocomplete="off"></label>
      <div class="section-title" style="margin:8px 0 4px">Choose students</div>
      <div style="max-height:340px;overflow:auto">${students && students.length ? list : emptyState('No students in this course’s queue.')}</div>`,
    footHtml: `<span class="modal-err" data-err></span><button class="btn btn-ghost" data-x="c">Cancel</button><button class="btn btn-primary" data-x="ok">Assign</button>`,
    onMount(root, close) {
      const err = root.querySelector('[data-err]'), ok = root.querySelector('[data-x=ok]');
      root.querySelector('[data-x=c]').onclick = close;
      ok.onclick = async () => {
        const batch = (root.querySelector('#f_batchcode').value || '').trim();
        if (!batch) { err.textContent = 'Batch code is required'; return; }
        const ids = Array.from(root.querySelectorAll('input[data-uid]:checked')).map(i => i.dataset.uid);
        if (!ids.length) { err.textContent = 'Pick at least one student'; return; }
        err.textContent = ''; ok.disabled = true;
        try {
          const r = await api('/manage/users/batch-assign', { method: 'POST', body: { user_ids: ids, batch } });
          toast((r.updated ?? ids.length) + ' assigned to batch ' + batch.toUpperCase(), 'good');
          close(); batchReload(courseId);
        } catch (ex) { err.textContent = ex.message || 'Failed'; ok.disabled = false; }
      };
      const f = root.querySelector('#f_batchcode'); if (f) f.focus();
    },
  });
}

/* Move one student: set (or clear → queue) their batch code via /users/:id/batch. */
function batchMoveStudent(courseId, uid, name, current) {
  formModal({
    title: 'Move ' + (name || 'student'), sub: 'Set or clear this student’s batch code',
    fields: [{ name: 'batch', label: 'Batch code', value: current || '', hint: 'blank = back to the queue' }],
    submitLabel: 'Save',
    async onSubmit(v) {
      const batch = (v.batch || '').trim();
      await api('/manage/users/' + uid + '/batch', { method: 'POST', body: { batch: batch === '' ? null : batch } });
      toast('Batch updated', 'good'); batchReload(courseId);
    },
  });
}

function batchReload(courseId) {
  batchCourseView(document.getElementById('content'), { setCrumbs, params: [courseId] }, courseId);
}
