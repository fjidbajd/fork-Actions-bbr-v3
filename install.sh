#!/bin/bash


# 限制脚本仅支持基于 Debian/Ubuntu 的系统（即支持 apt-get 的系统）
if ! command -v apt-get &> /dev/null; then
    echo -e "\033[31m此脚本仅支持基于 Debian/Ubuntu 的系统，请在支持 apt-get 的系统上运行！\033[0m"
    exit 1
fi

# 检查并安装必要的依赖，包括 jq 用于解析 JSON
REQUIRED_CMDS=("curl" "wget" "dpkg" "awk" "sed" "sysctl" "update-grub" "jq")
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "\033[33m缺少依赖：$cmd，正在安装...\033[0m"
        sudo apt-get update && sudo apt-get install -y $cmd > /dev/null 2>&1
    fi
done

# 检测系统架构
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" && "$ARCH" != "x86_64" ]]; then
    echo -e "\033[31m(￣□￣)哇！这个脚本只支持 ARM 和 x86_64 架构哦~ 您的系统架构是：$ARCH\033[0m"
    exit 1
fi

# 获取当前 BBR 状态
CURRENT_ALGO=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
CURRENT_QDISC=$(sysctl net.core.default_qdisc | awk '{print $3}')

# sysctl 配置文件路径
SYSCTL_CONF="/etc/sysctl.d/99-joeyblog.conf"

# 函数：清理 sysctl.d 中的旧配置
clean_sysctl_conf() {
    if [[ ! -f "$SYSCTL_CONF" ]]; then
        sudo touch "$SYSCTL_CONF"
    fi
    sudo sed -i '/net.core.default_qdisc/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_congestion_control/d' "$SYSCTL_CONF"
}

# 函数：询问是否永久保存更改
ask_to_save() {
    echo -n -e "\033[36m(｡♥‿♥｡) 要将这些配置永久保存到 $SYSCTL_CONF 吗？(y/n): \033[0m"
    read -r SAVE
    if [[ "$SAVE" == "y" || "$SAVE" == "Y" ]]; then
        clean_sysctl_conf
        echo "net.core.default_qdisc=$QDISC" | sudo tee -a "$SYSCTL_CONF" > /dev/null
        echo "net.ipv4.tcp_congestion_control=$ALGO" | sudo tee -a "$SYSCTL_CONF" > /dev/null
        sudo sysctl --system > /dev/null
        echo -e "\033[1;32m(☆^ー^☆) 更改已永久保存啦~\033[0m"
    else
        echo -e "\033[33m(⌒_⌒;) 好吧，没有永久保存呢~\033[0m"
    fi
}

# 函数：从 GitHub 获取最新版本并下载
get_download_links() {
    echo -e "\033[36m正在从 GitHub 获取最新版本信息...\033[0m"
    BASE_URL="https://api.github.com/repos/byJoey/Actions-bbr-v3/releases"
    RELEASE_DATA=$(curl -s "$BASE_URL")

    local ARCH_FILTER=""
    if [[ "$ARCH" == "aarch64" ]]; then
        ARCH_FILTER="arm64"
    elif [[ "$ARCH" == "x86_64" ]]; then
        ARCH_FILTER="x86_64"
    fi

    TAG_NAME=$(echo "$RELEASE_DATA" | jq -r --arg filter "$ARCH_FILTER" 'map(select(.tag_name | contains($filter))) | sort_by(.published_at) | .[-1].tag_name')

    if [[ -z "$TAG_NAME" || "$TAG_NAME" == "null" ]]; then
        echo -e "\033[31m未找到适合当前架构的版本。\033[0m"
        return 1
    fi

    echo -e "\033[36m找到的最新版本：$TAG_NAME\033[0m"
    ASSET_URLS=$(echo "$RELEASE_DATA" | jq -r --arg tag "$TAG_NAME" '.[] | select(.tag_name == $tag) | .assets[].browser_download_url')

    # 清理旧文件
    rm -f /tmp/linux-*.deb

    for URL in $ASSET_URLS; do
        FILE=$(basename "$URL")
        echo -e "\033[36m正在下载文件：$URL\033[0m"
        wget -q --show-progress "$URL" -P /tmp/ || { echo -e "\033[31m下载失败：$URL\033[0m"; return 1; }
    done
    return 0
}

# 函数：安全地安装下载的包
install_packages() {
    # 安全性检查：确认内核文件已存在
    if ! ls /tmp/linux-*.deb &> /dev/null; then
        echo -e "\033[31m错误：未在 /tmp 目录下找到内核文件，安装中止。\033[0m"
        return 1
    fi
    
    echo -e "\033[36m开始卸载旧版内核... \033[0m"
    sudo apt remove --purge $(dpkg -l | grep "joeyblog" | awk '{print $2}') -y > /dev/null 2>&1

    echo -e "\033[36m开始安装新内核... \033[0m"
    # 将关键命令链接，如果安装失败则中止后续操作
    if sudo dpkg -i /tmp/linux-*.deb && sudo update-grub; then
        echo -e "\033[1;32m内核安装并配置完成！\033[0m"
        # 增加重启询问步骤
        echo -n -e "\033[33m需要重启系统来加载新内核。是否立即重启？ (y/n): \033[0m"
        read -r REBOOT_NOW
        if [[ "$REBOOT_NOW" == "y" || "$REBOOT_NOW" == "Y" ]]; then
            echo -e "\033[36m系统即将重启...\033[0m"
            reboot
        else
            echo -e "\033[33m操作完成。请记得稍后手动重启 ('sudo reboot') 来应用新内核。\033[0m"
        fi
    else
        echo -e "\033[1;31m内核安装或 GRUB 更新失败！系统可能处于不稳定状态。请不要重启并寻求手动修复！\033[0m"
    fi
}

# 函数：安装指定版本
get_specific_version() {
    BASE_URL="https://api.github.com/repos/byJoey/Actions-bbr-v3/releases"
    RELEASE_DATA=$(curl -s "$BASE_URL")

    local ARCH_FILTER=""
    if [[ "$ARCH" == "aarch64" ]]; then
        ARCH_FILTER="arm64"
    else
        ARCH_FILTER="x86_64"
    fi

    MATCH_TAGS=$(echo "$RELEASE_DATA" | jq -r --arg filter "$ARCH_FILTER" '.[] | select(.tag_name | contains($filter)) | .tag_name')

    if [[ -z "$MATCH_TAGS" ]]; then
        echo -e "\033[31m未找到适合当前架构的版本。\033[0m"
        return 1
    fi

    echo -e "\033[36m以下为适用于当前架构的版本：\033[0m"
    IFS=$'\n' read -rd '' -a TAG_ARRAY <<<"$MATCH_TAGS"

    for i in "${!TAG_ARRAY[@]}"; do
        echo -e "\033[33m $((i+1)). ${TAG_ARRAY[$i]}\033[0m"
    done

    echo -n -e "\033[36m请输入要安装的版本编号（例如 1）：\033[0m"
    read -r CHOICE
    
    # 验证输入是否为数字
    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#TAG_ARRAY[@]} )); then
        echo -e "\033[31m输入无效编号，取消操作。\033[0m"
        return 1
    fi
    
    INDEX=$((CHOICE-1))
    SELECTED_TAG="${TAG_ARRAY[$INDEX]}"
    echo -e "\033[36m已选择版本：\033[0m\033[1;32m$SELECTED_TAG\033[0m"

    ASSET_URLS=$(echo "$RELEASE_DATA" | jq -r --arg tag "$SELECTED_TAG" '.[] | select(.tag_name == $tag) | .assets[].browser_download_url')
    
    # 清理旧文件
    rm -f /tmp/linux-*.deb
    
    for URL in $ASSET_URLS; do
        FILE=$(basename "$URL")
        echo -e "\033[36m下载中：$URL\033[0m"
        wget -q --show-progress "$URL" -P /tmp/ || { echo -e "\033[31m下载失败：$URL\033[0m"; return 1; }
    done
    return 0
}

# 美化输出的分隔线
print_separator() {
    echo -e "\033[34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
}

# --- 主要执行流程 ---

# 欢迎信息与作者信息展示
print_separator
echo -e "\033[1;35m(☆ω☆)✧*｡ 欢迎来到 BBR 管理脚本世界哒！ ✧*｡(☆ω☆)\033[0m"
print_separator
echo -e "\033[36m当前 TCP 拥塞控制算法：\033[0m\033[1;32m$CURRENT_ALGO\033[0m"
echo -e "\033[36m当前队列管理算法：    \033[0m\033[1;32m$CURRENT_QDISC\033[0m"
print_separator
echo -e "\033[1;33m作者：Joey  |  博客：https://joeyblog.net  |  反馈群组：https://t.me/+ft-zI76oovgwNmRh\033[0m"
print_separator

# 提示用户选择操作
echo -e "\033[1;33m╭( ･ㅂ･)و ✧ 你可以选择以下操作哦：\033[0m"
echo -e "\033[33m 1. 🚀 安装或更新 BBR v3 (最新版)\033[0m"
echo -e "\033[33m 2. 📚 指定版本安装\033[0m"
echo -e "\033[33m 3. 🔍 检查 BBR v3 状态\033[0m"
echo -e "\033[33m 4. ⚡ 启用 BBR + FQ\033[0m"
echo -e "\033[33m 5. ⚡ 启用 BBR + FQ_PIE\033[0m"
echo -e "\033[33m 6. ⚡ 启用 BBR + CAKE\033[0m"
echo -e "\033[33m 7. 🗑️  卸载 BBR 内核\033[0m"
print_separator
echo -n -e "\033[36m请选择一个操作 (1-7) (｡･ω･｡): \033[0m"
read -r ACTION

case "$ACTION" in
    1)
        echo -e "\033[1;32m٩(｡•́‿•̀｡)۶ 您选择了安装或更新 BBR v3！\033[0m"
        # 安全性改进：先执行下载，如果下载函数成功（返回0），再执行安装。
        if get_download_links; then
            install_packages
        else
            echo -e "\033[31m由于下载失败，安装过程已中止。未对您的系统做任何更改。\033[0m"
        fi
        ;;
    2)
        echo -e "\033[1;32m(｡･∀･)ﾉﾞ 您选择了安装指定版本的 BBR！\033[0m"
        # 安全性改进：先执行下载，如果下载函数成功（返回0），再执行安装。
        if get_specific_version; then
            install_packages
        else
            echo -e "\033[31m由于下载失败或选择无效，安装过程已中止。未对您的系统做任何更改。\033[0m"
        fi
        ;;
    3)
        echo -e "\033[1;32m(｡･ω･｡) 检查是否为 BBR v3...\033[0m"
        BBR_MODULE_INFO=$(modinfo tcp_bbr 2>/dev/null)
        if [[ -z "$BBR_MODULE_INFO" ]]; then
             echo -e "\033[31m(⊙﹏⊙) 未加载 tcp_bbr 模块，无法检查版本。请先安装内核并重启。\033[0m"
             exit 1
        fi
        BBR_VERSION=$(echo "$BBR_MODULE_INFO" | awk '/^version:/ {print $2}')
        if [[ "$BBR_VERSION" == "3" ]]; then
            echo -e "\033[36m✔ BBR 模块版本：\033[0m\033[1;32m$BBR_VERSION (v3)\033[0m"
        else
            echo -e "\033[33m(￣﹃￣) 检测到 BBR 模块，但版本是：$BBR_VERSION，不是 v3！\033[0m"
        fi
        
        CURRENT_ALGO=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
        if [[ "$CURRENT_ALGO" == "bbr" ]]; then
            echo -e "\033[36m✔ TCP 拥塞控制算法：\033[0m\033[1;32m$CURRENT_ALGO\033[0m"
        else
            echo -e "\033[31m(⊙﹏⊙) 当前算法不是 bbr，而是：$CURRENT_ALGO\033[0m"
        fi

        if [[ "$BBR_VERSION" == "3" && "$CURRENT_ALGO" == "bbr" ]]; then
             echo -e "\033[1;32mヽ(✿ﾟ▽ﾟ)ノ 检测完成，BBR v3 已正确安装并生效！\033[0m"
        else
             echo -e "\033[33mBBR v3 未完全生效。请确保已安装内核并重启，然后使用选项 4/5/6 启用。\033[0m"
        fi
        ;;
    4)
        echo -e "\033[1;32m(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧ 使用 BBR + FQ 加速！\033[0m"
        ALGO="bbr"
        QDISC="fq"
        ask_to_save
        ;;
    5)
        echo -e "\033[1;32m٩(•‿•)۶ 使用 BBR + FQ_PIE 加速！\033[0m"
        ALGO="bbr"
        QDISC="fq_pie"
        ask_to_save
        ;;
    6)
        echo -e "\033[1;32m(ﾉ≧∀≦)ﾉ 使用 BBR + CAKE 加速！\033[0m"
        ALGO="bbr"
        QDISC="cake"
        ask_to_save
        ;;
    7)
        echo -e "\033[1;32mヽ(・∀・)ノ 您选择了卸载 BBR 内核！\033[0m"
        # 查找所有相关的包并卸载
        PACKAGES_TO_REMOVE=$(dpkg -l | grep "joeyblog" | awk '{print $2}' | tr '\n' ' ')
        if [[ -n "$PACKAGES_TO_REMOVE" ]]; then
             echo -e "\033[36m将要卸载以下内核包: \033[33m$PACKAGES_TO_REMOVE\033[0m"
             sudo apt remove --purge $PACKAGES_TO_REMOVE -y
             sudo update-grub
             echo -e "\033[1;32m内核包已卸载。\033[0m"
        else
             echo -e "\033[33m未找到由本脚本安装的 'joeyblog' 内核包。\033[0m"
        fi
        ;;
    *)
        echo -e "\033[31m(￣▽￣)ゞ 无效的选项，请输入 1-7 之间的数字哦~\033[0m"
        ;;
esac
