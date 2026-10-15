import { expect, mock, test } from 'claude-code/testing'

import { ease, parseSpeak, ringSvg, timer, wave, waveSvg } from '../hooks/register'

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
  const svg = waveSvg(0.5, 0, '#D97757', 1234)
  expect(svg.match(/<line /g)?.length).toBe(28)
  expect(svg).toContain('begin="-1.23s"') // wave phase follows the clock across redraws
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
  expect(await desk.find({ type: 'Svg' })).toBeDefined()

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
