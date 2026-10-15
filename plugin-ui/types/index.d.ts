export type Phase = 'off' | 'idle' | 'queued' | 'speaking' | 'listening' | 'transcribing' | 'heard' | 'parked'
export type Line = { who: 'parley' | 'you'; text: string; at: number }
export type SessState = 'speaking' | 'listening' | 'transcribing' | 'queued' | 'working' | 'waiting' | 'parked' | 'idle' | 'stopped'
/** One Parley session as the app's GET /sessions reports it (epoch ms). */
export type Sess = { id: string; label: string; project: string; state: SessState; since: number; until: number | null; voice: boolean }

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
      /** When `overview` was fetched (epoch ms): the clock its timers count against. */
      seen: number
      /** This session's turn is running (reported to the app as presence). */
      isWorking: boolean
    }
  }
}
