#!/usr/bin/env bash
# re-exec with bash if started via `sh vm-manager.sh` (dash has no pipefail/arrays)
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
if (( BASH_VERSINFO[0] < 4 )); then
    echo "Bash >= 4 is required (found $BASH_VERSION)" >&2
    exit 1
fi
set -euo pipefail

# =============================
# MinhNeko VM — Multi-VM Manager (KVM-aware, raw+virtio)
# =============================

VM_DIR_FROM_ENV="${VM_DIR:+1}"
# Address QEMU binds forwarded ports to. Empty = all interfaces (old behaviour).
# Set BIND_ADDR=127.0.0.1 to keep SSH reachable only from the host itself.
BIND_ADDR="${BIND_ADDR:-}"

# Default VM dir. If VMs already exist in the old dir, keep using it.
if [[ -z "${VM_DIR:-}" ]]; then
    if [[ -d /var/lib/vishnu-vms && ! -d /var/lib/minhneko-vms ]]; then
        VM_DIR="/var/lib/vishnu-vms"
    else
        VM_DIR="/var/lib/minhneko-vms"
    fi
fi

# ── OS catalogue ──────────────────────────────────────────────────────────────
declare -A OS_OPTIONS=(
    ["Ubuntu 24.04 LTS"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu-vm|ubuntu|ubuntu123"
    ["Ubuntu 22.04 LTS"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu-vm|ubuntu|ubuntu123"
    ["Ubuntu 20.04 LTS"]="ubuntu|focal|https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img|ubuntu-vm|ubuntu|ubuntu123"
    ["Debian 13"]="debian|trixie|https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2|debian-vm|debian|debian123"
    ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2|debian-vm|debian|debian123"
    ["Debian 11"]="debian|bullseye|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2|debian-vm|debian|debian123"
    ["Fedora 39"]="fedora|39|https://dl.fedoraproject.org/pub/archive/fedora/linux/releases/39/Cloud/x86_64/images/Fedora-Cloud-Base-39-1.5.x86_64.qcow2|fedora-vm|fedora|fedora123"
    ["Alpine 3.19"]="alpine|3.19|https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/cloud/nocloud_alpine-3.19.0-x86_64-bios-cloudinit-r0.qcow2|alpine-vm|alpine|alpine123"
)

# ── header ────────────────────────────────────────────────────────────────────
display_header() {
    clear 2>/dev/null || true
    cat << "EOF"
╔════════════════════════════════════════════════════════════════════════╗
║   ███╗   ███╗██╗███╗   ██╗██╗  ██╗███╗   ██╗███████╗██╗  ██╗ ██████╗   ║
║  ████╗ ████║██║████╗  ██║██║  ██║████╗  ██║██╔════╝██║ ██╔╝██╔═══██╗   ║
║  ██╔████╔██║██║██╔██╗ ██║███████║██╔██╗ ██║█████╗  █████╔╝ ██║   ██║   ║
║  ██║╚██╔╝██║██║██║╚██╗██║██╔══██║██║╚██╗██║██╔══╝  ██╔═██╗ ██║   ██║   ║
║  ██║ ╚═╝ ██║██║██║ ╚████║██║  ██║██║ ╚████║███████╗██║  ██╗╚██████╔╝   ║
║   ╚═╝     ╚═╝╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝ ╚═════╝   ║
║                                                                        ║
║                          V M   M A N A G E R                           ║
╚════════════════════════════════════════════════════════════════════════╝
      MinhNeko VM — Multi-VM Manager (KVM-aware, raw+virtio)
EOF
    echo
}

# ── print helpers ─────────────────────────────────────────────────────────────
print_status() {
    local type=$1 message=$2 prefix
    case $type in
        "INFO")    prefix="\033[1;34m📋 [INFO]\033[0m" ;;
        "WARN")    prefix="\033[1;33m⚠️  [WARN]\033[0m" ;;
        "ERROR")   prefix="\033[1;31m❌ [ERROR]\033[0m" ;;
        "SUCCESS") prefix="\033[1;32m✅ [SUCCESS]\033[0m" ;;
        "INPUT")   prefix="\033[1;36m🎯 [INPUT]\033[0m" ;;
        *)         prefix="[$type]" ;;
    esac
    printf '%b %s\n' "$prefix" "$message"
}

pause() {
    read -rp "$(print_status "INPUT" "⏎ Press Enter to continue...")" _
}

# ── dependency check ──────────────────────────────────────────────────────────
check_dependencies() {
    local deps=("qemu-system-x86_64" "wget" "qemu-img" "openssl" "pgrep" "pkill" "ps")
    local missing=() dep t
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    # cloud-init seed: cloud-localds, or any ISO builder we can fall back to
    local seed_ok=false
    for t in cloud-localds genisoimage mkisofs xorriso; do
        if command -v "$t" &>/dev/null; then seed_ok=true; fi
    done
    if ! $seed_ok; then missing+=("cloud-localds"); fi
    # graceful shutdown talks to the QEMU monitor through socat or python3
    if ! command -v socat >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
        print_status "WARN" "Neither socat nor python3 found — 'Stop' will hard-kill QEMU instead of ACPI shutdown"
    fi
    if (( ${#missing[@]} == 0 )); then return 0; fi

    print_status "ERROR" "Missing dependencies: ${missing[*]}"

    # NixOS / Replit: cannot apt-get — print the replit.nix packages instead
    # only take the Nix path when apt is not an option (Nix installed on Debian/Ubuntu/freeroot must still use apt)
    if [[ -e /etc/NIXOS ]] || { ! command -v apt-get >/dev/null 2>&1 && command -v nix-shell >/dev/null 2>&1; }; then
        local nixpkgs=() n
        for dep in "${missing[@]}"; do
            case $dep in
                qemu-system-x86_64|qemu-img) n="pkgs.qemu" ;;
                cloud-localds)               n="pkgs.cloud-utils pkgs.cdrkit" ;;
                pgrep|pkill|ps)              n="pkgs.procps" ;;
                *)                           n="pkgs.$dep" ;;
            esac
            for t in $n; do [[ " ${nixpkgs[*]:-} " == *" $t "* ]] || nixpkgs+=("$t"); done
        done
        print_status "INFO" "NixOS/Replit: add to replit.nix deps = [ ${nixpkgs[*]} ];"
        print_status "INFO" "or try: nix-shell -p ${nixpkgs[*]//pkgs./} --run \"bash $0\""
        exit 1
    fi

    # map command → apt package
    local pkgs=() pkg
    for dep in "${missing[@]}"; do
        case $dep in
            qemu-system-x86_64) pkg="qemu-system-x86" ;;
            qemu-img)           pkg="qemu-utils" ;;
            cloud-localds)      pkg="cloud-image-utils" ;;
            pgrep|pkill|ps)     pkg="procps" ;;
            *)                  pkg="$dep" ;;
        esac
        [[ " ${pkgs[*]:-} " == *" $pkg "* ]] || pkgs+=("$pkg")
    done

    local SUDO=""
    if [[ "$(id -u)" != "0" ]] && command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi
    if command -v apt-get >/dev/null 2>&1 && { [[ "$(id -u)" == "0" ]] || [[ -n "$SUDO" ]]; }; then
        print_status "INFO" "📦 Packages to install: ${pkgs[*]}"
        local ans
        read -rp "$(print_status "INPUT" "Install them now with apt-get? (y/N): ")" ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            $SUDO apt-get update -y && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" || {
                print_status "ERROR" "apt-get failed — install manually: apt-get install -y ${pkgs[*]}"
                exit 1
            }
            hash -r
            for dep in "${missing[@]}"; do
                if [[ "$dep" == "cloud-localds" ]]; then
                    command -v cloud-localds &>/dev/null && continue
                    command -v genisoimage &>/dev/null && continue
                fi
                if ! command -v "$dep" &>/dev/null; then
                    print_status "ERROR" "'$dep' is still missing after install"
                    exit 1
                fi
            done
            return 0
        fi
    fi
    print_status "INFO" "Ubuntu/Debian: sudo apt install ${pkgs[*]}"
    exit 1
}

# ── KVM probe ─────────────────────────────────────────────────────────────────
kvm_available() {
    grep -qE '(vmx|svm)' /proc/cpuinfo 2>/dev/null \
        && [[ -c /dev/kvm ]] \
        && [[ -r /dev/kvm && -w /dev/kvm ]]
}

# usable host memory in MB (min of MemAvailable and the cgroup limit); 0 = unknown
host_mem_limit_mb() {
    local avail=0 lim f v
    avail=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || true)
    avail=${avail:-0}
    for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        if [[ -r "$f" ]]; then
            v=$(cat "$f" 2>/dev/null || true)
            if [[ "$v" =~ ^[0-9]+$ ]]; then
                lim=$(( v / 1024 / 1024 ))
                if (( lim > 0 && (avail == 0 || lim < avail) )); then avail=$lim; fi
            fi
        fi
    done
    echo "$avail"
}

# ── validation ────────────────────────────────────────────────────────────────
validate_input() {
    local type=$1 value=$2
    case $type in
        "number")
            if ! [[ "$value" =~ ^[0-9]+$ ]] || (( 10#$value < 1 )); then
                print_status "ERROR" "Must be a number >= 1"; return 1
            fi ;;
        "size")
            if ! [[ "$value" =~ ^[0-9]+[GgMm]$ ]]; then
                print_status "ERROR" "Must be a size with unit (e.g., 100G, 512M)"; return 1
            fi ;;
        "port")
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 23 ] || [ "$value" -gt 65535 ]; then
                print_status "ERROR" "Must be a valid port number (23-65535)"; return 1
            fi ;;
        "name")
            if ! [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                print_status "ERROR" "VM name can only contain letters, numbers, hyphens, underscores"; return 1
            fi ;;
        "hostname")
            if ! [[ "$value" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
                print_status "ERROR" "Hostname: letters, digits and hyphens only (no underscore, no leading/trailing hyphen)"; return 1
            fi ;;
        "username")
            if ! [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                print_status "ERROR" "Username must start with letter/underscore, lowercase only"; return 1
            fi ;;
    esac
    return 0
}

# ── lock check ────────────────────────────────────────────────────────────────
# PIDs of qemu processes using this image (matched on the -drive file= argument)
image_qemu_pids() {
    pgrep -f "qemu-system.*file=$1," 2>/dev/null || true
}

check_image_lock() {
    local img_file=$1
    local vm_name=$2
    local pid
    pid=$(image_qemu_pids "$img_file" | head -1 || true)

    if [[ -n "$pid" ]]; then
        print_status "WARN" "🔒 Image file $img_file is already in use by another QEMU process"
        print_status "INFO" "🔍 Process ID using the image: $pid"
        local pid_args
        pid_args=$(ps -p "$pid" -o args= 2>/dev/null || true)
        if grep -qE "$(vm_pattern "$vm_name")" <<<"$pid_args"; then
            print_status "INFO" "🤔 This appears to be the same VM already running"
            read -rp "$(print_status "INPUT" "🔄 Kill existing process and restart? (y/N): ")" kill_choice
            if [[ "$kill_choice" =~ ^[Yy]$ ]]; then
                kill "$pid" 2>/dev/null || true
                wait_pid_exit "$pid" 10
                if kill -0 "$pid" 2>/dev/null; then
                    kill -9 "$pid" 2>/dev/null || true
                    print_status "WARN" "⚠️  Forcefully terminated process $pid"
                fi
                return 0
            fi
            return 1
        fi
        print_status "ERROR" "🚫 Another QEMU instance is using this image"
        return 1
    fi

    local lock_file="${img_file}.lock"
    if [[ -f "$lock_file" ]]; then
        print_status "WARN" "🔒 Lock file found: $lock_file"
        if [[ $(find "$lock_file" -mmin +5 2>/dev/null) ]]; then
            print_status "WARN" "⏰ Lock file appears stale (older than 5 minutes)"
            read -rp "$(print_status "INPUT" "🗑️  Remove stale lock file? (y/N): ")" remove_lock
            if [[ "$remove_lock" =~ ^[Yy]$ ]]; then
                rm -f "$lock_file"
                print_status "SUCCESS" "✅ Removed stale lock file"
                return 0
            fi
        fi
        return 1
    fi
    return 0
}

# ── conf helpers ──────────────────────────────────────────────────────────────
load_vm_config() {
    local vm_name=$1
    local config_file="$VM_DIR/$vm_name.conf"
    if [[ -f "$config_file" ]]; then
        unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD \
              DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS \
              IMG_FILE SEED_FILE CREATED ACCEL CPU_MODEL
        # shellcheck source=/dev/null
        source "$config_file"
        # defaults for older .conf files (set -u safe)
        ACCEL="${ACCEL:-}"
        CPU_MODEL="${CPU_MODEL:-}"
        PORT_FORWARDS="${PORT_FORWARDS:-}"
        GUI_MODE="${GUI_MODE:-false}"
        return 0
    else
        print_status "ERROR" "📂 Configuration for VM '$vm_name' not found"
        return 1
    fi
}

save_vm_config() {
    mkdir -p "$VM_DIR"
    local f="$VM_DIR/$VM_NAME.conf" k
    : > "$f"
    for k in VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD \
             DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS \
             IMG_FILE SEED_FILE CREATED ACCEL CPU_MODEL; do
        printf '%s=%q\n' "$k" "${!k:-}" >> "$f"
    done
    chmod 600 "$f"
    print_status "SUCCESS" "💾 Configuration saved to $f"
}

conf_set() {
    local file="$1" key="$2" value="$3" q tmp
    printf -v q '%q' "$value"
    if [[ -f "$file" ]] && grep -q "^${key}=" "$file"; then
        tmp=$(mktemp)
        grep -v "^${key}=" "$file" > "$tmp" || true
        echo "${key}=${q}" >> "$tmp"
        cat "$tmp" > "$file"
        rm -f "$tmp"
    else
        echo "${key}=${q}" >> "$file"
    fi
}

# ── VM discovery ──────────────────────────────────────────────────────────────
get_vm_list() {
    local f
    for f in "$VM_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        f=${f##*/}
        echo "${f%.conf}"
    done | sort
}

# regex matching exactly this VM's qemu process (by -name or by image path)
vm_pattern() {
    echo "qemu-system.*(-name $1( |,)|/$1\.img)"
}

# wait up to N seconds for a pid to disappear
wait_pid_exit() {
    local pid=$1 secs=$2 i
    for (( i = 0; i < secs * 2; i++ )); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.5
    done
    return 1
}

# wait up to N seconds for the VM's qemu process to disappear
wait_vm_exit() {
    local vm_name=$1 secs=$2 i
    for (( i = 0; i < secs * 2; i++ )); do
        is_vm_running "$vm_name" || return 0
        sleep 0.5
    done
    return 1
}

monitor_sock() { echo "$VM_DIR/$1.mon"; }

# send one human-monitor command to the VM (socat, else python3)
send_monitor_cmd() {
    local sock=$1 cmd=$2
    [[ -S "$sock" ]] || return 1
    if command -v socat >/dev/null 2>&1; then
        printf '%s\n' "$cmd" | socat - "UNIX-CONNECT:$sock" >/dev/null 2>&1
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$sock" "$cmd" <<'PY' >/dev/null 2>&1
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.settimeout(3)
s.connect(sys.argv[1])
time.sleep(0.3)
s.sendall((sys.argv[2] + "\n").encode())
time.sleep(0.5)
s.close()
PY
    else
        return 1
    fi
}

is_vm_running() {
    pgrep -f "$(vm_pattern "$1")" >/dev/null 2>&1
}

# hard kill: SIGTERM, wait, then SIGKILL
kill_vm_process() {
    local vm_name=$1
    pkill -f "$(vm_pattern "$vm_name")" || true
    if ! wait_vm_exit "$vm_name" 5; then
        pkill -9 -f "$(vm_pattern "$vm_name")" || true
        wait_vm_exit "$vm_name" 3 || true
    fi
}

port_listening() {
    local port=$1 out=""
    if command -v ss >/dev/null 2>&1; then
        out=$(ss -tln 2>/dev/null || true)
    elif command -v netstat >/dev/null 2>&1; then
        out=$(netstat -tln 2>/dev/null || true)
    else
        if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then return 0; else return 1; fi
    fi
    # here-string, not a pipe: under pipefail `cmd | grep -q` can fail with SIGPIPE
    grep -qE "[:.]${port}[[:space:]]" <<<"$out"
}

# is this SSH port already used by another VM's config (or by a listener)?
ssh_port_taken() {
    local port=$1 self=${2:-} f other
    if port_listening "$port"; then return 0; fi
    for f in "$VM_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        other=$(basename "$f" .conf)
        [[ "$other" == "$self" ]] && continue
        if grep -qE "^SSH_PORT=['\"]?${port}['\"]?$" "$f"; then return 0; fi
    done
    return 1
}

# pick a VM interactively → sets global SELECTED_VM (no subshell, prompts stay visible)
SELECTED_VM=""
select_vm() {
    local -a vms
    mapfile -t vms < <(get_vm_list)

    if (( ${#vms[@]} == 0 )); then
        print_status "ERROR" "No VM configurations found in $VM_DIR"
        return 1
    fi
    if (( ${#vms[@]} == 1 )); then
        SELECTED_VM="${vms[0]}"
        print_status "INFO" "One VM found — auto-selecting: $SELECTED_VM"
        return 0
    fi

    echo
    print_status "INFO" "🌐 Select a VM:"
    local i=1 vm
    for vm in "${vms[@]}"; do
        local status="💤"
        is_vm_running "$vm" && status="🚀"
        printf "  \033[1;36m%d)\033[0m %s %s\n" "$i" "$status" "$vm"
        i=$((i + 1))
    done
    echo

    local choice
    while true; do
        read -rp "$(print_status "INPUT" "Enter number (1-${#vms[@]}): ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#vms[@]} )); then
            SELECTED_VM="${vms[$((choice - 1))]}"
            return 0
        fi
        print_status "ERROR" "Invalid selection. Try again."
    done
}

show_vm_info() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1
    echo
    print_status "INFO" "📊 VM Information: $vm_name"
    echo "🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹"
    echo "🌍 OS:            $OS_TYPE"
    echo "🏷️  Hostname:      $HOSTNAME"
    echo "👤 Username:      $USERNAME"
    echo "🔑 Password:      $PASSWORD"
    echo "🔌 SSH Port:      $SSH_PORT"
    echo "🧠 Memory:        ${MEMORY} MB"
    echo "⚡ CPUs:          $CPUS"
    echo "💾 Disk:          $DISK_SIZE"
    echo "🖥️  GUI Mode:      $GUI_MODE"
    echo "🌐 Port Forwards: ${PORT_FORWARDS:-None}"
    echo "⚡ Accel:         ${ACCEL:-auto-detect}"
    echo "🧠 CPU Model:     ${CPU_MODEL:-auto-detect}"
    echo "📅 Created:       $CREATED"
    echo "💿 Image File:    $IMG_FILE"
    echo "🌱 Seed File:     $SEED_FILE"
    # non-interactive check (check_image_lock may prompt/kill, so not used here)
    if [[ -n "$(image_qemu_pids "$IMG_FILE")" || -f "${IMG_FILE}.lock" ]]; then
        echo "🔒 Image Status:  Locked (possibly in use)"
    else
        echo "🔓 Image Status:  Unlocked"
    fi
    if is_vm_running "$vm_name"; then
        echo "🚀 Status:        Running"
    else
        echo "💤 Status:        Stopped"
    fi
    echo "🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹🔹"
    echo
    pause
}

# ── ensure image is raw (convert in-place if not) ─────────────────────────────
ensure_raw() {
    local img=$1
    local fmt
    # awk reads all input (no SIGPIPE); `|| true` so a failure is reported below instead of aborting under set -e
    fmt=$(qemu-img info "$img" 2>/dev/null | awk '/^file format:/ {f=$3} END {print f}') || true
    if [[ -z "$fmt" ]]; then
        print_status "ERROR" "❌ Cannot detect image format of $img"
        return 1
    fi
    [[ "$fmt" == "raw" ]] && return 0

    print_status "INFO" "🔄 Image is $fmt — converting to raw (one-time, may take a moment)..."
    local tmp="${img}.raw.tmp"
    if ! qemu-img convert -p -f "$fmt" -O raw "$img" "$tmp"; then
        rm -f "$tmp"
        print_status "ERROR" "❌ Conversion to raw failed (original image kept)"
        return 1
    fi
    mv -f "$tmp" "$img"
    print_status "SUCCESS" "✅ Converted to raw: $img"
}

# ── cloud-init seed ───────────────────────────────────────────────────────────
# build the NoCloud seed (volume label "cidata"): cloud-localds, else genisoimage/mkisofs/xorriso
build_seed_image() {
    local out=$1 ud=$2 md=$3 tmpd mk=""
    if command -v cloud-localds >/dev/null 2>&1; then
        if cloud-localds "$out" "$ud" "$md"; then return 0; fi
        print_status "WARN" "⚠️  cloud-localds failed — trying a plain ISO builder"
    fi
    if   command -v genisoimage >/dev/null 2>&1; then mk="genisoimage"
    elif command -v mkisofs     >/dev/null 2>&1; then mk="mkisofs"
    elif command -v xorriso     >/dev/null 2>&1; then mk="xorriso"
    else
        print_status "ERROR" "❌ No tool to build the seed ISO (need cloud-localds, genisoimage, mkisofs or xorriso)"
        return 1
    fi
    tmpd=$(mktemp -d) || return 1
    cp "$ud" "$tmpd/user-data"
    cp "$md" "$tmpd/meta-data"
    if [[ "$mk" == "xorriso" ]]; then
        xorriso -as mkisofs -quiet -output "$out" -volid cidata -joliet -rock "$tmpd" >/dev/null 2>&1 || { rm -rf "$tmpd"; return 1; }
    else
        "$mk" -quiet -output "$out" -volid cidata -joliet -rock "$tmpd/user-data" "$tmpd/meta-data" >/dev/null 2>&1 || { rm -rf "$tmpd"; return 1; }
    fi
    rm -rf "$tmpd"
    return 0
}

create_seed_iso() {
    local ud="/tmp/vm-user-data-$$"
    local md="/tmp/vm-meta-data-$$"

    cat > "$ud" <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: $(printf '%s' "$PASSWORD" | openssl passwd -6 -stdin | tr -d '\n')
chpasswd:
  list: |
    root:$PASSWORD
    $USERNAME:$PASSWORD
  expire: false
EOF

    cat > "$md" <<EOF
instance-id: iid-$VM_NAME-$(date +%s)
local-hostname: $HOSTNAME
EOF

    if ! build_seed_image "$SEED_FILE" "$ud" "$md"; then
        print_status "ERROR" "❌ Failed to create cloud-init seed image"
        rm -f "$ud" "$md"
        return 1
    fi
    rm -f "$ud" "$md"
    return 0
}

# ── create VM ─────────────────────────────────────────────────────────────────
create_new_vm() {
    print_status "INFO" "🆕 Creating a new VM"

    # OS selection (sorted so numbering is stable)
    print_status "INFO" "🌍 Select an OS to set up:"
    local os_options=()
    local i=1 os
    while IFS= read -r os; do
        echo "  $i) $os"
        os_options[$i]="$os"
        i=$((i + 1))
    done < <(printf '%s\n' "${!OS_OPTIONS[@]}" | sort)

    local choice
    while true; do
        read -rp "$(print_status "INPUT" "🎯 Enter your choice (1-${#OS_OPTIONS[@]}): ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#OS_OPTIONS[@]}" ]; then
            os="${os_options[$choice]}"
            IFS='|' read -r OS_TYPE CODENAME IMG_URL \
                DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD \
                <<< "${OS_OPTIONS[$os]}"
            break
        else
            print_status "ERROR" "❌ Invalid selection. Try again."
        fi
    done

    # VM name
    while true; do
        read -rp "$(print_status "INPUT" "🏷️  Enter VM name (default: $DEFAULT_HOSTNAME): ")" VM_NAME
        VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"
        validate_input "name" "$VM_NAME" || continue
        if [[ -f "$VM_DIR/$VM_NAME.conf" ]]; then
            print_status "ERROR" "⚠️  VM with name '$VM_NAME' already exists"
            continue
        fi
        break
    done

    # hostname
    while true; do
        read -rp "$(print_status "INPUT" "🏠 Enter hostname (default: $VM_NAME): ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"
        validate_input "hostname" "$HOSTNAME" && break
    done

    # username
    while true; do
        read -rp "$(print_status "INPUT" "👤 Enter username (default: $DEFAULT_USERNAME): ")" USERNAME
        USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
        validate_input "username" "$USERNAME" && break
    done

    # password
    while true; do
        read -rsp "$(print_status "INPUT" "🔑 Enter password (default: $DEFAULT_PASSWORD): ")" PASSWORD
        PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"
        echo
        [[ -n "$PASSWORD" ]] && break
        print_status "ERROR" "❌ Password cannot be empty"
    done

    # disk size
    while true; do
        read -rp "$(print_status "INPUT" "💾 Disk size (default: 20G): ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-20G}"
        validate_input "size" "$DISK_SIZE" && break
    done

    # memory
    while true; do
        read -rp "$(print_status "INPUT" "🧠 Memory in MB (default: 2048): ")" MEMORY
        MEMORY="${MEMORY:-2048}"
        validate_input "number" "$MEMORY" && break
    done

    # CPUs
    while true; do
        read -rp "$(print_status "INPUT" "⚡ Number of CPUs (default: 2): ")" CPUS
        CPUS="${CPUS:-2}"
        validate_input "number" "$CPUS" && break
    done

    # SSH port
    while true; do
        read -rp "$(print_status "INPUT" "🔌 SSH Port (default: 2222): ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"
        validate_input "port" "$SSH_PORT" || continue
        if ssh_port_taken "$SSH_PORT"; then
            print_status "ERROR" "🚫 Port $SSH_PORT is already in use (listener or another VM)"
            continue
        fi
        break
    done

    # GUI
    local gui_input
    while true; do
        read -rp "$(print_status "INPUT" "🖥️  Enable GUI mode? (y/n, default: n): ")" gui_input
        gui_input="${gui_input:-n}"
        if [[ "$gui_input" =~ ^[Yy]$ ]]; then GUI_MODE=true; break
        elif [[ "$gui_input" =~ ^[Nn]$ ]]; then GUI_MODE=false; break
        fi
        print_status "ERROR" "❌ Please answer y or n"
    done

    # extra port forwards
    read -rp "$(print_status "INPUT" "🌐 Additional port forwards (e.g., 8080:80,8443:443 — Enter for none): ")" PORT_FORWARDS

    # detect accel at create time — saved to conf
    if kvm_available; then
        ACCEL="kvm"
        CPU_MODEL="host"
        print_status "SUCCESS" "🚀 KVM available — will use hardware acceleration"
    else
        ACCEL="tcg"
        CPU_MODEL="max"
        print_status "WARN" "🐌 KVM not available — TCG (software) emulation"
        print_status "INFO" "💡 TCG is slow (first boot can take several minutes): prefer Alpine/Debian, 512–1024MB RAM, 1–2 CPUs"
    fi

    IMG_FILE="$VM_DIR/$VM_NAME.img"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    CREATED="$(date)"

    setup_vm_image || return 1
    save_vm_config
}

# ── setup VM image ────────────────────────────────────────────────────────────
setup_vm_image() {
    mkdir -p "$VM_DIR"
    print_status "INFO" "📥 Downloading and preparing image..."

    local tmp_dl="${IMG_FILE}.download.tmp"
    if [[ ! -f "$IMG_FILE" ]]; then
        print_status "INFO" "🌐 Downloading image from $IMG_URL..."
        if ! wget --tries=3 --timeout=30 --progress=bar:force "$IMG_URL" -O "$tmp_dl"; then
            print_status "ERROR" "❌ Failed to download image from $IMG_URL"
            rm -f "$tmp_dl"
            return 1
        fi
        mv "$tmp_dl" "$IMG_FILE"
    else
        print_status "INFO" "✅ Image file already exists. Skipping download."
    fi

    # convert to raw in-place
    ensure_raw "$IMG_FILE" || return 1

    # resize (grow only — never wipes an existing disk)
    if ! qemu-img resize -f raw "$IMG_FILE" "$DISK_SIZE"; then
        print_status "WARN" "⚠️  Could not resize image to $DISK_SIZE (shrinking is not supported) — keeping current size"
    fi

    create_seed_iso || return 1

    print_status "SUCCESS" "🎉 VM '$VM_NAME' created successfully."
    print_status "INFO" "🔑 Login: username=$USERNAME  password=$PASSWORD"
    print_status "INFO" "🔌 SSH: ssh -p $SSH_PORT $USERNAME@localhost"
}

# ── stop VM ───────────────────────────────────────────────────────────────────
stop_vm() {
    local vm_name=$1
    if ! is_vm_running "$vm_name"; then
        print_status "WARN" "⚠️  VM $vm_name is not running"
        return 0
    fi
    print_status "INFO" "🛑 Stopping $vm_name..."
    if send_monitor_cmd "$(monitor_sock "$vm_name")" "system_powerdown"; then
        print_status "INFO" "⏻  Sent ACPI shutdown — waiting up to 30s for the guest to power off..."
        if wait_vm_exit "$vm_name" 30; then
            rm -f "$(monitor_sock "$vm_name")"
            print_status "SUCCESS" "✅ VM $vm_name shut down cleanly"
            return 0
        fi
        print_status "WARN" "⚠️  Guest did not power off in time — forcing stop"
    fi
    kill_vm_process "$vm_name"
    rm -f "$(monitor_sock "$vm_name")"
    print_status "SUCCESS" "✅ VM $vm_name stopped"
}

# ── start VM ──────────────────────────────────────────────────────────────────
start_vm() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1

    # running guard
    if is_vm_running "$vm_name"; then
        print_status "WARN" "⚠️  VM '$vm_name' is already running"
        read -rp "$(print_status "INPUT" "🔄 Stop and restart? (y/N): ")" restart_choice
        if [[ "$restart_choice" =~ ^[Yy]$ ]]; then
            kill_vm_process "$vm_name"
        else
            return 1
        fi
    fi

    # lock guard
    if ! check_image_lock "$IMG_FILE" "$vm_name"; then
        print_status "ERROR" "🔒 Cannot start VM: Image file is locked by another process"
        read -rp "$(print_status "INPUT" "🔄 Do you want to force kill all QEMU processes using this image? (y/N): ")" force_kill
        if [[ "$force_kill" =~ ^[Yy]$ ]]; then
            pkill -f "qemu-system.*$IMG_FILE" || true
            sleep 2
            if pgrep -f "qemu-system.*$IMG_FILE" >/dev/null; then
                pkill -9 -f "qemu-system.*$IMG_FILE" || true
            fi
            rm -f "${IMG_FILE}.lock" 2>/dev/null || true
            print_status "SUCCESS" "✅ Terminated processes using the image"
        else
            return 1
        fi
    fi

    # sanity checks
    if [[ ! -f "$IMG_FILE" ]]; then
        print_status "ERROR" "❌ VM image file not found: $IMG_FILE"
        return 1
    fi
    if [[ ! -f "$SEED_FILE" ]]; then
        print_status "WARN" "⚠️  Seed file not found, recreating..."
        create_seed_iso || return 1
    fi

    # ── re-detect KVM (host may have changed) ────────────────────────────────
    local accel cpu_model disk_cache aio_mode

    if kvm_available; then
        accel="kvm"
        cpu_model="host"
        disk_cache="none"
        aio_mode="native"      # native AIO requires O_DIRECT (cache=none)
        print_status "SUCCESS" "🚀 KVM available — hardware-accelerated mode"
    else
        accel="tcg"
        cpu_model="max"
        disk_cache="writeback"
        aio_mode="threads"     # aio=native is rejected with cache=writeback
        print_status "WARN" "🐌 KVM not available — TCG (software) emulation"
    fi

    # cache=none needs O_DIRECT — fall back if the filesystem refuses it
    if [[ "$disk_cache" == "none" ]] \
       && ! dd if="$IMG_FILE" of=/dev/null iflag=direct bs=4096 count=1 2>/dev/null; then
        print_status "WARN" "⚠️  Filesystem does not support O_DIRECT — using cache=writeback,aio=threads"
        disk_cache="writeback"
        aio_mode="threads"
    fi

    # warn if the VM asks for more RAM than the host/container can give (OOM-kill = "Killed")
    local host_mb
    host_mb=$(host_mem_limit_mb)
    if (( host_mb > 0 && MEMORY > host_mb )); then
        print_status "WARN" "⚠️  VM wants ${MEMORY}MB but only ~${host_mb}MB is available — QEMU may be killed. Lower MEMORY via Edit."
    fi

    # patch conf
    conf_set "$VM_DIR/$vm_name.conf" ACCEL     "$accel"
    conf_set "$VM_DIR/$vm_name.conf" CPU_MODEL "$cpu_model"
    print_status "INFO" "💾 Patched conf: ACCEL=$accel  CPU_MODEL=$cpu_model"

    # ensure raw
    ensure_raw "$IMG_FILE" || return 1

    # ── build QEMU command ───────────────────────────────────────────────────
    local -a qemu_cmd=(
        qemu-system-x86_64
        -name "$vm_name"
        -m "$MEMORY"
        -smp "$CPUS"
        -machine "type=pc,accel=${accel},hpet=off"
        -cpu "$cpu_model"
        -monitor "unix:$(monitor_sock "$vm_name"),server,nowait"
    )

    [[ "$accel" == "kvm" ]] && qemu_cmd+=( -enable-kvm )

    # disks — raw + virtio-blk-pci
    qemu_cmd+=(
        -drive "file=${IMG_FILE},format=raw,if=none,id=hd0,cache=${disk_cache},aio=${aio_mode}"
        -device "virtio-blk-pci,drive=hd0"
        -drive "file=${SEED_FILE},format=raw,if=none,id=cd0,readonly=on"
        -device "virtio-blk-pci,drive=cd0"
        -boot order=c
    )

    # network — one virtio NIC, all port forwards on the same user netdev
    local hostfwd="hostfwd=tcp:${BIND_ADDR}:${SSH_PORT}-:22"
    if [[ -n "${PORT_FORWARDS:-}" ]]; then
        local -a fwds
        local fwd hport gport
        IFS=',' read -ra fwds <<< "${PORT_FORWARDS// /}"
        for fwd in "${fwds[@]}"; do
            [[ -z "$fwd" ]] && continue
            IFS=':' read -r hport gport <<< "$fwd"
            if [[ "$hport" =~ ^[0-9]+$ && "$gport" =~ ^[0-9]+$ ]]; then
                hostfwd+=",hostfwd=tcp:${BIND_ADDR}:${hport}-:${gport}"
            else
                print_status "WARN" "⚠️  Ignoring invalid port forward '$fwd' (expected host:guest)"
            fi
        done
    fi
    qemu_cmd+=(
        -device "virtio-net-pci,netdev=net0"
        -netdev "user,id=net0,${hostfwd}"
    )

    # display
    if [[ "${GUI_MODE:-false}" == "true" && -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        print_status "WARN" "⚠️  GUI mode needs a graphical session (DISPLAY not set) — using console instead"
    fi
    if [[ "${GUI_MODE:-false}" == "true" && -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        qemu_cmd+=( -vga virtio -display gtk )
        print_status "INFO" "🖥️  GUI mode"
    else
        qemu_cmd+=( -nographic -serial mon:stdio )
        print_status "INFO" "📟 Console mode — Ctrl+A then X to exit"
    fi

    # shared extras
    qemu_cmd+=(
        -device virtio-balloon-pci
        -object rng-random,filename=/dev/urandom,id=rng0
        -device virtio-rng-pci,rng=rng0
        -rtc base=utc,clock=host
    )

    if [[ -z "$BIND_ADDR" && "$PASSWORD" == "${OS_TYPE}123" ]]; then
        print_status "WARN" "⚠️  Default password + SSH port open on all interfaces — change it (Edit) or run with BIND_ADDR=127.0.0.1"
    fi

    # announce
    echo
    echo "📊 VM: $vm_name | accel: $accel | cpu: $cpu_model | RAM: ${MEMORY}MB | CPUs: $CPUS | disk: raw+virtio"
    print_status "INFO" "🔌 SSH: ssh -p ${SSH_PORT} ${USERNAME}@localhost"
    print_status "INFO" "🔑 Password: $PASSWORD"
    echo

    # fire
    rm -f "$(monitor_sock "$vm_name")"
    local t0=$SECONDS rc=0
    "${qemu_cmd[@]}" || rc=$?
    if (( rc != 0 )) && [[ "$accel" == "kvm" ]] && (( SECONDS - t0 < 15 )); then
        print_status "WARN" "⚠️  QEMU failed to start with KVM — retrying with TCG (software emulation)"
        local -a tcg_cmd=()
        local el prev=""
        for el in "${qemu_cmd[@]}"; do
            [[ "$el" == "-enable-kvm" ]] && continue
            [[ "$el" == "type=pc,accel=kvm,hpet=off" ]] && el="type=pc,accel=tcg,hpet=off"
            [[ "$prev" == "-cpu" && "$el" == "host" ]] && el="max"
            tcg_cmd+=( "$el" )
            prev="$el"
        done
        conf_set "$VM_DIR/$vm_name.conf" ACCEL "tcg"
        conf_set "$VM_DIR/$vm_name.conf" CPU_MODEL "max"
        rm -f "$(monitor_sock "$vm_name")"
        rc=0
        "${tcg_cmd[@]}" || rc=$?
    fi
    if (( rc != 0 )); then
        print_status "ERROR" "❌ QEMU exited with error (code $rc)"
        rm -f "${IMG_FILE}.lock" "$(monitor_sock "$vm_name")" 2>/dev/null || true
        return 1
    fi
    rm -f "$(monitor_sock "$vm_name")"

    print_status "INFO" "🛑 VM $vm_name shut down"
}

# ── edit VM config ────────────────────────────────────────────────────────────
edit_vm_config() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1

    local running=false
    if is_vm_running "$vm_name"; then
        running=true
        print_status "WARN" "⚠️  VM is running — changes apply after restart; hostname/user/password need the VM stopped"
    fi

    local choice new
    while true; do
        echo
        print_status "INFO" "✏️  Editing VM: $vm_name"
        echo "  1) Hostname        ($HOSTNAME)"
        echo "  2) Username        ($USERNAME)"
        echo "  3) Password"
        echo "  4) SSH port        ($SSH_PORT)"
        echo "  5) Memory (MB)     ($MEMORY)"
        echo "  6) CPUs            ($CPUS)"
        echo "  7) GUI mode        ($GUI_MODE)"
        echo "  8) Port forwards   (${PORT_FORWARDS:-none})"
        echo "  0) Back"
        read -rp "$(print_status "INPUT" "🎯 Choose: ")" choice

        case $choice in
            1)
                if $running; then print_status "ERROR" "❌ Stop the VM first (its cloud-init seed is in use)"; continue; fi
                read -rp "$(print_status "INPUT" "🏠 New hostname: ")" new
                if validate_input "hostname" "$new"; then
                    HOSTNAME="$new"; save_vm_config; create_seed_iso || true
                fi ;;
            2)
                if $running; then print_status "ERROR" "❌ Stop the VM first (its cloud-init seed is in use)"; continue; fi
                read -rp "$(print_status "INPUT" "👤 New username: ")" new
                if validate_input "username" "$new"; then
                    USERNAME="$new"; save_vm_config; create_seed_iso || true
                fi ;;
            3)
                if $running; then print_status "ERROR" "❌ Stop the VM first (its cloud-init seed is in use)"; continue; fi
                read -rsp "$(print_status "INPUT" "🔑 New password: ")" new; echo
                if [[ -n "$new" ]]; then
                    PASSWORD="$new"; save_vm_config; create_seed_iso || true
                else
                    print_status "ERROR" "❌ Password cannot be empty"
                fi ;;
            4)
                read -rp "$(print_status "INPUT" "🔌 New SSH port: ")" new
                if validate_input "port" "$new"; then
                    if [[ "$new" != "$SSH_PORT" ]] && ssh_port_taken "$new" "$vm_name"; then
                        print_status "ERROR" "🚫 Port $new is already in use (listener or another VM)"
                    else
                        SSH_PORT="$new"; save_vm_config
                    fi
                fi ;;
            5)
                read -rp "$(print_status "INPUT" "🧠 New memory (MB): ")" new
                if validate_input "number" "$new"; then MEMORY="$new"; save_vm_config; fi ;;
            6)
                read -rp "$(print_status "INPUT" "⚡ New CPU count: ")" new
                if validate_input "number" "$new"; then CPUS="$new"; save_vm_config; fi ;;
            7)
                if [[ "$GUI_MODE" == "true" ]]; then GUI_MODE=false; else GUI_MODE=true; fi
                save_vm_config ;;
            8)
                read -rp "$(print_status "INPUT" "🌐 Port forwards (e.g. 8080:80,8443:443 — empty to clear): ")" new
                PORT_FORWARDS="$new"; save_vm_config ;;
            0) break ;;
            *) print_status "ERROR" "❌ Invalid choice" ;;
        esac
    done
    print_status "INFO" "ℹ️  Hostname/user/password changes are re-applied by cloud-init on next boot (new seed)."
}

# ── resize disk ───────────────────────────────────────────────────────────────
resize_vm_disk() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1

    if is_vm_running "$vm_name"; then
        print_status "ERROR" "❌ Stop the VM before resizing its disk"
        return 1
    fi

    print_status "INFO" "💾 Current disk size: $DISK_SIZE"
    local new
    while true; do
        read -rp "$(print_status "INPUT" "📈 New disk size (e.g. 40G): ")" new
        validate_input "size" "$new" && break
    done

    if qemu-img resize -f raw "$IMG_FILE" "$new"; then
        DISK_SIZE="$new"
        save_vm_config
        print_status "SUCCESS" "✅ Disk resized to $new (guest grows its filesystem on next boot)"
    else
        print_status "ERROR" "❌ Resize failed — shrinking is not supported (data is untouched)"
        return 1
    fi
}

# ── delete VM ─────────────────────────────────────────────────────────────────
delete_vm() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1

    print_status "WARN" "🗑️  This permanently deletes VM '$vm_name' (disk, seed, config)"
    local confirm
    read -rp "$(print_status "INPUT" "Type the VM name to confirm: ")" confirm
    if [[ "$confirm" != "$vm_name" ]]; then
        print_status "INFO" "↩️  Cancelled"
        return 1
    fi

    is_vm_running "$vm_name" && stop_vm "$vm_name"
    rm -f "$IMG_FILE" "${IMG_FILE}.lock" "$SEED_FILE" "$(monitor_sock "$vm_name")" "$VM_DIR/$vm_name.conf"
    print_status "SUCCESS" "✅ VM '$vm_name' deleted"
}

# ── performance ───────────────────────────────────────────────────────────────
show_vm_performance() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1

    echo
    print_status "INFO" "📈 Performance: $vm_name"
    if is_vm_running "$vm_name"; then
        local pid
        pid=$(pgrep -f "$(vm_pattern "$vm_name")" | head -1)
        echo "🔹 QEMU process:"
        ps -p "$pid" -o pid,%cpu,%mem,rss,etime
        echo
    else
        print_status "WARN" "⚠️  VM is not running"
    fi
    echo "🔹 Disk usage (actual / apparent):"
    du -h "$IMG_FILE" | awk '{print "   actual:   " $1}'
    du -h --apparent-size "$IMG_FILE" | awk '{print "   apparent: " $1}'
    echo
    echo "🔹 Host memory:"
    free -h
    echo
}

# ── main menu ─────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        display_header

        local -a vms
        mapfile -t vms < <(get_vm_list)
        if (( ${#vms[@]} > 0 )); then
            print_status "INFO" "📂 Found ${#vms[@]} VM(s):"
            local i=1 vm
            for vm in "${vms[@]}"; do
                if is_vm_running "$vm"; then
                    printf "  %2d) 🚀 %s\n" "$i" "$vm"
                else
                    printf "  %2d) 💤 %s\n" "$i" "$vm"
                fi
                i=$((i + 1))
            done
            echo
        else
            print_status "INFO" "📭 No VMs yet — create one first"
            echo
        fi

        echo "Main Menu:"
        echo "  1) 🆕 Create a new VM"
        if (( ${#vms[@]} > 0 )); then
            echo "  2) 🚀 Start a VM"
            echo "  3) 🛑 Stop a VM"
            echo "  4) 📊 Show VM info"
            echo "  5) ✏️  Edit VM configuration"
            echo "  6) 🗑️  Delete a VM"
            echo "  7) 💾 Resize VM disk"
            echo "  8) 📈 Show VM performance"
        fi
        echo "  0) 👋 Exit"
        echo

        local choice
        read -rp "$(print_status "INPUT" "🎯 Enter your choice: ")" choice

        case $choice in
            1) create_new_vm || true; pause ;;
            2) if (( ${#vms[@]} > 0 )) && select_vm; then start_vm "$SELECTED_VM" || true; pause; fi ;;
            3) if (( ${#vms[@]} > 0 )) && select_vm; then stop_vm "$SELECTED_VM" || true; pause; fi ;;
            4) if (( ${#vms[@]} > 0 )) && select_vm; then show_vm_info "$SELECTED_VM" || true; fi ;;
            5) if (( ${#vms[@]} > 0 )) && select_vm; then edit_vm_config "$SELECTED_VM" || true; pause; fi ;;
            6) if (( ${#vms[@]} > 0 )) && select_vm; then delete_vm "$SELECTED_VM" || true; pause; fi ;;
            7) if (( ${#vms[@]} > 0 )) && select_vm; then resize_vm_disk "$SELECTED_VM" || true; pause; fi ;;
            8) if (( ${#vms[@]} > 0 )) && select_vm; then show_vm_performance "$SELECTED_VM" || true; pause; fi ;;
            0) print_status "INFO" "👋 Goodbye!"; exit 0 ;;
            *) print_status "ERROR" "❌ Invalid option"; sleep 1 ;;
        esac
    done
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
    check_dependencies
    if ! mkdir -p "$VM_DIR" 2>/dev/null || [[ ! -w "$VM_DIR" ]]; then
        if [[ -z "$VM_DIR_FROM_ENV" && -n "${HOME:-}" ]]; then
            print_status "WARN" "⚠️  Cannot write to $VM_DIR — using $HOME/minhneko-vms instead"
            VM_DIR="$HOME/minhneko-vms"
            mkdir -p "$VM_DIR" 2>/dev/null || true
        fi
        if [[ ! -w "$VM_DIR" ]]; then
            print_status "ERROR" "Cannot write to $VM_DIR — run with sudo or set VM_DIR=/path/you/own"
            exit 1
        fi
        sleep 1
    fi
    main_menu
}

main "$@"
