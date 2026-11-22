-- =============================================================================
-- 0016  The banned word list: super user only, and a matching fix
--
-- Two changes.
--
-- 1. The list is visible to super users alone. It was moderator readable, and a
--    published list of the words to avoid typing is also a list of the words to
--    try. Held posts are still handled by moderators; only the list itself moves.
--
-- 2. The matching is rewritten, because the old one was wrong in a way that
--    would have been very visible on an asbestos forum.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Super user only
-- -----------------------------------------------------------------------------
drop policy if exists banned_select_staff on public.banned_words;
drop policy if exists banned_insert_staff on public.banned_words;
drop policy if exists banned_update_staff on public.banned_words;
drop policy if exists banned_delete_staff on public.banned_words;

create policy banned_select_super on public.banned_words
  for select to authenticated using ((select app.is_super_user()));
create policy banned_insert_super on public.banned_words
  for insert to authenticated with check ((select app.is_super_user()));
create policy banned_update_super on public.banned_words
  for update to authenticated using ((select app.is_super_user()))
  with check ((select app.is_super_user()));
create policy banned_delete_super on public.banned_words
  for delete to authenticated using ((select app.is_super_user()));

comment on table public.banned_words is
  'Visible to super users only. A published list of the words to avoid typing is '
  'also a list of the words to try. Moderators still see and release held posts; '
  'they do not see what triggered the hold.';

-- -----------------------------------------------------------------------------
-- The matching fix
-- -----------------------------------------------------------------------------
-- The old version normalised BOTH the post and the word by collapsing any run of
-- a repeated character to one, so that "baaadger" would match "badger". It also
-- turned "ass" into "as", and "as" is one of the commonest words in English. On a
-- forum where people write about assessments and analysis all day, that would
-- have held a great many innocent posts and nobody would have known why.
--
-- The fix is to stop mangling the text and put the tolerance in the pattern
-- instead. Each character of the banned word becomes "that character, one or
-- more times". So "badger" becomes b+a+d+g+e+r+, which still catches "baaadger",
-- while "ass" becomes a+s+s+, which needs two esses and therefore cannot match
-- "as". Whole word boundaries then keep "assessment" and "analysis" clear.
create or replace function app.normalise_for_matching(p_text text) returns text
language sql
immutable
set search_path = ''
as $$
  select lower(translate(coalesce(p_text, ''),
                'àáâãäåèéêëìíîïòóôõöùúûüýÿñç',
                'aaaaaaeeeeiiiiooooouuuuyync'));
$$;

comment on function app.normalise_for_matching(text) is
  'Lower case and accents stripped. Repeated characters are NOT collapsed: doing '
  'that turned "ass" into "as" and would have held half the forum.';

create or replace function app.pattern_for_word(p_word text) returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  w text := app.normalise_for_matching(p_word);
  c text;
  out text := '';
  i int;
begin
  for i in 1 .. length(w) loop
    c := substr(w, i, 1);
    if c ~ '^[a-z0-9]$' then
      out := out || c || '+';            -- tolerate padding: baaadger
    elsif c = ' ' then
      out := out || '[^a-z0-9]+';        -- any gap between the words of a phrase
    else
      out := out || '\' || c || '+';     -- punctuation, escaped
    end if;
  end loop;
  return out;
end;
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

    -- anything outside the plain alphabet, an emoji for instance, is matched
    -- literally. Building a character by character pattern from it is not worth
    -- the trouble and the word boundary classes do not apply to it anyway.
    if app.normalise_for_matching(r.word) !~ '^[a-z0-9 &''\-]+$' then
      if position(app.normalise_for_matching(r.word) in v_norm) > 0 then
        return r.word;
      end if;
      continue;
    end if;

    if r.match_type = 'contains' then
      if v_norm ~ app.pattern_for_word(r.word) then
        return r.word;
      end if;
    else
      if v_norm ~ ('(^|[^a-z0-9])' || app.pattern_for_word(r.word) || '([^a-z0-9]|$)') then
        return r.word;
      end if;
    end if;
  end loop;
  return null;
end;
$$;

comment on function app.find_banned_word(text) is
  'Returns the first banned word found in a post, or null. Security definer, '
  'because the screening trigger has to read a table members cannot see.';
