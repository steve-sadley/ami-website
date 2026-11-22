
/* The register is read in one go and searched in the browser. That is the right
   trade at this size: a few hundred rows is a small download and it makes the
   search instant, with no round trip per keystroke. If the register passes a few
   thousand this becomes a server side query, and the place to change it is here. */
const PER = 25;
let all = [], shown = [], page = 1;

const out   = document.getElementById('out'),
      pager = document.getElementById('pager'),
      qBox  = document.getElementById('q'),
      gBox  = document.getElementById('grade'),
      nBox  = document.getElementById('n');

// A search that survives a reload, and that the home page can link straight into.
qBox.value = qs('q') || '';

(async () => {
  loading(out);
  const [{ data:rows, error }, { data:grades }] = await Promise.all([
    sb.from('public_register').select('*').order('family_name').order('given_name'),
    sb.from('public_grades').select('code,name').order('sort_order'),
  ]);
  if (error) return failed(out, error, 'The register');
  all = rows || [];
  (grades || []).forEach(g => gBox.insertAdjacentHTML('beforeend',
    `<option value="${esc(g.name)}">${esc(g.name)}</option>`));
  if (qs('grade')) gBox.value = qs('grade');
  draw();
})();

qBox.oninput  = () => { page = 1; draw(); syncUrl(); };
gBox.onchange = () => { page = 1; draw(); syncUrl(); };

function syncUrl(){
  const u = new URL(location);
  qBox.value ? u.searchParams.set('q', qBox.value) : u.searchParams.delete('q');
  gBox.value ? u.searchParams.set('grade', gBox.value) : u.searchParams.delete('grade');
  history.replaceState(null, '', u);
}

// The badge colour says which grade at a glance. Anything the office adds later
// that is not one of the three named grades still gets a badge rather than
// nothing, which is why the fallback exists.
function gradeClass(name){
  const g = String(name || '').toLowerCase();
  if (g.includes('fellow'))    return 'rt-fellow';
  if (g.includes('associate')) return 'rt-assoc';
  if (g.includes('member'))    return 'rt-full';
  return 'rt-cpq';
}

function draw(){
  const term = qBox.value.trim().toLowerCase(), grade = gBox.value;
  shown = all.filter(r =>
    (!grade || r.grade === grade) &&
    (!term || [r.given_name, r.family_name, r.membership_number, r.employer, r.grade]
      .filter(Boolean).join(' ').toLowerCase().includes(term)));

  if (!all.length) {
    nBox.textContent = '';
    out.innerHTML = `<div class="state glass"><p>There is nobody on the register yet.</p></div>`;
    pager.innerHTML = ''; return;
  }
  if (!shown.length) {
    nBox.textContent = `0 of ${all.length} members`;
    out.innerHTML = `<div class="state glass"><p>Nothing matches that. Try a surname, or part
      of a membership number.</p></div>`;
    pager.innerHTML = ''; return;
  }

  const pages = Math.ceil(shown.length / PER);
  page = Math.min(page, pages);
  const from = (page - 1) * PER, rows = shown.slice(from, from + PER);

  nBox.innerHTML = shown.length === all.length
    ? `Showing <b>${from + 1}&ndash;${from + rows.length}</b> of ${all.length} members`
    : `Showing <b>${from + 1}&ndash;${from + rows.length}</b> of ${shown.length} matching,
       from ${all.length} members`;

  out.innerHTML = `
    <div class="reg-wrap glass">
      <table class="rtable">
        <thead><tr>
          <th scope="col">Number</th><th scope="col">Name</th><th scope="col">Employer</th>
          <th scope="col">Grade</th><th scope="col">Member since</th>
        </tr></thead>
        <tbody>${rows.map(row).join('')}</tbody>
      </table>
    </div>`;

  drawPager(pages);
}

function row(r){
  // A slug is only present when the member has a public profile page. Without one
  // the name is plain text rather than a link that goes nowhere.
  const name = `<b>${esc(withPost(r))}</b>`;
  return `<tr>
    <td class="rref">${esc(r.membership_number || '')}</td>
    <td><div class="rname">
      <span class="rav">${esc(initials(r))}</span>
      ${r.slug ? `<a href="/m/${encodeURIComponent(r.slug)}">${name}</a>` : name}
    </div></td>
    <td>${esc(r.employer || '')}</td>
    <td><span class="rtype ${gradeClass(r.grade)}">${esc(r.grade || '')}</span></td>
    <td class="rjoined">${esc(r.joined_year || '')}</td>
  </tr>`;
}

// The numbers are drawn by drawPages in site.js, shared with the other lists.
function drawPager(pages){
  drawPages(pager, pages, page, n => { page = n; draw(); });
}
