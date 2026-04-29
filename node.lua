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
-- Bilder funktionieren auf jedem Pi; Video-Loops setzen Pi 4+ voraus
-- (raw=true GL-Pipeline).
--
-- Audio-Routing (Audio ist load-time-only in info-beamer; pause/start
-- schaltet zwischen Quellen):
--   * Normalbetrieb (PLAYING): Audio des Hintergrund-Videos.
--   * Backup-Zustand (IDLE) mit Backup-VIDEO: Audio des Backup-Videos.
--   * Backup-Zustand mit Backup-BILD: Audio des Hintergrund-Videos
--     läuft weiter, das Backup-Bild liegt nur visuell darüber.

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
-- Backup auf höherer (= weniger negativer) Ebene als Background, damit
-- es im IDLE-Zustand das Hintergrund-Video überdeckt.
local backup_slot     = { res = nil, kind = nil, file = nil, label = "Backup-Inhalt",     layer = -1 }
local background_slot = { res = nil, kind = nil, file = nil, label = "Hintergrund-Inhalt", layer = -2 }

-- Optionales Zeit-Overlay. Wird im PLAYING-Zustand über den Folien
-- gezeichnet, im IDLE-Zustand vom Backup-Layer überdeckt (durch
-- Render-Reihenfolge). Erfordert ein per Setup hochgeladenes Font-
-- Asset; ohne Schrift wird das Overlay übersprungen.
local time_overlay = {
    enabled   = false,
    format    = "%H:%M",
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
local slides         = {}     -- [{file, duration, res}, ...]
local current_idx    = 1
local slide_started  = 0
local pending_slides = nil    -- nächste Liste, swap am Zyklus-Ende

-- Zyklus-Crossfade (letzte Folie alt → erste Folie neu).
local outgoing         = nil   -- nil oder {res, dispose_after}
local cycle_fade_start = 0

-- Audio-Routing-Status: "background" | "backup" | "stream" | nil
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
-- raw=true (GL-Pipeline) und audio=true geladen; paused=true, weil
-- update_audio_routing entscheidet, wer aktiv abspielt — nur eine
-- Audio-Quelle gleichzeitig. Auf Pi 3 schlägt raw-Video fehl, der
-- pcall-Aufruf liefert ok=false.
local function load_media(name, kind)
    if kind == "video" then
        return pcall(resource.load_video, {
            file   = name,
            looped = true,
            raw    = true,
            audio  = true,
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
-- über den Hintergrund-Layer ist dann mathematisch korrekt für
-- alle Transparenz-Kombinationen.

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
            vec4 a_pre = vec4(a.rgb * a.a, a.a);
            vec4 b_pre = vec4(b.rgb * b.a, b.a);
            vec4 r_pre = mix(a_pre, b_pre, progress);
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

local function update_audio_routing()
    local target
    if state == STATE_IDLE
       and backup_slot.kind == "video" and backup_slot.res then
        target = "backup"
    elseif audio_stream.enabled and audio_stream.res then
        target = "stream"
    elseif background_slot.kind == "video" and background_slot.res then
        target = "background"
    else
        target = nil
    end

    if target == audio_active then return end

    -- Aktive Quelle stoppen. Beim Stream nur Volume auf 0 ziehen —
    -- nicht :stop()/:dispose(), damit der Decoder verbunden bleibt
    -- und der nächste Wechsel ohne Reconnect-Latenz hörbar ist.
    if audio_active == "background" then
        video_pause(background_slot)
    elseif audio_active == "backup" then
        video_pause(backup_slot)
    elseif audio_active == "stream" and audio_stream.res then
        pcall(function() audio_stream.res:volume(0) end)
    end

    -- Neue Quelle starten.
    if target == "background" then
        video_play(background_slot)
    elseif target == "backup" then
        video_play(backup_slot)
    elseif target == "stream" and audio_stream.res then
        pcall(function() audio_stream.res:volume(audio_stream.volume) end)
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

    if name == slot.file then return end

    if slot.res then
        pcall(function() slot.res:dispose() end)
    end
    slot.res, slot.kind, slot.file = nil, nil, name

    if not name then return end

    local kind = media_type_for(cfg_value, name)
    local ok, r = load_media(name, kind)
    if ok and r then
        slot.res, slot.kind = r, kind
        -- raw-Video hinter die GL-Surface legen, damit transparente
        -- Folien-Pixel das Video durchscheinen lassen können.
        if kind == "video" and slot.layer ~= nil then
            pcall(function() r:layer(slot.layer) end)
        end
    else
        local hint = (kind == "video") and " (Video-Loop benötigt Pi 4+)" or ""
        print(slot.label .. " nicht ladbar: " .. name .. hint)
    end
end

------------------------------------------------------------
-- Konfiguration / Watch (Lua-relevante Optionen)
------------------------------------------------------------

util.file_watch("config.json", function(raw)
    local cfg = json.decode(raw)

    CONFIG.fade_duration    = tonumber(cfg.fade_duration)    or 0.5
    CONFIG.default_duration = tonumber(cfg.default_duration) or 10

    update_media_slot(backup_slot,     cfg.backup_media,     "empty.png")
    update_media_slot(background_slot, cfg.background_media, nil)

    -- Zeit-Overlay
    time_overlay.enabled = cfg.time_enabled and true or false
    time_overlay.format  = (type(cfg.time_format) == "string"
                            and cfg.time_format ~= "")
                           and cfg.time_format or "%H:%M"
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

    -- Audio-Stream (Icecast/HTTP). check_audio_stream_health im Render
    -- erkennt URL-Änderungen und lädt entsprechend neu.
    audio_stream.enabled = cfg.audio_stream_enabled and true or false
    audio_stream.url     = cfg.audio_stream_url or ""
    audio_stream.volume  = db_to_linear(tonumber(cfg.audio_stream_volume_db))
    -- Pegel-Änderung im laufenden Stream sofort übernehmen, ohne
    -- erst auf den nächsten Routing-Wechsel zu warten.
    if audio_active == "stream" and audio_stream.res then
        pcall(function() audio_stream.res:volume(audio_stream.volume) end)
    end

    -- Slot-Wechsel können das Audio-Ziel verändern (Disposal des
    -- aktiven Videos). Routing-Stand zurücksetzen, damit der nächste
    -- Render-Frame frisch entscheidet.
    audio_active = nil
end)

------------------------------------------------------------
-- Manifest-Watch (vom Python-Service geschrieben)
------------------------------------------------------------

util.json_watch("manifest.json", function(m)
    if not m then return end
    local entries = m.slides or {}

    -- Leere Playlist → IDLE (Backup wird angezeigt). Vorhandene slides
    -- bleiben erhalten, um beim nächsten Manifest-Update ggf. nahtlos
    -- weiterzumachen — gerendert werden sie in IDLE nicht.
    if #entries == 0 then
        dispose_list(pending_slides)
        pending_slides = nil
        end_cycle_fade()
        state = STATE_IDLE
        return
    end

    -- Folien laden.
    local loaded = {}
    for _, e in ipairs(entries) do
        if e.file then
            local ok, res = pcall(resource.load_image, {file = e.file})
            if ok and res then
                loaded[#loaded + 1] = {
                    file     = e.file,
                    duration = tonumber(e.duration) or CONFIG.default_duration,
                    res      = res,
                }
            else
                print("Folie nicht ladbar: " .. tostring(e.file))
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
local function draw_time_overlay()
    if not time_overlay.enabled then return end
    local font = time_overlay.font_res
    if not font then return end

    local ok_t, text = pcall(os.date, time_overlay.format)
    if not ok_t or type(text) ~= "string" or text == "" then return end

    if time_overlay.locale == "de" then
        text = localize_de(text)
    end

    local x = time_overlay.x
    if time_overlay.align == "right" or time_overlay.align == "center" then
        local ok_w, w = pcall(function()
            return font:width(text, time_overlay.size)
        end)
        if ok_w and type(w) == "number" then
            x = (time_overlay.align == "right") and (x - w) or (x - w / 2)
        end
    end

    local c = time_overlay.color
    pcall(function()
        font:write(x, time_overlay.y, text, time_overlay.size,
                   c.r, c.g, c.b, c.a)
    end)
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
    update_audio_routing()

    local t = now()
    -- Transparent clearen, damit raw-Videos auf negativen Layers durch
    -- transparente Folien-Pixel hindurchscheinen können. Wo nichts auf
    -- der GL-Surface gezeichnet wird, ist sie durchsichtig — und gibt
    -- den Blick auf die Video-Ebenen darunter frei.
    gl.clear(0, 0, 0, 0)

    if state == STATE_IDLE then
        if backup_slot.kind == "video" and backup_slot.res then
            -- Backup-Video übernimmt voll: das Video liegt auf Layer -1
            -- hinter der (transparenten) GL-Surface und überdeckt das
            -- Hintergrund-Video auf Layer -2. Wir zeichnen weder
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
        return
    end

    -- PLAYING
    if #slides == 0 then
        state = STATE_IDLE
        return
    end

    local cur = slides[current_idx]
    if not cur or not cur.res then
        state = STATE_IDLE
        return
    end

    -- Hintergrund: Video :place auf Layer -2 (durchscheinend hinter
    -- transparenten Folien-Pixeln), Bild direkt auf GL (von Folien
    -- überdeckt, scheint durch transparente Folien-Pixel hindurch).
    draw_slot(background_slot, 1)

    -- Backup-Video off-screen verstecken — sonst würde sein Standbild
    -- auf Layer -1 das Hintergrund-Video durch die transparenten
    -- Folien-Pixel hindurch überdecken.
    hide_video(backup_slot)

    local fade_dur = math.max(0, CONFIG.fade_duration)

    -- Eine Folie muss mindestens fade_dur lang "current" sein, sonst
    -- bleibt fuer den Crossfade auf die naechste Folie keine Zeit. Bei
    -- duration=0 (oder duration < fade_dur) wuerde der Advance sofort
    -- nach dem Eintritt ausloesen und den Out-Fade ueberspringen — die
    -- naechste Folie poppt dann hart rein. Mit max(duration, fade_dur)
    -- spielt der Crossfade immer komplett.
    local cur_dur = math.max(cur.duration, fade_dur)
    local elapsed = t - slide_started

    -- Advance ZUERST. Beim Zyklus-Ende setzt das outgoing — der
    -- Cycle-Fade-Check muss DANACH laufen, damit die Crossfade direkt
    -- im selben Frame anlaeuft. Sonst entstuende ein Single-Frame-
    -- Flackern, in dem die naechste Folie kurz allein sichtbar ist,
    -- bevor das Cycle-Crossfade im Folgeframe startet.
    if elapsed >= cur_dur then
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
        cur_dur       = math.max(cur.duration, fade_dur)
        elapsed       = 0
    end

    -- Zyklus-Crossfade: outgoing (letzte Folie alt) ausblenden, cur
    -- (erste Folie neu) einblenden. Greift sowohl bei laufendem Fade
    -- aus vorigen Frames als auch im Frame, in dem advance gerade
    -- outgoing gesetzt hat (cycle_elapsed = 0 → progress = 0 →
    -- outgoing voll sichtbar, cur unsichtbar — keine harte Folge).
    local slide_drawn = false
    if outgoing then
        local cycle_elapsed = t - cycle_fade_start
        if fade_dur > 0 and cycle_elapsed < fade_dur then
            local progress = cycle_elapsed / fade_dur
            draw_crossfade(outgoing.res, cur.res, progress)
            slide_drawn = true
        else
            end_cycle_fade()
        end
    end

    if not slide_drawn then
        -- Intra-Zyklus-Crossfade oder einfache Folie.
        local fade_at = cur_dur - fade_dur
        if fade_dur > 0 and elapsed >= fade_at and current_idx < #slides then
            local nxt      = slides[current_idx + 1]
            local progress = math.min(1, (elapsed - fade_at) / fade_dur)
            draw_crossfade(cur.res, nxt.res, progress)
        else
            draw_fit(cur.res, 1)
        end
    end

    -- Zeit-Overlay über den Folien (in IDLE wird es ohnehin nicht
    -- aufgerufen, da das frühe return im IDLE-Branch bereits gezogen
    -- hat — somit bleibt die "hinter dem Backup-Layer"-Semantik
    -- erhalten).
    draw_time_overlay()

    -- Cornerlogo IMMER ganz oben.
    draw_corner_logo()
end
