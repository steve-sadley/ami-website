/* =============================================================================
   Members forum

   Two views on one page. Without a category it shows the categories and what has
   been said recently. With ?c=slug it shows that category's discussions. One page
   rather than two, because they share the header, the search and the start a
   discussion form, and a second file would be the same file with one list swapped.

   Everything here reads forum_category_list, forum_thread_list and, on the thread
   page, forum_post_list. Those three run as the owner and carry their own filter,
   because a member cannot read another member's people row and so cannot be shown
   who wrote anything without them.
   ============================================================================= */

const out = document.getElementById('out');
let CATS = [], P = null, cat = null;

(async () => {
  await memberChrome('/forum');
  cat = qs('c');

  const [profile, cats] = await Promise.all([
    sb.from('my_profile').select('*').maybeSingle(),
    sb.from('forum_category_list').select('*').order('sort_order'),
  ]);
  if (profile.error) return failed(out, profile.error, 'The forum');
  P = profile.data;

  // An inactive membership sees nothing at all, by policy. Saying so plainly is
  // better than an empty page that looks broken.
  if (!P || !P.is_active) {
    out.innerHTML = `<section class="pbanner"><h1>Members forum</h1></section>
      <div class="callout" style="max-width:70ch">
        <b>The forum is open to members with an active membership.</b> Yours is not
        currently active, so it is closed to you for the moment. The office can tell
        you why, and <a href="/contact" style="color:var(--link);font-weight:700">they
        are the people to ask</a>.</div>`;
    return;
  }

  CATS = cats.data || [];
  await draw();
})();

async function draw(){
  const here = CATS.find(c => c.slug === cat);

  const threads = await sb.from('forum_thread_list').select('*')
    .order('pinned', { ascending: false })
    .order('last_post_at', { ascending: false })
    .limit(here ? 100 : 8)
    .then(r => here ? { ...r, data: (r.data || []).filter(t => t.category_slug === cat) } : r);

  out.innerHTML = `
    <section class="pbanner" style="padding:10px 0 20px">
      ${here ? `<div class="crumb"><a href="/forum">Members forum</a>
        &nbsp;&rsaquo;&nbsp; <b>${esc(here.name)}</b></div>` : ''}
      <div class="eyebrow"><span class="tri"></span>Members only</div>
      <h1>${esc(here ? here.name : 'Members forum')}</h1>
      <p>${esc(here
        ? (here.description || 'Discussions in this category.')
        : 'Somewhere to ask the question you would otherwise ring three people about. '
          + 'Every post carries a real name and a grade, because that is what makes an '
          + 'answer worth reading.')}</p>
    </section>

    <div style="display:flex;gap:12px;flex-wrap:wrap;margin-bottom:24px;align-items:center">
      ${here && here.locked
        ? '<span class="badge-t">This category is closed to new discussions</span>'
        : '<button class="btn btn-red" type="button" id="new">Start a discussion</button>'}
      <div class="regsearch" style="flex:1;justify-content:flex-end">
        <input type="text" id="q" placeholder="Search the discussions"
               value="${esc(qs('q') || '')}">
      </div>
    </div>

    <div id="newslot"></div>

    <div class="mgrid">
      <div id="left"></div>
      <div id="right"></div>
    </div>`;

  if (!here || !here.locked) document.getElementById('new').onclick = newThread;
  document.getElementById('q').addEventListener('input', e => filter(e.target.value));

  if (here) {
    drawThreads(threads.data || [], 'left', 'Discussions', 'Nothing has been asked in this '
      + 'category yet. Somebody has to be first, and it may as well be a good question.');
    document.getElementById('right').innerHTML = sideCats();
  } else {
    drawCats();
    drawThreads(threads.data || [], 'right', 'Recent activity', 'Nothing has been posted yet.');
  }
}

/* ---------- the categories ---------- */
function drawCats(){
  const el = document.getElementById('left');
  if (!CATS.length) {
    el.innerHTML = `<div class="callout">No categories have been set up yet. The office
      adds them in the admin, and the forum opens the moment there is one.</div>`;
    return;
  }
  el.innerHTML = `
    <div class="head-left sec-head" style="margin-bottom:18px">
      <div class="eyebrow"><span class="tri"></span>Categories</div>
      <h2>Where to put a question</h2>
    </div>
    ${CATS.map(c => `
      <a class="fcat glass" href="/forum?c=${encodeURIComponent(c.slug)}" data-name="${esc(c.name)}">
        <div class="fic">${esc(c.name.trim()[0] || '?')}</div>
        <div class="fb">
          <h4>${esc(c.name)}</h4>
          <p>${esc(c.description || '')}</p>
        </div>
        <div class="fn"><b>${c.thread_count}</b>${c.thread_count === 1 ? 'discussion' : 'discussions'}
          ${c.last_post_at ? '<br>' + esc(fmtWhen(c.last_post_at)) : ''}</div>
      </a>`).join('')}`;
}

const sideCats = () => `
  <div class="aside glass">
    <h3>Categories</h3>
    <ul>${CATS.map(c =>
      `<li><a href="/forum?c=${encodeURIComponent(c.slug)}"
        style="color:${c.slug === cat ? '#fff' : 'var(--muted)'}">${esc(c.name)}</a></li>`
    ).join('')}</ul>
  </div>
  <div class="callout">
    <b>The forum is not moderated in advance.</b> Posts go up as they are written. A word
    list holds a post back for somebody to look at rather than publishing it, and that list
    is visible to the office only.
  </div>
  <div class="callout">
    <b>You can edit or delete your own post until somebody replies to it.</b> After that it
    stays, because changing a post that has already been answered makes nonsense of the
    answer.
  </div>`;

/* ---------- the discussions ---------- */
function drawThreads(rows, where, heading, empty){
  const el = document.getElementById(where);
  const list = rows.length
    ? rows.map(t => `
        <a class="trow glass-soft" href="/t/${encodeURIComponent(t.slug)}"
           data-search="${esc((t.title + ' ' + t.given_name + ' ' + t.family_name + ' ' + t.category).toLowerCase())}">
          ${avatar(null, t, 'tav')}
          <div class="tb">
            <h4>${t.pinned ? '<span class="badge-t red" style="margin-right:8px">Pinned</span>' : ''}
              ${esc(t.title)}</h4>
            <div class="tm">${esc(fullName(t))}${t.post_nominals ? ' ' + esc(t.post_nominals) : ''}
              &middot; ${esc(t.category)} &middot; ${esc(fmtWhen(t.last_post_at || t.created_at))}
              ${t.mine ? ' &middot; yours' : ''}</div>
          </div>
          <div class="tr"><b>${Math.max(0, t.post_count - 1)}</b>
            ${t.post_count === 2 ? 'reply' : 'replies'}</div>
        </a>`).join('')
    : `<div class="callout">${esc(empty)}</div>`;

  el.innerHTML = `
    <div class="head-left sec-head" style="margin-bottom:18px">
      <div class="eyebrow"><span class="tri"></span>${esc(heading === 'Discussions' ? 'In here' : 'Latest')}</div>
      <h2>${esc(heading)}</h2>
    </div>
    <div id="threadlist">${list}</div>
    ${where === 'right' && !cat ? sideNotes() : ''}`;
}

const sideNotes = () => `
  <div class="callout">
    <b>The forum is not moderated in advance.</b> Posts go up as they are written. A word
    list holds a post back for somebody to look at rather than publishing it, and that list
    is visible to the office only.
  </div>
  <div class="callout">
    <b>You can edit or delete your own post until somebody replies to it.</b> After that it
    stays, because changing a post that has already been answered makes nonsense of the
    answer.
  </div>`;

/* Searching filters what is already here rather than asking the database again.
   That is right at a few hundred discussions and becomes a server side query past
   a few thousand; the place to change it is this function. */
function filter(term){
  const t = term.trim().toLowerCase();
  document.querySelectorAll('#threadlist .trow').forEach(row => {
    row.style.display = !t || row.dataset.search.includes(t) ? '' : 'none';
  });
  document.querySelectorAll('.fcat').forEach(c => {
    c.style.display = !t || c.dataset.name.toLowerCase().includes(t) ? '' : 'none';
  });
}

/* ---------- starting one ---------- */
function newThread(){
  const slot = document.getElementById('newslot');
  slot.innerHTML = `
    <div class="formcard glass" style="max-width:none;margin-bottom:26px">
      <h3>Start a discussion</h3>
      <div class="fsub">Posting as ${esc(fullName(P))}${P.grade ? ', ' + esc(P.grade) : ''}. Your
        name and grade are shown on every post.</div>

      <div class="field">
        <label for="ncat">Category</label>
        <select id="ncat">
          ${CATS.filter(c => !c.locked).map(c =>
            `<option value="${c.id}"${c.slug === cat ? ' selected' : ''}>${esc(c.name)}</option>`
          ).join('')}
        </select>
      </div>

      <div class="field">
        <label for="ntitle">The question, in one line</label>
        <input type="text" id="ntitle" maxlength="200"
               placeholder="Stage two, how far do you go with a suspended ceiling?">
        <div class="hint">A specific question gets specific answers. Between 3 and 200
          characters.</div>
      </div>

      <div class="field">
        <label for="nbody">What you want to ask</label>
        <textarea id="nbody" rows="7" maxlength="20000"
          placeholder="What happened, what you did, and what you are unsure about."></textarea>
      </div>

      <div id="nmsg"></div>
      <div style="display:flex;gap:10px;flex-wrap:wrap">
        <button class="btn btn-red" type="button" id="npost">Post it</button>
        <button class="btn btn-g" type="button" id="ncancel">Cancel</button>
      </div>
    </div>`;
  slot.scrollIntoView({ behavior: 'smooth', block: 'start' });
  document.getElementById('ncancel').onclick = () => { slot.innerHTML = ''; };
  document.getElementById('npost').onclick = post;
}

async function post(){
  const btn = document.getElementById('npost');
  const msg = document.getElementById('nmsg');
  const title = document.getElementById('ntitle').value.trim();
  const body  = document.getElementById('nbody').value.trim();

  if (title.length < 3) return said(msg, 'err', 'Please give the discussion a title.');
  if (!body)            return said(msg, 'err', 'Please write your question.');

  btn.disabled = true; btn.textContent = 'Posting';
  const { data, error } = await sb.rpc('start_thread', {
    p_category_id: document.getElementById('ncat').value,
    p_title: title,
    p_body:  body,
  });
  if (error) {
    btn.disabled = false; btn.textContent = 'Post it';
    return said(msg, 'err', 'That could not be posted just now. Please try again.');
  }

  const r = Array.isArray(data) ? data[0] : data;

  // A held post is not a failure and must not read like one. The member is told
  // what happened, what happens next, and that it is not visible to anybody else
  // yet, because a post that disappears without explanation gets written again.
  if (r && r.held) {
    return said(msg, 'ok', 'Posted, and it is being looked at before it appears. Something '
      + 'in it matched the word list, which holds a post rather than publishing it. Nobody '
      + 'else can see it yet. The office normally clears these the same working day and you '
      + 'will hear either way.');
  }
  location.href = '/t/' + encodeURIComponent(r.slug);
}
