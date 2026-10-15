export type Phase = 'off' | 'idle' | 'queued' | 'speaking' | 'listening' | 'transcribing' | 'heard' | 'parked'
export type Line = { who: 'parley' | 'you'; text: string; at: number }
export type SessState = 'speaking' | 'listening' | 'transcribing' | 'queued' | 'working' | 'waiting' | 'parked' | 'background' | 'idle' | 'stopped'
/** One Parley session as the app's GET /sessions reports it (epoch ms). */
export type Stats = { startedAt: number | null; contextPercent: number | null; costUsd: number | null; turns: number; replies: number; lastLine: string | null }
export type Sess = { id: string; label: string; project: string; state: SessState; since: number; until: number | null; voice: boolean; resumable?: boolean; stats?: Stats; tasks?: Task[] }
/** Background work a session left running when its turn ended (subagent, shell, monitor). */
export type Task = { type: string; description: string }
export type Limit = { kind: string; percentUsed: number; resetsAt: string | null }
/** Totals for today across every session (GET /sessions `today`). */
export type Today = { costUsd: number; turns: number; spokenSeconds: number; rateLimits: Limit[] }

declare module 'claude-code' {
  interface PluginState {
    'parley-ui': {
      phase: Phase
      line: string
      history: Line[]
      tick: number
      /** Eased live volume 0…1 from the app's GET /status; null → no live data. */
      level: number | null
      isHidden: boolean
      /** Every Parley session from the app's GET /sessions; null → app unreachable. */
      overview: Sess[] | null
      /** Today's totals across every session; null → app too old to report them. */
      today: Today | null
      /** This session's in-flight background tasks, as its last Stop reported them. */
      tasks: Task[]
      /** Overview session rows scrolled past at the top (fractional: wheel ticks accumulate). */
      sessSkip: number
      /** History messages scrolled back from the newest (0 = following the conversation). */
      histSkip: number
      /** Session ids whose tile shows its details. */
      expanded: string[]
      /** When `overview` was fetched (epoch ms): the clock its timers count against. */
      seen: number
      /** This session's turn is running (reported to the app as presence). */
      isWorking: boolean
    }
  }
}
