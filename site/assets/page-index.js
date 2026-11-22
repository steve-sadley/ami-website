/* ---- the headline and the photograph, rotating together ---- */
// One ticker drives both, so they change on the same beat and with the same
// fade. Two intervals would drift apart within a minute and look like a fault.
const SHOTS = [
  ['/assets/hero.webp?v=70',          'Recognised best practice'],
  ['/assets/photo-review.webp?v=70',  'Assessed on evidence'],
  ['/assets/photo-team.webp?v=70',    'A community of professionals'],
  ['/assets/photo-site.webp?v=70',    'Competence, kept current'],
];

(async () => {
  const box = document.getElementById('hrot');
  const pic = document.getElementById('heroPic');
  const badge = document.getElementById('heroBadge');

  // Build the picture layers. The first is already in the page.
  //
  // The photograph is left off them until the page itself has finished loading.
  // Setting a background-image here would make the browser fetch all four at
  // once, against the stylesheet and the first photograph, which is what made
  // the home page feel slow. Nothing is lost by waiting: the first turn is nine
  // seconds away and the file is in the cache long before then.
  const layers = SHOTS.slice(1).map(([src]) => {
    const d = document.createElement('div');
    d.className = 'shot';
    pic.insertBefore(d, badge);
    return [d, src];
  });
  const warm = () => layers.forEach(([d, src]) => {
    d.style.backgroundImage =
      `linear-gradient(rgba(15,17,22,.05),rgba(15,17,22,.22)),url('${src}')`;
  });
  if (document.readyState === 'complete') setTimeout(warm, 300);
  else addEventListener('load', () => setTimeout(warm, 300));
  let shots = [...pic.querySelectorAll('.shot')];

  // The words, and since 0046 each headline's own photograph and label. A
  // headline with no photograph keeps the one in this file at its position.
  const { data, error } = await sb.from('public_hero').select('statement, image_path, badge').order('sort_order');
  if (!error && data && data.length) {
    data.forEach((r, i) => {
      const src = pictureUrl(r.image_path);
      if (src) SHOTS[i] = [src, r.badge || (SHOTS[i] ? SHOTS[i][1] : '')];
      else if (r.badge && SHOTS[i]) SHOTS[i] = [SHOTS[i][0], r.badge];
    });
    // A headline past the bundle's four with no photograph of its own borrows
    // one, so there is still exactly one photograph per headline.
    for (let i = 0; i < data.length; i++) if (!SHOTS[i]) SHOTS[i] = SHOTS[i % 4];
    SHOTS.length = Math.max(data.length, 1);
    // The first layer is already painted from the markup; repaint it, and the
    // rest pick up their address when they are warmed.
    const first = pic.querySelector('.shot');
    if (first && SHOTS[0]) first.style.backgroundImage =
      `linear-gradient(rgba(15,17,22,.05),rgba(15,17,22,.22)),url('${SHOTS[0][0]}')`;
    if (SHOTS[0]) badge.textContent = SHOTS[0][1];
    // One layer per photograph, so headline n always shows photograph n. The
    // old rule, keep two counts equal by hand, is gone.
    while (layers.length > SHOTS.length - 1) layers.pop()[0].remove();
    while (layers.length < SHOTS.length - 1) {
      const d = document.createElement('div');
      d.className = 'shot';
      pic.insertBefore(d, badge);
      layers.push([d, '']);
    }
    layers.forEach((l, i) => { l[1] = SHOTS[i + 1][0]; });
    if (document.readyState === 'complete') warm();
    shots = [...pic.querySelectorAll('.shot')];
    box.querySelector('.hrot-space').textContent =
      data.reduce((a, b) => b.statement.length > a.length ? b.statement : a, '');
    box.querySelectorAll('.hrot-item').forEach(el => el.remove());
    data.forEach((r, i) => box.insertAdjacentHTML('beforeend',
      `<span class="hrot-item${i ? '' : ' on'}">${esc(r.statement)}</span>`));
  }
  const words = [...box.querySelectorAll('.hrot-item')];

  // Somebody who has asked their machine to stop things moving gets the first
  // headline and the first photograph, and neither of them ever changes.
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  if (words.length < 2 && shots.length < 2) return;

  // One counter, and it WRAPS.
  //
  // It used to count up for ever, and each list took the remainder against its
  // own length. With three statements in the database and four photographs in
  // this file that is three against four, so the pairing changed on every turn
  // and did not come back round until the twelfth, which is a minute and a half
  // in. The words and the picture were both correct and they were never together
  // twice, which is what somebody watching the page notices.
  //
  // Wrapping the counter at the number of turns fixes it: statement two now
  // carries the same photograph every time the page comes back round to it.
  //
  // The number of turns is the number of statements, because the statements are
  // the half the office controls. A photograph past that count is therefore
  // never shown. Keep the two counts equal: four statements in the admin app for
  // the four photographs here, or take a photograph out of SHOTS.
  //
  // With one statement there is nothing to pair, so the photographs lead
  // instead and the single headline sits under all of them.
  const turns = words.length > 1 ? words.length : Math.max(shots.length, 1);
  let i = 0;
  setInterval(() => {
    const prev = i;
    i = (i + 1) % turns;
    if (words.length > 1) {
      words[prev % words.length].classList.remove('on');
      words[i % words.length].classList.add('on');
    }
    if (shots.length > 1) {
      shots[prev % shots.length].classList.remove('on');
      shots[i % shots.length].classList.add('on');
      badge.textContent = SHOTS[i % SHOTS.length][1];
    }
  }, 6500);
})();

/* ---- the grades, with this year's fee ---- */
(async () => {
  const box = document.getElementById('grades');
  const year = new Date().getFullYear();
  const [{ data:grades }, { data:fees }] = await Promise.all([
    sb.from('public_grades').select('*').order('sort_order'),
    sb.from('public_fees').select('*').eq('year', year),
  ]);
  if (!grades || !grades.length) { box.innerHTML = ''; return; }

  const fee = Object.fromEntries((fees || []).map(f => [f.code, f.fee_pence]));

  // No grade is picked out any more: every card turns red under the pointer
  // instead (site 83, Steve). That is in site.css, .grade:hover.

  box.innerHTML = grades.map(g => `
    <div class="grade glass reveal">
      <span class="tag">${esc(g.name)}</span>
      <h4>${esc(g.post_nominals || g.name)}</h4>
      <p>${esc(g.blurb || 'Recognition of assessed competence in asbestos management.')}</p>
      <div class="price">${money(fee[g.code])}<span>${fee[g.code] != null ? '/yr' : ''}</span></div>
    </div>`).join('');
  revealSoon();
})();

// money() now lives in site.js, because the membership page needs it too.

/* The counted figures came out on 11 August, from here and from the About page.
   The reader and the counting up animation went with them rather than being left
   sitting in the file: unreachable code still gets read, still gets maintained,
   and eventually gets called again by somebody who assumes it was left for a
   reason. The `public_numbers` view stays in the database, unused, because
   dropping a view is a migration and nothing is gained by it. */

/* ---- the latest three ---- */
(async () => {
  const box = document.getElementById('latest');
  loading(box);
  const { data, error } = await sb.from('public_content').select('*')
    .order('published_at', { ascending:false }).limit(3);
  if (error) return failed(box, error, 'The latest items');
  if (!data.length) {
    box.innerHTML = `<div class="state glass" style="grid-column:1/-1">
      <p>Nothing has been published yet.</p></div>`;
    return;
  }
  box.innerHTML = data.map(r => `
    <a class="ncard glass reveal" href="/article?kind=${encodeURIComponent(r.kind)}&slug=${encodeURIComponent(r.slug)}">
      <div class="nimg ph" style="background-image:linear-gradient(rgba(15,17,22,.05),rgba(15,17,22,.22)),url('${imageFor(r)}')">
        <span class="cat">${esc(r.category || r.kind)}</span>
      </div>
      <div class="body">
        <div class="date">${esc(fmtDate(r.starts_at || r.published_at))}</div>
        <h4>${esc(r.title)}</h4>
        <span class="more">Read more &rarr;</span>
      </div>
    </a>`).join('');
  revealSoon();
})();

revealSoon();
