import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Line, Phase, Sess, SessState, Task, Today } from '../types'

const phase = atom({ plugin: 'parley-ui', key: 'phase' } as const, 'off' as Phase)
const line = atom({ plugin: 'parley-ui', key: 'line' } as const, '')
const history = atom({ plugin: 'parley-ui', key: 'history' } as const, [] as Line[])
const tick = atom({ plugin: 'parley-ui', key: 'tick' } as const, 0)
const isHidden = atom({ plugin: 'parley-ui', key: 'isHidden' } as const, false)
const level = atom({ plugin: 'parley-ui', key: 'level' } as const, null as number | null)
const overview = atom({ plugin: 'parley-ui', key: 'overview' } as const, null as Sess[] | null)
const seen = atom({ plugin: 'parley-ui', key: 'seen' } as const, 0)
const today = atom({ plugin: 'parley-ui', key: 'today' } as const, null as Today | null)
const expanded = atom({ plugin: 'parley-ui', key: 'expanded' } as const, [] as string[])
const tasks = atom({ plugin: 'parley-ui', key: 'tasks' } as const, [] as Task[])
const sessSkip = atom({ plugin: 'parley-ui', key: 'sessSkip' } as const, 0)
const histSkip = atom({ plugin: 'parley-ui', key: 'histSkip' } as const, 0)
const isWorking = atom({ plugin: 'parley-ui', key: 'isWorking' } as const, false)
const awaiting = atom({ plugin: 'parley-ui', key: 'awaiting' } as const, null as string | null)
const delivered = atom({ plugin: 'parley-ui', key: 'delivered' } as const, [] as string[])

const PANE = 'parley'
const BARS = '▁▂▃▄▅▆▇█'
const APP = 'http://127.0.0.1:8787' // ponytail: default port; read PARLEY_PORT when someone moves it
const LIVE: readonly Phase[] = ['speaking', 'listening', 'transcribing']

// Same rule as plugin/scripts/stop-hook.sh: the LAST opening tag wins, its close optional (for
// <speak-end> too, as the hook takes it: a turn the mod leaves to the hook must be one it voices).
export function parseSpeak(msg: string): { text: string; listen: boolean; to?: string } | null {
  const end = msg.lastIndexOf('<speak-end>')
  // v7: <speak to="Max"> asks a guest of a shared session, like stop-hook.sh.
  const opens = [...msg.matchAll(/<speak(?:\s+to="([^"<>]{0,40})")?>/g)]
  const last = opens.at(-1)
  const speak = last?.index ?? -1
  if (end < 0 && speak < 0) return null
  const listen = speak > end
  const open = listen ? last![0] : '<speak-end>'
  const rest = msg.slice((listen ? speak : end) + open.length)
  const close = rest.indexOf(listen ? '</speak>' : '</speak-end>')
  const text = (close < 0 ? rest : rest.slice(0, close)).trim()
  const to = listen ? last?.[1] : undefined
  return text ? { text, listen, ...(to ? { to } : {}) } : null
}

type Turn = { speak: string; replies: { on: string; say: string; listen: boolean }[]; slides: Record<string, string | number>[] }

// The rest of what stop-hook.sh sends with /turn, by its rules: the <reply on="…" [listen]>
// lines directly above a final <speak> (at most 4), and the <slide …/> markers (at most 6) taken
// out of the spoken text, each with the index of the word it precedes.
export function turnParts(msg: string, spoken: { text: string; listen: boolean }): Turn {
  const flat = (v: string) => v.replace(/[\t\n]+/g, ' ').trim()
  const replies: Turn['replies'] = []
  let pre = spoken.listen ? msg.slice(0, [...msg.matchAll(/<speak(?:\s+to="[^"<>]{0,40}")?>/g)].at(-1)?.index ?? 0) : ''
  for (let m; replies.length < 4 && (m = /^([\s\S]*)<reply\b([^>]*)>((?:(?!<\/?reply\b)[\s\S])*)<\/reply>\s*$/.exec(pre));) {
    const [, head = '', attrs = '', inner = ''] = m
    pre = head
    const on = /on="([^"]*)"/.exec(attrs)?.[1]
    const say = flat(inner)
    if (on !== undefined && say) replies.unshift({ on: flat(on), say, listen: /\blisten\b/.test(attrs.replace(/on="[^"]*"/, '')) })
  }
  // The raw text up to its close, as the hook cuts it (parseSpeak trims it already: same words).
  const slides: Turn['slides'] = []
  let clean = '', rest = spoken.text
  for (let m; slides.length < 6 && (m = /<slide\b([^>]*?)\/?>/.exec(rest));) {
    clean += rest.slice(0, m.index)
    rest = rest.slice(m.index + m[0].length)
    const kv = [...(m[1] ?? '').matchAll(/(\w+)="([^"]*)"/g)].map(([, k = '', v = '']) => [k, v.replace(/[\t\n]+/g, ' ')] as const)
    if (kv.length) slides.push({ word: clean.split(/\s+/).filter(Boolean).length, ...Object.fromEntries(kv) })
  }
  const speak = (clean + rest).replace(/<slide\b[^>]*>/g, '').replace(/[ \t]{2,}/g, ' ').trim()
  return { speak, replies, slides }
}

// The app overlay's motion (RecordingHUD.swift): not a scrolling sample history but one
// travelling wave whose height follows the eased volume, tapered to the ends. Period 2π.
export function bar(i: number, n: number, p: number): number {
  const env = Math.sin((i / (n - 1)) * Math.PI)
  return env * Math.max(0, 0.55 + 0.3 * Math.sin(p + i * 0.55) + 0.15 * Math.sin(2 * p + i * 0.22))
}
const gain = (vol: number) => 0.12 + 0.88 * vol // a quiet idle wave even in silence

// Asymmetric one-pole smoothing per 100 ms poll: rise τ≈80 ms, fall τ≈350 ms (VU-like, calm).
// Quantised so near-equal values do not redraw.
export function ease(prev: number, target: number): number {
  const a = target > prev ? 0.71 : 0.25
  return Math.round((prev + (target - prev) * a) * 50) / 50
}

// Terminal: the same wave in block glyphs.
export function wave(p: number, n: number, vol: number): string {
  let s = ''
  for (let i = 0; i < n; i++) s += BARS[Math.min(7, Math.floor(bar(i, n, p) * gain(vol) * 8))]
  return s
}

// Desktop: rounded bars as SVG that animates itself (SMIL): the overlay's travelling wave
// plus a slow breathing of its height. The source depends on the phase alone — the desktop
// reloads an Svg whenever its source changes, and a reload per level update flickered.
const PERIOD = 2.4 // s per wave cycle; the overlay's ~1.2 s halved for a calmer inline band
const BREATH = { speaking: { gains: [0.62, 0.85, 0.7, 0.95, 0.66, 0.8, 0.62], dur: 3.7 },
                 listening: { gains: [0.22, 0.34, 0.26, 0.4, 0.24, 0.3, 0.22], dur: 2.9 } }
export const WAVE = { width: 168, height: 28 }
export function waveSvg(mode: keyof typeof BREATH, color: string): string {
  const n = 28, K = 24, { width: w, height: h } = WAVE, { gains, dur } = BREATH[mode]
  const slot = w / n, sw = slot * 0.5
  let bars = ''
  for (let i = 0; i < n; i++) {
    const ys = Array.from({ length: K + 1 }, (_, k) => ((bar(i, n, (k / K) * 2 * Math.PI) * (h - sw)) / 2).toFixed(1))
    const anim = (attr: string, sign: string) =>
      `<animate attributeName="${attr}" values="${ys.map(y => sign + y).join(';')}" dur="${PERIOD}s" repeatCount="indefinite"/>`
    const x = (slot * (i + 0.5)).toFixed(1)
    bars += `<line x1="${x}" x2="${x}" y1="-${ys[0]}" y2="${ys[0]}">${anim('y1', '-')}${anim('y2', '')}</line>`
  }
  const ease = gains.slice(1).map(() => '0.45 0 0.55 1').join(';')
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">`
    + `<style>line{vector-effect:non-scaling-stroke}</style>`
    + `<g transform="translate(0 ${h / 2})"><g transform="scale(1 ${gains[0]})">`
    + `<animateTransform attributeName="transform" type="scale" values="${gains.map(g => `1 ${g}`).join(';')}" dur="${dur}s" calcMode="spline" keySplines="${ease}" repeatCount="indefinite"/>`
    + `<g stroke="${color}" stroke-opacity="0.9" stroke-width="${sw}" stroke-linecap="round">${bars}</g></g></g></svg>`
}

const isWaiting = (p: Phase) => p === 'queued' || LIVE.includes(p)

type Status = { phase: string; session: string; levels: number[] }
const COLOR = { speaking: '#D97757', listening: '#E5484D' } // Claude orange; red as the overlay

// `mine`: a say over each status first (false = leave the phase alone).
async function poll($: EngineInterface, session: string, mine?: (st: Status) => boolean): Promise<boolean> {
  const res = await $.http.fetch(`${APP}/status`).catch(() => null)
  if (!res?.ok) return false
  const st = JSON.parse(res.text) as Status
  if (mine && !mine(st)) return true
  if (st.session !== session) {
    // Another project holds the voice right now; ours waits in the app's queue.
    if (st.phase !== 'idle') await update($, phase, p => (isWaiting(p) ? 'queued' : p))
    return true
  }
  if ((LIVE as readonly string[]).includes(st.phase)) {
    // A poll still in flight when the turn ended must not undo 'heard'/'parked'.
    await update($, phase, p => (isWaiting(p) ? (st.phase as Phase) : p))
    const target = Math.max(0, ...st.levels.slice(-3))
    const prev = await read($, level)
    const next = ease(prev ?? 0, target)
    if (next !== prev) await update($, level, () => next)
  }
  return true
}

// ── Session overview (/parley pane): every Parley session's state from the app ──────────

const STATE: Record<SessState, { label: string; tone: string; hex: string; glyph: string }> = {
  speaking: { label: 'spricht', tone: 'claude', hex: '#D97757', glyph: '◉' },
  listening: { label: 'hört zu', tone: 'claude', hex: '#D97757', glyph: '◉' },
  transcribing: { label: 'transkribiert', tone: 'claude', hex: '#D97757', glyph: '◉' },
  queued: { label: 'Warteschlange', tone: 'warning', hex: '#D9A43B', glyph: '◌' },
  working: { label: 'arbeitet', tone: 'suggestion', hex: '#5B8DEF', glyph: '◐' },
  background: { label: 'Agent im Hintergrund', tone: 'permission', hex: '#9B87F5', glyph: '◍' },
  waiting: { label: 'pausiert', tone: 'warning', hex: '#D9A43B', glyph: '◔' },
  parked: { label: 'geparkt', tone: 'inactive', hex: '#8B8A85', glyph: '⏸' },
  idle: { label: 'bereit', tone: 'success', hex: '#4EBA65', glyph: '○' },
  stopped: { label: 'gestoppt', tone: 'inactive', hex: '#8B8A85', glyph: '■' },
}

const clockText = (ms: number) => {
  const s = Math.max(0, Math.floor(ms / 1000)), h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60)
  const pad = (n: number) => String(n).padStart(2, '0')
  return h ? `${h}:${pad(m)}:${pad(s % 60)}` : `${m}:${pad(s % 60)}`
}
export function timer(s: Sess, at: number): string {
  if (s.state === 'waiting' && s.until) return `noch ${clockText(s.until - at)}`
  if (s.state === 'stopped') return `vor ${Math.max(1, Math.round((at - s.since) / 60000))} min`
  return `seit ${clockText(at - s.since)}`
}

// The ring per tile (design C). Its source depends on the state alone, never on the clock,
// so the redraw every second leaves the running SMIL animation alone. A countdown starts
// from where it stood when first drawn (`from`, fraction left) and drains to `until`.
// One dot per background job (at most 5), evenly spaced, circling together; each pulses in turn
// and the core breathes.
function orbit(jobs: number, col: string): string {
  const n = Math.min(5, Math.max(1, jobs)), base = [3.5, 3.3, 3, 2.7, 2.5][n - 1]
  const dots = Array.from({ length: n }, (_, i) => {
    const a = 2 * Math.PI * i / n, x = (20 + 15 * Math.sin(a)).toFixed(2), y = (20 - 15 * Math.cos(a)).toFixed(2)
    const lo = (base * 0.85).toFixed(2), hi = (base * 1.15).toFixed(2)
    return `<circle cx="${x}" cy="${y}" r="${base}" fill="${col}"><animate attributeName="r" values="${lo};${hi};${lo}" dur="1.8s" begin="${(1.8 * i / n).toFixed(2)}s" repeatCount="indefinite"/></circle>`
  }).join('')
  return `<g>${dots}<animateTransform attributeName="transform" type="rotate" from="0 20 20" to="360 20 20" dur="2.4s" repeatCount="indefinite"/></g>`
    + `<circle cx="20" cy="20" r="4" fill="${col}"><animate attributeName="r" values="4;5.2;4" dur="3.2s" repeatCount="indefinite"/></circle>`
}

export function ringSvg(s: Sess, from: number, at: number): string {
  const r = 15, c = +(2 * Math.PI * r).toFixed(2), col = STATE[s.state].hex
  const arc = (frac: number, extra = '') =>
    `<circle cx="20" cy="20" r="${r}" fill="none" stroke="${col}" stroke-width="3" stroke-linecap="round" stroke-dasharray="${(c * frac).toFixed(2)} ${c}" transform="rotate(-90 20 20)">${extra}</circle>`
  const spin = (frac: number, dur: number) =>
    `<g>${arc(frac)}<animateTransform attributeName="transform" type="rotate" from="0 20 20" to="360 20 20" dur="${dur}s" repeatCount="indefinite"/></g>`
  const inner =
    s.voice || s.state === 'speaking' || s.state === 'listening' || s.state === 'transcribing'
      ? `${arc(1)}<circle cx="20" cy="20" r="7" fill="${col}"><animate attributeName="r" values="6;9;6" dur="1.4s" repeatCount="indefinite"/></circle>`
    : s.state === 'working' ? spin(0.28, 1.6)
    : s.state === 'queued' ? spin(0.12, 4)
    : s.state === 'background'
      ? `${arc(1).replace('stroke-width="3"', 'stroke-width="3" stroke-opacity="0.35"')}${orbit(s.tasks?.length ?? 1, col)}`
    : s.state === 'waiting' && s.until
      ? arc(from, `<animate attributeName="stroke-dasharray" from="${(c * from).toFixed(2)} ${c}" to="0 ${c}" dur="${Math.max(0.1, (s.until - at) / 1000).toFixed(1)}s" fill="freeze"/>`)
    : s.state === 'parked' ? `<rect x="14" y="13" width="4" height="14" rx="1.5" fill="${col}"/><rect x="22" y="13" width="4" height="14" rx="1.5" fill="${col}"/>`
    : s.state === 'idle' ? `${arc(1).replace('stroke-width="3"', 'stroke-width="3" stroke-opacity="0.45"')}<circle cx="20" cy="20" r="5" fill="${col}"/>`
    : `<rect x="15" y="15" width="10" height="10" rx="2" fill="${col}"/>`
  return `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" viewBox="0 0 40 40">`
    + `<circle cx="20" cy="20" r="${r}" fill="none" stroke="${col}" stroke-opacity="0.18" stroke-width="3"/>${inner}</svg>`
}

// What a tile's details show: the figures you'd ask about a session at a glance, as
// label/value pairs for a two-column grid (the last line and background tasks go below).
export function facts(s: Sess, at: number): [string, string][] {
  const st = s.stats
  if (!st) return []
  const out: [string, string][] = []
  if (st.startedAt != null) out.push(['Laufzeit', span(at - st.startedAt)])
  if (st.contextPercent != null) out.push(['Kontext', `${Math.round(st.contextPercent)} %`])
  if (st.costUsd != null) out.push(['Kosten', `$${st.costUsd.toFixed(2)}`])
  out.push(['Updates', `${st.turns} · ${st.replies} Antw.`])
  return out
}
// "Agent im Hintergrund" for subagents/workflows, "Job im Hintergrund" for shells etc.
export function bgLabel(s: Sess): string | null {
  if (s.state !== 'background') return null
  const list = s.tasks ?? []
  const agents = list.filter(t => t.type === 'subagent' || t.type === 'workflow').length
  if (!list.length || agents === list.length) return agents > 1 ? `${agents} Agents im Hintergrund` : 'Agent im Hintergrund'
  return list.length > 1 ? `${list.length} Jobs im Hintergrund` : 'Job im Hintergrund'
}
const span = (ms: number) => {
  const m = Math.max(0, Math.round(ms / 60000))
  return m < 60 ? `${m} min` : `${Math.floor(m / 60)} h ${m % 60} min`
}
const LIMIT: Record<string, string> = { five_hour: '5-h-Limit', seven_day: 'Woche' }
// Today's totals as value/label pairs: values bold, labels dim.
export function todayParts(d: Today): [string, string][] {
  const parts: [string, string][] = [[`$${d.costUsd.toFixed(2)}`, 'Kosten'], [`${d.turns}`, 'Updates'],
    [`${Math.round(d.spokenSeconds / 60)} min`, 'gesprochen']]
  for (const r of d.rateLimits) {
    const name = LIMIT[r.kind]
    if (name) parts.push([`${Math.round(r.percentUsed)} %`, name])
  }
  return parts
}

// The history's top edge: a gradient from the pane's background to transparent laid over the
// clipped lines, so the oldest one fades out instead of being cut. The mod cannot read the
// desktop's theme, so the colour follows the system's scheme (dark measured at #191918).
export const FADE = `<svg xmlns="http://www.w3.org/2000/svg" width="100%" height="48" preserveAspectRatio="none" viewBox="0 0 10 48">`
  + `<style>stop{stop-color:#FAF9F5}@media (prefers-color-scheme: dark){stop{stop-color:#191918}}</style>`
  + `<defs><linearGradient id="f" x1="0" y1="0" x2="0" y2="1"><stop offset="0"/><stop offset="0.35" stop-opacity="0.85"/>`
  + `<stop offset="1" stop-opacity="0"/></linearGradient></defs><rect width="10" height="48" fill="url(#f)"/></svg>`

// Where a wheel tick goes in the split pane: over the top half (when the tiles overflow it)
// it moves the session rows (3 rows a tile row), anywhere else the history (2 rows a message, counted back from the
// newest). Fractional, so small trackpad moves add up; clamped to what exists.
export function scrollPane(by: number, bodyRows: number, row: number | undefined,
  s: { sess: number; sessMax: number; hist: number; histMax: number }): { sess: number; hist: number } {
  const clamp = (v: number, max: number) => Math.max(0, Math.min(Math.max(0, max), v))
  // Sessions take the wheel only when they overflow their half; otherwise anywhere scrolls the history.
  return s.sessMax > 0 && row !== undefined && row < Math.floor(bodyRows / 2)
    ? { sess: clamp(s.sess + by / 3, s.sessMax), hist: s.hist }
    : { sess: s.sess, hist: clamp(s.hist - by / 2, s.histMax) }
}

async function readLabel($: EngineInterface, cwd: string): Promise<string> {
  const cfg = await $.fs.read(`${cwd}/.parley.json`).catch(() => '')
  try { return String(JSON.parse(String(cfg)).name ?? '') } catch { return '' }
}
const basename = (cwd: string) => cwd.split(/[\\/]/).pop() ?? '' // Windows cwd uses backslashes

// ── Ohne Stop-Hook (docs/HOOKLESS.md): the mod posts the turn and returns; its reply comes
// back on /presence as a delivery. Module state starts over on a hot reload; what must outlive
// one (the open turn, the ids already submitted) is in $.state.

let interactive = false // a prompt box: under -p / the SDK the process ends after the Stop
let hostAsync = { ok: false, at: -Infinity } // GET /health says async:1; asked again each minute
let open = false // the app's last answer carried a delivery: presence every 0.5 s until it's gone
const taken = new Set<string>() // delivery ids submitted (beside `delivered`, at once: no race)

async function hostCarries($: EngineInterface): Promise<boolean> {
  if (!interactive) return false
  const t = await $.clock.now()
  if (t - hostAsync.at < 60000) return hostAsync.ok
  const res = await $.http.fetch(`${APP}/health`).catch(() => null)
  let ok = false
  try { ok = !!res?.ok && (JSON.parse(res.text) as { async?: number }).async === 1 } catch {}
  hostAsync = { ok, at: t }
  return ok
}

// The app's /status while the posted turn waits for its voice: queued → speaking → listening.
// Once its voice is done the delivery (or nothing) follows on presence; a wait shows parked.
let watcher: { cancel(): void } | null = null
let over: number | null = null // when its voice ended (0 = just now, stamped by the next presence)
function watch($: EngineInterface, session: string) {
  watcher?.cancel()
  let voiced = false, busy = false
  over = null
  watcher = $.clock.every(100, () => {
    if (busy) return
    busy = true
    void poll($, session, st => {
      if (st.session === session && (LIVE as readonly string[]).includes(st.phase)) voiced = true
      else if (voiced) over ??= 0
      return over === null
    }).catch(() => {}).finally(() => { busy = false })
  })
}
async function settle($: EngineInterface, p: Phase) {
  watcher?.cancel()
  watcher = null
  over = null
  await update($, awaiting, () => null)
  await update($, level, () => null)
  await update($, phase, () => p)
}

async function presence($: EngineInterface, sid: string, cwd: string, label: string) {
  const u = await $.session.usage().catch(() => null)
  const turn = await read($, awaiting)
  const ack = (await read($, delivered)).at(-1)
  const body = JSON.stringify({
    session_id: sid, label, project: basename(cwd), cwd,
    ...((await hostCarries($)) ? { async: 1 } : {}), ...(turn ? { awaiting: turn } : {}), ...(ack ? { ack } : {}),
    host: (await $.env.get('CLAUDE_CODE_HOST_SESSION_ID').catch(() => undefined)) ?? null, // the desktop app's id: tiles open it
    state: (await read($, isWorking)) ? 'working' : (await read($, tasks)).length ? 'background' : 'idle',
    tasks: await read($, tasks),
    usage: u && {
      startedAt: u.startedAt, contextPercent: u.context.percent ?? null, contextTokens: u.context.tokens ?? null,
      contextWindow: u.context.window, costUsd: u.cost?.usd ?? null,
      rateLimits: u.rateLimits.map(r => ({ kind: r.kind, percentUsed: r.percentUsed, resetsAt: r.resetsAt ?? null })),
    },
  })
  const res = await $.http.fetch(`${APP}/presence`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body }).catch(() => null)
  // A delivery: the posted turn's reply, or "Fortsetzen" on an idle session (the app ran the
  // voice dialog) — submitted once per delivery_id, acked with the next presence.
  const got = res?.ok ? (JSON.parse(res.text || '{}') as { instruction?: string; delivery_id?: string; unknown_turn?: boolean }) : {}
  const id = got.delivery_id
  open = !!id
  if (got.instruction && !(id && (taken.has(id) || (await read($, delivered)).includes(id)))) {
    if (id) {
      taken.add(id)
      await update($, delivered, list => [...list, id].slice(-20))
    }
    if (await read($, awaiting)) await settle($, 'heard')
    await update($, isWorking, () => true)
    await log($, 'you', got.instruction)
    await $.prompt.submit({ text: got.instruction, asUser: true })
  }
  // The app has no such turn (answered with nothing, or restarted): no more waiting.
  if (got.unknown_turn && (await read($, awaiting))) await settle($, 'parked')
  // Its voice is done and no reply came within a second: parked (or Sir's wait runs).
  if (over !== null && (await read($, awaiting))) {
    const t = await $.clock.now()
    if (!over) over = t
    else if (t - over >= 1000) {
      watcher?.cancel()
      watcher = null
      await update($, phase, p => (isWaiting(p) ? 'parked' : p))
    }
  }
}

// Brings a session forward in the desktop app: its claude:// deep link, opened by the OS.
const HOST = /^local_[A-Za-z0-9-]{1,64}$/ // the desktop's own check; also keeps the argv inert
async function openSession($: EngineInterface, host: string) {
  if (!HOST.test(host)) return
  const url = `claude://code/continue?session=${host}`
  const windows = (await $.env.get('OS').catch(() => undefined)) === 'Windows_NT'
  await $.process.run(windows ? ['cmd', '/c', 'start', '', url] : ['open', url]).catch(() => null)
}

async function log($: EngineInterface, who: Line["who"], text: string) {
  const at = await $.clock.now()
  await update($, history, list => [...list, { who, text, at }].slice(-100))
}

let label = ''
let selfId = '' // this session's id: its own tile says "hier" and offers no ↗ to itself
let home = '' // the folder the session started in

// Only once this session talks through Parley (phase leaves 'off'): report to the app
// every 2 s (alive, working, usage figures; the reply may hand back a resume
// instruction) — every 0.5 s while a posted turn or a delivery is open —, and fetch every
// session's state each second for the overview. A hot reload cancels the timer: the next
// Stop / prompt / turn arms it again.
let loop: { cancel(): void } | null = null
let beat = -Infinity, sentAt = -Infinity, fetchedAt = -Infinity
async function arm($: EngineInterface) {
  if (!home) return
  const t = await $.clock.now()
  if (loop && t - beat < 3000) return
  loop?.cancel()
  beat = t
  loop = $.clock.every(500, () => {
    void $.clock.now().then(async t => {
      beat = t
      if ((await read($, phase)) === 'off') return
      const sid = await $.session.id() // not the one at start: a /clear goes on under another
      selfId = sid
      if (t - sentAt >= 2000 || open || (await read($, awaiting))) {
        sentAt = t
        label ||= (await readLabel($, home)) || basename(home)
        await presence($, sid, home, label)
      }
      if (t - fetchedAt < 1000) return
      fetchedAt = t
      const res = await $.http.fetch(`${APP}/sessions`).catch(() => null)
      const body = res?.ok ? (JSON.parse(res.text) as { sessions: Sess[]; today?: Today }) : null
      await update($, overview, () => body?.sessions ?? null)
      await update($, today, () => body?.today ?? null)
      await update($, seen, () => t)
    }).catch(() => {})
  })
  const turn = await read($, awaiting)
  if (turn && !watcher) watch($, turn.slice(0, turn.lastIndexOf(':')))
}

export const register: Register = on => {
  // A (re)load starts the module's own state over, as the engine does for a hot reload.
  label = ''; selfId = ''; home = ''; interactive = false; open = false
  loop = null; watcher = null; over = null; beat = sentAt = fetchedAt = -Infinity
  hostAsync = { ok: false, at: -Infinity }
  taken.clear()
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'parley', description: 'Parley: Sessions und Gesprächsverlauf als Pane öffnen' })
    selfId = await $.session.id()
    home = e.cwd
    interactive = e.isInteractive
    await arm($)
    $.clock.every(140, () => {
      void read($, phase).then(p => {
        if (p === 'speaking' || p === 'listening') void update($, tick, t => t + 1) // terminal wave only
      })
    })
    return next(e)
  })

  on('command.run', { command: 'parley' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Parley' })
    return { text: 'Parley-Verlauf geöffnet.' }
  })

  // Wrap the existing Stop hook (stop-hook.sh does the transport): show what is spoken,
  // wait while the app speaks + records, then show what came back.
  on('classic.Stop', async ($, e, next) => {
    // Every Stop ends the turn — one without <speak> too, or presence says "working" forever.
    await update($, isWorking, () => false)
    await update($, tasks, () => (e.background_tasks ?? []).map(t => ({ type: t.type, description: t.description })))
    await arm($)
    const spoken = parseSpeak(e.last_assistant_message ?? '')
    if (!spoken) return next(e)

    label ||= (await readLabel($, e.cwd)) || basename(e.cwd)
    await update($, isHidden, () => false) // hidden until the next spoken line
    await update($, line, () => spoken.text)
    await update($, level, () => null)
    await log($, 'parley', spoken.text)

    // Ohne Stop-Hook: post the turn and end it now — the session takes input again, the reply
    // comes as a prompt (presence). An older app, -p, or a refused post: the hook as before.
    watcher?.cancel()
    watcher = null
    await update($, awaiting, () => null) // an older posted turn is moot: the app drops it too
    const parts = turnParts(e.last_assistant_message ?? '', spoken)
    if (parts.speak && (await hostCarries($))) {
      const sid = e.session_id || (await $.session.id())
      const cwd = home || e.cwd
      const turn = `${sid}:${await $.clock.now()}`
      const body = JSON.stringify({
        event: 'turn', session_id: sid, cwd, project: basename(cwd),
        tmux_pane: (await $.env.get('TMUX_PANE').catch(() => undefined)) ?? '',
        speak: parts.speak, label: await readLabel($, cwd), listen: spoken.listen,
        ...(parts.replies.length ? { replies: parts.replies } : {}), ...(parts.slides.length ? { slides: parts.slides } : {}),
        ...(spoken.to ? { to: spoken.to } : {}), async: true, turn_id: turn,
      })
      const res = await $.http.fetch(`${APP}/turn`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body }).catch(() => null)
      let queued = false
      try { queued = !!res?.ok && (JSON.parse(res.text) as { queued?: boolean }).queued === true } catch {}
      if (queued) {
        await update($, awaiting, () => turn)
        await update($, phase, () => 'queued')
        watch($, sid)
        return {}
      }
    }
    await update($, phase, () => 'speaking')

    // Live phase + levels from the app's GET /status while it voices this turn. An older
    // app without /status: fall back to guessing the switch to listening from word count.
    const ms = 1200 + spoken.text.split(/\s+/).length * 380
    const guess = spoken.listen
      ? $.clock.after(ms, () => void update($, phase, p => (p === 'speaking' ? 'listening' : p)))
      : null
    let busy = false
    const ticker = $.clock.every(100, () => {
      if (busy) return
      busy = true
      void poll($, e.session_id)
        .then(live => { if (live) guess?.cancel() })
        .catch(() => {})
        .finally(() => { busy = false })
    })

    const res = await next(e).finally(() => { ticker.cancel(); guess?.cancel() })
    await update($, level, () => null)

    if (res.block) {
      await update($, isWorking, () => true) // the spoken reply starts the next turn
      await update($, phase, () => 'heard')
      await log($, 'you', res.block)
    } else {
      await update($, phase, () => 'parked') // done: the session is parked, not just "ready"
    }
    return res
  }).catch(($, e, next) => next(e)) // replay-safe: once called, next(e) hands back its result, the hook doesn't run twice

  // Esc or an API error ends the turn without a Stop hook: not working any more.
  on('turn.complete', async ($, e, next) => {
    if (!e.agentId && (e.isAborted || e.reason === 'error')) await update($, isWorking, () => false)
    return next(e)
  }).catch(($, e, next) => next(e))

  on('turn.start', async ($, e, next) => {
    await update($, isWorking, () => true)
    await arm($)
    return next(e)
  }).catch(($, e, next) => next(e))

  on('prompt.submit', async ($, e, next) => {
    await update($, isWorking, () => true)
    // Sir typed (or wrote from his phone) before the voice reply came: that turn is moot.
    const turn = await read($, awaiting)
    const kind = e.origin?.kind
    if (turn && (kind === 'composer' || kind === 'bridge')) {
      await $.http.fetch(`${APP}/turn/cancel`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ session_id: turn.slice(0, turn.lastIndexOf(':')), turn_id: turn }),
      }).catch(() => null)
      await settle($, 'idle')
    }
    // Our own delivery keeps "eingespeist" up; anything else starts afresh.
    await update($, phase, p => (p === 'parked' || (p === 'heard' && kind !== 'plugin') ? 'idle' : p))
    await arm($)
    return next(e)
  }).catch(($, e, next) => next(e))

  // The session ends (exit, /clear, …): the app drops its queued turn and deliveries.
  on('session.end', async ($, e, next) => {
    if ((await read($, phase)) !== 'off') {
      await update($, awaiting, () => null)
      await $.http.fetch(`${APP}/close`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ session_id: e.sessionId }),
      }).catch(() => null)
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const p = await read($, phase)
    if (e.props.hasSurvey || p === 'off' || (await read($, isHidden))) return next(e)

    const els = $.ui.resolve(e)
    const { Box, Text, Button } = els
    // Only the terminal reads the live level (glyph wave, ●/○): on the desktop that read would
    // redraw the band ten times a second for nothing.
    const term = e.surface === 'terminal' || !('Svg' in els) // the terminal hands out Svg as an empty fragment
    const lv = term ? await read($, level) : null
    const said = await read($, line)
    const working = await read($, isWorking)
    const last = (await read($, history)).at(-1)
    const width = Math.max(20, e.props.bodyColumns - 2)
    const clip = (s: string, n: number) => (s.length > n ? s.slice(0, n - 1) + '…' : s)

    // No live data (older app without /status): a steady wave at a plausible height.
    const vol = lv ?? (p === 'speaking' ? 0.5 : 0.2)
    let viz = null
    if (p === 'speaking' || p === 'listening') {
      if (!term && 'Svg' in els) {
        const { Svg } = els
        const svg = waveSvg(p, COLOR[p])
        viz = <Svg key="wave" source={svg} alt={p === 'speaking' ? 'Parley spricht' : 'Parley hört zu'} width={WAVE.width} height={WAVE.height} isInteractive />
      } else {
        viz = <Text color={p === 'speaking' ? 'claude' : 'error'}>{wave((await read($, tick)) * 0.35, 24, vol)}</Text>
      }
    }
    const chip =
      p === 'speaking' ? <Text color="claude" bold>🔊 spricht</Text>
      : p === 'listening' ? <Text color="error" bold>{term && lv !== null && lv <= 0.35 ? '○' : '●'} hört zu</Text>
      : p === 'transcribing' ? <Text color="warning" bold>✎ transkribiert…</Text>
      : p === 'queued' ? <Text color="warning">⧗ wartet, anderes Projekt spricht</Text>
      : p === 'heard' ? <Text color="success" bold>✓ eingespeist</Text>
      : p === 'parked' || !working ? <Text color="warning" bold>⏸ geparkt</Text>
      : <Text dimColor>◐ arbeitet</Text>

    return (
      <Box flexDirection="column" borderStyle="round" borderColor={p === 'listening' ? 'error' : 'claude'} paddingX={1}>
        <Box flexDirection="row" justifyContent="space-between">
          <Box flexDirection="row" gap={1}>
            <Text color="claude" bold>◆ PARLEY</Text>
            {label ? <Text dimColor>· {label}</Text> : null}
            <Text dimColor>·</Text>
            {chip}
            {viz}
          </Box>
          <Box flexDirection="row" gap={1}>
            <Button key="log" plain label="Sessions" onPress={() => void $.ui.open({ id: PANE, title: 'Parley' })} />
            <Button key="hide" plain label="×" onPress={() => update($, isHidden, () => true)} />
          </Box>
        </Box>
        {said ? <Text italic dimColor={p !== 'speaking'}>„{clip(said, width - 4)}“</Text> : null}
        {p === 'heard' && last?.who === 'you' ? <Text color="success">Du: {clip(last.text, width - 6)}</Text> : null}
      </Box>
    )
  })

  // Countdown rings: the fraction left when a wait was first drawn, per session + wait.
  const drawnFrom = new Map<string, number>()

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const els = $.ui.resolve(e)
    const { Box, Text, Button } = els
    const list = await read($, history)
    const all = await read($, overview)
    const at = (await read($, seen)) || (await $.clock.now())
    const day = await read($, today)
    const open = await read($, expanded)
    const hhmm = (at: number) => new Date(at).toTimeString().slice(0, 5)

    const resume = (id: string) => void $.http.fetch(`${APP}/resume`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id }),
    }).catch(() => null)
    const toggle = (id: string) => update($, expanded, ids => (ids.includes(id) ? ids.filter(x => x !== id) : [...ids, id]))

    // Design C: ring, name, "state · time" up top; details (two-column figures, last line,
    // background tasks) behind a chevron; "Fortsetzen" as the tile's one action.
    const tile = (s: Sess) => {
      const st = STATE[s.state], off = s.state === 'stopped', mine = s.id === selfId, isOpen = open.includes(s.id)
      const host = !mine && s.host && e.surface !== 'terminal' ? s.host : null // a desktop session: the tile opens it
      let ring = <Text color={st.tone} bold>{st.glyph}</Text>
      if ('Svg' in els && e.surface !== 'terminal') { // the terminal hands out Svg as an empty fragment
        const { Svg } = els
        const key = `${s.id}:${s.until}`
        if (s.until && !drawnFrom.has(key)) drawnFrom.set(key, Math.max(0, Math.min(1, (s.until - at) / (s.until - s.since || 1))))
        ring = <Svg key={`ring-${s.id}`} source={ringSvg(s, drawnFrom.get(key) ?? 1, at)} alt={st.label} width={32} height={32} isInteractive />
      }
      const grid = facts(s, at)
      const pairs: [string, string][][] = []
      for (let i = 0; i < grid.length; i += 2) pairs.push(grid.slice(i, i + 2))
      return (
        <Box key={s.id} flexDirection="column" width="50%" flexShrink={1} minWidth={0} overflow="hidden" paddingX={1}
          borderStyle="round" borderColor={s.voice ? 'claude' : 'subtle'}
          backgroundColor={s.voice && e.surface !== 'terminal' ? 'rgba(217,119,87,0.10)' : undefined}>
          <Box flexDirection="row" alignItems="center" gap={1}>
            {ring}
            <Box flexDirection="column" flexGrow={1} flexShrink={1} minWidth={0}>
              <Text bold dimColor={off} wrap="truncate-end">
                {s.label || s.project}{mine ? <Text dimColor> · hier</Text> : null}
              </Text>
              <Text wrap="truncate-end">
                <Text color={off ? undefined : st.tone} dimColor={off}>{bgLabel(s) ?? st.label}</Text>
                <Text dimColor> · {timer(s, at)}</Text>
              </Text>
            </Box>
            {s.stats ? <Button key={`info-${s.id}`} plain dimColor label={isOpen ? '▴' : '▾'} onPress={() => toggle(s.id)} /> : null}
            {host ? <Button key={`open-${s.id}`} label="↗" onPress={() => openSession($, host)} /> : null}
          </Box>
          {isOpen ? (
            <Box flexDirection="column" marginTop={1}>
              {pairs.map((row, r) => (
                <Box key={`f${r}`} flexDirection="row">
                  {row.map(([k, v]) => (
                    <Box key={k} width="50%" minWidth={0}>
                      <Text wrap="truncate-end"><Text dimColor>{k} </Text>{v}</Text>
                    </Box>
                  ))}
                </Box>
              ))}
              {(s.tasks ?? []).map((t, i) => <Text key={`t${i}`} color="permission" wrap="truncate-end">◍ {t.description}</Text>)}
              {s.stats?.lastLine ? <Text italic dimColor wrap="truncate-end">„{s.stats.lastLine}“</Text> : null}
            </Box>
          ) : null}
          {s.resumable ?? s.state === 'parked' ? ( // this session too: its reply comes back here as a prompt
            <Box flexDirection="row" marginTop={1}>
              <Button key={`resume-${s.id}`} label="Fortsetzen" onPress={() => resume(s.id)} />
            </Box>
          ) : null}
        </Box>
      )
    }
    const sessions = all ?? []
    const rows: Sess[][] = []
    for (let i = 0; i < sessions.length; i += 2) rows.push(sessions.slice(i, i + 2))
    const alive = sessions.filter(s => s.state !== 'stopped').length

    // Two fixed halves of the body: sessions on top, the history below, pinned to its newest
    // line (flex-end clips the oldest). Both scroll on their own (see ui.scroll below);
    // without a known body height (inline pane) the tree just stacks.
    const body = e.props.scroll?.bodyRows ?? 0
    const top = body >= 12 ? Math.floor(body / 2) : undefined
    const sSkip = Math.min(Math.floor(await read($, sessSkip)), Math.max(0, rows.length - 1))
    const hSkip = Math.min(Math.floor(await read($, histSkip)), Math.max(0, list.length - 1))
    const shown = list.slice(Math.max(0, list.length - hSkip - 60), list.length - hSkip)

    return (
      <Box flexDirection="column" height={top ? body : undefined}>
        <Box flexDirection="column" gap={1} height={top} flexShrink={0} overflow="hidden">
          <Text bold dimColor>SESSIONS · {alive} aktiv{sSkip ? <Text> · ↑ {sSkip * 2} weitere</Text> : null}</Text>
          {day ? (
            <Text wrap="truncate-end">
              <Text dimColor>Heute  </Text>
              {todayParts(day).map(([v, k], i) => (
                <Text key={`h${i}`}>{i ? <Text dimColor>  ·  </Text> : null}<Text bold>{v}</Text><Text dimColor> {k}</Text></Text>
              ))}
            </Text>
          ) : null}
          {all === null ? <Text dimColor>Parley-App nicht erreichbar.</Text> : null}
          {rows.slice(sSkip).map((pair, r) => (
            <Box key={`row${r + sSkip}`} flexDirection="row" gap={1} flexShrink={0}>
              {pair.map(tile)}
              {pair.length === 1 ? <Box key="pad" width="50%" flexShrink={1} /> : null}
            </Box>
          ))}
        </Box>
        <Box flexDirection="column" height={top ? body - top : undefined} flexShrink={0} paddingTop={1}>
          <Box flexDirection="row" justifyContent="space-between">
            <Text bold dimColor>VERLAUF{label ? ` · ${label}` : ''}</Text>
            <Box flexDirection="row" gap={1}>
              {hSkip ? <Button key="latest" plain dimColor label="↓ Neueste" onPress={() => update($, histSkip, () => 0)} /> : null}
              <Button key="older" plain dimColor label="▲" onPress={() => update($, histSkip, v => Math.min(list.length - 1, Math.floor(v) + 1))} />
              <Button key="newer" plain dimColor label="▼" onPress={() => update($, histSkip, v => Math.max(0, Math.floor(v) - 1))} />
            </Box>
          </Box>
          <Box flexDirection="column" flexGrow={1} overflow="hidden" justifyContent="flex-end" gap={1} position="relative">
            {top && e.surface !== 'terminal' && 'Svg' in els
              ? <Box key="fade" position="absolute" top={0} left={0} right={0}><els.Svg key="fade-svg" source={FADE} alt="" width={1600} height={48} /></Box>
              : null}
            {list.length === 0 ? <Text dimColor>Noch kein Gespräch in dieser Session.</Text> : null}
            {shown.map((l, i) => (
              <Box key={`l${list.length - hSkip - shown.length + i}`} flexDirection="column" flexShrink={0}>
                <Text bold color={l.who === 'parley' ? 'claude' : 'success'}>
                  {l.who === 'parley' ? '◆ Parley' : '● Du'} <Text dimColor>{hhmm(l.at)}</Text>
                </Text>
                <Text>{l.text}</Text>
              </Box>
            ))}
          </Box>
        </Box>
      </Box>
    )
  })

  // The pane scrolls its two halves itself: a wheel over the top half moves the session rows,
  // anywhere else (and the scroll keys) the history, counted from its newest message.
  on('ui.scroll', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const sessRows = Math.ceil(((await read($, overview)) ?? []).length / 2)
    const overflows = 3 + sessRows * 5 > Math.floor(e.bodyRows / 2)
    const msgs = (await read($, history)).length
    const next = scrollPane(e.by, e.bodyRows, e.pointer?.row, {
      sess: await read($, sessSkip), sessMax: overflows ? sessRows - 1 : 0, hist: await read($, histSkip), histMax: msgs - 1,
    })
    await update($, sessSkip, () => next.sess)
    await update($, histSkip, () => next.hist)
    return {}
  }).catch(($, e, next) => next(e)) // on a failure the engine scrolls the body as before
}
