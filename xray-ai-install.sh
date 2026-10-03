#!/bin/bash
# ============================================================
# Xray-core installer: VLESS + TCP + REALITY
# Target: Ubuntu 22.04 (Debian-based, systemd)
# Run as root.
# ============================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_DIR="/usr/local/etc/xray"
CONFIG="${CONFIG_DIR}/config.json"
KEYS="${CONFIG_DIR}/.keys"
SNI="www.samsung.com"

TOTAL_STEPS=11

log()  { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
step() { echo -e "${YELLOW}[$1/${TOTAL_STEPS}] $2${NC}"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
bad()  { echo -e "${RED}✗ $*${NC}"; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "Скрипт нужно запускать от root."
        exit 1
    fi
}

# [1/11]
initial_update() {
    step 1 "Обновление системы и установка ufw"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
    ok "Система обновлена, ufw установлен (правила не добавлялись)."
}

# [2/11]
install_deps() {
    step 2 "Установка зависимостей"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        qrencode curl jq openssl iputils-ping
    ok "qrencode, curl, jq, openssl, iputils-ping установлены."
}

# [3/11]
enable_bbr() {
    step 3 "Включение BBR"
    local current
    current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '')"
    if [ "$current" = "bbr" ]; then
        ok "BBR уже включён."
        return 0
    fi

    grep -q '^net.core.default_qdisc=fq$' /etc/sysctl.conf \
        || echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
    grep -q '^net.ipv4.tcp_congestion_control=bbr$' /etc/sysctl.conf \
        || echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
    sysctl -p >/dev/null
    ok "BBR включён."
}

# [4/11]
install_xray() {
    step 4 "Установка Xray-core"
    local installer
    installer="$(mktemp)"
    curl -fsSL -o "$installer" \
        https://github.com/XTLS/Xray-install/raw/main/install-release.sh
    bash "$installer" install
    rm -f "$installer"
    ok "Xray-core установлен."
}

# [5/11]
update_geofiles() {
    step 5 "Обновление GeoFiles (Loyalsoldier)"
    mkdir -p /usr/local/share/xray

    if curl -fsSL -o /usr/local/share/xray/geoip.dat \
        https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/geoip.dat; then
        ok "geoip.dat загружен"
    else
        bad "Ошибка загрузки geoip.dat"
    fi

    if curl -fsSL -o /usr/local/share/xray/geosite.dat \
        https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/geosite.dat; then
        ok "geosite.dat загружен"
    else
        bad "Ошибка загрузки geosite.dat"
    fi
}

# [6/11]
generate_keys() {
    step 6 "Генерация ключей (uuid, shortid, X25519)"
    mkdir -p "$CONFIG_DIR"
    rm -f "$KEYS"
    umask 077
    : > "$KEYS"

    local short_id uuid x25519_out priv pub
    short_id="$(openssl rand -hex 8)"
    uuid="$(xray uuid)"

    x25519_out="$(xray x25519)"
    priv="$(printf '%s\n' "$x25519_out" | grep -iE 'private' | awk '{print $NF}' | head -n1)"
    pub="$(printf '%s\n' "$x25519_out" | grep -iE 'password|public' | awk '{print $NF}' | head -n1)"

    if [ -z "$priv" ] || [ -z "$pub" ]; then
        err "Не удалось распарсить вывод 'xray x25519':"
        printf '%s\n' "$x25519_out" >&2
        exit 1
    fi

    {
        echo "shortsid: $short_id"
        echo "uuid: $uuid"
        echo "PrivateKey: $priv"
        echo "Password: $pub"
        echo "fingerprint: edge"
    } >> "$KEYS"

    ok "Ключи сохранены в $KEYS (fingerprint по умолчанию: edge)."
}

# [7/11]
write_config() {
    step 7 "Запись конфигурации"

    local uuid priv short_id
    uuid="$(grep '^uuid:' "$KEYS" | awk '{print $2}')"
    priv="$(grep '^PrivateKey:' "$KEYS" | awk '{print $2}')"
    short_id="$(grep '^shortsid:' "$KEYS" | awk '{print $2}')"

    jq -n \
        --arg uuid     "$uuid" \
        --arg priv     "$priv" \
        --arg short_id "$short_id" \
        --arg sni      "$SNI" \
        '{
          "log": {
            "loglevel": "warning"
          },
          "routing": {
            "domainStrategy": "IPIfNonMatch",
            "rules": [
              {
                "domain": [
                  "geosite:category-ads-all",
                  "regexp:.*\\.ru$",
                  "regexp:.*\\.su$",
                  "regexp:.*\\.xn--p1ai$"
                ],
                "outboundTag": "block"
              }
            ]
          },
          "inbounds": [
            {
              "listen": "0.0.0.0",
              "port": 443,
              "protocol": "vless",
              "settings": {
                "users": [
                  {
                    "id": $uuid,
                    "email": "main",
                    "flow": "xtls-rprx-vision"
                  }
                ],
                "decryption": "none"
              },
              "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                  "show": false,
                  "dest": ($sni + ":443"),
                  "xver": 0,
                  "serverNames": [$sni],
                  "privateKey": $priv,
                  "shortIds": [$short_id]
                }
              },
              "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
              }
            }
          ],
          "outbounds": [
            {
              "protocol": "freedom",
              "settings": {
                "domainStrategy": "UseIPv4"
              },
              "tag": "direct"
            },
            {
              "protocol": "blackhole",
              "tag": "block"
            }
          ],
          "policy": {
            "levels": {
              "0": { "handshake": 3, "connIdle": 180 }
            }
          }
        }' > "$CONFIG"

    if ! jq . "$CONFIG" >/dev/null 2>&1; then
        err "jq не смог записать валидный JSON в $CONFIG"
        exit 1
    fi

    chmod 600 "$CONFIG"
    ok "Конфигурация записана в $CONFIG."
}

# [8/11]
create_helpers() {
    step 8 "Создание вспомогательных команд"

    # ---------- xray-main ----------
    cat > /usr/local/bin/xray-main <<'HELPER'
#!/bin/bash
set -euo pipefail

CONFIG=/usr/local/etc/xray/config.json
KEYS=/usr/local/etc/xray/.keys

[ -f "$KEYS" ]   || { echo "Файл $KEYS не найден"; exit 1; }
[ -f "$CONFIG" ] || { echo "Файл $CONFIG не найден"; exit 1; }

uuid=$(grep '^uuid:'        "$KEYS" | awk '{print $2}')
short_id=$(grep '^shortsid:' "$KEYS" | awk '{print $2}')
pub=$(grep -iE '^Password:' "$KEYS" | awk '{print $2}')
fp=$(grep '^fingerprint:'   "$KEYS" | awk '{print $2}')
[ -z "$fp" ] && fp=edge
sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG")
port=$(jq -r '.inbounds[0].port' "$CONFIG")
ip=$(curl -4 -s --max-time 5 icanhazip.com 2>/dev/null | tr -d '[:space:]')
[ -z "$ip" ] && ip="ВАШ_IP"

link="vless://${uuid}@${ip}:${port}?security=reality&sni=${sni}&fp=${fp}&pbk=${pub}&sid=${short_id}&spx=%2F&type=tcp&flow=xtls-rprx-vision&encryption=none#vless-${ip}"
echo "$link"
qrencode -t ansiutf8 "$link"
HELPER
    chmod +x /usr/local/bin/xray-main

    # ---------- xray-add ----------
    cat > /usr/local/bin/xray-add <<'HELPER'
#!/bin/bash
set -euo pipefail
CONFIG=/usr/local/etc/xray/config.json
KEYS=/usr/local/etc/xray/.keys

read -rp "Введите имя (email) нового пользователя: " name
[ -z "$name" ] && { echo "Имя не может быть пустым"; exit 1; }
case "$name" in *[[:space:]]*) echo "Имя не должно содержать пробелов"; exit 1 ;; esac

if jq -e --arg n "$name" '.inbounds[0].settings.users[] | select(.email==$n)' "$CONFIG" >/dev/null; then
    echo "Пользователь '$name' уже существует"
    exit 0
fi

new_uuid=$(xray uuid)
tmp=$(mktemp)
jq --arg id "$new_uuid" --arg n "$name" \
   '.inbounds[0].settings.users += [{"id":$id,"email":$n,"flow":"xtls-rprx-vision"}]' \
   "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

systemctl restart xray

short_id=$(grep '^shortsid:' "$KEYS" | awk '{print $2}')
pub=$(grep -iE '^Password:' "$KEYS" | awk '{print $2}')
fp=$(grep '^fingerprint:'   "$KEYS" | awk '{print $2}')
[ -z "$fp" ] && fp=edge
sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG")
port=$(jq -r '.inbounds[0].port' "$CONFIG")
ip=$(curl -4 -s --max-time 5 icanhazip.com 2>/dev/null | tr -d '[:space:]')
[ -z "$ip" ] && ip="ВАШ_IP"

link="vless://${new_uuid}@${ip}:${port}?security=reality&sni=${sni}&fp=${fp}&pbk=${pub}&sid=${short_id}&spx=%2F&type=tcp&flow=xtls-rprx-vision&encryption=none#${name}"
echo "$link"
qrencode -t ansiutf8 "$link"
HELPER
    chmod +x /usr/local/bin/xray-add

    # ---------- xray-link ----------
    cat > /usr/local/bin/xray-link <<'HELPER'
#!/bin/bash
set -euo pipefail
CONFIG=/usr/local/etc/xray/config.json
KEYS=/usr/local/etc/xray/.keys

mapfile -t users < <(jq -r '.inbounds[0].settings.users[].email // empty' "$CONFIG")
if [ "${#users[@]}" -eq 0 ]; then
    echo "Список клиентов пуст"
    exit 0
fi

i=1
for u in "${users[@]}"; do
    printf '%2d. %s\n' "$i" "$u"
    i=$((i+1))
done

read -rp "Введите номер: " n
if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "${#users[@]}" ]; then
    echo "Некорректный номер"
    exit 1
fi

name="${users[$((n-1))]}"
uuid=$(jq -r --arg n "$name" '.inbounds[0].settings.users[] | select(.email==$n) | .id' "$CONFIG")
short_id=$(grep '^shortsid:' "$KEYS" | awk '{print $2}')
pub=$(grep -iE '^Password:' "$KEYS" | awk '{print $2}')
fp=$(grep '^fingerprint:'   "$KEYS" | awk '{print $2}')
[ -z "$fp" ] && fp=edge
sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG")
port=$(jq -r '.inbounds[0].port' "$CONFIG")
ip=$(curl -4 -s --max-time 5 icanhazip.com 2>/dev/null | tr -d '[:space:]')
[ -z "$ip" ] && ip="ВАШ_IP"

link="vless://${uuid}@${ip}:${port}?security=reality&sni=${sni}&fp=${fp}&pbk=${pub}&sid=${short_id}&spx=%2F&type=tcp&flow=xtls-rprx-vision&encryption=none#${name}"
echo "$link"
qrencode -t ansiutf8 "$link"
HELPER
    chmod +x /usr/local/bin/xray-link

    # ---------- xray-del ----------
    cat > /usr/local/bin/xray-del <<'HELPER'
#!/bin/bash
set -euo pipefail
CONFIG=/usr/local/etc/xray/config.json

mapfile -t users < <(jq -r '.inbounds[0].settings.users[].email // empty' "$CONFIG")
if [ "${#users[@]}" -eq 0 ]; then
    echo "Список клиентов пуст"
    exit 0
fi

i=1
for u in "${users[@]}"; do
    printf '%2d. %s\n' "$i" "$u"
    i=$((i+1))
done

read -rp "Введите номер для удаления: " n
if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "${#users[@]}" ]; then
    echo "Некорректный номер"
    exit 1
fi

target="${users[$((n-1))]}"
tmp=$(mktemp)
jq --arg n "$target" \
   '.inbounds[0].settings.users |= map(select(.email != $n))' \
   "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

systemctl restart xray
echo "Клиент '$target' удалён"
HELPER
    chmod +x /usr/local/bin/xray-del

    # ---------- xray-list ----------
    cat > /usr/local/bin/xray-list <<'HELPER'
#!/bin/bash
CONFIG=/usr/local/etc/xray/config.json
mapfile -t users < <(jq -r '.inbounds[0].settings.users[].email // empty' "$CONFIG")
if [ "${#users[@]}" -eq 0 ]; then
    echo "Список клиентов пуст"
    exit 0
fi
i=1
for u in "${users[@]}"; do
    printf '%2d. %s\n' "$i" "$u"
    i=$((i+1))
done
HELPER
    chmod +x /usr/local/bin/xray-list

    # ---------- xray-update ----------
    cat > /usr/local/bin/xray-update <<'HELPER'
#!/bin/bash
set -e
echo "[*] Обновление Xray-core..."
inst=$(mktemp)
curl -fsSL -o "$inst" https://github.com/XTLS/Xray-install/raw/main/install-release.sh
bash "$inst" install
rm -f "$inst"
systemctl restart xray
echo "[+] Xray-core обновлён, служба перезапущена."
HELPER
    chmod +x /usr/local/bin/xray-update

    # ---------- xray-restart ----------
    cat > /usr/local/bin/xray-restart <<'HELPER'
#!/bin/bash
set -e
CONFIG=/usr/local/etc/xray/config.json
echo "[*] Проверка конфигурации..."
if ! xray run -test -c "$CONFIG" >/dev/null 2>&1; then
    echo "[x] Конфигурация не прошла проверку, рестарт отменён:"
    xray run -test -c "$CONFIG" || true
    exit 1
fi
echo "[*] Перезапуск Xray..."
systemctl restart xray
sleep 1
systemctl --no-pager --full status xray | head -n 6
HELPER
    chmod +x /usr/local/bin/xray-restart

    # ---------- xray-sni ----------
    cat > /usr/local/bin/xray-sni <<'HELPER'
#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

CONFIG=/usr/local/etc/xray/config.json
KEYS=/usr/local/etc/xray/.keys

current_sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG")

echo "Текущий SNI: ${GREEN}${current_sni}${NC}"
read -rp "Введите новый SNI (домен без порта, порт всегда 443): " new_sni

if [ -z "$new_sni" ]; then
    echo "Пустой ввод — отмена."
    exit 0
fi

if printf '%s' "$new_sni" | grep -qE '[[:space:]/:]'; then
    echo -e "${RED}Некорректный домен (содержит пробел, '/' или ':').${NC}"
    exit 1
fi
if ! printf '%s' "$new_sni" | grep -qE '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'; then
    echo -e "${RED}Некорректный домен.${NC}"
    exit 1
fi

echo
echo -e "${YELLOW}Проверка домена ${new_sni} (10 пингов, порог 15 мс)...${NC}"

ping_out=$(ping -c 10 -W 1 -q "$new_sni" 2>/dev/null || true)
if [ -z "$ping_out" ]; then
    echo -e "${RED}✗ Домен не пингуется. SNI не применён.${NC}"
    exit 1
fi

avg=$(printf '%s\n' "$ping_out" | awk -F'/' '/rtt min\/avg/ {print $5}')
if [ -z "$avg" ]; then
    echo -e "${RED}✗ Не удалось получить средний RTT. SNI не применён.${NC}"
    exit 1
fi

echo "Средний RTT: ${avg} мс"

if ! awk -v a="$avg" 'BEGIN { exit !(a <= 15) }'; then
    echo -e "${RED}✗ Средний RTT ${avg} мс > 15 мс. SNI не применён.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Проверка пройдена. Применяю SNI...${NC}"

tmp=$(mktemp)
jq --arg s "$new_sni" --arg d "${new_sni}:443" \
   '.inbounds[0].streamSettings.realitySettings.serverNames = [$s] |
    .inbounds[0].streamSettings.realitySettings.dest = $d' \
   "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
chmod 600 "$CONFIG"

systemctl restart xray
sleep 1
if systemctl is-active --quiet xray; then
    echo -e "${GREEN}✓ SNI изменён на ${new_sni}, Xray перезапущен.${NC}"
    echo -e "${YELLOW}Сгенерируйте новые ссылки: xray-main или xray-link${NC}"
else
    echo -e "${RED}✗ Xray не запустился, проверьте: systemctl status xray${NC}"
    exit 1
fi
HELPER
    chmod +x /usr/local/bin/xray-sni

    # ---------- xray-fp ----------
    cat > /usr/local/bin/xray-fp <<'HELPER'
#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

KEYS=/usr/local/etc/xray/.keys

if [ ! -f "$KEYS" ]; then
    echo -e "${RED}Файл $KEYS не найден.${NC}"
    exit 1
fi

current_fp=$(grep '^fingerprint:' "$KEYS" | awk '{print $2}')
[ -z "$current_fp" ] && current_fp=edge

echo "Текущий fingerprint: ${GREEN}${current_fp}${NC}"
echo
echo "Доступные варианты (по документации Xray):"
echo "  chrome, firefox, safari, ios, android, edge, 360, qq,"
echo "  random, randomized"
echo "  или собственная uTLS-строка (например, HelloChrome_106_Shuffle)"
echo
read -rp "Введите новый fingerprint (Enter — оставить текущий): " new_fp

if [ -z "$new_fp" ]; then
    echo "Пустой ввод — отмена."
    exit 0
fi

if printf '%s' "$new_fp" | grep -qE '[[:space:]]'; then
    echo -e "${RED}Значение не должно содержать пробелов.${NC}"
    exit 1
fi

grep -v '^fingerprint:' "$KEYS" > "${KEYS}.tmp" && mv "${KEYS}.tmp" "$KEYS"
echo "fingerprint: $new_fp" >> "$KEYS"
chmod 600 "$KEYS"

echo -e "${GREEN}✓ fingerprint изменён на ${new_fp}.${NC}"
echo -e "${YELLOW}Сгенерируйте новые ссылки: xray-main или xray-link${NC}"
HELPER
    chmod +x /usr/local/bin/xray-fp

    # ---------- xray-uninstall ----------
    cat > /usr/local/bin/xray-uninstall <<'HELPER'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${RED}=================================================${NC}"
echo -e "${RED}  ПОЛНОЕ УДАЛЕНИЕ XRAY И ИЗМЕНЕНИЙ СКРИПТА${NC}"
echo -e "${RED}=================================================${NC}"
echo
echo "Будет удалено:"
echo "  - Xray-core (бинарник, systemd-сервис, /usr/local/etc/xray, /usr/local/share/xray)"
echo "  - Вспомогательные команды xray-*"
echo "  - Файл-подсказка \$HOME/xray-help"
echo "Будет возвращено:"
echo "  - Порт SSH и параметры sshd (из бэкапа, если есть)"
echo "  - Настройки BBR в /etc/sysctl.conf"
echo "  - UFW будет сброшен и отключён"
echo

if [ "$(id -u)" -ne 0 ]; then
    echo "Запустите от root"
    exit 1
fi

read -rp "Подтверждение 1/3. Введите YES для продолжения: " c1
[ "$c1" = "YES" ] || { echo "Отменено."; exit 0; }

read -rp "Подтверждение 2/3. Введите слово REMOVE: " c2
[ "$c2" = "REMOVE" ] || { echo "Отменено."; exit 0; }

echo -e "${RED}Последнее предупреждение. Через 10 секунд начнётся удаление.${NC}"
echo -e "${RED}Нажмите Ctrl+C для отмены.${NC}"
for i in 10 9 8 7 6 5 4 3 2 1; do
    printf '%s... ' "$i"
    sleep 1
done
echo
read -rp "Подтверждение 3/3. Введите DELETE для окончательного удаления: " c3
[ "$c3" = "DELETE" ] || { echo "Отменено."; exit 0; }

echo
echo "[*] Остановка и удаление службы Xray..."
systemctl stop xray 2>/dev/null || true
systemctl disable xray 2>/dev/null || true
rm -f /etc/systemd/system/xray.service
rm -f /etc/systemd/system/xray@.service
rm -rf /etc/systemd/system/xray.service.d
systemctl daemon-reload

echo "[*] Удаление файлов Xray..."
rm -rf /usr/local/etc/xray
rm -rf /usr/local/share/xray
rm -f  /usr/local/bin/xray
rm -f  /usr/bin/xray
rm -rf /var/log/xray

echo "[*] Удаление вспомогательных команд..."
rm -f /usr/local/bin/xray-main
rm -f /usr/local/bin/xray-add
rm -f /usr/local/bin/xray-link
rm -f /usr/local/bin/xray-del
rm -f /usr/local/bin/xray-list
rm -f /usr/local/bin/xray-update
rm -f /usr/local/bin/xray-restart
rm -f /usr/local/bin/xray-sni
rm -f /usr/local/bin/xray-fp
rm -f /usr/local/bin/xray-uninstall

echo "[*] Удаление файла-подсказки..."
rm -f "$HOME/xray-help"
rm -f /root/xray-help

echo "[*] Возврат SSH..."
if [ -f /etc/ssh/sshd_config.backup ]; then
    cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
    echo "  sshd_config восстановлен из бэкапа"
fi
rm -f /etc/ssh/sshd_config.d/custom-port.conf
if sshd -t 2>/dev/null; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    echo "  sshd перезапущен"
else
    echo "  ВНИМАНИЕ: sshd -t провалился, проверьте /etc/ssh/sshd_config вручную"
fi

echo "[*] Возврат BBR..."
sed -i '/^net.core.default_qdisc=fq$/d' /etc/sysctl.conf
sed -i '/^net.ipv4.tcp_congestion_control=bbr$/d' /etc/sysctl.conf
sysctl -p >/dev/null 2>&1 || true

echo "[*] Сброс и отключение UFW..."
ufw --force reset >/dev/null 2>&1 || true
ufw --force disable >/dev/null 2>&1 || true

echo
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}  УДАЛЕНИЕ ЗАВЕРШЕНО${NC}"
echo -e "${GREEN}=================================================${NC}"
echo -e "${YELLOW}Если вы подключены по нестандартному порту SSH,${NC}"
echo -e "${YELLOW}текущая сессия сохранится, но при переподключении${NC}"
echo -e "${YELLOW}используйте порт 22 (или тот, что был до скрипта).${NC}"
HELPER
    chmod +x /usr/local/bin/xray-uninstall

    ok "Команды созданы: xray-main, xray-add, xray-link, xray-del, xray-list, xray-update, xray-restart, xray-sni, xray-fp, xray-uninstall."
}

# [9/11]
restart_and_verify() {
    step 9 "Перезапуск Xray и проверка"

    if ! xray run -test -c "$CONFIG" >/dev/null 2>&1; then
        err "Проверка конфигурации не прошла. Вывод:"
        xray run -test -c "$CONFIG" >&2 || true
        exit 1
    fi
    ok "Конфигурация валидна."

    systemctl restart xray
    sleep 3

    if systemctl is-active --quiet xray; then
        ok "Служба Xray запущена."
    else
        err "Служба Xray не запустилась. Статус:"
        systemctl status xray --no-pager >&2 || true
        exit 1
    fi

    echo
    log "Ссылка и QR-код основного пользователя:"
    xray-main
}

# [10/11]
create_help() {
    step 10 "Создание файла-подсказки"
    local help="$HOME/xray-help"
    cat > "$help" <<'HELP'
Xray-core — вспомогательные команды

ПРОСМОТР / ПОДКЛЮЧЕНИЕ
  xray-main       — ссылка и QR для основного пользователя
  xray-link       — ссылка и QR для выбранного пользователя
  xray-list       — список пользователей

УПРАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯМИ
  xray-add        — добавить нового пользователя
  xray-del        — удалить пользователя

ИЗМЕНЕНИЕ ПАРАМЕТРОВ REALITY
  xray-sni        — сменить SNI и dest (порт 443; проверка пинга ≤ 15 мс)
  xray-fp         — сменить TLS fingerprint (по умолчанию edge)

СЕРВИС
  xray-restart    — перезапустить Xray (с проверкой конфига)
  xray-update     — обновить Xray-core до последней версии

УДАЛЕНИЕ
  xray-uninstall  — полное удаление Xray и изменений скрипта (тройное подтверждение)

Конфиг:   /usr/local/etc/xray/config.json
Ключи:    /usr/local/etc/xray/.keys
Рестарт:  systemctl restart xray
HELP
    ok "Файл-подсказка создан: $help"
}

# [11/11]
configure_ssh_and_ufw() {
    step 11 "Настройка SSH и UFW"

    SSH_PORT=$((RANDOM % 14001 + 50000))
    echo -e "Порт SSH: ${GREEN}$SSH_PORT${NC}"

    mkdir -p /etc/ssh/sshd_config.d/
    if echo "Port $SSH_PORT" > /etc/ssh/sshd_config.d/custom-port.conf; then
        ok "Порт $SSH_PORT записан в /etc/ssh/sshd_config.d/custom-port.conf"
    else
        bad "Ошибка при записи порта"
        exit 1
    fi

    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    sed -i '/^#\?AuthorizedKeysFile/d' /etc/ssh/sshd_config
    echo "AuthorizedKeysFile     .ssh/authorized_keys .ssh/authorized_keys2" >> /etc/ssh/sshd_config

    ok "Параметры SSH обновлены."

    echo "Проверка конфигурации SSH..."
    if sshd -t; then
        ok "Конфигурация SSH корректна."
        systemctl restart ssh
        ok "SSH перезапущен."
    else
        bad "Ошибка в конфигурации SSH. Восстанавливаю бэкап."
        cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
        exit 1
    fi

    ufw default deny incoming
    ufw default allow outgoing
    ufw limit "$SSH_PORT"/tcp comment 'SSH'
    ufw allow 443/tcp comment 'HTTPS'

    echo "Включение UFW..."
    echo "y" | ufw enable >/dev/null
    if ufw status | grep -q "Status: active"; then
        ok "UFW включён."
    else
        bad "Ошибка при включении UFW"
        exit 1
    fi

    echo
    echo -e "${YELLOW}Статус UFW:${NC}"
    ufw status verbose

    echo
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}✓ БАЗОВАЯ НАСТРОЙКА ЗАВЕРШЕНА${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "${YELLOW}Порт SSH: ${GREEN}$SSH_PORT${NC}"
    echo -e "${RED}⚠ ВАЖНО: Проверьте вход по SSH в другом окне, не закрывая текущую сессию!${NC}"
    echo -e "${YELLOW}Пример подключения: ssh -p $SSH_PORT пользователь@сервер${NC}"
    echo -e "${BLUE}========================================${NC}"

    echo -e "${YELLOW}Активные правила UFW:${NC}"
    ufw status | grep -E "(SSH|HTTPS)" || true
}

main() {
    require_root
    log "Установка VLESS + TCP + REALITY. SNI/dest: ${SNI}:443"
    sleep 3
    initial_update
    install_deps
    enable_bbr
    install_xray
    update_geofiles
    generate_keys
    write_config
    create_helpers
    restart_and_verify
    create_help
    configure_ssh_and_ufw
    log "Готово."
}

main "$@"