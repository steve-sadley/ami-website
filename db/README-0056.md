# 0056: loading the AMI members from Dynamics, built now, used later

Database 43, admin 41. Steve, 31 October: put every AMI member on the website
from Dynamics, with new membership numbers; build it now and load after the
security test (and re-test after loading). `dynamics_members_load(prefix, start,
digits, go)`, super users only. A preview always works; creating is locked by
the setting `dynamics_member_load` ('off'). Creates each unlinked AMI member with
an email, a mapped category and a name, whose emails nobody on the website
holds: a person linked to the contact and an active, current membership numbered
in surname order, joined on the day of the load, with preferences. Sends nothing.
Admin 41: Members and Dynamics, Create website members (super users): preview,
then create only when unlocked. Test 48 (14). Database 832.

To load, after the security test: in the SQL editor,
`update public.system_settings set value = 'on' where key = 'dynamics_member_load';`
then the button; then switch it back to 'off'.
