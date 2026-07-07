/* Calendar — month grid of admin events + a read-only synced feed
 * (live classes / deadlines / announcements). Admin-only.
 * Editable events: GET/POST /manage/calendar, PATCH/DELETE /manage/calendar/:id,
 *                  DELETE /manage/calendar/history.
 * Read-only feed: GET /manage/calendar/feed. */
'use strict';

/* displayed month lives in module state so Prev/Next/Today survive re-render */
const calState = { y: null, m: null };
/* refreshed on every render so the modal helpers can read the current data */
let _events = [], _feed = [], _eventsById = {}, _eventsByDay = {}, _feedByDay = {};

const EVENT_TYPES = [
  { value: 'general', label: 'General' },
  { value: 'live', label: 'Live class' },
  { value: 'exam', label: 'Exam' },
  { value: 'batch_start', label: 'Batch start' },
  { value: 'holiday', label: 'Holiday' },
];
const WEEK = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/* colour a chip/pill by admin event_type OR feed kind */
function typeColor(t) {
  return {
    live: 'var(--info)', session: 'var(--info)',
    exam: 'var(--warn)', assessment_due: 'var(--warn)',
    holiday: 'var(--bad)', batch_start: 'var(--good)',
    announcement: 'var(--accent)', general: 'var(--ink-3)',
  }[t] || 'var(--ink-3)';
}
const typeLabel = t => (EVENT_TYPES.find(x => x.value === t) || {}).label || (t || 'General');
const feedKindLabel = k => ({ session: 'Live class', assessment_due: 'Deadline', announcement: 'Announcement' }[k] || k || 'Item');
const audienceLabel = ev => { const a = ev.audience || 'all'; if (a === 'batch') return 'Batch ' + (ev.batch_number || '?'); if (a === 'role') return ev.role || 'Role'; return 'Everyone'; };

/* date helpers (browser-local — new Date() is fine here) */
const pad = n => String(n).padStart(2, '0');
const dayKey = d => d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
const toLocalInput = d => (d instanceof Date && !isNaN(d)) ? `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}` : '';
function evTimeLabel(s) { const d = new Date(s); if (isNaN(d) || (d.getHours() === 0 && d.getMinutes() === 0)) return ''; return d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' }); }
function shortWhen(s) { const d = new Date(s); return isNaN(d) ? '' : d.toLocaleDateString(undefined, { day: 'numeric', month: 'short' }); }
function prettyDay(key) { const [y, m, d] = key.split('-').map(Number); return new Date(y, m - 1, d).toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }); }

/* full weeks of cells covering the given month (leading/trailing days flagged out) */
function monthMatrix(year, month) {
  const startDay = new Date(year, month, 1).getDay();
  const daysInMonth = new Date(year, month + 1, 0).getDate();
  const cells = [];
  for (let i = startDay - 1; i >= 0; i--) cells.push({ date: new Date(year, month, -i), out: true });
  for (let d = 1; d <= daysInMonth; d++) cells.push({ date: new Date(year, month, d), out: false });
  while (cells.length % 7 !== 0) { const last = cells[cells.length - 1].date; cells.push({ date: new Date(last.getFullYear(), last.getMonth(), last.getDate() + 1), out: true }); }
  return cells;
}

const reloadCalendar = () => VIEWS.calendar(document.getElementById('content'), { setCrumbs, params: [] });

registerView('calendar', async (content, ctx) => {
  ctx.setCrumbs('Calendar');
  if (!isAdmin()) { content.innerHTML = pageHead({ title: 'Calendar' }) + emptyState('Admins only', 'The calendar is managed by admins.'); return; }
  if (calState.y == null) { const now = new Date(); calState.y = now.getFullYear(); calState.m = now.getMonth(); }

  const [evRes, fdRes] = await Promise.allSettled([api('/manage/calendar'), api('/manage/calendar/feed')]);
  _events = evRes.status === 'fulfilled' ? arr(evRes.value, 'events') : [];
  _feed = fdRes.status === 'fulfilled' ? arr(fdRes.value, 'items') : [];

  _eventsById = {}; _eventsByDay = {}; _feedByDay = {};
  for (const ev of _events) { _eventsById[ev.id] = ev; const d = new Date(ev.starts_at); if (isNaN(d)) continue; (_eventsByDay[dayKey(d)] ||= []).push(ev); }
  for (const f of _feed) { const d = new Date(f.at); if (isNaN(d)) continue; (_feedByDay[dayKey(d)] ||= []).push(f); }

  const monthTitle = new Date(calState.y, calState.m, 1).toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
  const todayKey = dayKey(new Date());
  const cells = monthMatrix(calState.y, calState.m);

  const gridInner =
    WEEK.map(d => `<div style="padding:7px 4px;text-align:center;font-size:10.5px;font-weight:800;letter-spacing:.04em;color:var(--ink-3);border-right:1px solid var(--line-2);border-bottom:1px solid var(--line);background:var(--panel-2)">${d}</div>`).join('') +
    cells.map(c => cellHtml(c, todayKey)).join('');

  const legend = `<div style="display:flex;flex-wrap:wrap;gap:13px;margin:2px 0 12px">${
    [['live', 'Live'], ['exam', 'Exam'], ['batch_start', 'Batch start'], ['holiday', 'Holiday'], ['general', 'General']]
      .map(([k, l]) => `<span style="display:inline-flex;align-items:center;gap:6px;font-size:11px;font-weight:700;color:var(--ink-3)"><span style="width:9px;height:9px;border-radius:3px;background:${typeColor(k)}"></span>${l}</span>`).join('')
    }<span style="display:inline-flex;align-items:center;gap:6px;font-size:11px;font-weight:700;color:var(--ink-3)"><span style="width:9px;height:9px;border-radius:3px;border:1px dashed var(--ink-4)"></span>Synced · read-only</span></div>`;

  const now = new Date(), startToday = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const upcoming = _feed.filter(f => { const d = new Date(f.at); return !isNaN(d) && !f.ended && d >= startToday; })
    .sort((a, b) => new Date(a.at) - new Date(b.at)).slice(0, 18);

  content.innerHTML =
    pageHead({
      title: 'Calendar', sub: `${_events.length} event${_events.length === 1 ? '' : 's'}`,
      actions: btn('+ New event', { act: 'new', cls: 'btn-primary' }) + btn('Clear history', { act: 'clearhist', cls: 'btn-sm btn-danger' }),
    }) +
    `<div style="display:flex;gap:18px;align-items:flex-start;flex-wrap:wrap">
      <div style="flex:3;min-width:320px">
        <div class="toolbar">
          <button class="btn btn-sm" data-nav="prev" title="Previous month" aria-label="Previous month">‹</button>
          <button class="btn btn-sm" data-nav="today">Today</button>
          <button class="btn btn-sm" data-nav="next" title="Next month" aria-label="Next month">›</button>
          <div style="font-weight:800;font-size:16px;margin-left:6px">${esc(monthTitle)}</div>
          <div class="grow"></div>
        </div>
        ${legend}
        <div style="border:1px solid var(--line);border-radius:var(--r);overflow:hidden;box-shadow:var(--shadow);background:var(--panel)">
          <div id="calGrid" style="display:grid;grid-template-columns:repeat(7,1fr)">${gridInner}</div>
        </div>
      </div>
      <div style="flex:1;min-width:260px;max-width:360px">
        ${card(`<div class="section-title" style="margin:0 0 8px">Upcoming feed</div>` +
      (upcoming.length ? upcoming.map(feedRow).join('') : `<div class="stub">Nothing upcoming.</div>`))}
      </div>
    </div>`;

  content.querySelectorAll('[data-nav]').forEach(b => b.onclick = () => {
    const n = b.dataset.nav;
    if (n === 'prev') { if (--calState.m < 0) { calState.m = 11; calState.y--; } }
    else if (n === 'next') { if (++calState.m > 11) { calState.m = 0; calState.y++; } }
    else { const t = new Date(); calState.y = t.getFullYear(); calState.m = t.getMonth(); }
    reloadCalendar();
  });
  wire(content, { acts: { new: () => eventForm({ dateKey: dayKey(new Date()) }), clearhist: clearHistory } });

  content.querySelector('#calGrid').addEventListener('click', e => {
    const ev = e.target.closest('[data-ev]'); if (ev) return eventDetail(_eventsById[ev.dataset.ev]);
    const fd = e.target.closest('[data-feed]'); if (fd) return feedInfo(_feed[+fd.dataset.feed]);
    const more = e.target.closest('[data-more]'); if (more) return dayModal(more.dataset.more);
    const day = e.target.closest('[data-day]'); if (day) return eventForm({ dateKey: day.dataset.day });
  });
  content.querySelectorAll('[data-feedrow]').forEach(el => el.onclick = () => feedInfo(_feed[+el.dataset.feedrow]));
});

/* ---- grid cell ---- */
function cellHtml(cell, todayKey) {
  const key = dayKey(cell.date), isToday = key === todayKey;
  const evs = _eventsByDay[key] || [], fds = _feedByDay[key] || [];
  const items = [...evs.map(o => ({ t: 'ev', o, at: o.starts_at })), ...fds.map(o => ({ t: 'fd', o, at: o.at }))]
    .sort((a, b) => new Date(a.at) - new Date(b.at));
  const MAX = 3, shown = items.slice(0, MAX), extra = items.length - shown.length;
  const num = isToday
    ? `<span style="display:inline-grid;place-items:center;min-width:20px;height:20px;padding:0 5px;border-radius:999px;background:var(--accent);color:#fff;font-size:11.5px;font-weight:800">${cell.date.getDate()}</span>`
    : `<span style="font-size:12px;font-weight:700;color:${cell.out ? 'var(--ink-4)' : 'var(--ink-2)'}">${cell.date.getDate()}</span>`;
  return `<div data-day="${key}" style="min-height:98px;padding:5px 6px 7px;border-right:1px solid var(--line-2);border-bottom:1px solid var(--line-2);background:${cell.out ? 'var(--panel-2)' : 'var(--panel)'};cursor:pointer;min-width:0">
    <div style="display:flex;margin-bottom:2px">${num}</div>
    ${shown.map(it => it.t === 'ev' ? evChip(it.o) : feedChip(it.o)).join('')}
    ${extra > 0 ? `<div data-more="${key}" style="margin-top:3px;font-size:10.5px;font-weight:700;color:var(--ink-3);cursor:pointer">+${extra} more</div>` : ''}
  </div>`;
}
function evChip(ev) {
  const c = typeColor(ev.event_type), tl = evTimeLabel(ev.starts_at);
  return `<div data-ev="${esc(ev.id)}" title="${esc(ev.title)}" style="margin-top:3px;padding:2px 6px;border-radius:4px;font-size:11px;font-weight:700;line-height:1.4;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;cursor:pointer;background:color-mix(in srgb,${c} 15%,transparent);color:${c};border-left:2px solid ${c}">${tl ? `<span style="font-weight:800">${esc(tl)}</span> ` : ''}${esc(ev.title)}</div>`;
}
function feedChip(f) {
  const c = typeColor(f.kind), i = _feed.indexOf(f);
  return `<div data-feed="${i}" title="${esc(feedKindLabel(f.kind))}: ${esc(f.title)}" style="display:flex;align-items:center;gap:4px;margin-top:3px;padding:2px 6px;border-radius:4px;font-size:11px;font-weight:600;line-height:1.4;cursor:pointer;color:var(--ink-2);border:1px dashed color-mix(in srgb,${c} 50%,var(--line))"><span style="flex:none;width:6px;height:6px;border-radius:50%;background:${c}"></span><span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(f.title)}</span></div>`;
}
function feedRow(f) {
  const c = typeColor(f.kind), i = _feed.indexOf(f);
  return `<div data-feedrow="${i}" style="display:flex;align-items:center;gap:10px;padding:9px 2px;border-bottom:1px solid var(--line-2);cursor:pointer">
    <span style="flex:none;width:8px;height:8px;border-radius:50%;background:${c}"></span>
    <div style="min-width:0;flex:1">
      <div style="font-weight:700;font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${esc(f.title)}</div>
      <div class="muted" style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${esc(feedKindLabel(f.kind))}${f.course ? ' · ' + esc(f.course) : ''}</div>
    </div>
    <div class="muted" style="flex:none;font-size:11px">${esc(shortWhen(f.at))}</div>
  </div>`;
}

/* ---- all items on one day ---- */
function dayModal(key) {
  const evs = _eventsByDay[key] || [], fds = _feedByDay[key] || [];
  const rows =
    evs.map(ev => { const c = typeColor(ev.event_type), tl = evTimeLabel(ev.starts_at); return `<div data-ev="${esc(ev.id)}" style="display:flex;align-items:center;gap:9px;padding:9px 2px;border-bottom:1px solid var(--line-2);cursor:pointer"><span style="flex:none;width:8px;height:8px;border-radius:50%;background:${c}"></span><div style="flex:1;min-width:0"><div style="font-weight:700">${esc(ev.title)}</div><div class="muted">${esc(typeLabel(ev.event_type))}${tl ? ' · ' + esc(tl) : ''}</div></div><span class="muted">Edit ›</span></div>`; }).join('') +
    fds.map(f => { const c = typeColor(f.kind), i = _feed.indexOf(f); return `<div data-feed="${i}" style="display:flex;align-items:center;gap:9px;padding:9px 2px;border-bottom:1px solid var(--line-2);cursor:pointer"><span style="flex:none;width:8px;height:8px;border-radius:50%;background:${c};opacity:.6"></span><div style="flex:1;min-width:0"><div style="font-weight:600">${esc(f.title)}</div><div class="muted">${esc(feedKindLabel(f.kind))}${f.course ? ' · ' + esc(f.course) : ''}</div></div><span class="muted">Read-only</span></div>`; }).join('');
  openModal({
    title: prettyDay(key),
    bodyHtml: (evs.length || fds.length) ? rows : emptyState('Nothing on this day', 'Add an event below.'),
    footHtml: `<button class="btn btn-primary" data-x="add">+ Add event</button><button class="btn btn-ghost" data-x="c">Close</button>`,
    onMount(root, close) {
      root.querySelector('[data-x=c]').onclick = close;
      root.querySelector('[data-x=add]').onclick = () => { close(); eventForm({ dateKey: key }); };
      root.querySelectorAll('[data-ev]').forEach(el => el.onclick = () => { close(); eventDetail(_eventsById[el.dataset.ev]); });
      root.querySelectorAll('[data-feed]').forEach(el => el.onclick = () => { close(); feedInfo(_feed[+el.dataset.feed]); });
    },
  });
}

/* ---- editable event: detail → edit / delete ---- */
function eventDetail(ev) {
  if (!ev) return;
  const c = typeColor(ev.event_type);
  openModal({
    title: ev.title || 'Event',
    bodyHtml: dl([
      ['Type', `<span class="pill" style="background:color-mix(in srgb,${c} 15%,transparent);color:${c}">${esc(typeLabel(ev.event_type))}</span>`],
      ['Starts', esc(fmtDateTime(ev.starts_at))],
      ['Ends', ev.ends_at ? esc(fmtDateTime(ev.ends_at)) : '—'],
      ['Location', esc(ev.location) || '—'],
      ['Audience', esc(audienceLabel(ev))],
    ]) + (ev.description ? `<div class="card" style="margin-top:12px;white-space:pre-wrap">${esc(ev.description)}</div>` : ''),
    footHtml: `<button class="btn btn-danger" data-x="del">Delete</button><button class="btn btn-primary" data-x="edit">Edit</button><button class="btn btn-ghost" data-x="c">Close</button>`,
    onMount(root, close) {
      root.querySelector('[data-x=c]').onclick = close;
      root.querySelector('[data-x=edit]').onclick = () => { close(); eventForm({ event: ev }); };
      root.querySelector('[data-x=del]').onclick = async () => {
        if (!await confirmModal('Delete “' + (ev.title || 'this event') + '”?', { danger: true, confirmLabel: 'Delete' })) return;
        close(); await api('/manage/calendar/' + ev.id, { method: 'DELETE' }); toast('Event deleted'); reloadCalendar();
      };
    },
  });
}

/* ---- read-only feed item ---- */
function feedInfo(f) {
  if (!f) return;
  const c = typeColor(f.kind);
  openModal({
    title: f.title || 'Item',
    bodyHtml: dl([
      ['Type', `<span class="pill" style="background:color-mix(in srgb,${c} 15%,transparent);color:${c}">${esc(feedKindLabel(f.kind))}</span>`],
      ['Course', esc(f.course) || '—'],
      ['When', esc(fmtDateTime(f.at)) + (timeAgo(f.at) ? ` <span class="muted">(${esc(timeAgo(f.at))})</span>` : '')],
      ['Status', f.ended ? pill('ended', 'Ended') : pill('upcoming', 'Upcoming')],
    ]),
    footHtml: `<span style="margin-right:auto;color:var(--ink-4);font-size:11.5px;font-weight:600">Synced from classes, deadlines & announcements</span><button class="btn btn-ghost" data-x="c">Close</button>`,
    onMount(root, close) { root.querySelector('[data-x=c]').onclick = close; },
  });
}

/* ---- create / edit form ---- */
function eventForm({ event, dateKey }) {
  const editing = !!event;
  const start = editing ? toLocalInput(new Date(event.starts_at)) : (dateKey ? dateKey + 'T09:00' : toLocalInput(new Date()));
  formModal({
    title: editing ? 'Edit event' : 'New event', wide: true, submitLabel: editing ? 'Save changes' : 'Create event',
    fields: [
      { name: 'title', label: 'Title', required: true, value: editing ? event.title : '', placeholder: 'e.g. Midterm exam' },
      { name: 'event_type', label: 'Type', type: 'select', value: editing ? (event.event_type || 'general') : 'general', options: EVENT_TYPES },
      { name: 'starts_at', label: 'Starts', type: 'datetime', required: true, value: start },
      { name: 'ends_at', label: 'Ends', type: 'datetime', hint: 'optional', value: editing && event.ends_at ? toLocalInput(new Date(event.ends_at)) : '' },
      { name: 'location', label: 'Location', hint: 'optional', value: editing ? event.location : '', placeholder: 'e.g. Zoom / Room 4' },
      { name: 'audience', label: 'Audience', type: 'select', value: editing ? (event.audience || 'all') : 'all', options: [{ value: 'all', label: 'Everyone' }, { value: 'batch', label: 'A batch' }, { value: 'role', label: 'A role' }] },
      { name: 'batch_number', label: 'Batch', hint: 'used when audience = batch', value: editing && event.batch_number ? event.batch_number : '', placeholder: 'e.g. 12' },
      { name: 'role', label: 'Role', type: 'select', hint: 'used when audience = role', value: editing ? (event.role || '') : '', options: [{ value: '', label: '— choose —' }, { value: 'student', label: 'Students' }, { value: 'instructor', label: 'Instructors' }, { value: 'manager', label: 'Managers' }] },
      { name: 'description', label: 'Description', type: 'textarea', rows: 3, hint: 'optional', value: editing ? event.description : '' },
    ],
    async onSubmit(v) {
      if (!v.starts_at) return 'Start date/time is required';
      const body = { title: v.title, description: v.description || '', location: v.location || '', starts_at: v.starts_at, ends_at: v.ends_at || '', event_type: v.event_type || 'general', audience: v.audience || 'all' };
      if (v.audience === 'batch') { if (!String(v.batch_number || '').trim()) return 'Batch is required for a batch event'; body.batch_number = String(v.batch_number).trim(); }
      if (v.audience === 'role') { if (!v.role) return 'Choose a role for a role event'; body.role = v.role; }
      if (editing) await api('/manage/calendar/' + event.id, { method: 'PATCH', body });
      else await api('/manage/calendar', { method: 'POST', body });
      toast(editing ? 'Event updated' : 'Event created', 'good');
      reloadCalendar();
    },
  });
}

/* ---- bulk delete past events ---- */
async function clearHistory() {
  if (!await confirmModal('Delete all PAST calendar events (those already ended)? Live classes, deadlines and announcements are not affected.', { danger: true, confirmLabel: 'Clear history' })) return;
  const r = await api('/manage/calendar/history', { method: 'DELETE' });
  toast((r.events_deleted || 0) + ' past event(s) cleared', 'good');
  reloadCalendar();
}
