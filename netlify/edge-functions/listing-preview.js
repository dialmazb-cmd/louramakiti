// LOURAMAKITI — LISTING-SPECIFIC LINK PREVIEWS
//
// What this does: when Facebook, WhatsApp, or another link-preview robot
// visits a listing link (e.g. louramakiti.com/?l=4X7B9K), this hands back
// a tiny page with THAT listing's own photo/title/price in its preview
// tags — instead of the site's generic logo, which is all those robots
// could ever see before, since they never run the app's JavaScript.
//
// Every real visitor, and every request that isn't a known preview robot
// checking a specific listing, passes straight through untouched via
// context.next() — this file never changes what a real person sees.

const CRAWLER_PATTERN = /facebookexternalhit|Facebot|WhatsApp|Twitterbot|LinkedInBot|Slackbot|TelegramBot|Discordbot|Pinterest|SkypeUriPreview|vkShare|redditbot/i;

const SUPABASE_URL = "https://aazhskxsowisrosewfkc.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFhemhza3hzb3dpc3Jvc2V3ZmtjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQ5MDU0NTMsImV4cCI6MjEwMDQ4MTQ1M30.hcqPcIKL54Bjh4xv8ih9x3AIai3_8TqWX-jTuAyNJOY";

function escapeHtml(s) {
  return String(s || '').replace(/[&<>"']/g, m => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[m]));
}

export default async (request, context) => {
  const url = new URL(request.url);
  const listingCode = url.searchParams.get('l') || url.searchParams.get('listing');
  const userAgent = request.headers.get('user-agent') || '';

  console.log(`[listing-preview] hit: path=${url.pathname} search=${url.search} ua="${userAgent}"`);

  if (!listingCode || !CRAWLER_PATTERN.test(userAgent)) {
    console.log(`[listing-preview] passing through — listingCode=${listingCode || 'none'} crawlerMatch=${CRAWLER_PATTERN.test(userAgent)}`);
    return context.next();
  }

  console.log(`[listing-preview] crawler detected for listing ${listingCode} — fetching from Supabase`);

  try {
    const res = await fetch(
      `${SUPABASE_URL}/rest/v1/listings?or=(short_code.eq.${encodeURIComponent(listingCode)},id.eq.${encodeURIComponent(listingCode)})&select=title,price,description,image_url,status&limit=1`,
      { headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` } }
    );
    if (!res.ok) {
      console.log(`[listing-preview] Supabase fetch failed: ${res.status}`);
      return context.next();
    }
    const rows = await res.json();
    const listing = rows && rows[0];
    if (!listing) {
      console.log(`[listing-preview] no listing found for code ${listingCode}`);
      return context.next();
    }
    console.log(`[listing-preview] found listing "${listing.title}" — serving custom preview`);

    const price = new Intl.NumberFormat('fr-FR').format(listing.price) + ' GNF';
    const title = escapeHtml(listing.title);
    const image = listing.image_url || `${url.origin}/og-image.png`;
    const rawDesc = listing.description || `${listing.title} à ${price} sur LouraMakiti.`;
    const desc = escapeHtml(rawDesc.length > 197 ? rawDesc.slice(0, 197) + '…' : rawDesc);
    const pageUrl = `${url.origin}/?l=${encodeURIComponent(listingCode)}`;

    const html = `<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<title>${title} — ${price} — LouraMakiti</title>
<meta property="og:type" content="product">
<meta property="og:site_name" content="LouraMakiti">
<meta property="og:title" content="${title} — ${price}">
<meta property="og:description" content="${desc}">
<meta property="og:image" content="${escapeHtml(image)}">
<meta property="og:url" content="${escapeHtml(pageUrl)}">
<meta name="twitter:card" content="summary_large_image">
<meta http-equiv="refresh" content="0;url=${escapeHtml(pageUrl)}">
</head>
<body>
<p>LouraMakiti — <a href="${escapeHtml(pageUrl)}">voir l'annonce : ${title}</a></p>
</body>
</html>`;

    return new Response(html, { headers: { 'content-type': 'text/html; charset=utf-8' } });
  } catch (e) {
    console.log(`[listing-preview] error: ${e && e.message}`);
    return context.next();
  }
};

export const config = { path: "/" };
