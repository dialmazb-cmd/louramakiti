-- ============================================================
-- LOURAMAKITI — BOOST ON/OFF TOGGLE (SERVER-SIDE ENFORCEMENT)
-- Run this after the earlier hardening files. Safe to re-run.
--
-- Pairs with the new "Sponsorisé activé" checkbox in the admin panel's
-- Bannières tab, which reads/writes site_settings.boost_enabled.
--
-- This widens the existing enforce_payment_status_transition trigger
-- (originally UPDATE-only, since that's what boost approval needed)
-- to also cover INSERT — because a brand-new listing can request a
-- boost at the moment it's first posted, not only when editing one
-- later. It also adds a check for the 'pending_verification' request
-- step, so a direct API call can't request a boost while the toggle
-- is off, even though the button is hidden in the UI.
-- ============================================================

create or replace function enforce_payment_status_transition()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  boost_on text;
  becoming_premium boolean;
  becoming_pending boolean;
begin
  if tg_op = 'INSERT' then
    becoming_premium := (new.payment_status = 'premium');
    becoming_pending := (new.payment_status = 'pending_verification');
  else
    becoming_premium := (new.payment_status = 'premium' and old.payment_status is distinct from 'premium');
    becoming_pending := (new.payment_status = 'pending_verification' and old.payment_status is distinct from 'pending_verification');
  end if;

  if becoming_premium then
    if not is_admin() then
      raise exception 'Only an admin can approve premium/sponsored status';
    end if;
    if (select count(*) from listings
        where category = new.category
          and payment_status in ('premium','pending_verification')
          and (tg_op = 'INSERT' or id <> new.id)) >= 6 then
      raise exception 'Boost cap reached for this category (6 slots)';
    end if;
  end if;

  if becoming_pending then
    select value into boost_on from site_settings where key = 'boost_enabled';
    if boost_on = 'false' then
      raise exception 'Boost requests are currently disabled';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_enforce_payment_status on listings;
create trigger trg_enforce_payment_status
before insert or update on listings
for each row execute function enforce_payment_status_transition();
