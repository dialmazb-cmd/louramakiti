# LouraMakiti — Project Summary

**What it is:** A lightweight, no-login classifieds marketplace PWA built for Guinea (🇬🇳), designed to work well on slow 2G/3G connections. Buyers browse and contact sellers directly via phone/WhatsApp/SMS; sellers post listings with just a phone number and a 4-digit secret code — no accounts, no passwords, no backend server beyond Supabase.

**Live stack:**
- Single-file frontend: `index.html` (vanilla HTML/CSS/JS, no framework, no build step)
- `sw.js` — service worker for offline app-shell caching + install-to-home-screen support
- `manifest.json`, `logo.png`, `icon-192.png`, `icon-512.png` — PWA branding/install assets
- `_headers` — Netlify cache-control rules (critical: prevents `sw.js`/`index.html` from being cached so app updates are actually detected on installed devices)
- `schema.sql` — full Supabase/Postgres schema: tables, RLS policies, triggers, and `pg_cron` scheduled jobs
- `README.md` — setup/deploy instructions
- Backend: Supabase (Postgres + Storage + `pg_cron`), accessed via the anon public key directly from the browser, secured by Row Level Security policies

**Brand identity:** Name "LouraMakiti" inspired by Mont Loura (Préfecture de Mali, Labé region). Palette: navy (`--night` #1B1F3B), mango yellow (`--mango` #F6C90E), palm green (`--palm` #2F5D50), pepper red (`--pepper` #E8533E), azure blue (`--azure` #2C6E91) for call buttons. Current slogan: "Le marché qui bouge avec vous." Logo is a custom Mont Loura cliff illustration.

---

## Core marketplace features
- **No-login posting**: phone number (with country-code picker, defaults to Guinée) + a seller-chosen 4-digit PIN are the only "credentials." Ownership of a listing is recognized either by the posting device's local token, or by re-entering phone+PIN from any device ("🔑 Retrouver via téléphone" under Mon Compte).
- **Mandatory photos**: 1–5 photos required per listing, accumulate one-at-a-time (not overwritten), client-side compressed via canvas (max 600px width, ~50% quality) before upload to Supabase Storage. All product images forced to 1:1 square, `object-fit: cover`.
- **Multi-photo gallery** on cards: swipeable, clickable dots, prev/next arrow buttons, and now **auto-rotates every 3.5s** (pauses/resumes on manual interaction).
- **Fields**: title, price, description (with a **"✨ Suggérer une description"** auto-generator that builds a sentence from title/price/location/delivery/condition — no AI backend, just smart templating), category, ville/commune (Conakry + 12 named communes, or Coyah/Dubréka), delivery Yes/No, item condition (Neuf/Bon état/Usure normale/Autre), seller/shop name.
- **Listing lifecycle**: 30 days active → auto-expires from buyer view (but seller can see it under "Mes annonces" marked ⏰ Expiré and extend 30 more days) → hard-deleted at 60 days total unless an active paid sponsorship is protecting it.
- **Auto-delete**: sold listings purge 48h after being marked sold.

## Buyer-facing features
- Search (instant, client-side), filters (Ville, Commune, Date posted, Price sort) tucked behind a "⚙️ Filtres" panel next to the search bar.
- Category picker (🏷️ Catégories) — modal-based, always labeled consistently so there's always an obvious way back to "Tout."
- Contact a seller via **Appeler / WhatsApp / SMS**, each pre-filled with a bargain message, each gated behind a one-time-dismissible **safety reminder** (don't pay before verifying, meet in public, etc.).
- **"💰 Faire une offre"** — buyer types a counter-offer amount, sends it via WhatsApp or SMS with an auto-built negotiation message.
- **Favorites/wishlist** (❤️), stored per-device in localStorage, with a quick-access heart button next to the search bar and inside "Mon Compte."
- **Star ratings**, one vote per device per seller phone (enforced via unique DB constraint + localStorage), hidden entirely if the seller has zero ratings (no "not yet rated" clutter).
- **Seller trust signals**: "Vendeur depuis X jours" and activity tier badge (Nouveau/Vendeur actif/Vendeur confirmé, based on **lifetime** post count via a dedicated `sellers` table — not just currently-visible listings), plus an admin-controlled "✅ Vérifié" badge.
- **"↗️ Partager"**: generates an actual branded image (photo + title + price + LouraMakiti watermark) via canvas and shares it through the native Web Share API (falls back to a plain WhatsApp text link on unsupported browsers, e.g. desktop).
- **"🚩 Signaler"**: logs a structured report (one per device per listing) in addition to pinging the admin on WhatsApp; a listing auto-hides from buyers once 3 different people report it (admin reviews in a dedicated panel tab).

## Sponsored/boost system
- Sellers can pay to sponsor a listing for 24h / 3 jours / 7 jours (flat GNF fees, editable constants), via manual Orange Money transfer + a transaction reference the admin verifies.
- System-wide cap: max 6 concurrently sponsored/pending listings (simplified from an earlier per-category design at the user's request).
- Sponsored items show in a "✨ Sponsorisé" carousel at the top of the homepage (randomized, capped at 6) and are excluded from duplicating in the regular grid below.
- Approving a boost in the admin panel auto-opens a WhatsApp message to the seller confirming activation.
- An active sponsorship overrides both the 30-day buyer-visibility expiry and the 60-day hard-delete ceiling — a boost bought near either cutoff keeps the listing alive for its full paid duration.

## Anti-fraud / trust tooling
- Structured reports table + auto-flag at 3 reports (above).
- **Daily post rate limit**: max 8 new listings per phone number per rolling 24h.
- **Duplicate-listing nudge**: warns (soft, dismissible) if the same phone posts the exact same title again within 24h.
- **Manual "Vendeur vérifié" badge**, toggled per phone number from the admin panel.

## Admin panel (`?admin=1` or the small `·` in the bottom corner, password-gated)
Tabs: **📊 Statistiques** (posts today/7d/30d, active/sold counts, unique sellers, sponsorship pipeline, category/city breakdown, average rating), **💳 Paiements** (pending boost approvals), **📋 Annonces** (every listing site-wide, searchable, grouped by date-posted buckets, paginated 30-at-a-time, delete/mark-sold regardless of which device posted it), **👥 Vendeurs** (lifetime activity ranking, verified-badge toggle, one-tap "reward this seller" WhatsApp message), **🚩 Signalements** (auto-flagged listings, restore or delete), **🖼️ Bannières** (per-category ad banner management — 3 rotating images for "Tout," 1 static image per specific category, upload-by-file with automatic compression, no URL-hosting needed).

## PWA / technical robustness
- Installable to home screen (banner prompt), works offline on repeat visits (app-shell caching only — data always hits the network live).
- **In-app update banner**: detects when a new version is deployed and offers "🔄 Actualiser" instead of requiring the user to clear browser data or reinstall. (This required fixing a real bug where `self.skipWaiting()` was firing unconditionally, defeating the whole mechanism, plus adding the `_headers` file so Netlify stops caching `sw.js` itself.)
- Publish-failure false-negative handling: if publishing throws an error but a flaky connection means it actually succeeded server-side, the app now double-checks before scaring the user with a false "échec" message.
- Everything server-communication-related is wrapped defensively; copyright/trademark care taken on the WhatsApp icon (an original SVG rendition, not Meta's literal logo file) and the Mont Loura artwork (AI-generated image, cropped/lettered, not reproducing anyone else's copyrighted work).

---

## Known tradeoffs (documented on purpose, not oversights)
- **"No login" security is client-side only.** Ownership = device token or phone+PIN match — not cryptographic auth. Fine at current scale; would need a real backend (Edge Function + possibly SMS OTP) before high-value/high-fraud-risk growth.
- **Activity/trust badges reflect current-and-lifetime-tracked data**, not a perfect historical record for sellers who were active before certain features existed.
- **Banner box is a fixed 7.5:1 aspect ratio** — deliberate, prevents cropping differences between phone and desktop; making it visually "bigger" on phone would require redesigning the shape (and regenerating templates) for both breakpoints together.
- **Share-image feature** depends on the Web Share API with file support — works on modern mobile Safari/Chrome, gracefully falls back to a plain text link on desktop/unsupported browsers.
- **Duplicate-listing detection** is exact-title-match only, not fuzzy — won't catch reworded spam.

## Supabase setup required (if starting fresh or reconciling in a new chat)
Run all of `schema.sql` in one go — it's idempotent (safe to re-run). Also required, done manually in the Supabase dashboard (not expressible in SQL): mark the `listings` storage bucket **Public**, and expose all tables (`listings`, `ratings`, `banners`, `sellers`, `reports`) under **Project Settings → Data API → Exposed tables** — new tables are NOT auto-exposed, which caused real debugging sessions earlier in this project.

## Files in this delivery
`index.html`, `sw.js`, `manifest.json`, `_headers`, `schema.sql`, `README.md`, `logo.png`, `icon-192.png`, `icon-512.png` — plus a separate `louramakiti-banner-templates` folder with example ad-banner images at the correct 1200×160 spec.
