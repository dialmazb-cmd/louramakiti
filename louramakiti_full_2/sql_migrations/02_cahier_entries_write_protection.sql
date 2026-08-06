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
