#!/usr/bin/env python3
"""Write the admin app's Content-Security-Policy into admin/_headers.

WHY A TOOL. The admin app is one HTML file with its whole application and a
vendored Supabase client inline. 'self' cannot allow inline script, and
'unsafe-inline' would allow exactly what the policy exists to stop. So each
inline <script> is allowed by the SHA-256 of its exact text, and nothing else
inline runs: not an injected <script>, and not an onerror="" on an injected
picture, which is the hole the sanitiser fix of 30 October closed by hand.

The price is that the hashes change whenever the script does, which is every
release. Forget to rerun this and the browser refuses the app: the office sees
a blank screen. Two things stop that reaching anybody:

  this tool, which is the only way the line is written
  db/tests/19_admin_csp_browser.js, which recomputes the hashes, fails if they
  do not match, and then runs every screen under the real header

Run:  admin-csp.py ADMIN_DIR          rewrites ADMIN_DIR/_headers in place
      admin-csp.py ADMIN_DIR --check  exits 1 if the line is out of date
"""
import base64, hashlib, re, sys
from pathlib import Path

HOSTS_IMG = 'https://staging.ami.uk.com https://ami.uk.com https://www.ami.uk.com'

def policy(html):
    scripts = re.findall(r'<script(?: [^>]*)?>([\s\S]*?)</script>', html)
    if len(scripts) < 2:
        raise SystemExit(f'expected the inline scripts, found {len(scripts)}')
    hashes = ' '.join("'sha256-" + base64.b64encode(hashlib.sha256(s.encode()).digest()).decode() + "'"
                      for s in scripts)
    return '; '.join([
        "default-src 'none'",
        # 'self' as well as the hashes: the app has no script files of its own,
        # but Cloudflare can serve one from /cdn-cgi/ on this host (email
        # obfuscation, for one) and refusing it would be a fault nobody could
        # see. Nothing else can put a file on this origin.
        f"script-src 'self' {hashes}",
        # The Supabase client's realtime keeps itself alive from a blob worker.
        "worker-src blob:",
        # Inline styles are everywhere in this app, as on the public site: a
        # stated compromise. Style cannot run script.
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
        "font-src https://fonts.gstatic.com",
        # Any Supabase project, because Change project can point the app at one.
        # And the site itself: Send queued mail, a bulletin's sending and Fetch
        # attendance are requests to the site's Worker. Left out from admin 18
        # to admin 21, which refused every one of them in silence: the app said
        # the site could not be reached and the mail waited for the next drain.
        f"connect-src 'self' https://*.supabase.co wss://*.supabase.co {HOSTS_IMG}",
        f"img-src 'self' data: blob: https://*.supabase.co {HOSTS_IMG}",
        "frame-src 'none'",
        "frame-ancestors 'none'",
        "base-uri 'none'",
        "form-action 'self'",
        "object-src 'none'",
    ])

def main():
    admin = Path(sys.argv[1])
    html = (admin / 'index.html').read_text()
    line = '  Content-Security-Policy: ' + policy(html)
    hp = admin / '_headers'
    h = hp.read_text()
    m = re.search(r'^  Content-Security-Policy: .*$', h, re.M)
    if '--check' in sys.argv:
        ok = bool(m) and m.group(0) == line
        print('up to date' if ok else 'OUT OF DATE: run tools/admin-csp.py ADMIN_DIR')
        sys.exit(0 if ok else 1)
    if m:
        h = h[:m.start()] + line + h[m.end():]
    else:
        h = h.replace('  Strict-Transport-Security: max-age=31536000; includeSubDomains\n',
                      '  Strict-Transport-Security: max-age=31536000; includeSubDomains\n' + line + '\n', 1)
    hp.write_text(h)
    print('written:', line[:120], '...')

main()
