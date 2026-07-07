/* Reports — per-course Completion / Grades / Attendance. Instructors see their
 * own courses (endpoints are gated by canManageCourse); admins see all.
 * Route: #/reports/<courseId>/<tab>   ctx.params[0]=courseId, [1]=tab. */
'use strict';

const REPORT_TABS = [['completion', 'Completion'], ['grades', 'Grades'], ['attendance', 'Attendance'], ['risk', 'Progress & Risk']];

registerView('reports', async (content, ctx) => {
  const courses = arr(await api('/manage/courses'), 'courses');
  const courseId = ctx.params[0] || '';
  const tab = REPORT_TABS.some(([k]) => k === ctx.params[1]) ? ctx.params[1] : 'completion';
  const co = courses.find(c => String(c.id) === String(courseId));
  ctx.setCrumbs(courseId ? { label: 'Reports', href: '#/reports' } : 'Reports', ...(courseId ? [co ? (co.title || co.label || courseId) : 'Course'] : []));

  const picker = `<label class="fld" style="max-width:440px;margin:0">Course
    <select id="rpt-course">
      <option value="">— Select a course —</option>
      ${courses.map(c => `<option value="${esc(c.id)}" ${String(c.id) === String(courseId) ? 'selected' : ''}>${esc(c.title || c.label || c.id)}</option>`).join('')}
    </select></label>`;

  content.innerHTML =
    pageHead({ title: 'Reports', sub: 'Completion, grades & attendance — per course' }) +
    card(picker) +
    `<div id="rpt-body" style="margin-top:18px"></div>`;

  content.querySelector('#rpt-course').onchange = e => { const v = e.target.value; go(v ? `#/reports/${v}/${tab}` : '#/reports'); };

  const body = content.querySelector('#rpt-body');
  if (!courseId) { body.innerHTML = emptyState('Pick a course', 'Choose a course above to see its completion, grades and attendance reports.'); return; }

  body.innerHTML =
    `<div class="tabs">${REPORT_TABS.map(([k, l]) => `<div class="tab ${k === tab ? 'active' : ''}" data-t="${k}">${l}</div>`).join('')}</div>` +
    `<div id="rpt-tab"></div>`;
  body.querySelectorAll('.tab').forEach(t => t.onclick = () => go(`#/reports/${courseId}/${t.dataset.t}`));

  const tb = body.querySelector('#rpt-tab');
  tb.innerHTML = loadingPage();
  const slug = (co && (co.label || co.title) ? String(co.label || co.title) : courseId).replace(/[^\w.-]+/g, '-');
  try {
    await ({ completion: rptCompletion, grades: rptGrades, attendance: rptAttendance, risk: rptRisk }[tab])(tb, courseId, slug);
  } catch (e) {
    tb.innerHTML = card(`<b>Couldn’t load this report.</b><div class="stub" style="margin-top:8px">${esc(e.message)}</div>`);
  }
});

/* ---- generic report table + client-side CSV export ---- */
const rptNum = v => (v == null || v === '' ? '—' : v);
function csvCell(v) { const s = v == null ? '' : String(v); return /[",\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; }
function exportCsv(filename, columns, rows) {
  const lines = [columns.map(c => c.label)].concat(rows.map(r => columns.map(c => c.val(r))));
  const csv = lines.map(row => row.map(csvCell).join(',')).join('\r\n');
  const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = filename; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  toast('CSV exported', 'good');
}
/* columns: [{ label, val(r) -> csv value, render?(r) -> html, cls? }] */
function reportTable(tb, { filename, columns, rows, empty }) {
  const dtCols = columns.map(c => ({ label: c.label, cls: c.cls, render: c.render || (r => esc(rptNum(c.val(r)))) }));
  tb.innerHTML =
    `<div class="toolbar"><div class="grow"><span class="muted">${rows.length} row(s)</span></div>${rows.length ? btn('Export CSV', { act: 'csv', cls: 'btn-primary' }) : ''}</div>` +
    dataTable({ empty, columns: dtCols, rows });
  wire(tb, { acts: { csv: () => exportCsv(filename, columns, rows) } });
}

/* ---- Completion: per enrolled student ---- */
async function rptCompletion(tb, courseId, slug) {
  const rows = arr(await api('/manage/courses/' + courseId + '/report/completion'), 'completion');
  const lastKey = ['last_active', 'last_active_at', 'last_seen'].find(k => rows.some(r => r[k]));
  const columns = [
    { label: 'Student', val: r => r.student || r.full_name || r.user_id, render: r => `<b>${esc(r.student || r.full_name || 'Student')}</b>` },
    { label: '% Complete', cls: 'right', val: r => r.percent != null ? r.percent : (r.lessons_total ? Math.round(100 * (r.lessons_done || 0) / r.lessons_total) : 0), render: r => bar(r.percent != null ? r.percent : (r.lessons_total ? Math.round(100 * (r.lessons_done || 0) / r.lessons_total) : 0)) },
    { label: 'Lessons', cls: 'right', val: r => `${r.lessons_done ?? 0}/${r.lessons_total ?? 0}` },
    { label: 'Status', val: r => r.status || 'active', render: r => pill(r.status || 'active') },
  ];
  if (lastKey) columns.push({ label: 'Last active', val: r => r[lastKey] ? fmtDate(r[lastKey]) : '', render: r => esc(r[lastKey] ? fmtDate(r[lastKey]) : '—') });
  reportTable(tb, { filename: `completion-${slug}.csv`, columns, rows, empty: 'No students enrolled.' });
}
function bar(pct) {
  const p = Math.max(0, Math.min(100, +pct || 0));
  return `<div style="display:flex;align-items:center;gap:8px;justify-content:flex-end"><div style="flex:0 0 90px;height:6px;border-radius:99px;background:var(--line);overflow:hidden"><div style="height:100%;width:${p}%;background:var(--accent)"></div></div><span style="min-width:34px;text-align:right">${p}%</span></div>`;
}

/* ---- Grades: per assessment (avg / min / max / counts) ---- */
async function rptGrades(tb, courseId, slug) {
  const rows = arr(await api('/manage/courses/' + courseId + '/report/grades'), 'grades');
  const columns = [
    { label: 'Assessment', val: r => r.title || r.assessment_id, render: r => `<b>${esc(r.title || 'Assessment')}</b>` },
    { label: 'Submissions', cls: 'right', val: r => r.submissions ?? 0 },
    { label: 'Graded', cls: 'right', val: r => r.graded ?? 0 },
    { label: 'Average', cls: 'right', val: r => r.avg == null ? '' : r.avg, render: r => esc(rptNum(r.avg)) },
    { label: 'Min', cls: 'right', val: r => r.min == null ? '' : r.min, render: r => esc(rptNum(r.min)) },
    { label: 'Max', cls: 'right', val: r => r.max == null ? '' : r.max, render: r => esc(rptNum(r.max)) },
  ];
  reportTable(tb, { filename: `grades-${slug}.csv`, columns, rows, empty: 'No assessments in this course.' });
}

/* ---- Attendance: per session (present / absent / excused) ---- */
async function rptAttendance(tb, courseId, slug) {
  const rows = arr(await api('/manage/courses/' + courseId + '/report/attendance'), 'attendance');
  const tot = r => (r.present || 0) + (r.absent || 0) + (r.excused || 0);
  const columns = [
    { label: 'Session', val: r => r.title || r.session_id, render: r => `<b>${esc(r.title || 'Session')}</b>` },
    { label: 'Starts', val: r => r.starts_at ? fmtDateTime(r.starts_at) : '', render: r => esc(r.starts_at ? fmtDateTime(r.starts_at) : '—') },
    { label: 'Present', cls: 'right', val: r => r.present ?? 0 },
    { label: 'Absent', cls: 'right', val: r => r.absent ?? 0 },
    { label: 'Excused', cls: 'right', val: r => r.excused ?? 0 },
    { label: 'Marked', cls: 'right', val: r => tot(r) },
  ];
  reportTable(tb, { filename: `attendance-${slug}.csv`, columns, rows, empty: 'No live sessions for this course.' });
}

/* ---- Progress & Risk: learner cohorts derived CLIENT-SIDE from the completion
 * report (reuses /report/completion — no new endpoint). Stat cards per cohort;
 * click a card to filter the table + export that cohort's CSV. ---- */
const rptPct = r => r.percent != null ? r.percent : (r.lessons_total ? Math.round(100 * (r.lessons_done || 0) / r.lessons_total) : 0);
const RISK_INACTIVE_DAYS = 3;
const RISK_COHORTS = [
  { key: 'never', label: 'Never started', test: r => rptPct(r) === 0 || (r.lessons_done || 0) === 0 },
  { key: 'below50', label: 'Below 50%', test: r => { const p = rptPct(r); return p > 0 && p < 50; } },
  { key: 'ontrack', label: 'On track (50–99%)', test: r => { const p = rptPct(r); return p >= 50 && p < 100; } },
  { key: 'eligible', label: 'Certificate-eligible', note: 'by progress; final-project/attendance rules may also apply', test: r => rptPct(r) >= 80 || /complete|passed|finished|done/i.test(r.status || '') },
];

async function rptRisk(tb, courseId, slug) {
  const rows = arr(await api('/manage/courses/' + courseId + '/report/completion'), 'completion');
  const lastKey = ['last_active', 'last_active_at', 'last_seen'].find(k => rows.some(r => r[k]));
  const cohorts = RISK_COHORTS.slice();
  if (lastKey) {
    const cutoff = Date.now() - RISK_INACTIVE_DAYS * 86400000;
    cohorts.push({ key: 'inactive', label: `Inactive ${RISK_INACTIVE_DAYS}+ days`, test: r => r[lastKey] && new Date(r[lastKey]).getTime() < cutoff });
  }
  const columns = [
    { label: 'Student', val: r => r.student || r.full_name || r.user_id, render: r => `<b>${esc(r.student || r.full_name || 'Student')}</b>` },
    { label: '% Complete', cls: 'right', val: r => rptPct(r), render: r => bar(rptPct(r)) },
    { label: 'Lessons', cls: 'right', val: r => `${r.lessons_done ?? 0}/${r.lessons_total ?? 0}` },
    { label: 'Status', val: r => r.status || 'active', render: r => pill(r.status || 'active') },
  ];
  if (lastKey) columns.push({ label: 'Last active', val: r => r[lastKey] ? fmtDate(r[lastKey]) : '', render: r => esc(r[lastKey] ? fmtDate(r[lastKey]) : '—') });
  const groups = {}; for (const co of cohorts) groups[co.key] = rows.filter(co.test);
  riskRender(tb, { cohorts, groups, columns, slug, lastKey, total: rows.length, sel: cohorts[0].key });
}

function riskRender(tb, s) {
  const { cohorts, groups, columns, slug, lastKey, total, sel } = s;
  const stub = lastKey ? '' : `<p class="stub" style="margin:0 0 14px">Inactivity & watch-time cohorts need server-side activity tracking — the completion report exposes no last-active field.</p>`;
  const cards = `<div class="stat-grid">${cohorts.map(co => {
    const active = co.key === sel, n = groups[co.key].length;
    return `<button class="stat" data-cohort="${esc(co.key)}" style="cursor:pointer;text-align:left;border:1px solid ${active ? 'var(--accent)' : 'var(--line)'}">
      <div class="n">${n}</div><div class="l">${esc(co.label)}${total ? ` · ${Math.round(100 * n / total)}%` : ''}</div>${co.note ? `<div class="stub" style="margin-top:4px">${esc(co.note)}</div>` : ''}</button>`;
  }).join('')}</div>`;
  const co = cohorts.find(c => c.key === sel);
  tb.innerHTML = stub + cards +
    `<div class="section-title" style="margin-top:18px">${esc(co.label)}</div>${co.note ? `<div class="stub" style="margin:-2px 0 8px">${esc(co.note)}</div>` : ''}` +
    `<div id="risk-cohort-table"></div>`;
  tb.querySelectorAll('[data-cohort]').forEach(b => b.onclick = () => riskRender(tb, { ...s, sel: b.dataset.cohort }));
  reportTable(tb.querySelector('#risk-cohort-table'), { filename: `risk-${sel}-${slug}.csv`, columns, rows: groups[sel], empty: 'No students in this cohort.' });
}
