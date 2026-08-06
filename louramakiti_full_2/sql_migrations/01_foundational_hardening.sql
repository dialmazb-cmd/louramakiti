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
