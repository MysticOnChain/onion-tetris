// /api/submit — score submission endpoint
// Called directly by QR code scan: GET /s?i=HWID&oid=ONIONID&sc=SCORE&l=LINES&lv=LEVEL&w=WALLET
import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

// Look up @handle from numeric Onion ID via oniondao.dev public profile API
async function resolveHandle(onionId) {
  if (!onionId || onionId === 0) return null;
  try {
    const res = await fetch(
      `https://oniondao.dev/api/public/profile/${onionId}`,
      { headers: { 'Accept': 'application/json' }, signal: AbortSignal.timeout(3000) }
    );
    if (!res.ok) return null;
    const data = await res.json();
    // Profile response contains username/handle field
    return data.username || data.handle || data.name || null;
  } catch {
    return null;   // don't block score submission if lookup fails
  }
}

function isoWeek(date) {
  const d = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()));
  d.setUTCDate(d.getUTCDate() + 4 - (d.getUTCDay() || 7));
  const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
  return Math.ceil((((d - yearStart) / 86400000) + 1) / 7);
}

function isoWeekYear(date) {
  const d = new Date(date);
  d.setDate(d.getDate() + 4 - (d.getDay() || 7));
  return d.getFullYear();
}

export default async function handler(req, res) {
  // Support both /submit and /s routes
  const { i, sc, l, lv, w, oid } = req.query;

  // ── Validation ──────────────────────────────────────────────────────────────
  if (!i || !sc) {
    return res.status(400).send('Missing required params: i (badge id) and sc (score)');
  }

  // Badge ID: 12-char hex (ESP32 MAC address)
  if (!/^[A-Fa-f0-9]{12}$/.test(i)) {
    return res.status(400).send('Invalid badge ID format');
  }

  const scoreInt = parseInt(sc,  10);
  const linesInt = parseInt(l   || '0', 10);
  const levelInt = parseInt(lv  || '1', 10);
  const wallet   = (w  || '').trim();
  const onionId  = parseInt(oid || '0', 10) || null;

  // Resolve @ handle from numeric Onion ID (non-blocking — fails gracefully)
  const handle = onionId ? await resolveHandle(onionId) : null;

  if (isNaN(scoreInt) || scoreInt < 0 || scoreInt > 9999999) {
    return res.status(400).send('Invalid score');
  }
  if (isNaN(linesInt) || linesInt < 0 || linesInt > 9999) {
    return res.status(400).send('Invalid lines');
  }
  if (isNaN(levelInt) || levelInt < 1 || levelInt > 99) {
    return res.status(400).send('Invalid level');
  }

  // Basic Solana wallet address validation (base58, 32-44 chars)
  if (wallet && !/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(wallet)) {
    return res.status(400).send('Invalid wallet address');
  }

  // ── Rate limiting: max 20 submissions per badge per day ───────────────────
  const dayAgo = new Date(Date.now() - 86400000).toISOString();
  const { count, error: countErr } = await supabase
    .from('scores')
    .select('id', { count: 'exact', head: true })
    .eq('badge_id', i.toUpperCase())
    .gte('submitted_at', dayAgo);

  if (countErr) console.error('Count error:', countErr);
  if (count >= 20) {
    return res.status(429).send('Rate limit: max 20 submissions per badge per day');
  }

  // ── Insert score ───────────────────────────────────────────────────────────
  const now  = new Date();
  const week = isoWeek(now);
  const year = isoWeekYear(now);

  const { error } = await supabase.from('scores').insert({
    badge_id:       i.toUpperCase(),
    score:          scoreInt,
    lines:          linesInt,
    level:          levelInt,
    wallet_address: wallet   || null,
    onion_id:       onionId  || null,
    onion_handle:   handle   || null,   // @handle resolved from Onion ID
    week_number:    week,
    week_year:      year,
  });

  if (error) {
    // 23505 = unique constraint violation (duplicate score) — silently ignore
    if (error.code !== '23505') {
      console.error('Insert error:', error);
      return res.status(500).send('Database error');
    }
  }

  // ── Redirect to leaderboard ────────────────────────────────────────────────
  res.redirect(302, 'https://MysticOnChain.github.io/onion-tetris/leaderboard.html');
}
