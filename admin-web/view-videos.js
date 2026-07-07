/* Video Store — R2-backed recordings library (source for recorded-as-live +
 * lessons). List with transcode status, chunked upload straight to R2, plus
 * re-transcode / delete. Admin-only section. Follows the view-courses pattern. */
'use strict';

/* bytes → human ("—" when unknown/0) */
function fmtBytes(n) {
  n = +n || 0; if (!n) return '—';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.min(u.length - 1, Math.floor(Math.log(n) / Math.log(1024)));
  const v = n / Math.pow(1024, i);
  return (i === 0 ? v : v.toFixed(v >= 100 ? 0 : 1)) + ' ' + u[i];
}

async function videosView(content, ctx) {
  ctx.setCrumbs('Video Store');
  const data = await api('/manage/videos');
  const vids = arr(data, 'videos');
  const r2ok = data.r2_enabled !== false;
  const nProc = vids.filter(v => v.status === 'processing').length;

  const sub = [`${vids.length} video${vids.length === 1 ? '' : 's'}`];
  if (nProc) sub.push(`${nProc} processing`);

  content.innerHTML = pageHead({
    title: 'Video Store',
    sub: sub.join(' · '),
    actions: (isAdmin() && r2ok ? btn('+ Upload video', { act: 'upload', cls: 'btn-primary' }) + ' ' : '') +
      btn('Refresh', { act: 'refresh' }),
  }) +
    (r2ok ? '' : `<p class="stub" style="margin-bottom:12px">Video storage (R2) is not configured on this server — uploads are disabled. Configure R2 to enable the library.</p>`) +
    dataTable({
      empty: 'No videos yet. Upload a recording to start your library.',
      columns: [
        { label: 'Title', render: v => `<b>${esc(v.title || 'Untitled')}</b>${v.encrypted ? ' ' + tag('encrypted') : ''}` },
        { label: 'Status', render: v => pill(v.status || 'processing') },
        { label: 'Duration', render: v => v.duration_seconds ? esc(fmtDur(v.duration_seconds)) : '<span class="muted">—</span>' },
        { label: 'Size', render: v => esc(fmtBytes(v.size_bytes)) },
        { label: 'Added', render: v => esc(fmtDate(v.created_at)) },
        {
          label: '', cls: 'right', render: v =>
            btn('ⓘ Info', { act: 'info', id: v.id, cls: 'btn-sm btn-ghost', title: 'Video details' }) + ' ' +
            btn('Re-transcode', { act: 'retr', id: v.id, cls: 'btn-sm btn-ghost' }) + ' ' +
            btn('Delete', { act: 'del', id: v.id, cls: 'btn-sm btn-danger' }),
        },
      ],
      rows: vids,
    });

  wire(content, {
    acts: {
      refresh: () => reloadVideos(),
      info: id => videoInfo(vids.find(v => String(v.id) === String(id))),
      upload: () => uploadModal(() => reloadVideos()),
      retr: async id => {
        if (await confirmModal('Re-transcode this video? It will show as “processing” until the fresh HLS stream is ready.', { confirmLabel: 'Re-transcode' })) {
          await api('/manage/videos/' + id + '/retranscode', { method: 'POST' });
          toast('Re-transcoding started', 'good'); reloadVideos();
        }
      },
      del: async id => {
        if (await confirmModal('Permanently delete this video, its source file and HLS stream? This cannot be undone.', { danger: true, confirmLabel: 'Delete' })) {
          await api('/manage/videos/' + id, { method: 'DELETE' });
          toast('Video deleted'); reloadVideos();
        }
      },
    },
  });
}
registerView('videos', videosView);
const reloadVideos = () => videosView(document.getElementById('content'), { setCrumbs });

/* ⓘ details for one video */
function videoInfo(v) {
  if (!v) { toast('Video not found'); return; }
  openModal({
    title: v.title || 'Untitled', sub: 'Video details', wide: true,
    bodyHtml: dl([
      ['Title', esc(v.title || 'Untitled')],
      ['Video ID', `<code class="keepcase">${esc(v.id)}</code>`],
      ['Status', pill(v.status || 'processing')],
      ['Duration', v.duration_seconds ? esc(fmtDur(v.duration_seconds)) : '—'],
      ['Size', esc(fmtBytes(v.size_bytes))],
      ['Encrypted', v.encrypted ? 'Yes' : 'No'],
      ['Added', esc(fmtDateTime(v.created_at))],
      ...(v.hls_url ? [['HLS URL', `<code class="keepcase">${esc(v.hls_url)}</code>`]] : []),
      ...(v.source_key || v.key ? [['Storage key', `<code class="keepcase">${esc(v.source_key || v.key)}</code>`]] : []),
      ...(v.error ? [['Last error', `<span style="color:var(--bad)">${esc(v.error)}</span>`]] : []),
    ]),
    footHtml: `<button class="btn btn-ghost" data-x="c">Close</button>`,
    onMount(root, close) { root.querySelector('[data-x=c]').onclick = close; },
  });
}

/* ---- Chunked upload: init → sign → PUT each part to R2 → complete ----
 * Parts go DIRECTLY to R2 via short-lived presigned PUT URLs (full bandwidth).
 * If a direct PUT fails (e.g. bucket CORS not applied), we fall back to the
 * server proxy part endpoint — the same fallback the backend is built for. */
const UPLOAD_CHUNK = 12 * 1024 * 1024; // 12MB parts (R2 min part size is 5MB)

/* raw PUT to a presigned R2 URL, with per-part byte progress. Returns the ETag. */
function putSignedPart(url, blob, onBytes) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('PUT', url);
    xhr.upload.onprogress = e => { if (e.lengthComputable && onBytes) onBytes(e.loaded); };
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        const etag = (xhr.getResponseHeader('ETag') || '').replace(/^"|"$/g, '');
        if (!etag) reject(new Error('no ETag from R2')); else resolve(etag);
      } else reject(new Error('R2 PUT ' + xhr.status));
    };
    xhr.onerror = () => reject(new Error('network error'));
    xhr.send(blob);
  });
}

/* fallback: stream one chunk through the API server, which forwards it to R2. */
async function putProxyPart(uploadID, key, partNum, blob) {
  const q = '?upload_id=' + encodeURIComponent(uploadID) + '&key=' + encodeURIComponent(key) + '&part=' + partNum;
  const res = await fetch(API + '/manage/videos/upload/part' + q, {
    method: 'POST',
    headers: { 'Authorization': 'Bearer ' + (token() || ''), 'X-Device-UUID': deviceId() },
    body: blob,
  });
  if (!res.ok) { const t = await res.text().catch(() => ''); throw new Error(t || 'part upload failed'); }
  const d = await res.json().catch(() => ({}));
  if (!d.etag) throw new Error('proxy returned no ETag');
  return d.etag;
}

/* Full flow. onProgress(fraction 0..1) fires as bytes land. Returns the created video. */
async function uploadVideoMultipart(file, title, onProgress) {
  const init = await api('/manage/videos/upload/init', {
    method: 'POST', body: { filename: file.name, content_type: file.type || 'video/mp4' },
  });
  const uploadID = init.upload_id, key = init.key;
  if (!uploadID || !key) throw new Error('upload could not be initialised');

  const total = Math.max(1, Math.ceil(file.size / UPLOAD_CHUNK));
  const partNums = Array.from({ length: total }, (_, i) => i + 1);

  let urls = {};
  try { urls = (await api('/manage/videos/upload/sign', { method: 'POST', body: { key, upload_id: uploadID, parts: partNums } })).urls || {}; }
  catch (_) { urls = {}; } // no signed URLs → everything goes through the proxy

  const parts = [];
  let uploaded = 0;
  for (let i = 0; i < total; i++) {
    const start = i * UPLOAD_CHUNK;
    const blob = file.slice(start, Math.min(start + UPLOAD_CHUNK, file.size)); // no type → no Content-Type header (keeps presign signature valid)
    const pn = i + 1;
    const signed = urls[String(pn)];
    let etag = null;
    if (signed) {
      try { etag = await putSignedPart(signed, blob, done => onProgress((uploaded + done) / file.size)); }
      catch (_) { etag = null; } // fall through to proxy
    }
    if (!etag) etag = await putProxyPart(uploadID, key, pn, blob);
    uploaded += blob.size;
    onProgress(uploaded / file.size);
    parts.push({ part_number: pn, etag });
  }

  return api('/manage/videos/upload/complete', {
    method: 'POST', body: { upload_id: uploadID, key, title, size: file.size, parts },
  });
}

function uploadModal(onDone) {
  openModal({
    title: 'Upload video',
    sub: 'Uploads in chunks straight to storage, then transcodes to HLS.',
    bodyHtml: `
      <label class="fld">Title <span class="hint">optional — defaults to the file name</span>
        <input id="uv_title" type="text" placeholder="e.g. Module 3 — Prompt Engineering">
      </label>
      <label class="fld">Video file
        <input id="uv_file" type="file" accept="video/*">
      </label>
      <div id="uv_prog" style="display:none;margin-top:14px">
        <div style="height:8px;border-radius:999px;background:var(--panel-2);overflow:hidden">
          <div id="uv_bar" style="height:100%;width:0;background:var(--accent);transition:width .2s"></div>
        </div>
        <div id="uv_pct" class="stub" style="margin-top:6px">Preparing…</div>
      </div>
      <div class="modal-err" id="uv_err" style="margin-top:8px"></div>`,
    footHtml: `<button class="btn btn-ghost" data-x="c">Cancel</button><button class="btn btn-primary" data-x="up">Upload</button>`,
    onMount(root, close) {
      const fileEl = root.querySelector('#uv_file'), titleEl = root.querySelector('#uv_title');
      const prog = root.querySelector('#uv_prog'), bar = root.querySelector('#uv_bar'), pct = root.querySelector('#uv_pct');
      const err = root.querySelector('#uv_err'), upBtn = root.querySelector('[data-x=up]'), cancelBtn = root.querySelector('[data-x=c]');
      cancelBtn.onclick = close;
      upBtn.onclick = async () => {
        const file = fileEl.files && fileEl.files[0];
        if (!file) { err.textContent = 'Choose a video file first.'; return; }
        err.textContent = ''; prog.style.display = '';
        upBtn.disabled = fileEl.disabled = titleEl.disabled = cancelBtn.disabled = true;
        const title = titleEl.value.trim() || file.name;
        try {
          await uploadVideoMultipart(file, title, frac => {
            const p = Math.min(100, Math.round(frac * 100));
            bar.style.width = p + '%'; pct.textContent = 'Uploading… ' + p + '%';
          });
          bar.style.width = '100%'; pct.textContent = 'Uploaded — transcoding started.';
          toast('Video uploaded — transcoding started', 'good');
          close(); if (onDone) onDone();
        } catch (ex) {
          err.textContent = ex.message || 'Upload failed';
          upBtn.disabled = fileEl.disabled = titleEl.disabled = cancelBtn.disabled = false;
        }
      };
    },
  });
}
