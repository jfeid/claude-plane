import { expect, test } from 'claude-code/testing'
import { handOff, SKILL } from '../hooks/register'

test('/plane status hands the arguments to the skill', async ($, on) => {
  const registered: string[] = []
  const submitted: { text: string; asUser?: true }[] = []
  on('command.register', (_, e) => {
    registered.push(e.name)
    return { value: { command: e.name } }
  })
  on('prompt.submit', (_, e) => {
    submitted.push({ text: e.text, asUser: e.origin?.kind === 'plugin' ? e.origin.asUser : undefined })
    return { text: e.text }
  })
  const logs: string[] = []
  on('ui.log', (_, e) => { logs.push(JSON.stringify(e)); return { value: undefined } })
  on('clock.after', () => ({ value: undefined }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))

  await $.session.start({ cwd: '/work/shop', surface: 'terminal', isInteractive: true })
  expect(registered).toEqual(['plane'])

  const res = await $.command.run({ command: 'plane', args: ' status ABC-12 ' })
  expect(res.text).toBeUndefined()
  expect(res.context).toEqual([
    `The person ran /plane status ABC-12. Load the ${SKILL} skill with the Skill tool, passing the arguments "status ABC-12", and follow it.`,
  ])
  // The prompt goes from a timer after the hook returned; let it run.
  await new Promise(r => setTimeout(r, 20))
  expect(logs).toEqual([])
  expect(submitted).toEqual([{ text: 'plane status ABC-12', asUser: true }])
})

test('a bare /plane passes no arguments', () => {
  const { prompt, note } = handOff('')
  expect(prompt).toBe('plane')
  expect(note).toContain('passing no arguments')
})
