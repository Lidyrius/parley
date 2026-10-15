import { expect, mock, test } from 'claude-code/testing'

import { meter, parseSpeak, wave } from '../hooks/register'

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

test('meter maps live levels to bar glyphs, newest last', async () => {
  expect(meter([0, 0.5, 1], 24)).toBe('▁▅█')
  expect(meter([0, 0, 0, 1], 2)).toBe('▁█')
})

test('live /status drives phase and a real meter while the app listens', async ($, on) => {
  const clock = mock.clock(on)
  let release = () => {}
  const gate = new Promise<void>(r => { release = r })
  on('classic.Stop', async () => { await gate; return { block: 'Klingt gut.' } })
  on('http.fetch', async () => ({ value: {
    status: 200, ok: true, headers: {},
    text: JSON.stringify({ phase: 'listening', session: 's1', levels: [0, 0.5, 1] }),
  } }))
  on('ui.render', async ($, e) => { const { Text } = $.ui.resolve(e); return <Text>engine</Text> })

  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const stop = $.classic.Stop({ stop_hook_active: false, session_id: 's1', last_assistant_message: '<speak>Frage, Sir?</speak>' })
  await clock.advance(350)
  expect(await ui.find({ type: 'Text', text: /hört zu\s+▁▅█/ })).toBeDefined()

  release()
  await stop
  expect(await ui.find({ type: 'Text', text: /eingespeist/ })).toBeDefined()
  await ui.unmount()
})
