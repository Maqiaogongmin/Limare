// Uploads one file to Limare (POST /attachments) for the current connection, with progress.
// Resolves with { ok, attachment } or { ok: false, message }; never rejects.
export function uploadFile(file, connectionID, onProgress) {
  return new Promise((resolve) => {
    const xhr = new XMLHttpRequest();
    const name = encodeURIComponent(file.name || 'upload');
    xhr.open('POST', `/attachments?connection=${encodeURIComponent(connectionID)}&filename=${name}`);
    xhr.setRequestHeader('Content-Type', file.type || 'application/octet-stream');
    xhr.upload.onprogress = (event) => { if (event.lengthComputable) onProgress(event.loaded / event.total); };
    xhr.onload = () => {
      let body = null;
      try { body = JSON.parse(xhr.responseText); } catch { /* not JSON */ }
      if (xhr.status === 200 && body && body.id) resolve({ ok: true, attachment: body });
      else resolve({ ok: false, message: (body && body.message) || (xhr.status === 403 ? '登录已过期，请刷新页面。' : `上传失败（${xhr.status}）`) });
    };
    xhr.onerror = () => resolve({ ok: false, message: '网络中断，上传失败。' });
    xhr.send(file);
  });
}
