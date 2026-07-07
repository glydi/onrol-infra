/* Ask Mentor — the queue of LMS students who asked a mentor a question.
 *
 * These are the PRIVATE "Ask Mentor" threads that live in module_comments (NOT
 * live chat). The list endpoint only returns threads whose LATEST message is
 * from the student — i.e. the queue awaiting a mentor reply. Doubts sort first.
 * Opening a row shows that student's full thread (for the course/module) and a
 * reply box; the reply posts straight into that student's thread.
 *
 * Endpoints:
 *   GET  /manage/mentor-questions                → the awaiting-reply queue
 *   GET  /manage/courses/:courseId/comments      → whole course thread (filtered
 *                                                   client-side to this student)
 *   POST /modules/:moduleId/comments             → reply into a module thread
 *   POST /courses/:courseId/comments             → reply into the General thread
 * Reply body: { body, thread_user_id, is_doubt:false } — staff-only thread_user_id
 * targets the student whose thread we're answering.
 */
'use strict';

const snip = (s, n = 92) => { s = String(s || '').replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };

/* Two real tabs — both are awaiting-reply items (the endpoint returns nothing
 * else). "Doubt queue" is the default and shows only is_doubt items; "All
 * questions" shows the whole queue. Routed via #/mentor/<tab>, mirroring the
 * courses tabs pattern. A "Closed/answered" list is intentionally absent —
 * this endpoint can't produce one (see file header). */
const MENTOR_TABS = [['doubts', 'Doubt queue'], ['all', 'All questions']];
const mentorTab = () => {
  const parts = location.hash.replace(/^#\/?/, '').split('?')[0].split('/').filter(Boolean);
  return MENTOR_TABS.some(([k]) => k === parts[1]) ? parts[1] : 'doubts';
};

registerView('mentor', async (content, ctx) => {
  ctx.setCrumbs('Ask Mentor');
  await renderMentorList(content, mentorTab());
});

async function renderMentorList(content, tab = mentorTab()) {
  const data = await api('/manage/mentor-questions').catch(() => ({}));
  const qs = arr(data, 'questions');
  const waiting = data.waiting ?? qs.length;
  const doubts = qs.filter(q => q.is_doubt).length;
  setBadge('mentor', waiting || 0);

  const sub = waiting
    ? `${waiting} awaiting reply${doubts ? ` · ${doubts} doubt${doubts > 1 ? 's' : ''}` : ''}`
    : 'All caught up — no questions waiting';

  const counts = { doubts, all: qs.length };
  const rows = tab === 'doubts' ? qs.filter(q => q.is_doubt) : qs;
  const empty = tab === 'doubts'
    ? 'No doubts waiting. You’re all caught up.'
    : 'No student questions waiting. You’re all caught up.';

  content.innerHTML =
    pageHead({ title: 'Ask Mentor', sub }) +
    `<div class="tabs">${MENTOR_TABS.map(([k, l]) =>
      `<div class="tab ${k === tab ? 'active' : ''}" data-t="${k}">${esc(l)}${counts[k] ? ` <span style="opacity:.6;font-weight:600">${counts[k]}</span>` : ''}</div>`).join('')}</div>` +
    dataTable({
      clickable: true,
      empty,
      columns: [
        { label: 'Student', render: q => `<b>${esc(q.name || 'Student')}</b>` },
        { label: 'Course / module', render: q => `${esc(q.course || '—')}<div class="sub">${esc(q.where || 'General')}</div>` },
        { label: 'Last message', render: q => `<span class="muted">${esc(snip(q.body))}</span>` },
        { label: 'When', render: q => { const w = q.at; return `<span title="${esc(fmtDateTime(w))}">${esc(timeAgo(w) || fmtDate(w))}</span>`; } },
        { label: 'Status', cls: 'right', render: q => q.is_doubt ? pill('bad', 'doubt') : pill('pending', 'awaiting') },
      ],
      rows,
    });

  content.querySelectorAll('.tab').forEach(t => t.onclick = () => go('#/mentor/' + t.dataset.t));
  const byId = {};
  rows.forEach(q => { byId[q.id] = q; });
  wire(content, { rowClick: id => openThread(byId[id], content) });
}

/* ---- Thread view: one student's private mentor thread + reply box ---- */
function openThread(q, content) {
  if (!q) return;
  openModal({
    title: q.name || 'Student',
    sub: `${q.course || ''}${q.where ? ' · ' + q.where : ''}`,
    wide: true,
    bodyHtml: `<div class="thread" id="mtThread" style="max-height:52vh;overflow-y:auto;display:flex;flex-direction:column;gap:10px;padding:2px">${loadingPage()}</div>`,
    footHtml: `<div style="width:100%;display:flex;flex-direction:column;gap:8px">
        <textarea id="mtReply" rows="3" placeholder="Write a reply to ${esc((q.name || 'the student').split(' ')[0])}…"></textarea>
        <div style="display:flex;align-items:center;gap:10px">
          <span class="modal-err" data-err></span><span class="grow" style="flex:1"></span>
          <button class="btn btn-ghost" data-x="close">Close</button>
          <button class="btn btn-primary" data-x="send">Send reply</button>
        </div>
      </div>`,
    onMount(root, close) {
      const threadEl = root.querySelector('#mtThread');
      const ta = root.querySelector('#mtReply');
      const err = root.querySelector('[data-err]');
      const sendBtn = root.querySelector('[data-x=send]');
      root.querySelector('[data-x=close]').onclick = close;

      loadThread(q, threadEl);

      sendBtn.onclick = async () => {
        const body = ta.value.trim();
        if (!body) { ta.focus(); return; }
        err.textContent = ''; sendBtn.disabled = true;
        try {
          await postReply(q, body);
          ta.value = '';
          toast('Reply sent', 'good');
          await loadThread(q, threadEl);       // show the reply in the thread
          renderMentorList(content);           // refresh the queue behind the modal
        } catch (ex) {
          err.textContent = ex.message || 'Failed to send reply';
        } finally { sendBtn.disabled = false; }
      };
      // Cmd/Ctrl+Enter sends.
      ta.addEventListener('keydown', e => { if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') sendBtn.click(); });
      ta.focus();
    },
  });
}

async function loadThread(q, el) {
  el.innerHTML = loadingPage();
  let msgs;
  try {
    const data = await api('/manage/courses/' + q.course_id + '/comments');
    const wantModule = String(q.module_id || '');
    const wantUser = String(q.thread_user_id || '');
    msgs = arr(data, 'comments')
      .filter(m => String(m.thread_user_id || '') === wantUser && String(m.module_id || '') === wantModule)
      .sort((a, b) => new Date(a.at) - new Date(b.at));
  } catch (ex) {
    el.innerHTML = `<div class="stub">Couldn’t load the thread: ${esc(ex.message)}</div>`;
    return;
  }
  if (!msgs.length) { el.innerHTML = emptyState('No messages in this thread yet.'); return; }
  el.innerHTML = msgs.map(msgBubble).join('');
  el.scrollTop = el.scrollHeight;
}

function msgBubble(m) {
  const staff = !!m.staff;
  const wrap = `display:flex;flex-direction:column;max-width:82%;${staff ? 'align-self:flex-end;align-items:flex-end' : 'align-self:flex-start;align-items:flex-start'}`;
  const bubble = `padding:8px 12px;border-radius:12px;white-space:pre-wrap;word-break:break-word;` +
    (staff
      ? 'background:var(--info-bg);color:var(--ink);border:1px solid var(--line)'
      : 'background:var(--panel-3);color:var(--ink)');
  const meta = `font-size:11px;color:var(--ink-3);margin:0 4px 3px;display:flex;gap:6px;align-items:center`;
  return `<div style="${wrap}">
      <div style="${meta}">${esc(m.author || (staff ? 'Mentor' : 'Student'))}${m.is_doubt && !staff ? ' ' + pill('bad', 'doubt') : ''}<span title="${esc(fmtDateTime(m.at))}">${esc(timeAgo(m.at) || fmtDateTime(m.at))}</span></div>
      <div style="${bubble}">${esc(m.body)}</div>
    </div>`;
}

/* Reply goes into the student's thread: module thread if the question is
 * module-scoped, otherwise the course-level "General" thread. thread_user_id
 * (staff-only) tells the backend whose thread to post into. */
function postReply(q, body) {
  const payload = { body, thread_user_id: q.thread_user_id, is_doubt: false };
  return q.module_id
    ? api('/modules/' + q.module_id + '/comments', { method: 'POST', body: payload })
    : api('/courses/' + q.course_id + '/comments', { method: 'POST', body: payload });
}
