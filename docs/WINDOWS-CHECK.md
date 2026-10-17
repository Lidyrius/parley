# Windows check — win-v0.4.0

Everything below ships on Windows but has only been compiled (CI), never run on a real PC.
Go through it once; the log is `%APPDATA%\Parley\debug.log` (look for the quoted lines).

## Basics
- [ ] Update over an existing install: `stats.json` (Statistiken) is still there afterwards.
- [ ] A normal turn at the PC: speaks, beeps, listens, injects. Music pauses and resumes.

## iPhone
- [ ] Pair (tray → "iPhone verbinden…"), the phone shows the PC's sessions live.
- [ ] Unterwegs on the phone → an update rings; voice, captions and slides arrive; the reply
      from the phone's mic is injected.
- [ ] A permission prompt in a call: "ja" / "nein" by voice.
- [ ] Live Activity starts on the phone ("live activity: start → 200"), updates while working,
      widgets follow without opening the app ("widgets: silent push → 200").
- [ ] Put a call off from the phone → rings again in a minute.

## New in this release
- [ ] **Fragerunde:** hang up, let two sessions finish within 4 min → no ring in between, then one
      ring: "Ich habe zwei Updates für Sie, Sir."
- [ ] **Unterwegs bei Sperre:** tray "Unterwegs, wenn der PC gesperrt ist" on, Win+L, wait over a
      minute → the next update rings the phone; unlock → the PC speaks again.
- [ ] **Wachhund:** a session that keeps repeating the same command (or hangs for 15 min) → Parley
      asks "Soll ich eingreifen?"; "ja" → the session gets the hint.
- [ ] **Fortsetzen:** a session with background work shows "Fortsetzen" and resumes by voice.
- [ ] **Barge-in in a call:** talk over Parley → it stops at once, no beep, your first words are
      in the transcript.
- [ ] **Barge-in at the PC's speaker:** needs the German speech pack and Settings → Datenschutz →
      Spracherkennung → "Online-Spracherkennung" on. Say "Stopp" while Parley speaks → it stops and
      listens ("barge-in at the PC: Parley stops"). If not: the log says why ("barge: …").
      Check that Parley's own voice on loudspeakers does NOT trigger it.
- [ ] **Zentrale:** "schließ Session X" closes that terminal / desktop session; "mach mir eine
      Farbpalette …" lands on the phone under Eigene.
