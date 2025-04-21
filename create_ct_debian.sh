#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Proxmox LXC Container Creator (Debian 12)
# Author: Stony64
# Version: 1.0 | 2025-04-21
# Description:
#     Secure container provisioning with advanced features:
#     - Dual-stack networking (IPv4/IPv6)
#     - SSH key or temporary password auth
#     - POSIX-compliant error handling
#     - Modular architecture
#     - Multi-language support (EN/DE)
###############################################################################

#──────────────────────────────────────────────────────────────────────────────
# Configuration Constants
#──────────────────────────────────────────────────────────────────────────────
readonly TEMPLATE_PATH="/mnt/pve/VM_CON_1TB/template/cache"
readonly TEMPLATE_PATTERN="debian-12-standard_*.tar.zst"
readonly STORAGE="VM_CON_1TB"
readonly NET_BRIDGE="vmbr0"
readonly DISK_SIZE="8" # GB
readonly CPU_CORES="1"
readonly RAM="512"  # MB
readonly SWAP="512" # MB
readonly BASE_IPV4="192.168.10."
readonly BASE_IPV6="fd00:1234:abcd:10::"
readonly GATEWAY_IPV4="192.168.10.1"
readonly GATEWAY_IPV6="fd00:1234:abcd:10:3ea6:2fff:fe65:8fa7"

#──────────────────────────────────────────────────────────────────────────────
# Initialization & Sanity Checks
#──────────────────────────────────────────────────────────────────────────────
init_environment() {
    check_root_privileges
    configure_terminal
    load_translations
}

check_root_privileges() {
    [[ $EUID -ne 0 ]] && error_exit "This script requires root privileges"
}

configure_terminal() {
    stty erase ^H 2>/dev/null
}

#──────────────────────────────────────────────────────────────────────────────
# Template Handling
#──────────────────────────────────────────────────────────────────────────────
select_template() {
    local templates=($(find "${TEMPLATE_PATH}" -name "${TEMPLATE_PATTERN}" -printf "%f\n"))
    ((${#templates[@]} == 0)) && error_exit "No templates found in ${TEMPLATE_PATH}"

    local menu_items=()
    for tpl in "${templates[@]}"; do
        menu_items+=("${tpl}" " ")
    done

    TEMPLATE_FILE=$(whiptail --menu "Select template:" 20 70 10 "${menu_items[@]}" 3>&1 1>&2 2>&3)
    [[ -z "${TEMPLATE_FILE}" ]] && error_exit "Template selection aborted"
}

#──────────────────────────────────────────────────────────────────────────────
# Network Configuration
#──────────────────────────────────────────────────────────────────────────────
validate_ip_octet() {
    [[ "$1" =~ ^([2-9][0-9]?|1[0-9]{2}|2[0-4][0-9]|25[0-4])$ ]] && return 0 || return 1
}

get_ipv4_octet() {
    while true; do
        last_octet=$(whiptail --inputbox "${MSG[octet]}" 10 40 "" 3>&1 1>&2 2>&3)
        validate_ip_octet "$last_octet" && break
        show_message "${MSG[input_invalid]}"
    done
    CT_IPV4="${BASE_IPV4}${last_octet}"
    CT_IPV6="${BASE_IPV6}${last_octet}"
}

#──────────────────────────────────────────────────────────────────────────────
# Security Functions
#──────────────────────────────────────────────────────────────────────────────
generate_secure_password() {
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!%_-#' | head -c 24
}

create_password_file() {
    local passwd_file=$(mktemp)
    chmod 600 "${passwd_file}"
    echo "${ROOT_PASSWORD}" >"${passwd_file}"
    trap 'rm -f "${passwd_file}"' EXIT
    echo "${passwd_file}"
}

#──────────────────────────────────────────────────────────────────────────────
# Container Creation Command
#──────────────────────────────────────────────────────────────────────────────
build_pct_command() {
    local passwd_file=$(create_password_file)

    echo "pct create ${CT_ID} ${TEMPLATE_PATH}/${TEMPLATE_FILE} \
    --hostname ${CT_HOSTNAME} \
    --storage ${STORAGE} \
    --rootfs ${DISK_SIZE} \
    --password-stdin \
    --features nesting=1 \
    --unprivileged ${UNPRIVILEGED} \
    --net0 name=eth0,bridge=${NET_BRIDGE},ip=${CT_IPV4}/24,gw=${GATEWAY_IPV4},ip6=${CT_IPV6}/64,gw6=${GATEWAY_IPV6} \
    $([[ -n "${SSH_KEY_PATH}" ]] && echo "--ssh-public-keys ${SSH_KEY_PATH}")"
}

#──────────────────────────────────────────────────────────────────────────────
# Error Handling
#──────────────────────────────────────────────────────────────────────────────
error_exit() {
    local msg="$1"
    whiptail --title "Critical Error" --msgbox "ERROR: ${msg}" 10 60
    exit 1
}

show_message() {
    whiptail --title "Info" --msgbox "$1" 10 60
}

#──────────────────────────────────────────────────────────────────────────────
# Translation Management (can be moved to translation.func for clarity)
#──────────────────────────────────────────────────────────────────────────────
declare -A MSG
load_translations() {
    local lang
    lang=$(whiptail --menu "Sprache wählen / Choose language:" 12 40 2 \
        "de" "Deutsch" \
        "en" "English" 3>&1 1>&2 2>&3)
    [[ -z "$lang" ]] && lang="en"
    export LANGCODE="$lang"

    if [[ "$lang" == "de" ]]; then
        MSG[welcome]="Willkommen zum LXC-Erstell-Skript!"
        MSG[choose_type]="Bitte Container-Typ wählen:"
        MSG[priv]="Privilegierter Container (weniger sicher)"
        MSG[unpriv]="Unprivilegierter Container (empfohlen, sicherer)"
        MSG[hostname]="Geben Sie den Hostnamen ein (nur Buchstaben, Zahlen, Bindestrich):"
        MSG[password]="Geben Sie das Root-Passwort ein (mindestens 8 Zeichen):"
        MSG[octet]="Geben Sie das letzte Oktett der IPv4-Adresse ein (z. B. 25):"
        MSG[ssh_add]="Möchten Sie einen SSH-Key (*.pub) für root hinzufügen?"
        MSG[ssh_prompt]="Pfad zum SSH-Public-Key (.pub) eingeben:"
        MSG[ssh_invalid]="Ungültiger oder nicht existierender SSH-Key!"
        MSG[summary]="Zusammenfassung:\n\nHostname: %s\nIPv4: %s\nIPv6: %s\nTyp: %s\nSSH-Key: %s\n\nSind diese Angaben korrekt?"
        MSG[template_select]="Template auswählen:"
        MSG[template_none]="Keine Template-Dateien gefunden!"
        MSG[template_chosen]="Verwendetes Template:\n%s"
        MSG[creating]="Container wird erstellt..."
        MSG[created]="Container wurde erstellt."
        MSG[ssh_setup]="SSH-Key wurde erfolgreich im Container hinterlegt."
        MSG[ssh_temp]="Kein gültiger SSH-Key angegeben. Temporärer Root-Login via Passwort wird aktiviert."
        MSG[locale_wait]="Warte, bis der Container startet..."
        MSG[locale_ok]="Locales wurden erfolgreich konfiguriert."
        MSG[locale_fail]="Fehler beim Konfigurieren der Locales."
        MSG[update]="Container wird aktualisiert..."
        MSG[update_ok]="Container wurde erfolgreich aktualisiert."
        MSG[update_fail]="Fehler beim Aktualisieren des Containers."
        MSG[download]="Lade benutzerdefinierte Dateien herunter..."
        MSG[download_ok]="Alle Dateien wurden erfolgreich übertragen."
        MSG[download_fail]="Fehler beim Herunterladen von %s"
        MSG[cleanup]="Systembereinigung wird durchgeführt..."
        MSG[cleanup_ok]="System wurde erfolgreich bereinigt."
        MSG[cleanup_fail]="Fehler bei der Systembereinigung."
        MSG[reboot]="Soll der Container jetzt neu gestartet werden?"
        MSG[rebooting]="Container wird neu gestartet..."
        MSG[abort]="Vorgang abgebrochen."
        MSG[input_empty]="Eingabe darf nicht leer sein."
        MSG[input_invalid]="Ungültige Eingabe. Bitte erneut versuchen."
        MSG[yes]="Ja"
        MSG[no]="Nein"
    else
        MSG[welcome]="Welcome to the LXC creation script!"
        MSG[choose_type]="Please select container type:"
        MSG[priv]="Privileged container (less secure)"
        MSG[unpriv]="Unprivileged container (recommended, more secure)"
        MSG[hostname]="Enter hostname (letters, numbers, dash only):"
        MSG[password]="Enter root password (min. 8 chars):"
        MSG[octet]="Enter last octet of IPv4 address (e.g. 25):"
        MSG[ssh_add]="Do you want to add an SSH key (*.pub) for root?"
        MSG[ssh_prompt]="Enter path to SSH public key (.pub):"
        MSG[ssh_invalid]="Invalid or non-existent SSH key!"
        MSG[summary]="Summary:\n\nHostname: %s\nIPv4: %s\nIPv6: %s\nType: %s\nSSH-Key: %s\n\nAre these values correct?"
        MSG[template_select]="Select template:"
        MSG[template_none]="No template files found!"
        MSG[template_chosen]="Selected template:\n%s"
        MSG[creating]="Creating container..."
        MSG[created]="Container created."
        MSG[ssh_setup]="SSH key successfully added to container."
        MSG[ssh_temp]="No valid SSH key provided. Temporary root login via password will be enabled."
        MSG[locale_wait]="Waiting for container to start..."
        MSG[locale_ok]="Locales successfully configured."
        MSG[locale_fail]="Failed to configure locales."
        MSG[update]="Updating container..."
        MSG[update_ok]="Container updated successfully."
        MSG[update_fail]="Failed to update container."
        MSG[download]="Downloading custom files..."
        MSG[download_ok]="All files transferred successfully."
        MSG[download_fail]="Failed to download %s"
        MSG[cleanup]="Cleaning up system..."
        MSG[cleanup_ok]="System cleanup successful."
        MSG[cleanup_fail]="System cleanup failed."
        MSG[reboot]="Do you want to reboot the container now?"
        MSG[rebooting]="Rebooting container..."
        MSG[abort]="Operation aborted."
        MSG[input_empty]="Input must not be empty."
        MSG[input_invalid]="Invalid input. Please try again."
        MSG[yes]="Yes"
        MSG[no]="No"
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# User Input & Confirmation Workflow
#──────────────────────────────────────────────────────────────────────────────
select_container_type() {
    local type=$(whiptail --menu "${MSG[choose_type]}" 12 60 2 \
        "1" "${MSG[unpriv]}" \
        "2" "${MSG[priv]}" 3>&1 1>&2 2>&3)
    case "$type" in
    1) UNPRIVILEGED=1 ;;
    2) UNPRIVILEGED=0 ;;
    *) error_exit "${MSG[abort]}" ;;
    esac
}

collect_user_inputs() {
    while true; do
        CT_HOSTNAME=$(whiptail --inputbox "${MSG[hostname]}" 10 60 "" 3>&1 1>&2 2>&3)
        [[ -z "$CT_HOSTNAME" ]] && {
            show_message "${MSG[input_empty]}"
            continue
        }
        [[ ! "$CT_HOSTNAME" =~ ^[a-zA-Z0-9-]+$ ]] && {
            show_message "${MSG[input_invalid]}"
            continue
        }
        break
    done

    get_ipv4_octet

    if whiptail --yesno "${MSG[ssh_add]}" 10 60; then
        while true; do
            SSH_KEY_PATH=$(whiptail --inputbox "${MSG[ssh_prompt]}" 10 60 "" 3>&1 1>&2 2>&3)
            if [[ -z "$SSH_KEY_PATH" ]]; then
                show_message "${MSG[input_empty]}"
                continue
            fi
            validate_ssh_key "$SSH_KEY_PATH" && break
            show_message "${MSG[ssh_invalid]}"
        done
    else
        SSH_KEY_PATH=""
    fi

    get_root_password
}

confirm_user_inputs() {
    local sshInfo
    if [[ -n "$SSH_KEY_PATH" ]]; then
        sshInfo="SSH key"
    else
        sshInfo="Temporary root password"
    fi

    local summary
    summary=$(printf "${MSG[summary]}" \
        "$CT_HOSTNAME" "$CT_IPV4" "$CT_IPV6" \
        "$([[ $UNPRIVILEGED -eq 1 ]] && echo "${MSG[unpriv]}" || echo "${MSG[priv]}")" \
        "$sshInfo")

    whiptail --yesno "$summary" 18 70 || error_exit "${MSG[abort]}"
}

#──────────────────────────────────────────────────────────────────────────────
# Container update (with language support and improved error handling)
#──────────────────────────────────────────────────────────────────────────────
update_container() {
    show_message "${MSG[update]}"
    if pct exec "$CT_ID" -- bash -c '
        apt-get update -qq && \
        apt-get upgrade -y -qq && \
        apt-get autoremove -y -qq && \
        apt-get clean -qq
    '; then
        show_message "${MSG[update_ok]}"
    else
        show_message "${MSG[update_fail]}"
        exit 1
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# Download custom files (with temp directory and permission setup)
#──────────────────────────────────────────────────────────────────────────────
download_custom_files() {
    local tmpDir
    tmpDir=$(mktemp -d)
    trap 'rm -rf "$tmpDir"' EXIT

    show_message "${MSG[download]}"

    declare -A filesToDownload=(
        ["custom-script.sh"]="https://example.com/custom-script.sh"
        ["app-config.conf"]="https://example.com/app-config.conf"
    )

    for filename in "${!filesToDownload[@]}"; do
        if ! wget -qO "${tmpDir}/${filename}" "${filesToDownload[$filename]}"; then
            show_message "$(printf "${MSG[download_fail]}" "${filename}")"
            continue
        fi

        pct push "$CT_ID" "${tmpDir}/${filename}" "/root/${filename}"

        # Make scripts executable
        [[ "$filename" == *.sh ]] && pct exec "$CT_ID" -- chmod +x "/root/${filename}"
    done

    show_message "${MSG[download_ok]}"
}

#──────────────────────────────────────────────────────────────────────────────
# System cleanup (including variable cleanup)
#──────────────────────────────────────────────────────────────────────────────
clean_system() {
    show_message "${MSG[cleanup]}"

    # Unset all non-readonly variables
    unset CT_HOSTNAME CT_IPV4 CT_IPV6 SSH_KEY_PATH ROOT_PASSWORD
    unset last_octet tmpDir filename url

    # Remove temporary password file if present
    [[ -f "$PASSWD_FILE" ]] && rm -f "$PASSWD_FILE"

    # Remove SSH keys from memory
    ssh-add -D &>/dev/null

    show_message "${MSG[cleanup_ok]}"
}

#──────────────────────────────────────────────────────────────────────────────
# Progress bar and workflow control
#──────────────────────────────────────────────────────────────────────────────
run_with_progress() {
    {
        echo 5
        select_container_type
        echo 15
        collect_user_inputs
        echo 25
        confirm_user_inputs
        echo 35
        select_template_file
        echo 45
        build_pct_command
        echo 55
        create_container
        echo 65
        update_container
        echo 75
        setup_ct_locales
        echo 85
        setup_ssh_key_or_temp
        echo 95
        download_custom_files
        echo 100
        clean_system
    } | whiptail --title "Container Creation" --gauge "${MSG[creating]}" 12 60 0
}

#──────────────────────────────────────────────────────────────────────────────
# Main function: workflow control
#──────────────────────────────────────────────────────────────────────────────
main() {
    check_root
    set_language
    show_message "${MSG[welcome]}"
    run_with_progress
    show_summary
    unset_variables
    reboot_container_prompt
}

main "$@"

# Todo:
# Die Sprachverwaltung kann für Übersichtlichkeit in eine separate Datei ausgelagert werden (z.B. translation.func),
# indem die Funktion load_translations und das Array MSG ausgelagert und im Hauptskript per source eingebunden werden.
