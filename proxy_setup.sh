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

set_proxy_curl() {
    echo "[*] Configuring curl proxy via ~/.curlrc..."
    local conf_file="$HOME/.curlrc"
    mkdir -p "$(dirname "$conf_file")" 2>/dev/null
    
    if [ -f "$conf_file" ]; then
        sed -i '/^proxy /d; /^proxy = /d' "$conf_file" || true
    fi
    
    echo "proxy = ${PROXY_HOST}:${PROXY_PORT}" >> "$conf_file"
    echo "[*] curl proxy set in $conf_file"
}

set_git_user() {
    echo "[*] Configuring git user..."
    git config --global user.name "laoshanxi"
    git config --global user.email "178029200@qq.com"
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

set_proxy_wsl_environment() {
    echo "[*] Configuring system-wide proxy via /etc/environment..."
    local env_file="/etc/environment"
    local temp_file="$(mktemp)"
    
    # Copy existing content
    if [ -f "$env_file" ]; then
        cp "$env_file" "$temp_file"
    fi
    
    # Remove existing proxy lines
    sed -i '/^http_proxy=/d; /^https_proxy=/d; /^HTTP_PROXY=/d; /^HTTPS_PROXY=/d; /^no_proxy=/d; /^NO_PROXY=/d' "$temp_file" 2>/dev/null || true
    
    # Append new proxy settings
    {
        echo "http_proxy=$PROXY"
        echo "https_proxy=$PROXY"
        echo "HTTP_PROXY=$PROXY"
        echo "HTTPS_PROXY=$PROXY"
        echo 'no_proxy="localhost,127.0.0.1,::1"'
        echo 'NO_PROXY="localhost,127.0.0.1,::1"'
    } >> "$temp_file"
    
    # Write back with sudo
    sudo cp "$temp_file" "$env_file"
    rm -f "$temp_file"
    
    echo "[*] System-wide proxy set in $env_file"
}

set_alias_ll() {
    echo "[*] Setting up 'll' alias globally via /etc/profile.d/aliases.sh..."
    local alias_file="/etc/profile.d/aliases.sh"
    
    # Ensure directory exists
    sudo mkdir -p "$(dirname "$alias_file")"
    
    # Truncate and recreate the file with all aliases
    sudo bash -c "cat > $alias_file" <<'EOF'
#!/bin/bash
# System-wide aliases — loaded for all users

# List files in long format
alias ll='ls -l'
alias la='ls -A'
alias l='ls -CF'
EOF
    
    sudo chmod +x "$alias_file"
    echo "[*] 'll' alias setup completed in $alias_file"
}

set_proxy_docker() {
    # echo "[*] Configuring Docker permission..."
    # sudo usermod -aG docker $USER
    # newgrp docker
    
    echo "[*] Configuring Docker proxy..."
    
    # Docker systemd service config directory
    local docker_conf_dir="/etc/systemd/system/docker.service.d"
    local docker_conf_file="${docker_conf_dir}/http-proxy.conf"
    
    # Create directory if not exists
    sudo mkdir -p "$docker_conf_dir"
    
    # Write proxy configuration to the file
    sudo bash -c "cat > $docker_conf_file" <<EOF
[Service]
Environment="HTTP_PROXY=$PROXY"
Environment="HTTPS_PROXY=$PROXY"
Environment="NO_PROXY=localhost,127.0.0.1,::1"
EOF
    
    # Reload systemd and restart Docker
    sudo systemctl daemon-reload
    sudo systemctl restart docker
    
    # Wait a moment for Docker to start
    sleep 2
    
    # Verify Docker proxy is set (optional)
    if command -v docker &> /dev/null; then
        echo "[*] Verifying Docker proxy settings..."
        docker info | grep -E "(HTTP Proxy|HTTPS Proxy|No Proxy)" || echo "[!] Docker proxy may not be active — ensure Docker is running."
    else
        echo "[!] Docker is not installed or not in PATH."
    fi
    
    echo "[*] Docker proxy configured in $docker_conf_file"
}

set_proxy_docker_build_image() {
    sudo bash -c "cat > Dockerfile" <<EOF
    FROM python:3.13.7-slim-bookworm AS build_stage

    # --- Proxy configuration ---
    ENV HTTP_PROXY=http://172.22.62.85:7890
    ENV HTTPS_PROXY=http://172.22.62.85:7890
    # Optional: If using apt/yum/pip/wget inside container
    RUN echo "Acquire::http::Proxy \"$HTTP_PROXY\";" > /etc/apt/apt.conf.d/01proxy \
        && echo "Acquire::https::Proxy \"$HTTPS_PROXY\";" >> /etc/apt/apt.conf.d/01proxy \
        && echo "export http_proxy=$HTTP_PROXY" >> ~/.bashrc \
        && echo "export https_proxy=$HTTPS_PROXY" >> ~/.bashrc
    # --- End proxy config ---
    EOF
}


set_all() {
    set_proxy_wget
    set_proxy_curl
    set_proxy_git
    set_proxy_apt
    set_proxy_pip
    set_proxy_wsl_environment
    set_proxy_docker
    set_alias_ll
    echo "[*] Proxy configuration applied successfully."
}

set_all
