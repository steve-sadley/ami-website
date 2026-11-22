-- =============================================================================
-- Is staging up to date with 0056, 0057 and 0059 to 0066?
--
--   Supabase SQL editor: paste and run. It changes nothing except asking the
--   database API to re-read the database, which is harmless.
--
-- Every row should say yes. If 0056 says NO, run 0056 and then 0057. If only
-- 0057 says NO, run 0057 again (safe twice). If any of 0059 to 0066 says NO,
-- run that one (each is safe twice).
-- =============================================================================
notify pgrst, 'reload schema';

select '0056: the member load is there' as what,
       case when to_regproc('public.dynamics_members_load') is not null then 'yes' else 'NO' end as answer
union all
select '0056: the member load is locked (off)',
       case when exists (select 1 from public.system_settings where key = 'dynamics_member_load' and value = 'off')
            then 'yes' else 'NO' end
union all
select '0059: members hide who switched them, and why',
       case when not has_table_privilege('authenticated', 'public.members', 'select')
             and not has_column_privilege('authenticated', 'public.members', 'deactivation_reason', 'select')
             and has_column_privilege('authenticated', 'public.members', 'membership_number', 'select')
            then 'yes' else 'NO' end
union all
select '0059: the office can still see them (member_activation)',
       case when to_regproc('public.member_activation') is not null then 'yes' else 'NO' end
union all
select '0060: the office can edit a member''s details (update_member_details)',
       case when to_regproc('public.update_member_details') is not null then 'yes' else 'NO' end
union all
select '0060: the members list shows the employer',
       case when exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'admin_member_list' and column_name = 'employer')
            then 'yes' else 'NO' end
union all
select '0061: a member chooses which email AMI writes to',
       case when exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'people' and column_name = 'preferred_email')
            then 'yes' else 'NO' end
union all
select '0062: members ask to change their emails (email_change_requests)',
       case when to_regclass('public.email_change_requests') is not null
             and to_regproc('public.request_my_email_change') is not null then 'yes' else 'NO' end
union all
select '0063: my_profile shows only the member themself',
       case when pg_get_viewdef('public.my_profile'::regclass, true) like '%member_id()%' then 'yes' else 'NO' end
union all
select '0064: interview booking is there',
       case when to_regclass('public.interview_slots') is not null
             and to_regproc('public.interview_page') is not null then 'yes' else 'NO' end
union all
select '0064: the interview functions are the Worker''s alone',
       case when not has_function_privilege('authenticated', 'public.interview_page(text)', 'execute')
             and not has_function_privilege('anon', 'public.interview_hold(text, uuid)', 'execute')
             and not has_function_privilege('authenticated', 'public.interview_confirm(uuid, text, text)', 'execute')
            then 'yes' else 'NO' end
union all
select '0065: guidance documents are served by the Worker (guidance_file)',
       case when to_regproc('public.guidance_file') is not null
             and not has_function_privilege('anon', 'public.guidance_file(text)', 'execute') then 'yes' else 'NO' end
union all
select '0066: content-media is read by office staff only',
       case when exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                          and policyname = 'media_select_staff')
             and not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                              and policyname = 'media_select_signed_in')
            then 'yes' else 'NO' end
union all
-- A view is staff only when it carries the staff gate from 0057, the
-- membership staff test (admin_interview_slots), or reads as the person asking
-- (security_invoker) so the tables' own rules apply (admin_application_queue,
-- whose applications only staff can read). The security check proves each one
-- returns nothing to a member.
select '0057: ' || c.relname || ' is staff only',
       case when pg_get_viewdef(c.oid, true) like '%staff_gate%'
              or pg_get_viewdef(c.oid, true) like '%is_membership_staff()%'
              or 'security_invoker=true' = any (coalesce(c.reloptions, '{}'))
            then 'yes' else 'NO' end
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'v' and c.relname like 'admin\_%'
 order by 2, 1;
