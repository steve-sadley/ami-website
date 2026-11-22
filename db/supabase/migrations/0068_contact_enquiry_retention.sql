-- =============================================================================
-- 0068: contact enquiries are kept for 12 months, then deleted
--
-- Since 0046 the two emails from the contact form, the enquiry to the office
-- and the acknowledgement to the sender, are kept in the communication log
-- (email_outbox, template codes direct:contact_office and direct:contact_ack).
-- The privacy notice said they were not stored at all. Steve, 22 November
-- 2026: keep them for 12 months. Site 86's notice now says so, and this makes
-- it true.
--
-- app.purge_contact_enquiries() deletes those rows once they are older than
-- the setting contact_retention_months (12). Only those two kinds: nothing
-- else in the log is touched. It is scheduled daily at 03:17 below, where
-- pg_cron exists (on staging and live; not on the test mirror).
--
-- Safe to run twice.
-- =============================================================================

insert into public.system_settings (key, value, note) values
  ('contact_retention_months', '12',
   'Months a contact form enquiry and its acknowledgement are kept in the communication log before deletion (0068).')
on conflict (key) do nothing;

create or replace function app.purge_contact_enquiries()
returns integer
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_months int;
  v_gone   int;
begin
  -- A missing or nonsense setting falls back to 12, never to 0: a typo must
  -- not delete every enquiry in the log.
  select case when value ~ '^[0-9]+$' and value::int >= 1 then value::int else 12 end
    into v_months
    from public.system_settings where key = 'contact_retention_months';
  v_months := coalesce(v_months, 12);

  delete from public.email_outbox
   where template_code in ('direct:contact_office', 'direct:contact_ack')
     and queued_at < now() - make_interval(months => v_months);
  get diagnostics v_gone = row_count;
  return v_gone;
end;
$$;

revoke all on function app.purge_contact_enquiries() from public, anon, authenticated;

do $$
begin
  perform cron.unschedule('ami-contact-retention')
    where exists (select 1 from cron.job where jobname = 'ami-contact-retention');
  perform cron.schedule('ami-contact-retention', '17 3 * * *', 'select app.purge_contact_enquiries()');
exception when invalid_schema_name or undefined_table or undefined_function then
  raise notice 'pg_cron is not here (the test mirror): ami-contact-retention not scheduled';
end $$;
