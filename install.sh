#!/usr/bin/env bash
#
# Instalador VeltrixUPGW (https://github.com/TelksBr/VeltrixUPGW)
# - Compila o binário a partir do código-fonte (Go)
# - Sobe como serviço systemd (inicia com o boot, reinicia sozinho se cair)
# - Abre as portas UDP necessárias no firewall (ufw/iptables)
# - Instala um comando de menu para gerenciar tudo depois de instalado
#
# Uso:
#   sudo bash install.sh
#
set -euo pipefail

# ============================================================
# CONFIGURAÇÕES (ajuste antes de rodar, se quiser)
# ============================================================
REPO_URL="https://github.com/TelksBr/VeltrixUPGW.git"
INSTALL_DIR="/opt/veltrixupgw"                 # onde o código-fonte fica
BIN_PATH="/usr/local/bin/veltrixupgw"          # binário final
CONF_DIR="/etc/veltrixupgw"
CONF_FILE="${CONF_DIR}/veltrixupgw.env"
SERVICE_NAME="veltrixupgw"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

MENU_CMD_NAME="Upg"                            # nome do comando do menu (ex: digitar "Upg" no terminal)
MENU_BIN_PATH="/usr/local/bin/${MENU_CMD_NAME}"

DEFAULT_TCP_LISTEN_PORT="7400"                 # porta TCP onde o gateway escuta os clientes
DEFAULT_METRICS_PORT="9091"                    # métricas Prometheus (fica só em 127.0.0.1)
DEFAULT_UDP_PORT_RANGE="10000-60000"           # faixa de portas UDP liberadas no firewall

# ============================================================
# Funções utilitárias
# ============================================================
c_green() { echo -e "\e[32m$*\e[0m"; }
c_yellow() { echo -e "\e[33m$*\e[0m"; }
c_red() { echo -e "\e[31m$*\e[0m"; }

need_root() {
    if [[ $EUID -ne 0 ]]; then
        c_red "Rode este script como root (sudo bash install.sh)."
        exit 1
    fi
}

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    else
        c_red "Gerenciador de pacotes não suportado automaticamente. Instale git/curl/go manualmente."
        exit 1
    fi
}

install_deps() {
    local pm
    pm=$(detect_pkg_manager)
    c_yellow "Instalando dependências (git, curl, build tools)..."
    case "$pm" in
        apt)
            apt-get update -y
            apt-get install -y git curl build-essential ufw
            ;;
        dnf)
            dnf install -y git curl gcc make firewalld
            ;;
        yum)
            yum install -y git curl gcc make firewalld
            ;;
    esac
}

install_go() {
    if command -v go >/dev/null 2>&1; then
        c_green "Go já está instalado: $(go version)"
        return
    fi
    c_yellow "Instalando Go 1.22+..."
    local GO_VERSION="1.22.5"
    local ARCH
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) GOARCH="amd64" ;;
        aarch64|arm64) GOARCH="arm64" ;;
        *) c_red "Arquitetura não suportada: $ARCH"; exit 1 ;;
    esac
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" -o /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm -f /tmp/go.tar.gz
    if ! grep -q '/usr/local/go/bin' /etc/profile; then
        echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
    fi
    export PATH=$PATH:/usr/local/go/bin
    c_green "Go instalado: $(go version)"
}

build_veltrix() {
    c_yellow "Baixando código-fonte do VeltrixUPGW..."
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    export PATH=$PATH:/usr/local/go/bin
    c_yellow "Compilando..."
    go build -trimpath -ldflags="-s -w" -o "$BIN_PATH" ./cmd/udpgw
    chmod +x "$BIN_PATH"
    c_green "Binário instalado em ${BIN_PATH}"
}

write_config() {
    mkdir -p "$CONF_DIR"
    cat > "$CONF_FILE" <<EOF
# Configuração do VeltrixUPGW - edite e depois rode: systemctl restart ${SERVICE_NAME}
TCP_LISTEN=0.0.0.0:${TCP_LISTEN_PORT}
METRICS_LISTEN=127.0.0.1:${METRICS_PORT}
MAX_CLIENTS=10000
# Ajustes do caminho de resposta UDP -> TCP -> cliente.
# Valores maiores reduzem descartes sob rajadas, mas consomem mais memória.
WRITE_CHAN=4096
UDP_RBUF=1048576
UDP_WBUF=1048576
MAP_TTL=90s
IDLE_TIMEOUT=2m
EOF
    c_green "Config gravada em ${CONF_FILE}"
}

update_config() {
    # Mantém a configuração existente e apenas acrescenta os novos ajustes.
    if [[ ! -f "$CONF_FILE" ]]; then
        c_red "Configuração não encontrada em ${CONF_FILE}. Execute a instalação normal primeiro."
        exit 1
    fi

    local changed=0
    for setting in \
        "WRITE_CHAN=4096" \
        "UDP_RBUF=1048576" \
        "UDP_WBUF=1048576"; do
        local key="${setting%%=*}"
        if ! grep -q "^${key}=" "$CONF_FILE"; then
            printf '%s\n' "$setting" >> "$CONF_FILE"
            changed=1
        fi
    done

    if [[ "$changed" -eq 1 ]]; then
        c_green "Novos ajustes de resposta UDP adicionados à configuração."
    else
        c_yellow "A configuração já contém os ajustes de resposta UDP."
    fi
}

write_systemd_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=VeltrixUPGW - Gateway UDP sobre TCP (BadVPN udpgw)
After=network.target

[Service]
Type=simple
EnvironmentFile=${CONF_FILE}
ExecStart=${BIN_PATH} -listen \${TCP_LISTEN} -metrics-listen \${METRICS_LISTEN} -max-clients \${MAX_CLIENTS} -write-chan \${WRITE_CHAN} -udp-rbuf \${UDP_RBUF} -udp-wbuf \${UDP_WBUF} -map-ttl \${MAP_TTL} -idle-timeout \${IDLE_TIMEOUT}
Restart=always
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
    c_green "Serviço systemd '${SERVICE_NAME}' criado e iniciado."
}

open_firewall() {
    c_yellow "Abrindo portas no firewall..."
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${TCP_LISTEN_PORT}"/tcp || true
        ufw allow "${UDP_PORT_RANGE}"/udp || true
        # ufw só é ativado se o usuário já tiver o ufw habilitado; não forçamos enable aqui.
        c_green "Regras ufw adicionadas (TCP ${TCP_LISTEN_PORT}, UDP ${UDP_PORT_RANGE})."
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${TCP_LISTEN_PORT}/tcp" || true
        firewall-cmd --permanent --add-port="${UDP_PORT_RANGE}/udp" || true
        firewall-cmd --reload || true
        c_green "Regras firewalld adicionadas (TCP ${TCP_LISTEN_PORT}, UDP ${UDP_PORT_RANGE})."
    else
        c_yellow "Nenhum firewall gerenciado (ufw/firewalld) encontrado; usando iptables diretamente."
        iptables -I INPUT -p tcp --dport "${TCP_LISTEN_PORT}" -j ACCEPT || true
        IFS='-' read -r UDP_START UDP_END <<< "${UDP_PORT_RANGE}"
        iptables -I INPUT -p udp --dport "${UDP_START}:${UDP_END}" -j ACCEPT || true
    fi
}

write_menu_script() {
    cat > "$MENU_BIN_PATH" <<'MENU_EOF'
#!/usr/bin/env bash
# Menu de gerenciamento do VeltrixUPGW
set -euo pipefail

SERVICE_NAME="veltrixupgw"
CONF_FILE="/etc/veltrixupgw/veltrixupgw.env"
BIN_PATH="/usr/local/bin/veltrixupgw"

c_green() { echo -e "\e[32m$*\e[0m"; }
c_yellow() { echo -e "\e[33m$*\e[0m"; }
c_red() { echo -e "\e[31m$*\e[0m"; }

pause() { read -rp "Pressione ENTER para continuar..." _; }

status() {
    systemctl status "$SERVICE_NAME" --no-pager -l || true
}

open_udp_range() {
    read -rp "Digite a faixa de portas UDP a abrir (ex: 20000-30000) ou uma porta única: " RANGE
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${RANGE}"/udp
        c_green "Faixa ${RANGE}/udp liberada via ufw."
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${RANGE}/udp"
        firewall-cmd --reload
        c_green "Faixa ${RANGE}/udp liberada via firewalld."
    else
        if [[ "$RANGE" == *-* ]]; then
            IFS='-' read -r S E <<< "$RANGE"
            iptables -I INPUT -p udp --dport "${S}:${E}" -j ACCEPT
        else
            iptables -I INPUT -p udp --dport "${RANGE}" -j ACCEPT
        fi
        c_green "Faixa ${RANGE}/udp liberada via iptables."
    fi
}

change_tcp_port() {
    read -rp "Nova porta TCP de escuta (atual em ${CONF_FILE}): " NEWPORT
    sed -i "s/^TCP_LISTEN=.*/TCP_LISTEN=0.0.0.0:${NEWPORT}/" "$CONF_FILE"
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${NEWPORT}"/tcp || true
    fi
    systemctl restart "$SERVICE_NAME"
    c_green "Porta TCP alterada para ${NEWPORT} e serviço reiniciado."
}

show_config() {
    echo "----- ${CONF_FILE} -----"
    cat "$CONF_FILE"
    echo "-------------------------"
}

update_service() {
    local updater="/tmp/velt-update.sh"
    c_yellow "Baixando a versão mais recente do instalador..."
    curl -fsSL "https://raw.githubusercontent.com/Willapela/Velt/main/install.sh" -o "$updater"
    chmod +x "$updater"
    if [[ "$EUID" -eq 0 ]]; then
        bash "$updater" --update
    else
        sudo bash "$updater" --update
    fi
    rm -f "$updater"
}

uninstall_all() {
    read -rp "Tem certeza que quer desinstalar o VeltrixUPGW? (s/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[sS]$ ]]; then
        systemctl stop "$SERVICE_NAME" || true
        systemctl disable "$SERVICE_NAME" || true
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
        rm -f "$BIN_PATH"
        rm -rf /etc/veltrixupgw
        rm -rf /opt/veltrixupgw
        c_yellow "VeltrixUPGW removido. O comando de menu ainda existe; apague-o manualmente se quiser:"
        echo "  rm -f $0"
    fi
}

main_menu() {
    while true; do
        clear
        echo "============================================"
        echo "   VeltrixUPGW - Painel de Gerenciamento"
        echo "============================================"
        echo " 1) Ver status do serviço"
        echo " 2) Iniciar serviço"
        echo " 3) Parar serviço"
        echo " 4) Reiniciar serviço"
        echo " 5) Ver logs em tempo real"
        echo " 6) Ver configuração atual"
        echo " 7) Trocar porta TCP de escuta"
        echo " 8) Abrir mais portas UDP no firewall"
        echo " 9) Desinstalar"
        echo "10) Atualizar instalação"
        echo " 0) Sair"
        echo "============================================"
        read -rp "Escolha uma opção: " OPT
        case "$OPT" in
            1) status; pause ;;
            2) systemctl start "$SERVICE_NAME"; c_green "Iniciado."; pause ;;
            3) systemctl stop "$SERVICE_NAME"; c_yellow "Parado."; pause ;;
            4) systemctl restart "$SERVICE_NAME"; c_green "Reiniciado."; pause ;;
            5) journalctl -u "$SERVICE_NAME" -f ;;
            6) show_config; pause ;;
            7) change_tcp_port; pause ;;
            8) open_udp_range; pause ;;
            9) uninstall_all; pause ;;
            10) update_service; pause ;;
            0) exit 0 ;;
            *) c_red "Opção inválida."; pause ;;
        esac
    done
}

main_menu
MENU_EOF
    chmod +x "$MENU_BIN_PATH"
    c_green "Comando de menu instalado: digite '${MENU_CMD_NAME}' em qualquer lugar do servidor para abrir o painel."
}

# ============================================================
# Execução
# ============================================================
UPDATE_MODE=false
if [[ "${1:-}" == "--update" ]]; then
    UPDATE_MODE=true
elif [[ $# -gt 0 ]]; then
    c_red "Uso: sudo bash install.sh [--update]"
    exit 1
fi

need_root
install_deps
install_go

if [[ "$UPDATE_MODE" == true ]]; then
    if [[ ! -f "$CONF_FILE" ]]; then
        c_red "Instalação existente não encontrada em ${CONF_FILE}."
        exit 1
    fi

    # Importa TCP_LISTEN, METRICS_LISTEN e MAX_CLIENTS da instalação atual.
    set -a
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    set +a
    METRICS_PORT="${METRICS_LISTEN##*:}"

    build_veltrix
    update_config
    write_systemd_service
    write_menu_script

    c_green "Atualização concluída sem alterar a porta, os limites ou o firewall."
    c_green "O menu de gerenciamento também foi atualizado."
    exit 0
fi

echo ""
read -rp "Porta TCP de escuta do gateway [padrão ${DEFAULT_TCP_LISTEN_PORT}]: " TCP_LISTEN_PORT
TCP_LISTEN_PORT="${TCP_LISTEN_PORT:-$DEFAULT_TCP_LISTEN_PORT}"

read -rp "Faixa de portas UDP a liberar no firewall [padrão ${DEFAULT_UDP_PORT_RANGE}]: " UDP_PORT_RANGE
UDP_PORT_RANGE="${UDP_PORT_RANGE:-$DEFAULT_UDP_PORT_RANGE}"

read -rp "Nome do comando de menu (o que você vai digitar pra abrir o painel) [padrão ${MENU_CMD_NAME}, ENTER para manter]: " CUSTOM_MENU_NAME
if [[ -n "${CUSTOM_MENU_NAME:-}" ]]; then
    MENU_CMD_NAME="$CUSTOM_MENU_NAME"
    MENU_BIN_PATH="/usr/local/bin/${MENU_CMD_NAME}"
fi

METRICS_PORT="$DEFAULT_METRICS_PORT"

build_veltrix
write_config
write_systemd_service
open_firewall
write_menu_script

echo ""
c_green "============================================================"
c_green " Instalação concluída!"
c_green "============================================================"
echo " Serviço:        systemctl status ${SERVICE_NAME}"
echo " Porta TCP:      ${TCP_LISTEN_PORT}"
echo " Portas UDP:     ${UDP_PORT_RANGE} (liberadas no firewall)"
echo " Painel/menu:    digite '${MENU_CMD_NAME}' no terminal"
echo " Config:         ${CONF_FILE}"
c_green "============================================================"
