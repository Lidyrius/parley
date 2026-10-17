# Zentrale

Template for the **Zentrale** of Parley for iPhone: a permanent Claude Code session with Parley
voice mode on that takes everything said via "Hey Parley" that no running project session
claims — it finds and creates projects, hands tasks to project sessions through `POST /dispatch`
(Parley starts them when needed), says what is running (`GET /sessions`), and answers general
questions. `CLAUDE.md` is its (German) operating manual and `.parley.json` gives it the spoken
name "Zentrale". The Parley host (macOS/Windows) creates `~/workspace/privat/parley-zentrale`
(or the configured `zentraleDir`) from this folder when it first needs it and starts the session
there with `/parley:voice` — see `docs/IPHONE.md`, "Protocol v2".
