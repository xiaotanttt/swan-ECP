#!/bin/bash
set -eo pipefail

# ==================== 全局配置 ====================
VERSION="3.1.0"                         # 脚本版本
LOG_FILE="ecp_install.log"              # 安装日志
DEFAULT_CP_PATH="$HOME/swan_ecp"        # 默认配置目录
MIN_STORAGE=200                         # 最小存储(GB)
ECP_VERSION="v1.0.2"                    # ECP版本
ZK_TOTAL_SIZE=214748364800              # 200GB (200*1024^3)
SWAN_CONTRACT="0xBb4eC1b56cB624863298740Fd264ef2f910d5564" # SWAN合约地址

# ==================== 颜色定义 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== 功能函数 ====================
error() { echo -e "${RED}[✗] $*${NC}" >&2; exit 1; }
warn() { echo -e "${YELLOW}[!] $*${NC}" >&2; }
info() { echo -e "${GREEN}[✓] $*${NC}" >&2; }
title() { clear; echo -e "${BLUE}\n▓ SwanChain ECP 管理套件 v${VERSION} ▓${NC}"; }

# ==================== 存储检查 ====================
check_storage() {
    local path="$1"
    local available=$(df -BG "$path" | awk 'NR==2 {print $4}' | tr -d 'G')

    if [ "$available" -lt "$MIN_STORAGE" ]; then
        error "存储空间不足！需要至少 ${MIN_STORAGE}GB，当前可用 ${available}GB"
    fi
    info "存储空间检查通过：可用 ${available}GB"
}

# ==================== 钱包管理 ====================
wallet_setup() {
    title
    local wallet_file="${CP_PATH}/.wallet_address"
    
    # 检测现有钱包
    if [ -f "$wallet_file" ]; then
        local existing=$(cat "$wallet_file")
        warn "检测到已有钱包地址: ${existing}"
        read -p "是否创建新钱包？[y/N]: " choice
        [[ "$choice" =~ ^[Yy] ]] || return
    fi

    PS3="请选择钱包操作: "
    select opt in "创建新钱包" "导入私钥" "返回主菜单"; do
        case $opt in
            "创建新钱包")
                create_wallet
                break ;;
            "导入私钥")
                import_wallet
                break ;;
            *) main_menu ;;
        esac
    done

    validate_wallet || error "钱包验证失败"
}

create_wallet() {
    info "正在生成新钱包..."
    local output=$("./computing-provider" --repo "$CP_PATH" wallet new)
    WALLET_ADDRESS=$(grep -oE '0x[a-fA-F0-9]{40}' <<< "$output")
    local private_key=$(grep 'Private Key' <<< "$output" | cut -d: -f2 | tr -d ' ')
    
    echo "$output" | tee "${CP_PATH}/${WALLET_ADDRESS}.key" >/dev/null
    echo "$WALLET_ADDRESS" > "${CP_PATH}/.wallet_address"
    chmod 600 "${CP_PATH}/${WALLET_ADDRESS}.key"
    
    info "地址: ${WALLET_ADDRESS}"
    warn "请妥善保管私钥: ${private_key}"
}

import_wallet() {
    read -sp "请输入私钥 (0x前缀可选): " key
    key=${key#0x}
    echo
    
    [[ "$key" =~ ^[a-fA-F0-9]{64}$ ]] || error "无效私钥格式"
    
    WALLET_ADDRESS=$(echo "$key" | "./computing-provider" --repo "$CP_PATH" wallet import | grep -oE '0x[a-fA-F0-9]{40}')
    echo "$WALLET_ADDRESS" > "${CP_PATH}/.wallet_address"
    info "导入成功! 地址: ${WALLET_ADDRESS}"
}

validate_wallet() {
    [ -n "$WALLET_ADDRESS" ] && [[ "$WALLET_ADDRESS" =~ ^0x[a-fA-F0-9]{40}$ ]]
}

# ==================== 账户初始化 ====================
init_account() {
    info "正在初始化ECP账户..."
    local wallet=$(get_wallet_address)
    
    echo -e "\n${BLUE}账户配置预览："
    echo -e "Owner地址: ${wallet}"
    echo -e "Worker地址: ${wallet}"
    echo -e "收益地址: ${wallet}"
    echo -e "任务类型: 1,2,4 (Fil-C2, Mining, Inference)${NC}"
    
    read -p "是否使用默认配置？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        read -p "输入自定义Owner地址: " custom_owner
        read -p "输入自定义Worker地址: " custom_worker
        read -p "输入自定义收益地址: " custom_beneficiary
        
        validate_address "$custom_owner"
        validate_address "$custom_worker"
        validate_address "$custom_beneficiary"
        
        wallet="$custom_owner"
    fi

    "$CP_PATH/computing-provider" --repo "$CP_PATH" account create \
        --ownerAddress "${custom_owner:-$wallet}" \
        --workerAddress "${custom_worker:-$wallet}" \
        --beneficiaryAddress "${custom_beneficiary:-$wallet}" \
        --task-types 1,2,4 || error "账户初始化失败"
}

validate_address() {
    [[ "$1" =~ ^0x[a-fA-F0-9]{40}$ ]] || error "无效地址格式: $1"
}

# ==================== 经济功能 ====================
stake_swan() {
    local wallet=$(get_wallet_address)
    title
    info "当前质押余额: $(./computing-provider --repo "$CP_PATH" collateral info)"
    
    while true; do
        read -p "输入质押SWAN数量 (e.g. 1000): " amount
        [[ "$amount" =~ ^[0-9]+$ ]] && break
        warn "请输入有效整数"
    done
    
    info "正在质押..."
    tx=$(./computing-provider --repo "$CP_PATH" collateral add --ecp --from "$wallet" "$amount" | grep TxHash | awk '{print $2}')
    info "质押成功! 交易哈希: ${tx:-\"需查看日志\"}"
}

deposit_sequencer() {
    local wallet=$(get_wallet_address)
    title
    info "当前Sequencer余额: $(./computing-provider --repo "$CP_PATH" sequencer info)"
    
    while true; do
        read -p "输入存款金额(ETH, e.g. 1): " amount
        [[ "$amount" =~ ^[0-9.]+$ ]] && break
        warn "请输入有效数字"
    done
    
    info "正在存款..."
    tx=$(./computing-provider --repo "$CP_PATH" sequencer add --from "$wallet" "$amount" | grep TxHash | awk '{print $2}')
    info "存款成功! 交易哈希: ${tx:-\"需查看日志\"}"
}

get_wallet_address() {
    [ -f "${CP_PATH}/.wallet_address" ] && cat "${CP_PATH}/.wallet_address" || error "未找到钱包地址"
}

# ==================== ZK下载管理 ====================
zk_progress() {
    local current=$(du -sb "$PARENT_PATH" 2>/dev/null | cut -f1)
    local percent=$(( current*100/ZK_TOTAL_SIZE ))
    echo -ne "下载进度: ["
    for ((i=0; i<50; i++)); do
        [ $i -lt $((percent/2)) ] && echo -n '#' || echo -n '-'
    done
    echo -e "] ${percent}% ($(numfmt --to=iec $current)/$(numfmt --to=iec $ZK_TOTAL_SIZE))"
}

download_zk_params() {
    mkdir -p "$PARENT_PATH"
    check_storage "$PARENT_PATH"
    
    info "开始下载ZK参数 (约200GB)..."
    (
        info "下载512MiB参数..."
        curl -#C - -fSL https://raw.githubusercontent.com/swanchain/go-computing-provider/releases/ubi/fetch-param-512.sh | bash
        
        info "下载32GiB参数..."
        curl -#C - -fSL https://raw.githubusercontent.comswanchain/go-computing-provider/releases/ubi/fetch-param-32.sh | bash
    ) >> "$LOG_FILE" 2>&1 &
    
    info "后台下载进程PID: $! 输入 tail -f $LOG_FILE 查看详情"
}

# ==================== 服务管理 ====================
service_manager() {
    case $1 in
        start)
            info "启动节点服务..."
            export RUST_GPU_TOOLS_CUSTOM_GPU=$(get_gpu_info)
            nohup ./computing-provider --repo "$CP_PATH" ubi daemon >> "$CP_PATH/cp.log" 2>&1 &
            sleep 3
            check_service_running || error "启动失败，请检查日志"
            ;;
        stop)
            info "停止节点服务..."
            pkill -f "computing-provider" && info "服务已停止" || warn "服务未运行"
            ;;
        restart) 
            service_manager stop
            service_manager start
            ;;
    esac
}

# ==================== 主安装流程 ====================
main_install() {
    title
    info "开始ECP节点安装"
    
    # 配置路径
    read -p "输入配置路径 [默认: $DEFAULT_CP_PATH]: " CP_PATH
    export CP_PATH=${CP_PATH:-$DEFAULT_CP_PATH}
    mkdir -p "$CP_PATH"
    
    # 依赖安装
    info "安装系统依赖..."
    curl -fsSL https://raw.githubusercontent.com/swanchain/go-computing-provider/releases/ubi/setup.sh | bash
    
    # 下载核心程序
    info "下载ECP核心..."
    wget -qc "https://github.com/swanchain/go-computing-provider/releases/download/${ECP_VERSION}/computing-provider" -O "$CP_PATH/computing-provider"
    chmod +x "$CP_PATH/computing-provider"
    
    # ZK参数下载
    read -p "ZK参数存储路径 [默认: $HOME/zk_params]: " PARENT_PATH
    export PARENT_PATH=${PARENT_PATH:-$HOME/zk_params}
    export FIL_PROOFS_PARAMETER_CACHE="$PARENT_PATH"
    download_zk_params
    
    # 节点初始化
    info "节点初始化..."
    read -p "公网IP地址: " ip
    read -p "节点名称: " name
    "$CP_PATH/computing-provider" --repo "$CP_PATH" init --multi-address="/ip4/$ip/tcp/9085" --node-name="$name"
    
    # 账户配置
    wallet_setup
    init_account
    
    # 经济配置
    stake_swan
    deposit_sequencer
    
    info "安装完成! 输入 ./ecp.sh 启动管理菜单"
}

# ==================== 主菜单 ====================
main_menu() {
    while :; do
        title
        echo -e "服务状态: $(check_service_running && echo -e "${GREEN}运行中" || echo -e "${RED}已停止")${NC}"
        echo -e "${BLUE}[1] 启动节点   [2] 停止节点   [3] 重启节点"
        echo -e "[4] 质押SWAN   [5] Sequencer存款"
        echo -e "[6] 节点信息   [7] ZK下载进度  [8] 实时日志"
        echo -e "[9] 钱包管理   [0] 退出系统${NC}"
        
        read -p "请输入选项: " choice
        case $choice in
            1) service_manager start ;;
            2) service_manager stop ;;
            3) service_manager restart ;;
            4) stake_swan ;;
            5) deposit_sequencer ;;
            6) show_node_info ;;
            7) zk_progress ;;
            8) show_logs ;;
            9) wallet_setup ;;
            0) exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
        read -p "按回车继续..."
    done
}

# ==================== 辅助函数 ====================
check_service_running() { pgrep -f "computing-provider" >/dev/null; }
get_gpu_info() {
    local gpu_info=$(nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader | head -n1)
    [ -n "$gpu_info" ] && echo "${gpu_info%,*}" | tr ' ' '_' || echo "CPU"
}
show_node_info() { ./computing-provider --repo "$CP_PATH" info; }
show_logs() { tail -f "$CP_PATH/cp.log"; }

# ==================== 执行入口 ====================
if [ $# -eq 0 ]; then
    [ -f "$CP_PATH/computing-provider" ] && main_menu || main_install
else
    case $1 in
        install) main_install ;;
        start|stop|restart) service_manager "$1" ;;
        *) error "未知参数: $1" ;;
    esac
fi