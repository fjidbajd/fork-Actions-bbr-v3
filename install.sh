#!/bin/bash

export LC_ALL=C
export LANG=C

set -e

if ! command -v apt-get &> /dev/null; then
    echo -e "\033[31m错误：此脚本专为基于 Debian/Ubuntu 的系统（使用 apt-get）设计。\033[0m"
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    echo -e "\033[31m错误：此脚本必须以 root 权限运行。请使用 'sudo' 执行。\033[0m"
    exit 1
fi

ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" && "$ARCH" != "x86_64" ]]; then
    echo -e "\033[31m(￣□￣) 不支持的架构: $ARCH。此脚本仅支持 aarch64 和 x86_64。\033[0m"
    exit 1
fi

echo -e "\033[36m正在检查所需依赖...\033[0m"
REQUIRED_CMDS=("curl" "wget" "dpkg" "awk" "sed" "sysctl" "jq")

DEPS_TO_INSTALL=()
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "\033[33m依赖 '$cmd' 未找到，准备安装。\033[0m"
        DEPS_TO_INSTALL+=("$cmd")
    fi
done

if [ ${#DEPS_TO_INSTALL[@]} -gt 0 ]; then
    echo -e "\033[36m正在安装缺失的依赖: ${DEPS_TO_INSTALL[*]}\033[0m"
    apt-get update
    apt-get install -y "${DEPS_TO_INSTALL[@]}"
    echo -e "\033[32m依赖安装成功。\033[0m"
fi

CURRENT_ALGO=$(sysctl -n net.ipv4.tcp_congestion_control)
CURRENT_QDISC=$(sysctl -n net.core.default_qdisc)
SYSCTL_CONF="/etc/sysctl.d/99-joey-bbr.conf"

print_separator() {
    echo -e "\033[34m──────────────────────────────────────────────────────────\033[0m"
}

fetch_github_releases() {
    local GITHUB_API_URL="https://api.github.com/repos/byJoey/Actions-bbr-v3/releases"
    echo -e "\033[36m正在从 GitHub 获取版本信息...\033[0m"
    RELEASE_DATA=$(curl -s "$GITHUB_API_URL")
    if [[ -z "$RELEASE_DATA" || "$(echo "$RELEASE_DATA" | jq 'if type=="array" then "valid" else "invalid" end')" == '"invalid"' ]]; then
        echo -e "\033[31m错误：从 GitHub 获取或解析版本数据失败。请检查你的网络连接。\033[0m"
        return 1
    fi
    return 0
}

get_latest_tag() {
    local ARCH_FILTER=""
    [[ "$ARCH" == "aarch64" ]] && ARCH_FILTER="arm64"
    [[ "$ARCH" == "x86_64" ]] && ARCH_FILTER="x86_64"

    LATEST_TAG=$(echo "$RELEASE_DATA" | jq -r --arg filter "$ARCH_FILTER" 'map(select(.tag_name | contains($filter))) | sort_by(.published_at) | .[-1].tag_name')

    if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
        echo -e "\033[31m错误：找不到适合您系统架构 ($ARCH) 的版本。\033[0m"
        return 1
    fi
    echo "$LATEST_TAG"
    return 0
}

download_packages_by_tag() {
    local TAG_NAME=$1
    echo -e "\033[36m准备下载版本: \033[1;32m$TAG_NAME\033[0m"

    local ASSET_URLS
    ASSET_URLS=$(echo "$RELEASE_DATA" | jq -r --arg tag "$TAG_NAME" '.[] | select(.tag_name == $tag) | .assets[].browser_download_url')

    if [[ -z "$ASSET_URLS" ]]; then
        echo -e "\033[31m错误：找不到标签 $TAG_NAME 的下载链接。\033[0m"
        return 1
    fi

    echo -e "\033[36m正在清理 /tmp/ 目录下的旧内核包...\033[0m"
    rm -f /tmp/linux-*.deb

    for URL in $ASSET_URLS; do
        echo -e "\033[36m正在下载: $URL\033[0m"
        wget -q --show-progress -O "/tmp/$(basename "$URL")" "$URL" || {
            echo -e "\033[31m下载失败: $URL\033[0m"
            rm -f /tmp/linux-*.deb
            return 1
        }
    done
    echo -e "\033[32m下载完成。\033[0m"
    return 0
}

install_packages_func() {
    if ! ls /tmp/linux-*.deb &> /dev/null; then
        echo -e "\033[31m错误：在 /tmp/ 目录下未找到内核包。安装已中止。\033[0m"
        return 1
    fi

    echo -e "\033[36m正在卸载任何先前由本脚本安装的 'joeyblog' 内核...\033[0m"
    apt-get remove --purge -y $(dpkg -l | grep "joeyblog" | awk '{print $2}') > /dev/null 2>&1 || true

    echo -e "\033[36m正在安装新内核包...\033[0m"
    if ! dpkg -i /tmp/linux-*.deb; then
        echo -e "\033[1;31m致命错误：使用 dpkg 安装内核失败。系统可能处于不稳定状态。请不要重启并寻求手动修复！\033[0m"
        return 1
    fi

    echo -e "\033[32m内核包安装成功。\033[0m"

    if command -v update-grub &> /dev/null; then
        echo -e "\033[36m检测到 'update-grub' 命令，正在更新引导配置...\033[0m"
        if ! update-grub; then
            echo -e "\033[1;31m致命错误：'update-grub' 执行失败。系统可能无法启动到新内核。请不要重启并寻求手动修复！\033[0m"
            return 1
        fi
        echo -e "\033[32m引导配置更新成功。\033[0m"
    else
        echo -e "\033[33m未找到 'update-grub' 命令，跳过此步骤。您的系统可能使用其他引导程序（如 U-Boot/flash-kernel），通常会在内核安装时自动更新。\033[0m"
    fi

    rm -f /tmp/linux-*.deb

    echo -e "\033[1;32m内核安装与配置完成！\033[0m"
    echo -n -e "\033[33m需要重启系统以应用新内核。是否立即重启？ (y/n): \033[0m"
    read -r REBOOT_NOW
    if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
        echo -e "\033[36m系统即将重启...\033[0m"
        reboot
    else
        echo -e "\033[33m操作完成。请记得稍后手动重启（运行 'sudo reboot'）。\033[0m"
    fi
}

persist_sysctl_settings() {
    local ALGO=$1
    local QDISC=$2
    echo -n -e "\033[36m(｡♥‿♥｡) 要将这些配置永久保存吗？(y/n): \033[0m"
    read -r SAVE
    if [[ "$SAVE" =~ ^[Yy]$ ]]; then
        if [ -f "$SYSCTL_CONF" ]; then
            sed -i '/net.core.default_qdisc/d' "$SYSCTL_CONF"
            sed -i '/net.ipv4.tcp_congestion_control/d' "$SYSCTL_CONF"
        fi
        echo "net.core.default_qdisc=$QDISC" >> "$SYSCTL_CONF"
        echo "net.ipv4.tcp_congestion_control=$ALGO" >> "$SYSCTL_CONF"
        sysctl --system > /dev/null
        echo -e "\033[1;32m(☆^ー^☆) 设置已保存到 $SYSCTL_CONF 并已生效。\033[0m"
    else
        sysctl -w net.core.default_qdisc="$QDISC" > /dev/null
        sysctl -w net.ipv4.tcp_congestion_control="$ALGO" > /dev/null
        echo -e "\033[33m(⌒_⌒;) 设置仅在当前会话生效，重启后将失效。\033[0m"
    fi
}

main() {
    print_separator
    echo -e "\033[1;35m(☆ω☆)✧*｡ 欢迎使用 Joey 的 BBR v3 管理脚本 ✧*｡(☆ω☆)\033[0m"
    print_separator
    echo -e "\033[36m系统架构: \033[1;32m$ARCH\033[0m"
    echo -e "\033[36m当前拥塞控制算法: \033[1;32m$CURRENT_ALGO\033[0m"
    echo -e "\033[36m当前队列调度算法: \033[1;32m$CURRENT_QDISC\033[0m"
    echo -e "\033[36m正在运行的内核: \033[1;32m$(uname -r)\033[0m"
    print_separator
    echo -e "\033[1;33m作者: Joey  |  博客: https://joeyblog.net  |  Telegram: https://t.me/+ft-zI76oovgwNmRh\033[0m"
    print_separator
    echo -e "\033[1;33m╭( ･ㅂ･)و ✧ 请选择一个操作:\033[0m"
    echo -e "\033[33m 1. 🚀 安装或更新 BBRv3 内核 (最新版)\033[0m"
    echo -e "\033[33m 2. 📚 安装指定版本的 BBRv3 内核\033[0m"
    echo -e "\033[33m 3. 🔍 检查 BBRv3 状态\033[0m"
    echo -e "\033[33m 4. ⚡ 启用 BBR + FQ\033[0m"
    echo -e "\033[33m 5. ⚡ 启用 BBR + FQ_PIE\033[0m"
    echo -e "\033[33m 6. ⚡ 启用 BBR + CAKE\033[0m"
    echo -e "\033[33m 7. 🗑️  卸载 BBRv3 内核\033[0m"
    print_separator
    echo -n -e "\033[36m请输入你的选择 (1-7): \033[0m"
    read -r ACTION

    case "$ACTION" in
        1)
            echo -e "\033[1;32m٩(｡•́‿•̀｡)۶ 已选择：安装或更新 BBRv3 内核 (最新版)\033[0m"
            if ! fetch_github_releases; then exit 1; fi

            LATEST_TAG=$(get_latest_tag)
            if [[ -z "$LATEST_TAG" ]]; then
                echo -e "\033[31m无法确定最新版本。操作中止。\033[0m"
                exit 1
            fi
            
            LATEST_VERSION_BASE=$(echo "$LATEST_TAG" | sed -E 's/_(x86_64|arm64)//')
            CURRENT_KERNEL_VERSION=$(uname -r)

            if [[ "$CURRENT_KERNEL_VERSION" == *"$LATEST_VERSION_BASE"* ]]; then
                echo -e "\033[1;32m(o´▽`o) 你当前运行的已经是最新版本 ($CURRENT_KERNEL_VERSION)。无需更新。\033[0m"
            else
                echo -e "\033[33m发现新版本 ($LATEST_VERSION_BASE)。当前版本: $CURRENT_KERNEL_VERSION。\033[0m"
                if download_packages_by_tag "$LATEST_TAG"; then
                    install_packages_func
                else
                    echo -e "\033[31m因下载失败，安装已中止。\033[0m"
                fi
            fi
            ;;
        2)
            echo -e "\033[1;32m(｡･∀･)ﾉﾞ 已选择：安装指定版本的 BBRv3 内核\033[0m"
            if ! fetch_github_releases; then exit 1; fi

            local ARCH_FILTER=""
            [[ "$ARCH" == "aarch64" ]] && ARCH_FILTER="arm64"
            [[ "$ARCH" == "x86_64" ]] && ARCH_FILTER="x86_64"

            MATCH_TAGS=$(echo "$RELEASE_DATA" | jq -r --arg filter "$ARCH_FILTER" '.[] | select(.tag_name | contains($filter)) | .tag_name')
            if [[ -z "$MATCH_TAGS" ]]; then
                echo -e "\033[31m未找到适合当前架构的版本。\033[0m"
                exit 1
            fi

            echo -e "\033[36m以下是适用于当前架构的版本：\033[0m"
            mapfile -t TAG_ARRAY <<< "$MATCH_TAGS"

            for i in "${!TAG_ARRAY[@]}"; do
                echo -e "\033[33m $((i+1)). ${TAG_ARRAY[$i]}\033[0m"
            done

            echo -n -e "\033[36m请输入要安装的版本编号 (例如 1): \033[0m"
            read -r CHOICE
            
            if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#TAG_ARRAY[@]} )); then
                echo -e "\033[31m输入无效编号，取消操作。\033[0m"
                exit 1
            fi
            
            SELECTED_TAG="${TAG_ARRAY[$((CHOICE-1))]}"
            echo -e "\033[36m已选择版本：\033[0m\033[1;32m$SELECTED_TAG\033[0m"
            
            if download_packages_by_tag "$SELECTED_TAG"; then
                install_packages_func
            else
                echo -e "\033[31m因下载失败，安装已中止。\033[0m"
            fi
            ;;
        3)
            echo -e "\033[1;32m(｡･ω･｡) 正在检查 BBR v3 状态...\033[0m"
            BBR_MODULE_INFO=$(modinfo tcp_bbr 2>/dev/null || echo "not_found")
            if [[ "$BBR_MODULE_INFO" == "not_found" ]]; then
                echo -e "\033[31m(⊙﹏⊙) 未加载 tcp_bbr 模块。请先安装内核并重启。\033[0m"
                exit 1
            fi

            BBR_VERSION=$(echo "$BBR_MODULE_INFO" | awk '/^version:/ {print $2}')
            if [[ "$BBR_VERSION" == "3" ]]; then
                echo -e "\033[36m✔ BBR 模块版本：\033[0m\033[1;32m$BBR_VERSION (v3)\033[0m"
            else
                echo -e "\033[33m(￣﹃￣) 检测到 BBR 模块，但版本是：$BBR_VERSION，不是 v3！\033[0m"
            fi
            
            if [[ "$CURRENT_ALGO" == "bbr" ]]; then
                echo -e "\033[36m✔ TCP 拥塞控制算法：\033[0m\033[1;32m$CURRENT_ALGO\033[0m"
            else
                echo -e "\033[31m(⊙﹏⊙) 当前算法不是 bbr，而是：$CURRENT_ALGO\033[0m"
            fi

            if [[ "$BBR_VERSION" == "3" && "$CURRENT_ALGO" == "bbr" ]]; then
                echo -e "\033[1;32mヽ(✿ﾟ▽ﾟ)ノ 检测完成，BBR v3 已正确安装并生效！\033[0m"
            else
                echo -e "\033[33mBBR v3 未完全生效。请确保已安装内核、已重启，并已使用选项 4/5/6 启用。\033[0m"
            fi
            ;;
        4)
            echo -e "\033[1;32m(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧ 启用 BBR + FQ 加速！\033[0m"
            persist_sysctl_settings "bbr" "fq"
            ;;
        5)
            echo -e "\033[1;32m٩(•‿•)۶ 启用 BBR + FQ_PIE 加速！\033[0m"
            persist_sysctl_settings "bbr" "fq_pie"
            ;;
        6)
            echo -e "\033[1;32m(ﾉ≧∀≦)ﾉ 启用 BBR + CAKE 加速！\033[0m"
            persist_sysctl_settings "bbr" "cake"
            ;;
        7)
            echo -e "\033[1;32mヽ(・∀・)ノ 已选择：卸载 BBRv3 内核！\033[0m"
            PACKAGES_TO_REMOVE=$(dpkg -l | grep "joeyblog" | awk '{print $2}' | tr '\n' ' ')
            if [[ -n "$PACKAGES_TO_REMOVE" ]]; then
                echo -e "\033[36m将要卸载以下内核包: \033[33m$PACKAGES_TO_REMOVE\033[0m"
                apt-get remove --purge -y $PACKAGES_TO_REMOVE
                if command -v update-grub &> /dev/null; then
                    echo -e "\033[36m检测到 'update-grub' 命令，正在更新引导配置...\033[0m"
                    update-grub
                else
                    echo -e "\033[33m未找到 'update-grub' 命令，跳过引导更新。\033[0m"
                fi
                echo -e "\033[1;32m内核包已卸载。建议重启以应用更改。\033[0m"
            else
                echo -e "\033[33m未找到由本脚本安装的 'joeyblog' 内核包。\033[0m"
            fi
            ;;
        *)
            echo -e "\033[31m(￣▽￣)ゞ 无效的选项，请输入 1-7 之间的数字哦~\033[0m"
            ;;
    esac
}

main
