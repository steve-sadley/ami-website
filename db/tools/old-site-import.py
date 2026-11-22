"""Build the import of the old ami.uk.com content into the new site.

Reads news.json and support.json (captured from the old site in the browser on
22 November 2026) and img/, and writes:
  import.sql         the rows, for the Supabase connection
  redirects.json     old address -> new address, for the Worker
  out-img/           the pictures, renamed for the site's assets folder
  report.txt         every decision a person should look at
"""
import json, re, html, shutil, os
from datetime import datetime
from bs4 import BeautifulSoup, NavigableString

news = json.load(open('news.json'))
support = json.load(open('support.json'))
report = []
redirects = {}

def slugify(s, n=70):
    s = html.unescape(s).lower().replace('’', '').replace("'", '')
    s = re.sub(r'[^a-z0-9]+', '-', s).strip('-')
    return s[:n].rstrip('-')

def q(s):
    return 'null' if s is None else "'" + str(s).replace("'", "''") + "'"

INTERNAL = {
    '/membership/categories/': '/membership#grades', '/membership/cpd-scheme/': '/cpd-scheme',
    '/membership/committees/': '/committees', '/support/discussion-forum/': '/forum',
    '/events/': '/news?kind=event', '/membership/professional-conduct/': '/professional-conduct',
}

def fix_href(h, where):
    h = h.strip()
    # The old CMS appended "#<the address again>" or "#here" to many links.
    if '#' in h and not h.startswith('#'):
        base, frag = h.split('#', 1)
        if frag.startswith('/registration'):           # Zoom keeps its own
            h = base + '#/registration'
        elif re.match(r'(https?:|here$|the%20|HSE%20)', frag) or ' ' in frag:
            h = base
    h = h.replace('https://www.ami.uk.com/', '/')
    if h in INTERNAL: return INTERNAL[h]
    if re.match(r'/support/(ami-|amiagm)', h):
        return '/videos'
    if h.startswith('/support/asbestos-network-information') or h.startswith('/support/hse-publications') or h.startswith('/support/useful-links'):
        return '/resources'
    if h.startswith('/news/archive/'):
        return h                                        # fixed after slugs are known
    if h.startswith('/assets/') or h.startswith('/support/'):
        report.append(f'{where}: link to the old site\'s {h} removed (the words stay); the file is not on the new site')
        return None
    return h

def clean(content, where):
    s = BeautifulSoup(content, 'html.parser')
    for t in s.find_all(['h4', 'h5', 'h6']):
        t.name = 'p'; inner = s.new_tag('strong')
        for c in list(t.contents): inner.append(c.extract())
        t.append(inner)
    for t in s.find_all(['span', 'sup', 'font', 'div', 'sub']):
        t.unwrap()
    for a in s.find_all('a'):
        if not a.get_text(strip=True):
            a.decompose(); continue
        h = fix_href(a.get('href', ''), where)
        if h is None: a.unwrap(); continue
        a.attrs = {'href': h}
    for t in s.find_all(True):
        if t.name != 'a': t.attrs = {}
    out = str(s).replace('\xa0', ' ').replace('\u202f', ' ').replace('\u2009', ' ').replace('&nbsp;', ' ')
    out = re.sub(r'<p>\s*(<br/?>\s*)*</p>', '', out)
    out = re.sub(r'<(strong|em|b|i)>\s*</\1>', '', out)
    out = re.sub(r'<p>\s*</p>', '', out)
    out = re.sub(r'[ \t]{2,}', ' ', out).replace('<br/>', '<br>')
    out = re.sub(r'\s*\n\s*', '\n', out).strip()
    return out

def summary_of(body):
    txt = html.unescape(re.sub(r'<[^>]+>', ' ', body))
    txt = re.sub(r'\s+', ' ', txt).strip()
    if len(txt) <= 240: return txt
    cut = txt[:240]
    i = max(cut.rfind('. '), cut.rfind('? '), cut.rfind('! '))
    return (cut[:i+1] if i > 80 else cut[:cut.rfind(' ')] + '…')

def category(t):
    t = t.lower()
    if re.search(r'annual general meeting|agm|seminar|webinar|meeting', t): return 'Events'
    if re.search(r'hse|regulation|report|parliament|cscs|analysts|operating procedures|school', t): return 'Industry'
    if re.search(r'guidance|competency', t): return 'Guidance'
    return 'Institute'

# --- news -------------------------------------------------------------------
os.makedirs('out-img', exist_ok=True)
imgname = {}
rows = []
EXISTING = {'asbestos-management-institute-celebrates-successful-fourth-annual-general-meeting':
            'asbestos-management-institute-celebrates-successful-fourth-annual-gene'}
slugmap = {}
for a in news:
    old = a['slug']
    if old in EXISTING:
        slugmap[old] = EXISTING[old]
        report.append(f'news "{a["title"]}": already on the new site (entered by the office), not imported again')
        continue
    title = re.sub(r'\s+', ' ', html.unescape(a['title'])).strip()
    slugmap[old] = slugify(title)
for a in news:
    old = a['slug']
    if old in EXISTING: continue
    new = slugmap[old]
    title = re.sub(r'\s+', ' ', html.unescape(a['title'])).strip()
    body = clean(a['content'], f'news "{title}"')
    body = re.sub(r'href="/news/archive/([^"/]+)/?"',
                  lambda m: f'href="/article?kind=news&amp;slug={slugmap.get(m.group(1), m.group(1))}"', body)
    when = datetime.strptime(a['date'], '%d %B %Y').strftime('%Y-%m-%d') + ' 12:00 Europe/London'
    img = None
    if a['imgs']:
        src = a['imgs'][0]
        if src not in imgname:
            nm = 'news-' + new[:58].rstrip('-')
            key = re.sub(r'[^a-z0-9]+', '-', src.lower().replace('/assets/', '').rsplit('.', 1)[0]).strip('-')
            shutil.copy(f'img/{key}.webp', f'out-img/{nm}.webp')
            imgname[src] = f'/assets/{nm}.webp'
        img = imgname[src]
    rows.append(f"  ({q(new)}, {q(title)}, {q(category(title))}, {q(summary_of(body))}, {q(body)}, {q(img)}, "
                f"'published', timestamp {q(when.rsplit(' ',1)[0])} at time zone 'Europe/London')")
    redirects[f'/news/archive/{old}'] = f'/article?kind=news&slug={new}'
for old, new in EXISTING.items():
    redirects[f'/news/archive/{old}'] = f'/article?kind=news&slug={new}'

sql = ['-- Old ami.uk.com content, captured 22 November 2026. Run once; safe twice (slugs).',
       '-- notified_at is set so the daily digest does not announce years of old news.',
       'begin;',
       'insert into public.news_articles (slug, title, category, summary, body, image_path, status, published_at)',
       'values', ',\n'.join(rows), 'on conflict (slug) do nothing;',
       "update public.news_articles set notified_at = now() where notified_at is null and slug in ("
       + ', '.join(q(slugmap[a['slug']]) for a in news if a['slug'] not in EXISTING) + ');']

# --- videos -----------------------------------------------------------------
vrows = []
for p in support:
    if '/support/' not in p['url'] or not re.search(r'agm|webinar|video', p['url'] + (p.get('title') or ''), re.I):
        continue
    event = re.sub(r'\s+', ' ', p['title']).strip()
    m = re.search(r'(\d{1,2})(?:st|nd|rd|th)?\s+([A-Z][a-z]+)\s+(\d{4})', event)
    when = datetime.strptime(f'{m.group(1)} {m.group(2)} {m.group(3)}', '%d %B %Y').strftime('%Y-%m-%d')
    s = BeautifulSoup(p['html'], 'html.parser')
    seen = set()
    for a in s.find_all('a'):
        t = re.sub(r'\s+', ' ', a.get_text(' ')).strip()
        h = a.get('href', '')
        if not re.search(r'youtu|vimeo', h): continue
        if not t:
            if not any(h.split('?')[0] in x for x in seen):
                report.append(f'video page "{event}": a link with no title ({h}) left out')
            continue
        h = h.split('#')[0]
        vm = re.match(r'https?://vimeo\.com/(\d+)/([0-9a-f]+)', h)
        link = f'https://vimeo.com/{vm.group(1)}/{vm.group(2)}' if vm else h.split('?si=')[0]
        if link in seen:
            continue
        seen.add(link)
        t = t.replace('AM AGM', 'AMI AGM').replace(' -  ', ' - ')
        t = re.sub(r'\s+Presentation$', ' presentation', t)
        # The card shows the event underneath, so the title need not repeat it.
        t = re.sub(r'^AMI (AGM Webinar|AGM|Winter Webinar|Webinar)\s*-\s*', '', t).strip()
        t = t[0].upper() + t[1:]
        slug = slugify(event.split(' - ')[0] + ' ' + re.sub(r'^AMI (AGM|Winter Webinar|Webinar|AGM Webinar)\s*-\s*', '', t))
        desc = 'Recorded at the ' + re.sub(r' - (\d+)(st|nd|rd|th) ', r', \1 ', event.replace(' Videos', '')) + '.'
        vrows.append(f"  ({q(slug)}, {q(t)}, {q(desc)}, {q(link)}, {q(event)}, false, 'published', "
                     f"timestamp '{when} 12:00' at time zone 'Europe/London')")
    redirects[p['url'].rstrip('/')] = '/videos'
sql += ["-- The office's test entry (one video standing for a whole AGM) is replaced by the presentations themselves.",
        "delete from public.videos where slug = 'ami-1st-agm-videos-6th-april-2023';",
        'insert into public.videos (slug, title, description, vimeo_id, category, members_only, status, published_at)',
        'values', ',\n'.join(vrows), 'on conflict (slug) do nothing;',
        "update public.videos set notified_at = now() where notified_at is null;"]

# --- the one event ----------------------------------------------------------
sql += ['insert into public.events (slug, title, kind, starts_at, ends_at, location, description, members_only, status, published_at, notified_at)',
        "values ('regulation-the-law-and-our-asbestos-legacy', 'Regulation, the Law and Our Asbestos Legacy', 'Webinar',",
        "  timestamp '2026-11-26 10:30' at time zone 'Europe/London', timestamp '2026-11-26 12:30' at time zone 'Europe/London',",
        "  'Online via Zoom',",
        "  " + q('A free online seminar from the Asbestos Management Institute, open to all. Three speakers will cover where the regulator is heading, the latest developments in corporate manslaughter and asbestos prosecutions, and the question the industry keeps returning to: should Great Britain manage its asbestos legacy or remove it.\n\nRegister on Zoom: https://us02web.zoom.us/meeting/register/YXUVAGcrRu6WqNQmhkNgvg') + ",",
        "  false, 'published', timestamp '2026-10-23 12:00' at time zone 'Europe/London', now())",
        'on conflict (slug) do nothing;',
        'commit;']
redirects['/events'] = '/news?kind=event'
redirects['/news/latest'] = '/news'
redirects['/news/archive'] = '/news'
redirects['/support'] = '/support'

open('import.sql', 'w').write('\n'.join(sql) + '\n')
json.dump(redirects, open('redirects.json', 'w'), indent=1)
open('report.txt', 'w').write('\n'.join(report) + '\n')
print(len(rows), 'news;', len(vrows), 'videos; pictures', len(imgname))
print('\n'.join(report))
