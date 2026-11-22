
const hero = document.getElementById('hero'), out = document.getElementById('out');

(async () => {
  loading(out);
  const { data, error } = await sb.from('public_content').select('*')
    .eq('kind', 'video').order('published_at', { ascending:false });
  if (error) return failed(out, error, 'The video library');

  const rows = data || [];
  if (!rows.length) {
    hero.innerHTML = '';
    out.innerHTML = `<div class="state glass" style="grid-column:1/-1">
      <p>No recordings have been published yet. Webinar and AGM sessions appear here as soon
         as they are released.</p></div>`;
    return;
  }

  const [first, ...rest] = rows;

  hero.innerHTML = `
    <div class="vhero glass" data-vimeo="${esc(first.vimeo_id || '')}" data-title="${esc(first.title)}"
         role="button" tabindex="0">
      <div class="vthumb ph" style="background-image:url('${imageFor(first)}')">
        <div class="playbtn"><svg viewBox="0 0 24 24" fill="#fff" aria-hidden="true"><path d="M8 5v14l11-7z"/></svg></div>
      </div>
      <div class="vhero-txt">
        <div class="vcat">Featured${first.category ? ' &bull; ' + esc(first.category) : ''}</div>
        <h2>${esc(first.title)}</h2>
        <p>${esc(first.summary || '')}</p>
        <span class="btn btn-p" style="align-self:flex-start">&#9654;&nbsp; Watch now</span>
      </div>
    </div>`;

  out.innerHTML = rest.length ? rest.map(r => `
    <div class="vcard glass" data-vimeo="${esc(r.vimeo_id || '')}" data-title="${esc(r.title)}"
         role="button" tabindex="0">
      <div class="vthumb ph" style="background-image:url('${imageFor(r)}')">
        <div class="playbtn sm"><svg viewBox="0 0 24 24" fill="#fff" aria-hidden="true"><path d="M8 5v14l11-7z"/></svg></div>
      </div>
      <div class="vbody">
        <div class="vcat">${esc(r.category || 'Recording')}</div>
        <h4>${esc(r.title)}</h4>
      </div>
    </div>`).join('')
    : `<div class="state glass" style="grid-column:1/-1">
         <p>This is the only recording published so far.</p></div>`;
})();

/* One listener on the document rather than one per card, because the cards are
   drawn after this script runs and a listener attached to something that does not
   exist yet attaches to nothing. */
const modal = document.getElementById('vmodal'), frame = document.getElementById('vframe');

function open_(el){
  // Vimeo or YouTube, whatever the office pasted (videoEmbed in site.js). A
  // recording with nothing playable has nothing to show. Sending somebody to an
  // empty player is worse than saying so.
  const src = videoEmbed(el.dataset.vimeo, true);
  if (!src) { location.href = '/news?kind=video'; return; }
  frame.src = src;
  frame.title = el.dataset.title || 'AMI video';
  modal.classList.add('open');
  document.body.style.overflow = 'hidden';
  document.getElementById('vclose').focus();
}

// Emptying the source is what actually stops the sound. Hiding the overlay does
// not, and a video still playing behind a closed dialog is the fault everybody
// notices.
function close_(){
  modal.classList.remove('open');
  frame.src = '';
  document.body.style.overflow = '';
}

document.addEventListener('click', e => {
  const card = e.target.closest('[data-vimeo]');
  if (card) return open_(card);
  if (e.target.id === 'vclose' || e.target === modal) close_();
});
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && modal.classList.contains('open')) close_();
  if ((e.key === 'Enter' || e.key === ' ') && e.target.dataset && e.target.dataset.vimeo !== undefined) {
    e.preventDefault(); open_(e.target);
  }
});
