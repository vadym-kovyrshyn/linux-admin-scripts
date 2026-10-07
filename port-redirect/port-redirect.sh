#!/bin/bash

set -u

SERVICE_PREFIX="port-redirect-"
SERVICE_DIR="/etc/systemd/system"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

die() {
    echo "Error: $*" >&2
    exit 1
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Run this script as root: sudo $0"
    fi
}

validate_port() {
    local port="$1"

    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if (( port < 1 || port > 65535 )); then
        return 1
    fi

    return 0
}

validate_name() {
    local name="$1"

    # Keep names safe for systemd unit names and nft table names.
    if ! [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        return 1
    fi

    return 0
}

service_file_for_name() {
    local name="$1"
    echo "${SERVICE_DIR}/${SERVICE_PREFIX}${name}.service"
}

table_name_for_rule() {
    local name="$1"

    # nft identifiers cannot contain '-'.
    echo "port_redirect_${name//-/_}"
}

# ------------------------------------------------------------
# Add
# ------------------------------------------------------------

add_rule() {
    local name
    local source_port
    local destination_port
    local service_file
    local service_name
    local table_name
    local confirm

    echo
    read -rp "Rule name: " name

    if ! validate_name "$name"; then
        die "Rule name may contain only letters, numbers, '_' and '-'."
    fi

    service_file="$(service_file_for_name "$name")"
    service_name="${SERVICE_PREFIX}${name}.service"
    table_name="$(table_name_for_rule "$name")"

    if [[ -e "$service_file" ]]; then
        die "Rule '$name' already exists."
    fi

    read -rp "External/listening port: " source_port

    if ! validate_port "$source_port"; then
        die "Invalid port: $source_port"
    fi

    read -rp "Redirect to port: " destination_port

    if ! validate_port "$destination_port"; then
        die "Invalid port: $destination_port"
    fi

    if [[ "$source_port" == "$destination_port" ]]; then
        die "Source and destination ports must be different."
    fi

    echo
    echo "Rule:"
    echo "  Name:     $name"
    echo "  Redirect: TCP $source_port -> $destination_port"
    echo

    read -rp "Create this rule? [Y/n]: " confirm

    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        echo "Cancelled."
        return
    fi

    cat > "$service_file" <<EOF
[Unit]
Description=TCP port redirect ${source_port} -> ${destination_port} (${name})
After=network.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes

ExecStart=/usr/sbin/nft add table ip ${table_name}
ExecStart=/usr/sbin/nft add chain ip ${table_name} prerouting { type nat hook prerouting priority dstnat; policy accept; }
ExecStart=/usr/sbin/nft add rule ip ${table_name} prerouting tcp dport ${source_port} redirect to :${destination_port}

ExecStop=/usr/sbin/nft delete table ip ${table_name}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    if ! systemctl enable --now "$service_name"; then
        echo
        echo "Failed to start rule. Removing service file..."

        systemctl disable "$service_name" 2>/dev/null || true
        rm -f "$service_file"
        systemctl daemon-reload

        # Clean up a partially-created nft table.
        nft delete table ip "$table_name" 2>/dev/null || true

        die "Could not create redirect rule."
    fi

    echo
    echo "Rule '$name' created successfully."
    echo "TCP $source_port -> $destination_port"
}

# ------------------------------------------------------------
# Delete
# ------------------------------------------------------------

delete_rule() {
    local files=()
    local names=()
    local file
    local base
    local name
    local selection
    local service_name
    local description
    local confirm

    shopt -s nullglob
    files=("${SERVICE_DIR}/${SERVICE_PREFIX}"*.service)
    shopt -u nullglob

    if (( ${#files[@]} == 0 )); then
        echo
        echo "No port redirect rules found."
        return
    fi

    echo
    echo "Port redirect rules:"
    echo

    local i=1

    for file in "${files[@]}"; do
        base="$(basename "$file")"
        name="${base#${SERVICE_PREFIX}}"
        name="${name%.service}"

        names+=("$name")

        description="$(grep '^Description=' "$file" | head -n1 | cut -d= -f2-)"

        printf "  %d) %s" "$i" "$name"

        if [[ -n "$description" ]]; then
            printf "  [%s]" "$description"
        fi

        printf "\n"

        ((i++))
    done

    echo
    read -rp "Rule number to delete (0 = cancel): " selection

    if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
        die "Invalid selection."
    fi

    if (( selection == 0 )); then
        echo "Cancelled."
        return
    fi

    if (( selection < 1 || selection > ${#names[@]} )); then
        die "Invalid rule number."
    fi

    name="${names[$((selection - 1))]}"
    service_name="${SERVICE_PREFIX}${name}.service"
    file="$(service_file_for_name "$name")"

    echo
    read -rp "Delete rule '$name'? [Y/n]: " confirm

    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        echo "Cancelled."
        return
    fi

    systemctl disable --now "$service_name" 2>/dev/null || true

    rm -f "$file"

    systemctl daemon-reload
    systemctl reset-failed "$service_name" 2>/dev/null || true

    echo
    echo "Rule '$name' deleted."
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

require_root

command -v nft >/dev/null 2>&1 || die "nft command not found."
command -v systemctl >/dev/null 2>&1 || die "systemctl command not found."

echo "Port Redirect Manager"
echo
echo "  1) Add rule"
echo "  2) Delete rule"
echo
read -rp "Select action [1-2]: " action

case "$action" in
    1)
        add_rule
        ;;
    2)
        delete_rule
        ;;
    *)
        die "Invalid selection."
        ;;
esac