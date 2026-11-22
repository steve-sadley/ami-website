/* Site 87: a video plays from Vimeo or YouTube, whatever shape of address the
   office pasted, and nothing else becomes a player address.

   videoEmbed() lives in site.js, which is written for the browser, so the one
   function is lifted out by name and run here on its own.

   Run:  node tests/72_video_embed.js [SITE_DIR]                               */
const fs = require('fs'), path = require('path');
const SITE = process.argv[2] || path.resolve(__dirname, '../../site');
const src = fs.readFileSync(path.join(SITE, 'assets/site.js'), 'utf8');
const start = src.indexOf('function videoEmbed(');
const body = src.slice(start, src.indexOf('\n}\n', start) + 2);
const videoEmbed = new Function(body + '\nreturn videoEmbed;')();
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) pass++; else { fail++; console.log('  FAIL  ' + what); } };

const YT = 'https://www.youtube-nocookie.com/embed/Sv42d-UJy6U?rel=0';
const VM = 'https://player.vimeo.com/video/123456789';
for (const [input, want] of [
  ['youtube.com/watch?v=Sv42d-UJy6U&feature=youtu.be', YT],   // what the office pasted on staging
  ['https://www.youtube.com/watch?v=Sv42d-UJy6U', YT],
  ['https://www.youtube.com/watch?feature=share&v=Sv42d-UJy6U', YT],
  ['https://youtu.be/Sv42d-UJy6U?si=abc', YT],
  ['https://www.youtube.com/embed/Sv42d-UJy6U', YT],
  ['https://youtube.com/shorts/Sv42d-UJy6U', YT],
  ['https://m.youtube.com/watch?v=Sv42d-UJy6U', YT],
  ['  Sv42d-UJy6U  ', YT],
  ['123456789', VM],
  ['https://vimeo.com/123456789', VM],
  ['vimeo.com/123456789?share=copy', VM],
  ['https://player.vimeo.com/video/123456789', VM],
  // unlisted Vimeo, as the November 2023 webinar recordings are
  ['https://vimeo.com/886369969/397afd4730', 'https://player.vimeo.com/video/886369969?h=397afd4730'],
  ['https://vimeo.com/886369969/397afd4730?share=copy', 'https://player.vimeo.com/video/886369969?h=397afd4730'],
]) ok(videoEmbed(input) === want, `${input.trim()} plays, got ${videoEmbed(input)}`);

ok(videoEmbed('youtu.be/Sv42d-UJy6U', true) === YT + '&autoplay=1', 'autoplay is added for the library overlay (YouTube)');
ok(videoEmbed('123456789', true) === VM + '?autoplay=1', 'and for Vimeo');
ok(videoEmbed('vimeo.com/886369969/397afd4730', true) === 'https://player.vimeo.com/video/886369969?h=397afd4730&autoplay=1', 'and for unlisted Vimeo, code kept');

for (const bad of ['', null, 'https://evil.example/embed/Sv42d-UJy6U', 'javascript:alert(1)',
                   'https://www.youtube.com.evil.example/watch?v=Sv42d-UJy6U', 'youtube.com/watch?v=short',
                   'https://vimeo.com/12', '"><script>', 'https://notyoutube.com/watch?v=Sv42d-UJy6U'])
  ok(videoEmbed(bad) === null, `${JSON.stringify(bad)} gives no player`);

const headers = fs.readFileSync(path.join(SITE, '_headers'), 'utf8');
ok(/frame-src https:\/\/player\.vimeo\.com https:\/\/www\.youtube-nocookie\.com;/.test(headers),
   'the content security policy lets both players in, and nothing else');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
