/* LocalTunes local transfer client. No dependencies or external requests. */
function sha256(buffer) {
  const input = new Uint8Array(buffer);
  const size = Math.ceil((input.length + 9) / 64) * 64;
  const data = new Uint8Array(size); data.set(input); data[input.length] = 128;
  const view = new DataView(data.buffer);
  view.setUint32(size - 8, Math.floor(input.length * 8 / 4294967296));
  view.setUint32(size - 4, input.length * 8 >>> 0);
  const k = [0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2];
  const h = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
  const rotate = (x, n) => x >>> n | x << (32 - n);
  const w = new Uint32Array(64);
  for (let block = 0; block < size; block += 64) {
    for (let i = 0; i < 16; i++) w[i] = view.getUint32(block + i * 4);
    for (let i = 16; i < 64; i++) {
      const x = w[i - 15], y = w[i - 2];
      w[i] = (rotate(x,7) ^ rotate(x,18) ^ x >>> 3) + w[i-16] + (rotate(y,17) ^ rotate(y,19) ^ y >>> 10) + w[i-7];
    }
    let [a,b,c,d,e,f,g,t] = h;
    for (let i = 0; i < 64; i++) {
      const p = (t + (rotate(e,6) ^ rotate(e,11) ^ rotate(e,25)) + ((e & f) ^ (~e & g)) + k[i] + w[i]) >>> 0;
      const q = ((rotate(a,2) ^ rotate(a,13) ^ rotate(a,22)) + ((a & b) ^ (a & c) ^ (b & c))) >>> 0;
      t=g; g=f; f=e; e=(d+p)>>>0; d=c; c=b; b=a; a=(p+q)>>>0;
    }
    const next = [a,b,c,d,e,f,g,t]; for (let i=0;i<8;i++) h[i]=(h[i]+next[i])>>>0;
  }
  return h.map(x => x.toString(16).padStart(8,'0')).join('');
}
if (typeof module !== 'undefined') module.exports = {sha256};
if (typeof document !== 'undefined') {
  const status = document.getElementById('status'), progress = document.getElementById('progress');
  let busy = false, controller = null;
  async function request(path, options = {}) {
    const response = await fetch(path, {...options, signal: controller.signal});
    const value = await response.json();
    if (!response.ok) throw new Error(value.error || 'Transfer failed');
    return value;
  }
  async function transfer(files) {
    if (busy) return;
    const allowed = new Set('mp3 m4a m4b m4r aac wav wave aif aiff aifc alac caf mp4 flac au snd ac3 amr lrc txt'.split(' '));
    const originalCount = files.length;
    files = files.filter(file => file.size > 0 && allowed.has(file.name.split('.').pop().toLowerCase()));
    const skipped = originalCount - files.length;
    if (!files.length) { status.textContent = 'No supported music or lyric files selected.'; return; }
    busy = true; controller = new AbortController();
    document.querySelectorAll('input').forEach(x => x.disabled = true);
    document.getElementById('pause').disabled = false;
    try {
      let count = 0;
      for (const file of files) {
        status.textContent = 'Preparing ' + file.name;
        let upload = await request('begin', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({name:file.name,size:file.size,modified:String(file.lastModified),relative:file.webkitRelativePath || file.name})});
        const chunk = 1048576;
        for (let i = 0; i < upload.hashes.length; i++) {
          status.textContent = 'Verifying resume: ' + file.name;
          const data = await file.slice(i*chunk, Math.min((i+1)*chunk,file.size)).arrayBuffer();
          if (sha256(data) !== upload.hashes[i]) throw new Error('This file changed since the earlier upload. Rename it and select it again.');
        }
        let offset = upload.offset;
        while (!upload.completed && offset < file.size) {
          const data = await file.slice(offset, Math.min(offset+chunk,file.size)).arrayBuffer();
          upload = await request('chunk?id='+encodeURIComponent(upload.id)+'&offset='+offset, {method:'POST',headers:{'Content-Type':'application/octet-stream','X-Chunk-SHA256':sha256(data)},body:data});
          offset = upload.offset; progress.value = offset / file.size;
          status.textContent = file.name + ' — ' + Math.round(100*progress.value) + '% ('+(count+1)+'/'+files.length+')';
        }
        if (!upload.completed) await request('finish?id='+encodeURIComponent(upload.id), {method:'POST'});
        count++; progress.value = 1;
      }
      status.textContent = count + ' files received (' + skipped + ' unsupported or empty files skipped). Stop transfer on the iPhone, then tap Import received files.';
    } catch (error) {
      status.textContent = error.name === 'AbortError' ? 'Paused. Select the same files to resume.' : error.message + ' Select the same files to retry or resume.';
    } finally {
      busy = false; document.querySelectorAll('input').forEach(x => x.disabled = false);
      document.getElementById('pause').disabled = true;
    }
  }
  for (const id of ['files','folder']) document.getElementById(id).addEventListener('change', event => { const files=Array.from(event.target.files); event.target.value=''; transfer(files); });
  document.getElementById('pause').addEventListener('click',()=>controller?.abort());
}
