#!/usr/bin/env bash
# Configure proxy for Debian/Ubuntu tools: wget, curl, git, apt, pip, maven, node.js, docker
# Default proxy: 127.0.0.1:7890
# Re-execution will update existing configurations

PROXY_HOST="127.0.0.1"
PROXY_PORT="7890"
PROXY="http://${PROXY_HOST}:${PROXY_PORT}"

# Detect WSL
is_wsl() {
  grep -qi "microsoft" /proc/version 2>/dev/null || [ -n "$WSL_DISTRO_NAME" ]
}

set_proxy_wget() {
  echo "[*] Configuring wget proxy..."
  local conf_file="$HOME/.wgetrc"
  if grep -q "^http_proxy" "$conf_file" 2>/dev/null; then
    sed -i "s|^http_proxy.*|http_proxy = $PROXY|g" "$conf_file"
  else
    echo "http_proxy = $PROXY" >> "$conf_file"
  fi
  if grep -q "^https_proxy" "$conf_file" 2>/dev/null; then
    sed -i "s|^https_proxy.*|https_proxy = $PROXY|g" "$conf_file"
  else
    echo "https_proxy = $PROXY" >> "$conf_file"
  fi
}

set_proxy_curl() {
  echo "[*] Configuring curl proxy..."
  local conf_file="$HOME/.curlrc"
  [ -f "$conf_file" ] && sed -i '/^proxy[[:space:]]/d; /^proxy =/d' "$conf_file" || true
  echo "proxy = ${PROXY_HOST}:${PROXY_PORT}" >> "$conf_file"
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
  sudo bash -c "cat > $conf_file <<EOF
Acquire {
  HTTP { Proxy \"$PROXY\"; }
  HTTPS { Proxy \"$PROXY\"; }
}
EOF"
  echo "[*] APT proxy configured in $conf_file"
  echo "[*] Running apt-get update to verify proxy..."
  # sudo apt-get update -qq || echo "[!] apt-get update failed (proxy may not be reachable)."
}

set_proxy_maven() {
  echo "[*] Configuring Maven proxy..."
  local m2_dir="$HOME/.m2"
  local settings_file="${m2_dir}/settings.xml"
  mkdir -p "$m2_dir"

  cat > "$settings_file" <<EOF
<settings>
  <proxies>
    <proxy>
      <id>default-proxy</id>
      <active>true</active>
      <protocol>http</protocol>
      <host>${PROXY_HOST}</host>
      <port>${PROXY_PORT}</port>
      <nonProxyHosts>localhost|127.0.0.1</nonProxyHosts>
    </proxy>
  </proxies>
</settings>
EOF

  echo "[*] Maven proxy configured in $settings_file"
}

set_proxy_node() {
  echo "[*] Configuring Node.js (npm / yarn) proxy..."
  if command -v npm >/dev/null 2>&1; then
    npm config set proxy "$PROXY"
    npm config set https-proxy "$PROXY"
    npm config set strict-ssl false
    echo "[*] npm proxy configured."
  else
    echo "[!] npm not found, skipping npm proxy."
  fi
  if command -v yarn >/dev/null 2>&1; then
    yarn config set proxy "$PROXY"
    yarn config set https-proxy "$PROXY"
    yarn config set strict-ssl false
    echo "[*] yarn proxy configured."
  else
    echo "[!] yarn not found, skipping yarn proxy."
  fi
}

set_proxy_wsl_environment() {
  if ! is_wsl; then
    echo "[*] Not running in WSL — skipping /etc/environment proxy config."
    return
  fi

  echo "[*] Configuring system-wide proxy (/etc/environment)..."
  local env_file="/etc/environment"
  local tmpf
  tmpf=$(mktemp)
  [ -f "$env_file" ] && cp "$env_file" "$tmpf"
  sed -i '/^http_proxy=/d; /^https_proxy=/d; /^HTTP_PROXY=/d; /^HTTPS_PROXY=/d; /^no_proxy=/d; /^NO_PROXY=/d' "$tmpf" || true
  {
    echo "http_proxy=$PROXY"
    echo "https_proxy=$PROXY"
    echo "HTTP_PROXY=$PROXY"
    echo "HTTPS_PROXY=$PROXY"
    echo 'no_proxy="localhost,127.0.0.1,::1"'
    echo 'NO_PROXY="localhost,127.0.0.1,::1"'
  } >> "$tmpf"
  sudo cp "$tmpf" "$env_file"
  rm -f "$tmpf"
  echo "[*] System-wide proxy set in $env_file"
  echo "[!] Please log out and log back in (or reboot) for environment changes to take effect."
}

set_alias_ll() {
  echo "[*] Setting up system-wide 'll' alias..."
  local alias_file="/etc/profile.d/aliases.sh"
  sudo bash -c "cat > $alias_file <<'EOF'
#!/bin/bash
alias ll='ls -l'
alias la='ls -A'
alias l='ls -CF'
EOF"
  sudo chmod +x "$alias_file"
}

set_proxy_docker() {
  echo "[*] Configuring Docker proxy..."
  local docker_conf_dir="/etc/systemd/system/docker.service.d"
  local docker_conf_file="${docker_conf_dir}/http-proxy.conf"
  sudo mkdir -p "$docker_conf_dir"
  sudo bash -c "cat > $docker_conf_file <<EOF
[Service]
Environment=\"HTTP_PROXY=${PROXY}\" \"HTTPS_PROXY=${PROXY}\" \"NO_PROXY=localhost,127.0.0.1,docker.internal\"
EOF"
  echo "[*] Docker proxy configured in $docker_conf_file"
  echo "[*] Reloading and restarting Docker..."
  sudo systemctl daemon-reload
  sudo systemctl restart docker
}

set_proxy_docker_build_image() {
  echo "[*] Configuring Docker build-time proxy..."
  local apt_proxy_file="/etc/apt/apt.conf.d/01proxy"
  sudo bash -c "cat > $apt_proxy_file <<EOF
Acquire::http::Proxy \"$PROXY\";
Acquire::https::Proxy \"$PROXY\";
EOF"
  # avoid duplicate exports
  sed -i '/http_proxy=/d;/https_proxy=/d' "$HOME/.bashrc"
  {
    echo "export http_proxy=$PROXY"
    echo "export https_proxy=$PROXY"
  } >> "$HOME/.bashrc"
  echo "[!] Please reload your shell (source ~/.bashrc) for build-time proxy vars."
}

set_all() {
  set_proxy_wget
  set_proxy_curl
  set_proxy_git
  set_git_user
  set_proxy_apt
  set_proxy_maven
  set_proxy_node
  set_proxy_wsl_environment   # only runs in WSL now
  set_proxy_docker
  set_proxy_docker_build_image
  set_alias_ll
  echo "[*] Proxy configuration applied successfully."
}

set_all
