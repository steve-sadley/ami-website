-- =============================================================================
-- 0033  Reissuing a card
--
-- WHAT WAS WRONG
--
-- 0009 gave wallet_passes a unique index allowing one live pass per member per
-- platform, and a trigger to revoke the previous one when a new one is issued:
--
--   create unique index wallet_passes_one_live
--     on public.wallet_passes (member_id, platform) where revoked_at is null;
--
--   create trigger wallet_passes_supersede
--     after insert on public.wallet_passes ...
--
-- Both are right and together they are wrong. **A unique index is enforced as
-- the row goes in. An AFTER INSERT trigger runs once it is already there.** So
-- the second pass a member ever issues is refused by the index and the trigger
-- that would have made room for it never runs.
--
-- The result: the first card a member issues works, and every one after it
-- fails with 23505. Reissue has therefore never worked, and nor has the ordinary
-- path once anybody has a card, because issuing and reissuing are the same
-- statement. Losing a phone is exactly when a member needs this to work.
--
-- WHY THE TESTS DID NOT CATCH IT
--
-- Every fixture issued one card. One card is the only case that passes. This is
-- the same shape of blind spot as counting absolute numbers in test 07: a
-- fixture that only ever meets the easy case is a fixture that has not been
-- tested where it matters.
--
-- WHAT IS DIFFERENT NOW
--
-- The trigger moves to BEFORE INSERT. The old pass is revoked while the new row
-- is still on its way in, so by the time the index looks there is only one live
-- row for that member and platform. Column defaults are applied before a BEFORE
-- trigger runs, so new.id is already set and the `id <> new.id` guard still
-- reads the way it always did, even though the new row cannot match anything
-- yet because it is not in the table.
--
-- The function body is unchanged. Only when it runs has changed.
--
-- WHAT WAS CONSIDERED AND NOT DONE
--
-- Revoking inside issue_my_card, before the insert. It would work, and it would
-- leave the trigger wrong for any other route into the table. The guarantee
-- belongs to the table, not to one caller of it.
--
-- Making the index deferrable. A unique INDEX cannot be deferred; only a unique
-- CONSTRAINT can, and swapping one for the other to work around an ordering
-- problem is a larger change that buys nothing here.
-- =============================================================================

drop trigger if exists wallet_passes_supersede on public.wallet_passes;

create trigger wallet_passes_supersede
  before insert on public.wallet_passes
  for each row execute function app.revoke_previous_pass();

comment on function app.revoke_previous_pass() is
  'Revokes any live pass for the same member and platform. BEFORE INSERT, not '
  'after: the wallet_passes_one_live index is enforced as the row goes in, so an '
  'AFTER trigger runs too late and the second card a member issues is refused.';


-- -----------------------------------------------------------------------------
-- Anything already stuck
-- -----------------------------------------------------------------------------
-- Nothing to repair. The index made a second live row impossible, so there is at
-- most one live pass per member and platform, and it is the one the member is
-- holding. It is superseded properly the next time they issue.
--
-- Stated rather than left silent, because "no data migration" and "the data
-- migration was forgotten" look identical afterwards.
