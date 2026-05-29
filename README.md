# Kiosk Dwuekranowy — Chromium + Prezentacja PowerPoint — Debian 13

Kiosk na 1 monitor.w Chromium tylko strona oczekiwania na sieć, prawy ekran wyświetla w pętli prezentację PowerPoint z zamontowanego udziału SMB. Używa **X11** (xinit + openbox) i **LibreOffice Impress** w trybie pokazu (`--show`) — bez konwersji, z zachowanymi animacjami i przejściami.

---

## Architektura

```
┌──────────────────────────────────────────────────────────────────┐
│                          kiosk.service                           │
│                    (xinit + openbox — tty7)                      │
│                                                                  │
│  Wirtualny desktop 3840×1080 (xrandr --right-of)                 │
│               ┌──────────────────────────────┐                   │
│               │  LibreOffice Impress --show  │	               │
│               │  HDMI-1  (1920,0–3840×1080)  │		   │ 	
│               │  terminal_live.pptx          │                   │
│  	        └──────────────────────────────┘                   │
│                  ▲    above (wmctrl)      ▲                      │
│             kiosk-manager.sh   presentation-manager.sh           │
└──────────────────────────────────────────────────────────────────┘
                                              ▲
                              /mnt/presentation (CIFS/SMB)
                              montowany przez skrypt (fstab user)
                                              ▲
                              //192.168.40.201/DatyFirmowe/ALS
```

**Przepływ — lewy ekran (kiosk-manager.sh):**
1. Konfiguruje X11: xrandr dual-screen, wyłącza DPMS, uruchamia openbox
2. Zapisuje `registrymodifications.xcu` — wyłącza presenter console LO
3. Uruchamia watchdog sesji (co 0.4 s chowa okna LO z lewego ekranu)
4. Uruchamia `presentation-manager.sh` w tle
5. Otwiera `waiting.html` fullscreen + always-on-top
6. Czeka na: sieć (`ping diluals31`) **oraz** sygnał od `presentation-manager.sh` (plik `/tmp/kiosk-smb-ready`)
7. Po otrzymaniu obu sygnałów: `sleep 10` — daje LO czas na otwarcie i pozycjonowanie okna na prawym ekranie
8. Przełącza Chromium na docelowy URL

> `sleep 10` jest kluczowe: zapewnia, że LibreOffice zdąży otworzyć i ustawić okno pokazu zanim Chromium wejdzie w tryb fullscreen+above na lewym ekranie. Bez tego opóźnienia konsola prezentacji była widoczna po reboot.

**Przepływ — prawy ekran (presentation-manager.sh):**
1. Montuje udział SMB (`mount /mnt/presentation`) z retry co 5 s
2. Synchronizuje czcionki z `$SMB_MOUNT/fonts/` do `~/.local/share/fonts/smb/`
3. Tworzy plik `/tmp/kiosk-smb-ready` — sygnał dla `kiosk-manager.sh`
4. Czeka na plik `terminal_live.pptx`
5. Uruchamia persistentny watchdog konsoli (co 0.3 s)
6. Uruchamia `soffice --show terminal_live.pptx`
7. Przesuwa okno pokazu na prawy ekran i stosuje fullscreen
8. Co 5 s: sprawdza mtime pliku i restartuje po zmianie

---

## Wymagania

- Debian 13 netinst — instalacja minimalna bez środowiska graficznego
- Monitor `HDMI-1`
- Dostęp do udziału SMB/CIFS z plikiem prezentacji

---

## Instalacja krok po kroku

### 1. Utwórz użytkownika kiosk

```bash
useradd -m -s /usr/sbin/nologin kiosk
usermod -aG tty,input,video,render,dialout kiosk
```

### 2. Zainstaluj pakiety

```bash
apt update && apt install -y \
    xorg xinit openbox \
    chromium \
    libreoffice-impress \
    cifs-utils \
    xdotool wmctrl \
    x11-xserver-utils \
    iputils-ping \
    ethtool \
    wakeonlan
```

> Nie są już potrzebne:

### 2a. Zainstaluj czcionki

LibreOffice podstawia czcionkę zastępczą gdy oryginalna nie jest zainstalowana w systemie — może to zmienić układ tekstu na slajdach.

#### Automatyczna instalacja przez udział SMB (zalecane)

`presentation-manager.sh` automatycznie synchronizuje czcionki z folderu `fonts/` na udziale SMB do `/home/kiosk/.local/share/fonts/smb/`. Wystarczy wrzucić pliki `.ttf`/`.otf` na udział — zostaną zainstalowane przy najbliższym restarcie kiosku.

**Na maszynie Windows** — skopiuj pliki czcionek do `\\192.168.40.201\DatyFirmowe\ALS\fonts\`:

```powershell
# Calibri (C:\Windows\Fonts\ lub %LOCALAPPDATA%\Microsoft\Windows\Fonts\)
Copy-Item C:\Windows\Fonts\calibri*.ttf \\192.168.40.201\DatyFirmowe\ALS\fonts\

# Aptos — zazwyczaj w cache czcionek chmurowych Microsoft 365:
$src = "$env:LOCALAPPDATA\Microsoft\FontCache\4\CloudFonts\Aptos"
Copy-Item "$src\*" \\192.168.40.201\DatyFirmowe\ALS\fonts\
```

> Nazwy plików Aptos w cache mogą być numeryczne — to normalne, fontconfig czyta metadane wewnętrzne, nie nazwę pliku.

**Restart kiosku** — czcionki zostaną zainstalowane automatycznie:

```bash
systemctl restart kiosk.service
# Sprawdź w logach:
journalctl -u kiosk.service -b | grep "czcionka\|Cache czcionek"
```

#### Carlito — open-source'owy zamiennik Calibri (opcjonalnie)

Jeśli nie masz dostępu do oryginalnych plików Calibri, `Carlito` ma identyczne metryki (ten sam układ tekstu i łamania linii):

```bash
apt install fonts-crosextra-carlito fonts-crosextra-caladea
```

`fonts-crosextra-caladea` to odpowiednik Cambrii. Nie wymaga wrzucania plików na SMB — instalowany systemowo.

#### Inne czcionki Microsoft (Arial, Times New Roman, Verdana)

```bash
apt install ttf-mscorefonts-installer
```

> Nie są już potrzebne: `sway`, `swayidle`, `wlopm`, `wlr-randr`, `seatd`, `mpv`, `poppler-utils`.

### 3. Skonfiguruj montowanie udziału SMB

#### 3a. Utwórz plik poświadczeń

```bash
mkdir -p /etc/samba
cat > /etc/samba/kiosk-credentials << 'EOF'
username=NAZWA_UZYTKOWNIKA
password=HASLO
domain=WORKGROUP
EOF
chmod 600 /etc/samba/kiosk-credentials
chown root:kiosk /etc/samba/kiosk-credentials
```

#### 3b. Utwórz punkt montowania

```bash
mkdir -p /mnt/presentation
```

#### 3c. Dodaj wpis w /etc/fstab (montowanie przez użytkownika kiosk)

```bash
echo '//192.168.40.201/DatyFirmowe/ALS /mnt/presentation cifs credentials=/etc/samba/kiosk-credentials,uid=kiosk,gid=kiosk,vers=3.0,user,noauto,_netdev 0 0' >> /etc/fstab
```

Opcja `user` pozwala użytkownikowi `kiosk` wykonać `mount /mnt/presentation` bez uprawnień roota. Opcja `noauto` wyłącza automatyczne montowanie przy starcie — skrypt sam zarządza montem z retry.

> **Uwaga:** Systemd unit `mnt-presentation.mount` jest **wyłączony** — skrypt `presentation-manager.sh` przejął odpowiedzialność za montowanie.

```bash
systemctl disable mnt-presentation.mount
systemctl stop mnt-presentation.mount
```

### 4. Wykryj nazwy wyjść wideo

```bash
for p in /sys/class/drm/card*-*; do
    echo "$(basename $p | sed 's/card[0-9]*-//'): $(cat $p/status)"
done
```

Przykładowe wyjście:
```
DP-1: connected
HDMI-1: connected
```

Ustaw właściwe nazwy w `kiosk-manager.sh`:
```bash
OUTPUT_LEFT="DP-1"    # lewy ekran — primary
OUTPUT_RIGHT="HDMI-1" # prawy ekran
```

### 5. Skopiuj pliki konfiguracyjne

```bash
cp kiosk-manager.sh /home/kiosk/kiosk-manager.sh
cp presentation-manager.sh /home/kiosk/presentation-manager.sh
cp waiting.html /home/kiosk/waiting.html
chmod +x /home/kiosk/kiosk-manager.sh /home/kiosk/presentation-manager.sh
chown -R kiosk:kiosk /home/kiosk/

cp kiosk.service /etc/systemd/system/kiosk.service
```

### 6. Rozwiązanie problemu z domenami .local

Jeśli `diluals31` jest rozwiązywany przez DNS firmowy (nie mDNS):

- Otwórz `/etc/nsswitch.conf`
- Zmień linię `hosts:` na: `hosts: files dns mdns4_minimal [NOTFOUND=return]`

### 7. Włącz i uruchom serwis

```bash
systemctl daemon-reload
systemctl enable kiosk.service
systemctl start kiosk.service
```

### 8. Skonfiguruj GRUB — natychmiastowy start

```bash
# /etc/default/grub
GRUB_DEFAULT=0
GRUB_TIMEOUT=0
```

```bash
/usr/sbin/grub-mkconfig -o /boot/grub/grub.cfg
```

---

## Harmonogram — Automatyczne wyłączanie i Wake on LAN

Kiosk wyłącza się automatycznie w **sobotę o 7:00** i jest budzony przez Magic Packet (Wake on LAN) co 5 minut przez całe okno aktywności (**niedziela 21:00 – sobota 7:00**). Pakiet WoL jest ignorowany gdy kiosk jest już włączony — cykliczne wysyłanie nie powoduje restartów.

> **Utrata prądu:** WoL nie zadziała gdy karta sieciowa nie ma zasilania. Aby kiosk sam wstał po powrocie prądu, wejdź w ustawienia BIOS/UEFI i ustaw opcję **Restore on AC Power Loss** (lub **After Power Failure**) na **Power On**. W połączeniu z cyklicznym WoL zapewnia to pełne pokrycie: brak prądu → BIOS bootuje automatycznie; awaria software → WoL obudzi po max. 5 min.
>
> Jeśli prąd wróci w oknie wyłączenia (sobota 7:00 – niedziela 20:59), kiosk uruchomi się przez BIOS, ale `kiosk-schedule` wyłączy go ponownie w ciągu max. 5 minut.

### Na kiosku

#### 9a. Cron — automatyczne wyłączanie

```bash
cp kiosk-schedule /etc/cron.d/kiosk-schedule
chmod 644 /etc/cron.d/kiosk-schedule
```

#### 9b. Wake on LAN — włączanie i utrwalanie

```bash
cp wol-enable.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now wol-enable.service
```

Sprawdź, czy WoL jest aktywne:

```bash
ip link show | grep -A1 "state UP" | grep ether  # MAC adres kiosku
ethtool enp2s0 | grep -i wake                    # zamień enp2s0 na właściwy interfejs
```

> **Wymagane ręcznie: BIOS kiosku** — wejdź w ustawienia firmware i włącz opcję **Wake on LAN** lub **Power on by PCI-E/PCI**. Bez tego ustawienia Magic Packet jest ignorowany przez sprzęt.

#### 9c. Pobierz MAC adres kiosku

```bash
ip link show | grep -A1 "state UP" | grep ether | awk '{print $2}'
```

Zanotuj ten adres — potrzebny do konfiguracji serwera (krok poniżej).

### Na serwerze (192.168.40.126)

Zainstaluj narzędzie do wysyłania Magic Packet:

```bash
apt install wakeonlan
```

Utwórz plik crona wysyłającego WoL co 5 minut przez całe okno aktywności kiosku (wstaw MAC kiosku):

```bash
cat > /etc/cron.d/kiosk-wol << 'EOF'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# Budź kiosk WS-VK016 co 5 min w oknie aktywności: nd 21:00 – sb 7:00
# Jeśli kiosk jest już włączony, pakiet WoL jest ignorowany (bezpieczne).
*/5 21-23 * * 0 root wakeonlan XX:XX:XX:XX:XX:XX
*/5 *    * * 1-5 root wakeonlan XX:XX:XX:XX:XX:XX
*/5 0-6  * * 6   root wakeonlan XX:XX:XX:XX:XX:XX
EOF
chmod 644 /etc/cron.d/kiosk-wol
```

Zastąp `XX:XX:XX:XX:XX:XX` adresem MAC pobranym w kroku 9c.

> WoL działa w obrębie jednej podsieci (broadcast). Kiosk i serwer są w sieci `192.168.40.x` — brak potrzeby konfiguracji routera.

---

### `kiosk.service` → `/etc/systemd/system/kiosk.service`

Jednostka systemd uruchamiająca sesję X11 jako użytkownik `kiosk`.

| Opcja | Wartość | Opis |
|---|---|---|
| `ExecStart` | `xinit kiosk-manager.sh -- :0 vt7` | Uruchamia X11 na tty7 |
| `ExecStartPre` | `chvt 7` | Przełącza konsolę na tty7 |
| `PAMName` | `login` | Wymagane do bezrootowego X11 (xinit jako user) |
| `TTYPath` | `/dev/tty7` | Przypisuje serwis do tty7 |
| `SLIDE_DURATION` | `10` | Czas slajdu (s) — aktualnie nieużywany, LO używa timingów z PPTX |
| `Restart=always` | — | Automatyczny restart po awarii |

> Serwis startuje **bez** `network-online.target` — celowo, aby `waiting.html` było widoczne od razu po uruchomieniu systemu. Montowanie SMB obsługuje skrypt z retry.

---

### `kiosk-manager.sh` → `/home/kiosk/kiosk-manager.sh`

Uruchamiany przez xinit. Konfiguruje X11 i obsługuje lewy ekran.

**Co robi:**
1. `xrandr` — tryb rozszerzony: `DP-1` primary (0,0), `HDMI-1` po prawej (1920,0)
2. `xsetroot` + `xset` — czarne tło, wyłączony wygaszacz i DPMS
3. `openbox --sm-disable` — lekki WM wymagany przez `wmctrl fullscreen`
4. Zapisuje `registrymodifications.xcu` — wyłącza presenter console LO (`StartWithPresenterScreen=false`)
5. Uruchamia watchdog sesji w tle — co 0.4 s chowa okna soffice z lewego ekranu (x < 1920)
6. Uruchamia `presentation-manager.sh` w tle
7. Chromium otwiera `waiting.html` z `fullscreen` + `above`
8. Czeka na sieć (`ping diluals31`) **i** na plik `/tmp/kiosk-smb-ready`
9. `sleep 10` — LO ma czas na pełny start i pozycjonowanie okna przed Chromium
10. Kill waiting Chromium → exec Chromium z docelowym URL

**Flagi Chromium (`CHROMIUM_OPTS`):**

| Flaga | Opis |
|---|---|
| `--app=URL` | Tryb aplikacji — brak paska adresu, brak kart |
| `--window-position=0,0 --window-size=1920,1080` | Pozycja na lewym ekranie (X11: bez `--kiosk`, który rozciąga na cały wirtualny desktop) |
| `--no-first-run` | Pomija ekran powitalny |
| `--noerrdialogs` | Ukrywa okna dialogowe błędów |
| `--disable-gpu-suspend` | Zapobiega zawieszaniu GPU przy wygaszaniu |
| `--force-device-scale-factor=1` | Skalowanie 1:1 |
| `--disable-features=Translate,MediaRouter` | Wyłącza tłumaczenie i Chromecast |
| `--disable-sync` | Wyłącza synchronizację Google |
| `--disable-extensions` | Wyłącza rozszerzenia |
| `--password-store=basic` | Nie używa systemowego portfela haseł |
| `--disable-pinch` | Wyłącza pinch-to-zoom |

> **Uwaga:** `--kiosk` na X11 rozciąga okno na cały wirtualny desktop 3840×1080 (oba ekrany). Używamy `--app` + `--window-position/size` + `wmctrl fullscreen`.

**Zmiana hosta / URL kiosku:**
```bash
# kiosk-manager.sh
KIOSK_HOST="diluals31"
KIOSK_URL="http://diluals31/terminal/ift/5/DE/index"
```

---

### `presentation-manager.sh` → `/home/kiosk/presentation-manager.sh`

Obsługuje prawy ekran — montowanie SMB i wyświetlanie prezentacji.

**Montowanie SMB:**
```bash
until mountpoint -q "$SMB_MOUNT"; do
    mount "$SMB_MOUNT"   # korzysta z wpisu fstab z opcją 'user'
    sleep 5              # retry co 5 s
done
```
Przy zakończeniu skryptu (trap EXIT/INT/TERM): `umount /mnt/presentation`.

**Ustawianie okien LibreOffice (`start_lo`):**

Iteruje wszystkie widoczne okna `soffice` wg pozycji X:
- `x ≥ 1920` → okno pokazu slajdów → `wmctrl fullscreen`
- `x < 1920` → konsola prezentacji → przesunięcie na `x=3840` (poza desktop) + `wmctrl below`
- Fallback po 5 s: jeśli nadal brak okna na prawym ekranie → przeniesienie pierwszego znalezionego

Po ustawieniu LO: Chromium podniesiony jako `above` (always-on-top na lewym ekranie).

**Watchdog (co 5 s w głównej pętli):**
- Sprawdza wszystkie widoczne okna `soffice` — jeśli któreś wróciło na `x < 1920`, wysyła je z powrotem na `x=3840`
- Sprawdza `mtime` pliku PPTX — po zmianie restartuje pokaz
- Sprawdza czy `soffice` żyje — jeśli zakończył (koniec pokazu), restartuje

**Konfiguracja:**
```bash
SMB_MOUNT="/mnt/presentation"
SMB_SOURCE="//192.168.40.201/DatyFirmowe/ALS"
PRESENTATION_FILE="$SMB_MOUNT/terminal_live.pptx"
```

---

### `kiosk.service` (wyłączone) `mnt-presentation.mount`

Systemd unit do montowania SMB jest **wyłączony**. Skrypt `presentation-manager.sh` przejął montowanie przez `mount /mnt/presentation` (wpis fstab z opcją `user,noauto`).

---

### `sway-config`

Nieużywany — zachowany jako archiwum poprzedniej architektury (Wayland/sway).

---

### `kiosk-schedule` → `/etc/cron.d/kiosk-schedule`

Plik crona systemu wyłączający kiosk w sobotę o 7:00 (`shutdown -h now` jako root).

---

### `wol-enable.service` → `/etc/systemd/system/wol-enable.service`

Jednostka systemd uruchamiana przy każdym starcie systemu. Wywołuje `ethtool -s IFACE wol g` na wszystkich interfejsach sieciowych — utrzymuje Wake on LAN włączone po rebootach (niektóre sterowniki resetują ustawienie WoL przy wyłączaniu).

---

### `waiting.html` → `/home/kiosk/waiting.html`

Lokalna strona HTML wyświetlana przez Chromium podczas oczekiwania na sieć. Ciemne tło, animowany spinner. Widoczna od startu systemu do momentu, gdy `diluals31` odpowie na ping.

---

## Zarządzanie i diagnostyka

### Logi

```bash
# Logi kiosku na żywo
journalctl -u kiosk.service -f

# Ostatnie 100 linii
journalctl -u kiosk.service -b -n 100

# Tylko logi prezentacji
journalctl -u kiosk.service -b | grep presentation-manager

# Logi montowania SMB
journalctl -u kiosk.service -b | grep "mount:"
```

### Restart / zatrzymanie

```bash
systemctl restart kiosk.service
systemctl stop kiosk.service
```

### Ręczne montowanie / odmontowanie SMB (jako root)

```bash
mount /mnt/presentation
umount /mnt/presentation
mountpoint /mnt/presentation && echo "zamontowany"
```

### Wykrycie nazw wyjść wideo (bez uruchomionego kiosku)

```bash
for p in /sys/class/drm/card*-*; do
    echo "$(basename $p | sed 's/card[0-9]*-//'): $(cat $p/status)"
done
```

### Wymuszenie restartu pokazu (zmiana pliku)

```bash
touch /mnt/presentation/terminal_live.pptx
# skrypt wykryje zmianę mtime w ciągu 5 s i zrestartuje LO
```

### Czyszczenie cache Chromium

```bash
systemctl stop kiosk.service
rm -rf /home/kiosk/.cache/chromium
systemctl start kiosk.service
```

---

## Rozwiązywanie problemów

| Objaw | Przyczyna | Rozwiązanie |
|---|---|---|
| `waiting.html` nie pojawia się | Sieć dostępna natychmiast, ping loop kończy się w <2 s | Normalne zachowanie — `sleep 2` zapewnia min. 2 s widoczności |
| Prezentacja się nie wyświetla | SMB nie zamontowany | `journalctl -u kiosk.service -b \| grep mount` — sprawdź błędy |
| `mount: Permission denied` | Opcja `user` brak w fstab lub kiosk nie jest właścicielem | Sprawdź wpis fstab: `grep presentation /etc/fstab` |
| `mount: not found in /etc/fstab` | Brak wpisu fstab | Dodaj wpis zgodnie z sekcją 3c |
| Konsola LibreOffice widoczna na lewym ekranie po reboot | LibreOffice startuje przed Chromium (kiosk URL) i konsola zdąży się pokazać | Zwiększ `sleep 10` w `kiosk-manager.sh` (linia po pętli `kiosk-smb-ready`) |
| Chromium rozciągnięty na oba ekrany | Użyto `--kiosk` zamiast `--app` | Sprawdź `kiosk-manager.sh` — nie używamy `--kiosk` |
| Lewy ekran czarny, tylko prawy działa | Chromium nie znalazł okna w 30 s | `journalctl \| grep "kiosk-manager"` — sprawdź błędy Chromium |
| `openbox: command not found` | Brak pakietu | `apt install openbox` |
| `wmctrl: command not found` | Brak pakietu | `apt install wmctrl` |
| `xdotool: command not found` | Brak pakietu | `apt install xdotool` |
| Animacje nie działają | LO konwertuje do PNG/PDF (stare podejście) | Aktualna wersja używa `soffice --show` bezpośrednio — animacje powinny działać |
| Tekst źle wyświetlany (zła czcionka, zły układ) | Brak czcionki | Skopiuj pliki `.ttf`/`.otf` do `\\serwer\DatyFirmowe\ALS\fonts\` i zrestartuj kiosk — skrypt zainstaluje je automatycznie |
| Udział SMB z protokołem SMB 1.0 | `vers=3.0` nieobsługiwany | Zmień na `vers=2.1` lub `vers=1.0` w `/etc/fstab` |
| Czarny ekran po restarcie | Chromium trzyma zablokowany profil | `rm -rf /home/kiosk/.cache/chromium` |
| X11 nie startuje (`cannot open display`) | Brak pakietu xorg | `apt install xorg` |
