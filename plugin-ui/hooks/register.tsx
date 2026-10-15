import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Line, Phase, Sess, SessState } from '../types'

const phase = atom({ plugin: 'parley-ui', key: 'phase' } as const, 'off' as Phase)
const line = atom({ plugin: 'parley-ui', key: 'line' } as const, '')
const history = atom({ plugin: 'parley-ui', key: 'history' } as const, [] as Line[])
const tick = atom({ plugin: 'parley-ui', key: 'tick' } as const, 0)
const isHidden = atom({ plugin: 'parley-ui', key: 'isHidden' } as const, false)
const level = atom({ plugin: 'parley-ui', key: 'level' } as const, null as number | null)
const overview = atom({ plugin: 'parley-ui', key: 'overview' } as const, null as Sess[] | null)
const seen = atom({ plugin: 'parley-ui', key: 'seen' } as const, 0)
const isWorking = atom({ plugin: 'parley-ui', key: 'isWorking' } as const, false)

const PANE = 'parley'
const BARS = '▁▂▃▄▅▆▇█'
const APP = 'http://127.0.0.1:8787' // ponytail: default port; read PARLEY_PORT when someone moves it
const LIVE: readonly Phase[] = ['speaking', 'listening', 'transcribing']

// Same rule as plugin/scripts/stop-hook.sh: the LAST opening tag wins, its close optional.
export function parseSpeak(msg: string): { text: string; listen: boolean } | null {
  const end = msg.lastIndexOf('<speak-end>')
  const speak = msg.lastIndexOf('<speak>')
  if (end < 0 && speak < 0) return null
  const listen = speak > end
  const open = listen ? '<speak>' : '<speak-end>'
  const rest = msg.slice((listen ? speak : end) + open.length)
  const close = rest.indexOf(listen ? '</speak>' : '</speak-end>')
  if (!listen && close < 0) return null
  const text = (close < 0 ? rest : rest.slice(0, close)).trim()
  return text ? { text, listen } : null
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

// Desktop: rounded bars as SVG. The wave runs as SMIL in the surface (smooth at its frame
// rate, phase kept across redraws by a clock-based negative `begin`); a redraw only eases
// the height from the last drawn volume to the new one.
const PERIOD = 2.4 // s per wave cycle; the overlay's ~1.2 s halved for a calmer inline band
export const WAVE = { width: 168, height: 28 }
export function waveSvg(vol: number, from: number, color: string, nowMs: number): string {
  const n = 28, K = 24, { width: w, height: h } = WAVE
  const slot = w / n, sw = slot * 0.5, begin = -((nowMs / 1000) % PERIOD)
  let bars = ''
  for (let i = 0; i < n; i++) {
    const ys = Array.from({ length: K + 1 }, (_, k) => ((bar(i, n, (k / K) * 2 * Math.PI) * (h - sw)) / 2).toFixed(1))
    const anim = (attr: string, sign: string) =>
      `<animate attributeName="${attr}" values="${ys.map(y => sign + y).join(';')}" dur="${PERIOD}s" begin="${begin.toFixed(2)}s" repeatCount="indefinite"/>`
    const x = (slot * (i + 0.5)).toFixed(1)
    bars += `<line x1="${x}" x2="${x}" y1="-${ys[0]}" y2="${ys[0]}">${anim('y1', '-')}${anim('y2', '')}</line>`
  }
  const g = gain(vol).toFixed(3)
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">`
    + `<style>line{vector-effect:non-scaling-stroke}</style>`
    + `<g transform="translate(0 ${h / 2})"><g transform="scale(1 ${g})">`
    + `<animateTransform attributeName="transform" type="scale" from="1 ${gain(from).toFixed(3)}" to="1 ${g}" dur="0.2s" fill="freeze"/>`
    + `<g stroke="${color}" stroke-opacity="0.9" stroke-width="${sw}" stroke-linecap="round">${bars}</g></g></g></svg>`
}

const isWaiting = (p: Phase) => p === 'queued' || LIVE.includes(p)

type Status = { phase: string; session: string; levels: number[] }
const COLOR = { speaking: '#D97757', listening: '#E5484D' } // Claude orange; red as the overlay

async function poll($: EngineInterface, session: string): Promise<boolean> {
  const res = await $.http.fetch(`${APP}/status`).catch(() => null)
  if (!res?.ok) return false
  const st = JSON.parse(res.text) as Status
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
  waiting: { label: 'pausiert', tone: 'warning', hex: '#D9A43B', glyph: '◔' },
  parked: { label: 'geparkt', tone: 'inactive', hex: '#8B8A85', glyph: '⏸' },
  idle: { label: 'bereit', tone: 'inactive', hex: '#8B8A85', glyph: '○' },
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
    : s.state === 'waiting' && s.until
      ? arc(from, `<animate attributeName="stroke-dasharray" from="${(c * from).toFixed(2)} ${c}" to="0 ${c}" dur="${Math.max(0.1, (s.until - at) / 1000).toFixed(1)}s" fill="freeze"/>`)
    : s.state === 'parked' ? `<rect x="14" y="13" width="4" height="14" rx="1.5" fill="${col}"/><rect x="22" y="13" width="4" height="14" rx="1.5" fill="${col}"/>`
    : s.state === 'idle' ? `<circle cx="20" cy="20" r="3.5" fill="${col}"/>`
    : `<rect x="15" y="15" width="10" height="10" rx="2" fill="${col}"/>`
  return `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" viewBox="0 0 40 40">`
    + `<circle cx="20" cy="20" r="${r}" fill="none" stroke="${col}" stroke-opacity="0.18" stroke-width="3"/>${inner}</svg>`
}

async function readLabel($: EngineInterface, cwd: string): Promise<string> {
  const cfg = await $.fs.read(`${cwd}/.parley.json`).catch(() => '')
  try { return String(JSON.parse(String(cfg)).name ?? '') } catch { return '' }
}
const basename = (cwd: string) => cwd.split(/[\\/]/).pop() ?? '' // Windows cwd uses backslashes

async function log($: EngineInterface, who: Line["who"], text: string) {
  const at = await $.clock.now()
  await update($, history, list => [...list, { who, text, at }].slice(-100))
}

export const register: Register = on => {
  let label = ''
  let shown = 0 // volume the desktop wave last drew; its next redraw eases from here

  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'parley', description: 'Parley: Sessions und Gesprächsverlauf als Pane öffnen' })
    const sid = await $.session.id()
    // Only once this session talks through Parley (phase leaves 'off'): report to the app
    // every 5 s so it knows we are alive and working, and fetch every session's state each
    // second for the overview (its timers count in seconds).
    let n = 0
    $.clock.every(1000, () => {
      void read($, phase).then(async p => {
        if (p === 'off') return
        if (n++ % 5 === 0) {
          label ||= (await readLabel($, e.cwd)) || basename(e.cwd)
          const body = JSON.stringify({
            session_id: sid, label, project: basename(e.cwd), cwd: e.cwd,
            state: (await read($, isWorking)) ? 'working' : 'idle',
          })
          void $.http.fetch(`${APP}/presence`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body }).catch(() => null)
        }
        const res = await $.http.fetch(`${APP}/sessions`).catch(() => null)
        const list = res?.ok ? (JSON.parse(res.text) as { sessions: Sess[] }).sessions : null
        await update($, overview, () => list)
        const t = await $.clock.now()
        await update($, seen, () => t)
      }).catch(() => {})
    })
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
    const spoken = parseSpeak(e.last_assistant_message ?? '')
    if (!spoken) return next(e)

    label ||= (await readLabel($, e.cwd)) || basename(e.cwd)
    await update($, isWorking, () => false)
    await update($, isHidden, () => false) // hidden until the next spoken line
    await update($, line, () => spoken.text)
    await update($, phase, () => 'speaking')
    await update($, level, () => null)
    await log($, 'parley', spoken.text)

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
      await update($, phase, () => (spoken.listen ? 'parked' : 'idle'))
    }
    return res
  }).catch(($, e, next) => next(e))

  on('prompt.submit', async ($, e, next) => {
    await update($, isWorking, () => true)
    await update($, phase, p => (p === 'heard' || p === 'parked' ? 'idle' : p))
    return next(e)
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const p = await read($, phase)
    if (e.props.hasSurvey || p === 'off' || (await read($, isHidden))) return next(e)

    const els = $.ui.resolve(e)
    const { Box, Text, Button } = els
    const lv = await read($, level)
    const said = await read($, line)
    const last = (await read($, history)).at(-1)
    const width = Math.max(20, e.props.bodyColumns - 2)
    const clip = (s: string, n: number) => (s.length > n ? s.slice(0, n - 1) + '…' : s)

    // No live data (older app without /status): a steady wave at a plausible height.
    const vol = lv ?? (p === 'speaking' ? 0.5 : 0.2)
    let viz = null
    if (p === 'speaking' || p === 'listening') {
      if ('Svg' in els && e.surface !== 'terminal') { // the terminal hands out Svg as an empty fragment
        const { Svg } = els
        const svg = waveSvg(vol, shown, COLOR[p], await $.clock.now())
        shown = vol
        viz = <Svg key="wave" source={svg} alt={p === 'speaking' ? 'Parley spricht' : 'Parley hört zu'} width={WAVE.width} height={WAVE.height} isInteractive />
      } else {
        viz = <Text color={p === 'speaking' ? 'claude' : 'error'}>{wave((await read($, tick)) * 0.35, 24, vol)}</Text>
      }
    }
    const chip =
      p === 'speaking' ? <Text color="claude" bold>🔊 spricht</Text>
      : p === 'listening' ? <Text color="error" bold>{lv !== null && lv > 0.35 ? '●' : '○'} hört zu</Text>
      : p === 'transcribing' ? <Text color="warning" bold>✎ transkribiert…</Text>
      : p === 'queued' ? <Text color="warning">⧗ wartet, anderes Projekt spricht</Text>
      : p === 'heard' ? <Text color="success" bold>✓ eingespeist</Text>
      : p === 'parked' ? <Text color="warning" bold>⏸ geparkt</Text>
      : <Text dimColor>○ bereit</Text>

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
    const hhmm = (at: number) => new Date(at).toTimeString().slice(0, 5)

    const tile = (s: Sess) => {
      const st = STATE[s.state], off = s.state === 'stopped'
      let ring = <Text color={st.tone} bold>{st.glyph}</Text>
      if ('Svg' in els && e.surface !== 'terminal') { // the terminal hands out Svg as an empty fragment
        const { Svg } = els
        const key = `${s.id}:${s.until}`
        if (s.until && !drawnFrom.has(key)) drawnFrom.set(key, Math.max(0, Math.min(1, (s.until - at) / (s.until - s.since || 1))))
        ring = <Svg key={`ring-${s.id}`} source={ringSvg(s, drawnFrom.get(key) ?? 1, at)} alt={st.label} width={40} height={40} isInteractive />
      }
      return (
        <Box key={s.id} flexDirection="row" alignItems="center" gap={1} width="50%" flexShrink={1} paddingX={1}
          borderStyle="round" borderColor={s.voice ? 'claude' : 'subtle'}
          backgroundColor={s.voice && e.surface !== 'terminal' ? 'rgba(217,119,87,0.10)' : undefined}>
          {ring}
          <Box flexDirection="column" flexGrow={1}>
            <Text bold dimColor={off} wrap="truncate-end">{s.label || s.project}</Text>
            <Text color={off ? undefined : st.tone} dimColor={off}>{st.label}</Text>
            <Text dimColor>{timer(s, at)}</Text>
            {s.state === 'parked'
              ? <Button key={`resume-${s.id}`} label="Fortsetzen" onPress={() => void $.http.fetch(`${APP}/resume`, {
                  method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id: s.id }),
                }).catch(() => null)} />
              : null}
          </Box>
        </Box>
      )
    }
    const sessions = all ?? []
    const rows: Sess[][] = []
    for (let i = 0; i < sessions.length; i += 2) rows.push(sessions.slice(i, i + 2))
    const alive = sessions.filter(s => s.state !== 'stopped').length
    const room = Math.max(2, (e.viewport?.rows ?? 24) - 6 - rows.length * 5)

    return (
      <Box flexDirection="column" gap={1}>
        <Text bold dimColor>SESSIONS · {alive} aktiv</Text>
        {all === null ? <Text dimColor>Parley-App nicht erreichbar.</Text> : null}
        {rows.map((pair, r) => (
          <Box key={`row${r}`} flexDirection="row" gap={1}>
            {pair.map(tile)}
            {pair.length === 1 ? <Box key="pad" width="50%" flexShrink={1} /> : null}
          </Box>
        ))}
        <Text bold dimColor>VERLAUF{label ? ` · ${label}` : ''}</Text>
        {list.length === 0 ? <Text dimColor>Noch kein Gespräch in dieser Session.</Text> : null}
        {list.slice(-room).map((l, i) => (
          <Box key={`l${i}`} flexDirection="column">
            <Text bold color={l.who === 'parley' ? 'claude' : 'success'}>
              {l.who === 'parley' ? '◆ Parley' : '● Du'} <Text dimColor>{hhmm(l.at)}</Text>
            </Text>
            <Text>{l.text}</Text>
          </Box>
        ))}
      </Box>
    )
  })
}
