# 0045  A certificate counts once

Site 69, admin 25, database 32.

Steve, 31 October: a certificate is uploaded once; uploaded a second time it
is declined. And Claude checks certificates now.

## What it does

**1. The same file is refused.** Evidence now goes through the site, which
checks the file really is a PDF or a picture (whatever its name says) and takes
its fingerprint (SHA-256: identical files have identical fingerprints). If that
file is already on any CPD entry that has not been rejected, anybody's, it is
refused with "This certificate has already been used for CPD. A certificate
counts once." The form checks before anything is logged, so the member is told
at once. If an entry is rejected for another reason, its certificate may be
used again on a corrected entry.

**2. Claude reads every certificate.** Ask Claude on CPD to review now reads
the reflections first, then the certificates on pending entries: who it was
awarded to, the course, who issued it, the date and the certificate number.
Claude is sent the file and the entry's activity, title, provider and date,
**not the member's name**. The database then checks, and the card says:

- **certificate number already used**, and on whose entry, however the number
  was written (AB-12/34 and ab1234 are the same)
- **in the name of somebody else** than the member
- **a date far from the entry's** (more than a month)
- anything Claude noticed that looks altered
- a file too large for Claude to read (over 10MB for a PDF, 5MB for a
  picture), to open by hand

Claude decides nothing. On a certificate there is no recommendation: the facts
are on the card and the office declines.

**3. A likely repeat is flagged.** A second entry by the same member for the
same activity, on the same date or with the same title, says "Possible repeat
of ..." on the card. A new scan of an old certificate has a different
fingerprint, so this and the certificate number are what catch it.

**Evidence on the card.** The office can now open a CPD entry's files from
the card (Evidence), which it could not before.

**Members can no longer write to the evidence bucket or table directly.**
Evidence attached before this release has no fingerprint, so it cannot be
matched as the same file; Claude still reads it, and the number check still
works on it.

## Before real members

The privacy notice line about AI review now has to cover certificates as well
as reflections: they are sent to Claude to be read.

## Run it in this order

1. **Migration 0045** in the SQL editor.
2. **Test 32**, `tests/32_certificates_once_supabase.sql`, Run without RLS.
   Expect `ALL 30 TESTS PASSED`.
3. **Site 69**, then **admin 25** (tag V25).

## Then check

1. As the test member, log an External training course with a PDF
   certificate. It is accepted.
2. Log another with **the same file**. Before anything is logged: "That
   certificate has already been used for CPD".
3. Admin, CPD to review, **Ask Claude**. The first entry shows "Certificate,
   as Claude read it" with the name, course and number. If it is a real
   certificate in your name: "Name and number check out."
4. **Evidence** on the card opens the file.

## Checked here

639 database tests; staging's order replayed. Test 32 went red when the
fingerprint check was removed from either end and when the number check was
taken out. Test 33 (29, the Worker) went red when the browser's word for the
file type was trusted and when a refused file was left in storage. Tests 21
(99) and 30 (26) cover the form and the card.
