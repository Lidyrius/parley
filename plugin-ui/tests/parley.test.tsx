import { expect, mock, test } from 'claude-code/testing'

import { bgLabel, ease, facts, parseSpeak, ringSvg, scrollPane, timer, todayParts, wave, waveSvg } from '../hooks/register'

const BAND = {
  plugin: 'parley-ui',
  component: 'AbovePrompt',
  props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 80 } as never, // scroll + view: engine-owned, unread here
} as const

test('parseSpeak takes the last tag, like stop-hook.sh', async () => {
  expect(parseSpeak('no tag')).toBe(null)
  expect(parseSpeak('x `<speak-end>` y\n<speak>Hallo Sir.</speak>')).toEqual({ text: 'Hallo Sir.', listen: true })
  expect(parseSpeak('<speak>a</speak>\n<speak-end>Fertig.</speak-end>')).toEqual({ text: 'Fertig.', listen: false })
  expect(parseSpeak('<speak>offen ohne close')).toEqual({ text: 'offen ohne close', listen: true })
  expect(wave(3, 14, 1).length).toBe(14)
})

test('Stop shows the spoken line, then the reply, on terminal and desktop', async ($, on) => {
  mock.clock(on)
  on('classic.Stop', async () => ({ block: 'Ja, bau den Prototyp.' }))
  on('ui.render', async ($, e) => { const { Text } = $.ui.resolve(e); return <Text>engine</Text> })

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...BAND, surface })
    await $.classic.Stop({
      stop_hook_active: false,
      last_assistant_message: 'Text.\n<speak>Recherche fertig, Sir.</speak>',
      cwd: '/tmp/parley-demo',
    })
    expect(await ui.find({ type: 'Text', text: /Recherche fertig, Sir/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /eingespeist/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Du: Ja, bau den Prototyp/ })).toBeDefined()

    await ui.press({ key: 'hide' })
    expect(await ui.find({ type: 'Text', text: /PARLEY/ })).toBeUndefined()
    await ui.unmount()
  }
})

test('/parley pane lists the conversation on terminal and desktop', async ($, on) => {
  mock.clock(on)
  on('classic.Stop', async () => ({ block: 'Weiter.' }))
  on('ui.render', async ($, e) => { const { Text } = $.ui.resolve(e); return <Text>engine</Text> })
  await $.classic.Stop({ stop_hook_active: false, last_assistant_message: '<speak>Erledigt, Sir.</speak>' })

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ plugin: 'parley-ui', surface, component: 'Pane', requestId: 'parley', props: {} as never })
    expect(await ui.find({ type: 'Text', text: 'Erledigt, Sir.' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: 'Weiter.' })).toBeDefined()
    await ui.unmount()
  }
})

test('ease rises fast, falls slowly, and settles', async () => {
  expect(ease(0, 1)).toBe(0.72)
  expect(ease(1, 0)).toBe(0.76)
  let v = 1
  for (let i = 0; i < 40; i++) v = ease(v, 0)
  expect(v).toBeLessThan(0.05)
  const svg = waveSvg('speaking', '#D97757')
  expect(svg.match(/<line /g)?.length).toBe(28)
  expect(svg).toBe(waveSvg('speaking', '#D97757')) // same source every redraw: the desktop never reloads it
  expect(svg).not.toBe(waveSvg('listening', '#E5484D'))
})

test('live /status drives phase; desktop draws the SVG wave, terminal the glyph wave', async ($, on) => {
  const clock = mock.clock(on)
  let release = () => {}
  const gate = new Promise<void>(r => { release = r })
  on('classic.Stop', async () => { await gate; return { block: 'Klingt gut.' } })
  on('http.fetch', async () => ({ value: {
    status: 200, ok: true, headers: {},
    text: JSON.stringify({ phase: 'listening', session: 's1', levels: [0, 0.5, 1] }),
  } }))
  on('ui.render', async ($, e) => { const { Text } = $.ui.resolve(e); return <Text>engine</Text> })

  const term = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const desk = await $.ui.mount({ ...BAND, surface: 'desktop' })
  const stop = $.classic.Stop({ stop_hook_active: false, session_id: 's1', last_assistant_message: '<speak>Frage, Sir?</speak>' })
  await clock.advance(350)
  expect(await term.find({ type: 'Text', text: /● hört zu/ })).toBeDefined()
  expect(await term.find({ type: 'Text', text: /^[▁▂▃▄▅▆▇█]{24}$/ })).toBeDefined()
  expect(await term.find({ type: 'Svg' })).toBeUndefined()
  const first = (await desk.find({ type: 'Svg' })) as { props: { source: string } } | undefined
  expect(first).toBeDefined()
  await clock.advance(500) // more /status polls, new levels
  const later = (await desk.find({ type: 'Svg' })) as { props: { source: string } } | undefined
  expect(later?.props.source).toBe(first?.props.source) // no reload → no flicker

  release()
  await stop
  expect(await desk.find({ type: 'Text', text: /eingespeist/ })).toBeDefined()
  expect(await desk.find({ type: 'Svg' })).toBeUndefined()
  await term.unmount()
  await desk.unmount()
})

test('overview: ring tiles for every Parley session, presence while active, parked ones resume', async ($, on) => {
  const clock = mock.clock(on)
  const now = clock.now()
  const sessions = [
    { id: 'a', label: 'Parley', project: 'vloude', state: 'speaking', since: now - 8000, until: null, voice: true },
    { id: 'b', label: 'Shop', project: 'shop', state: 'working', since: now - 134000, until: null, voice: false },
    { id: 'c', label: 'API', project: 'api', state: 'waiting', since: now - 48000, until: now + 252000, voice: false },
    { id: 'd', label: 'Docs', project: 'docs', state: 'parked', since: now - 720000, until: null, voice: false },
    { id: 'e', label: 'Alt', project: 'alt', state: 'stopped', since: now - 180000, until: null, voice: false },
  ]
  const calls: string[] = []
  on('http.fetch', async ($, e) => {
    calls.push(`${e.init?.method ?? 'GET'} ${e.url.replace(/^.*:8787/, '')} ${e.init?.body ?? ''}`)
    const text = e.url.endsWith('/sessions') ? JSON.stringify({ sessions })
      : e.url.endsWith('/status') ? JSON.stringify({ phase: 'idle', session: 'x', levels: [] }) : '{}'
    return { value: { status: 200, ok: true, headers: {}, text } }
  })
  on('classic.Stop', async () => ({ block: 'Weiter.' }))
  on('ui.render', async ($, e) => { const { Text } = $.ui.resolve(e); return <Text>engine</Text> })

  on('command.register', async () => ({ value: undefined }) as never)
  on('session.id', async () => ({ value: 's1' }))
  on('session.start', async ($, e) => ({ cwd: e.cwd }) as never)
  await $.session.start({ cwd: '/tmp/parley-demo', surface: 'desktop', isInteractive: true } as never)
  await clock.advance(1100)
  expect(calls.filter(c => c.includes('/presence'))).toEqual([]) // silent until voice mode is on

  await $.classic.Stop({ stop_hook_active: false, last_assistant_message: '<speak>Hallo.</speak>', cwd: '/tmp/parley-demo' })
  await clock.advance(1100)
  expect(calls.some(c => c.startsWith('POST /presence') && c.includes('"state":"working"'))).toBe(true)

  const desk = await $.ui.mount({ plugin: 'parley-ui', surface: 'desktop', component: 'Pane', requestId: 'parley', props: {} as never })
  expect(await desk.find({ type: 'Text', text: /SESSIONS · 4 aktiv/ })).toBeDefined()
  expect(await desk.find({ type: 'Text', text: /noch 4:1\d/ })).toBeDefined()
  expect(await desk.find({ type: 'Text', text: 'geparkt' })).toBeDefined()
  expect(await desk.find({ type: 'Svg' })).toBeDefined()
  await desk.press({ key: 'resume-d' })
  expect(calls.some(c => c.startsWith('POST /resume') && c.includes('"id":"d"'))).toBe(true)
  await desk.unmount()

  const term = await $.ui.mount({ plugin: 'parley-ui', surface: 'terminal', component: 'Pane', requestId: 'parley', props: {} as never })
  expect(await term.find({ type: 'Text', text: '⏸' })).toBeDefined()
  expect(await term.find({ type: 'Svg' })).toBeUndefined()
  await term.unmount()
})

test('timer and ring: countdown, elapsed, stopped; ring drains without the clock in it', async () => {
  const s = { id: 'c', label: 'API', project: 'api', state: 'waiting', since: 0, until: 300000, voice: false } as const
  expect(timer(s, 48000)).toBe('noch 4:12')
  expect(timer({ ...s, state: 'working', until: null }, 3723000)).toBe('seit 1:02:03')
  expect(timer({ ...s, state: 'stopped', until: null }, 180000)).toBe('vor 3 min')
  const ring = ringSvg(s, 0.84, 48000)
  expect(ring).toContain('dur="252.0s"')
  expect(ringSvg({ ...s, state: 'working', until: null }, 1, 1000)).toBe(ringSvg({ ...s, state: 'working', until: null }, 1, 9000))
})

test('details + today: stats per tile behind a toggle; idle resumes; the app\'s instruction becomes a prompt', async ($, on) => {
  const clock = mock.clock(on)
  const now = clock.now()
  const stats = { startedAt: now - 8040000, contextPercent: 62.4, costUsd: 3.4, turns: 14, replies: 9, lastLine: 'Tests grün, Sir.' }
  const sessions = [
    { id: 'b', label: 'Shop', project: 'shop', state: 'idle', since: now - 60000, until: null, voice: false, resumable: true, stats },
  ]
  const today = { costUsd: 12.8, turns: 23, spokenSeconds: 1380, rateLimits: [{ kind: 'five_hour', percentUsed: 42, resetsAt: null }] }
  const calls: string[] = []
  const prompts: string[] = []
  let inbox: string | null = null
  on('http.fetch', async ($, e) => {
    calls.push(`${e.init?.method ?? 'GET'} ${e.url.replace(/^.*:8787/, '')} ${e.init?.body ?? ''}`)
    const text = e.url.endsWith('/sessions') ? JSON.stringify({ sessions, today })
      : e.url.endsWith('/presence') && inbox ? JSON.stringify({ instruction: inbox }) : '{}'
    if (e.url.endsWith('/presence')) inbox = null
    return { value: { status: 200, ok: true, headers: {}, text } }
  })
  on('session.usage', async () => ({ value: { startedAt: now - 60000, context: { tokens: 120000, window: 200000, percent: 60 }, rateLimits: [], cost: { usd: 1.5 } } }) as never)
  on('prompt.submit', async ($, e) => { prompts.push(e.text); return { text: e.text } })
  on('command.register', async () => ({ value: undefined }) as never)
  on('session.id', async () => ({ value: 's1' }))
  on('session.start', async ($, e) => ({ cwd: e.cwd }) as never)
  on('classic.Stop', async () => ({}))
  on('ui.render', async ($, e) => { const { Text } = $.ui.resolve(e); return <Text>engine</Text> })

  await $.session.start({ cwd: '/tmp/parley-demo', surface: 'desktop', isInteractive: true } as never)
  await $.classic.Stop({ stop_hook_active: false, last_assistant_message: '<speak-end>Fertig.</speak-end>', cwd: '/tmp/parley-demo' })
  await clock.advance(1100)
  expect(calls.some(c => c.includes('/presence') && c.includes('"contextPercent":60') && c.includes('"costUsd":1.5'))).toBe(true)

  const desk = await $.ui.mount({ plugin: 'parley-ui', surface: 'desktop', component: 'Pane', requestId: 'parley', props: {} as never })
  expect(await desk.find({ type: 'Text', text: /Heute\s+\$12\.80 Kosten\s+·\s+23 Updates\s+·\s+23 min gesprochen\s+·\s+42 % 5-h-Limit/ })).toBeDefined()
  expect(await desk.find({ type: 'Text', text: /Kontext/ })).toBeUndefined()
  await desk.press({ key: 'info-b' })
  expect(await desk.find({ type: 'Text', text: 'Kontext 62 %' })).toBeDefined()
  expect(await desk.find({ type: 'Text', text: 'Laufzeit 2 h 14 min' })).toBeDefined()
  expect(await desk.find({ type: 'Text', text: '„Tests grün, Sir.“' })).toBeDefined()
  await desk.press({ key: 'resume-b' })
  expect(calls.some(c => c.startsWith('POST /resume') && c.includes('"id":"b"'))).toBe(true)
  await desk.unmount()

  inbox = 'Bau den Export noch ein.'
  await clock.advance(2100)
  expect(prompts).toEqual(['Bau den Export noch ein.'])
  await clock.advance(2100)
  expect(prompts.length).toBe(1) // handed out once
})

test('facts and today parts read well', async () => {
  const s = { id: 'x', label: 'X', project: 'x', state: 'idle', since: 0, until: null, voice: false,
    stats: { startedAt: 0, contextPercent: null, costUsd: null, turns: 2, replies: 1, lastLine: null } } as const
  expect(facts(s, 45 * 60000)).toEqual([['Laufzeit', '45 min'], ['Updates', '2 · 1 Antw.']])
  expect(todayParts({ costUsd: 0, turns: 0, spokenSeconds: 0, rateLimits: [{ kind: 'seven_day', percentUsed: 18.4, resetsAt: null }] }))
    .toEqual([['$0.00', 'Kosten'], ['0', 'Updates'], ['0 min', 'gesprochen'], ['18 %', 'Woche']])
})

test('background: a Stop with running background work reports "background"; a new turn is "working" again', async ($, on) => {
  const clock = mock.clock(on)
  const bodies: string[] = []
  on('http.fetch', async ($, e) => {
    if (e.url.endsWith('/presence')) bodies.push(e.init?.body ?? '')
    return { value: { status: 200, ok: true, headers: {}, text: e.url.endsWith('/sessions') ? '{"sessions":[]}' : '{}' } }
  })
  on('session.usage', async () => ({ value: { startedAt: 0, context: { window: 200000 }, rateLimits: [] } }) as never)
  on('command.register', async () => ({ value: undefined }) as never)
  on('session.id', async () => ({ value: 's1' }))
  on('session.start', async ($, e) => ({ cwd: e.cwd }) as never)
  on('classic.Stop', async () => ({}))
  on('turn.start', async ($, e) => ({ turnId: e.turnId }) as never)

  await $.session.start({ cwd: '/tmp/parley-demo', surface: 'desktop', isInteractive: true } as never)
  await $.classic.Stop({
    stop_hook_active: false, last_assistant_message: '<speak-end>Läuft im Hintergrund.</speak-end>', cwd: '/tmp/parley-demo',
    background_tasks: [{ id: 't1', type: 'subagent', status: 'running', description: 'App: session presence' }],
  } as never)
  await clock.advance(1100)
  expect(bodies.at(-1)).toContain('"state":"background"')
  expect(bodies.at(-1)).toContain('"description":"App: session presence"')

  await $.turn.start({ text: '', turnId: 't2' } as never)
  await clock.advance(2100)
  expect(bodies.at(-1)).toContain('"state":"working"')

  const s = { id: 'x', label: 'X', project: 'x', state: 'background', since: 0, until: null, voice: false } as const
  expect(bgLabel({ ...s, tasks: [{ type: 'subagent', description: 'a' }] })).toBe('Agent im Hintergrund')
  expect(bgLabel({ ...s, tasks: [{ type: 'shell', description: 'npm test' }] })).toBe('Job im Hintergrund')
  expect(bgLabel({ ...s, state: 'idle' })).toBe(null)
})

test('split pane: wheel over the top half scrolls sessions, below it the history from its newest', async () => {
  const s = { sess: 0, sessMax: 2, hist: 0, histMax: 10 }
  expect(scrollPane(3, 40, 5, s)).toEqual({ sess: 1, hist: 0 })        // down over the sessions
  expect(scrollPane(-4, 40, 30, s)).toEqual({ sess: 0, hist: 2 })      // up over the history → older
  expect(scrollPane(-4, 40, undefined, s)).toEqual({ sess: 0, hist: 2 }) // keys → history
  expect(scrollPane(9, 40, 30, s)).toEqual({ sess: 0, hist: 0 })       // never past the newest
  expect(scrollPane(-100, 40, 30, s).hist).toBe(10)                    // nor past the oldest
  expect(scrollPane(-4, 40, 5, { ...s, sessMax: 0 })).toEqual({ sess: 0, hist: 2 }) // tiles fit → the wheel scrolls the history
})

test('split pane: fixed halves when the body height is known, history shows the newest', async ($, on) => {
  mock.clock(on)
  on('classic.Stop', async () => ({ block: 'Antwort.' }))
  on('ui.render', async ($, e) => { const { Text } = $.ui.resolve(e); return <Text>engine</Text> })
  for (let i = 0; i < 6; i++) await $.classic.Stop({ stop_hook_active: false, last_assistant_message: `<speak>Satz ${i}.</speak>` })
  const ui = await $.ui.mount({ plugin: 'parley-ui', surface: 'desktop', component: 'Pane', requestId: 'parley',
    props: { scroll: { offset: 0, bodyRows: 30 }, bodyColumns: 80 } as never })
  const boxes = (await ui.findAll({ type: 'Box' })) as { props: { height?: number } }[]
  expect(boxes.some(b => b.props.height === 15)).toBe(true)
  expect(await ui.find({ type: 'Text', text: 'Satz 5.' })).toBeDefined()
  const labels = async () => ((await ui.findAll({ type: 'Button' })) as { props: { label?: string } }[]).map(b => b.props.label)
  expect(await labels()).not.toContain('↓ Neueste')
  expect(await ui.find({ type: 'Svg' })).toBeDefined() // the fade over the history's top edge
  await ui.press({ key: 'older' })
  await ui.press({ key: 'older' })
  expect(await ui.find({ type: 'Text', text: 'Satz 5.' })).toBeUndefined() // two messages back: Satz 5 + its reply
  expect(await ui.find({ type: 'Text', text: 'Satz 4.' })).toBeDefined()
  expect(await labels()).toContain('↓ Neueste')
  await ui.press({ key: 'latest' })
  expect(await ui.find({ type: 'Text', text: 'Satz 5.' })).toBeDefined()
  await ui.unmount()
})
