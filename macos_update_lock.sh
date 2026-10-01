#!/bin/bash
#
# macos_update_lock.sh — 彻底关闭 macOS 系统更新，并可完整还原
#
#   sudo bash macos_update_lock.sh apply    关闭更新（含安全更新），别名 off
#   sudo bash macos_update_lock.sh restore  还原到关闭前的状态，别名 on
#   bash macos_update_lock.sh status        查看当前状态（不需要 sudo）
#
# 关闭前会把原状备份到 /var/db/macos-update-lock/，还原时按备份逐项回滚。
# 即使备份被删，on 也会用内置默认值尽力还原。
#
# 三层防护的实际效力（2026-10 在 macOS 15.7.5 上实测）：
#   /etc/hosts 屏蔽  ← 真正扛住的一层，重启后依然有效
#   偏好开关         ← 有效，重启后依然有效
#   launchctl 禁用   ← 只在本开机周期内有效，macOS 重启时会强制重新启用系统守护进程
#
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# These identifiers are deliberately frozen and do NOT track the script
# filename. They are already written into /etc/hosts and /var/db on machines
# where an earlier version ran; renaming them would orphan that state and leave
# a second hosts block behind on the next run.
BACKUP_DIR="/var/db/macos-update-lock"
MANIFEST="$BACKUP_DIR/disabled-services.txt"
HOSTS_FILE="/etc/hosts"
MARK_BEGIN="# macos-update-lock BEGIN"
MARK_END="# macos-update-lock END"

# 要屏蔽的 Apple 更新服务器。
#
# 刻意不挡这两个：
#   mesu.apple.com — 挡了会让 Finder 刷不了 iPhone/iPad。它同时是部分移动资产的 XML 回退
#                    路径，留着能替被 gdmf 屏蔽波及的资产挽回一点。
#   ocsp.apple.com — 证书吊销校验，挡了一大片 App 的 TLS 会出问题。
#
# gdmf.apple.com 挡回去（2026-10-01 实测后的取舍）：它是 Pallas，mobileassetd 的「通用」
# 资产清单端点 —— Apple 把系统更新清单和其它所有资产的清单复用在这一个端点上，没法按域名
# 切开。放行它，softwareupdated 就能直接查到 macOS 27.0.1 并做资产暂存查询（载荷下载仍被
# swcdn 挡住，装不上，但守护进程有了可见性）。挡回去的代价是 trustd 的证书信任补充、Siri
# 语音资产、唤醒词也一起下不来 —— 这是明确比较过、选择接受的取舍。
#
# 剩下的这些足以拦住系统更新：没有 swscan 就发现不了更新，没有 swcdn 就下不动包。
BLOCK_HOSTS=(
  swscan.apple.com swdist.apple.com swquery.apple.com
  swdownload.apple.com swcdn.apple.com suconfig.apple.com
  gdmf.apple.com appldnld.apple.com
)

SYS_DAEMONS=(
  system/com.apple.softwareupdated
  system/com.apple.suhelperd
)
# 进程名（用于 pgrep/killall）。注意它和上面的 launchd job label 不是一回事，
# 进程叫 softwareupdated，job 叫 com.apple.softwareupdated。
DAEMON_PROCS=(softwareupdated suhelperd)

SWU_PLIST="/Library/Preferences/com.apple.SoftwareUpdate.plist"
COMMERCE_PLIST="/Library/Preferences/com.apple.commerce.plist"

SWU_KEYS=(AutomaticCheckEnabled AutomaticDownload AutomaticallyInstallMacOSUpdates CriticalUpdateInstall ConfigDataInstall)
# AutoUpdateRestartRequired 不收进来：它是受管键（写不进），且只对 MDM 强制重启策略有意义，
# 非受管 Mac 上设不设都一样，留着只会在核验时冒一个没意义的 ✗
COMMERCE_KEYS=(AutoUpdate)

# ---------- 输出 ----------
ok()   { printf '      \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '      \033[33m·\033[0m %s\n' "$*"; }
bad()  { printf '      \033[31m✗\033[0m %s\n' "$*"; }
head1() { printf '\n\033[1m%s\033[0m\n' "$*"; }

need_root() {
  [ "$(id -u)" -eq 0 ] || { bad "需要 root：sudo bash $0 $1"; exit 1; }
}

REAL_USER="${SUDO_USER:-$(stat -f %Su /dev/console 2>/dev/null || echo "")}"
REAL_UID_NUM=""
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
  REAL_UID_NUM="$(id -u "$REAL_USER" 2>/dev/null || echo "")"
fi
as_user() {
  if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    sudo -u "$REAL_USER" "$@"
  else
    "$@"
  fi
}

# 从 plist 文件直读某个键的原始值（绕开 cfprefsd 缓存）。
# 键不存在时 plutil 会把错误信息打到 stdout，所以必须用退出码判断，不能看输出。
plist_get() {
  local v
  v="$(plutil -extract "$2" raw -o - "$1" 2>/dev/null)" || return 1
  printf '%s' "$v"
}

show_key() {
  local v
  printf '    %-32s ' "$2"
  if v="$(plist_get "$1" "$2")"; then
    case "$v" in
      false|0) printf '\033[32m关闭\033[0m\n' ;;
      *)       printf '\033[33m开启（%s）\033[0m\n' "$v" ;;
    esac
  elif [ "$2" = "AutomaticCheckEnabled" ]; then
    printf '\033[33m未写入 — 受管键，仅 MDM 描述文件可改\033[0m\n'
  else
    printf '未写入（系统默认）\n'
  fi
}

# ---------- 备份 ----------
backup_once() {
  if [ -f "$BACKUP_DIR/.backed-up" ]; then
    warn "已有原始备份，保留不覆盖"
    return 0
  fi
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
  cp "$HOSTS_FILE" "$BACKUP_DIR/hosts.orig" 2>/dev/null && ok "/etc/hosts"
  for p in "$SWU_PLIST" "$COMMERCE_PLIST"; do
    if [ -f "$p" ]; then
      cp "$p" "$BACKUP_DIR/$(basename "${p%.plist}").orig.plist" && ok "$(basename "$p")"
    else
      warn "$(basename "$p") 原本不存在 → 还原时会删掉它"
    fi
  done
  : > "$BACKUP_DIR/.backed-up"
}

# ---------- 偏好设置 ----------
# 注意：cfprefsd 会静默丢弃某些「受管键」（macOS 15 起 AutomaticCheckEnabled 即是），
# 所以写完必须回读磁盘核验，不能拿 defaults write 的退出码当成功。
set_domain_false() {
  local live="$1"; shift
  local k
  for k in "$@"; do defaults write "$live" "$k" -bool false 2>/dev/null; done
}

# 回读磁盘核验。defaults write 的退出码不可信 —— cfprefsd 会静默丢弃受管键，
# 而且写入当时落盘、随后被 softwareupdated 回写覆盖也是可能的，所以单独做一遍终检。
# 失败的键记进 VERIFY_FAILED（bash 3.2 没有可靠的空数组展开，用字符串）
VERIFY_FAILED=""
verify_domain() {
  local live="$1"; shift
  local k v
  for k in "$@"; do
    if v="$(plist_get "$live" "$k")"; then
      if [ "$v" = "false" ] || [ "$v" = "0" ]; then ok "$k = false"
      else bad "$k 未生效（磁盘上是 $v）"; VERIFY_FAILED="$VERIFY_FAILED $k"; fi
    else
      bad "$k 未落盘"; VERIFY_FAILED="$VERIFY_FAILED $k"
    fi
  done
}

restore_domain() {
  local live="$1" orig="$2"; shift 2
  local k v
  for k in "$@"; do
    v=""
    [ -f "$orig" ] && v="$(defaults read "$orig" "$k" 2>/dev/null)"
    if [ -n "$v" ]; then
      case "$v" in
        0|1) defaults write "$live" "$k" -bool "$v" ;;
        *)   defaults write "$live" "$k" -string "$v" ;;
      esac
      ok "$k → $v（原值）"
    else
      if defaults delete "$live" "$k" 2>/dev/null; then
        ok "$k → 已删除（原本就没有）"
      else
        warn "$k 原本就没有"
      fi
    fi
  done
}

# ---------- /etc/hosts ----------
hosts_locked() { grep -qF "$MARK_BEGIN" "$HOSTS_FILE" 2>/dev/null; }

hosts_strip() {
  [ -f "$HOSTS_FILE" ] || return 0
  sed -i '' "/^${MARK_BEGIN}$/,/^${MARK_END}$/d" "$HOSTS_FILE"
}

hosts_inject() {
  hosts_strip
  # 若文件末尾没有换行符，先补一个，避免和标记行粘连
  if [ -s "$HOSTS_FILE" ] && [ -n "$(tail -c1 "$HOSTS_FILE")" ]; then
    echo "" >> "$HOSTS_FILE"
  fi
  {
    echo "$MARK_BEGIN"
    echo "# 由 macos_update_lock.sh 添加 — 阻止 macOS 更新服务器"
    echo "# 还原：sudo bash macos_update_lock.sh on"
    local h
    for h in "${BLOCK_HOSTS[@]}"; do echo "0.0.0.0 $h"; done
    echo "$MARK_END"
  } >> "$HOSTS_FILE"
}

flush_dns() {
  dscacheutil -flushcache 2>/dev/null || true
  killall -HUP mDNSResponder 2>/dev/null || true
}

# ---------- off ----------
cmd_off() {
  need_root off
  VERIFY_FAILED=""
  printf '\n\033[1m关闭 macOS 系统更新\033[0m\n'

  head1 "[1/6] 备份原状 → $BACKUP_DIR"
  backup_once

  head1 "[2/6] 关闭所有自动更新开关"
  set_domain_false "$SWU_PLIST" "${SWU_KEYS[@]}"
  set_domain_false "$COMMERCE_PLIST" "${COMMERCE_KEYS[@]}"
  warn "已写入 $(( ${#SWU_KEYS[@]} + ${#COMMERCE_KEYS[@]} )) 个开关 —— 能否落盘见 [6/6] 核验"
  if softwareupdate --schedule off >/dev/null 2>&1; then
    ok "softwareupdate 调度已关闭"
  else
    warn "softwareupdate --schedule 已被新版 macOS 废弃（偏好已关，无影响）"
  fi
  killall cfprefsd 2>/dev/null || true   # 让所有进程立刻重读偏好

  head1 "[3/6] 禁用更新守护进程（临时，重启后会被系统还原）"
  : > "$MANIFEST"
  local svc name
  for svc in "${SYS_DAEMONS[@]}"; do
    name="${svc#system/}"
    if [ ! -f "/System/Library/LaunchDaemons/$name.plist" ]; then
      warn "$name 不存在，跳过"
      continue
    fi
    if launchctl disable "$svc" 2>/dev/null; then
      echo "$svc" >> "$MANIFEST"; ok "禁用 $svc"
    else
      bad "禁用 $svc 失败（可能被 SIP 保护）"
    fi
  done
  if [ -n "$REAL_UID_NUM" ]; then
    local f b t
    for f in /System/Library/LaunchAgents/*[Ss]oftware[Uu]pdate*.plist; do
      [ -e "$f" ] || continue
      b="$(basename "$f" .plist)"
      t="gui/$REAL_UID_NUM/$b"
      if as_user launchctl disable "$t" 2>/dev/null; then
        echo "$t" >> "$MANIFEST"; ok "禁用 $t"
      fi
    done
  fi

  # launchctl disable 只拦后续加载：已经在跑的实例会一直活到下次重启为止。
  # 这里不去强杀系统进程（Software Update.app 里这些服务另有用途），如实报告即可。
  local p
  sleep 1
  for p in "${DAEMON_PROCS[@]}"; do
    if pgrep -qx "$p"; then
      warn "$p 仍在运行（launchd 本次已禁用它，但重启后系统会重新启用）"
    else
      ok "$p 已停止"
    fi
  done

  head1 "[4/6] 屏蔽更新服务器 (/etc/hosts)"
  hosts_inject && ok "已写入 ${#BLOCK_HOSTS[@]} 条屏蔽规则"
  flush_dns

  head1 "[5/6] 清除更新红点角标"
  if as_user defaults delete com.apple.systempreferences AttentionPrefBundleIDs 2>/dev/null; then
    ok "已清除"
  else
    warn "无角标可清"
  fi
  as_user killall Dock 2>/dev/null || true

  head1 "[6/6] 回读磁盘核验偏好"
  killall cfprefsd 2>/dev/null || true
  sleep 1
  verify_domain "$SWU_PLIST" "${SWU_KEYS[@]}"
  verify_domain "$COMMERCE_PLIST" "${COMMERCE_KEYS[@]}"

  printf '\n\033[1m完成\033[0m — 当前版本 %s %s\n' "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"
  printf '  \033[33m·\033[0m launchd 禁用不持久：macOS 开机会强制重新启用这些系统守护进程。\n'
  printf '    真正拦住更新的是 /etc/hosts 屏蔽，那层重启后依然有效\n'
  case " $VERIFY_FAILED " in
    *" AutomaticCheckEnabled "*)
      printf '  \033[33m·\033[0m AutomaticCheckEnabled 是受管键，defaults 锁不住（仅 MDM 描述文件可写）；\n'
      printf '    但网络已切断 + 守护进程已禁用，实际拦截不受影响\n' ;;
  esac
  printf '  还原：\033[36msudo bash %s on\033[0m\n\n' "$0"
}

# ---------- on ----------
cmd_on() {
  need_root on
  printf '\n\033[1m还原 macOS 系统更新\033[0m\n'

  head1 "[1/5] 移除 /etc/hosts 屏蔽"
  if hosts_locked; then
    hosts_strip && ok "已移除屏蔽块"
  else
    warn "未发现屏蔽块"
  fi
  flush_dns

  head1 "[2/5] 还原更新偏好"
  if [ -f "$BACKUP_DIR/.backed-up" ]; then
    restore_domain "$SWU_PLIST" "$BACKUP_DIR/com.apple.SoftwareUpdate.orig.plist" "${SWU_KEYS[@]}"
    restore_domain "$COMMERCE_PLIST" "$BACKUP_DIR/com.apple.commerce.orig.plist" "${COMMERCE_KEYS[@]}"
  else
    warn "备份不存在，按默认还原（删除这些键 = 回到系统默认）"
    local k
    for k in "${SWU_KEYS[@]}"; do
      if defaults delete "$SWU_PLIST" "$k" 2>/dev/null; then
        ok "删除 $k"
      else
        warn "$k 本就不存在"
      fi
    done
    for k in "${COMMERCE_KEYS[@]}"; do
      defaults delete "$COMMERCE_PLIST" "$k" 2>/dev/null || true
    done
  fi
  softwareupdate --schedule on >/dev/null 2>&1 && ok "已恢复更新调度" || true
  killall cfprefsd 2>/dev/null || true

  head1 "[3/5] 重新启用守护进程"
  if [ -s "$MANIFEST" ]; then
    local t
    while read -r t; do
      [ -n "$t" ] || continue
      case "$t" in
        system/*)
          launchctl enable "$t" 2>/dev/null && ok "启用 $t"
          launchctl bootstrap system "/System/Library/LaunchDaemons/${t#system/}.plist" 2>/dev/null || true
          ;;
        gui/*) as_user launchctl enable "$t" 2>/dev/null && ok "启用 $t" ;;
      esac
    done < "$MANIFEST"
  else
    local svc name
    for svc in "${SYS_DAEMONS[@]}"; do
      name="${svc#system/}"
      [ -f "/System/Library/LaunchDaemons/$name.plist" ] || continue
      launchctl enable "$svc" 2>/dev/null && ok "启用 $svc"
      launchctl bootstrap system "/System/Library/LaunchDaemons/$name.plist" 2>/dev/null || true
    done
  fi
  launchctl kickstart -k system/com.apple.softwareupdated 2>/dev/null || true

  head1 "[4/5] 恢复 App Store 自动更新"
  as_user defaults delete com.apple.systempreferences AttentionPrefBundleIDs 2>/dev/null || true
  as_user killall Dock 2>/dev/null || true

  head1 "[5/5] 完成"
  printf '      验证：\033[36msoftwareupdate --list\033[0m 应能正常列出更新\n'
  printf '      备份保留在 %s（确认无误后可自行删除）\n\n' "$BACKUP_DIR"
}

# ---------- status ----------
cmd_status() {
  printf '\n\033[1mmacOS 更新锁定状态\033[0m\n\n'
  printf '  系统版本：%s (%s)\n\n' "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"

  printf '  \033[1m偏好设置\033[0m\n'
  local k
  for k in "${SWU_KEYS[@]}";     do show_key "$SWU_PLIST" "$k"; done
  for k in "${COMMERCE_KEYS[@]}"; do show_key "$COMMERCE_PLIST" "$k"; done

  printf '\n  \033[1m/etc/hosts 屏蔽\033[0m\n'
  if hosts_locked; then
    # 数文件里的实际条数，不是配置里的 —— 改过 BLOCK_HOSTS 但没重跑 off 时两者会不一致
    printf '    \033[32m已启用\033[0m（文件里实际 %s 条，当前配置 %s 条）\n' \
      "$(sed -n "/^${MARK_BEGIN}$/,/^${MARK_END}$/p" "$HOSTS_FILE" 2>/dev/null | grep -c '^0\.0\.0\.0')" \
      "${#BLOCK_HOSTS[@]}"
  else
    printf '    未启用\n'
  fi

  printf '\n  \033[1m守护进程\033[0m\n'
  local svc
  for svc in "${SYS_DAEMONS[@]}"; do
    if launchctl print-disabled system 2>/dev/null | grep -q "\"${svc#system/}\" => disabled"; then
      printf '    %-36s \033[32m已禁用\033[0m\n' "${svc#system/}"
    else
      printf '    %-36s 启用中\n' "${svc#system/}"
    fi
  done
  printf '    \033[33m（该层不持久 — macOS 开机会强制重新启用）\033[0m\n'

  if [ ! -r "$BACKUP_DIR" ]; then
    printf '\n  备份：\033[33m需 sudo 才能查看\033[0m %s\n' "$BACKUP_DIR"
  elif [ -f "$BACKUP_DIR/.backed-up" ]; then
    printf '\n  备份：\033[32m存在\033[0m %s\n' "$BACKUP_DIR"
  else
    printf '\n  备份：\033[33m不存在\033[0m\n'
  fi
  printf '\n'
}

# ---------- 分发 ----------
case "${1:-}" in
  # apply/restore are the names the other scripts in this repo use; off/on are
  # kept because they are already written into /etc/hosts comments and people's
  # shell history.
  off|apply)   cmd_off ;;
  on|restore)  cmd_on ;;
  status)      cmd_status ;;
  *)
    printf '\n用法：\n'
    printf '  sudo bash %s apply    关闭 macOS 系统更新（别名 off）\n' "$0"
    printf '  sudo bash %s restore  还原（别名 on）\n' "$0"
    printf '  bash %s status        查看状态\n\n' "$0"
    exit 1 ;;
esac
