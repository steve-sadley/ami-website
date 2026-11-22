-- Local development only. NEVER run this against Supabase.
--
-- Supabase provides the auth schema, the auth.uid() function and the anon,
-- authenticated and service_role roles. This file recreates just enough of them
-- to run the migrations and the tests on a plain Postgres, so the SQL can be
-- proved before it goes anywhere near a hosted project.

create schema if not exists auth;

create table if not exists auth.users (
  id    uuid primary key default gen_random_uuid(),
  email text unique not null
);

-- Supabase reads the signed in user from a request scoped setting. The real
-- implementation reads a JWT claim; this reads the same setting name, so the
-- policies under test are the policies that ship.
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator noinherit login;
  end if;
end $$;

grant anon, authenticated, service_role to authenticator;
grant usage on schema auth to anon, authenticated, service_role;
grant select on auth.users to authenticated, service_role;

-- Supabase also provides a storage schema. Only the objects table matters here.
create schema if not exists storage;
create table if not exists storage.buckets (
  id     text primary key,
  name   text not null,
  public boolean not null default false
);
create table if not exists storage.objects (
  id       uuid primary key default gen_random_uuid(),
  bucket_id text not null references storage.buckets(id),
  name     text not null,
  owner    uuid,
  created_at timestamptz not null default now()
);
create or replace function storage.foldername(name text) returns text[]
language sql immutable as $$
  select string_to_array(name, '/');
$$;
grant usage on schema storage to anon, authenticated, service_role;
