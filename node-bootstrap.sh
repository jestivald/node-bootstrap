#!/usr/bin/env bash
# ============================================================================
#  node-bootstrap.sh  —  One-shot Remnawave / xray node provisioner
# ----------------------------------------------------------------------------
#  What it does (in order):
#    1. Apt update + essentials (curl, ufw, chrony, jq, htop, ...)
#    2. Kernel / network tuning  (BBR + fq, buffers, backlog, fs.file-max)
#    3. ulimits 1M (system-wide + systemd + docker)
#    4. 2G swapfile (if none), swappiness=10
#    5. journald cap 200 MB
#    6. Docker CE + Compose v2  (+ daemon.json with log rotation & ulimits)
#    7. UFW: allow 22, 443/tcp, 443/udp, 2222/tcp   (default deny in)
#    8. Prompts you to PASTE a full docker-compose.yml into the terminal,
#       then `docker compose up -d` in /opt/node
#
#  Usage (one-liner, interactive — paste compose when asked, finish with Ctrl-D):
#    bash <(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/node-bootstrap.sh)
#
#  Or download first:
#    curl -fsSLO https://raw.githubusercontent.com/<user>/<repo>/main/node-bootstrap.sh
#    bash node-bootstrap.sh
#
#  Optional flags:
#    --compose-file=/path/to/file.yml   skip the paste prompt, use this file
#    --env-file=/path/to/.env           copy this .env next to compose
#    --dir=/opt/node                    install dir (default: /opt/node)
#    --extra-ports="80,8443,51820/udp"  extra UFW allow rules
#    --no-swap   --no-ufw   --no-docker --no-compose   skip individual steps
#    --yes       don't ask for confirmation
# ============================================================================
set -euo pipefail

# ---------- colors / logging ------------------------------------------------
if [[ -t 1 ]]; then
    C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'
    C_B=$'\033[0;34m'; C_M=$'\033[0;35m'; C_N=$'\033[0m';    C_BOLD=$'\033[1m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_M=""; C_N=""; C_BOLD=""
fi
log()   { echo "${C_B}[*]${C_N} $*"; }
ok()    { echo "${C_G}[✓]${C_N} $*"; }
warn()  { echo "${C_Y}[!]${C_N} $*"; }
die()   { echo "${C_R}[✗]${C_N} $*" >&2; exit 1; }
step()  { echo; echo "${C_BOLD}${C_M}━━━ $* ━━━${C_N}"; }

# ---------- defaults --------------------------------------------------------
INSTALL_DIR="/opt/node"
COMPOSE_FILE=""
ENV_FILE=""
EXTRA_PORTS=""
DO_SWAP=1 DO_UFW=1 DO_DOCKER=1 DO_COMPOSE=1 ASSUME_YES=0

for arg in "$@"; do
    case "$arg" in
        --compose-file=*) COMPOSE_FILE="${arg#*=}" ;;
        --env-file=*)     ENV_FILE="${arg#*=}" ;;
        --dir=*)          INSTALL_DIR="${arg#*=}" ;;
        --extra-ports=*)  EXTRA_PORTS="${arg#*=}" ;;
        --no-swap)        DO_SWAP=0 ;;
        --no-ufw)         DO_UFW=0 ;;
        --no-docker)      DO_DOCKER=0 ;;
        --no-compose)     DO_COMPOSE=0 ;;
        --yes|-y)         ASSUME_YES=1 ;;
        -h|--help)        sed -n '2,40p' "$0"; exit 0 ;;
        *) die "Unknown arg: $arg" ;;
    esac
done

# ---------- preflight -------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root (sudo -i)."
. /etc/os-release 2>/dev/null || die "Cannot read /etc/os-release"
case "$ID" in
    ubuntu|debian) : ;;
    *) warn "Tested on Ubuntu/Debian; detected $ID $VERSION_ID — continuing anyway." ;;
esac

echo "${C_BOLD}Node bootstrap${C_N}"
echo "  Host:     $(hostname) ($(hostname -I 2>/dev/null | awk '{print $1}'))"
echo "  OS:       ${PRETTY_NAME:-$ID $VERSION_ID}"
echo "  Install:  ${INSTALL_DIR}"
echo "  Ports:    22, 443/tcp, 443/udp, 2222/tcp${EXTRA_PORTS:+, $EXTRA_PORTS}"
echo
if [[ $ASSUME_YES -eq 0 ]]; then
    read -r -p "Proceed? [y/N] " ans </dev/tty
    [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted."
fi

export DEBIAN_FRONTEND=noninteractive

# ---------- 1. apt essentials ----------------------------------------------
step "1/7  Updating apt + installing essentials"
apt-get update -y
apt-get upgrade -y
apt-get install -y curl wget gnupg ca-certificates lsb-release \
    software-properties-common ufw htop iftop iotop jq \
    net-tools dnsutils chrony unzip
systemctl enable --now chrony >/dev/null 2>&1 || true
ok "Base packages installed"

# ---------- 2. sysctl tuning -----------------------------------------------
step "2/7  Kernel / network tuning (BBR + fq)"
cat >/etc/sysctl.d/99-node-tune.conf <<'EOF'
# --- TCP congestion: BBR + fq ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Socket buffers (1 Gbps+) ---
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# --- Backlog / conntrack ---
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# --- Fast Open / SACK / MTU probe ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_sack = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072

# --- IP forward (docker / xray) ---
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# --- Ports / file handles ---
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = 2097152
fs.nr_open  = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches   = 524288

# --- SYN flood ---
net.ipv4.tcp_syncookies = 1
EOF
sysctl --system >/dev/null
ok "BBR: $(sysctl -n net.ipv4.tcp_congestion_control) / qdisc: $(sysctl -n net.core.default_qdisc)"

# ---------- 3. ulimits ------------------------------------------------------
step "3/7  ulimits (1M open files)"
cat >/etc/security/limits.d/99-node.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc  1048576
* hard nproc  1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
mkdir -p /etc/systemd/system.conf.d
cat >/etc/systemd/system.conf.d/limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF
ok "ulimits pinned to 1048576"

# ---------- 4. swap ---------------------------------------------------------
if [[ $DO_SWAP -eq 1 ]]; then
    step "4/7  Swap (2G if missing)"
    if ! swapon --show | grep -q .; then
        if [ ! -f /swapfile ]; then
            fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null
        fi
        swapon /swapfile || true
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        ok "Swap 2G active"
    else
        ok "Swap already present: $(swapon --show --noheadings | awk '{print $1,$3}' | tr '\n' '; ')"
    fi
    echo 'vm.swappiness=10' >/etc/sysctl.d/99-swap.conf
    sysctl -p /etc/sysctl.d/99-swap.conf >/dev/null
else
    warn "Skipping swap (--no-swap)"
fi

# ---------- 5. journald cap + extras ---------------------------------------
step "5/7  journald size cap + misc"
mkdir -p /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/size.conf <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
EOF
systemctl restart systemd-journald || true
ok "journald capped at 200M"

# ---------- 6. docker -------------------------------------------------------
if [[ $DO_DOCKER -eq 1 ]]; then
    step "6/7  Docker CE + Compose v2"
    if ! command -v docker >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com | sh
    else
        ok "Docker already installed: $(docker --version)"
    fi
    mkdir -p /etc/docker
    cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "20m", "max-file": "3"},
  "default-ulimits": {"nofile": {"Name": "nofile", "Soft": 1048576, "Hard": 1048576}},
  "live-restore": true
}
EOF
    systemctl enable --now docker
    systemctl restart docker
    ok "Docker $(docker --version | awk '{print $3}' | tr -d ,) / Compose $(docker compose version --short 2>/dev/null || echo '?')"
else
    warn "Skipping Docker (--no-docker)"
fi

# ---------- 7. ufw ----------------------------------------------------------
if [[ $DO_UFW -eq 1 ]]; then
    step "7/7  UFW firewall"
    ufw --force reset >/dev/null
    ufw default deny incoming  >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow 22/tcp   comment 'SSH'                    >/dev/null
    ufw allow 443/tcp  comment 'xray tls/reality'       >/dev/null
    ufw allow 443/udp  comment 'xray quic/hysteria'     >/dev/null
    ufw allow 2222/tcp comment 'remnawave node api'     >/dev/null
    if [[ -n "$EXTRA_PORTS" ]]; then
        IFS=',' read -ra PORTS <<< "$EXTRA_PORTS"
        for p in "${PORTS[@]}"; do
            p="${p// /}"; [[ -z "$p" ]] && continue
            ufw allow "$p" comment 'extra' >/dev/null
            log "UFW allow $p"
        done
    fi
    ufw --force enable >/dev/null
    ok "UFW enabled: $(ufw status | grep -c ALLOW) rules"
else
    warn "Skipping UFW (--no-ufw)"
fi

# ---------- compose deploy --------------------------------------------------
if [[ $DO_COMPOSE -eq 1 ]]; then
    step "Deploying docker-compose stack"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    if [[ -n "$COMPOSE_FILE" ]]; then
        [[ -f "$COMPOSE_FILE" ]] || die "Compose file not found: $COMPOSE_FILE"
        cp "$COMPOSE_FILE" "$INSTALL_DIR/docker-compose.yml"
        ok "Copied compose from $COMPOSE_FILE"
    else
        echo
        echo "${C_BOLD}Paste your full docker-compose.yml below.${C_N}"
        echo "When done, press ${C_BOLD}Ctrl-D${C_N} on an empty line to finish."
        echo "(or type a single line with   ${C_BOLD}__END__${C_N}   to finish)"
        echo "---------------------------- BEGIN PASTE ----------------------------"
        # Read from /dev/tty so it works even when script was piped from curl
        tmp="$(mktemp)"
        while IFS= read -r line </dev/tty; do
            [[ "$line" == "__END__" ]] && break
            printf '%s\n' "$line" >>"$tmp"
        done
        echo "----------------------------- END PASTE -----------------------------"
        [[ -s "$tmp" ]] || die "Empty compose — aborting."
        mv "$tmp" "$INSTALL_DIR/docker-compose.yml"
        ok "Compose saved to $INSTALL_DIR/docker-compose.yml ($(wc -l <"$INSTALL_DIR/docker-compose.yml") lines)"
    fi

    if [[ -n "$ENV_FILE" ]]; then
        [[ -f "$ENV_FILE" ]] || die ".env file not found: $ENV_FILE"
        cp "$ENV_FILE" "$INSTALL_DIR/.env"
        chmod 600 "$INSTALL_DIR/.env"
        ok "Copied .env"
    elif [[ ! -f "$INSTALL_DIR/.env" ]]; then
        echo
        read -r -p "Paste a .env file too? [y/N] " want_env </dev/tty
        if [[ "$want_env" =~ ^[Yy]$ ]]; then
            echo "Paste .env contents. Ctrl-D or __END__ to finish."
            echo "---------------------------- BEGIN PASTE ----------------------------"
            tmp="$(mktemp)"
            while IFS= read -r line </dev/tty; do
                [[ "$line" == "__END__" ]] && break
                printf '%s\n' "$line" >>"$tmp"
            done
            echo "----------------------------- END PASTE -----------------------------"
            if [[ -s "$tmp" ]]; then
                mv "$tmp" "$INSTALL_DIR/.env"
                chmod 600 "$INSTALL_DIR/.env"
                ok ".env saved"
            else
                rm -f "$tmp"
                warn "Empty .env — skipping"
            fi
        fi
    fi

    log "docker compose pull"
    docker compose pull
    log "docker compose up -d"
    docker compose up -d
    sleep 4
    echo
    docker compose ps
    echo
    log "Recent logs:"
    docker compose logs --tail 25 || true
fi

# ---------- summary ---------------------------------------------------------
echo
echo "${C_BOLD}${C_G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_N}"
ok "Bootstrap complete."
echo "  Install dir : $INSTALL_DIR"
echo "  BBR         : $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "  Docker      : $(docker --version 2>/dev/null || echo 'not installed')"
echo "  UFW         : $(ufw status 2>/dev/null | head -1)"
echo "  Listening   :"
ss -tlnp 2>/dev/null | awk 'NR>1 {print "    " $4 "  " $NF}' | sort -u | head -20
echo "${C_BOLD}${C_G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_N}"
