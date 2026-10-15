import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Line, Phase } from '../types'

const phase = atom({ plugin: 'parley-ui', key: 'phase' } as const, 'off' as Phase)
const line = atom({ plugin: 'parley-ui', key: 'line' } as const, '')
const history = atom({ plugin: 'parley-ui', key: 'history' } as const, [] as Line[])
const tick = atom({ plugin: 'parley-ui', key: 'tick' } as const, 0)
const isHidden = atom({ plugin: 'parley-ui', key: 'isHidden' } as const, false)
const levels = atom({ plugin: 'parley-ui', key: 'levels' } as const, null as number[] | null)

const PANE = 'parley'
const BARS = '▁▂▃▄▅▆▇█'
const STATUS = 'http://127.0.0.1:8787/status' // ponytail: default port; read PARLEY_PORT when someone moves it
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

export function wave(t: number, n: number, amp: number): string {
  let s = ''
  for (let i = 0; i < n; i++) {
    const v = (Math.sin(t * 0.7 + i * 0.9) * Math.cos(t * 0.31 + i * 0.4) + 1) / 2
    s += BARS[Math.min(7, Math.floor(v * amp * 8))]
  }
  return s
}

// Real levels from the app → one bar glyph each (newest on the right).
export function meter(values: readonly number[], n: number): string {
  return values.slice(-n).map(v => BARS[Math.max(0, Math.min(7, Math.round(v * 7)))]).join('')
}

const isWaiting = (p: Phase) => p === 'queued' || LIVE.includes(p)

type Status = { phase: string; session: string; levels: number[] }

async function poll($: EngineInterface, session: string): Promise<boolean> {
  const res = await $.http.fetch(STATUS).catch(() => null)
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
    await update($, levels, () => st.levels)
  }
  return true
}

async function log($: EngineInterface, who: Line["who"], text: string) {
  const at = await $.clock.now()
  await update($, history, list => [...list, { who, text, at }].slice(-100))
}

export const register: Register = on => {
  let label = ''

  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'parley', description: 'Parley: Gesprächsverlauf als Pane öffnen' })
    $.clock.every(140, () => {
      void Promise.all([read($, phase), read($, levels)]).then(([p, lv]) => {
        if (lv === null && (p === 'speaking' || p === 'listening')) void update($, tick, t => t + 1)
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

    if (!label) {
      const cfg = await $.fs.read(`${e.cwd}/.parley.json`).catch(() => '')
      try { label = JSON.parse(String(cfg)).name ?? '' } catch { label = '' }
      label ||= e.cwd.split(/[\\/]/).pop() ?? '' // Windows cwd uses backslashes
    }
    await update($, isHidden, () => false) // hidden until the next spoken line
    await update($, line, () => spoken.text)
    await update($, phase, () => 'speaking')
    await update($, levels, () => null)
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
    await update($, levels, () => null)

    if (res.block) {
      await update($, phase, () => 'heard')
      await log($, 'you', res.block)
    } else {
      await update($, phase, () => (spoken.listen ? 'parked' : 'idle'))
    }
    return res
  }).catch(($, e, next) => next(e))

  on('prompt.submit', async ($, e, next) => {
    await update($, phase, p => (p === 'heard' || p === 'parked' ? 'idle' : p))
    return next(e)
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const p = await read($, phase)
    if (e.props.hasSurvey || p === 'off' || (await read($, isHidden))) return next(e)

    const { Box, Text, Button } = $.ui.resolve(e)
    const t = await read($, tick)
    const lv = await read($, levels)
    const said = await read($, line)
    const last = (await read($, history)).at(-1)
    const width = Math.max(20, e.props.bodyColumns - 2)
    const clip = (s: string, n: number) => (s.length > n ? s.slice(0, n - 1) + '…' : s)

    const bars = (fake: number, amp: number) => (lv ? meter(lv, 24) : wave(fake, 24, amp))
    const peak = lv ? Math.max(...lv.slice(-4)) : 0
    const chip =
      p === 'speaking' ? <Text color="claude" bold>🔊 spricht  {bars(t, 1)}</Text>
      : p === 'listening' ? <Text color="error" bold>{lv ? (peak > 0.35 ? '●' : '○') : t % 6 < 3 ? '●' : '○'} hört zu  {bars(t * 2, 0.45)}</Text>
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
          </Box>
          <Box flexDirection="row" gap={1}>
            <Button key="log" plain label="Verlauf" onPress={() => void $.ui.open({ id: PANE, title: 'Parley' })} />
            <Button key="hide" plain label="×" onPress={() => update($, isHidden, () => true)} />
          </Box>
        </Box>
        {said ? <Text italic dimColor={p !== 'speaking'}>„{clip(said, width - 4)}“</Text> : null}
        {p === 'heard' && last?.who === 'you' ? <Text color="success">Du: {clip(last.text, width - 6)}</Text> : null}
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const list = await read($, history)
    const room = Math.max(2, (e.viewport?.rows ?? 24) - 4)
    const hhmm = (at: number) => new Date(at).toTimeString().slice(0, 5)

    return (
      <Box flexDirection="column" gap={1}>
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
