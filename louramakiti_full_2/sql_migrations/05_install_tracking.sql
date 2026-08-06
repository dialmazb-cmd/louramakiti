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
