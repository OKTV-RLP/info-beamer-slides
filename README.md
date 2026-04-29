# Infotext Player für info-beamer hosted

Spielt Folien (`playlist.m3u8` + PNG-Folien mit optionalem
Alphakanal) auf einem info-beamer-hosted-Pi ab.

## Architektur

info-beamer-Lua-Knoten haben **kein eingebautes HTTP**. Das Package
besteht daher aus zwei Teilen:

```
service        ← Python-Sidecar: pollt HTTP, speichert Folien, schreibt
                 manifest.json (HTTP/HTTPS, optional self-signed)
                       │
                       ▼
                 manifest.json + cache/*.png
                       │
                       ▼
node.lua       ← Renderer: liest manifest via util.json_watch, lädt
                 Folien aus cache/, rendert mit Crossfade
```

- Der Service pollt regelmäßig (`poll_interval`, Default 60 s) und
  schreibt nur dann ein neues Manifest, wenn sich die Folien-Liste
  ändert.
- Der Renderer wendet ein neues Manifest am **Ende des aktuellen
  Zyklus** an, mit Crossfade von der letzten Folie der alten Liste zur
  ersten Folie der neuen — analog zum HTML-Player.
- Folien-Filenames sind content-adressiert; der Cache prüft daher nur
  auf Existenz, kein Hash-Vergleich, keine Re-Downloads.

## Features

- HTTP **und** HTTPS, optional mit self-signed-Zertifikaten
  (`allow_insecure_https`).
- Crossfade zwischen Folien innerhalb eines Zyklus **und** über die
  Zyklus-Grenze hinweg.
- Backup-Inhalt aus Hosted-Asset-Pool, wenn Playlist nicht ladbar oder
  leer — Bild oder Video-Loop möglich.
- Optionaler Hintergrund-Inhalt (Bild oder Video-Loop), der durch die
  transparenten Folien durchscheint.

## Installation

1. Diesen Ordner als Package nach info-beamer hosted hochladen
   (`Packages → Upload`).
2. Auf Basis des Packages ein Setup anlegen.
3. Optional: eigenes Backup-Asset (Bild oder Video) hochladen und im
   Setup auswählen — sonst wird `empty.png` verwendet (schwarzes Bild).
4. Optional: Hintergrund-Asset (Bild oder Video) hochladen und im
   Setup-Feld *Hintergrund-Inhalt* auswählen.
5. `Playlist-URL` und `Folien-Basis-URL` des Infotext-Servers
   eintragen, ggf. *Self-signed-HTTPS akzeptieren* einschalten, Setup
   einem Device zuweisen.

## Konfigurationsoptionen

| Option | Default | Beschreibung |
|---|---|---|
| Playlist-URL | – | M3U8-Playlist-URL (http:// oder https://) |
| Folien-Basis-URL | – | Verzeichnis-URL der Folien-Bilder |
| Self-signed-HTTPS akzeptieren | false | TLS-Pruefung deaktivieren |
| Polling-Intervall | 60 s | Wie oft der Service die Playlist prüft |
| Wiederholversuch | 30 s | Pause nach HTTP-Fehler oder leerer Playlist |
| Fade-Dauer | 0.5 s | Crossfade zwischen Folien (intra- und inter-Zyklus) |
| Standard-Anzeigedauer | 10 s | Fallback wenn `#EXTINF` fehlt |
| Backup-Inhalt | empty.png | Bild oder Video bei Fehler/leerer Playlist |
| Hintergrund-Inhalt | (leer) | Optionales Bild oder Video hinter den Folien |

## HTTP/HTTPS und self-signed-Zertifikate

Der Python-Service nutzt die `requests`-Library. Standardmäßig wird die
TLS-Zertifikatskette gegen die System-CA validiert.

- **Reguläre Zertifikate** (Let's Encrypt etc.): einfach `https://`-URL
  eintragen, fertig.
- **Self-signed-Zertifikate**: Option *Self-signed-HTTPS akzeptieren*
  einschalten. Das setzt `verify=False` in `requests.get()` und
  unterdrückt die `InsecureRequestWarning`-Logs. **Schutz vor MITM
  entfällt** — nur in vertrauenswürdigen Netzen verwenden.
- **Reines HTTP**: einfach `http://`-URL eintragen.

## Backup- und Hintergrund-Inhalt

Beide Slots akzeptieren entweder ein Bild (PNG/JPG) oder ein Video-Loop
(MP4/WebM/MOV/MKV). Der Player erkennt den Typ automatisch über die
Asset-Metadaten von info-beamer hosted bzw. die Datei­endung und lädt
entsprechend `resource.load_image` oder `resource.load_video`.

**Bild:** funktioniert auf jeder Pi-Generation. Wird auf den vollen
Bildschirm gestreckt — bei abweichendem Seitenverhältnis verzerrt es,
also in nativer Display-Auflösung (z. B. 1920×1080) liefern.

**Video-Loop:** wird mit `raw = true` in die GL-Pipeline geladen, damit
es sich mit anderen Layern mischen lässt. Das setzt **Raspberry Pi 4
oder neuer** voraus. Auf Pi 3 schlägt der Load fehl, der Player loggt
eine Warnung (`<Slot> nicht ladbar … (Video-Loop benötigt Pi 4+)`) und
arbeitet ohne den betroffenen Slot weiter:
- Hintergrund-Slot leer → Schwarz hinter den Folien.
- Backup-Slot leer → Schwarzer Bildschirm während Fehlerzustand.

Wer Pi-3-Kompatibilität braucht, lädt für die jeweiligen Slots ein Bild
hoch.

**Skalierung:** sowohl Bilder als auch Videos werden auf den vollen
Output-Bildschirm gestreckt (kein Letterbox). Folien, Backup-Inhalt
und Hintergrund-Inhalt daher **in nativer Display-Auflösung
liefern** (z. B. 1920×1080), sonst verzerrt es. Hintergrund: bei
raw-Videos gibt info-beamer ohnehin keine Aspect-Korrektur (kein
`:size()` für `:place`), bei Bildern ist es eine bewusste Wahl —
Letterbox-Balken stören den Look des Players.

## Audio

Videos werden mit `audio = true` geladen; vorhandene Audio-Tracks
werden über das info-beamer-Audio-Target ausgegeben (HDMI bei Hosted-
Default). Da info-beamer keinen Runtime-Mute kennt, schaltet der Player
zwischen den Quellen über `:stop()` und `:start()`:

- **Normalbetrieb (Folienwiedergabe):** Audio des Hintergrund-Videos.
- **Backup mit Backup-VIDEO:** Audio des Backup-Videos. Hintergrund-
  Video wird angehalten (Frame eingefroren, Decoder pausiert).
- **Backup mit Backup-BILD (oder leerem Slot):** Audio des Hintergrund-
  Videos läuft weiter; das Backup-Bild liegt visuell darüber.

Wenn weder Hintergrund- noch Backup-Slot ein Video ist, ist der Player
stumm. Das Backup-Default `empty.png` ist ein Bild — Audio kommt also
vom Hintergrund-Video, sofern eines konfiguriert ist.

## Voraussetzungen

- info-beamer hosted Runtime (Service-Sidecar mit Python 2.7 und
  `requests` ist Standard).
- Erreichbarkeit des Quell-Servers per HTTP/HTTPS vom Pi aus.
- Folien-Filenames müssen content-addressed sein (gleicher Name ⇒
  gleicher Inhalt).
- Für Video-Loops: Raspberry Pi 4 oder neuer.

## Caching-Verhalten

- **Cache-Verzeichnis**: `cache/` neben dem Service. Lua liest die
  Folien direkt von dort.
- **Download nur bei Bedarf**: Filenames sind content-adressiert; der
  Service prüft vor jedem Download nur, ob `cache/<name>` existiert.
- **Cache-GC**: nach jedem erfolgreichen Playlist-Fetch löscht der
  Service alle Files in `cache/`, die nicht mehr in der aktuellen
  Playlist stehen, sowie `.tmp`-Reste abgebrochener Downloads. Wird
  bei HTTP-Fehler oder leerer Playlist übersprungen, damit ein
  Server-Ausfall nicht den Cache wegwirft.
- **Cache-Wipe bei Service-Update**: info-beamer entfernt alle vom
  Service erzeugten Files (außer `SCRATCH/`), wenn das Service-Skript
  aktualisiert wird. Folien werden dann beim ersten Polling neu
  heruntergeladen. Reine `node.lua`/`node.json`-Updates lassen den
  Cache intakt.

## Lokales Testen mit info-beamer pi

Falls du auf einem Pi außerhalb der Hosted-Plattform testen willst:

```bash
# config.json manuell anlegen:
cat > config.json <<EOF
{
    "playlist_url": "https://dein-server/slides/playlist.m3u8",
    "folien_base_url": "https://dein-server/slides/",
    "allow_insecure_https": false,
    "poll_interval": 60,
    "retry_interval": 30,
    "fade_duration": 0.5,
    "default_duration": 10,
    "backup_media": "empty.png",
    "background_media": ""
}
EOF

# Service im Hintergrund starten (lädt Folien & schreibt manifest.json):
./service &

# Renderer starten:
info-beamer .
```
