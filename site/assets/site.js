/* =============================================================================
   AMI public site: the shared bits

   One client, the background, the navigation, the footer, and the small helpers
   every page needs. Each page then does its own one job.

   The two values below are not secrets. The project URL is in every request the
   browser makes anyway, and the publishable key is public by design: it
   authenticates as `anon`, which holds no privilege on a single table in this
   database. What protects the data is row level security and the public views,
   not the obscurity of these strings. Anything that could write is behind the
   Worker in _worker.js, which holds the secret key in a binding the browser
   never sees.
   ============================================================================= */

const SUPABASE_URL = 'https://ttjvwxxtoidiiejyqmbc.supabase.co';
const SUPABASE_KEY = 'sb_publishable_qqz_c0zI5I25_d_tMBtWfg_vut-Y8wt';

/* The client is built the first time a page asks for it rather than the moment
   this file loads. That is what lets this file run BEFORE the 211KB database
   library: the header, the navigation and the footer are drawn from these ten
   kilobytes, and the library arrives behind them. Every page still writes
   sb.from(...) exactly as before. */
let _sb = null;
Object.defineProperty(window, 'sb', {
  configurable: true,
  get(){
    if (!_sb) {
      if (!window.supabase) throw new Error('The database library has not loaded yet');
      _sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
    }
    return _sb;
  },
});

/* ---------- the background ---------- */
// A fine mesh, then three drifting blobs, behind a moving gradient. Decoration,
// and marked as such so a screen reader walks straight past it.
//
// The mesh is first in the order on purpose. It is what the glass panels
// refract: without something structured behind them a backdrop blur has nothing
// to work on and the panels read as flat grey. The blobs sit over it and soften
// it where they overlap.
function buildBackground(){
  document.body.insertAdjacentHTML('afterbegin',
    '<div class="bg" aria-hidden="true"><div class="mesh"></div>'
    + '<div class="blob b1"></div>'
    + '<div class="blob b2"></div><div class="blob b3"></div></div>');
}

/* ---------- navigation ---------- */
/* CPD points at /cpd-scheme rather than /cpd. /cpd is the member's own record and
   sits behind the login, so the two cannot share an address. */
const NAV = [
  ['/about',       'About Us'],
  ['/membership',  'Membership'],
  ['/cpd-scheme',  'CPD'],
  ['/cscs-cards',  'CSCS Cards'],
  ['/support',     'Support &amp; Guidance'],
  ['/news',        'News &amp; Events'],
  ['/contact',     'Contact'],
];

function buildHeader(current){
  document.body.insertAdjacentHTML('afterbegin', `
    <a class="skip" href="#main">Skip to the content</a>
    <nav class="top">
      <a class="brandcard" href="/">
        <img src="/assets/ami-logo.webp?v=70" alt="AMI, the Asbestos Management Institute">
      </a>
      <div class="navbar glass">
        <ul id="navlist">
          ${NAV.map(([h,t]) =>
            `<li><a href="${h}" class="${h===current?'active':''}">${t}</a></li>`).join('')}
        </ul>
        <div class="right">
          <a href="/login" class="btn btn-g btn-s">Member Login</a>
          <a href="/apply" class="btn btn-p btn-s">Join AMI</a>
        </div>
        <button class="burger" id="burger" aria-label="Menu" aria-expanded="false">&#9776;</button>
      </div>
    </nav>`);
  const b = document.getElementById('burger');
  b.onclick = () => {
    const n = document.getElementById('navlist');
    n.classList.toggle('open');
    b.setAttribute('aria-expanded', n.classList.contains('open'));
  };
}

/* signedIn changes exactly two of the sixteen links. The forum and the login
   link both point at /login for a visitor, because both of them have to, and
   both are wrong for a member who is already signed in: one sends them through
   a sign in form they do not need, the other invites them to sign in twice. */
function buildFooter(signedIn){
  const forumHref = signedIn ? '/forum' : '/login';
  const meHref    = signedIn ? '/me'    : '/login';
  const meLabel   = signedIn ? 'My AMI' : 'Member login';
  document.body.insertAdjacentHTML('beforeend', `
    <footer><div class="wrap">
      <div class="cols">
        <div>
          <span class="flogo"><img src="/assets/ami-logo.webp?v=70" alt="AMI"></span>
          <p>The professional institute for individuals working in asbestos management.
             Membership is evidence of competence, maintained through continuing
             professional development and open to independent verification.</p>
        </div>
        <div>
          <h4>Membership</h4>
          <a href="/apply">Join AMI</a>
          <a href="/membership#grades">Grades of membership</a>
          <a href="/cscs-cards">CSCS cards</a>
          <a href="/membership#join">How to join</a>
          <a href="/register">Check a member</a>
          <a href="/professional-conduct">Professional conduct</a>
          <a href="/committees">Committees</a>
        </div>
        <div>
          <h4>Support and guidance</h4>
          <a href="/support">Guidance and resources</a>
          <a href="/cpd-scheme">Continuing development</a>
          <a href="/guidance">Guidance documents</a>
          <a href="/videos">Webinars and AGM</a>
          <a href="${forumHref}">Members forum</a>
        </div>
        <div>
          <h4>About</h4>
          <a href="/about">What AMI is</a>
          <a href="/news">News and events</a>
          <a href="/contact">Contact the office</a>
          <a href="${meHref}">${meLabel}</a>
        </div>
      </div>
      <div class="base">
        <span>&copy; ${new Date().getFullYear()} The Asbestos Management Institute</span>
        <span><a href="/privacy">Privacy notice</a></span>
      </div>
    </div></footer>`);
}

// Called by every page, in this order, so no page has to remember it.
function buildChrome(current){
  buildBackground();
  buildHeader(current);
}

/* ---------- helpers ---------- */
const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c =>
  ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

const qs = k => new URLSearchParams(location.search).get(k);

function fmtDate(v){
  if (!v) return '';
  const d = new Date(v);
  return isNaN(d) ? '' : d.toLocaleDateString('en-GB', {day:'numeric',month:'long',year:'numeric'});
}

// The events sidebar and the event rows both want a date split into a big day and
// a short month. One function, so the two never disagree about which month it is.
function dayOf(v){ const d = new Date(v); return isNaN(d) ? '' : String(d.getDate()).padStart(2,'0'); }
function monOf(v){
  const d = new Date(v);
  return isNaN(d) ? '' : d.toLocaleDateString('en-GB', { month:'short' });
}

// A time range for an event, written the way a person says it.
function timeOf(v){
  const d = new Date(v);
  return isNaN(d) ? '' : d.toLocaleTimeString('en-GB', { hour:'2-digit', minute:'2-digit' });
}

// A fee that has not been set yet is shown as "on application" rather than as
// £0.00, which would be a price and a wrong one. Used by the home page and by the
// membership page, so it lives here rather than in one of them.
function money(pence){
  if (pence == null) return '<span style="font-size:18px;opacity:.85">On application</span>';
  return '£' + (pence / 100).toLocaleString('en-GB', { maximumFractionDigits: 0 });
}

function loading(el){ el.innerHTML = '<div class="state"><span class="spin"></span></div>'; }

// One place that decides what a failed read looks like, so no page has to invent
// its own wording and none of them leak a database message to a visitor.
function failed(el, err, what){
  console.error(what, err);
  el.innerHTML = `<div class="state"><p>${esc(what)} could not be loaded just now.
    Please try again in a moment.</p></div>`;
}

// Names on a public register. Kept in one function so the register, the profile
// page and the card all spell a person the same way.
const fullName = r => [r.given_name, r.family_name].filter(Boolean).join(' ');
const withPost = r => fullName(r) + (r.post_nominals ? ' ' + r.post_nominals : '');
const initials = r => [r.given_name, r.family_name].filter(Boolean)
  .map(s => s[0]).join('').toUpperCase();

// The stock photographs, used where an item has no image of its own. Rotating
// by a stable hash of the slug rather than at random, so an article keeps the
// same picture between visits.
const STOCK = ['/assets/photo-team.webp?v=70', '/assets/photo-review.webp?v=70',
               '/assets/photo-site.webp?v=70', '/assets/photo-survey.webp?v=70'];
function stockFor(key){
  let n = 0;
  for (const ch of String(key || '')) n = (n * 31 + ch.charCodeAt(0)) % 9973;
  return STOCK[n % STOCK.length];
}

// An item's own picture if the office has uploaded one, otherwise a stock
// photograph. Pictures live in the public-media bucket, which is genuinely
// public, so the address can be built and the browser fetches it straight from
// the edge with no signing and no round trip.
//
// This used to point at content-media, which is private. A private bucket with a
// permissive policy is readable in theory and unreachable by an image tag in
// practice, so every uploaded picture silently fell back to a stock photograph.
const MEDIA = SUPABASE_URL + '/storage/v1/object/public/public-media/';
// 0046: a picture address is either a bundle photograph (/assets/...) or a
// path in public-media. An item with no picture of its own gets the one the
// database chose for it from the library's "use where an item has none"
// pictures (fallback_path), and only if there are none, one of the bundle's.
// The address goes into a CSS url(), so it is checked against the one pattern
// the database also holds (0037, 0046) and anything else is refused.
const PICTURE_ADDRESS = /^(\/assets\/[a-z0-9-]+\.webp|[a-z0-9][a-z0-9\/_-]*\.(webp|jpg))$/;
function pictureUrl(path){
  const p = String(path || '');
  if (!PICTURE_ADDRESS.test(p)) return '';
  return p.startsWith('/assets/') ? p + '?v=70' : MEDIA + p;
}
function imageFor(r){
  return (r && (pictureUrl(r.image_path) || pictureUrl(r.fallback_path))) || stockFor(r && r.slug);
}


/* ---------- reveal on scroll ---------- */
// Anything with .reveal fades up as it arrives. If this never runs, or the
// browser has no observer, everything is simply shown: an animation must never
// be the reason a paragraph is invisible.
// An element carrying data-bg gets its photograph only when the visitor is
// nearly at it. A big picture two screens down otherwise competes with the one
// they are actually looking at, and the whole page waits on it.
function paintBg(el){
  if (!el.dataset.bg) return;
  el.style.backgroundImage = el.dataset.bg;
  delete el.dataset.bg;
}

function startReveal(){
  const els = document.querySelectorAll('.reveal, [data-bg]');
  if (!('IntersectionObserver' in window)) {
    els.forEach(el => { el.classList.add('in'); paintBg(el); });
    return;
  }
  // Two margins: the picture starts loading 300px before it is needed so it has
  // arrived by the time it is on screen, while the fade still fires at the edge.
  const bgIo = new IntersectionObserver(entries => {
    entries.forEach(e => { if (e.isIntersecting) { paintBg(e.target); bgIo.unobserve(e.target); } });
  }, { rootMargin: '300px 0px' });
  const io = new IntersectionObserver(entries => {
    entries.forEach(e => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } });
  }, { rootMargin: '0px 0px -60px 0px' });
  els.forEach(el => {
    if (el.classList.contains('reveal')) io.observe(el);
    if (el.dataset.bg) bgIo.observe(el);
  });
}

// Called after a page has drawn whatever it draws.
function revealSoon(){ requestAnimationFrame(startReveal); }


/* ---------- article bodies ---------- */
/* The office can now write bold, lists and links in the admin, so a body may be
   markup rather than plain text. That markup is checked on the way in, and it is
   checked AGAIN here on the way out.
   Twice, because once is a policy and twice is a guarantee: the database could be
   written to by something other than the admin app, and this is the last thing
   between it and a browser.
   Anything not on the list is unwrapped, so the words survive and the machinery
   does not. No attributes survive except href on a link, and a link has to be
   http, https, mailto, or an address on this site, which is what stops
   javascript: in one.

   THE SITE'S OWN ADDRESSES WERE MISSING FROM THAT LIST UNTIL 30 OCTOBER 2026,
   and the way they were missing is the kind worth writing down. A link to
   /register failed the test, so the anchor was unwrapped and the words were
   kept. The sentence still read correctly. Nothing was logged, nothing looked
   broken, and the only sign was a link that was not a link. It never showed
   because the four blocks that existed at the time happened to contain no
   links at all. The page copy being moved into blocks contains two.

   A leading slash is this site. A leading double slash is NOT: //evil.example
   is another host written to look like a path, and it is refused along with
   everything else off the list. */
const SAFE_TAGS = ['P','BR','STRONG','B','EM','I','U','UL','OL','LI','A','H3','BLOCKQUOTE'];
/* What may sit INSIDE a paragraph, a bullet or an answer. A list item that
   arrives holding a <ul> or a <p> is nested markup the design never drew, so
   those are unwrapped and the words kept, by the same walk. */
const INLINE_TAGS = ['BR','STRONG','B','EM','I','U','A'];
const SAFE_LINK = /^(https?:|mailto:)/i;
const SITE_LINK = /^(\/(?!\/)|#)/;

function safeHtml(html, tags){
  const allow = tags || SAFE_TAGS;
  /* Parsed in a <template>, NEVER in a live element. Found 30 October 2026 by
     test 15: a <div> made with createElement belongs to the page even while
     it is detached, so an <img onerror> written into it starts loading at
     once and its handler runs before the walk below ever reaches it. The
     sanitiser was executing the thing it existed to remove. A template's
     content is inert: nothing loads and nothing runs. Only the cleaned nodes
     are moved into a real element, after the walk. */
  const tpl = document.createElement('template');
  tpl.innerHTML = String(html || '');
  const box = tpl.content;
  const walk = node => {
    [...node.childNodes].forEach(child => {
      if (child.nodeType === 3) return;
      if (child.nodeType !== 1) { child.remove(); return; }
      // A script or a stylesheet has no words worth keeping: unwrapped, its
      // code would appear on the page as a sentence.
      if (['SCRIPT','STYLE','TEMPLATE','IFRAME','OBJECT','EMBED','NOSCRIPT'].includes(child.tagName)) {
        child.remove(); return;
      }
      if (!allow.includes(child.tagName)) {
        walk(child);
        while (child.firstChild) node.insertBefore(child.firstChild, child);
        child.remove();
        return;
      }
      const href = child.tagName === 'A' ? child.getAttribute('href') : null;
      [...child.attributes].forEach(a => child.removeAttribute(a.name));
      if (child.tagName === 'A') {
        const to = href ? href.trim() : '';
        if (to && SITE_LINK.test(to)) {
          // Our own page. No target and no nofollow: opening the institute's
          // own pages in new tabs is how somebody ends up with nine of them,
          // and telling a search engine not to follow our own links is wrong.
          child.setAttribute('href', to);
        } else if (to && SAFE_LINK.test(to)) {
          child.setAttribute('href', to);
          child.setAttribute('rel', 'noopener nofollow');
          child.setAttribute('target', '_blank');
        } else {
          walk(child);
          while (child.firstChild) node.insertBefore(child.firstChild, child);
          child.remove();
          return;
        }
      }
      walk(child);
    });
  };
  walk(box);
  const out = document.createElement('div');
  out.appendChild(box);
  return out.innerHTML;
}

/* =============================================================================
   PAGE BLOCKS

   Every word on a public page is in the markup AND, once somebody has edited it,
   in page_blocks. The markup is the fallback and the database wins, so a page
   can never come out blank because a block was unpublished at five to five.

   THE RULE THAT MAKES TWO COPIES OF EACH SENTENCE BEARABLE: once a block
   exists, the copy in the markup is never edited again except to match it. It
   is a fallback, not a draft.

   Which element a block belongs to is in BLOCK_MAP, in assets/blocks.js, which
   is GENERATED by db/tools/extract-page-copy.py from the same mapping that
   generated the seed and the admin app's field list. Three things that have to
   agree, written by one file, rather than three by hand.

   A block whose key is not in the map does nothing, and a key in the map with
   no block shows the markup. Both silences are deliberate: neither can put a
   page on the screen with a hole in it.
   ============================================================================= */

// The browser half of the selector language. @n means the n-th match and
// A >> B means B inside the n-th A, and both exist because these pages use one
// class for one shape several times down a page, which is right of them.
function pickBlocks(sel, scope){
  const root = scope || document;
  if (sel.includes('>>')) {
    const [outer, rest] = sel.split('>>');
    const outs = pickBlocks(outer.trim(), root);
    return outs.length ? pickBlocks(rest.trim(), outs[0]) : [];
  }
  const m = sel.match(/@(\d+)$/);
  if (m) {
    const all = [...root.querySelectorAll(sel.slice(0, m.index))];
    const one = all[Number(m[1])];
    return one ? [one] : [];
  }
  return [...root.querySelectorAll(sel)];
}

// An address from the database gets the same treatment as one inside a body:
// our own pages plainly, anything off site in a new tab, anything else refused.
function blockHref(to){
  const s = String(to || '').trim();
  if (SITE_LINK.test(s) || SAFE_LINK.test(s)) return s;
  return null;
}

function paintLink(a, item){
  const href = blockHref(item.href);
  if (!href || !item.label) return;
  a.textContent = item.label;
  a.setAttribute('href', href);
  if (SITE_LINK.test(href)) { a.removeAttribute('target'); a.removeAttribute('rel'); }
  else { a.setAttribute('target', '_blank'); a.setAttribute('rel', 'noopener'); }
}

async function applyBlocks(pageKey){
  const map = (typeof BLOCK_MAP !== 'undefined' && BLOCK_MAP[pageKey]) || null;
  if (!map) return;

  /* `sb` is a getter that THROWS when the database library has not loaded, so
     this is a try rather than a typeof. typeof invokes a getter, so the obvious
     guard would have been the thing that raised. */
  let client = null;
  try { client = sb; } catch { return; }
  if (!client) return;

  const { data, error } = await client.from('public_page').select('*').eq('page_key', pageKey);
  if (error || !data) return;          // the markup is already on the screen
  let listed = false;
  const waits = [];

  data.forEach(b => {
    const spec = map[b.block_key];
    if (!spec) return;
    const [sel, kind] = spec;
    const els = pickBlocks(sel);
    if (!els.length) return;

    if (kind === 'line') {
      if (b.body) els[0].textContent = b.body;

    } else if (kind === 'rich') {
      if (b.body) els[0].innerHTML = bodyHtml(b.body);

    } else if (kind === 'prose') {
      // A run of sibling paragraphs with no wrapper of its own. The first one
      // becomes the whole block and the rest go, which is why a paragraph whose
      // job is to hold a button is left alone: it is not part of the prose and
      // removing it would take the button off the page.
      if (!b.body) return;
      const ps = els.filter(p => !p.querySelector('a.btn, button'));
      if (!ps.length) return;
      ps[0].outerHTML = bodyHtml(b.body);
      ps.slice(1).forEach(p => p.remove());

    } else if (kind === 'links') {
      const items = Array.isArray(b.items) ? b.items : [];
      if (!items.length) return;
      items.forEach((item, i) => {
        if (els[i]) { paintLink(els[i], item); return; }
        // More buttons than the markup has. They are always siblings, so one
        // more is a copy of the last put next to it.
        const last = els[els.length - 1];
        const clone = last.cloneNode(true);
        last.parentNode.insertBefore(clone, last.nextSibling);
        els.push(clone);
        paintLink(clone, item);
      });
      els.slice(items.length).forEach(a => a.remove());

    } else if (kind === 'list') {
      if (paintList(els, b.items, spec[2])) listed = true;

    } else if (kind === 'image') {
      // The banner is held back until its picture is the right one; the other
      // photographs are below the fold and painted lazily, so they do not wait.
      const p = paintPhoto(els[0], b.body);
      if (els[0].matches && els[0].matches('.pbanner.img')) waits.push(p);
    }
  });
  await Promise.all(waits);

  // A card added by the office is a CLONE, made after the reveal observer had
  // already been handed the page. An unobserved .reveal stays at opacity 0 for
  // ever, which is the privacy notice fault again in a new place: the words are
  // in the page and nothing is painted. So the observer is handed the page once
  // more. Calling it twice does nothing to what it has already seen.
  if (listed) revealSoon();
}

/* =============================================================================
   THE CPD SCHEME PAGE'S ACTIVITY LISTS (0040)

   The two "what counts" cards list the activity types the office has switched
   on, core in the first and non core in the second, with what each is worth.
   Read from public_cpd_activities, so ticking a type on the admin app's CPD
   activity types screen is what changes the page. The typed list in the markup
   is the fallback, and stays on the screen if the read fails.

   An activity's name is TEXT and goes in with textContent. It is written by
   staff, but the rule on this site is that nothing from the database becomes
   markup without passing the sanitiser, and a name needs no markup at all.
   ============================================================================= */
function pointsLabel(a){
  const n = v => String(Number(v));
  if (a.points != null) return n(a.points) + (Number(a.points) === 1 ? ' point' : ' points');
  if (a.points_min != null && a.points_max != null)
    return n(a.points_min) + ' to ' + n(a.points_max) + ' points';
  return '';
}

async function cpdActivities(){
  let client = null;
  try { client = sb; } catch { return; }
  const { data, error } = await client.from('public_cpd_activities').select('*');
  if (error || !Array.isArray(data) || !data.length) return;
  const cards = pickBlocks('.support-grid@0 >> .scard');
  if (cards.length < 2) return;
  [true, false].forEach((core, i) => {
    const list = data.filter(a => !!a.is_core === core);
    const ul = cards[i].querySelector('ul');
    if (!ul || !list.length) return;
    ul.textContent = '';
    list.forEach(a => {
      const li = document.createElement('li');
      li.textContent = a.name;
      const pts = pointsLabel(a);
      if (pts) {
        const b = document.createElement('b');
        b.textContent = ' · ' + pts;
        b.style.fontWeight = '600';
        li.appendChild(b);
      }
      ul.appendChild(li);
    });
  });
}

/* =============================================================================
   PHOTOGRAPHS

   A photograph block holds one address: a picture the bundle carries,
   /assets/<name>.webp, or a converted upload in the public-media bucket. It is
   written into a CSS url(), so it is checked against a pattern that cannot
   contain a quote, a bracket or a space before it goes anywhere near one. The
   database holds the same pattern as a constraint (0037); this is the second
   lock, for the same reason the sanitiser runs twice.

   The wash over a banner is part of the design and stays: only the url() is
   swapped, wherever it is, whether the picture is painted already or still
   waiting in data-bg for the lazy painter.

   The new picture is LOADED FIRST and swapped in once it has arrived. Swapped
   straight away, a banner would show the markup's photograph, then nothing
   while the new one downloads, then the new one, which reads as a fault.
   ============================================================================= */
const PHOTO_ADDRESS = /^(\/assets\/[a-z0-9-]+\.webp|[a-z0-9][a-z0-9\/_-]*\.(webp|jpg))$/;

/* NOT photoUrl. That name is already the members area's signed link for a
   member's own photograph, further down this file, and every page script shares
   one global scope with this one. A second function of the same name replaces
   the first without a word, node --check cannot see it, and the first symptom
   would have been every member's photograph vanishing. The const qs lesson
   from August, in a new place. */
function pagePhotoSrc(address, stamp){
  const a = String(address || '').trim();
  if (!PHOTO_ADDRESS.test(a)) return null;
  return a.startsWith('/assets/') ? a + stamp : MEDIA + a;
}

/* Returns a promise that settles once the picture is in place, or once there
   is nothing to do, so the banner can wait for the right picture rather than
   show the bundle's one first (see BANNER WAIT below). It never rejects. */
function paintPhoto(el, address){
  return new Promise(done => {
    if (!el) return done();
    const current = el.dataset.bg || el.style.backgroundImage || '';
    if (!/url\(/.test(current)) return done();   // the markup has no picture to replace
    // The bundle's own cache stamp, borrowed from the address the markup already
    // uses, so a photograph from the bundle is the same cached file and this is
    // not one more place to bump the version on every release.
    const stamp = (current.match(/\?v=\d+/) || [''])[0];
    const url = pagePhotoSrc(address, stamp);
    if (!url) return done();
    const swap = css => css.replace(/url\((['"]?)[^'")]*\1\)/, `url('${url}')`);
    if (current.includes(url)) return done();    // it is already this one
    const img = new Image();
    img.onload = () => {
      // Read again at the moment of swapping: the lazy painter may have moved
      // the picture from data-bg into the style while this one was loading.
      if (el.dataset.bg) el.dataset.bg = swap(el.dataset.bg);
      else el.style.backgroundImage = swap(el.style.backgroundImage);
      done();
    };
    img.onerror = () => done();                  // keep the bundle's picture
    img.src = url;
  });
}

/* =============================================================================
   REPEATING BLOCKS, piece two

   The cards, the steps, the questions and the bullets. Each item is drawn INTO
   the element the markup already has for it, and an item the markup has no
   element for is a copy of the last one, so the design comes from the page and
   never from here. Nothing below builds a card from a string of markup.

   Three rules, each because the obvious version is wrong:

   AN ICON IS A NAME. The drawing comes from BLOCK_ICONS in the bundle. A name
   the bundle does not know leaves the drawing that was there.

   A NUMBER ON A STEP IS A POSITION, so it is written from the index and never
   read from the item. Same for which question starts open: the first one, if
   the first one in the markup was.

   A LIST THAT IS NOT WHOLE IS NOT DRAWN AT ALL. An item with no title would
   otherwise keep the title of the card it was copied from, and the page would
   show the same heading twice with nothing to say why. Half a list from the
   database is worse than the whole list from the markup.
   ============================================================================= */
const LIST_NEEDS = {
  card:   ['title'],
  step:   ['title', 'body'],
  faq:    ['question', 'answer'],
  bullet: ['text'],
};

function paintList(els, items, type){
  const needs = LIST_NEEDS[type];
  if (!needs || !Array.isArray(items) || !items.length) return false;
  const whole = items.every(it => it && typeof it === 'object' && !Array.isArray(it)
    && needs.every(k => typeof it[k] === 'string' && it[k].trim()));
  if (!whole) return false;

  const firstOpen = els[0].hasAttribute('open');
  let prev = null;
  items.forEach((item, i) => {
    let el = els[i];
    if (!el) {
      const last = els[els.length - 1];
      el = last.cloneNode(true);
      (prev || last).after(el);
      els.push(el);
    }
    if (type === 'card')   fillCard(el, item);
    if (type === 'step')   fillStep(el, item, i);
    if (type === 'faq')    fillFaq(el, item, i, firstOpen);
    if (type === 'bullet') el.innerHTML = safeHtml(item.text, INLINE_TAGS);
    prev = el;
  });
  els.slice(items.length).forEach(el => el.remove());
  return true;
}

function linkTarget(a, href){
  a.setAttribute('href', href);
  if (SITE_LINK.test(href)) { a.removeAttribute('target'); a.removeAttribute('rel'); }
  else { a.setAttribute('target', '_blank'); a.setAttribute('rel', 'noopener'); }
}

function fillCard(el, it){
  const icon = el.querySelector('.qicon, .sicon');
  if (icon && it.icon && typeof BLOCK_ICONS !== 'undefined'
      && Object.prototype.hasOwnProperty.call(BLOCK_ICONS, it.icon))
    icon.innerHTML = BLOCK_ICONS[it.icon];

  const h = el.querySelector('h3, h4');
  if (h) h.textContent = it.title;

  // The words. Only a paragraph that is a direct child and holds no button is
  // prose; the paragraph a button sits in is the link, further down.
  const own = tag => [...el.children].filter(c => c.tagName === tag);
  const prose = own('P').filter(p => !p.querySelector('a.btn, button'));
  let after = h;
  if (it.body && String(it.body).trim()) {
    let p = prose[0];
    if (!p) { p = document.createElement('p'); (h ? h.after(p) : el.prepend(p)); }
    p.textContent = it.body;
    prose.slice(1).forEach(x => x.remove());
    after = p;
  } else {
    prose.forEach(x => x.remove());
  }

  // The bullets, which carry a bold term and a line break, so they are markup
  // and go through the inline allow list.
  const bl = (Array.isArray(it.bullets) ? it.bullets : [])
    .filter(b => typeof b === 'string' && b.trim());
  let ul = own('UL')[0];
  if (bl.length) {
    if (!ul) {
      ul = document.createElement('ul');
      ul.className = 'tlist';
      ul.style.marginTop = after === h ? '4px' : '12px';
      (after || el.lastElementChild).after(ul);
    }
    ul.innerHTML = bl.map(b => '<li>' + safeHtml(b, INLINE_TAGS) + '</li>').join('');
  } else if (ul) {
    ul.remove();
  }

  // The link. Either the whole card is the anchor, or a button sits in it.
  const href = blockHref(it.href);
  if (el.tagName === 'A') {
    if (href) linkTarget(el, href);
    else { el.removeAttribute('href'); el.removeAttribute('target'); el.removeAttribute('rel'); }
    return;
  }
  let a = el.querySelector('a.btn, a.more');
  if (href && it.link_label) {
    if (!a) {
      const p = document.createElement('p');
      p.style.marginTop = '16px';
      a = document.createElement('a');
      a.className = 'btn btn-g btn-s';
      p.appendChild(a);
      el.appendChild(p);
    }
    a.textContent = it.link_label;
    linkTarget(a, href);
  } else if (a) {
    const p = a.parentNode;
    a.remove();
    if (p !== el && p.tagName === 'P' && !p.textContent.trim()) p.remove();
  }
}

function fillStep(el, it, i){
  const n = el.querySelector('.n');
  if (n) n.textContent = String(i + 1);
  const h = el.querySelector('h4');
  if (h) h.textContent = it.title;
  const p = el.querySelector('p');
  if (p) p.textContent = it.body;
}

function fillFaq(el, it, i, firstOpen){
  const s = el.querySelector('summary');
  if (s) s.textContent = it.question;
  const p = el.querySelector('p');
  if (p) p.innerHTML = safeHtml(it.answer, INLINE_TAGS);
  if (i === 0 && firstOpen) el.setAttribute('open', '');
  else el.removeAttribute('open');
}

// A body written before the editor existed is plain text with blank lines in it.
// One function decides which it is looking at, so no page has to.
function bodyHtml(body){
  if (!body) return '';
  return /<[a-z][\s\S]*>/i.test(body)
    ? safeHtml(body)
    : String(body).split(/\n{2,}/).map(p => `<p>${esc(p.trim()).replace(/\n/g, '<br>')}</p>`).join('');
}


/* =============================================================================
   THE MEMBERS AREA

   Six pages behind a sign in, sharing one header, one guard and one idea of who
   the signed in person is. Every page calls member() first and does nothing until
   it comes back, because a page that draws itself and then discovers it should
   not have is a page that has already leaked something.
   ============================================================================= */

const MEMBER_NAV = [
  ['/me',      'My AMI'],
  ['/cpd',     'My CPD'],
  ['/learn',   'Earn CPD'],
  ['/card',    'My card'],
  ['/forum',   'Members forum'],
  ['/profile', 'My profile'],
];

/* The header on a members page keeps the PUBLIC navigation. A member is still a
   visitor and still wants to read the news, and duplicating the six members
   destinations in two bars a centimetre apart is two bars saying the same thing.
   The members destinations live in the sub navigation below it. */
function buildMemberHeader(me){
  const name = [me.given_name, me.family_name].filter(Boolean).join(' ') || me.email;
  document.body.insertAdjacentHTML('afterbegin', `
    <a class="skip" href="#main">Skip to the content</a>
    <nav class="top">
      <a class="brandcard" href="/">
        <img src="/assets/ami-logo.webp?v=70" alt="AMI, the Asbestos Management Institute">
      </a>
      <div class="navbar glass">
        <ul id="navlist">
          ${NAV.map(([h,t]) => `<li><a href="${h}">${t}</a></li>`).join('')}
        </ul>
        <div class="right">
          <a href="/me" class="btn btn-p btn-s">${esc(name)}</a>
          <button class="btn btn-g btn-s" id="signout" type="button">Sign out</button>
        </div>
        <button class="burger" id="burger" aria-label="Menu" aria-expanded="false">&#9776;</button>
      </div>
    </nav>`);
  const b = document.getElementById('burger');
  b.onclick = () => {
    const n = document.getElementById('navlist');
    n.classList.toggle('open');
    b.setAttribute('aria-expanded', n.classList.contains('open'));
  };
  document.getElementById('signout').onclick = signOut;
}

function memberSubNav(current){
  return `<nav class="msub glass-soft" aria-label="Members area">
    ${MEMBER_NAV.map(([h,t]) =>
      `<a href="${h}" class="${h===current?'on':''}"${h===current?' aria-current="page"':''}>${t}</a>`
    ).join('')}
  </nav>`;
}

async function signOut(){
  await sb.auth.signOut();
  location.href = '/';
}

/* ---------- the guard ---------- */
/* One call at the top of every members page. It returns the person, or it sends
   them to the sign in page and never returns, so nothing below it has to wonder.
   The address they were heading for is carried across, so signing in puts them
   where they were going rather than on a landing page. */
let _me = null;
async function member(){
  if (_me) return _me;
  const { data:{ session } } = await sb.auth.getSession();
  if (!session) { toLogin(); return new Promise(() => {}); }

  // Harmless to call twice, and it is what attaches a new account to the record
  // the office created, so it belongs on the way in rather than only on sign in.
  await sb.rpc('link_account');
  const { data, error } = await sb.rpc('whoami');
  if (error) { toLogin(); return new Promise(() => {}); }
  const me = Array.isArray(data) ? data[0] : data;
  if (!me) { location.href = '/login'; return new Promise(() => {}); }
  _me = me;
  return me;
}

function toLogin(){
  const back = location.pathname + location.search;
  location.href = '/login?next=' + encodeURIComponent(back);
}

/* Draws the header and the sub navigation once the person is known, and hands the
   page back the person. Every members page starts with exactly this line. */
/* The footer goes on the members pages too, and it goes on AFTER the guard
   rather than before it. A members page draws nothing until it knows who is
   looking, and a footer offering "Member login" to somebody who is signed in is
   the page admitting it has not checked. */
async function memberChrome(current){
  buildBackground();
  const me = await member();
  buildMemberHeader(me);
  const bar = document.getElementById('subnav');
  if (bar) bar.outerHTML = memberSubNav(current);
  buildFooter(true);
  return me;
}

/* ---------- the member's own photograph ---------- */
/* Member photographs are in a private bucket, so an address alone reaches nothing
   and an <img> cannot sign a request. This asks the database for a signed link
   that expires. A member with no photograph gets null, and every place that shows
   one falls back to initials rather than to a stock picture of somebody else. */
const PHOTO_TTL = 60 * 60;
async function photoUrl(path){
  if (!path) return null;
  const { data, error } = await sb.storage.from('member-photos').createSignedUrl(path, PHOTO_TTL);
  return error ? null : data.signedUrl;
}

// An avatar is a photograph if there is one and initials if there is not. One
// function, so the six places that draw one cannot disagree about the fallback.
function avatar(url, person, cls){
  return url
    ? `<div class="${cls}" style="background-image:url('${encodeURI(url)}')"></div>`
    : `<div class="${cls}">${esc(initials(person))}</div>`;
}

/* ---------- small shared things ---------- */
const YEAR = new Date().getFullYear();

// A relative time for anything inside a week, and a real date beyond it. "3 days
// ago" is useful; "412 days ago" is arithmetic the reader has to do.
function fmtWhen(v){
  if (!v) return '';
  const d = new Date(v);
  if (isNaN(d)) return '';
  const mins = Math.round((Date.now() - d) / 60000);
  if (mins < 1)    return 'just now';
  if (mins < 60)   return mins + (mins === 1 ? ' minute ago' : ' minutes ago');
  const hrs = Math.round(mins / 60);
  if (hrs < 24)    return hrs + (hrs === 1 ? ' hour ago' : ' hours ago');
  const days = Math.round(hrs / 24);
  if (days === 1)  return 'yesterday';
  if (days < 7)    return days + ' days ago';
  return fmtDate(v);
}

// Every write from a members page goes through here, so no page invents its own
// idea of what a failure looks like and no database message reaches a member.
function said(el, kind, text){
  el.innerHTML = `<div class="note ${kind}">${esc(text)}</div>`;
  el.scrollIntoView({ block:'nearest' });
}


/* ---------- forum bodies ---------- */
/* A forum post is stored as PLAIN TEXT, deliberately: 0008 says so, because it is
   the largest body of member submitted text on the site and therefore the most
   likely route to stored cross site scripting. So it is never passed through
   safeHtml, which is for the office's rich text editor. It is escaped, split into
   paragraphs, and that is all.

   Addresses are turned into links, which is worth having in a technical forum
   where people paste guidance. It is done AFTER escaping, so a URL containing a
   quotation mark has already become &quot; and cannot close the attribute, and
   only http and https match in the first place. */
const URL_IN_TEXT = /\bhttps?:\/\/[^\s<>"']+/g;

function postBody(text){
  return String(text || '')
    .split(/\n{2,}/)
    .map(p => '<p>' + esc(p.trim())
      .replace(/\n/g, '<br>')
      .replace(URL_IN_TEXT, u =>
        `<a href="${u}" rel="noopener nofollow ugc" target="_blank">${u}</a>`)
      + '</p>')
    .join('');
}


/* =============================================================================
   Starting a page

   Public pages used to carry one line of inline script calling buildChrome and
   buildFooter. That single line is what would have forced the Content Security
   Policy to allow inline script, which is the one thing the policy exists to
   refuse, so it became an attribute instead:

     <body data-nav="/about">

   Present means a public page, and its value is which navigation item is the
   current one. Absent means a members page, which builds its own header once it
   knows who is looking, and does that in memberChrome().

   revealSoon() is called HERE as well as by every page script, and that is not
   belt and braces, it is a fix. Until the privacy notice was added, every public
   page had a script of its own and every one of those scripts ended by calling
   revealSoon(). The privacy notice needs no script, so it did not have one, so
   nothing ever ran the reveal, so every `.reveal` section stayed at the opacity 0
   the stylesheet gives it and the entire notice was invisible below the banner.
   The page was there, the markup was there, and there was nothing on the screen.

   Calling it from here means a page with no script of its own cannot be blank
   again. Page scripts still call it after they draw, because content that
   arrives from the database arrives long after this runs, and calling it twice
   is harmless: adding a class an element already has does nothing.
   ============================================================================= */
(function(){
  const start = () => {
    const nav = document.body.getAttribute('data-nav');
    if (nav === null) return;          // a members page looks after itself
    buildChrome(nav);
    buildFooter(false);
    revealSoon();

    /* data-page is which page's blocks to read, and it is HERE rather than in
       eleven page scripts for the same reason revealSoon is: two of the eleven
       public pages have no script of their own. The CPD scheme and the CSCS
       cards pages are pure markup, exactly as the privacy notice was when it
       turned out nothing was calling the reveal and the whole page was
       invisible. A page with no script must not be a page with no copy. */
    const page = document.body.getAttribute('data-page');
    // The CPD scheme page's activity lists come from the database AFTER the
    // blocks, so a block can never paint over them with an older typed list.
    /* BANNER WAIT (1 November 2026). Found by Steve: the office changed the
       About page's banner picture, and every visit showed the bundle's old
       picture for a moment before the new one replaced it. The stylesheet now
       draws a banner on a page with blocks as the dark wash alone until the
       body carries blocks-ready, which is added once the blocks are applied
       and the banner's own picture has loaded, or after 1.5 seconds whatever
       has happened, so a slow or failed read still shows the bundle's
       picture rather than an empty banner. */
    const ready = () => document.body.classList.add('blocks-ready');
    setTimeout(ready, 1500);
    if (page) applyBlocks(page).then(() => { ready(); if (page === 'cpd-scheme') cpdActivities(); }, ready);
    else ready();
  };
  if (document.readyState === 'loading')
    document.addEventListener('DOMContentLoaded', start);
  else start();
})();
