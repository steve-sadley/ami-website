-- =============================================================================
-- 0068, contact enquiries are deleted after 12 months.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: an enquiry and its acknowledgement older than 12 months go;
-- younger ones stay; no other email in the log is touched, however old; a
-- nonsense setting falls back to 12 rather than deleting everything; nobody
-- signed in can run it. Nothing is kept: it all rolls back.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(7);

-- Start clean of anything this test might count.
delete from public.email_outbox where to_email like '%@test-68.invalid';

insert into public.email_outbox (template_code, to_email, subject, html, status, attempts, queued_at, sent_at) values
  ('direct:contact_office', 'old-office@test-68.invalid', 'TEST', '', 'sent', 1, now() - interval '13 months', now() - interval '13 months'),
  ('direct:contact_ack',    'old-ack@test-68.invalid',    'TEST', '', 'sent', 1, now() - interval '13 months', now() - interval '13 months'),
  ('direct:contact_office', 'new-office@test-68.invalid', 'TEST', '', 'sent', 1, now() - interval '11 months', now() - interval '11 months'),
  ('direct:contact_ack',    'new-ack@test-68.invalid',    'TEST', '', 'sent', 1, now() - interval '1 day',     now() - interval '1 day'),
  ('direct:application_received', 'old-app@test-68.invalid', 'TEST', '', 'sent', 1, now() - interval '5 years', now() - interval '5 years');

select is(app.purge_contact_enquiries() >= 2, true, 'the purge runs and reports what it removed');
select is((select count(*)::int from public.email_outbox where to_email in ('old-office@test-68.invalid', 'old-ack@test-68.invalid')), 0,
          'an enquiry and its acknowledgement older than 12 months are gone');
select is((select count(*)::int from public.email_outbox where to_email in ('new-office@test-68.invalid', 'new-ack@test-68.invalid')), 2,
          'younger ones stay');
select is((select count(*)::int from public.email_outbox where to_email = 'old-app@test-68.invalid'), 1,
          'no other kind of email is touched, however old');

update public.system_settings set value = 'zero' where key = 'contact_retention_months';
select is((select count(*)::int from (select app.purge_contact_enquiries()) x) = 1
          and (select count(*)::int from public.email_outbox where to_email like 'new-%@test-68.invalid') = 2, true,
          'a nonsense setting falls back to 12 months, not to deleting everything');
update public.system_settings set value = '0' where key = 'contact_retention_months';
select is((select count(*)::int from (select app.purge_contact_enquiries()) x) = 1
          and (select count(*)::int from public.email_outbox where to_email like 'new-%@test-68.invalid') = 2, true,
          'and so does 0');

set local role authenticated;
select throws_ok('select app.purge_contact_enquiries()', '42501', null,
                 'nobody signed in can run the purge');
reset role;

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 7. Do not go on until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 7 TESTS PASSED' as result;

rollback;
