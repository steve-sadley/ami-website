-- =============================================================================
-- 0050  A Dynamics column name matches whatever its case
--
-- Found by Steve on 31 October: the admin app showed the column names the sync
-- found in capitals (the tag style), and a name copied from there would not
-- have matched, because a row's keys are looked up exactly. Dynamics logical
-- names are lower case, but a person should not have to know that. So a column
-- is found by its exact name first, and failing that by the same name in any
-- case. Two columns differing only by case cannot happen in Dynamics.
--
-- Safe to run twice.
-- =============================================================================

create or replace function app.dyn_key(p_raw jsonb, p_field text) returns text
language sql immutable set search_path = ''
as $$
  select case
    when p_field is null then null
    when p_raw ? p_field then p_field
    else (select k from jsonb_object_keys(p_raw) k where lower(k) = lower(p_field) limit 1)
  end;
$$;

create or replace function app.dyn_text(p_raw jsonb, p_field text) returns text
language sql immutable set search_path = ''
as $$
  -- The words Dynamics gives beside a lookup or a choice are looked for on
  -- their own: a view can carry the words without the id.
  select case when p_field is null then null else
    left(coalesce(nullif(btrim(p_raw ->> app.dyn_key(p_raw, p_field || '@OData.Community.Display.V1.FormattedValue')), ''),
                  nullif(btrim(p_raw ->> app.dyn_key(p_raw, p_field)), '')), 300) end;
$$;

create or replace function app.dyn_date(p_raw jsonb, p_field text) returns date
language plpgsql stable set search_path = ''
as $$
declare
  v text := btrim(coalesce(p_raw ->> app.dyn_key(p_raw, p_field), ''));
begin
  if p_field is null or v = '' then return null; end if;
  if v ~ '^\d{4}-\d{2}-\d{2}$' then return v::date; end if;
  return (v::timestamptz at time zone 'Europe/London')::date;
exception when others then
  return null;
end;
$$;
