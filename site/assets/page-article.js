
const out = document.getElementById('out'), banner = document.getElementById('banner');
const kind = qs('kind'), slug = qs('slug');

(async () => {
  if (!slug) return missing();
  loading(out);
  let q = sb.from('public_article').select('*').eq('slug', slug);
  if (kind) q = q.eq('kind', kind);
  const { data, error } = await q.maybeSingle();
  if (error) return failed(out, error, 'This item');
  if (!data) return missing();
  render(data);
  related(data);
})();

function missing(){
  document.title = 'Not found | AMI';
  banner.innerHTML = `<section class="pbanner">
    <div class="crumb"><a href="/">Home</a> &nbsp;&rsaquo;&nbsp;
      <a href="/news">News and events</a> &nbsp;&rsaquo;&nbsp; <b>Not found</b></div>
    <h1>This page is not here</h1></section>`;
  out.innerHTML = `<section style="padding-top:20px"><div class="glass" style="padding:40px">
    <p style="color:var(--muted);margin-bottom:26px">It may have been withdrawn, or it may be
      material that is open to members only.</p>
    <a class="btn btn-p" href="/news">Back to news and events</a></div></section>`;
}

function render(r){
  document.title = r.title + ' | AMI';

  /* The banner carries the photograph, the category and the byline, as the
     prototype had it. The wash is the same graphite wash every inner page uses,
     so the picture reads as a picture and the words stay legible over it. */
  banner.innerHTML = `
    <section class="pbanner img wash ph"
      style="background-image:linear-gradient(100deg,rgba(10,12,16,.93),rgba(10,12,16,.62) 46%,rgba(10,12,16,.10) 80%),url('${imageFor(r)}')">
      <div class="crumb"><a href="/">Home</a> &nbsp;&rsaquo;&nbsp;
        <a href="/news">News and events</a> &nbsp;&rsaquo;&nbsp; <b>${esc(r.title)}</b></div>
      <span class="cat">${esc(r.category || r.kind)}</span>
      <h1>${esc(r.title)}</h1>
      <div class="meta">${esc(r.kind === 'event'
        ? fmtDate(r.starts_at) + (r.location ? ' · ' + r.location : '')
        : fmtDate(r.published_at))}</div>
    </section>`;

  // Two slots, because a Vimeo player in a 290 pixel aside is a Vimeo player
  // nobody can watch, while a download button and the when and where of an event
  // belong beside the words rather than interrupting them.
  let extraMain = '', extra = '';
  if (r.kind === 'event') {
    extra = `<h4>When and where</h4><ul class="facts" style="margin-top:0">
      <li><b>When</b><span>${esc(fmtDate(r.starts_at))}${
        r.starts_at ? ', ' + timeOf(r.starts_at) : ''}</span></li>
      ${r.location ? `<li><b>Where</b><span>${esc(r.location)}</span></li>` : ''}</ul>`;
  }
  // has_document since 0067; storage_path kept for the moment before 0067 runs.
  if (r.kind === 'guidance' && (r.has_document || r.storage_path)) {
    extra = `<p style="margin:26px 0"><button class="btn btn-p" id="dl">Download the document</button></p>`;
  }
  // Vimeo or YouTube (videoEmbed in site.js). Nothing recognisable, no player.
  const player = r.kind === 'video' ? videoEmbed(r.vimeo_id) : null;
  if (player) {
    extraMain = `<div class="vframe" style="margin:0 0 26px">
      <iframe src="${esc(player)}"
        allow="fullscreen; picture-in-picture" title="${esc(r.title)}"></iframe></div>`;
  }

  const url = location.origin + location.pathname + location.search;
  const share = encodeURIComponent(url), text = encodeURIComponent(r.title);

  out.innerHTML = `
    <article class="article glass">
      <div class="article-grid">
        <div>
          ${extraMain}
          ${r.summary ? `<p class="lead">${esc(r.summary)}</p>` : ''}
          <!-- bodyHtml() lives in site.js. It sanitises markup written in the admin
               against the same allow list the admin applies on the way in, and falls
               back to paragraph splitting for the older plain text bodies. -->
          ${bodyHtml(r.body)}
        </div>

        <aside class="article-aside">
          <h4>Share this</h4>
          <div class="share">
            <a href="https://www.linkedin.com/sharing/share-offsite/?url=${share}"
               rel="noopener" target="_blank" aria-label="Share on LinkedIn">in</a>
            <a href="https://x.com/intent/tweet?url=${share}&text=${text}"
               rel="noopener" target="_blank" aria-label="Share on X">X</a>
            <a href="mailto:?subject=${text}&body=${share}" aria-label="Share by email">&#9993;</a>
          </div>
          ${extra}
          <h4>Details</h4>
          <ul class="meta-list">
            ${r.category ? `<li><b>Category</b>${esc(r.category)}</li>` : ''}
            ${r.published_at ? `<li><b>Published</b>${esc(fmtDate(r.published_at))}</li>` : ''}
            <li><b>From</b>The Asbestos Management Institute</li>
          </ul>
        </aside>
      </div>
    </article>
    <p style="margin-top:26px">${r.kind === 'guidance'
      ? '<a class="btn btn-g" href="/guidance">&larr; All guidance documents</a>'
      : '<a class="btn btn-g" href="/news">&larr; News and events</a>'}</p>`;

  // The document is in a private bucket. Until site 83 the link was signed here
  // with supabase-js, and signing needs a session, so a visitor who was not
  // signed in pressed Download and was told it was not available. The Worker
  // serves it now, at /api/guidance/<slug>, and decides who may have it.
  // Members only documents never reach this page (public_article leaves them
  // out), so a plain address is enough here.
  const dl = document.getElementById('dl');
  if (dl) dl.onclick = () => { location.href = '/api/guidance/' + encodeURIComponent(r.slug); };
}

/* Three more of the same kind, newest first, never the one being read. If there
   are none the whole section stays hidden rather than showing an empty heading. */
async function related(r){
  const { data } = await sb.from('public_content').select('*')
    .eq('kind', r.kind).neq('slug', r.slug)
    .order('published_at', { ascending:false }).limit(3);
  if (!data || !data.length) return;
  document.getElementById('related-wrap').style.display = '';
  document.getElementById('related').innerHTML = data.map(x => `
    <a class="ncard glass" href="/article?kind=${encodeURIComponent(x.kind)}&slug=${encodeURIComponent(x.slug)}">
      <div class="nimg ph" style="background-image:url('${imageFor(x)}')">
        <span class="cat">${esc(x.category || x.kind)}</span>
      </div>
      <div class="body">
        <div class="date">${esc(fmtDate(x.published_at))}</div>
        <h4>${esc(x.title)}</h4>
        <span class="more">Read more &rarr;</span>
      </div>
    </a>`).join('');
}
