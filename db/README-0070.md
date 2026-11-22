# 0070 and the old site's content

Database 58, site 89, admin 51. Steve, 22 November 2026: bring the old
ami.uk.com's news, events, videos and support pages into the new site.

## What came across

- **News: 36 stories**, 2015 to October 2026, word for word, each with its
  picture (now `/assets/news-*.webp`) and its original date. New, cleaner
  addresses; every old one redirects. The 4th AGM story was already on the
  new site (entered by the office) and was not imported twice.
- **Videos: 29 presentations** from the seven AGM and webinar pages, one
  entry each, the event as the category. All YouTube except the November 2023
  webinar, which is unlisted Vimeo (site 88 plays both; site 89 keeps the
  Vimeo code). The office's single test entry for the 1st AGM was replaced by
  its four presentations.
- **Event: 1**, the 26 November 2026 seminar (the old Events page held no
  others).
- **Support pages: /resources**, Publications and useful links (0070): HSE
  publications, the Asbestos Network appendices (two PDFs were on the old site
  and are now in assets), the ATaC personal monitoring form (Excel, in
  assets), useful links, and Croner HR support. The Support page's HSE card
  now leads there. The old discussion forum page was not brought across; the
  new site has its own forum.

Everything imported is marked as already announced, so the daily email did
not send members years of old news.

## How

Captured in the built-in browser on Steve's Mac (the container and the Mac's
shell cannot reach ami.uk.com), tidied by `db/tools/old-site-import.py`, and
written to `db/seeds/old-site-import.sql` (safe twice). Run on staging through
the Supabase connection, then checked: every article's title, summary, body,
picture and category, the videos and the event match the import exactly (MD5
on both sides).

## Look at, flag if wrong

- Three AGM agenda PDFs (1st, 2nd and 3rd AGM) were on the old site only; the
  words "The agenda is available here" stay, without a link.
- The 1st AGM video page had a fifth link with no title
  (https://youtu.be/mqhU5vozN9k); left out.
- Categories were assigned by subject: Events, Industry, Guidance, Institute.
- Old addresses redirect from the new site (tests/73), which matters at
  cutover, when ami.uk.com becomes the new site.
