/* Processing Queue — the operational view of transcodes in flight. Reads the same
 * /manage/videos list as the Video Store but shows ONLY the not-ready assets
 * (processing / failed / queued) so staff can watch encodes finish and kick off a
 * Re-transcode on anything that stalled or failed. Admin-only. Top-level names are
 * prefixed `proc` to avoid colliding with view-videos.js. Uses only window helpers. */
'use strict';

/* statuses ListVideos can emit for a not-ready asset (ready is the finished state).
 * media_transcode.go flips rows to 'failed' on error and 'ready' on success; uploads
 * start at 'processing'. 'queued' is kept defensively in case the pipeline adds it. */
const PROC_INFLIGHT = ['processing', 'failed', 'queued'];

/* bytes → human ("—" when unknown/0). Local copy so we don't depend on view-videos. */
function procBytes(n) {
  n = +n || 0; if (!n) return '—';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.min(u.length - 1, Math.floor(Math.log(n) / Math.log(1024)));
  const v = n / Math.pow(1024, i);
  return (i === 0 ? v : v.toFixed(v >= 100 ? 0 : 1)) + ' ' + u[i];
}

async function procView(content, ctx) {
  ctx.setCrumbs('Processing Queue');

  if (!isAdmin()) {
    content.innerHTML = pageHead({ title: 'Processing Queue' }) +
      card(emptyState('Admins only', 'The processing queue is available to managers.'));
    return;
  }

  const data = await api('/manage/videos');
  const vids = arr(data, 'videos');
  const inflight = vids.filter(v => PROC_INFLIGHT.includes((v.status || '').toLowerCase()));

  const nProc = inflight.filter(v => (v.status || '').toLowerCase() === 'processing').length;
  const nFailed = inflight.filter(v => (v.status || '').toLowerCase() === 'failed').length;
  const nQueued = inflight.filter(v => (v.status || '').toLowerCase() === 'queued').length;

  /* keep the sidebar/topbar badge honest with what this view shows */
  setBadge('processing', nProc);

  const subParts = [`${nProc} processing`, `${nFailed} failed`];
  if (nQueued) subParts.push(`${nQueued} queued`);

  const head = pageHead({
    title: 'Processing Queue',
    sub: subParts.join(' · '),
    actions: btn('Refresh', { act: 'refresh' }),
  });

  /* nothing in flight → everything transcoded. Encourage + point to the full store. */
  if (!inflight.length) {
    content.innerHTML = head + card(emptyState(
      'All videos are ready.',
      'Nothing is transcoding right now. <a href="#/videos" style="color:var(--accent)">Open the Video Store →</a>'
    ));
    wire(content, { acts: { refresh: () => procReload() } });
    return;
  }

  content.innerHTML = head + dataTable({
    empty: 'All videos are ready.',
    columns: [
      { label: 'Title', render: v => `<b>${esc(v.title || 'Untitled')}</b>${v.encrypted ? ' ' + tag('encrypted') : ''}` },
      { label: 'Status', render: v => pill(v.status || 'processing') },
      { label: 'Duration', render: v => v.duration_seconds ? esc(fmtDur(v.duration_seconds)) : '<span class="muted">—</span>' },
      { label: 'Size', render: v => esc(procBytes(v.size_bytes)) },
      { label: 'Added', render: v => esc(fmtDate(v.created_at)) },
      {
        label: '', cls: 'right', render: v =>
          btn('Re-transcode', { act: 'retr', id: v.id, cls: 'btn-sm btn-ghost' }),
      },
    ],
    rows: inflight,
  });

  wire(content, {
    acts: {
      refresh: () => procReload(),
      retr: async id => {
        if (await confirmModal('Re-transcode this video? It will show as “processing” until the fresh HLS stream is ready.', { confirmLabel: 'Re-transcode' })) {
          await api('/manage/videos/' + id + '/retranscode', { method: 'POST' });
          toast('Re-transcoding started', 'good'); procReload();
        }
      },
    },
  });
}
registerView('processing', procView);
const procReload = () => procView(document.getElementById('content'), { setCrumbs });
