#!/bin/bash
set -eo pipefail

# ==================== 全局配置 ====================
VERSION="5.0.0"                         # 脚本版本
LOG_FILE="ecp_install.log"              # 安装日志
DEFAULT_CP_PATH="$HOME/swan_ecp"        # 默认配置目录
MIN_STORAGE=200                         # 最小存储(GB)
ECP_VERSION="v1.0.2"                    # ECP版本
ZK_TOTAL_SIZE=214748364800              # 200GB (200*1024^3)

# ==================== 颜色定义 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==================== 功能函数 ====================
error() { echo -e "${RED}[✗] $*${NC}" >&2; exit 1; }
warn() { echo -e "${YELLOW}[!] $*${NC}" >&2; }
info() { echo -e "${GREEN}[✓] $*${NC}" >&2; }
title() { clear; echo -e "${BLUE}\n▓ SwanChain ECP 管理套件 v${VERSION} ▓${NC}"; }

# ==================== 交易处理增强 ====================
execute_transaction() {
    local command="$1"
    local success_msg="$2"
    local error_msg="$3"
    local temp_file="/tmp/tx_output_$$.tmp"

    # 执行命令并捕获输出
    if ! eval "$command" 2>&1 | tee "$temp_file"; then
        rm -f "$temp_file"
        error "$error_msg"
    fi

    # 提取交易哈希
    local tx_hash=$(grep -oE 'TxHash: 0x[a-fA-F0-9]{64}' "$temp_file" | cut -d' ' -f2)
    [ -z "$tx_hash" ] && tx_hash=$(grep -oE 'transaction hash: 0x[a-fA-F0-9]{64}' "$temp_file" | cut -d' ' -f3)
    
    rm -f "$temp_file"

    if [ -n "$tx_hash" ]; then
        echo -e "\n${CYAN}交易哈希: ${YELLOW}$tx_hash${NC}"
        echo -e "${CYAN}区块浏览器: ${YELLOW}https://swanscan.io/tx/$tx_hash${NC}"
    else
        warn "未找到交易哈希，请查看日志: ${LOG_FILE}"
    fi
    
    info "$success_msg"
}

# ==================== 质押功能增强 ====================
stake_swan() {
    title
    local wallet=$(get_wallet_address)
    info "当前质押余额: $(./computing-provider --repo "$CP_PATH" collateral info)"
    
    while true; do
        read -p "输入质押SWAN数量 (整数): " amount
        [[ "$amount" =~ ^[0-9]+$ ]] && break
        warn "请输入有效整数"
    done
    
    execute_transaction \
        "./computing-provider --repo \"$CP_PATH\" collateral add --ecp --from \"$wallet\" \"$amount\"" \
        "质押 ${amount} SWAN 成功" \
        "质押操作失败"
}

# ==================== 存款功能增强 ====================
deposit_sequencer() {
    title
    local wallet=$(get_wallet_address)
    info "当前Sequencer余额: $(./computing-provider --repo "$CP_PATH" sequencer info)"
    
    while true; do
        read -p "输入存款金额 (ETH，支持小数): " amount
        [[ "$amount" =~ ^[0-9]+(\.[0-9]+)?$ ]] && break
        warn "请输入有效数字"
    done
    
    execute_transaction \
        "./computing-provider --repo \"$CP_PATH\" sequencer add --from \"$wallet\" \"$amount\"" \
        "存款 ${amount} ETH 成功" \
        "存款操作失败"
}

# ==================== 钱包地址获取 ====================
get_wallet_address() {
    local wallet_file="${CP_PATH}/.wallet_address"
    [ -f "$wallet_file" ] && cat "$wallet_file" || error "未找到钱包地址，请先配置钱包"
}

# ==================== 其他保持一致的核心函数 ====================
# 注意：以下保持与先前提供的钱包管理、节点初始化等功能一致
# 包括：check_storage, wallet_setup, init_account, download_zk_params 等
# 因篇幅限制此处省略重复代码，实际脚本需包含完整功能

# ==================== 主菜单 ====================
main_menu() {
    while :; do
        title
        echo -e "服务状态: $(check_service_running && echo -e "${GREEN}运行中" || echo -e "${RED}已停止")${NC}"
        echo -e "${BLUE}[1] 启动节点   [2] 停止节点   [3] 经济操作"
        echo -e "[4] 节点信息   [5] ZK参数管理  [6] 实时日志"
        echo -e "[7] 钱包管理   [0] 退出系统${NC}"
        
        read -p "请输入选项: " choice
        case $choice in
            1) start_node ;;
            2) stop_node ;;
            3) economic_menu ;;
            4) show_node_info ;;
            5) zk_menu ;;
            6) show_logs ;;
            7) wallet_management ;;
            0) exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
        read -p "按回车继续..."
    done
}

# ==================== 经济操作子菜单 ====================
economic_menu() {
    while :; do
        title
        echo -e "${BLUE}===== 经济操作管理 ====="
        echo -e "[1] 质押 SWAN       [2] 存入 Sequencer"
        echo -e "[3] 查看质押信息    [4] 查看存款余额"
        echo -e "[0] 返回主菜单${NC}"
        
        read -p "请输入选项: " choice
        case $choice in
            1) stake_swan ;;
            2) deposit_sequencer ;;
            3) show_collateral ;;
            4) show_sequencer ;;
            0) break ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

# ==================== 辅助函数 ====================
show_collateral() {
    ./computing-provider --repo "$CP_PATH" collateral info
    read -p "按回车继续..."
}

show_sequencer() {
    ./computing-provider --repo "$CP_PATH" sequencer info
    read -p "按回车继续..."
}

# ==================== 执行入口 ====================
if [ $# -eq 0 ]; then
    [ -f "$CP_PATH/computing-provider" ] && main_menu || main_install
else
    case $1 in
        install) main_install ;;
        *) error "未知参数: $1" ;;
    esac
fi