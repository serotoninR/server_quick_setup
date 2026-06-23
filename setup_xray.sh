#!/bin/bash

# chmod +x setup_xray.sh
# sudo ./setup_xray.sh

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Настройка XRAY${NC}"
echo -e "${BLUE}========================================${NC}"

# Проверка прав root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Пожалуйста, запустите с sudo${NC}"
    exit 1
fi

# Установка jq если не установлен
if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}Установка jq...${NC}"
    apt install jq -y
fi

# 1. Установка XRAY
echo -e "${YELLOW}[1/6] Установка XRAY...${NC}"
wget -qO- https://raw.githubusercontent.com/ServerTechnologies/simple-xray-core/refs/heads/main/xray-install | bash
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ XRAY установлен${NC}"
else
    echo -e "${RED}✗ Ошибка установки XRAY${NC}"
    exit 1
fi

# 2. Обновление GeoFiles
echo -e "${YELLOW}[2/6] Обновление GeoFiles...${NC}"
cd /usr/local/share/xray/
curl -LO https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/geoip.dat
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ geoip.dat загружен${NC}"
else
    echo -e "${RED}✗ Ошибка загрузки geoip.dat${NC}"
fi

curl -LO https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/geosite.dat
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ geosite.dat загружен${NC}"
else
    echo -e "${RED}✗ Ошибка загрузки geosite.dat${NC}"
fi
echo -e "${GREEN}✓ GeoFiles обновлены${NC}"

# 3. Перезапуск XRAY
echo -e "${YELLOW}[3/6] Перезапуск XRAY...${NC}"
systemctl restart xray
sleep 3

# 4. Спрашиваем про WARP
echo -e "${YELLOW}[4/6] Использовать WARP-CloudFlare Для AI? (y/n):${NC}"
read -r use_warp

CONFIG_FILE="/usr/local/etc/xray/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}✗ Файл $CONFIG_FILE не найден${NC}"
    exit 1
fi

# 5. Обработка в зависимости от выбора
if [[ "$use_warp" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Настройка WARP...${NC}"
    
    # Установка wgcf
    echo -e "${YELLOW}Установка wgcf...${NC}"
    curl -L https://github.com/ViRb3/wgcf/releases/download/v2.2.25/wgcf_2.2.25_linux_amd64 -o /usr/local/bin/wgcf
    chmod +x /usr/local/bin/wgcf
    
    # Регистрация
    echo -e "${YELLOW}Регистрация wgcf...${NC}"
    echo -e "${BLUE}Нажмите Enter для подтверждения${NC}"
    wgcf register
    
    # Генерация конфига
    echo -e "${YELLOW}Генерация конфига...${NC}"
    wgcf generate
    
    # Извлечение параметров
    WGCF_FILE="wgcf-profile.conf"
    if [ -f "$WGCF_FILE" ]; then
        PRIVATE_KEY=$(grep "^PrivateKey" "$WGCF_FILE" | awk '{print $3}')
        ADDRESS=$(grep "^Address" "$WGCF_FILE" | awk '{print $3}' | cut -d',' -f1)
        PUBLIC_KEY=$(grep "^PublicKey" "$WGCF_FILE" | awk '{print $3}')
        
        echo -e "${GREEN}✓ Параметры WARP получены${NC}"
    else
        echo -e "${RED}✗ Файл $WGCF_FILE не найден${NC}"
        exit 1
    fi
    
    # Создание outbound WARP
    WARP_OUTBOUND=$(cat <<EOF
        {
            "protocol": "wireguard",
            "settings": {
                "secretKey": "$PRIVATE_KEY",
                "address": ["$ADDRESS"],
                "peers": [
                    {
                        "publicKey": "$PUBLIC_KEY",
                        "allowedIPs": ["0.0.0.0/0"],
                        "endpoint": "engage.cloudflareclient.com:2408"
                    }
                ],
                "domainStrategy": "ForceIPv4",
                "mtu": 1280
            },
            "tag": "warp"
        }
EOF
)
    
    # Редактирование config.json с warp
    echo -e "${YELLOW}Редактирование config.json с WARP...${NC}"
    
    # Извлекаем все текущие значения
    CURRENT_ID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_FILE")
    CURRENT_PRIVATE_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$CONFIG_FILE")
    CURRENT_SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$CONFIG_FILE")
    
    # Создаем новый config.json
    jq --arg id "$CURRENT_ID" \
       --arg privkey "$CURRENT_PRIVATE_KEY" \
       --arg shortid "$CURRENT_SHORT_ID" \
       '.routing.rules = [
            {
                "type": "field",
                "domain": ["geosite:category-ai-!cn"],
                "outboundTag": "warp"
            },
            {
                "type": "field",
                "domain": [
                    "regexp:.*\\.ru$",
                    "regexp:.*\\.su$",
                    "regexp:.*\\.xn--p1ai$"
                ],
                "outboundTag": "block"
            }
        ] |
        .inbounds[0].settings.clients[0].id = $id |
        .inbounds[0].streamSettings.realitySettings.privateKey = $privkey |
        .inbounds[0].streamSettings.realitySettings.shortIds = [$shortid] |
        .outbounds = [
            {
                "protocol": "freedom",
                "settings": {
                    "domainStrategy": "UseIPv4"
                },
                "tag": "direct"
            },
            {
                "protocol": "wireguard",
                "settings": {
                    "secretKey": "'"$PRIVATE_KEY"'",
                    "address": ["'"$ADDRESS"'"],
                    "peers": [
                        {
                            "publicKey": "'"$PUBLIC_KEY"'",
                            "allowedIPs": ["0.0.0.0/0"],
                            "endpoint": "engage.cloudflareclient.com:2408"
                        }
                    ],
                    "domainStrategy": "ForceIPv4",
                    "mtu": 1280
                },
                "tag": "warp"
            },
            {
                "protocol": "blackhole",
                "tag": "block"
            }
        ]' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    
    echo -e "${GREEN}✓ config.json обновлен с WARP${NC}"
    
else
    # Без WARP - просто блокировка .ru
    echo -e "${YELLOW}Настройка без WARP...${NC}"
    
    # Извлекаем значения
    CURRENT_ID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_FILE")
    CURRENT_PRIVATE_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$CONFIG_FILE")
    CURRENT_SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$CONFIG_FILE")
    
    # Создаем новый config.json
    jq --arg id "$CURRENT_ID" \
       --arg privkey "$CURRENT_PRIVATE_KEY" \
       --arg shortid "$CURRENT_SHORT_ID" \
       '.routing.rules = [
            {
                "type": "field",
                "domain": [
                    "regexp:.*\\.ru$",
                    "regexp:.*\\.su$",
                    "regexp:.*\\.xn--p1ai$"
                ],
                "outboundTag": "block"
            }
        ] |
        .inbounds[0].settings.clients[0].id = $id |
        .inbounds[0].streamSettings.realitySettings.privateKey = $privkey |
        .inbounds[0].streamSettings.realitySettings.shortIds = [$shortid] |
        .outbounds = [
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
        ]' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    
    echo -e "${GREEN}✓ config.json обновлен без WARP${NC}"
fi

# 6. Перезапуск XRAY
echo -e "${YELLOW}[6/6] Перезапуск XRAY...${NC}"
systemctl restart xray
sleep 3

# Проверка статуса
if systemctl is-active --quiet xray; then
    echo -e "${GREEN}✓ XRAY успешно перезапущен${NC}"
else
    echo -e "${RED}✗ Ошибка при перезапуске XRAY${NC}"
    journalctl -u xray -n 20 --no-pager
    exit 1
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}✓ Настройка завершена!${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${YELLOW}Конфиг: $CONFIG_FILE${NC}"
if [[ "$use_warp" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}WARP активирован для AI трафика${NC}"
else
    echo -e "${YELLOW}WARP не используется${NC}"
fi
echo -e "${BLUE}========================================${NC}"