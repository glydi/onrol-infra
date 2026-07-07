/* ONROL Staff Console — vanilla JS scaffold (no build, no deps).
 * Pattern to extend: auth (JWT + device header) → hash router → role-aware
 * sidebar → views. "Courses" is fully wired end-to-end; other sections are
 * stubs that name the exact API endpoint to build against. Alpine/HTMX can be
 * layered on per-screen later; nothing here depends on a framework. */
'use strict';

const API = '/api/v1';
const K = { tok: 'onrol.staff.token', dev: 'onrol.staff.device', usr: 'onrol.staff.user' };

/* ---------- tiny helpers ---------- */
const $ = (s, r = document) => r.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
function uuid() { return (crypto.randomUUID && crypto.randomUUID()) || 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => { const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16); }); }
function deviceId() { let d = localStorage.getItem(K.dev); if (!d) { d = uuid(); localStorage.setItem(K.dev, d); } return d; }
function toast(msg) { const t = document.createElement('div'); t.className = 'toast'; t.textContent = msg; document.body.appendChild(t); setTimeout(() => t.remove(), 2600); }

/* ---------- session ---------- */
let USER = null;
try { USER = JSON.parse(localStorage.getItem(K.usr) || 'null'); } catch (_) {}
const token = () => localStorage.getItem(K.tok);
const isAdmin = () => USER && (USER.role === 'manager' || USER.role === 'superadmin');
const isStaff = () => USER && ['manager', 'superadmin', 'instructor'].includes(USER.role);

/* ---------- API client ---------- */
async function api(path, { method = 'GET', body } = {}) {
  const res = await fetch(API + path, {
    method,
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ' + (token() || ''),
      'X-Device-UUID': deviceId(),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.status === 401 || res.status === 403) {
    // fall through for 403 on data endpoints; only bounce to login on 401.
    if (res.status === 401) { logout(); throw new Error('signed out'); }
  }
  const txt = await res.text();
  const data = txt ? JSON.parse(txt) : {};
  if (!res.ok) throw new Error(data.error || res.statusText);
  return data;
}
// pull an array out of either [...] or {key:[...]}
const arr = (d, key) => Array.isArray(d) ? d : (d && Array.isArray(d[key]) ? d[key] : []);

/* ---------- auth ---------- */
async function login(identifier, password) {
  const res = await fetch(API + '/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Device-UUID': deviceId() },
    body: JSON.stringify({ email: identifier, password, portal: 'any', platform: 'web', model: 'Staff Console' }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || 'Sign-in failed');
  if (!['manager', 'superadmin', 'instructor'].includes(data.user?.role)) {
    throw new Error('This console is for staff (admin & instructor) only.');
  }
  localStorage.setItem(K.tok, data.access_token);
  localStorage.setItem(K.usr, JSON.stringify(data.user));
  USER = data.user;
}
function logout() { localStorage.removeItem(K.tok); localStorage.removeItem(K.usr); USER = null; showLogin(); }

/* ---------- navigation model (IA) ---------- */
// admin:true → managers/superadmins only. stub → endpoint hint for the builder.
const NAV = [
  { group: 'Overview', items: [{ id: '', icon: '▦', label: 'Dashboard' }] },
  { group: 'Teaching', items: [
    { id: 'courses', icon: '▤', label: 'Courses' },
    { id: 'live', icon: '◉', label: 'Live Classes', stub: 'GET /manage/courses/:id/sessions + GET /live-host/sessions' },
    { id: 'ask-mentor', icon: '✎', label: 'Ask Mentor', stub: 'GET /manage/mentor-questions → reply via POST /modules|courses/:id/comments {body, thread_user_id}' },
  ] },
  { group: 'People', admin: true, items: [
    { id: 'students', icon: '☰', label: 'Students', stub: 'GET /manage/users → Student detail (enrollments/batches/devices/certs/lead)' },
    { id: 'enrollments', icon: '⇲', label: 'Enrollments', stub: 'GET /manage/enrollment-requests · GET /manage/converted-leads' },
    { id: 'staff', icon: '★', label: 'Staff & Access', stub: 'GET /manage/users (roles) · /manage/groups · /manage/instructors' },
  ] },
  { group: 'Engage', admin: true, items: [
    { id: 'announcements', icon: '📣', label: 'Announcements', stub: 'GET|POST|DELETE /manage/announcements' },
    { id: 'communities', icon: '⌗', label: 'Communities', stub: 'GET|POST /manage/community/servers · /channels' },
    { id: 'calendar', icon: '▦', label: 'Calendar', stub: 'GET /manage/calendar + /feed · POST|PATCH|DELETE /manage/calendar/:id' },
  ] },
  { group: 'Library', items: [
    { id: 'videos', icon: '▷', label: 'Video Store', stub: 'GET /manage/videos · upload /manage/videos/upload/{init,sign,part,complete} · retranscode · DELETE' },
  ] },
  { group: 'Insights', items: [
    { id: 'reports', icon: '◔', label: 'Reports', stub: 'GET /manage/courses/:id/report/{completion,grades,attendance}' },
  ] },
];

/* ---------- sidebar ---------- */
function renderSidebar() {
  const cur = (location.hash.replace(/^#\/?/, '').split('/')[0]) || '';
  let html = '<div class="side-brand">ONROL</div>';
  for (const g of NAV) {
    if (g.admin && !isAdmin()) continue;
    const items = g.items.filter((it) => !(it.admin && !isAdmin()));
    if (!items.length) continue;
    html += `<div class="side-group">${esc(g.group)}</div>`;
    for (const it of items) {
      const active = it.id === cur ? ' active' : '';
      const badge = it._badge ? `<span class="badge">${it._badge}</span>` : '';
      html += `<a class="side-link${active}" href="#/${it.id}"><span class="ic">${it.icon}</span>${esc(it.label)}${badge}</a>`;
    }
  }
  html += `<div class="side-foot"><a class="side-link" href="#/profile"><span class="ic">◍</span>Profile</a>
           <a class="side-link" id="signout"><span class="ic">⎋</span>Sign out</a></div>`;
  $('#sidebar').innerHTML = html;
  $('#signout').onclick = logout;
}

/* ---------- router ---------- */
const VIEWS = {}; // id → async function(content, params)
function crumbs(...parts) { $('#crumbs').innerHTML = parts.map((p, i) => i === parts.length - 1 ? esc(p) : `<span class="dim">${esc(p)} ›</span>`).join(' '); }

async function route() {
  if (!token() || !isStaff()) return showLogin();
  const raw = location.hash.replace(/^#\/?/, '');
  const [seg, ...rest] = raw.split('/');
  renderSidebar();
  const c = $('#content'); c.innerHTML = '<div class="empty">Loading…</div>';
  try {
    const view = VIEWS[seg] || VIEWS['']; // default dashboard
    await view(c, rest);
  } catch (e) { c.innerHTML = `<div class="card"><b>Couldn’t load.</b><br><span class="stub">${esc(e.message)}</span></div>`; }
  $('.content').scrollTop = 0;
}

/* ---------- VIEW: Dashboard ---------- */
VIEWS[''] = async (c) => {
  crumbs('Dashboard');
  const counts = { requests: '·', mentor: '·', videos: '·' };
  const [r, m, v] = await Promise.allSettled([
    api('/manage/enrollment-requests'), api('/manage/mentor-questions'), api('/manage/videos'),
  ]);
  if (r.status === 'fulfilled') counts.requests = arr(r.value, 'requests').length;
  if (m.status === 'fulfilled') counts.mentor = m.value.waiting ?? arr(m.value, 'questions').length;
  if (v.status === 'fulfilled') counts.videos = arr(v.value, 'videos').filter((x) => x.status === 'processing').length;
  // reflect badges in the sidebar
  NAV.forEach((g) => g.items.forEach((it) => { if (it.id === 'ask-mentor' && counts.mentor) it._badge = counts.mentor; if (it.id === 'enrollments' && counts.requests) it._badge = counts.requests; }));
  renderSidebar();
  c.innerHTML = `
    <div class="page-head"><h1>Dashboard</h1><span class="sub">Welcome back, ${esc(USER.full_name || 'there')}</span></div>
    <div class="attn">
      <a href="#/enrollments"><div class="big">${counts.requests}</div><div class="lab">Enrollment requests</div></a>
      <a href="#/ask-mentor"><div class="big">${counts.mentor}</div><div class="lab">Mentor questions waiting</div></a>
      <a href="#/videos"><div class="big">${counts.videos}</div><div class="lab">Videos processing</div></a>
    </div>
    <p class="stub" style="margin-top:22px">This is the scaffold. Build each sidebar section following the <b>Courses</b> pattern; every section names its API endpoint on its page.</p>`;
};

/* ---------- VIEW: Courses (list) — fully wired ---------- */
VIEWS['courses'] = async (c, rest) => {
  if (rest[0]) return courseDetail(c, rest[0], rest[1] || 'curriculum');
  crumbs('Courses');
  const d = await api('/manage/courses');
  const courses = arr(d, 'courses');
  const rows = courses.map((co) => `
    <tr class="clickable" data-id="${esc(co.id)}">
      <td><b>${esc(co.title || 'Untitled')}</b></td>
      <td class="stub">${esc(co.label || co.id)}</td>
      <td><span class="pill ${esc(co.status || 'draft')}">${esc(co.status || 'draft')}</span></td>
      <td>${esc(co.enroll_type || '')}</td>
    </tr>`).join('');
  c.innerHTML = `
    <div class="page-head"><h1>Courses</h1><span class="sub">${courses.length} total</span>
      ${isAdmin() ? '<div class="actions"><button class="btn btn-primary" id="newCourse">+ New course</button></div>' : ''}</div>
    <div class="tablewrap"><table>
      <thead><tr><th>Title</th><th>Course ID</th><th>Status</th><th>Enrollment</th></tr></thead>
      <tbody>${rows || '<tr><td colspan="4" class="empty">No courses yet.</td></tr>'}</tbody>
    </table></div>`;
  c.querySelectorAll('tr.clickable').forEach((tr) => tr.onclick = () => { location.hash = `#/courses/${tr.dataset.id}`; });
  const nc = $('#newCourse'); if (nc) nc.onclick = () => toast('New-course form → POST /manage/courses {title,label,description,instructor_id,enroll_type}');
};

/* ---------- Course detail (tabs) ---------- */
const COURSE_TABS = [
  ['curriculum', 'Curriculum'], ['live', 'Live Classes'], ['assessments', 'Assessments'],
  ['students', 'Students'], ['study', 'Study Hub'], ['discussion', 'Discussion'],
  ['certificates', 'Certificates'], ['settings', 'Settings'],
];
async function courseDetail(c, id, tab) {
  const co = await api('/manage/courses/' + id);
  crumbs('Courses', co.title || 'Course');
  const tabsHtml = COURSE_TABS.map(([k, l]) => `<div class="tab ${k === tab ? 'active' : ''}" data-tab="${k}">${l}</div>`).join('');
  c.innerHTML = `
    <div class="page-head"><h1>${esc(co.title || 'Course')}</h1>
      <span class="sub">${esc(co.label || id)} · <span class="pill ${esc(co.status || 'draft')}">${esc(co.status || 'draft')}</span></span></div>
    <div class="tabs">${tabsHtml}</div>
    <div id="tabBody"></div>`;
  c.querySelectorAll('.tab').forEach((t) => t.onclick = () => { location.hash = `#/courses/${id}/${t.dataset.tab}`; });
  const body = $('#tabBody');
  if (tab === 'curriculum') renderCurriculum(body, co);
  else if (tab === 'settings') renderSettings(body, co);
  else body.innerHTML = tabStub(tab, id);
}

function renderCurriculum(body, co) {
  const mods = co.modules || [];
  if (!mods.length) { body.innerHTML = `<div class="empty">No modules yet. <br><span class="stub">Add: POST /manage/courses/${esc(co.id)}/modules</span></div>`; return; }
  const renderMod = (m) => {
    const lessons = m.lessons || [];
    const labels = m.day_labels || {};
    const byDay = {};
    lessons.forEach((l) => { const d = l.day_number ?? null; (byDay[d] = byDay[d] || []).push(l); });
    const keys = Object.keys(byDay).sort((a, b) => (a === 'null' ? 1 : b === 'null' ? -1 : a - b));
    const days = keys.map((k) => {
      const name = k === 'null' ? 'Unscheduled' : (labels[k] || 'Day ' + k);
      const items = byDay[k].map((l) => `<div class="lesson"><span class="type">${esc(l.type || 'lesson')}</span>${esc(l.title || '')}</div>`).join('');
      return `<div class="day"><div class="day-name">${esc(name)}</div>${items}</div>`;
    }).join('');
    const subs = (m.submodules || []).map(renderMod).join('');
    return `<div class="module"><div class="module-head">▸ ${esc(m.title || 'Module')} <span class="count">${lessons.length} lesson(s)</span></div>${days}${subs}</div>`;
  };
  body.innerHTML = mods.map(renderMod).join('') +
    `<p class="stub" style="margin-top:14px">Read-only preview. Wire editing: modules <code>POST /manage/courses/:id/modules</code>, lessons <code>POST /manage/modules/:id/lessons</code> · <code>PATCH|DELETE /manage/lessons/:id</code>, day names <code>POST /manage/modules/:id/day-label</code>.</p>`;
}

function renderSettings(body, co) {
  body.innerHTML = `
    <div class="card"><dl class="dl">
      <dt>Title</dt><dd>${esc(co.title || '')}</dd>
      <dt>Course ID</dt><dd>${esc(co.label || co.id)}</dd>
      <dt>Status</dt><dd>${esc(co.status || 'draft')}</dd>
      <dt>Enrollment</dt><dd>${esc(co.enroll_type || '')}</dd>
      <dt>Instructor</dt><dd>${esc(co.instructor || '—')}</dd>
      <dt>Description</dt><dd>${esc(co.description || '—')}</dd>
    </dl></div>
    <p class="stub" style="margin-top:14px">Wire editing → <code>PATCH /manage/courses/${esc(co.id)}</code> (title, label, description, image_url, instructor_id, status, enroll_type, batch_size, batch_auto, batch_target, in_explore). Batches → <code>GET /manage/courses/${esc(co.id)}/batches</code>.</p>`;
}

const TAB_ENDPOINTS = {
  live: 'GET|POST /manage/courses/:id/sessions · PATCH|DELETE /manage/sessions/:id · host: POST /me/live/:id/control',
  assessments: 'GET|POST /manage/courses/:id/assessments · questions /manage/assessments/:id/questions · submissions + POST /manage/submissions/:id/grade',
  students: 'GET /manage/courses/:id/students · POST /manage/courses/:id/enroll · GET …/report/completion',
  study: 'GET|POST /manage/courses/:id/study · POST …/study/generate · PATCH|DELETE /manage/study/:id',
  discussion: 'GET /manage/courses/:id/comments',
  certificates: 'GET|POST /manage/courses/:id/certificates · DELETE …/certificates/:userId',
};
const tabStub = (tab, id) => `<div class="card"><b>${esc(tab)} — scaffold</b><p class="stub" style="margin-top:8px">Build this tab against:<br><code>${esc((TAB_ENDPOINTS[tab] || '').replace(/:id/g, id))}</code></p></div>`;

/* ---------- stub views for the other sidebar sections ---------- */
NAV.forEach((g) => g.items.forEach((it) => {
  if (it.id === '' || it.id === 'courses') return;
  VIEWS[it.id] = async (c) => {
    crumbs(it.label);
    c.innerHTML = `<div class="page-head"><h1>${esc(it.label)}</h1></div>
      <div class="card"><b>Scaffolded — build this next.</b>
      <p class="stub" style="margin-top:10px">Follow the <b>Courses</b> pattern (list → detail). API:<br><code>${esc(it.stub || '')}</code></p></div>`;
  };
}));
VIEWS['profile'] = async (c) => {
  crumbs('Profile');
  c.innerHTML = `<div class="page-head"><h1>Profile</h1></div>
    <div class="card"><dl class="dl">
      <dt>Name</dt><dd>${esc(USER.full_name || '')}</dd>
      <dt>Email</dt><dd>${esc(USER.email || '—')}</dd>
      <dt>Role</dt><dd>${esc(USER.role || '')}</dd>
    </dl></div>`;
};

/* ---------- shell wiring ---------- */
function showLogin() {
  $('#app').hidden = true; $('#login').hidden = false;
}
function showApp() {
  $('#login').hidden = true; $('#app').hidden = false;
  const initials = (USER.full_name || 'S').split(' ').map((x) => x[0]).slice(0, 2).join('').toUpperCase();
  $('#userChip').innerHTML = `<div class="avatar">${esc(initials)}</div><div><div>${esc(USER.full_name || '')}</div><div class="role">${esc(USER.role || '')}</div></div>`;
  $('#menuBtn').onclick = () => $('#sidebar').classList.toggle('open');
  $('#globalSearch').onkeydown = (e) => { if (e.key === 'Enter') toast('Global search → GET /manage/users + /manage/courses (build me)'); };
  route();
}

$('#loginForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const btn = $('#loginBtn'); btn.disabled = true; $('#loginErr').textContent = '';
  try {
    await login($('#loginId').value.trim(), $('#loginPw').value);
    showApp();
  } catch (err) { $('#loginErr').textContent = err.message; }
  finally { btn.disabled = false; }
});
window.addEventListener('hashchange', route);

/* ---------- boot ---------- */
if (token() && isStaff()) showApp(); else showLogin();
