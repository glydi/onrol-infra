/* Live Classes (global) — every live session across all courses, in one place.
 * Also the home for the `live_host` role. Pattern mirrors view-courses.js:
 * list → detail. The room itself is hosted in the Flutter live screen, not here.
 *
 * Endpoints wired:
 *   GET    /live-host/sessions                  (live_host: simulated sessions)
 *   GET    /manage/courses                      (staff: course list to fan out)
 *   GET    /manage/courses/:id/sessions         (staff: a course's sessions)
 *   GET    /manage/videos                       (recordings for "recorded-as-live")
 *   POST   /manage/courses/:id/sessions         (schedule)
 *   PATCH  /manage/sessions/:id                 (edit)
 *   DELETE /manage/sessions/:id                 (delete)
 *   GET    /me/live/:id/state                   (authoritative status + viewers)
 *   GET    /me/live/:id/attendance              (who watched, how long)
 */
'use strict';

/* A session with no explicit end (external links, or a recording whose duration
 * we don't have in the list) is assumed to run this long — so it flips out of
 * "live" instead of showing live forever. The room's own /state is authoritative
 * on the detail screen. */
const LIVE_WINDOW_SECS = 3 * 3600;

/* small cache so list → detail → back doesn't re-fan-out every navigation */
let LIVE_CACHE = { list: null, byId: {}, at: 0 };
function invalidateLive() { LIVE_CACHE = { list: null, byId: {}, at: 0 }; }

const liveEndMs = s => {
  if (s && s.ends_at) { const e = new Date(s.ends_at).getTime(); if (!isNaN(e)) return e; }
  const st = new Date(s && s.starts_at).getTime();
  return isNaN(st) ? null : st + LIVE_WINDOW_SECS * 1000;
};
function liveStatus(s, now = Date.now()) {
  const st = new Date(s && s.starts_at).getTime();
  if (isNaN(st) || now < st) return 'upcoming';
  const end = liveEndMs(s);
  return end != null && now >= end ? 'ended' : 'live';
}
const isSimulated = s => (s.kind === 'simulated') || !!s.media_asset_id;
const liveType = s => isSimulated(s) ? 'recorded-as-live' : 'external';
const liveStatusPill = st => st === 'preparing' ? pill('warn', 'preparing') : pill(st || 'upcoming');

/* Build the global list. A live_host only has /live-host/sessions; everyone else
 * (instructor / manager / superadmin) fans out over their courses so BOTH external
 * and recorded-as-live sessions are covered. */
async function loadAllSessions() {
  if (LIVE_CACHE.list && Date.now() - LIVE_CACHE.at < 15000) return LIVE_CACHE.list;
  let list = [];
  if (USER.role === 'live_host') {
    list = arr(await api('/live-host/sessions'), 'sessions').map(x => ({ ...x, kind: 'simulated' }));
  } else {
    const courses = arr(await api('/manage/courses'), 'courses');
    const results = await Promise.allSettled(
      courses.map(co => api('/manage/courses/' + co.id + '/sessions').then(d => ({ co, sessions: arr(d, 'sessions') })))
    );
    for (const r of results) {
      if (r.status !== 'fulfilled') continue;
      const { co, sessions } = r.value;
      for (const s of sessions) list.push({ ...s, course: co.title, course_id: co.id, course_label: co.label });
    }
  }
  LIVE_CACHE = { list, byId: Object.fromEntries(list.map(s => [s.id, s])), at: Date.now() };
  return list;
}

/* ========== LIST ========== */
registerView('live', async (content, ctx) => {
  if (ctx.params[0]) return liveDetail(content, ctx, ctx.params[0]);
  ctx.setCrumbs('Live Classes');
  const now = Date.now();
  const all = (await loadAllSessions()).map(s => ({ ...s, _status: liveStatus(s, now) }));
  const groups = [
    ['live', 'Live now', s => new Date(s.starts_at) - new Date()],           // earliest-started first
    ['upcoming', 'Upcoming', s => new Date(s.starts_at) - now],              // soonest first
    ['ended', 'Ended', s => new Date(now) - new Date(s.starts_at)],          // most recent first
  ];
  const counts = { live: 0, upcoming: 0, ended: 0 };
  all.forEach(s => { counts[s._status] = (counts[s._status] || 0) + 1; });
  setBadge('live', counts.live || 0);

  const canSchedule = isStaff() && USER.role !== 'live_host';
  let html = pageHead({
    title: 'Live Classes', sub: `${all.length} session${all.length === 1 ? '' : 's'} across all courses`,
    actions: canSchedule ? btn('+ Schedule session', { act: 'new', cls: 'btn-primary' }) : '',
  }) + statCards([
    { n: counts.live, l: 'Live now' }, { n: counts.upcoming, l: 'Upcoming' }, { n: counts.ended, l: 'Ended' },
  ]);

  if (!all.length) {
    html += emptyState('No live classes yet', canSchedule ? 'Schedule one to play a recording as a live class, or link an external room.' : '');
  } else {
    for (const [key, label, sort] of groups) {
      const rows = all.filter(s => s._status === key).sort((a, b) => sort(a) - sort(b));
      if (!rows.length) continue;
      html += `<div class="section-title" style="margin-top:18px">${esc(label)} <span class="muted">(${rows.length})</span></div>` +
        dataTable({
          clickable: true, empty: '',
          columns: [
            { label: 'Title', render: s => `<b>${esc(s.title || 'Live class')}</b>` },
            { label: 'Course', render: s => esc(s.course || s.course_title || '—') },
            { label: 'Type', render: s => tag(liveType(s)) },
            { label: 'Starts', render: s => `<span title="${esc(fmtDateTime(s.starts_at))}">${esc(fmtDateTime(s.starts_at))}</span>` },
            { label: 'Status', cls: 'right', render: s => liveStatusPill(s._status) },
          ], rows,
        });
    }
  }
  content.innerHTML = html;
  wire(content, {
    rowClick: id => go('#/live/' + id),
    acts: { new: () => scheduleSession() },
  });
});

/* ========== DETAIL ========== */
async function liveDetail(content, ctx, id) {
  // Session base from the (cached) global list; /state is authoritative for
  // status + live viewer count and also backfills a deep-linked session.
  const list = await loadAllSessions();
  let s = LIVE_CACHE.byId[id] || list.find(x => x.id === id) || null;
  const st = await api('/me/live/' + id + '/state').catch(() => null);
  if (!s && !st) { content.innerHTML = pageHead({ title: 'Live class' }) + emptyState('Session not found', 'It may have been deleted, or you don’t manage its course.'); return; }
  if (!s) s = { id, title: st.title, course: st.course, starts_at: st.starts_at, kind: st.duration ? 'simulated' : 'external', chat_enabled: st.chat_enabled, qa_enabled: st.qa_enabled };

  const status = st ? st.status : liveStatus(s);
  const title = s.title || (st && st.title) || 'Live class';
  const course = s.course || s.course_title || (st && st.course) || '—';
  ctx.setCrumbs({ label: 'Live Classes', href: '#/live' }, title);

  const canEdit = isStaff() && USER.role !== 'live_host' && !!s.course_id;
  const hostUrl = s.host_url || '';
  const joinUrl = s.join_url || '';

  content.innerHTML =
    pageHead({
      title, sub: course,
      actions: liveStatusPill(status) +
        (isSimulated(s) ? ' ' + btn('Open host controls', { act: 'host', cls: 'btn-sm btn-primary' }) : '') +
        (hostUrl ? ' ' + btn('Copy host link', { act: 'copyhost', cls: 'btn-sm' }) : '') +
        (canEdit ? ' ' + btn('Edit', { act: 'edit', cls: 'btn-sm' }) + ' ' + btn('Delete', { act: 'del', cls: 'btn-sm btn-danger' }) : ''),
    }) +
    card(dl([
      ['Course', esc(course)],
      ['Type', tag(liveType(s))],
      ['Status', liveStatusPill(status)],
      ['Starts', esc(fmtDateTime(s.starts_at))],
      ['Ends', st && st.duration ? esc(fmtDateTime(new Date(st.starts_at).getTime() + st.duration * 1000)) : (s.ends_at ? esc(fmtDateTime(s.ends_at)) : '—')],
      ...(st && (status === 'live' || st.viewers) ? [['Viewers now', `<b>${st.viewers ?? 0}</b>`]] : []),
      ['Recording', s.media_title ? esc(s.media_title) : (isSimulated(s) ? tag('recorded-as-live') : '—')],
      ['Chat', (s.chat_enabled ?? (st && st.chat_enabled)) ? pill('good', 'on') : pill('disabled', 'off')],
      ['Q&A', (s.qa_enabled ?? (st && st.qa_enabled)) ? pill('good', 'on') : pill('disabled', 'off')],
      ['Simulated viewers', s.viewer_base != null ? esc(s.viewer_base) : '—'],
      ['Join link', joinUrl ? `<a href="${esc(joinUrl)}" target="_blank" rel="noopener" style="color:var(--accent)">${esc(joinUrl)}</a>` : '—'],
    ])) +
    (isSimulated(s)
      ? `<div class="toolbar" style="margin:14px 2px 0">${btn('Open host controls', { act: 'host', cls: 'btn-primary' })}<span class="stub">Run the room live — start/end, seek, switch video, pause / blank / mute, banner, slides &amp; slideshow, and answer Q&amp;A.</span></div>`
      : `<p class="stub" style="margin:10px 2px 0">This is an external live class — students join the link above; there’s no in-app room to host.</p>`) +
    `<div class="section-title" style="margin-top:22px">Attendance</div><div id="attn">${loadingPage()}</div>`;

  wire(content, {
    acts: {
      host: () => go('#/livehost/' + id),
      copyhost: async () => { try { await navigator.clipboard.writeText(hostUrl); toast('Host link copied', 'good'); } catch (_) { toast('Copy failed'); } },
      edit: () => scheduleSession(s),
      del: async () => { if (await confirmModal('Delete “' + title + '”? Its chat, questions and attendance go too.', { danger: true, confirmLabel: 'Delete' })) { await api('/manage/sessions/' + id, { method: 'DELETE' }); toast('Session deleted'); invalidateLive(); go('#/live'); } },
    },
  });

  liveAttendancePanel(content.querySelector('#attn'), id, title);
}

/* Attendance: enriched rows + a client-side CSV export. Empty for external
 * sessions (watch-time is only tracked for recorded-as-live rooms). */
async function liveAttendancePanel(box, id, title) {
  let data;
  try { data = await api('/me/live/' + id + '/attendance'); }
  catch (e) { box.innerHTML = card(`<div class="muted">Attendance unavailable.</div><div class="stub" style="margin-top:6px">${esc(e.message || '')}</div>`); return; }
  const rows = arr(data, 'attendance');
  const dur = data.duration || 0;
  const head = statCards([
    { n: data.count ?? rows.length, l: 'Attendees' },
    { n: fmtDur(data.avg_watched_seconds || 0), l: 'Avg watched' },
    { n: dur ? fmtDur(dur) : '—', l: 'Session length' },
  ]);
  const toolbar = `<div class="toolbar" style="margin-top:12px"><div class="grow"></div>${rows.length ? btn('Export CSV', { act: 'csv', cls: 'btn-sm' }) : ''}</div>`;
  box.innerHTML = head + toolbar + dataTable({
    empty: 'No attendance recorded yet.',
    columns: [
      { label: 'Name', render: a => `<b>${esc(a.name || 'Student')}</b>${a.email || a.phone || a.login_id ? `<div class="sub">${esc(a.email || a.phone || a.login_id)}</div>` : ''}` },
      { label: 'Watched', render: a => `${a.watched_pct ?? 0}%<div class="sub">${fmtDur(a.watched_seconds || 0)}</div>` },
      { label: 'Active span', render: a => `<span title="${esc(fmtDateTime(a.first_seen))} → ${esc(fmtDateTime(a.last_seen))}">${fmtDur(a.span_seconds || 0)}</span>` },
      { label: 'Reactions', cls: 'right', render: a => esc(a.reactions ?? 0) },
      { label: 'Questions', cls: 'right', render: a => esc(a.questions ?? 0) },
    ], rows,
  });
  wire(box, {
    acts: {
      csv: () => exportCsv(
        (title || 'attendance').replace(/[^\w.-]+/g, '_').slice(0, 60) + '_attendance.csv',
        [
          { label: 'Name', val: a => a.name || '' },
          { label: 'Email', val: a => a.email || '' },
          { label: 'Phone', val: a => a.phone || '' },
          { label: 'Login ID', val: a => a.login_id || '' },
          { label: 'First seen', val: a => a.first_seen || '' },
          { label: 'Last seen', val: a => a.last_seen || '' },
          { label: 'Watched (s)', val: a => a.watched_seconds ?? 0 },
          { label: 'Watched %', val: a => a.watched_pct ?? 0 },
          { label: 'Active span (s)', val: a => a.span_seconds ?? 0 },
          { label: 'Reactions', val: a => a.reactions ?? 0 },
          { label: 'Questions', val: a => a.questions ?? 0 },
        ], rows),
    },
  });
}

/* ========== SCHEDULE / EDIT ========== */
/* Pass a session to edit (PATCH /manage/sessions/:id); omit to create
 * (POST /manage/courses/:id/sessions). A recording turns it into a
 * recorded-as-live class; leave it blank + set a join link for an external room. */
async function scheduleSession(edit) {
  const editing = !!edit;
  const courses = editing ? [] : arr(await api('/manage/courses').catch(() => ({})), 'courses');
  // Ready recordings for the "play as live" picker (admins only; instructors 403 → external-only).
  const vids = arr(await api('/manage/videos').catch(() => ({})), 'videos').filter(v => v.status === 'ready');
  const vidOpts = [{ value: '', label: '— none (external link) —' }, ...vids.map(v => ({ value: v.id, label: v.title || v.id }))];
  const localDT = s => { const d = new Date(s); if (isNaN(d)) return ''; const p = n => String(n).padStart(2, '0'); return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`; };

  const fields = [];
  if (!editing) fields.push({ name: 'course_id', label: 'Course', type: 'select', required: true, options: [{ value: '', label: '— pick a course —' }, ...courses.map(c => ({ value: c.id, label: (c.title || c.id) + (c.label ? ' (' + c.label + ')' : '') }))] });
  fields.push(
    { name: 'title', label: 'Title', required: true, value: edit && edit.title, placeholder: 'e.g. Week 3 — Live workshop' },
    { name: 'starts_at', label: 'Starts at', type: 'datetime', required: true, value: edit ? localDT(edit.starts_at) : '' },
  );
  if (vids.length) fields.push({ name: 'media_asset_id', label: 'Recording (recorded-as-live)', type: 'select', value: (edit && edit.media_asset_id) || '', hint: 'plays as a live class; leave as external for a Zoom/Meet room', options: vidOpts });
  fields.push(
    { name: 'join_url', label: 'External join link', value: edit && edit.join_url, hint: 'Zoom / Meet / Zoho — used when no recording is selected' },
    { name: 'host_url', label: 'Host / start link', value: edit && edit.host_url, hint: 'instructor’s run-and-record link (external rooms)' },
    { name: 'viewer_base', label: 'Simulated viewers', type: 'number', value: edit && edit.viewer_base, hint: 'a live-feeling floor for recorded-as-live classes' },
    { name: 'chat_enabled', label: 'Chat enabled', type: 'toggle', value: edit ? !!edit.chat_enabled : true },
    { name: 'qa_enabled', label: 'Q&A enabled', type: 'toggle', value: edit ? !!edit.qa_enabled : true },
  );

  formModal({
    title: editing ? 'Edit session' : 'Schedule a live class',
    sub: editing ? (edit.title || '') : 'Recorded-as-live (a recording played live) or an external room link.',
    wide: true, fields, submitLabel: editing ? 'Save' : 'Schedule',
    async onSubmit(v) {
      const body = {
        title: v.title,
        starts_at: v.starts_at ? new Date(v.starts_at).toISOString() : undefined,
        join_url: v.join_url || '',
        host_url: v.host_url || '',
        media_asset_id: v.media_asset_id || '',
        viewer_base: v.viewer_base != null ? v.viewer_base : 0,
        chat_enabled: v.chat_enabled,
        qa_enabled: v.qa_enabled,
      };
      if (editing) {
        await api('/manage/sessions/' + edit.id, { method: 'PATCH', body });
        toast('Session updated', 'good'); invalidateLive();
        liveDetail(document.getElementById('content'), { setCrumbs }, edit.id);
      } else {
        if (!v.course_id) return 'Pick a course';
        await api('/manage/courses/' + v.course_id + '/sessions', { method: 'POST', body });
        toast('Session scheduled', 'good'); invalidateLive();
        go('#/live');
      }
    },
  });
}
