/* Enrollments — approval queue (requests) + converted leads (auto-provisioning). Admin-only. */
'use strict';

const ENROLL_TABS = [['requests', 'Requests'], ['leads', 'Converted leads']];

registerView('enrollments', async (content, ctx) => {
  const tab = ctx.params[0] === 'leads' ? 'leads' : 'requests';
  ctx.setCrumbs('Enrollments');
  content.innerHTML =
    pageHead({ title: 'Enrollments', sub: 'Approvals & auto-provisioned leads' }) +
    `<div class="tabs">${ENROLL_TABS.map(([k, l]) => `<div class="tab ${k === tab ? 'active' : ''}" data-t="${k}">${l}</div>`).join('')}</div><div id="tb"></div>`;
  content.querySelectorAll('.tab').forEach(t => t.onclick = () => go('#/enrollments/' + t.dataset.t));
  const tb = content.querySelector('#tb');
  (tab === 'leads' ? tabLeads : tabRequests)(tb);
});

/* ---- Requests: pending enrollment approvals ---- */
async function tabRequests(tb) {
  const reqs = arr(await api('/manage/enrollment-requests').catch(() => ({})), 'requests');
  setBadge('enrollments', reqs.length);
  tb.innerHTML = `<div class="toolbar"><div class="grow"><span class="muted">${reqs.length} pending</span></div></div>` +
    dataTable({ empty: 'No enrollment requests waiting.', columns: [
      { label: 'Student', render: r => `<b>${esc(r.student || r.name || 'Student')}</b>${r.email ? `<div class="sub">${esc(r.email)}</div>` : ''}${r.phone ? `<div class="sub">${esc(r.phone)}</div>` : ''}` },
      { label: 'Requested course', render: r => esc(r.course || r.course_title || r.course_id || '—') },
      { label: 'When', render: r => { const w = r.created_at || r.ts; return timeAgo(w) ? `<span title="${esc(fmtDateTime(w))}">${esc(timeAgo(w))}</span>` : esc(fmtDate(w)); } },
      { label: '', cls: 'right', render: r => btn('Approve', { act: 'approve', id: r.id, cls: 'btn-sm btn-primary' }) + ' ' + btn('Deny', { act: 'deny', id: r.id, cls: 'btn-sm btn-danger' }) },
    ], rows: reqs });
  wire(tb, { acts: {
    approve: async id => { if (await confirmModal('Approve this request and enroll the student?', { confirmLabel: 'Approve' })) { await api('/manage/enrollment-requests/' + id + '/approve', { method: 'POST' }); toast('Approved — student enrolled', 'good'); tabRequests(tb); } },
    deny: async id => { if (await confirmModal('Deny this enrollment request?', { danger: true, confirmLabel: 'Deny' })) { await api('/manage/enrollment-requests/' + id + '/reject', { method: 'POST' }); toast('Request denied'); tabRequests(tb); } },
  } });
}

/* ---- Converted leads: auto-provisioning records ---- */
async function tabLeads(tb) {
  const leads = arr(await api('/manage/converted-leads').catch(() => ({})), 'leads');
  tb.innerHTML = `<div class="toolbar"><div class="grow"><span class="muted">${leads.length} converted</span></div></div>` +
    dataTable({ clickable: true, idKey: 'lead_id', empty: 'No converted leads yet.', columns: [
      { label: 'Name', render: l => `<b>${esc(l.name || '—')}</b>` },
      { label: 'Contact', render: l => `${esc(l.email || l.phone || '—')}${l.email && l.phone ? `<div class="sub">${esc(l.phone)}</div>` : ''}` },
      { label: 'Course', render: l => esc(l.course_title || l.course_id || '—') },
      { label: 'Provisioned', render: l => l.provisioned ? pill('good', 'yes') : pill('warn', 'pending') },
      { label: 'Converted', render: l => esc(fmtDate(l.converted_at)) },
      { label: '', cls: 'right', render: l => btn('Delete', { act: 'del', id: l.lead_id, cls: 'btn-sm btn-danger' }) },
    ], rows: leads });
  wire(tb, {
    rowClick: id => leadDetail(id, tb),
    acts: { del: async id => { if (await confirmModal('Delete this converted-lead record? Any student account already created is kept.', { danger: true, confirmLabel: 'Delete' })) { await api('/manage/converted-leads/' + id, { method: 'DELETE' }); toast('Lead deleted'); tabLeads(tb); } } },
  });
}

async function leadDetail(id, tb) {
  const l = await api('/manage/converted-leads/' + id).catch(() => ({}));
  const pairs = [
    ['Name', esc(l.name)], ['Email', esc(l.email)], ['Phone', esc(l.phone)],
    ['Course', esc(l.course_title || l.course_id)], ['Source', esc(l.source)], ['Campaign', esc(l.campaign)],
    ['Owner', esc(l.owner)], ['Status', l.status ? pill(l.status) : ''], ['Score', l.score != null ? String(l.score) : ''],
    ['Provisioned', l.provisioned ? pill('good', 'yes') : pill('warn', 'no')],
    ['Temp password', l.temp_password ? `<code>${esc(l.temp_password)}</code>` : ''],
    ['Created', esc(fmtDateTime(l.created_at))], ['Converted', esc(fmtDateTime(l.converted_at))],
  ];
  const cf = l.record && typeof l.record === 'object' ? (l.record.custom_fields && typeof l.record.custom_fields === 'object' ? l.record.custom_fields : l.record) : null;
  const cfHtml = cf && Object.keys(cf).length
    ? `<div class="section-title" style="margin-top:16px">Custom fields</div>` + dl(Object.keys(cf).map(k => [k, esc(typeof cf[k] === 'object' ? JSON.stringify(cf[k]) : String(cf[k] ?? ''))]))
    : '';
  openModal({
    title: l.name || 'Converted lead', sub: l.email || l.phone || '', wide: true,
    bodyHtml: dl(pairs) + cfHtml,
    footHtml: `<span class="grow"></span><button class="btn btn-danger" data-x="del">Delete lead</button><button class="btn btn-ghost" data-x="close">Close</button>`,
    onMount(root, close) {
      root.querySelector('[data-x=close]').onclick = close;
      root.querySelector('[data-x=del]').onclick = async () => {
        if (await confirmModal('Delete this converted-lead record? Any student account already created is kept.', { danger: true, confirmLabel: 'Delete' })) {
          await api('/manage/converted-leads/' + id, { method: 'DELETE' }); toast('Lead deleted'); close(); tabLeads(tb);
        }
      };
    },
  });
}
