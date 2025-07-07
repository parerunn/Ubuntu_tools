#!/bin/bash

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
INSTALL_SCRIPT="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"

function install_xray() {
    echo "[*] 开始安装或更新 Xray..."
    bash <(curl -Ls $INSTALL_SCRIPT)
}

function uninstall_xray() {
    echo "[*] 卸载 Xray..."
    bash <(curl -Ls $INSTALL_SCRIPT) remove
}

function view_config() {
    echo "[*] 当前配置："
    if [ -f "$XRAY_CONFIG" ]; then
        cat "$XRAY_CONFIG" | jq
    else
        echo "未找到配置文件：$XRAY_CONFIG"
    fi
}

function view_users() {
    echo "[*] 当前用户："
    if [ -f "$XRAY_CONFIG" ]; then
        jq '.inbounds[].settings.clients // empty' "$XRAY_CONFIG"
    else
        echo "未找到配置文件"
    fi
}

function add_user() {
    echo "[*] 添加新用户..."
    read -p "请输入用户备注（email）: " email
    uuid=$(cat /proc/sys/kernel/random/uuid)
    echo "生成的UUID: $uuid"

    # 备份配置
    cp "$XRAY_CONFIG" "$XRAY_CONFIG.bak"

    # 使用 jq 插入新用户
    jq --arg uuid "$uuid" --arg email "$email" '
      (.inbounds[] | select(.protocol == "vless" or .protocol == "vmess")).settings.clients +=
      [{"id": $uuid, "email": $email}]
    ' "$XRAY_CONFIG.bak" > "$XRAY_CONFIG"

    echo "[+] 用户已添加。请重启 Xray 服务使配置生效。"
    echo "systemctl restart xray"
}

function menu() {
    while true; do
        echo ""
        echo "===== Xray 管理脚本 ====="
        echo "1. 安装 / 更新 Xray"
        echo "2. 卸载 Xray"
        echo "3. 查看配置文件"
        echo "4. 查看当前用户"
        echo "5. 添加新用户"
        echo "0. 退出"
        echo "=========================="
        read -p "请输入选项: " choice

        case $choice in
            1) install_xray ;;
            2) uninstall_xray ;;
            3) view_config ;;
            4) view_users ;;
            5) add_user ;;
            0) exit 0 ;;
            *) echo "无效选项，请重新输入。" ;;
        esac
    done
}

# 检查依赖
if ! command -v jq &>/dev/null; then
    echo "[!] 未找到 jq，正在安装..."
    apt update && apt install -y jq || yum install -y jq
fi

menu
