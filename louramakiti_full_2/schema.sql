-- ============================================================
-- LOURAMAKITI — Supabase schema
-- Run this once in the Supabase SQL editor (Project > SQL Editor)
-- ============================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------
-- LISTINGS
-- ---------------------------------------------------------------
create table if not exists listings (
  id                    uuid primary key default gen_random_uuid(),
  title                 text not null,
  price                 integer not null check (price >= 0),
  description           text,
  phone_number          text not null,
  category              text not null check (category in ('Électroniques','Ménage','Mode','Immobilier','Services','Auto & Moto','Autre')),
  city                  text not null check (city in ('Conakry','Coyah','Dubréka')),
  commune               text check (commune is null or commune in (
                          'Kaloum','Matoto','Gbessia','Tombolia','Ratoma','Sonfonia',
                          'Lambanyi','Dixinn','Matam','Kagbelen','Sanoyah','Manéah'
                        )),
  delivery_available    boolean not null default false,
  condition             text default 'Bon état', -- Neuf / Bon état / Usure normale / Autre
  management_pin        text, -- required secret code, so knowing a phone number alone isn't enough to manage/delete a listing
  image_url             text, -- primary/first photo (kept for backward compatibility)
  image_urls            jsonb not null default '[]'::jsonb, -- up to 5 photo URLs
  owner_name            text not null,
  owner_token           uuid not null,
  status                text not null default 'active' check (status in ('active','sold')),
  payment_status        text not null default 'free' check (payment_status in ('free','pending_verification','premium')),
  transaction_reference text,
  calculated_boost_fee  integer,
  boost_duration_days   integer, -- 1, 3, or 7: which boost tier the seller picked
  created_at            timestamptz not null default now(),
  expires_at            timestamptz not null default (now() + interval '30 days'),
  sold_at               timestamptz,
  premium_expires_at    timestamptz
);

create index if not exists idx_listings_active on listings (status, expires_at);
create index if not exists idx_listings_category on listings (category);
create index if not exists idx_listings_city on listings (city);
create index if not exists idx_listings_premium on listings (payment_status) where payment_status = 'premium';

-- Safe to re-run on an existing deployment:
alter table listings add column if not exists boost_duration_days integer;
alter table listings add column if not exists image_urls jsonb not null default '[]'::jsonb;
alter table listings add column if not exists management_pin text;
alter table listings add column if not exists condition text default 'Bon état';
alter table listings alter column expires_at set default (now() + interval '30 days');

-- ---------------------------------------------------------------
-- RATINGS  (one vote per phone number per device token)
-- ---------------------------------------------------------------
create table if not exists ratings (
  id           uuid primary key default gen_random_uuid(),
  seller_phone text not null,
  rating       integer not null check (rating between 1 and 5),
  voter_token  uuid not null,
  created_at   timestamptz not null default now(),
  unique (seller_phone, voter_token)
);

create index if not exists idx_ratings_phone on ratings (seller_phone);

-- ---------------------------------------------------------------
-- SELLERS  (lifetime post count per phone number — survives listings
-- being cleaned up, unlike counting current listings directly. No
-- login/account needed: just a running counter keyed by phone number.)
-- ---------------------------------------------------------------
create table if not exists sellers (
  phone_number  text primary key,
  total_posts   integer not null default 0,
  first_seen_at timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  verified      boolean not null default false, -- admin-controlled trust badge
  banned        boolean not null default false, -- admin-controlled suspension: blocks new posts, hides existing listings from buyers
  ban_reason    text
);

alter table sellers enable row level security;
alter table sellers add column if not exists verified boolean not null default false;
alter table sellers add column if not exists banned boolean not null default false;
alter table sellers add column if not exists ban_reason text;

create policy "public can read sellers" on sellers
  for select using (true);

create policy "anyone can insert sellers" on sellers
  for insert with check (true);

create policy "anyone can update sellers" on sellers
  for update using (true);

create policy "anyone can delete sellers" on sellers
  for delete using (true);

-- Atomic increment so two people posting at the same instant can never
-- clobber each other's count (a plain "read then write" from the client
-- would risk exactly that race condition).
create or replace function increment_seller_post_count(p_phone text)
returns void as $$
begin
  insert into sellers (phone_number, total_posts, first_seen_at, updated_at)
  values (p_phone, 1, now(), now())
  on conflict (phone_number)
  do update set total_posts = sellers.total_posts + 1, updated_at = now();
end;
$$ language plpgsql;

grant execute on function increment_seller_post_count(text) to anon, authenticated;

-- ---------------------------------------------------------------
-- MON CAHIER  (offline-first shopkeeping ledger, "Ma Boutique" in the
-- footer). Deliberately its OWN phone+PIN identity, separate from a
-- listing's management_pin — a shopkeeper using this may not even sell
-- on LouraMakiti itself. Same security model as the rest of the app:
-- no real auth, RLS is permissive, protection is the PIN + client-side
-- gating. This is genuinely more sensitive than listings (real
-- financial records, customer names, amounts owed) — worth being extra
-- clear with users that this isn't bank-grade security.
-- ---------------------------------------------------------------
create table if not exists cahier_owners (
  phone_number  text primary key,
  pin           text not null,
  boutique_name text,
  created_at    timestamptz not null default now(),
  banned        boolean not null default false, -- admin-controlled suspension: blocks unlock/recovery
  ban_reason    text
);

alter table cahier_owners enable row level security;
alter table cahier_owners add column if not exists banned boolean not null default false;
alter table cahier_owners add column if not exists boutique_name text;
alter table cahier_owners add column if not exists ban_reason text;
-- PIN brute-force lockout: 5 wrong tries locks this phone number's Cahier
-- for 1 hour (enforced in app code, not by RLS — same client-enforced
-- security model as the rest of this schema). Admin can clear a lockout
-- early from the admin panel once they've confirmed the seller's identity.
alter table cahier_owners add column if not exists failed_pin_attempts integer not null default 0;
alter table cahier_owners add column if not exists pin_locked_until timestamptz;
create policy "public can read cahier_owners" on cahier_owners for select using (true);
create policy "anyone can insert cahier_owners" on cahier_owners for insert with check (true);
create policy "anyone can update cahier_owners" on cahier_owners for update using (true);
create policy "anyone can delete cahier_owners" on cahier_owners for delete using (true);

create table if not exists cahier_entries (
  id             uuid primary key default gen_random_uuid(),
  phone_number   text not null references cahier_owners(phone_number) on delete cascade,
  type           text not null check (type in ('vente','depense','credit','dette')),
  amount         numeric not null,
  description    text,
  product        text,    -- only for vente/depense: product/item name
  quantity       numeric, -- only for vente/depense: units sold/bought
  unit_price     numeric, -- only for vente/depense: price per unit — amount = quantity * unit_price
  contact_name   text,
  contact_phone  text,
  status         text default 'impaye', -- 'impaye' | 'paye' — only meaningful for credit/dette
  payments       jsonb not null default '[]'::jsonb, -- [{amount, date}] partial payment history for credit/dette
  sale_group_id  uuid, -- links multiple line items from one "vente multi-articles" checkout (same customer, one go)
  created_at     timestamptz not null default now()
);
create index if not exists idx_cahier_entries_sale_group on cahier_entries (sale_group_id) where sale_group_id is not null;

create index if not exists idx_cahier_entries_phone on cahier_entries(phone_number);
alter table cahier_entries add column if not exists product text;
alter table cahier_entries add column if not exists quantity numeric;
alter table cahier_entries add column if not exists unit_price numeric;
alter table cahier_entries add column if not exists payments jsonb not null default '[]'::jsonb;

alter table cahier_entries enable row level security;
create policy "public can read cahier_entries" on cahier_entries for select using (true);
create policy "anyone can insert cahier_entries" on cahier_entries for insert with check (true);
create policy "anyone can update cahier_entries" on cahier_entries for update using (true);
create policy "anyone can delete cahier_entries" on cahier_entries for delete using (true);

-- ---------------------------------------------------------------
-- REPORTS  (structured "Signaler" tracking, one report per device
-- per listing so a single person can't inflate the count). A listing
-- gets auto-flagged (hidden from buyers, admin-reviewable) once 3
-- different people report it.
-- ---------------------------------------------------------------
alter table listings add column if not exists flagged boolean not null default false;

create table if not exists reports (
  id             uuid primary key default gen_random_uuid(),
  listing_id     uuid not null references listings(id) on delete cascade,
  reason         text,
  reporter_token uuid not null,
  created_at     timestamptz not null default now(),
  unique (listing_id, reporter_token)
);

create index if not exists idx_reports_listing on reports(listing_id);

alter table reports enable row level security;

create policy "public can read reports" on reports
  for select using (true);

create policy "anyone can insert reports" on reports
  for insert with check (true);

create or replace function check_listing_reports()
returns trigger as $$
declare
  report_count integer;
begin
  select count(distinct reporter_token) into report_count from reports where listing_id = new.listing_id;
  if report_count >= 3 then
    update listings set flagged = true where id = new.listing_id;
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_check_listing_reports on reports;
create trigger trg_check_listing_reports
after insert on reports
for each row execute function check_listing_reports();

-- ---------------------------------------------------------------
-- BANNERS  (category-sensitive "Sponsorisé" strip, admin-editable)
-- ---------------------------------------------------------------
create table if not exists banners (
  category    text primary key, -- 'Tout' or one of the listing categories
  image_url   text,
  link_url    text,
  image_url_2 text,
  link_url_2  text,
  image_url_3 text,
  link_url_3  text,
  updated_at  timestamptz not null default now()
);

-- Safe to re-run: adds the 3-image carousel columns to an existing table.
alter table banners add column if not exists image_url_2 text;
alter table banners add column if not exists link_url_2 text;
alter table banners add column if not exists image_url_3 text;
alter table banners add column if not exists link_url_3 text;

insert into banners (category, image_url, link_url) values
  ('Tout', null, null),
  ('Électroniques', null, null),
  ('Ménage', null, null),
  ('Mode', null, null),
  ('Immobilier', null, null),
  ('Services', null, null),
  ('Auto & Moto', null, null),
  ('Alimentation', null, null),
  ('Enfants', null, null),
  ('Agricole', null, null),
  ('Sport/Loisirs', null, null),
  ('Autre', null, null)
on conflict (category) do nothing;

alter table banners enable row level security;

create policy "public can read banners" on banners
  for select using (true);

create policy "anyone can update banners" on banners
  for update using (true);

create policy "anyone can insert banners" on banners
  for insert with check (true);

-- Simple key/value store for admin-editable site-wide settings (Facebook
-- page link, admin WhatsApp number) — so these can be changed from the
-- admin panel instead of editing index.html directly. Safe to re-run.
create table if not exists site_settings (
  key        text primary key,
  value      text,
  updated_at timestamptz not null default now()
);
alter table site_settings enable row level security;
create policy "public can read site_settings" on site_settings for select using (true);
create policy "anyone can insert site_settings" on site_settings for insert with check (true);
create policy "anyone can update site_settings" on site_settings for update using (true);
create policy "anyone can delete site_settings" on site_settings for delete using (true);

-- ---------------------------------------------------------------
-- ROW LEVEL SECURITY
-- No login exists in this app, so "ownership" is enforced only by
-- matching owner_token from the browser's localStorage. This is a
-- pragmatic MVP tradeoff, not cryptographic security — anyone with
-- the anon key can technically write to these tables. Before real
-- money volume, move mutations behind a Supabase Edge Function.
-- ---------------------------------------------------------------
alter table listings enable row level security;
alter table ratings  enable row level security;

create policy "public can read listings" on listings
  for select using (true);

create policy "anyone can create a listing" on listings
  for insert with check (true);

create policy "anyone can update a listing" on listings
  for update using (true);

create policy "anyone can delete a listing" on listings
  for delete using (true);

create policy "public can read ratings" on ratings
  for select using (true);

create policy "anyone can rate once per seller" on ratings
  for insert with check (true);

create policy "anyone can delete ratings" on ratings
  for delete using (true);

-- ---------------------------------------------------------------
-- STORAGE POLICIES for the 'listings' bucket
-- Marking a bucket "Public" in the dashboard only allows reading
-- files by URL — it does NOT allow uploads. storage.objects has its
-- own RLS, so we need explicit insert/select policies too.
-- ---------------------------------------------------------------
create policy "Public can upload to listings bucket"
on storage.objects for insert
to public
with check (bucket_id = 'listings');

create policy "Public can read listings bucket"
on storage.objects for select
to public
using (bucket_id = 'listings');

-- ---------------------------------------------------------------
-- SCHEDULED CLEANUP (requires the pg_cron extension, enabled by
-- default on most Supabase projects: Database > Extensions > pg_cron)
-- ---------------------------------------------------------------
create extension if not exists pg_cron;

-- Delete listings marked 'sold' for more than 48 hours
select cron.schedule(
  'louramakiti-delete-sold',
  '0 * * * *', -- every hour
  $$ delete from listings where status = 'sold' and sold_at < now() - interval '48 hours'; $$
);

-- NOTE: reaching expires_at no longer deletes a listing by itself — it just
-- stops showing to buyers. The seller can still see it under "Mes annonces"
-- (marked Expiré) and extend it by 30 more days. Only the hard 60-day
-- ceiling below actually deletes rows, unless an active sponsorship
-- protects the listing past that point.

-- Unschedule the old expiry-triggered delete job if it exists from an
-- earlier version of this schema (safe no-op if it was never created).
do $$
begin
  perform cron.unschedule('louramakiti-delete-expired');
exception when others then
  null;
end $$;

do $$
begin
  perform cron.unschedule('louramakiti-delete-30-days');
exception when others then
  null;
end $$;

-- Hard ceiling: delete ANY listing 60 days after it was first created
-- (30 days active + 30 days as an extendable "Expiré" listing) — even if
-- the seller kept clicking "Prolonger" — except if a boost was bought
-- near that cutoff and is still active, in which case the listing
-- survives until the paid sponsorship period actually ends.
select cron.schedule(
  'louramakiti-delete-60-days',
  '0 * * * *',
  $$ delete from listings
     where created_at < now() - interval '60 days'
       and not (payment_status = 'premium' and premium_expires_at > now()); $$
);

-- Revert premium listings back to free after 7 days
select cron.schedule(
  'louramakiti-expire-premium',
  '*/15 * * * *',
  $$ update listings set payment_status = 'free', premium_expires_at = null
     where payment_status = 'premium' and premium_expires_at < now(); $$
);

-- Note: the app ALSO filters these client-side as a safety net, so
-- behaviour is correct even before pg_cron first runs.
