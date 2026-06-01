#!/bin/bash
# presentation-manager.sh — obsługa prezentacji PowerPoint z udziału SMB
#
# Działanie:
#   1. Czeka na zamontowanie udziału SMB
#   2. Sprawdza obecność pliku $SMB_MOUNT/terminal_live.pptx
#   3. Wyświetla prezentację bezpośrednio przez LibreOffice Impress (--show)
#      → zachowane animacje, przejścia i efekty z oryginalnego pliku PPTX
#   4. Po zakończeniu pokazu automatycznie restartuje (pętla)
#   5. Co 5 sekund sprawdza, czy plik się zmienił — jeśli tak, restartuje pokaz

SMB_MOUNT="/mnt/presentation"
SMB_SOURCE="//192.168.40.201/DatyFirmowe"
SMB_OPTS="credentials=/etc/samba/kiosk-credentials,uid=kiosk,gid=kiosk,vers=3.0"
PRESENTATION_FILE="$SMB_MOUNT/terminal_live.pptx"
# Lokalna kopia PPTX — LibreOffice otwiera ten plik zamiast pliku z SMB.
# Dzięki temu SMB nie jest blokowany i można nadpisać terminal_live.pptx
# w dowolnej chwili z innego komputera (Windows/macOS/Linux).
LOCAL_PRESENTATION="/tmp/kiosk-live.pptx"

# Konfiguracja ekranu: szerokość używana do rozróżnienia widocznego obszaru od obszaru ukrytego
ONE_SCREEN=${ONE_SCREEN:-1}
SCREEN_WIDTH=${SCREEN_WIDTH:-${RES_W:-1920}}
RES_W=${RES_W:-$SCREEN_WIDTH}
RES_H=${RES_H:-1080}
OFFSCREEN_X=$((SCREEN_WIDTH * 2))

CURRENT_MTIME=""
LO_PID=""
WATCHDOG_PID=""

# Usuń stary plik sygnałowy (restart serwisu)
rm -f /tmp/kiosk-smb-ready

# Odmontuj udział przy zamknięciu skryptu
trap 'stop_lo; kill "${WATCHDOG_PID:-0}" 2>/dev/null; umount "$SMB_MOUNT" 2>/dev/null' EXIT INT TERM

stop_lo() {
    if [ -n "${LO_PID:-}" ] && kill -0 "$LO_PID" 2>/dev/null; then
        kill "$LO_PID"
        wait "$LO_PID" 2>/dev/null
        LO_PID=""
    fi
}

# Persistentny watchdog co 0.3s — przenosi konsolę LO poza ekran zanim stanie się widoczna.
# Działa przez cały czas życia skryptu. Fullscreen i Chromium above obsługuje start_lo().
console_watchdog() {
    while true; do
        sleep 0.3
        for _wid in $(xdotool search --class soffice --onlyvisible 2>/dev/null); do
            _wx=$(xdotool getwindowgeometry "$_wid" 2>/dev/null \
                  | awk '/Position:/{split($2,a,","); print a[1]+0}')
            if [ "${_wx:-0}" -lt "$SCREEN_WIDTH" ]; then
                wmctrl -i -r "$_wid" -b remove,above 2>/dev/null
                wmctrl -i -r "$_wid" -b add,below    2>/dev/null
                xdotool windowmove --sync "$_wid" "$OFFSCREEN_X" 0 2>/dev/null
                echo "[watchdog] Konsola ukryta (WID=$_wid, x=${_wx:-?})"
            fi
        done
    done
}

start_lo() {
    stop_lo
    # Usuń plik blokady LO — pozostaje po kill i blokuje kolejne uruchomienie
    rm -f /tmp/.~lock.kiosk-live.pptx\#

    # Wyłącz konsolę prezentera — zapisujemy tuż przed uruchomieniem LO,
    # żeby mieć pewność że dotyczy bieżącego profilu ($HOME może być /root)
    _LO_PROFILE="$HOME/.config/libreoffice/4/user"
    mkdir -p "$_LO_PROFILE"
    cat > "$_LO_PROFILE/registrymodifications.xcu" << 'XCUEOF'
<?xml version="1.0" encoding="UTF-8"?>
<oor:items xmlns:oor="http://openoffice.org/2001/registry"
           xmlns:xs="http://www.w3.org/2001/XMLSchema"
           xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <item oor:path="/org.openoffice.Office.Impress/Misc">
    <prop oor:name="StartWithPresenterScreen" oor:op="fuse">
      <value>false</value>
    </prop>
  </item>
</oor:items>
XCUEOF

    echo "[presentation-manager] Kopiowanie pliku z SMB do /tmp..."
    cp "$PRESENTATION_FILE" "$LOCAL_PRESENTATION" || {
        echo "[presentation-manager] Błąd kopiowania pliku — retry za 5s"
        sleep 5
        return 1
    }
    echo "[presentation-manager] Uruchamianie pokazu: $LOCAL_PRESENTATION"
    # --show otwiera bezpośrednio pokaz (bez Start Center)
    soffice \
        --norestore \
        --nofirststartwizard \
        --show "$LOCAL_PRESENTATION" &
    LO_PID=$!
    echo "[presentation-manager] LibreOffice Impress uruchomiony (PID=$LO_PID)"

    # Obsłuż wszystkie okna LO wg pozycji:
    #   x >= SCREEN_WIDTH  → okno pokazu slajdów → fullscreen
    #   x <  SCREEN_WIDTH  → konsola prezentacji → przeniesienie poza obszar widoczny
    # Fallback po 5s: przenieś pierwsze znalezione okno do widocznego obszaru
    (
        for _i in $(seq 1 30); do
            sleep 1
            WIDS=$(xdotool search --pid "$LO_PID" --onlyvisible 2>/dev/null)
            [ -z "$WIDS" ] && WIDS=$(xdotool search --class soffice --onlyvisible 2>/dev/null)
            [ -z "$WIDS" ] && continue

            PRES_WID=""
            for WID in $WIDS; do
                WIN_X=$(xdotool getwindowgeometry "$WID" 2>/dev/null \
                        | awk '/Position:/{split($2,a,","); print a[1]+0}')
                if [ "${WIN_X:-0}" -ge "$SCREEN_WIDTH" ]; then
                    PRES_WID=$WID
                fi
                # Konsola (x<1920) obsługiwana przez console_watchdog()
            done

            if [ -n "$PRES_WID" ]; then
                wmctrl -i -r "$PRES_WID" -b add,fullscreen 2>/dev/null
                echo "[presentation-manager] Pokaz fullscreen (próba $_i)"
                break
            fi

            # Fallback: po 5s nadal brak okna do fullscreen → przenieś pierwsze
            if [ "$_i" -ge 5 ]; then
                FIRST_WID=$(echo "$WIDS" | head -1)
                if [ -n "$FIRST_WID" ]; then
                    wmctrl -i -r "$FIRST_WID" -b remove,fullscreen 2>/dev/null
                    sleep 0.3
                    # Jeśli tryb jednokanałowy — ustaw na 0,0
                    TARGET_X=0
                    xdotool windowmove --sync "$FIRST_WID" "$TARGET_X" 0
                    xdotool windowsize --sync "$FIRST_WID" "$RES_W" "$RES_H"
                    wmctrl -i -r "$FIRST_WID" -b add,fullscreen 2>/dev/null
                    echo "[presentation-manager] Fallback: przeniesiono okno (próba $_i, x=$TARGET_X)"
                    break
                fi
            fi
        done

        # Podnieś Chromium na wierzch lewego ekranu (przykrywa konsolę jeśli się pojawiła)
        sleep 1
        CHROMIUM_WID=$(xdotool search --class chromium --onlyvisible 2>/dev/null | head -1)
        if [ -n "$CHROMIUM_WID" ]; then
            xdotool windowraise "$CHROMIUM_WID"
            wmctrl -i -r "$CHROMIUM_WID" -b add,above
            echo "[presentation-manager] Chromium always-on-top (above)"
        fi
    ) &
}

# ─── GŁÓWNA LOGIKA ───────────────────────────────────────────────────────────

echo "[presentation-manager] Montowanie udziału SMB: $SMB_SOURCE"
until mountpoint -q "$SMB_MOUNT" 2>/dev/null; do
    mount "$SMB_MOUNT" 2>&1 \
        | sed 's/^/[presentation-manager] mount: /'
    mountpoint -q "$SMB_MOUNT" 2>/dev/null || sleep 5
done
echo "[presentation-manager] SMB zamontowany."

# Synchronizuj czcionki z udziału SMB do katalogu użytkownika kiosk.
# Fontconfig i LibreOffice odczytują ~/.local/share/fonts/ bez uprawnień roota.
# Wystarczy wrzucić nowe pliki .ttf/.otf do $SMB_MOUNT/fonts/ — zostaną
# automatycznie zainstalowane przy następnym starcie kiosku.
FONTS_SRC="$SMB_MOUNT/fonts"
FONTS_DST="/home/kiosk/.local/share/fonts/smb"
if [ -d "$FONTS_SRC" ]; then
    mkdir -p "$FONTS_DST"
    FONTS_NEW=0
    for _f in "$FONTS_SRC"/*.ttf "$FONTS_SRC"/*.otf "$FONTS_SRC"/*.TTF "$FONTS_SRC"/*.OTF; do
        [ -f "$_f" ] || continue
        _dest="$FONTS_DST/$(basename "$_f")"
        if [ ! -f "$_dest" ]; then
            cp "$_f" "$_dest" 2>/dev/null && FONTS_NEW=1
            echo "[presentation-manager] Nowa czcionka: $(basename "$_f")"
        fi
    done
    if [ "$FONTS_NEW" -eq 1 ]; then
        fc-cache "$FONTS_DST"
        echo "[presentation-manager] Cache czcionek zaktualizowany"
    fi
fi

# Sygnał dla kiosk-manager.sh: SMB zamontowany, można przełączyć Chromium
touch /tmp/kiosk-smb-ready
echo "[presentation-manager] SMB gotowy — sygnał wysłany"

until [ -f "$PRESENTATION_FILE" ]; do
    echo "[presentation-manager] Oczekiwanie na plik: $PRESENTATION_FILE" >&2
    sleep 5
done

# Uruchom persistentny watchdog przed pierwszym startem LO
console_watchdog &
WATCHDOG_PID=$!
echo "[presentation-manager] Watchdog uruchomiony (PID=$WATCHDOG_PID)"

CURRENT_MTIME=$(stat -c %Y "$PRESENTATION_FILE" 2>/dev/null || echo "0")
start_lo

# Pętla: restartuje pokaz po zakończeniu lub gdy wykryje zmianę pliku
while true; do
    sleep 5

    NEW_MTIME=$(stat -c %Y "$PRESENTATION_FILE" 2>/dev/null || echo "0")

    # Plik zmieniony — odśwież pokaz
    if [ "$NEW_MTIME" != "$CURRENT_MTIME" ]; then
        echo "[presentation-manager] Wykryto zmianę pliku — restart pokazu"
        CURRENT_MTIME="$NEW_MTIME"
        start_lo
        # Po 5 s wyślij sygnał do kiosk-manager.sh — restartuje Chromium po tym jak LO
        # zakończy ładowanie i ustawi okno pokazu
        ( sleep 5
          touch /tmp/kiosk-chromium-restart
          echo "[presentation-manager] Sygnał restart Chromium wysłany"
        ) &
        continue
    fi

    # LibreOffice zakończył (koniec pokazu) — uruchom ponownie
    if ! kill -0 "${LO_PID:-0}" 2>/dev/null; then
        echo "[presentation-manager] Pokaz zakończony — restart"
        start_lo
    fi
done
