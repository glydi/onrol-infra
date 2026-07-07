/* Live HOST CONTROL panel — the web twin of the Flutter live_session_screen host
 * controls. Drives a simulated ("recorded-as-live") room: start/end, seek, switch
 * video, pause/blank/mute, chat/Q&A/reactions toggles, banner, slides + slideshow,
 * answer questions, and attendance. Everything runs off the host-only control API
 * (POST /me/live/:id/control — every field optional, send only what changes) and
 * the supporting reads. Registered as #/livehost/<sessionId> (ctx.params[0]).
 *
 * Endpoints wired (all confirmed in router.go):
 *   GET    /me/live/:id/state            authoritative status + toggles + host-only elapsed/duration/viewers
 *   POST   /me/live/:id/control          the one control endpoint (all the buttons below)
 *   GET    /me/live/:id/videos           ready recordings to switch_to
 *   GET/POST /me/live/:id/slides         image album (+ add data-uri slide)
 *   DELETE /me/live/:id/slides/:slideId  remove a slide
 *   GET    /me/live/:id/questions        Q&A queue (host sees all, unanswered first)
 *   POST   /me/live/:id/questions/:qid/answer   answer one ({body})
 *   GET    /me/live/:id/attendance       who watched + how long
 *
 * EFFICIENCY: one /state fetch on load, then a modest 4s poll to keep the status
 * pill / viewers / elapsed / toggle labels fresh. The timer is module-level and is
 * cleared at the very start of every render AND self-terminates the instant the
 * hash no longer targets this exact #/livehost/<id> — no runaway pollers.
 */
'use strict';

let lhTimer = null;   // module-level poll handle — cleared on every render + on navigate-away
let lhSession = null; // the sessionId this panel is bound to
let lhState = null;   // latest /state payload (host view: includes elapsed/duration/viewers)

/* ---------- status / formatting helpers ---------- */
function lhStatusPill(st) {
  const s = String((st && st.status) || '').toLowerCase();
  if (s === 'ended') return pill('ended', 'Ended');
  if (s === 'upcoming') return pill('upcoming', 'Upcoming');
  if (s === 'preparing') return pill('warn', 'Preparing');
  if (st && st.paused) return pill('warn', 'Paused');
  if (st && st.blank) return pill('disabled', 'Blank');
  return pill('live', 'Live');
}
function lhElapsedText(st) {
  if (!st || (st.elapsed == null && st.duration == null)) return '—';
  const e = st.elapsed != null ? fmtDur(st.elapsed) : '—';
  const d = st.duration ? fmtDur(st.duration) : '∞';
  return e + ' / ' + d;
}
/* "90" or "1:30" or "1:02:03" → seconds (null if unparseable). */
function lhParseSeconds(raw) {
  const s = String(raw || '').trim();
  if (!s) return null;
  if (s.indexOf(':') >= 0) {
    const parts = s.split(':').map(x => parseInt(x, 10));
    if (parts.some(n => isNaN(n) || n < 0)) return null;
    return parts.reduce((acc, n) => acc * 60 + n, 0);
  }
  const n = parseInt(s, 10);
  return isNaN(n) ? null : Math.max(0, n);
}

/* ---------- the one control POST + state refresh ---------- */
async function lhControl(id, body, okMsg) {
  try {
    await api('/me/live/' + id + '/control', { method: 'POST', body });
    if (okMsg) toast(okMsg, 'good');
    await lhRefreshState(id);
  } catch (e) {
    toast(e.message || 'Control failed');
  }
}
async function lhRefreshState(id) {
  try { lhState = await api('/me/live/' + id + '/state'); lhPaintState(); } catch (_) {}
}
/* Flip exactly one boolean toggle, sending only that field. */
async function lhToggle(id, field) {
  const cur = !!(lhState && lhState[field]);
  await lhControl(id, { [field]: !cur });
}

/* ---------- live repaint (poll target — patches, never re-renders) ---------- */
function lhPaintToggle(key, on, label) {
  const b = document.getElementById('lh-b-' + key);
  if (!b) return;
  b.textContent = label;
  b.classList.toggle('btn-primary', !!on);
}
function lhPaintState() {
  const st = lhState || {};
  const sp = document.getElementById('lh-statuspill'); if (sp) sp.innerHTML = lhStatusPill(st);
  const vw = document.getElementById('lh-viewers'); if (vw) vw.textContent = st.viewers ?? 0;
  const el = document.getElementById('lh-elapsed'); if (el) el.textContent = lhElapsedText(st);
  lhPaintToggle('paused', st.paused, st.paused ? 'Resume playback' : 'Pause playback');
  lhPaintToggle('blank', st.blank, 'Blank screen: ' + (st.blank ? 'On' : 'Off'));
  lhPaintToggle('muted', st.muted, 'Mute all: ' + (st.muted ? 'On' : 'Off'));
  lhPaintToggle('chat', st.chat_enabled, 'Chat: ' + (st.chat_enabled ? 'On' : 'Off'));
  lhPaintToggle('qa', st.qa_enabled, 'Q&A: ' + (st.qa_enabled ? 'On' : 'Off'));
  lhPaintToggle('reactions', st.reactions_enabled, 'Reactions: ' + (st.reactions_enabled ? 'On' : 'Off'));
  const ss = document.getElementById('lh-b-slideshow');
  if (ss) { ss.textContent = st.slideshow ? 'Stop slideshow' : 'Start slideshow'; ss.classList.toggle('btn-primary', !!st.slideshow); }
  // highlight the slide currently on screen (auto-slideshow advances this itself)
  const cur = st.current_slide_id || '';
  document.querySelectorAll('#lh-slides [data-slide]').forEach(node => {
    const on = node.dataset.slide === cur;
    node.style.outline = on ? '3px solid var(--accent)' : 'none';
    node.style.outlineOffset = '-1px';
  });
}

/* ---------- poll (self-terminates when we leave this exact route) ---------- */
function lhOnRoute(id) {
  const parts = location.hash.replace(/^#\/?/, '').split('?')[0].split('/').filter(Boolean);
  return parts[0] === 'livehost' && parts[1] === id;
}
function lhPoll(id) {
  if (!lhOnRoute(id)) { clearInterval(lhTimer); lhTimer = null; return; }
  api('/me/live/' + id + '/state')
    .then(st => { if (lhOnRoute(id)) { lhState = st; lhPaintState(); } })
    .catch(() => {});
}

/* ---------- view ---------- */
registerView('livehost', async (content, ctx) => {
  clearInterval(lhTimer); lhTimer = null;            // kill any prior timer up front
  const id = ctx.params[0];
  if (!id) { content.innerHTML = pageHead({ title: 'Host controls' }) + emptyState('No session', 'Open a live class first.'); return; }
  lhSession = id;
  ctx.setCrumbs({ label: 'Live Classes', href: '#/live' }, { label: 'Live', href: '#/live/' + id }, 'Host controls');

  // Single authoritative state fetch on load (403 = not the host → surface + stop).
  let st;
  try { st = await api('/me/live/' + id + '/state'); }
  catch (e) {
    toast(e.message || 'Cannot open host controls');
    content.innerHTML = pageHead({ title: 'Host controls' }) + emptyState('Cannot open host controls', esc(e.message || 'You may not host this session.'));
    return;
  }
  lhState = st;
  lhRender(content, id);

  // Modest poll to keep status/viewers/toggles fresh; only while on this route.
  lhTimer = setInterval(() => lhPoll(id), 4000);
});

function lhRender(content, id) {
  const st = lhState || {};
  const tbtn = (key, act) => `<button class="btn" id="lh-b-${key}" data-act="${act}"></button>`;
  const actions =
    `<span id="lh-statuspill">${lhStatusPill(st)}</span> ` +
    `<a class="btn btn-sm" href="#/live/${esc(id)}">Session details</a>`;

  content.innerHTML =
    pageHead({ title: st.title || 'Host controls', sub: st.course || '', actions }) +
    `<div class="stat-grid">
       <div class="stat"><div class="n" id="lh-viewers">${st.viewers ?? 0}</div><div class="l">Viewers now</div></div>
       <div class="stat"><div class="n" id="lh-elapsed">${lhElapsedText(st)}</div><div class="l">Elapsed / duration</div></div>
     </div>` +

    `<div class="section-title" style="margin-top:8px">Live controls</div>` +
    card(`<div class="toolbar" style="margin-bottom:0">
       ${btn('Start now', { act: 'startnow', cls: 'btn-primary' })}
       ${btn('End now', { act: 'endnow', cls: 'btn-danger' })}
       ${btn('Seek to…', { act: 'seek' })}
       ${btn('Switch video', { act: 'switchvideo' })}
     </div>`) +

    `<div class="section-title">Room toggles</div>` +
    card(`<div class="toolbar" style="margin-bottom:0">
       ${tbtn('paused', 'tg_paused')}
       ${tbtn('blank', 'tg_blank')}
       ${tbtn('muted', 'tg_muted')}
       ${tbtn('chat', 'tg_chat')}
       ${tbtn('qa', 'tg_qa')}
       ${tbtn('reactions', 'tg_reactions')}
     </div>`) +

    `<div class="section-title">Banner</div>` +
    card(`<div class="toolbar" style="margin-bottom:0">
       <input id="lh-banner-input" type="text" maxlength="300" placeholder="Message shown across every viewer's screen…" value="${esc(st.banner || '')}" style="flex:1;min-width:220px">
       ${btn('Set banner', { act: 'setbanner', cls: 'btn-primary' })}
       ${btn('Clear', { act: 'clearbanner' })}
     </div>`) +

    `<div class="section-title">Slides</div>` +
    card(`<div class="toolbar">
       ${btn('Add slide', { act: 'addslide', cls: 'btn-primary' })}
       <button class="btn" id="lh-b-slideshow" data-act="slideshow"></button>
       ${btn('Stop presenting', { act: 'stoppresent' })}
       <input type="file" id="lh-slide-file" accept="image/*" hidden>
     </div><div id="lh-slides">${loadingPage()}</div>`) +

    `<div class="section-title">Q&amp;A</div><div id="lh-qa">${loadingPage()}</div>` +
    `<div class="section-title">Attendance</div><div id="lh-attn">${loadingPage()}</div>`;

  // Top-level buttons (sub-sections wire their own acts once loaded).
  wire(content, {
    acts: {
      startnow: () => lhStartNow(id),
      endnow: () => lhEndNow(id),
      seek: () => lhSeek(id),
      switchvideo: () => lhSwitchVideo(id),
      tg_paused: () => lhToggle(id, 'paused'),
      tg_blank: () => lhToggle(id, 'blank'),
      tg_muted: () => lhToggle(id, 'muted'),
      tg_chat: () => lhToggle(id, 'chat_enabled'),
      tg_qa: () => lhToggle(id, 'qa_enabled'),
      tg_reactions: () => lhToggle(id, 'reactions_enabled'),
      setbanner: () => { const el = document.getElementById('lh-banner-input'); lhControl(id, { banner: (el && el.value) || '' }, 'Banner set'); },
      clearbanner: () => { const el = document.getElementById('lh-banner-input'); if (el) el.value = ''; lhControl(id, { banner: '' }, 'Banner cleared'); },
      addslide: () => { const f = document.getElementById('lh-slide-file'); if (f) f.click(); },
      slideshow: () => lhToggle(id, 'slideshow'),
      stoppresent: () => lhControl(id, { present_slide: '' }, 'Stopped presenting'),
    },
  });

  const fileInput = content.querySelector('#lh-slide-file');
  if (fileInput) fileInput.onchange = () => lhAddSlideFromFile(id, fileInput);

  lhPaintState();          // sync toggle labels / highlights from lhState
  lhLoadSlides(id);
  lhLoadQuestions(id);
  lhLoadAttendance(id);
}

/* ---------- primary actions ---------- */
async function lhStartNow(id) {
  if (!(await confirmModal('Go live right now? The clock starts and viewers join immediately.', { confirmLabel: 'Start now' }))) return;
  await lhControl(id, { start_now: true }, 'Live now');
}
async function lhEndNow(id) {
  // DOUBLE confirm — ending is immediate and irreversible for every viewer.
  if (!(await confirmModal('End this live class for everyone now?', { danger: true, confirmLabel: 'End class' }))) return;
  if (!(await confirmModal('Are you absolutely sure? Every viewer sees the ended screen at once — this cannot be undone.', { danger: true, confirmLabel: 'Yes, end now' }))) return;
  await lhControl(id, { end_now: true }, 'Class ended');
}
function lhSeek(id) {
  formModal({
    title: 'Seek to', sub: 'Jump the live position — every viewer re-syncs to the new spot.',
    fields: [{ name: 't', label: 'Seconds or mm:ss', required: true, placeholder: 'e.g. 90 or 1:30', value: (lhState && lhState.elapsed != null) ? String(lhState.elapsed) : '' }],
    submitLabel: 'Seek',
    async onSubmit(v) {
      const secs = lhParseSeconds(v.t);
      if (secs == null) return 'Enter seconds (90) or mm:ss (1:30)';
      await lhControl(id, { seek_to: secs }, 'Seeked to ' + fmtDur(secs));
    },
  });
}
async function lhSwitchVideo(id) {
  let vids;
  try { vids = arr(await api('/me/live/' + id + '/videos'), 'videos'); }
  catch (e) { toast(e.message || 'Cannot list recordings'); return; }
  if (!vids.length) { toast('No ready recordings to switch to'); return; }
  formModal({
    title: 'Switch video', sub: 'Play a different recording — restarts every viewer\'s player from its start.',
    fields: [{
      name: 'vid', label: 'Recording', type: 'select', required: true,
      options: [{ value: '', label: '— pick a recording —' }, ...vids.map(v => ({ value: v.id, label: (v.title || v.id) + ' · ' + fmtDur(v.duration_seconds || 0) }))],
    }],
    submitLabel: 'Switch',
    async onSubmit(v) {
      if (!v.vid) return 'Pick a recording';
      const ok = await confirmModal('Switch the class to this recording now? Every viewer\'s player restarts from the beginning.', { danger: true, confirmLabel: 'Switch now' });
      if (!ok) return 'Cancelled — pick again or close.';
      await lhControl(id, { switch_to: v.vid }, 'Video switched');
    },
  });
}

/* ---------- slides ---------- */
/* Downscale a picked image to a JPEG data URI (backend requires a data:image/ URI,
 * ≤ ~6 MB). Max edge 1600px keeps a slide well under the cap. */
function lhImageToDataUri(file) {
  return new Promise((resolve, reject) => {
    const fr = new FileReader();
    fr.onerror = () => reject(new Error('Could not read the file'));
    fr.onload = () => {
      const img = new Image();
      img.onerror = () => reject(new Error('That file is not an image'));
      img.onload = () => {
        const max = 1600, scale = Math.min(1, max / Math.max(img.width, img.height));
        const w = Math.max(1, Math.round(img.width * scale)), h = Math.max(1, Math.round(img.height * scale));
        const cv = document.createElement('canvas'); cv.width = w; cv.height = h;
        cv.getContext('2d').drawImage(img, 0, 0, w, h);
        resolve(cv.toDataURL('image/jpeg', 0.85));
      };
      img.src = fr.result;
    };
    fr.readAsDataURL(file);
  });
}
async function lhAddSlideFromFile(id, input) {
  const f = input.files && input.files[0];
  input.value = '';
  if (!f) return;
  toast('Adding slide…');
  try {
    const uri = await lhImageToDataUri(f);
    await api('/me/live/' + id + '/slides', { method: 'POST', body: { image: uri } });
    toast('Slide added', 'good');
    lhLoadSlides(id);
  } catch (e) { toast(e.message || 'Add slide failed'); }
}
async function lhLoadSlides(id) {
  const box = document.getElementById('lh-slides');
  if (!box) return;
  let data;
  try { data = await api('/me/live/' + id + '/slides'); }
  catch (e) { box.innerHTML = `<div class="muted">Slides unavailable. <span class="stub">${esc(e.message || '')}</span></div>`; return; }
  const slides = arr(data, 'slides');
  if (!slides.length) { box.innerHTML = emptyState('No slides yet', 'Add an image to present it over the video.'); return; }
  const cur = (lhState && lhState.current_slide_id) || '';
  box.innerHTML = `<div style="display:flex;flex-wrap:wrap;gap:12px">` + slides.map(sl => {
    const on = sl.id === cur;
    return `<div data-slide="${esc(sl.id)}" style="width:190px;border:1px solid var(--line);border-radius:8px;overflow:hidden;background:var(--panel);outline:${on ? '3px solid var(--accent)' : 'none'};outline-offset:-1px">
      <img src="${esc(sl.image)}" alt="slide" style="width:100%;height:107px;object-fit:cover;display:block;background:var(--panel-3)">
      <div class="toolbar" style="margin:0;padding:8px;gap:6px">
        ${btn(on ? 'Presenting' : 'Present', { act: 'present', id: sl.id, cls: on ? 'btn-sm btn-primary' : 'btn-sm' })}
        ${btn('Delete', { act: 'delslide', id: sl.id, cls: 'btn-sm btn-danger' })}
      </div>
    </div>`;
  }).join('') + `</div>`;
  wire(box, {
    acts: {
      present: sid => lhControl(id, { present_slide: sid }, 'Presenting slide'),
      delslide: async sid => {
        if (!(await confirmModal('Delete this slide?', { danger: true, confirmLabel: 'Delete' }))) return;
        try { await api('/me/live/' + id + '/slides/' + sid, { method: 'DELETE' }); toast('Slide deleted'); lhLoadSlides(id); }
        catch (e) { toast(e.message || 'Delete failed'); }
      },
    },
  });
}

/* ---------- Q&A ---------- */
async function lhLoadQuestions(id) {
  const box = document.getElementById('lh-qa');
  if (!box) return;
  let data;
  try { data = await api('/me/live/' + id + '/questions'); }
  catch (e) { box.innerHTML = card(`<div class="muted">Q&amp;A unavailable.</div><div class="stub" style="margin-top:6px">${esc(e.message || '')}</div>`); return; }
  const qs = arr(data, 'questions');
  const waiting = qs.filter(q => !q.answered).length;
  box.innerHTML =
    `<div class="toolbar" style="margin-bottom:8px"><div class="grow"><span class="muted">${qs.length} question(s) · ${waiting} waiting</span></div>${btn('Refresh', { act: 'refresh', cls: 'btn-sm' })}</div>` +
    dataTable({
      empty: 'No questions asked yet.',
      columns: [
        { label: 'From', render: q => `<b>${esc(q.name || 'Student')}</b><div class="sub">${esc(timeAgo(q.at))}</div>` },
        { label: 'Question', render: q => esc(q.body || '') + (q.answered && q.answer ? `<div class="sub" style="color:var(--good)">↳ ${esc(q.answer)}</div>` : '') },
        { label: '', cls: 'right', render: q => q.answered ? pill('answered', 'Answered') : btn('Answer', { act: 'answer', id: q.id, cls: 'btn-sm btn-primary' }) },
      ], rows: qs,
    });
  wire(box, {
    acts: {
      refresh: () => lhLoadQuestions(id),
      answer: qid => {
        const q = qs.find(x => x.id === qid) || {};
        formModal({
          title: 'Answer question', sub: q.body || '',
          fields: [{ name: 'body', label: 'Your answer', type: 'textarea', required: true, rows: 4, placeholder: 'The student sees this reply.' }],
          submitLabel: 'Send answer',
          async onSubmit(v) {
            await api('/me/live/' + id + '/questions/' + qid + '/answer', { method: 'POST', body: { body: v.body } });
            toast('Answer sent', 'good');
            lhLoadQuestions(id);
          },
        });
      },
    },
  });
}

/* ---------- attendance (reuses the global exportCsv from view-reports.js) ---------- */
async function lhLoadAttendance(id) {
  const box = document.getElementById('lh-attn');
  if (!box) return;
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
        ((lhState && lhState.title) || 'attendance').replace(/[^\w.-]+/g, '_').slice(0, 60) + '_attendance.csv',
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
