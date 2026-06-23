#!/bin/bash

# Инструкция по запуску: перекинуть на сервере, в корень. 
# Сделать файл исполняемым chmod +x setup_server_ubuntu_2204.sh
# Выполнить: sudo ./setup_server_ubuntu_2204.sh

# Цвета для красивого вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Начинаем базовую настройку сервера${NC}"
echo -e "${BLUE}========================================${NC}"

# 1. Обновление системы
echo -e "${YELLOW}[1/7] Обновление системы...${NC}"
sudo apt update && sudo apt upgrade -y
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Система обновлена${NC}"
else
    echo -e "${RED}✗ Ошибка при обновлении системы${NC}"
    exit 1
fi

# 2. Установка UFW
echo -e "${YELLOW}[2/7] Установка UFW...${NC}"
sudo apt install ufw -y
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ UFW установлен${NC}"
else
    echo -e "${RED}✗ Ошибка при установке UFW${NC}"
    exit 1
fi

# 3. Генерация случайного порта и настройка SSH
echo -e "${YELLOW}[3/7] Настройка SSH...${NC}"
SSH_PORT=$((RANDOM % 14001 + 50000))
echo -e "Порт SSH: ${GREEN}$SSH_PORT${NC}"

# Создаем директорию для конфигов если её нет
sudo mkdir -p /etc/ssh/sshd_config.d/

# Записываем порт в отдельный конфиг
echo "Port $SSH_PORT" | sudo tee /etc/ssh/sshd_config.d/custom-port.conf > /dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Порт $SSH_PORT записан в /etc/ssh/sshd_config.d/custom-port.conf${NC}"
else
    echo -e "${RED}✗ Ошибка при записи порта${NC}"
    exit 1
fi

# 4. Настройка параметров SSH
echo -e "${YELLOW}[4/7] Настройка параметров SSH...${NC}"

# Создаем резервную копию
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Заменяем параметры (включая закомментированные)
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Удаляем все строки с AuthorizedKeysFile (включая закомментированные)
sudo sed -i '/^#\?AuthorizedKeysFile/d' /etc/ssh/sshd_config

# Добавляем новую строку в конец файла
echo "AuthorizedKeysFile     .ssh/authorized_keys .ssh/authorized_keys2" | sudo tee -a /etc/ssh/sshd_config > /dev/null

echo -e "${GREEN}✓ Параметры SSH настроены${NC}"

# Проверяем конфигурацию SSH
echo -e "${YELLOW}Проверка конфигурации SSH...${NC}"
sudo sshd -t
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Конфигурация SSH корректна${NC}"
    sudo systemctl restart ssh
    echo -e "${GREEN}✓ SSH перезапущен${NC}"
else
    echo -e "${RED}✗ Ошибка в конфигурации SSH, восстанавливаем бэкап${NC}"
    sudo cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
    exit 1
fi

# 5. Настройка UFW
echo -e "${YELLOW}[5/7] Настройка UFW...${NC}"

# Устанавливаем политики по умолчанию
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Добавляем правила
sudo ufw limit $SSH_PORT/tcp comment 'SSH'
sudo ufw allow 443/tcp comment 'HTTPS'

# Включаем UFW
echo -e "${YELLOW}Включение UFW...${NC}"
echo "y" | sudo ufw enable
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ UFW включен${NC}"
else
    echo -e "${RED}✗ Ошибка при включении UFW${NC}"
    exit 1
fi

# 6. Вывод статуса UFW
echo -e "${YELLOW}[6/7] Статус UFW:${NC}"
sudo ufw status verbose

# 7. Финальное сообщение
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}✓ БАЗОВАЯ НАСТРОЙКА ЗАВЕРШЕНА!${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${YELLOW}Порт SSH: ${GREEN}$SSH_PORT${NC}"
echo -e "${RED}⚠ ВАЖНО: Проверьте вход по SSH в другом окне, не закрывая текущую сессию!${NC}"
echo -e "${YELLOW}Пример подключения: ssh -p $SSH_PORT пользователь@сервер${NC}"
echo -e "${BLUE}========================================${NC}"

# Выводим последние правила UFW
echo -e "${YELLOW}Активные правила UFW:${NC}"
sudo ufw status | grep -E "(SSH|HTTPS)"

echo -e "${GREEN}Скрипт успешно выполнен!${NC}"