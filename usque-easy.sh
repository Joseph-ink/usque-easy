#!/bin/bash

#===============================================================================
# Usque WARP MASQUE Manager
# 为IPv6-only VPS提供IPv4访问能力
# 使用Native Tunnel模式获得最高性能
#===============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 配置变量
INSTALL_DIR="/opt/usque"
CONFIG_FILE="${INSTALL_DIR}/config.json"
BINARY_PATH="${INSTALL_DIR}/usque"
SERVICE_NAME="usque-warp"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
GITHUB_REPO="Diniboy1123/usque"
LATEST_VERSION="1.4.2"

# TUN接口名称
TUN_INTERFACE="warp0"

# Cron任务标识
CRON_MARKER="# usque-warp-watchdog"
WATCHDOG_SCRIPT="${INSTALL_DIR}/watchdog.sh"

#===============================================================================
# 辅助函数
#===============================================================================

print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           Usque WARP MASQUE Manager                          ║"
    echo "║           为IPv6-only VPS提供IPv4访问能力                      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        log_info "请使用 sudo $0 运行"
        exit 1
    fi
}

confirm_action() {
    local prompt="$1"
    local default="${2:-n}"
    
    if [[ "$default" == "y" ]]; then
        prompt="${prompt} [Y/n]: "
    else
        prompt="${prompt} [y/N]: "
    fi
    
    read -p "$prompt" response
    response=${response:-$default}
    
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

get_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7*|armv7l)
            echo "armv7"
            ;;
        armv6*)
            echo "armv6"
            ;;
        armv5*)
            echo "armv5"
            ;;
        *)
            log_error "不支持的CPU架构: $arch"
            exit 1
            ;;
    esac
}

get_os() {
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
        linux)
            echo "linux"
            ;;
        darwin)
            echo "darwin"
            ;;
        *)
            log_error "不支持的操作系统: $os"
            exit 1
            ;;
    esac
}

#===============================================================================
# 依赖检查和安装
#===============================================================================

install_dependencies() {
    log_step "检查并安装依赖..."
    
    # 检测包管理器
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt-get"
        PKG_UPDATE="apt-get update"
        PKG_INSTALL="apt-get install -y"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
        PKG_UPDATE="yum makecache"
        PKG_INSTALL="yum install -y"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
        PKG_UPDATE="dnf makecache"
        PKG_INSTALL="dnf install -y"
    elif command -v pacman &> /dev/null; then
        PKG_MANAGER="pacman"
        PKG_UPDATE="pacman -Sy"
        PKG_INSTALL="pacman -S --noconfirm"
    elif command -v apk &> /dev/null; then
        PKG_MANAGER="apk"
        PKG_UPDATE="apk update"
        PKG_INSTALL="apk add"
    else
        log_error "无法检测到支持的包管理器"
        exit 1
    fi
    
    log_info "检测到包管理器: $PKG_MANAGER"
    
    # 更新包列表
    log_info "更新包列表..."
    $PKG_UPDATE || true
    
    # 安装必要依赖
    local deps_to_install=""
    
    # 检查curl
    if ! command -v curl &> /dev/null; then
        deps_to_install="$deps_to_install curl"
    fi
    
    # 检查unzip
    if ! command -v unzip &> /dev/null; then
        deps_to_install="$deps_to_install unzip"
    fi
    
    # 检查jq (用于JSON处理)
    if ! command -v jq &> /dev/null; then
        deps_to_install="$deps_to_install jq"
    fi
    
    # 检查iproute2 (ip命令)
    if ! command -v ip &> /dev/null; then
        case "$PKG_MANAGER" in
            apt-get)
                deps_to_install="$deps_to_install iproute2"
                ;;
            yum|dnf)
                deps_to_install="$deps_to_install iproute"
                ;;
            pacman)
                deps_to_install="$deps_to_install iproute2"
                ;;
            apk)
                deps_to_install="$deps_to_install iproute2"
                ;;
        esac
    fi
    
    # 检查iptables
    if ! command -v iptables &> /dev/null; then
        deps_to_install="$deps_to_install iptables"
    fi
    
    if [[ -n "$deps_to_install" ]]; then
        log_info "安装依赖: $deps_to_install"
        $PKG_INSTALL $deps_to_install
    else
        log_info "所有依赖已满足"
    fi
}

#===============================================================================
# TUN设备检查
#===============================================================================

check_tun_support() {
    log_step "检查TUN设备支持..."
    
    # 检查/dev/net/tun是否存在
    if [[ -c /dev/net/tun ]]; then
        log_info "TUN设备已存在: /dev/net/tun"
        return 0
    fi
    
    # 尝试加载tun模块
    log_info "尝试加载tun内核模块..."
    
    if modprobe tun 2>/dev/null; then
        log_info "成功加载tun模块"
        
        # 确保/dev/net目录存在
        if [[ ! -d /dev/net ]]; then
            mkdir -p /dev/net
        fi
        
        # 检查设备是否已创建
        if [[ -c /dev/net/tun ]]; then
            log_info "TUN设备已就绪"
            return 0
        fi
        
        # 尝试手动创建设备节点
        if mknod /dev/net/tun c 10 200 2>/dev/null; then
            chmod 666 /dev/net/tun
            log_info "成功创建TUN设备"
            return 0
        fi
    fi
    
    # 检查内核是否编译了TUN支持
    if [[ -f /proc/config.gz ]]; then
        if zcat /proc/config.gz | grep -q "CONFIG_TUN=y\|CONFIG_TUN=m"; then
            log_warn "内核支持TUN，但无法加载模块"
        fi
    fi
    
    # 检查是否在容器环境中
    if [[ -f /.dockerenv ]] || grep -q docker /proc/1/cgroup 2>/dev/null; then
        log_error "检测到Docker容器环境"
        log_error "容器需要使用 --cap-add=NET_ADMIN --device=/dev/net/tun 启动"
        exit 1
    fi
    
    if systemd-detect-virt -c &>/dev/null; then
        local virt=$(systemd-detect-virt)
        log_error "检测到容器环境: $virt"
        log_error "请确保VPS提供商支持TUN/TAP设备"
        exit 1
    fi
    
    log_error "无法启用TUN设备支持"
    log_error "请确保:"
    log_error "  1. 内核支持TUN模块 (CONFIG_TUN=y 或 CONFIG_TUN=m)"
    log_error "  2. 如果是VPS，请联系提供商启用TUN/TAP支持"
    log_error "  3. 如果是容器，请使用 --cap-add=NET_ADMIN --device=/dev/net/tun"
    exit 1
}

ensure_tun_on_boot() {
    log_info "配置TUN模块开机自动加载..."
    
    # 添加到modules配置
    if [[ -d /etc/modules-load.d ]]; then
        echo "tun" > /etc/modules-load.d/usque-tun.conf
    elif [[ -f /etc/modules ]]; then
        if ! grep -q "^tun$" /etc/modules; then
            echo "tun" >> /etc/modules
        fi
    fi
    
    log_info "TUN模块已配置为开机自动加载"
}

#===============================================================================
# 下载和安装
#===============================================================================

# GitHub镜像源列表
declare -a GITHUB_MIRRORS=(
    "https://github.com"                           # 原始地址
    "https://gh-proxy.com/github.com"              # gh-proxy镜像
    "https://ghproxy.net/github.com"               # ghproxy.net镜像
    "https://mirror.ghproxy.com/github.com"        # mirror.ghproxy镜像
    "https://gh.ddlc.top/github.com"               # ddlc镜像
    "https://slink.ltd/github.com"                 # slink镜像
    "https://gh.con.sh/github.com"                 # con.sh镜像
    "https://hub.gitmirror.com/github.com"         # gitmirror镜像
)

select_mirror() {
    echo ""
    echo -e "${CYAN}=== 选择下载源 ===${NC}"
    echo ""
    echo "由于IPv6-only环境访问GitHub困难，请选择下载源："
    echo ""
    echo "  1) 自动尝试所有镜像 (推荐)"
    echo "  2) GitHub原始地址"
    echo "  3) gh-proxy.com 镜像"
    echo "  4) ghproxy.net 镜像"
    echo "  5) mirror.ghproxy.com 镜像"
    echo "  6) gh.ddlc.top 镜像"
    echo "  7) slink.ltd 镜像"
    echo "  8) gh.con.sh 镜像"
    echo "  9) hub.gitmirror.com 镜像"
    echo "  0) 手动输入镜像地址"
    echo ""
    read -p "请选择 [1-9, 0]: " mirror_choice
    
    case $mirror_choice in
        1) SELECTED_MIRROR="auto" ;;
        2) SELECTED_MIRROR="https://github.com" ;;
        3) SELECTED_MIRROR="https://gh-proxy.com/github.com" ;;
        4) SELECTED_MIRROR="https://ghproxy.net/github.com" ;;
        5) SELECTED_MIRROR="https://mirror.ghproxy.com/github.com" ;;
        6) SELECTED_MIRROR="https://gh.ddlc.top/github.com" ;;
        7) SELECTED_MIRROR="https://slink.ltd/github.com" ;;
        8) SELECTED_MIRROR="https://gh.con.sh/github.com" ;;
        9) SELECTED_MIRROR="https://hub.gitmirror.com/github.com" ;;
        0)
            echo ""
            echo "请输入镜像地址前缀 (例如: https://mirror.example.com/github.com)"
            echo "下载URL格式为: {镜像前缀}/${GITHUB_REPO}/releases/download/v{版本}/{文件名}"
            read -p "镜像地址: " SELECTED_MIRROR
            ;;
        *)
            log_warn "无效选择，使用自动模式"
            SELECTED_MIRROR="auto"
            ;;
    esac
}

try_download() {
    local url="$1"
    local output="$2"
    local timeout="${3:-60}"
    
    log_info "尝试下载: $url"
    
    # 使用curl下载，设置超时和重试
    if curl -L \
        --connect-timeout 15 \
        --max-time "$timeout" \
        --retry 2 \
        --retry-delay 3 \
        -o "$output" \
        "$url" 2>&1; then
        
        # 检查文件大小
        local file_size=$(stat -c%s "$output" 2>/dev/null || stat -f%z "$output" 2>/dev/null || echo "0")
        if [[ "$file_size" -gt 1000000 ]]; then
            return 0
        else
            log_warn "文件过小 (${file_size} bytes)，可能下载不完整"
            return 1
        fi
    else
        return 1
    fi
}

download_usque() {
    local auto_ipv6_mirror="${1:-false}"
    
    log_step "下载usque二进制文件..."
    
    local os=$(get_os)
    local arch=$(get_arch)
    
    log_info "检测到系统: ${os}_${arch}"
    
    # 获取最新版本
    log_info "获取最新版本信息..."
    local latest_version=""
    
    # 尝试从不同源获取版本信息（IPv6-only时优先使用gh-proxy）
    local api_mirrors=("https://api.github.com" "https://gh-proxy.com/https://api.github.com")
    if [[ "$auto_ipv6_mirror" == "true" ]]; then
        # IPv6-only环境优先使用代理
        api_mirrors=("https://gh-proxy.com/https://api.github.com" "https://api.github.com")
    fi
    
    for api_mirror in "${api_mirrors[@]}"; do
        latest_version=$(curl -sL --connect-timeout 10 --max-time 20 \
            "${api_mirror}/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null | \
            grep '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/' || true)
        
        if [[ -n "$latest_version" ]]; then
            log_info "从 $api_mirror 获取到版本信息"
            break
        fi
    done
    
    if [[ -z "$latest_version" ]]; then
        latest_version="$LATEST_VERSION"
        log_warn "无法获取最新版本，使用默认版本: v${latest_version}"
    else
        log_info "最新版本: v${latest_version}"
    fi
    
    local filename="usque_${latest_version}_${os}_${arch}.zip"
    local github_path="${GITHUB_REPO}/releases/download/v${latest_version}/${filename}"
    
    # 选择镜像（IPv6-only时自动使用gh-proxy）
    if [[ "$auto_ipv6_mirror" == "true" ]]; then
        log_info "IPv6-only环境: 自动使用 gh-proxy.com 镜像"
        SELECTED_MIRROR="https://gh-proxy.com/github.com"
    else
        select_mirror
    fi
    
    # 创建临时目录
    local tmp_dir=$(mktemp -d)
    local zip_file="${tmp_dir}/${filename}"
    
    local download_success=false
    
    if [[ "$SELECTED_MIRROR" == "auto" ]]; then
        # 自动尝试所有镜像
        log_info "自动模式：依次尝试所有镜像源..."
        
        for mirror in "${GITHUB_MIRRORS[@]}"; do
            local download_url="${mirror}/${github_path}"
            
            if try_download "$download_url" "$zip_file" 120; then
                log_info "下载成功!"
                download_success=true
                break
            else
                log_warn "镜像 $mirror 下载失败，尝试下一个..."
                rm -f "$zip_file"
            fi
        done
    else
        # 使用指定镜像
        local download_url="${SELECTED_MIRROR}/${github_path}"
        
        if try_download "$download_url" "$zip_file" 180; then
            log_info "下载成功!"
            download_success=true
        else
            # 如果指定镜像失败，尝试自动模式
            log_warn "指定镜像下载失败，尝试其他镜像..."
            for mirror in "${GITHUB_MIRRORS[@]}"; do
                if [[ "$mirror" == "$SELECTED_MIRROR" ]]; then
                    continue
                fi
                local download_url="${mirror}/${github_path}"
                
                if try_download "$download_url" "$zip_file" 120; then
                    log_info "下载成功!"
                    download_success=true
                    break
                else
                    log_warn "镜像 $mirror 下载失败，尝试下一个..."
                    rm -f "$zip_file"
                fi
            done
        fi
    fi
    
    if ! $download_success; then
        log_error "所有下载源均失败"
        log_info ""
        log_info "手动下载方案："
        log_info "1. 在有IPv4的机器上下载: https://github.com/${github_path}"
        log_info "2. 使用scp上传到VPS: scp ${filename} user@your-vps:${INSTALL_DIR}/"
        log_info "3. 解压: unzip ${filename} -d ${INSTALL_DIR}"
        log_info "4. 重新运行此脚本选择'仅注册WARP账号'"
        rm -rf "$tmp_dir"
        exit 1
    fi
    
    # 检查文件大小
    local file_size=$(stat -c%s "$zip_file" 2>/dev/null || stat -f%z "$zip_file" 2>/dev/null)
    log_info "下载完成，文件大小: $(numfmt --to=iec $file_size 2>/dev/null || echo "${file_size} bytes")"
    
    # 创建安装目录
    mkdir -p "$INSTALL_DIR"
    
    # 解压文件
    log_info "解压文件..."
    if ! unzip -o "$zip_file" -d "$tmp_dir"; then
        log_error "解压失败"
        rm -rf "$tmp_dir"
        exit 1
    fi
    
    # 移动二进制文件
    if [[ -f "${tmp_dir}/usque" ]]; then
        mv "${tmp_dir}/usque" "$BINARY_PATH"
    else
        log_error "解压后未找到usque二进制文件"
        rm -rf "$tmp_dir"
        exit 1
    fi
    
    # 设置执行权限
    chmod +x "$BINARY_PATH"
    
    # 清理临时文件
    rm -rf "$tmp_dir"
    
    log_info "usque已安装到: $BINARY_PATH"
    
    # 验证安装
    if "$BINARY_PATH" --help &>/dev/null; then
        log_info "安装验证成功"
        "$BINARY_PATH" --help | head -5
    else
        log_error "安装验证失败"
        exit 1
    fi
}

#===============================================================================
# WARP注册和配置
#===============================================================================

register_warp() {
    log_step "注册WARP账号..."
    
    cd "$INSTALL_DIR"
    
    # 检查是否已有配置
    if [[ -f "$CONFIG_FILE" ]]; then
        log_warn "检测到已存在的配置文件"
        if ! confirm_action "是否覆盖现有配置?"; then
            log_info "保留现有配置"
            return 0
        fi
        # 备份旧配置
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    fi
    
    log_info "正在注册新的WARP账号..."
    
    # 注册设备
    if ! "$BINARY_PATH" -c "$CONFIG_FILE" register -n "usque-$(hostname)"; then
        log_error "WARP注册失败"
        log_info "可能是被速率限制，请稍后重试"
        exit 1
    fi
    
    log_info "WARP注册成功"
    
    # 显示配置信息
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "配置文件已保存到: $CONFIG_FILE"
        
        # 提取并显示分配的IP
        local ipv4=$(grep -o '"ipv4": "[^"]*"' "$CONFIG_FILE" | cut -d'"' -f4)
        local ipv6=$(grep -o '"ipv6": "[^"]*"' "$CONFIG_FILE" | cut -d'"' -f4)
        
        if [[ -n "$ipv4" ]]; then
            log_info "分配的内部IPv4: $ipv4"
        fi
        if [[ -n "$ipv6" ]]; then
            log_info "分配的内部IPv6: $ipv6"
        fi
    fi
}

#===============================================================================
# IPv6-only检测和修复功能
# 将endpoint_v4修改为endpoint_v6的值以支持IPv6-only机型
# 注：此功能用于修复IPv6-only环境，未来usque可能原生支持，届时可移除
#===============================================================================

# 获取主要物理网络接口名称（排除lo、warp0、docker等虚拟接口）
get_primary_interface() {
    # 方法1：从IPv6默认路由获取接口
    local iface=$(ip -6 route show default 2>/dev/null | grep -oP 'dev \K[^ ]+' | head -1)
    
    # 方法2：如果没有IPv6默认路由，从IPv4默认路由获取（排除warp0）
    if [[ -z "$iface" ]]; then
        iface=$(ip -4 route show default 2>/dev/null | grep -v "dev ${TUN_INTERFACE}" | grep -oP 'dev \K[^ ]+' | head -1)
    fi
    
    # 方法3：获取第一个UP状态的非虚拟接口
    if [[ -z "$iface" ]]; then
        iface=$(ip link show | grep -E '^[0-9]+:' | grep -v -E '(lo|warp|docker|veth|br-)' | grep 'state UP' | head -1 | awk -F: '{print $2}' | tr -d ' ')
    fi
    
    echo "$iface"
}

# 检测是否为IPv6-only环境
# 核心逻辑：检查物理接口是否有公网IPv4默认路由
is_ipv6_only() {
    # 获取主接口
    local primary_if=$(get_primary_interface)
    
    # 检查是否有通过主接口的IPv4默认路由
    local has_ipv4_default_via_primary=""
    if [[ -n "$primary_if" ]]; then
        has_ipv4_default_via_primary=$(ip -4 route show default 2>/dev/null | grep "dev ${primary_if}" | head -1)
    fi
    
    # 也检查是否有任何非warp0的IPv4默认路由
    local has_any_native_ipv4_default=$(ip -4 route show default 2>/dev/null | grep -v "dev ${TUN_INTERFACE}" | head -1)
    
    # 检查是否有IPv6默认路由
    local has_ipv6_default=$(ip -6 route show default 2>/dev/null | head -1)
    
    # 判断逻辑：
    # 1. 如果有IPv6默认路由，但没有任何原生IPv4默认路由 -> IPv6-only
    # 2. 如果有原生IPv4默认路由 -> 非IPv6-only
    if [[ -n "$has_ipv6_default" ]] && [[ -z "$has_any_native_ipv4_default" ]]; then
        return 0  # IPv6-only
    fi
    
    return 1  # 非IPv6-only
}

# 检测网络环境（详细版本，用于调试和显示）
check_network_environment() {
    log_step "检测网络环境..."
    
    # 获取主接口
    local primary_if=$(get_primary_interface)
    log_info "主网络接口: ${primary_if:-未知}"
    
    # 显示所有IPv4默认路由
    local all_ipv4_defaults=$(ip -4 route show default 2>/dev/null)
    log_info "所有IPv4默认路由:"
    if [[ -n "$all_ipv4_defaults" ]]; then
        echo "$all_ipv4_defaults" | while read line; do
            echo "    $line"
        done
    else
        echo "    (无)"
    fi
    
    # 显示原生IPv4默认路由（排除warp0）
    local native_ipv4_default=$(ip -4 route show default 2>/dev/null | grep -v "dev ${TUN_INTERFACE}" | head -1)
    log_info "原生IPv4默认路由: ${native_ipv4_default:-无}"
    
    # 显示IPv6默认路由
    local ipv6_default=$(ip -6 route show default 2>/dev/null | head -1)
    log_info "IPv6默认路由: ${ipv6_default:-无}"
    
    # 判断网络环境
    if [[ -n "$ipv6_default" ]] && [[ -z "$native_ipv4_default" ]]; then
        echo ""
        log_info "═══════════════════════════════════════"
        log_info "检测结果: ${YELLOW}IPv6-only 环境${NC}"
        log_info "═══════════════════════════════════════"
        return 0
    elif [[ -n "$native_ipv4_default" ]]; then
        echo ""
        log_info "═══════════════════════════════════════"
        log_info "检测结果: 双栈或纯IPv4环境"
        log_info "═══════════════════════════════════════"
        return 1
    else
        echo ""
        log_warn "═══════════════════════════════════════"
        log_warn "检测结果: 网络环境异常，默认按IPv6-only处理"
        log_warn "═══════════════════════════════════════"
        return 0  # 异常情况下按IPv6-only处理更安全
    fi
}

# 修复endpoint_v4为endpoint_v6的值
fix_endpoint_for_ipv6_only() {
    log_step "修复IPv6-only环境的endpoint配置..."
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "配置文件不存在: $CONFIG_FILE"
        return 1
    fi
    
    # 检查是否为IPv6-only环境
    if ! is_ipv6_only; then
        log_info "当前环境有IPv4路由，无需修复endpoint"
        return 0
    fi
    
    log_info "检测到IPv6-only环境，正在修复endpoint配置..."
    
    # 读取当前的endpoint值
    local endpoint_v4=$(jq -r '.endpoint_v4 // empty' "$CONFIG_FILE" 2>/dev/null)
    local endpoint_v6=$(jq -r '.endpoint_v6 // empty' "$CONFIG_FILE" 2>/dev/null)
    
    if [[ -z "$endpoint_v6" ]]; then
        log_error "无法读取endpoint_v6值"
        return 1
    fi
    
    log_info "当前 endpoint_v4: $endpoint_v4"
    log_info "当前 endpoint_v6: $endpoint_v6"
    
    # 检查是否已经修复过
    if [[ "$endpoint_v4" == "$endpoint_v6" ]]; then
        log_info "endpoint_v4 已经是 IPv6 地址，无需修改"
        return 0
    fi
    
    # 备份配置文件
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    log_info "已备份配置文件"
    
    # 使用jq修改endpoint_v4为endpoint_v6的值
    local tmp_file=$(mktemp)
    if jq --arg v6 "$endpoint_v6" '.endpoint_v4 = $v6' "$CONFIG_FILE" > "$tmp_file"; then
        mv "$tmp_file" "$CONFIG_FILE"
        log_info "已将 endpoint_v4 修改为: $endpoint_v6"
        log_info "IPv6-only环境修复完成"
    else
        log_error "修改配置文件失败"
        rm -f "$tmp_file"
        return 1
    fi
}

# 恢复endpoint_v4的原始值（用于未来移除此修复时）
restore_endpoint_v4() {
    log_step "恢复endpoint_v4原始值..."
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "配置文件不存在"
        return 1
    fi
    
    # 查找最近的备份文件
    local latest_backup=$(ls -t "${CONFIG_FILE}.bak."* 2>/dev/null | head -1)
    
    if [[ -z "$latest_backup" ]]; then
        log_warn "未找到备份文件，无法恢复"
        return 1
    fi
    
    # 从备份文件中读取原始的endpoint_v4
    local original_v4=$(jq -r '.endpoint_v4 // empty' "$latest_backup" 2>/dev/null)
    
    if [[ -z "$original_v4" ]]; then
        log_error "无法从备份读取原始endpoint_v4"
        return 1
    fi
    
    log_info "原始 endpoint_v4: $original_v4"
    
    # 恢复原始值
    local tmp_file=$(mktemp)
    if jq --arg v4 "$original_v4" '.endpoint_v4 = $v4' "$CONFIG_FILE" > "$tmp_file"; then
        mv "$tmp_file" "$CONFIG_FILE"
        log_info "已恢复 endpoint_v4 为: $original_v4"
    else
        log_error "恢复配置文件失败"
        rm -f "$tmp_file"
        return 1
    fi
}

#===============================================================================
# WARP+ 功能
# 通过API推送WARP+密钥启用付费功能
#===============================================================================

activate_warp_plus() {
    log_step "启用WARP+..."
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "配置文件不存在，请先注册WARP账号"
        return 1
    fi
    
    # 读取配置
    local id=$(jq -r '.id // empty' "$CONFIG_FILE" 2>/dev/null)
    local access_token=$(jq -r '.access_token // empty' "$CONFIG_FILE" 2>/dev/null)
    local current_license=$(jq -r '.license // empty' "$CONFIG_FILE" 2>/dev/null)
    
    if [[ -z "$id" ]] || [[ -z "$access_token" ]]; then
        log_error "无法读取配置文件中的id或access_token"
        return 1
    fi
    
    log_info "当前账户ID: $id"
    log_info "当前许可证: ${current_license:-无}"
    
    echo ""
    echo -e "${CYAN}=== WARP+ 激活 ===${NC}"
    echo ""
    echo "请输入您的WARP+密钥 (格式类似: XXXXXXXX-XXXXXXXX-XXXXXXXX)"
    echo "您可以从WARP手机应用获取密钥，或从第三方获取"
    echo ""
    read -p "WARP+密钥: " warp_plus_key
    
    if [[ -z "$warp_plus_key" ]]; then
        log_error "未输入密钥，取消激活"
        return 1
    fi
    
    # 验证密钥格式 (可选，简单验证)
    if [[ ! "$warp_plus_key" =~ ^[A-Za-z0-9]{8}-[A-Za-z0-9]{8}-[A-Za-z0-9]{8}$ ]]; then
        log_warn "密钥格式可能不正确，但仍尝试推送..."
    fi
    
    log_info "正在推送WARP+密钥到服务器..."
    
    # 构建API请求
    local api_url="https://api.cloudflareclient.com/v0a2158/reg/${id}/account"
    
    # 发送请求
    local response
    response=$(curl -s -w "\n%{http_code}" -X PUT \
        -H "Authorization: Bearer ${access_token}" \
        -H "Content-Type: application/json" \
        -d "{\"license\": \"${warp_plus_key}\"}" \
        "$api_url" 2>&1)
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    echo ""
    log_info "API响应码: $http_code"
    
    if [[ "$http_code" == "200" ]] || [[ "$http_code" == "201" ]]; then
        log_info "WARP+密钥推送成功!"
        echo ""
        log_info "API响应: $body"
        
        # 更新配置文件
        log_info "正在更新本地配置..."
        cd "$INSTALL_DIR"
        
        if "$BINARY_PATH" -c "$CONFIG_FILE" enroll 2>/dev/null; then
            log_info "配置文件已更新"
        else
            log_warn "自动更新配置失败，请手动运行: cd $INSTALL_DIR && ./usque enroll"
        fi
        
        # 对于IPv6-only环境，需要再次修复endpoint
        if is_ipv6_only; then
            log_info "检测到IPv6-only环境，重新修复endpoint配置..."
            fix_endpoint_for_ipv6_only
        fi
        
        # 重启服务
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            log_info "重启服务以应用更改..."
            systemctl restart "$SERVICE_NAME"
            sleep 3
        fi
        
        # 验证WARP+状态
        echo ""
        log_info "验证WARP+状态..."
        sleep 2
        verify_warp_plus_status
        
    else
        log_error "WARP+密钥推送失败"
        log_error "HTTP状态码: $http_code"
        log_error "响应内容: $body"
        echo ""
        log_info "可能的原因:"
        log_info "  1. 密钥无效或已过期"
        log_info "  2. 密钥已被使用达到上限"
        log_info "  3. 网络连接问题"
        return 1
    fi
}

verify_warp_plus_status() {
    log_info "检查WARP连接状态..."
    
    local trace_result
    trace_result=$(curl -4 -s --connect-timeout 10 --max-time 15 \
        "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null || true)
    
    if [[ -z "$trace_result" ]]; then
        log_warn "无法连接到Cloudflare，请检查WARP隧道"
        return 1
    fi
    
    echo ""
    log_info "Cloudflare Trace 结果:"
    echo "$trace_result" | grep -E "^(warp|ip|colo)=" | while read line; do
        echo "  $line"
    done
    
    local warp_status=$(echo "$trace_result" | grep "^warp=" | cut -d= -f2)
    
    case "$warp_status" in
        "plus")
            echo ""
            log_info "✓ WARP+ 已成功激活!"
            ;;
        "on")
            echo ""
            log_warn "WARP已启用，但WARP+未激活"
            log_info "如果刚刚激活，请等待几分钟后再次检查"
            ;;
        "off")
            echo ""
            log_error "WARP未启用"
            ;;
        *)
            echo ""
            log_warn "WARP状态: $warp_status"
            ;;
    esac
}

#===============================================================================
# 定时监控和自动重启功能
#===============================================================================

# 创建watchdog监控脚本
create_watchdog_script() {
    log_step "创建监控脚本..."
    
    cat > "$WATCHDOG_SCRIPT" << 'WATCHDOG_EOF'
#!/bin/bash
#===============================================================================
# Usque WARP Watchdog
# 定时检测IPv4连通性，失败时自动重启服务
#===============================================================================

LOG_FILE="/var/log/usque-watchdog.log"
SERVICE_NAME="usque-warp"
MAX_LOG_SIZE=$((1024 * 1024))  # 1MB

# 记录日志
log_msg() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" >> "$LOG_FILE"
}

# 检查并轮转日志
rotate_log() {
    if [[ -f "$LOG_FILE" ]]; then
        local size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo "0")
        if [[ "$size" -gt "$MAX_LOG_SIZE" ]]; then
            mv "$LOG_FILE" "${LOG_FILE}.old"
            log_msg "日志已轮转"
        fi
    fi
}

# 测试IPv4连通性
test_ipv4_connectivity() {
    local test_urls=(
        "https://1.1.1.1/cdn-cgi/trace"
        "https://cloudflare.com/cdn-cgi/trace"
        "https://8.8.8.8"
    )
    
    for url in "${test_urls[@]}"; do
        if curl -4 -s --connect-timeout 5 --max-time 10 "$url" &>/dev/null; then
            return 0
        fi
    done
    
    return 1
}

# 主逻辑
main() {
    rotate_log
    
    # 检查服务是否运行
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        log_msg "服务未运行，尝试启动..."
        systemctl start "$SERVICE_NAME"
        sleep 5
    fi
    
    # 测试连通性
    if test_ipv4_connectivity; then
        # 连接正常，静默退出（可选择性记录）
        # log_msg "IPv4连接正常"
        exit 0
    else
        log_msg "IPv4连接失败，重启服务..."
        systemctl restart "$SERVICE_NAME"
        sleep 10
        
        # 再次测试
        if test_ipv4_connectivity; then
            log_msg "服务重启后连接恢复正常"
        else
            log_msg "服务重启后连接仍然失败"
        fi
    fi
}

main
WATCHDOG_EOF

    chmod +x "$WATCHDOG_SCRIPT"
    log_info "监控脚本已创建: $WATCHDOG_SCRIPT"
}

# 设置cron定时任务
setup_watchdog_cron() {
    log_step "设置定时监控任务..."
    
    # 先创建监控脚本
    create_watchdog_script
    
    # 检查是否已存在cron任务
    if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
        log_info "定时任务已存在，更新中..."
        # 删除旧的任务
        crontab -l 2>/dev/null | grep -v "$CRON_MARKER" | grep -v "$WATCHDOG_SCRIPT" | crontab -
    fi
    
    # 添加新的cron任务（每5分钟执行一次）
    (crontab -l 2>/dev/null; echo "*/5 * * * * $WATCHDOG_SCRIPT $CRON_MARKER") | crontab -
    
    log_info "定时监控任务已设置 (每5分钟检测一次)"
    log_info "日志文件: /var/log/usque-watchdog.log"
    
    # 显示当前cron任务
    echo ""
    log_info "当前cron任务:"
    crontab -l 2>/dev/null | grep -E "(usque|warp)" || echo "  (无相关任务)"
}

# 移除cron定时任务
remove_watchdog_cron() {
    log_step "移除定时监控任务..."
    
    if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
        crontab -l 2>/dev/null | grep -v "$CRON_MARKER" | grep -v "$WATCHDOG_SCRIPT" | crontab -
        log_info "定时监控任务已移除"
    else
        log_info "未找到定时监控任务"
    fi
    
    # 删除监控脚本
    if [[ -f "$WATCHDOG_SCRIPT" ]]; then
        rm -f "$WATCHDOG_SCRIPT"
        log_info "监控脚本已删除"
    fi
}

# 查看监控状态
show_watchdog_status() {
    echo ""
    echo -e "${CYAN}=== 定时监控状态 ===${NC}"
    echo ""
    
    # 检查cron任务
    echo -e "${BLUE}Cron任务:${NC}"
    if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
        echo -e "  状态: ${GREEN}已启用${NC}"
        crontab -l 2>/dev/null | grep "$CRON_MARKER" | sed 's/^/  /'
    else
        echo -e "  状态: ${RED}未启用${NC}"
    fi
    echo ""
    
    # 检查监控脚本
    echo -e "${BLUE}监控脚本:${NC}"
    if [[ -f "$WATCHDOG_SCRIPT" ]]; then
        echo -e "  ${GREEN}存在${NC}: $WATCHDOG_SCRIPT"
    else
        echo -e "  ${RED}不存在${NC}"
    fi
    echo ""
    
    # 显示最近的日志
    echo -e "${BLUE}最近的监控日志:${NC}"
    if [[ -f /var/log/usque-watchdog.log ]]; then
        tail -10 /var/log/usque-watchdog.log | sed 's/^/  /'
    else
        echo "  (无日志)"
    fi
    echo ""
}

#===============================================================================
# 路由配置 - 仅IPv4通过WARP
#===============================================================================

setup_routes() {
    log_step "配置路由规则..."
    
    # 获取配置中的endpoint
    local endpoint_v4=$(grep -o '"endpoint_v4": "[^"]*"' "$CONFIG_FILE" | cut -d'"' -f4)
    local endpoint_v6=$(grep -o '"endpoint_v6": "[^"]*"' "$CONFIG_FILE" | cut -d'"' -f4)
    
    log_info "WARP端点IPv4: $endpoint_v4"
    log_info "WARP端点IPv6: $endpoint_v6"
    
    # 获取默认网关和接口
    local default_if=$(ip -6 route show default | awk '{print $5}' | head -1)
    local default_gw=$(ip -6 route show default | awk '{print $3}' | head -1)
    
    if [[ -z "$default_if" ]]; then
        # 如果没有IPv6默认路由，尝试获取第一个非lo接口
        default_if=$(ip link show | grep -E '^[0-9]+:' | grep -v 'lo:' | head -1 | awk -F: '{print $2}' | tr -d ' ')
    fi
    
    log_info "默认网络接口: $default_if"
    
    # 创建路由配置脚本
    cat > "${INSTALL_DIR}/setup-routes.sh" << 'ROUTE_SCRIPT'
#!/bin/bash

# 路由配置脚本
# 确保IPv6优先，IPv4通过WARP隧道

TUN_INTERFACE="${1:-warp0}"
ENDPOINT_V6="${2:-2606:4700:103::}"

# 等待TUN接口就绪
wait_for_interface() {
    local max_wait=30
    local count=0
    while [[ $count -lt $max_wait ]]; do
        if ip link show "$TUN_INTERFACE" &>/dev/null; then
            return 0
        fi
        sleep 1
        ((count++))
    done
    return 1
}

# 配置IPv4路由通过WARP
setup_ipv4_routes() {
    echo "[路由] 配置IPv4流量通过WARP隧道..."
    
    # 添加IPv4默认路由通过TUN接口
    # 使用较高的metric确保不影响其他路由
    ip route add default dev "$TUN_INTERFACE" metric 100 2>/dev/null || \
    ip route replace default dev "$TUN_INTERFACE" metric 100
    
    echo "[路由] IPv4默认路由已配置"
}

# 保持IPv6原生路由
ensure_ipv6_native() {
    echo "[路由] 确保IPv6使用原生路由..."
    
    # IPv6路由保持不变，因为我们没有添加IPv6的WARP路由
    # 系统将继续使用原生IPv6路由
    
    echo "[路由] IPv6将使用原生路由"
}

# 主逻辑
main() {
    echo "[路由] 等待TUN接口就绪..."
    if ! wait_for_interface; then
        echo "[路由] 错误: TUN接口未就绪"
        exit 1
    fi
    
    setup_ipv4_routes
    ensure_ipv6_native
    
    echo "[路由] 路由配置完成"
    echo "[路由] IPv4 -> WARP隧道 (${TUN_INTERFACE})"
    echo "[路由] IPv6 -> 原生路由"
}

main
ROUTE_SCRIPT

    chmod +x "${INSTALL_DIR}/setup-routes.sh"
    
    log_info "路由配置脚本已创建"
}

#===============================================================================
# 优化网络参数
#===============================================================================

optimize_network() {
    log_step "优化网络参数..."
    
    # 创建sysctl配置
    cat > /etc/sysctl.d/99-usque-warp.conf << 'SYSCTL_CONF'
# Usque WARP 网络优化

# 增加UDP缓冲区大小 (QUIC优化)
net.core.rmem_max = 7500000
net.core.wmem_max = 7500000
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576

# 增加netdev缓冲区
net.core.netdev_max_backlog = 5000

# 启用IP转发 (可选，如需要作为网关)
# net.ipv4.ip_forward = 1
# net.ipv6.conf.all.forwarding = 1

# 优化TCP参数 (适用于高延迟连接)
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# 优化连接跟踪
net.netfilter.nf_conntrack_max = 131072
SYSCTL_CONF

    # 应用配置
    sysctl -p /etc/sysctl.d/99-usque-warp.conf 2>/dev/null || true
    
    log_info "网络参数已优化"
}

#===============================================================================
# Systemd服务配置
#===============================================================================

create_systemd_service() {
    local force_ipv6="${1:-false}"
    
    log_step "创建Systemd服务..."
    
    local connect_flag=""
    
    # 如果明确指定为IPv6-only环境，直接使用-6参数
    if [[ "$force_ipv6" == "true" ]]; then
        log_info "使用IPv6连接WARP端点 (由安装流程指定)"
        connect_flag="-6"
    else
        # 检测VPS的网络环境，决定使用IPv4还是IPv6连接WARP
        # 注意：排除warp0接口的路由，只检查原生路由
        local has_native_ipv4_route=$(ip -4 route show default 2>/dev/null | grep -v "dev ${TUN_INTERFACE}" | grep "^default" | head -1)
        local has_ipv6_route=$(ip -6 route show default 2>/dev/null | grep "^default" | head -1)
        
        if [[ -z "$has_native_ipv4_route" ]] && [[ -n "$has_ipv6_route" ]]; then
            log_info "检测到IPv6-only环境，将使用IPv6连接WARP端点"
            connect_flag="-6"
        elif [[ -n "$has_native_ipv4_route" ]]; then
            log_info "检测到原生IPv4网络，将使用IPv4连接WARP端点"
            connect_flag=""
        else
            log_warn "无法检测网络环境，默认使用IPv6连接"
            connect_flag="-6"
        fi
    fi
    
    # 创建服务文件
    # 参数说明:
    #   -6: 使用IPv6连接WARP端点 (IPv6-only VPS需要)
    #   -S/--no-tunnel-ipv6: 隧道内禁用IPv6 (只使用IPv4通过WARP)
    #   -n/--interface-name: 指定TUN接口名称
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Usque WARP MASQUE Tunnel
Documentation=https://github.com/Diniboy1123/usque
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStartPre=/sbin/modprobe tun
ExecStart=${BINARY_PATH} -c ${CONFIG_FILE} nativetun ${connect_flag} -S -n ${TUN_INTERFACE}
ExecStartPost=${INSTALL_DIR}/setup-routes.sh ${TUN_INTERFACE}
Restart=always
RestartSec=5
LimitNOFILE=1048576

# 安全加固
NoNewPrivileges=no
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${INSTALL_DIR}
PrivateTmp=true

# 环境变量
Environment="HOME=${INSTALL_DIR}"

[Install]
WantedBy=multi-user.target
EOF

    # 重载systemd
    systemctl daemon-reload
    
    log_info "Systemd服务已创建: $SERVICE_NAME"
}

enable_service() {
    log_step "启用并启动服务..."
    
    systemctl enable "$SERVICE_NAME"
    log_info "服务已设置为开机自启"
    
    systemctl start "$SERVICE_NAME"
    
    # 等待服务启动
    sleep 3
    
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_info "服务启动成功"
        systemctl status "$SERVICE_NAME" --no-pager
    else
        log_error "服务启动失败"
        journalctl -u "$SERVICE_NAME" -n 20 --no-pager
        exit 1
    fi
}

#===============================================================================
# 测试连接
#===============================================================================

test_connection() {
    log_step "测试IPv4连接..."
    
    # 等待隧道稳定
    sleep 2
    
    # 测试IPv4连通性
    log_info "测试IPv4连接 (通过WARP)..."
    
    local test_urls=(
        "https://cloudflare.com/cdn-cgi/trace"
        "https://1.1.1.1/cdn-cgi/trace"
        "https://ifconfig.me"
    )
    
    local success=false
    
    for url in "${test_urls[@]}"; do
        log_info "测试: $url"
        if curl -4 -s --connect-timeout 10 --max-time 15 "$url" 2>/dev/null; then
            echo ""
            success=true
            break
        fi
    done
    
    if $success; then
        log_info "IPv4连接测试成功!"
    else
        log_warn "IPv4连接测试失败，可能需要等待隧道稳定"
    fi
    
    # 测试IPv6连通性（应该使用原生）
    log_info "测试IPv6连接 (原生)..."
    if curl -6 -s --connect-timeout 10 --max-time 15 "https://ipv6.google.com" &>/dev/null; then
        log_info "IPv6原生连接正常"
    else
        log_warn "IPv6连接可能有问题"
    fi
    
    # 显示路由信息
    echo ""
    log_info "当前路由表:"
    echo "--- IPv4 路由 ---"
    ip -4 route show | head -10
    echo ""
    echo "--- IPv6 路由 ---"
    ip -6 route show | head -10
}

#===============================================================================
# 卸载功能
#===============================================================================

uninstall() {
    log_step "开始卸载Usque WARP..."
    
    echo ""
    echo -e "${CYAN}=== 将要清理的内容 ===${NC}"
    echo "  1. 定时监控: cron任务、watchdog脚本、日志文件"
    echo "  2. Systemd服务: ${SERVICE_NAME}"
    echo "  3. 网络配置: TUN接口(${TUN_INTERFACE})、路由规则"
    echo "  4. 系统配置: sysctl优化、模块加载配置"
    echo "  5. 安装目录: ${INSTALL_DIR} (可选)"
    echo ""
    
    if ! confirm_action "确定要卸载Usque WARP吗? 这将删除所有相关文件和配置"; then
        log_info "取消卸载"
        return
    fi
    
    echo ""
    log_info "开始清理..."
    
    # ===== 1. 移除定时监控任务 =====
    log_info "[1/5] 清理定时监控..."
    
    # 移除cron任务
    if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
        crontab -l 2>/dev/null | grep -v "$CRON_MARKER" | grep -v "$WATCHDOG_SCRIPT" | crontab -
        log_info "  - 已移除cron定时任务"
    fi
    
    # 删除watchdog脚本
    if [[ -f "$WATCHDOG_SCRIPT" ]]; then
        rm -f "$WATCHDOG_SCRIPT"
        log_info "  - 已删除watchdog脚本: $WATCHDOG_SCRIPT"
    fi
    
    # 删除watchdog日志
    if [[ -f /var/log/usque-watchdog.log ]]; then
        rm -f /var/log/usque-watchdog.log
        log_info "  - 已删除watchdog日志"
    fi
    if [[ -f /var/log/usque-watchdog.log.old ]]; then
        rm -f /var/log/usque-watchdog.log.old
        log_info "  - 已删除watchdog旧日志"
    fi
    
    # ===== 2. 停止并禁用服务 =====
    log_info "[2/5] 清理Systemd服务..."
    
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME"
        log_info "  - 已停止服务"
    fi
    
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl disable "$SERVICE_NAME"
        log_info "  - 已禁用服务"
    fi
    
    if [[ -f "$SERVICE_FILE" ]]; then
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        log_info "  - 已删除服务文件: $SERVICE_FILE"
    fi
    
    # ===== 3. 清理网络配置 =====
    log_info "[3/5] 清理网络配置..."
    
    # 删除TUN接口
    if ip link show "$TUN_INTERFACE" &>/dev/null; then
        ip link set "$TUN_INTERFACE" down 2>/dev/null || true
        ip link delete "$TUN_INTERFACE" 2>/dev/null || true
        log_info "  - 已删除TUN接口: $TUN_INTERFACE"
    fi
    
    # 清理路由规则（以防万一）
    ip route del default dev "$TUN_INTERFACE" 2>/dev/null || true
    
    # ===== 4. 清理系统配置 =====
    log_info "[4/5] 清理系统配置..."
    
    # 删除sysctl配置
    if [[ -f /etc/sysctl.d/99-usque-warp.conf ]]; then
        rm -f /etc/sysctl.d/99-usque-warp.conf
        sysctl --system &>/dev/null || true
        log_info "  - 已删除sysctl配置"
    fi
    
    # 删除modules配置
    if [[ -f /etc/modules-load.d/usque-tun.conf ]]; then
        rm -f /etc/modules-load.d/usque-tun.conf
        log_info "  - 已删除模块加载配置"
    fi
    
    # ===== 5. 删除安装目录 =====
    log_info "[5/5] 处理安装目录..."
    
    if [[ -d "$INSTALL_DIR" ]]; then
        echo ""
        echo -e "${YELLOW}安装目录包含以下内容:${NC}"
        ls -la "$INSTALL_DIR" 2>/dev/null | sed 's/^/  /'
        echo ""
        
        if confirm_action "是否删除安装目录和所有配置文件 ($INSTALL_DIR)?"; then
            rm -rf "$INSTALL_DIR"
            log_info "  - 已删除安装目录: $INSTALL_DIR"
        else
            log_info "  - 保留安装目录: $INSTALL_DIR"
            log_warn "  注意: 配置文件和备份仍保留在 $INSTALL_DIR"
        fi
    fi
    
    echo ""
    log_info "=========================================="
    log_info "卸载完成!"
    log_info "=========================================="
    echo ""
    echo -e "${GREEN}已清理的内容:${NC}"
    echo "  ✓ cron定时任务"
    echo "  ✓ watchdog监控脚本和日志"
    echo "  ✓ systemd服务 ($SERVICE_NAME)"
    echo "  ✓ TUN网络接口 ($TUN_INTERFACE)"
    echo "  ✓ sysctl网络优化配置"
    echo "  ✓ TUN模块自动加载配置"
    if [[ ! -d "$INSTALL_DIR" ]]; then
        echo "  ✓ 安装目录 ($INSTALL_DIR)"
    else
        echo "  - 安装目录已保留 ($INSTALL_DIR)"
    fi
    echo ""
    log_info "VPS已恢复到安装前状态"
}

#===============================================================================
# 状态查看
#===============================================================================

show_status() {
    echo ""
    echo -e "${CYAN}=== Usque WARP 状态 ===${NC}"
    echo ""
    
    # 服务状态
    echo -e "${BLUE}服务状态:${NC}"
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "  状态: ${GREEN}运行中${NC}"
        echo -e "  启动时间: $(systemctl show -p ActiveEnterTimestamp $SERVICE_NAME --value)"
    else
        echo -e "  状态: ${RED}未运行${NC}"
    fi
    echo ""
    
    # 接口状态
    echo -e "${BLUE}TUN接口:${NC}"
    if ip link show "$TUN_INTERFACE" &>/dev/null; then
        echo -e "  ${GREEN}$TUN_INTERFACE${NC}:"
        ip addr show "$TUN_INTERFACE" 2>/dev/null | grep -E "inet|link" | sed 's/^/    /'
    else
        echo -e "  ${RED}接口不存在${NC}"
    fi
    echo ""
    
    # 配置信息
    echo -e "${BLUE}配置信息:${NC}"
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "  配置文件: $CONFIG_FILE"
        local ipv4=$(grep -o '"ipv4": "[^"]*"' "$CONFIG_FILE" | cut -d'"' -f4)
        local ipv6=$(grep -o '"ipv6": "[^"]*"' "$CONFIG_FILE" | cut -d'"' -f4)
        local license=$(jq -r '.license // "无"' "$CONFIG_FILE" 2>/dev/null)
        local endpoint_v4=$(jq -r '.endpoint_v4 // empty' "$CONFIG_FILE" 2>/dev/null)
        echo "  内部IPv4: $ipv4"
        echo "  内部IPv6: $ipv6"
        echo "  许可证: $license"
        echo "  Endpoint (v4配置): $endpoint_v4"
    else
        echo -e "  ${RED}配置文件不存在${NC}"
    fi
    echo ""
    
    # 网络环境
    echo -e "${BLUE}网络环境:${NC}"
    # 检测原生网络环境（排除warp0接口）
    local has_native_ipv4=$(ip -4 route show default 2>/dev/null | grep -v "dev ${TUN_INTERFACE}" | head -1)
    if [[ -z "$has_native_ipv4" ]]; then
        echo -e "  ${YELLOW}IPv6-only环境${NC} (原生无IPv4路由)"
    else
        echo "  双栈或IPv4环境 (原生有IPv4路由)"
    fi
    echo ""
    
    # 连接测试
    echo -e "${BLUE}连接测试:${NC}"
    echo -n "  IPv4 (WARP): "
    if curl -4 -s --connect-timeout 5 --max-time 10 "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null | grep -q "warp="; then
        local warp_status=$(curl -4 -s --connect-timeout 5 --max-time 10 "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null | grep "warp=")
        echo -e "${GREEN}连接正常${NC} ($warp_status)"
    else
        echo -e "${RED}连接失败${NC}"
    fi
    
    echo -n "  IPv6 (原生): "
    if curl -6 -s --connect-timeout 5 --max-time 10 "https://ipv6.google.com" &>/dev/null; then
        echo -e "${GREEN}连接正常${NC}"
    else
        echo -e "${YELLOW}无法连接${NC}"
    fi
    echo ""
    
    # 定时监控状态
    echo -e "${BLUE}定时监控:${NC}"
    if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
        echo -e "  ${GREEN}已启用${NC} (每5分钟检测)"
    else
        echo -e "  ${YELLOW}未启用${NC}"
    fi
    echo ""
}

#===============================================================================
# 主菜单
#===============================================================================

show_menu() {
    echo ""
    echo -e "${CYAN}请选择操作:${NC}"
    echo ""
    echo -e "  ${GREEN}基础功能${NC}"
    echo "  1) 完整安装 (推荐首次使用)"
    echo "  2) 仅下载/更新二进制文件"
    echo "  3) 仅注册WARP账号"
    echo "  4) 配置Systemd服务"
    echo ""
    echo -e "  ${GREEN}新增功能${NC}"
    echo "  5) 修复IPv6-only环境 (修改endpoint)"
    echo "  6) 启用WARP+ (输入密钥)"
    echo "  7) 设置定时监控 (每5分钟检测)"
    echo "  8) 移除定时监控"
    echo ""
    echo -e "  ${GREEN}运维功能${NC}"
    echo "  9) 测试连接"
    echo " 10) 查看状态"
    echo " 11) 重启服务"
    echo " 12) 查看日志"
    echo " 13) 查看监控日志"
    echo " 14) 卸载"
    echo ""
    echo "  0) 退出"
    echo ""
    read -p "请输入选项 [0-14]: " choice
    
    case $choice in
        1) full_install ;;
        2) download_usque ;;
        3) register_warp ;;
        4) 
            setup_routes
            create_systemd_service
            enable_service
            ;;
        5) 
            fix_endpoint_for_ipv6_only
            if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
                if confirm_action "是否重启服务以应用更改?" "y"; then
                    systemctl restart "$SERVICE_NAME"
                    sleep 3
                    test_connection
                fi
            fi
            ;;
        6) activate_warp_plus ;;
        7) setup_watchdog_cron ;;
        8) remove_watchdog_cron ;;
        9) test_connection ;;
        10) show_status ;;
        11) 
            systemctl restart "$SERVICE_NAME"
            sleep 2
            show_status
            ;;
        12) journalctl -u "$SERVICE_NAME" -n 50 --no-pager ;;
        13) show_watchdog_status ;;
        14) uninstall ;;
        0) 
            log_info "再见!"
            exit 0
            ;;
        *)
            log_error "无效选项"
            ;;
    esac
}

#===============================================================================
# 完整安装流程
#===============================================================================

full_install() {
    log_step "开始完整安装流程..."
    echo ""
    
    # 0. 首先停止并清理可能存在的旧服务（确保网络检测准确）
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_warn "检测到旧的WARP服务正在运行，先停止..."
        systemctl stop "$SERVICE_NAME"
        sleep 2
    fi
    # 删除可能存在的warp0接口
    if ip link show "$TUN_INTERFACE" &>/dev/null; then
        log_warn "删除旧的TUN接口..."
        ip link delete "$TUN_INTERFACE" 2>/dev/null || true
        sleep 1
    fi
    echo ""
    
    # 1. 检测网络环境（在安装任何东西之前，且确保没有warp0干扰）
    local is_ipv6_only_env=false
    if check_network_environment; then
        is_ipv6_only_env=true
        echo ""
        log_info "将执行以下IPv6-only专用操作:"
        log_info "  • 自动使用支持IPv6的镜像下载"
        log_info "  • 注册后修复endpoint配置"
        log_info "  • 使用 -6 参数启动服务"
    fi
    echo ""
    
    # 2. 安装依赖
    install_dependencies
    echo ""
    
    # 3. 检查TUN支持
    check_tun_support
    ensure_tun_on_boot
    echo ""
    
    # 4. 下载二进制文件（IPv6-only时自动使用gh-proxy）
    download_usque "$is_ipv6_only_env"
    echo ""
    
    # 5. 注册WARP
    register_warp
    echo ""
    
    # 6. 【关键】立即修复IPv6-only环境的endpoint（在启动服务之前！）
    if [[ "$is_ipv6_only_env" == "true" ]]; then
        log_info "══════════════════════════════════════════════════"
        log_info "IPv6-only环境: 修复endpoint配置"
        log_info "══════════════════════════════════════════════════"
        fix_endpoint_for_ipv6_only
        echo ""
    fi
    
    # 7. 配置路由
    setup_routes
    echo ""
    
    # 8. 优化网络
    optimize_network
    echo ""
    
    # 9. 创建并启动服务（传递IPv6-only状态，确保使用正确的连接参数）
    create_systemd_service "$is_ipv6_only_env"
    enable_service
    echo ""
    
    # 10. 测试连接
    test_connection
    echo ""
    
    # 11. 询问是否启用定时监控
    echo ""
    if confirm_action "是否启用定时监控 (每5分钟检测IPv4连通性并自动重启)?" "y"; then
        setup_watchdog_cron
    fi
    echo ""
    
    log_info "安装完成!"
    echo ""
    echo -e "${GREEN}=== 安装摘要 ===${NC}"
    echo "  安装目录: $INSTALL_DIR"
    echo "  配置文件: $CONFIG_FILE"
    echo "  服务名称: $SERVICE_NAME"
    echo "  TUN接口: $TUN_INTERFACE"
    if [[ "$is_ipv6_only_env" == "true" ]]; then
        echo -e "  网络环境: ${YELLOW}IPv6-only (已修复endpoint，使用-6参数)${NC}"
    else
        echo "  网络环境: 双栈或IPv4"
    fi
    echo ""
    echo -e "${YELLOW}常用命令:${NC}"
    echo "  查看状态: systemctl status $SERVICE_NAME"
    echo "  查看日志: journalctl -u $SERVICE_NAME -f"
    echo "  重启服务: systemctl restart $SERVICE_NAME"
    echo "  停止服务: systemctl stop $SERVICE_NAME"
    echo ""
    echo -e "${YELLOW}新增功能:${NC}"
    echo "  启用WARP+: 运行脚本选择菜单项 6"
    echo "  定时监控: 运行脚本选择菜单项 7"
    echo ""
    echo -e "${YELLOW}流量路由:${NC}"
    echo "  IPv4流量 -> 通过WARP隧道 (共享IP，存在风险)"
    echo "  IPv6流量 -> 使用原生路由 (优先，更安全)"
    echo ""
}

#===============================================================================
# 主程序入口
#===============================================================================

main() {
    print_banner
    check_root
    
    # 解析命令行参数
    case "${1:-}" in
        install|--install|-i)
            full_install
            ;;
        uninstall|--uninstall|-u)
            uninstall
            ;;
        status|--status|-s)
            show_status
            ;;
        test|--test|-t)
            test_connection
            ;;
        fix-ipv6|--fix-ipv6)
            fix_endpoint_for_ipv6_only
            ;;
        warp-plus|--warp-plus|-p)
            activate_warp_plus
            ;;
        watchdog-on|--watchdog-on)
            setup_watchdog_cron
            ;;
        watchdog-off|--watchdog-off)
            remove_watchdog_cron
            ;;
        watchdog-status|--watchdog-status)
            show_watchdog_status
            ;;
        *)
            # 交互式菜单
            while true; do
                show_menu
                echo ""
                read -p "按Enter继续..."
            done
            ;;
    esac
}

# 运行主程序
main "$@"
