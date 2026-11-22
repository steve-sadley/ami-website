-- =============================================================================
-- 0045, a certificate counts once, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: evidence is written only through the Worker; a file already
-- used on an entry that counts is refused, whoever uploads it; Claude is sent
-- the certificate and nothing about the person; a certificate number used
-- before, a holder who is not the member, and a likely repeat entry all show
-- on the card; Claude decides nothing.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(30);

insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('member', 'Member', 'MAMI', true, true, true, 2)
on conflict (code) do nothing;
insert into auth.users (id, email) values
  ('5d5d0000-0000-0000-0000-000000000001', 'once.one@test.invalid'),
  ('5d5d0000-0000-0000-0000-000000000002', 'once.two@test.invalid'),
  ('5d5d0000-0000-0000-0000-000000000009', 'once.office@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('5d5d1111-0000-0000-0000-000000000001','5d5d0000-0000-0000-0000-000000000001','Cerys','Cert','once.one@test.invalid'),
  ('5d5d1111-0000-0000-0000-000000000002','5d5d0000-0000-0000-0000-000000000002','Dewi','Dup','once.two@test.invalid'),
  ('5d5d1111-0000-0000-0000-000000000009','5d5d0000-0000-0000-0000-000000000009','Olwen','Office','once.office@test.invalid');
insert into public.role_grants (person_id, role_code) values ('5d5d1111-0000-0000-0000-000000000009', 'membership');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select v.mid::uuid, v.pid::uuid, v.num, g.id, date '2021-01-01', true, 'current'
  from (values ('5d5d2222-0000-0000-0000-000000000001','5d5d1111-0000-0000-0000-000000000001','TEST-O-0001'),
               ('5d5d2222-0000-0000-0000-000000000002','5d5d1111-0000-0000-0000-000000000002','TEST-O-0002')) v(mid, pid, num),
       public.membership_grades g where g.code = 'member';

create or replace function type_id(c text) returns uuid language sql as $$
  select id from public.cpd_activity_types where code = c $$;
create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function h(c text) returns text language sql as $$ select repeat(c, 64) $$;
create temporary table got (k text, j jsonb) on commit drop;
grant all on got to public;

-- Four pending course entries: two for member one, two for member two.
insert into public.cpd_entries
  (id, member_id, year, occurred_on, activity_type_id, title, points, is_core, status, how_recorded)
values
  ('5d5d4444-0000-0000-0000-000000000001', '5d5d2222-0000-0000-0000-000000000001', extract(year from current_date)::int,
   current_date - 10, type_id('external_training'), 'ZZ TEST face fit', 1, false, 'pending', 'self_declared'),
  ('5d5d4444-0000-0000-0000-000000000002', '5d5d2222-0000-0000-0000-000000000001', extract(year from current_date)::int,
   current_date - 10, type_id('external_training'), 'ZZ TEST face fit again', 1, false, 'pending', 'self_declared'),
  ('5d5d4444-0000-0000-0000-000000000003', '5d5d2222-0000-0000-0000-000000000002', extract(year from current_date)::int,
   current_date - 9, type_id('external_training'), 'ZZ TEST borrowed', 1, false, 'pending', 'self_declared'),
  ('5d5d4444-0000-0000-0000-000000000004', '5d5d2222-0000-0000-0000-000000000002', extract(year from current_date)::int,
   current_date - 3, type_id('qualification'), 'ZZ TEST NVQ', 2, false, 'pending', 'self_declared');

-- -----------------------------------------------------------------------------
-- 1. Members cannot write evidence themselves
-- -----------------------------------------------------------------------------
select sign_in_as('5d5d0000-0000-0000-0000-000000000001');
select throws_ok($$ insert into public.cpd_evidence (cpd_entry_id, storage_path, original_name, byte_size, content_type)
                    values ('5d5d4444-0000-0000-0000-000000000001', 'x/y.pdf', 'y.pdf', 10, 'application/pdf') $$,
  '42501', null, 'a member cannot write an evidence row directly any more');
select is(public.cpd_evidence_seen(h('a')), false, 'a file nobody has used is not seen');
insert into got select 'up1', public.cpd_evidence_begin('5d5d4444-0000-0000-0000-000000000001', h('a'), 'cert.pdf', 'application/pdf', 1000);
select ok((select j ->> 'path' from got where k = 'up1') like '5d5d1111-0000-0000-0000-000000000001/5d5d4444-0000-0000-0000-000000000001-%.pdf',
          'a member may begin an upload to their own entry, into their own folder');
select throws_ok($$ select public.cpd_evidence_begin('5d5d4444-0000-0000-0000-000000000003', h('b'), 'x.pdf', 'application/pdf', 10) $$,
  '42501', null, 'but not to somebody else''s entry');
select throws_ok($$ select public.cpd_evidence_begin('5d5d4444-0000-0000-0000-000000000001', h('b'), 'x.exe', 'application/x-msdownload', 10) $$,
  '22023', null, 'and only a PDF or a picture');
select throws_ok($$ select public.cpd_evidence_record((select (j ->> 'upload_id')::uuid from got where k = 'up1'), repeat('a', 64)) $$,
  '42501', null, 'a member cannot finish an upload: only the Worker, which has the bytes, can');
reset role;
select ok(not has_function_privilege('authenticated', 'public.cpd_evidence_record(uuid,text)', 'execute'),
          'recording evidence is granted to the service role and nobody else');

-- -----------------------------------------------------------------------------
-- 2. The Worker records it, and the same file is refused next time
-- -----------------------------------------------------------------------------
set local role service_role;
select throws_ok($$ select public.cpd_evidence_record((select (j ->> 'upload_id')::uuid from got where k = 'up1'), repeat('c', 64)) $$,
  '42501', null, 'the Worker cannot record a different file from the one asked about');
insert into got select 'ev1', to_jsonb(public.cpd_evidence_record((select (j ->> 'upload_id')::uuid from got where k = 'up1'), repeat('a', 64)));
reset role;
select ok((select sha256 = h('a') and signature_ok from public.cpd_evidence where id = (select (j #>> '{}')::uuid from got where k = 'ev1')),
          'the evidence is stored with its fingerprint, checked by the Worker');

select sign_in_as('5d5d0000-0000-0000-0000-000000000002');
select is(public.cpd_evidence_seen(h('a')), true, 'another member sees that the file has been used');
select throws_ok($$ select public.cpd_evidence_begin('5d5d4444-0000-0000-0000-000000000003', repeat('a', 64), 'cert.pdf', 'application/pdf', 1000) $$,
  '23505', 'This certificate has already been used for CPD. A certificate counts once.',
  'and cannot use the same certificate: refused, in words');
reset role;
select sign_in_as('5d5d0000-0000-0000-0000-000000000001');
select throws_ok($$ select public.cpd_evidence_begin('5d5d4444-0000-0000-0000-000000000002', repeat('a', 64), 'cert.pdf', 'application/pdf', 1000) $$,
  '23505', null, 'nor can the member who used it first, on a second entry');
reset role;

-- Two uploads of one new file before either is finished: the second is refused.
select sign_in_as('5d5d0000-0000-0000-0000-000000000001');
insert into got select 'r1', public.cpd_evidence_begin('5d5d4444-0000-0000-0000-000000000002', h('d'), 'n.pdf', 'application/pdf', 900);
reset role;
select sign_in_as('5d5d0000-0000-0000-0000-000000000002');
insert into got select 'r2', public.cpd_evidence_begin('5d5d4444-0000-0000-0000-000000000003', h('d'), 'n.pdf', 'application/pdf', 900);
reset role;
set local role service_role;
insert into got select 'evd', to_jsonb(public.cpd_evidence_record((select (j ->> 'upload_id')::uuid from got where k = 'r1'), repeat('d', 64)));
select ok((select j #>> '{}' from got where k = 'evd') is not null, 'two members race the same new file: the first is stored');
select throws_ok($$ select public.cpd_evidence_record((select (j ->> 'upload_id')::uuid from got where k = 'r2'), repeat('d', 64)) $$,
  '23505', null, 'and the second refused when it is recorded');
reset role;

-- Rejected for another reason: the certificate may be used again.
select sign_in_as('5d5d0000-0000-0000-0000-000000000009');
select public.review_cpd(array['5d5d4444-0000-0000-0000-000000000001'::uuid], 'rejected', 'Wrong activity: log it as a qualification.');
reset role;
select sign_in_as('5d5d0000-0000-0000-0000-000000000001');
select is(public.cpd_evidence_seen(h('a')), false,
          'once the entry it was on is rejected, the certificate may be used on a corrected one');
reset role;

-- -----------------------------------------------------------------------------
-- 3. Claude reads the certificate
-- -----------------------------------------------------------------------------
-- Two more files, placed as the Worker would: one on member two's NVQ, and one
-- far too large for Claude to read.
insert into public.cpd_evidence (id, cpd_entry_id, storage_path, original_name, byte_size, content_type, signature_ok, sha256, uploaded_at)
values ('5d5d5555-0000-0000-0000-000000000004', '5d5d4444-0000-0000-0000-000000000004',
        '5d5d1111-0000-0000-0000-000000000002/nvq.jpg', 'nvq.jpg', 200000, 'image/jpeg', true, h('e'), now() - interval '1 hour'),
       ('5d5d5555-0000-0000-0000-000000000005', '5d5d4444-0000-0000-0000-000000000004',
        '5d5d1111-0000-0000-0000-000000000002/huge.jpg', 'huge.jpg', 9000000, 'image/jpeg', true, h('f'), now());

select sign_in_as('5d5d0000-0000-0000-0000-000000000001');
select throws_ok($$ select public.ai_certificate_begin(2) $$, '42501', null, 'a member cannot ask Claude to read anything');
reset role;

select sign_in_as('5d5d0000-0000-0000-0000-000000000009');
insert into got select 'cb', public.ai_certificate_begin(3);
reset role;
select ok((select count(*) from got, jsonb_array_elements(j -> 'items') i where k = 'cb') >= 2,
          'staff ask, and the certificates waiting are handed over');
select ok(not exists (select 1 from got, jsonb_array_elements(j -> 'items') i where k = 'cb'
                       and i ->> 'id' = '5d5d5555-0000-0000-0000-000000000005'),
          'but never one too large for Claude to read');
select ok((select bool_and((select array_agg(x order by x) from jsonb_object_keys(i) x)
                           = array['activity','byte_size','content_type','id','occurred_on','path','provider','title'])
             from got, jsonb_array_elements(j -> 'items') i where k = 'cb'),
          'each carries the file and the entry''s activity, title, provider and date, and nothing else');
select ok((select j::text from got where k = 'cb') !~* '(Cerys|Dewi|TEST-O-|once\.)',
          'no name, no membership number and no address');

select sign_in_as('5d5d0000-0000-0000-0000-000000000009');
select throws_ok($$ select public.ai_certificate_record((select (j #>> '{}')::uuid from got where k = 'evd'),
                     '5d5d1111-0000-0000-0000-000000000009', 'x', true, true, 'Cerys Cert', 'Face fit', 'ACME', '2026-01-01', 'X1', null) $$,
  '42501', null, 'staff cannot write what Claude read');
reset role;

set local role service_role;
-- Member one's face fit certificate, read correctly.
select isnt(public.ai_certificate_record((select (j #>> '{}')::uuid from got where k = 'evd'),
              '5d5d1111-0000-0000-0000-000000000009', 'claude-test', true, true,
              'Ms Cerys Cert', 'Face fit testing', 'ACME Training', to_char(current_date - 10, 'YYYY-MM-DD'), 'AB-12/34', null),
            null, 'the Worker records what Claude read');
-- Member two's NVQ certificate: somebody else's name, and the same number.
select isnt(public.ai_certificate_record('5d5d5555-0000-0000-0000-000000000004',
              '5d5d1111-0000-0000-0000-000000000009', 'claude-test', true, true,
              'John Smith', 'NVQ Level 3', 'Awarding Body', to_char(current_date - 200, 'YYYY-MM-DD'), 'ab1234', 'Looks edited near the date.'),
            null, 'and a second one');
reset role;

select sign_in_as('5d5d0000-0000-0000-0000-000000000009');
select is((select cert_holder_matches from public.admin_cpd_queue where id = '5d5d4444-0000-0000-0000-000000000002'), true,
          'a certificate in the member''s own name is shown as matching');
select is((select cert_holder_matches from public.admin_cpd_queue where id = '5d5d4444-0000-0000-0000-000000000004'), false,
          'one in somebody else''s name is shown as NOT matching');
select ok((select cert_number_used_on from public.admin_cpd_queue where id = '5d5d4444-0000-0000-0000-000000000004') like 'Cerys Cert,%',
          'the same certificate number, written differently, is shown as already used, and by whom');
select is((select cert_date_gap_days from public.admin_cpd_queue where id = '5d5d4444-0000-0000-0000-000000000004'), 197,
          'and how far the certificate''s date is from the entry''s');
select is((select cert_files_too_large from public.admin_cpd_queue where id = '5d5d4444-0000-0000-0000-000000000004'), 1,
          'a file too large for Claude is counted, for the office to open');
select is((select status::text from public.cpd_entries where id = '5d5d4444-0000-0000-0000-000000000004'), 'pending',
          'AND NOTHING IS DECIDED: the office declines it');
reset role;

-- -----------------------------------------------------------------------------
-- 4. A likely repeat
-- -----------------------------------------------------------------------------
select sign_in_as('5d5d0000-0000-0000-0000-000000000009');
select ok((select possible_repeat from public.admin_cpd_queue where id = '5d5d4444-0000-0000-0000-000000000002') is null,
          'an entry whose twin was rejected is not called a repeat');
reset role;
insert into public.cpd_entries
  (id, member_id, year, occurred_on, activity_type_id, title, points, is_core, status, how_recorded)
values ('5d5d4444-0000-0000-0000-000000000006', '5d5d2222-0000-0000-0000-000000000002', extract(year from current_date)::int,
        current_date - 9, type_id('external_training'), 'ZZ TEST same day course', 1, false, 'pending', 'self_declared');
select sign_in_as('5d5d0000-0000-0000-0000-000000000009');
select ok((select possible_repeat from public.admin_cpd_queue where id = '5d5d4444-0000-0000-0000-000000000006') like 'ZZ TEST borrowed,%',
          'a second course by the same member on the same day is flagged as a likely repeat');
reset role;

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 30. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 30 TESTS PASSED' as result;

rollback;
