export type Phase = 'off' | 'idle' | 'queued' | 'speaking' | 'listening' | 'transcribing' | 'heard' | 'parked'
export type Line = { who: 'parley' | 'you'; text: string; at: number }

declare module 'claude-code' {
  interface PluginState {
    'parley-ui': {
      phase: Phase
      line: string
      history: Line[]
      tick: number
      /** Live audio levels 0…1 from the app's GET /status; null → no live data, animate. */
      levels: number[] | null
      isHidden: boolean
    }
  }
}
