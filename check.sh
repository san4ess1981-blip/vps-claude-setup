#!/usr/bin/env bash
# =============================================================
# check.sh — проверка сервера после выполнения setup.sh
#
# Запуск С ЛОКАЛЬНОЙ МАШИНЫ (не на сервере):
#   bash check.sh                              # root@146.103.57.168, порт 51222
#   bash check.sh dev@146.103.57.168           # другой пользователь/хост
#   bash check.sh root@146.103.57.168 51222    # явно указать SSH-порт
#
# Для полной проверки (UFW, fail2ban, sshd -T, сводка) нужен root —
# при запуске от обычного пользователя эти пункты будут [SKIP].
# Код выхода: 0 — всё в порядке, 1 — есть проблемы.
# =============================================================

set -uo pipefail

TARGET="${1:-root@146.103.57.168}"
PORT="${2:-51222}"

echo "Проверяю сервер через SSH: ${TARGET} (порт ${PORT})..."
echo

ssh -o ConnectTimeout=10 -p "${PORT}" "${TARGET}" "bash -s -- ${PORT}" <<'REMOTE'
SSH_PORT="${1:-51222}"

PASS=0; FAIL=0; SKIP=0
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
skip() { printf '\033[1;33m[SKIP]\033[0m %s\n' "$*"; SKIP=$((SKIP+1)); }

check() { # check "описание" команда [аргументы...]
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1
[ "$IS_ROOT" -eq 0 ] && echo "(запуск не от root — часть проверок будет пропущена)"

echo "== Пользователь dev =="
check "пользователь dev существует" id dev
check "dev входит в группу sudo"   bash -c 'id -nG dev | grep -qw sudo'
check "dev входит в группу docker" bash -c 'id -nG dev | grep -qw docker'

echo "== Базовые пакеты =="
for p in curl git tmux ufw fail2ban unattended-upgrades; do
  check "пакет $p установлен" dpkg -s "$p"
done
check "автообновления безопасности включены" systemctl is-enabled unattended-upgrades

echo "== SSH (защита) =="
check "sshd слушает порт ${SSH_PORT}" bash -c "ss -tln | grep -qE ':${SSH_PORT}[[:space:]]'"
if [ "$IS_ROOT" -eq 1 ]; then
  check "sshd: AllowUsers настроен" bash -c 'sshd -T 2>/dev/null | grep -qi "^allowusers "'
  check "sshd: root только по ключу" bash -c 'sshd -T 2>/dev/null | grep -qi "^permitrootlogin prohibit-password"'
  if sshd -T 2>/dev/null | grep -qi '^passwordauthentication no'; then
    ok "sshd: вход по паролю отключён"
  else
    warn "sshd: вход по паролю ВКЛЮЧЁН (нет SSH-ключей? добавьте ключ и перезапустите setup.sh)"
  fi
else
  skip "эффективный конфиг sshd (нужен root)"
fi

echo "== Файрвол и fail2ban =="
if [ "$IS_ROOT" -eq 1 ]; then
  check "UFW активен" bash -c 'ufw status | grep -q "Status: active"'
  check "UFW: открыт ${SSH_PORT}/tcp" bash -c "ufw status | grep -qE '^${SSH_PORT}/tcp[[:space:]]'"
  for rule in "51820/udp" "51821/tcp"; do
    check "UFW: открыт $rule" bash -c "ufw status | grep -qE '^${rule}[[:space:]]'"
  done
  if [ "${SSH_PORT}" != "22" ]; then
    if ufw status | grep -qE '^22/tcp[[:space:]]'; then
      bad "UFW: старый порт 22/tcp всё ещё открыт"
    else
      ok "UFW: старый порт 22/tcp закрыт"
    fi
  fi
  check "fail2ban: jail sshd активен" fail2ban-client status sshd
else
  skip "UFW и fail2ban jail (нужен root)"
fi
check "fail2ban запущен" systemctl is-active fail2ban

echo "== Docker =="
check "служба docker активна" systemctl is-active docker
check "docker CLI доступен" bash -c 'docker version --format "{{.Server.Version}}"'

echo "== WireGuard (wg-easy) =="
check "контейнер wg-easy запущен" bash -c 'docker ps --format "{{.Names}}" | grep -qx wg-easy'
check "панель wg-easy отвечает на 51821" bash -c '
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:51821/)
  [ "$code" = 200 ] || [ "$code" = 301 ] || [ "$code" = 302 ]'
check "WireGuard слушает UDP 51820" bash -c 'ss -uln | grep -q ":51820 "'

echo "== Node.js и Claude Code =="
check "Node.js версии >= 22" bash -c '
  v=$(node -v 2>/dev/null | sed "s/v//; s/\..*//")
  [ -n "$v" ] && [ "$v" -ge 22 ]'
check "claude CLI установлен" bash -c 'command -v claude'
check "claude отвечает (--version)" bash -c 'claude --version'

echo "== GitHub и прочее =="
check "SSH-ключ dev для GitHub создан" bash -c '[ -s /home/dev/.ssh/id_ed25519.pub ]'
if [ "$IS_ROOT" -eq 1 ]; then
  check "сводка /root/setup-summary.txt на месте" bash -c '[ -f /root/setup-summary.txt ]'
else
  skip "сводка /root/setup-summary.txt (нужен root)"
fi

echo
echo "==============================================="
printf "ИТОГО: \033[1;32m%d OK\033[0m, \033[1;31m%d FAIL\033[0m, \033[1;33m%d SKIP\033[0m\n" "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -eq 0 ]; then
  echo "Сервер настроен корректно."
  exit 0
else
  echo "Есть проблемы — см. строки [FAIL] выше."
  exit 1
fi
REMOTE
