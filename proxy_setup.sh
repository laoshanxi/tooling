#!/usr/bin/env bash
# Configure proxy for Debian tools: wget, git, apt, pip
# Default proxy: 127.0.0.1:7890
# Re-execution will update existing configurations

PROXY_HOST="127.0.0.1"
PROXY_PORT="7890"
PROXY="http://${PROXY_HOST}:${PROXY_PORT}"

set_proxy_wget() {
    echo "[*] Configuring wget proxy..."
    local conf_file="$HOME/.wgetrc"
    grep -q "http_proxy" "$conf_file" 2>/dev/null && \
    sed -i "s|^http_proxy=.*|http_proxy = $PROXY|g" "$conf_file" || \
    echo "http_proxy = $PROXY" >> "$conf_file"
    
    grep -q "https_proxy" "$conf_file" 2>/dev/null && \
    sed -i "s|^https_proxy=.*|https_proxy = $PROXY|g" "$conf_file" || \
    echo "https_proxy = $PROXY" >> "$conf_file"
}

set_proxy_git() {
    echo "[*] Configuring git proxy..."
    git config --global http.proxy "$PROXY"
    git config --global https.proxy "$PROXY"
}

set_proxy_apt() {
    echo "[*] Configuring apt proxy..."
    local conf_dir="/etc/apt/apt.conf.d"
    local conf_file="${conf_dir}/80proxy"
    
    sudo mkdir -p "$conf_dir"
    sudo bash -c "cat > $conf_file" <<EOF
Acquire::http::Proxy "$PROXY";
Acquire::https::Proxy "$PROXY";
EOF
}

set_proxy_pip() {
    echo "[*] Configuring pip proxy..."
    local conf_dir="$HOME/.config/pip"
    local conf_file="${conf_dir}/pip.conf"
    mkdir -p "$conf_dir"
    
    if [ -f "$conf_file" ]; then
        sed -i "s|^proxy = .*|proxy = ${PROXY_HOST}:${PROXY_PORT}|g" "$conf_file" || true
    else
        cat > "$conf_file" <<EOF
[global]
proxy = ${PROXY_HOST}:${PROXY_PORT}
EOF
    fi
}

set_all() {
    set_proxy_wget
    set_proxy_git
    set_proxy_apt
    set_proxy_pip
    echo "[*] Proxy configuration applied successfully."
}

set_all
