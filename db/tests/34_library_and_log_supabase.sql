-- =============================================================================
-- 0046, the image library, the photographs and the communication log.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: the library is staff only and editors write it; the bundle's
-- photographs cannot be deleted or faked; a picture in use cannot be deleted
-- and says where it is used; each headline carries its own photograph; an item
-- with no picture gets the same default every time; the log holds the emails
-- the site sends directly, written only by the site; and staff, not members,
-- can read it.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(30);

insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('member', 'Member', 'MAMI', true, true, true, 2)
on conflict (code) do nothing;
insert into auth.users (id, email) values
  ('6e6e0000-0000-0000-0000-000000000001', 'lib.member@test.invalid'),
  ('6e6e0000-0000-0000-0000-000000000008', 'lib.editor@test.invalid'),
  ('6e6e0000-0000-0000-0000-000000000009', 'lib.office@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('6e6e1111-0000-0000-0000-000000000001','6e6e0000-0000-0000-0000-000000000001','Mair','Member','lib.member@test.invalid'),
  ('6e6e1111-0000-0000-0000-000000000008','6e6e0000-0000-0000-0000-000000000008','Eddie','Editor','lib.editor@test.invalid'),
  ('6e6e1111-0000-0000-0000-000000000009','6e6e0000-0000-0000-0000-000000000009','Olga','Office','lib.office@test.invalid');
insert into public.role_grants (person_id, role_code) values
  ('6e6e1111-0000-0000-0000-000000000008', 'editor'),
  ('6e6e1111-0000-0000-0000-000000000009', 'membership');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select '6e6e2222-0000-0000-0000-000000000001', '6e6e1111-0000-0000-0000-000000000001', 'TEST-LIB-0001',
       g.id, date '2021-01-01', true, 'current' from public.membership_grades g where g.code = 'member';

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

-- -----------------------------------------------------------------------------
-- 1. The library
-- -----------------------------------------------------------------------------
select is((select count(*)::int from public.media_library where builtin), 5, 'the bundle''s five photographs are in the library');

select sign_in_as('6e6e0000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.media_library), 0, 'a member reads nothing from the library');
select throws_ok($$ insert into public.media_library (path, name) values ('library/2026/zz-test-a.webp', 'ZZ TEST') $$,
  '42501', null, 'and cannot add to it');
reset role;

select sign_in_as('6e6e0000-0000-0000-0000-000000000008');
select lives_ok($$ insert into public.media_library (path, name, builtin) values ('library/2026/zz-test-a.webp', 'ZZ TEST hall', true) $$,
  'an editor adds a picture');
select is((select builtin from public.media_library where path = 'library/2026/zz-test-a.webp'), false,
          'but cannot make it look like one of the site''s own');
select is((select uploaded_by from public.media_library where path = 'library/2026/zz-test-a.webp'),
          '6e6e1111-0000-0000-0000-000000000008'::uuid, 'and is recorded as having added it');
select throws_ok($$ insert into public.media_library (path, name) values ('x'');background:url(evil', 'ZZ TEST bad') $$,
  '23514', null, 'an address that could break out of a CSS url() is refused');
select throws_ok($$ update public.media_library set path = 'library/2026/zz-test-b.webp' where path = 'library/2026/zz-test-a.webp' $$,
  '22023', null, 'a picture''s address does not change');
select throws_ok($$ delete from public.media_library where path = '/assets/hero.webp' $$,
  '22023', null, 'a built in photograph cannot be deleted');
reset role;

-- Use it on a page, and it cannot be deleted.
insert into public.page_blocks (page_key, block_key, body, status, sort_order)
values ('zz-test', 'banner_photo', 'library/2026/zz-test-a.webp', 'published', 1);
select sign_in_as('6e6e0000-0000-0000-0000-000000000008');
select ok((select uses from public.admin_media_library where path = 'library/2026/zz-test-a.webp') = array['Page: zz-test, banner'],
          'the library says where a picture is used');
select throws_ok($$ delete from public.media_library where path = 'library/2026/zz-test-a.webp' $$,
  '22023', null, 'a picture in use cannot be deleted');
select lives_ok($$ update public.media_library set archived = true where path = 'library/2026/zz-test-a.webp' $$,
  'but it can be archived');
reset role;
delete from public.page_blocks where page_key = 'zz-test';
select sign_in_as('6e6e0000-0000-0000-0000-000000000008');
select lives_ok($$ delete from public.media_library where path = 'library/2026/zz-test-a.webp' $$,
  'and once nothing uses it, deleted');
reset role;

-- -----------------------------------------------------------------------------
-- 2. The headline's photograph, and the default for an item with none
-- -----------------------------------------------------------------------------
select ok((select bool_and(image_path is not null) from public.hero_statements where active),
          'every headline already shown carries a photograph, as it did before');
select throws_ok($$ update public.hero_statements set image_path = 'javascript:alert(1)' where true $$,
  '23514', null, 'a headline photograph has to be a picture address');
set local role anon;
select ok((select count(*) from public.public_hero where image_path is not null) >= 1,
          'and a visitor reads it with the headline');
reset role;

select is(public.fallback_picture('zz-test-item'), public.fallback_picture('zz-test-item'),
          'the same item always gets the same default picture');
select ok(public.fallback_picture('zz-test-item') in (select path from public.media_library where fallback),
          'chosen from the pictures marked as defaults');
update public.media_library set fallback = false;
select is(public.fallback_picture('zz-test-item'), null, 'with none marked there is none, and the site uses its own');
update public.media_library set fallback = true where builtin and path <> '/assets/hero.webp';

insert into public.news_articles (slug, title, summary, body, status, published_at)
values ('zz-test-no-picture', 'ZZ TEST no picture', 'x', '<p>x</p>', 'published', now() - interval '1 day');
set local role anon;
select is((select fallback_path from public.public_content where slug = 'zz-test-no-picture'),
          public.fallback_picture('zz-test-no-picture'), 'the news list carries the item''s default picture');
select is((select fallback_path from public.public_article where slug = 'zz-test-no-picture'),
          public.fallback_picture('zz-test-no-picture'), 'and so does the article');
reset role;

select ok(app.digest_item_html('News', 't', null, 's', 'https://x.invalid/a', '/assets/photo-team.webp')
            like '%src="' || rtrim(app.setting('site_url'), '/') || '/assets/photo-team.webp"%',
          'the daily digest finds a built in photograph on the site, not in the media bucket');

-- -----------------------------------------------------------------------------
-- 3. The communication log
-- -----------------------------------------------------------------------------
select ok(not has_function_privilege('authenticated',
            'public.log_direct_email(text,text,text,text,text,text,boolean,text,jsonb)', 'execute')
          and not has_function_privilege('anon',
            'public.log_direct_email(text,text,text,text,text,text,boolean,text,jsonb)', 'execute'),
          'only the site can write to the log: a browser cannot record "we told them"');

set local role service_role;
select isnt(public.log_direct_email('contact_ack', 'Lib.Member@test.invalid', 'Mair', 'AMI has your message',
              '<p>Thanks</p>', 'office@test.invalid', true), null, 'the site records an email it sent itself');
select isnt(public.log_direct_email('application_office', 'office@test.invalid', 'AMI office', 'ZZ TEST application',
              '<p>x</p>', null, false, 'SMTP2GO answered 500'), null, 'and one that failed');
select throws_ok($$ select public.log_direct_email('anything', 'a@test.invalid', null, 's', 'h', null, true) $$,
  '22023', null, 'but only the four it sends directly');
reset role;

select ok((select status = 'sent' and sent_at is not null and person_id = '6e6e1111-0000-0000-0000-000000000001'
                  and template_code = 'direct:contact_ack'
             from public.email_outbox where to_email = 'lib.member@test.invalid' and subject = 'AMI has your message'),
          'sent, dated, and linked to the person by their address');
select ok((select status = 'failed' and last_error like 'SMTP2GO%' from public.email_outbox where subject = 'ZZ TEST application'),
          'a failure is recorded as a failure, with the reason');

select sign_in_as('6e6e0000-0000-0000-0000-000000000009');
select ok((select membership_number = 'TEST-LIB-0001' and route like 'Sent by the site%'
             from public.admin_communication_log where subject = 'AMI has your message' and to_email = 'lib.member@test.invalid'),
          'membership staff read it in the log, with the member it went to');
reset role;
select sign_in_as('6e6e0000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.admin_communication_log), 0, 'a member reads nothing from the log');
reset role;

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 30. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 30 TESTS PASSED' as result;

rollback;
