## 产品概述
基于现有 `easytier.sh` 脚本改造为 EasyTier 全能管理脚本，新增 easytier-web-embed Web 控制台安装与配置、完整覆盖所有 CLI 参数的高级配置菜单、Web 服务管理、CLI 工具箱等功能。保持二进制直接安装方式，兼容 Linux(systemd)、Alpine(OpenRC)、macOS(Launchd) 三大平台。

## 核心功能
- **双组件安装**：同一菜单下分别安装/更新 easytier-core + easytier-cli 和 easytier-web-embed
- **完整 CLI 参数覆盖**：高级网络配置子菜单，逐项管理所有 easytier-core 命令行参数（网络身份、监听连接、exit node、subnet proxy、VPN Portal、SOCKS5、RPC portal、手动路由、多线程、日志级别、加密开关等），交互式修改后自动写入 TOML 配置文件
- **Web 服务管理**：独立的 Web 控制台服务生命周期管理（启动/停止/重启/状态/开机自启/日志），支持 Web 专属参数配置（API端口、配置下发端口、协议、数据库路径等）
- **CLI 工具箱**：封装 easytier-cli 常用运维命令（peer查看、route路由表、vpn-portal管理、node信息）
- **主菜单重构**：按"安装部署 → 网络配置 → 服务管理 → 运维工具"四大板块组织，清晰导航

## 技术栈
- Shell 脚本：Bash（保持与现有脚本一致）
- 配置格式：TOML（使用 sed 进行键值修改）
- 平台适配：systemd / OpenRC / Launchd 服务管理
- 依赖工具：curl、jq、unzip（与现有依赖一致）
- GitHub API：获取最新 Release 版本信息

## 实施方案

### 总体策略
在现有 `easytier.sh` 基础上**增量扩展**，不重写已有功能。核心思路：
1. 修改 `install_easytier()` 使其同时提取 easytier-web-embed 二进制
2. 新增 Web 服务管理函数族（复用现有 Core 服务管理的平台适配模式）
3. 新增高级配置子菜单，逐参数交互式配置
4. 新增 Web 配置子菜单
5. 新增 CLI 工具箱子菜单
6. 重构主菜单布局

### 关键技术决策

**1. Web 服务管理独立于 Core 服务**
- 理由：Web 控制台是可选组件，不是每个节点都需要
- 实现：新增独立的 `WEB_SERVICE_NAME`、`WEB_SERVICE_FILE`、`WEB_LOG_FILE` 变量，以及独立的 `create_web_service_file()`、`start_web_service()` 等函数族

**2. 高级配置使用两级菜单深度**
- 理由：20+ 个配置参数不能全部平铺在主菜单
- 实现：主菜单新增"高级网络配置"入口 → 子菜单按功能分组（网络身份/监听连接/高级功能/性能协议/开关选项/日志配置）

**3. install_easytier() 统一提取所有二进制**
- 理由：easytier-web-embed 与 easytier-core/cli 打包在同一个 Release zip 中
- 实现：在现有的解压后文件移动逻辑中，增加对 easytier-web-embed 的查找和安装

**4. 配置持久化策略**
- 新增参数超出当前 `create_default_config()` 的 TOML 模板范围（如 proxy_networks、exit_nodes、vpn_portal、socks5、rpc_portal、hostname、instance_name、multi_thread 等）
- 采用**动态追加**方式：默认配置模板保持现有内容，高级参数通过 `add_toml_entry()` 新函数按需追加到配置文件

### 实施注意事项

**性能考虑**
- 菜单项数量增加但仅涉及文本 I/O，无性能瓶颈
- jq 解析 GitHub API 为单次网络请求，已有缓存策略（curl 一次性获取）

**向后兼容**
- 所有现有菜单选项编号和行为保持不变（1-7 保留原功能）
- 新增功能使用 8+ 编号和子菜单
- 已有的 `deploy_new_network()` 和 `join_existing_network()` 内部逻辑不变

**日志与错误处理**
- 复用现有的颜色输出体系（GREEN/RED/YELLOW/BLUE）
- Web 服务管理新增独立日志路径 `/var/log/easytier-web.log`
- 高级配置菜单中每个参数修改后即时反馈成功/失败

## 架构设计

### 系统架构
脚本采用扁平函数式架构，函数按职责分组：

```
┌─────────────────────────────────────────────┐
│                  main()                      │
│  ├─ 平台检测 (OS_TYPE / SERVICE_FILE)        │
│  ├─ 依赖检查                                  │
│  └─ 主菜单循环                                │
│      ├─ 安装与部署板块                         │
│      │   ├─ install_easytier() [MODIFIED]    │
│      │   └─ install_web() [NEW]              │
│      ├─ 网络配置板块                           │
│      │   ├─ deploy_new_network() [KEPT]      │
│      │   ├─ join_existing_network() [KEPT]   │
│      │   └─ advanced_config_menu() [NEW]     │
│      ├─ 服务管理板块                           │
│      │   ├─ manage_service() [KEPT]          │
│      │   └─ manage_web_service() [NEW]       │
│      └─ 运维工具板块                           │
│          ├─ cli_toolbox_menu() [NEW]         │
│          ├─ view_config() [KEPT]             │
│          └─ uninstall_easytier() [MODIFIED]  │
└─────────────────────────────────────────────┘
```

### 数据流
```
用户输入参数 → 函数处理 → set_toml_value() / add_toml_entry()
    → 写入 CONFIG_FILE (TOML格式)
    → create_service_file() 生成服务文件
    → reload_service_daemon() + restart_service() 生效
```

## 目录结构

仅修改一个文件，无新增文件：

```
/home/leon/develop/github/onekeyeasytier/
└── easytier.sh  # [MODIFY] 全能管理脚本
    ├── [配置段] 新增 WEB_* 变量、高级配置默认值
    ├── [NEW] check_web_installed() - 检查 Web 组件是否安装
    ├── [NEW] add_toml_entry() - 动态追加 TOML 条目
    ├── [NEW] add_toml_array() - 动态追加 TOML 数组条目
    ├── [MODIFY] install_easytier() - 同时提取 easytier-web-embed
    ├── [NEW] install_web() - 单独安装/更新 Web 组件
    ├── [NEW] create_web_service_file() - 生成 Web 服务文件
    ├── [NEW] start_web_service/stop_web_service/restart_web_service
    ├── [NEW] enable_web_service/disable_web_service/status_web_service/log_web_service
    ├── [KEPT] deploy_new_network() / join_existing_network()
    ├── [NEW] advanced_config_menu() - 高级配置子菜单 (20+ 参数)
    ├── [NEW] web_config_menu() - Web 配置子菜单
    ├── [NEW] manage_web_service() - Web 服务管理子菜单
    ├── [NEW] cli_toolbox_menu() - CLI 工具箱子菜单
    ├── [MODIFY] uninstall_easytier() - 同时清理 Web 组件
    └── [MODIFY] main() - 主菜单重构为四大板块布局
```

## 关键代码结构

### 新增变量定义
```bash
# Web 组件路径
WEB_BINARY_NAME="easytier-web-embed"
WEB_CONFIG_DIR="${CONFIG_DIR}/web"
WEB_DB_FILE="${WEB_CONFIG_DIR}/et.db"
WEB_SERVICE_NAME="easytier-web"
WEB_SERVICE_FILE=""  # 平台相关，在 main() 中设置
WEB_LOG_FILE="/var/log/easytier-web.log"
WEB_SERVICE_LABEL="com.easytier.web"

# 高级配置默认值
DEFAULT_RPC_PORTAL="127.0.0.1:15888"
DEFAULT_CONSOLE_LOG_LEVEL="info"
DEFAULT_API_SERVER_PORT="11211"
DEFAULT_CONFIG_SERVER_PORT="22020"
DEFAULT_CONFIG_SERVER_PROTOCOL="udp"
```

### 函数签名（关键新增）
```bash
# 动态添加 TOML 条目（用于默认模板中不存在的参数）
add_toml_entry() {
    # $1=section (如 "proxy_network"), $2=key, $3=value, $4=file
    # 如果 section/key 已存在则更新，否则追加
}

# 动态添加 TOML 数组条目
add_toml_array() {
    # $1=section, $2=key, $3=value, $4=file
}

# 高级配置菜单（函数式架构，每个参数一个配置函数）
advanced_config_menu() {
    # 子菜单分组：
    # 1.网络身份(network_name/secret/ipv4/dhcp/hostname/instance_name)
    # 2.监听连接(listeners/peers/external_node/default_protocol/rpc_portal)
    # 3.高级功能(vpn_portal/proxy_networks/exit_nodes/enable_exit_node/manual_routes/socks5)
    # 4.性能协议(mtu/latency_first/multi_thread/encryption/ipv6)
    # 5.开关选项(no_tun/smoltcp/disable_p2p/udp_hole_punching/relay_all_rpc/kcp/private)
    # 6.日志(console_log_level/file_log_level/file_log_dir)
    # 7.白名单(foreign_network_whitelist)
}
```

## TODOS

- [ ] 新增 Web 组件全局变量和高级配置默认值定义段
- [ ] 新增 add_toml_entry() 和 add_toml_array() 动态 TOML 写入函数
- [ ] 修改 install_easytier() 使其同时提取和安装 easytier-web-embed 二进制
- [ ] 新增 install_web() 函数，支持单独安装/更新 Web 组件
- [ ] 新增 Web 服务管理函数族（create_web_service_file、start/stop/restart/enable/disable/status/log_web_service），复用现有平台适配模式
- [ ] 新增 advanced_config_menu() 高级网络配置子菜单，逐参数覆盖所有 CLI 选项（网络身份、监听连接、高级功能、性能协议、开关选项、日志、白名单共七组）
- [ ] 新增 web_config_menu() Web 配置子菜单，管理 api-server-port、api-host、config-server-port、config-server-protocol、db 路径等参数
- [ ] 新增 cli_toolbox_menu() CLI 工具箱，封装 easytier-cli peer/route/vpn-portal/node 命令
- [ ] 新增 manage_web_service() Web 服务管理子菜单（启动/停止/重启/状态/开机自启/日志）
- [ ] 修改 uninstall_easytier() 同时清理 Web 组件（二进制、服务文件、配置目录、日志）
- [ ] 重构 main() 主菜单为四大板块布局（安装部署/网络配置/服务管理/运维工具），集成所有新增和修改的功能入口