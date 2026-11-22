
/* The three most recent pieces of guidance. If nothing has been published the
   section says so rather than leaving a hole where three cards should be. */
(async () => {
  const box = document.getElementById('latest');
  loading(box);
  const { data, error } = await sb.from('public_content').select('*')
    .eq('kind', 'guidance').order('published_at', { ascending:false }).limit(3);
  if (error) return failed(box, error, 'The published guidance');
  if (!data.length) {
    box.innerHTML = `<div class="state glass" style="grid-column:1/-1">
      <p>No guidance has been published here yet.</p></div>`;
    return;
  }
  box.innerHTML = data.map(r => `
    <a class="ncard glass" href="/article?kind=guidance&slug=${encodeURIComponent(r.slug)}">
      <div class="nimg ph" style="background-image:url('${imageFor(r)}')">
        <span class="cat">${esc(r.category || 'Guidance')}</span>
      </div>
      <div class="body">
        <div class="date">${esc(fmtDate(r.published_at))}</div>
        <h4>${esc(r.title)}</h4>
        <p>${esc(r.summary || '')}</p>
        <span class="more">Read more &rarr;</span>
      </div>
    </a>`).join('');
})();

revealSoon();
