import type { VercelRequest, VercelResponse } from '@vercel/node'

// Vercel Web Analytics lightweight proxy.
// Reads: VERCEL_TOKEN (project-level env var in Vercel dashboard)
// Uses: VERCEL_PROJECT_ID / VERCEL_ORG_ID (injected by Vercel at runtime)
// Returns last 7 days summary and top pages (best-effort) in a compact shape.

function toISOSeconds(ms: number) {
  return new Date(ms).toISOString()
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  try {
    const token = process.env.VERCEL_TOKEN
    const projectId = process.env.VERCEL_PROJECT_ID || req.query.projectId as string | undefined
    const teamId = process.env.VERCEL_ORG_ID || process.env.VERCEL_TEAM_ID || req.query.teamId as string | undefined

    if (!token) return res.status(500).json({ error: 'Missing VERCEL_TOKEN env' })
    if (!projectId) return res.status(500).json({ error: 'Missing VERCEL_PROJECT_ID' })

    const now = Date.now()
    const sevenDays = 7 * 24 * 60 * 60 * 1000
    const from = toISOSeconds(now - sevenDays)
    const to = toISOSeconds(now)

    // Helper to build URL with params
    const build = (base: string, params: Record<string, string | undefined>) => {
      const url = new URL(base)
      for (const [k, v] of Object.entries(params)) if (v) url.searchParams.set(k, v)
      return url.toString()
    }

    const headers = { Authorization: `Bearer ${token}` }

    // Summary (visits/pageviews) — endpoint may change; using current public path
    const summaryUrl = build('https://api.vercel.com/v1/analytics/summary', {
      projectId,
      teamId,
      from,
      to,
      unit: 'day'
    })

    const summaryResp = await fetch(summaryUrl, { headers })
    if (!summaryResp.ok) {
      const text = await summaryResp.text()
      return res.status(summaryResp.status).json({ error: 'vercel_summary_error', details: text })
    }
    const summary = await summaryResp.json()

    // Top pages (best-effort; if API differs, ignore failure gracefully)
    let topPages: any[] = []
    try {
      const topUrl = build('https://api.vercel.com/v1/analytics/top-pages', { projectId, teamId, from, to })
      const topResp = await fetch(topUrl, { headers })
      if (topResp.ok) {
        const j = await topResp.json()
        topPages = (j?.pages || j?.top || j || []).slice?.(0, 5) || []
      }
    } catch { /* ignore */ }

    res.setHeader('Cache-Control', 'public, s-maxage=300, stale-while-revalidate=600')
    return res.status(200).json({
      range: { from, to },
      projectId,
      visits: summary?.visits ?? summary?.total?.visits ?? null,
      pageviews: summary?.pageviews ?? summary?.total?.pageviews ?? null,
      series: summary?.series ?? undefined,
      topPages
    })
  } catch (e: any) {
    return res.status(500).json({ error: 'server_error', message: String(e?.message || e) })
  }
}

