#!/usr/bin/env python3
"""
Pull the copy out of the public pages, and write both halves of the CMS from it.

WHY THIS EXISTS RATHER THAN SOMEBODY TYPING IT

Five thousand words moved by hand is five thousand chances to drop a word, and
the drop would not be noticed, because the page would go on rendering its
fallback and look exactly right.

So the mapping below is written by a person and everything else is mechanical.
One run produces three things from that one mapping:

  the seed        insert into page_blocks, the words taken off the page, so a
                  block and the fallback it overrides start life identical by
                  construction
  the block map   assets/blocks.js, which is how the public pages find the
                  element each block belongs to
  the field list  tools/out/pages.js, the PAGES array the admin app offers

The second and third are the two copies of one rule that the plan warned about,
the site's idea of the keys and the admin app's idea of them. Generating both
from this file is what stops them drifting, and the test asserts it.

HOW THE MAPPING READS

MAP names, per page, which element carries which block. A selector picks the
element and a kind says how to read and how to write it:

  line   its text. Written back with textContent.
  rich   its inner markup, which is kept as markup because paragraphs matter.
  prose  a RUN of sibling paragraphs that has no wrapper of its own. Read as
         several <p>, written back over the first and the rest removed. This is
         what stops a block replacing a heading and a button that happen to
         share the container.
  list   a repeating thing. Each match becomes one item, read by ITEM_READERS.
  links  the one or two buttons at the foot of a section, label and address.
  image  a photograph drawn as a CSS background. The block holds a picture's
         address: one of the bundle's own photographs, /assets/<name>.webp, or
         a converted upload in the public-media bucket. The wash over it is
         part of the design and stays in the markup.

A selector may carry @n to mean the n-th match, and A >> B to mean B inside the
n-th A. Both exist because these pages use the same class for the same shape
several times down one page, which is correct of them and awkward here.

Run:  extract-page-copy.py SITE_DIR [--out DIR]
Seed to stdout, the generated files to --out, a report to stderr.
"""
import sys, json, re, hashlib, argparse
from pathlib import Path
from bs4 import BeautifulSoup

# ---------------------------------------------------------------------------
# Icons
#
# Every card on this site carries an inline SVG drawn in the brand line weight.
# An icon is therefore a CHOICE from a named set, never markup somebody typed,
# or within a month the set has two padlocks in it that do not match.
#
# Identity is the hash of the drawing with its own attributes stripped, so the
# same drawing is the same icon whether or not it was given aria-hidden. The
# first version of this file matched fragments of path data instead and got
# four of them wrong, because a circle of radius six appears in both the award
# and the target.
# ---------------------------------------------------------------------------
ICONS = {
    '248a315502': 'document',   # a page with a folded corner
    '88be5b7a6b': 'external',   # a box with an arrow leaving it
    'feab38311e': 'video',      # a circle with a play triangle
    '7629f77da6': 'calendar',
    'aad2b20004': 'award',      # a medal with a ribbon
    'd5851a0c23': 'person',     # one figure
    '2df76557e5': 'people',     # two figures
    '7516d8c0b2': 'shield',
    'ed26d03965': 'search',
    '195ae51e98': 'pencil',
    '5ab11cbfdc': 'check',
    '333ab5ea7f': 'clock',
    '2410d13af8': 'book',       # an open book
    '5d77ebc67b': 'list',       # three lines with bullets
    '27c2464be2': 'target',     # three circles
}

def svg_id(svg):
    """The drawing, normalised: children only, whitespace collapsed."""
    raw = ''.join(str(c) for c in svg.contents)
    raw = re.sub(r'\s+', ' ', raw).strip()
    return hashlib.sha1(raw.encode()).hexdigest()[:10]

UNKNOWN_ICONS = {}

def icon_of(el):
    svg = el.find('svg')
    if not svg:
        return None
    h = svg_id(svg)
    if h in ICONS:
        return ICONS[h]
    UNKNOWN_ICONS[h] = ''.join(str(c) for c in svg.contents)[:200]
    return 'unknown:' + h

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------
def txt(el):
    return re.sub(r'\s+', ' ', el.get_text(' ', strip=True)).strip() if el else None

def inner(el):
    if not el:
        return None
    s = ''.join(str(c) for c in el.contents)
    return re.sub(r'\s+', ' ', s).strip() or None

def is_action(p):
    """A paragraph whose job is to hold a button is not prose."""
    return bool(p.find('a', class_='btn')) or bool(p.find('button'))

def prose(els):
    keep = [e for e in els if not is_action(e)]
    out = ''.join('<p>' + (inner(e) or '') + '</p>' for e in keep)
    return out or None

def href_of(el):
    a = el if el.name == 'a' else el.find('a')
    return a.get('href') if a and a.get('href') else None

def bullets(el):
    # Markup, not text: these bullets lead with a bold term and the whole point
    # of the bold is that the eye finds the term before the sentence.
    li = el.select('ul li')
    return [inner(x) for x in li] if li else None

# How one item of a list is read. The keys here ARE the fields the Block List
# editor will offer, which is why a card that has no bullets omits the key
# rather than carrying an empty one: an empty list in the editor invites
# somebody to fill it in on a card whose design has no room for it.
def card(el):
    it = {'icon': icon_of(el), 'title': txt(el.find(['h3', 'h4']))}
    ps = [p for p in el.find_all('p', recursive=False) if not is_action(p)]
    body = ' '.join(txt(p) for p in ps if txt(p))
    if body:
        it['body'] = body
    b = bullets(el)
    if b:
        it['bullets'] = b
    # The card itself may be the link, or hold one in its last paragraph.
    a = el if el.name == 'a' else el.find('a')
    if a is not None and a.get('href'):
        it['href'] = a['href']
        label = txt(a)
        if el.name != 'a' and label:
            it['link_label'] = label
    return it

ITEM_READERS = {
    'card':   card,
    'step':   lambda el: {'title': txt(el.find('h4')), 'body': txt(el.find('p'))},
    'faq':    lambda el: {'question': txt(el.find('summary')), 'answer': inner(el.find('p'))},
    'bullet': lambda el: {'text': inner(el)},
}

# Fields that may be absent from an item without that being a fault.
OPTIONAL = {'href', 'link_label', 'bullets', 'body', 'icon'}


# ---------------------------------------------------------------------------
# HOW MANY ITEMS A LIST MAY HOLD
#
# A list is drawn into a grid, and the grid decides what a sensible count is.
# .cards3, .support-grid and .steprow are three across, so four cards leave a
# hole in the second row that reads as a fault rather than a decision. That has
# bitten this site twice already, with the grades in both directions, so the
# rule is stated once here and the editor enforces it rather than leaving it to
# somebody noticing.
#
#   min, max   how few and how many
#   step       the count must be a multiple of this; 3 for a grid three across
#   noun       what one item is called on the Add button
#
# FIXED means the design is the number. The home page's three cards sit beside
# a photograph that is laid out for three; the joining process is three steps
# and the numbers on them are positions; core and non core are a pair. Those
# can be reworded and reordered and not added to. Changing the count is a
# design change and belongs with whoever has the bundle.
# ---------------------------------------------------------------------------
GRID3_FIXED = {'min': 3, 'max': 3, 'step': 3, 'noun': 'card'}
GRID3       = {'min': 3, 'max': 6, 'step': 3, 'noun': 'card'}
GRID3_NINE  = {'min': 3, 'max': 9, 'step': 3, 'noun': 'card'}
PAIR_FIXED  = {'min': 2, 'max': 2, 'step': 2, 'noun': 'card'}
# The two "what counts" cards on the CPD scheme page. Their bullets are not
# typed: they are the active CPD activity types, core in the first card and non
# core in the second, read live from the database (0040). So the order is fixed
# and the bullets are MANAGED: the editor shows them as coming from the CPD
# activity types screen rather than offering a box that would be ignored.
CPD_COUNTS  = {'min': 2, 'max': 2, 'step': 2, 'noun': 'card',
               'fixed_order': True, 'managed': ['bullets']}
STEPS_FIXED = {'min': 3, 'max': 3, 'step': 3, 'noun': 'step'}
BULLETS     = {'min': 1, 'max': 10, 'step': 1, 'noun': 'bullet'}
QUESTIONS   = {'min': 1, 'max': 12, 'step': 1, 'noun': 'question'}
# The committees page (site 83). Two across, and an odd card out spans the row
# (.cards2 > :last-child:nth-child(odd)), so any count is a whole design and
# the office can add a committee without a hole appearing.
COMMITTEES  = {'min': 1, 'max': 8, 'step': 1, 'noun': 'committee'}

# The order the editor lays an item's fields out in, which is the order a
# reader meets them on the page. Anything a reader returns that is not here is a
# fault in this file, and the run says so.
FIELD_ORDER = ['icon', 'title', 'question', 'text', 'body', 'answer',
               'bullets', 'link_label', 'href']

# ---------------------------------------------------------------------------
# THE MAPPING. The part that needs a person.
#
# Not here, deliberately:
#   privacy.html      2,124 words of legal text going to a solicitor. A deploy
#                     is a record of exactly what changed and when, which a
#                     page_blocks row is not.
#   the apply form    its field labels stay in the bundle. A label is half of a
#                     pair with the input name next to it, and editing one half
#                     from a screen that cannot see the other is a trap. The
#                     words around the form are here; the form is not.
#   crumbs            Home > About AMI is derived from where the page sits.
#   step numbers      and which question starts open. Both are positions, and a
#                     position that becomes a field is a position somebody sets
#                     to 2 twice.
# ---------------------------------------------------------------------------
# EVERY links SELECTOR ENDS a.btn, and one of them did not.
#
# intro_link on About was written `.intro-grid .intro > div a`, which matched
# the one button on the page, because the only anchor under .intro was that
# button. #intro is also a div under .intro. The moment the intro block carried
# a link of its own, that anchor came first in the document and the button's
# label and address were written onto it instead. The page then had a link
# saying "Explore membership" in the middle of a sentence and no button.
#
# Nothing in the markup was wrong. The selector was correct against the page as
# it stood and became wrong the moment the page held editable content, which is
# the whole point: a selector that depends on what is NOT in an element is a
# selector that a CMS will break. Found by test-blocks.js on the first run.
MAP = {
 'index.html': ('home', [
    ('hero_eyebrow',     'line',  '.hero .eyebrow'),
    ('hero_lede',        'rich',  '.hero p.lede'),
    ('hero_actions',     'links', '.hero .actions a'),
    ('hero_badge',       'line',  '#heroBadge'),
    ('quick_cards',      'list',  '.cards3 .qcard', 'card', GRID3_FIXED),
    ('news_eyebrow',     'line',  '.sec-head .eyebrow@0'),
    ('news_heading',     'line',  '.sec-head h2@0'),
    ('news_link',        'links', '#latest + div a.btn'),
    ('band_photo',       'image', '.band.ph'),
    ('band_eyebrow',     'line',  '.band .eyebrow'),
    ('band_heading',     'line',  '.band h2'),
    ('band_body',        'prose', '.band .inner p'),
    ('band_link',        'links', '.band a.btn'),
    ('grades_eyebrow',   'line',  '#membership .eyebrow'),
    ('grades_heading',   'line',  '#membership h2'),
    ('grades_lede',      'prose', '#membership .sec-head p'),
    ('grades_link',      'links', '#grades + div a.btn'),
    ('cta_heading',      'line',  '.cta h2'),
    ('cta_body',         'prose', '.cta p'),
    ('cta_link',         'links', '.cta a.btn'),
 ]),
 'about.html': ('about', [
    ('banner_photo',     'image', '.pbanner.img'),
    ('banner_heading',   'line',  '.pbanner h1'),
    ('banner_lede',      'rich',  '.pbanner p'),
    ('intro_heading',    'line',  '.intro-grid .intro h2'),
    ('intro',            'rich',  '#intro'),
    ('intro_link',       'links', '.intro-grid .intro a.btn'),
    ('glance_heading',   'line',  '.aside h3'),
    ('glance',           'list',  '.aside ul li', 'bullet', BULLETS),
    ('purpose_eyebrow',  'line',  '.sec-head .eyebrow'),
    ('purpose_heading',  'line',  '.sec-head h2'),
    ('purpose_cards',    'list',  '.cards3 .qcard', 'card', GRID3),
    ('practice_photo',  'image', '.split .pic'),
    ('practice_eyebrow', 'line',  '.split .txt .eyebrow'),
    ('practice_heading', 'line',  '.split .txt h2'),
    ('practice_body',    'prose', '.split .txt p'),
    ('practice_link',    'links', '.split .txt a.btn'),
    ('cta_heading',      'line',  '.cta h2'),
    ('cta_body',         'prose', '.cta p'),
    ('cta_link',         'links', '.cta a.btn'),
 ]),
 'membership.html': ('membership', [
    ('banner_photo',     'image', '.pbanner.img'),
    ('banner_heading',   'line',  '.pbanner h1'),
    ('banner_lede',      'rich',  '.pbanner p'),
    ('intro_heading',    'line',  '.intro-grid .intro h2'),
    ('intro',            'rich',  '#intro'),
    ('intro_links',      'links', '.intro-grid .intro a.btn'),
    ('benefits_heading', 'line',  '.aside h3'),
    ('benefits',         'list',  '.aside ul li', 'bullet', BULLETS),
    ('grades_eyebrow',   'line',  '#grades .eyebrow'),
    ('grades_heading',   'line',  '#grades h2'),
    ('grades_lede',      'prose', '#grades .sec-head p'),
    ('grades_link',      'links', '#grades-out + p a.btn'),
    ('more_photo',      'image', '.split .pic'),
    ('more_eyebrow',     'line',  '.split .txt .eyebrow'),
    ('more_heading',     'line',  '.split .txt h2'),
    ('more_body',        'prose', '.split .txt p'),
    ('more_link',        'links', '.split .txt a.btn'),
    ('standards_eyebrow', 'line', '#standards .eyebrow'),
    ('standards_heading', 'line', '#standards h2'),
    ('standards_cards',  'list',  '#standards .cards2 .qcard', 'card', PAIR_FIXED),
    ('steps_eyebrow',    'line',  '#join .eyebrow'),
    ('steps_heading',    'line',  '#join h2'),
    ('steps',            'list',  '.steprow .step', 'step', STEPS_FIXED),
    ('steps_link',       'links', '.steprow + p a.btn'),
    ('faq_eyebrow',      'line',  '#questions .eyebrow'),
    ('faq_heading',      'line',  '#questions h2'),
    ('faq',              'list',  '.faq details', 'faq', QUESTIONS),
    ('cta_heading',      'line',  '.cta h2'),
    ('cta_body',         'prose', '.cta p'),
    ('cta_link',         'links', '.cta a.btn'),
 ]),
 'cpd-scheme.html': ('cpd-scheme', [
    ('banner_photo',     'image', '.pbanner.img'),
    ('banner_heading',   'line',  '.pbanner h1'),
    ('banner_lede',      'rich',  '.pbanner p'),
    ('rule_eyebrow',     'line',  '.sec-head .eyebrow@0'),
    ('rule_heading',     'line',  '.sec-head h2@0'),
    ('rule_body',        'prose', '.sec-head + .glass p'),
    ('counts_eyebrow',   'line',  '.sec-head .eyebrow@1'),
    ('counts_heading',   'line',  '.sec-head h2@1'),
    ('counts',           'list',  '.support-grid@0 >> .scard', 'card', CPD_COUNTS),
    ('how_eyebrow',      'line',  '.sec-head .eyebrow@2'),
    ('how_heading',      'line',  '.sec-head h2@2'),
    ('how',              'list',  '.support-grid@1 >> .scard', 'card', GRID3),
    ('how_note_heading', 'line',  '.support-grid + .glass h3'),
    ('how_note_body',    'prose', '.support-grid + .glass p'),
    ('record_photo',    'image', '.split .pic'),
    ('record_pill',      'line',  '.split .txt .lockpill'),
    ('record_heading',   'line',  '.split .txt h2'),
    ('record_body',      'prose', '.split .txt p'),
    ('record_link',      'links', '.split .txt a.btn'),
    ('cta_heading',      'line',  '.cta h2'),
    ('cta_body',         'prose', '.cta p'),
    ('cta_link',         'links', '.cta a.btn'),
 ]),
 'cscs-cards.html': ('cscs-cards', [
    ('banner_photo',     'image', '.pbanner.img'),
    ('banner_heading',   'line',  '.pbanner h1'),
    ('banner_lede',      'rich',  '.pbanner p'),
    ('scheme_eyebrow',   'line',  '.sec-head .eyebrow@0'),
    ('scheme_heading',   'line',  '.sec-head h2@0'),
    ('scheme_body',      'prose', '.sec-head + .glass p'),
    ('scheme_link',      'links', '.sec-head + .glass a.btn'),
    ('which_eyebrow',    'line',  '.sec-head .eyebrow@1'),
    ('which_heading',    'line',  '.sec-head h2@1'),
    ('cards',            'list',  '.support-grid .scard', 'card', GRID3),
    ('cta_heading',      'line',  '.cta h2'),
    ('cta_body',         'prose', '.cta p'),
    ('cta_link',         'links', '.cta a.btn'),
 ]),
 'support.html': ('support', [
    ('banner_photo',     'image', '.pbanner.img'),
    ('banner_heading',    'line',  '.pbanner h1'),
    ('banner_lede',       'rich',  '.pbanner p'),
    ('resources_eyebrow', 'line',  '.sec-head .eyebrow@0'),
    ('resources_heading', 'line',  '.sec-head h2@0'),
    ('resources',         'list',  '.support-grid .scard', 'card', GRID3_NINE),
    ('forum_photo',     'image', '.split .pic'),
    ('forum_pill',        'line',  '.split .txt .lockpill'),
    ('forum_heading',     'line',  '.split .txt h2'),
    ('forum_body',        'prose', '.split .txt p'),
    ('forum_link',        'links', '.split .txt a.btn'),
    ('recent_eyebrow',    'line',  '.sec-head .eyebrow@1'),
    ('recent_heading',    'line',  '.sec-head h2@1'),
    ('cta_heading',       'line',  '.cta h2'),
    ('cta_body',          'prose', '.cta p'),
    ('cta_link',          'links', '.cta a.btn'),
 ]),
 'contact.html': ('contact', [
    ('banner_photo',     'image', '.pbanner.img'),
    ('banner_heading', 'line', '.pbanner h1'),
    ('banner_lede',    'rich', '.pbanner p'),
    ('form_heading',   'line', '#form h3'),
    ('form_lede',      'line', '#form .fsub'),
    ('form_note',      'rich', '#form > p'),
    # These two have been blocks since August and keep their keys and their
    # ids. They are in the mapping so that applyBlocks goes on rendering them:
    # a key left out of the map is a block that stops appearing.
    ('phone',          'line', '#phone'),
    ('address',        'rich', '#address'),
    ('hours',          'line', '.contact-info .row:nth-of-type(4) p'),
    ('checking',       'rich', '.contact-info .row:nth-of-type(5) p'),
 ]),
 'apply.html': ('apply', [
    ('banner_eyebrow', 'line',  '.pbanner .eyebrow'),
    ('banner_heading', 'line',  '.pbanner h1'),
    ('banner_lede',    'rich',  '.pbanner p@0'),
    ('banner_note',    'rich',  '.pbanner p@1'),
    ('consent',        'prose', '.fset@4 >> p'),
    ('address_hint',   'line',  'p.hint'),
 ]),
 'news.html': ('news', [
    ('banner_photo',     'image', '.pbanner.img'),
    ('banner_heading', 'line', '.pbanner h1'),
    ('banner_lede',    'rich', '.pbanner p'),
    ('main_eyebrow',   'line', '.sec-head .eyebrow'),
    ('main_heading',   'line', '#head'),
    ('events_heading', 'line', '.ev-side h3'),
    ('events_sub',     'line', '.ev-side .subh'),
 ]),
 'videos.html': ('videos', [
    ('banner_eyebrow', 'line', '.pbanner .eyebrow'),
    ('banner_heading', 'line', '.pbanner h1'),
    ('banner_lede',    'rich', '.pbanner p'),
    ('all_eyebrow',    'line', '.sec-head .eyebrow'),
    ('all_heading',    'line', '.sec-head h2'),
 ]),
 'professional-conduct.html': ('professional-conduct', [
    ('banner_photo',     'image', '.pbanner.img'),
    ('banner_heading',   'line',  '.pbanner h1'),
    ('banner_lede',      'rich',  '.pbanner p'),
    ('intro_heading',    'line',  '.intro-grid .intro h2'),
    ('intro',            'rich',  '#intro'),
    ('notify_heading',   'line',  '.aside h3'),
    ('notify',           'list',  '.aside ul li', 'bullet', BULLETS),
    ('cta_heading',      'line',  '.cta h2'),
    ('cta_body',         'prose', '.cta p'),
    ('cta_link',         'links', '.cta a.btn'),
 ]),
 'committees.html': ('committees', [
    ('banner_photo',     'image', '.pbanner.img'),
    ('banner_heading',   'line',  '.pbanner h1'),
    ('banner_lede',      'rich',  '.pbanner p'),
    ('intro_eyebrow',    'line',  '.sec-head .eyebrow'),
    ('intro_heading',    'line',  '.sec-head h2'),
    ('intro_lede',       'prose', '.sec-head p'),
    ('committees',       'list',  '.cards2 .qcard', 'card', COMMITTEES),
    ('cta_heading',      'line',  '.cta h2'),
    ('cta_body',         'prose', '.cta p'),
    ('cta_link',         'links', '.cta a.btn'),
 ]),
 'guidance.html': ('guidance', [
    ('banner_photo',     'image', '.pbanner.img'),
    ('banner_heading',   'line',  '.pbanner h1'),
    ('banner_lede',      'rich',  '.pbanner p'),
 ]),
 'register.html': ('register', [
    ('banner_photo',     'image', '.pbanner.img'),
    ('banner_heading', 'line', '.pbanner h1'),
    ('banner_lede',    'rich', '.pbanner p'),
 ]),
}

# The labels the admin app shows. A key read as a label reads like a key, and a
# screen whose labels read like keys is a screen somebody has to be trained on.
LABELS = {
    'banner_heading': 'Banner heading', 'banner_lede': 'Banner text',
    'banner_photo': 'Banner photograph', 'band_photo': 'Photograph band picture',
    'practice_photo': 'Best practice photograph', 'more_photo': 'More than a listing photograph',
    'record_photo': 'Your record photograph', 'forum_photo': 'Forum photograph',
    'banner_eyebrow': 'Banner eyebrow', 'banner_note': 'Note under the banner',
    'hero_eyebrow': 'Hero eyebrow', 'hero_lede': 'Hero text',
    'hero_actions': 'Hero buttons', 'hero_badge': 'Photograph badge',
    'quick_cards': 'The three cards', 'news_eyebrow': 'News eyebrow',
    'news_heading': 'News heading', 'news_link': 'News button',
    'band_eyebrow': 'Photograph band eyebrow', 'band_heading': 'Photograph band heading',
    'band_body': 'Photograph band text', 'band_link': 'Photograph band button',
    'grades_eyebrow': 'Grades eyebrow', 'grades_heading': 'Grades heading',
    'grades_lede': 'Grades text', 'grades_link': 'Grades button',
    'cta_heading': 'Red panel heading', 'cta_body': 'Red panel text',
    'cta_link': 'Red panel button',
    'intro_heading': 'Opening heading', 'intro': 'Opening text',
    'intro_link': 'Opening button', 'intro_links': 'Opening buttons',
    'glance_heading': 'At a glance heading', 'glance': 'At a glance bullets',
    'purpose_eyebrow': 'Purpose eyebrow', 'purpose_heading': 'Purpose heading',
    'purpose_cards': 'Purpose cards',
    'practice_eyebrow': 'Best practice eyebrow', 'practice_heading': 'Best practice heading',
    'practice_body': 'Best practice text', 'practice_link': 'Best practice button',
    'benefits_heading': 'Benefits heading', 'benefits': 'Benefits bullets',
    'more_eyebrow': 'More than a listing eyebrow', 'more_heading': 'More than a listing heading',
    'more_body': 'More than a listing text', 'more_link': 'More than a listing button',
    'steps_eyebrow': 'Joining eyebrow', 'steps_heading': 'Joining heading',
    'steps': 'The joining steps', 'steps_link': 'Joining button',
    'faq_eyebrow': 'Questions eyebrow', 'faq_heading': 'Questions heading',
    'faq': 'Questions and answers',
    'rule_eyebrow': 'Requirement eyebrow', 'rule_heading': 'Requirement heading',
    'rule_body': 'Requirement text',
    'counts_eyebrow': 'What counts eyebrow', 'counts_heading': 'What counts heading',
    'counts': 'What counts cards',
    'how_eyebrow': 'Recording eyebrow', 'how_heading': 'Recording heading',
    'how': 'Recording cards', 'how_note_heading': 'Recording note heading',
    'how_note_body': 'Recording note text',
    'record_pill': 'Members only label', 'record_heading': 'Your record heading',
    'record_body': 'Your record text', 'record_link': 'Your record button',
    'scheme_eyebrow': 'Scheme eyebrow', 'scheme_heading': 'Scheme heading',
    'scheme_body': 'Scheme text', 'scheme_link': 'Leaflet button',
    'which_eyebrow': 'Which card eyebrow', 'which_heading': 'Which card heading',
    'cards': 'The cards',
    'resources_eyebrow': 'Resources eyebrow', 'resources_heading': 'Resources heading',
    'resources': 'Resource cards',
    'forum_pill': 'Members only label', 'forum_heading': 'Forum heading',
    'forum_body': 'Forum text', 'forum_link': 'Forum button',
    'recent_eyebrow': 'Recently published eyebrow', 'recent_heading': 'Recently published heading',
    'form_heading': 'Form heading', 'form_lede': 'Form subheading',
    'form_note': 'Note under the form', 'hours': 'Office hours',
    'checking': 'Checking a membership',
    'phone': 'Telephone number', 'address': 'Office address',
    'consent': 'Declaration wording', 'address_hint': 'Address hint',
    'main_eyebrow': 'List eyebrow', 'main_heading': 'List heading',
    'events_heading': 'Events panel heading', 'events_sub': 'Events panel subheading',
    'all_eyebrow': 'Recordings eyebrow', 'all_heading': 'Recordings heading',
    'notify_heading': 'Telling AMI heading', 'notify': 'Telling AMI bullets',
    'intro_eyebrow': 'Opening eyebrow', 'intro_lede': 'Opening text',
    'committees': 'The committees',
    'standards_eyebrow': 'Standards eyebrow', 'standards_heading': 'Standards heading',
    'standards_cards': 'Professional conduct and committees cards',
}

PAGE_TITLES = {
    'home': 'Home', 'about': 'About AMI', 'membership': 'Membership',
    'cpd-scheme': 'CPD scheme', 'cscs-cards': 'CSCS cards',
    'support': 'Support and guidance', 'contact': 'Contact',
    'apply': 'Apply for membership', 'news': 'News and events',
    'videos': 'Video library', 'register': 'Members register',
    'professional-conduct': 'Professional conduct', 'committees': 'Committees',
    'guidance': 'Guidance documents',
}
PAGE_PATHS = {
    'home': '/', 'about': '/about', 'membership': '/membership',
    'cpd-scheme': '/cpd-scheme', 'cscs-cards': '/cscs-cards',
    'support': '/support', 'contact': '/contact', 'apply': '/apply',
    'news': '/news', 'videos': '/videos', 'register': '/register',
    'professional-conduct': '/professional-conduct', 'committees': '/committees',
    'guidance': '/guidance',
}

# ---------------------------------------------------------------------------
def pick(scope, sel):
    """One selector, honouring @n and A >> B. Returns a list of elements."""
    if '>>' in sel:
        outer, inner_sel = [s.strip() for s in sel.split('>>', 1)]
        outs = pick(scope, outer)
        return pick(outs[0], inner_sel) if outs else []
    n = None
    m = re.search(r'@(\d+)$', sel)
    if m:
        n, sel = int(m.group(1)), sel[:m.start()]
    els = scope.select(sel)
    if n is not None:
        return [els[n]] if n < len(els) else []
    return els

def sql_str(s):
    return "'" + str(s).replace("'", "''") + "'"


ap = argparse.ArgumentParser()
ap.add_argument('site')
ap.add_argument('--out', default=None)
# Only these kinds in the seed. 0037 seeds the photographs alone, because the
# 135 words went in with 0035 and a migration that repeated them would be 135
# rows of noise around the thirteen that matter.
ap.add_argument('--kinds', default=None, help='comma separated kinds to seed, e.g. image')
# Splice PAGES and ICONS into the admin app in place. Done by the generator
# rather than by hand because the hand step is the one that gets skipped:
# regenerate the site's half, forget the admin's, and test 12 goes red a week
# later on somebody else's screen.
ap.add_argument('--admin', default=None, help='admin index.html to splice PAGES into')
args = ap.parse_args()
SITE = Path(args.site)

blocks, report, problems = [], [], []
block_map, pages_def = {}, []
icon_svgs = {}      # name -> the whole <svg>, from the first page that draws it

for filename, (page_key, fields) in MAP.items():
    path = SITE / filename
    if not path.exists():
        problems.append(f'{filename}: not found')
        continue
    soup = BeautifulSoup(path.read_text(), 'lxml')
    main = soup.find('main') or soup
    # Every drawing on the page, not only the ones inside a list, so the set the
    # editor offers is the set the site already draws in the brand line weight.
    for svg in main.find_all('svg'):
        name = ICONS.get(svg_id(svg))
        if name and name not in icon_svgs:
            icon_svgs[name] = re.sub(r'\s+', ' ', str(svg)).strip()
    pmap, pfields = {}, []
    for spec in fields:
        key, kind, sel = spec[0], spec[1], spec[2]
        label = LABELS.get(key) or key.replace('_', ' ').capitalize()
        if key not in LABELS:
            problems.append(f'{page_key}.{key}: no label')
        els = pick(main, sel)
        if not els:
            problems.append(f'{page_key}.{key}: selector matched nothing  [{sel}]')
            continue
        pmap[key] = [sel, kind] + ([spec[3]] if kind == 'list' else [])
        pf = {'k': key, 'label': label, 'kind': kind}
        pfields.append(pf)

        if kind == 'list':
            reader = ITEM_READERS[spec[3]]
            items = [reader(e) for e in els]
            if len(spec) < 5:
                problems.append(f'{page_key}.{key}: a list with no count rule')
                rule = {'min': 1, 'max': len(items), 'step': 1, 'noun': 'item'}
            else:
                rule = spec[4]
            # The fields an item offers are the union across the items, in page
            # order. A CSCS card with bullets and one without are the same kind
            # of card, and the editor offers both parts on every one.
            seen = {f for it in items for f in it}
            for f in seen - set(FIELD_ORDER):
                problems.append(f'{page_key}.{key}: field {f} is not in FIELD_ORDER')
            fields_used = [f for f in FIELD_ORDER if f in seen]
            # Required means every item on the page has it today. Anything some
            # items lack is optional by the evidence of the page itself.
            required = [f for f in fields_used
                        if all(it.get(f) not in (None, '', []) for it in items)]
            if not (rule['min'] <= len(items) <= rule['max']) or len(items) % rule['step']:
                problems.append(f'{page_key}.{key}: {len(items)} items breaks its own rule {rule}')
            pf['item'] = {'type': spec[3], 'fields': fields_used, 'required': required,
                          'min': rule['min'], 'max': rule['max'], 'step': rule['step'],
                          'noun': rule['noun']}
            if rule.get('fixed_order'):
                pf['item']['fixed_order'] = True
            if rule.get('managed'):
                pf['item']['managed'] = rule['managed']
            for n, it in enumerate(items, 1):
                for f, v in it.items():
                    if v in (None, '', []) and f not in OPTIONAL:
                        problems.append(f'{page_key}.{key} item {n}: {f} is empty')
                    if isinstance(v, str) and v.startswith('unknown:'):
                        problems.append(f'{page_key}.{key} item {n}: icon {v} is not in the set')
            blocks.append((page_key, key, None, items))
            report.append(f'{page_key:12} {key:20} list   {len(items)} items')
        elif kind == 'image':
            # The address inside url(...), from the lazy data-bg if there is
            # one and the inline style if not. The ?v= stamp is the bundle's
            # cache key, not part of the picture's name.
            src = els[0].get('data-bg') or els[0].get('style') or ''
            m = re.search(r"url\('([^'?]+)", src)
            if not m:
                problems.append(f'{page_key}.{key}: no url() on the element  [{sel}]')
                continue
            blocks.append((page_key, key, m.group(1), None))
            report.append(f'{page_key:12} {key:20} image  {m.group(1)}')
        elif kind == 'links':
            items = [{'label': txt(a), 'href': a.get('href')} for a in els]
            for n, it in enumerate(items, 1):
                for f in ('label', 'href'):
                    if not it.get(f):
                        problems.append(f'{page_key}.{key} link {n}: {f} is empty')
            blocks.append((page_key, key, None, items))
            report.append(f'{page_key:12} {key:20} links  {len(items)}')
        else:
            body = txt(els[0]) if kind == 'line' else (
                   prose(els) if kind == 'prose' else inner(els[0]))
            if not body:
                problems.append(f'{page_key}.{key}: empty  [{sel}]')
                continue
            blocks.append((page_key, key, body, None))
            report.append(f'{page_key:12} {key:20} {kind:6} {len(body):5} chars')

    block_map[page_key] = pmap
    pages_def.append({'key': page_key, 'title': PAGE_TITLES[page_key],
                      'path': PAGE_PATHS[page_key], 'fields': pfields})

# --- the seed -------------------------------------------------------------
print('-- Generated by tools/extract-page-copy.py from the public site bundle.')
print('-- Do not hand edit. Re-run the extractor against the bundle instead.')
print('--')
print('-- on conflict do nothing, deliberately: a second run must never overwrite')
print('-- copy somebody has edited in the admin app. Re-seeding a changed block is')
print('-- a decision, not a side effect of running a migration twice.')
print()
print('insert into public.page_blocks (page_key, block_key, body, items, status, sort_order)')
print('values')
rows = []
want = set(args.kinds.split(',')) if args.kinds else None
kind_of = {(pk, k): v[1] for pk, m in block_map.items() for k, v in m.items()}
for i, (pk, bk, body, items) in enumerate(blocks):
    if want and kind_of.get((pk, bk)) not in want:
        continue
    b = sql_str(body) if body is not None else 'null'
    it = sql_str(json.dumps(items, ensure_ascii=False)) + '::jsonb' if items is not None else 'null'
    rows.append(f"  ({sql_str(pk)}, {sql_str(bk)}, {b}, {it}, 'published', {i * 10})")
print(',\n'.join(rows))
print('on conflict (page_key, block_key) do nothing;')

# --- the generated files --------------------------------------------------
if args.out:
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    head = ('/* GENERATED by db/tools/extract-page-copy.py. Do not edit.\n'
            '   The mapping lives in that file so that the site and the admin app\n'
            '   cannot hold two different ideas of what a page is made of. */\n')
    # One line per key. Every public page loads blocks.js, so it is written to
    # be read rather than to be pretty printed over nine hundred lines.
    # No trailing commas anywhere: what follows `const BLOCK_MAP = ` is then
    # valid JSON as well as valid JavaScript, and test-blocks.js reads it with
    # JSON.parse rather than by evaluating a file it is meant to be testing.
    bm = []
    for pk, keys in block_map.items():
        rows = [f'    {json.dumps(k)}: {json.dumps(v, ensure_ascii=False)}'
                for k, v in keys.items()]
        bm.append(f'  {json.dumps(pk)}: {{\n' + ',\n'.join(rows) + '\n  }')
    # The icons follow the map rather than leading it, and the tests find the map
    # by its own name rather than by the first brace in the file.
    icons_js = ',\n'.join(f'  {json.dumps(k)}: {json.dumps(icon_svgs[k])}'
                          for k in sorted(icon_svgs))
    (out / 'blocks.js').write_text(
        head + 'const BLOCK_MAP = {\n' + ',\n'.join(bm) + '\n};\n\n'
        '/* The drawings a card may carry. A card names one and the bundle draws it,\n'
        '   so nothing typed in the admin app ever becomes markup on the page. */\n'
        'const BLOCK_ICONS = {\n' + icons_js + '\n};\n')

    pg = ['const PAGES = [']
    for p in pages_def:
        pg.append(f'  {{ key: {json.dumps(p["key"])}, title: {json.dumps(p["title"])}, '
                  f'path: {json.dumps(p["path"])}, fields: [')
        for f in p['fields']:
            extra = f', item: {json.dumps(f["item"])}' if 'item' in f else ''
            pg.append(f'    {{ k: {json.dumps(f["k"])}, label: {json.dumps(f["label"])}, '
                      f'kind: {json.dumps(f["kind"])}{extra} }},')
        pg.append('  ] },')
    pg.append('];')
    pg.append('')
    pg.append('/* The same drawings the site carries in blocks.js, so the icon picker shows')
    pg.append('   exactly what the page will show. Generated alongside PAGES. */')
    pg.append('/* The photographs the bundle carries, which the picture fields offer as a')
    pg.append('   choice beside an upload. Generated from what the pages actually use. */')
    stock = sorted({b[2] for b in blocks if b[2] and str(b[2]).startswith('/assets/')
                    and kind_of.get((b[0], b[1])) == 'image'})
    pg.append('const STOCK_PHOTOS = ' + json.dumps(stock) + ';')
    pg.append('')
    pg.append('const ICONS = {')
    pg.append(',\n'.join(f'  {json.dumps(k)}: {json.dumps(icon_svgs[k])}' for k in sorted(icon_svgs)))
    pg.append('};')
    pages_js = '\n'.join(pg) + '\n'
    (out / 'pages.js').write_text(head + pages_js)
    print(f'\nwrote {out}/blocks.js and {out}/pages.js', file=sys.stderr)

if args.admin:
    a = Path(args.admin)
    src = a.read_text()
    start = src.index('const PAGES = [')
    end = src.index('const SCREENS = [')
    a.write_text(src[:start] + pages_js + '\n' + src[end:])
    print(f'spliced PAGES and ICONS into {a}', file=sys.stderr)

# --- the report -----------------------------------------------------------
print(f'\n{len(blocks)} blocks from {len(MAP)} pages', file=sys.stderr)
for line in report:
    print('  ' + line, file=sys.stderr)
for name in ICONS.values():
    if name not in icon_svgs:
        problems.append(f'icon {name}: no page draws it, so neither can the editor')
if UNKNOWN_ICONS:
    print('\nicons not in the set:', file=sys.stderr)
    for h, raw in UNKNOWN_ICONS.items():
        print(f'  {h}  {raw}', file=sys.stderr)
if problems:
    print(f'\n{len(problems)} PROBLEMS', file=sys.stderr)
    for p in problems:
        print('  ' + p, file=sys.stderr)
    sys.exit(1)
print('\nno problems', file=sys.stderr)
