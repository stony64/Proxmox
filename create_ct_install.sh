#!/usr/bin/env bash
###############################################################################
# Proxmox LXC Container Creator
# Version:    2.7.2
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
#
###############################################################################

set -euo pipefail
trap 'log_error "💥 FEHLER in Zeile $LINENO"; exit 2' ERR

################################################################################
# 1 – Sprachmodul initialisieren
################################################################################

source "$(dirname "$0")/translation.func"
load_translations

################################################################################
# 2 – Konfiguration
################################################################################

readonly STORAGE="FP1000GB"
readonly TEMPLATE_PATH="/mnt/FP1000GB/template/cache"
readonly NETWORK_BRIDGE="vmbr2"
readonly LOGFILE="/opt/scripts/proxmox/lxc_create_$(date +'%Y%m%d_%H%M%S').log"

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

################################################################################
# 3 – Hilfs- & Loggingfunktionen
################################################################################

### Logging
log()            { echo "$1" | tee -a "$LOGFILE"; }
log_success()    { log "✅ $1"; }
log_error()      { log "❌ $1"; }
exit_with_log()  { log_error "$1"; exit 1; }

### Einheitlicher Whiptail-Titel pro CT
dialog_title() {
    echo "CT ${CT_ID} – $1"
}

### Ganzzahlige Eingabe mit Validierung
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

### Dry Run: Konfigurationsvorschau anzeigen
dry_run_preview() {
    log "📝 ${MSG[preview]}"
    log "   ${MSG[ctid_assigned]} $CT_ID"
    log "   Hostname: $CT_HOSTNAME"
    log "   OS-Type: $OSType"
    log "   Template: $TEMPLATE_FILE"
    log "   ${MSG[rootfs]}: $ROOTFS_SIZE GB"
    log "   ${MSG[cores]}: $CT_CORES"
    log "   ${MSG[memory]}: $CT_MEMORY MB"
    log "   ${MSG[abort]}"
    exit 0
}

################################################################################
# 4 – Interaktive Eingaben
################################################################################

### Root-Rechte prüfen
check_root() {
    [[ $EUID -ne 0 ]] && exit_with_log "${MSG[root_required]}"
    log "${MSG[root_ok]}"
}

### Container-Modus auswählen
select_mode() {
    local modus
    modus=$(whiptail --title "${MSG[mode_title]}" \
        --menu "${MSG[choose_type]}" 12 50 2 \
        "${MSG[mode_single]}" "${MSG[desc_single]}" \
        "${MSG[mode_cancel]}" "${MSG[abort]}" 3>&1 1>&2 2>&3) || exit_with_log "${MSG[abort]}"
    
    [[ "$modus" == "${MSG[mode_single]}" ]] && log "${MSG[mode_selected_single]}" || exit_with_log "${MSG[abort]}"
}

### Nächste freie CT-ID ermitteln
find_next_ctid() {
    local used_ids
    used_ids=$(pct list | awk 'NR>1 {print $1}' | sort -n)
    CT_ID=$(comm -23 <(seq 100 999 | sort) <(echo "$used_ids") | head -n1)
    [[ -z "$CT_ID" ]] && exit_with_log "${MSG[ctid_none]}"
    log "${MSG[ctid_assigned]} $CT_ID"
}

### Hostname eingeben
input_hostname() {
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

### Passwort abfragen
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
    log "${MSG[password]} (Länge: ${#CT_PASSWORD})"
}

### Template auswählen
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

### OS-Typ anhand Dateiname bestimmen
detect_ostype_from_template() {
    if [[ "$TEMPLATE_FILE" =~ ^(debian|ubuntu|centos|arch|alpine)- ]]; then
        OSType="${BASH_REMATCH[1]}"
        log "${MSG[ostype_detected]} $OSType"
    else
        exit_with_log "${MSG[ostype_unknown]}"
    fi
}

### Root-FS-Größe setzen
input_rootfs_size() {
    ROOTFS_SIZE=$(request_positive_integer "${MSG[rootfs]}" "2") || exit_with_log "${MSG[abort]}"
    log "${MSG[rootfs]}: $ROOTFS_SIZE GB"
}

### CPU & RAM setzen
input_resources() {
    CT_CORES=$(request_positive_integer "${MSG[cores]}" "1") || exit_with_log "${MSG[abort]}"
    CT_MEMORY=$(request_positive_integer "${MSG[memory]}" "512") || exit_with_log "${MSG[abort]}"
    log "${MSG[cores]}: $CT_CORES, ${MSG[memory]}: $CT_MEMORY MB"
}

################################################################################
# 5 – SSH Key Handling
################################################################################

### SSH-Kommentar vom Benutzer abfragen
ask_for_laptop_key_comment() {
    LAPTOP_KEY_COMMENT=$(whiptail --title "$(dialog_title SSH)" \
        --inputbox "${MSG[ssh_comment_prompt]}" 10 70 "" 3>&1 1>&2 2>&3) || exit_with_log "${MSG[abort]}"
    
    [[ -z "$LAPTOP_KEY_COMMENT" ]] && exit_with_log "${MSG[input_empty]}"
    log "${MSG[ssh_lookup]}: $LAPTOP_KEY_COMMENT"
}

### SSH-Key anhand Autorisierungs-Kommentar suchen
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

### SSH-Key vor Start ins RootFS kopieren
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

### SSH-Key nach Start final einrichten
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
# 6 – Container-Erstellung
################################################################################

### LXC-Container erstellen & starten
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
        --net0 "name=eth0,bridge=$NETWORK_BRIDGE,ip=dhcp" \
        --rootfs "$STORAGE:$ROOTFS_SIZE" \
        --password "$CT_PASSWORD" \
        --ostype "$OSType" \
        --description "Erstellt am $(date '+%d.%m.%Y %H:%M:%S')"

    log_success "${MSG[created]} (CT-ID: $CT_ID)"
    pct start "$CT_ID"
    log_success "${MSG[started]} (CT-ID: $CT_ID)"
}

################################################################################
# 7 – Hauptprogramm
################################################################################

### Main-Funktion: Ruft alle Module in Reihenfolge auf
main() {
    check_root
    select_mode
    find_next_ctid
    input_hostname
    input_password
    select_template
    detect_ostype_from_template
    input_rootfs_size
    input_resources
    ask_for_laptop_key_comment
    extract_laptop_key
    [[ "${1:-}" == "--dry-run" ]] && dry_run_preview
    prepare_ssh_key_prestart
    create_container
    finalize_ssh_key_after_start
}

main "$@"
