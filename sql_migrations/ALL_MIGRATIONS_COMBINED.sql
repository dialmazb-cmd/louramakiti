-- ============================================================
-- LOURAMAKITI — ALL HARDENING & FEATURE MIGRATIONS, COMBINED
-- Everything built together in our sessions, in the order it was
-- originally applied. Genuinely safe to run top-to-bottom on a
-- fresh copy of schema.sql, AND safe to re-run in full even on a
-- database that already has all of this applied — every create
-- statement in here has a matching drop-if-exists first.
--
-- If you're setting up a NEW Supabase project from scratch: run
-- schema.sql first, then this single file, in one go.
-- If you're already up to date (you've run each piece before as
-- we built it): you don't need to re-run this, it's just a
-- reference copy of everything for your records.
-- ============================================================


-- ================================================================
-- FILE: 01_foundational_hardening.sql
-- ================================================================
-- ============================================================
-- SECTION 1 — FOUNDATIONAL HARDENING (admin auth, PIN protection,
-- boost approval enforcement, admin-only tables, phone format)
-- Originally applied first. Safe to re-run.
-- ============================================================

-- ---------------------------------------------------------------
-- 1. ADMIN AUTH
-- ---------------------------------------------------------------
create table if not exists admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table admins enable row level security;

drop policy if exists "admins can read own row" on admins;
create policy "admins can read own row" on admins
  for select using (auth.uid() = user_id);

create or replace function is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(select 1 from admins where user_id = auth.uid());
$$;
grant execute on function is_admin() to anon, authenticated;

-- ---------------------------------------------------------------
-- 2. PIN PROTECTION — listings.management_pin
-- ---------------------------------------------------------------
revoke select (management_pin) on listings from anon, authenticated;
grant select (management_pin) on listings to authenticated;

create or replace function verify_owned_listings(p_phone text, p_pin text)
returns table(id uuid)
language sql
stable
security definer
set search_path = public
as $$
  select l.id from listings l
  where l.phone_number = p_phone
    and l.management_pin is not null
    and l.management_pin = p_pin;
$$;
grant execute on function verify_owned_listings(text, text) to anon, authenticated;

create or replace function listing_pin_mismatch(p_phone text, p_pin text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from listings
    where phone_number = p_phone
      and management_pin is distinct from p_pin
  );
$$;
grant execute on function listing_pin_mismatch(text, text) to anon, authenticated;

-- ---------------------------------------------------------------
-- 3. PIN PROTECTION — cahier_owners.pin / cahier_entries (reads)
-- ---------------------------------------------------------------
revoke select (pin) on cahier_owners from anon, authenticated;
grant select (pin) on cahier_owners to authenticated;

revoke update (pin, failed_pin_attempts, pin_locked_until) on cahier_owners from anon, authenticated;

create or replace function verify_cahier_pin(p_phone text, p_pin text)
returns table(ok boolean, boutique_name text, banned boolean, ban_reason text, locked boolean, minutes_left integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  rec cahier_owners%rowtype;
begin
  select * into rec from cahier_owners where phone_number = p_phone;

  if rec is null then
    return query select false, null::text, false, null::text, false, 0;
    return;
  end if;

  if rec.pin_locked_until is not null and rec.pin_locked_until > now() then
    return query select false, rec.boutique_name, rec.banned, rec.ban_reason, true,
      greatest(1, ceil(extract(epoch from (rec.pin_locked_until - now())) / 60))::int;
    return;
  end if;

  if rec.pin = p_pin then
    update cahier_owners set failed_pin_attempts = 0, pin_locked_until = null
      where phone_number = p_phone;
    return query select true, rec.boutique_name, rec.banned, rec.ban_reason, false, 0;
  else
    update cahier_owners
      set failed_pin_attempts = failed_pin_attempts + 1,
          pin_locked_until = case when failed_pin_attempts + 1 >= 5 then now() + interval '1 hour' else pin_locked_until end
      where phone_number = p_phone;
    return query select false, rec.boutique_name, rec.banned, rec.ban_reason, false, 0;
  end if;
end;
$$;
grant execute on function verify_cahier_pin(text, text) to anon, authenticated;

create or replace function update_cahier_pin(p_phone text, p_old_pin text, p_new_pin text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  matches boolean;
begin
  if is_admin() then
    update cahier_owners set pin = p_new_pin, failed_pin_attempts = 0, pin_locked_until = null
      where phone_number = p_phone;
    return found;
  end if;

  select (pin = p_old_pin) into matches from cahier_owners where phone_number = p_phone;
  if not coalesce(matches, false) then
    return false;
  end if;
  update cahier_owners set pin = p_new_pin, failed_pin_attempts = 0, pin_locked_until = null
    where phone_number = p_phone;
  return true;
end;
$$;
grant execute on function update_cahier_pin(text, text, text) to anon, authenticated;

create or replace function admin_clear_cahier_lockout(p_phone text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Admin only';
  end if;
  update cahier_owners set failed_pin_attempts = 0, pin_locked_until = null where phone_number = p_phone;
  return found;
end;
$$;
grant execute on function admin_clear_cahier_lockout(text) to authenticated;

revoke update (banned, ban_reason) on cahier_owners from anon, authenticated;
grant update (banned, ban_reason) on cahier_owners to authenticated;

drop policy if exists "public can read cahier_entries" on cahier_entries;
drop policy if exists "admin can read cahier_entries" on cahier_entries;
create policy "admin can read cahier_entries" on cahier_entries
  for select using (is_admin());

create or replace function get_cahier_entries(p_phone text, p_pin text)
returns setof cahier_entries
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  ok boolean;
begin
  select (pin = p_pin and not banned
          and (pin_locked_until is null or pin_locked_until < now()))
    into ok
    from cahier_owners where phone_number = p_phone;

  if not coalesce(ok, false) then
    return;
  end if;
  return query select * from cahier_entries where phone_number = p_phone order by created_at asc;
end;
$$;
grant execute on function get_cahier_entries(text, text) to anon, authenticated;

-- ---------------------------------------------------------------
-- 4. ADMIN-ONLY TABLES: sellers (ban/verify), banners, site_settings
-- ---------------------------------------------------------------
create or replace function increment_seller_post_count(p_phone text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into sellers (phone_number, total_posts, first_seen_at, updated_at)
  values (p_phone, 1, now(), now())
  on conflict (phone_number)
  do update set total_posts = sellers.total_posts + 1, updated_at = now();
end;
$$;
grant execute on function increment_seller_post_count(text) to anon, authenticated;

drop policy if exists "anyone can insert sellers" on sellers;
drop policy if exists "anyone can update sellers" on sellers;
drop policy if exists "anyone can delete sellers" on sellers;
drop policy if exists "admin can insert sellers" on sellers;
drop policy if exists "admin can update sellers" on sellers;
drop policy if exists "admin can delete sellers" on sellers;
create policy "admin can insert sellers" on sellers for insert with check (is_admin());
create policy "admin can update sellers" on sellers for update using (is_admin());
create policy "admin can delete sellers" on sellers for delete using (is_admin());

drop policy if exists "anyone can insert banners" on banners;
drop policy if exists "anyone can update banners" on banners;
drop policy if exists "admin can insert banners" on banners;
drop policy if exists "admin can update banners" on banners;
create policy "admin can insert banners" on banners for insert with check (is_admin());
create policy "admin can update banners" on banners for update using (is_admin());

drop policy if exists "anyone can insert site_settings" on site_settings;
drop policy if exists "anyone can update site_settings" on site_settings;
drop policy if exists "anyone can delete site_settings" on site_settings;
drop policy if exists "admin can insert site_settings" on site_settings;
drop policy if exists "admin can update site_settings" on site_settings;
drop policy if exists "admin can delete site_settings" on site_settings;
create policy "admin can insert site_settings" on site_settings for insert with check (is_admin());
create policy "admin can update site_settings" on site_settings for update using (is_admin());
create policy "admin can delete site_settings" on site_settings for delete using (is_admin());

-- ---------------------------------------------------------------
-- 5. STORAGE — banner images restricted to admin; seller photos stay open
-- ---------------------------------------------------------------
drop policy if exists "Public can upload to listings bucket" on storage.objects;
drop policy if exists "Public can upload seller photos" on storage.objects;
drop policy if exists "Public can update seller photos" on storage.objects;
drop policy if exists "Admin can upload banners" on storage.objects;
drop policy if exists "Admin can update banners" on storage.objects;

create policy "Public can upload seller photos"
on storage.objects for insert
to public
with check (bucket_id = 'listings' and (storage.foldername(name))[1] is distinct from 'banners');

create policy "Public can update seller photos"
on storage.objects for update
to public
using (bucket_id = 'listings' and (storage.foldername(name))[1] is distinct from 'banners');

create policy "Admin can upload banners"
on storage.objects for insert
to authenticated
with check (bucket_id = 'listings' and (storage.foldername(name))[1] = 'banners' and is_admin());

create policy "Admin can update banners"
on storage.objects for update
to authenticated
using (bucket_id = 'listings' and (storage.foldername(name))[1] = 'banners' and is_admin());

-- ---------------------------------------------------------------
-- 6. INPUT VALIDATION — phone number format (defense in depth)
-- ---------------------------------------------------------------
alter table listings drop constraint if exists listings_phone_format_check;
alter table listings add constraint listings_phone_format_check
  check (phone_number ~ '^\+[0-9]{6,15}$') not valid;

alter table cahier_owners drop constraint if exists cahier_owners_phone_format_check;
alter table cahier_owners add constraint cahier_owners_phone_format_check
  check (phone_number ~ '^\+[0-9]{6,15}$') not valid;

alter table sellers drop constraint if exists sellers_phone_format_check;
alter table sellers add constraint sellers_phone_format_check
  check (phone_number ~ '^\+[0-9]{6,15}$') not valid;

-- Optional, run later once ready:
-- alter table listings validate constraint listings_phone_format_check;
-- alter table cahier_owners validate constraint cahier_owners_phone_format_check;
-- alter table sellers validate constraint sellers_phone_format_check;

-- Note: the boost/premium-approval trigger (enforce_payment_status_transition)
-- was originally created here, then extended later (see SECTION 4 below,
-- "BOOST ON/OFF TOGGLE") to also cover the boost on/off switch and new-
-- listing inserts. Only the final, complete version is included in this
-- combined file — defined once, in Section 4 — to avoid defining it twice.

-- Daily posting limit, added alongside the above:
create or replace function enforce_daily_post_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cnt integer;
begin
  select count(*) into cnt from listings
    where phone_number = new.phone_number
      and created_at > now() - interval '24 hours';
  if cnt >= 8 then
    raise exception 'Daily posting limit reached for this phone number (8 / 24h)';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_daily_post_limit on listings;
create trigger trg_enforce_daily_post_limit
before insert on listings
for each row execute function enforce_daily_post_limit();


-- ================================================================
-- FILE: 02_cahier_entries_write_protection.sql
-- ================================================================
-- ============================================================
-- LOURAMAKITI — CAHIER_ENTRIES WRITE PROTECTION
-- Run this AFTER hardening_migration.sql (which you already ran).
-- Safe to re-run.
--
-- What this does: closes the one known gap from the last hardening
-- pass. cahier_entries (the actual ledger — sales, expenses, customer
-- names/phones, amounts) can no longer be written to directly by
-- anyone with the anon key. Every add/edit/delete now goes through a
-- function that checks the phone+PIN first, server-side, and only
-- then makes the change.
--
-- Why this won't repeat last time's bug: last time, the TABLE's own
-- read permission was restricted, which broke the browser's own
-- direct "upsert" call (Postgres needs to peek at existing rows to
-- resolve an upsert, and that peek was being blocked). This time, the
-- upsert happens *inside* these SECURITY DEFINER functions instead,
-- which run with their own elevated access and never hit that
-- particular Postgres/RLS interaction at all.
-- ============================================================

-- Adds/edits: the offline-sync engine already batches pending changes
-- into one array before sending them — this takes that same array,
-- checks the PIN once, and saves them all in a single call.
create or replace function sync_cahier_entries(p_phone text, p_pin text, p_entries jsonb)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  ok boolean;
begin
  select (pin = p_pin and not banned) into ok from cahier_owners where phone_number = p_phone;
  if not coalesce(ok, false) then
    return false;
  end if;

  insert into cahier_entries (id, phone_number, type, amount, description, product, quantity, unit_price, contact_name, contact_phone, status, payments, sale_group_id, created_at)
  select
    coalesce((e->>'id')::uuid, gen_random_uuid()),
    p_phone, -- always the verified phone — whatever the payload claims for phone_number is ignored
    e->>'type',
    (e->>'amount')::numeric,
    e->>'description',
    e->>'product',
    (e->>'quantity')::numeric,
    (e->>'unit_price')::numeric,
    e->>'contact_name',
    e->>'contact_phone',
    coalesce(e->>'status', 'impaye'),
    coalesce(e->'payments', '[]'::jsonb),
    nullif(e->>'sale_group_id','')::uuid,
    coalesce((e->>'created_at')::timestamptz, now())
  from jsonb_array_elements(p_entries) as e
  on conflict (id) do update set
    type = excluded.type,
    amount = excluded.amount,
    description = excluded.description,
    product = excluded.product,
    quantity = excluded.quantity,
    unit_price = excluded.unit_price,
    contact_name = excluded.contact_name,
    contact_phone = excluded.contact_phone,
    status = excluded.status,
    payments = excluded.payments,
    sale_group_id = excluded.sale_group_id,
    created_at = excluded.created_at
  where cahier_entries.phone_number = p_phone; -- never touch a pre-existing row belonging to a different phone, even on an id collision

  return true;
end;
$$;
grant execute on function sync_cahier_entries(text, text, jsonb) to anon, authenticated;

-- Deletes: one entry or several at once (covers the single-delete,
-- group-delete, and "replace group on edit" cases the app already has).
create or replace function delete_cahier_entries(p_phone text, p_pin text, p_ids uuid[])
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  ok boolean;
begin
  select (pin = p_pin and not banned) into ok from cahier_owners where phone_number = p_phone;
  if not coalesce(ok, false) then
    return false;
  end if;

  delete from cahier_entries where phone_number = p_phone and id = any(p_ids);
  return true;
end;
$$;
grant execute on function delete_cahier_entries(text, text, uuid[]) to anon, authenticated;

-- Now lock the table itself down completely — reads were already
-- admin-only from the last migration; writes join them here.
drop policy if exists "anyone can insert cahier_entries" on cahier_entries;
drop policy if exists "anyone can update cahier_entries" on cahier_entries;
drop policy if exists "anyone can delete cahier_entries" on cahier_entries;
drop policy if exists "admin can insert cahier_entries" on cahier_entries;
drop policy if exists "admin can update cahier_entries" on cahier_entries;
drop policy if exists "admin can delete cahier_entries" on cahier_entries;
create policy "admin can insert cahier_entries" on cahier_entries for insert with check (is_admin());
create policy "admin can update cahier_entries" on cahier_entries for update using (is_admin());
create policy "admin can delete cahier_entries" on cahier_entries for delete using (is_admin());
-- "admin can read cahier_entries" (select) already exists from last time — untouched.


-- ================================================================
-- FILE: 03_listings_write_protection.sql
-- ================================================================
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


-- ================================================================
-- FILE: 04_boost_toggle_protection.sql
-- ================================================================
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


-- ================================================================
-- FILE: 05_install_tracking.sql
-- ================================================================
-- ============================================================
-- LOURAMAKITI — ANDROID INSTALL TRACKING
-- Safe to re-run.
--
-- Records when a visitor's browser fires the real "appinstalled" event
-- (the app was actually added to their home screen, on Android/Chrome)
-- — not just that the install prompt was shown or clicked.
--
-- Note on iOS: Apple's Safari never fires this event for "Add to Home
-- Screen" installs — no website can detect that, on any platform. This
-- table only ever counts Android/Chrome-based installs, so treat the
-- number as "at least this many," not a true total across all phones.
--
-- Security note, consistent with everything else built today: this
-- table only holds an install timestamp + browser user-agent string —
-- no personal data, no financial/ownership stakes — so it's kept
-- simple (open insert, admin-only read) rather than behind a
-- SECURITY DEFINER function like the more sensitive tables. Someone
-- could in theory script fake inserts to inflate the count; since it's
-- just a vanity metric with nothing to protect, that's an accepted,
-- low-priority tradeoff rather than something worth over-engineering.
-- ============================================================

create table if not exists install_events (
  id           uuid primary key default gen_random_uuid(),
  installed_at timestamptz not null default now(),
  user_agent   text
);
alter table install_events enable row level security;

drop policy if exists "anyone can log an install" on install_events;
drop policy if exists "admin can read install events" on install_events;
create policy "anyone can log an install" on install_events for insert with check (true);
create policy "admin can read install events" on install_events for select using (is_admin());


-- ================================================================
-- FILE: 06_listing_short_codes.sql
-- ================================================================
-- ============================================================
-- LOURAMAKITI — SHORT LISTING CODES
-- Safe to re-run.
--
-- Adds a short, human-friendly code (e.g. "4X7B9K") to every listing,
-- used instead of the long internal ID in shared WhatsApp/Facebook
-- links. Old links already shared with the long ID keep working —
-- the app checks both.
-- ============================================================

alter table listings add column if not exists short_code text;

-- Generates a unique 6-character code for any new listing that doesn't
-- already have one. Avoids 0/O/1/I (easy to mix up when read aloud or
-- typed by hand).
create or replace function generate_listing_short_code()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  candidate text;
  chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  i int;
  tries int := 0;
begin
  if new.short_code is not null then
    return new;
  end if;
  loop
    candidate := '';
    for i in 1..6 loop
      candidate := candidate || substr(chars, 1 + floor(random()*length(chars))::int, 1);
    end loop;
    tries := tries + 1;
    exit when not exists (select 1 from listings where short_code = candidate) or tries > 20;
  end loop;
  new.short_code := candidate;
  return new;
end;
$$;

drop trigger if exists trg_generate_listing_short_code on listings;
create trigger trg_generate_listing_short_code
before insert on listings
for each row execute function generate_listing_short_code();

-- One-time backfill: give every listing that already existed before
-- this migration a short code too, so links you share for them from
-- now on are short as well.
do $$
declare
  r record;
  candidate text;
  chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  i int;
begin
  for r in select id from listings where short_code is null loop
    loop
      candidate := '';
      for i in 1..6 loop
        candidate := candidate || substr(chars, 1 + floor(random()*length(chars))::int, 1);
      end loop;
      exit when not exists (select 1 from listings where short_code = candidate);
    end loop;
    update listings set short_code = candidate where id = r.id;
  end loop;
end $$;

alter table listings alter column short_code set not null;
create unique index if not exists idx_listings_short_code on listings (short_code);

