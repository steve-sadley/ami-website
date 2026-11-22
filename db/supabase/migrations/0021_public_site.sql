-- =============================================================================
-- 0021  What the public site needs, and nothing else
--
-- 0012 gave anon three views and said they were the only grants anon would ever
-- receive. That was the right instinct and it was one page short: the home page
-- has a headline, an article has a body, and a page has words on it, and none of
-- those were readable by somebody who is not signed in.
--
-- So this adds four more views and keeps the rule. anon still holds no privilege
-- on a single table. Every view names its columns, filters itself, and is
-- security definer by omission, which here is what we want: the view decides
-- what leaves, not the caller.
--
-- What anon can reach after this migration, in full:
--   public_register   active members who chose to be listed
--   public_profile    one of them, by slug
--   public_content    the list of published news, events, guidance and video
--   public_article    the body of one published article           NEW
--   public_hero       the home page headline                      NEW
--   public_page       the words on a static page                  NEW
--   public_numbers    three counts for the home page              NEW
--
-- And one function, callable only with the service role, for the application
-- form. It is the one place a stranger causes a row to be written, so it is
-- written narrowly and it goes through a Worker rather than the browser.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- An article, with its body
-- -----------------------------------------------------------------------------
-- public_content is a list. It carries a summary because a list needs one, and
-- deliberately no body, because a list that carries every body is a list that
-- transfers the whole site to read the front page. This is the other half.
create or replace view public.public_article as
  select 'news'::text as kind, n.slug, n.title, n.category, n.summary, n.body,
         n.image_path, n.published_at, null::text as storage_path,
         null::text as vimeo_id, null::timestamptz as starts_at,
         null::timestamptz as ends_at, null::text as location
    from public.news_articles n
   where n.status = 'published' and n.published_at <= now()
  union all
  select 'guidance', d.slug, d.title, d.category, d.summary, null,
         null, d.published_at, d.storage_path, null, null, null, null
    from public.guidance_documents d
   where d.status = 'published' and not d.members_only
  union all
  select 'video', v.slug, v.title, v.category, v.description, null,
         null, v.published_at, null, v.vimeo_id, null, null, null
    from public.videos v
   where v.status = 'published' and not v.members_only
  union all
  select 'event', e.slug, e.title, e.kind, e.description, null,
         null, e.published_at, null, null, e.starts_at, e.ends_at, e.location
    from public.events e
   where e.status = 'published' and not e.members_only;

comment on view public.public_article is
  'One published item with its body, by kind and slug. Members only material is '
  'excluded here rather than in the page, because a filter written in JavaScript '
  'is a filter somebody can turn off.';


-- -----------------------------------------------------------------------------
-- The home page headline
-- -----------------------------------------------------------------------------
create or replace view public.public_hero as
  select h.statement, h.sort_order
    from public.hero_statements h
   where h.active
   order by h.sort_order;


-- -----------------------------------------------------------------------------
-- The words on a static page
-- -----------------------------------------------------------------------------
-- About, join, contact and so on. Blocks rather than whole pages, so the office
-- can change a paragraph without a developer and without being able to break the
-- layout by pasting markup into it.
create or replace view public.public_page as
  select b.page_key, b.block_key, b.body, b.sort_order
    from public.page_blocks b
   where b.status = 'published'
   order by b.page_key, b.sort_order;


-- -----------------------------------------------------------------------------
-- Three numbers
-- -----------------------------------------------------------------------------
-- The home page says how many members there are. Doing that by counting rows in
-- the register view from the browser means transferring the register to display
-- one number, and it means the number is wrong the moment the list is paged.
create or replace view public.public_numbers as
  select (select count(*) from public.public_register)                       as members,
         (select count(*) from public.membership_grades where appears_on_register) as grades,
         (select count(*) from public.public_content)                        as items;


grant select on public.public_article, public.public_hero,
                public.public_page, public.public_numbers to anon, authenticated;


-- -----------------------------------------------------------------------------
-- The photograph on a public profile page
-- -----------------------------------------------------------------------------
-- member-photos is a private bucket and stays one. The member decided, in their
-- own preferences, whether their photograph appears on their public page, and
-- this is the one narrow hole that decision needs.
--
-- Three conditions, all of them re-checked on every request rather than baked
-- into a link: the membership is active, the profile is public, and the
-- photograph is switched on. Turning any of them off takes the photograph down
-- immediately, which a public bucket could not do.
--
-- The path convention from 0011 is that the first folder is the member id, so
-- the policy can find the owner without a lookup table.
do $$
begin
  execute $p$
    drop policy if exists member_photo_public on storage.objects;
    create policy member_photo_public on storage.objects
      for select to anon
      using (
        bucket_id = 'member-photos'
        and exists (
          select 1
            from public.members m
            join public.member_preferences pr on pr.member_id = m.id
           where m.id::text = (storage.foldername(storage.objects.name))[1]
             and m.is_active
             and pr.public_profile
             and pr.photo_on_public_page
        ))
  $p$;
exception when insufficient_privilege or undefined_table or undefined_function then
  -- Plain Postgres, where the tests run, has a stub storage schema and no
  -- foldername function. The policy matters on Supabase and nowhere else.
  raise notice 'storage policy skipped: not a Supabase storage schema';
end $$;


-- -----------------------------------------------------------------------------
-- The application form
-- -----------------------------------------------------------------------------
-- The one place where somebody who is not signed in causes a row to be written.
--
-- It is NOT granted to anon. The form posts to a Cloudflare Worker, the Worker
-- holds the secret key in a binding and calls this, and the browser never holds
-- anything that can write. That costs one hop and buys the ability to rate limit,
-- to check a turnstile token and to reject a submission before it reaches the
-- database, none of which a table policy can do.
--
-- The reference is generated here rather than sent, because a reference chosen by
-- the caller is a reference that can be chosen twice.
create or replace function public.submit_application(
  p_given_name    text,
  p_family_name   text,
  p_email         text,
  p_grade_code    text default null,
  p_telephone     text default null,
  p_employer_name text default null,
  p_job_title     text default null,
  p_answers       jsonb default '{}'::jsonb
) returns table (id uuid, reference text)
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_grade uuid;
  v_ref   text;
  v_id    uuid;
  v_year  text := to_char(now(), 'YYYY');
begin
  if coalesce(btrim(p_given_name), '') = '' or coalesce(btrim(p_family_name), '') = '' then
    raise exception 'A name is needed.' using errcode = '22023';
  end if;
  if p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'That does not look like an email address.' using errcode = '22023';
  end if;

  select g.id into v_grade from public.membership_grades g where g.code = p_grade_code;

  -- One open application per address. The partial unique index in 0006 says the
  -- same thing, and saying it here as well turns a constraint violation into a
  -- sentence the applicant can act on.
  if exists (select 1 from public.membership_applications a
              where lower(a.email) = lower(btrim(p_email))
                and a.status in ('draft','submitted','under_review')) then
    raise exception 'There is already an application in progress for that address. '
                    'The office will be in touch, and they can be reached in the meantime.'
      using errcode = '23505';
  end if;

  -- AMI-2026-0001, counted per year rather than for all time, so the number says
  -- something. Serialised by the unique constraint: if two arrive together one
  -- retries, which is the whole reason this is not a client side counter.
  select 'AMI-' || v_year || '-' ||
         lpad((coalesce(max(substring(a.reference from 10)::int), 0) + 1)::text, 4, '0')
    into v_ref
    from public.membership_applications a
   where a.reference like 'AMI-' || v_year || '-%';

  insert into public.membership_applications
    (reference, grade_id, given_name, family_name, email, telephone,
     employer_name, job_title, answers, status, submitted_at)
  values
    (v_ref, v_grade, btrim(p_given_name), btrim(p_family_name), lower(btrim(p_email)),
     nullif(btrim(coalesce(p_telephone,'')), ''), nullif(btrim(coalesce(p_employer_name,'')), ''),
     nullif(btrim(coalesce(p_job_title,'')), ''), coalesce(p_answers, '{}'::jsonb),
     'submitted', now())
  returning membership_applications.id into v_id;

  insert into public.application_events (application_id, from_status, to_status, note)
  values (v_id, 'draft', 'submitted', 'Submitted through the website.');

  return query select v_id, v_ref;
end;
$$;

revoke all on function public.submit_application(text,text,text,text,text,text,text,jsonb) from public;
grant execute on function public.submit_application(text,text,text,text,text,text,text,jsonb)
  to service_role;

comment on function public.submit_application(text,text,text,text,text,text,text,jsonb) is
  'Creates a submitted application. Granted to the service role only: the form '
  'posts to a Worker and the browser holds nothing that can write. Generates its '
  'own reference, because a reference chosen by the caller can be chosen twice.';

-- The grades a form may offer. Not the grades table, which carries flags the
-- public has no business seeing.
create or replace view public.public_grades as
  select g.code, g.name, g.post_nominals, g.sort_order
    from public.membership_grades g
   where g.appears_on_register
   order by g.sort_order;

grant select on public.public_grades to anon, authenticated;
