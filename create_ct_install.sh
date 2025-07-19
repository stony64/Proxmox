#!/usr/bin/env bash
###############################################################################
# Proxmox LXC Container Creator
# Version:    2.7.4
# Datum:      2025-07-20
#
# Beschreibung:
#   Interaktives Bash-Skript zur automatisierten Erstellung von LXC-Containern
#   auf einem Proxmox VE-Host mit:
#     - Mehrsprachigem UI (Deutsch / Englisch)
#     - Benutzerführung via whiptail
#     - Validierten Eingaben für Hostname, Ressourcen etc.
#     - Optionaler SSH-Key-Integration per Kommentar-Suche
#     - Logging, Sicherheitsmechanismen und automatischem CT-ID Scan
#     - Optionaler Hostname-Übergabe per Kommandozeile (--hostname)
#
###############################################################################

set -euo pipefail
trap 'log_error "FEHLER in Zeile $LINENO"; exit 2' ERR

################################################################################
# 1 – Sprachmodul initialisieren
################################################################################

source "$(dirname "$0")/translation.func"
load_translations

################################################################################
# 2 – Konfiguration & globale Variablen
################################################################################

readonly STORAGE="FP1000GB"
readonly TEMPLATE_PATH="/mnt/FP1000GB/template/cache"
readonly LOGFILE="/opt/scripts/proxmox/lxc_create_$(date +'%Y%m%d_%H%M%S').log"

readonly NET_BRIDGE="vmbr2"
readonly BASE_IPV4="192.168.10."
readonly BASE_IPV6="fd00:1234:abcd:10::"
readonly GATEWAY_IPV4="192.168.10.1"
readonly GATEWAY_IPV6="fd00:1234:abcd:10:3ea6:2fff:fe65:8fa7"

CT_ID=""
CT_HOSTNAME=""
CT_PASSWORD=""
CT_CORES=""
CT_MEMORY=""
ROOTFS_SIZE=""
TEMPLATE_FILE=""
OSTEMPLATE=""
OSType=""
SSH_PUBKEY=""
LAPTOP_KEY_COMMENT=""
CT_IPV4=""
CT_IPV6=""

# Übernahmewert für Hostname per Parameter
PARAM_HOSTNAME=""

################################################################################
# 3 – Logging- & Hilfsfunktionen
################################################################################

# Standardisiertes Logging ohne Emojis
log()            { echo "[INFO] $1" | tee -a "$LOGFILE"; }
log_success()    { echo "[OK] $1" | tee -a "$LOGFILE"; }
log_error()      { echo "[ERROR] $1" | tee -a "$LOGFILE"; }
exit_with_log()  { log_error "$1"; exit 1; }

# Whiptail-Titelformatierung
dialog_title() {
    echo "CT ${CT_ID} – $1"
}

# Validierte Eingabe integer
request_positive_integer() {
    local prompt="$1" default="$2" result
    while true; do
        result=$(whiptail --title "$(dialog_title Eingabe)" \
               --inputbox "$prompt" 8 60 "$default" 3>&1 1>&2 2>&3) || return 1
        if [[ "$result" =~ ^[1-9][0-9]*$ ]]; then
            echo "$result"
            return 0
        fi
        whiptail --title "$(dialog_title Fehler)" --msgbox "${MSG[input_invalid]}" 8 60
    done
}

# Validiert das letzte Oktett für IPv4
validate_ip_octet() {
    [[ "$1" =~ ^([0-9]{1,2}|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]] && return 0 || return 1
}

# Dry Run Vorschau ausgeben
dry_run_preview() {
    log "${MSG[preview]}"
    log "${MSG[ctid_assigned]} $CT_ID"
    log "Hostname: $CT_HOSTNAME"
    log "OS-Type: $OSType"
    log "Template: $TEMPLATE_FILE"
    log "${MSG[rootfs]}: $ROOTFS_SIZE GB"
    log "${MSG[cores]}: $CT_CORES"
    log "${MSG[memory]}: $CT_MEMORY MB"
    log "${MSG[abort]}"
    exit 0
}

################################################################################
# 4 – CLI-Argumente & Parameter Mapping
################################################################################

parse_args() {
    local arg
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hostname)
                shift
                PARAM_HOSTNAME="$1"
                log "Hostname übergeben: $PARAM_HOSTNAME"
                ;;
            *)
                # weitere Parameter bei Bedarf hier ergänzen
                ;;
        esac
        shift
    done
}

################################################################################
# 5 – Interaktive Benutzereingaben
################################################################################

# Root-Rechte prüfen
check_root() {
    [[ $EUID -ne 0 ]] && exit_with_log "${MSG[root_required]}"
    log "${MSG[root_ok]}"
}

# Modus auswählbar (optional erweiterbar)
select_mode() {
    local modus
    modus=$(whiptail --title "${MSG[mode_title]}" \
        --menu "${MSG[choose_type]}" 12 50 2 \
        "${MSG[mode_single]}" "${MSG[desc_single]}" \
        "${MSG[mode_cancel]}" "${MSG[abort]}" 3>&1 1>&2 2>&3) || exit_with_log "${MSG[abort]}"
    [[ "$modus" == "${MSG[mode_single]}" ]] && log "${MSG[mode_selected_single]}" || exit_with_log "${MSG[abort]}"
}

# freie Container-ID bestimmen
find_next_ctid() {
    local used_ids
    used_ids=$(pct list | awk 'NR>1 {print $1}' | sort -n)
    CT_ID=$(comm -23 <(seq 100 999 | sort) <(echo "$used_ids") | head -n1)
    [[ -z "$CT_ID" ]] && exit_with_log "${MSG[ctid_none]}"
    log "${MSG[ctid_assigned]} $CT_ID"
}

# Hostname abfragen (bzw. per Parameter übernehmen)
input_hostname() {
    if [[ -n "$PARAM_HOSTNAME" ]]; then
        CT_HOSTNAME="$PARAM_HOSTNAME"
        log "Verwende übergebenen Hostname: $CT_HOSTNAME"
        return
    fi
    while true; do
        CT_HOSTNAME=$(whiptail --title "$(dialog_title Hostname)" \
            --inputbox "${MSG[hostname]}" 10 60 "" 3>&1 1>&2 2>&3) || exit_with_log "${MSG[abort]}"
        if [[ -z "$CT_HOSTNAME" ]]; then
            whiptail --title "$(dialog_title Fehler)" --msgbox "${MSG[input_empty]}" 8 60
            continue
        fi
        if [[ "$CT_HOSTNAME" =~ ^[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?$ ]]; then
            break
        else
            whiptail --title "$(dialog_title Fehler)" --msgbox "${MSG[input_invalid]}" 8 60
        fi
    done
    log "${MSG[hostname]} $CT_HOSTNAME"
}

# Passwort abfragen
input_password() {
    while true; do
        CT_PASSWORD=$(whiptail --title "$(dialog_title Passwort)" \
                       --passwordbox "${MSG[password]}" 10 60 "" 3>&1 1>&2 2>&3)
        [[ $? -ne 0 ]] && exit_with_log "${MSG[abort]}"
        if [[ -z "$CT_PASSWORD" || ${#CT_PASSWORD} -lt 8 ]]; then
            whiptail --title "$(dialog_title Fehler)" --msgbox "${MSG[input_invalid]}" 8 60
            continue
        fi
        break
    done
    log "${MSG[password]} wurde erfolgreich gesetzt."
}

# Template-Auswahl
select_template() {
    log "${MSG[template_select]} $TEMPLATE_PATH"
    mapfile -t templates < <(cd "$TEMPLATE_PATH" && ls -1 *-standard_*.tar.zst 2>/dev/null || true)
    [[ ${#templates[@]} -eq 0 ]] && exit_with_log "${MSG[template_none]}"
    local menu_items=()
    for tpl in "${templates[@]}"; do menu_items+=("$tpl" ""); done
    TEMPLATE_FILE=$(whiptail --title "$(dialog_title Template)" \
        --menu "${MSG[template_select]}" 20 70 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit_with_log "${MSG[abort]}"
    OSTEMPLATE="${TEMPLATE_PATH}/${TEMPLATE_FILE}"
    log "$(printf "${MSG[template_chosen]}" "$TEMPLATE_FILE")"
}

# OS-Typ ableiten
detect_ostype_from_template() {
    if [[ "$TEMPLATE_FILE" =~ ^(debian|ubuntu|centos|arch|alpine)- ]]; then
        OSType="${BASH_REMATCH[1]}"
        log "${MSG[ostype_detected]} $OSType"
    else
        exit_with_log "${MSG[ostype_unknown]}"
    fi
}

# Root-FS-Größe abfragen
input_rootfs_size() {
    ROOTFS_SIZE=$(request_positive_integer "${MSG[rootfs]}" "2") || exit_with_log "${MSG[abort]}"
    log "${MSG[rootfs]}: $ROOTFS_SIZE GB"
}

# Ressourcen abfragen
input_resources() {
    CT_CORES=$(request_positive_integer "${MSG[cores]}" "1") || exit_with_log "${MSG[abort]}"
    CT_MEMORY=$(request_positive_integer "${MSG[memory]}" "512") || exit_with_log "${MSG[abort]}"
    log "${MSG[cores]}: $CT_CORES, ${MSG[memory]}: $CT_MEMORY MB"
}

# Letztes Oktett für statische IP abfragen und Adressen bauen
get_container_ip() {
    local last_octet=""
    while true; do
        last_octet=$(whiptail --title "$(dialog_title IP-Adresse)" \
            --inputbox "${MSG[octet]}" 10 50 "" 3>&1 1>&2 2>&3) || exit_with_log "${MSG[abort]}"
        if validate_ip_octet "$last_octet"; then
            break
        else
            whiptail --title "$(dialog_title Fehler)" --msgbox "${MSG[input_invalid]}" 8 60
        fi
    done
    CT_IPV4="${BASE_IPV4}${last_octet}"
    CT_IPV6="${BASE_IPV6}${last_octet}"
    log "Statische IPv4: $CT_IPV4"
    log "Statische IPv6: $CT_IPV6"
}

################################################################################
# 6 – SSH Key Management
################################################################################

# SSH-Kommentar abfragen
ask_for_laptop_key_comment() {
    LAPTOP_KEY_COMMENT=$(whiptail --title "$(dialog_title SSH)" \
        --inputbox "${MSG[ssh_comment_prompt]}" 10 70 "" 3>&1 1>&2 2>&3) || exit_with_log "${MSG[abort]}"
    [[ -z "$LAPTOP_KEY_COMMENT" ]] && exit_with_log "${MSG[input_empty]}"
    log "${MSG[ssh_lookup]}: $LAPTOP_KEY_COMMENT"
}

# SSH-Key durch Kommentar suchen und Datei erzeugen
extract_laptop_key() {
    local authfile="/root/.ssh/authorized_keys"
    [[ ! -f "$authfile" ]] && exit_with_log "authorized_keys nicht gefunden unter $authfile"
    local key_match
    key_match=$(grep -m1 "$LAPTOP_KEY_COMMENT" "$authfile" || true)
    if [[ -n "$key_match" && "$key_match" =~ ^ssh-(rsa|ed25519|ecdsa) ]]; then
        SSH_PUBKEY=$(mktemp "/tmp/lxc_ssh_${CT_ID}_XXXXXXXX.pub")
        echo "$key_match" > "$SSH_PUBKEY"
        chmod 600 "$SSH_PUBKEY"
        log_success "${MSG[ssh_found]}"
    else
        whiptail --title "$(dialog_title SSH)" --msgbox "${MSG[ssh_not_found]}" 8 60
        SSH_PUBKEY=""
    fi
}

# SSH-Key in Container vorbereiten
prepare_ssh_key_prestart() {
    if [[ -n "$SSH_PUBKEY" && -f "$SSH_PUBKEY" ]]; then
        local ssh_dir="/var/lib/lxc/$CT_ID/rootfs/root/.ssh"
        mkdir -p "$ssh_dir"
        cp "$SSH_PUBKEY" "$ssh_dir/authorized_keys"
        chmod 700 "$ssh_dir"
        chmod 600 "$ssh_dir/authorized_keys"
        chown root:root "$ssh_dir" "$ssh_dir/authorized_keys"
        log "${MSG[ssh_setup]}"
    fi
}

# SSH-Key nach dem Start finalisieren
finalize_ssh_key_after_start() {
    if [[ -n "$SSH_PUBKEY" && -f "$SSH_PUBKEY" ]]; then
        pct exec "$CT_ID" -- bash -c '
            mkdir -p /root/.ssh
            cat > /root/.ssh/authorized_keys < /dev/stdin
            chmod 600 /root/.ssh/authorized_keys
            chown root:root /root/.ssh/authorized_keys
        ' < "$SSH_PUBKEY"
        log_success "${MSG[ssh_setup]}"
    else
        pct exec "$CT_ID" -- bash -c '
            sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
            sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
            systemctl restart ssh || systemctl restart sshd || true
        '
        log "${MSG[ssh_temp]}"
    fi
}

################################################################################
# 7 – Container-Erstellung und Konfigurations-Schritte
################################################################################

# LXC-Container erstellen und starten
create_container() {
    log "${MSG[creating]}"
    pct create "$CT_ID" "$OSTEMPLATE" \
        --hostname "$CT_HOSTNAME" \
        --arch amd64 \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap 512 \
        --features nesting=1 \
        --unprivileged 0 \
        --net0 "name=eth0,bridge=${NET_BRIDGE},ip=${CT_IPV4}/24,gw=${GATEWAY_IPV4},ip6=${CT_IPV6}/64,gw6=${GATEWAY_IPV6}" \
        --rootfs "$STORAGE:$ROOTFS_SIZE" \
        --password "$CT_PASSWORD" \
        --ostype "$OSType" \
        --description "Erstellt am $(date '+%d.%m.%Y %H:%M:%S')"
    log_success "${MSG[created]} (CT-ID: $CT_ID)"
    pct start "$CT_ID"
    log_success "${MSG[started]} (CT-ID: $CT_ID)"
    pct set "$CT_ID" --tags "$OSType"
    log "Tag gesetzt: $OSType"
}

# Systemlocales und Zeitzone im Container konfigurieren
configure_locales() {
    log "${MSG[locales]}"
    log "${MSG[timezone]}"
    if pct exec "$CT_ID" -- apt-get install -y -qq locales tzdata &&
       pct exec "$CT_ID" -- bash -c "echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen; echo 'de_DE.UTF-8 UTF-8' >> /etc/locale.gen; locale-gen" &&
       pct exec "$CT_ID" -- update-locale LANG=de_DE.UTF-8 &&
       pct exec "$CT_ID" -- ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime &&
       pct exec "$CT_ID" -- bash -c 'echo "Europe/Berlin" > /etc/timezone'; then
        log_success "${MSG[locales_ok]}"
        log_success "${MSG[timezone_ok]}"
    else
        log_error "${MSG[locales_fail]}"
        log_error "${MSG[timezone_fail]}"
        exit 1
    fi
}

# Container per APT aktualisieren
update_container() {
    log "${MSG[update]}"
    if pct exec "$CT_ID" -- bash -c '
        DEBIAN_FRONTEND=noninteractive
        apt-get update -qq &&
        apt-get upgrade -y -qq &&
        apt-get autoremove -y -qq &&
        apt-get clean -qq
    '; then
        log_success "${MSG[update_ok]}"
    else
        log_error "${MSG[update_fail]}"
        exit 1
    fi
}

# Dotfiles im Container klonen oder aktualisieren
clone_dotfiles_in_container() {
    log "${MSG[dotfiles]}"
    if pct exec "$CT_ID" -- bash -eu <<'EOF'
apt-get update -qq
apt-get install -y -qq git
if [ ! -d /root/dotfiles/.git ]; then
    git clone https://github.com/stony64/dotfiles.git /root/dotfiles
else
    cd /root/dotfiles && git pull
fi
EOF
    then
        log_success "${MSG[dotfiles_ok]}"
    else
        log_error "${MSG[dotfiles_fail]}"
        exit 1
    fi
}

################################################################################
# 8 – Hauptprogramm
################################################################################

main() {
    parse_args "$@"
    check_root
    select_mode
    find_next_ctid
    input_hostname
    input_password
    select_template
    detect_ostype_from_template
    input_rootfs_size
    input_resources
    get_container_ip
    ask_for_laptop_key_comment
    extract_laptop_key
    [[ "${1:-}" == "--dry-run" ]] && dry_run_preview
    prepare_ssh_key_prestart
    create_container
    finalize_ssh_key_after_start
    configure_locales
    update_container
    clone_dotfiles_in_container
}

main "$@"
