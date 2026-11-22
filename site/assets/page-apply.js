
const form = $('#form'), msg = $('#msg'), go = $('#go');

// Today, so nobody has to find the date picker to sign something they are
// signing today.
$('#signed_on').value = new Date().toISOString().slice(0, 10);

/* ---------- files ---------- */
// Chosen files are listed back, because a file input that says "3 files" and
// nothing else is how people submit the wrong three files.
document.querySelectorAll('[data-drop]').forEach(box => {
  const key   = box.dataset.drop;
  const input = document.getElementById(key);
  const list  = box.querySelector(`[data-picked="${key}"]`);

  const show = () => {
    list.innerHTML = [...input.files].map(f =>
      `<span><b>${esc(f.name)}</b> ${(f.size / 1024 / 1024).toFixed(1)} MB${
        f.size > 20 * 1024 * 1024 ? ' — too large, twenty megabytes is the limit' : ''}</span>`).join('');
  };
  input.addEventListener('change', show);

  // Dragging a file onto the panel. The input still holds the truth, so nothing
  // depends on this working.
  ['dragenter', 'dragover'].forEach(e => box.addEventListener(e, ev => {
    ev.preventDefault(); box.classList.add('over'); }));
  ['dragleave', 'drop'].forEach(e => box.addEventListener(e, ev => {
    ev.preventDefault(); box.classList.remove('over'); }));
  box.addEventListener('drop', ev => {
    if (!ev.dataTransfer?.files?.length) return;
    const dt = new DataTransfer();
    if (input.multiple) [...input.files].forEach(f => dt.items.add(f));
    [...ev.dataTransfer.files].forEach(f => dt.items.add(f));
    input.files = dt.files;
    show();
  });
});

/* ---------- sending ---------- */
form.onsubmit = async e => {
  e.preventDefault();
  msg.innerHTML = '';

  const problem = check();
  if (problem) return say('err', problem);

  go.disabled = true; go.textContent = 'Sending';

  // Posted to a Worker as multipart, files and all. The browser holds a key that
  // cannot write anything; the Worker holds the one that can, and it never
  // leaves Cloudflare.
  const fd = new FormData(form);

  try {
    const res = await fetch('/api/apply', { method:'POST', body: fd });
    const text = await res.text();
    let out = {};
    try { out = JSON.parse(text); }
    catch {
      throw new Error(res.status === 404 || res.status === 405
        ? 'The form is not connected to the office yet (' + res.status + '). '
          + 'Please email the office instead, and let them know you saw this.'
        : 'The application could not be sent (' + res.status + ').');
    }
    if (!res.ok) throw new Error(out.error || 'The application could not be sent (' + res.status + ').');
    done(out.reference, out.failed || []);
  } catch (err) {
    say('err', err.message);
    go.disabled = false; go.textContent = 'Submit the application';
  }
};

function check(){
  const v = id => ($('#' + id).value || '').trim();
  if (!v('given') || !v('family'))   return 'Please give your first name and surname.';
  if (!v('dob'))                     return 'Please give your date of birth.';
  if (!v('telephone'))               return 'Please give a mobile telephone number.';
  if (!v('address'))                 return 'Please give your private address.';
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v('email')))
    return 'Please check the email address. Everything about the application goes to it.';
  if (!v('employer') || !v('position')) return 'Please give your employer and current position.';
  if (!v('appointed'))               return 'Please give the date you were appointed.';
  if (!$('#cv').files.length)        return 'A current CV is needed. It is what the assessment is made on.';
  if (!v('signed_name'))             return 'Please give your name in full on the declaration.';
  if (!v('signed_on'))               return 'Please date the application.';

  const big = [...form.querySelectorAll('input[type=file]')]
    .flatMap(i => [...i.files]).find(f => f.size > 20 * 1024 * 1024);
  if (big) return `${big.name} is larger than twenty megabytes. Please send that one to the office by email.`;
  return null;
}

function say(kind, text){
  msg.innerHTML = `<div class="note ${kind}">${esc(text)}</div>`;
  msg.scrollIntoView({ behavior:'smooth', block:'center' });
}

function done(reference, failed){
  document.title = 'Application sent | AMI';
  form.innerHTML = `
    <div class="note ok">
      <h3 style="margin-bottom:8px">Your application is with the office</h3>
      <p style="margin:0">Your reference is <b>${esc(reference || 'being allocated')}</b>. Keep it:
        it is how the office will refer to your application. Somebody reads every one by hand, so it
        will not be instant. Your application will be assessed, the appropriate grade of membership
        confirmed, and an invoice for that grade sent to the address you gave.</p>
    </div>
    ${failed.length ? `<div class="note err" style="margin-top:14px">
      <b>These attachments did not go through:</b> ${esc(failed.join(', '))}.<br>
      Everything else arrived. Please email them to the office quoting your reference.</div>` : ''}
    <p style="margin-top:24px"><a class="btn btn-g" href="/">Back to the home page</a></p>`;
  window.scrollTo({ top:0, behavior:'smooth' });
}
