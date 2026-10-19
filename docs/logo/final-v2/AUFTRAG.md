# Auftrag: wählbare App-Icons (Standard: Graphit)

Assets in `docs/logo/final-v2/` (mit Apples Icon Composer gebaut):

- `icon-composer/01-porzellan-indigo.icon`, `02-indigo.icon`, `03-graphit.icon`, `04-petrol.icon`:
  Icon-Composer-Bundles mit Hell/Dunkel/Getönt. `03-graphit.icon` ist das Standard-AppIcon.
- `png/<name>-{Default,Dark,ClearLight,ClearDark,TintedLight,TintedDark}.png`: Renderings in 1024×1024.
- `menuleiste.svg`: Template-Glyphe fürs Menüleisten-Symbol.
- `uebersicht-1.png`, `uebersicht-2.png`: Übersicht.

Gewünscht:

1. Einstellungen: Auswahl „App-Icon“ mit allen vier Optionen als Vorschau-Kacheln, Standard Graphit.
2. macOS: `03-graphit.icon` als primäres AppIcon. Zur Laufzeit umschalten über
   `NSApp.applicationIconImage` + `NSWorkspace.shared.setIcon(_:forFile:)` auf das .app-Bundle
   (Default-/Dark-PNG je nach Erscheinungsbild), Wahl persistieren.
3. Windows (gleicher Change): dieselben vier als .ico aus den PNGs, im Tray/Settings wählbar,
   Standard Graphit; per `windows-build`-CI kompilieren.
4. iOS: optional als Alternate App Icons (`setAlternateIconName`). Sir entscheidet.
5. Kein Release, bis Sir es sagt.
