-- =============================================================================
-- 0009  The membership card
--
-- The photograph shows on the CARD by default, because that is why the member
-- uploaded it. Whether it shows on the PUBLIC verification page is a switch on
-- member_preferences, off until they turn it on.
--
-- A member may reissue their own card. Issuing a new pass revokes the previous
-- one, and every issue is logged, so repeated reissues are visible. People
-- change phones far more often than a membership system expects.
-- =============================================================================

create table public.wallet_passes (
  id              uuid primary key default gen_random_uuid(),
  member_id       uuid not null references public.members(id) on delete cascade,
  platform        public.wallet_platform not null,
  serial_number   text not null unique,
  auth_token_hash text not null,
  pass_type_id    text,
  issued_at       timestamptz not null default now(),
  last_updated_at timestamptz not null default now(),
  revoked_at      timestamptz,
  revoked_reason  text
);
create index wallet_passes_member on public.wallet_passes (member_id);
-- One live pass per member per platform. A member may hold an Apple pass and a
-- Google pass at once; they may not hold two live Apple passes.
create unique index wallet_passes_one_live
  on public.wallet_passes (member_id, platform) where revoked_at is null;

comment on column public.wallet_passes.auth_token_hash is
  'Stored hashed, exactly as a password would be. The token itself is returned '
  'to the device once, at issue, and never again.';

create table public.wallet_registrations (
  id                uuid primary key default gen_random_uuid(),
  pass_id           uuid not null references public.wallet_passes(id) on delete cascade,
  device_library_id text not null,
  push_token        text not null,
  registered_at     timestamptz not null default now(),
  unregistered_at   timestamptz,
  unique (pass_id, device_library_id)
);
create index wallet_reg_pass on public.wallet_registrations (pass_id) where unregistered_at is null;

comment on table public.wallet_registrations is
  'Apple''s update mechanism needs a row per device. This is what lets a pass on '
  'a phone change the moment a membership is switched off, which is the whole '
  'argument for a digital card over a printed one.';

create table public.card_issues (
  id         uuid primary key default gen_random_uuid(),
  member_id  uuid not null references public.members(id) on delete cascade,
  platform   public.wallet_platform not null,
  reason     public.card_issue_reason not null,
  issued_at  timestamptz not null default now(),
  issued_by  uuid references public.people(id)
);
create index card_issues_member on public.card_issues (member_id, issued_at desc);

-- Issuing a new pass revokes the previous one for that platform, so a member
-- can never hold two live cards and a lost phone stops verifying.
create or replace function app.revoke_previous_pass() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.wallet_passes
     set revoked_at = now(),
         revoked_reason = 'Superseded by a newer pass'
   where member_id = new.member_id
     and platform = new.platform
     and id <> new.id
     and revoked_at is null;
  return new;
end;
$$;

create trigger wallet_passes_supersede
  after insert on public.wallet_passes
  for each row execute function app.revoke_previous_pass();

create trigger wallet_passes_audit
  after insert or update or delete on public.wallet_passes
  for each row execute function app.audit_row();

-- -----------------------------------------------------------------------------
-- Row level security
-- -----------------------------------------------------------------------------
alter table public.wallet_passes        enable row level security;
-- superseded passes are revoked by app.revoke_previous_pass(), so not forced
alter table public.wallet_passes        no force row level security;
alter table public.wallet_registrations enable row level security;
alter table public.wallet_registrations force  row level security;
alter table public.card_issues          enable row level security;
alter table public.card_issues          force  row level security;

grant select, insert, update on public.wallet_passes to authenticated;
grant select, insert on public.card_issues to authenticated;
-- wallet_registrations: no grant to authenticated. Apple talks to a Worker.

create policy passes_select_own on public.wallet_passes
  for select to authenticated using (member_id = (select app.member_id()));
create policy passes_select_staff on public.wallet_passes
  for select to authenticated using ((select app.is_staff()));

-- Self service reissue, and only for an active membership. A member whose card
-- has been switched off cannot mint a new one that says they are valid.
create policy passes_insert_own on public.wallet_passes
  for insert to authenticated
  with check (member_id = (select app.member_id()) and (select app.is_active_member()));

create policy passes_insert_staff on public.wallet_passes
  for insert to authenticated with check ((select app.is_membership_staff()));
create policy passes_update_staff on public.wallet_passes
  for update to authenticated
  using ((select app.is_membership_staff())) with check ((select app.is_membership_staff()));

create policy card_issues_select_own on public.card_issues
  for select to authenticated using (member_id = (select app.member_id()));
create policy card_issues_select_staff on public.card_issues
  for select to authenticated using ((select app.is_staff()));
create policy card_issues_insert_own on public.card_issues
  for insert to authenticated
  with check (member_id = (select app.member_id()) and (select app.is_active_member()));
create policy card_issues_insert_staff on public.card_issues
  for insert to authenticated with check ((select app.is_membership_staff()));
