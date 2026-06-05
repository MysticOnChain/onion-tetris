// /api/submit — score submission endpoint
// Called directly by QR code scan: GET /s?i=HWID&oid=ONIONID&sc=SCORE&l=LINES&lv=LEVEL&w=WALLET
const { createClient } = require('@supabase/supabase-js');

function getSupabase() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_KEY;
  if (!url || !key) throw new Error('Missing SUPABASE_URL or SUPABASE_SERVICE_KEY');
  return createClient(url, key);
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
    return data.username || data.handle || data.name || null;
  } catch {
    return null;
  }
}

module.exports = async function handler(req, res) {
  const { i, sc, l, lv, w, oid } = req.query;

  // ── Validation ──────────────────────────────────────────────────────────────
  if (!i || !sc) return res.status(400).send('Missing required params: i and sc');
  if (!/^[A-Fa-f0-9]{12}$/.test(i)) return res.status(400).send('Invalid badge ID');

  const scoreInt = parseInt(sc,  10);
  const linesInt = parseInt(l   || '0', 10);
  const levelInt = parseInt(lv  || '1', 10);
  const wallet   = (w  || '').trim();
  const onionId  = parseInt(oid || '0', 10) || null;

  if (isNaN(scoreInt) || scoreInt < 0 || scoreInt > 9999999) return res.status(400).send('Invalid score');
  if (isNaN(linesInt) || linesInt < 0) return res.status(400).send('Invalid lines');
  if (isNaN(levelInt) || levelInt < 1) return res.status(400).send('Invalid level');
  if (wallet && !/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(wallet)) return res.status(400).send('Invalid wallet');

  // ── Resolve handle ─────────────────────────────────────────────────────────
  const handle = onionId ? await resolveHandle(onionId) : null;

  // ── Rate limit ─────────────────────────────────────────────────────────────
  let supabase;
  try { supabase = getSupabase(); }
  catch (e) { return res.status(500).send(e.message); }

  const dayAgo = new Date(Date.now() - 86400000).toISOString();
  const { count } = await supabase
    .from('scores')
    .select('id', { count: 'exact', head: true })
    .eq('badge_id', i.toUpperCase())
    .gte('submitted_at', dayAgo);

  if (count >= 20) return res.status(429).send('Rate limit: 20 submissions per badge per day');

  // ── Insert ─────────────────────────────────────────────────────────────────
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
    onion_handle:   handle   || null,
    week_number:    week,
    week_year:      year,
  });

  if (error && error.code !== '23505') {
    console.error('Insert error:', JSON.stringify(error));
    return res.status(500).send('Database error');
  }

  res.redirect(302, 'https://MysticOnChain.github.io/onion-tetris/leaderboard.html');
};
