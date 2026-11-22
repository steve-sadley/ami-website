-- =============================================================================
-- Give the staff test account a new password, the same one as in the config.
--
--   Supabase SQL editor. Replace TYPE-THE-NEW-PASSWORD-HERE with a new password
--   of letters and numbers only (a quote mark or a backslash breaks the
--   config file), run it, and type exactly the same password into
--   staffPassword in security.config.json. Never paste it into a chat.
--
-- The dashboard cannot set a password itself: it only sends a reset email,
-- which is why this is done here.
-- =============================================================================
update auth.users
   set encrypted_password = extensions.crypt('TYPE-THE-NEW-PASSWORD-HERE', extensions.gen_salt('bf')),
       email_confirmed_at = coalesce(email_confirmed_at, now()),
       updated_at = now()
 where email = 'steve.sadley+amistaff@arca.org.uk';

-- Check: one row, confirmed, and it has a password.
select email, email_confirmed_at is not null as confirmed, encrypted_password like '$2%' as has_password
  from auth.users where email = 'steve.sadley+amistaff@arca.org.uk';
