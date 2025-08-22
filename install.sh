#!/bin/bash

# ==============================================================================
# Debian & Ubuntu LTS VPS 通用初始化脚本
# 版本: 4.1-pro
# 描述: 集成参数化配置、动态BBR优化、Fail2ban防护、智能Swap和日志记录。
# ==============================================================================
set -e

# --- 默认配置 ---
TIMEZONE="Asia/Hong_Kong"
SWAP_SIZE_MB="1024"
INSTALL_PACKAGES="sudo wget zip vim"
PRIMARY_DNS_V4="1.1.1.1"
SECONDARY_DNS_V4="8.8.8.8"
PRIMARY_DNS_V6="2606:4700:4700::1111"
SECONDARY_DNS_V6="2001:4860:4860::8888"
NEW_HOSTNAME=""
BBR_MODE="default" # 可选值: default, optimized, none
ENABLE_FAIL2BAN=false
FAIL2BAN_EXTRA_PORT=""

# --- 颜色定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 全局变量 ---
non_interactive=false

# ==============================================================================
# --- 命令行参数解析 ---
# ==============================================================================
usage() {
    echo -e "${YELLOW}用法: $0 [选项]...${NC}"
    echo "  全功能初始化脚本，用于 Debian 和 Ubuntu LTS 系统。"
    echo
    echo -e "${BLUE}核心选项:${NC}"
    echo "  --hostname <name>         设置新的主机名 (例如: 'my-server')"
    echo "  --timezone <tz>           设置时区 (例如: 'Asia/Shanghai', 'UTC')"
    echo "  --swap <size_mb>          设置 Swap 大小 (MB)，'auto' 或 '0' (禁用)"
    echo "  --ip-dns <'p s'>          设置 IPv4 DNS (主/备，用引号和空格隔开)"
    echo "  --ip6-dns <'p s'>         设置 IPv6 DNS (主/备，用引号和空格隔开)"
    echo
    echo -e "${BLUE}BBR 模式选项 (三选一):${NC}"
    echo "  (默认)                    启用标准 BBR + FQ"
    echo "  --bbr-optimized           启用动态优化的 BBR (推荐)"
    echo "  --no-bbr                  禁用 BBR 配置"
    echo
    echo -e "${BLUE}安全选项:${NC}"
    echo "  --fail2ban [port]         安装并配置 Fail2ban。可选提供一个额外要保护的SSH端口。"
    echo
    echo -e "${BLUE}其他选项:${NC}"
    echo "  -h, --help                显示此帮助信息"
    echo "  --non-interactive         以非交互模式运行，自动应答并重启"
    echo
    echo -e "${GREEN}示例:${NC}"
    echo "  # 全功能优化，设置主机名，自动swap，并用fail2ban保护22和2222端口"
    echo "  $0 --hostname \"web01\" --swap \"auto\" --bbr-optimized --fail2ban 2222"
    exit 0
}

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -h|--help) usage ;;
        --hostname) NEW_HOSTNAME="$2"; shift 2 ;;
        --timezone) TIMEZONE="$2"; shift 2 ;;
        --swap) SWAP_SIZE_MB="$2"; shift 2 ;;
        --ip-dns) read -r PRIMARY_DNS_V4 SECONDARY_DNS_V4 <<< "$2"; shift 2 ;;
        --ip6-dns) read -r PRIMARY_DNS_V6 SECONDARY_DNS_V6 <<< "$2"; shift 2 ;;
        --bbr-optimized) BBR_MODE="optimized"; shift ;;
        --no-bbr) BBR_MODE="none"; shift ;;
        --fail2ban)
            ENABLE_FAIL2BAN=true
            if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                FAIL2BAN_EXTRA_PORT="$2"
                shift 2
            else
                shift
            fi
            ;;
        --non-interactive) non_interactive=true; shift ;;
        *) echo -e "${RED}错误: 未知选项 '$1'${NC}"; usage ;;
    esac
done

# --- 辅助函数 (错误处理、IPv6检测等) ---
handle_error() {
    local exit_code=$?
    local line_number=$1
    echo -e "\n${RED}[ERROR] 脚本在第 $line_number 行执行失败 (退出码: $exit_code)${NC}"
    echo -e "${RED}[ERROR] 完整日志请查看: ${LOG_FILE:-"未生成日志文件"}${NC}"
    exit $exit_code
}
has_ipv6() { ip -6 route show default 2>/dev/null | grep -q 'default' || ip -6 addr show 2>/dev/null | grep -q 'inet6.*scope global'; }
check_disk_space() {
    local required_mb=$1
    local available_mb=$(df /tmp | awk 'NR==2 {print int($4/1024)}')
    if [ "$available_mb" -lt "$required_mb" ]; then
        echo -e "${RED}[ERROR] 磁盘空间不足，需要 ${required_mb}MB，可用 ${available_mb}MB${NC}"; return 1;
    fi
}

# --- 功能函数区 ---

# 1. 系统预检
pre_flight_checks() {
    echo -e "${BLUE}[INFO] 正在执行系统预检查...${NC}"
    local supported=false
    if [ "$ID" = "debian" ] && [[ "$VERSION_ID" =~ ^(10|11|12|13)$ ]]; then supported=true;
    elif [ "$ID" = "ubuntu" ] && [[ "$VERSION_ID" =~ ^(20\.04|22\.04|24\.04)$ ]]; then supported=true; fi
    if [ "$supported" = "false" ]; then
        echo -e "${YELLOW}[WARN] 此脚本为 Debian 10-13 或 Ubuntu 20.04-24.04 LTS 设计，当前系统为 $PRETTY_NAME。${NC}"
        if [ "$non_interactive" = "true" ]; then echo -e "${YELLOW}[WARN] 在非交互模式下将强制继续。${NC}";
        else read -p "是否强制继续? [y/N] " -r < /dev/tty; [[ ! $REPLY =~ ^[Yy]$ ]] && echo "操作已取消。" && exit 0; fi
    fi
    echo -e "${GREEN}[SUCCESS]${NC} ✅ 预检查完成。系统: $PRETTY_NAME"
}

# 2. 配置主机名
configure_hostname() {
    echo -e "\n${YELLOW}=============== 1. 配置主机名 ===============${NC}"
    local CURRENT_HOSTNAME=$(hostname)
    echo "当前主机名: $CURRENT_HOSTNAME"
    local FINAL_HOSTNAME="$CURRENT_HOSTNAME"
    if [ -n "$NEW_HOSTNAME" ]; then
        if [[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$|^[a-zA-Z0-9]$ ]]; then
            echo -e "${BLUE}[INFO] 通过参数设置新主机名为: $NEW_HOSTNAME${NC}"
            hostnamectl set-hostname "$NEW_HOSTNAME"
            FINAL_HOSTNAME="$NEW_HOSTNAME"
        else echo -e "${RED}[ERROR] 主机名 '$NEW_HOSTNAME' 格式不正确，保持不变。${NC}"; fi
    elif [ "$non_interactive" = "false" ]; then
        read -p "是否需要修改主机名？ [y/N] 默认 N: " -r < /dev/tty
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            read -p "请输入新的主机名: " INTERACTIVE_HOSTNAME < /dev/tty
            if [ -n "$INTERACTIVE_HOSTNAME" ] && [[ "$INTERACTIVE_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$|^[a-zA-Z0-9]$ ]]; then
                hostnamectl set-hostname "$INTERACTIVE_HOSTNAME"
                FINAL_HOSTNAME="$INTERACTIVE_HOSTNAME"
            else echo -e "${YELLOW}[WARN] 主机名格式不正确或为空，保持不变。${NC}"; fi
        fi
    fi
    if ! grep -q "127.0.1.1\s\+$FINAL_HOSTNAME" /etc/hosts; then
        if grep -q "127.0.1.1" /etc/hosts; then sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$FINAL_HOSTNAME/g" /etc/hosts;
        else echo -e "127.0.1.1\t$FINAL_HOSTNAME" >> /etc/hosts; fi
    fi
    echo -e "${GREEN}[SUCCESS]${NC} ✅ 主机名已更新为: $(hostname)"
}

# 3. 配置时区
configure_timezone() {
    echo -e "\n${YELLOW}=============== 2. 配置时区 ===============${NC}"
    timedatectl set-timezone "$TIMEZONE" 2>/dev/null && echo -e "${GREEN}[SUCCESS]${NC} ✅ 时区已设置为 $TIMEZONE"
}

# 4. 配置 BBR (标准模式)
configure_default_bbr() {
    echo -e "\n${YELLOW}=============== 3. 配置 BBR (标准模式) ===============${NC}"
    cat > /etc/sysctl.d/99-bbr.conf << 'EOF'
# Generated by VPS Init Script (Default BBR)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1
    echo -e "${GREEN}[SUCCESS]${NC} ✅ 标准 BBR 已启用"
}

# 4. 配置 BBR (动态优化模式)
configure_optimized_bbr() {
    echo -e "\n${YELLOW}=============== 3. 配置 BBR (动态优化模式) ===============${NC}"
    # 检查内核
    KERNEL_VERSION=$(uname -r); KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1); KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)
    if (( KERNEL_MAJOR < 4 )) || (( KERNEL_MAJOR == 4 && KERNEL_MINOR < 9 )); then
        echo -e "${RED}❌ 错误: 内核版本 $KERNEL_VERSION 不支持BBR (需要 4.9+), 跳过优化。${NC}"; return 1;
    fi
    if [[ ! $(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null) =~ "bbr" ]]; then
        echo -e "${YELLOW}⚠️  警告: BBR模块未加载，尝试加载...${NC}"
        modprobe tcp_bbr 2>/dev/null || echo -e "${RED}❌ 无法加载BBR模块${NC}"
    fi

    # 获取系统信息
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    CPU_CORES=$(nproc)
    echo -e "${BLUE}[INFO] 系统信息: ${TOTAL_MEM}MB 内存, ${CPU_CORES} 核 CPU${NC}"

    # 动态计算参数
    local RMEM_MAX WMEM_MAX TCP_RMEM TCP_WMEM SOMAXCONN NETDEV_BACKLOG FILE_MAX CONNTRACK_MAX VM_TIER
    if [ $TOTAL_MEM -le 512 ]; then
        RMEM_MAX="8388608"; WMEM_MAX="8388608"; TCP_RMEM="4096 65536 8388608"; TCP_WMEM="4096 65536 8388608"
        SOMAXCONN="32768"; NETDEV_BACKLOG="16384"; FILE_MAX="262144"; CONNTRACK_MAX="131072"; VM_TIER="经典级(≤512MB)"
    elif [ $TOTAL_MEM -le 1024 ]; then
        RMEM_MAX="16777216"; WMEM_MAX="16777216"; TCP_RMEM="4096 65536 16777216"; TCP_WMEM="4096 65536 16777216"
        SOMAXCONN="49152"; NETDEV_BACKLOG="24576"; FILE_MAX="524288"; CONNTRACK_MAX="262144"; VM_TIER="轻量级(512MB-1GB)"
    elif [ $TOTAL_MEM -le 2048 ]; then
        RMEM_MAX="33554432"; WMEM_MAX="33554432"; TCP_RMEM="4096 87380 33554432"; TCP_WMEM="4096 65536 33554432"
        SOMAXCONN="65535"; NETDEV_BACKLOG="32768"; FILE_MAX="1048576"; CONNTRACK_MAX="524288"; VM_TIER="标准级(1GB-2GB)"
    else # 涵盖所有 >2GB 的情况
        RMEM_MAX="67108864"; WMEM_MAX="67108864"; TCP_RMEM="4096 131072 67108864"; TCP_WMEM="4096 87380 67108864"
        SOMAXCONN="65535"; NETDEV_BACKLOG="65535"; FILE_MAX="2097152"; CONNTRACK_MAX="1048576"; VM_TIER="高性能级(>2GB)"
    fi
    echo -e "${BLUE}[INFO] 已匹配优化配置: ${VM_TIER}${NC}"

    local CONF_FILE="/etc/sysctl.d/99-bbr.conf"
    
    # 备份管理
    if [ -f "$CONF_FILE" ]; then
        cp "$CONF_FILE" "$CONF_FILE.bak_$(date +%F_%H-%M-%S)"
        echo -e "${BLUE}[INFO] 已备份现有 BBR 配置。${NC}"
    fi

    # 写入配置
    cat > "$CONF_FILE" << EOF
# Auto-generated by VPS Init Script on $(date)
# Optimized for ${TOTAL_MEM}MB RAM (${VM_TIER})

# --- BBR Core ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Buffers ---
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX
net.ipv4.tcp_rmem = $TCP_RMEM
net.ipv4.tcp_wmem = $TCP_WMEM

# --- Backlogs ---
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $NETDEV_BACKLOG
net.ipv4.tcp_max_syn_backlog = $SOMAXCONN

# --- Timeouts & Buckets ---
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 180000

# --- File Descriptors ---
fs.file-max = $FILE_MAX
fs.nr_open = $FILE_MAX

# --- Misc ---
net.ipv4.tcp_slow_start_after_idle = 0
vm.swappiness = 10
EOF
    if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
        echo "net.netfilter.nf_conntrack_max = $CONNTRACK_MAX" >> "$CONF_FILE"
    fi
    
    # 应用配置
    sysctl --system >/dev/null 2>&1
    echo -e "${GREEN}[SUCCESS]${NC} ✅ 动态 BBR 优化已应用。当前拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control)"
}

# 5. 配置Swap
configure_swap() {
    echo -e "\n${YELLOW}=============== 4. 配置 Swap ===============${NC}"
    local swap_size_num
    if [[ "$SWAP_SIZE_MB" =~ ^[0-9]+$ ]]; then swap_size_num=$SWAP_SIZE_MB; else swap_size_num=-1; fi
    if [ "$swap_size_num" -eq 0 ]; then echo -e "${BLUE}[INFO] Swap配置为0，跳过。${NC}"; return 0; fi
    if [ "$(awk '/SwapTotal/ {print $2}' /proc/meminfo)" -gt 0 ]; then echo -e "${BLUE}[INFO] 已存在Swap，跳过。${NC}"; return 0; fi

    local swap_to_create_mb
    if [ "$SWAP_SIZE_MB" = "auto" ]; then
        mem_total_mb=$(($(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024))
        if [ "$mem_total_mb" -lt 2048 ]; then swap_to_create_mb=$mem_total_mb; else swap_to_create_mb=2048; fi
        echo -e "${BLUE}[INFO] 自动计算Swap大小为 ${swap_to_create_mb}MB...${NC}"
    else swap_to_create_mb=$SWAP_SIZE_MB; fi

    if ! check_disk_space "$((swap_to_create_mb + 100))"; then return 1; fi
    echo -e "${BLUE}[INFO] 正在配置 ${swap_to_create_mb}MB Swap...${NC}"
    if [ -f /swapfile ]; then swapoff /swapfile 2>/dev/null || true; rm -f /swapfile; fi

    if fallocate -l "${swap_to_create_mb}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$swap_to_create_mb" status=none 2>/dev/null; then
        chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
        grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
        echo -e "${GREEN}[SUCCESS]${NC} ✅ ${swap_to_create_mb}MB Swap 配置完成"
    else echo -e "${RED}[ERROR] Swap 文件创建失败${NC}"; return 1; fi
}

# 6. 配置DNS
configure_dns() {
    echo -e "\n${YELLOW}=============== 5. 配置公共 DNS ===============${NC}"
    local has_ipv6_support=false
    if has_ipv6; then
        echo -e "${BLUE}[INFO] 检测到IPv6连接，将同时配置IPv6 DNS。${NC}"
        has_ipv6_support=true
    else
        echo -e "${YELLOW}[WARN] 未检测到IPv6连接，仅配置IPv4 DNS。${NC}"
    fi
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo -e "${BLUE}[INFO] 检测到 systemd-resolved 服务，正在写入配置...${NC}"
        mkdir -p /etc/systemd/resolved.conf.d
        local dns_content="[Resolve]\nDNS=$PRIMARY_DNS_V4 $SECONDARY_DNS_V4\n"
        if [ "$has_ipv6_support" = "true" ]; then
            dns_content+="FallbackDNS=$PRIMARY_DNS_V6 $SECONDARY_DNS_V6\n"
        else
            dns_content+="FallbackDNS=$PRIMARY_DNS_V4 $SECONDARY_DNS_V4\n"
        fi
        echo -e "$dns_content" > /etc/systemd/resolved.conf.d/99-custom-dns.conf
        systemctl restart systemd-resolved
        resolvectl flush-caches 2>/dev/null || true
        echo -e "${GREEN}[SUCCESS]${NC} ✅ DNS 配置完成 (systemd-resolved)。"
        return 0
    fi
    if [ -d /etc/cloud/ ] && grep -q -r "manage_resolv_conf: *true" /etc/cloud/ 2>/dev/null; then
        echo -e "${BLUE}[INFO] 检测到 cloud-init 正在管理DNS，正在写入持久化配置...${NC}"
        local cloud_config_file="/etc/cloud/cloud.cfg.d/99-custom-dns.cfg"
        local cloud_dns_content
        cloud_dns_content=$(cat <<EOF
#cloud-config
manage_resolv_conf: true
resolv_conf:
  nameservers:
    - '$PRIMARY_DNS_V4'
    - '$SECONDARY_DNS_V4'
EOF
)
        if [ "$has_ipv6_support" = "true" ]; then
            cloud_dns_content+=$(cat <<EOF

    - '$PRIMARY_DNS_V6'
    - '$SECONDARY_DNS_V6'
EOF
)
        fi
        echo -e "$cloud_dns_content" > "$cloud_config_file"
        echo -e "${GREEN}[SUCCESS]${NC} ✅ DNS 配置完成 (cloud-init)。下次重启后生效。"
        return 0
    fi
    if command -v resolvconf >/dev/null; then
        echo -e "${BLUE}[INFO] 检测到 resolvconf，正在写入配置...${NC}"
        local head_file="/etc/resolvconf/resolv.conf.d/head"
        sed -i '/^nameserver/d' "$head_file" 2>/dev/null || true
        {
            echo "nameserver $PRIMARY_DNS_V4"
            echo "nameserver $SECONDARY_DNS_V4"
            [ "$has_ipv6_support" = "true" ] && {
                echo "nameserver $PRIMARY_DNS_V6"
                echo "nameserver $SECONDARY_DNS_V6"
            }
        } >> "$head_file"
        resolvconf -u
        echo -e "${GREEN}[SUCCESS]${NC} ✅ DNS 配置完成 (resolvconf)。"
        return 0
    fi
    echo -e "${YELLOW}[WARN] 未检测到特定DNS管理器。将直接覆盖 /etc/resolv.conf。${NC}"
    if [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf /etc/resolv.conf.backup.$(date +%s)
        echo -e "${BLUE}[INFO] 已备份原 /etc/resolv.conf 文件${NC}"
    fi
    chattr -i /etc/resolv.conf 2>/dev/null || true
    {
        echo "nameserver $PRIMARY_DNS_V4"
        echo "nameserver $SECONDARY_DNS_V4"
        [ "$has_ipv6_support" = "true" ] && {
            echo "nameserver $PRIMARY_DNS_V6"
            echo "nameserver $SECONDARY_DNS_V6"
        }
    } > /etc/resolv.conf
    echo -e "${GREEN}[SUCCESS]${NC} ✅ DNS 配置完成 (直接覆盖)。"
}

# 7. 安装工具和Vim
install_tools_and_vim() {
    echo -e "\n${YELLOW}=============== 6. 安装常用工具和配置Vim ===============${NC}"
    echo -e "${BLUE}[INFO] 更新软件包列表...${NC}"
    apt-get update -qq || { echo -e "${RED}[ERROR] 软件包列表更新失败。${NC}"; return 1; }
    echo -e "${BLUE}[INFO] 正在安装: $INSTALL_PACKAGES${NC}"
    apt-get install -y $INSTALL_PACKAGES >/dev/null 2>&1 || echo -e "${YELLOW}[WARN] 部分软件包安装失败。${NC}"
    if command -v vim &> /dev/null; then
        echo -e "${BLUE}[INFO] 配置Vim基础特性...${NC}"
        cat > /etc/vim/vimrc.local << 'EOF'
syntax on
set nocompatible
set backspace=indent,eol,start
set ruler
set showcmd
set hlsearch
set incsearch
set autoindent
set tabstop=4
set shiftwidth=4
set expandtab
set encoding=utf-8
set mouse=a
set nobackup
set noswapfile
EOF
        if [ -d /root ] && ! grep -q "source /etc/vim/vimrc.local" /root/.vimrc 2>/dev/null; then
            echo "source /etc/vim/vimrc.local" >> /root/.vimrc
        fi
        echo -e "${GREEN}[SUCCESS]${NC} ✅ Vim配置完成。"
    fi
}

# 8. 安装和配置 Fail2ban
install_and_configure_fail2ban() {
    echo -e "\n${YELLOW}=============== 7. 配置 Fail2ban 安全防护 ===============${NC}"
    local PORT_LIST="22"
    if [ -n "$FAIL2BAN_EXTRA_PORT" ]; then
        if ! [[ "$FAIL2BAN_EXTRA_PORT" =~ ^[0-9]+$ && "$FAIL2BAN_EXTRA_PORT" -ge 1 && "$FAIL2BAN_EXTRA_PORT" -le 65535 ]]; then
            echo -e "${RED}[ERROR] 无效的Fail2ban端口号 '$FAIL2BAN_EXTRA_PORT'，跳过配置。${NC}"
            return 1
        fi
        if [ "$FAIL2BAN_EXTRA_PORT" != "22" ]; then PORT_LIST="22,${FAIL2BAN_EXTRA_PORT}"; fi
    fi
    echo -e "${BLUE}[INFO] 正在安装 Fail2ban...${NC}"
    apt-get install -y fail2ban >/dev/null 2>&1 || { echo -e "${RED}[ERROR] Fail2ban 安装失败。${NC}"; return 1; }
    
    echo -e "${BLUE}[INFO] 正在创建配置文件 /etc/fail2ban/jail.local...${NC}"
    echo -e "${BLUE}[INFO] 将保护的SSH端口: ${PORT_LIST}${NC}"
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = -1
findtime = 300
maxretry = 3
banaction = iptables-allports
action = %(action_mwl)s

[sshd]
enabled = true
port = ${PORT_LIST}
backend = systemd
ignoreip = 127.0.0.1/8
EOF
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban
    echo -e "${GREEN}[SUCCESS]${NC} ✅ Fail2ban 已配置并启动。"
}

# 9. 系统更新和清理
update_and_cleanup() {
    echo -e "\n${YELLOW}=============== 8. 系统更新和清理 ===============${NC}"
    echo -e "${BLUE}[INFO] 执行系统升级...${NC}"
    DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -o Dpkg::Options::="--force-confold" >/dev/null 2>&1 || \
        echo -e "${YELLOW}[WARN] 系统升级过程出现错误，但继续执行。${NC}"
    echo -e "${BLUE}[INFO] 移除无用依赖并清理缓存...${NC}"
    apt-get autoremove --purge -y >/dev/null 2>&1
    apt-get clean
    echo -e "${GREEN}[SUCCESS]${NC} ✅ 系统更新和清理完成。"
}

# 10. 最终摘要
final_summary() {
    echo -e "\n${YELLOW}===================== 配置完成 =====================${NC}"
    echo -e "${GREEN}[SUCCESS]${NC} 🎉 系统初始化配置完成！\n"
    echo "配置摘要："
    echo "  - 主机名: $(hostname)"
    echo "  - 时区: $(timedatectl show --property=Timezone --value 2>/dev/null || echo '未设置')"
    local bbr_status=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    echo "  - BBR模式: ${BBR_MODE} (当前: ${bbr_status:-'未知'})"
    echo "  - Swap大小: $(free -h | awk '/Swap/ {print $2}' || echo '未配置')"
    if $ENABLE_FAIL2BAN && systemctl is-active --quiet fail2ban; then
        local f2b_ports=$(grep -oP 'port\s*=\s*\K[0-9,]+' /etc/fail2ban/jail.local || echo "未知")
        echo -e "  - Fail2ban: ${GREEN}已启用 (保护端口: ${f2b_ports})${NC}"
    else
        echo "  - Fail2ban: 未配置"
    fi
    echo -e "\n总执行时间: ${SECONDS} 秒"
    echo -e "完整日志已保存至: ${LOG_FILE}"
}

# --- 主函数 ---
main() {
    trap 'handle_error ${LINENO}' ERR
    SECONDS=0
    if [[ $EUID -ne 0 ]]; then echo -e "${RED}[ERROR] 此脚本需要 root 权限运行。${NC}" >&2; exit 1; fi

    LOG_FILE="/var/log/vps-init-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "${LOG_FILE}") 2>&1
    echo -e "${BLUE}[INFO] 脚本启动。日志记录到: ${LOG_FILE}${NC}"
    if [ "$non_interactive" = "true" ]; then echo -e "${BLUE}[INFO] 已启用非交互模式。${NC}"; fi

    [ -f /etc/os-release ] && source /etc/os-release || { echo "错误: /etc/os-release 未找到"; exit 1; }

    pre_flight_checks
    configure_hostname
    configure_timezone
    
    # === 【关键修改】自动清理旧的优化配置文件（如果存在） ===
    rm -f /etc/sysctl.d/99-bbr-optimized.conf
    
    # BBR 逻辑判断
    if [ "$BBR_MODE" = "optimized" ]; then
        configure_optimized_bbr
    elif [ "$BBR_MODE" = "default" ]; then
        configure_default_bbr
    else
        echo -e "\n${YELLOW}=============== 3. 配置 BBR ===============${NC}"
        echo -e "${BLUE}[INFO] 根据参数 (--no-bbr)，跳过 BBR 配置。${NC}"
        # 如果跳过，也确保旧的配置文件被移除，以免干扰
        rm -f /etc/sysctl.d/99-bbr.conf
    fi

    configure_swap
    configure_dns
    install_tools_and_vim
    
    # Fail2ban 逻辑判断
    if [ "$ENABLE_FAIL2BAN" = true ]; then
        install_and_configure_fail2ban
    fi

    update_and_cleanup
    final_summary

    echo
    if [ "$non_interactive" = "true" ]; then
        echo -e "${BLUE}[INFO] 非交互模式：配置完成，正在自动重启系统...${NC}"
        reboot
    else
        read -p "是否立即重启系统以确保所有配置生效？ [Y/n] 默认 Y: " -r < /dev/tty
        [[ ! $REPLY =~ ^[Nn]$ ]] && { echo -e "${BLUE}[INFO] 正在立即重启系统...${NC}"; reboot; } || \
            echo -e "${BLUE}[INFO] 配置完成，建议稍后手动重启 (sudo reboot)。${NC}"
    fi
}

main "$@"
