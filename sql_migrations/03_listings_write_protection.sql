-- ============================================================
-- LOURAMAKITI — LISTINGS WRITE PROTECTION
-- Run this AFTER cahier_entries_write_protection.sql.
-- Safe to re-run.
--
-- Same pattern as the ledger fix: editing or deleting a listing now
-- has to prove ownership first (matching device token, OR the
-- listing's management_pin) via a SECURITY DEFINER function — instead
-- of that check happening only in the app's own buttons, which a
-- direct API call could skip entirely.
--
-- Admin actions (boost approval/rejection, banning/removing a
-- seller's listings, clearing a flagged report, deleting from the
-- "all listings" admin tab) are untouched and keep working exactly
-- as before — they already run under your authenticated admin
-- session, which is_admin() recognizes regardless of this change.
-- ============================================================

create or replace function update_own_listing(p_id uuid, p_owner_token uuid, p_pin text, p_updates jsonb)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  owns boolean;
begin
  select (owner_token = p_owner_token) or (management_pin is not null and p_pin is not null and management_pin = p_pin)
    into owns
    from listings where id = p_id;
  if not coalesce(owns, false) then
    return false;
  end if;

  update listings set
    title = coalesce(p_updates->>'title', title),
    price = coalesce((p_updates->>'price')::integer, price),
    description = case when p_updates ? 'description' then p_updates->>'description' else description end,
    category = coalesce(p_updates->>'category', category),
    city = coalesce(p_updates->>'city', city),
    commune = case when p_updates ? 'commune' then p_updates->>'commune' else commune end,
    delivery_available = coalesce((p_updates->>'delivery_available')::boolean, delivery_available),
    condition = coalesce(p_updates->>'condition', condition),
    phone_number = coalesce(p_updates->>'phone_number', phone_number),
    owner_name = coalesce(p_updates->>'owner_name', owner_name),
    management_pin = coalesce(p_updates->>'management_pin', management_pin),
    image_url = case when p_updates ? 'image_url' then p_updates->>'image_url' else image_url end,
    image_urls = coalesce(p_updates->'image_urls', image_urls),
    status = coalesce(p_updates->>'status', status),
    sold_at = case when p_updates ? 'sold_at' then (p_updates->>'sold_at')::timestamptz else sold_at end,
    expires_at = coalesce((p_updates->>'expires_at')::timestamptz, expires_at),
    payment_status = coalesce(p_updates->>'payment_status', payment_status),
    transaction_reference = coalesce(p_updates->>'transaction_reference', transaction_reference),
    calculated_boost_fee = coalesce((p_updates->>'calculated_boost_fee')::integer, calculated_boost_fee),
    boost_duration_days = coalesce((p_updates->>'boost_duration_days')::integer, boost_duration_days)
  where id = p_id;
  -- Note: setting payment_status to 'premium' is still blocked here unless
  -- the caller is an admin — that's enforced by the existing
  -- enforce_payment_status_transition trigger from the last hardening
  -- pass, which fires no matter which path the UPDATE comes through.

  return true;
end;
$$;
grant execute on function update_own_listing(uuid, uuid, text, jsonb) to anon, authenticated;

create or replace function delete_own_listing(p_id uuid, p_owner_token uuid, p_pin text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  owns boolean;
begin
  select (owner_token = p_owner_token) or (management_pin is not null and p_pin is not null and management_pin = p_pin)
    into owns
    from listings where id = p_id;
  if not coalesce(owns, false) then
    return false;
  end if;

  delete from listings where id = p_id;
  return true;
end;
$$;
grant execute on function delete_own_listing(uuid, uuid, text) to anon, authenticated;

-- Lock the table down: only an admin session, or one of the two
-- functions above (which run with their own elevated access), can
-- update or delete a listing now. Posting a brand-new listing is
-- untouched — that stays open to everyone, as before.
drop policy if exists "anyone can update a listing" on listings;
drop policy if exists "anyone can delete a listing" on listings;
drop policy if exists "admin can update a listing" on listings;
drop policy if exists "admin can delete a listing" on listings;
create policy "admin can update a listing" on listings for update using (is_admin());
create policy "admin can delete a listing" on listings for delete using (is_admin());
