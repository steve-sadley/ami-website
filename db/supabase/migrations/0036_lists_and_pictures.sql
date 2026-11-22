-- =============================================================================
-- 0036  Repeating blocks and converted pictures
--
-- Two backstops for two things the admin app now does in the browser. A rule
-- written only in a browser is a rule somebody can step round with the API, so
-- each one is said again here, where it cannot be.
--
--   1. page_blocks.items must be a list of objects. The site draws a list item
--      by reading named fields off an object; a string, a number or a nested
--      list in there is a list the site refuses to draw, and it falls back to
--      the markup in silence. Refused at the door instead, with a reason.
--
--   2. The public-media bucket takes WebP and JPEG only, two megabytes at most.
--      Admin 17 converts every picture before upload: scaled to 2000 pixels at
--      most, re-encoded, metadata gone, WebP where the browser can and JPEG
--      where it cannot (Safari). So these two types are the only ones that
--      should ever arrive, and anything else is something that went round the
--      converter.
--
-- WHAT 2 TAKES AWAY. 0023 allowed PNG, AVIF and SVG and ten megabytes. SVG in a
-- public bucket is a document that can carry script, served from the storage
-- host to anybody with the address. Nothing uses PNG or AVIF once pictures are
-- converted. Files already in the bucket are untouched: a limit applies to an
-- upload, not to what is stored.
--
-- Safe to run twice.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The shape of a list
-- -----------------------------------------------------------------------------
-- Said before the constraint is added, so that a staging row that would break
-- it is NAMED rather than reported as "check constraint violated by some row".
do $$
declare bad text;
begin
  select string_agg(page_key || '.' || block_key, ', ') into bad
    from public.page_blocks
   where items is not null
     and (jsonb_typeof(items) <> 'array'
          or jsonb_array_length(items) not between 1 and 24
          or jsonb_path_exists(items, 'strict $[*] ? (@.type() != "object")', '{}', true));
  if bad is not null then
    raise exception 'These blocks hold items that are not a list of 1 to 24 objects: %. '
                    'Fix them on the Pages screen, or set items to null, then run 0036 again.', bad;
  end if;
end $$;

-- No function, deliberately. A check that calls a function in `app` needs the
-- writer to hold EXECUTE on it and USAGE on the schema, and a missing grant
-- there would read as the Pages screen refusing to save anything at all.
-- jsonb_path_exists is built in and immutable.
--
-- STRICT, and the first version was not. A JSON path in its default lax mode
-- unwraps arrays as it goes, so `$[*]` over [[{...}]] walked straight through
-- the inner list and found an object, and a list inside a list passed. Test 17
-- caught it, once its own failure count had been mended (see the end of 11).
--
-- SILENT (the fourth argument), because strict mode RAISES on something that
-- is not an array rather than answering, and Postgres does not promise to
-- evaluate the jsonb_typeof test first. Silent, it answers null there, and
-- false AND null is false, so a non array is still refused, as 23514.
alter table public.page_blocks drop constraint if exists page_blocks_items_shape;
alter table public.page_blocks add  constraint page_blocks_items_shape check (
  items is null
  or (jsonb_typeof(items) = 'array'
      and jsonb_array_length(items) between 1 and 24
      and not jsonb_path_exists(items, 'strict $[*] ? (@.type() != "object")', '{}', true))
);

comment on constraint page_blocks_items_shape on public.page_blocks is
  'items is a list of 1 to 24 objects or nothing. The admin app holds each '
  'list to the count its grid can show; this is the outer bound, and the '
  'guarantee that the site is never handed something it cannot draw.';


-- -----------------------------------------------------------------------------
-- 2. The public pictures bucket
-- -----------------------------------------------------------------------------
-- The two columns exist on Supabase and not on the plain Postgres the tests run
-- against, exactly as in 0023. On the mirror this does nothing and says so.
do $$
begin
  update storage.buckets
     set file_size_limit    = 2097152,
         allowed_mime_types = array['image/webp','image/jpeg']
   where id = 'public-media';
  if not found then
    raise exception 'The public-media bucket does not exist. Run 0023 first.';
  end if;
exception when undefined_column then
  raise notice 'storage.buckets has no size or type columns here (the local mirror). Nothing to do.';
end $$;
