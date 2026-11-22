-- =============================================================================
-- 0055  Grade names, consistently
--
-- Steve, 31 October: "all grades either end in Member or they don't; I suggest
-- they don't." Three did. The code, the letters after the name, the blurb and
-- every membership are unchanged; only the name people read changes, on the
-- register, the card, the admin app and the emails.
--
-- Safe to run twice.
-- =============================================================================
update public.membership_grades set name = 'Affiliate'  where code = 'affiliate'  and name = 'Affiliate Member';
update public.membership_grades set name = 'Entrant'    where code = 'entrant'    and name = 'Entrant Member';
update public.membership_grades set name = 'Technician' where code = 'technician' and name = 'Technician Grade Member';

select code, name, post_nominals from public.membership_grades order by sort_order;
