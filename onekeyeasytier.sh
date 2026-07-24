#!/bin/bash

# --- 脚本配置 ---
GITHUB_PROXY="ghfast.top"

# 颜色定义
GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

# --- 平台无关路径和文件名 ---
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/easytier"
CONFIG_FILE="${CONFIG_DIR}/easytier.toml"
CORE_BINARY_NAME="easytier-core"
CLI_BINARY_NAME="easytier-cli"
ALIAS_PATH="/usr/local/bin/et"

# --- 平台特定变量 (将在 main 函数中设置) ---
OS_TYPE=""
SERVICE_FILE=""
SERVICE_LABEL="com.easytier.core"
SERVICE_NAME="easytier"
LOG_FILE="/var/log/easytier.log"

# --- Web 组件变量 ---
WEB_BINARY_NAME="easytier-web-embed"
WEB_CONFIG_DIR="${CONFIG_DIR}/web"
WEB_DB_FILE="${WEB_CONFIG_DIR}/et.db"
WEB_SERVICE_NAME="easytier-web"
WEB_SERVICE_FILE=""
WEB_SERVICE_LABEL="com.easytier.web"
WEB_LOG_FILE="/var/log/easytier-web.log"
WEB_CONFIG_FILE="${CONFIG_DIR}/easytier-web.env"
# Core 连接 Web 控制台的配置文件（单独存储，不写入 TOML）
CORE_WEB_SERVER_FILE="${CONFIG_DIR}/.web_server"

# --- 高级配置默认值 ---
DEFAULT_RPC_PORTAL="127.0.0.1:15888"
DEFAULT_CONSOLE_LOG_LEVEL="info"
DEFAULT_FILE_LOG_LEVEL="warn"
DEFAULT_FILE_LOG_DIR=""
DEFAULT_HOSTNAME=""
DEFAULT_INSTANCE_NAME="default"
DEFAULT_API_SERVER_PORT="11211"
DEFAULT_CONFIG_SERVER_PORT="22020"
DEFAULT_CONFIG_SERVER_PROTOCOL="udp"

# --- 防火墙端口定义 ---
# EasyTier Core 默认端口
FIREWALL_PORTS_CORE_TCP="11010 11011 11012"
FIREWALL_PORTS_CORE_UDP="11010 11011 11012"
# RPC 管理端口
FIREWALL_PORT_RPC="15888"
# Web 控制台端口
FIREWALL_PORT_WEB="11211"
# 配置下发端口
FIREWALL_PORT_CONFIG_SERVER="22020"

# --- 公共节点配置 ---
# 官方公共节点状态 API
EASYTIER_NODES_API="https://uptime.easytier.cn/api/nodes?page=1&per_page=200"
# 内置官方公共中继节点
BUILTIN_PUBLIC_NODES=(
	"tcp://public.easytier.top:11010"
	"tcp://public.easytier.cn:11010"
)
# 内置社区公共节点
BUILTIN_COMMUNITY_NODES=(
	"tcp://sh.vomiku.com:7910"
	"udp://sh.vomiku.com:7910"
	"ws://sh.vomiku.com:7911"
	"wss://sh.vomiku.com:7912"
	"tcp://us01.225284.xyz:11010"
	"udp://us01.225284.xyz:11010"
)
# 节点测速超时时间（秒）
NODE_PING_TIMEOUT=3
# 节点测速缓存文件
NODES_CACHE_FILE="${CONFIG_DIR}/.nodes_cache"

# 原始下载地址
GITHUB_API_URL="https://api.github.com/repos/EasyTier/EasyTier/releases/latest"

# --- 辅助函数 ---
check_root() {
	if [ "$(id -u)" -ne 0 ]; then
		echo -e "${RED}错误: 此脚本必须以 root 或 sudo 权限运行。${NC}"; exit 1
	fi
}

check_dependencies() {
	local missing_deps=()
	for cmd in curl jq unzip; do
		if ! command -v "$cmd" &> /dev/null; then missing_deps+=("$cmd"); fi
	done
	if [ ${#missing_deps[@]} -gt 0 ]; then
		echo -e "${YELLOW}检测到缺失的依赖: ${missing_deps[*]}${NC}"
		if [[ "$OS_TYPE" == "linux" || "$OS_TYPE" == "alpine"  ]]; then
			read -p "是否尝试自动安装? (y/n): " choice
			if [[ "$choice" != "y" && "$choice" != "Y" ]]; then echo -e "${RED}操作中止。${NC}"; exit 1; fi
			if [[ "$OS_TYPE" == "linux" ]]; then
				if command -v apt-get &>/dev/null; then apt-get update && apt-get install -y "${missing_deps[@]}";
				elif command -v yum &>/dev/null; then yum install -y "${missing_deps[@]}";
				elif command -v dnf &>/dev/null; then dnf install -y "${missing_deps[@]}";
				else echo -e "${RED}无法确定包管理器。请手动安装。${NC}"; exit 1; fi
			elif [[ "$OS_TYPE" == "alpine" ]]; then apk add --no-cache "${missing_deps[@]}"; fi
		elif [[ "$OS_TYPE" == "macos" ]]; then
			echo -e "${YELLOW}请使用 Homebrew 手动安装: brew install ${missing_deps[*]}${NC}"; exit 1
		fi
		for cmd in "${missing_deps[@]}"; do
			 if ! command -v "$cmd" &> /dev/null; then
				echo -e "${RED}依赖 '$cmd' 安装失败。请手动安装后重试。${NC}"; exit 1
			 fi
		done
	fi
}

get_arch() {
	case "$(uname -m)" in
		x86_64|amd64) echo "x86_64" ;; aarch64|arm64) echo "aarch64" ;;
		*) echo -e "${RED}错误: 不支持的架构: $(uname -m)${NC}"; exit 1 ;;
	esac
}

# --- 安装状态检查 ---
check_installed() {
	if [ ! -f "${INSTALL_DIR}/${CORE_BINARY_NAME}" ]; then
		echo -e "${YELLOW}EasyTier Core 尚未安装。请先选择安装选项。${NC}"; return 1
	fi; return 0
}

check_cli_installed() {
	if [ ! -f "${INSTALL_DIR}/${CLI_BINARY_NAME}" ]; then
		echo -e "${YELLOW}EasyTier CLI 尚未安装。请先选择安装选项。${NC}"; return 1
	fi; return 0
}

check_web_installed() {
	if [ ! -f "${INSTALL_DIR}/${WEB_BINARY_NAME}" ]; then
		echo -e "${YELLOW}EasyTier Web 尚未安装。请先选择 Web 安装选项。${NC}"; return 1
	fi; return 0
}

set_toml_value() {
	# This sed command works on both Linux and macOS
	sed -i.bak "s|^#* *${1} *=.*|${1} = ${2}|" "$3" && rm "${3}.bak"
}

# --- 动态 TOML 写入函数 ---
# 追加或更新顶级键值对（不在 section 内的）
add_toml_entry() {
	local key="$1" value="$2" file="$3"
	if grep -q "^#*\s*${key}\s*=" "$file" 2>/dev/null; then
		sed -i.bak "s|^#* *${key} *=.*|${key} = ${value}|" "$file" && rm "${file}.bak"
	else
		echo "${key} = ${value}" >> "$file"
	fi
	echo -e "${GREEN}已设置 ${key} = ${value}${NC}"
}

# 追加或更新 TOML 数组键值对
add_toml_array() {
	local key="$1" value="$2" file="$3"
	if grep -q "^#*\s*${key}\s*=" "$file" 2>/dev/null; then
		sed -i.bak "s|^#* *${key} *=.*|${key} = ${value}|" "$file" && rm "${file}.bak"
	else
		echo "${key} = ${value}" >> "$file"
	fi
	echo -e "${GREEN}已设置 ${key} = ${value}${NC}"
}

# 追加 proxy_network 数组条目
add_proxy_network() {
	local cidr="$1" file="$2"
	if ! grep -q "\[\[proxy_network\]\]" "$file" 2>/dev/null; then
		echo -e "\n[[proxy_network]]" >> "$file"
	fi
	echo "cidr = \"${cidr}\"" >> "$file"
	echo -e "${GREEN}已添加子网代理: ${cidr}${NC}"
}

# 追加 peer 数组条目
add_peer_uri() {
	local uri="$1" file="$2"
	echo -e "\n[[peer]]\nuri = \"${uri}\"" >> "$file"
	echo -e "${GREEN}已添加对端节点: ${uri}${NC}"
}

# 追加 exit_nodes 数组
add_exit_nodes() {
	local nodes="$1" file="$2"
	# 先移除旧值，再添加
	sed -i.bak "/^exit_nodes\s*=/d" "$file" && rm "${file}.bak"
	local arr="["
	local first=true
	IFS=',' read -ra ADDR <<< "$nodes"
	for i in "${ADDR[@]}"; do
		local trimmed; trimmed=$(echo "$i" | xargs)
		if [ -n "$trimmed" ]; then
			if [ "$first" = true ]; then first=false; else arr="${arr}, "; fi
			arr="${arr}\"${trimmed}\""
		fi
	done
	arr="${arr}]"
	echo "exit_nodes = ${arr}" >> "$file"
	echo -e "${GREEN}已设置出口节点: ${arr}${NC}"
}

# 追加 manual_routes 数组
add_manual_routes() {
	local routes="$1" file="$2"
	sed -i.bak "/^manual_routes\s*=/d" "$file" && rm "${file}.bak"
	local arr="["
	local first=true
	IFS=',' read -ra ADDR <<< "$routes"
	for i in "${ADDR[@]}"; do
		local trimmed; trimmed=$(echo "$i" | xargs)
		if [ -n "$trimmed" ]; then
			if [ "$first" = true ]; then first=false; else arr="${arr}, "; fi
			arr="${arr}\"${trimmed}\""
		fi
	done
	arr="${arr}]"
	echo "manual_routes = ${arr}" >> "$file"
	echo -e "${GREEN}已设置手动路由: ${arr}${NC}"
}

# 追加 vpn_portal 配置
add_vpn_portal() {
	local portal="$1" file="$2"
	sed -i.bak "/^vpn_portal\s*=/d" "$file" && rm "${file}.bak"
	echo "vpn_portal = \"${portal}\"" >> "$file"
	echo -e "${GREEN}已设置 VPN Portal: ${portal}${NC}"
}


# --- 防火墙管理功能 ---

# 检测系统使用的防火墙类型
detect_firewall() {
	if [[ "$OS_TYPE" == "macos" ]]; then
		echo "pfctl"
	elif [[ "$OS_TYPE" == "alpine" ]]; then
		echo "iptables"
	else
		if command -v ufw &>/dev/null && ufw status &>/dev/null; then
			echo "ufw"
		elif command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
			echo "firewalld"
		elif command -v iptables &>/dev/null; then
			echo "iptables"
		else
			echo "none"
		fi
	fi
}

# 检查端口是否已在防火墙中放行（ufw）
check_ufw_port() {
	local port="$1" protocol="$2"
	if ufw status | grep -q "${port}/${protocol}"; then
		return 0
	else
		return 1
	fi
}

# 检查端口是否已在防火墙中放行（firewalld）
check_firewalld_port() {
	local port="$1" protocol="$2"
	if firewall-cmd --list-ports 2>/dev/null | grep -q "${port}/${protocol}"; then
		return 0
	else
		return 1
	fi
}

# 检查端口是否已在防火墙中放行（iptables）
check_iptables_port() {
	local port="$1" protocol="$2"
	if iptables -L INPUT -n 2>/dev/null | grep -q "dpt:${port}.*${protocol}"; then
		return 0
	else
		return 1
	fi
}

# 检查端口是否已在防火墙中放行（通用入口）
check_firewall_port() {
	local port="$1" protocol="$2"
	local fw_type; fw_type=$(detect_firewall)

	case "$fw_type" in
		ufw) check_ufw_port "$port" "$protocol"; return $? ;;
		firewalld) check_firewalld_port "$port" "$protocol"; return $? ;;
		iptables) check_iptables_port "$port" "$protocol"; return $? ;;
		pfctl) echo -e "${YELLOW}macOS pfctl 检查暂未实现${NC}"; return 1 ;;
		none) echo -e "${YELLOW}未检测到防火墙${NC}"; return 0 ;;
	esac
}

# 开放端口（ufw）
open_ufw_port() {
	local port="$1" protocol="$2"
	if check_ufw_port "$port" "$protocol"; then
		echo -e "${GREEN}端口 ${port}/${protocol} 已在 ufw 中放行${NC}"
		return 0
	fi
	ufw allow "${port}/${protocol}" &>/dev/null
	if check_ufw_port "$port" "$protocol"; then
		echo -e "${GREEN}已在 ufw 中放行端口 ${port}/${protocol}${NC}"
		return 0
	else
		echo -e "${RED}ufw 放行端口 ${port}/${protocol} 失败${NC}"
		return 1
	fi
}

# 开放端口（firewalld）
open_firewalld_port() {
	local port="$1" protocol="$2"
	if check_firewalld_port "$port" "$protocol"; then
		echo -e "${GREEN}端口 ${port}/${protocol} 已在 firewalld 中放行${NC}"
		return 0
	fi
	firewall-cmd --permanent --add-port="${port}/${protocol}" &>/dev/null
	firewall-cmd --reload &>/dev/null
	if check_firewalld_port "$port" "$protocol"; then
		echo -e "${GREEN}已在 firewalld 中放行端口 ${port}/${protocol}${NC}"
		return 0
	else
		echo -e "${RED}firewalld 放行端口 ${port}/${protocol} 失败${NC}"
		return 1
	fi
}

# 开放端口（iptables）
open_iptables_port() {
	local port="$1" protocol="$2"
	if check_iptables_port "$port" "$protocol"; then
		echo -e "${GREEN}端口 ${port}/${protocol} 已在 iptables 中放行${NC}"
		return 0
	fi
	iptables -A INPUT -p "$protocol" --dport "$port" -j ACCEPT &>/dev/null
	if check_iptables_port "$port" "$protocol"; then
		echo -e "${GREEN}已在 iptables 中放行端口 ${port}/${protocol}${NC}"
		return 0
	else
		echo -e "${RED}iptables 放行端口 ${port}/${protocol} 失败${NC}"
		return 1
	fi
}

# 开放端口（通用入口）
open_firewall_port() {
	local port="$1" protocol="$2"
	local fw_type; fw_type=$(detect_firewall)

	case "$fw_type" in
		ufw) open_ufw_port "$port" "$protocol"; return $? ;;
		firewalld) open_firewalld_port "$port" "$protocol"; return $? ;;
		iptables) open_iptables_port "$port" "$protocol"; return $? ;;
		pfctl) echo -e "${YELLOW}macOS pfctl 配置暂未实现${NC}"; return 1 ;;
		none) echo -e "${YELLOW}未检测到防火墙，无需配置${NC}"; return 0 ;;
	esac
}

# 关闭端口（ufw）
close_ufw_port() {
	local port="$1" protocol="$2"
	if ! check_ufw_port "$port" "$protocol"; then
		echo -e "${YELLOW}端口 ${port}/${protocol} 未在 ufw 中放行${NC}"
		return 0
	fi
	ufw delete allow "${port}/${protocol}" &>/dev/null
	if ! check_ufw_port "$port" "$protocol"; then
		echo -e "${GREEN}已在 ufw 中关闭端口 ${port}/${protocol}${NC}"
		return 0
	else
		echo -e "${RED}ufw 关闭端口 ${port}/${protocol} 失败${NC}"
		return 1
	fi
}

# 关闭端口（firewalld）
close_firewalld_port() {
	local port="$1" protocol="$2"
	if ! check_firewalld_port "$port" "$protocol"; then
		echo -e "${YELLOW}端口 ${port}/${protocol} 未在 firewalld 中放行${NC}"
		return 0
	fi
	firewall-cmd --permanent --remove-port="${port}/${protocol}" &>/dev/null
	firewall-cmd --reload &>/dev/null
	if ! check_firewalld_port "$port" "$protocol"; then
		echo -e "${GREEN}已在 firewalld 中关闭端口 ${port}/${protocol}${NC}"
		return 0
	else
		echo -e "${RED}firewalld 关闭端口 ${port}/${protocol} 失败${NC}"
		return 1
	fi
}

# 关闭端口（iptables）
close_iptables_port() {
	local port="$1" protocol="$2"
	if ! check_iptables_port "$port" "$protocol"; then
		echo -e "${YELLOW}端口 ${port}/${protocol} 未在 iptables 中放行${NC}"
		return 0
	fi
	iptables -D INPUT -p "$protocol" --dport "$port" -j ACCEPT &>/dev/null
	if ! check_iptables_port "$port" "$protocol"; then
		echo -e "${GREEN}已在 iptables 中关闭端口 ${port}/${protocol}${NC}"
		return 0
	else
		echo -e "${RED}iptables 关闭端口 ${port}/${protocol} 失败${NC}"
		return 1
	fi
}

# 关闭端口（通用入口）
close_firewall_port() {
	local port="$1" protocol="$2"
	local fw_type; fw_type=$(detect_firewall)

	case "$fw_type" in
		ufw) close_ufw_port "$port" "$protocol"; return $? ;;
		firewalld) close_firewalld_port "$port" "$protocol"; return $? ;;
		iptables) close_iptables_port "$port" "$protocol"; return $? ;;
		pfctl) echo -e "${YELLOW}macOS pfctl 配置暂未实现${NC}"; return 1 ;;
		none) echo -e "${YELLOW}未检测到防火墙，无需配置${NC}"; return 0 ;;
	esac
}

# 一键放行 EasyTier 所有必要端口
open_all_easytier_ports() {
	echo -e "${BLUE}--- 正在放行 EasyTier 所需端口 ---${NC}"
	echo "检测到防火墙类型: $(detect_firewall)"
	echo ""

	# Core TCP 端口
	for port in $FIREWALL_PORTS_CORE_TCP; do
		open_firewall_port "$port" "tcp"
	done

	# Core UDP 端口
	for port in $FIREWALL_PORTS_CORE_UDP; do
		open_firewall_port "$port" "udp"
	done

	# RPC 端口（TCP）
	open_firewall_port "$FIREWALL_PORT_RPC" "tcp"

	# Web 控制台端口（TCP）
	open_firewall_port "$FIREWALL_PORT_WEB" "tcp"

	# 配置下发端口
	open_firewall_port "$FIREWALL_PORT_CONFIG_SERVER" "tcp"
	open_firewall_port "$FIREWALL_PORT_CONFIG_SERVER" "udp"

	echo -e "${GREEN}--- EasyTier 端口配置完成 ---${NC}"
}

# 一键关闭 EasyTier 所有端口
close_all_easytier_ports() {
	echo -e "${BLUE}--- 正在关闭 EasyTier 相关端口 ---${NC}"
	echo "检测到防火墙类型: $(detect_firewall)"
	echo ""

	# Core TCP 端口
	for port in $FIREWALL_PORTS_CORE_TCP; do
		close_firewall_port "$port" "tcp"
	done

	# Core UDP 端口
	for port in $FIREWALL_PORTS_CORE_UDP; do
		close_firewall_port "$port" "udp"
	done

	# RPC 端口（TCP）
	close_firewall_port "$FIREWALL_PORT_RPC" "tcp"

	# Web 控制台端口（TCP）
	close_firewall_port "$FIREWALL_PORT_WEB" "tcp"

	# 配置下发端口
	close_firewall_port "$FIREWALL_PORT_CONFIG_SERVER" "tcp"
	close_firewall_port "$FIREWALL_PORT_CONFIG_SERVER" "udp"

	echo -e "${GREEN}--- EasyTier 端口关闭完成 ---${NC}"
}

# 检查 EasyTier 端口状态
check_all_easytier_ports() {
	echo -e "${BLUE}--- EasyTier 端口状态检查 ---${NC}"
	echo "检测到防火墙类型: $(detect_firewall)"
	echo ""

	# Core TCP 端口
	echo -e "${BLUE}Core TCP 端口:${NC}"
	for port in $FIREWALL_PORTS_CORE_TCP; do
		if check_firewall_port "$port" "tcp" 2>/dev/null; then
			echo -e "  ${GREEN}✓${NC} ${port}/tcp - 已放行"
		else
			echo -e "  ${RED}✗${NC} ${port}/tcp - 未放行"
		fi
	done

	# Core UDP 端口
	echo -e "${BLUE}Core UDP 端口:${NC}"
	for port in $FIREWALL_PORTS_CORE_UDP; do
		if check_firewall_port "$port" "udp" 2>/dev/null; then
			echo -e "  ${GREEN}✓${NC} ${port}/udp - 已放行"
		else
			echo -e "  ${RED}✗${NC} ${port}/udp - 未放行"
		fi
	done

	# RPC 端口
	echo -e "${BLUE}RPC 管理端口:${NC}"
	if check_firewall_port "$FIREWALL_PORT_RPC" "tcp" 2>/dev/null; then
		echo -e "  ${GREEN}✓${NC} ${FIREWALL_PORT_RPC}/tcp - 已放行"
	else
		echo -e "  ${RED}✗${NC} ${FIREWALL_PORT_RPC}/tcp - 未放行"
	fi

	# Web 控制台端口
	echo -e "${BLUE}Web 控制台端口:${NC}"
	if check_firewall_port "$FIREWALL_PORT_WEB" "tcp" 2>/dev/null; then
		echo -e "  ${GREEN}✓${NC} ${FIREWALL_PORT_WEB}/tcp - 已放行"
	else
		echo -e "  ${RED}✗${NC} ${FIREWALL_PORT_WEB}/tcp - 未放行"
	fi

	# 配置下发端口
	echo -e "${BLUE}配置下发端口:${NC}"
	if check_firewall_port "$FIREWALL_PORT_CONFIG_SERVER" "tcp" 2>/dev/null; then
		echo -e "  ${GREEN}✓${NC} ${FIREWALL_PORT_CONFIG_SERVER}/tcp - 已放行"
	else
		echo -e "  ${RED}✗${NC} ${FIREWALL_PORT_CONFIG_SERVER}/tcp - 未放行"
	fi
	if check_firewall_port "$FIREWALL_PORT_CONFIG_SERVER" "udp" 2>/dev/null; then
		echo -e "  ${GREEN}✓${NC} ${FIREWALL_PORT_CONFIG_SERVER}/udp - 已放行"
	else
		echo -e "  ${RED}✗${NC} ${FIREWALL_PORT_CONFIG_SERVER}/udp - 未放行"
	fi
}


# --- 公共节点管理功能 ---

# 从 URI 中解析协议、主机和端口
parse_node_uri() {
	local uri="$1"
	local protocol host port

	if [[ "$uri" =~ ^([a-zA-Z]+)://([^:/]+):([0-9]+) ]]; then
		protocol="${BASH_REMATCH[1]}"
		host="${BASH_REMATCH[2]}"
		port="${BASH_REMATCH[3]}"
		echo "$protocol $host $port"
		return 0
	else
		echo ""
		return 1
	fi
}

# 测试单个节点的 TCP 连接延迟
test_node_latency() {
	local uri="$1"
	local parsed; parsed=$(parse_node_uri "$uri")
	if [ -z "$parsed" ]; then
		echo "N/A"
		return 1
	fi

	local protocol host port
	read -r protocol host port <<< "$parsed"

	# 对于非 TCP 协议（UDP、WS、WSS），降级使用 TCP 端口测试
	# 因为无法直接测试 UDP 延迟，WS/WSS 也需要完整握手
	if [ "$protocol" = "udp" ]; then
		# UDP 节点用同一端口的 TCP 测试，或使用 ping 测试主机延迟
		protocol="tcp"
	elif [ "$protocol" = "ws" ] || [ "$protocol" = "wss" ]; then
		protocol="tcp"
	fi

	# 使用 timeout + bash 的 /dev/tcp 测试延迟
	local start end latency
	start=$(date +%s%N 2>/dev/null || date +%s)
	if timeout "$NODE_PING_TIMEOUT" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
		end=$(date +%s%N 2>/dev/null || date +%s)
		# 计算延迟（毫秒）
		if echo "$start" | grep -q "N"; then
			latency=$(( (end - start) / 1000000 ))
		else
			latency=$(( (end - start) * 1000 ))
		fi
		echo "$latency"
		return 0
	else
		echo "timeout"
		return 1
	fi
}

# 获取所有公共节点列表（内置 + 可选 API）
get_all_public_nodes() {
	local all_nodes=()

	# 添加官方节点
	for node in "${BUILTIN_PUBLIC_NODES[@]}"; do
		all_nodes+=("官方|$node")
	done

	# 添加社区节点
	for node in "${BUILTIN_COMMUNITY_NODES[@]}"; do
		all_nodes+=("社区|$node")
	done

	# 尝试从 API 获取更多节点
	if command -v curl &>/dev/null && command -v jq &>/dev/null; then
		local api_data; api_data=$(curl -sL --connect-timeout 5 "$EASYTIER_NODES_API" 2>/dev/null)
		if [ -n "$api_data" ] && echo "$api_data" | jq . >/dev/null 2>&1; then
			# 解析 API 返回的节点列表
			local nodes_count; nodes_count=$(echo "$api_data" | jq '.data | length' 2>/dev/null || echo "0")
			if [ "$nodes_count" -gt 0 ] 2>/dev/null; then
				for i in $(seq 0 $((nodes_count - 1))); do
					local name addr status
					name=$(echo "$api_data" | jq -r ".data[$i].name" 2>/dev/null || echo "unknown")
					addr=$(echo "$api_data" | jq -r ".data[$i].addr" 2>/dev/null || echo "")
					status=$(echo "$api_data" | jq -r ".data[$i].status" 2>/dev/null || echo "unknown")
					if [ -n "$addr" ] && [ "$addr" != "null" ]; then
						all_nodes+=("API|$addr|$name|$status")
					fi
				done
			fi
		fi
	fi

	# 输出所有节点
	for node in "${all_nodes[@]}"; do
		echo "$node"
	done
}

# 测试所有公共节点并按延迟排序
test_all_nodes() {
	echo -e "${BLUE}正在获取公共节点列表...${NC}"
	local nodes; nodes=$(get_all_public_nodes)
	local total_nodes; total_nodes=$(echo "$nodes" | wc -l)

	echo -e "${GREEN}共找到 ${total_nodes} 个公共节点${NC}"
	echo -e "${BLUE}开始测速（每个节点约 ${NODE_PING_TIMEOUT} 秒超时）...${NC}"
	echo ""

	local results=()
	local index=0

	while IFS='|' read -r source uri extra1 extra2; do
		index=$((index + 1))
		local display_name
		if [ "$source" = "官方" ]; then
			display_name="[官方] ${uri}"
		elif [ "$source" = "社区" ]; then
			display_name="[社区] ${uri}"
		elif [ "$source" = "API" ]; then
			display_name="[API] ${extra1} (${uri})"
		else
			display_name="${uri}"
		fi

		printf "  [%d/%d] 测试 %-60s " "$index" "$total_nodes" "$display_name"
		local latency; latency=$(test_node_latency "$uri")

		if [ "$latency" = "timeout" ]; then
			echo -e "${RED}超时${NC}"
			results+=("999999|${display_name}|${uri}|超时")
		else
			echo -e "${GREEN}${latency}ms${NC}"
			results+=("${latency}|${display_name}|${uri}|${latency}ms")
		fi
	done <<< "$nodes"

	# 按延迟排序并保存到缓存
	mkdir -p "$CONFIG_DIR"
	printf "%s\n" "${results[@]}" | sort -t'|' -k1 -n > "$NODES_CACHE_FILE"

	echo ""
	echo -e "${GREEN}测速完成！结果已按延迟排序。${NC}"
	echo -e "${YELLOW}缓存文件: ${NODES_CACHE_FILE}${NC}"
}

# 显示测速结果
show_latency_results() {
	if [ ! -f "$NODES_CACHE_FILE" ]; then
		echo -e "${YELLOW}暂无测速结果，请先运行测速。${NC}"
		return 1
	fi

	echo -e "${BLUE}--- 公共节点延迟排名 ---${NC}"
	echo ""
	printf "%-5s %-65s %s\n" "排名" "节点" "延迟"
	echo "------------------------------------------------------------"

	local rank=0
	while IFS='|' read -r _latency display_name uri latency_str; do
		rank=$((rank + 1))
		if [ "$latency_str" = "超时" ]; then
			printf "%-5s %-65s %s\n" "$rank" "$display_name" "${RED}${latency_str}${NC}"
		else
			# 根据延迟设置颜色
			if [ "$_latency" -lt 50 ]; then
				printf "%-5s %-65s %s\n" "$rank" "$display_name" "${GREEN}${latency_str}${NC}"
			elif [ "$_latency" -lt 150 ]; then
				printf "%-5s %-65s %s\n" "$rank" "$display_name" "${YELLOW}${latency_str}${NC}"
			else
				printf "%-5s %-65s %s\n" "$rank" "$display_name" "${latency_str}"
			fi
		fi
	done < "$NODES_CACHE_FILE"

	echo ""
	echo -e "${BLUE}提示: 数字越小延迟越好${NC}"
}

# 快速选择最优节点并添加为 peer
select_fastest_node() {
	if [ ! -f "$NODES_CACHE_FILE" ]; then
		echo -e "${YELLOW}暂无测速结果，正在自动测速...${NC}"
		test_all_nodes
	fi

	# 获取最快的节点
	local fastest; fastest=$(head -n 1 "$NODES_CACHE_FILE")
	if [ -z "$fastest" ]; then
		echo -e "${RED}未找到可用节点${NC}"
		return 1
	fi

	local uri; uri=$(echo "$fastest" | cut -d'|' -f3)
	local display_name; display_name=$(echo "$fastest" | cut -d'|' -f2)
	local latency_str; latency_str=$(echo "$fastest" | cut -d'|' -f4)

	echo -e "${GREEN}最快节点: ${display_name}${NC}"
	echo -e "${GREEN}延迟: ${latency_str}${NC}"
	echo ""

	read -p "是否将此节点添加为 peer? (y/n): " choice
	if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
		if [ -f "$CONFIG_FILE" ]; then
			add_peer_uri "$uri" "$CONFIG_FILE"
			echo -e "${YELLOW}正在重启服务以应用配置...${NC}"
			restart_service
			echo -e "${GREEN}已添加最快节点并重启服务！${NC}"
		else
			echo -e "${RED}配置文件不存在，请先部署网络。${NC}"
		fi
	fi
}

# 手动选择节点添加为 peer
select_node_manually() {
	if [ ! -f "$NODES_CACHE_FILE" ]; then
		echo -e "${YELLOW}暂无测速结果，正在自动测速...${NC}"
		test_all_nodes
	fi

	echo -e "${BLUE}--- 选择节点添加为 Peer ---${NC}"
	echo ""

	local nodes=()
	local index=0

	while IFS='|' read -r _latency display_name uri latency_str; do
		index=$((index + 1))
		nodes+=("$uri")
		printf "%3d. %-60s %s\n" "$index" "$display_name" "$latency_str"
	done < "$NODES_CACHE_FILE"

	echo ""
	read -p "请输入节点编号添加为 peer (0 取消): " choice

	if [ "$choice" -gt 0 ] 2>/dev/null && [ "$choice" -le "$index" ]; then
		local selected_uri="${nodes[$((choice - 1))]}"
		if [ -f "$CONFIG_FILE" ]; then
			add_peer_uri "$selected_uri" "$CONFIG_FILE"
			echo -e "${YELLOW}正在重启服务以应用配置...${NC}"
			restart_service
			echo -e "${GREEN}已添加节点并重启服务！${NC}"
		else
			echo -e "${RED}配置文件不存在，请先部署网络。${NC}"
		fi
	fi
}


# --- 平台相关的 Core 服务管理功能 ---

create_service_file() {
    if [[ "$OS_TYPE" == "macos" || "$OS_TYPE" == "alpine" ]]; then
        touch "$LOG_FILE"
        chown root:root "$LOG_FILE" &>/dev/null
        chmod 644 "$LOG_FILE"
    fi

    # 读取 web_server 配置（从单独文件读取，避免污染 TOML）
    local web_server_config=""
    if [ -f "$CORE_WEB_SERVER_FILE" ]; then
        web_server_config=$(cat "$CORE_WEB_SERVER_FILE" 2>/dev/null | tr -d '\n')
    fi
    local web_server_arg=""
    if [ -n "$web_server_config" ]; then
        web_server_arg="-w ${web_server_config}"
    fi

    if [[ "$OS_TYPE" == "linux" ]]; then
        cat > "${SERVICE_FILE}" << EOL
[Unit]
Description=EasyTier Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/${CORE_BINARY_NAME} -c ${CONFIG_FILE} ${web_server_arg}
# 使用 "always" 策略确保进程无论如何退出都会被重启，提供最强的守护
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL
    elif [[ "$OS_TYPE" == "alpine" ]]; then
        # 使用 OpenRC 的 supervise-daemon 实现真正的进程守护
        cat > "${SERVICE_FILE}" << EOL
#!/sbin/openrc-run
description="EasyTier Service with Supervisor"
supervisor=supervise-daemon
command="${INSTALL_DIR}/${CORE_BINARY_NAME}"
command_args="-c ${CONFIG_FILE} ${web_server_arg}"
command_user="root"
pidfile="/var/run/${SERVICE_NAME}.pid"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"
depend() {
	need net
	after net
}
EOL
        chmod +x "${SERVICE_FILE}";
    elif [[ "$OS_TYPE" == "macos" ]]; then
        if [ -n "$web_server_config" ]; then
            # 使用 printf 确保正确的换行符
            printf '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>%s</string>
    <key>ProgramArguments</key>
    <array>
        <string>%s</string>
        <string>-c</string>
        <string>%s</string>
        <string>-w</string>
        <string>%s</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>%s</string>
    <key>StandardErrorPath</key>
    <string>%s</string>
</dict>
</plist>
' "$SERVICE_LABEL" "$INSTALL_DIR/$CORE_BINARY_NAME" "$CONFIG_FILE" "$web_server_config" "$LOG_FILE" "$LOG_FILE" > "${SERVICE_FILE}"
        else
            cat > "${SERVICE_FILE}" << EOL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/${CORE_BINARY_NAME}</string>
        <string>-c</string>
        <string>${CONFIG_FILE}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
</dict>
</plist>
EOL
        fi
    fi
    echo -e "${GREEN}EasyTier Core 服务文件创建/更新成功: ${SERVICE_FILE}${NC}"
}

# --- 平台相关的 Web 服务管理功能 ---

create_web_service_file() {
    mkdir -p "$WEB_CONFIG_DIR"
    # 生成 Web 环境配置文件供 systemd 环境变量使用
    local web_env=""
    if [ -f "$WEB_CONFIG_FILE" ]; then web_env=$(cat "$WEB_CONFIG_FILE"); fi

    if [[ "$OS_TYPE" == "macos" || "$OS_TYPE" == "alpine" ]]; then
        touch "$WEB_LOG_FILE"
        chown root:root "$WEB_LOG_FILE" &>/dev/null
        chmod 644 "$WEB_LOG_FILE"
    fi

    if [[ "$OS_TYPE" == "linux" ]]; then
        cat > "${WEB_SERVICE_FILE}" << EOL
[Unit]
Description=EasyTier Web Console Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${WEB_CONFIG_DIR}
ExecStart=${INSTALL_DIR}/${WEB_BINARY_NAME} --db ${WEB_DB_FILE} --api-server-port 11211 --api-host "http://127.0.0.1:11211" --config-server-port 22020 --config-server-protocol udp
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL
    elif [[ "$OS_TYPE" == "alpine" ]]; then
        cat > "${WEB_SERVICE_FILE}" << EOL
#!/sbin/openrc-run
description="EasyTier Web Console with Supervisor"
supervisor=supervise-daemon
command="${INSTALL_DIR}/${WEB_BINARY_NAME}"
command_args="--db ${WEB_DB_FILE} --api-server-port 11211 --api-host http://127.0.0.1:11211 --config-server-port 22020 --config-server-protocol udp"
command_user="root"
pidfile="/var/run/${WEB_SERVICE_NAME}.pid"
output_log="${WEB_LOG_FILE}"
error_log="${WEB_LOG_FILE}"
directory="${WEB_CONFIG_DIR}"
depend() {
	need net
	after net
}
EOL
        chmod +x "${WEB_SERVICE_FILE}";
    elif [[ "$OS_TYPE" == "macos" ]]; then
        cat > "${WEB_SERVICE_FILE}" << EOL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${WEB_SERVICE_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/${WEB_BINARY_NAME}</string>
        <string>--db</string>
        <string>${WEB_DB_FILE}</string>
        <string>--api-server-port</string>
        <string>11211</string>
        <string>--api-host</string>
        <string>http://127.0.0.1:11211</string>
        <string>--config-server-port</string>
        <string>22020</string>
        <string>--config-server-protocol</string>
        <string>udp</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${WEB_CONFIG_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${WEB_LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${WEB_LOG_FILE}</string>
</dict>
</plist>
EOL
    fi
    echo -e "${GREEN}EasyTier Web 服务文件创建/更新成功: ${WEB_SERVICE_FILE}${NC}"
}

reload_service_daemon() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl daemon-reload; fi; }
start_service() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl start "${SERVICE_NAME}"; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-service "${SERVICE_NAME}" start; elif [[ "$OS_TYPE" == "macos" ]]; then launchctl load "${SERVICE_FILE}" &>/dev/null; fi; }
stop_service() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl stop "${SERVICE_NAME}"; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-service "${SERVICE_NAME}" stop; elif [[ "$OS_TYPE" == "macos" ]]; then launchctl unload "${SERVICE_FILE}" &>/dev/null; fi; }
restart_service() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl restart "${SERVICE_NAME}"; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-service "${SERVICE_NAME}" restart; elif [[ "$OS_TYPE" == "macos" ]]; then stop_service; sleep 1; start_service; fi; }
enable_service() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl enable "${SERVICE_NAME}"; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-update add "${SERVICE_NAME}" default; elif [[ "$OS_TYPE" == "macos" ]]; then start_service; fi; echo -e "${GREEN}EasyTier Core 服务已设为开机自启。${NC}"; }
disable_service() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl disable "${SERVICE_NAME}"; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-update del "${SERVICE_NAME}" default; elif [[ "$OS_TYPE" == "macos" ]]; then stop_service; fi; echo -e "${YELLOW}EasyTier Core 服务已取消开机自启。${NC}"; }
status_service() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl status "${SERVICE_NAME}" --no-pager -l; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-service "${SERVICE_NAME}" status; elif [[ "$OS_TYPE" == "macos" ]]; then if launchctl list | grep -q "${SERVICE_LABEL}"; then echo -e "${GREEN}EasyTier Core 服务 (${SERVICE_LABEL}) 正在运行。${NC}"; ps aux | grep "${CORE_BINARY_NAME}" | grep -v grep; else echo -e "${YELLOW}EasyTier Core 服务 (${SERVICE_LABEL}) 已停止。${NC}"; fi; fi; }
log_service() { if [[ "$OS_TYPE" == "linux" ]]; then journalctl -u "${SERVICE_NAME}" -f --no-pager; elif [[ "$OS_TYPE" == "alpine" || "$OS_TYPE" == "macos" ]]; then echo "正在显示日志文件: ${LOG_FILE}"; tail -f "${LOG_FILE}"; fi; }

# --- Web 服务管理函数 ---
start_web_service() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl start "${WEB_SERVICE_NAME}"; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-service "${WEB_SERVICE_NAME}" start; elif [[ "$OS_TYPE" == "macos" ]]; then launchctl load "${WEB_SERVICE_FILE}" &>/dev/null; fi; }
stop_web_service() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl stop "${WEB_SERVICE_NAME}"; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-service "${WEB_SERVICE_NAME}" stop; elif [[ "$OS_TYPE" == "macos" ]]; then launchctl unload "${WEB_SERVICE_FILE}" &>/dev/null; fi; }
restart_web_service() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl restart "${WEB_SERVICE_NAME}"; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-service "${WEB_SERVICE_NAME}" restart; elif [[ "$OS_TYPE" == "macos" ]]; then stop_web_service; sleep 1; start_web_service; fi; }
enable_web_service() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl enable "${WEB_SERVICE_NAME}"; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-update add "${WEB_SERVICE_NAME}" default; elif [[ "$OS_TYPE" == "macos" ]]; then start_web_service; fi; echo -e "${GREEN}EasyTier Web 服务已设为开机自启。${NC}"; }
disable_web_service() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl disable "${WEB_SERVICE_NAME}"; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-update del "${WEB_SERVICE_NAME}" default; elif [[ "$OS_TYPE" == "macos" ]]; then stop_web_service; fi; echo -e "${YELLOW}EasyTier Web 服务已取消开机自启。${NC}"; }
status_web_service() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl status "${WEB_SERVICE_NAME}" --no-pager -l; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-service "${WEB_SERVICE_NAME}" status; elif [[ "$OS_TYPE" == "macos" ]]; then if launchctl list | grep -q "${WEB_SERVICE_LABEL}"; then echo -e "${GREEN}EasyTier Web 服务 (${WEB_SERVICE_LABEL}) 正在运行。${NC}"; else echo -e "${YELLOW}EasyTier Web 服务 (${WEB_SERVICE_LABEL}) 已停止。${NC}"; fi; fi; }
log_web_service() { if [[ "$OS_TYPE" == "linux" ]]; then journalctl -u "${WEB_SERVICE_NAME}" -f --no-pager; elif [[ "$OS_TYPE" == "alpine" || "$OS_TYPE" == "macos" ]]; then echo "正在显示日志文件: ${WEB_LOG_FILE}"; tail -f "${WEB_LOG_FILE}"; fi; }

# --- 主功能函数 ---
create_shortcut() {
	local SCRIPT_PATH; SCRIPT_PATH=$(realpath "$0" 2>/dev/null || (cd "$(dirname "$0")" && echo "$(pwd)/$(basename "$0")"))
	if [ -L "${ALIAS_PATH}" ] && [ "$(readlink "${ALIAS_PATH}")" = "${SCRIPT_PATH}" ]; then return 0; fi
	echo -e "${YELLOW}正在创建"et"快捷命令...${NC}"
	chmod +x "${SCRIPT_PATH}"
	ln -sf "${SCRIPT_PATH}" "${ALIAS_PATH}"
	if [ $? -eq 0 ]; then echo -e "${GREEN}成功! 现在你可以在终端中直接输入"et"来运行此脚本。${NC}"; else echo -e "${RED}创建快捷命令失败。请检查权限或 /usr/local/bin 是否在你的 PATH 中。${NC}"; fi
}

remove_shortcut() {
	if [ -L "${ALIAS_PATH}" ]; then rm -f "${ALIAS_PATH}" &>/dev/null; fi
}

install_easytier() {
	echo -e "${GREEN}--- 开始安装或更新 EasyTier ---${NC}"
	local os_identifier="linux"; if [[ "$OS_TYPE" == "macos" ]]; then os_identifier="macos"; fi
	local arch; arch=$(get_arch)

	echo "1. 获取最新版本信息..."
	local latest_info; latest_info=$(curl -sL "$GITHUB_API_URL")
	if [ -z "$latest_info" ] || ! echo "$latest_info" | jq . >/dev/null 2>&1; then echo -e "${RED}错误: 无法从 GitHub API 获取版本信息。${NC}"; return 1; fi
	local search_prefix="easytier-${os_identifier}-${arch}"
	local asset_json; asset_json=$(echo "$latest_info" | jq ".assets[] | select(.name | startswith(\"${search_prefix}\") and endswith(\".zip\"))")
	if [ -z "$asset_json" ]; then echo -e "${RED}错误: 未能找到适用于 ${OS_TYPE}(${arch}) 的包。${NC}"; return 1; fi
	local download_url; download_url=$(echo "$asset_json" | jq -r '.browser_download_url')
	local actual_filename; actual_filename=$(echo "$asset_json" | jq -r '.name')
	local version; version=$(echo "$latest_info" | jq -r ".tag_name")
	echo "检测到版本: ${version}, 架构: ${arch}, 文件: ${actual_filename}"
	if [ -n "$GITHUB_PROXY" ]; then download_url="https://$GITHUB_PROXY/$download_url"; echo -e "${YELLOW}2. 使用代理下载: ${download_url}${NC}"; else echo "2. 直接下载: ${download_url}"; fi
	local temp_file; temp_file=$(mktemp)
	curl -L --progress-bar -o "$temp_file" "$download_url" || { echo -e "${RED}下载失败!${NC}"; rm -f "$temp_file"; return 1; }
	echo "3. 解压并安装..."
	local unzip_dir_name="easytier-${os_identifier}-${arch}"
	unzip -o "$temp_file" -d /tmp/ > /dev/null || { echo -e "${RED}解压失败!${NC}"; rm -f "$temp_file"; return 1; }
	local extracted_core="/tmp/${unzip_dir_name}/${CORE_BINARY_NAME}"; local extracted_cli="/tmp/${unzip_dir_name}/${CLI_BINARY_NAME}"
	if [ ! -f "$extracted_core" ] || [ ! -f "$extracted_cli" ]; then echo -e "${RED}错误: 在解压目录中未找到核心文件。${NC}"; rm -f "$temp_file"; rm -rf "/tmp/${unzip_dir_name}"; return 1; fi
	mkdir -p "$INSTALL_DIR"
	mv -f "$extracted_core" "${INSTALL_DIR}/${CORE_BINARY_NAME}"; mv -f "$extracted_cli" "${INSTALL_DIR}/${CLI_BINARY_NAME}"
	chmod +x "${INSTALL_DIR}/${CORE_BINARY_NAME}" "${INSTALL_DIR}/${CLI_BINARY_NAME}"
	
	# [NEW] 同时尝试提取 easytier-web-embed
	local extracted_web; extracted_web=$(find "/tmp/${unzip_dir_name}" -type f -name "${WEB_BINARY_NAME}" 2>/dev/null | head -1)
	if [ -n "$extracted_web" ] && [ -f "$extracted_web" ]; then
		mv -f "$extracted_web" "${INSTALL_DIR}/${WEB_BINARY_NAME}"
		chmod +x "${INSTALL_DIR}/${WEB_BINARY_NAME}"
		echo -e "${GREEN}EasyTier Web (${WEB_BINARY_NAME}) 同时安装成功。${NC}"
	else
		echo -e "${YELLOW}注意: 当前版本包中未找到 ${WEB_BINARY_NAME}，Web 组件需单独安装。${NC}"
	fi
	
	rm -f "$temp_file"; rm -rf "/tmp/${unzip_dir_name}"
	
	echo -e "${GREEN}--- EasyTier ${version} 安装/更新成功! ---${NC}"
	create_shortcut
	
	if [ -f "$SERVICE_FILE" ]; then
		echo -e "${YELLOW}检测到现有 Core 服务，正在重启以应用更新...${NC}"; restart_service;
	fi
}

install_web() {
	echo -e "${GREEN}--- 开始安装或更新 EasyTier Web (${WEB_BINARY_NAME}) ---${NC}"
	local os_identifier="linux"; if [[ "$OS_TYPE" == "macos" ]]; then os_identifier="macos"; fi
	local arch; arch=$(get_arch)

	echo "1. 获取最新版本信息..."
	local latest_info; latest_info=$(curl -sL "$GITHUB_API_URL")
	if [ -z "$latest_info" ] || ! echo "$latest_info" | jq . >/dev/null 2>&1; then echo -e "${RED}错误: 无法从 GitHub API 获取版本信息。${NC}"; return 1; fi
	local search_prefix="easytier-${os_identifier}-${arch}"
	local asset_json; asset_json=$(echo "$latest_info" | jq ".assets[] | select(.name | startswith(\"${search_prefix}\") and endswith(\".zip\"))")
	if [ -z "$asset_json" ]; then echo -e "${RED}错误: 未能找到适用于 ${OS_TYPE}(${arch}) 的包。${NC}"; return 1; fi
	local download_url; download_url=$(echo "$asset_json" | jq -r '.browser_download_url')
	local version; version=$(echo "$latest_info" | jq -r ".tag_name")
	if [ -n "$GITHUB_PROXY" ]; then download_url="https://$GITHUB_PROXY/$download_url"; echo -e "${YELLOW}2. 使用代理下载: ${download_url}${NC}"; else echo "2. 直接下载: ${download_url}"; fi
	local temp_file; temp_file=$(mktemp)
	curl -L --progress-bar -o "$temp_file" "$download_url" || { echo -e "${RED}下载失败!${NC}"; rm -f "$temp_file"; return 1; }
	echo "3. 解压并安装 Web 组件..."
	local unzip_dir_name="easytier-${os_identifier}-${arch}"
	unzip -o "$temp_file" -d /tmp/ > /dev/null || { echo -e "${RED}解压失败!${NC}"; rm -f "$temp_file"; return 1; }
	local extracted_web; extracted_web=$(find "/tmp/${unzip_dir_name}" -type f -name "${WEB_BINARY_NAME}" 2>/dev/null | head -1)
	if [ -z "$extracted_web" ] || [ ! -f "$extracted_web" ]; then
		echo -e "${RED}错误: 在当前版本包中未找到 ${WEB_BINARY_NAME}。请检查 EasyTier Release 是否包含此组件。${NC}"
		rm -f "$temp_file"; rm -rf "/tmp/${unzip_dir_name}"; return 1
	fi
	mkdir -p "$INSTALL_DIR"
	mv -f "$extracted_web" "${INSTALL_DIR}/${WEB_BINARY_NAME}"
	chmod +x "${INSTALL_DIR}/${WEB_BINARY_NAME}"
	rm -f "$temp_file"; rm -rf "/tmp/${unzip_dir_name}"
	echo -e "${GREEN}--- EasyTier Web ${version} 安装/更新成功! ---${NC}"

	if [ -f "$WEB_SERVICE_FILE" ]; then
		echo -e "${YELLOW}检测到现有 Web 服务，正在重启以应用更新...${NC}"; restart_web_service;
	fi
}

create_default_config() { mkdir -p "$CONFIG_DIR"; cat > "$CONFIG_FILE" << 'EOF'
ipv4 = ""
dhcp = false
listeners = ["udp://0.0.0.0:11010", "tcp://0.0.0.0:11010", "wg://0.0.0.0:11011", "ws://0.0.0.0:11011/", "wss://0.0.0.0:11012/", "tcp://[::]:11010", "udp://[::]:11010"]
[network_identity]
network_name = ""
network_secret = ""
[flags]
default_protocol = "udp"
dev_name = ""
enable_encryption = true
enable_ipv6 = true
mtu = 1380
latency_first = true
enable_exit_node = false
no_tun = false
use_smoltcp = false
foreign_network_whitelist = "*"
disable_p2p = false
relay_all_peer_rpc = false
disable_udp_hole_punching = false
enableKcp_Proxy = true
# 新增：默认开启私有模式（仅允许相同network_name/network_secret的节点连接）
private_mode = true
EOF
	if [ $? -eq 0 ]; then echo "已成功创建默认配置文件: ${CONFIG_FILE}"; return 0;
	else echo -e "${RED}错误: 创建配置文件失败!${NC}"; return 1; fi; }

deploy_new_network() { 
	check_installed || return 1
	
	# 显示现有网络配置（如果存在）
	if [ -f "$CONFIG_FILE" ]; then
		echo -e "${BLUE}--- 当前网络配置 ---${NC}"
		echo "网络名称: $(grep 'network_name' "$CONFIG_FILE" 2>/dev/null | sed 's/network_name\s*=\s*"\([^"]*\)"/\1/' || echo '(未设置)')"
		echo "网络密钥: $(grep 'network_secret' "$CONFIG_FILE" 2>/dev/null | sed 's/network_secret\s*=\s*"\([^"]*\)"/\1/' || echo '(未设置)')"
		echo "虚拟IPv4: $(grep 'ipv4' "$CONFIG_FILE" 2>/dev/null | sed 's/ipv4\s*=\s*"\([^"]*\)"/\1/' || echo '(未设置)')"
		echo "DHCP: $(grep 'dhcp' "$CONFIG_FILE" 2>/dev/null | sed 's/dhcp\s*=\s*\(.*\)/\1/' || echo 'false')"
		echo ""
		echo -e "${YELLOW}提示: 留空将保留现有配置${NC}"
		echo ""
	fi
	
	read -p "请输入网络名称 (留空保留现有): " network_name
	read -p "请输入网络密钥 (留空保留现有): " network_secret
	read -p "请输入此虚拟IP (回车则启用DHCP，留空保留现有): " virtual_ip
	
	# 如果名称和密码都为空，保留现有配置
	if [ -z "$network_name" ] && [ -z "$network_secret" ] && [ -z "$virtual_ip" ]; then
		if [ ! -f "$CONFIG_FILE" ]; then
			echo -e "${YELLOW}配置文件不存在，正在创建默认配置...${NC}"
			create_default_config || return 1
		else
			echo -e "${YELLOW}网络名称、密钥和IP都未输入，保留现有配置。${NC}"
		fi
	else
		# 如果配置文件不存在，创建默认配置
		if [ ! -f "$CONFIG_FILE" ]; then
			create_default_config || return 1
		fi
		
		# 更新网络名称（如果输入了）
		if [ -n "$network_name" ]; then
			set_toml_value "network_name" "\"$network_name\"" "$CONFIG_FILE"
		fi
		
		# 更新网络密钥（如果输入了）
		if [ -n "$network_secret" ]; then
			set_toml_value "network_secret" "\"$network_secret\"" "$CONFIG_FILE"
		fi
		
		# 更新虚拟IP（如果输入了）
		if [ -n "$virtual_ip" ]; then
			if [ "$virtual_ip" = "dhcp" ] || [ "$virtual_ip" = "DHCP" ]; then
				echo -e "${YELLOW}启用 DHCP 自动获取地址。${NC}"
				set_toml_value "dhcp" "true" "$CONFIG_FILE"
				set_toml_value "ipv4" "\"\"" "$CONFIG_FILE"
			else
				echo -e "${GREEN}已设置静态IP: ${virtual_ip}${NC}"
				set_toml_value "dhcp" "false" "$CONFIG_FILE"
				set_toml_value "ipv4" "\"$virtual_ip\"" "$CONFIG_FILE"
			fi
		fi
	fi

	create_service_file
	reload_service_daemon
	
	# [MODIFIED] 自动启用并重启服务
	echo -e "${YELLOW}正在设置开机自启并启动服务...${NC}"
	enable_service
	restart_service
	echo -e "${GREEN}--- 新网络部署成功，服务已启动并设为开机自启! ---${NC}"
	
	sleep 2; status_service
}

join_existing_network() { 
	check_installed || return 1
	read -p "请输入网络名称: " network_name
	read -p "请输入网络密钥: " network_secret
	read -p "请输入此节点虚拟IP (留空则启用DHCP): " virtual_ip
	read -p "请输入一个对端节点地址 (回车默认为 tcp://public.easytier.top:11010): " peer_address
	if [ -z "$peer_address" ]; then
		peer_address="tcp://public.easytier.top:11010"
		echo -e "${YELLOW}使用默认对端节点: ${peer_address}${NC}"
	fi

	create_default_config || return 1

	set_toml_value "network_name" "\"$network_name\"" "$CONFIG_FILE"
	set_toml_value "network_secret" "\"$network_secret\"" "$CONFIG_FILE"
	echo -e "\n[[peer]]\nuri = \"${peer_address}\"" >> "$CONFIG_FILE"

	if [ -z "$virtual_ip" ]; then
		echo -e "${YELLOW}未输入IP，将启用 DHCP 自动获取地址。${NC}"
		set_toml_value "dhcp" "true" "$CONFIG_FILE"
		set_toml_value "ipv4" "\"\"" "$CONFIG_FILE"
	else
		echo -e "${GREEN}已设置静态IP: ${virtual_ip}${NC}"
		set_toml_value "dhcp" "false" "$CONFIG_FILE"
		set_toml_value "ipv4" "\"$virtual_ip\"" "$CONFIG_FILE"
	fi

	create_service_file
	reload_service_daemon

	# [MODIFIED] 自动启用并重启服务
	echo -e "${YELLOW}正在设置开机自启并启动服务...${NC}"
	enable_service
	restart_service
	echo -e "${GREEN}--- 已加入网络，服务已启动并设为开机自启! ---${NC}"

	sleep 2; status_service
}

# --- 高级网络配置菜单 ---
advanced_config_menu() {
	check_installed || return 1
	if [ ! -f "$CONFIG_FILE" ]; then
		echo -e "${YELLOW}配置文件不存在，正在创建默认配置...${NC}"
		create_default_config || return 1
	fi

	while true; do
		clear
		echo "======================================================="
		echo -e "   ${BLUE}高级网络配置菜单${NC}"
		echo "======================================================="
		echo " --- 网络身份 ---"
		echo "  1. 修改网络名称 (network_name)"
		echo "  2. 修改网络密钥 (network_secret)"
		echo "  3. 修改虚拟IPv4地址 (ipv4)"
		echo "  4. 切换 DHCP 模式 (dhcp)"
		echo "  5. 设置主机名 (hostname)"
		echo "  6. 设置实例名 (instance_name)"
		echo ""
		echo " --- 监听与连接 ---"
		echo "  7. 管理监听地址 (listeners)"
		echo "  8. 管理对端节点 (peers)"
		echo "  9. 设置外部发现节点 (external_node)"
		echo " 10. 设置默认协议 (default_protocol)"
		echo " 11. 设置 RPC 管理端口 (rpc_portal)"
		echo " 12. 连接 Web 控制台 (web_server)"
		echo ""
		echo " --- 高级功能 ---"
		echo " 13. 出口节点 (exit node) 配置"
		echo " 14. 子网代理 (subnet proxy)"
		echo " 15. VPN Portal (WireGuard)"
		echo " 16. SOCKS5 代理服务器"
		echo " 17. 手动路由 (manual_routes)"
		echo ""
		echo " --- 性能与协议 ---"
		echo " 18. 设置 MTU"
		echo " 19. 延迟优先模式 (latency_first)"
		echo " 20. 多线程模式 (multi_thread)"
		echo ""
		echo " --- 开关选项 ---"
		echo " 21. 加密开关 (enable_encryption)"
		echo " 22. IPv6 开关 (enable_ipv6)"
		echo " 23. P2P 开关 (disable_p2p)"
		echo " 24. UDP 打洞开关 (disable_udp_hole_punching)"
		echo " 25. TUN 设备开关 (no_tun)"
		echo " 26. Smoltcp 栈开关 (use_smoltcp)"
		echo " 27. KCP 代理开关 (enableKcp_Proxy)"
		echo " 28. 中继所有 RPC (relay_all_peer_rpc)"
		echo " 29. 私有模式 (private_mode)"
		echo ""
		echo " --- 其他 ---"
		echo " 30. 日志配置"
		echo " 31. 路由白名单 (foreign_network_whitelist)"
		echo ""
		echo " ---"
		echo "  0. 返回主菜单"
		echo "======================================================="
		read -p "请输入选项 [0-31]: " sub

		case $sub in
		1) echo "当前网络名称: $(grep 'network_name' "$CONFIG_FILE" 2>/dev/null | sed 's/network_name\s*=\s*"\([^"]*\)"/\1/' || echo '(未设置)')";
		   read -p "新的网络名称: " val; set_toml_value "network_name" "\"$val\"" "$CONFIG_FILE" ;;
		2) echo "当前网络密钥: $(grep 'network_secret' "$CONFIG_FILE" 2>/dev/null | sed 's/network_secret\s*=\s*"\([^"]*\)"/\1/' || echo '(未设置)')";
		   read -p "新的网络密钥: " val; set_toml_value "network_secret" "\"$val\"" "$CONFIG_FILE" ;;
		3) echo "当前虚拟IPv4: $(grep 'ipv4' "$CONFIG_FILE" 2>/dev/null | sed 's/ipv4\s*=\s*"\([^"]*\)"/\1/' || echo '(未设置)')";
		   echo "当前 DHCP: $(grep 'dhcp' "$CONFIG_FILE" 2>/dev/null | sed 's/dhcp\s*=\s*\(.*\)/\1/' || echo 'false')";
		   read -p "新的虚拟IPv4地址 (留空则清空): " val;
		   if [ -z "$val" ]; then set_toml_value "ipv4" "\"\"" "$CONFIG_FILE"; set_toml_value "dhcp" "false" "$CONFIG_FILE";
		   else set_toml_value "ipv4" "\"$val\"" "$CONFIG_FILE"; set_toml_value "dhcp" "false" "$CONFIG_FILE"; fi ;;
		4) echo "当前 DHCP: $(grep 'dhcp' "$CONFIG_FILE" 2>/dev/null | sed 's/dhcp\s*=\s*\(.*\)/\1/' || echo 'false')";
		   read -p "是否启用 DHCP? (true/false): " val; set_toml_value "dhcp" "$val" "$CONFIG_FILE" ;;
		5) echo "当前主机名: $(grep 'hostname' "$CONFIG_FILE" 2>/dev/null | sed 's/hostname\s*=\s*"\([^"]*\)"/\1/' || echo '(系统默认)')";
		   read -p "主机名 (留空使用系统默认): " val; add_toml_entry "hostname" "\"$val\"" "$CONFIG_FILE" ;;
		6) echo "当前实例名: $(grep 'instance_name' "$CONFIG_FILE" 2>/dev/null | sed 's/instance_name\s*=\s*"\([^"]*\)"/\1/' || echo 'default')";
		   read -p "实例名 (用于区分多实例): " val; add_toml_entry "instance_name" "\"$val\"" "$CONFIG_FILE" ;;
		7) echo "当前监听地址:";
		   grep "^listeners" "$CONFIG_FILE" 2>/dev/null || echo "(未设置)"
		   echo "格式: [\"udp://0.0.0.0:11010\", \"tcp://0.0.0.0:11010\"]"
		   read -p "输入新的监听地址列表 (JSON数组格式): " val
		   if [ -n "$val" ]; then set_toml_value "listeners" "$val" "$CONFIG_FILE"; fi ;;
		8) echo "当前对端节点:";
		   grep "uri\s*=" "$CONFIG_FILE" 2>/dev/null || echo "(无)"
		   read -p "操作: [a]添加 [d]清空所有 [c]取消: " act
		   if [ "$act" = "a" ]; then read -p "对端节点URI (如 udp://1.2.3.4:11010): " val; add_peer_uri "$val" "$CONFIG_FILE";
		   elif [ "$act" = "d" ]; then sed -i.bak "/^\[\[peer\]\]/d;/^uri\s*=/d" "$CONFIG_FILE" && rm "${CONFIG_FILE}.bak"; echo -e "${YELLOW}已清空所有对端节点。${NC}"; fi ;;
		9) echo "当前外部发现节点: $(grep 'external_node' "$CONFIG_FILE" 2>/dev/null | sed 's/external_node\s*=\s*"\([^"]*\)"/\1/' || echo '(未设置)')";
		   read -p "外部发现节点地址 (如 udp://public.easytier.top:11010): " val; add_toml_entry "external_node" "\"$val\"" "$CONFIG_FILE" ;;
		10) echo "当前默认协议: $(grep 'default_protocol' "$CONFIG_FILE" 2>/dev/null | sed 's/default_protocol\s*=\s*"\([^"]*\)"/\1/' || echo 'udp')";
		    read -p "默认协议 (tcp/udp/wg/ws/wss): " val; set_toml_value "default_protocol" "\"$val\"" "$CONFIG_FILE" ;;
		11) echo "当前 RPC Portal:";
		    grep "^rpc_portal" "$CONFIG_FILE" 2>/dev/null || echo "(未设置，默认 ${DEFAULT_RPC_PORTAL})"
		    read -p "新的 RPC Portal (如 127.0.0.1:15888，0 为随机端口): " val
		    if [ -n "$val" ]; then add_toml_entry "rpc_portal" "\"$val\"" "$CONFIG_FILE"; fi ;;
		12) echo "连接 Web 控制台:"
		    echo "当前 web_server: $(cat "$CORE_WEB_SERVER_FILE" 2>/dev/null || echo '(未设置)')"
		    echo "格式: <protocol>://<host>:<port>/<username>"
		    echo "示例: udp://127.0.0.1:22020/admin"
		    echo ""
		    echo "注意: <username>是你在Web控制台注册的用户名，必须包含!"
		    read -p "Web 控制台地址 (留空则删除): " val
		    if [ -n "$val" ]; then
		        # 验证格式是否包含用户名部分
		        if [[ ! "$val" =~ ^[a-zA-Z]+://[^/]+/.+$ ]]; then
		            echo -e "${RED}错误: 地址格式不正确，缺少用户名部分!${NC}"
		            echo -e "${YELLOW}正确格式示例: udp://127.0.0.1:22020/admin${NC}"
		        else
		            # 写入单独的配置文件（不污染 TOML）
		            mkdir -p "$CONFIG_DIR"
		            echo "$val" > "$CORE_WEB_SERVER_FILE"
		            echo -e "${GREEN}已设置 web_server = ${val}${NC}"
		            echo -e "${YELLOW}配置已更新，正在重新生成服务文件并重启服务...${NC}"
		            create_service_file
		            reload_service_daemon
		            restart_service
		            echo -e "${GREEN}服务已重启，Core 将连接到 Web 控制台。${NC}"
		        fi
		    else
		        # 删除配置文件
		        rm -f "$CORE_WEB_SERVER_FILE"
		        echo -e "${YELLOW}已删除 Web 控制台连接配置。${NC}"
		        echo -e "${YELLOW}正在重新生成服务文件并重启服务...${NC}"
		        create_service_file
		        reload_service_daemon
		        restart_service
		    fi ;;
		13) echo "出口节点配置:"
		    echo "  enable_exit_node = $(grep 'enable_exit_node' "$CONFIG_FILE" 2>/dev/null || echo 'false')"
		    echo "  exit_nodes = $(grep 'exit_nodes' "$CONFIG_FILE" 2>/dev/null || echo '(空)')"
		    read -p "操作: [1]启用本节点为出口 [2]禁用出口 [3]设置出口节点列表 [0]返回: " eact
		    case $eact in
		        1) set_toml_value "enable_exit_node" "true" "$CONFIG_FILE" ;;
		        2) set_toml_value "enable_exit_node" "false" "$CONFIG_FILE" ;;
		        3) read -p "出口节点虚拟IP列表 (逗号分隔, 如 10.0.0.1,10.0.0.2): " val; add_exit_nodes "$val" "$CONFIG_FILE" ;;
		    esac ;;
		14) echo "子网代理:";
		    grep -A1 "\[\[proxy_network\]\]" "$CONFIG_FILE" 2>/dev/null | grep cidr || echo "(无)"
		    read -p "[a]添加子网 [d]清空所有 [c]取消: " pact
		    if [ "$pact" = "a" ]; then 
		        read -p "CIDR (如 192.168.1.0/24): " val; 
		        add_proxy_network "$val" "$CONFIG_FILE";
		        echo -e "${YELLOW}正在重启服务以应用子网代理配置...${NC}";
		        restart_service;
		    elif [ "$pact" = "d" ]; then 
		        sed -i.bak "/\[\[proxy_network\]\]/d;/cidr\s*=/d" "$CONFIG_FILE" && rm "${CONFIG_FILE}.bak"; 
		        echo -e "${YELLOW}已清空所有子网代理。${NC}";
		        echo -e "${YELLOW}正在重启服务以应用配置...${NC}";
		        restart_service;
		    fi ;;
		15) echo "VPN Portal (WireGuard 门户):"
		    grep "^vpn_portal" "$CONFIG_FILE" 2>/dev/null || echo "(未设置)"
		    read -p "VPN Portal 配置 (如 wg://0.0.0.0:11013/10.14.14.0/24，留空则删除): " val
		    if [ -n "$val" ]; then add_vpn_portal "$val" "$CONFIG_FILE";
		    else sed -i.bak "/^vpn_portal\s*=/d" "$CONFIG_FILE" && rm "${CONFIG_FILE}.bak"; echo -e "${YELLOW}已删除 VPN Portal 配置。${NC}"; fi ;;
		16) echo "SOCKS5 代理:"
		    grep "^socks5" "$CONFIG_FILE" 2>/dev/null || echo "(未设置)"
		    read -p "SOCKS5 端口 (如 1080，留空则删除): " val
		    if [ -n "$val" ]; then add_toml_entry "socks5" "\"$val\"" "$CONFIG_FILE";
		    else sed -i.bak "/^socks5\s*=/d" "$CONFIG_FILE" && rm "${CONFIG_FILE}.bak"; echo -e "${YELLOW}已删除 SOCKS5 配置。${NC}"; fi ;;
		17) echo "手动路由:"
		    grep "^manual_routes" "$CONFIG_FILE" 2>/dev/null || echo "(未设置，使用自动路由)"
		    read -p "手动路由 CIDR 列表 (逗号分隔, 如 10.1.0.0/16,10.2.0.0/16，留空则清空): " val
		    if [ -n "$val" ]; then add_manual_routes "$val" "$CONFIG_FILE";
		    else sed -i.bak "/^manual_routes\s*=/d" "$CONFIG_FILE" && rm "${CONFIG_FILE}.bak"; echo -e "${YELLOW}已清空手动路由。${NC}"; fi ;;
		18) echo "当前 MTU: $(grep 'mtu' "$CONFIG_FILE" 2>/dev/null | sed 's/mtu\s*=\s*\([0-9]*\)/\1/' || echo '1380')";
		    read -p "MTU 值 (加密默认1400，未加密默认1420): " val; set_toml_value "mtu" "$val" "$CONFIG_FILE" ;;
		19) echo "当前延迟优先模式: $(grep 'latency_first' "$CONFIG_FILE" 2>/dev/null | sed 's/latency_first\s*=\s*\(.*\)/\1/' || echo 'true')";
		    read -p "延迟优先模式 (true/false): " val; set_toml_value "latency_first" "$val" "$CONFIG_FILE" ;;
		20) echo "当前多线程模式: $(grep 'multi_thread' "$CONFIG_FILE" 2>/dev/null | sed 's/multi_thread\s*=\s*\(.*\)/\1/' || echo 'false')";
		    read -p "多线程模式 (true/false): " val; add_toml_entry "multi_thread" "$val" "$CONFIG_FILE" ;;
		21) echo "当前加密开关: $(grep 'enable_encryption' "$CONFIG_FILE" 2>/dev/null | sed 's/enable_encryption\s*=\s*\(.*\)/\1/' || echo 'true')";
		    read -p "启用加密 (true/false): " val; set_toml_value "enable_encryption" "$val" "$CONFIG_FILE" ;;
		22) echo "当前 IPv6 开关: $(grep 'enable_ipv6' "$CONFIG_FILE" 2>/dev/null | sed 's/enable_ipv6\s*=\s*\(.*\)/\1/' || echo 'true')";
		    read -p "启用 IPv6 (true/false): " val; set_toml_value "enable_ipv6" "$val" "$CONFIG_FILE" ;;
		23) echo "当前 P2P 开关: $(grep 'disable_p2p' "$CONFIG_FILE" 2>/dev/null | sed 's/disable_p2p\s*=\s*\(.*\)/\1/' || echo 'false')";
		    read -p "禁用 P2P (true/false): " val; set_toml_value "disable_p2p" "$val" "$CONFIG_FILE" ;;
		24) echo "当前 UDP 打洞开关: $(grep 'disable_udp_hole_punching' "$CONFIG_FILE" 2>/dev/null | sed 's/disable_udp_hole_punching\s*=\s*\(.*\)/\1/' || echo 'false')";
		    read -p "禁用 UDP 打洞 (true/false): " val; set_toml_value "disable_udp_hole_punching" "$val" "$CONFIG_FILE" ;;
		25) echo "当前 TUN 设备开关: $(grep 'no_tun' "$CONFIG_FILE" 2>/dev/null | sed 's/no_tun\s*=\s*\(.*\)/\1/' || echo 'false')";
		    read -p "不创建 TUN 设备 (true/false): " val; set_toml_value "no_tun" "$val" "$CONFIG_FILE" ;;
		26) echo "当前 Smoltcp 栈开关: $(grep 'use_smoltcp' "$CONFIG_FILE" 2>/dev/null | sed 's/use_smoltcp\s*=\s*\(.*\)/\1/' || echo 'false')";
		    read -p "启用 smoltcp 用户态栈 (true/false): " val; set_toml_value "use_smoltcp" "$val" "$CONFIG_FILE" ;;
		27) echo "当前 KCP 代理开关: $(grep 'enableKcp_Proxy' "$CONFIG_FILE" 2>/dev/null | sed 's/enableKcp_Proxy\s*=\s*\(.*\)/\1/' || echo 'true')";
		    read -p "启用 KCP 代理 (true/false): " val; set_toml_value "enableKcp_Proxy" "$val" "$CONFIG_FILE" ;;
		28) echo "当前中继所有 RPC: $(grep 'relay_all_peer_rpc' "$CONFIG_FILE" 2>/dev/null | sed 's/relay_all_peer_rpc\s*=\s*\(.*\)/\1/' || echo 'false')";
		    read -p "中继所有 Peer RPC (true/false): " val; set_toml_value "relay_all_peer_rpc" "$val" "$CONFIG_FILE" ;;
		29) echo "当前私有模式: $(grep 'private_mode' "$CONFIG_FILE" 2>/dev/null | sed 's/private_mode\s*=\s*\(.*\)/\1/' || echo 'true')";
		    read -p "私有模式 (true/false): " val; set_toml_value "private_mode" "$val" "$CONFIG_FILE" ;;
		30) echo "日志配置:"
		    echo "  console_log_level = $(grep 'console_log_level' "$CONFIG_FILE" 2>/dev/null || echo '(未设置)')"
		    echo "  file_log_level = $(grep 'file_log_level' "$CONFIG_FILE" 2>/dev/null || echo '(未设置)')"
		    echo "  file_log_dir = $(grep 'file_log_dir' "$CONFIG_FILE" 2>/dev/null || echo '(未设置)')"
		    read -p "控制台日志级别 (trace/debug/info/warn/error): " val; [ -n "$val" ] && add_toml_entry "console_log_level" "\"$val\"" "$CONFIG_FILE"
		    read -p "文件日志级别 (trace/debug/info/warn/error): " val; [ -n "$val" ] && add_toml_entry "file_log_level" "\"$val\"" "$CONFIG_FILE"
		    read -p "日志目录路径: " val; [ -n "$val" ] && add_toml_entry "file_log_dir" "\"$val\"" "$CONFIG_FILE" ;;
		31) echo "当前白名单: $(grep 'foreign_network_whitelist' "$CONFIG_FILE" 2>/dev/null || echo '(未设置)')"
		    read -p "路由白名单 (* 表示全部，空则禁用转发): " val
		    if [ -n "$val" ]; then set_toml_value "foreign_network_whitelist" "\"$val\"" "$CONFIG_FILE"; fi ;;
		0) break ;;
		*) echo -e "${RED}无效输入${NC}" ;;
		esac
		echo -e "\n${YELLOW}按任意键继续...${NC}"; read -n 1 -s -r
	done
}

# --- 防火墙管理菜单 ---
firewall_menu() {
	check_root || return 1
	local fw_type; fw_type=$(detect_firewall)

	while true; do
		clear
		echo "======================================================="
		echo -e "   ${BLUE}EasyTier 防火墙端口管理${NC}"
		echo "======================================================="
		echo -e " 检测到的防火墙: ${GREEN}${fw_type}${NC}"
		echo ""
		echo " 1. 检查 EasyTier 端口状态"
		echo " 2. 一键放行 EasyTier 所有端口"
		echo " 3. 一键关闭 EasyTier 所有端口"
		echo " 4. 手动开放单个端口"
		echo " 5. 手动关闭单个端口"
		echo ""
		echo " 0. 返回主菜单"
		echo "======================================================="
		read -p "请输入选项 [0-5]: " sub

		echo

		case $sub in
			1) check_all_easytier_ports ;;
			2) open_all_easytier_ports ;;
			3) close_all_easytier_ports ;;
			4) 
				read -p "请输入端口号: " port
				read -p "请输入协议 (tcp/udp): " protocol
				if [ -n "$port" ] && [ -n "$protocol" ]; then
					open_firewall_port "$port" "$protocol"
				else
					echo -e "${RED}端口和协议不能为空${NC}"
				fi
				;;
			5) 
				read -p "请输入端口号: " port
				read -p "请输入协议 (tcp/udp): " protocol
				if [ -n "$port" ] && [ -n "$protocol" ]; then
					close_firewall_port "$port" "$protocol"
				else
					echo -e "${RED}端口和协议不能为空${NC}"
				fi
				;;
			0) break ;;
			*) echo -e "${RED}无效输入${NC}" ;;
		esac
		echo -e "\n${YELLOW}按任意键继续...${NC}"; read -n 1 -s -r
	done
}

# --- 公共节点管理菜单 ---
public_nodes_menu() {
	while true; do
		clear
		echo "======================================================="
		echo -e "   ${BLUE}EasyTier 公共节点管理${NC}"
		echo "======================================================="
		echo " 1. 查看公共节点列表"
		echo " 2. 测试所有节点延迟"
		echo " 3. 查看延迟排名结果"
		echo " 4. 一键使用最快节点（自动添加为 Peer）"
		echo " 5. 手动选择节点添加为 Peer"
		echo " 6. 刷新节点缓存（重新测速）"
		echo ""
		echo " 0. 返回主菜单"
		echo "======================================================="
		read -p "请输入选项 [0-6]: " sub

		echo

		case $sub in
			1) 
				echo -e "${BLUE}--- 公共节点列表 ---${NC}"
				echo ""
				echo "官方节点:"
				for node in "${BUILTIN_PUBLIC_NODES[@]}"; do
					echo "  ${GREEN}✓${NC} $node"
				done
				echo ""
				echo "社区节点:"
				for node in "${BUILTIN_COMMUNITY_NODES[@]}"; do
					echo "  ${GREEN}✓${NC} $node"
				done
				echo ""
				echo -e "${YELLOW}提示: 还可以从官方 API 获取更多节点（选项2测速时自动获取）${NC}"
				;;
			2) test_all_nodes ;;
			3) show_latency_results ;;
			4) select_fastest_node ;;
			5) select_node_manually ;;
			6) 
				rm -f "$NODES_CACHE_FILE"
				echo -e "${GREEN}已清除缓存，下次测速将重新获取节点列表。${NC}"
				;;
			0) break ;;
			*) echo -e "${RED}无效输入${NC}" ;;
		esac
		echo -e "\n${YELLOW}按任意键继续...${NC}"; read -n 1 -s -r
	done
}

# --- Web 配置菜单 ---
web_config_menu() {
	check_web_installed || return 1
	mkdir -p "$WEB_CONFIG_DIR"

	while true; do
		clear
		echo "======================================================="
		echo -e "   ${BLUE}EasyTier Web 控制台配置${NC}"
		echo "======================================================="
		echo " Web 前端/API 端口:    ${DEFAULT_API_SERVER_PORT}"
		echo " API 主机地址:         http://127.0.0.1:${DEFAULT_API_SERVER_PORT}"
		echo " 配置下发端口:         ${DEFAULT_CONFIG_SERVER_PORT}"
		echo " 配置下发协议:         ${DEFAULT_CONFIG_SERVER_PROTOCOL}"
		echo " 数据库路径:           ${WEB_DB_FILE}"
		echo "======================================================="
		echo " 1. 生成/更新 Web 服务文件"
		echo " 2. 配置 Web 控制台参数 (重新生成服务文件)"
		echo " 3. 启动 Web 服务"
		echo " 4. 停止 Web 服务"
		echo " 5. 重启 Web 服务"
		echo " 6. 查看 Web 服务状态"
		echo " 7. 设为开机自启"
		echo " 8. 取消开机自启"
		echo " 9. 查看 Web 服务日志"
		echo " 0. 返回主菜单"
		echo "======================================================="
		read -p "请输入选项 [0-9]: " sub

		case $sub in
		1) create_web_service_file; reload_service_daemon ;;
		2) echo "配置 Web 控制台参数:"
		   read -p "API 服务器端口 (默认 11211): " api_port; api_port=${api_port:-11211}
		   read -p "API 主机地址 (默认 http://127.0.0.1:11211): " api_host; api_host=${api_host:-"http://127.0.0.1:11211"}
		   read -p "配置下发端口 (默认 22020): " cfg_port; cfg_port=${cfg_port:-22020}
		   read -p "配置下发协议 (udp/tcp/ws, 默认 udp): " cfg_proto; cfg_proto=${cfg_proto:-udp}
		   read -p "Web 额外端口 (可选，留空跳过): " web_port
		   read -p "数据库路径 (默认 ${WEB_DB_FILE}): " db_path; db_path=${db_path:-"$WEB_DB_FILE"}

		   # 重建服务文件
		   if [[ "$OS_TYPE" == "macos" || "$OS_TYPE" == "alpine" ]]; then
		       touch "$WEB_LOG_FILE"; chown root:root "$WEB_LOG_FILE" &>/dev/null; chmod 644 "$WEB_LOG_FILE"
		   fi
		   local extra_args=""
		   [ -n "$web_port" ] && extra_args=" --web-server-port ${web_port}"

		   if [[ "$OS_TYPE" == "linux" ]]; then
		       cat > "${WEB_SERVICE_FILE}" << EOL
[Unit]
Description=EasyTier Web Console Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${WEB_CONFIG_DIR}
ExecStart=${INSTALL_DIR}/${WEB_BINARY_NAME} --db ${db_path} --api-server-port ${api_port} --api-host "${api_host}" --config-server-port ${cfg_port} --config-server-protocol ${cfg_proto}${extra_args}
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL
		   elif [[ "$OS_TYPE" == "alpine" ]]; then
		       cat > "${WEB_SERVICE_FILE}" << EOL
#!/sbin/openrc-run
description="EasyTier Web Console with Supervisor"
supervisor=supervise-daemon
command="${INSTALL_DIR}/${WEB_BINARY_NAME}"
command_args="--db ${db_path} --api-server-port ${api_port} --api-host ${api_host} --config-server-port ${cfg_port} --config-server-protocol ${cfg_proto}${extra_args}"
command_user="root"
pidfile="/var/run/${WEB_SERVICE_NAME}.pid"
output_log="${WEB_LOG_FILE}"
error_log="${WEB_LOG_FILE}"
directory="${WEB_CONFIG_DIR}"
depend() {
	need net
	after net
}
EOL
		       chmod +x "${WEB_SERVICE_FILE}";
		   elif [[ "$OS_TYPE" == "macos" ]]; then
		       local web_args="<string>${INSTALL_DIR}/${WEB_BINARY_NAME}</string>
					<string>--db</string>
					<string>${db_path}</string>
					<string>--api-server-port</string>
					<string>${api_port}</string>
					<string>--api-host</string>
					<string>${api_host}</string>
					<string>--config-server-port</string>
					<string>${cfg_port}</string>
					<string>--config-server-protocol</string>
					<string>${cfg_proto}</string>"
		       [ -n "$web_port" ] && web_args="${web_args}
					<string>--web-server-port</string>
					<string>${web_port}</string>"
		       cat > "${WEB_SERVICE_FILE}" << EOL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${WEB_SERVICE_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        ${web_args}
    </array>
    <key>WorkingDirectory</key>
    <string>${WEB_CONFIG_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${WEB_LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${WEB_LOG_FILE}</string>
</dict>
</plist>
EOL
		   fi
		   reload_service_daemon
		   echo -e "${GREEN}Web 服务文件已重新生成并含自定义参数。${NC}"
		   echo -e "${YELLOW}提示: 浏览器访问 ${api_host} 即可打开 Web 控制台。${NC}" ;;
		3) start_web_service && echo -e "${GREEN}Web 服务已启动。${NC}" ;;
		4) stop_web_service && echo -e "${GREEN}Web 服务已停止。${NC}" ;;
		5) restart_web_service && echo -e "${GREEN}Web 服务已重启。${NC}" ;;
		6) status_web_service ;;
		7) enable_web_service ;;
		8) disable_web_service ;;
		9) log_web_service ;;
		0) break ;;
		*) echo -e "${RED}无效输入${NC}" ;;
		esac
		if [ "$sub" != "0" ] && [ "$sub" != "9" ]; then
			echo -e "\n${YELLOW}按任意键继续...${NC}"; read -n 1 -s -r
		fi
	done
}

# --- CLI 工具箱 ---
cli_toolbox_menu() {
	check_installed || return 1
	while true; do
		clear
		echo "======================================================="
		echo -e "   ${BLUE}CLI 工具箱${NC}"
		echo "======================================================="
		echo " 1. 查看所有在线节点 (peer)"
		echo " 2. 查看路由表 (route)"
		echo " 3. 查看本节点信息 (node)"
		echo " 4. 查看 VPN Portal 客户端配置 (vpn-portal)" 
		echo " 5. 查看帮助信息 (--help)"
		echo " 6. 查看版本信息 (--version)"
		echo " 7. 执行自定义 CLI 命令"
		echo " 0. 返回主菜单"
		echo "======================================================="
		read -p "请输入选项 [0-7]: " sub

		case $sub in
		1) echo -e "${GREEN}--- Online Peers ---${NC}"
		   ${INSTALL_DIR}/${CLI_BINARY_NAME} peer ;;
		2) echo -e "${GREEN}--- Routes ---${NC}"
		   ${INSTALL_DIR}/${CLI_BINARY_NAME} route ;;
		3) echo -e "${GREEN}--- Node Info ---${NC}"
		   ${INSTALL_DIR}/${CLI_BINARY_NAME} node ;;
		4) echo -e "${GREEN}--- VPN Portal Config ---${NC}"
		   echo "注意: 此功能需要 easytier-core 已配置 vpn_portal 参数。"
		   ${INSTALL_DIR}/${CLI_BINARY_NAME} vpn-portal 2>/dev/null || echo -e "${YELLOW}获取 VPN Portal 信息失败（可能未配置）。${NC}" ;;
		5) ${INSTALL_DIR}/${CORE_BINARY_NAME} --help 2>/dev/null | head -60
		   echo -e "\n${YELLOW}(显示 easytier-core 帮助，按任意键继续...)${NC}"; read -n 1 -s -r ;;
		6) ${INSTALL_DIR}/${CORE_BINARY_NAME} --version 2>/dev/null
		   ${INSTALL_DIR}/${CLI_BINARY_NAME} --version 2>/dev/null
		   if [ -f "${INSTALL_DIR}/${WEB_BINARY_NAME}" ]; then
		       echo -n "Web: "; ${INSTALL_DIR}/${WEB_BINARY_NAME} --version 2>/dev/null || echo "(无法获取版本)"
		   fi ;;
		7) read -p "输入自定义 CLI 命令参数 (如 peer --detail): " custom_args
		   if [ -n "$custom_args" ]; then ${INSTALL_DIR}/${CLI_BINARY_NAME} $custom_args; fi ;;
		0) break ;;
		*) echo -e "${RED}无效输入${NC}" ;;
		esac
		if [ "$sub" != "0" ] && [ "$sub" != "5" ]; then
			echo -e "\n${YELLOW}按任意键继续...${NC}"; read -n 1 -s -r
		fi
	done
}

# --- Core 服务管理菜单 ---
manage_service() {
	check_installed || return 1
	PS3="请选择操作: "
	options=("启动" "停止" "重启" "状态" "设为开机自启" "取消开机自启" "查看日志" "返回")
	select opt in "${options[@]}"; do
		case $opt in
			"启动") start_service && echo -e "${GREEN}EasyTier Core 服务已启动。${NC}"; break ;;
			"停止") stop_service && echo -e "${GREEN}EasyTier Core 服务已停止。${NC}"; break ;;
			"重启") restart_service && echo -e "${GREEN}EasyTier Core 服务已重启。${NC}"; break ;;
			"状态") status_service; break ;;
			"设为开机自启") enable_service; break ;;
			"取消开机自启") disable_service; break ;;
			"查看日志") log_service; break ;;
			"返回") break ;;
		esac
	done
}

# --- Web 服务管理菜单 ---
manage_web_service() {
	check_web_installed || return 1
	if [ ! -f "$WEB_SERVICE_FILE" ]; then
		echo -e "${YELLOW}Web 服务文件不存在，正在创建...${NC}"
		create_web_service_file
		reload_service_daemon
	fi
	PS3="请选择操作: "
	options=("启动" "停止" "重启" "状态" "设为开机自启" "取消开机自启" "查看日志" "返回")
	select opt in "${options[@]}"; do
		case $opt in
			"启动") start_web_service && echo -e "${GREEN}EasyTier Web 服务已启动。${NC}"; break ;;
			"停止") stop_web_service && echo -e "${GREEN}EasyTier Web 服务已停止。${NC}"; break ;;
			"重启") restart_web_service && echo -e "${GREEN}EasyTier Web 服务已重启。${NC}"; break ;;
			"状态") status_web_service; break ;;
			"设为开机自启") enable_web_service; break ;;
			"取消开机自启") disable_web_service; break ;;
			"查看日志") log_web_service; break ;;
			"返回") break ;;
		esac
	done
}

# --- 卸载函数 (修改以包含 Web 清理) ---
uninstall_easytier() {
	read -p "警告: 此操作将停止服务并删除所有相关文件。确定要卸载吗? (y/n): " confirm
	if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then echo "操作已取消。"; return; fi

	read -p "卸载选项: [1]仅 Core [2]仅 Web [3]全部 [0]取消: " uopt
	case $uopt in
	1)
		echo "正在停止并禁用 EasyTier Core 服务..."
		stop_service &> /dev/null; disable_service &> /dev/null
		echo "正在删除 Core 文件..."
		rm -f "${SERVICE_FILE}" "${INSTALL_DIR}/${CORE_BINARY_NAME}" "${INSTALL_DIR}/${CLI_BINARY_NAME}"
		rm -rf "${CONFIG_DIR}"
		remove_shortcut
		if [[ "$OS_TYPE" == "linux" ]]; then systemctl daemon-reload; fi
		if [[ "$OS_TYPE" == "macos" || "$OS_TYPE" == "alpine" ]]; then rm -f "$LOG_FILE"; fi
		echo -e "${GREEN}EasyTier Core 已成功卸载。${NC}"
		;;
	2)
		echo "正在停止并禁用 EasyTier Web 服务..."
		stop_web_service &> /dev/null; disable_web_service &> /dev/null
		echo "正在删除 Web 文件..."
		rm -f "${WEB_SERVICE_FILE}" "${INSTALL_DIR}/${WEB_BINARY_NAME}"
		rm -rf "${WEB_CONFIG_DIR}"
		if [[ "$OS_TYPE" == "linux" ]]; then systemctl daemon-reload; fi
		if [[ "$OS_TYPE" == "macos" || "$OS_TYPE" == "alpine" ]]; then rm -f "$WEB_LOG_FILE"; fi
		echo -e "${GREEN}EasyTier Web 已成功卸载。${NC}"
		;;
	3)
		echo "正在停止并禁用所有服务..."
		stop_service &> /dev/null; disable_service &> /dev/null
		stop_web_service &> /dev/null; disable_web_service &> /dev/null
		echo "正在删除所有文件..."
		rm -f "${SERVICE_FILE}" "${WEB_SERVICE_FILE}"
		rm -f "${INSTALL_DIR}/${CORE_BINARY_NAME}" "${INSTALL_DIR}/${CLI_BINARY_NAME}" "${INSTALL_DIR}/${WEB_BINARY_NAME}"
		rm -rf "${CONFIG_DIR}" "${WEB_CONFIG_DIR}"
		remove_shortcut
		if [[ "$OS_TYPE" == "linux" ]]; then systemctl daemon-reload; fi
		if [[ "$OS_TYPE" == "macos" || "$OS_TYPE" == "alpine" ]]; then rm -f "$LOG_FILE" "$WEB_LOG_FILE"; fi
		echo -e "${GREEN}EasyTier 全部组件已成功卸载。${NC}"
		;;
	0|*) echo "操作已取消。" ;;
	esac
}


# --- 主菜单 ---
main() {
	# 修复 set_toml_value 与旧版不兼容的问题
	set_toml_value() {
		sed -i.bak "s|^#* *${1} *=.*|${1} = ${2}|" "$3" && rm "${3}.bak"
	}

	case "$(uname)" in
		Linux) if [ -f /etc/alpine-release ]; then OS_TYPE="alpine"; SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"; else OS_TYPE="linux"; SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"; fi ;;
		Darwin) OS_TYPE="macos"; SERVICE_FILE="/Library/LaunchDaemons/${SERVICE_LABEL}.plist"; ;;
		*) echo -e "${RED}错误: 不支持的操作系统: $(uname)${NC}"; exit 1 ;;
	esac

	# 设置 Web 服务文件路径
	if [[ "$OS_TYPE" == "linux" ]]; then WEB_SERVICE_FILE="/etc/systemd/system/${WEB_SERVICE_NAME}.service";
	elif [[ "$OS_TYPE" == "alpine" ]]; then WEB_SERVICE_FILE="/etc/init.d/${WEB_SERVICE_NAME}";
	elif [[ "$OS_TYPE" == "macos" ]]; then WEB_SERVICE_FILE="/Library/LaunchDaemons/${WEB_SERVICE_LABEL}.plist"; fi

	check_root; check_dependencies

	while true; do
		clear
		echo "======================================================="
		echo -e "   ${GREEN}EasyTier 全能管理脚本${NC}"
		echo -e "   跨平台部署 Debian/Ubuntu/Mac/Alpine"
		echo "======================================================="
		echo -e " ${BLUE}--- 安装与部署 ---${NC}"
		echo "  1. 安装或更新 EasyTier Core"
		echo "  2. 安装或更新 EasyTier Web (${WEB_BINARY_NAME})"
		echo "  3. 部署新网络 (首个节点)"
		echo "  4. 加入现有组网网络"
		echo ""
		echo -e " ${BLUE}--- 网络配置 ---${NC}"
		echo "  5. 高级网络配置 (全部 CLI 参数)"
		echo "  6. 查看当前配置文件"
		echo ""
		echo -e " ${BLUE}--- 服务管理 ---${NC}"
		echo "  7. 管理 EasyTier Core 服务"
		echo "  8. 管理 EasyTier Web 服务"
		echo ""
		echo -e " ${BLUE}--- 运维工具 ---${NC}"
		echo "  9. CLI 工具箱 (peer/route/vpn-portal/node)"
		echo " 10. 查看组网节点"
		echo " 13. 公共节点管理（测速+一键最快）"
		echo " 12. 防火墙端口管理"
		echo ""
		echo -e " ${RED}--- 系统 ---${NC}"
		echo " 11. 卸载 EasyTier"
		echo "  0. 退出脚本"
		echo "======================================================="
		read -p "请输入选项 [0-13]: " choice
		
		echo
		
		case $choice in
			1) install_easytier ;;
			2) install_web ;;
			3) deploy_new_network ;;
			4) join_existing_network ;;
			5) advanced_config_menu ;;
			6) if check_installed && [ -f "$CONFIG_FILE" ]; then cat "$CONFIG_FILE"; else echo -e "${YELLOW}配置文件不存在或未安装。${NC}"; fi ;;
			7) manage_service ;;
			8) manage_web_service ;;
			9) cli_toolbox_menu ;;
			10) if check_installed; then ${INSTALL_DIR}/${CLI_BINARY_NAME} peer; fi ;;
			13) public_nodes_menu ;;
			12) firewall_menu ;;
			11) uninstall_easytier ;;
			0) exit 0 ;;
			*) echo -e "${RED}无效输入${NC}" ;;
		esac
		echo -e "\n${YELLOW}按任意键返回主菜单...${NC}"; read -n 1 -s -r
	done
}

# 将 set_toml_value 函数定义移到 main 函数内部，以覆盖全局定义
main "$@"
