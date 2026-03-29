#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/TelegramMessenger/MTProxy"
INSTALL_DIR="/root/MTProxy"
BIN_DIR="/root/MTProxy/objs/bin"

SERVICE_FILE="/etc/systemd/system/mtproxy.service"
WATCHDOG_SCRIPT="/usr/local/sbin/mtproxy-watchdog.sh"
WATCHDOG_SERVICE="/etc/systemd/system/mtproxy-watchdog.service"
WATCHDOG_TIMER="/etc/systemd/system/mtproxy-watchdog.timer"

UPDATE_SCRIPT="/usr/local/sbin/mtproxy-update-config.sh"
UPDATE_SERVICE="/etc/systemd/system/mtproxy-update-config.service"
UPDATE_TIMER="/etc/systemd/system/mtproxy-update-config.timer"

REBOOT_SERVICE="/etc/systemd/system/daily-reboot.service"
REBOOT_TIMER="/etc/systemd/system/daily-reboot.timer"

SYSCTL_FILE="/etc/sysctl.d/99-mtproxy-pid.conf"

STATS_PORT="8888"
AD_DOMAIN="ya.ru"
AD_TAG="da9400e02d96b1155472bdb7bb0d1ca0"
WORKERS="2"
SERVICE_NAME="mtproxy.service"

STEP=0

step() {
  STEP=$((STEP + 1))
  echo "${STEP}. $1"
}

run_quiet() {
  "$@" >/dev/null 2>&1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || {
    echo "Запусти скрипт от root"
    exit 1
  }
}

detect_os() {
  [[ -f /etc/os-release ]] || {
    echo "/etc/os-release не найден"
    exit 1
  }

  . /etc/os-release

  case "${ID:-}" in
    debian|ubuntu) ;;
    *)
      echo "Поддерживаются только Debian/Ubuntu"
      exit 1
      ;;
  esac

  VERSION_ID="${VERSION_ID:-0}"

  if [[ "${ID}" == "debian" ]]; then
    dpkg --compare-versions "${VERSION_ID}" ge "12" || {
      echo "Нужен Debian 12+"
      exit 1
    }
  fi

  if [[ "${ID}" == "ubuntu" ]]; then
    dpkg --compare-versions "${VERSION_ID}" ge "20.04" || {
      echo "Нужен Ubuntu 20.04+"
      exit 1
    }
  fi
}

ask_port() {
  read -rp "Введите порт MTProxy [443]: " PROXY_PORT
  PROXY_PORT="${PROXY_PORT:-443}"

  if ! [[ "${PROXY_PORT}" =~ ^[0-9]+$ ]] || (( PROXY_PORT < 1 || PROXY_PORT > 65535 )); then
    echo "Некорректный порт"
    exit 1
  fi
}

install_packages() {
  run_quiet apt-get update -y
  run_quiet env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git curl build-essential libssl-dev zlib1g-dev \
    openssl xxd ca-certificates iproute2 net-tools procps lsof
}

clone_and_build() {
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    run_quiet git -C "${INSTALL_DIR}" fetch --all --tags
    run_quiet git -C "${INSTALL_DIR}" reset --hard origin/master
    run_quiet git -C "${INSTALL_DIR}" clean -fd
  else
    run_quiet rm -rf "${INSTALL_DIR}"
    run_quiet git clone "${REPO_URL}" "${INSTALL_DIR}"
  fi

  run_quiet make -C "${INSTALL_DIR}"
  test -x "${BIN_DIR}/mtproto-proxy"
}

download_proxy_files() {
  run_quiet curl -fsSL https://core.telegram.org/getProxySecret -o "${BIN_DIR}/proxy-secret"
  run_quiet curl -fsSL https://core.telegram.org/getProxyConfig -o "${BIN_DIR}/proxy-multi.conf"
  run_quiet chmod 600 "${BIN_DIR}/proxy-secret" "${BIN_DIR}/proxy-multi.conf"
}

detect_public_host() {
  PUBLIC_HOST="$(curl -4fsSL https://api.ipify.org 2>/dev/null || true)"
  [[ -n "${PUBLIC_HOST}" ]] || PUBLIC_HOST="YOUR_IP"
}

generate_server_secret() {
  SERVER_SECRET="$(openssl rand -hex 16)"
  [[ "${#SERVER_SECRET}" -eq 32 ]] || {
    echo "Не удалось сгенерировать SERVER_SECRET"
    exit 1
  }
}

build_client_secret() {
  local domain_hex
  domain_hex="$(printf '%s' "${AD_DOMAIN}" | xxd -ps -c 256 | tr -d '\n')"
  CLIENT_SECRET="ee${SERVER_SECRET}${domain_hex}"
}

set_pid_limit() {
  cat > "${SYSCTL_FILE}" <<'EOF'
kernel.pid_max=65535
EOF
  run_quiet sysctl --system
}

create_main_service() {
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=MTProxy
After=network.target
StartLimitIntervalSec=300
StartLimitBurst=20

[Service]
LimitNOFILE=1000000
LimitNPROC=1000000
TasksMax=infinity
Type=simple
User=root
WorkingDirectory=${BIN_DIR}
ExecStart=${BIN_DIR}/mtproto-proxy -u root -p ${STATS_PORT} -H ${PROXY_PORT} -S ${SERVER_SECRET} -D ${AD_DOMAIN} --aes-pwd proxy-secret proxy-multi.conf -M ${WORKERS} -P ${AD_TAG} --http-stats
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  run_quiet systemctl daemon-reload
  run_quiet systemctl enable --now mtproxy.service
}

create_update_timer() {
  cat > "${UPDATE_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

TMP_FILE="$(mktemp)"
curl -fsSL https://core.telegram.org/getProxyConfig -o "${TMP_FILE}" >/dev/null 2>&1
install -m 600 "${TMP_FILE}" /root/MTProxy/objs/bin/proxy-multi.conf >/dev/null 2>&1
rm -f "${TMP_FILE}" >/dev/null 2>&1

systemctl restart mtproxy.service >/dev/null 2>&1
EOF

  run_quiet chmod +x "${UPDATE_SCRIPT}"

  cat > "${UPDATE_SERVICE}" <<EOF
[Unit]
Description=Update MTProxy proxy-multi.conf

[Service]
Type=oneshot
ExecStart=${UPDATE_SCRIPT}
EOF

  cat > "${UPDATE_TIMER}" <<'EOF'
[Unit]
Description=Daily MTProxy config update

[Timer]
OnBootSec=10min
OnUnitActiveSec=1d
Persistent=true

[Install]
WantedBy=timers.target
EOF

  run_quiet systemctl daemon-reload
  run_quiet systemctl enable --now mtproxy-update-config.timer
}

create_watchdog() {
  cat > "${WATCHDOG_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SERVICE="${SERVICE_NAME}"
PORT="${PROXY_PORT}"

service_ok() {
  systemctl is-active --quiet "\${SERVICE}" >/dev/null 2>&1
}

port_ok() {
  ss -lnt 2>/dev/null | grep -q ":\\\${PORT}[[:space:]]"
}

restart_service() {
  systemctl restart "\${SERVICE}" >/dev/null 2>&1
}

main() {
  if ! service_ok; then
    restart_service
    exit 0
  fi

  if ! port_ok; then
    restart_service
    exit 0
  fi

  exit 0
}

main "\$@"
EOF

  run_quiet chmod +x "${WATCHDOG_SCRIPT}"

  cat > "${WATCHDOG_SERVICE}" <<EOF
[Unit]
Description=MTProxy watchdog

[Service]
Type=oneshot
ExecStart=${WATCHDOG_SCRIPT}
EOF

  cat > "${WATCHDOG_TIMER}" <<'EOF'
[Unit]
Description=Run MTProxy watchdog every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  run_quiet systemctl daemon-reload
  run_quiet systemctl enable --now mtproxy-watchdog.timer
}

create_daily_reboot_timer() {
  cat > "${REBOOT_SERVICE}" <<'EOF'
[Unit]
Description=Daily server reboot

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl reboot
EOF

  cat > "${REBOOT_TIMER}" <<'EOF'
[Unit]
Description=Run daily server reboot

[Timer]
OnCalendar=*-*-* 05:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  run_quiet systemctl daemon-reload
  run_quiet systemctl enable --now daily-reboot.timer
}

show_result() {
  TG_LINK="tg://proxy?server=${PUBLIC_HOST}&port=${PROXY_PORT}&secret=${CLIENT_SECRET}"
  HTTPS_LINK="https://t.me/proxy?server=${PUBLIC_HOST}&port=${PROXY_PORT}&secret=${CLIENT_SECRET}"

  echo
  echo "================ RESULT ================"
  echo "Сервер:        ${PUBLIC_HOST}"
  echo "Порт:          ${PROXY_PORT}"
  echo "Secret: ${CLIENT_SECRET}"
  echo
  echo "HTTPS: ${HTTPS_LINK}"
  echo "TG:    ${TG_LINK}"
  echo "========================================"
}

main() {
  require_root

  step "Проверка системы"
  detect_os

  step "Выбор порта"
  ask_port

  step "Установка зависимостей"
  install_packages

  step "Загрузка и сборка MTProxy"
  clone_and_build

  step "Загрузка файлов конфигурации Telegram"
  download_proxy_files

  step "Определение внешнего IP"
  detect_public_host

  step "Генерация server secret"
  generate_server_secret

  step "Формирование клиентского secret"
  build_client_secret

  step "Настройка лимита PID"
  set_pid_limit

  step "Создание и запуск сервиса MTProxy"
  create_main_service

  step "Настройка автообновления конфигурации"
  create_update_timer

  step "Настройка watchdog"
  create_watchdog

  step "Настройка ежедневной перезагрузки"
  create_daily_reboot_timer

  step "Вывод ссылок"
  show_result
}

main "$@"
