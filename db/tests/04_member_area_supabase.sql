-- =============================================================================
-- The members area, proved rather than asserted.
--
--   Supabase SQL editor: paste the whole file and run it
--
-- 01 proves nobody can read what they should not. 02 proves the office's actions
-- work for the right person. This file proves the third thing: that a member can
-- do everything the members area offers them, that a second member sitting beside
-- them can see none of it, and that the two rules the scheme rests on hold when
-- somebody pushes at them.
--
-- The two rules:
--   a member cannot make a CPD point count, only ask for one
--   a member cannot rewrite a post somebody has already answered
--
-- Same discipline as 01 and 02. Every fixture value is prefixed or uses a
-- .invalid address, so this runs on an empty database and on a populated one.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(51);

-- -----------------------------------------------------------------------------
-- Fixtures: two ordinary members and one member of staff
-- -----------------------------------------------------------------------------
insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('member', 'Member', 'MAMI', true, true, true, 2)
on conflict (code) do nothing;

insert into public.cpd_activity_types (code, name, is_core, sort_order, points, member_can_log) values
  ('mtest_core', 'Test core activity', true,  90, 1, true),
  ('mtest_non',  'Test non core activity', false, 91, 1, true)
on conflict (code) do nothing;

insert into public.cpd_requirements (year, grade_id, core_required, non_core_required)
select extract(year from current_date)::int, g.id, 5, 5
  from public.membership_grades g where g.code = 'member'
on conflict (year, grade_id) do nothing;

insert into public.forum_categories (slug, name, sort_order) values
  ('mtest-cat', 'Test category for the members area', 90)
on conflict (slug) do nothing;

insert into auth.users (id, email) values
  ('11110000-0000-0000-0000-000000000001', 'mem.one@test.invalid'),
  ('11110000-0000-0000-0000-000000000002', 'mem.two@test.invalid'),
  ('11110000-0000-0000-0000-000000000003', 'mem.staff@test.invalid'),
  ('11110000-0000-0000-0000-000000000004', 'mem.lapsed@test.invalid');

insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('22220000-0000-0000-0000-000000000001','11110000-0000-0000-0000-000000000001','Mina','One','mem.one@test.invalid'),
  ('22220000-0000-0000-0000-000000000002','11110000-0000-0000-0000-000000000002','Theo','Two','mem.two@test.invalid'),
  ('22220000-0000-0000-0000-000000000003','11110000-0000-0000-0000-000000000003','Stella','Staff','mem.staff@test.invalid'),
  ('22220000-0000-0000-0000-000000000004','11110000-0000-0000-0000-000000000004','Lena','Lapsed','mem.lapsed@test.invalid');

insert into public.role_grants (person_id, role_code)
values ('22220000-0000-0000-0000-000000000003', 'membership');

insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select v.mid::uuid, v.pid::uuid, v.num, g.id, date '2021-01-01', v.act, v.st::public.member_status
  from (values
    ('33330000-0000-0000-0000-000000000001','22220000-0000-0000-0000-000000000001','TEST-M-0001', true,  'current'),
    ('33330000-0000-0000-0000-000000000002','22220000-0000-0000-0000-000000000002','TEST-M-0002', true,  'current'),
    ('33330000-0000-0000-0000-000000000004','22220000-0000-0000-0000-000000000004','TEST-M-0004', false, 'lapsed')
  ) as v(mid, pid, num, act, st),
  public.membership_grades g
 where g.code = 'member';

insert into public.member_preferences (member_id) values
  ('33330000-0000-0000-0000-000000000001'),
  ('33330000-0000-0000-0000-000000000002'),
  ('33330000-0000-0000-0000-000000000004');

-- Theo shows his photograph publicly, Mina does not. That one difference is what
-- the forum view is tested against.
update public.member_preferences set photo_on_public_page = true
 where member_id = '33330000-0000-0000-0000-000000000002';
update public.people set photo_path = '22220000-0000-0000-0000-000000000002/square-x.jpg',
                         photo_consent = true, photo_consent_at = now()
 where id = '22220000-0000-0000-0000-000000000002';

-- -----------------------------------------------------------------------------
-- Helpers, the same two 01 and 02 use
-- -----------------------------------------------------------------------------
create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function try_dml(p_sql text) returns void language plpgsql as $$
begin execute p_sql; end $$;

-- =============================================================================
-- 1. my_profile
-- =============================================================================
select sign_in_as('11110000-0000-0000-0000-000000000001');

select is((select membership_number from public.my_profile),
          'TEST-M-0001',
          'A member reads their own record through my_profile');

select is((select count(*) from public.my_profile), 1::bigint,
          'and gets exactly one row, whoever else is in the table');

select is((select cpd_required_core from public.my_profile), 5::numeric,
          'and the requirement for their grade comes with it');

select is((select grade from public.my_profile), 'Member',
          'and the grade is spelled out rather than left as an id');

-- =============================================================================
-- 2. The profile a member may change, and the record they may not
-- =============================================================================
select lives_ok(
  $$ select public.update_my_profile(p_mobile => '07700 900001') $$,
  'A member may change their own telephone number');

select is((select mobile from public.my_profile), '07700 900001',
          'and it is theirs afterwards');

-- The membership record is the office's. This is the line the whole scheme sits
-- on: a member who can edit their own grade can award themselves one.
--
-- Note what this asserts, and what it deliberately does not. Row level security
-- does not raise when a USING clause excludes a row: the statement succeeds and
-- updates NOTHING. So the check is on the row, not on an exception. Asserting a
-- refusal here would be asserting a behaviour Postgres does not have, and would
-- pass for the wrong reason the day the policy was removed.
select lives_ok(
  $$ update public.members set current_job_title = 'Chief Executive of Everything'
      where id = '33330000-0000-0000-0000-000000000001' $$,
  'A member''s attempt to edit their own membership row does not raise');

select is(
  (select current_job_title from public.my_profile),
  null,
  'because it silently changes nothing, which is what row level security does');

select is(
  (select count(*) from public.members where id = '33330000-0000-0000-0000-000000000002'),
  0::bigint,
  'and cannot see another member''s membership row');

-- The people row is the other half of that line, and it behaves differently from
-- the members row above. There IS a policy letting a member update their own
-- people row, so the statement is not silently excluded: it reaches the table and
-- the trigger from 0028 refuses it by name. Which is the better failure of the
-- two, because a field that appears to save and does not is worse than one that
-- says no.
--
-- post_nominals first, because it is the one that matters. public_register reads
-- it straight off this row, so a member who could set it could put the letters of
-- a grade they do not hold on the page a duty holder checks.
select throws_ok(
  $$ update public.people set post_nominals = 'FAMI'
      where id = '22220000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'A member cannot give themselves post nominals on their own people row');

select is(
  (select post_nominals from public.people
    where id = '22220000-0000-0000-0000-000000000001'),
  null,
  'and the register still shows no letters after their name');

select throws_ok(
  $$ update public.people set family_name = 'Renamed'
      where id = '22220000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'nor rename themselves');

select throws_ok(
  $$ update public.people set email = 'someone-else@example.invalid'
      where id = '22220000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'nor change the address the office writes to');

-- The three they do own, straight at the table rather than through the function,
-- because the trigger has to allow the route the page does not use as well.
select lives_ok(
  $$ update public.people set mobile = '07700 900123'
      where id = '22220000-0000-0000-0000-000000000001' $$,
  'A member may change their telephone number directly');

select lives_ok(
  $$ update public.people
        set home_address = '{"lines":["1 High Street"]}'::jsonb,
            business_address = '{"lines":["2 Trade Park"]}'::jsonb
      where id = '22220000-0000-0000-0000-000000000001' $$,
  'and both addresses');

select lives_ok(
  $$ update public.member_preferences set list_on_register = false
      where member_id = '33330000-0000-0000-0000-000000000001' $$,
  'A member may change their own preferences');

select is(
  (select count(*) from public.member_preferences
    where member_id = '33330000-0000-0000-0000-000000000002'),
  0::bigint,
  'and cannot see, or therefore change, anybody else''s');

-- =============================================================================
-- 3. The photograph
-- =============================================================================
select is((select folder from public.photo_upload_target()),
          '22220000-0000-0000-0000-000000000001',
          'photo_upload_target hands back the member''s own folder, not one they asked for');

select lives_ok(
  $$ select public.set_my_photo(
       '22220000-0000-0000-0000-000000000001/square-a.jpg',
       '22220000-0000-0000-0000-000000000001/strip-a.jpg') $$,
  'A member may record a photograph in their own folder');

select is((select photo_consent from public.my_profile), true,
          'and the consent is recorded with it rather than left for later');

select isnt((select photo_consent_at from public.people
              where id = '22220000-0000-0000-0000-000000000001'), null,
          'and it is dated, which the check constraint on people requires');

-- The path is the only thing a caller controls here, so it is the only thing
-- worth attacking.
select throws_ok(
  $$ select public.set_my_photo(
       '22220000-0000-0000-0000-000000000002/square-a.jpg',
       '22220000-0000-0000-0000-000000000002/strip-a.jpg') $$,
  '42501',
  null,
  'A member cannot point their record at somebody else''s folder');

select lives_ok(
  $$ select public.clear_my_photo() $$,
  'A member may remove their own photograph');

select is((select photo_consent from public.my_profile), false,
          'and the consent goes with it rather than outliving the picture');

-- =============================================================================
-- 4. CPD: asking for a point, and not being able to award one
-- =============================================================================
select lives_ok(
  $$ select public.log_cpd(current_date - 7,
       (select id from public.cpd_activity_types where code = 'mtest_core'),
       'A test activity') $$,
  'A member may log an activity');

select is((select status from public.my_cpd where title = 'A test activity'),
          'pending',
          'and it arrives pending, which is the whole point');

select is((select how_recorded from public.my_cpd where title = 'A test activity'),
          'self_declared',
          'and it is marked as self declared however it was asked for');

-- A member choosing is_core is a member deciding what counts as asbestos
-- technical competence. It comes from the activity type instead.
select is((select is_core from public.my_cpd where title = 'A test non core activity'),
          null,
          'nothing yet logged against the non core type');

select lives_ok(
  $$ select public.log_cpd(current_date - 7,
       (select id from public.cpd_activity_types where code = 'mtest_non'),
       'A test non core activity') $$,
  'A member may log a non core activity');

select is((select is_core from public.my_cpd where title = 'A test non core activity'),
          false,
          'and it is non core because the ACTIVITY TYPE says so, not because they did');

select is((select core_points from public.my_cpd_summary
            where year = extract(year from current_date)::int), 0::numeric,
          'A pending entry counts for nothing at all');

select is((select pending_count from public.my_cpd_summary
            where year = extract(year from current_date)::int), 2::bigint,
          'and shows in the waiting count instead');

select throws_ok(
  $$ select try_dml('update public.cpd_entries set status = ''accepted''
                      where member_id = ''33330000-0000-0000-0000-000000000001''') $$,
  null, null,
  'A member cannot accept their own CPD entry');

select throws_ok(
  $$ select public.log_cpd(current_date + 30,
       (select id from public.cpd_activity_types where code = 'mtest_core'),
       'Something I have not done yet') $$,
  '22023', null,
  'and cannot log an activity that has not happened yet');

-- From 0038 the member does not say what an entry is worth at all: the
-- activity does. The old fourth argument was the points claimed, and passing it
-- now finds no function. Was "cannot claim ninety nine points"; the rule moved
-- from a range check to there being nothing to claim with.
select throws_ok(
  $$ select public.log_cpd(current_date - 7,
       (select id from public.cpd_activity_types where code = 'mtest_core'),
       'Greedy', 99::numeric) $$,
  '42883', null,
  'and cannot say how many points it is worth: the activity decides');

-- =============================================================================
-- 5. The forum
-- =============================================================================
select lives_ok(
  $$ select public.start_thread(
       (select id from public.forum_categories where slug = 'mtest-cat'),
       'A test discussion about clearance', 'The opening post.') $$,
  'A member may start a discussion');

select is((select count(*) from public.forum_thread_list
            where title = 'A test discussion about clearance'), 1::bigint,
          'and it appears in the list with its author');

select is((select given_name from public.forum_thread_list
            where title = 'A test discussion about clearance'), 'Mina',
          'and the author has a name, which is the reason these views exist');

-- Mina cannot read Theo's people row. Without the view she would see a post by
-- nobody, which is how this was found.
select sign_in_as('11110000-0000-0000-0000-000000000002');

select is((select count(*) from public.people
            where id = '22220000-0000-0000-0000-000000000001'), 0::bigint,
          'A member still cannot read another member''s people row directly');

select is((select given_name from public.forum_thread_list
            where title = 'A test discussion about clearance'), 'Mina',
          'but can see who wrote a post, through the view and only through it');

select is((select photo_path from public.forum_post_list
            where body = 'The opening post.'), null,
          'A member whose photograph is not public does not have it shown in the forum');

select lives_ok(
  $$ select public.reply_to_thread(
       (select id from public.forum_threads where title = 'A test discussion about clearance'),
       'A reply from the second member.') $$,
  'A second member may reply');

-- The rule, and the reason for it: changing a post that has already been
-- answered makes nonsense of the answer.
select sign_in_as('11110000-0000-0000-0000-000000000001');

select is((select can_edit from public.forum_post_list where body = 'The opening post.'),
          false,
          'Once a post has a reply its author is told they can no longer edit it');

select is((select count(*) from public.forum_post_list
            where body = 'The opening post.'
              and body <> 'Rewritten after the fact'), 1::bigint,
          'and the post still says what it said');

-- Again: no exception, no rows. The post is what proves it, not an error code.
select lives_ok(
  $$ update public.forum_posts set body = 'Rewritten after the fact'
      where body = 'The opening post.' $$,
  'The edit is attempted');

select is(
  (select count(*) from public.forum_posts where body = 'Rewritten after the fact'),
  0::bigint,
  'and the database changed nothing, rather than the page merely hiding the link');

-- =============================================================================
-- 6. An inactive membership
-- =============================================================================
select sign_in_as('11110000-0000-0000-0000-000000000004');

select is((select count(*) from public.forum_thread_list), 0::bigint,
          'A member whose membership is switched off sees no forum at all');

select throws_ok(
  $$ select public.start_thread(
       (select id from public.forum_categories where slug = 'mtest-cat'),
       'Should not be possible', 'Nor this.') $$,
  null, null,
  'and cannot start a discussion');

select is((select count(*) from public.my_profile), 1::bigint,
          'but can still see their own record, which is where they find out why');

-- =============================================================================
-- 7. The other side of the column guard
-- =============================================================================
-- A rule that stops a member is only half a rule. If it also stopped the office
-- correcting a misspelled name it would be discovered by a telephone call rather
-- than by a test, so the same statements run again as staff.
select sign_in_as('11110000-0000-0000-0000-000000000003');

select lives_ok(
  $$ update public.people set post_nominals = 'MAMI'
      where id = '22220000-0000-0000-0000-000000000001' $$,
  'The office may set post nominals on a member''s record');

select lives_ok(
  $$ update public.people set family_name = 'Corrected'
      where id = '22220000-0000-0000-0000-000000000001' $$,
  'and correct a name, which is the whole reason this is a trigger rather than a grant');

select * from finish();

-- A run that scrolls past is a run nobody reads. This turns any failure into a
-- red error you cannot miss.
do $$
declare v_failed integer := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 51. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 51 TESTS PASSED' as result;

rollback;
