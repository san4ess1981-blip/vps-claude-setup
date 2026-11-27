#!/usr/bin/env bash
# =============================================================
# setup.sh — подготовка VPS (Ubuntu 24.04) под работу с Claude
#
# Что делает:
#   Часть 2: обновления, пользователь, UFW, fail2ban, автообновления
#   Часть 3.5: защита SSH — новый порт, AllowUsers, запрет пароля (если есть ключ)
#   Часть 3: Docker + wg-easy (WireGuard с веб-панелью)
#   Часть 4: Node.js 22 + Claude Code + git/tmux/python
#   Часть 6.5: SSH-ключ для GitHub
#
# Запуск:  bash setup.sh        (от root, на свежем сервере)
# =============================================================

set -euo pipefail

# ---------- Параметры (можно поменять) ----------
NEW_USER="dev"            # имя рабочего пользователя
SSH_PORT="51222"          # НОВЫЙ порт SSH (нестандартный — защита от ботов)
WG_UDP_PORT="51820"       # порт WireGuard
WG_UI_PORT="51821"        # порт веб-панели wg-easy
SERVER_IP="146.103.57.168"  # внешний IP сервера (Virtarix)
# Алфавит паролей без похожих символов (нет 0/O, 1/l/I) — проще переписывать
PASS_ALPHABET='ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789'
# ------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "ОШИБКА: запустите скрипт от root (bash setup.sh)" >&2
  exit 1
fi

echo "==> [1/7] Обновление системы и базовые пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y curl ca-certificates ufw fail2ban git tmux python3-pip unattended-upgrades

# Автоматические security-обновления
dpkg-reconfigure -f noninteractive unattended-upgrades || true

echo "==> [2/7] Создание пользователя '${NEW_USER}'"
if id "${NEW_USER}" &>/dev/null; then
  echo "    пользователь уже существует — пропускаю"
else
  USER_PASS="$(tr -dc "${PASS_ALPHABET}" </dev/urandom | head -c 20 || true)"
  useradd -m -s /bin/bash -G sudo "${NEW_USER}"
  echo "${NEW_USER}:${USER_PASS}" | chpasswd
fi
# Если у root настроен SSH-ключ — копируем его новому пользователю
if [[ -f /root/.ssh/authorized_keys ]]; then
  mkdir -p "/home/${NEW_USER}/.ssh"
  cp /root/.ssh/authorized_keys "/home/${NEW_USER}/.ssh/authorized_keys"
  chown -R "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.ssh"
  chmod 700 "/home/${NEW_USER}/.ssh"
  chmod 600 "/home/${NEW_USER}/.ssh/authorized_keys"
  echo "    SSH-ключ root скопирован пользователю ${NEW_USER}"
fi

echo "==> [3/7] Файрвол UFW + fail2ban"
ufw allow "${SSH_PORT}/tcp"     # новый порт SSH
if [[ "${SSH_PORT}" != "22" ]]; then
  ufw allow 22/tcp              # старый порт — временно, закроем после проверки
fi
ufw allow "${WG_UDP_PORT}/udp"
ufw allow "${WG_UI_PORT}/tcp"   # панель wg-easy — закройте после настройки (команда в конце)
ufw --force enable

# fail2ban следит за новым портом SSH
cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled  = true
port     = ${SSH_PORT}
maxretry = 5
bantime  = 1h
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

echo "==> [3.5/7] Защита SSH: порт ${SSH_PORT}, AllowUsers, запрет пароля"
# Ubuntu 24.04 использует socket-активацию SSH: параметр Port в sshd_config
# при ней игнорируется — отключаем сокет, включаем классический сервис
if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
  systemctl disable --now ssh.socket
fi
systemctl enable ssh.service >/dev/null 2>&1 || systemctl enable ssh >/dev/null 2>&1 || true

# Запрещаем пароль ТОЛЬКО если есть хоть один SSH-ключ — иначе потеряем доступ
HAVE_KEYS=0
[[ -s /root/.ssh/authorized_keys ]] && HAVE_KEYS=1 || true
[[ -s "/home/${NEW_USER}/.ssh/authorized_keys" ]] && HAVE_KEYS=1 || true

# Имя 00-* — sshd читает файлы по алфавиту, и первое значение побеждает;
# облачный 50-cloud-init.conf иначе перебивает запрет пароля
{
  echo "Port ${SSH_PORT}"
  echo "AllowUsers ${NEW_USER} root"
  echo "PermitRootLogin prohibit-password"
  if [[ "${HAVE_KEYS}" -eq 1 ]]; then
    echo "PubkeyAuthentication yes"
    echo "PasswordAuthentication no"
  fi
} > /etc/ssh/sshd_config.d/00-vps-hardening.conf

if [[ "${HAVE_KEYS}" -eq 1 ]]; then
  PW_AUTH="ОТКЛЮЧЁН (только по ключу)"
else
  PW_AUTH="ВКЛЮЧЁН — SSH-ключи не найдены! Добавьте ключ в /home/${NEW_USER}/.ssh/authorized_keys и перезапустите setup.sh"
  echo "    ВНИМАНИЕ: SSH-ключи не найдены — вход по паролю ОСТАВЛЕН, иначе доступ был бы потерян."
fi

# Проверка конфига и перезапуск; при неудаче — откат
if sshd -t; then
  systemctl restart ssh
else
  echo "    ОШИБКА: конфиг sshd невалиден — откатываю" >&2
  rm -f /etc/ssh/sshd_config.d/00-vps-hardening.conf
  systemctl restart ssh || true
  exit 1
fi

SS_LISTEN="$(ss -tln)"
if grep -qE ":${SSH_PORT}[[:space:]]" <<<"${SS_LISTEN}"; then
  echo "    sshd слушает порт ${SSH_PORT}"
  if [[ "${SSH_PORT}" != "22" ]]; then
    ufw delete allow 22/tcp >/dev/null 2>&1 || true
    echo "    старый порт 22/tcp закрыт в UFW"
  fi
else
  echo "    ОШИБКА: sshd не поднялся на порту ${SSH_PORT} — откатываю конфиг" >&2
  rm -f /etc/ssh/sshd_config.d/00-vps-hardening.conf
  systemctl restart ssh || true
  exit 1
fi

echo "==> [4/7] Установка Docker"
if command -v docker &>/dev/null; then
  echo "    Docker уже установлен — пропускаю"
else
  curl -fsSL https://get.docker.com | sh
fi
usermod -aG docker "${NEW_USER}"

echo "==> [5/7] WireGuard (wg-easy)"
# IP задан в параметрах выше; проверяем, что он совпадает с фактическим
DETECTED_IP="$(curl -4 -fsSL https://ifconfig.me || curl -4 -fsSL https://api.ipify.org || true)"
if [[ -n "${DETECTED_IP}" && "${DETECTED_IP}" != "${SERVER_IP}" ]]; then
  echo "    ВНИМАНИЕ: фактический IP (${DETECTED_IP}) отличается от заданного (${SERVER_IP})."
  echo "    Использую фактический — исправьте SERVER_IP в начале скрипта, если это ошибка."
  SERVER_IP="${DETECTED_IP}"
fi

# Случайный пароль веб-панели и его bcrypt-хэш
WG_UI_PASS="$(tr -dc "${PASS_ALPHABET}" </dev/urandom | head -c 20 || true)"
# ВАЖНО: </dev/null — иначе при запуске через curl|bash docker съест остаток скрипта
RAW_HASH="$(docker run --rm ghcr.io/wg-easy/wg-easy:14 wgpw "${WG_UI_PASS}" </dev/null | tr -d '\r\n')"
HASH="${RAW_HASH#PASSWORD_HASH=\'}"
HASH="${HASH%\'}"
# ВАЖНО: для docker run -e символы $ экранировать НЕ нужно!
# ($$ — синтаксис docker-compose; с ним хэш битый и пароль никогда не подойдёт)

mkdir -p /opt/wg-easy
DOCKER_PS="$(docker ps -a --format '{{.Names}}')"
if grep -q '^wg-easy$' <<<"${DOCKER_PS}"; then
  echo "    контейнер wg-easy уже существует — пересоздаю"
  docker rm -f wg-easy >/dev/null
fi

docker run -d \
  --name=wg-easy \
  -e WG_HOST="${SERVER_IP}" \
  -e PASSWORD_HASH="${HASH}" \
  -p "${WG_UDP_PORT}:51820/udp" \
  -p "${WG_UI_PORT}:51821/tcp" \
  -v /opt/wg-easy:/etc/wireguard \
  --cap-add=NET_ADMIN \
  --restart unless-stopped \
  ghcr.io/wg-easy/wg-easy:14

echo "==> [6/7] Node.js 22 + Claude Code"
if ! command -v node &>/dev/null || [[ "$(node -v 2>/dev/null | cut -dv -f2 | cut -d. -f1)" -lt 22 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
npm install -g @anthropic-ai/claude-code

echo "==> [6.5/7] Доступ к GitHub (SSH-ключ для пользователя ${NEW_USER})"
# Ключ без парольной фразы для удобства; можно пересоздать с passphrase вручную
sudo -u "${NEW_USER}" bash -c '
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  if [[ ! -f ~/.ssh/id_ed25519 ]]; then
    ssh-keygen -t ed25519 -C "vps-claude-setup" -f ~/.ssh/id_ed25519 -N "" -q
  fi
  # Удобный алиас: ssh github.com вместо ssh -T git@github.com
  grep -q "Host github.com" ~/.ssh/config 2>/dev/null || cat >> ~/.ssh/config <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  StrictHostKeyChecking accept-new
EOF
  chmod 600 ~/.ssh/config
'
GH_PUBKEY="$(cat /home/${NEW_USER}/.ssh/id_ed25519.pub)"

echo "==> [7/7] Сводка"
SUMMARY="/root/setup-summary.txt"
{
  echo "======================================================"
  echo " СЕРВЕР ГОТОВ — сохраните этот файл и удалите его с сервера"
  echo "======================================================"
  echo "IP сервера:            ${SERVER_IP}"
  echo "Рабочий пользователь:  ${NEW_USER}"
  if [[ -n "${USER_PASS:-}" ]]; then
    echo "Пароль пользователя:   ${USER_PASS}   (смените: passwd)"
  fi
  echo
  echo "--- SSH (защищён) ---"
  echo "НОВЫЙ порт SSH:        ${SSH_PORT}   (порт 22 закрыт!)"
  echo "Подключение:           ssh -p ${SSH_PORT} ${NEW_USER}@${SERVER_IP}"
  echo "Вход по паролю:        ${PW_AUTH}"
  echo "Разрешённые юзеры:     ${NEW_USER}, root (root — только по ключу)"
  echo
  echo "--- VPN (WireGuard / wg-easy) ---"
  echo "Панель управления:     http://${SERVER_IP}:${WG_UI_PORT}"
  echo "Пароль панели:         ${WG_UI_PASS}"
  echo "Порт WireGuard (UDP):  ${WG_UDP_PORT}"
  echo
  echo "ДАЛЬШЕ ПО ШАГАМ:"
  echo "1) НЕ закрывая текущую сессию, проверьте вход: ssh -p ${SSH_PORT} ${NEW_USER}@${SERVER_IP}"
  echo "2) Откройте панель wg-easy, создайте клиента, скачайте конфиг / QR."
  echo "3) Импортируйте конфиг в приложение WireGuard на домашнем ПК."
  echo "4) Проверьте whoer.net — должен быть IP ${SERVER_IP}."
  echo "5) С ВКЛЮЧЁННЫМ VPN зарегистрируйтесь/войдите на claude.ai."
  echo "6) Закройте панель снаружи:"
  echo "     sudo ufw deny ${WG_UI_PORT}/tcp"
  echo "   (открывать обратно: sudo ufw allow ${WG_UI_PORT}/tcp)"
  echo
  echo "--- Claude Code ---"
  echo "Вход:        ssh -p ${SSH_PORT} ${NEW_USER}@${SERVER_IP}"
  echo "Запуск:      tmux new -s work   →   claude"
  echo "Авторизация: ссылку из терминала открыть в браузере С VPN."
  echo
  echo "--- GitHub ---"
  echo "SSH-ключ пользователя ${NEW_USER} создан. Добавьте его в GitHub:"
  echo "  https://github.com/settings/ssh/new  (открыть с VPN или напрямую)"
  echo "Публичный ключ (скопируйте целиком в поле Key):"
  echo "${GH_PUBKEY}"
  echo "Проверка после добавления:  ssh -p ${SSH_PORT} ${NEW_USER}@${SERVER_IP}  →  ssh -T git@github.com"
  echo "Должно ответить: Hi <ваш_логин>! You've successfully authenticated."
  echo
  echo "--- Финал ---"
  echo "Сделайте снапшот в панели Virtarix (1 бесплатный в тарифе)."
  echo "======================================================"
} | tee "${SUMMARY}"

echo
echo "Готово. Сводка также сохранена в ${SUMMARY}"
echo "ВАЖНО: SSH теперь на порту ${SSH_PORT}. Не закрывая эту сессию,"
echo "проверьте вход:  ssh -p ${SSH_PORT} ${NEW_USER}@${SERVER_IP}"
