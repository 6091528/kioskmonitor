#!/bin/bash
# kiosk-manager.sh — konfiguracja X11 + lewy ekran: Chromium
# Plik docelowy: /home/kiosk/kiosk-manager.sh

# Jawnie ustawiamy HOME — serwis może startować jako root (xinit bez User=kiosk),
# a LibreOffice szuka profilu w $HOME/.config/libreoffice/ (nie w /home/kiosk/).
# Wszystkie procesy potomne (soffice, chromium) dziedziczą tę wartość.
export HOME=/home/kiosk

KIOSK_HOST="diluals31"
KIOSK_URL="http://diluals31/terminal/ift/5/DE/index"
WAITING_PAGE="file:///home/kiosk/waiting.html"

OUTPUT_LEFT="DP-1"
OUTPUT_RIGHT="HDMI-1"
RES_W=1920
RES_H=1080

# ─── Niewidoczny kursor ──────────────────────────────────────────────────────
# Tworzymy motyw XCursor (1x1 px, ARGB 0x00000000) i eksportujemy XCURSOR_THEME
# zanim uruchomią się Chromium i LibreOffice — dziedziczą środowisko procesu.
# Brak myszy w kiosku nie usuwa kursora X11; bez tego wskaźnik jest widoczny
# w środku między ekranami (domyślna pozycja X11 = centrum wirtualnego desktopa).
_BLANK_DIR="/home/kiosk/.icons/blank/cursors"
mkdir -p "$_BLANK_DIR"
# printf pisze binarnie bezpośrednio do pliku — nie przez zmienną (bash $() ucina null-byte'y)
for _n in left_ptr default pointer crosshair text watch wait move size_all fleur; do
    printf '\x58\x63\x75\x72\x10\x00\x00\x00\x00\x00\x01\x00\x01\x00\x00\x00\x02\x00\xfd\xff\x01\x00\x00\x00\x1c\x00\x00\x00\x24\x00\x00\x00\x02\x00\xfd\xff\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x32\x00\x00\x00\x00\x00\x00\x00' > "$_BLANK_DIR/$_n"
done
printf '[Icon Theme]\nName=blank\n' > /home/kiosk/.icons/blank/index.theme
export XCURSOR_THEME=blank
export XCURSOR_SIZE=1



# Dual-screen rozszerzony: lewy ekran primary, prawy po prawej
# --auto wykrywa tryb automatycznie (bezpieczniejsze niż --mode 1920x1080)
xrandr --output "$OUTPUT_LEFT" --auto --primary --pos 0x0
xrandr --output "$OUTPUT_RIGHT" --auto --right-of "$OUTPUT_LEFT"
# Rozszerz wirtualny framebuffer 200 px poniżej ekranów — kursor trafi w ten obszar
# i nie będzie widoczny na żadnym fizycznym monitorze (bez potrzeby dodatkowych pakietów)
xrandr --fb "$((RES_W * 2))x$((RES_H + 200))"
echo "[kiosk-manager] Konfiguracja xrandr:"
xrandr | grep -E "connected|[0-9]+x[0-9]+\+"

# Czarne tło na obu ekranach
xsetroot -solid black

# Wyłącz wygaszacz ekranu i DPMS (kiosk działa non-stop)
xset s off
xset -dpms
xset s noblank

# Przesuń kursor poniżej fizycznych ekranów — w obszar framebuffera bez outputu
# Kursor istnieje w X11, ale nie jest wyświetlany na żadnym monitorze
xdotool mousemove "$RES_W" "$((RES_H + 100))"

# Uruchom lekki WM — wymagany do per-screen fullscreen przez wmctrl
openbox --sm-disable &
sleep 0.5

# Konfiguracja LibreOffice Impress: wyłącz presenter console, pokaz na ekranie 1 (HDMI-1)
# Nadpisujemy przy każdym starcie — profil kiosku nie wymaga ochrony
LO_PROFILE="$HOME/.config/libreoffice/4/user"
mkdir -p "$LO_PROFILE"
cat > "$LO_PROFILE/registrymodifications.xcu" << 'XCUEOF'
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

# ─── Start aplikacji ─────────────────────────────────────────────────────────

# Uruchom menedżera prezentacji w tle (prawy ekran)
/home/kiosk/presentation-manager.sh &

# Watchdog sesji: ukrywa okna konsoli LibreOffice przez cały czas trwania sesji X.
# Uruchomiony tu — nie czeka na SMB, działa od startu X niezależnie od timing'u LO.
(
    while sleep 0.4; do
        for _wid in $(xdotool search --class soffice --onlyvisible 2>/dev/null); do
            _wx=$(xdotool getwindowgeometry "$_wid" 2>/dev/null \
                  | awk '/Position:/{split($2,a,","); print a[1]+0}')
            if [ "${_wx:-0}" -lt 1920 ]; then
                wmctrl -i -r "$_wid" -b remove,above 2>/dev/null
                wmctrl -i -r "$_wid" -b add,below    2>/dev/null
                xdotool windowmove --sync "$_wid" 4000 0 2>/dev/null
                echo "[kiosk-manager/watchdog] Konsola LO ukryta (WID=$_wid, x=${_wx:-?})"
            fi
        done
    done
) &

# ─── START PREZENTACJI ───────────────────────────────────────────────────────
/home/kiosk/presentation-manager.sh &

# ─── WAITING SCREEN ──────────────────────────────────────────────────────────
chromium --app="$WAITING_PAGE" \
    --window-position=0,0 \
    --window-size=${RES_W},${RES_H} \
    --no-first-run \
    --disable-infobars \
    --disable-session-crashed-bubble &

CHROMIUM_PID=$!

# fullscreen waiting
for _i in $(seq 1 40); do
    sleep 0.5
    WID=$(xdotool search --pid "$CHROMIUM_PID" --onlyvisible 2>/dev/null | head -1)
    if [ -n "$WID" ]; then
        wmctrl -i -r "$WID" -b add,fullscreen
        wmctrl -i -r "$WID" -b add,above
        break
    fi
done

echo "[kiosk-manager] Czekam na SMB..."

while [ ! -f /tmp/kiosk-smb-ready ]; do
    sleep 1
done

echo "[kiosk-manager] SMB gotowe — zamykam waiting"

sleep 3

kill "$CHROMIUM_PID"
wait "$CHROMIUM_PID" 2>/dev/null

# watchdog LibreOffice
(
    while sleep 0.4; do
        for _wid in $(xdotool search --class soffice --onlyvisible 2>/dev/null); do
            _wx=$(xdotool getwindowgeometry "$_wid" 2>/dev/null \
                  | awk '/Position:/{split($2,a,","); print a[1]+0}')
            if [ "${_wx:-0}" -lt 1920 ]; then
                wmctrl -i -r "$_wid" -b remove,above 2>/dev/null
                wmctrl -i -r "$_wid" -b add,below    2>/dev/null
                xdotool windowmove --sync "$_wid" 4000 0 2>/dev/null
            fi
        done
    done
) &

echo "[kiosk-manager] Tryb: prezentacja aktywna"

wait
