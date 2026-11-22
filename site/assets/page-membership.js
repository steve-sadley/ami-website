/* The grades and this year's fee, exactly as the home page draws them, so the two
   can never disagree about what a grade costs. */
(async () => {
  const box = document.getElementById('grades-out');
  loading(box);
  const year = new Date().getFullYear();
  const [{ data:grades, error }, { data:fees }] = await Promise.all([
    sb.from('public_grades').select('*').order('sort_order'),
    sb.from('public_fees').select('*').eq('year', year),
  ]);
  if (error) return failed(box, error, 'The grades of membership');
  if (!grades || !grades.length) {
    box.innerHTML = `<div class="state glass" style="grid-column:1/-1">
      <p>The grades of membership have not been published yet.</p></div>`;
    return;
  }

  const fee = Object.fromEntries((fees || []).map(f => [f.code, f.fee_pence]));

  // No grade is picked out any more: every card turns red under the pointer
  // instead (site 83, Steve). That is in site.css, .grade:hover.

  box.innerHTML = grades.map(g => `
    <div class="grade glass">
      <span class="tag">${esc(g.name)}</span>
      <h4>${esc(g.post_nominals || g.name)}</h4>
      <p>${esc(g.blurb || 'Recognition of assessed competence in asbestos management.')}</p>
      <div class="price">${money(fee[g.code])}<span>${fee[g.code] != null ? '/yr' : ''}</span></div>
    </div>`).join('');
})();

revealSoon();
