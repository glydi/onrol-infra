/* Communities — forum servers (global/course/batch) + their channels. list → detail. */
'use strict';

registerView('communities', async (content, ctx) => {
  if (ctx.params[0]) return serverDetail(content, ctx, ctx.params[0]);
  ctx.setCrumbs('Communities');
  const servers = arr(await api('/manage/community/servers'), 'servers');
  content.innerHTML = pageHead({
    title: 'Communities', sub: `${servers.length} server${servers.length === 1 ? '' : 's'}`,
    actions: isAdmin() ? btn('+ New server', { act: 'new', cls: 'btn-primary' }) : '',
  }) + dataTable({
    clickable: true, empty: 'No community servers yet.',
    columns: [
      { label: 'Name', render: s => `<b>${s.icon ? esc(s.icon) + ' ' : ''}${esc(s.name || 'Server')}</b>` },
      { label: 'Scope', render: s => tag(s.scope || 'global') },
      { label: 'Course', render: s => s.scope === 'global' ? '<span class="muted">—</span>' : esc(s.course || '—') + (s.batch_number ? ' · Batch ' + esc(s.batch_number) : '') },
      { label: 'Channels', render: s => `${arr(s, 'channels').length}` },
    ], rows: servers,
  });
  wire(content, {
    rowClick: id => go('#/communities/' + id),
    acts: { new: () => newServer() },
  });
});

async function newServer() {
  const courses = await api('/manage/courses').then(d => arr(d, 'courses')).catch(() => []);
  formModal({
    title: 'New community server', sub: 'A server groups channels for a scope of members. A #general channel is seeded.',
    fields: [
      { name: 'name', label: 'Name', required: true, placeholder: 'e.g. General Community' },
      { name: 'icon', label: 'Icon', hint: 'optional emoji', placeholder: '💬' },
      { name: 'scope', label: 'Scope', type: 'select', value: 'global', options: [
        { value: 'global', label: 'Global (everyone)' },
        { value: 'course', label: 'Course (enrolled students)' },
        { value: 'batch', label: 'Batch (course + batch)' },
      ] },
      { name: 'course_id', label: 'Course', type: 'select', hint: 'required for course / batch scope', options: [{ value: '', label: '— none —' }, ...courses.map(c => ({ value: c.id, label: c.title || c.label || c.id }))] },
      { name: 'batch_number', label: 'Batch number', hint: 'required for batch scope', placeholder: 'e.g. 3' },
    ], submitLabel: 'Create server',
    async onSubmit(v) {
      if ((v.scope === 'course' || v.scope === 'batch') && !v.course_id) return 'Pick a course for this scope.';
      if (v.scope === 'batch' && !String(v.batch_number || '').trim()) return 'Batch number is required for batch scope.';
      const body = { name: v.name, scope: v.scope, icon: v.icon };
      if (v.scope === 'course' || v.scope === 'batch') body.course_id = v.course_id;
      if (v.scope === 'batch') body.batch_number = String(v.batch_number).trim();
      const r = await api('/manage/community/servers', { method: 'POST', body });
      toast('Server created', 'good');
      go('#/communities/' + (r.id || ''));
    },
  });
}

async function serverDetail(content, ctx, id) {
  const s = arr(await api('/manage/community/servers'), 'servers').find(x => String(x.id) === String(id));
  ctx.setCrumbs({ label: 'Communities', href: '#/communities' }, s ? (s.name || 'Server') : 'Server');
  if (!s) { content.innerHTML = pageHead({ title: 'Server' }) + emptyState('Server not found', 'It may have been deleted.'); return; }
  const channels = arr(s, 'channels');
  content.innerHTML =
    pageHead({ title: `${s.icon ? esc(s.icon) + ' ' : ''}${esc(s.name || 'Server')}`, sub: `${channels.length} channel${channels.length === 1 ? '' : 's'}`, actions: tag(s.scope || 'global') }) +
    card(dl([
      ['Scope', tag(s.scope || 'global')],
      ['Course', s.scope === 'global' ? '—' : esc(s.course || '—')],
      ...(s.scope === 'batch' ? [['Batch', esc(s.batch_number || '—')]] : []),
    ])) +
    `<div class="toolbar" style="margin-top:16px"><div class="grow"><span class="muted">${channels.length} channel(s)</span></div>${isAdmin() ? btn('+ Add channel', { act: 'addch', cls: 'btn-primary' }) : ''}</div>` +
    dataTable({ empty: 'No channels yet.', columns: [
      { label: 'Channel', render: c => `<b>#${esc(c.name || 'channel')}</b>` },
      { label: '', cls: 'right', render: c => isAdmin() ? btn('Delete', { act: 'delch', id: c.id, cls: 'btn-sm btn-danger' }) : '' },
    ], rows: channels }) +
    (isAdmin() ? `<div class="toolbar" style="margin-top:16px">${btn('Delete server', { act: 'delserver', cls: 'btn-danger' })}</div>` : '');
  wire(content, { acts: {
    addch: () => formModal({ title: 'Add channel', sub: 'Names are lowercased and dashed.', fields: [{ name: 'name', label: 'Channel name', required: true, placeholder: 'e.g. announcements' }], async onSubmit(v) { await api('/manage/community/servers/' + id + '/channels', { method: 'POST', body: { name: v.name } }); toast('Channel added', 'good'); reloadServer(id); } }),
    delch: async cid => { if (await confirmModal('Delete this channel and its messages?', { danger: true, confirmLabel: 'Delete' })) { await api('/manage/community/channels/' + cid, { method: 'DELETE' }); toast('Channel deleted'); reloadServer(id); } },
    delserver: async () => { if (await confirmModal('Delete “' + (s.name || 'this server') + '” and all its channels + messages?', { danger: true, confirmLabel: 'Delete server' })) { await api('/manage/community/servers/' + id, { method: 'DELETE' }); toast('Server deleted'); go('#/communities'); } },
  } });
}
const reloadServer = id => serverDetail(document.getElementById('content'), { setCrumbs }, id);
