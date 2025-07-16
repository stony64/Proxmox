#!/usr/bin/env bash
set -euo pipefail

# Load translations
source ./translation.func
load_translations

# Load git_clone_dotfiles function
source ./git_clone_dotfiles.func

###############################################################################
# Proxmox LXC Container Creator (Debian 12)
# Author: Stony64
# Version: 1.0 | 2025-04-21
# Description:
#   Secure container provisioning with advanced features:
#   - Dual-stack networking (IPv4/IPv6)
#   - SSH key or temporary password authentication
#   - POSIX-compliant error handling
#   - Modular architecture
#   - Multi-language support (EN/DE)
###############################################################################

# ----------------------------------------------------------------------------
# Configuration Constants
# ----------------------------------------------------------------------------

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

# ----------------------------------------------------------------------------
# Initialization & Sanity Checks
# ----------------------------------------------------------------------------

init_environment() {
    check_root_privileges
    configure_terminal
    load_translations
    detect_next_ct_id
    show_message "Automatically selected container ID: ${CT_ID}"
}

check_root_privileges() {
    [[ $EUID -ne 0 ]] && error_exit "This script requires root privileges"
}

configure_terminal() {
    stty erase ^H 2>/dev/null || true
}

####################################################
# detect_next_ct_id – Automatically detect next available container ID
####################################################
detect_next_ct_id() {
    local existing_ids next_id
    existing_ids=$(pct list | tail -n +2 | awk '{print $1}' | sort -n)
    next_id=100  # Starting ID, adjust as needed

    for id in $existing_ids; do
        if (( id == next_id )); then
            ((next_id++))
        elif (( id > next_id )); then
            break
        fi
    done

    CT_ID=$next_id
}

# ----------------------------------------------------------------------------
# Error Handling
# ----------------------------------------------------------------------------

error_exit() {
    local msg="$1"
    whiptail --title "Critical Error" --msgbox "ERROR: ${msg}" 10 60
    exit 1
}

show_message() {
    whiptail --title "Info" --msgbox "$1" 10 60
}

# ----------------------------------------------------------------------------
# Template Selection
# ----------------------------------------------------------------------------

select_template_file() {
    local templates=()
    mapfile -t templates < <(find "${TEMPLATE_PATH}" -name "${TEMPLATE_PATTERN}" -printf "%f\n")
    ((${#templates[@]} == 0)) && error_exit "${MSG[template_none]}"

    local menu_items=()
    for tpl in "${templates[@]}"; do
        menu_items+=("${tpl}" " ")
    done

    TEMPLATE_FILE=$(whiptail --menu "${MSG[template_select]}" 20 70 10 "${menu_items[@]}" 3>&1 1>&2 2>&3)
    [[ -z "${TEMPLATE_FILE}" ]] && error_exit "${MSG[abort]}"
}

# ----------------------------------------------------------------------------
# Network Configuration
# ----------------------------------------------------------------------------

validate_ip_octet() {
    [[ "$1" =~ ^([1-9][0-9]?|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]] && return 0 || return 1
}

get_ipv4_octet() {
    while true; do
        local last_octet
        last_octet=$(whiptail --inputbox "${MSG[octet]}" 10 40 "" 3>&1 1>&2 2>&3)
        validate_ip_octet "$last_octet" && break
        show_message "${MSG[input_invalid]}"
    done
    CT_IPV4="${BASE_IPV4}${last_octet}"
    CT_IPV6="${BASE_IPV6}${last_octet}"
}

validate_ssh_key() {
    [[ -f "$1" && "$1" == *.pub ]] || return 1
}

get_root_password() {
    while true; do
        ROOT_PASSWORD=$(whiptail --passwordbox "${MSG[password]}" 10 60 3>&1 1>&2 2>&3)
        if [[ -z "$ROOT_PASSWORD" ]]; then
            show_message "${MSG[input_empty]}"
            continue
        fi
        if (( ${#ROOT_PASSWORD} < 8 )); then
            show_message "${MSG[input_invalid]}"
            continue
        fi
        break
    done
}

# ----------------------------------------------------------------------------
# Container Type Selection & User Input
# ----------------------------------------------------------------------------

select_container_type() {
    local type
    type=$(whiptail --menu "${MSG[choose_type]}" 12 60 2 \
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
        [[ -z "$CT_HOSTNAME" ]] && { show_message "${MSG[input_empty]}"; continue; }
        [[ ! "$CT_HOSTNAME" =~ ^[a-zA-Z0-9-]+$ ]] && { show_message "${MSG[input_invalid]}"; continue; }
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
    [[ -n "$SSH_KEY_PATH" ]] && sshInfo="${MSG[yes]}" || sshInfo="${MSG[no]}"

    local summary
    summary=$(printf "${MSG[summary]}" \
        "$CT_HOSTNAME" "$CT_IPV4" "$CT_IPV6" \
        "$([[ $UNPRIVILEGED -eq 1 ]] && echo "${MSG[unpriv]}" || echo "${MSG[priv]}")" \
        "$sshInfo")

    whiptail --yesno "$summary" 18 70 || error_exit "${MSG[abort]}"
}

# ----------------------------------------------------------------------------
# Container Creation Command
# ----------------------------------------------------------------------------

generate_secure_password() {
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!%_-#' | head -c 24
}

# NOTE: Now PASSWD_FILE is global for cleanup!
PASSWD_FILE=""

create_password_file() {
    PASSWD_FILE=$(mktemp)
    chmod 600 "${PASSWD_FILE}"
    echo "${ROOT_PASSWORD}" >"${PASSWD_FILE}"
    echo "${PASSWD_FILE}"
}

build_pct_command() {
    create_password_file

    echo "pct create ${CT_ID} ${TEMPLATE_PATH}/${TEMPLATE_FILE} \
    --hostname ${CT_HOSTNAME} \
    --storage ${STORAGE} \
    --rootfs ${DISK_SIZE}G \
    --password-stdin \
    --features nesting=1 \
    --unprivileged $( [[ "${UNPRIVILEGED:-0}" -eq 1 ]] && echo "1" || echo "0") \
    --net0 name=eth0,bridge=${NET_BRIDGE},ip=${CT_IPV4}/24,gw=${GATEWAY_IPV4},ip6=${CT_IPV6}/64,gw6=${GATEWAY_IPV6} \
    $([[ -n "${SSH_KEY_PATH-}" ]] && echo "--ssh-public-keys ${SSH_KEY_PATH}")"
}

create_container() {
    show_message "${MSG[creating]}"

    local cmd
    cmd=$(build_pct_command)

    # Execute creation command with password input via stdin
    cat "$PASSWD_FILE" | eval "$cmd" --password-stdin

    show_message "${MSG[created]}"
}

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

# ----------------------------------------------------------------------------
# Configure locales inside the container
# ----------------------------------------------------------------------------

setup_ct_locales() {
    show_message "${MSG[locale_wait]}"

    if pct exec "$CT_ID" -- bash -c '
        set -e
        apt-get update -qq
        apt-get install -y locales
        locale-gen en_US.UTF-8 de_DE.UTF-8
        update-locale LANG=en_US.UTF-8
    '; then
        show_message "${MSG[locale_ok]}"
    else
        show_message "${MSG[locale_fail]}"
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# Setup SSH key or enable temporary root password login
# ----------------------------------------------------------------------------

setup_ssh_key_or_temp() {
    if [[ -n "$SSH_KEY_PATH" ]]; then
        show_message "${MSG[ssh_setup]}"
        pct exec "$CT_ID" -- mkdir -p /root/.ssh
        pct push "$CT_ID" "$SSH_KEY_PATH" /root/.ssh/authorized_keys
        pct exec "$CT_ID" -- chmod 600 /root/.ssh/authorized_keys
        pct exec "$CT_ID" -- chown root:root /root/.ssh/authorized_keys
    else
        show_message "${MSG[ssh_temp]}"
        pct exec "$CT_ID" -- bash -c '
            sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
            sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
            systemctl restart ssh || systemctl restart sshd || true
        '
    fi
}

# ----------------------------------------------------------------------------
# Show summary of container settings
# ----------------------------------------------------------------------------

show_summary() {
    local sshInfo
    [[ -n "$SSH_KEY_PATH" ]] && sshInfo="${MSG[yes]}" || sshInfo="${MSG[no]}"

    local summary
    summary=$(printf "${MSG[summary]}" \
        "$CT_HOSTNAME" "$CT_IPV4" "$CT_IPV6" \
        "$([[ $UNPRIVILEGED -eq 1 ]] && echo "${MSG[unpriv]}" || echo "${MSG[priv]}")" \
        "$sshInfo")

    whiptail --title "${MSG[welcome]}" --msgbox "$summary" 20 70
}

# ----------------------------------------------------------------------------
# Cleanup function, unset variables, remove temp files and ssh keys
# ----------------------------------------------------------------------------

clean_system() {
    show_message "${MSG[cleanup]}"

    unset CT_HOSTNAME CT_IPV4 CT_IPV6 SSH_KEY_PATH ROOT_PASSWORD TEMPLATE_FILE UNPRIVILEGED last_octet tmpDir filename url

    [[ -n "${PASSWD_FILE:-}" && -f "$PASSWD_FILE" ]] && rm -f "$PASSWD_FILE"

    ssh-add -D &>/dev/null || true

    show_message "${MSG[cleanup_ok]}"
}

# ----------------------------------------------------------------------------
# Prompt user for reboot and reboot container if confirmed
# ----------------------------------------------------------------------------

reboot_container_prompt() {
    if whiptail --yesno "${MSG[reboot]}" 10 60; then
        show_message "${MSG[rebooting]}"
        pct reboot "$CT_ID"
    else
        show_message "${MSG[abort]}"
    fi
}

# ----------------------------------------------------------------------------
# Progress bar and workflow control
# ----------------------------------------------------------------------------

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
        git git_clone_dotfiles
        echo 100        
    } | whiptail --title "Container Creation" --gauge "${MSG[creating]}" 12 60 0
}

# ----------------------------------------------------------------------------
# Main function
# ----------------------------------------------------------------------------

main() {
    init_environment
    show_message "${MSG[welcome]}"
    run_with_progress
    show_summary
    clean_system
    reboot_container_prompt
}

main "$@"
