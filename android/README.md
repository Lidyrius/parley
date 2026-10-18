# Parley für Android

Kotlin / Jetpack Compose, ein Port der iPhone-App (`ios/`) gegen dasselbe Relay-Protokoll
(`docs/IPHONE.md`): Kopplung per QR-Code oder Link, die Übersicht im C2-Design (Raster/Liste,
Blatt pro Session, Wiedervorlagen), Verlauf + Nachricht, Anrufe über das Relay (klingeln,
annehmen, „Später“, Stumm, Lautsprecher, Untertitel).

```bash
JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home ./gradlew assembleRelease
# → app/build/outputs/apk/release/app-release.apk (mit dem Debug-Schlüssel signiert)
```

Demo ohne Relay (Screenshots): `adb shell am start -n de.developaway.parley.android/de.developaway.parley.MainActivity --es demo overview`
(`session`, `incoming`, `connecting`, `speaking`, `listening`, `idle`).

Verbindung wie beim iPhone: über das öffentliche Relay (Standard) oder ein eigenes, Ende-zu-Ende
verschlüsselt (Schlüssel im QR-Code, `docs/IPHONE.md` → v5). Eine Kopplung von vor v5 → neu koppeln.

Anders als auf dem iPhone:

- **Klingeln nur mit „Unterwegs“:** kein Push (FCM) — ein Vordergrund-Dienst hält die
  Verbindung zum Relay offen; Akku-Optimierung in den Einstellungen ausschalten.
- **„Sprechen“ / „Unterbrechen“ sind Knöpfe** statt „Hey Parley“ und Barge-in per Stimme.
- Kein „Stumm“ (der Mac schickt Mitteilungen nur über APNs), keine Folien, Paletten, Widgets
  oder Live Activity.
