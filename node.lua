-- Infotext Player für info-beamer hosted
--
-- Reiner Renderer: HTTP-Fetching erfolgt im Python-Service-Sidecar
-- (siehe ./service), der Folien herunterlädt und manifest.json schreibt.
-- Diese Datei wird via util.json_watch beobachtet — bei Änderung wird
-- zum nächsten Zyklus-Ende auf die neue Folge geswitcht.
--
-- Crossfade zwischen Folien innerhalb eines Zyklus UND über die
-- Zyklus-Grenze hinweg (letzte Folie alt → erste Folie neu, ggf. nach
-- Manifest-Update).
--
-- Backup- und Hintergrund-Slot akzeptieren je ein Bild ODER ein Video.
-- Folien selbst koennen Bilder (PNG) ODER H.264-Videos (MP4) sein,
-- in beliebiger Mischung in der Playlist. Video-Folien werden in voller
-- Dateilaenge ausgespielt (Manifest-duration wird ignoriert) und mit
-- Hard-Cut an Image- bzw. anderen Video-Folien angeschlossen — der
-- Crossfade-Shader kann nur GL-Texturen samplen, nicht raw-Videos.
--
-- Bilder funktionieren auf jedem Pi; Video-Loops/Folien setzen einen
-- H.264-Hardware-Decoder voraus (raw=true GL-Pipeline). Auf Pi 3B
-- gibt es nur EINEN Decoder-Slot — das BG-Video wird daher fuer die
-- Dauer einer Video-Folie via background_yield() komplett freigegeben
-- und mit background_resume() wieder geladen.
--
-- Layer-Stack (negativ = hinter GL-Surface):
--   -3: Hintergrund-Video (background_slot)
--   -2: Backup-Video      (backup_slot)
--   -1: Foreground-Video  (fg_video, NEU — nur waehrend Video-Folien aktiv)
--    0: GL-Surface mit Folien-Image, Cornerlogo, Zeit-Overlay
-- Cornerlogo + Zeit liegen damit auch ueber laufenden Video-Folien.
--
-- Audio (info-beamer mischt automatisch alle :start()-aktiven Quellen):
--   * Normalbetrieb (PLAYING): Audio des Hintergrund-Videos.
--   * Backup-Zustand (IDLE) mit Backup-VIDEO: Audio des Backup-Videos.
--   * Backup-Zustand mit Backup-BILD: Audio des Hintergrund-Videos
--     laeuft weiter, das Backup-Bild liegt nur visuell darueber.
--   * Video-Folie (PLAYING): FG-Audio mischt sich mit der bisherigen
--     Quelle (Stream/Jukebox); BG-Audio entfaellt, weil BG fuer den
--     Decoder-Slot weichen muss.

gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

util.no_globals()

local json = require "json"

------------------------------------------------------------
-- Konfiguration
------------------------------------------------------------

local CONFIG = {
    fade_duration    = 0.5,
    default_duration = 10,
}

-- Raw-Videos rendern in info-beamer auf einer eigenen Ebene außerhalb
-- der GL-Pipeline. layer < 0 platziert das Video HINTER der GL-Surface,
-- sodass transparente Folien-Pixel via gl.clear(_, _, _, 0) und
-- transparenten Folien-PNG-Bereichen das Video durchscheinen lassen.
-- Reihenfolge der negativen Layer (siehe Datei-Header): BG (-3),
-- Backup (-2), Foreground-Video-Folie (-1, dynamisch). Backup auf
-- hoeherer (= weniger negativer) Ebene als BG, damit es im IDLE-
-- Zustand das BG-Video ueberdeckt; FG-Video wiederum oberhalb von
-- Backup, damit eine Video-Folie BG/Backup ueberblendet.
-- slot.audio steuert, ob die Resource mit Audio-Track geladen wird.
-- Backup-Video: immer mit Audio (Audio-Quelle nur waehrend IDLE+
-- backup-video sichtbar; Pause durch :stop() in anderen States ist
-- ok, weil das Video dann ohnehin off-screen ge:place't ist).
-- Background-Video: dynamisch, abhaengig von audio_stream.enabled.
--   Stream aus → audio=true  (BG-Video kann Audio-Quelle sein)
--   Stream an  → audio=false (BG-Video laeuft visuell durchgehend
--                             und wird vom Routing nicht :stop()ed)
-- Bei Toggle des Stream-Zustands forciert update_media_slot ueber
-- den slot.audio_loaded-Vergleich einen Reload des BG-Videos.
local backup_slot     = { res = nil, kind = nil, file = nil, label = "Backup-Inhalt",     layer = -2, audio = true }
local background_slot = { res = nil, kind = nil, file = nil, label = "Hintergrund-Inhalt", layer = -3, audio = true }

-- Foreground-Video-Slot fuer Video-Folien. Nur eine Resource gleichzeitig
-- (Lazy-Load beim Eintritt in eine Video-Folie, Dispose beim Verlassen).
-- BG-Video MUSS vor dem Load via background_yield() freigegeben werden,
-- weil Pi 3B nur einen H.264-Decoder hat. looped=false → das Video laeuft
-- bis :state() == "finished", dann advanced der Render-Loop.
local fg_video = {
    res   = nil,
    file  = nil,
    layer = -1,
}

-- Optionales Zeit-Overlay. Wird im PLAYING-Zustand über den Folien
-- gezeichnet, im IDLE-Zustand vom Backup-Layer überdeckt (durch
-- Render-Reihenfolge). Erfordert ein per Setup hochgeladenes Font-
-- Asset; ohne Schrift wird das Overlay übersprungen.
local time_overlay = {
    enabled   = false,
    -- text wird vom service-Sidecar (mit korrekter Timezone) per
    -- UDP-IPC zugestellt und via util.data_mapper{ time = … }
    -- eingespielt. Kein Disk-IO.
    text      = "",
    locale    = "de",
    font_res  = nil,
    font_file = nil,
    size      = 80,
    color     = { r = 1, g = 1, b = 1, a = 1 },
    x         = 1820,
    y         = 980,
    align     = "right",
}

-- Optionales Cornerlogo: PNG mit Alphakanal, in Originalgröße bei
-- (x, y) gezeichnet.
-- Wird IMMER zuletzt gezeichnet, liegt also auch im Backup-Zustand
-- sichtbar oben drüber.
local corner_logo = {
    enabled = false,
    res     = nil,
    file    = nil,
    x       = 0,
    y       = 0,
}

------------------------------------------------------------
-- Player-State
------------------------------------------------------------

local STATE_IDLE    = "idle"      -- keine Folien aktiv → backup_slot
local STATE_PLAYING = "playing"

local state          = STATE_IDLE
local slides         = {}     -- [{file, kind, duration, res}, ...]
local current_idx    = 1
local slide_started  = 0
local pending_slides = nil    -- nächste Liste, swap am Zyklus-Ende
local last_cur       = nil    -- zuletzt gerenderte Folie (Slide-Wechsel-Hook)

-- Zyklus-Crossfade (letzte Folie alt → erste Folie neu).
local outgoing         = nil   -- nil oder {res, dispose_after}
local cycle_fade_start = 0

-- Audio-Routing-Status: "background" | "backup" | "stream" | "jukebox" | nil
local audio_active = nil

-- Optionaler HTTP-/Icecast-Audio-Stream via resource.load_audio;
-- Aktivierung verlangt zusätzlich
-- runtime.outside_sources=true in package.json (für HTTP-URLs) und
-- die "audio"-Capability auf der Hardware (sys.provides "audio").
-- Pegel wird zur Laufzeit per :volume(0..1) gesteuert. Watchdog disposed bei
-- state="error"/"finished" und reconnectet nach retry_after Sekunden.
local audio_stream = {
    enabled      = false,
    url          = "",
    volume       = 1.0,  -- 0.0 (stumm) bis 1.0 (voll)
    res          = nil,
    loaded_url   = nil,
    last_attempt = -math.huge,
    retry_after  = 5,
    buffer       = 5,    -- Sekunden Pre-Buffer
    available    = sys.provides and sys.provides("audio") or false,
}

-- Optionale Jukebox: lokal gespeicherte Audio-Files (per Setup als
-- Resources hochgeladen) werden sequenziell oder zufaellig nacheinander
-- abgespielt. Genau ein Track ist gleichzeitig geladen. Sobald
-- :state() == "finished" liefert, disposed der Health-Check ihn und
-- laedt den naechsten Track der Reihenfolge. Bei "error" wird der
-- gleiche Track nicht endlos retried — wir wechseln direkt zum
-- naechsten der Liste, sonst koennte ein einzelnes kaputtes File die
-- gesamte Wiedergabe blockieren.
--
-- Reihenfolge: order ist eine Permutation von 1..#files (Sequenz oder
-- Fisher-Yates-Shuffle). order_pos zeigt auf den zuletzt geladenen
-- Eintrag. Nach dem Ende der Liste mischt sich order bei shuffle=true
-- neu — sonst startet sie wieder bei 1.
local audio_jukebox = {
    enabled       = false,
    shuffle       = false,
    volume        = 1.0,
    files         = {},     -- {dateiname, ...}
    order         = {},     -- Indizes in files (Sequenz oder Shuffle)
    order_pos     = 0,
    res           = nil,
    loaded_file   = nil,
    last_state    = nil,
    last_attempt  = -math.huge,
    retry_after   = 2,      -- Cooldown zwischen Load-Versuchen (Schutz
                            -- gegen Reload-Sturm bei wiederholten
                            -- Fehlern; bei normalen Track-Wechseln
                            -- vernachlaessigbar, weil last_attempt nur
                            -- im load_jukebox_track() gesetzt wird)
    available     = sys.provides and sys.provides("audio") or false,
}

-- Math-RNG einmalig seeden, damit Shuffle nicht in jeder Session
-- identisch laeuft. sys.now() liefert eine Float-Sekunde seit
-- Knoten-Start; das genuegt fuer die Audio-Reihenfolge (kein
-- Krypto-Bedarf).
math.randomseed(math.floor((sys.now() or 0) * 1000) + 1)

------------------------------------------------------------
-- Hilfsfunktionen
------------------------------------------------------------

local function now() return sys.now() end

-- Hosted gibt resource-Optionen je nach Runtime-Version mal als String,
-- mal als Tabelle mit asset_name/filename zurück. Beide Formen abdecken.
local function resolve_resource(value)
    if type(value) == "string" then
        return (value ~= "" and value) or nil
    end
    if type(value) == "table" then
        local n = value.asset_name or value.filename or value.file
        return (n and n ~= "" and n) or nil
    end
    return nil
end

-- Typ eines Media-Assets bestimmen: zuerst Hosted-Metadaten, sonst über
-- die Endung erraten. Default ist "image" — funktioniert auf jedem Pi.
local function media_type_for(value, name)
    if type(value) == "table" then
        if value.type == "video" then return "video" end
        if value.type == "image" then return "image" end
    end
    if name then
        local ext = name:lower():match("%.([%w]+)$") or ""
        if ext == "mp4" or ext == "webm" or ext == "mov"
           or ext == "mkv" or ext == "m4v" or ext == "avi" then
            return "video"
        end
    end
    return "image"
end

-- Lädt ein Media-Asset entsprechend seines Typs. Videos werden mit
-- raw=true (GL-Pipeline) geladen. with_audio steuert pro Slot, ob
-- ein Audio-Track mitgeladen wird — das Hintergrund-Video bekommt
-- audio=false, weil sein Frame-Strom durchgehend visuell laufen muss
-- und info-beamers :stop() Audio nicht ohne Video muten kann. paused
-- =true, weil update_media_slot direkt nach load :start() aufruft
-- (so beginnt der Decoder unter unserer Kontrolle). Auf Pi 3
-- schlägt raw-Video fehl, der pcall-Aufruf liefert ok=false.
local function load_media(name, kind, with_audio)
    if kind == "video" then
        return pcall(resource.load_video, {
            file   = name,
            looped = true,
            raw    = true,
            audio  = with_audio and true or false,
            paused = true,
        })
    end
    return pcall(resource.load_image, {file = name})
end

local function dispose_list(list)
    for _, s in ipairs(list or {}) do
        if s.res then
            pcall(function() s.res:dispose() end)
        end
    end
end

-- Dezibel → linearer Faktor [0..1] für info-beamers :volume()-API.
-- 0 dB = 1.0 (unity), -6 dB ≈ 0.5 (halbe Amplitude), -20 dB = 0.1.
-- Werte ≤ -60 dB auf 0 clampen (praktisch stumm), Werte ≥ 0 dB auf
-- 1 (Stream-Audio kann von info-beamer nicht verstärkt, nur
-- abgesenkt werden).
local function db_to_linear(db)
    if db == nil  then return 1   end
    if db <= -60  then return 0   end
    if db >=   0  then return 1   end
    return 10 ^ (db / 20)
end

-- Englische Wochentag-/Monatsnamen durch deutsche ersetzen. Wird auf
-- die Ausgabe von os.date() angewendet, weil info-beamer-Lua mit
-- C-Locale läuft (=> englische %A/%B/%a/%b). Frontier-Patterns
-- (%f[%a]…%f[%A]) sorgen für Wortgrenzen — sonst würde "Mon" im
-- bereits ersetzten "Montag" wieder zu "Mo" werden.
--
-- Reihenfolge: vollständige Namen ZUERST, dann Abkürzungen. Sonst
-- könnte z. B. "Mar" das "Mar"-Präfix von "March" ersetzen, bevor
-- die volle Form drankommt.
local DE_REPLACEMENTS = {
    -- Vollständige Wochentage
    {"Wednesday", "Mittwoch"},
    {"Thursday",  "Donnerstag"},
    {"Saturday",  "Samstag"},
    {"Tuesday",   "Dienstag"},
    {"Monday",    "Montag"},
    {"Friday",    "Freitag"},
    {"Sunday",    "Sonntag"},
    -- Vollständige Monate
    {"September", "September"},
    {"February",  "Februar"},
    {"November",  "November"},
    {"December",  "Dezember"},
    {"October",   "Oktober"},
    {"January",   "Januar"},
    {"August",    "August"},
    {"March",     "März"},
    {"April",     "April"},
    {"June",      "Juni"},
    {"July",      "Juli"},
    -- Abgekürzte Wochentage
    {"Mon", "Mo"},
    {"Tue", "Di"},
    {"Wed", "Mi"},
    {"Thu", "Do"},
    {"Fri", "Fr"},
    {"Sat", "Sa"},
    {"Sun", "So"},
    -- Abgekürzte Monate (nur die, die sich vom Englischen unterscheiden)
    {"Mar", "Mär"},
    {"May", "Mai"},
    {"Oct", "Okt"},
    {"Dec", "Dez"},
}

local function localize_de(text)
    for _, pair in ipairs(DE_REPLACEMENTS) do
        text = text:gsub("%f[%a]" .. pair[1] .. "%f[%A]", pair[2])
    end
    return text
end

-- Zeit-Overlay-Schrift bei Asset-Wechsel neu laden.
local function update_time_font(name)
    if name == time_overlay.font_file then return end
    if time_overlay.font_res then
        pcall(function() time_overlay.font_res:dispose() end)
    end
    time_overlay.font_res  = nil
    time_overlay.font_file = name
    if not name then return end
    local ok, f = pcall(resource.load_font, name)
    if ok and f then
        time_overlay.font_res = f
    else
        print("Zeit-Schrift nicht ladbar: " .. name)
    end
end

-- Cornerlogo-Asset bei Wechsel neu laden.
local function update_corner_logo(name)
    if name == corner_logo.file then return end
    if corner_logo.res then
        pcall(function() corner_logo.res:dispose() end)
    end
    corner_logo.res  = nil
    corner_logo.file = name
    if not name then return end
    local ok, r = pcall(resource.load_image, {file = name})
    if ok and r then
        corner_logo.res = r
    else
        print("Cornerlogo nicht ladbar: " .. name)
    end
end

------------------------------------------------------------
-- Crossfade-Shader (prämultiplizierte-Alpha-Lerp)
------------------------------------------------------------
-- Standard-Alphablending mit zwei :draw-Aufrufen produziert keine
-- saubere Lerp zwischen zwei RGBA-Texturen — zweiter Draw = src*p +
-- (1-p) * (1-p)*A statt p*B + (1-p)*A. Die Folge: an Stellen, wo
-- Folie A opak und Folie B transparent ist (oder umgekehrt), gibt es
-- entweder einen abrupten Wechsel am Fade-Ende oder ein Helligkeits-
-- Loch in der Mitte des Fades.
--
-- Lösung: fragment-shader, der beide Texturen sampelt, in
-- prämultipliziertem Alpha-Raum lerpt (sodass transparente Pixel
-- wirklich keinen Color-Beitrag haben) und das Ergebnis als
-- straight-alpha herausgibt. Der nachgelagerte Standard-Composite
-- ueber den Hintergrund-Layer ist dann mathematisch korrekt fuer
-- alle Transparenz-Kombinationen.
--
-- WICHTIG: info-beamer liefert PNG-Texturen bereits prämultipliziert
-- (tex.rgb = color*A). Daher KEIN nochmaliges `a.rgb*a.a` — sonst
-- waere der Foreground-Beitrag im Shader-Pfad um Faktor A dunkler
-- als im :draw-Pfad (sichtbar als plötzlicher Helligkeitsabfall an
-- Fade-Beginn in halbtransparenten Folienbereichen).
local crossfade_shader
do
    local ok, sh = pcall(resource.create_shader, [[
        uniform sampler2D from_tex;
        uniform sampler2D to_tex;
        uniform float progress;
        varying vec2 TexCoord;
        void main() {
            vec4 a = texture2D(from_tex, TexCoord);
            vec4 b = texture2D(to_tex,   TexCoord);
            vec4 r_pre = mix(a, b, progress);
            if (r_pre.a > 0.0) {
                gl_FragColor = vec4(r_pre.rgb / r_pre.a, r_pre.a);
            } else {
                gl_FragColor = vec4(0.0);
            }
        }
    ]])
    if ok then
        crossfade_shader = sh
    else
        print("Crossfade-Shader konnte nicht kompiliert werden — fallback auf zwei-Draw-Compositing mit leichten Artefakten an Transparenz-Kanten.")
    end
end

-- Mathematisch sauberer Crossfade zwischen zwei Folien-Ressourcen.
-- Die Geometrie kommt vom :draw der ersten Textur, der Shader
-- ersetzt jedoch die Fragment-Farbe — beide Texturen werden über
-- die Uniforms gesampelt.
local function draw_crossfade(from_res, to_res, progress)
    if not from_res or not to_res then return end
    if crossfade_shader then
        crossfade_shader:use{
            from_tex = from_res,
            to_tex   = to_res,
            progress = progress,
        }
        from_res:draw(0, 0, WIDTH, HEIGHT)
        crossfade_shader:deactivate()
    else
        -- Fallback (Compositing-Artefakte an Transparenz-Kanten).
        from_res:draw(0, 0, WIDTH, HEIGHT, 1)
        to_res:draw(0, 0, WIDTH, HEIGHT, progress)
    end
end

------------------------------------------------------------
-- Audio-Routing
------------------------------------------------------------
-- info-beamer setzt audio=true beim Laden — runtime gibt's keinen
-- Mute-Toggle. pause/start eines Videos hält Decoder + Audio an.
-- Wir laden beide Videos initial paused, und genau eines wird per
-- :start() aktiv — entweder das Hintergrund- oder das Backup-Video.

local function video_pause(slot)
    if slot.kind == "video" and slot.res then
        pcall(function() slot.res:stop() end)
    end
end

local function video_play(slot)
    if slot.kind == "video" and slot.res then
        pcall(function() slot.res:start() end)
    end
end

-- (Re)load des Audio-Streams via resource.load_audio. paused=true,
-- damit update_audio_routing im nächsten Frame über :volume(0/1)
-- entscheidet. last_attempt setzt die Cooldown-Schranke für den
-- Watchdog, damit fehlerhafte Streams nicht in einer Reconnect-
-- Schleife landen.
local function load_audio_stream()
    audio_stream.last_attempt = sys.now()

    local ok, r = pcall(resource.load_audio, {
        file   = audio_stream.url,
        buffer = audio_stream.buffer,
        paused = true,
    })
    if ok and r then
        audio_stream.res = r
        audio_stream.loaded_url = audio_stream.url
        pcall(function() r:volume(0) end)  -- gemutet starten
        pcall(function() r:start() end)     -- Decoder anwerfen
        audio_active = nil                  -- Routing-Neuevaluation
        print("Audio-Stream geladen: " .. audio_stream.url)
    else
        audio_stream.res = nil
        audio_stream.loaded_url = nil
        print(string.format(
            "Audio-Stream nicht ladbar: %s (Fehler: %s)",
            audio_stream.url, tostring(r)
        ))
    end
end

-- Wird pro Frame aufgerufen. Disposed den Stream, wenn er deaktiviert,
-- die URL geändert oder der Decoder in "error"/"finished" gelandet ist;
-- lädt ihn neu, sobald die Cooldown-Periode (retry_after) abgelaufen ist.
local function check_audio_stream_health()
    -- Audio-Capability nicht verfügbar (z. B. Pi ohne Sound-Hardware
    -- oder info-beamer-Build ohne Audio-Support) → Feature stillgelegt.
    if not audio_stream.available then return end

    if not audio_stream.enabled or audio_stream.url == "" then
        if audio_stream.res then
            pcall(function() audio_stream.res:dispose() end)
            audio_stream.res = nil
            audio_stream.loaded_url = nil
        end
        return
    end

    -- URL hat sich seit dem Load geändert → bestehenden Stream killen.
    if audio_stream.res and audio_stream.loaded_url ~= audio_stream.url then
        pcall(function() audio_stream.res:dispose() end)
        audio_stream.res = nil
    end

    -- Health-Check via :state(). Werte: "loaded", "paused", "finished",
    -- "error". Bei den letzten beiden den Stream verwerfen und nach
    -- Cooldown neu aufbauen.
    if audio_stream.res then
        local ok, st = pcall(function() return audio_stream.res:state() end)
        if ok and (st == "error" or st == "finished") then
            print(string.format(
                "Audio-Stream state=%s — Reconnect in %d s",
                tostring(st), audio_stream.retry_after
            ))
            pcall(function() audio_stream.res:dispose() end)
            audio_stream.res = nil
        end
    end

    -- (Re)load nach Cooldown.
    if not audio_stream.res
       and sys.now() - audio_stream.last_attempt >= audio_stream.retry_after then
        load_audio_stream()
    end
end

-- Fisher-Yates-Shuffle in-place.
local function shuffle_array(arr)
    for i = #arr, 2, -1 do
        local j = math.random(i)
        arr[i], arr[j] = arr[j], arr[i]
    end
end

-- order neu aufbauen: Sequenz 1..N, optional gemischt. Der
-- Health-Check inkrementiert order_pos vor dem Load — Start mit 0
-- bedeutet: naechster Load liest order[1].
--
-- Wenn waehrend des Rebuilds gerade ein Track laeuft, richten wir
-- order_pos so aus, dass er auf seine neue Position in der Reihenfolge
-- zeigt. Dadurch laedt der naechste Wechsel den darauffolgenden Track
-- der neuen Reihenfolge, statt versehentlich wieder bei order[1]
-- anzufangen (was den gerade beendeten Track erneut spielen koennte).
-- Ist der laufende Track nicht (mehr) in der Liste, faellt order_pos
-- auf 0 zurueck — der naechste Load startet dann sauber von vorn.
local function rebuild_jukebox_order()
    audio_jukebox.order = {}
    for i = 1, #audio_jukebox.files do
        audio_jukebox.order[i] = i
    end
    if audio_jukebox.shuffle then
        shuffle_array(audio_jukebox.order)
    end

    audio_jukebox.order_pos = 0
    if audio_jukebox.loaded_file then
        for pos, idx in ipairs(audio_jukebox.order) do
            if audio_jukebox.files[idx] == audio_jukebox.loaded_file then
                audio_jukebox.order_pos = pos
                break
            end
        end
    end
end

local function dispose_jukebox_track()
    if audio_jukebox.res then
        pcall(function() audio_jukebox.res:dispose() end)
    end
    audio_jukebox.res         = nil
    audio_jukebox.loaded_file = nil
    audio_jukebox.last_state  = nil
end

-- Naechsten Filenamen aus der Reihenfolge holen. Am Listenende neu
-- mischen (falls shuffle aktiv) und wieder von vorn.
local function jukebox_next_file()
    if #audio_jukebox.order == 0 then return nil end
    audio_jukebox.order_pos = audio_jukebox.order_pos + 1
    if audio_jukebox.order_pos > #audio_jukebox.order then
        if audio_jukebox.shuffle then
            shuffle_array(audio_jukebox.order)
        end
        audio_jukebox.order_pos = 1
    end
    local idx = audio_jukebox.order[audio_jukebox.order_pos]
    return audio_jukebox.files[idx]
end

-- Naechsten Track laden, gemutet starten. update_audio_routing
-- entscheidet pro Frame, ob die Jukebox tatsaechlich hoerbar wird.
local function load_jukebox_track()
    audio_jukebox.last_attempt = sys.now()

    local file = jukebox_next_file()
    if not file then return end

    local ok, r = pcall(resource.load_audio, {
        file   = file,
        paused = true,
    })
    if ok and r then
        audio_jukebox.res         = r
        audio_jukebox.loaded_file = file
        audio_jukebox.last_state  = nil
        pcall(function() r:volume(0) end)   -- gemutet starten
        pcall(function() r:start() end)      -- Decoder anwerfen
        audio_active = nil                   -- Routing-Neuevaluation
        print("Jukebox-Track geladen: " .. file)
    else
        audio_jukebox.res         = nil
        audio_jukebox.loaded_file = nil
        print(string.format(
            "Jukebox-Track nicht ladbar: %s (Fehler: %s)",
            file, tostring(r)
        ))
    end
end

-- Wird pro Frame aufgerufen. Disposed den aktuellen Track, sobald
-- er fertig oder fehlerhaft ist; laedt den naechsten nach Cooldown.
-- Keine endlosen Retry-Schleifen auf demselben File: bei "error"
-- ruecken wir in der Reihenfolge weiter.
--
-- Bei aktivem Stream (Stream > Jukebox in der Routing-Prioritaet, kein
-- Fallback) wird die Jukebox nie hoerbar — wir disposen den Decoder
-- und laden nichts neu, statt unnoetig Resourcen zu verbrennen. Sobald
-- der Stream im Setup deaktiviert wird, springt der Watchdog wieder
-- an.
local function check_audio_jukebox_health()
    if not audio_jukebox.available then return end

    local stream_dominates = audio_stream.enabled

    if not audio_jukebox.enabled
       or #audio_jukebox.files == 0
       or stream_dominates then
        if audio_jukebox.res then
            dispose_jukebox_track()
        end
        return
    end

    if audio_jukebox.res then
        local ok, st = pcall(function() return audio_jukebox.res:state() end)
        if ok then
            audio_jukebox.last_state = st
            if st == "finished" or st == "error" then
                if st == "error" then
                    print(string.format(
                        "Jukebox-Track-Fehler: %s — naechster Track",
                        tostring(audio_jukebox.loaded_file)
                    ))
                end
                dispose_jukebox_track()
            end
        end
    end

    if not audio_jukebox.res
       and sys.now() - audio_jukebox.last_attempt >= audio_jukebox.retry_after then
        load_jukebox_track()
    end
end

local function update_audio_routing()
    -- Audio-Quellen mit Prioritaet:
    --   1. BACKUP-Video (in IDLE mit Backup als Video)
    --   2. Stream (wenn audio_stream.enabled + Resource ready)
    --   3. Jukebox (wenn audio_jukebox.enabled + Resource ready)
    --   4. BG-Video (nur wenn mit Audio geladen — d. h. weder Stream
    --      noch Jukebox aktiviert, sonst hat BG audio_loaded = false)
    -- Kein dynamisches Fallback zwischen Stream/Jukebox/BG bei Ausfall
    -- der hoeher priorisierten Quelle: ist Stream konfiguriert aber
    -- gerade nicht ladbar, bleibt's stumm — wir wechseln NICHT auf
    -- Jukebox/BG-Audio. Konsistent mit Setup-Erwartung "wenn Stream
    -- aktiv, dominiert er".
    local target
    if state == STATE_IDLE
       and backup_slot.kind == "video" and backup_slot.res then
        target = "backup"
    elseif audio_stream.enabled then
        if audio_stream.res then target = "stream" end
    elseif audio_jukebox.enabled then
        if audio_jukebox.res then target = "jukebox" end
    elseif background_slot.kind == "video"
       and background_slot.res
       and background_slot.audio_loaded then
        target = "background"
    end

    if target == audio_active then return end

    -- Mute alle Nicht-Ziel-Audio-Quellen. Bei Videos :stop() (pausiert
    -- auch den Frame-Strom — fuer Backup egal weil off-screen, fuer
    -- BG nur dann aufgerufen, wenn es ueberhaupt mit Audio geladen
    -- ist; sonst gibt's nichts zu muten und :stop() wuerde nur den
    -- Visual-Freeze ausloesen). Beim Stream/Jukebox :volume(0), damit
    -- der Decoder verbunden bleibt und ein Reaktivieren ohne Latenz
    -- hoerbar ist.
    if target ~= "backup"
       and backup_slot.kind == "video" and backup_slot.res then
        pcall(function() backup_slot.res:stop() end)
    end
    if target ~= "background"
       and background_slot.kind == "video"
       and background_slot.res
       and background_slot.audio_loaded then
        pcall(function() background_slot.res:stop() end)
    end
    if target ~= "stream" and audio_stream.res then
        pcall(function() audio_stream.res:volume(0) end)
    end
    if target ~= "jukebox" and audio_jukebox.res then
        pcall(function() audio_jukebox.res:volume(0) end)
    end

    -- Aktiviere Ziel.
    if target == "backup" then
        video_play(backup_slot)
    elseif target == "background" then
        video_play(background_slot)
    elseif target == "stream" and audio_stream.res then
        pcall(function() audio_stream.res:volume(audio_stream.volume) end)
    elseif target == "jukebox" and audio_jukebox.res then
        pcall(function() audio_jukebox.res:volume(audio_jukebox.volume) end)
    end

    audio_active = target
end

------------------------------------------------------------
-- Zyklus-Crossfade-Primitive
------------------------------------------------------------

local function end_cycle_fade()
    if outgoing then
        if outgoing.dispose_after then
            pcall(function() outgoing.res:dispose() end)
        end
        outgoing = nil
    end
end

local function set_outgoing(slide)
    end_cycle_fade()
    if not slide or not slide.res then return end
    outgoing = {
        res           = slide.res,
        kind          = slide.kind,
        dispose_after = false,   -- ggf. von swap_slides auf true geflippt
    }
    cycle_fade_start = now()
end

-- Tauscht slides-Liste atomar aus und gibt die Ressourcen der alten
-- Liste frei — mit Ausnahme der ggf. von outgoing referenzierten, für
-- die wir die Disposal-Verantwortung übernehmen, damit der Zyklus-
-- Crossfade die Textur noch zu Ende rendern kann.
local function swap_slides(new_list)
    local old = slides
    slides = new_list
    for _, s in ipairs(old) do
        if s.res then
            if outgoing and outgoing.res == s.res then
                outgoing.dispose_after = true
            else
                pcall(function() s.res:dispose() end)
            end
        end
    end
end

------------------------------------------------------------
-- Media-Slot-Verwaltung
------------------------------------------------------------

local function update_media_slot(slot, cfg_value, default_name)
    local name = resolve_resource(cfg_value) or default_name
    if name == "" then name = nil end

    -- Reload, wenn der Filename ODER der gewuenschte Audio-Modus
    -- sich gegenueber dem zuletzt geladenen Stand unterscheidet.
    -- Audio-Mode-Wechsel passiert beim BG-Video, sobald audio_stream
    -- ein-/ausgeschaltet wird.
    if name == slot.file and slot.audio == slot.audio_loaded then return end

    if slot.res then
        pcall(function() slot.res:dispose() end)
    end
    slot.res, slot.kind, slot.file = nil, nil, name
    slot.audio_loaded = nil

    if not name then return end

    local kind = media_type_for(cfg_value, name)
    local ok, r = load_media(name, kind, slot.audio)
    if ok and r then
        slot.res, slot.kind = r, kind
        slot.audio_loaded = slot.audio
        -- raw-Video hinter die GL-Surface legen, damit transparente
        -- Folien-Pixel das Video durchscheinen lassen können.
        if kind == "video" and slot.layer ~= nil then
            pcall(function() r:layer(slot.layer) end)
            -- Visual-Playback sofort starten. paused=true im Load
            -- haelt Video- UND Audio-Decoder an; ohne diesen :start()
            -- bleibt das Bild eingefroren, sobald das Audio-Routing
            -- direkt auf eine andere Quelle (z. B. den Stream) zielt
            -- und video_play(slot) nie aufruft. Das nachfolgende
            -- :stop() im Routing pausiert auf info-beamer empirisch
            -- nur den Audio-Track, nicht den Frame-Strom — daher
            -- bleibt das Video sichtbar.
            pcall(function() r:start() end)
        end
    else
        local hint = (kind == "video") and " (Video-Loop benötigt Pi 4+)" or ""
        print(slot.label .. " nicht ladbar: " .. name .. hint)
    end
end

------------------------------------------------------------
-- Foreground-Video / BG-Yield (fuer Video-Folien)
------------------------------------------------------------

-- FG-Video aus dem Speicher loesen. Wird beim Verlassen einer Video-
-- Folie und vor jedem Reload aufgerufen. :place(0,0,0,0) verhindert,
-- dass info-beamer das letzte Frame auf seinem Layer eingefroren stehen
-- laesst — sonst bliebe es bis zum naechsten Slide-Wechsel sichtbar.
local function fg_video_unload()
    if fg_video.res then
        pcall(function() fg_video.res:place(0, 0, 0, 0) end)
        pcall(function() fg_video.res:dispose() end)
    end
    fg_video.res, fg_video.file = nil, nil
end

-- FG-Video laden und starten. looped=false → laeuft bis "finished",
-- dann triggert der Render-Loop das Advance. audio=true: der Audio-Track
-- mischt sich automatisch in den info-beamer-Output, parallel zu Stream/
-- Jukebox/BG (siehe Datei-Header). Auf Pi 3B muss vor dem Load das BG-
-- Video via background_yield() weichen — das macht der Caller.
local function fg_video_load(slide)
    if fg_video.res and fg_video.file == slide.file then return end
    fg_video_unload()
    local ok, r = pcall(resource.load_video, {
        file   = slide.file,
        looped = false,
        raw    = true,
        audio  = true,
        paused = true,
    })
    if ok and r then
        pcall(function() r:layer(fg_video.layer) end)
        pcall(function() r:start() end)
        fg_video.res, fg_video.file = r, slide.file
    else
        print("FG-Video nicht ladbar: " .. tostring(slide.file))
    end
end

-- Pi-3B-Engpass: nur ein H.264-Hardware-Decoder. Wenn eine Video-Folie
-- spielen soll, muss das BG-Video vorher KOMPLETT freigegeben werden
-- (:dispose), nicht nur :stop()'t — sonst behaelt manche info-beamer-
-- Build den Decoder-Slot weiter belegt und der FG-Load schlaegt fehl.
-- bg_yielded_state merkt sich Filename + Audio-Modus, damit
-- background_resume() die Resource beim Verlassen der Video-Folie ueber
-- update_media_slot wiederherstellen kann. Der config.json-Watch muss
-- waehrend bg_yielded_state ~= nil das BG NICHT laden — sonst greift
-- der Yield ins Leere; das wird im Watch-Handler abgefangen.
local bg_yielded_state = nil  -- {file, audio}

local function background_yield()
    if not background_slot.res then return end
    bg_yielded_state = {
        file  = background_slot.file,
        audio = background_slot.audio,
    }
    pcall(function() background_slot.res:dispose() end)
    background_slot.res, background_slot.kind = nil, nil
    background_slot.file, background_slot.audio_loaded = nil, nil
    audio_active = nil   -- Routing zwingen, neu zu evaluieren
end

local function background_resume()
    if not bg_yielded_state then return end
    local restore = bg_yielded_state
    bg_yielded_state = nil
    background_slot.audio = restore.audio
    update_media_slot(background_slot, restore.file, nil)
    audio_active = nil
end

------------------------------------------------------------
-- Konfiguration / Watch (Lua-relevante Optionen)
------------------------------------------------------------

util.file_watch("config.json", function(raw)
    local cfg = json.decode(raw)

    CONFIG.fade_duration    = tonumber(cfg.fade_duration)    or 0.5
    CONFIG.default_duration = tonumber(cfg.default_duration) or 10

    -- Audio-Stream- UND Jukebox-Zustand ZUERST lesen — beide bestimmen
    -- gemeinsam, ob das Hintergrund-Video mit oder ohne Audio-Track
    -- geladen wird (s. background_slot-Kommentar). Sobald eine der
    -- beiden Quellen aktiv ist, soll BG-Video stumm laufen (visuell
    -- durchgehend, Audio kommt von hoeher priorisierter Quelle).
    -- update_media_slot disposed+reloadet das BG-Video automatisch beim
    -- Toggle ueber den slot.audio_loaded-Vergleich.
    audio_stream.enabled = cfg.audio_stream_enabled and true or false
    audio_stream.url     = cfg.audio_stream_url or ""
    audio_stream.volume  = db_to_linear(tonumber(cfg.audio_stream_volume_db))

    -- Jukebox-Playlist parsen. Reihenfolge im Setup ist Reihenfolge
    -- der sequenziellen Wiedergabe. Leere/ungueltige Eintraege werden
    -- uebersprungen (Setup-Liste kann in info-beamer leere Slots haben).
    local new_files = {}
    if type(cfg.audio_jukebox_playlist) == "table" then
        for _, item in ipairs(cfg.audio_jukebox_playlist) do
            local name = item and resolve_resource(item.file)
            if name then
                new_files[#new_files + 1] = name
            end
        end
    end

    local new_shuffle = cfg.audio_jukebox_shuffle and true or false

    -- Aenderungen im laufenden Betrieb so schonend wie moeglich
    -- behandeln: Track laeuft weiter, wenn er noch in der Liste ist.
    local files_changed = (#new_files ~= #audio_jukebox.files)
    if not files_changed then
        for i, f in ipairs(new_files) do
            if f ~= audio_jukebox.files[i] then
                files_changed = true
                break
            end
        end
    end
    local shuffle_changed = (new_shuffle ~= audio_jukebox.shuffle)

    audio_jukebox.enabled = cfg.audio_jukebox_enabled and true or false
    audio_jukebox.shuffle = new_shuffle
    audio_jukebox.volume  = db_to_linear(tonumber(cfg.audio_jukebox_volume_db))
    audio_jukebox.files   = new_files

    if files_changed or shuffle_changed then
        rebuild_jukebox_order()
        -- Wenn der gerade gespielte Track aus der Liste entfernt wurde,
        -- direkt disposen — der Health-Check laedt dann den naechsten.
        if audio_jukebox.loaded_file then
            local still_present = false
            for _, f in ipairs(new_files) do
                if f == audio_jukebox.loaded_file then
                    still_present = true
                    break
                end
            end
            if not still_present then
                dispose_jukebox_track()
            end
        end
    end

    update_media_slot(backup_slot, cfg.backup_media, "empty.png")

    -- BG-Slot: waehrend einer Video-Folie ist das BG-Video via
    -- background_yield() disposed (Pi 3B Decoder-Engpass). Wir fuettern
    -- die neuen Werte in bg_yielded_state, damit background_resume()
    -- spaeter die richtige Resource wiederherstellt — KEIN update_media_
    -- slot, sonst kollidiert der Reload mit dem laufenden FG-Video.
    local bg_audio_now = not (audio_stream.enabled or audio_jukebox.enabled)
    if bg_yielded_state then
        bg_yielded_state.audio = bg_audio_now
        bg_yielded_state.file  = cfg.background_media
        background_slot.audio  = bg_audio_now  -- bleibt fuer spaeter konsistent
    else
        background_slot.audio = bg_audio_now
        update_media_slot(background_slot, cfg.background_media, nil)
    end

    -- Zeit-Overlay (Format und Timezone liest der Python-Service;
    -- Lua-Seite verarbeitet nur den fertigen Text aus dem
    -- data_mapper-Handler).
    time_overlay.enabled = cfg.time_enabled and true or false
    time_overlay.size    = tonumber(cfg.time_size) or 80
    time_overlay.x       = tonumber(cfg.time_x)    or 1820
    time_overlay.y       = tonumber(cfg.time_y)    or 980
    time_overlay.align   = cfg.time_align or "right"
    time_overlay.locale  = cfg.time_locale or "de"
    if type(cfg.time_color) == "table" then
        time_overlay.color = {
            r = tonumber(cfg.time_color.r) or 1,
            g = tonumber(cfg.time_color.g) or 1,
            b = tonumber(cfg.time_color.b) or 1,
            a = tonumber(cfg.time_color.a) or 1,
        }
    end
    update_time_font(resolve_resource(cfg.time_font))

    -- Cornerlogo
    corner_logo.enabled = cfg.logo_enabled and true or false
    corner_logo.x       = tonumber(cfg.logo_x) or 0
    corner_logo.y       = tonumber(cfg.logo_y) or 0
    update_corner_logo(resolve_resource(cfg.logo_image))

    -- Pegel-Änderung im laufenden Stream sofort übernehmen, ohne
    -- erst auf den nächsten Routing-Wechsel zu warten.
    -- (audio_stream.enabled/url/volume wurden weiter oben gesetzt,
    -- damit BG-Video-Reload den richtigen Audio-Modus bekommt.)
    if audio_active == "stream" and audio_stream.res then
        pcall(function() audio_stream.res:volume(audio_stream.volume) end)
    end
    if audio_active == "jukebox" and audio_jukebox.res then
        pcall(function() audio_jukebox.res:volume(audio_jukebox.volume) end)
    end

    -- Slot-Wechsel können das Audio-Ziel verändern (Disposal des
    -- aktiven Videos). Routing-Stand zurücksetzen, damit der nächste
    -- Render-Frame frisch entscheidet.
    audio_active = nil
end)

------------------------------------------------------------
-- Manifest-Watch (vom Python-Service geschrieben)
------------------------------------------------------------

-- Zeit-Text vom service-Sidecar (mit korrekter Timezone-Behandlung
-- via Python pytz). Per UDP-IPC zugestellt — keine SD-Writes.
-- Path "time" matcht das vom Service gesendete "root/time:<text>".
util.data_mapper{
    time = function(msg)
        time_overlay.text = msg or ""
    end,
}

util.json_watch("manifest.json", function(m)
    if not m then return end
    local entries = m.slides or {}

    -- Leere Playlist → IDLE (Backup wird angezeigt). Vorhandene slides
    -- bleiben erhalten, um beim nächsten Manifest-Update ggf. nahtlos
    -- weiterzumachen — gerendert werden sie in IDLE nicht.
    if #entries == 0 then
        -- Falls gerade eine Video-Folie laeuft: FG-Video wegraeumen und
        -- BG-Video reaktivieren, sonst bliebe die Decoder-Belegung
        -- bestehen und der Backup-Pfad waere visuell vom FG ueberdeckt.
        if fg_video.res then
            fg_video_unload()
            background_resume()
        end
        dispose_list(pending_slides)
        pending_slides = nil
        end_cycle_fade()
        state = STATE_IDLE
        return
    end

    -- Folien laden. Image-Slides werden sofort als GL-Texturen geladen
    -- (preload), Video-Slides nur als Metadaten — die Resource entsteht
    -- erst beim Eintritt in die Folie via fg_video_load (Lazy-Load,
    -- weil Pi 3B nur einen Decoder hat und mehrere Videos parallel
    -- nicht haltbar waeren).
    local loaded = {}
    for _, e in ipairs(entries) do
        if e.file then
            local kind = media_type_for(e, e.file)
            if kind == "video" then
                -- duration aus Manifest wird ignoriert: Video laeuft bis
                -- :state() == "finished".
                loaded[#loaded + 1] = {
                    file     = e.file,
                    kind     = "video",
                    duration = 0,
                    res      = nil,
                }
            else
                local ok, res = pcall(resource.load_image, {file = e.file})
                if ok and res then
                    loaded[#loaded + 1] = {
                        file     = e.file,
                        kind     = "image",
                        duration = tonumber(e.duration) or CONFIG.default_duration,
                        res      = res,
                    }
                else
                    print("Folie nicht ladbar: " .. tostring(e.file))
                end
            end
        end
    end

    if #loaded == 0 then return end

    dispose_list(pending_slides)
    pending_slides = loaded

    if state == STATE_IDLE then
        -- Sofort einsetzen — kein laufender Zyklus, von dem wir
        -- ausfaden müssten.
        local old = slides
        slides = pending_slides
        pending_slides = nil
        dispose_list(old)
        current_idx   = 1
        slide_started = now()
        state = STATE_PLAYING
    end
    -- Sonst: bleibt als pending; Renderer swappt am Zyklus-Ende mit
    -- Crossfade.
end)

------------------------------------------------------------
-- Renderer
------------------------------------------------------------

-- Bild auf den vollen Bildschirm strecken (kein Letterbox). Bei
-- abweichendem Seitenverhältnis verzerrt es — Folien daher in nativer
-- Display-Auflösung anliefern.
local function draw_fit(res, alpha)
    if not res then return end
    res:draw(0, 0, WIDTH, HEIGHT, alpha)
end

-- Media-Slot auf den vollen Bildschirm zeichnen. Bilder per :draw mit
-- Zielrechteck, Videos per :place (raw-Videos haben kein :draw und
-- kein :size). Beide Pfade strecken ohne Aspect-Korrektur — Backup-
-- und Hintergrund-Assets daher in nativer Display-Auflösung
-- (z. B. 1920x1080) anliefern, sonst verzerrt es.
local function draw_slot(slot, alpha)
    if not slot.res then return end
    if slot.kind == "video" then
        pcall(function() slot.res:place(0, 0, WIDTH, HEIGHT) end)
    else
        slot.res:draw(0, 0, WIDTH, HEIGHT, alpha or 1)
    end
end

-- Verstecke ein Video durch :place auf ein 0×0-Rechteck — info-beamer
-- behält sonst die letzte Platzierung bei und das Video bliebe sichtbar.
local function hide_video(slot)
    if slot.kind == "video" and slot.res then
        pcall(function() slot.res:place(0, 0, 0, 0) end)
    end
end

-- Zeit-Overlay zeichnen (wenn aktiviert und Schrift verfügbar). Nur
-- im PLAYING-Zustand aufgerufen; im IDLE-Zustand bleibt das Overlay
-- aus, damit der Backup-Inhalt klar dominiert.
--
-- Mehrzeilige Formate (\n im strftime-Format) werden auf einzelne
-- Zeilen aufgeteilt und untereinander mit Zeilenhöhe = Schriftgröße
-- gerendert. Die Ausrichtung gilt pro Zeile relativ zu time_x.
local function draw_time_overlay()
    if not time_overlay.enabled then return end
    local font = time_overlay.font_res
    if not font then return end

    local text = time_overlay.text
    if type(text) ~= "string" or text == "" then return end

    if time_overlay.locale == "de" then
        text = localize_de(text)
    end

    local lines = {}
    for line in text:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end
    if #lines == 0 then return end

    local size       = time_overlay.size
    local line_height = size  -- 1.0 line-height; ggf. später konfigurierbar
    local c          = time_overlay.color

    for i, line in ipairs(lines) do
        local x = time_overlay.x
        if time_overlay.align == "right" or time_overlay.align == "center" then
            local ok_w, w = pcall(function() return font:width(line, size) end)
            if ok_w and type(w) == "number" then
                x = (time_overlay.align == "right") and (x - w) or (x - w / 2)
            end
        end
        local y = time_overlay.y + (i - 1) * line_height
        pcall(function()
            font:write(x, y, line, size, c.r, c.g, c.b, c.a)
        end)
    end
end

-- Cornerlogo zeichnen — wird IMMER zuletzt gezeichnet, also über
-- Folien, Backup-Bild UND Zeit-Overlay. Bei Backup-Video liegt das
-- Logo auf der GL-Surface oberhalb des raw-Videos.
--
-- Bild in Originalgröße bei (x, y) zeichnen. Vollformatige Logos
-- (Display-Auflösung, Position via Transparenz) füllen bei (0, 0)
-- automatisch den ganzen Bildschirm. image:size() liefert Pixelmaße;
-- Fallback auf Vollbild, falls die Abfrage scheitert (z. B. Resource
-- noch im "loading"-Zustand).
local function draw_corner_logo()
    if not corner_logo.enabled or not corner_logo.res then return end

    local ok, w, h = pcall(function() return corner_logo.res:size() end)
    if ok and type(w) == "number" and type(h) == "number" then
        local x, y = corner_logo.x, corner_logo.y
        corner_logo.res:draw(x, y, x + w, y + h, 1)
    else
        corner_logo.res:draw(0, 0, WIDTH, HEIGHT, 1)
    end
end

function node.render()
    check_audio_stream_health()
    check_audio_jukebox_health()
    update_audio_routing()

    local t = now()
    -- Transparent clearen, damit raw-Videos auf negativen Layers durch
    -- transparente Folien-Pixel hindurchscheinen können. Wo nichts auf
    -- der GL-Surface gezeichnet wird, ist sie durchsichtig — und gibt
    -- den Blick auf die Video-Ebenen darunter frei.
    gl.clear(0, 0, 0, 0)

    if state == STATE_IDLE then
        -- Defensiv: falls IDLE betreten wurde, ohne dass die ueblichen
        -- State-Transition-Pfade FG-Cleanup gelaufen sind (z. B. bei
        -- erstem Render-Frame nach Knoten-Start mit altem fg_video-
        -- State waere ohnehin alles nil — der Block kostet nichts).
        if fg_video.res then
            fg_video_unload()
            background_resume()
        end
        if backup_slot.kind == "video" and backup_slot.res then
            -- Backup-Video übernimmt voll: das Video liegt auf Layer -2
            -- hinter der (transparenten) GL-Surface und überdeckt das
            -- Hintergrund-Video auf Layer -3. Wir zeichnen weder
            -- Hintergrund-Bild noch sonst etwas auf GL, damit das
            -- Backup-Video sichtbar bleibt.
            pcall(function() backup_slot.res:place(0, 0, WIDTH, HEIGHT) end)
        else
            -- Backup-Bild (oder leerer Slot): Hintergrund zuerst,
            -- danach Backup-Bild darüber. Bei transparenten Pixeln
            -- des Backup-Bildes scheint der Hintergrund durch.
            draw_slot(background_slot, 1)
            if backup_slot.kind == "image" and backup_slot.res then
                backup_slot.res:draw(0, 0, WIDTH, HEIGHT, 1)
            end
        end
        -- Cornerlogo IMMER ganz oben (auch im Backup-Zustand).
        draw_corner_logo()
        last_cur = nil
        return
    end

    -- PLAYING
    if #slides == 0 then
        if fg_video.res then
            fg_video_unload()
            background_resume()
        end
        last_cur = nil
        state = STATE_IDLE
        return
    end

    local cur = slides[current_idx]
    -- Image-Slides muessen eine geladene Resource haben (sonst Loader-
    -- Fehler und sie waeren nicht in slides[] gelandet). Video-Slides
    -- haben legitimerweise res=nil — die Resource entsteht erst durch
    -- fg_video_load weiter unten.
    if not cur then
        if fg_video.res then
            fg_video_unload()
            background_resume()
        end
        last_cur = nil
        state = STATE_IDLE
        return
    end

    -- Hintergrund: Video :place auf Layer -3 (durchscheinend hinter
    -- transparenten Folien-Pixeln), Bild direkt auf GL (von Folien
    -- überdeckt, scheint durch transparente Folien-Pixel hindurch).
    -- Waehrend einer Video-Folie ist background_slot via
    -- background_yield() disposed — draw_slot wird dann zum No-op.
    draw_slot(background_slot, 1)

    -- Backup-Video off-screen verstecken — sonst würde sein Standbild
    -- auf Layer -2 das Hintergrund-Video durch die transparenten
    -- Folien-Pixel hindurch überdecken.
    hide_video(backup_slot)

    local fade_dur = math.max(0, CONFIG.fade_duration)
    local elapsed  = t - slide_started

    -- Advance-Entscheidung. Bei Image-Slides timer-basiert (mind.
    -- fade_dur lang sichtbar, sonst kein vollstaendiger Out-Fade), bei
    -- Video-Slides am Decoder-State festgemacht: das Video laeuft bis
    -- "finished", dann wechseln wir. Manifest-duration wird fuer Videos
    -- ignoriert. "error" behandeln wir wie "finished" — eine kaputte
    -- Folie soll nicht den Zyklus blockieren.
    local should_advance
    if cur.kind == "video" then
        if fg_video.res then
            local ok, st = pcall(function() return fg_video.res:state() end)
            should_advance = ok and (st == "finished" or st == "error")
        else
            -- Load fehlgeschlagen oder noch nicht erfolgt; ueberspringen,
            -- aber nur wenn der Slide-Wechsel-Hook bereits gelaufen ist
            -- (sonst skippen wir die Folie noch vor dem Lade-Versuch).
            should_advance = (cur == last_cur)
        end
    else
        local cur_dur = math.max(cur.duration, fade_dur)
        should_advance = (elapsed >= cur_dur)
    end

    -- Advance ZUERST. Beim Zyklus-Ende setzt das outgoing — der
    -- Cycle-Fade-Check muss DANACH laufen, damit die Crossfade direkt
    -- im selben Frame anlaeuft. Sonst entstuende ein Single-Frame-
    -- Flackern, in dem die naechste Folie kurz allein sichtbar ist,
    -- bevor das Cycle-Crossfade im Folgeframe startet.
    if should_advance then
        if current_idx >= #slides then
            -- Zyklus-Ende: outgoing erfassen, ggf. pending einsetzen.
            set_outgoing(cur)
            if pending_slides then
                swap_slides(pending_slides)
                pending_slides = nil
            end
            current_idx = 1
        else
            current_idx = current_idx + 1
        end
        slide_started = t
        cur           = slides[current_idx]
        elapsed       = 0
    end

    -- Slide-Wechsel-Hook: Video-Folien benoetigen explizite Decoder-
    -- Koordination (BG yield/resume) und Lazy-Load. Wird auch beim
    -- ersten Frame nach IDLE→PLAYING aktiv (last_cur ist dann nil bzw.
    -- zeigt auf eine alte Folie).
    if cur ~= last_cur then
        if cur.kind == "video" then
            background_yield()
            fg_video_load(cur)
        elseif last_cur and last_cur.kind == "video" then
            fg_video_unload()
            background_resume()
        end
        last_cur = cur
    end

    if cur.kind == "video" then
        -- Hard-Cut zur Video-Folie: laufenden Cycle-Fade verwerfen,
        -- GL-Surface bleibt transparent (Folie wird NICHT gezeichnet),
        -- damit das FG-Video auf Layer -1 voll sichtbar ist.
        end_cycle_fade()
        if fg_video.res then
            pcall(function() fg_video.res:place(0, 0, WIDTH, HEIGHT) end)
        end
    else
        -- Image-Pfad. Crossfade nur Image↔Image — Outgoing oder Nachfolger
        -- als Video → Hard-Cut (kein Shader-Sample auf raw-Videos
        -- moeglich).
        local slide_drawn = false
        if outgoing then
            local cycle_elapsed = t - cycle_fade_start
            local can_fade = (outgoing.kind == "image")
            if can_fade and fade_dur > 0 and cycle_elapsed < fade_dur then
                local progress = cycle_elapsed / fade_dur
                draw_crossfade(outgoing.res, cur.res, progress)
                slide_drawn = true
            else
                end_cycle_fade()
            end
        end

        if not slide_drawn then
            local cur_dur = math.max(cur.duration, fade_dur)
            local fade_at = cur_dur - fade_dur
            local nxt     = slides[current_idx + 1]
            if nxt and nxt.kind == "image"
               and fade_dur > 0 and elapsed >= fade_at
               and current_idx < #slides then
                local progress = math.min(1, (elapsed - fade_at) / fade_dur)
                draw_crossfade(cur.res, nxt.res, progress)
            else
                draw_fit(cur.res, 1)
            end
        end
    end

    -- Zeit-Overlay über den Folien (in IDLE wird es ohnehin nicht
    -- aufgerufen, da das frühe return im IDLE-Branch bereits gezogen
    -- hat — somit bleibt die "hinter dem Backup-Layer"-Semantik
    -- erhalten). Liegt auf der GL-Surface (Layer 0) und ist somit auch
    -- ueber FG-Video-Folien (Layer -1) sichtbar.
    draw_time_overlay()

    -- Cornerlogo IMMER ganz oben.
    draw_corner_logo()
end
