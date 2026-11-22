
/* Everything published, read once, then filtered in the browser. The counts and
   the chips come out of the same array, so they cannot disagree. */
const KINDS = [['','Everything'],['news','News'],['guidance','Guidance'],
               ['event','Events'],['video','Video']];
const HEADS = { '':'From the institute', news:'News', guidance:'Guidance',
                event:'Events', video:'Video' };

let all = [], kind = qs('kind') || '', page = pageNow();
const out  = document.getElementById('out'),
      feat = document.getElementById('feature'),
      nBox = document.getElementById('n');

document.getElementById('kinds').innerHTML = KINDS.map(([k,t]) =>
  `<button class="btn btn-s" data-k="${k}">${t}</button>`).join('');

(async () => {
  loading(out);
  const { data, error } = await sb.from('public_content').select('*')
    .order('published_at', { ascending:false });
  if (error) return failed(out, error, 'The published items');
  all = data || [];
  draw();
  drawEvents();
})();

document.getElementById('kinds').onclick = e => {
  const b = e.target.closest('[data-k]'); if (!b) return;
  kind = b.dataset.k; page = 1;
  const u = new URL(location);
  kind ? u.searchParams.set('kind', kind) : u.searchParams.delete('kind');
  u.searchParams.delete('page');
  history.replaceState(null, '', u);
  draw();
};

const link = r => `/article?kind=${encodeURIComponent(r.kind)}&slug=${encodeURIComponent(r.slug)}`;

// An event is dated by when it happens. Everything else is dated by when it was
// published, which is the only date it has.
const dateOf = r => r.kind === 'event' ? (r.starts_at || r.published_at) : r.published_at;

function whenLine(r){
  if (r.kind !== 'event') return fmtDate(r.published_at);
  return fmtDate(r.starts_at) + (r.location ? ' &middot; ' + esc(r.location) : '');
}

/* THE EVENTS LIST IS ONE LIST IN TWO HALVES, 23 August 2026.

   Everything else on this page is ordered by when it was published, which is the
   only date it has. An event has two dates and the one a reader cares about is
   when it happens, so the events view is ordered by that: what is coming, soonest
   first, then what has been, most recent first.

   The line between them is a heading rather than a second list, because a second
   list is a second empty state, a second count and a second thing to keep in step
   with the panel. `pastFrom` is where the second half starts, and the renderer
   puts the heading in front of it.

   AN EVENT WITH NO START DATE COUNTS AS UPCOMING. It has nowhere to sit on a
   calendar, which is why the panel leaves it alone, but filing it under Previous
   events would be the site asserting that something has happened when it does not
   know. The safer error is the one that does not make a claim. */
function orderEvents(rows){
  const now  = Date.now();
  const at   = r => new Date(r.starts_at).getTime();
  const soon = rows.filter(r => !r.starts_at || at(r) >= now)
                   .sort((a, b) => (a.starts_at ? at(a) : Infinity)
                                 - (b.starts_at ? at(b) : Infinity));
  const past = rows.filter(r => r.starts_at && at(r) < now)
                   .sort((a, b) => at(b) - at(a));
  const out  = soon.concat(past);
  out.pastFrom = soon.length;      // an index into `out`, not a count of anything
  return out;
}

const PAST_HEAD = `
  <div class="head-left sec-head" style="margin:30px 0 16px">
    <div class="eyebrow"><span class="tri"></span>The archive</div>
    <h2 style="font-size:24px">Previous events</h2>
  </div>`;

function draw(){
  // The chosen filter used to be the white pill against grey ones. Every pill
  // rests grey now, so it wears `on` instead, which is the hover look held.
  document.querySelectorAll('[data-k]').forEach(b =>
    b.className = 'btn btn-s btn-g' + (b.dataset.k === kind ? ' on' : ''));
  document.getElementById('head').textContent = HEADS[kind] || 'From the institute';

  const all_ = kind === 'event'
    ? orderEvents(all.filter(r => r.kind === 'event'))
    : all.filter(r => !kind || r.kind === kind);
  const pagerBox = document.getElementById('pager');

  if (!all_.length) {
    feat.innerHTML = ''; nBox.textContent = ''; drawPages(pagerBox, 1, 1);
    out.innerHTML = `<div class="state glass"><p>Nothing has been published here yet.</p></div>`;
    return;
  }

  // Eight to a page (site 90). On the first page the newest is given the room
  // and seven rows follow; later pages are eight rows and no feature.
  const pg = pageSlice(all_, page);
  page = pg.page; keepPage(page);
  nBox.textContent = pg.pages > 1
    ? `${pg.from + 1}\u2013${pg.from + pg.rows.length} of ${all_.length} items`
    : `${all_.length} item${all_.length === 1 ? '' : 's'}`;
  drawPages(pagerBox, pg.pages, page, n => { page = n; draw(); });

  const featured = page === 1;
  const first = featured ? pg.rows[0] : null;
  const rest  = featured ? pg.rows.slice(1) : pg.rows;

  /* Where the Previous events heading goes. `pastFrom` is an index into the
     whole list, so it is first made relative to this page. On the first page a
     value of 0 means the feature is itself a previous event and the heading goes
     above it, the case a naive splice gets wrong and the ordinary one for most
     of the year. On a later page the heading goes before the row it lands on,
     and on no page at all if the line falls elsewhere. */
  const local = (all_.pastFrom === undefined ? -1 : all_.pastFrom - pg.from);
  const headBeforeFeature = featured && local === 0;
  const headAtRestIndex = featured
    ? ((local > 0 && local <= rest.length) ? local - 1 : -1)
    : ((local >= 0 && local < rest.length) ? local : -1);

  feat.innerHTML = !first ? '' : (headBeforeFeature ? PAST_HEAD : '') + `
    <a href="${link(first)}" class="news-feature glass" style="margin-bottom:22px">
      <div class="pic ph" style="background-image:url('${imageFor(first)}')"></div>
      <div class="fbody">
        <span class="fcat">${esc(first.category || first.kind)}</span>
        <div class="fdate">${whenLine(first)}</div>
        <h2>${esc(first.title)}</h2>
        <p>${esc(first.summary || '')}</p>
        <span class="btn btn-p" style="align-self:flex-start">Read the story</span>
      </div>
    </a>`;

  out.innerHTML = rest.map((r, i) => (i === headAtRestIndex ? PAST_HEAD : '') + `
    <a href="${link(r)}" class="nrow glass">
      <div class="th ph" style="background-image:url('${imageFor(r)}')"></div>
      <div class="nb">
        <div class="ndate">${esc(r.category || r.kind)} &middot; ${whenLine(r)}</div>
        <h4>${esc(r.title)}</h4>
        <p>${esc(r.summary || '')}</p>
        <span class="more">Read more &rarr;</span>
      </div>
    </a>`).join('');

  revealSoon();
}

/* The sidebar is the calendar, so it shows what has not happened yet and nothing
   else. An event with no start date has nowhere to sit on a calendar and is left
   to the list on the left. */
function drawEvents(){
  const box = document.getElementById('events');
  const now = Date.now();
  const rows = all
    .filter(r => r.kind === 'event' && r.starts_at && new Date(r.starts_at).getTime() >= now)
    .sort((a,b) => new Date(a.starts_at) - new Date(b.starts_at))
    .slice(0, 6);

  if (!rows.length) {
    box.innerHTML = `<p style="font-size:14px;color:var(--muted);padding:8px 0 4px">
      Nothing is in the calendar just now. New events are listed here as soon as they are
      published.</p>`;
    return;
  }

  box.innerHTML = rows.map(r => `
    <a class="evc" href="${link(r)}">
      <div class="ed"><span class="d">${dayOf(r.starts_at)}</span><span class="m">${monOf(r.starts_at)}</span></div>
      <div>
        <div class="et">${esc(r.category || 'Event')}</div>
        <h5>${esc(r.title)}</h5>
        <div class="em">${esc(r.location || 'Location to be confirmed')}${
          r.starts_at ? ' &middot; ' + timeOf(r.starts_at) : ''}</div>
      </div>
    </a>`).join('')
    + `<div style="margin-top:18px"><a href="/news?kind=event" class="btn btn-red"
         style="width:100%;text-align:center">See every event</a></div>`;
}
