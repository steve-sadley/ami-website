-- =============================================================================
-- 0008  The forum
--
-- Not moderated. Posts appear immediately, except where a banned word is found,
-- in which case the post is HELD and a person looks at it.
--
-- A member may edit or delete their own post until it receives a reply. That is
-- a better rule than a clock, because the harm is not in changing an old post,
-- it is in changing a post somebody has already answered.
-- =============================================================================

create table public.forum_categories (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique,
  name         text not null,
  description  text,
  sort_order   integer not null default 0,
  members_only boolean not null default true,
  locked       boolean not null default false,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create trigger forum_categories_updated before update on public.forum_categories
  for each row execute function app.set_updated_at();

create table public.forum_threads (
  id           uuid primary key default gen_random_uuid(),
  category_id  uuid not null references public.forum_categories(id),
  author_id    uuid not null references public.members(id),
  title        text not null check (length(btrim(title)) between 3 and 200),
  slug         text not null unique,
  status       public.forum_thread_status not null default 'published',
  pinned       boolean not null default false,
  locked       boolean not null default false,
  post_count   integer not null default 0,
  last_post_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index forum_threads_cat on public.forum_threads (category_id, pinned desc, last_post_at desc);
create trigger forum_threads_updated before update on public.forum_threads
  for each row execute function app.set_updated_at();

create table public.forum_posts (
  id          uuid primary key default gen_random_uuid(),
  seq         bigint generated always as identity,
  thread_id   uuid not null references public.forum_threads(id) on delete cascade,
  author_id   uuid not null references public.members(id),
  body        text not null check (length(btrim(body)) between 1 and 20000),
  status      public.forum_post_status not null default 'published',
  held_reason text,
  edited_at   timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index forum_posts_thread on public.forum_posts (thread_id, seq);
create unique index forum_posts_seq on public.forum_posts (seq);
create index forum_posts_held on public.forum_posts (status, created_at) where status = 'held';
create trigger forum_posts_updated before update on public.forum_posts
  for each row execute function app.set_updated_at();

comment on column public.forum_posts.body is
  'Stored as plain text. Sanitising and escaping happen on the server and on '
  'output, never in the browser. This is the largest body of member submitted '
  'text on the site and therefore the most likely route to stored cross site scripting.';

create table public.forum_post_revisions (
  id          uuid primary key default gen_random_uuid(),
  post_id     uuid not null references public.forum_posts(id) on delete cascade,
  body        text not null,
  replaced_at timestamptz not null default now()
);
create index forum_post_revisions_post on public.forum_post_revisions (post_id, replaced_at desc);

comment on table public.forum_post_revisions is
  'Every edit keeps the previous body, whatever the edit window is, so a post '
  'cannot be quietly rewritten after somebody has replied to it.';

create table public.forum_reports (
  id          uuid primary key default gen_random_uuid(),
  post_id     uuid not null references public.forum_posts(id) on delete cascade,
  reported_by uuid not null references public.members(id),
  reason      text not null,
  created_at  timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references public.people(id),
  outcome     text,
  unique (post_id, reported_by)
);
create index forum_reports_open on public.forum_reports (created_at) where resolved_at is null;

create table public.forum_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references public.members(id) on delete cascade,
  thread_id   uuid references public.forum_threads(id) on delete cascade,
  category_id uuid references public.forum_categories(id) on delete cascade,
  delivery    text not null default 'daily'
    check (delivery in ('immediate', 'daily', 'weekly')),
  created_at  timestamptz not null default now(),
  constraint forum_sub_one_target
    check (num_nonnulls(thread_id, category_id) = 1)
);
create unique index forum_sub_thread_uniq on public.forum_subscriptions (member_id, thread_id)
  where thread_id is not null;
create unique index forum_sub_cat_uniq on public.forum_subscriptions (member_id, category_id)
  where category_id is not null;

create table public.forum_endorsements (
  post_id     uuid not null references public.forum_posts(id) on delete cascade,
  endorsed_by uuid not null references public.people(id),
  endorsed_at timestamptz not null default now(),
  primary key (post_id, endorsed_by)
);

comment on table public.forum_endorsements is
  'Shows a badge in phase 1. It is the hook the automatic CPD work will use later.';

-- -----------------------------------------------------------------------------
-- The banned word filter
-- -----------------------------------------------------------------------------
create table public.banned_words (
  id         uuid primary key default gen_random_uuid(),
  word       text not null,
  match_type public.word_match_type not null default 'whole_word',
  active     boolean not null default true,
  added_by   uuid references public.people(id),
  added_at   timestamptz not null default now()
);
create unique index banned_words_word on public.banned_words (lower(word));

comment on table public.banned_words is
  'Maintained by staff from an admin screen, never by editing code. Whole word '
  'is the default match, because matching any occurrence catches innocent words '
  'that happen to contain a rude one, which is a well known way to make a forum '
  'look foolish. This is a filter, not moderation: it catches an angry post '
  'written at four in the afternoon, and it does not catch somebody being '
  'unpleasant in polite language. The report route and staff hiding a post are '
  'what deal with that.';

-- Lower case, accents stripped, and any run of a repeated character collapsed to
-- one. Both the post and the banned word go through this, so the comparison
-- stays consistent. Without the last step the filter is defeated by anybody
-- typing one extra letter. It will
-- still be defeated by somebody determined, and that is not what it is for.
create or replace function app.normalise_for_matching(p_text text) returns text
language sql
immutable
set search_path = ''
as $$
  select regexp_replace(
           lower(translate(coalesce(p_text, ''),
                 'àáâãäåèéêëìíîïòóôõöùúûüýÿñç',
                 'aaaaaaeeeeiiiiooooouuuuyync')),
           '(.)\1+', '\1', 'g');
$$;

create or replace function app.find_banned_word(p_body text) returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_norm text := app.normalise_for_matching(p_body);
  r record;
begin
  for r in select word, match_type from public.banned_words where active loop
    if r.match_type = 'contains' then
      if position(app.normalise_for_matching(r.word) in v_norm) > 0 then
        return r.word;
      end if;
    else
      if v_norm ~ ('(^|[^a-z0-9])' || app.normalise_for_matching(r.word) || '([^a-z0-9]|$)') then
        return r.word;
      end if;
    end if;
  end loop;
  return null;
end;
$$;

-- Held rather than dropped. The member must be able to see that it is held and
-- that a person will look at it. A post that disappears without explanation
-- gets rewritten and posted again, which is worse.
create or replace function app.screen_forum_post() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hit text;
begin
  if tg_op = 'UPDATE' and new.body is not distinct from old.body then
    return new;
  end if;

  -- staff decisions about status are not second guessed by the filter
  if tg_op = 'UPDATE' and new.status is distinct from old.status
     and new.body is not distinct from old.body then
    return new;
  end if;

  v_hit := app.find_banned_word(new.body);
  if v_hit is not null then
    new.status := 'held';
    new.held_reason := 'Held automatically for review.';
  end if;
  return new;
end;
$$;

create trigger forum_posts_screen
  before insert or update on public.forum_posts
  for each row execute function app.screen_forum_post();

-- Keep the previous body on every edit.
create or replace function app.keep_post_revision() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.body is distinct from old.body then
    insert into public.forum_post_revisions (post_id, body) values (old.id, old.body);
    new.edited_at := now();
  end if;
  return new;
end;
$$;

create trigger forum_posts_revision
  before update on public.forum_posts
  for each row execute function app.keep_post_revision();

-- Thread counters.
create or replace function app.forum_thread_counters() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_thread uuid := coalesce(new.thread_id, old.thread_id);
begin
  update public.forum_threads t
     set post_count   = (select count(*) from public.forum_posts p
                          where p.thread_id = v_thread and p.status = 'published'),
         last_post_at = (select max(created_at) from public.forum_posts p
                          where p.thread_id = v_thread and p.status = 'published')
   where t.id = v_thread;
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;

create trigger forum_posts_counters
  after insert or update or delete on public.forum_posts
  for each row execute function app.forum_thread_counters();

-- "Has a reply" is decided on seq, not on created_at. created_at defaults to
-- now(), which is the TRANSACTION timestamp, so two posts written in the same
-- transaction carry the same value and a timestamp comparison silently fails.
--
-- A policy on forum_posts cannot itself select from forum_posts: the subquery
-- re-enters the policy and Postgres raises "infinite recursion detected in
-- policy". This helper is security definer, so it reads the table with the
-- owner's rights and the recursion never starts.
create or replace function app.post_has_reply(p_post_id uuid) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.forum_posts later
      join public.forum_posts self on self.id = p_post_id
     where later.thread_id = self.thread_id
       and later.seq > self.seq);
$$;

grant execute on function app.post_has_reply(uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Row level security
-- -----------------------------------------------------------------------------
alter table public.forum_categories     enable row level security;
alter table public.forum_categories     force  row level security;
alter table public.forum_threads        enable row level security;
-- counters maintained by app.forum_thread_counters(), so not forced
alter table public.forum_threads        no force row level security;
alter table public.forum_posts          enable row level security;
alter table public.forum_posts          force  row level security;
alter table public.forum_post_revisions enable row level security;
-- written by app.keep_post_revision(), so not forced
alter table public.forum_post_revisions no force row level security;
alter table public.forum_reports        enable row level security;
alter table public.forum_reports        force  row level security;
alter table public.forum_subscriptions  enable row level security;
alter table public.forum_subscriptions  force  row level security;
alter table public.forum_endorsements   enable row level security;
alter table public.forum_endorsements   force  row level security;
alter table public.banned_words         enable row level security;
-- read by app.find_banned_word() when screening a post, so not forced. Members
-- still cannot read it: the policies below are moderator only.
alter table public.banned_words         no force row level security;

grant select, insert, update on public.forum_categories to authenticated;
grant select, insert, update, delete on public.forum_threads to authenticated;
grant select, insert, update, delete on public.forum_posts  to authenticated;
grant select on public.forum_post_revisions to authenticated;
grant select, insert, update on public.forum_reports to authenticated;
grant select, insert, update, delete on public.forum_subscriptions to authenticated;
grant select, insert, delete on public.forum_endorsements to authenticated;
grant select, insert, update, delete on public.banned_words to authenticated;

create policy forum_cat_select on public.forum_categories
  for select to authenticated
  using (active and (select app.is_active_member()) or (select app.is_staff()));
create policy forum_cat_write_staff on public.forum_categories
  for insert to authenticated with check ((select app.is_moderator()));
create policy forum_cat_update_staff on public.forum_categories
  for update to authenticated
  using ((select app.is_moderator())) with check ((select app.is_moderator()));

create policy forum_thread_select on public.forum_threads
  for select to authenticated
  using ((status = 'published' and (select app.is_active_member()))
         or author_id = (select app.member_id())
         or (select app.is_staff()));

create policy forum_thread_insert on public.forum_threads
  for insert to authenticated
  with check (author_id = (select app.member_id()) and (select app.is_active_member()));

-- Deletable only while the thread has no replies at all.
create policy forum_thread_delete_own on public.forum_threads
  for delete to authenticated
  using (author_id = (select app.member_id()) and post_count <= 1);

create policy forum_thread_update_staff on public.forum_threads
  for update to authenticated
  using ((select app.is_moderator())) with check ((select app.is_moderator()));

-- A member sees published posts, plus their own whatever its status, so a held
-- post is visible TO ITS AUTHOR and to nobody else.
create policy forum_post_select on public.forum_posts
  for select to authenticated
  using ((status = 'published' and (select app.is_active_member()))
         or author_id = (select app.member_id())
         or (select app.is_staff()));

create policy forum_post_insert on public.forum_posts
  for insert to authenticated
  with check (author_id = (select app.member_id()) and (select app.is_active_member()));

-- Editable and deletable only while no later post exists in the same thread.
-- This is the rule, not a clock.
create policy forum_post_update_own on public.forum_posts
  for update to authenticated
  using (author_id = (select app.member_id()) and not app.post_has_reply(id))
  with check (author_id = (select app.member_id()));

create policy forum_post_delete_own on public.forum_posts
  for delete to authenticated
  using (author_id = (select app.member_id()) and not app.post_has_reply(id));

create policy forum_post_update_staff on public.forum_posts
  for update to authenticated
  using ((select app.is_moderator())) with check ((select app.is_moderator()));

create policy forum_rev_select_own on public.forum_post_revisions
  for select to authenticated
  using (exists (select 1 from public.forum_posts p
                 where p.id = post_id and p.author_id = (select app.member_id())));
create policy forum_rev_select_staff on public.forum_post_revisions
  for select to authenticated using ((select app.is_staff()));

create policy forum_report_insert on public.forum_reports
  for insert to authenticated
  with check (reported_by = (select app.member_id()) and (select app.is_active_member()));
create policy forum_report_select_own on public.forum_reports
  for select to authenticated using (reported_by = (select app.member_id()));
create policy forum_report_select_staff on public.forum_reports
  for select to authenticated using ((select app.is_staff()));
create policy forum_report_update_staff on public.forum_reports
  for update to authenticated
  using ((select app.is_moderator())) with check ((select app.is_moderator()));

create policy forum_sub_own on public.forum_subscriptions
  for select to authenticated using (member_id = (select app.member_id()));
create policy forum_sub_insert_own on public.forum_subscriptions
  for insert to authenticated with check (member_id = (select app.member_id()));
create policy forum_sub_update_own on public.forum_subscriptions
  for update to authenticated
  using (member_id = (select app.member_id()))
  with check (member_id = (select app.member_id()));
create policy forum_sub_delete_own on public.forum_subscriptions
  for delete to authenticated using (member_id = (select app.member_id()));

create policy forum_end_select on public.forum_endorsements
  for select to authenticated using ((select app.is_active_member()) or (select app.is_staff()));
create policy forum_end_insert_staff on public.forum_endorsements
  for insert to authenticated with check ((select app.is_moderator()));
create policy forum_end_delete_staff on public.forum_endorsements
  for delete to authenticated using ((select app.is_moderator()));

-- Members cannot read the banned word list. Publishing it is publishing the
-- list of words to avoid typing, which is also the list of words to try.
create policy banned_select_staff on public.banned_words
  for select to authenticated using ((select app.is_moderator()));
create policy banned_insert_staff on public.banned_words
  for insert to authenticated with check ((select app.is_moderator()));
create policy banned_update_staff on public.banned_words
  for update to authenticated
  using ((select app.is_moderator())) with check ((select app.is_moderator()));
create policy banned_delete_staff on public.banned_words
  for delete to authenticated using ((select app.is_moderator()));
