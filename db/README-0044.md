# 0044  A reflection sent with its course certificate earns both

Site 68, admin 24, database 31.

Steve, 31 October: there are points for certificates and points for
reflections, so a reflection sent with its certificate should earn both.

**For members, on My CPD, Log an activity:** choosing Reflection following a
training course now labels the evidence box **Course certificate**. Attach the
certificate and the form asks what it is for: **External training course or
seminar** (1 point) or **Formal asbestos qualification** (2 points). Sending
logs two entries at once, the reflection and the course, with the certificate
on the course entry. It also says that an ARCA course should be left off,
because ARCA's records give that point automatically and logging it here would
count it twice. Without a certificate, a reflection is logged on its own as
before.

**For the office:** each of the pair says "Logged together with its ...
entry" and each is decided on its own. A good certificate with a thin
reflection earns the course and not the reflection. Claude reads only the
reflection.

## Run it in this order

1. **Migration 0044** in the SQL editor.
2. **Test 31**, `tests/31_reflection_with_certificate_supabase.sql`, Run
   without RLS. Expect `ALL 14 TESTS PASSED`.
3. **Site 68**, then **admin 24** (tag V24).

## Then check

1. As the test member, My CPD, Log an activity, Reflection following a
   training course. The box says Course certificate.
2. Attach any PDF. "The certificate is for" appears with two choices.
3. Write 500 words, a title, and send. The log shows two entries waiting.
4. Admin, CPD to review: both, each saying it was logged with the other.

## Checked here

609 database tests. Test 31 went red when the pairing could be changed by a
member and when any loggable activity could be the certificate half. Test 21
(97) went red when the form sent the reflection alone.
