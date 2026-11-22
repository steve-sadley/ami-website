/* The sign in page's ?next= only ever sends somebody to a page on this site.
   Run: node 50_login_next_path.mjs
   Found by the security check on 31 October: /<tab>/evil.example passed the
   old check, and browsers drop the tab, giving //evil.example. */
import fs from 'node:fs';
const src = fs.readFileSync(new URL('../../site/assets/page-login.js', import.meta.url), 'utf8');
const fn = src.match(/function nextPath\(\)\{[\s\S]*?\n\}/)[0];
let pass = 0, fail = 0;
const ok = (c, w) => { if (c) pass++; else { fail++; console.log('  FAIL  ' + w); } };
const nextPath = raw => new Function('qs', 'location', fn + '; return nextPath();')(() => raw, { origin: 'https://staging.ami.uk.com' });
// what the page receives once URLSearchParams has decoded the address
for (const [raw, want] of [
  ['/cpd', '/cpd'], ['/cpd?year=2027#top', '/cpd?year=2027#top'], ['/me', '/me'], [null, '/me'], ['', '/me'],
  ['//evil.example', '/me'], ['https://evil.example', '/me'], ['/\\evil.example', '/me'], ['\\/evil.example', '/me'],
  ['/\t/evil.example', '/me'], ['/\n/evil.example', '/me'], ['/\r/evil.example', '/me'], ['/x\t/y', '/me'],
  ['javascript:alert(1)', '/me'], ['/%2F/evil.example', '/%2F/evil.example'], ['/ /evil.example', '/%20/evil.example'],
]) {
  const got = nextPath(raw);
  ok(got === want, `${JSON.stringify(raw)} goes to ${got}, expected ${want}`);
  ok(new URL(got, 'https://staging.ami.uk.com').origin === 'https://staging.ami.uk.com', `${JSON.stringify(raw)} stays on the site`);
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
