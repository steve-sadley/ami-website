-- =============================================================================
-- Two accounts for the security check, on STAGING only.
--
--   a test MEMBER with no staff role          (memberToken)
--   a test MEMBERSHIP STAFF, not a super user (staffToken, optional)
--
-- First sign in once with each address at the staging site's /login, so the
-- accounts exist. Then run this in the Supabase SQL editor. Safe to run again.
-- Everything is named TEST so it is easy to see and to remove (bottom).
-- =============================================================================
do $$
declare
  v_member_email text := 'steve.sadley+amitest@arca.org.uk';    -- the test member
  v_staff_email  text := 'steve.sadley+amistaff@arca.org.uk';   -- the test staff (optional)
  v_uid uuid; v_person uuid; v_member uuid; v_grade uuid;
begin
  select id into v_grade from public.membership_grades where code = 'member';

  -- The member.
  select id into v_uid from auth.users where lower(email) = lower(v_member_email);
  if v_uid is null then
    raise exception 'Nobody has signed in as % yet. Sign in at the staging /login first.', v_member_email;
  end if;
  select id into v_person from public.people where lower(email) = lower(v_member_email);
  if v_person is null then
    insert into public.people (auth_user_id, given_name, family_name, email)
    values (v_uid, 'TEST', 'Security Member', lower(v_member_email)) returning id into v_person;
  else
    update public.people set auth_user_id = coalesce(auth_user_id, v_uid) where id = v_person;
  end if;
  delete from public.role_grants where person_id = v_person;            -- a member, nothing more
  select id into v_member from public.members where person_id = v_person;
  if v_member is null then
    insert into public.members (person_id, membership_number, grade_id, joined_on, is_active, status)
    values (v_person, 'TEST-SEC-MEMBER', v_grade, date '2020-01-01', true, 'current') returning id into v_member;
  end if;
  insert into public.member_preferences (member_id) values (v_member) on conflict (member_id) do nothing;

  -- The staff account, if that address has signed in.
  select id into v_uid from auth.users where lower(email) = lower(v_staff_email);
  if v_uid is not null then
    select id into v_person from public.people where lower(email) = lower(v_staff_email);
    if v_person is null then
      insert into public.people (auth_user_id, given_name, family_name, email)
      values (v_uid, 'TEST', 'Security Staff', lower(v_staff_email)) returning id into v_person;
    else
      update public.people set auth_user_id = coalesce(auth_user_id, v_uid) where id = v_person;
    end if;
    delete from public.role_grants where person_id = v_person and role_code <> 'membership';
    insert into public.role_grants (person_id, role_code)
    select v_person, 'membership'
     where not exists (select 1 from public.role_grants where person_id = v_person and role_code = 'membership');
  else
    raise notice 'No staff account yet (%): the staff checks will be skipped.', v_staff_email;
  end if;
end $$;

-- Check: the member has no roles; the staff account has membership only.
select p.email, m.membership_number, coalesce(string_agg(g.role_code, ', '), 'no roles') as roles
  from public.people p
  left join public.members m on m.person_id = p.id
  left join public.role_grants g on g.person_id = p.id
 where p.family_name like 'Security %'
 group by p.email, m.membership_number;

-- To remove them afterwards:
--   delete from public.role_grants where person_id in (select id from public.people where family_name like 'Security %');
--   update public.members set is_active = false where membership_number = 'TEST-SEC-MEMBER';
