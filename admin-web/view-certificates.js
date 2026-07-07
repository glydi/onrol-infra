/* Certificates — hub + verification (course-scoped). list(course picker) → detail.
 * Mirrors view-courses.js. Uses ONLY the window-exposed core helpers. */
'use strict';

registerView('certificates', async (content, ctx) => {
  if (ctx.params[0]) return certCourseView(content, ctx, ctx.params[0]);
  ctx.setCrumbs('Certificates');
  const courses = arr(await api('/manage/courses'), 'courses');
  content.innerHTML = pageHead({
    title: 'Certificates', sub: 'Pick a course to manage its certificates',
  }) + dataTable({
    clickable: true, empty: 'No courses yet.',
    columns: [
      { label: 'Title', render: c => `<b>${esc(c.title || 'Untitled')}</b>` },
      { label: 'Course ID', render: c => `<span class="muted">${esc(c.label || c.id)}</span>` },
      { label: 'Status', render: c => pill(c.status || 'draft') },
      { label: 'Enrollment', render: c => esc(c.enroll_type || '—') },
    ], rows: courses,
  });
  wire(content, { rowClick: id => go('#/certificates/' + id) });
});

/* Public verification URL for a serial — same-origin, mounted on the api group
 * (GET /api/v1/certificates/:serial → CertificatePage). It doubles as a
 * printable certificate + shareable verify link. */
function certVerifyUrl(serial) { return location.origin + API + '/certificates/' + encodeURIComponent(serial); }
const certReload = id => certCourseView(document.getElementById('content'), { setCrumbs }, id);

async function certCourseView(content, ctx, id) {
  const [co, holdersRes, studentsRes] = await Promise.all([
    api('/manage/courses/' + id),
    api('/manage/courses/' + id + '/certificates').catch(() => ({})),
    api('/manage/courses/' + id + '/students').catch(() => ({})),
  ]);
  const holders = arr(holdersRes, 'certificates');
  const byId = {}; arr(studentsRes, 'students').forEach(s => { byId[s.id] = s; });
  ctx.setCrumbs({ label: 'Certificates', href: '#/certificates' }, co.title || 'Course');
  content.innerHTML =
    pageHead({ title: co.title || 'Course', sub: co.label || id, actions: pill(co.status || 'draft') }) +
    statCards([{ n: holders.length, l: 'Certificates issued' }]) +
    `<div class="toolbar"><div class="grow"><span class="muted">${holders.length} issued for this course</span></div>${btn('Issue to whole course', { act: 'issueall', cls: 'btn-primary' })}</div>` +
    dataTable({
      empty: 'No certificates issued yet.',
      columns: [
        { label: 'Student', render: h => { const s = byId[h.user_id]; return `<b>${esc((s && (s.name || s.full_name)) || h.user_id)}</b>${s && s.email ? `<div class="sub">${esc(s.email)}</div>` : ''}`; } },
        { label: 'Serial', render: h => h.serial ? `<code>${esc(h.serial)}</code>` : '<span class="muted">—</span>' },
        { label: 'Issued', render: h => esc(fmtDate(h.issued_at || h.created_at)) },
        { label: '', cls: 'right', render: h =>
          (h.serial
            ? btn('Copy verify link', { act: 'copy', id: h.serial, cls: 'btn-sm', title: 'Copy the public verification URL' }) + ' ' +
              btn('Open', { act: 'open', id: h.serial, cls: 'btn-sm', title: 'Open the printable certificate / verify page' }) + ' '
            : '') +
          btn('Revoke', { act: 'revoke', id: h.user_id, cls: 'btn-sm btn-danger' }) },
      ], rows: holders,
    });
  wire(content, { acts: {
    issueall: async () => {
      if (!await confirmModal('Issue a certificate to every enrolled student? Already-certified students are skipped.', { confirmLabel: 'Issue' })) return;
      const r = await api('/manage/courses/' + id + '/certificates', { method: 'POST', body: { all: true } });
      toast((r && r.issued != null ? r.issued : 0) + ' certificate(s) issued', 'good'); certReload(id);
    },
    copy: async serial => {
      const url = certVerifyUrl(serial);
      try { await navigator.clipboard.writeText(url); toast('Verify link copied', 'good'); }
      catch (_) { toast(url); }
    },
    open: serial => window.open(certVerifyUrl(serial), '_blank', 'noopener'),
    revoke: async uid => {
      if (!await confirmModal('Revoke this certificate? The verify link will stop working.', { danger: true, confirmLabel: 'Revoke' })) return;
      await api('/manage/courses/' + id + '/certificates/' + uid, { method: 'DELETE' }); toast('Revoked'); certReload(id);
    },
  } });
}
