// The /plane command of the plane-worklog plugin.
//
// The workflow itself is the plugin's skill, which needs a model turn. A
// plugin skill shows as /plane-worklog:<name>, so the skill is named
// plane-workflow (it does not claim /plane) and this mod registers a plain
// /plane that hands the typed arguments to Claude with the skill to load.

import type { Register } from 'claude-code'

export const SKILL = 'plane-worklog:plane-workflow'

const ACTIONS = 'start|close|show|status|log|day|month|comment|move|done|pause|resume|mine|setup|help'

// The prompt the person sees under /plane, and the note only Claude reads.
export function handOff(args: string): { prompt: string; note: string } {
  const a = args.trim()
  return {
    prompt: a ? `plane ${a}` : 'plane',
    note:
      `The person ran /plane${a ? ` ${a}` : ''}. Load the ${SKILL} skill with the Skill tool, ` +
      `passing ${a ? `the arguments "${a}"` : 'no arguments'}, and follow it.`,
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    try {
      await $.command.register({
        name: 'plane',
        description: 'Plane work item workflow: start, close, status, log, day and month reports',
        argumentHint: `[${ACTIONS}] [KEY|URL|DATE|MM-YYYY]`,
      })
    } catch (err) {
      // Another command already owns /plane; the skill still answers plain requests.
      $.ui.log(`plane-worklog: /plane not registered: ${String(err)}`)
    }
    return started
  })

  // The note is recorded after the command's row. The prompt starts Claude's
  // turn; the engine refuses a submit from inside this hook (it would wait on
  // the run this hook holds), so it goes from a timer once the hook returned.
  on('command.run', { command: 'plane' }, async ($, e) => {
    const { prompt, note } = handOff(e.args)
    $.clock.after(1, () => {
      void $.prompt.submit({ text: prompt, asUser: true }).catch(err =>
        $.ui.log(`plane-worklog: /plane could not start a turn: ${String(err)}`),
      )
    })
    return { context: [note] }
  }).catch(($, e, next) => next(e))
}
