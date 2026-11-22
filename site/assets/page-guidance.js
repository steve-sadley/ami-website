/* The guidance documents page (site 83, database 0065).

   Every published guidance document, newest first, with a search box and one
   pill per category. The list comes from public_guidance, which carries the
   document's type and size but never its storage address.

   DOWNLOADING. The documents are in a private bucket. Until now the article
   page signed a link with supabase-js, and signing needs a session, so it only
   ever worked for somebody signed in: a visitor pressing Download got "not
   available". The Worker now serves them at /api/guidance/<slug>:

     open document         an ordinary link. The Worker checks it is published
                           and streams it.
     members only          the link would carry no sign in, so the page fetches
                           it with the member's token and hands the browser the
                           file. Signed out, the button is a sign in link that
                           comes back here.

   Words from the database go in through esc(), never as markup. */

const out  = document.getElementById('docs');
const qBox = document.getElementById('q');
const cats = document.getElementById('cats');
let all = [], cat = '', page = pageNow();

const TYPES = { pdf:'PDF', doc:'Word', docx:'Word', xls:'Excel', xlsx:'Excel',
                ppt:'PowerPoint', pptx:'PowerPoint', csv:'CSV', txt:'Text',
                odt:'Document', ods:'Spreadsheet', odp:'Presentation' };
const sizeOf = n => !n ? '' : n < 1024 * 1024 ? Math.max(1, Math.round(n / 1024)) + ' KB'
                              : (n / 1048576).toFixed(1).replace(/\.0$/, '') + ' MB';

function card(d){
  const type = TYPES[d.file_type] || (d.file_type ? d.file_type.toUpperCase() : '');
  const facts = [d.category, d.published_at ? fmtDate(d.published_at) : '',
                 [type, sizeOf(d.file_size)].filter(Boolean).join(', ')].filter(Boolean);
  const read = `/article?kind=guidance&slug=${encodeURIComponent(d.slug)}`;
  const dl = !d.has_document ? ''
    : d.members_only
      ? `<button class="btn btn-p btn-s" type="button" data-member-dl="${esc(d.slug)}">Download</button>`
      : `<a class="btn btn-p btn-s" href="/api/guidance/${encodeURIComponent(d.slug)}">Download</a>`;
  return `
    <article class="doc glass">
      <div class="doc-top">
        <div class="qicon" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><line x1="8" y1="13" x2="16" y2="13"/><line x1="8" y1="17" x2="14" y2="17"/></svg></div>
        <div>
          <h3>${esc(d.title)}</h3>
          <div class="doc-meta">${facts.map(esc).join(' &middot; ')}${
            d.members_only ? ' <span class="lockpill">Members only</span>' : ''}</div>
        </div>
      </div>
      ${d.summary ? `<p>${esc(d.summary)}</p>` : ''}
      <div class="doc-acts">${dl}${
        // A members only document has no public article to read more on.
        d.members_only ? '' : `<a class="btn btn-g btn-s" href="${read}">Read more</a>`}</div>
      <div class="note doc-msg" aria-live="polite"></div>
    </article>`;
}

function draw(){
  const q = qBox.value.trim().toLowerCase();
  const shown = all.filter(d => (!cat || d.category === cat)
    && (!q || [d.title, d.summary, d.category].join(' ').toLowerCase().includes(q)));
  // Eight to a page (site 90).
  const pg = pageSlice(shown, page);
  page = pg.page; keepPage(page);
  drawPages(document.getElementById('pager'), pg.pages, page, n => { page = n; draw(); });
  out.innerHTML = shown.length ? pg.rows.map(card).join('')
    : `<p class="note">${all.length ? 'Nothing matches that search.' : 'No guidance documents have been published yet.'}</p>`;
  out.querySelectorAll('[data-member-dl]').forEach(b => b.onclick = () => memberDownload(b));
  revealSoon();
}

async function memberDownload(btn){
  const msg = btn.closest('.doc').querySelector('.doc-msg');
  let token = null;
  try { const { data } = await sb.auth.getSession(); token = data && data.session && data.session.access_token; } catch {}
  if (!token) {
    location.href = '/login?next=' + encodeURIComponent('/guidance');
    return;
  }
  btn.disabled = true; btn.textContent = 'Preparing';
  try {
    const res = await fetch('/api/guidance/' + encodeURIComponent(btn.dataset.memberDl),
      { headers: { Authorization: 'Bearer ' + token } });
    if (!res.ok) {
      const text = await res.text();
      let words = ''; try { words = JSON.parse(text).error; } catch {}
      msg.textContent = words || 'The download is not available just now.';
      return;
    }
    const blob = await res.blob();
    const name = (res.headers.get('Content-Disposition') || '').match(/filename="([^"]+)"/);
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = name ? name[1] : btn.dataset.memberDl;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 60000);
    msg.textContent = '';
  } catch {
    msg.textContent = 'The site could not be reached. Please try again.';
  } finally {
    btn.disabled = false; btn.textContent = 'Download';
  }
}

(async () => {
  let data = null, error = null;
  try {
    ({ data, error } = await sb.from('public_guidance').select('*').order('published_at', { ascending: false }));
  } catch (e) { error = e; }
  if (error) { out.innerHTML = '<p class="note">The guidance documents could not be loaded just now. Please try again shortly.</p>'; return; }
  all = data || [];
  const names = [...new Set(all.map(d => d.category).filter(Boolean))].sort();
  cats.innerHTML = names.length < 2 ? '' : ['', ...names].map(c =>
    `<button class="btn btn-s${c === cat ? ' on' : ''}" type="button" data-cat="${esc(c)}">${c ? esc(c) : 'All'}</button>`).join('');
  cats.onclick = e => {
    const b = e.target.closest('[data-cat]'); if (!b) return;
    cat = b.dataset.cat; page = 1;
    cats.querySelectorAll('[data-cat]').forEach(x => x.classList.toggle('on', x.dataset.cat === cat));
    draw();
  };
  qBox.oninput = () => { page = 1; draw(); };
  draw();
})();
