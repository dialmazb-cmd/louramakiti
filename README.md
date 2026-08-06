# LouraMakiti — marketplace PWA for Guinea

Plain HTML/CSS/JS (no build step, no UI framework) + Supabase. Works offline
on repeat visits, degrades gracefully on 2G.

## Files
- `index.html` — the entire app (UI, buyer flow, seller flow, admin panel)
- `sw.js` — service worker, caches the app shell for instant/offline reloads
- `manifest.json`, `icon.svg` — PWA install metadata
- `schema.sql` — Supabase tables, RLS policies, and scheduled cleanup jobs

## 1. Create the Supabase project
1. Create a project at supabase.com (free tier is enough to start).
2. Open **SQL Editor** and run all of `schema.sql`. This creates `listings`,
   `ratings`, `banners`, their RLS policies, and three `pg_cron` jobs
   (auto-delete sold listings after 48h, auto-delete expired listings,
   auto-revert premium listings to free after 7 days).
   - If `pg_cron` isn't available on your plan, skip that section — the app
     already filters expired/old-sold rows out client-side, so behavior is
     correct either way; you'll just want a periodic cleanup job eventually
     to actually shrink the tables.
3. **Storage → New bucket** named `listings`, set it **public** (buyers need
   to load images directly from a CDN URL with no auth).

## 2. Point the app at your project
In `index.html`, near the top of the `<script type="module">` block, set:
```js
const SUPABASE_URL = "https://YOUR-PROJECT.supabase.co";
const SUPABASE_ANON_KEY = "YOUR_ANON_PUBLIC_KEY";
const ADMIN_PHONE = "224622000000";     // YOUR WhatsApp number, digits only, WITH country code (224 = Guinea) — no +, no spaces
```
The anon key is meant to be public; access is governed by the RLS policies
in `schema.sql`, not by hiding the key.

Also change `ADMIN_PASSWORD` (currently `LouraMakiti2026`) before you launch.

## 3. Deploy
Any static host works (Netlify, Vercel, GitHub Pages, Supabase Storage
itself, a $2/mo VPS with nginx). Just upload all the files at the same
level — no build step. Make sure the `_headers` file comes along too
(it's what tells Netlify never to cache `sw.js`/`index.html`, which is
required for the in-app update banner to actually detect new deploys —
without it, browsers can keep serving a stale cached copy of the app
shell indefinitely). If you deploy somewhere other than Netlify, that
host will need an equivalent no-cache rule for those two files instead.

## 4. Admin access
- Small `·` dot in the bottom-right corner of every page, or
- Visit `yoursite.com/index.html?admin=1`
- Password prompt, then approve/reject pending boost payments and edit the
  5 partner banner slots (Tout + 4 categories).

## What changed in this update

- **⚠️ Action required: WhatsApp links now work internationally.** Previously
  every phone number was force-prefixed with Guinea's country code (224),
  which silently broke WhatsApp links for any seller posting from outside
  Guinea. That auto-prefix is now removed — sellers must include their own
  country code when posting (the form now says so and gives examples).
  **You must update `ADMIN_PHONE` in `index.html`** to include your country
  code too (e.g. `224622000000` instead of `622000000`), or your own
  Appeler/WhatsApp Admin buttons will stop working correctly.
- **Mont Loura logo** — `logo.png`, `icon-192.png`, `icon-512.png` are built
  from the cliff-crest artwork you uploaded, lightly edited (the
  "AI-Generated" badge removed, "LOURAMAKITI" lettered onto the ribbon,
  cropped to a circle, palette-reduced to keep file size down — 6KB /
  15KB / 67KB respectively). The circular crest now sits next to the
  wordmark in the header, and the two PNGs replace `icon.svg` as the PWA's
  install icon in `manifest.json` and the browser favicon/apple-touch-icon.
  `icon.svg` is no longer referenced and can be deleted.
- **Landscape pushed to the bottom** — `body` is now a flex column
  (`min-height:100dvh`) and the mountain illustration has `margin-top:auto`,
  so it always sits at the very bottom of the screen instead of floating
  right under a short list of listings.
- **Call button color fixed** — "Appeler" buttons (on cards and in the new
  admin-contact row) used the same navy as the header, so they visually
  merged together when stacked near the top. They're now a distinct blue
  (`--azure`), separate from the header's navy, the WhatsApp green, and the
  mango/pepper/palm accents used elsewhere.


- **Livraison possible (Oui/Non)** — new `delivery_available` boolean on
  `listings`, a Oui/Non field on the form, and a 🚚 tag on cards that have it.
- **Hard 30-day auto-delete** — on top of the existing 14-day renewable
  expiry, every listing is now force-deleted 30 days after `created_at`,
  no matter how many times "Prolonger" was clicked. Enforced by a new
  `louramakiti-delete-30-days` `pg_cron` job in `schema.sql`, and mirrored
  client-side so it's correct even between cron runs.
- **Ville → Commune** — `city` is now one of `Conakry`, `Coyah`, `Dubréka`.
  A new `commune` column (nullable) only applies to Conakry, with these 12
  options: Kaloum, Matoto, Gbessia, Tombolia, Ratoma, Sonfonia, Lambanyi,
  Dixinn, Matam, Kagbelen, Sanoyah, Manéah. **Note:** the list you sent had
  "1. KaloumMatoto" as one line — I split that into Kaloum and Matoto (both
  real Conakry communes) to get 12 distinct options; shout if that's not
  what you meant. The seller form and the homepage filter both show a
  second "Commune" dropdown that appears only when Conakry is selected.

**If you already have a live database:** the old `city` column allowed
values like `Kaloum`/`Ratoma`/etc. directly with no `Conakry` wrapper.
Re-running `schema.sql` won't retroactively migrate existing rows — you'll
want to `update listings set commune = city, city = 'Conakry'` (adjusting
per row) before applying the new `city` check constraint, or just wipe the
table if it's still test data.

## Honest tradeoffs worth knowing about
- **"No-login" ownership is client-side, not cryptographic.** Edit/delete/
  mark-sold buttons appear when the browser's stored `owner_token` matches
  the row — exactly as specified — but the anon Supabase key can technically
  write to any row. Fine for an MVP; before real transaction volume, move
  mutations behind a Supabase Edge Function that checks a signed token.
- **Total page weight.** The app shell (HTML+CSS+JS) is ~41KB, which meets
  the "no framework, minimal CSS" spirit of the brief. The Supabase JS SDK
  itself (loaded from a CDN as an ES module) is a separate, larger, browser
  cached download — there's no way to talk to Postgres over HTTP from the
  browser in a few KB without hand-rolling REST calls against PostgREST
  directly. If the 2G budget needs to be absolute, the next step is
  replacing the SDK import with raw `fetch()` calls to the PostgREST/Storage
  REST endpoints, cutting that dependency entirely.
- **WhatsApp status share** uses `https://wa.me/?text=...`, WhatsApp's real
  supported deep-link pattern, instead of a bare `https://whatsapp.com` URL
  with query text (which WhatsApp doesn't actually parse).
- **Scheduled cleanup** (48h sold-listing purge, 14-day expiry, 7-day
  premium revert) relies on `pg_cron` running in Postgres; the client also
  filters these out defensively so nothing incorrect is ever shown even if
  a cron run is delayed.
- **Listing detail pages** don't exist as separate routes — everything a
  buyer needs (photo, price, description snippet, call/WhatsApp, rating) is
  on the card itself, which keeps the app single-page and avoids a router
  library. The "share to WhatsApp Status" link points back to
  `index.html?listing=<id>`; wire up a highlight/scroll-to for that param if
  you want the deep link to visually jump to the item.
