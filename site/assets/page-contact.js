/* The form posts to /api/contact in the Worker, which holds the mail key in an
   encrypted binding. The browser never sees it. */
const form = document.getElementById('form'),
      go   = document.getElementById('go'),
      msg  = document.getElementById('msg');

form.onsubmit = async e => {
  e.preventDefault();
  const body = {
    name:    document.getElementById('name').value.trim(),
    email:   document.getElementById('email').value.trim(),
    topic:   document.getElementById('topic').value,
    message: document.getElementById('message').value.trim(),
    website: document.getElementById('website').value,
  };

  // Checked here so somebody is told at once, and checked again in the Worker,
  // because a check in a browser is a courtesy and not a control.
  if (!body.name)  return say('err', 'Please give your name.');
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(body.email))
    return say('err', 'Please check the email address.');
  if (body.message.length < 10)
    return say('err', 'Please say a little more, so the office can help.');

  go.disabled = true; go.textContent = 'Sending';
  msg.innerHTML = '';

  let out;
  try {
    const res = await fetch('/api/contact', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    out = await res.json().catch(() => null);
    if (!res.ok) throw new Error(out?.error || '');
  } catch (err) {
    go.disabled = false; go.textContent = 'Send message';
    return say('err', (err && err.message)
      || 'The message could not be sent just now. Please try again shortly, or email the office.');
  }

  // The form is replaced rather than cleared, so nobody sends the same message
  // three times wondering whether it went.
  form.innerHTML = `<h3>Thank you</h3>
    <div class="fsub">Your message has reached the office.</div>
    <div class="note ok">A copy has gone to your email address. Somebody will reply, normally
      within two working days.</div>
    <p style="margin-top:8px"><a class="btn btn-g" href="/">Back to the home page</a></p>`;
};

function say(kind, text){
  msg.innerHTML = `<div class="note ${kind}">${esc(text)}</div>`;
}
