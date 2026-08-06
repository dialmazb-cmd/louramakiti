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
