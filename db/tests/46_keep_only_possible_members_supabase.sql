-- =============================================================================
-- 0053, keep only what can be about a member, proved.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: a row whose email matches is kept; a row whose name is a
-- current member's surname and first initial is kept and names the member; a
-- row that is neither is not stored and leaves nothing in the history; a row
-- already stored that now fits neither is removed; an office decision is never
-- removed; the sync's reading leaves nothing in the history.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(12);

insert into public.membership_grades (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('zz-keep', 'ZZ TEST keep grade', 'ZZK', true, false, true, 94) on conflict (code) do nothing;
insert into public.people (id, given_name, family_name, email) values
  ('5e5e1111-0000-0000-0000-000000000001', 'Jonathan', 'O''Sheldonish', 'keep.one@test.invalid'),
  ('5e5e1111-0000-0000-0000-000000000002', 'Kim', 'Lapsedkeep', 'keep.two@test.invalid');
insert into auth.users (id, email) values ('5e5e0000-0000-0000-0000-000000000009', 'keep.office@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email)
values ('5e5e1111-0000-0000-0000-000000000009', '5e5e0000-0000-0000-0000-000000000009', 'Kit', 'Office', 'keep.office@test.invalid');
insert into public.role_grants (person_id, role_code) values ('5e5e1111-0000-0000-0000-000000000009', 'membership');
create or replace function sign_in_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $f$;
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select v.mid::uuid, v.pid::uuid, v.num, g.id, date '2021-01-01', v.act, v.st::public.member_status
  from (values ('5e5e2222-0000-0000-0000-000000000001','5e5e1111-0000-0000-0000-000000000001','TEST-K-0001', true, 'current'),
               ('5e5e2222-0000-0000-0000-000000000002','5e5e1111-0000-0000-0000-000000000002','TEST-K-0002', false, 'lapsed')) v(mid, pid, num, act, st)
  join public.membership_grades g on g.code = 'zz-keep';

update public.dynamics_runs set status = 'ok', finished_at = now() where status in ('running', 'requested');
update public.dynamics_feeds set email_field = 'e', email2_field = null, name_field = 'n', event_field = null,
       date_field = 'd', active = true where code = 'arca_agm';

select is((app.name_parts('Mr J. O''Sheldonish')).surname, 'osheldonish', 'a title is left out and a surname keeps letters only');
select is(cardinality(app.dyn_name_candidates('J Osheldonish')), 1, 'surname and first initial find a current member');
select is(cardinality(app.dyn_name_candidates('K Lapsedkeep')), 0, 'but not a lapsed one');

create temporary table runs (id uuid) on commit drop;
grant all on runs to service_role;
create temporary table hist (n int) on commit drop;
insert into hist select coalesce(max(id), 0) from public.audit_log;
set local role service_role;
insert into runs select (public.dynamics_run_begin() ->> 'run')::uuid;
create temporary table got (j jsonb) on commit drop;
grant all on got to service_role;
insert into got select public.dynamics_record((select id from runs), 'arca_agm', '{"fields":[]}', $j$[
  {"_ami_id":"k-1","e":"keep.one@test.invalid","n":"Somebody Else","d":"2026-06-01"},
  {"_ami_id":"k-2","e":"jon@elsewhere.invalid","n":"Jon O'Sheldonish","d":"2026-06-01"},
  {"_ami_id":"k-3","e":"stranger@elsewhere.invalid","n":"Pat Nobody","d":"2026-06-01"},
  {"_ami_id":"k-4","n":"No Email Atall","d":"2026-06-01"}
]$j$::jsonb);
reset role;
select ok(exists (select 1 from public.dynamics_attendance where dynamics_id = 'k-1'), 'an email that matches is kept');
select ok(exists (select 1 from public.dynamics_attendance where dynamics_id = 'k-2'), 'a name like a current member''s is kept');
select sign_in_as('5e5e0000-0000-0000-0000-000000000009');
select is((select possible from public.admin_cpd_feed_queue where id = (select id from public.dynamics_attendance where dynamics_id = 'k-2')),
          'Jonathan O''Sheldonish (TEST-K-0001)', 'and People to match names the possible member');
reset role;
select ok(not exists (select 1 from public.dynamics_attendance where dynamics_id in ('k-3', 'k-4')),
          'anybody else is not stored');
select is((select (j -> 'decided' ->> 'not_kept')::int from got), 2, 'and is counted as not kept');
select is((select count(*)::int from public.audit_log l
            where l.table_name = 'dynamics_attendance' and l.id > (select n from hist)
              and l.row_id not in (select id::text from public.dynamics_attendance)), 0,
          'the history holds nothing about anybody who was not kept');
select ok(not exists (select 1 from public.audit_log where after::text like '%stranger@elsewhere.invalid%'
                                                         or before::text like '%stranger@elsewhere.invalid%'),
          'and nothing about the stranger anywhere in it');

-- The member's name changes, so k-2 no longer fits: removed on the next read.
-- An office decision on another row is kept whatever.
update public.people set family_name = 'Renamed' where id = '5e5e1111-0000-0000-0000-000000000001';
update public.dynamics_attendance set decided_by = '5e5e1111-0000-0000-0000-000000000001', decided_at = now()
 where dynamics_id = 'k-1';
update public.dynamics_attendance set email = 'gone@elsewhere.invalid' where dynamics_id = 'k-1';
set local role service_role;
select public.dynamics_record((select id from runs), 'arca_agm', '{"fields":[]}', $j$[
  {"_ami_id":"k-1","e":"gone@elsewhere.invalid","n":"Somebody Else","d":"2026-06-01"},
  {"_ami_id":"k-2","e":"jon@elsewhere.invalid","n":"Jon O'Sheldonish","d":"2026-06-01"}
]$j$::jsonb);
reset role;
select ok(not exists (select 1 from public.dynamics_attendance where dynamics_id = 'k-2'),
          'a stored row that now fits neither rule is removed');
select ok(exists (select 1 from public.dynamics_attendance where dynamics_id = 'k-1'),
          'but a row the office has decided about stays');

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 12. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 12 TESTS PASSED' as result;

rollback;
