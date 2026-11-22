/* =============================================================================
   Your photograph

   The page around the cropper. It loads the member's current picture so that
   arriving here to make a small adjustment does not mean finding the original
   again, wires the controls, and hands the two cut files to the Worker.

   The upload goes to /api/photo rather than to storage directly. A browser
   writing into a bucket means the bucket's policy is the only check, and a policy
   cannot look inside a file. The Worker can, and does.
   ============================================================================= */

const msg  = document.getElementById('msg');
const save = document.getElementById('save');
const rst  = document.getElementById('reset');
let P = null, crop = null;

(async () => {
  await memberChrome('/profile');

  const { data, error } = await sb.from('my_profile').select('*').maybeSingle();
  if (error || !data) return said(msg, 'err', 'Your record could not be loaded just now.');
  P = data;

  document.getElementById('pname').textContent  = fullName(P);
  document.getElementById('pgrade').textContent =
    [P.grade, P.grade_post_nominals].filter(Boolean).join(' · ');

  crop = makeCropper({
    stage:  document.getElementById('stage'),
    canvas: document.getElementById('cv'),
    band:   document.getElementById('band'),
    zoom:   document.getElementById('zoom'),
    bandy:  document.getElementById('bandy'),
    previews: {
      square: document.getElementById('p1'),
      small:  document.getElementById('p2'),
      strip:  document.getElementById('p3'),
    },
    onchange: ready => {
      save.disabled = rst.disabled = !ready;
      document.getElementById('empty').style.display = ready ? 'none' : 'flex';
      document.getElementById('zv').textContent =
        Math.round(crop.state().scale * 100) + '%';
      const by = crop.state().by;
      document.getElementById('bv').textContent =
        by < 0.25 ? 'High' : by > 0.6 ? 'Low' : 'Middle';
    },
  });

  // Start from the picture they already have, so a small adjustment does not mean
  // finding the original again. It is the square, so the band starts where it was
  // rather than where the strip was.
  if (P.photo_path) {
    document.getElementById('removebox').style.display = 'block';
    const url = await photoUrl(P.photo_path);
    if (url) {
      try { await crop.load(await (await fetch(url)).blob()); }
      catch (e) { /* an unreadable stored picture is not worth an error here */ }
    }
  }

  wire();
})();

function wire(){
  document.getElementById('file').addEventListener('change', async e => {
    const f = e.target.files && e.target.files[0];
    e.target.value = '';                       // so choosing the same file twice works
    if (!f) return;
    if (f.size > 20 * 1024 * 1024)
      return said(msg, 'err', 'That file is larger than 20MB. Most phones can send a '
        + 'smaller version if you choose one from the photo library rather than a file.');
    try { await crop.load(f); msg.innerHTML = ''; }
    catch (err) { said(msg, 'err', err.message); }
  });

  rst.onclick  = () => crop.reset();
  save.onclick = upload;
  document.getElementById('remove').onclick = remove;
}

async function upload(){
  save.disabled = true; save.textContent = 'Saving';
  said(msg, 'info', 'Cutting and sending. This takes a moment on a slow connection.');

  try {
    const { square, strip } = await crop.cutBoth();
    const { data:{ session } } = await sb.auth.getSession();

    const body = new FormData();
    body.append('square', square, 'square.jpg');
    body.append('strip',  strip,  'strip.png');

    const r = await fetch('/api/photo', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + session.access_token },
      body,
    });
    // The body is read as TEXT first and parsed second. Reading it as JSON and
    // swallowing the failure is what hid this for an entire evening: when the
    // answer was not JSON at all, the only thing left was a status code and a
    // shrug. Off the live site the raw body goes on screen, because whatever
    // produced it says what it is, and I cannot.
    const raw = await r.text();
    let out = {};
    try { out = JSON.parse(raw); } catch { out = {}; }
    const staging = location.hostname !== 'ami.uk.com';

    if (!r.ok) {
      save.disabled = false; save.textContent = 'Save photograph';
      const why = [out.at && '[' + out.at + ']', out.detail].filter(Boolean).join(' ');
      const rawBit = (!out.error && staging)
        ? '  [status ' + r.status + '] ' + raw.replace(/\s+/g, ' ').slice(0, 400)
        : '';
      return said(msg, 'err', (out.error
        || 'That could not be saved just now. Please try again in a moment.')
        + (why && staging ? '  ' + why : '')
        + rawBit);
    }

    save.textContent = 'Saved';
    said(msg, 'ok', 'Saved. It is on your profile and on your card now. '
      + (P.photo_on_public_page
          ? 'It also appears on your public page, because that switch is on.'
          : 'It does not appear on your public page, because that switch is off.'));
    setTimeout(() => { location.href = '/profile'; }, 1600);
  } catch (err) {
    save.disabled = false; save.textContent = 'Save photograph';
    said(msg, 'err', err.message || 'That could not be saved just now.');
  }
}

async function remove(){
  const b = document.getElementById('remove');
  b.disabled = true; b.textContent = 'Removing';
  const { data:{ session } } = await sb.auth.getSession();
  const r = await fetch('/api/photo', {
    method: 'DELETE',
    headers: { Authorization: 'Bearer ' + session.access_token },
  });
  b.disabled = false; b.textContent = 'Remove my photograph';
  if (!r.ok) return said(msg, 'err', 'That could not be removed just now.');
  said(msg, 'ok', 'Removed.');
  setTimeout(() => { location.href = '/profile'; }, 1200);
}
