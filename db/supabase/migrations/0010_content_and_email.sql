-- =============================================================================
-- 0010  Content, events and email
--
-- Every content type has a draft state and a published state. Pages render from
-- the database at the edge with caching, so a correction goes live immediately.
-- =============================================================================

create table public.news_articles (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique,
  title        text not null,
  category     text,
  summary      text,
  body         text,
  image_path   text,
  featured     boolean not null default false,
  status       public.content_status not null default 'draft',
  published_at timestamptz,
  author_id    uuid references public.people(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index news_published on public.news_articles (status, published_at desc);
create trigger news_updated before update on public.news_articles
  for each row execute function app.set_updated_at();

create table public.events (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique,
  title        text not null,
  kind         text,
  starts_at    timestamptz not null,
  ends_at      timestamptz,
  location     text,
  description  text,
  capacity     integer check (capacity is null or capacity > 0),
  members_only boolean not null default false,
  status       public.content_status not null default 'draft',
  published_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index events_when on public.events (starts_at);
create trigger events_updated before update on public.events
  for each row execute function app.set_updated_at();

create table public.event_bookings (
  id           uuid primary key default gen_random_uuid(),
  event_id     uuid not null references public.events(id) on delete cascade,
  member_id    uuid not null references public.members(id) on delete cascade,
  booked_at    timestamptz not null default now(),
  cancelled_at timestamptz,
  notes        text,
  unique (event_id, member_id)
);
create index event_bookings_event on public.event_bookings (event_id) where cancelled_at is null;

create table public.guidance_documents (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique,
  title        text not null,
  category     text,
  summary      text,
  storage_path text,
  members_only boolean not null default false,
  status       public.content_status not null default 'draft',
  published_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create trigger guidance_updated before update on public.guidance_documents
  for each row execute function app.set_updated_at();

create table public.videos (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique,
  title        text not null,
  description  text,
  vimeo_id     text,
  category     text,
  members_only boolean not null default false,
  status       public.content_status not null default 'draft',
  published_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create trigger videos_updated before update on public.videos
  for each row execute function app.set_updated_at();

create table public.page_blocks (
  id         uuid primary key default gen_random_uuid(),
  page_key   text not null,
  block_key  text not null,
  body       text,
  sort_order integer not null default 0,
  status     public.content_status not null default 'draft',
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (page_key, block_key)
);
create trigger page_blocks_updated before update on public.page_blocks
  for each row execute function app.set_updated_at();

create table public.hero_statements (
  id         uuid primary key default gen_random_uuid(),
  statement  text not null,
  sort_order integer not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Email
-- -----------------------------------------------------------------------------
create table public.email_templates (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  name       text not null,
  subject    text not null,
  html       text not null,
  is_service boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger email_templates_updated before update on public.email_templates
  for each row execute function app.set_updated_at();

comment on column public.email_templates.is_service is
  'A service email concerns somebody''s own membership and cannot be opted out '
  'of. A marketing email can. The distinction has to hold in the data, not just '
  'in the sending code.';

create table public.email_campaigns (
  id           uuid primary key default gen_random_uuid(),
  template_id  uuid references public.email_templates(id),
  name         text not null,
  audience     jsonb not null default '{}'::jsonb,
  scheduled_at timestamptz,
  sent_at      timestamptz,
  created_by   uuid references public.people(id),
  created_at   timestamptz not null default now()
);

create table public.email_sends (
  id          uuid primary key default gen_random_uuid(),
  campaign_id uuid references public.email_campaigns(id),
  person_id   uuid references public.people(id),
  email       text not null,
  sent_at     timestamptz,
  status      text not null default 'queued',
  provider_ref text
);
create index email_sends_campaign on public.email_sends (campaign_id);

create table public.email_events (
  id       uuid primary key default gen_random_uuid(),
  send_id  uuid references public.email_sends(id) on delete cascade,
  event    text not null,
  occurred_at timestamptz not null default now(),
  detail   jsonb
);

create table public.suppression_list (
  email      text primary key,
  reason     text not null,
  added_at   timestamptz not null default now()
);

comment on table public.suppression_list is
  'Hard bounces and complaints, honoured on every send without exception, '
  'including service emails. An address that bounces does not stop bouncing '
  'because the message was important.';

create table public.consents (
  id         uuid primary key default gen_random_uuid(),
  person_id  uuid not null references public.people(id) on delete cascade,
  kind       text not null,
  given      boolean not null,
  source     text not null,
  occurred_at timestamptz not null default now()
);
create index consents_person on public.consents (person_id, kind, occurred_at desc);

comment on table public.consents is
  'Append only in practice: a change of mind is a new row, so the history of '
  'what somebody agreed to and when is intact.';

-- -----------------------------------------------------------------------------
-- Row level security
-- -----------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'news_articles','events','event_bookings','guidance_documents','videos',
    'page_blocks','hero_statements','email_templates','email_campaigns',
    'email_sends','email_events','suppression_list','consents']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force  row level security', t);
  end loop;
end $$;

grant select, insert, update, delete on
  public.news_articles, public.events, public.guidance_documents, public.videos,
  public.page_blocks, public.hero_statements to authenticated;
grant select, insert, update on public.event_bookings to authenticated;
grant delete on public.event_bookings to authenticated;
grant select, insert, update, delete on
  public.email_templates, public.email_campaigns to authenticated;
grant select on public.email_sends, public.email_events to authenticated;
grant select, insert on public.suppression_list to authenticated;
grant select, insert on public.consents to authenticated;

-- Published content is readable by any signed in user. The PUBLIC reads it
-- through the view in 0012, never from these tables.
do $$
declare t text;
begin
  foreach t in array array['news_articles','events','guidance_documents','videos','page_blocks']
  loop
    execute format($f$
      create policy %1$s_select_published on public.%1$I
        for select to authenticated
        using (status = 'published' or (select app.is_staff()));
      create policy %1$s_insert_editor on public.%1$I
        for insert to authenticated with check ((select app.is_editor()));
      create policy %1$s_update_editor on public.%1$I
        for update to authenticated
        using ((select app.is_editor())) with check ((select app.is_editor()));
      create policy %1$s_delete_editor on public.%1$I
        for delete to authenticated using ((select app.is_editor()));
    $f$, t);
  end loop;
end $$;

create policy hero_select on public.hero_statements
  for select to authenticated using (active or (select app.is_staff()));
create policy hero_write on public.hero_statements
  for insert to authenticated with check ((select app.is_editor()));
create policy hero_update on public.hero_statements
  for update to authenticated
  using ((select app.is_editor())) with check ((select app.is_editor()));
create policy hero_delete on public.hero_statements
  for delete to authenticated using ((select app.is_editor()));

create policy bookings_select_own on public.event_bookings
  for select to authenticated using (member_id = (select app.member_id()));
create policy bookings_select_staff on public.event_bookings
  for select to authenticated using ((select app.is_staff()));
create policy bookings_insert_own on public.event_bookings
  for insert to authenticated
  with check (member_id = (select app.member_id()) and (select app.is_active_member()));
create policy bookings_update_own on public.event_bookings
  for update to authenticated
  using (member_id = (select app.member_id()))
  with check (member_id = (select app.member_id()));
create policy bookings_update_staff on public.event_bookings
  for update to authenticated
  using ((select app.is_staff())) with check ((select app.is_staff()));

create policy templates_staff on public.email_templates
  for select to authenticated using ((select app.is_editor()));
create policy templates_write on public.email_templates
  for insert to authenticated with check ((select app.is_editor()));
create policy templates_update on public.email_templates
  for update to authenticated
  using ((select app.is_editor())) with check ((select app.is_editor()));

create policy campaigns_staff on public.email_campaigns
  for select to authenticated using ((select app.is_editor()));
create policy campaigns_write on public.email_campaigns
  for insert to authenticated with check ((select app.is_editor()));
create policy campaigns_update on public.email_campaigns
  for update to authenticated
  using ((select app.is_editor())) with check ((select app.is_editor()));

create policy sends_staff on public.email_sends
  for select to authenticated using ((select app.is_staff()));
create policy email_events_staff on public.email_events
  for select to authenticated using ((select app.is_staff()));
create policy suppression_staff on public.suppression_list
  for select to authenticated using ((select app.is_staff()));
create policy suppression_insert_staff on public.suppression_list
  for insert to authenticated with check ((select app.is_staff()));

create policy consents_select_own on public.consents
  for select to authenticated using (person_id = (select app.person_id()));
create policy consents_insert_own on public.consents
  for insert to authenticated
  with check (person_id = (select app.person_id()) or (select app.is_staff()));
create policy consents_select_staff on public.consents
  for select to authenticated using ((select app.is_staff()));
