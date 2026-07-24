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


# --- 平台相关的 Core 服务管理功能 ---

create_service_file() {
    if [[ "$OS_TYPE" == "macos" || "$OS_TYPE" == "alpine" ]]; then
        touch "$LOG_FILE"
        chown root:root "$LOG_FILE" &>/dev/null
        chmod 644 "$LOG_FILE"
    fi

    # 读取 web_server 配置（用于连接 Web 控制台）
    local web_server_config=""
    if [ -f "$CONFIG_FILE" ]; then
        web_server_config=$(grep "^web_server\s*=" "$CONFIG_FILE" 2>/dev/null | sed 's/^web_server\s*=\s*"\([^"]*\)"/\1/')
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
        local web_server_xml=""
        if [ -n "$web_server_config" ]; then
            web_server_xml="<string>-w</string>\n        <string>${web_server_config}</string>"
        fi
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
        ${web_server_xml}
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
# 连接 Web 控制台配置（通过高级配置菜单设置，格式: udp://127.0.0.1:22020/admin）
# web_server = ""
EOF
	if [ $? -eq 0 ]; then echo "已成功创建默认配置文件: ${CONFIG_FILE}"; return 0;
	else echo -e "${RED}错误: 创建配置文件失败!${NC}"; return 1; fi; }

deploy_new_network() { 
	check_installed || return 1
	read -p "请输入网络名称: " network_name
	read -p "请输入网络密钥: " network_secret
	read -p "请输入此虚拟IP (回车则启用DHCP): " virtual_ip
	
	create_default_config || return 1
	
	set_toml_value "network_name" "\"$network_name\"" "$CONFIG_FILE"
	set_toml_value "network_secret" "\"$network_secret\"" "$CONFIG_FILE"
	
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
		1) read -p "新的网络名称: " val; set_toml_value "network_name" "\"$val\"" "$CONFIG_FILE" ;;
		2) read -p "新的网络密钥: " val; set_toml_value "network_secret" "\"$val\"" "$CONFIG_FILE" ;;
		3) read -p "新的虚拟IPv4地址 (留空则清空): " val;
		   if [ -z "$val" ]; then set_toml_value "ipv4" "\"\"" "$CONFIG_FILE"; set_toml_value "dhcp" "false" "$CONFIG_FILE";
		   else set_toml_value "ipv4" "\"$val\"" "$CONFIG_FILE"; set_toml_value "dhcp" "false" "$CONFIG_FILE"; fi ;;
		4) read -p "是否启用 DHCP? (true/false): " val; set_toml_value "dhcp" "$val" "$CONFIG_FILE" ;;
		5) read -p "主机名 (留空使用系统默认): " val; add_toml_entry "hostname" "\"$val\"" "$CONFIG_FILE" ;;
		6) read -p "实例名 (用于区分多实例): " val; add_toml_entry "instance_name" "\"$val\"" "$CONFIG_FILE" ;;
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
		9) read -p "外部发现节点地址 (如 udp://public.easytier.top:11010): " val; add_toml_entry "external_node" "\"$val\"" "$CONFIG_FILE" ;;
		10) read -p "默认协议 (tcp/udp/wg/ws/wss): " val; set_toml_value "default_protocol" "\"$val\"" "$CONFIG_FILE" ;;
		11) echo "当前 RPC Portal:";
		    grep "^rpc_portal" "$CONFIG_FILE" 2>/dev/null || echo "(未设置，默认 ${DEFAULT_RPC_PORTAL})"
		    read -p "新的 RPC Portal (如 127.0.0.1:15888，0 为随机端口): " val
		    if [ -n "$val" ]; then add_toml_entry "rpc_portal" "\"$val\"" "$CONFIG_FILE"; fi ;;
		12) echo "连接 Web 控制台:"
		    echo "当前 web_server: $(grep "^web_server" "$CONFIG_FILE" 2>/dev/null || echo '(未设置)')"
		    echo "格式: <protocol>://<host>:<port>/<username>"
		    echo "示例: udp://127.0.0.1:22020/admin"
		    read -p "Web 控制台地址 (留空则删除): " val
		    if [ -n "$val" ]; then add_toml_entry "web_server" "\"$val\"" "$CONFIG_FILE";
		    else sed -i.bak "/^web_server\s*=/d" "$CONFIG_FILE" && rm "${CONFIG_FILE}.bak"; echo -e "${YELLOW}已删除 Web 控制台连接配置。${NC}"; fi ;;
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
		    if [ "$pact" = "a" ]; then read -p "CIDR (如 192.168.1.0/24): " val; add_proxy_network "$val" "$CONFIG_FILE";
		    elif [ "$pact" = "d" ]; then sed -i.bak "/\[\[proxy_network\]\]/d;/cidr\s*=/d" "$CONFIG_FILE" && rm "${CONFIG_FILE}.bak"; echo -e "${YELLOW}已清空所有子网代理。${NC}"; fi ;;
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
		18) read -p "MTU 值 (加密默认1400，未加密默认1420): " val; set_toml_value "mtu" "$val" "$CONFIG_FILE" ;;
		19) read -p "延迟优先模式 (true/false): " val; set_toml_value "latency_first" "$val" "$CONFIG_FILE" ;;
		20) read -p "多线程模式 (true/false): " val; add_toml_entry "multi_thread" "$val" "$CONFIG_FILE" ;;
		21) read -p "启用加密 (true/false): " val; set_toml_value "enable_encryption" "$val" "$CONFIG_FILE" ;;
		22) read -p "启用 IPv6 (true/false): " val; set_toml_value "enable_ipv6" "$val" "$CONFIG_FILE" ;;
		23) read -p "禁用 P2P (true/false): " val; set_toml_value "disable_p2p" "$val" "$CONFIG_FILE" ;;
		24) read -p "禁用 UDP 打洞 (true/false): " val; set_toml_value "disable_udp_hole_punching" "$val" "$CONFIG_FILE" ;;
		25) read -p "不创建 TUN 设备 (true/false): " val; set_toml_value "no_tun" "$val" "$CONFIG_FILE" ;;
		26) read -p "启用 smoltcp 用户态栈 (true/false): " val; set_toml_value "use_smoltcp" "$val" "$CONFIG_FILE" ;;
		27) read -p "启用 KCP 代理 (true/false): " val; set_toml_value "enableKcp_Proxy" "$val" "$CONFIG_FILE" ;;
		28) read -p "中继所有 Peer RPC (true/false): " val; set_toml_value "relay_all_peer_rpc" "$val" "$CONFIG_FILE" ;;
		29) read -p "私有模式 (true/false): " val; set_toml_value "private_mode" "$val" "$CONFIG_FILE" ;;
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
		echo ""
		echo -e " ${RED}--- 系统 ---${NC}"
		echo " 11. 卸载 EasyTier"
		echo "  0. 退出脚本"
		echo "======================================================="
		read -p "请输入选项 [0-11]: " choice
		
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
			11) uninstall_easytier ;;
			0) exit 0 ;;
			*) echo -e "${RED}无效输入${NC}" ;;
		esac
		echo -e "\n${YELLOW}按任意键返回主菜单...${NC}"; read -n 1 -s -r
	done
}

# 将 set_toml_value 函数定义移到 main 函数内部，以覆盖全局定义
main "$@"
