#!/usr/bin/env python3
"""
Turn a pgTAP suite into one that NAMES the checks that failed.

WHY THIS EXISTS

The Supabase SQL editor shows only the final result of a script, and pgTAP
returns each answer from its own statement. So a suite of twenty five
assertions reports "TESTS FAILED: 1 of 25" and throws away which one and what it
expected. On 30 October 2026 that cost a round trip, and the fix was written on
the spot and then nearly thrown away. This is that fix, kept.

WHAT IT DOES

Every assertion is rewritten to write its answer into a temporary table instead
of returning it, so the last thing the file does is show the failures with their
descriptions, what they wanted and what they got. Everything else is untouched,
including the rollback at the end, so running the result changes nothing.

    python3 tools/name-the-failing-check.py tests/03_public_site_supabase.sql > /tmp/which.sql

Then paste /tmp/which.sql into the SQL editor and run it.

TWO THINGS IT HAD TO GET RIGHT

The temp table has to be writable after `set local role anon`, which these
files do half way down, so it is granted to the three Supabase roles.

Statements are split on the semicolons that END one, which means skipping the
ones inside dollar quotes, inside strings, and inside LINE COMMENTS. The first
version missed the last of those: a comment in test 03 reads "the service role
holds every grant;" and that semicolon ended a statement in the middle of a
sentence, which left one assertion unwrapped and invisible.
"""
import re, sys
from pathlib import Path

TAP = r'(^|\n)\s*select\s+(is|isnt|ok|throws_ok|lives_ok|cmp_ok|matches|has_column|col_type_is|col_is_null|table_privs_are|isnt_empty|is_empty)\s*\('


def statements(s):
    out, buf, i, tag = [], '', 0, None
    while i < len(s):
        if tag:
            if s.startswith(tag, i):
                buf += tag; i += len(tag); tag = None; continue
            buf += s[i]; i += 1; continue
        if s.startswith('--', i):
            j = s.find('\n', i)
            j = len(s) if j < 0 else j + 1
            buf += s[i:j]; i = j; continue
        m = re.match(r'\$[A-Za-z_]*\$', s[i:])
        if m:
            tag = m.group(0); buf += tag; i += len(tag); continue
        if s[i] == "'":
            j = i + 1
            while j < len(s):
                if s[j] == "'" and s[j + 1:j + 2] == "'": j += 2; continue
                if s[j] == "'": break
                j += 1
            buf += s[i:j + 1]; i = j + 1; continue
        if s[i] == ';':
            buf += ';'; out.append(buf); buf = ''; i += 1; continue
        buf += s[i]; i += 1
    if buf.strip():
        out.append(buf)
    return out


def convert(src):
    out, wrapped = [], 0
    for st in statements(src):
        if re.search(TAP, st, re.I):
            body = st.strip()
            if not body.endswith(';'):
                out.append(st); continue
            body = body[:-1]
            lead, lines = [], body.split('\n')
            while lines and (lines[0].strip().startswith('--') or not lines[0].strip()):
                lead.append(lines.pop(0))
            body = re.sub(r'^\s*select\s+', '', '\n'.join(lines), count=1, flags=re.I)
            out.append('\n'.join(lead) + ('\n' if lead else '')
                       + 'insert into _tap(line) select ' + body + ';')
            wrapped += 1
        else:
            out.append(st)

    doc = ''.join(out)
    setup = ('\n-- Writable after SET ROLE anon, which these files do half way down.\n'
             'create temp table _tap(n serial, line text);\n'
             'grant insert on _tap to anon, authenticated, service_role;\n'
             'grant usage, select on sequence _tap_n_seq to anon, authenticated, service_role;\n')
    doc = re.sub(r'(select plan\(\d+\);)', r'\1' + setup, doc, count=1)

    # The plan, so a reader can see whether this tool caught every assertion.
    # It will not always: an assertion written in a shape the pattern above does
    # not match returns its answer normally and never reaches the table. Saying
    # so is the difference between a tool and a tool you can trust.
    plan = re.search(r'select plan\((\d+)\)', src)
    planned = plan.group(1) if plan else 'null'
    verdict = ('\n-- ---------------------------------------------------------------\n'
               '-- The answer\n'
               '--\n'
               '-- If checks_run is smaller than planned, this tool did not catch\n'
               '-- every assertion and one of the missing ones could be the failure.\n'
               '-- ---------------------------------------------------------------\n'
               'reset role;\n'
               f'select {planned} as planned,\n'
               '       (select count(*) from _tap) as checks_run,\n'
               "       (select count(*) from _tap where line like 'not ok%') as failed;\n"
               "select n, line from _tap where line like 'not ok%' order by n;\n\n"
               'rollback;\n')
    # Everything from the suite's own verdict block onwards is replaced, so the
    # exception it raises does not hide the answer this file exists to give.
    cut = re.search(r'\n-- -+\n-- The verdict\n', doc)
    doc = doc[:cut.start()] + verdict if cut else doc.replace('\nrollback;', verdict)
    return doc, wrapped


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = Path(sys.argv[1]).read_text()
    doc, n = convert(src)
    head = (f'-- Generated from {Path(sys.argv[1]).name} by '
            'tools/name-the-failing-check.py.\n'
            '-- NOT A TEST. It runs the same checks and names the ones that fail.\n'
            '-- Paste the whole thing into the SQL editor, Run without RLS.\n'
            '-- It rolls everything back, so it changes nothing.\n')
    print(head + doc)
    print(f'{n} assertions wrapped', file=sys.stderr)
