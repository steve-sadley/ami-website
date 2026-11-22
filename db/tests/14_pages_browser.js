/* Does the Pages screen do what it says?

   The admin app is one file with the whole application inline, so the only way
   to test it is to run it. The Supabase client is replaced, and nothing else
   is: the real PAGES, the real rich text editor, the real sanitiser and the
   real save path all run, and what the save WOULD have sent is captured.

   What this is for. The Pages screen is the first screen in this app that is
   not a grid and not the record editor, it writes one row per field rather
   than one row per record, and it is driven by a generated list of 135 fields.
   Reading it is not enough.

   Run:  node tests/14_pages_browser.js [path-to-admin]
*/
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

// The admin bundle, which is beside this bundle rather than under it.
const ROOT = process.argv[2] || require('path').resolve(__dirname, '../../admin');
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) pass++; else { fail++; console.log('  FAIL  ' + what); } };

// What the fake database holds. Three blocks on About: one published, one
// draft, one absent, which are the three states the screen has to show.
const ROWS = [
  { id:'1', page_key:'about', block_key:'banner_heading',
    body:'About the Asbestos Management Institute', items:null,
    status:'published', sort_order:0 },
  { id:'2', page_key:'about', block_key:'intro',
    body:'<p>AMI is the professional body.</p>', items:null,
    status:'draft', sort_order:30 },
  { id:'3', page_key:'about', block_key:'intro_link', body:null,
    items:[{ label:'Explore membership', href:'/membership' }],
    status:'published', sort_order:40 },
  // Two repeating blocks, for the Block List editor added in admin 17.
  { id:'4', page_key:'about', block_key:'glance', body:null,
    items:[{ text:'Membership assessed on evidence' }, { text:'<b>Wholly</b> focused on asbestos' }],
    status:'published', sort_order:60 },
  { id:'5', page_key:'about', block_key:'purpose_cards', body:null,
    items:[{ icon:'award', title:'Recognise', body:'Grades and post nominals.' },
           { icon:'book',  title:'Develop',   body:'CPD and events.' },
           { icon:'shield', title:'Protect',  body:'Standards that protect people.' }],
    status:'published', sort_order:90 },
  { id:'7', page_key:'cpd-scheme', block_key:'counts', body:null,
    items:[{ icon:'award', title:'Core activities', body:'Core words', bullets:['Old core'] },
           { icon:'people', title:'Non core activities', body:'Non core words', bullets:['Old non core'] }],
    status:'published', sort_order:100 },
  { id:'6', page_key:'about', block_key:'banner_photo', body:'/assets/photo-team.webp', items:null,
    status:'published', sort_order:5 },
];

const STUB = `
window.__sent = [];
const rows = ${JSON.stringify(ROWS)};
const res = (data, error) => Promise.resolve({ data, error: error || null });
function table(name){
  const q = {
    _f: {},
    select(){ return q; },
    eq(c, v){ q._f[c] = v; return q; },
    order(){ return q; },
    range(){ return q; },
    limit(){ return q; },
    then(r){
      let d = rows.filter(x => x.page_key !== undefined);
      if (name === 'cpd_activity_types') return res([{ id: 't-tr', name: 'Technical Review' }]).then(r);
      // 0046: the image library, the bundle's five plus one uploaded earlier.
      if (name === 'admin_media_library') return res([
        ...['hero','photo-review','photo-site','photo-survey','photo-team'].map((n, i) => ({ id: 'b' + i,
          path: '/assets/' + n + '.webp', name: 'Built in ' + n, builtin: true, archived: false, fallback: false, uses: [] })),
        { id: 'u1', path: 'library/2026/hall-abc123.webp', name: 'AGM hall', builtin: false, archived: false,
          fallback: false, width: 2000, height: 1300, byte_size: 300000, uses: [] },
        ...(window.__libAdded || []) ]).then(r);
      if (name !== 'page_blocks') d = [];
      Object.entries(q._f).forEach(([c, v]) => { d = d.filter(x => x[c] === v); });
      return res(d).then(r);
    },
    upsert(payload, opts){
      window.__sent.push({ table: name, payload, opts });
      return res(payload);
    },
    insert(p){ window.__sent.push({ table: name, insert: p });
      if (name === 'media_library') window.__libAdded = (window.__libAdded || []).concat([Object.assign(
        { id: 'n' + Date.now(), builtin: false, archived: false, fallback: false, uses: [] }, p)]);
      return res(p); },
    update(p){ window.__sent.push({ table: name, update: p }); return q; },
    delete(){ return q; },
  };
  return q;
}
window.__stubClient = {
  from: table,
  rpc: (fn) => {
    if (fn === 'whoami') return res([{ person_id:'p1', given_name:'Test', family_name:'Editor',
                                       roles:['super_user','administrator','editor'] }]);
    return res(null);
  },
  auth: {
    getSession: () => res({ session: { user: { id:'u1', email:'editor@test.invalid' } } }),
    getUser: () => res({ user: { id:'u1', email:'editor@test.invalid' } }),
    signInWithOtp: () => res({}),
    onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }),
    signInWithPassword: () => res({ user:{ id:'u1' } }),
    signOut: () => res(null),
  },
  storage: { from: bucket => ({
    upload: (p, body, opts) => { window.__ups = (window.__ups || []).concat([{ bucket, path: p,
      type: opts && opts.contentType, size: body.size }]); return res({ path: p }); },
    remove: (ps) => { window.__removed = (window.__removed || []).concat(ps); return res(null); },
  }) },
};
`;

(async () => {
  const srv = await new Promise(r => {
    const s = http.createServer((req, res) => {
      const p = req.url.split('?')[0] === '/' ? '/index.html' : req.url.split('?')[0];
      const f = path.join(ROOT, p);
      if (!f.startsWith(ROOT) || !fs.existsSync(f)) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { 'Content-Type': p.endsWith('.html') ? 'text/html' : 'text/javascript' });
      res.end(fs.readFileSync(f));
    });
    s.listen(0, () => r(s));
  });
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(String(e) + ' ' + (e.stack||'').split('\n').slice(0,3).join(' | ')));

  /* The app builds its client once, lazily, from window.supabase. Replacing
     createClient is the whole of the stand in. */
  await page.addInitScript(STUB + `
    Object.defineProperty(window, 'supabase', { configurable: true,
      value: { createClient: () => window.__stubClient } });
  `);

  await page.goto('http://127.0.0.1:' + srv.address().port + '/index.html');
  await page.waitForTimeout(900);

  ok(errors.length === 0, 'the app loads with no errors: ' + (errors[0] || ''));

  // The gate is passed by the stubbed session, so the app should be showing.
  const shown = await page.evaluate(() => ({
    app: document.getElementById('app').style.display,
    ver: document.getElementById('verTag').textContent,
    nav: [...document.querySelectorAll('#nav button')].map(b => b.textContent),
  }));
  ok(shown.app === 'block', 'the application is showing, not the sign in gate');
  ok(/^v\d+$/.test(shown.ver) && shown.ver !== 'v29', 'the version tag is shown and moves on with each build (19 checks the exact one), got ' + shown.ver);
  ok(shown.nav.includes('Pages'), 'there is a Pages screen in the navigation');
  ok(shown.nav.includes('Page text rows'),
     'the raw table screen is still there for a super user');

  /* Bundle 15 showed "Content" twice in the sidebar, because the navigation
     started a new heading whenever the group changed from the entry before it
     and the new System screen had been left sitting among the Content ones.
     Nothing was broken and it looked like a mistake. */
  const heads = await page.evaluate(() =>
    [...document.querySelectorAll('#nav h4')].map(h => h.textContent));
  ok(heads.length === new Set(heads).size,
     'no group appears twice in the sidebar: ' + heads.join(', '));

  // Open Pages.
  await page.evaluate(() => {
    [...document.querySelectorAll('#nav button')].find(b => b.textContent === 'Pages').click();
  });
  await page.waitForTimeout(250);

  const list = await page.evaluate(() => ({
    rows: [...document.querySelectorAll('.prow h3')].map(h => h.textContent),
    counts: [...document.querySelectorAll('.prow .meta')].map(m => m.textContent),
  }));
  ok(list.rows.length === 16, 'sixteen pages are listed (0065 added three, 0069 the rules, 0070 resources), got ' + list.rows.length);
  ok(list.rows.includes('About AMI') && list.rows.includes('CPD scheme'),
     'the pages are named rather than keyed');
  ok(/\d+ things to say/.test(list.counts[0] || ''), 'each page says how much is on it');

  // Open About.
  await page.evaluate(() => {
    const i = [...document.querySelectorAll('.prow')]
      .findIndex(p => p.querySelector('h3').textContent === 'About AMI');
    document.querySelectorAll('.prow')[i].querySelector('[data-page]').click();
  });
  await page.waitForTimeout(400);

  const form = await page.evaluate(() => ({
    labels: [...document.querySelectorAll('.pgedit label')].map(l => l.textContent.trim()),
    tags: [...document.querySelectorAll('.pgedit .st')].map(s => s.textContent),
    lineVal: document.querySelector('[data-pgline="banner_heading"]')?.value,
    richHtml: document.getElementById('e_intro')?.innerHTML,
    linkVals: [...document.querySelectorAll('[data-lk^="intro_link"]')].map(i => i.value),
    notyet: document.querySelectorAll('.pgedit .notyet').length,
    hasPublish: !!document.getElementById('pgPub'),
  }));

  ok(form.labels.some(l => l.startsWith('Banner heading')),
     'fields carry their own labels, not their keys');
  ok(!form.labels.some(l => /banner_heading/.test(l)),
     'and no label is a key');
  ok(form.lineVal === 'About the Asbestos Management Institute',
     'a published line arrives in its box, got ' + form.lineVal);
  ok((form.richHtml || '').includes('professional body'),
     'a draft body arrives in the rich text editor');
  ok(form.linkVals.slice(0, 2).join('|') === 'Explore membership|/membership',
     'a links block arrives as label and address, got ' + form.linkVals.slice(0, 2).join('|'));
  ok(form.tags.includes('live') && form.tags.includes('draft')
     && form.tags.includes('not published'),
     'every field says whether it is live, a draft, or has never been published');
  ok(form.notyet === 0, 'no repeating block says "not yet" any more');
  ok(form.hasPublish, 'there is a publish button');

  // Nothing changed: a draft save should refuse rather than write.
  await page.evaluate(() => { window.__sent = []; document.getElementById('pgDraft').click(); });
  await page.waitForTimeout(200);
  let after = await page.evaluate(() => ({ sent: window.__sent.length,
                                           msg: document.getElementById('pgMsg').textContent }));
  ok(after.sent === 0 && /nothing has changed/i.test(after.msg),
     'saving with nothing changed writes nothing and says so');

  // Change one line and save as a draft. ONLY that field may be sent.
  await page.evaluate(() => {
    const i = document.querySelector('[data-pgline="banner_heading"]');
    i.value = 'About the Institute';
    i.dispatchEvent(new Event('input'));
    window.__sent = [];
    document.getElementById('pgDraft').click();
  });
  await page.waitForTimeout(300);

  const draft = await page.evaluate(() => window.__sent);
  ok(draft.length === 1, 'one write, got ' + draft.length);
  ok(draft[0] && draft[0].table === 'page_blocks', 'into page_blocks');
  ok(draft[0] && draft[0].opts && draft[0].opts.onConflict === 'page_key,block_key',
     'as an upsert keyed on the page and the block');
  const sent = draft[0] ? draft[0].payload : [];
  ok(sent.length === 1, 'ONLY the field that changed is sent, got ' + sent.length);
  ok(sent[0] && sent[0].block_key === 'banner_heading' && sent[0].status === 'draft'
     && sent[0].body === 'About the Institute',
     'with the new words and a draft status: ' + JSON.stringify(sent[0] || {}));
  ok(sent[0] && sent[0].items === null, 'and no items on a prose block');

  // Publish. The changed field goes, AND the draft that was already there.
  await page.evaluate(() => {
    const i = document.querySelector('[data-pgline="banner_heading"]');
    i.value = 'About AMI the body';
    i.dispatchEvent(new Event('input'));
    window.__sent = [];
    document.getElementById('pgPub').click();
  });
  await page.waitForTimeout(300);

  const pub = await page.evaluate(() => window.__sent);
  const keys = pub.length ? pub[0].payload.map(r => r.block_key + ':' + r.status) : [];
  ok(keys.includes('banner_heading:published'), 'publishing sends the change as published');
  ok(keys.includes('intro:published'),
     'AND publishes the draft that was already on the page, so the page is one vintage: '
     + keys.join(', '));
  ok(!keys.includes('intro_link:published'),
     'but does not rewrite a block that was already live and untouched');

  // An emptied field must be refused rather than saved as a gap in the page.
  await page.evaluate(() => {
    const i = document.querySelector('[data-pgline="banner_heading"]');
    i.value = '   ';
    i.dispatchEvent(new Event('input'));
    window.__sent = [];
    document.getElementById('pgDraft').click();
  });
  await page.waitForTimeout(250);
  after = await page.evaluate(() => ({ sent: window.__sent.length,
                                       msg: document.getElementById('pgMsg').textContent }));
  ok(after.sent === 0 && /cannot be left empty/i.test(after.msg),
     'an emptied field is refused, because every one of these is on the page: ' + after.msg);


  /* =====================================================================
     THE BLOCK LIST EDITOR, admin 17
     ===================================================================== */
  page.on('dialog', d => d.accept());
  // Through the screen, the way a person gets there. The app's functions are
  // not on window, and a test that reached round the screen to call them would
  // be testing something nobody can do.
  const openVia = async title => {
    await page.evaluate(() =>
      [...document.querySelectorAll('#nav button')].find(b => b.textContent === 'Pages').click());
    await page.waitForTimeout(250);
    await page.evaluate(t => {
      const row = [...document.querySelectorAll('.prow')].find(p => p.querySelector('h3').textContent === t);
      row.querySelector('[data-page]').click();
    }, title);
    await page.waitForTimeout(350);
  };
  const reopen = () => openVia('About AMI');
  const saveAs = async which => {
    await page.evaluate(w => { window.__sent = []; document.getElementById(w).click(); }, which);
    await page.waitForTimeout(300);
    return page.evaluate(() => ({ sent: window.__sent,
                                  msg: document.getElementById('pgMsg').textContent }));
  };
  await reopen();

  const lists = await page.evaluate(() => ({
    boxes: [...document.querySelectorAll('.lst')].map(b => b.id),
    cards: [...document.querySelectorAll('#ls_purpose_cards .it')].length,
    on: [...document.querySelectorAll('#ls_purpose_cards .it')].map(it =>
          (it.querySelector('.ic.on') || {}).title),
    icons: document.querySelectorAll('#ls_purpose_cards .it:first-child .ic').length,
    title0: document.querySelector('[data-iv="purpose_cards:0:title"]')?.value,
    bullets: [...document.querySelectorAll('#ls_glance [data-inl]')].map(d => d.innerHTML),
    addCards: document.querySelector('[data-add="purpose_cards"]')?.textContent.trim(),
    help: document.querySelector('#ls_purpose_cards')?.previousElementSibling?.textContent,
  }));
  // SHOT=dir writes a picture of the editor, for looking at rather than asserting on.
  if (process.env.SHOT) {
    await page.setViewportSize({ width: 1400, height: 900 });
    await page.evaluate(() => document.getElementById('ls_glance').scrollIntoView());
    await page.screenshot({ path: path.join(process.env.SHOT, 'pages-lists.png'), fullPage: false });
    await page.evaluate(() => document.getElementById('ls_purpose_cards').scrollIntoView());
    await page.screenshot({ path: path.join(process.env.SHOT, 'pages-cards.png'), fullPage: false });
  }
  ok(lists.boxes.includes('ls_glance') && lists.boxes.includes('ls_purpose_cards'),
     'both repeating blocks open as editors: ' + lists.boxes.join(', '));
  ok(lists.cards === 3, 'three purpose cards, got ' + lists.cards);
  ok(lists.on.join() === 'award,book,shield', 'each card shows its own icon chosen: ' + lists.on.join());
  ok(lists.icons === 15, 'from a set of fifteen, got ' + lists.icons);
  ok(lists.title0 === 'Recognise', 'a heading arrives in its box');
  ok(lists.bullets[1] === '<b>Wholly</b> focused on asbestos', 'bold in a bullet arrives as bold: ' + lists.bullets[1]);
  ok(/3 cards/.test(lists.addCards || ''), 'a grid three across adds three at a time: ' + lists.addCards);
  ok(/in threes/.test(lists.help || ''), 'and says why');

  // Untouched lists are not sent: change a line only.
  await page.evaluate(() => {
    const i = document.querySelector('[data-pgline="glance_heading"]');
    i.value = 'At a glance, again'; i.dispatchEvent(new Event('input'));
  });
  let r = await saveAs('pgDraft');
  ok(r.sent[0] && r.sent[0].payload.length === 1 && r.sent[0].payload[0].block_key === 'glance_heading',
     'changing a line sends the line and not the lists beside it');

  // Reorder, change an icon, reword. Exactly one row, in the new order.
  await reopen();
  await page.evaluate(() => {
    document.querySelector('[data-mv="purpose_cards:0:1"]').click();           // Recognise down
  });
  await page.evaluate(() => {
    document.querySelector('[data-ic="purpose_cards:0:icon"][data-name="target"]').click();
    const t = document.querySelector('[data-iv="purpose_cards:2:title"]');
    t.value = '  Protect people  '; t.dispatchEvent(new Event('input'));
  });
  const numbering = await page.evaluate(() =>
    [...document.querySelectorAll('#ls_purpose_cards .ih b')].map(b => b.textContent));
  ok(numbering.join() === 'Card 1,Card 2,Card 3', 'the numbers are positions and stay in order');
  r = await saveAs('pgDraft');
  const row = r.sent[0] && r.sent[0].payload.find(x => x.block_key === 'purpose_cards');
  ok(r.sent[0] && r.sent[0].payload.length === 1 && !!row, 'one row sent, the list');
  ok(row && row.body === null && row.status === 'draft', 'as items, as a draft');
  ok(row && row.items.map(i => i.title).join() === 'Develop,Recognise,Protect people',
     'in the new order, trimmed: ' + (row ? row.items.map(i => i.title).join() : ''));
  ok(row && row.items[0].icon === 'target' && row.items[1].icon === 'award',
     'the icon chosen went with its own card, and the moved card kept its own');
  ok(row && row.items.every(i => Object.keys(i).every(k => ['icon','title','body'].includes(k))),
     'and nothing but the fields a purpose card has');

  // Add three, leave them blank: refused, naming the card and the field.
  await reopen();
  await page.evaluate(() => document.querySelector('[data-add="purpose_cards"]').click());
  const six = await page.evaluate(() => ({
    n: document.querySelectorAll('#ls_purpose_cards .it').length,
    addOff: document.querySelector('[data-add="purpose_cards"]').disabled,
  }));
  ok(six.n === 6, 'adding gives six, got ' + six.n);
  ok(six.addOff, 'and at the maximum the add button is off');
  r = await saveAs('pgPub');
  ok(r.sent.length === 0 && /card 4: the heading is empty/i.test(r.msg),
     'blank new cards are refused with the card named: ' + r.msg);

  // Remove one of the new ones: a whole row goes, back to three.
  await page.evaluate(() => document.querySelector('[data-rm="purpose_cards:4"]').click());
  const back = await page.evaluate(() => ({
    titles: [...document.querySelectorAll('#ls_purpose_cards [data-iv$=":title"]')].map(i => i.value),
    rmOff: [...document.querySelectorAll('[data-rm^="purpose_cards"]')].every(b => b.disabled),
  }));
  ok(back.titles.join() === 'Recognise,Develop,Protect',
     'removing one in a grid three across takes the row, leaving the original three: ' + back.titles.join());
  ok(back.rmOff, 'and at the minimum nothing can be removed');

  // A bad address on a card is refused before anything is sent. Support's
  // resource cards are whole links, so they carry one.
  await openVia('Support and guidance');
  await page.evaluate(() => document.querySelector('[data-add="resources"]').click());
  const res3 = await page.evaluate(() => document.querySelectorAll('#ls_resources .it').length);
  ok(res3 === 3, 'support has no rows in the fake database, so one press gives a row of three: ' + res3);
  await page.evaluate(() => {
    [0, 1, 2].forEach(i => {
      const set = (f, v) => { const e = document.querySelector(`[data-iv="resources:${i}:${f}"]`);
                              e.value = v; e.dispatchEvent(new Event('input')); };
      set('title', 'T' + i); set('body', 'B' + i);
      set('href', i === 1 ? 'javascript:alert(1)' : '/news');
    });
  });
  r = await saveAs('pgDraft');
  ok(r.sent.length === 0 && /card 2: "javascript:alert\(1\)" is not an address/i.test(r.msg),
     'a javascript: address is refused with the card named: ' + r.msg);
  await page.evaluate(() => {
    const e = document.querySelector('[data-iv="resources:1:href"]');
    e.value = '//evil.example'; e.dispatchEvent(new Event('input'));
  });
  r = await saveAs('pgDraft');
  ok(r.sent.length === 0 && /is not an address/.test(r.msg), 'and so is //evil.example, another host dressed as a path');

  // Bullets: markup is cleaned to inline only, empty ones dropped, one removed.
  await reopen();
  await page.evaluate(() => {
    document.querySelector('[data-rm="glance:0"]').click();          // confirm accepted
    document.querySelector('[data-add="glance"]').click();
  });
  await page.evaluate(() => {
    const d = document.querySelector('[data-inl="glance:1:text"]');
    d.innerHTML = '<p>New <strong>one</strong></p><img src="data:,"><ul><li>in</li></ul>';
    d.dispatchEvent(new Event('input'));
  });
  r = await saveAs('pgDraft');
  const g = r.sent[0] && r.sent[0].payload.find(x => x.block_key === 'glance');
  ok(g && g.items.length === 2, 'one removed and one added is still two: ' + (g ? g.items.length : r.msg));
  ok(g && g.items[0].text === '<b>Wholly</b> focused on asbestos', 'the remaining bullet is unchanged');
  ok(g && g.items[1].text === 'New <strong>one</strong>in',
     'a pasted paragraph, image and list are reduced to words and bold: ' + (g ? g.items[1].text : ''));

  // The CSCS cards: a button needs both halves.
  await openVia('CSCS cards');
  await page.evaluate(() => document.querySelector('[data-add="cards"]').click());
  const cscs = await page.evaluate(() => ({
    fields: [...document.querySelectorAll('#ls_cards .it:first-child .il')].map(l => l.textContent),
    addOn: !!document.querySelector('[data-add="cards"]'),
  }));
  ok(cscs.fields.join('|') === 'Icon|Heading|Words optional|Bullets optional|Button label|Links to',
     'a CSCS card offers its parts in page order, words and bullets optional: ' + cscs.fields.join('|'));

  // A list whose count is the design offers no add and no remove.
  await openVia('Membership');
  const steps = await page.evaluate(() => ({
    add: !!document.querySelector('[data-add="steps"]'),
    rm: document.querySelectorAll('[data-rm^="steps"]').length,
    faqAdd: document.querySelector('[data-add="faq"]')?.textContent.trim(),
  }));
  ok(!steps.add && steps.rm === 0, 'the joining steps can be reworded and reordered, not added to or removed');
  ok(steps.faqAdd === 'Add a question', 'questions are added one at a time: ' + steps.faqAdd);

  /* ---------------------------------------------------------------------
     THE PAGE PHOTOGRAPHS, admin 18
     --------------------------------------------------------------------- */
  await page.route('**/*.webp', r => r.fulfill({ contentType: 'image/png',
    body: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==', 'base64') }));
  await reopen();
  const ph = await page.evaluate(() => ({
    preview: document.getElementById('pv_banner_photo')?.style.backgroundImage || '',
    name: document.getElementById('pn_banner_photo')?.textContent || '',
    fields: [...document.querySelectorAll('.ph1')].map(x => x.id),
    stockButtons: document.querySelectorAll('[data-stock]').length,
  }));
  if (process.env.SHOT) {
    await page.evaluate(() => document.getElementById('ph_banner_photo').scrollIntoView({ block: 'center' }));
    await page.screenshot({ path: path.join(process.env.SHOT, 'pages-photo.png') });
  }
  ok(ph.fields.includes('ph_banner_photo') && ph.fields.includes('ph_practice_photo'),
     'About has its banner and its best practice photograph as fields: ' + ph.fields.join(', '));
  ok(/photo-team\.webp/.test(ph.preview) && ph.name === 'Built in photo-team',
     'the banner shows the photograph it has now, by its library name: ' + ph.name);
  ok(ph.stockButtons === 0, 'the field no longer carries its own row of photographs: the library does');

  // 0046: choosing opens the library.
  await page.evaluate(() => document.querySelector('[data-pickphoto="banner_photo"]').click());
  await page.waitForTimeout(400);
  const lib = await page.evaluate(() => ({
    on: document.getElementById('libpick').classList.contains('on'),
    items: [...document.querySelectorAll('#lpGrid [data-libpath]')].map(b => b.dataset.libpath),
    marked: (document.querySelector('#lpGrid .libitem.on') || {}).dataset?.libpath }));
  ok(lib.on && lib.items.length === 6 && lib.items.includes('library/2026/hall-abc123.webp'),
     'Choose opens the library: the five built in and the one uploaded: ' + lib.items.length);
  ok(lib.marked === '/assets/photo-team.webp', 'with the current photograph marked');
  await page.fill('#lpSearch', 'hall');
  await page.waitForTimeout(200);
  ok((await page.evaluate(() => document.querySelectorAll('#lpGrid [data-libpath]').length)) === 1, 'and it can be searched by name');
  await page.evaluate(() => document.querySelector('#lpGrid [data-libpath="library/2026/hall-abc123.webp"]').click());
  await page.waitForTimeout(200);
  ok(!(await page.evaluate(() => document.getElementById('libpick').classList.contains('on')))
     && (await page.evaluate(() => document.getElementById('pn_banner_photo').textContent)) === 'AGM hall',
     'picking one closes the library and the field names it');
  r = await saveAs('pgDraft');
  let bp = r.sent[0] && r.sent[0].payload.find(x => x.block_key === 'banner_photo');
  ok(r.sent[0] && r.sent[0].payload.length === 1 && bp && bp.body === 'library/2026/hall-abc123.webp' && bp.items === null,
     'saving sends that one address: ' + JSON.stringify(bp || r.msg));

  // Uploading from the chooser: converted, stored under library/, named, chosen.
  await reopen();
  await page.evaluate(() => { window.__ups = []; window.__sent = []; });
  await page.evaluate(() => document.querySelector('[data-pickphoto="banner_photo"]').click());
  await page.waitForTimeout(300);
  await page.setInputFiles('#lpFile', path.join(__dirname, 'fixtures', 'phone.jpg'));
  for (let n = 0; n < 40; n++) {
    await page.waitForTimeout(150);
    if (await page.evaluate(() => !document.getElementById('libpick').classList.contains('on'))) break;
  }
  const up = await page.evaluate(() => ({ ups: window.__ups, ins: (window.__sent.find(x => x.table === 'media_library') || {}).insert,
                                          name: document.getElementById('pn_banner_photo').textContent }));
  ok(up.ups.length === 1 && up.ups[0].bucket === 'public-media'
     && /^library\/\d{4}\/phone-[a-z0-9]{6}\.(webp|jpg)$/.test(up.ups[0].path),
     'an upload goes to public-media under library/: ' + JSON.stringify(up.ups[0] || null));
  ok(up.ups[0] && up.ups[0].type === 'image/webp', 'converted to WebP first');
  ok(up.ins && up.ins.path === (up.ups[0] || {}).path && up.ins.name === 'phone' && up.ins.width === 1500,
     'and named in the library with its size: ' + JSON.stringify(up.ins || null));
  ok(up.name === 'phone', 'and chosen for the field straight away');
  r = await saveAs('pgPub');
  bp = r.sent.find(x => x.payload) && r.sent.find(x => x.payload).payload.find(x => x.block_key === 'banner_photo');
  ok(bp && up.ups[0] && bp.body === up.ups[0].path && bp.status === 'published',
     'publishing sends the uploaded picture\'s path');

  await reopen();
  await page.evaluate(() => { window.__ups = []; });
  await page.evaluate(() => document.querySelector('[data-pickphoto="banner_photo"]').click());
  await page.waitForTimeout(300);
  await page.setInputFiles('#lpFile', path.join(__dirname, 'fixtures', 'small.jpg'));
  await page.waitForTimeout(800);
  const small = await page.evaluate(() => ({ ups: window.__ups.length, msg: document.getElementById('lpMsg').textContent,
                                             open: document.getElementById('libpick').classList.contains('on') }));
  ok(small.ups === 0 && /640 pixels wide/.test(small.msg) && small.open,
     'a picture too small is refused in the library there and then: ' + small.msg);
  await page.evaluate(() => document.getElementById('lpCancel').click());

  // The CPD scheme page's two cards: their bullets come from CPD activity types.
  await openVia('CPD scheme');
  const counts = await page.evaluate(() => {
    const box = document.getElementById('ls_counts');
    return box ? { arrows: box.querySelectorAll('[data-mv]').length,
                   note: [...box.querySelectorAll('.notyet')].map(n => n.textContent.replace(/\s+/g, ' ').trim()),
                   bulletEditors: box.querySelectorAll('[data-inl*=":bullets"]').length } : null;
  });
  ok(counts && counts.arrows === 0, 'the two CPD cards cannot be reordered: core first, non core second');
  ok(counts && counts.bulletEditors === 0 && counts.note.some(t => /CPD activity types/.test(t)),
     'and their bullets are not offered as a box that would be ignored, but say where they come from');
  // Rewording a card keeps its stored bullets, which the page falls back to if
  // the live list cannot be read.
  await page.evaluate(() => {
    const t = document.querySelector('[data-iv="counts:0:title"]');
    t.value = 'Core activities, 2027'; t.dispatchEvent(new Event('input'));
  });
  const cs = await saveAs('pgDraft');
  const crow = cs.sent[0] && cs.sent[0].payload.find(x => x.block_key === 'counts');
  ok(crow && crow.items[0].title === 'Core activities, 2027' && crow.items[0].bullets[0] === 'Old core',
     'rewording a card saves the words and keeps the stored list underneath: ' + JSON.stringify(crow ? crow.items[0] : cs.msg));

  /* ---------------------------------------------------------------------
     CPD TO READ AND WATCH, admin 21: the questions editor
     --------------------------------------------------------------------- */
  await page.evaluate(() =>
    [...document.querySelectorAll('#nav button')].find(b => b.textContent === 'CPD to read and watch').click());
  await page.waitForTimeout(300);
  await page.evaluate(() => document.getElementById('addRow').click());
  await page.waitForTimeout(300);
  const qe = await page.evaluate(() => ({
    quiz: !!document.getElementById('quiz_questions'),
    counts: [...document.querySelectorAll('#e_activity_type_id option')].length,
  }));
  ok(qe.quiz, 'the item editor has a questions editor');
  await page.evaluate(() => {
    const set = (id, v) => { const e = document.getElementById(id); e.value = v; e.dispatchEvent(new Event('input')); };
    set('e_title', 'TEST review'); set('e_slug', 'test-review');
    document.querySelector('[data-qadd]').click();
  });
  await page.evaluate(() => {
    const set = (sel, v) => { const e = document.querySelector(sel); e.value = v; e.dispatchEvent(new Event('input')); };
    set('[data-qq="0"]', 'Which regulation?');
    set('[data-qo="0:0"]', 'CAR 2012');
    set('[data-qo="0:1"]', '');
    document.querySelector('[data-qoadd="0"]').click();
  });
  await page.evaluate(() => {
    const set = (sel, v) => { const e = document.querySelector(sel); e.value = v; e.dispatchEvent(new Event('input')); };
    set('[data-qo="0:2"]', 'COSHH');
    const r = document.querySelector('[data-qa="0:2"]'); r.checked = true; r.dispatchEvent(new Event('change'));
    window.__sent = [];
    document.getElementById('dSave').click();
  });
  await page.waitForTimeout(300);
  let qs = await page.evaluate(() => ({ msg: document.getElementById('dMsg').textContent,
    ins: (window.__sent.find(x => x.insert) || {}).insert }));
  ok(!qs.ins && /Counts as is needed/.test(qs.msg), 'it will not save without the activity it counts as: ' + qs.msg);
  ok(qe.counts === 2, 'which offers the activity types to choose from');
  await page.evaluate(() => {
    const e = document.getElementById('e_activity_type_id'); e.value = 't-tr'; e.dispatchEvent(new Event('change'));
    window.__sent = [];
    document.getElementById('dSave').click();
  });
  await page.waitForTimeout(300);
  qs = await page.evaluate(() => ({ msg: document.getElementById('dMsg').textContent,
    ins: (window.__sent.find(x => x.insert) || {}).insert }));
  ok(qs.ins && JSON.stringify(qs.ins.questions)
       === JSON.stringify([{ q: 'Which regulation?', options: ['CAR 2012', 'COSHH'], answer: 1 }]),
     'the blank answer is dropped and the right answer moves with it: ' + JSON.stringify(qs.ins && qs.ins.questions));
  ok(qs.ins && qs.ins.activity_type_id === 't-tr' && qs.ins.title === 'TEST review', 'with the rest of the item');

  ok(errors.length === 0, 'no errors anywhere in the editor: ' + (errors[0] || ''));

  await browser.close();
  srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
