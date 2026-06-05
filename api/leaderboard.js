// /api/leaderboard-data — returns JSON leaderboard for current week
import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

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

function nextMonday() {
  const now = new Date();
  const d   = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const day = d.getUTCDay();
  d.setUTCDate(d.getUTCDate() + (day === 0 ? 1 : 8 - day));
  return d.toISOString();
}

export default async function handler(req, res) {
  const now  = new Date();
  const week = isoWeek(now);
  const year = isoWeekYear(now);

  // Fetch top 50 scores for this week, ordered by score desc
  const { data, error } = await supabase
    .from('scores')
    .select('badge_id, onion_id, onion_handle, wallet_address, score, lines, level, submitted_at')
    .eq('week_number', week)
    .eq('week_year',   year)
    .order('score', { ascending: false })
    .limit(50);

  if (error) {
    console.error('Leaderboard query error:', error);
    return res.status(500).json({ error: 'Database error' });
  }

  // Deduplicate: keep best score per badge
  const seen  = new Set();
  const top10 = [];
  for (const row of (data || [])) {
    if (!seen.has(row.badge_id)) {
      seen.add(row.badge_id);
      top10.push({
        badge_id:       row.badge_id,
        onion_id:       row.onion_id,
        onion_handle:   row.onion_handle,
        wallet_address: row.wallet_address,
        score:          row.score,
        lines:          row.lines,
        level:          row.level,
        submitted_at:   row.submitted_at,
      });
      if (top10.length >= 10) break;
    }
  }

  res.setHeader('Cache-Control', 's-maxage=30, stale-while-revalidate=60');
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.json({
    week,
    year,
    weekEnd: nextMonday(),
    prizes:  { first: 100, second: 50, third: 25, currency: 'ONION' },
    top10,
  });
}
