/* Federated search — the topbar search box routes here as #/search?q=<term>.
 * Queries Courses (all staff), plus People + Videos (admins only), filters each
 * list client-side and renders grouped, capped result sections. Read-only.
 * Uses ONLY the core.js window helpers. All top-level names are `srch`-prefixed. */
'use strict';

const SRCH_CAP = 20; // per-group result cap; overflow shown as "+N more"

/* Pull the URL-decoded query out of #/search?q=<term>. Defensive on malformed hashes. */
function srchQuery() {
  const h = location.hash || '';
  const i = h.indexOf('?');
  if (i < 0) return '';
  try { return (new URLSearchParams(h.slice(i + 1)).get('q') || '').trim(); }
  catch (_) { return ''; }
}

/* case-insensitive "does this field contain q" (q is already lower-cased) */
const srchHit = (field, q) => String(field == null ? '' : field).toLowerCase().includes(q);

const srchCourseMatch = (c, q) => [c.title, c.label, c.id, c.status, c.enroll_type].some(f => srchHit(f, q));
const srchUserMatch = (u, q) => [u.full_name, u.email, u.phone, u.login_id, u.role, u.username, u.course_label, u.batch].some(f => srchHit(f, q));
const srchVideoMatch = (v, q) => [v.title, v.id, v.status].some(f => srchHit(f, q));

registerView('search', async (content, ctx) => {
  const q = srchQuery();
  ctx.setCrumbs('Search');

  content.innerHTML =
    pageHead({
      title: 'Search',
      sub: q ? `Results for “${q}”` : 'Type a term to search across the console',
    }) +
    `<div class="toolbar">
       <input class="search" id="srchInput" placeholder="Search courses${isAdmin() ? ', people, videos' : ''}…" value="${esc(q)}" autocomplete="off" spellcheck="false">
       <div class="grow"></div>
     </div>
     <div id="srchResults"></div>`;

  // In-page refine box: prefilled, re-runs the search on Enter.
  const input = content.querySelector('#srchInput');
  if (input) {
    input.onkeydown = e => {
      if (e.key !== 'Enter') return;
      const t = input.value.trim();
      if (t) go('#/search?q=' + encodeURIComponent(t));
    };
    input.focus();
    try { input.setSelectionRange(input.value.length, input.value.length); } catch (_) {}
  }

  const out = content.querySelector('#srchResults');
  if (!q) {
    out.innerHTML = emptyState('Type a query', 'Search across courses' + (isAdmin() ? ', people and videos' : '') + ' — enter a term above.');
    return;
  }
  out.innerHTML = loadingPage();
  const ql = q.toLowerCase();

  // Fan out in parallel; each call is individually guarded so one failure can't
  // sink the others (People/Videos are admin-only, so skip them for instructors).
  const tasks = [api('/manage/courses').catch(() => null)];
  if (isAdmin()) tasks.push(api('/manage/users').catch(() => null), api('/manage/videos').catch(() => null));
  const settled = await Promise.allSettled(tasks);
  const val = i => (settled[i] && settled[i].status === 'fulfilled') ? settled[i].value : null;

  const courses = arr(val(0), 'courses').filter(c => srchCourseMatch(c, ql));
  const users = isAdmin() ? arr(val(1), 'users').filter(u => srchUserMatch(u, ql)) : [];
  const videos = isAdmin() ? arr(val(2), 'videos').filter(v => srchVideoMatch(v, ql)) : [];

  let html = '';
  const wires = []; // {wid, rowClick} — wired per-group after mount

  const addGroup = (key, title, list, columns, rowClick) => {
    if (!list.length) return; // empty groups are hidden
    const capped = list.slice(0, SRCH_CAP);
    const more = list.length - capped.length;
    const wid = 'srchG_' + key;
    html += `<div class="section-title" style="margin-top:18px">${esc(title)} <span class="muted">(${list.length})</span></div>`;
    html += `<div id="${wid}">${dataTable({ clickable: true, columns, rows: capped })}</div>`;
    if (more > 0) html += `<p class="stub" style="margin-top:6px">+${more} more — refine your search to narrow results.</p>`;
    wires.push({ wid, rowClick });
  };

  // Courses → course detail
  addGroup('courses', 'Courses', courses, [
    { label: 'Title', render: c => `<b>${esc(c.title || 'Untitled')}</b>` },
    { label: 'Course ID', render: c => `<span class="muted">${esc(c.label || c.id)}</span>` },
    { label: 'Status', render: c => pill(c.status || 'draft') },
    { label: 'Enrollment', render: c => esc(c.enroll_type || '—') },
  ], id => go('#/courses/' + id));

  // People → student detail for students; staff are noted and sent to the Staff section
  addGroup('people', 'People', users, [
    { label: 'Name', render: u => `<b>${esc(u.full_name || 'Unnamed')}</b>${(u.email || u.login_id) ? `<div class="sub">${esc(u.email || u.login_id)}</div>` : ''}` },
    { label: 'Role', render: u => tag(u.role || 'user') + (u.role && u.role !== 'student' ? ' ' + tag('staff') : '') },
    { label: 'Status', render: u => pill(u.is_active === false ? 'inactive' : 'active') },
    { label: 'Batch / Course', render: u => u.batch ? tag('Batch ' + u.batch) : (u.course_label ? tag(u.course_label) : '<span class="muted">—</span>') },
  ], id => {
    const u = users.find(x => String(x.id) === String(id));
    if (u && u.role === 'student') go('#/students/' + id); else go('#/staff');
  });

  // Videos → the Video Store (no per-video detail route exists)
  addGroup('videos', 'Videos', videos, [
    { label: 'Title', render: v => `<b>${esc(v.title || 'Untitled')}</b>` },
    { label: 'Status', render: v => pill(v.status || 'processing') },
    { label: 'Video ID', render: v => `<span class="muted">${esc(v.id)}</span>` },
  ], () => go('#/videos'));

  out.innerHTML = html || emptyState('No results', 'Nothing matched “' + esc(q) + '”. Try a different term.');

  // Wire each group's rows to its own destination.
  wires.forEach(w => { const el = out.querySelector('#' + w.wid); if (el) wire(el, { rowClick: w.rowClick }); });
});
