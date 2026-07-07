/* ONROL Staff Console — CORE (shared contract). No build, no deps.
 * Section files (view-*.js) call registerView(id, fn) and use ONLY the helpers
 * exposed here. Load order: core.js first, then view-*.js. */
'use strict';

/* ========== session / api ========== */
const API = '/api/v1';
const K = { tok: 'onrol.staff.token', dev: 'onrol.staff.device', usr: 'onrol.staff.user', thm: 'onrol.staff.theme' };
function uuid() { return (crypto.randomUUID && crypto.randomUUID()) || 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => { const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16); }); }
function deviceId() { let d = localStorage.getItem(K.dev); if (!d) { d = uuid(); localStorage.setItem(K.dev, d); } return d; }
let USER = null; try { USER = JSON.parse(localStorage.getItem(K.usr) || 'null'); } catch (_) {}
const token = () => localStorage.getItem(K.tok);
const isAdmin = () => !!USER && (USER.role === 'manager' || USER.role === 'superadmin');
const isStaff = () => !!USER && ['manager', 'superadmin', 'instructor'].includes(USER.role);

async function api(path, { method = 'GET', body } = {}) {
  const res = await fetch(API + path, {
    method,
    headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + (token() || ''), 'X-Device-UUID': deviceId() },
    body: body != null ? JSON.stringify(body) : undefined,
  });
  if (res.status === 401) { logout(); throw new Error('Session expired'); }
  const txt = await res.text();
  let data = {}; try { data = txt ? JSON.parse(txt) : {}; } catch (_) { data = { error: txt }; }
  if (!res.ok) throw new Error(data.error || res.statusText || 'Request failed');
  return data;
}
const arr = (d, key) => Array.isArray(d) ? d : (d && Array.isArray(d[key]) ? d[key] : (d && d[key] ? d[key] : []));

/* ========== formatting ========== */
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
function fmtDate(s) { const d = new Date(s); return isNaN(d) ? '—' : d.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' }); }
function fmtDateTime(s) { const d = new Date(s); return isNaN(d) ? '—' : d.toLocaleString(undefined, { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }); }
function fmtDur(sec) { sec = +sec || 0; const h = sec / 3600 | 0, m = (sec % 3600) / 60 | 0; return h ? `${h}h ${m}m` : `${m}m ${sec % 60 | 0}s`; }
function timeAgo(s) { const d = new Date(s); if (isNaN(d)) return ''; const t = (Date.now() - d) / 1000; if (t < 60) return 'just now'; if (t < 3600) return (t / 60 | 0) + 'm ago'; if (t < 86400) return (t / 3600 | 0) + 'h ago'; return (t / 86400 | 0) + 'd ago'; }
const initials = n => (n || 'S').trim().split(/\s+/).map(x => x[0]).slice(0, 2).join('').toUpperCase();

/* ========== render helpers (return HTML strings) ========== */
function pageHead({ title, sub, actions }) {
  return `<div class="page-head"><h1>${esc(title)}</h1>${sub ? `<span class="sub">${esc(sub)}</span>` : ''}${actions ? `<div class="actions">${actions}</div>` : ''}</div>`;
}
const pill = (status, label) => `<span class="pill ${esc((status || '').toLowerCase())}">${esc(label ?? status ?? '')}</span>`;
const tag = t => `<span class="tag">${esc(t)}</span>`;
const card = (html, cls = '') => `<div class="card ${cls}">${html}</div>`;
const dl = pairs => `<dl class="dl">${pairs.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${v == null || v === '' ? '—' : v}</dd>`).join('')}</dl>`;
const statCards = items => `<div class="stat-grid">${items.map(i => `<div class="stat"><div class="n">${i.n}</div><div class="l">${esc(i.l)}</div></div>`).join('')}</div>`;
const emptyState = (title, hint) => `<div class="empty"><div class="ico">◍</div><div>${esc(title)}</div>${hint ? `<div class="stub" style="margin-top:6px">${hint}</div>` : ''}</div>`;
const btn = (label, { act, id, cls = 'btn-sm btn-ghost', title = '' } = {}) => `<button class="btn ${cls}"${act ? ` data-act="${esc(act)}"` : ''}${id != null ? ` data-id="${esc(id)}"` : ''}${title ? ` title="${esc(title)}"` : ''}>${label}</button>`;
function dataTable({ columns, rows, idKey = 'id', clickable = false, empty = 'Nothing here yet.' }) {
  if (!rows || !rows.length) return `<div class="tablewrap">${emptyState(empty)}</div>`;
  const head = columns.map(c => `<th class="${c.cls || ''}">${esc(c.label || '')}</th>`).join('');
  const body = rows.map(r => {
    const tds = columns.map(c => `<td class="${c.cls || ''}">${c.render ? c.render(r) : esc(r[c.key] ?? '')}</td>`).join('');
    return `<tr${clickable ? ' class="clickable"' : ''} data-id="${esc(r[idKey])}">${tds}</tr>`;
  }).join('');
  return `<div class="tablewrap"><div class="tablescroll"><table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div></div>`;
}
/* wire row clicks + [data-act] buttons after mounting */
function wire(container, { rowClick, acts } = {}) {
  if (rowClick) container.querySelectorAll('tr[data-id]').forEach(tr => tr.addEventListener('click', () => rowClick(tr.dataset.id)));
  if (acts) container.querySelectorAll('[data-act]').forEach(b => b.addEventListener('click', ev => { ev.stopPropagation(); const f = acts[b.dataset.act]; if (f) f(b.dataset.id, b); }));
}

/* ========== toast / modal / form ========== */
function toast(msg, kind = '') { let box = document.querySelector('.toasts'); if (!box) { box = document.createElement('div'); box.className = 'toasts'; document.body.appendChild(box); } const t = document.createElement('div'); t.className = 'toast ' + kind; t.textContent = msg; box.appendChild(t); setTimeout(() => t.remove(), 2800); }

function openModal({ title, sub, wide, bodyHtml, footHtml, onMount }) {
  const ov = document.createElement('div'); ov.className = 'modal-overlay';
  ov.innerHTML = `<div class="modal ${wide ? 'wide' : ''}" role="dialog">
    ${title ? `<div class="modal-head">${esc(title)}</div>` : ''}${sub ? `<div class="modal-sub">${esc(sub)}</div>` : ''}
    <div class="modal-body">${bodyHtml || ''}</div>
    <div class="modal-foot">${footHtml || ''}</div></div>`;
  const close = () => ov.remove();
  ov.addEventListener('mousedown', e => { if (e.target === ov) close(); });
  document.addEventListener('keydown', function esc2(e) { if (e.key === 'Escape') { close(); document.removeEventListener('keydown', esc2); } });
  document.body.appendChild(ov);
  if (onMount) onMount(ov.querySelector('.modal'), close);
  return { el: ov, close };
}
function confirmModal(msg, { danger = false, confirmLabel = 'Confirm' } = {}) {
  return new Promise(resolve => {
    const m = openModal({
      title: 'Please confirm', bodyHtml: `<div>${esc(msg)}</div>`,
      footHtml: `<button class="btn btn-ghost" data-x="c">Cancel</button><button class="btn ${danger ? 'btn-danger' : 'btn-primary'}" data-x="ok">${esc(confirmLabel)}</button>`,
      onMount(root, close) {
        root.querySelector('[data-x=c]').onclick = () => { close(); resolve(false); };
        root.querySelector('[data-x=ok]').onclick = () => { close(); resolve(true); };
      }
    });
  });
}
/* field: {name,label,type,value,options,required,hint,rows,placeholder}
   type: text|email|number|password|textarea|select|toggle|date|datetime|static|section */
function fieldHtml(f) {
  const id = 'f_' + f.name;
  if (f.type === 'section') return `<div class="section-title" style="margin:6px 0 0">${esc(f.label)}</div>`;
  if (f.type === 'static') return `<label class="fld">${esc(f.label)}<div style="padding:9px 0;color:var(--ink-2)">${f.value ?? '—'}</div></label>`;
  if (f.type === 'toggle') return `<label class="switch"><input type="checkbox" id="${id}" ${f.value ? 'checked' : ''}><span class="track"></span>${esc(f.label)}</label>`;
  let input;
  if (f.type === 'textarea') input = `<textarea id="${id}" rows="${f.rows || 4}" placeholder="${esc(f.placeholder || '')}">${esc(f.value ?? '')}</textarea>`;
  else if (f.type === 'select') input = `<select id="${id}">${(f.options || []).map(o => `<option value="${esc(o.value)}" ${String(o.value) === String(f.value ?? '') ? 'selected' : ''}>${esc(o.label)}</option>`).join('')}</select>`;
  else { const t = ({ datetime: 'datetime-local' }[f.type]) || f.type || 'text'; input = `<input id="${id}" type="${t}" value="${esc(f.value ?? '')}" placeholder="${esc(f.placeholder || '')}">`; }
  return `<label class="fld">${esc(f.label)}${f.hint ? ` <span class="hint">${esc(f.hint)}</span>` : ''}${input}</label>`;
}
function readField(root, f) {
  const e = root.querySelector('#f_' + f.name); if (!e) return undefined;
  if (f.type === 'toggle') return e.checked;
  if (f.type === 'number') return e.value === '' ? null : Number(e.value);
  return e.value;
}
function formModal({ title, sub, wide, fields, submitLabel = 'Save', onSubmit }) {
  const body = fields.filter(f => f.type !== 'section' || f.label).map(fieldHtml).join('');
  openModal({
    title, sub, wide, bodyHtml: body,
    footHtml: `<span class="modal-err" data-err></span><button class="btn btn-ghost" data-x="c">Cancel</button><button class="btn btn-primary" data-x="ok">${esc(submitLabel)}</button>`,
    onMount(root, close) {
      const err = root.querySelector('[data-err]'), ok = root.querySelector('[data-x=ok]');
      root.querySelector('[data-x=c]').onclick = close;
      ok.onclick = async () => {
        const values = {}; for (const f of fields) { if (f.type === 'section' || f.type === 'static') continue; values[f.name] = readField(root, f); }
        for (const f of fields) { if (f.required && (values[f.name] == null || values[f.name] === '')) { err.textContent = (f.label || f.name) + ' is required'; return; } }
        err.textContent = ''; ok.disabled = true;
        try { const e = await onSubmit(values); if (e) { err.textContent = e; ok.disabled = false; return; } close(); }
        catch (ex) { err.textContent = ex.message || 'Failed'; ok.disabled = false; }
      };
      const first = root.querySelector('input,textarea,select'); if (first) first.focus();
    }
  });
}

/* ========== information architecture (nav) ========== */
const NAV = [
  { group: 'Overview', items: [{ id: '', icon: svg('grid'), label: 'Dashboard' }] },
  { group: 'Academics', items: [
    { id: 'courses', icon: svg('book'), label: 'Courses' },
    { id: 'live', icon: svg('bcast'), label: 'Live Classes' },
    { id: 'assessments', icon: svg('check'), label: 'Assessments' },
    { id: 'certificates', icon: svg('award'), label: 'Certificates' },
  ] },
  { group: 'Learners', admin: true, items: [
    { id: 'students', icon: svg('users'), label: 'Students' },
    { id: 'enrollments', icon: svg('inbox'), label: 'Enrollments' },
    { id: 'batches', icon: svg('layers'), label: 'Batches' },
    { id: 'devices', icon: svg('device'), label: 'Devices' },
  ] },
  { group: 'Mentorship', items: [
    { id: 'mentor', icon: svg('chat'), label: 'Ask Mentor' },
  ] },
  { group: 'Engagement', admin: true, items: [
    { id: 'announcements', icon: svg('mega'), label: 'Announcements' },
    { id: 'communities', icon: svg('hash'), label: 'Communities' },
    { id: 'calendar', icon: svg('cal'), label: 'Calendar' },
  ] },
  { group: 'Media Library', admin: true, items: [
    { id: 'videos', icon: svg('play'), label: 'Video Store' },
    { id: 'processing', icon: svg('clock'), label: 'Processing Queue' },
  ] },
  { group: 'Team & Access', admin: true, items: [
    { id: 'staff', icon: svg('shield'), label: 'Staff' },
    { id: 'roles', icon: svg('key'), label: 'Roles & Permissions' },
    { id: 'groups', icon: svg('layers'), label: 'Groups' },
  ] },
  { group: 'Reports & Insights', items: [
    { id: 'reports', icon: svg('chart'), label: 'Reports' },
  ] },
  { group: 'Settings', items: [
    { id: 'profile', icon: svg('user'), label: 'Profile' },
    { id: 'theme', icon: svg('sun'), label: 'Toggle theme', action: 'theme' },
    { id: 'signout', icon: svg('logout'), label: 'Sign out', action: 'signout' },
  ] },
];
function svg(name) {
  const p = {
    grid: '<rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/>',
    book: '<path d="M4 4h11a2 2 0 0 1 2 2v14H6a2 2 0 0 1-2-2V4z"/><path d="M17 4h3v14"/>',
    bcast: '<circle cx="12" cy="12" r="3"/><path d="M5 12a7 7 0 0 1 2-5M19 12a7 7 0 0 0-2-5M3 12a9 9 0 0 1 3-7M21 12a9 9 0 0 0-3-7"/>',
    chat: '<path d="M4 5h16v11H9l-4 4V5z"/>',
    users: '<circle cx="9" cy="8" r="3"/><path d="M3 20c0-3 3-5 6-5s6 2 6 5"/><path d="M16 6a3 3 0 0 1 0 6M21 20c0-2-1-3.5-3-4.3"/>',
    inbox: '<path d="M4 13l2-8h12l2 8v6H4z"/><path d="M4 13h5l1 2h4l1-2h5"/>',
    shield: '<path d="M12 3l7 3v6c0 5-3 7-7 9-4-2-7-4-7-9V6z"/>',
    mega: '<path d="M4 10v4l10 5V5L4 10z"/><path d="M14 8a4 4 0 0 1 0 8"/>',
    hash: '<path d="M9 4L7 20M17 4l-2 16M4 9h16M3 15h16"/>',
    cal: '<rect x="3" y="5" width="18" height="16" rx="1"/><path d="M3 9h18M8 3v4M16 3v4"/>',
    play: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M10 9l5 3-5 3z"/>',
    chart: '<path d="M4 20V4M4 20h16M8 16v-5M12 16V8M16 16v-8"/>',
    check: '<path d="M4 12l5 5L20 6"/>',
    award: '<circle cx="12" cy="9" r="6"/><path d="M9 14l-2 7 5-3 5 3-2-7"/>',
    layers: '<path d="M12 3l9 5-9 5-9-5 9-5z"/><path d="M3 13l9 5 9-5"/>',
    device: '<rect x="7" y="3" width="10" height="18" rx="2"/><path d="M11 18h2"/>',
    clock: '<circle cx="12" cy="12" r="8"/><path d="M12 8v4l3 2"/>',
    key: '<circle cx="8" cy="12" r="3"/><path d="M11 12h9l-2 2 2 2M17 12v3"/>',
    user: '<circle cx="12" cy="8" r="3.5"/><path d="M5 20c0-3.5 3-6 7-6s7 2.5 7 6"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.4 1.4M17.6 17.6L19 19M19 5l-1.4 1.4M6.4 17.6L5 19"/>',
    logout: '<path d="M15 4h4v16h-4"/><path d="M10 8l-4 4 4 4M6 12h9"/>',
    search: '<circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/>',
    bell: '<path d="M6 9a6 6 0 0 1 12 0c0 5 2 6 2 6H4s2-1 2-6"/><path d="M10 20a2 2 0 0 0 4 0"/>',
  }[name] || '';
  return `<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${p}</svg>`;
}

/* ========== router ========== */
const VIEWS = {};
function registerView(id, fn) { VIEWS[id] = fn; }
function go(hash) { location.hash = hash; }
function setCrumbs(...parts) {
  document.getElementById('crumbs').innerHTML = parts.map((p, i) => {
    const last = i === parts.length - 1, o = typeof p === 'string' ? { label: p } : p;
    if (last) return esc(o.label);
    return `${o.href ? `<a class="dim" href="${esc(o.href)}">${esc(o.label)}</a>` : `<span class="dim">${esc(o.label)}</span>`}<span class="dim">›</span>`;
  }).join(' ');
}
let _navBadges = {};
function setBadge(id, n) { _navBadges[id] = n; renderSidebar(); }
async function route() {
  if (!token() || !isStaff()) return showLogin();
  const raw = location.hash.replace(/^#\/?/, '').split('?')[0];
  const parts = raw.split('/').filter(Boolean);
  const id = parts[0] || '';
  renderSidebar();
  document.querySelectorAll('.sidebar').forEach(s => s.classList.remove('open'));
  const content = document.getElementById('content');
  content.innerHTML = loadingPage();
  const view = VIEWS[id] || VIEWS[''] || (c => c.innerHTML = emptyState('Not built yet', 'This section is on the roadmap.'));
  try { await view(content, { params: parts.slice(1), setCrumbs }); }
  catch (e) { content.innerHTML = card(`<b>Couldn’t load.</b><div class="stub" style="margin-top:8px">${esc(e.message)}</div><button class="btn btn-sm" style="margin-top:12px" onclick="location.reload()">Retry</button>`); }
  content.parentElement.scrollTop = 0;
}
const loadingPage = () => `<div class="tablewrap"><div class="tablescroll"><table><tbody>${Array.from({ length: 6 }).map(() => `<tr class="loading-rows"><td><div class="skl" style="width:60%"></div></td><td><div class="skl" style="width:40%"></div></td><td><div class="skl" style="width:30%"></div></td></tr>`).join('')}</tbody></table></div></div>`;

/* ========== shell ========== */
function renderSidebar() {
  const cur = (location.hash.replace(/^#\/?/, '').split(/[?/]/)[0]) || '';
  let html = `<div class="side-brand"><span class="dot"></span>ONROL</div><div class="side-scroll">`;
  for (const g of NAV) {
    if (g.admin && !isAdmin()) continue;
    const items = g.items.filter(it => !(it.admin && !isAdmin()));
    if (!items.length) continue;
    html += `<div class="side-group">${esc(g.group)}</div>`;
    for (const it of items) {
      if (it.action) { html += `<a class="side-link" data-action="${it.action}"><span class="ic">${it.icon}</span>${esc(it.label)}</a>`; continue; }
      const b = _navBadges[it.id];
      html += `<a class="side-link${it.id === cur ? ' active' : ''}" href="#/${it.id}"><span class="ic">${it.icon}</span>${esc(it.label)}${b ? `<span class="badge">${b}</span>` : ''}</a>`;
    }
  }
  html += `</div>`;
  const sb = document.getElementById('sidebar'); sb.innerHTML = html;
  sb.querySelectorAll('[data-action=theme]').forEach(e => e.onclick = e2 => { e2.preventDefault(); toggleTheme(); });
  sb.querySelectorAll('[data-action=signout]').forEach(e => e.onclick = e2 => { e2.preventDefault(); logout(); });
}
function toggleTheme() {
  const cur = document.documentElement.getAttribute('data-theme');
  const next = cur === 'dark' ? 'light' : (cur === 'light' ? 'dark' : (matchMedia('(prefers-color-scheme:dark)').matches ? 'light' : 'dark'));
  document.documentElement.setAttribute('data-theme', next); localStorage.setItem(K.thm, next);
}

/* ========== auth flow ========== */
async function login(identifier, password) {
  const res = await fetch(API + '/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Device-UUID': deviceId() }, body: JSON.stringify({ email: identifier, password, portal: 'any', platform: 'web', model: 'Staff Console' }) });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || (res.status === 409 ? 'Device limit reached — free a device slot for this account.' : 'Sign-in failed'));
  if (!['manager', 'superadmin', 'instructor'].includes(data.user?.role)) throw new Error('This console is for staff (admin & instructor) only.');
  localStorage.setItem(K.tok, data.access_token); localStorage.setItem(K.usr, JSON.stringify(data.user)); USER = data.user;
}
function logout() { localStorage.removeItem(K.tok); localStorage.removeItem(K.usr); USER = null; showLogin(); }
function showLogin() { document.getElementById('app').hidden = true; document.getElementById('login').hidden = false; }
function showApp() {
  document.getElementById('login').hidden = true; document.getElementById('app').hidden = false;
  const chip = document.getElementById('userChip');
  chip.innerHTML = `<button class="userbtn" id="userBtn"><div class="avatar">${esc(initials(USER.full_name))}</div><div class="who"><div class="nm">${esc(USER.full_name || '')}</div><div class="role">${esc(USER.role || '')}</div></div><span class="caret">▾</span></button>
    <div class="menu" id="userMenu" hidden>
      <a href="#/profile" data-close><span class="ic">${svg('user')}</span>Profile</a>
      <a data-action="theme"><span class="ic">${svg('sun')}</span>Toggle theme</a>
      <a data-action="signout"><span class="ic">${svg('logout')}</span>Sign out</a>
    </div>`;
  const menu = chip.querySelector('#userMenu');
  chip.querySelector('#userBtn').onclick = e => { e.stopPropagation(); menu.hidden = !menu.hidden; };
  document.addEventListener('click', () => { menu.hidden = true; });
  menu.querySelector('[data-action=theme]').onclick = e => { e.preventDefault(); toggleTheme(); menu.hidden = true; };
  menu.querySelector('[data-action=signout]').onclick = e => { e.preventDefault(); logout(); };
  menu.querySelectorAll('[data-close]').forEach(a => a.addEventListener('click', () => menu.hidden = true));
  document.getElementById('menuBtn').onclick = () => document.getElementById('sidebar').classList.toggle('open');
  document.getElementById('globalSearch').onkeydown = e => { if (e.key === 'Enter' && e.target.value.trim()) go('#/search?q=' + encodeURIComponent(e.target.value.trim())); };
  if (!location.hash) location.hash = '#/';
  route();
  refreshAlerts();
}

/* Topbar alert badges + sidebar badges — the "needs attention" pulse. */
async function refreshAlerts() {
  try {
    const [reqs, mentor, vids] = await Promise.allSettled([
      isAdmin() ? api('/manage/enrollment-requests') : Promise.resolve({}),
      api('/manage/mentor-questions').catch(() => ({})),
      isAdmin() ? api('/manage/videos') : Promise.resolve({}),
    ]);
    const nReq = reqs.status === 'fulfilled' ? arr(reqs.value, 'requests').length : 0;
    const nMentor = mentor.status === 'fulfilled' ? (mentor.value.waiting ?? arr(mentor.value, 'questions').length) : 0;
    const nProc = vids.status === 'fulfilled' ? arr(vids.value, 'videos').filter(v => v.status === 'processing').length : 0;
    setBadge('mentor', nMentor || 0);
    if (isAdmin()) { setBadge('enrollments', nReq || 0); setBadge('processing', nProc || 0); }
    const el = document.getElementById('alerts'); if (!el) return;
    const chip = (n, label, href, kind) => n ? `<a class="alert ${kind}" href="${href}" title="${esc(label)}">${svg('bell')}<b>${n}</b></a>` : '';
    el.innerHTML = [
      chip(nMentor, nMentor + ' mentor question(s) waiting', '#/mentor', 'warn'),
      isAdmin() ? chip(nReq, nReq + ' enrollment request(s)', '#/enrollments', 'info') : '',
      isAdmin() ? chip(nProc, nProc + ' video(s) processing', '#/processing', 'info') : '',
    ].join('');
  } catch (_) {}
}

/* ========== reference view: Dashboard ========== */
registerView('', async (content, { setCrumbs }) => {
  setCrumbs('Dashboard');
  const [reqs, mentor, vids, courses] = await Promise.allSettled([
    isAdmin() ? api('/manage/enrollment-requests') : Promise.resolve({}),
    api('/manage/mentor-questions'), isAdmin() ? api('/manage/videos') : Promise.resolve({}), api('/manage/courses'),
  ]);
  const nReq = reqs.status === 'fulfilled' ? arr(reqs.value, 'requests').length : 0;
  const nMentor = mentor.status === 'fulfilled' ? (mentor.value.waiting ?? arr(mentor.value, 'questions').length) : 0;
  const nProc = vids.status === 'fulfilled' ? arr(vids.value, 'videos').filter(v => v.status === 'processing').length : 0;
  const nCourses = courses.status === 'fulfilled' ? arr(courses.value, 'courses').length : 0;
  setBadge('mentor', nMentor || 0); if (isAdmin()) setBadge('enrollments', nReq || 0);
  content.innerHTML =
    pageHead({ title: `Welcome, ${USER.full_name?.split(' ')[0] || 'there'}`, sub: new Date().toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' }) }) +
    statCards([{ n: nCourses, l: 'Active courses' }, { n: nMentor, l: 'Questions waiting' }, ...(isAdmin() ? [{ n: nReq, l: 'Enrollment requests' }, { n: nProc, l: 'Videos processing' }] : [])]) +
    `<div class="section-title">Needs attention</div>
     <div class="attn">
       ${isAdmin() ? `<a href="#/enrollments"><div class="big">${nReq}</div><div class="lab">Enrollment requests to review</div></a>` : ''}
       <a href="#/mentor"><div class="big">${nMentor}</div><div class="lab">Mentor questions waiting</div></a>
       ${isAdmin() ? `<a href="#/videos"><div class="big">${nProc}</div><div class="lab">Videos still processing</div></a>` : ''}
     </div>
     <div class="section-title" style="margin-top:24px">Quick actions</div>
     <div class="toolbar" style="flex-wrap:wrap">
       <a class="btn btn-primary" href="#/courses">${svg('book')} Courses</a>
       <a class="btn" href="#/live">${svg('bcast')} Live classes</a>
       <a class="btn" href="#/assessments">${svg('check')} Assessments</a>
       ${isAdmin() ? `<a class="btn" href="#/students">${svg('users')} Students</a>` : ''}
       ${isAdmin() ? `<a class="btn" href="#/announcements">${svg('mega')} Announce</a>` : ''}
       ${isAdmin() ? `<a class="btn" href="#/videos">${svg('play')} Upload video</a>` : ''}
       <a class="btn" href="#/reports">${svg('chart')} Reports</a>
     </div>`;
});

/* profile */
registerView('profile', async (content, { setCrumbs }) => {
  setCrumbs('Profile');
  content.innerHTML = pageHead({ title: 'Profile' }) + card(dl([['Name', esc(USER.full_name)], ['Email', esc(USER.email) || '—'], ['Role', esc(USER.role)]]));
});

/* ========== boot (runs on DOMContentLoaded, after every view-*.js has registered) ========== */
function boot() {
  const t = localStorage.getItem(K.thm); if (t) document.documentElement.setAttribute('data-theme', t);
  const form = document.getElementById('loginForm');
  form.addEventListener('submit', async e => {
    e.preventDefault(); const b = document.getElementById('loginBtn'); b.disabled = true; document.getElementById('loginErr').textContent = '';
    try { await login(document.getElementById('loginId').value.trim(), document.getElementById('loginPw').value); showApp(); }
    catch (err) { document.getElementById('loginErr').textContent = err.message; } finally { b.disabled = false; }
  });
  window.addEventListener('hashchange', route);
  if (token() && isStaff()) showApp(); else showLogin();
}
document.readyState === 'loading' ? document.addEventListener('DOMContentLoaded', boot) : boot();

/* expose contract to view-*.js */
Object.assign(window, { API, api, arr, esc, fmtDate, fmtDateTime, fmtDur, timeAgo, initials, USER, isAdmin, isStaff, pageHead, pill, tag, card, dl, statCards, emptyState, btn, dataTable, wire, toast, openModal, confirmModal, formModal, registerView, go, setBadge, setCrumbs, loadingPage });
Object.defineProperty(window, 'USER', { get: () => USER });
