-- =============================================================================
-- Make a test member, so the members area has somebody to be.
--
-- Run this in the Supabase SQL editor on ami-staging. It is idempotent: run it
-- as often as you like and it will not make a second of anything.
--
-- Put the email address of an account that has ALREADY SIGNED IN at least once
-- on the line below. Signing in is what creates the auth.users row, and this
-- attaches an AMI record to it. If nobody has signed in with that address yet,
-- the script says so and stops rather than creating a record with nothing behind
-- it.
--
-- Everything it creates is prefixed TEST so it is obvious in the admin app and
-- easy to find again. Clearing up is at the bottom of this file.
-- =============================================================================

do $$
declare
  v_email  text := 'steve.sadley@arca.org.uk';   -- <<< CHANGE THIS IF YOU WANT
  v_given  text := 'Steve';                      -- <<< and these two
  v_family text := 'Sadley';
  v_uid    uuid;
  v_person uuid;
  v_member uuid;
  v_grade  uuid;
  v_year   integer := extract(year from current_date)::int;
  v_slug   text;
begin
  select id into v_uid from auth.users where lower(email) = lower(v_email);
  if v_uid is null then
    raise exception 'No account has signed in with % yet. Sign in at /login first, then run this again.', v_email;
  end if;

  select id into v_grade from public.membership_grades where code = 'member';
  if v_grade is null then
    raise exception 'There is no grade with the code "member". Load the starting lists first.';
  end if;

  -- The person. If one already exists for this address it is reused and simply
  -- attached to the account, which is what link_account does at sign in anyway.
  select id into v_person from public.people where lower(email) = lower(v_email);
  if v_person is null then
    insert into public.people (auth_user_id, given_name, family_name, email)
    values (v_uid, v_given, v_family, v_email)
    returning id into v_person;
  else
    update public.people set auth_user_id = coalesce(auth_user_id, v_uid)
     where id = v_person;
  end if;

  -- The membership. Active, because an inactive one shows you the "not active"
  -- state and nothing else, which is worth seeing once but not first.
  select id into v_member from public.members where person_id = v_person;
  if v_member is null then
    insert into public.members
      (person_id, membership_number, grade_id, joined_on, is_active, status)
    values (v_person, 'TEST-' || to_char(now(), 'YYMMDDHH24MI'), v_grade,
            date '2019-03-01', true, 'current')
    returning id into v_member;
  else
    update public.members set is_active = true, status = 'current' where id = v_member;
  end if;

  insert into public.member_preferences (member_id) values (v_member)
  on conflict (member_id) do nothing;

  -- A slug, so /m/<slug> resolves and the profile page can link to it.
  if not exists (select 1 from public.register_slugs
                  where member_id = v_member and retired_at is null) then
    v_slug := regexp_replace(lower(v_given || '-' || v_family), '[^a-z0-9]+', '-', 'g');
    while exists (select 1 from public.register_slugs where slug = v_slug) loop
      v_slug := v_slug || '-' || floor(random() * 100)::text;
    end loop;
    insert into public.register_slugs (slug, member_id) values (v_slug, v_member);
  end if;

  -- A requirement for this year and this grade, or the rings have nothing to
  -- measure against and quietly fall back to five and five.
  insert into public.cpd_requirements (year, grade_id, core_required, non_core_required)
  values (v_year, v_grade, 5, 5)
  on conflict (year, grade_id) do nothing;

  raise notice 'Ready. person=% member=% slug=%', v_person, v_member,
    (select slug from public.register_slugs
      where member_id = v_member and retired_at is null);
end $$;


-- =============================================================================
-- Optional: a few CPD entries, so the rings, the chart and the log have
-- something in them.
--
-- Skip this the first time if you would rather see the empty state, which is
-- worth seeing, because most members will meet it before they meet anything else.
-- =============================================================================
do $$
declare
  v_email  text := 'steve.sadley@arca.org.uk';   -- <<< THE SAME ADDRESS
  v_member uuid;
  v_person uuid;
  v_core   uuid;
  v_non    uuid;
  v_year   integer := extract(year from current_date)::int;
begin
  select m.id, m.person_id into v_member, v_person
    from public.members m
    join public.people p on p.id = m.person_id
   where lower(p.email) = lower(v_email);
  if v_member is null then return; end if;

  select id into v_core from public.cpd_activity_types
   where is_core and active order by sort_order limit 1;
  select id into v_non from public.cpd_activity_types
   where not is_core and active order by sort_order limit 1;
  if v_core is null or v_non is null then
    raise notice 'No CPD activity types are set up, so no entries were created.';
    return;
  end if;

  -- An accepted entry has to name its reviewer: the check constraint on
  -- cpd_entries says a decision is attributed or it did not happen.
  --
  -- None of these is marked automatic, and that is the database refusing rather
  -- than an oversight. cpd_automatic_needs_rule_and_source says an automatic
  -- award must point at the rule that valued it and the source that evidenced it,
  -- and nothing in phase 1 writes either, so nothing in phase 1 can honestly
  -- write an automatic entry. The constraint is doing exactly the job it was put
  -- there to do. Two of the rows below are marked as awarded by AMI instead,
  -- which is true: a member of staff would have recorded them.
  --
  -- The consequence for testing is that the green "Automatic" pill on the CPD
  -- page will not appear until the automatic award work is built. The other two
  -- pills, awarded by AMI and logged by you, both show.
  insert into public.cpd_entries
    (member_id, year, occurred_on, activity_type_id, title, provider, points, is_core,
     how_recorded, status, evidence_ref, reviewed_by, reviewed_at, recorded_by)
  select v_member, v_year, d.on_date, d.type_id, d.title, d.provider, 1, d.core,
         d.how::public.cpd_how_recorded, 'accepted', d.evid, v_person, now(), v_person
    from (values
      (make_date(v_year, 2, 11), v_core, 'TEST Internal refresher, RPE maintenance',   null::text, true,  'self_declared',  'certificate.pdf'),
      (make_date(v_year, 3, 6),  v_non,  'TEST Webinar, notifiable non licensed work', 'AMI',      false, 'awarded_by_ami', 'Attended 58 of 60 minutes'),
      (make_date(v_year, 4, 14), v_core, 'TEST Site assessment, operative set',        null,       true,  'awarded_by_ami', 'Independent auditor'),
      (make_date(v_year, 5, 20), v_non,  'TEST Reading and questions, HSG247 revision', null,      false, 'self_declared',  '5 of 5 correct'),
      (make_date(v_year, 6, 12), v_core, 'TEST AMI regional meeting, North West',      'AMI',      true,  'awarded_by_ami', 'Attendance register')
    ) as d(on_date, type_id, title, provider, core, how, evid)
   where not exists (select 1 from public.cpd_entries e
                      where e.member_id = v_member and e.title = d.title);

  -- One waiting, so the awaiting review state is visible.
  insert into public.cpd_entries
    (member_id, year, occurred_on, activity_type_id, title, points, is_core,
     how_recorded, status, recorded_by)
  select v_member, v_year, current_date - 7, v_core,
         'TEST Toolbox talk, face fit testing', 1, true, 'self_declared', 'pending', v_person
   where not exists (select 1 from public.cpd_entries e
                      where e.member_id = v_member
                        and e.title = 'TEST Toolbox talk, face fit testing');

  -- And one refused, so you can see that a refusal comes with a reason attached
  -- to it, which is the promise the design makes.
  insert into public.cpd_entries
    (member_id, year, occurred_on, activity_type_id, title, points, is_core,
     how_recorded, status, review_note, reviewed_by, reviewed_at, recorded_by)
  select v_member, v_year, current_date - 40, v_core,
         'TEST A course with nothing attached', 1, true, 'self_declared', 'rejected',
         'No evidence was attached, so the office could not accept it.',
         v_person, now(), v_person
   where not exists (select 1 from public.cpd_entries e
                      where e.member_id = v_member
                        and e.title = 'TEST A course with nothing attached');
end $$;


-- =============================================================================
-- Clearing up
-- =============================================================================
-- The test CPD entries only, leaving the membership so you can put fresh ones in:
--
--   delete from public.cpd_entries where title like 'TEST %';
--
-- The whole test membership, in this order because of the references. Find the
-- member id in the admin app or with the select at the top.
--
--   delete from public.cpd_entries        where member_id = '<member id>';
--   delete from public.member_preferences where member_id = '<member id>';
--   delete from public.register_slugs     where member_id = '<member id>';
--   delete from public.members            where id        = '<member id>';
