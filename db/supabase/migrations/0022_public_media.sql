-- =============================================================================
-- 0022  A picture on a public page
--
-- content-media is a private bucket. 0011 gave it three policies: any signed in
-- person may read it, an editor may write to it, an editor may delete from it.
-- Nothing there lets an anonymous visitor see anything, which is correct for a
-- draft and wrong for the photograph at the top of a published article.
--
-- The obvious fix, making the bucket public, is the wrong one: it would also
-- publish every draft, every withdrawn document and every image somebody
-- uploaded and thought better of.
--
-- So the bucket stays private and the path decides. Anything under public/ is
-- readable by anybody. Everything else is readable only by somebody signed in,
-- exactly as before. An editor moves a file into the open by choosing where to
-- put it, which is a decision they can see themselves making.
--
--   public/2026/hse-guidance-update.jpg     the picture on a published article
--   documents/2026/asbestos-register.pdf    a members only guidance document
--
-- The admin app writes to public/ for article images and to documents/ for
-- guidance, and says which is which on screen.
-- =============================================================================

do $$
begin
  execute $p$
    drop policy if exists media_select_public on storage.objects;
    create policy media_select_public on storage.objects
      for select to anon
      using (bucket_id = 'content-media'
             and (storage.foldername(storage.objects.name))[1] = 'public')
  $p$;
exception when insufficient_privilege or undefined_table or undefined_function then
  raise notice 'storage policy skipped: not a Supabase storage schema';
end $$;

-- The obvious place for a note about this is a comment on the storage schema,
-- and the migration role does not own that schema, so it cannot leave one. It
-- goes here instead: the only things an anonymous visitor can read out of
-- storage are content-media/public/ and a member photograph whose owner has
-- switched it on. Everything else needs an account.

-- -----------------------------------------------------------------------------
-- The picture, on the public side
-- -----------------------------------------------------------------------------
-- public_article already carries image_path for news. The other three kinds had
-- nowhere to put one, so a guidance note or an event could never have a picture
-- of its own and always fell back to a stock photograph. This adds the column
-- and the view picks it up.
alter table public.guidance_documents add column if not exists image_path text;
alter table public.events            add column if not exists image_path text;
alter table public.videos            add column if not exists image_path text;

create or replace view public.public_article as
  select 'news'::text as kind, n.slug, n.title, n.category, n.summary, n.body,
         n.image_path, n.published_at, null::text as storage_path,
         null::text as vimeo_id, null::timestamptz as starts_at,
         null::timestamptz as ends_at, null::text as location
    from public.news_articles n
   where n.status = 'published' and n.published_at <= now()
  union all
  select 'guidance', d.slug, d.title, d.category, d.summary, null,
         d.image_path, d.published_at, d.storage_path, null, null, null, null
    from public.guidance_documents d
   where d.status = 'published' and not d.members_only
  union all
  select 'video', v.slug, v.title, v.category, v.description, null,
         v.image_path, v.published_at, null, v.vimeo_id, null, null, null
    from public.videos v
   where v.status = 'published' and not v.members_only
  union all
  select 'event', e.slug, e.title, e.kind, e.description, null,
         e.image_path, e.published_at, null, null, e.starts_at, e.ends_at, e.location
    from public.events e
   where e.status = 'published' and not e.members_only;

-- The list needs the picture too, or a news page of stock photographs sits above
-- article pages that all have their own.
--
-- Dropped rather than replaced: create or replace can add a column at the end
-- and nothing else, and image_path belongs beside the category rather than
-- tacked on after the location.
drop view if exists public.public_numbers;
drop view if exists public.public_content;
create view public.public_content as
  select 'news'::text as kind, n.slug, n.title, n.summary, n.published_at, n.category,
         n.image_path, null::timestamptz as starts_at, null::text as location
    from public.news_articles n
   where n.status = 'published' and n.published_at <= now()
  union all
  select 'event', e.slug, e.title, e.description, e.published_at, e.kind,
         e.image_path, e.starts_at, e.location
    from public.events e
   where e.status = 'published' and not e.members_only
  union all
  select 'guidance', d.slug, d.title, d.summary, d.published_at, d.category,
         d.image_path, null, null
    from public.guidance_documents d
   where d.status = 'published' and not d.members_only
  union all
  select 'video', v.slug, v.title, v.description, v.published_at, v.category,
         v.image_path, null, null
    from public.videos v
   where v.status = 'published' and not v.members_only;

-- public_numbers counted public_content, so it fell with it.
create or replace view public.public_numbers as
  select (select count(*) from public.public_register)                              as members,
         (select count(*) from public.membership_grades where appears_on_register)  as grades,
         (select count(*) from public.public_content)                               as items;

grant select on public.public_article, public.public_content, public.public_numbers
  to anon, authenticated;

-- -----------------------------------------------------------------------------
-- Publishing is a moment, not a checkbox
-- -----------------------------------------------------------------------------
-- Every one of these tables has a status and a published_at, and nothing kept
-- them honest. An article marked published with a null date never appeared,
-- because the view compares the date to now(), and the editor had no way of
-- knowing why. This stamps it on the way through.
create or replace function app.stamp_published_at() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.status = 'published' and new.published_at is null then
    new.published_at := now();
  end if;
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['news_articles','guidance_documents','events','videos'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_stamp_published', t);
    execute format(
      'create trigger %I before insert or update of status, published_at on public.%I '
      'for each row execute function app.stamp_published_at()', t || '_stamp_published', t);
  end loop;
end $$;

comment on function app.stamp_published_at() is
  'Fills in the publication date when something is first marked published. '
  'Without it, published with no date meant published and invisible, with '
  'nothing on screen to say why.';


-- -----------------------------------------------------------------------------
-- What the home page needs to show a grade properly
-- -----------------------------------------------------------------------------
-- The prototype shows each grade with a sentence and a fee. The sentence had
-- nowhere to live, and the fee was readable only by staff, so the home page
-- could show neither. Both are set from the admin area like everything else.
alter table public.membership_grades add column if not exists blurb text;

comment on column public.membership_grades.blurb is
  'One sentence describing who this grade is for. Shown on the home page and on '
  'the About page. Set from the admin area, because a sentence written into a '
  'web page is a sentence that needs a developer to change.';

drop view if exists public.public_grades;
create view public.public_grades as
  select g.code, g.name, g.post_nominals, g.blurb, g.sort_order
    from public.membership_grades g
   where g.appears_on_register
   order by g.sort_order;

-- The fee for a grade in a year. It is already published on every invoice and
-- on the join page, so there is nothing to protect, and a fee nobody can see
-- until they apply is a fee that costs the office a telephone call.
create or replace view public.public_fees as
  select g.code, f.year, f.fee_pence
    from public.grade_fees f
    join public.membership_grades g on g.id = f.grade_id
   where g.appears_on_register;

grant select on public.public_grades, public.public_fees to anon, authenticated;

comment on view public.public_fees is
  'This year''s subscription per grade. A grade with no fee set simply has no '
  'row, and the site says on application rather than showing a zero, because a '
  'zero is a price and a wrong one.';
