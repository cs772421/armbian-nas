#!/usr/bin/env bash
# =============================================================================
# Armbian 小主机 NAS 一键部署脚本（可断点续跑 / 断线恢复 / 幂等重入）
# -----------------------------------------------------------------------------
# 适用：Armbian（Debian/Ubuntu 系，arm64 / armv7）
# 目标：/dev/sda1（外置 NTFS 500G 移动硬盘，已有电影等数据，绝不格式化、不改动已有文件）
#       /dev/sdb1（第二块硬盘，可选）挂载为 /mnt/sdb1
#       所有网站/日志/下载/索引/配置数据统一放 /mnt/sda1/www/ 子目录
#
# 断点续跑：每一步执行前后写状态到 /mnt/sda1/www/.deploy/state
#          直接重跑脚本 = 从第一个未完成步骤继续
#          --status 查看跑到哪一步；--redo=ID = 定向只重跑该步，--from=ID 才从该步跑到尾
#          SSH 断线：脚本自动放进 tmux 会话，重连后 `tmux attach -t armbian-nas`
#
# PHP：严格锁定 8.2（只装 php8.2-* 包，nginx 只连 php8.2-fpm.sock），
#      源里没有 8.2 时自动添加 Sury 仓库；扩展按内置清单逐项核对，缺失明确报出。
# 软件选择性安装：每个可选软件跑到那一步会单独问「装 / 跳过」，并显示预计占用
#       eMMC 空间，方便 8G 小容量机器取舍。输入 n 记 skip，下次运行会再问；
#       装完记 done，之后自动跳过。也可 --with-KEY / --no-KEY / --all-yes / --all-no。
# qBittorrent / Transmission 固定 apt 原生安装（不进 Docker），配置、WebUI 静态文件、
#       下载目录全部放 $BASE 下；Docker 本身只是可选组件，供你自己跑别的容器。
# 卸载：--uninstall / --uninstall=qb / --uninstall-all，二次确认，默认保留外置盘
#       全部用户数据；--purge-data 才删组件专属目录（共用目录永远不删）。
#       卸载后状态记 uninstalled，下次运行会重新询问是否装回。
# 步骤 18 在 Web 默认目录生成静态 index.html 导航页：一键直达各软件 WebUI，
#       并内嵌「软件装在哪」区块——每个软件的程序/服务/配置/界面/数据/日志路径
#       逐条列出、可复制，未安装的自动灰显。纯静态，不联网也能看。
# 步骤 19 做 eMMC 瘦身（Docker 日志轮转 / journald / apt 缓存外置 / swappiness）与
#        PHP 安全基线（open_basedir、disable_functions 白名单冲突检查、CLI+FPM 双端核对）。
# 最终自检会打印「软件组件清单 + 软件路径清单 + 逐项检查表」，并写入最终报告。
#
# 重要边界：
#   * 只有 /mnt/sda1/www 下新建目录，不格式化、不 chmod -R / chown -R、不删用户文件
#   * NTFS 不支持 overlay2：Docker data-root 不能直接放 NTFS。可选 --docker-external=1
#     用「NTFS 里的 ext4 loop 镜像」挂回 /var/lib/docker，软依赖保证挂不上时自动回退
#   * SWAP 文件不能放 NTFS（swapon 不支持无洞文件），512M swapfile 只能留 eMMC；
#     步骤 19 会配「zram 优先 / 磁盘 swap 兜底」的优先级分层（兼容新版 Ubuntu 的
#     zram-tools / systemd-zram-generator 与 Armbian 自带 armbian-zram-config，
#     并按内核版本探测 vm.swappiness 上限，老内核 <5.8 自动回落 100）
#   * aria2 RPC 密钥只放 .deploy/secrets.env；步骤 19 用 open_basedir 让 PHP 读不到它
#   * 比特米盒 / Khadas VIM1 (S905X)：风扇不走 PWM。★用户用 fan.sh 实测确认
#     风扇 = sysfs 全局编号 515（J9 Pin35 / GPIOAO_3），高开低关，脚本默认就用它。
#     另两套互斥映射保留可切换（取决于 dtb）：504+面板灯(p212)、libgpiod line3。
#   * 515 是【纯风扇引脚】：474/476/477 在这套 dtb 下是别的线，脚本默认
#     FAN_LED=off，绝不联动面板灯，避免误触发其它硬件功能。
#   * 绝不自动逐线扫描 GPIO；gpiochip1【line 70~80】会掉线需拔电，与 sysfs
#     全局编号 515 不是同一命名空间，脚本明确区分并警告。
#   * ★设备与实测环境（2026-11，root@khadas-vim1）：
#       设备是【比特米盒 CumeBox2】，刷的是 Khadas VIM1 开发板的 Armbian 镜像；
#       本脚本在【全新系统】下部署（不是老机器上补装）。
#       Armbian 26.8.11 resolute（Ubuntu 26.04）/ 内核 6.18.57-current-meson64
#       PHP 8.2.35 已从 Sury 的 ubuntu26.04 包装好；/sys/class/gpio 存在且
#       gpiochip512(AO 域) + gpiochip523(Periphs 域) → 印证 515 = 512+3。
#       911M 内存、系统自带 1.89G zram 已启用、CPU 57℃。
#       全新部署（--no-docker --no-gui）后实测：根 7.0G 用 2.1G / 剩 4.9G / 30%，
#       eMMC 占用很低；两块 466G 外置盘各剩约 13G（盘上原有电影，注意下载余量）。
#     脚本【不写死发行版/内核版本】：PHP 源按 VERSION_CODENAME 探测、swappiness
#     用 sysctl -w 实测内核是否接受 >100、gpiod 按 --version 判 v1/v2、zram
#     按已有管理器识别。下文出现的 Ubuntu 22.04 / 内核 5.x / Armbian 23.x
#     一律是【兼容老镜像的举例】，绝不是本机版本，改代码时别被带偏。
#     步骤 19 做低内存自适应（php-fpm 进程数、zram 大小）；发行版源没有
#     zram-tools 时自动回落 generator / zram-config / 原生自建 zram unit。
#   * ★ 面板 OLED 已按真机实测整体移除（步骤 20 改为安全清理占位）：
#     i2cdetect 全总线扫描会打断网口/整个内网，详见 step_oled_removed()。
#     绝不替换 dtb（换 CumeBox2 的 v.dtb 会让 504 风扇/面板灯脚本失效）
#   * 风扇引脚因板型差异极大，脚本不会乱猜 GPIO，未配置时明确标记「待配置」
#   * ZeroTier 加入网络后必须到 ZeroTier Central 勾选授权，脚本无法代做
# =============================================================================

set -Eeuo pipefail
export LC_ALL=C.UTF-8
export TZ=${TZ:-Asia/Shanghai}

VERSION="1.0.0"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# ------------------------------ 默认配置 -------------------------------------
# 可用同名环境变量、--config=文件、或命令行参数覆盖
BASE="${BASE:-/mnt/sda1/www}"
MOUNT_MAIN="${MOUNT_MAIN:-/mnt/sda1}"
MOUNT_SECOND="${MOUNT_SECOND:-/mnt/sdb1}"
MAIN_DEV="${MAIN_DEV:-/dev/sda1}"
SECOND_DEV="${SECOND_DEV:-/dev/sdb1}"

STATE_DIR="$BASE/.deploy"
STATE_FILE="$STATE_DIR/state"
MIRROR_DIR="/var/lib/armbian-nas-deploy"
MIRROR_FILE="$MIRROR_DIR/state.mirror"
SECRETS_FILE="$STATE_DIR/secrets.env"
SHARES_FILE="$STATE_DIR/share_dirs.txt"
REPORT_FILE="$STATE_DIR/final-report.txt"
# qB WebUI 本次实际生效的明文密码（供 --check 的 curl 登录自检用；600 权限，内网自用）
QB_PASS_FILE="$STATE_DIR/qb-webui.pass"
LOG_DIR="$BASE/logs"
LOG_FILE="$LOG_DIR/deploy.log"
BOOT_LOG="/var/log/armbian-nas-deploy.log"

ZT_NETWORK_ID="${ZT_NETWORK_ID:-}"
# qBittorrent / Transmission 固定「直接装进系统」(apt 原生)，不再用 Docker 容器。
# Docker 本身降级为可独立选择安装的组件，供你自己跑别的容器用。
DOCKER_MIRROR="${DOCKER_MIRROR:-}"        # 例：Aliyun / AzureChinaCloud
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-}"  # 仅允许 ext4/xfs/btrfs，NTFS 会被拒绝

FAN_ON_TEMP="${FAN_ON_TEMP:-50}"          # 达到 50℃ 开风扇
FAN_OFF_TEMP="${FAN_OFF_TEMP:-48}"        # 默认 48℃ 关（2℃ 滞回防抖动）；设 50 即严格模式
FAN_POLL="${FAN_POLL:-5}"
FAN_MIN_RUN="${FAN_MIN_RUN:-30}"          # 最少运行秒数，避免反复启停
FAN_GPIO="${FAN_GPIO:-}"                  # sysfs GPIO 全局编号，需按板型自行确认
FAN_ACTIVE_HIGH="${FAN_ACTIVE_HIGH:-1}"
FAN_PWM_CHIP="${FAN_PWM_CHIP:-}"          # 例：pwmchip0
FAN_PWM_CHANNEL="${FAN_PWM_CHANNEL:-0}"
FAN_TEMP_FILE="${FAN_TEMP_FILE:-}"        # 留空自动探测
FAN_ON_CMD="${FAN_ON_CMD:-}"              # 自定义开风扇 shell 命令（优先级最高）
FAN_OFF_CMD="${FAN_OFF_CMD:-}"            # 自定义关风扇 shell 命令

# ---- 风扇：比特米盒 / Khadas VIM1 (S905X) 专用 --------------------------------
# 【用户实测提供的硬件说明，原样记录，改代码前务必先读】
#   * 这台机器是「比特米盒」，刷的是 Khadas VIM1 的 Armbian 镜像（两者同为
#     Amlogic S905X，外设大体相同，所以板级脚本通用）。
#   * 风扇控制【不是】标准 PWM：cat /sys/class/hwmon/hwmon0/pwm1 无结果，
#     说明内核没加载风扇 PWM 驱动；/sys/class/pwm 那套在本机无效。
#   * 控制方式是 libgpiod 直接操作 GPIO 寄存器：gpiochip0 的 line 3。
#       gpioset gpiochip0 3=1   # 开风扇
#       gpioset gpiochip0 3=0   # 关风扇
#   * ⚠ 不同批次引脚可能不同，需自行逐线确认。
#   * ⚠⚠ 严禁测试 gpiochip1 的 70~80 线号区间：会让设备掉线，必须拔电重启！
#     因此本脚本【绝不自动扫描任何 GPIO 线】，只写用户明确指定的 chip/line。
#   * ⚠ libgpiod 的坑（两个大版本行为不同，脚本会自动适配）：
#       v1（gpiod 1.6.x，Debian 12 / Ubuntu 24.04 及更早常见）：
#           gpioset 默认 --mode=exit，进程一退出 line 就被释放、电平不保证；
#           必须 `gpioset --mode=wait gpiochip0 3=1` 常驻才能稳定保持。
#       v2（gpiod 2.x，Ubuntu 25.04+ / 26.04 resolute、Debian 13 Trixie）：
#           --mode 已被移除，语法改为 `gpioset -c gpiochip0 3=1`；
#           不带 -t0 时默认【不退出、一直占用 line】，正好是我们要的。
#     两个版本都必须让 gpioset 进程常驻；温控服务退出时子进程一起被 systemd
#     回收，line 释放、风扇回到硬件默认状态，属于安全行为。
#   * 温度读取：S905X 常见 /sys/class/thermal/thermal_zone0/temp（毫摄氏度），
#     或 Armbian 的 /etc/armbianmonitor/datasources/soctemp；脚本会自动探测。
FAN_BOARD="${FAN_BOARD:-auto}"            # auto | bitemi | generic（仅影响板型识别，
                                          # 不再决定引脚；★引脚统一由 FAN_SYSFS_FAN 决定）
FAN_GPIO_CHIP="${FAN_GPIO_CHIP:-gpiochip0}"   # 另一套 dtb 的 libgpiod 芯片（备选）
FAN_GPIO_LINE="${FAN_GPIO_LINE:-3}"           # 另一套 dtb 的 libgpiod 线号（备选）
FAN_GPIOD_MAJOR="${FAN_GPIOD_MAJOR:-auto}"    # auto = 由 gpioset --version 探测 1/2

# 【本机实测结论 2026-11：风扇 = sysfs 全局编号 515，GPIOAO_3 / J9 排针 Pin35】
# 用户用 fan.sh（10 个排针安全引脚逐个测试）确认：515 拉高风扇转、拉低风扇停。
# 这推翻了之前两份资料的预设，所以脚本默认采用 515，且【绝不联动面板灯】。
#
# 三套映射互斥，取决于 dtb / 镜像，绝不能混用：
#   A) sysfs 515 —— ★本机实测（Khadas VIM1 官方镜像，AO 域 base=512 + 3）。
#                    纯风扇引脚，高=开 低=关。474/476/477 在这套 dtb 下是别的线，
#                    ⚠ 绝不能拿去联动面板灯，否则可能误触发其它功能！
#   B) sysfs 504 —— 网上 bitbox_on/off.sh，基于 meson-gxl-s905x-p212.dtb（ophub）。
#                    风扇 504；面板灯 474=蓝 / 476=红 / 477=绿。
#                    开：504 high, 474 high, 476 high, 477 low
#                    关：504 low , 474 low , 476 low , 477 high（绿灯亮）
#   C) libgpiod gpiochip0 line 3 —— 另一套 dtb / 镜像的实测值。
# 换 CumeBox2 专用 v.dtb 后 B 脚本会失效（博客原话），所以 dtb 决定编号。
#
# fan.sh 提供的 10 个「排针引出、未被系统关键功能占用」的安全 sysfs 全局编号。
# 注意：这些是【sysfs 全局编号】，和之前警告的 gpiochip1【line 70~80】不是同一
# 命名空间 —— 后者会掉线需拔电重启，脚本绝不碰；前者是用户筛选过的可测引脚。
FAN_PROBE_PINS=(
  "515:J9 Pin35 GPIOAO_3 (AO域 base=512+3) ★用户实测风扇"
  "516:J9 Pin16 GPIOAO_4"
  "517:J9 Pin15 GPIOAO_5"
  "518:J9 Pin33 GPIOAO_6"
  "544:J9 Pin37 GPIOH_2 (Periphs域 base=523)"
  "545:J9 Pin30 GPIOH_3"
  "546:J9 Pin29 GPIOH_4"
  "547:J9 Pin32 GPIOH_5"
  "548:J9 Pin31 GPIOH_6"
  "622:J9 Pin39 GPIOX_9"
)
FAN_MODE="${FAN_MODE:-auto}"                  # auto|sysfs|sysfs504|libgpiod|pwm|custom
FAN_SYSFS_FAN="${FAN_SYSFS_FAN:-515}"         # ★用户实测：515；p212 dtb 才用 504
FAN_PIN_DESC="${FAN_PIN_DESC:-J9 Pin35 GPIOAO_3（用户 fan.sh 实测）}"
FAN_CONFIRMED_PIN="${FAN_CONFIRMED_PIN:-}"    # --fan-confirmed=515：已人工测过，直接写服务
FAN_PROBE_SCAN="${FAN_PROBE_SCAN:-0}"         # --scan：强制走全部安全候选（忽略 --fan-confirmed）
FAN_LED_BLUE="${FAN_LED_BLUE:-474}"
FAN_LED_RED="${FAN_LED_RED:-476}"
FAN_LED_GREEN="${FAN_LED_GREEN:-477}"
FAN_LED="${FAN_LED:-off}"                     # ★默认 off：515 是纯风扇，绝不联动面板灯
# 温度源全部读不到时的 fail-safe：1=开风扇（散热优先，推荐），0=保持不动
FAN_FAILSAFE="${FAN_FAILSAFE:-1}"

# ---- 面板 OLED 已移除：不再定义任何 OLED_* 变量 -----------------------------
# 详见 step_oled_removed() 的根因说明。旧 --oled-* 参数会被明确提示并忽略，
# 不会触发任何 I2C 操作。

# ---- 网页终端 ttyd（步骤 21，用户明确要求「必须安装」）-----------------------
# 安全边界（ttyd 等于一个浏览器里的 shell，必须收紧）：
#   * ttyd 默认【无认证】且监听 0.0.0.0:7681，直接暴露等于把 shell 送给全世界
#   * 脚本让 ttyd 只听 127.0.0.1（-i 127.0.0.1），外部根本连不到 7681
#   * 由 nginx 反代 /ttyd/ 并强制 auth_basic（密码在 .deploy/secrets.env，不在 Web 目录）
#   * 不加 ttyd 自带 -c：命令行明文密码会出现在 ps / /proc 里，反而更不安全
#   * 默认以 root 运行（小白要能干活），但务必不要把这个 80 端口映射到公网
TTYD_PORT="${TTYD_PORT:-7681}"
# ★ Docker 的 Web 管理界面端口必须在【组件元数据之前】定义：
#   COMP_ENTRY[docker] 会引用它，而本脚本 set -Eeuo pipefail，放在后面会
#   在 --help / --status 时直接报 unbound variable。
PORT_PORTAINER="${PORT_PORTAINER:-9000}"   # Portainer CE（装 Docker 时自动部署）
PORTAINER_ENABLED="${PORTAINER_ENABLED:-1}" # 1=自动带 Portainer；--no-portainer 关闭

# ---- Transmission 中文增强 WebUI（TrguiNG 汉化版）----
# 官方自带 WebUI 是英文且功能较简。步骤 09 会问「是否安装中文增强界面？[Y/n]」，
# 输入 y（或直接回车）即从 jayzcoder/TrguiNG 的 GitHub release 拉取【已编译好的
# 静态包】，放到外置盘，再用官方支持的 TRANSMISSION_WEB_HOME 环境变量切换。
# ★ 绝不在 1G 内存 ARM 小主机上跑 npm install / rust 编译（上游构建需 Node16+
#   + Rust1.69+，必然 OOM）；拉的是仓库发布的 WebUI 产物，不是源码现场编译。
TR_WEBUI="${TR_WEBUI:-ask}"             # ask=部署时询问 | trguing=装中文 | official=保留英文
TR_WEBUI_RESELECT="${TR_WEBUI_RESELECT:-0}" # 显式传 --tr-webui=ask 时置 1：清除落盘选择并重新询问
TR_WEBUI_ZIP="${TR_WEBUI_ZIP:-}"        # 离线包：本地路径或 URL（GitHub 不可达时用）
TR_WEBUI_TAG="${TR_WEBUI_TAG:-}"        # 指定 release 资产名；空=自动取最新中文版
GITHUB_MIRROR="${GITHUB_MIRROR:-}"      # 可选加速前缀，如 https://ghproxy.net/
TTYD_PATH="${TTYD_PATH:-/ttyd}"
TTYD_USER="${TTYD_USER:-root}"            # 可改成低权限用户（如 nasweb），但那样 sudo 会要密码
# ★ 内网自用版统一凭据：ttyd / aria2 RPC 一律 admin / admin。
#   FileBrowser 例外：上游强制密码 ≥12 位，故默认 admin / adminadmin123
#   （--fb-password 可自定义）。用户明确要求"密码无所谓安全与否，
#   只需在状态页给出改密方法提醒"。想恢复旧版随机密码：--creds=random。
CRED_MODE="${CRED_MODE:-simple}"        # simple=统一凭据 | random=每处随机密钥
TTYD_AUTH_USER="${TTYD_AUTH_USER:-admin}"
# ★ FileBrowser v2.6x 起强制密码 ≥12 位（真机实测：
#   `users update --password adminadmin` → Error: password is too short, minimum length is 12）。
#   ttyd / aria2 仍可用 5 位的 admin；FileBrowser 用 13 位、同样是 admin 系、好记的默认值。
#   可用 --fb-password=<≥12位> 自定义；低于 12 位脚本会明确拒绝，不再让 CLI 报英文错误。
FB_SIMPLE_PASS="${FB_SIMPLE_PASS:-adminadmin123}"
FB_PASS_MIN=12
TTYD_MAX_CLIENTS="${TTYD_MAX_CLIENTS:-3}"
TTYD_CMD="${TTYD_CMD:-bash -l}"
TTYD_VERSION="${TTYD_VERSION:-1.7.7}"    # GitHub release 静态二进制版本号（apt 装不上时用）
TTYD_BIN_URL="${TTYD_BIN_URL:-}"          # 自定义下载地址，离线环境可放本地路径

# ---- 风扇针脚实测（--fan-probe）----------------------------------------------
# 必须先人工确认「开→转」和「关→停」两轮，才把 on/off 写进服务；绝不先写死。
FAN_PROBE_FILE="$STATE_DIR/fan-probe.env"
FAN_PROBE_HOLD="${FAN_PROBE_HOLD:-4}"     # 每次动作后等待几秒让用户看/听风扇
PROBE_CHIP="${PROBE_CHIP:-}"              # 额外候选：--probe-chip=gpiochip1 --probe-line=17
PROBE_LINE="${PROBE_LINE:-}"
PROBE_SYSFS="${PROBE_SYSFS:-}"

# ---- 低内存自适应（该机仅 1G RAM）-------------------------------------------
LOW_MEM_MIB="${LOW_MEM_MIB:-1200}"            # 总内存 <= 该值即启用保守配置

HD_IDLE_TIMEOUT="${HD_IDLE_TIMEOUT:-600}" # 空闲 10 分钟休眠
SMB_WRITABLE="${SMB_WRITABLE:-0}"         # 1 = 允许 SMB 写入（默认只读，更安全）
ARIA_NG_ZIP="${ARIA_NG_ZIP:-}"            # 本地 AriaNg zip，离线环境用
SHARE_DIRS="${SHARE_DIRS:-}"              # 逗号/换行分隔的共享目录，留空自动/交互选择

# ---- 组件选择：每个软件单独询问「装 / 跳过」-------------------------------
# 变量取值：空 = 运行时询问；1 = 直接安装；0 = 直接跳过
# 命令行：--with-<key> / --no-<key>；--all-yes / --all-no；配置文件里也可写 INSTALL_<KEY>
# 「跳过」记为 skip 状态，下次运行脚本会再次询问；选 y 安装后记 done，之后自动跳过。
INSTALL_DOCKER="${INSTALL_DOCKER:-}"
INSTALL_VERYSYNC="${INSTALL_VERYSYNC:-}"
INSTALL_ZEROTIER="${INSTALL_ZEROTIER:-}"
INSTALL_QB="${INSTALL_QB:-}"
INSTALL_TRANSMISSION="${INSTALL_TRANSMISSION:-}"
INSTALL_ARIA2="${INSTALL_ARIA2:-}"
INSTALL_MINIDLNA="${INSTALL_MINIDLNA:-}"
INSTALL_SAMBA="${INSTALL_SAMBA:-}"
INSTALL_FAN="${INSTALL_FAN:-}"
INSTALL_HD_IDLE="${INSTALL_HD_IDLE:-}"
INSTALL_GUI="${INSTALL_GUI:-}"            # 图形界面默认建议不装（占 1–2 GiB）
ALL_YES=0
ALL_NO=0

# ---- 卸载功能相关开关 --------------------------------------------------------
# 设计原则（给不熟悉 Linux 的用户）：
#   1) 卸载只删「系统盘上的程序与配置」，外置盘上的下载文件、电影、配置默认全部保留；
#   2) 想连外置盘数据一起删，必须显式加 --purge-data，且会逐项列出将被删的目录再确认；
#   3) 卸载前一定二次确认，输入 yes 才动手；
#   4) 卸载后把该步骤状态改成 uninstalled（不是 done），
#      所以「下次运行脚本」会像第一次那样重新问你要不要装，装回来很方便。
UNINSTALL_LIST="${UNINSTALL_LIST:-}"     # 逗号分隔的组件 key，如 qb,transmission
UNINSTALL_ALL=0                          # --uninstall-all：卸载全部可选组件
UNINSTALL_MENU=0                         # --uninstall（不带值）：进入交互菜单
PURGE_DATA=0                             # 1=连外置盘数据一起删（危险，默认 0）
ASSUME_YES=0                             # 1=跳过交互确认（--yes），用于脚本化

# 组件元数据：key | 显示名 | eMMC 粗估(含依赖) | 非交互默认 | 端口/入口 | 数据目录
declare -A COMP_NAME COMP_SIZE COMP_DEFAULT COMP_STEP COMP_ENTRY COMP_DATA
COMP_KEYS=(docker verysync zerotier qb transmission aria2 minidlna samba fan hd_idle gui ttyd filebrowser)
COMP_NAME[docker]="Docker 引擎"
COMP_SIZE[docker]="~350 MiB（镜像层另计 0.8–1.2 GiB）"
COMP_DEFAULT[docker]=1
COMP_STEP[docker]=05
COMP_ENTRY[docker]="Portainer Web 管理 :$PORT_PORTAINER（装 Docker 时自动部署；命令行 docker）"
COMP_DATA[docker]="/var/lib/docker（可选外置）、$BASE/portainer"
COMP_NAME[verysync]="微力同步 Verysync"
COMP_SIZE[verysync]="~30 MiB"
COMP_DEFAULT[verysync]=1
COMP_STEP[verysync]=06
COMP_ENTRY[verysync]=":8886"
COMP_DATA[verysync]="$BASE/verysync"
COMP_NAME[zerotier]="ZeroTier"
COMP_SIZE[zerotier]="~15 MiB"
COMP_DEFAULT[zerotier]=1
COMP_STEP[zerotier]=07
COMP_ENTRY[zerotier]="9993/udp"
COMP_DATA[zerotier]="/var/lib/zerotier-one"
COMP_NAME[qb]="qBittorrent-nox（原生）"
COMP_SIZE[qb]="~90 MiB"
COMP_DEFAULT[qb]=1
COMP_STEP[qb]=08
COMP_ENTRY[qb]=":8080"
COMP_DATA[qb]="$BASE/qb、$BASE/downloads、$BASE/webui/qbittorrent"
COMP_NAME[transmission]="Transmission（原生）"
COMP_SIZE[transmission]="~25 MiB"
COMP_DEFAULT[transmission]=1
COMP_STEP[transmission]=09
COMP_ENTRY[transmission]=":9091"
COMP_DATA[transmission]="$BASE/transmission、$BASE/downloads、$BASE/webui/transmission"
COMP_NAME[aria2]="aria2 + AriaNg"
COMP_SIZE[aria2]="~15 MiB"
COMP_DEFAULT[aria2]=1
COMP_STEP[aria2]=10
COMP_ENTRY[aria2]="/ariang/、/jsonrpc"
COMP_DATA[aria2]="$BASE/aria2、$BASE/web/ariang"
COMP_NAME[minidlna]="MiniDLNA"
COMP_SIZE[minidlna]="~10 MiB"
COMP_DEFAULT[minidlna]=1
COMP_STEP[minidlna]=12
COMP_ENTRY[minidlna]=":8200"
COMP_DATA[minidlna]="$BASE/minidlna/db"
COMP_NAME[samba]="Samba 共享"
COMP_SIZE[samba]="~60 MiB"
COMP_DEFAULT[samba]=1
COMP_STEP[samba]=13
COMP_ENTRY[samba]="445/139"
COMP_DATA[samba]="共享清单 $SHARES_FILE"
COMP_NAME[fan]="风扇温控服务"
COMP_SIZE[fan]="~0 MiB（脚本 + systemd unit）"
COMP_DEFAULT[fan]=1
COMP_STEP[fan]=14
COMP_ENTRY[fan]="无（后台服务）"
COMP_DATA[fan]="$BASE/logs/fan.log"
COMP_NAME[hd_idle]="硬盘休眠"
COMP_SIZE[hd_idle]="~2 MiB"
COMP_DEFAULT[hd_idle]=1
COMP_STEP[hd_idle]=15
COMP_ENTRY[hd_idle]="无（后台服务）"
COMP_DATA[hd_idle]="$BASE/logs/hd-idle.log"
# ★ 面板 OLED（SSD1306）组件【已整体移除】：见 step_oled_removed() 的根因说明。
#   component_decision / 清单 / 首页 / 自检 / 卸载菜单都不再出现 oled。
COMP_NAME[ttyd]="ttyd 网页终端"
COMP_SIZE[ttyd]="~1 MiB（apt 包 546KB；静态二进制约 2MB）"
COMP_DEFAULT[ttyd]=1                 # 用户明确要求：必须有，默认安装（仍可输入 n 跳过）
COMP_STEP[ttyd]=21
COMP_ENTRY[ttyd]="${TTYD_PATH%/}/（nginx 反代 + 密码）"   # 参数解析后会在「路径派生」段再刷新一次
COMP_DATA[ttyd]="$BASE/ttyd（日志）"
# ---------------------------------------------------------------------------
# 组件 → systemd 服务单元名。导航页每张卡片按它拼出
#   sudo systemctl start|stop|restart|status <unit>
# 这四项 SSH 命令，小白不用记服务名也能启停软件。
# 有两个单元（如 samba）只列主单元，注释里说明另一个。
# ---------------------------------------------------------------------------
# ---- FileBrowser（网页文件管理器，单二进制，配置/数据库在外置盘）----
COMP_NAME[filebrowser]="FileBrowser 文件管理器"
COMP_SIZE[filebrowser]="≈15 MiB 单二进制 + 几 MB 数据库"
COMP_DEFAULT[filebrowser]=1
COMP_STEP[filebrowser]=22
COMP_ENTRY[filebrowser]=":8082（网页管理两块外置硬盘）"
COMP_DATA[filebrowser]="$BASE/filebrowser（数据库在外置盘）"

declare -A COMP_SVC
COMP_SVC[docker]="docker"
COMP_SVC[verysync]="verysync"
COMP_SVC[zerotier]="zerotier-one"
COMP_SVC[qb]="qbittorrent-nox"
COMP_SVC[transmission]="transmission-daemon"
COMP_SVC[aria2]="aria2"
COMP_SVC[minidlna]="minidlna"
COMP_SVC[samba]="smbd"
COMP_SVC[fan]="armbian-fan"
COMP_SVC[hd_idle]="hd-idle"
COMP_SVC[gui]="xrdp"
COMP_SVC[ttyd]="armbian-ttyd"
COMP_SVC[filebrowser]="armbian-filebrowser"

# 默认密码 / 初始凭据（局域网自用，用户明确要求卡片里直接显示明文）。
# 动态读取：ttyd 与 aria2 的真值在 secrets.env 里，只有生成页面那一刻才读。
# --no-nav-secrets 会让导航页隐藏这一栏（报告文件仍保留，600 权限）。
component_creds(){
  local k="$1"
  case "$k" in
    qb)
      printf '登录：用户名 admin ｜ 密码 adminadmin（脚本已写入 [Preferences] 的 WebUI\\\\Username 与 Password_PBKDF2，中文界面，已关 Host 头校验/CSRF）。'
      printf '若仍提示 Invalid Username or Password，跑 sudo bash %s --with-qb --redo=08 --qb-password=adminadmin 强制重写凭据后 Ctrl+F5 强刷。' "$SCRIPT_PATH"
      printf '★ :8080 是 qB 自己的 WebUI，不是网页终端；改密：登录 WebUI → 工具 → 选项 → WebUI → 身份验证。' ;;
    ttyd)
      if [[ "${NAV_SECRETS:-1}" -eq 1 ]]; then
        printf '网页登录：用户名 %s ｜ 密码 %s（统一凭据；改密方法见状态页）' \
          "$TTYD_AUTH_USER" "$(secret_get TTYD_WEB_PASS)"
      else
        printf '网页登录：用户名 %s ｜ 密码已隐藏（--no-nav-secrets）；查 sudo grep TTYD_WEB_PASS %s' \
          "$TTYD_AUTH_USER" "$SECRETS_FILE"
      fi ;;
    aria2)
      if [[ "${NAV_SECRETS:-1}" -eq 1 ]]; then
        printf 'AriaNg RPC 密钥：%s（设置 → RPC → 密钥栏填入；统一凭据，改密方法见状态页）' "$(secret_get ARIA_RPC_SECRET)"
      else
        printf 'AriaNg RPC 密钥已隐藏（--no-nav-secrets）；查 sudo grep ARIA_RPC_SECRET %s' "$SECRETS_FILE"
      fi ;;
    transmission)
      printf '默认关闭认证（settings.json 里 rpc-authentication-required=false）；无初始密码，需要时在 WebUI/设置里开启。'
      case "$(tr_webui_decision)" in
        trguing) printf '界面：TrguiNG 汉化版（简体中文，步骤 09 选 y 安装）' ;;
        official) printf '界面：官方英文 WebUI（--tr-webui=trguing --redo=09 可换中文增强版）' ;;
        failed)   printf '界面：官方英文 WebUI（中文包下载失败，可用 --tr-webui-zip 离线补装）' ;;
        *)        printf '界面：首次部署到步骤 09 会询问是否装中文增强版' ;;
      esac ;;
    verysync)
      printf '无默认密码：首次打开 :8886 时自行设置管理密码' ;;
    samba)
      printf '共享默认按 guest 访问（smb.conf 里 map to guest）；无初始密码' ;;
    zerotier)
      printf '无网页密码：加入网络用 sudo zerotier-cli join %s，再去 my.zerotier.com 勾选授权' \
        "${ZT_NETWORK_ID:-<16位网络ID>}" ;;
    gui)
      printf '远程桌面用系统账号密码（root 或你新建的用户）；xrdp :3389' ;;
    filebrowser)
      if [[ "${NAV_SECRETS:-1}" -eq 1 ]]; then
        printf '网页登录：用户名 admin ｜ 密码 %s（上游强制 ≥12 位；改密方法见状态页）' "$(secret_get FILEBROWSER_PASS)"
        if [[ -f "$BASE/filebrowser/auth-noauth" ]]; then printf '（本机 CLI 版本不支持建用户，已切免密登录，直接进即可）'; fi
      else
        printf '网页登录：用户名 admin ｜ 密码已隐藏（--no-nav-secrets）；查 sudo grep FILEBROWSER_PASS %s' "$SECRETS_FILE"
      fi ;;
    docker)
      printf 'Portainer 首次打开 http://<本机IP>:%s 时自行创建 admin 密码（5 分钟内完成，超时需重启容器）；Docker 命令本身无密码。改密方法见状态页' "$PORT_PORTAINER" ;;
    minidlna|fan|hd_idle)
      printf '无初始密码（后台服务 / 局域网直接访问）' ;;
    *)
      printf '无默认密码' ;;
  esac
}

# ---------------------------------------------------------------------------
# ★ 每个软件卡片的「本脚本一键安装 / 重装 / 修复」命令。
#   小白场景：某软件当时选了 n（例如 FileBrowser 没装），过几天想装，
#   不用翻文档、不用记步骤号——状态页卡片最后一条直接复制到 SSH 执行即可。
#   --with-<key> 让 component_gate 不再询问；--redo=<步骤号> 把该步及之后
#   的状态清掉重跑（幂等，已装的会重装配置、不会重复装第二份）。
#   必需服务（nginx / PHP / 博客）没有组件 key，只需 --redo。
# ---------------------------------------------------------------------------
component_install_cmd(){
  # ★ 必修（SC2318）：bash 先展开整行再逐个赋值，同一行里引用刚赋值的 $k，
  #   在 set -Eeuo pipefail 下会直接报「k: unbound variable」退出。
  #   之前两个调用点外层恰好都有 k，靠动态作用域"巧合正确"；一旦外层改名
  #   或新增调用点，步骤 18 生成导航页时会整体崩掉。拆成两行才是真修。
  local k="$1" step s
  step="${COMP_STEP[$k]:-}"
  s="sudo bash $SCRIPT_PATH"
  case "$k" in
    fan)
      # 风扇必须先有针脚两轮实测；本机实测为 sysfs 全局编号 515。
      printf '%s --with-fan --redo=14 --fan-confirmed=515' "$s" ;;
    zerotier)
      printf '%s --with-zerotier --redo=07' "$s" ;;
    gui)
      printf '%s --with-gui --redo=17' "$s" ;;
    *)
      if [[ -n "$step" ]]; then printf '%s --with-%s --redo=%s' "$s" "$k" "$step"
      else printf '%s --redo=18' "$s"; fi ;;
  esac
}

COMP_NAME[gui]="XFCE 图形界面"
COMP_SIZE[gui]="1–2 GiB（8G eMMC 强烈不建议）"
COMP_DEFAULT[gui]=0
COMP_STEP[gui]=17
COMP_ENTRY[gui]="xrdp :3389"
COMP_DATA[gui]="系统盘"

# ---------------------------------------------------------------------------
# 组件「路径清单」：给不熟悉 Linux 的用户看明白每个软件到底装在哪。
#
# 为什么需要它：
#   Linux 装一个软件，文件会散落在好几个地方——程序在 /usr/bin，服务在
#   /etc/systemd/system，配置在 /etc 或外置盘，网页界面又在外置盘的 web 目录，
#   下载的文件还在另一个目录。新手最容易「找不到东西 / 不敢删」。
#   所以这里把每个软件的位置一条条列清楚，首页、最终报告、卸载预览都用它。
#
# 输出格式：TSV（用 Tab 分隔的 10 列），每个组件可以有多行（一行 = 一条路径）：
#   key | 显示名 | 选择状态 | 安装状态 | 运行状态 | 版本 | eMMC估算 | 入口 | 路径说明 | 路径值
# 之后由 component_snapshot_json() 把同一个 key 的多行聚合成 JSON 数组，
# 内嵌到静态导航页里（页面不依赖网络、不需要后端，离线也能看）。
#
# ppath()：路径不存在时在后面标注「当前不存在」，避免用户照着找却扑空，
#          也让他知道「装好之后会出现在这里」。
# ---------------------------------------------------------------------------
ppath(){
  local p="$1"
  if [[ -e "$p" ]]; then printf '%s' "$p"
  else printf '%s（当前不存在，安装后才会出现）' "$p"; fi
}

# 只负责列出「路径说明 / 路径值」两列，前面 8 列由 component_paths_tsv 补齐
component_path_rows(){
  local k="$1"
  case "$k" in
    docker)
      printf '程序文件（docker 命令）\t%s\n' "$(ppath "$(command -v docker 2>/dev/null || echo /usr/bin/docker)")"
      printf '服务单元\tdocker.service / containerd.service\n'
      printf '配置文件\t%s\n' "$(ppath /etc/docker/daemon.json)"
      printf '镜像与容器数据\t%s\n' "$(ppath /var/lib/docker)"
      printf '外置盘镜像（可选）\t%s\n' "$(ppath "$BASE/.docker-ext4.img")"
      printf '用户组\tdocker（加入后普通用户才能免 sudo 跑 docker）\n'
      printf '★ Web 管理界面\tPortainer CE 容器 armbian-nas-portainer（装 Docker 时自动部署）\n'
      printf 'Portainer 数据卷\t%s（账号/设置落在外置盘，重装系统不丢）\n' "$(ppath "$BASE/portainer")"
      printf 'Portainer 访问入口\thttp://<本机IP>:%s（首次打开自行创建 admin 密码）\n' "$PORT_PORTAINER"
      printf 'Portainer 运维命令\tsudo docker ps | grep portainer / sudo docker logs armbian-nas-portainer\n'
      printf '一键重装命令\t%s\n' "$(component_install_cmd docker)"
      ;;
    verysync)
      printf '程序目录\t%s\n' "$(ppath /usr/bin/verysync/verysync)"
      printf '服务单元\tverysync.service（含 10-armbian-nas.conf 覆盖参数）\n'
      printf '配置与索引目录\t%s\n' "$(ppath "$BASE/verysync")"
      printf '网页界面\t内置在程序里，无需单独文件\n'
      printf '访问入口\thttp://<本机IP>:8886\n'
      printf '服务单元文件\t%s\n' "$(ppath /etc/systemd/system/verysync.service)"
      ;;
    zerotier)
      printf '程序文件\t%s\n' "$(ppath "$(command -v zerotier-cli 2>/dev/null || echo /usr/sbin/zerotier-cli)")"
      printf '服务单元\tzerotier-one.service\n'
      printf '身份与网络配置\t/var/lib/zerotier-one\n'
      printf '访问入口\t9993/udp；管理在 https://my.zerotier.com/\n'
      printf '常用命令\tzerotier-cli info / listnetworks / join <16位ID>\n'
      ;;
    qb)
      printf '程序文件（软件本体）\t%s\n' "$(ppath "$(command -v qbittorrent-nox 2>/dev/null || echo /usr/bin/qbittorrent-nox)")"
      printf '服务单元\t%s\n' "$(ppath /etc/systemd/system/qbittorrent-nox.service)"
      printf '配置文件\t%s\n' "$(ppath "$BASE/qb/config/qBittorrent/qBittorrent.conf")"
      printf '网页界面文件\t%s\n' "$(ppath "$BASE/webui/qbittorrent/index.html")"
      printf '种子 / 缓存数据\t%s\n' "$(ppath "$BASE/qb/data")"
      printf '已完成下载\t%s\n' "$(ppath "$BASE/downloads/complete")"
      printf '未完成下载\t%s\n' "$(ppath "$BASE/downloads/incomplete")"
      printf '服务日志\tjournalctl -u qbittorrent-nox（不写单独文件）\n'
      printf '访问入口\thttp://<本机IP>:8080（脚本已写入 admin/adminadmin，中文界面）\n'
      ;;
    transmission)
      printf '程序文件（软件本体）\t%s\n' "$(ppath "$(command -v transmission-daemon 2>/dev/null || echo /usr/bin/transmission-daemon)")"
      printf '服务单元\ttransmission-daemon.service + %s\n' "$(ppath /etc/systemd/system/transmission-daemon.service.d/10-armbian-nas.conf)"
      printf '配置文件\t%s\n' "$(ppath "$BASE/transmission/settings.json")"
      printf '网页界面文件\t%s\n' "$(ppath "$BASE/webui/transmission/index.html")"
      printf '自动加种监视目录\t%s\n' "$(ppath "$BASE/downloads/watch")"
      printf '已完成下载\t%s\n' "$(ppath "$BASE/downloads/complete")"
      printf '服务日志\tjournalctl -u transmission-daemon\n'
      printf '★ 中文增强 WebUI\t%s（TrguiNG 汉化版，index.html 直接在此目录）\n' "$(ppath "$(tr_webui_dir)")"
      printf '界面版本记录\t%s\n' "$(ppath "$(tr_webui_version_file)")"
      printf '界面来源\tgithub.com/jayzcoder/TrguiNG（上游 openscopeproject/TrguiNG，AGPL-3.0）\n'
      printf '装中文界面\tsudo bash %s --tr-webui=trguing --redo=09\n' "$SCRIPT_PATH"
      printf '切回官方英文\tsudo bash %s --tr-webui=official --redo=09\n' "$SCRIPT_PATH"
      printf '离线补装\tsudo bash %s --tr-webui-zip=/路径/trguing-web-xxx-zh.zip --redo=09\n' "$SCRIPT_PATH"
      printf '界面切换原理\tTransmission 官方环境变量 TRANSMISSION_WEB_HOME，不改 settings.json\n'
      printf '访问入口\thttp://<本机IP>:9091\n'
      ;;
    aria2)
      printf '程序文件\t%s\n' "$(ppath "$(command -v aria2c 2>/dev/null || echo /usr/bin/aria2c)")"
      printf '服务单元\t%s\n' "$(ppath /etc/systemd/system/aria2.service)"
      printf '配置文件\t%s\n' "$(ppath "$BASE/aria2/aria2.conf")"
      printf '断点续传记录\t%s\n' "$(ppath "$BASE/aria2/aria2.session")"
      printf 'AriaNg 网页界面\t%s\n' "$(ppath "$WEB_ROOT/ariang/index.html")"
      printf '下载目录\t%s\n' "$(ppath "$BASE/downloads/aria2")"
      printf 'RPC 密钥文件\t%s\n' "$(ppath "$SECRETS_FILE")"
      printf '访问入口\thttp://<本机IP>/ariang/ ；RPC 走 http://<本机IP>/jsonrpc\n'
      ;;
    minidlna)
      printf '程序文件\t%s\n' "$(ppath "$(command -v minidlnad 2>/dev/null || echo /usr/sbin/minidlnad)")"
      printf '服务单元\tminidlna.service\n'
      printf '配置文件\t%s（原文件备份 %s）\n' "$(ppath /etc/minidlna.conf)" /etc/minidlna.conf.bak.armbian-nas
      printf '媒体索引数据库\t%s\n' "$(ppath "$BASE/minidlna/db")"
      printf '日志目录\t%s\n' "$(ppath "$BASE/logs")"
      printf '共享目录清单\t%s\n' "$(ppath "$SHARES_FILE")"
      printf '访问入口\thttp://<本机IP>:8200；播放器里搜索 armbian-nas\n'
      ;;
    samba)
      printf '程序文件\t%s\n' "$(ppath "$(command -v smbd 2>/dev/null || echo /usr/sbin/smbd)")"
      printf '服务单元\tsmbd.service / nmbd.service\n'
      printf '配置文件\t%s（原文件备份 %s）\n' "$(ppath /etc/samba/smb.conf)" /etc/samba/smb.conf.bak.armbian-nas
      printf '日志目录\t%s\n' "$(ppath "$BASE/logs/samba")"
      printf '共享目录清单\t%s\n' "$(ppath "$SHARES_FILE")"
      printf '访问入口\tWindows 资源管理器输入 \\\\<本机IP>\\\n'
      ;;
    filebrowser)
      printf '程序文件（单二进制）\t%s\n' "$(ppath /usr/local/bin/filebrowser)"
      printf '服务单元\t%s\n' "$(ppath /etc/systemd/system/armbian-filebrowser.service)"
      printf '数据库（账号/设置）\t%s\n' "$(ppath "$FB_DB")"
      printf '可浏览根目录\t%s（两块外置硬盘都在这里）\n' "$(ppath "$FB_ROOT")"
      printf '服务日志\t%s\n' "$(ppath "$BASE/logs/filebrowser.log")"
      printf '登录密码\t%s 里的 FILEBROWSER_PASS\n' "$(ppath "$SECRETS_FILE")"
      printf '访问入口\thttp://<本机IP>:%s\n' "$PORT_FB" ;;
    fan)
      printf '温控脚本（软件本体）\t%s\n' "$(ppath /usr/local/sbin/armbian-fan-control)"
      printf '服务单元\t%s\n' "$(ppath /etc/systemd/system/armbian-fan.service)"
      printf '参数文件\t%s\n' "$(ppath /etc/default/armbian-fan)"
      printf '控制方式\t%s（★本机实测：sysfs 全局编号，不是 PWM、不是 libgpiod）\n' \
        "$(grep -F 'FAN_MODE=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo '<待配置>')"
      printf '★ 风扇 GPIO 编号\t%s\n' \
        "$(grep -F 'FAN_SYSFS_FAN=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo 515)"
      printf '引脚说明\t%s\n' \
        "$(grep -F 'FAN_PIN_DESC=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2- | tr -d '"' || echo 'J9 Pin35 / GPIOAO_3')"
      printf '开 / 关电平\t写%s = 开风扇，写%s = 关风扇\n' \
        "$(grep -F 'FAN_ACTIVE_HIGH=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo 1)" \
        "$((1-$(grep -F 'FAN_ACTIVE_HIGH=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo 1)))"
      printf '实际 sysfs 路径\t/sys/class/gpio/gpio%s/value\n' \
        "$(grep -F 'FAN_SYSFS_FAN=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo 515)"
      printf '面板灯联动\t%s（515 是纯风扇，474/476/477 是别的线，默认绝不联动）\n' \
        "$(grep -F 'FAN_LED_EFF=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 | sed 's/^0$/已关闭/;s/^1$/已启用/' || echo 已关闭)"
      printf '针脚实测记录\t%s\n' "$(ppath "${FAN_PROBE_FILE:-$STATE_DIR/fan-probe.env}")"
      printf '⚠ 安全提示\t严禁测试 gpiochip1 的【line 70~80】（会掉线需拔电）；那是另一套命名空间，与 sysfs 全局编号 515 不同\n'
      printf '手动验证开关\tsudo bash %s --fan-test-on / --fan-test-off\n' "$SCRIPT_PATH"
      printf '运行日志\t%s\n' "$(ppath "$BASE/logs/fan.log")"
      printf '访问入口\t无网页界面，后台自动运行\n'
      printf '查看是否动作\tsudo journalctl -u armbian-fan -f\n'
      ;;
    hd_idle)
      printf '程序文件\t%s\n' "$(ppath "$(command -v hd-idle 2>/dev/null || command -v hdparm 2>/dev/null || echo /usr/sbin/hd-idle)")"
      printf '服务单元\thd-idle.service 或 armbian-hdparm.timer（二选一）\n'
      printf '参数文件\t%s\n' "$(ppath /etc/default/hd-idle)"
      printf '运行日志\t%s\n' "$(ppath "$BASE/logs/hd-idle.log")"
      printf '访问入口\t无网页界面，后台自动运行\n'
      printf '查看硬盘状态\tsudo hdparm -C %s\n' "$MAIN_DEV"
      ;;
    ttyd)
      printf '程序本体\t%s\n' "$(ppath "$(command -v ttyd 2>/dev/null || echo /usr/local/bin/ttyd)")"
      printf '服务单元\t%s\n' "$(ppath /etc/systemd/system/armbian-ttyd.service)"
      printf 'nginx 反代片段\t%s\n' "$(ppath /etc/nginx/snippets/armbian-nas-ttyd.conf)"
      printf '网页密码文件\t%s\n' "$(ppath /etc/nginx/.ttydpasswd)"
      printf '密码明文存放处\t%s（TTYD_WEB_PASS）\n' "$(ppath "$SECRETS_FILE")"
      printf '访问入口\thttp://<本机IP>%s/\n' "$TTYD_PATH"
      printf '登录用户名\t%s\n' "$TTYD_AUTH_USER"
      printf '⚠ 安全边界\tt%d 只监听 127.0.0.1，由 nginx 加密码；绝不要把 80 映射到公网\n' "$TTYD_PORT"
      printf '查看日志\tsudo journalctl -u armbian-ttyd -f\n'
      ;;
    gui)
      printf '桌面环境\tXFCE（xfce4 / xfce4-goodies）\n'
      printf '显示管理器\tlightdm.service\n'
      printf '远程桌面\txrdp.service\n'
      printf '默认启动目标\tgraphical.target（卸载会改回 multi-user.target）\n'
      printf '访问入口\t远程桌面客户端连 <本机IP>:3389\n'
      printf '数据位置\t系统盘（会占 1–2 GiB，8G eMMC 建议别装）\n'
      ;;
  esac
}

# 生成完整 TSV 快照（10 列）。状态列复用后面的 component_running /
# component_version，它们在同一脚本里定义，执行到 main 时已全部加载完毕。
component_paths_tsv(){
  local k chosen inst run ver label value rows
  for k in "${COMP_KEYS[@]}"; do
    case "$(component_decision "$k")" in
      chosen)      chosen="已选择安装" ;;
      uninstalled) chosen="已卸载（下次运行会再问）" ;;
      skip)        chosen="已跳过（下次运行会再问）" ;;
      *)           chosen="尚未部署（脚本未跑到该步）" ;;
    esac
    if component_installed "$k"; then inst="已安装"; else inst="未安装"; fi
    if [[ "$inst" == "未安装" ]]; then run="—"
    elif component_running "$k"; then run="运行中"
    else run="已安装但未运行"; fi
    ver="$(component_version "$k")"; [[ -n "$ver" ]] || ver="-"
    # ---- 每张卡片固定附带的 SSH 运维命令（4 条）+ 日志命令 ----
    # 前缀 [CMD] / [SECRET] 会被 component_snapshot_json 提取成独立字段，
    # 导航页单独渲染成「SSH 命令」「默认密码」两个醒目区块。
    local svc="${COMP_SVC[$k]:-}"
    if [[ -n "$svc" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$k" "${COMP_NAME[$k]}" "$chosen" "$inst" "$run" "$ver" \
        "${COMP_SIZE[$k]}" "${COMP_ENTRY[$k]}" "[CMD] 启动服务" "sudo systemctl start $svc"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$k" "${COMP_NAME[$k]}" "$chosen" "$inst" "$run" "$ver" \
        "${COMP_SIZE[$k]}" "${COMP_ENTRY[$k]}" "[CMD] 停止服务" "sudo systemctl stop $svc"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$k" "${COMP_NAME[$k]}" "$chosen" "$inst" "$run" "$ver" \
        "${COMP_SIZE[$k]}" "${COMP_ENTRY[$k]}" "[CMD] 重启服务" "sudo systemctl restart $svc"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$k" "${COMP_NAME[$k]}" "$chosen" "$inst" "$run" "$ver" \
        "${COMP_SIZE[$k]}" "${COMP_ENTRY[$k]}" "[CMD] 查看状态" "sudo systemctl status $svc"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$k" "${COMP_NAME[$k]}" "$chosen" "$inst" "$run" "$ver" \
        "${COMP_SIZE[$k]}" "${COMP_ENTRY[$k]}" "[CMD] 实时日志" "sudo journalctl -u $svc -f"
    fi
    # ---- ★ 本脚本一键安装 / 重装 / 修复命令（状态页卡片最后一条） ----
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$k" "${COMP_NAME[$k]}" "$chosen" "$inst" "$run" "$ver" \
      "${COMP_SIZE[$k]}" "${COMP_ENTRY[$k]}" "[INSTALL] 一键安装 / 重装 / 修复" "$(component_install_cmd "$k")"
    # ---- 默认密码 / 初始凭据 ----
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$k" "${COMP_NAME[$k]}" "$chosen" "$inst" "$run" "$ver" \
      "${COMP_SIZE[$k]}" "${COMP_ENTRY[$k]}" "[SECRET] 默认密码 / 初始凭据" "$(component_creds "$k")"
    rows="$(component_path_rows "$k")"
    if [[ -n "$rows" ]]; then
      while IFS=$'\t' read -r label value; do
        [[ -z "$label" ]] && continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$k" "${COMP_NAME[$k]}" "$chosen" "$inst" "$run" "$ver" \
          "${COMP_SIZE[$k]}" "${COMP_ENTRY[$k]}" "$label" "${value:-}"
      done <<< "$rows"
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$k" "${COMP_NAME[$k]}" "$chosen" "$inst" "$run" "$ver" \
        "${COMP_SIZE[$k]}" "${COMP_ENTRY[$k]}" "路径" "（无）"
    fi
  done
  # nginx / php-fpm 是「必需服务」，不在可选组件清单里，但用户要求导航页
  # 也要有它们的状态卡片与 SSH 命令。这里以只读快照形式追加，不参与选装。
  core_service_rows
}

# 核心服务（nginx / PHP 8.2 FPM）的 10 列快照，格式与可选组件完全一致。
# 虚拟 key 为 nginx / php；JS 的 byKey 会认得它们，顶部快捷卡片不会误灰掉。
core_service_rows(){
  local k name svc inst run ver entry size label value i
  local -a rows
  for k in nginx php; do
    if [[ "$k" == nginx ]]; then
      name="nginx Web 服务器"; svc="nginx"; entry=":80（本导航页）"
      size="~10 MiB（系统盘）"
      if command -v nginx >/dev/null 2>&1; then
        inst="已安装"; ver="$(nginx -v 2>&1 | awk -F/ '{print $2}' || echo -)"
      else inst="未安装"; ver="-"; fi
    else
      name="PHP 8.2 FPM + SQLite3"; svc="$PHP_FPM_SVC"; entry="unix:$PHP_SOCK ｜ /prober.php 完整探针"
      size="~60 MiB（含扩展，系统盘）"
      if command -v "$PHP_BIN" >/dev/null 2>&1; then
        inst="已安装"; ver="$("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null || echo -)"
      else inst="未安装"; ver="-"; fi
    fi
    if [[ "$inst" == "未安装" ]]; then run="—"
    elif svc_active "$svc"; then run="运行中"
    else run="已安装但未运行"; fi
    [[ -n "$ver" ]] || ver="-"
    local chosen="必需组件（随步骤 03/04 安装）"
    # 命令
    for label in "启动服务:start" "停止服务:stop" "重启服务:restart" "查看状态:status"; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$k" "$name" "$chosen" "$inst" "$run" "$ver" "$size" "$entry" \
        "[CMD] ${label%%:*}" "sudo systemctl ${label##*:} $svc"
    done
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$k" "$name" "$chosen" "$inst" "$run" "$ver" "$size" "$entry" \
      "[CMD] 实时日志" "sudo journalctl -u $svc -f"
    local _icmd="sudo bash $SCRIPT_PATH --redo=03"
    [[ "$k" == "nginx" ]] && _icmd="sudo bash $SCRIPT_PATH --redo=03"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$k" "$name" "$chosen" "$inst" "$run" "$ver" "$size" "$entry" \
      "[INSTALL] 一键安装 / 重装 / 修复" "$_icmd"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$k" "$name" "$chosen" "$inst" "$run" "$ver" "$size" "$entry" \
      "[SECRET] 默认密码 / 初始凭据" "无密码（本地服务；网站登录密码属于各应用，见对应卡片）"
    # 路径 / 配置项
    if [[ "$k" == nginx ]]; then
      rows=(
        "程序文件|$(ppath "$(command -v nginx 2>/dev/null || echo /usr/sbin/nginx)")"
        "主配置文件|$(ppath /etc/nginx/nginx.conf)"
        "本站站点配置|$(ppath /etc/nginx/sites-available/armbian-nas)"
        "网站根目录|$(ppath "$WEB_ROOT")"
        "访问日志|$(ppath "$BASE/logs/nginx/access.log")"
        "错误日志|$(ppath "$BASE/logs/nginx/error.log")"
        "配置语法检查|sudo nginx -t"
        "重载配置|sudo systemctl reload nginx"
      )
    else
      rows=(
        "PHP 可执行文件|$(ppath "$(command -v "$PHP_BIN" 2>/dev/null || echo /usr/bin/php8.2)")"
        "FPM 服务|$PHP_FPM_SVC"
        "主配置目录|$(ppath "$PHP_ETC")"
        "安全基线 ini|$(ppath "$PHP_ETC/fpm/conf.d/99-armbian-nas-security.ini")"
        "扩展核对探针|$(ppath "$WEB_ROOT/probe.php")"
        "★ 完整 PHP 探针|http://<本机IP>/prober.php（X-Prober / 雅黑风格，看整个网站环境）"
        "备用状态页|http://<本机IP>/status.php"
        "CLI 查扩展|sudo $PHP_BIN -m"
      )
    fi
    for i in "${rows[@]}"; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$k" "$name" "$chosen" "$inst" "$run" "$ver" "$size" "$entry" \
        "${i%%|*}" "${i#*|}"
    done
  done

  # ---- 本地博客站点（虚拟 key blog）-------------------------------------
  # 首页「本地博客」快捷卡片带 data-comp="blog"，JS 末段会用 byKey 查它；
  # 没有这张只读快照，卡片会被判成「未安装」而灰掉、禁止跳转。
  local _bk="blog" _bn="本地博客站点（:$PORT_BLOG）"
  local _bsize="0 MiB（复用 nginx；网站目录在外置盘）" _bver="-"
  local _binst="未安装" _brun="—" _bentry=":$PORT_BLOG ｜ $BLOG_DIR"
  local _bchosen="必需组件（随步骤 23 创建）"
  command -v nginx >/dev/null 2>&1 && _bver="$(nginx -v 2>&1 | awk -F/ '{print $2}' || echo -)"
  if [[ -d "$BLOG_DIR" && -f "$BLOG_DIR/index.html" ]]; then
    _binst="已安装"
    if port_open "$PORT_BLOG"; then _brun="运行中"; else _brun="已安装但未运行"; fi
  fi
  [[ -n "$_bver" ]] || _bver="-"
  local -a _bc=(
    "[CMD] 检查 nginx 配置|sudo nginx -t"
    "[CMD] 重载 nginx|sudo systemctl reload nginx"
    "[CMD] 重启 nginx|sudo systemctl restart nginx"
    "[CMD] 查看状态|sudo systemctl status nginx"
    "[CMD] 实时错误日志|sudo tail -f $BASE/logs/nginx/blog-error.log"
    "[CMD] 本地验证|curl -I http://127.0.0.1:$PORT_BLOG/"
  )
  local _bi
  for _bi in "${_bc[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$_bk" "$_bn" "$_bchosen" "$_binst" "$_brun" "$_bver" "$_bsize" "$_bentry" \
      "${_bi%%|*}" "${_bi#*|}"
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$_bk" "$_bn" "$_bchosen" "$_binst" "$_brun" "$_bver" "$_bsize" "$_bentry" \
    "[INSTALL] 一键安装 / 重装 / 修复" "sudo bash $SCRIPT_PATH --redo=23"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$_bk" "$_bn" "$_bchosen" "$_binst" "$_brun" "$_bver" "$_bsize" "$_bentry" \
    "[SECRET] 默认密码 / 初始凭据" "无密码；把博客程序放进 $BLOG_DIR 后按程序自身流程设置管理员"
  local -a _bp=(
    "站点配置文件|$BLOG_SITE"
    "网站根目录|$(ppath "$BLOG_DIR")"
    "默认首页|$(ppath "$BLOG_DIR/index.html")"
    "PHP 验证页|$(ppath "$BLOG_DIR/info.php")"
    "访问日志|$(ppath "$BASE/logs/nginx/blog-access.log")"
    "错误日志|$(ppath "$BASE/logs/nginx/blog-error.log")"
    "访问入口|http://<本机IP>:$PORT_BLOG/（新标签页打开）"
    "放博客程序|上传到 $BLOG_DIR，删掉默认 index.html 即可；如需伪静态改 location / 的 try_files"
  )
  for _bi in "${_bp[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$_bk" "$_bn" "$_bchosen" "$_binst" "$_brun" "$_bver" "$_bsize" "$_bentry" \
      "${_bi%%|*}" "${_bi#*|}"
  done
}

# TSV → JSON 数组（内嵌到静态导航页）。用 python3 做转义，避免路径里的
# 引号、反斜杠、中文把 HTML/JS 弄坏；同时把 "<" 转成 \u003c，防止意外闭合 script。
component_snapshot_json(){
  local tsv; tsv="$(mktemp)"
  component_paths_tsv > "$tsv"
  python3 - "$tsv" <<'PY'
import json, sys
items = []
order = []
idx = {}
for line in open(sys.argv[1], encoding='utf-8'):
    line = line.rstrip('\n')
    if not line:
        continue
    r = line.split('\t')
    while len(r) < 10:
        r.append('')
    k = r[0]
    if k not in idx:
        idx[k] = len(items)
        order.append(k)
        items.append({
            'key': k, 'name': r[1], 'chosen': r[2], 'installed': r[3],
            'running': r[4], 'version': r[5], 'size': r[6], 'entry': r[7],
            'paths': [], 'cmds': [], 'creds': [], 'install': ''
        })
    if r[8].startswith('[CMD]'):
        items[idx[k]]['cmds'].append({'label': r[8][5:].strip(), 'value': r[9]})
    elif r[8].startswith('[SECRET]'):
        items[idx[k]]['creds'].append({'label': r[8][8:].strip(), 'value': r[9]})
    elif r[8].startswith('[INSTALL]'):
        items[idx[k]]['install'] = r[9]
    elif r[8]:
        items[idx[k]]['paths'].append({'label': r[8], 'value': r[9]})
# ★ 卡片排序：常用 Web 界面在前，运行状态 / 探针 / 引擎类在后。
#   顶部快捷卡片与下方「运行状态卡片」用同一个 COMP 数组，顺序天然一致。
# ★ Docker 的 Portainer 是 Web 管理界面，归到「常用 Web」组；状态页与首页
#   共用同一份 COMP 数组，分组标题也按这里的顺序一一对应。
ORDER = ['ttyd','qb','transmission','aria2','filebrowser','verysync','blog','docker',
         'zerotier','minidlna','samba','nginx','php',
         'fan','hd_idle','gui']
_rank = {k: i for i, k in enumerate(ORDER)}
items.sort(key=lambda x: _rank.get(x['key'], 999))
s = json.dumps(items, ensure_ascii=False, separators=(',', ':'))
s = s.replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026')
sys.stdout.write(s)
PY
  rm -f "$tsv"
}

# ---- PHP：严格锁定 8.2，不安装 php-fpm / php-cli 这类会跟随系统默认版本的 meta 包 ----
PHP_VER="${PHP_VER:-8.2}"
PHP_BIN="php$PHP_VER"
PHP_FPM_SVC="php$PHP_VER-fpm.service"
PHP_ETC="/etc/php/$PHP_VER"
PHP_SOCK="/run/php/php$PHP_VER-fpm.sock"
PHP_EXT_FILE="$BASE/.deploy/php-extensions-wanted.txt"
PHP_EXT_MISSING="$BASE/.deploy/php-extensions-missing.txt"
PECL_FALLBACK="${PECL_FALLBACK:-1}"       # apt 缺第三方扩展时，用 pecl 自动补装
# ---------------------------------------------------------------------------
# ★ CLI SAPI 专有扩展（Debian/Ubuntu/Sury 官方 php8.2-fpm 二进制不编译 pcntl）
#   php8.2 -m（CLI）有 pcntl，但 php-fpm8.2 -m（FPM/网页真实环境）永远没有，
#   而且【没有 pcntl.so 可加载】——这是上游编译期决定，不是配置错误，也无法通过
#   conf.d 软链补上。用户要求的清单里 pcntl 必须保留在【CLI 侧】核对，
#   但 FPM 侧要把它排除，否则 probe.php 会误报 PHP_EXT_FAIL、最终自检假 FAIL。
#   真机实测（Armbian 26.11 / Sury php8.2-fpm 8.2.35）确认了这一点。
# ---------------------------------------------------------------------------
PHP_CLI_ONLY_EXTS="${PHP_CLI_ONLY_EXTS:-pcntl}"

# 导航页各 WebUI 端口（与实际安装保持一致，可按需覆盖）
PORT_QB="${PORT_QB:-8080}"
PORT_TR="${PORT_TR:-9091}"
PORT_VS="${PORT_VS:-8886}"
PORT_DLNA="${PORT_DLNA:-8200}"
PORT_FB="${PORT_FB:-8082}"             # FileBrowser 网页文件管理器（避开 8080 qB / 9091 tr）
FB_BIN="${FB_BIN:-}"                   # 可选：本地已下载的 filebrowser 二进制/tar.gz，离线安装用
FB_ROOT="${FB_ROOT:-/mnt}"             # 文件管理器根目录：/mnt 下能同时看到 sda1 与 sdb1

FB_VERSION="${FB_VERSION:-latest}"     # 可钉版本，如 v2.31.2

# ---- 本地博客站点（步骤 23）：独立端口 81，网站目录 boke（外置盘）----
PORT_BLOG="${PORT_BLOG:-81}"                       # 独立端口，不与 80/8080/8082/9091 冲突
BLOG_DIR="${BLOG_DIR:-$BASE/boke}"                 # 网站根目录：/mnt/sda1/www/boke
BLOG_SITE="/etc/nginx/sites-available/armbian-blog"
TR_PROXY="${TR_PROXY:-0}"                    # 1 = 在 80 端口加 /transmission/ 反代
TR_PROXY_SNIPPET="/etc/nginx/snippets/armbian-nas-transmission.conf"
TR_PROXY_PATH="/transmission"
# 用户指定必须包含的扩展清单（原文保留；"Zend OPcache" 被换行拆成 Zend / OPcache 两行，核对时会合并）
PHP_EXT_WANT="$(cat <<'PHPEXT'
Core
date
libxml
openssl
pcre
sqlite3
zlib
bcmath
ctype
curl
dom
filter
ftp
gd
gettext
hash
iconv
intl
json
mbstring
SPL
session
pcntl
standard
mysqlnd
PDO
pdo_mysql
pdo_sqlite
Phar
posix
random
Reflection
mysqli
shmop
SimpleXML
soap
sockets
sodium
sysvsem
tokenizer
xml
xmlreader
xmlwriter
zip
fileinfo
igbinary
imap
gmp
zstd
event
exif
redis
pdo_pgsql
Zend
OPcache

fileinfo
opcache
redis
imap
exif
intl
pgsql
pdo_pgsql
gmp
igbinary
zstd
event
PHPEXT
)"

# ---- 步骤 19：eMMC 瘦身与 PHP 安全基线 ----
DOCKER_LOG_MAX_SIZE="${DOCKER_LOG_MAX_SIZE:-10m}"
DOCKER_LOG_MAX_FILE="${DOCKER_LOG_MAX_FILE:-3}"
JOURNALD_MAX_USE="${JOURNALD_MAX_USE:-100M}"
JOURNALD_RETENTION="${JOURNALD_RETENTION:-2week}"
# ---- 内存分层：zram 优先 / 512M 磁盘 swapfile 兜底 ---------------------------
# 优先级（swapon 的 pri）：数字越大越先用。zram 高、磁盘低，内核才会先压缩进内存，
# 只有 zram 塞满了才碰 eMMC。
# 新版 Ubuntu / Armbian 的差别由 zram_baseline() 在运行时识别，这里只放默认值：
#   * Armbian 自带 armbian-zram-config.service：zram 默认 pri=5、磁盘 -2（不要覆盖它的大小/算法）
#   * Ubuntu/Debian 的 zram-tools：/etc/default/zramswap 里 PRIORITY=100
#   * systemd-zram-generator：/etc/systemd/zram-generator.conf 里 swap-priority=100
#   脚本绝不重复装第二套管理器去抢 /dev/zram0。
ZRAM_MODE="${ZRAM_MODE:-auto}"            # auto | off | force
ZRAM_PRIORITY="${ZRAM_PRIORITY:-100}"     # 新建 zram 时用的优先级
SWAP_PRIORITY="${SWAP_PRIORITY:--2}"      # 磁盘 swapfile 的优先级（低）
ZRAM_SIZE_PERCENT="${ZRAM_SIZE_PERCENT:-50}"   # zram 容量 = 物理内存的百分比
ZRAM_ALGO="${ZRAM_ALGO:-lz4}"             # S905X 是老四核，lz4 比 zstd 省 CPU
# vm.swappiness：内核 >=5.8 上限 200（专为 zram 放宽），<5.8 上限 100。
# auto = 有 zram 用 150、无 zram 用 10，并实测探测内核上限、失败自动回落 100。
SWAPPINESS="${SWAPPINESS:-auto}"
SWAPPINESS_USER_SET=0                     # 命令行显式给过 --swappiness 就置 1
SWAPPINESS_EFF=""                         # 实际生效值（自检/报告显示用）
EXT4_RESERVE_PCT="${EXT4_RESERVE_PCT:-1}"     # 根分区 ext4 保留块比例（默认 5% 太浪费 8G）
BOOT_LOG_MAX_SIZE="${BOOT_LOG_MAX_SIZE:-2M}"
APT_CACHE_ON_EXTERNAL="${APT_CACHE_ON_EXTERNAL:-1}"  # apt 缓存/lists 挪到外置盘
ENABLE_ADMIN_POOL="${ENABLE_ADMIN_POOL:-0}"   # 1 = 真正落地 root 权限 admin FPM 池（默认只生成模板）

# Docker data-root 外置：NTFS 上不能跑 overlay2，方案是在 NTFS 里放一个 ext4 loop 镜像
# 再挂回 /var/lib/docker。默认 0（关闭）——USB 掉盘/断电会伤容器层，属可选取舍。
DOCKER_EXTERNAL="${DOCKER_EXTERNAL:-0}"
DOCKER_LOOP_SIZE="${DOCKER_LOOP_SIZE:-12G}"
DOCKER_LOOP_IMG="$BASE/.docker-ext4.img"
DOCKER_EXT_HELPER="/usr/local/sbin/armbian-docker-external"
DOCKER_EXT_UNIT="armbian-docker-external.service"

MODE="deploy"           # deploy | status | check | help | dry-run | uninstall | reset
                        # | fan-probe | fan-probe-apply | fan-test-on | fan-test-off
FAN_PROBE_ONLY=0        # 1 = 只记录两轮确认结果，不启用温控服务
KEEP_GOING=0
NO_TMUX=0
# ★ 部署【前】的根分区剩余空间门槛（MiB）。装软件发生在「apt 缓存外置」之前，
#   此时 .deb 下载与解包都落在 eMMC，等步骤 19 瘦身时已经装完了。
#   全新系统实测（--no-docker --no-gui 部署后）：7.0G 用 2.1G / 剩 4.9G / 30%，
#   远高于门槛；这个检查只在「老机器已经塞满还想再部署」时才会拦下来。
MIN_ROOT_SPACE_MB="${MIN_ROOT_SPACE_MB:-1536}"   # 默认 1.5 GiB
FORCE_LOW_SPACE=0                                 # --force-low-space 跳过中止，只告警
# 交互终端：所有「需要人看/按键」的界面都显式走这个设备，不依赖 fd1。
# 原因：main 里 exec > >(tee ...) 会把 fd1 变成管道，-t 1 从此恒为假；
# 组件勾选(component_gate)、风扇确认(probe_ask)、共享目录勾选(step_shares)
# 统一用 /dev/tty 才能绕开日志管道。测试可注入 NAS_TTY 指向普通文件。
NAS_TTY="${NAS_TTY:-/dev/tty}"
# 在日志重定向【之前】算好的交互标志；0=非交互/无 tty，1=可用。
# main 会重算一次，这里给默认值，保证 --status / --check 等分支也有定义。
NAS_INTERACTIVE="${NAS_INTERACTIVE:-0}"
NONINTERACTIVE=0
RESELECT=0
REDO_ID=""
FROM_ID=""

# ---- 定向模式（★ 真机反馈）----
# 命令行一旦显式指定某个软件（--with-<组件>）或某个单步（--redo=<步骤>），
# 就【只执行目标步骤】，然后末尾重建导航页 + 状态页并跑自检。
# 不再把其它「已选跳过」的组件又弹出来问一遍，也绝不改写其它组件的状态。
# 只有不带这些参数、直接运行脚本的一键部署，才逐个询问所有可选组件。
# --no-<组件> / --all-yes / --all-no 是「完整部署的偏好」，不触发定向模式。
TARGETED=0
TARGET_COMPS=()      # --with-* 收集到的组件 key
TARGET_STEPS=()      # 最终要执行的步骤 ID 集合（去重后）
CONFIG_FILE="${CONFIG_FILE:-/etc/armbian-nas-deploy.conf}"

# ---------------------------------------------------------------------------
# 安装过程可见化（实机反馈：装 PHP 时长时间没输出，一度以为死机）
#   INSTALL_PROGRESS=1（默认）：apt 输出实时显示、每步带 [n/N] 总进度、
#                              长操作每 10 秒打一次心跳、结束打印耗时。
#   main 里 exec > >(tee -a "$BOOT_LOG") 2>&1 已经把 stdout/stderr 同时送到
#   屏幕和日志，所以【只要不额外 >/dev/null，输出天然可见】。以前恰恰是各
#   安装调用点自己加了 >/dev/null 2>&1 把过程吞掉了。
#   用 --quiet / --no-install-progress 可关闭（只留步骤级摘要）。
# ---------------------------------------------------------------------------
INSTALL_PROGRESS="${INSTALL_PROGRESS:-1}"
HEARTBEAT_SEC="${HEARTBEAT_SEC:-10}"
NAV_SECRETS="${NAV_SECRETS:-1}"          # 1=导航页卡片显示默认密码/密钥（局域网自用）
NAV_THEME="${NAV_THEME:-light}"          # light=白色明亮（默认）；dark=旧深色
PROBER_PHP="${PROBER_PHP:-}"             # 可选：指定 X-Prober 单文件 prober.php 路径

# ------------------------------ 基础工具 -------------------------------------
c_ok(){   printf '[ OK ] %s\n' "$*"; }
c_info(){ printf '[INFO] %s\n' "$*"; }
c_warn(){ printf '[WARN] %s\n' "$*"; }
c_err(){  printf '[FAIL] %s\n' "$*" >&2; }
c_step(){ printf '\n========== %s ==========\n' "$*"; }
die(){ c_err "$*"; exit 1; }

need_root(){ [[ "$(id -u)" -eq 0 ]] || die "请用 root 运行：sudo bash $SCRIPT_PATH"; }

apt_update(){
  if [[ "${INSTALL_PROGRESS:-1}" -eq 1 ]]; then
    c_info "  ▸ 刷新 apt 软件包索引（apt-get update；换源/网络慢时可能要 10–60 秒，输出实时显示）"
    apt-get update || c_warn "apt update 有告警，继续尝试安装"
  else
    apt-get update -qq || c_warn "apt update 有告警，继续尝试安装"
  fi
}
apt_install(){
  # 进度头：先告诉用户「正在装什么、一共几个包」，随后 apt 的下载/解包输出
  # 会实时打在屏幕上。绝不在函数内部重定向，否则调用方无法看到过程。
  if [[ "${INSTALL_PROGRESS:-1}" -eq 1 ]]; then
    c_info "  ▸ apt 安装 $# 个包（实时输出如下，请勿关闭窗口）：$*"
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::=--force-confold "$@"
}
# 探测性安装（「试一下，不行就换下一个方案」）：只打印一行意图，apt 细节不刷屏。
# 例如 zram-tools / systemd-zram-generator / zram-config 三级兜底、gpiod 可选包。
apt_install_quiet(){
  if [[ "${INSTALL_PROGRESS:-1}" -eq 1 ]]; then
    c_info "  ▸ 尝试安装（可选 / 兜底，失败会换方案）：$*"
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::=--force-confold "$@" >/dev/null 2>&1
}
# ---------------------------------------------------------------------------
# 长操作心跳：编译 pecl 扩展、下载大文件、跑官方安装脚本时，命令本身可能
# 几十秒到几分钟没有任何输出。每 HEARTBEAT_SEC 秒打一行「仍在执行（已 Xs）」，
# 用户看到心跳就知道没死机。心跳进程用 kill -0 $PPID 自检：父 shell 一退出
# 就自动结束，不会在 tmux 里留下孤儿进程。
# ---------------------------------------------------------------------------
long_op(){
  local label="$1"; shift
  local start beat rc ts
  start="$(date +%s)"
  c_info "  ⏳ 开始：$label"
  c_info "     这是耗时操作，终端会每 ${HEARTBEAT_SEC}s 打印一次心跳；看到心跳就说明在跑，请勿关闭窗口"
  beat=""
  if [[ "${INSTALL_PROGRESS:-1}" -eq 1 ]]; then
    ( while :; do
        sleep "${HEARTBEAT_SEC}"
        kill -0 "$PPID" 2>/dev/null || exit 0
        ts=$(( $(date +%s) - start ))
        printf '[%s]   ⏳ 仍在执行：%s（已 %dm%02ds）\n' \
          "$(date '+%H:%M:%S')" "$label" $((ts/60)) $((ts%60))
      done ) >&2 &
    beat=$!
  fi
  # if 条件里的命令不受 errexit 影响，失败也能正确收回心跳
  if "$@"; then rc=0; else rc=$?; fi
  if [[ -n "$beat" ]]; then
    kill "$beat" 2>/dev/null || true
    wait "$beat" 2>/dev/null || true
  fi
  ts=$(( $(date +%s) - start ))
  if [[ "$rc" -eq 0 ]]; then
    c_ok "  ✔ 完成：$label（耗时 $((ts/60))m$((ts%60))s）"
  else
    c_warn "  ✘ 结束但有告警：$label（rc=$rc，耗时 $((ts/60))m$((ts%60))s）"
  fi
  return "$rc"
}
# 带进度条的文件下载（curl -# 会显示 # 号进度；失败时保留原返回值）
download_show(){
  local label="$1" url="$2" out="$3"
  long_op "$label" curl -fSL --retry 2 --connect-timeout 15 -# -o "$out" "$url"
}

http_ok(){
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || echo 000)"
  [[ "$code" =~ ^[23] || "$code" == 401 || "$code" == 403 || "$code" == 409 ]]
}
port_open(){ timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/$1" >/dev/null 2>&1; }
lan_ip(){
  local dev out
  dev="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}' || true)"
  if [[ -n "$dev" ]]; then
    out="$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' || true)"
    if [[ -n "$out" ]]; then echo "$out"; return 0; fi
  fi
  ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); if(a[1]!=""){print a[1]; exit}}' || true
}
lan_ifaces(){
  ip -o link show 2>/dev/null | awk -F': ' '{print $2}' \
    | grep -Ev '^(lo|docker|veth|br-|zt|tun|tap|virbr)' \
    | paste -sd, - | cut -c1-120 || true
}
svc_active(){ systemctl is-active --quiet "$1" 2>/dev/null; }
php_service(){
  # 严格锁定 8.2：绝不自动挑系统里其它版本的 php*-fpm
  if systemctl list-unit-files --type=service --no-legend 2>/dev/null | grep -qF "$PHP_FPM_SVC"; then
    echo "$PHP_FPM_SVC"
    return 0
  fi
  # 兜底 1：unit 文件存在但 list-unit-files 输出格式不同（新版 systemd / 别名）
  if [[ -f "/lib/systemd/system/$PHP_FPM_SVC" || -f "/etc/systemd/system/$PHP_FPM_SVC"         || -f "/usr/lib/systemd/system/$PHP_FPM_SVC" ]]; then
    echo "$PHP_FPM_SVC"
    return 0
  fi
  # 兜底 2：从已加载单元里找 8.2 的 fpm（别名 / 模板实例）
  local u
  u="$(systemctl list-units --type=service --all --no-legend 2>/dev/null         | awk '/php8\.2.*fpm|fpm.*php8\.2/{print $1; exit}' || true)"
  if [[ -n "$u" ]]; then echo "$u"; return 0; fi
  # 兜底 3：socket 存在 + php-fpm 进程在 = FPM 确实在跑（哪怕 unit 名字查不到）。
  # 返回标准名即可，systemctl restart 用它仍然有效。
  if [[ -S "$PHP_SOCK" ]] && pgrep -f 'php-fpm|php8.2-fpm' >/dev/null 2>&1; then
    echo "$PHP_FPM_SVC"
    return 0
  fi
  # 兜底 4（最硬的功能证据）：能执行 PHP 页面 = FPM 必然在跑。
  # 真机上出现过 unit 名探测全失败、但 probe.php 正常的情况。
  if curl -fsS --max-time 8 'http://127.0.0.1/probe.php' 2>/dev/null | grep -q 'PHP_SQLITE_OK'; then
    echo "$PHP_FPM_SVC"
    return 0
  fi
  echo ""
}
# FPM 是否真的在跑：以【功能】为准，不依赖单元名拼写。
# 真机上出现过「probe.php 明明能执行（FPM 活着），但 php_service() 探测返回空」
# 的情况，仅凭 systemctl is-active <名字> 会误报 FAIL。
php_fpm_running_ok(){
  svc_active "$PHP_FPM_SVC" && return 0
  local u
  u="$(systemctl list-units --type=service --all --no-legend 2>/dev/null         | awk '/php.*fpm/{print $1; exit}' || true)"
  [[ -n "$u" ]] && svc_active "$u" && return 0
  [[ -S "$PHP_SOCK" ]] && pgrep -f 'php-fpm|php8.2-fpm' >/dev/null 2>&1 && return 0
  # 最后兜底：能执行 PHP 页面 = FPM 必然活着
  curl -fsS --max-time 8 'http://127.0.0.1/probe.php' 2>/dev/null | grep -q 'PHP_SQLITE_OK'
}
# FPM 侧期望清单：剔除 CLI SAPI 专有扩展（pcntl）
php_ext_want_fpm(){
  php_ext_want_ensure
  php_ext_normalize "$PHP_EXT_FILE" \
    | awk -v ex=",$PHP_CLI_ONLY_EXTS," 'index(ex, "," $0 ",") == 0'
}
php_ext_normalize(){ # 归一化扩展名：合并「Zend / OPcache」与「Zend OPcache」，小写去重；传 - 读 stdin
  local src="${1:--}" prog
  prog='
    { gsub(/\r/,""); line=$0; gsub(/^[ \t]+|[ \t]+$/,"",line)
      if (line=="" || line ~ /^\[/) next
      l=tolower(line)
      if (l=="zend") { pending=1; next }
      if (l=="opcache" && pending) { print "opcache"; pending=0; next }
      pending=0
      if (l=="zend opcache" || l=="zend opcache," || l=="opcache") print "opcache"; else print l
    }'
  if [[ "$src" == "-" ]]; then awk "$prog" | sort -u
  else awk "$prog" "$src" | sort -u; fi
}
php_ext_want_ensure(){ [[ -f "$PHP_EXT_FILE" ]] || printf '%s\n' "$PHP_EXT_WANT" > "$PHP_EXT_FILE"; }
php_ext_audit(){ # CLI 侧：php8.2 -m 与期望清单比对，结果写 $PHP_EXT_MISSING；0=齐全
  local got tmp_missing
  php_ext_want_ensure
  tmp_missing="$(mktemp)"; got="$(mktemp)"
  php_ext_normalize "$PHP_EXT_FILE" > "$got.want"
  "$PHP_BIN" -m 2>/dev/null | php_ext_normalize - > "$got.loaded"
  comm -23 "$got.want" "$got.loaded" > "$tmp_missing"
  mv -f "$tmp_missing" "$PHP_EXT_MISSING"
  rm -f "$got" "$got.want" "$got.loaded"
  [[ ! -s "$PHP_EXT_MISSING" ]]
}
# FPM 侧：curl probe.php 拿到 FPM 进程真实加载的模块（CLI 与 FPM 的 conf.d 可能不一致），
# 与同一份期望清单比对，结果写 $PHP_EXT_MISSING_FPM。probe.php 不读任何文件，故不受
# open_basedir 与 .deploy 700 权限影响。
php_ext_audit_fpm(){
  local body got tmp_missing marker='--- loaded extensions (PHP + Zend) ---'
  php_ext_want_ensure
  body="$(curl -fsS --max-time 8 'http://127.0.0.1/probe.php' 2>/dev/null || true)"
  if [[ -z "$body" || "$body" != *"$marker"* ]]; then
    printf 'probe.php-unreachable\n' > "$PHP_EXT_MISSING_FPM"
    return 1
  fi
  tmp_missing="$(mktemp)"; got="$(mktemp)"
  # ★ 用 FPM 侧清单（已剔除 pcntl 这类 CLI SAPI 专有扩展）
  php_ext_want_fpm > "$got.want"
  printf '%s\n' "$body" | awk -v m="$marker" 'f{print} $0==m{f=1}' \
    | php_ext_normalize - > "$got.loaded"
  comm -23 "$got.want" "$got.loaded" > "$tmp_missing"
  mv -f "$tmp_missing" "$PHP_EXT_MISSING_FPM"
  rm -f "$got" "$got.want" "$got.loaded"
  [[ ! -s "$PHP_EXT_MISSING_FPM" ]]
}

# ------------------------------ 状态机 ---------------------------------------
init_state_area(){
  mkdir -p "$STATE_DIR" "$MIRROR_DIR"
  touch "$STATE_FILE"
  chmod 700 "$STATE_DIR"
  chmod 600 "$STATE_FILE" "$SECRETS_FILE" 2>/dev/null || true
}
state_get(){
  local f="$STATE_FILE"
  [[ -r "$f" ]] || f="$MIRROR_FILE"
  [[ -r "$f" ]] || { echo ""; return 0; }
  grep -F "$1=" "$f" 2>/dev/null | tail -1 | cut -d= -f2- | cut -d'|' -f1 || true
}
state_set(){
  local id="$1" st="$2" tmp
  init_state_area
  tmp="$(mktemp)"
  grep -v -F "$id=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
  printf '%s=%s|%s\n' "$id" "$st" "$(date '+%F %T')" >> "$tmp"
  mv -f "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  cp -f "$STATE_FILE" "$MIRROR_FILE" 2>/dev/null || true
}
state_del(){
  local id="$1" tmp
  [[ -f "$STATE_FILE" ]] || return 0
  tmp="$(mktemp)"; grep -v -F "$id=" "$STATE_FILE" > "$tmp" || true
  mv -f "$tmp" "$STATE_FILE"; cp -f "$STATE_FILE" "$MIRROR_FILE" 2>/dev/null || true
}
sync_log(){
  [[ -f "$BOOT_LOG" ]] || return 0
  findmnt -rn --target "$MOUNT_MAIN" >/dev/null 2>&1 || return 0
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  sleep 0.3
  cp -f "$BOOT_LOG" "$LOG_FILE" 2>/dev/null || true
}
secret_get(){
  local key="$1" val
  [[ -f "$SECRETS_FILE" ]] || touch "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
  # ★ 内网自用统一凭据：simple 模式下 ttyd / aria2 恒定 admin；
  #   FileBrowser 因上游 ≥12 位策略用 FB_SIMPLE_PASS（默认 adminadmin123）。
  #   与 sync_simple_creds 写进 secrets.env 的值严格一致。
  #   其它 key（例如以后新增的）仍走随机生成，不受影响。
  if [[ "${CRED_MODE:-simple}" == "simple" ]]; then
    case "$key" in
      TTYD_WEB_PASS|ARIA_RPC_SECRET) printf 'admin'; return 0 ;;
      FILEBROWSER_PASS)              printf '%s' "$FB_SIMPLE_PASS"; return 0 ;;
    esac
  fi
  val="$(grep -F "$key=" "$SECRETS_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  if [[ -z "$val" ]]; then
    val="$(openssl rand -hex 16 2>/dev/null || date +%s%N | sha256sum | cut -c1-32)"
    printf '%s=%s\n' "$key" "$val" >> "$SECRETS_FILE"
  fi
  printf '%s' "$val"
}

# ---------------------------------------------------------------------------
# ★ FileBrowser 改密：必须先停服，否则报 "Error: timeout"（真机实测）
#
# 根因：FileBrowser 用 bbolt(bolt) 存 filebrowser.db，同一时刻只允许一个进程
# 持有写锁（flock）。服务正在跑时，另一条 CLI 去开同一个 db 会一直等锁，
# 超时就打印 "Error: timeout"；此时密码【并没有改成功】，而命令行里的
# `&& sudo systemctl restart ...` 也因为前一条失败根本不会执行。
#
# 所以正确顺序是【停服 → users update → 启服】，而且不管改密成功与否都必须
# 把服务拉回来，不能让 NAS 的文件管理器停在那儿。FB_BIN 可由测试桩注入。
# ---------------------------------------------------------------------------
fb_set_password(){
  local pw="$1" fbdb="${2:-$FB_DB}"
  # ★ 不能用 FB_BIN：那是 --fb-bin=<离线包路径> 的变量，可能指向 tar.gz / 临时文件。
  #   FB_CLI 只给测试桩注入；正式环境恒为 /usr/local/bin/filebrowser。
  local fb="${FB_CLI:-/usr/local/bin/filebrowser}" was=0 rc=0 i
  [[ -x "$fb" && -f "$fbdb" ]] || { c_warn "FileBrowser 未安装或数据库不存在：$fbdb"; return 1; }
  [[ -n "$pw" ]] || { c_warn "FileBrowser 新密码不能为空"; return 1; }
  # ★ 真机第二个错误：password is too short, minimum length is 12。
  #   该校验发生在打开数据库【之前】，所以短密码连 timeout 都遇不到，直接被拒。
  #   先在本地挡掉，给中文提示 + 可用示例，不再让用户去猜英文报错。
  if (( ${#pw} < FB_PASS_MIN )); then
    c_warn "  ★ FileBrowser 拒绝改密：密码 ${#pw} 位，上游要求至少 ${FB_PASS_MIN} 位"
    c_warn "    这就是 CLI 里的 'Error: password is too short, minimum length is 12'"
    c_warn "    admin(5) / adminadmin(10) 都不行；用 adminadmin123(13) 或自定义 ≥12 位"
    c_warn "    自定义：sudo bash $SCRIPT_PATH --fb-password=你的12位以上密码 --redo=22"
    return 1
  fi

  if svc_active armbian-filebrowser; then
    was=1
    c_info "  FileBrowser 正在运行：先停服释放 bbolt 数据库锁（不停会报 Error: timeout）"
    systemctl stop armbian-filebrowser >/dev/null 2>&1 || true
    # 等锁真正释放（最多 5 秒），避免 stop 返回后 flock 还没交出去
    for i in 1 2 3 4 5; do
      "$fb" -d "$fbdb" users ls >/dev/null 2>&1 && break
      sleep 1
    done
  fi

  if ! "$fb" -d "$fbdb" users update admin --password "$pw" >/dev/null 2>&1; then
    rc=1
  fi

  # ★ 无论成败都把服务拉回来；失败也不能让文件管理器一直停着
  if [[ "$was" -eq 1 ]]; then
    if ! systemctl start armbian-filebrowser >/dev/null 2>&1; then
      c_warn "  ★ FileBrowser 服务未能重新启动，请手动：sudo systemctl start armbian-filebrowser"
    fi
  fi

  if [[ "$rc" -ne 0 ]]; then
    c_warn "  ★ FileBrowser 改密失败（Error: timeout / password is too short / 账号 admin 不存在 / CLI 版本差异）"
    c_warn "    正确顺序：sudo systemctl stop armbian-filebrowser"
    c_warn "              sudo filebrowser -d $fbdb users update admin --password 至少12位的新密码"
    c_warn "              sudo systemctl start armbian-filebrowser"
    c_warn "    查占用：sudo lsof $fbdb 或 sudo fuser -v $fbdb"
    c_warn "    查服务：sudo systemctl status armbian-filebrowser ; sudo journalctl -u armbian-filebrowser -n 30"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# ★★ FileBrowser 数据库路径自愈（真机：改密成功却依然登录不上）
#
# 现象：状态页/文档/改密命令写 $BASE/filebrowser/filebrowser.db，
#       ps -ef 却显示服务跑的是 $BASE/filebrowse/filebrowser.db（少一个 r）。
# 后果：改密改到了「另一个库」，服务读的库里旧密码不变，怎么改都登不上。
# 根因：早期版本（或手工改过的 unit）与当前脚本用了不同目录名，而脚本每次
#       重建页面只刷新显示、从不核对 unit 里真正的 -d 参数。
# 修法：以【unit 实际在用的库】为权威，把它迁到规范路径 FB_DB，重写 unit，
#       再把统一密码收敛到迁移后的库上。只搬数据、绝不删原有文件。
#   · 路径已经一致 → 直接返回，零动作、零中断（幂等）
#   · 只在 MODE=deploy 下动手；--check / --status / --help / --dry-run 只读
# ---------------------------------------------------------------------------
fb_actual_db(){
  local u=/etc/systemd/system/armbian-filebrowser.service p=""
  if [[ -r "$u" ]]; then
    p="$(grep -oE -- '-d[[:space:]]+[^[:space:]]+' "$u" 2>/dev/null | head -1 | awk '{print $2}' || true)"
  fi
  if [[ -z "$p" ]]; then
    p="$(ps -eo args 2>/dev/null | grep '[f]ilebrowser' \
        | grep -oE -- '-d[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $2}' || true)"
  fi
  printf '%s' "$p"
}

fb_db_reconcile(){
  [[ "${MODE:-}" == "deploy" ]] || return 0
  [[ -x /usr/local/bin/filebrowser ]] || return 0
  local actual ts
  actual="$(fb_actual_db)"
  [[ -n "$actual" && "$actual" != "$FB_DB" ]] || return 0   # 已一致：什么都不做

  c_warn "★ 检测到 FileBrowser 数据库路径与脚本不一致（这就是改密不生效的原因）："
  c_warn "   服务实际在用：$actual"
  c_warn "   脚本规范路径：$FB_DB"
  c_warn "   现在把「实际在用的库」迁移到规范路径，并重写服务单元（旧文件保留备份，不删数据）"

  # bbolt 独占锁：必须先停服再搬文件
  if svc_active armbian-filebrowser; then
    systemctl stop armbian-filebrowser >/dev/null 2>&1 || true
    sleep 1
  fi
  mkdir -p "$FB_DB_DIR"
  if [[ -f "$actual" ]]; then
    if [[ -f "$FB_DB" ]]; then
      ts="$(date +%Y%m%d-%H%M%S)"
      cp -a "$FB_DB" "$FB_DB.bak.$ts" 2>/dev/null || true
      c_info "  规范路径原有库已备份为 $FB_DB.bak.$ts"
    fi
    # 用 cp 而非 mv：旧文件原样留着，万一要回退随时可用
    cp -a "$actual" "$FB_DB" || { c_warn "  迁移失败，保持原状"; return 1; }
    c_ok "  已把实际在用的库迁到：$FB_DB（旧库保留在 $actual）"
  else
    c_warn "  实际路径 $actual 下没有数据库文件，仅修正 unit 路径，账号将在重配时重建"
  fi

  # 重写 unit 里的 -d 参数（只替换 -d 后面那一段，不动其它 ExecStart 参数）
  local u=/etc/systemd/system/armbian-filebrowser.service
  if [[ -w "$u" ]]; then
    sed -i -E "s#(-d[[:space:]]+)[^[:space:]]+#\1$FB_DB#" "$u"
    systemctl daemon-reload >/dev/null 2>&1 || true
    c_ok "  服务单元已改为 -d $FB_DB；状态页与改密命令现在指向同一个库"
  else
    c_warn "  服务单元不可写，请手动重跑：sudo bash $SCRIPT_PATH --with-filebrowser --redo=22"
  fi
  # 迁移过来的库里是旧密码 → 收敛到统一凭据（内部会停服/改密/启服）
  if [[ -f "$FB_DB" ]]; then
    if fb_set_password "$(secret_get FILEBROWSER_PASS)" "$FB_DB"; then
      c_ok "  迁移后密码已统一：admin / $(secret_get FILEBROWSER_PASS)"
    else
      c_warn "  迁移后改密未成功，可手动：sudo systemctl stop armbian-filebrowser ; sudo filebrowser -d $FB_DB users update admin --password 至少12位密码 ; sudo systemctl start armbian-filebrowser"
    fi
  fi
  return 0
}

# 自检 helper：库文件存在，且 unit 里 -d 指向同一个路径。
# 只查「一致性」，不修（修由 fb_db_reconcile 负责，--check 保持只读）。
fb_db_path_ok(){
  local a
  a="$(fb_actual_db)"
  [[ -f "$FB_DB" ]] || return 1
  [[ -z "$a" || "$a" == "$FB_DB" ]] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# ★ 统一凭据 admin / admin 的落地与下游同步（幂等）
#
# 只改「脚本自己能控制」的三处：ttyd 网页密码、aria2 RPC 密钥、FileBrowser 密码。
# 旧机器上这些值是随机串，光改 secrets.env 不够——aria2.conf、nginx 的
# .ttydpasswd（bcrypt/APR1）、filebrowser.db 里都存着旧值，不同步会直接连不上。
# 所以这里在【每次运行开头】收敛一次：值不一致才重写文件 + 重启对应服务，
# 全部一致时零动作、零中断。--creds=random 时整段跳过，恢复旧行为。
# ---------------------------------------------------------------------------
sync_simple_creds(){
  # ★ 必须先纠正数据库路径，否则下面 fb_set_password 又会改到另一个库上
  fb_db_reconcile || c_warn "FileBrowser 数据库路径自愈未完成，请查看上面的提示"
  # ★ 从 simple 切回 random：把三把 admin 换成新随机值。
  #   不这么做的话 secrets.env 里仍写着 admin，--creds=random 会形同虚设。
  if [[ "${CRED_MODE:-simple}" != "simple" ]]; then
    local rk rv rtmp rchanged=0 _sp
    mkdir -p "$STATE_DIR"; [[ -f "$SECRETS_FILE" ]] || : > "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
    for rk in TTYD_WEB_PASS ARIA_RPC_SECRET FILEBROWSER_PASS; do
      # ★ 不能只看 "$rk=admin"：FileBrowser 的 simple 值是 adminadmin123，
      #   前缀匹配虽能命中，但换成任意自定义值后就会漏判。
      case "$rk" in FILEBROWSER_PASS) _sp="$FB_SIMPLE_PASS";; *) _sp="admin";; esac
      if grep -qF "$rk=$_sp" "$SECRETS_FILE" 2>/dev/null; then
        rv="$(openssl rand -hex 16 2>/dev/null || date +%s%N | sha256sum | cut -c1-32)"
        rtmp="$(mktemp)"; grep -vF "$rk=" "$SECRETS_FILE" > "$rtmp" 2>/dev/null || true
        printf '%s=%s\n' "$rk" "$rv" >> "$rtmp"; mv -f "$rtmp" "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
        rchanged=1
      fi
    done
    if [[ "$rchanged" -eq 1 ]]; then
      c_warn "已切回随机密钥（--creds=random）。请分别重跑对应步骤让服务配置同步："
      c_warn "  sudo bash $SCRIPT_PATH --creds=random --redo=21   # ttyd"
      c_warn "  sudo bash $SCRIPT_PATH --creds=random --redo=10   # aria2 RPC"
      c_warn "  sudo bash $SCRIPT_PATH --creds=random --redo=22   # FileBrowser"
    fi
    return 0
  fi
  local key old want tmp changed=0
  mkdir -p "$STATE_DIR"; [[ -f "$SECRETS_FILE" ]] || : > "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
  for key in TTYD_WEB_PASS ARIA_RPC_SECRET FILEBROWSER_PASS; do
    case "$key" in FILEBROWSER_PASS) want="$FB_SIMPLE_PASS";; *) want="admin";; esac
    old="$(grep -F "$key=" "$SECRETS_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    if [[ "$old" != "$want" ]]; then
      tmp="$(mktemp)"
      grep -vF "$key=" "$SECRETS_FILE" > "$tmp" 2>/dev/null || true
      printf '%s=%s\n' "$key" "$want" >> "$tmp"
      mv -f "$tmp" "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
      changed=1
    fi
  done
  if [[ "$changed" -eq 0 ]]; then return 0; fi
  c_info "统一凭据：ttyd / aria2 RPC = admin / admin；FileBrowser = admin / $FB_SIMPLE_PASS（上游强制 ≥${FB_PASS_MIN} 位；--creds=random 可恢复随机）"

  # ① aria2：改 rpc-secret 并重启（服务没装就跳过，step_aria2 会用 admin 生成）
  local ac="$BASE/aria2/aria2.conf"
  if [[ -f "$ac" ]] && ! grep -q '^rpc-secret=admin$' "$ac"; then
    sed -i 's/^rpc-secret=.*/rpc-secret=admin/' "$ac"
    if svc_active aria2; then systemctl restart aria2 >/dev/null 2>&1 || true; fi
    c_ok "  aria2.conf 的 rpc-secret 已同步为 admin"
  fi
  # ② ttyd：nginx 密码文件里存的是哈希，必须用 htpasswd 重建
  local passfile="/etc/nginx/.ttydpasswd"
  if [[ -f "$passfile" ]] && command -v htpasswd >/dev/null 2>&1; then
    htpasswd -bcB "$passfile" "$TTYD_AUTH_USER" admin >/dev/null 2>&1 || \
      printf '%s:%s\n' "$TTYD_AUTH_USER" "$(openssl passwd -apr1 admin 2>/dev/null)" > "$passfile"
    chown root:www-data "$passfile" 2>/dev/null || true; chmod 640 "$passfile"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    c_ok "  nginx 网页终端密码文件已重建：$TTYD_AUTH_USER / admin"
  fi
  # ③ FileBrowser：bbolt 独占锁，必须【停服 → 改密 → 启服】
  #   ★ 真机教训：旧版在服务运行时直接 users update，报 Error: timeout，
  #     而 `|| true` + 无条件 c_ok 让它「假装成功」。现在由 fb_set_password
  #     统一处理（失败也会把服务拉回来），且失败时明确告警而不是假 OK。
  local fbdb="$FB_DB"
  if [[ -f "$fbdb" && -x /usr/local/bin/filebrowser ]]; then
    if fb_set_password "$FB_SIMPLE_PASS" "$fbdb"; then
      c_ok "  FileBrowser 账号已更新：admin / $FB_SIMPLE_PASS"
    else
      c_warn "  FileBrowser 账号未能同步（不影响其它组件）；按上面打印的命令手动处理"
    fi
  fi
  return 0
}

# ------------------------------ 组件选择（装 / 跳过）-------------------------
component_var(){ local k="${1//-/_}"; printf 'INSTALL_%s' "${k^^}"; }
component_installed(){
  local k="$1"
  case "$k" in
    docker)       command -v docker >/dev/null 2>&1 ;;
    verysync)     [[ -x /usr/bin/verysync/verysync ]] || \
                  systemctl list-unit-files --no-legend 2>/dev/null | grep -qi 'verysync.*\.service' ;;
    zerotier)     command -v zerotier-cli >/dev/null 2>&1 ;;
    qb)           command -v qbittorrent-nox >/dev/null 2>&1 ;;
    transmission) command -v transmission-daemon >/dev/null 2>&1 ;;
    aria2)        command -v aria2c >/dev/null 2>&1 ;;
    minidlna)     command -v minidlnad >/dev/null 2>&1 ;;
    samba)        command -v smbd >/dev/null 2>&1 ;;
    fan)          [[ -f /etc/systemd/system/armbian-fan.service ]] ;;
    ttyd)         command -v ttyd >/dev/null 2>&1 ;;
    filebrowser)  [[ -x /usr/local/bin/filebrowser ]] ;;
    hd_idle)      dpkg -s hd-idle >/dev/null 2>&1 || \
                  [[ -f /etc/systemd/system/armbian-hdparm.service ]] ;;
    gui)          # ★ 真机反馈：Armbian 镜像默认可能就是 graphical.target，
                  #   单看它会把「选择跳过」误显示成「已安装 / 运行中」。
                  #   必须同时确认 XFCE 本体确实在。
                  { command -v startxfce4 >/dev/null 2>&1 || \
                    dpkg -s xfce4 >/dev/null 2>&1 || \
                    dpkg -s xfce4-session >/dev/null 2>&1; } && \
                  systemctl get-default 2>/dev/null | grep -q graphical ;;
    *)            return 1 ;;
  esac
}
# ---------------------------------------------------------------------------
# 组件的「选择状态」四态判定。仅用于【展示 / 自检】，不参与部署决策
# （部署是否询问由 component_gate + run_step 决定，和这里完全解耦）。
#   chosen      已明确选择安装、或该步骤已完成、或检测到已装
#   skip        用户主动输入 n / --no-xxx / --all-no
#   uninstalled 用户主动卸载过
#   undecided   ★状态为空：脚本还没跑到这一步，尚未做任何选择
#
# 【为什么必须有 undecided】旧版最后一行 `return 0` 把「还没跑到」当成
# 「计划安装」，于是新机器直接 --check 时：组件清单写「安装」、ck_comp 走
# ck OK 去查根本不存在的服务 → 报一堆 FAIL。那是误报，不是安装失败。
# 现在空状态一律归 undecided，清单标「尚未部署」、自检标 SKIP 并说明原因。
# ---------------------------------------------------------------------------
component_decision(){
  local k="$1" var v st
  var="$(component_var "$k")"; v="${!var:-}"
  [[ "$v" == "0" || "$ALL_NO" -eq 1 ]] && { echo skip; return 0; }
  [[ "$v" == "1" || "$ALL_YES" -eq 1 ]] && { echo chosen; return 0; }
  st="$(state_get "${COMP_STEP[$k]}")"
  case "$st" in
    skip|uninstalled) echo "$st"; return 0 ;;
    # 已经跑过（含中途失败）：属于「确实打算装」，自检该报错就报错
    done|running|failed) echo chosen; return 0 ;;
  esac
  # 没跑过但机器上确实装着（用户自己 apt 装的）→ 仍算已装，避免清单失真
  component_installed "$k" && { echo chosen; return 0; }
  echo undecided
}
component_chosen(){ # 返回 0 = 已选择安装 / 已装；1 = 未选择（含尚未部署）
  [[ "$(component_decision "$1")" == "chosen" ]]
}
# 交互询问；返回 0=安装，77=跳过（run_step 会把 77 记成 skip 状态）
component_gate(){
  local k="$1" var v ans inst="未安装" choice
  var="$(component_var "$k")"; v="${!var:-}"
  # ★ 定向模式：目标步骤直接执行，绝不弹出「是否安装」。
  #   用户已经用 --with-<组件> / --redo=<步骤> 明确表达了意图，再问一遍毫无意义；
  #   更重要的是旧版会在这里把别的组件状态写成 skip（真机日志里 ttyd 被误改）。
  #   只有显式传了 --no-<组件> 才尊重跳过。
  if [[ "${TARGETED:-0}" -eq 1 ]]; then
    if [[ "$v" == "0" ]]; then
      c_warn "定向模式：${COMP_NAME[$k]} 被 --no-$k 明确跳过"
      return 77
    fi
    c_ok "定向模式：直接执行 ${COMP_NAME[$k]}（不询问装 / 跳过）"
    return 0
  fi
  component_installed "$k" && inst="已检测到已安装"

  if [[ -n "$v" ]]; then
    choice="$v"
  elif [[ "$ALL_YES" -eq 1 ]]; then
    choice=1
  elif [[ "$ALL_NO" -eq 1 ]]; then
    choice=0
  elif [[ "$NONINTERACTIVE" -eq 1 || ! -r /dev/tty || ! -w /dev/tty ]]; then
    choice="${COMP_DEFAULT[$k]}"
    c_info "非交互模式：${COMP_NAME[$k]} 按默认值 $([[ $choice -eq 1 ]] && echo 安装 || echo 跳过)（可用 --with-$k / --no-$k 指定）"
  else
    {
      printf '\n────────────────────────────────────────────────────────────\n'
      printf '  [软件选择] %s\n' "${COMP_NAME[$k]}"
      printf '  预计占用 eMMC：%s\n' "${COMP_SIZE[$k]}"
      printf '  当前：%s    数据/界面：%s\n' "$inst" "${COMP_DATA[$k]}"
      printf '  访问入口：%s\n' "${COMP_ENTRY[$k]}"
      # 1G 内存的小白最容易在选装时踩 OOM，这里把内存余量也摆出来
      printf '  本机内存：%s MiB%s\n' "$(mem_total_mib)" \
        "$(is_low_mem && printf '（偏低：建议跳过 Docker / 图形界面 / 多个下载器）' || printf '')"
      printf '  是否安装？ 直接回车=安装，输入 n = 跳过（下次运行会再问）  [Y/n] '
    } > /dev/tty
    ans=""
    read -r ans < /dev/tty || ans=""
    case "${ans,,}" in
      n|no|0) choice=0 ;;
      *)      choice=1 ;;
    esac
    printf '\n' > /dev/tty
  fi

  if [[ "$choice" -eq 1 ]]; then
    c_ok "选择安装：${COMP_NAME[$k]}"
    return 0
  fi
  c_warn "选择跳过：${COMP_NAME[$k]}（未安装，下次运行会再次询问；--with-$k 可直接安装）"
  return 77
}

# 步骤表：ID|中文描述|函数名|可选组件key（- = 不可跳过）
STEPS=(
  "01|准备外置盘数据目录结构|step_layout|-"
  "02|安装基础依赖与工具|step_apt_base|-"
  "03|安装 nginx + PHP 8.2 + 指定扩展 + sqlite3|step_nginx_php|-"
  "04|配置网站根目录、PHP 探针与日志重定向|step_nginx_site|-"
  "05|安装 Docker 引擎（可选）|step_docker|docker"
  "06|安装微力同步 Verysync（可选）|step_verysync|verysync"
  "07|安装并加入 ZeroTier（可选）|step_zerotier|zerotier"
  "08|安装 qBittorrent-nox 原生版（可选）|step_qb|qb"
  "09|安装 Transmission 原生版（可选）|step_tr|transmission"
  "10|安装 aria2 + AriaNg Web 界面（可选）|step_aria2|aria2"
  "11|选择 sda1 / sdb1 下的视频共享目录|step_shares|-"
  "12|安装配置 MiniDLNA（可选）|step_minidlna|minidlna"
  "13|安装配置 Samba 共享（可选）|step_samba|samba"
  "14|CPU 温度控制风扇服务（可选）|step_fan|fan"
  "15|空闲硬盘休眠（可选）|step_hd_idle|hd_idle"
  "16|防火墙放通局域网服务端口|step_firewall|-"
  "17|安装图形界面（可选）|step_gui|gui"
  "18|生成默认目录 HTML 导航页|step_nav|-"
  "19|eMMC 瘦身与 PHP 安全基线|step_emmc_baseline|-"
  "20|（已移除）清理面板 OLED 残留（不再扫描 I2C）|step_oled_removed|-"
  "21|安装 ttyd 网页终端（默认装，需密码）|step_ttyd|ttyd"
  "22|安装 FileBrowser 网页文件管理器（可选）|step_filebrowser|filebrowser"
  "23|创建本地博客站点（端口 81 / 目录 boke）|step_blog|-"
)
step_desc(){ local s i d f o; for s in "${STEPS[@]}"; do IFS='|' read -r i d f o <<< "$s"; if [[ "$i" == "$1" ]]; then echo "$d"; return 0; fi; done; echo "$1"; }

# 组件 key → 步骤 ID（从 STEPS 表第 4 列读，避免再维护一份容易漂移的映射）
step_for_component(){
  local k="$1" s i d f o
  for s in "${STEPS[@]}"; do
    IFS='|' read -r i d f o <<< "$s"
    [[ "$o" == "$k" ]] && { echo "$i"; return 0; }
  done
  return 1
}
in_target_steps(){
  local want="$1" x
  for x in "${TARGET_STEPS[@]}"; do [[ "$x" == "$want" ]] && return 0; done
  return 1
}
# 定向模式专用：只清目标步骤自己的状态，【不清】后续步骤。
# 旧版 reset_from 会把 22 之后的 23 也清掉，导致「只装 FileBrowser」却把博客站点重跑一遍。
reset_only(){
  local x
  init_state_area
  for x in "$@"; do state_del "$x"; done
}

run_step(){
  local id="$1" desc="$2" func="$3" opt="${4:--}" st rc
  st="$(state_get "$id")"
  if [[ "$st" == "done" ]]; then
    c_ok "[$id] 已完成，跳过：$desc"
    return 0
  fi
  local _step_tag="[$id/${#STEPS[@]}]" _t0 _dt
  if [[ "$st" == "running" || "$st" == "failed" ]]; then
    c_warn "$_step_tag 上次状态=$st（可能中途卡住/断线），现在重新执行：$desc"
  else
    c_step "$_step_tag $desc"
  fi
  _t0="$(date +%s)"
  c_info "  ▶ 步骤开始 $(date '+%H:%M:%S')｜共 ${#STEPS[@]} 步，本步 [$id]；安装过程会实时打印，长操作另有心跳提示"

  # 可选组件：先问「装 / 跳过」。返回 77 = 本次跳过，记 skip 状态（不是 done），
  # 所以下次运行脚本会再次询问；用户那时输入 y 即可安装。
  if [[ "$opt" != "-" && -n "$opt" ]]; then
    if component_gate "$opt"; then
      :
    else
      rc=$?
      if [[ "$rc" -eq 77 ]]; then
        state_set "$id" "skip"
        sync_log
        c_warn "[$id] 已跳过：$desc（下次运行会再问；--with-$opt 可直接安装）"
        return 0
      fi
      state_set "$id" "failed"; sync_log
      c_err "[$id] 组件选择出错（rc=$rc）：$desc"
      [[ "$KEEP_GOING" -eq 1 ]] || die "组件选择失败，已停在 [$id]"
      return 0
    fi
  fi

  state_set "$id" "running"
  # 子 shell 内重新开启 errexit，保证步骤内任一命令失败都会整体判失败
  if ( set -e; "$func" ); then
    state_set "$id" "done"
    sync_log
    _dt=$(( $(date +%s) - _t0 ))
    c_ok "$_step_tag 完成：$desc（本步耗时 $((_dt/60))m$((_dt%60))s）"
  else
    rc=$?
    state_set "$id" "failed"
    sync_log
    _dt=$(( $(date +%s) - _t0 ))
    c_err "$_step_tag 失败（rc=$rc，耗时 $((_dt/60))m$((_dt%60))s）：$desc"
    if [[ "$KEEP_GOING" -eq 1 ]]; then
      c_warn "已按 --keep-going 继续后续步骤；修复后重跑脚本即可补上本步"
    else
      die "已停在步骤 [$id]。日志：$LOG_FILE；状态：bash $SCRIPT_PATH --status；修好后直接重跑脚本会从本步继续。"
    fi
  fi
}
reset_from(){
  local target="$1" found=0 s i d f o
  init_state_area
  for s in "${STEPS[@]}"; do
    IFS='|' read -r i d f o <<< "$s"
    [[ "$i" == "$target" ]] && found=1
    [[ $found -eq 1 ]] && state_del "$i"
  done
  [[ $found -eq 1 ]] || die "未知步骤 ID：$target"
  c_info "已清除 [$target] 及其之后步骤的状态，下次运行会重新执行"
}

# ------------------------------ 挂载（每次都做，幂等） -----------------------
# ★ 真机教训（CumeBox2 双 USB 转 SATA 盘位）：
#   sda1 挂上了、sdb1 永远挂不上，reboot 也如此。两个原因叠加：
#   ① 内核 ntfs3 对「脏位 / Windows 快速启动休眠 / 个别元数据」极严格，
#      直接拒绝 rw 挂载；用户态 ntfs-3g 容忍度高。手写 fstab 改成
#      `-t ntfs` 能挂，正是因为 mount.ntfs → mount.ntfs-3g 符号链接。
#   ② nofail + x-systemd.device-timeout=30s：第二块 USB 盘同时上电枚举慢，
#      30s 内没出现就被 systemd 跳过，且【不会重试】；reboot 还是不行。
#   旧版 ensure_mounts 的降级链只在「主盘没挂上」时跑，第二块盘只
#   mount -a 一次 + WARN，从不降级、从不回写 fstab；重启后 systemd 直接读
#   fstab，脚本的降级链根本没机会执行 → 永久挂不上。
# 修复：① 逐盘降级并把成功组合回写 fstab；②  device-timeout 120s；
#       ③ 开机补挂 timer（设备晚到/ntfs3 拒绝都能自愈，且固化正确驱动）。
DEV_TIMEOUT="${DEV_TIMEOUT:-120}"          # 秒；USB 双盘 spin-up，30s 太短
SECOND_FSTYPE="${SECOND_FSTYPE:-}"          # 可强制第二块盘：ntfs-3g / ntfs / ntfs3
MOUNT_HELPER_ENABLED="${MOUNT_HELPER_ENABLED:-1}"
MOUNT_HELPER="/usr/local/sbin/armbian-nas-mount-helper"
MOUNT_HELPER_UNIT="armbian-nas-mounts.service"
MOUNT_HELPER_TIMER="armbian-nas-mounts.timer"
MOUNT_HELPER_LOG="/var/log/armbian-nas-mounts.log"

# 生成开机补挂 helper：systemd 直接读 fstab 时不会跑本脚本，所以必须有一个
# 独立的开机任务，负责把「nofail 跳过 / USB 晚到 / ntfs3 拒绝」的盘补挂回来。
# 它只尝试挂载与改写 fstab 的 fs/opts 两列：绝不 force、绝不 ntfsfix、
# 绝不格式化、绝不动盘上已有文件。
install_mount_helper(){
  [[ "$MOUNT_HELPER_ENABLED" -eq 1 ]] || return 0
  command -v python3 >/dev/null 2>&1 || { c_warn "缺 python3，跳过开机补挂单元"; return 0; }
  cat > "$MOUNT_HELPER" <<'HELPER'
#!/usr/bin/env bash
# armbian-nas 开机补挂：处理 nofail 跳过 / USB 晚到 / ntfs3 拒绝挂载。
# 只改 /etc/fstab 的「文件系统类型 + 选项」两列，不动 UUID、挂载点、数据。
set -u
LOG="${MOUNT_HELPER_LOG:-/var/log/armbian-nas-mounts.log}"
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }
FSTAB=/etc/fstab
TIMEOUT="${DEV_TIMEOUT:-120}"
[[ -r "$FSTAB" ]] || { log "无 fstab，退出"; exit 0; }

# 只处理脚本标记块内的条目，绝不碰用户自己的其它挂载
python3 - "$FSTAB" <<'PY' | while IFS='|' read -r uuid mp fs opts; do
import sys
lines=open(sys.argv[1],encoding='utf-8',errors='replace').read().splitlines()
inside=False
for l in lines:
    if l.startswith('# >>> armbian-nas-deploy >>>'): inside=True; continue
    if l.startswith('# <<< armbian-nas-deploy <<<'): inside=False; continue
    if not inside or not l.strip() or l.lstrip().startswith('#'): continue
    f=l.split()
    if len(f)>=4 and f[0].startswith('UUID='):
        print('|'.join([f[0][5:], f[1], f[2], f[3]]))
PY
  [[ -n "$uuid" && -n "$mp" ]] || continue
  mkdir -p "$mp" 2>/dev/null || true
  # 已经挂上 → 什么都不做（绝不 umount 用户数据）
  if findmnt -rn --target "$mp" >/dev/null 2>&1; then continue; fi
  dev="$(blkid -U "$uuid" 2>/dev/null || true)"
  if [[ -z "$dev" || ! -b "$dev" ]]; then log "$mp 设备未接入（UUID=$uuid），跳过"; continue; fi

  # ① 先按 fstab 原样挂一次。★ 不能把 mount -a 的返回码当判据：
  #   fstab 里另一块盘失败也会让它非 0，但当前目标其实已经挂上了。
  mount -a >/dev/null 2>&1 || true
  if findmnt -rn --target "$mp" >/dev/null 2>&1; then
    log "$mp 已按 fstab 补挂成功（$fs）"; continue
  fi
  ok=0; newfs="$fs"; newopts="$opts"
  # ② ntfs3 → 逐级精简选项（去掉 uid/gid/umask/noatime 等可疑项）
  if [[ "$fs" == "ntfs3" ]]; then
    for o in \
      "defaults,nofail,noatime,uid=0,gid=0,umask=0000,x-systemd.device-timeout=${TIMEOUT}s" \
      "defaults,nofail,noatime,uid=0,gid=0" \
      "defaults,nofail,noatime" \
      "defaults,nofail"; do
      if mount -t ntfs3 -o "$o" "$dev" "$mp" >/dev/null 2>&1; then
        newopts="$o"; ok=1; log "$mp ntfs3 精简选项挂载成功：$o"; break
      fi
    done
    # ③ 仍失败 → 换用户态 ntfs-3g（兼容脏位/休眠/个别元数据更好）
    #    这就是手写 fstab 写 `ntfs` 能挂的原因：/sbin/mount.ntfs → ntfs-3g。
    if [[ "$ok" -eq 0 ]] && command -v ntfs-3g >/dev/null 2>&1; then
      o="defaults,nofail,noatime,uid=0,gid=0,umask=0000,big_writes,windows_names,x-systemd.device-timeout=${TIMEOUT}s"
      if mount -t ntfs-3g -o "$o" "$dev" "$mp" >/dev/null 2>&1; then
        newfs="ntfs-3g"; newopts="$o"; ok=1; log "$mp ntfs3 被拒，已用 ntfs-3g 挂上"
      fi
    fi
  fi
  if [[ "$ok" -ne 1 ]]; then
    log "★ $mp 仍未挂上：ntfs3 可能被脏位/休眠标记拒绝。dmesg | tail -30 看 'volume is dirty'；"
    log "   处理：Windows 里 powercfg /h off + 彻底关机，或手动改用 ntfs-3g。脚本不会 force / ntfsfix（避免损坏数据）"
    continue
  fi
  # ④ 把成功的驱动/选项回写 fstab，下次 reboot 直接生效（幂等）
  if [[ "$newfs" != "$fs" || "$newopts" != "$opts" ]]; then
    python3 - "$FSTAB" "$uuid" "$mp" "$newfs" "$newopts" <<'PY'
import sys
p,uuid,mp,fs,opts=sys.argv[1:6]
ls=open(p,encoding='utf-8',errors='replace').read().splitlines()
out=[]
for l in ls:
    f=l.split()
    if len(f)>=4 and f[0]=="UUID="+uuid and f[1]==mp:
        out.append(" ".join(["UUID="+uuid, mp, fs, opts, "0", "0"]))
    else:
        out.append(l)
open(p,'w',encoding='utf-8').write("\n".join(out)+"\n")
PY
    systemctl daemon-reload >/dev/null 2>&1 || true
    log "$mp fstab 已固化：$fs -> $newfs"
  fi
done
exit 0
HELPER
  chmod 755 "$MOUNT_HELPER"
  cat > "/etc/systemd/system/$MOUNT_HELPER_UNIT" <<EOF
[Unit]
Description=armbian-nas 外置盘开机补挂（nofail 跳过 / USB 晚到 / ntfs3 拒绝自愈）
After=local-fs.target
[Service]
Type=oneshot
Environment=DEV_TIMEOUT=${DEV_TIMEOUT}
Environment=MOUNT_HELPER_LOG=${MOUNT_HELPER_LOG}
ExecStart=$MOUNT_HELPER
EOF
  cat > "/etc/systemd/system/$MOUNT_HELPER_TIMER" <<'EOF'
[Unit]
Description=armbian-nas 外置盘补挂定时检查
[Timer]
OnBootSec=25s
OnUnitActiveSec=90s
AccuracySec=10s
Unit=armbian-nas-mounts.service
Persistent=false
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now "$MOUNT_HELPER_TIMER" >/dev/null 2>&1 || \
    systemctl enable "$MOUNT_HELPER_TIMER" >/dev/null 2>&1 || true
  # 当下就跑一次，不等 25 秒
  systemctl start "$MOUNT_HELPER_UNIT" >/dev/null 2>&1 || "$MOUNT_HELPER" || true
  c_ok "开机补挂自愈已启用：$MOUNT_HELPER_TIMER（日志 $MOUNT_HELPER_LOG）"
}

# 逐盘挂载 + 降级：成功时把最终 fs/opts 写进 TRY_FS / TRY_OPTS。
# ★ 与主盘共用同一套降级链，第二块盘不再只 mount -a 一次就 WARN 了事。
mount_try_chain(){
  local uuid="$1" mp="$2" fs="$3" opts="$4"
  local dev o
  TRY_FS="$fs"; TRY_OPTS="$opts"
  dev="$(blkid -U "$uuid" 2>/dev/null || true)"
  [[ -n "$dev" && -b "$dev" ]] || return 1
  findmnt -rn --target "$mp" >/dev/null 2>&1 && return 0   # 已挂，保持现状
  mount -a >/dev/null 2>&1 || true
  findmnt -rn --target "$mp" >/dev/null 2>&1 && return 0
  if [[ "$fs" == "ntfs3" ]]; then
    while IFS= read -r o; do
      [[ -n "$o" ]] || continue
      o="${o},x-systemd.device-timeout=${DEV_TIMEOUT}s"
      if mount -t ntfs3 -o "$o" "$dev" "$mp" >/dev/null 2>&1; then
        TRY_OPTS="$o"; return 0
      fi
    done < <(ntfs3_fallback_opts)
    apt_install_quiet ntfs-3g >/dev/null 2>&1 || true
    o="defaults,nofail,noatime,uid=0,gid=0,umask=0000,big_writes,windows_names,x-systemd.device-timeout=${DEV_TIMEOUT}s"
    if mount -t ntfs-3g -o "$o" "$dev" "$mp" >/dev/null 2>&1; then
      TRY_FS="ntfs-3g"; TRY_OPTS="$o"; return 0
    fi
  fi
  return 1
}
fstab_rebuild(){
  local uuid_main="$1" fs_main="$2" opts_main="$3" \
        uuid_sec="$4" fs_sec="$5" opts_sec="$6" has_sec="$7" bak
  bak="/etc/fstab.bak.armbian-nas"
  # 外层已判断 ! -f，cp -n 完全多余；新 coreutils 还会打印
  #   "cp: warning: behavior of -n is non-portable ... use --update=none"
  # 直接 cp 最兼容（--update=none 在老 coreutils 上不存在）。
  [[ -f "$bak" ]] || cp /etc/fstab "$bak"
  sed -i '/^# >>> armbian-nas-deploy >>>/,/^# <<< armbian-nas-deploy <<</d' /etc/fstab
  {
    echo "# >>> armbian-nas-deploy >>>"
    echo "UUID=$uuid_main $MOUNT_MAIN $fs_main $opts_main 0 0"
    if [[ "$has_sec" -eq 1 ]]; then
      echo "UUID=$uuid_sec $MOUNT_SECOND $fs_sec $opts_sec 0 0"
    fi
    echo "# <<< armbian-nas-deploy <<<"
  } >> /etc/fstab
  systemctl daemon-reload 2>/dev/null || true
}
fs_options(){
  # $1 = fstype ; 输出 "fstype|options"
  local t="$1"
  case "$t" in
    ntfs|ntfs3)
      if modprobe ntfs3 >/dev/null 2>&1 && grep -qw ntfs3 /proc/filesystems; then
        # ★ windows_names / big_writes 是【ntfs-3g 用户态驱动】的选项，
        #   内核 ntfs3 驱动不认识：传进去会 "mount: ... Invalid argument" /
        #   "wrong fs type, bad option"，整块外置盘挂载失败。已从 ntfs3 分支删掉。
        #   ntfs3 原生支持 uid / gid / umask / fmask / dmask / iocharset，保留这些。
        printf "ntfs3|defaults,nofail,noatime,uid=0,gid=0,umask=0000,x-systemd.device-timeout=${DEV_TIMEOUT}s"
      else
        apt_update >&2; apt_install ntfs-3g >&2
        printf "ntfs-3g|defaults,nofail,noatime,uid=0,gid=0,umask=0000,big_writes,windows_names,x-systemd.device-timeout=${DEV_TIMEOUT}s"
      fi
      ;;
    ext4|ext3|ext2) printf "%s|defaults,noatime,nofail,x-systemd.device-timeout=${DEV_TIMEOUT}s" "$t" ;;
    exfat)          printf "exfat|defaults,nofail,noatime,uid=0,gid=0,umask=0000,x-systemd.device-timeout=${DEV_TIMEOUT}s" ;;
    btrfs|xfs)      printf "%s|defaults,noatime,nofail,x-systemd.device-timeout=${DEV_TIMEOUT}s" "$t" ;;
    *)              printf "%s|defaults,nofail,noatime,x-systemd.device-timeout=${DEV_TIMEOUT}s" "$t" ;;
  esac
}

# ntfs3 挂载失败时的选项降级链：依次去掉可疑选项，最后在 ensure_mounts 里
# 回退到 ntfs-3g。只改 fstab 的挂载选项，绝不格式化、绝不碰盘上已有数据。
ntfs3_fallback_opts(){
  printf '%s\n' \
    'defaults,nofail,noatime,uid=0,gid=0,umask=0000' \
    'defaults,nofail,noatime,uid=0,gid=0' \
    'defaults,nofail,noatime' \
    'defaults,nofail'
}
ensure_mounts(){
  c_step "前置检查：外置硬盘挂载（不格式化、不改动已有文件）"
  mkdir -p "$MOUNT_MAIN" "$MOUNT_SECOND"

  # 仅自检模式：不碰 fstab、不装依赖、不执行 mount -a
  if [[ "$MODE" == "check" ]]; then
    findmnt -rn --target "$MOUNT_MAIN" >/dev/null 2>&1 \
      || die "$MOUNT_MAIN 未挂载，无法自检。先正常跑一次脚本，或检查硬盘与 --main-dev。"
    local ctf="$MOUNT_MAIN/.armbian-nas-check"
    touch "$ctf" 2>/dev/null || die "$MOUNT_MAIN 不可写"
    rm -f "$ctf"
    c_ok "只读校验：$MOUNT_MAIN 已挂载且可写，未改动 fstab"
    init_state_area
    return 0
  fi

  # 主盘：优先 /dev/sda1；找不到时尝试发现第一个 NTFS/exFAT 分区
  if [[ ! -b "$MAIN_DEV" ]]; then
    local guess
    guess="$(lsblk -rno NAME,FSTYPE 2>/dev/null | awk '$2 ~ /^(ntfs|exfat|ext4)$/ {print "/dev/"$1; exit}' || true)"
    if [[ -n "$guess" && -b "$guess" ]]; then
      c_warn "未找到 $MAIN_DEV，自动改用 $guess；可用 --main-dev=... 指定"
      MAIN_DEV="$guess"
    fi
  fi
  [[ -b "$MAIN_DEV" ]] || die "找不到主硬盘分区 $MAIN_DEV。请插好移动硬盘，或用 --main-dev=/dev/xxx1 指定。"

  local uuid_main type_main fs_main opts_main line
  uuid_main="$(blkid -o value -s UUID "$MAIN_DEV")"
  type_main="$(blkid -o value -s TYPE "$MAIN_DEV")"
  [[ -n "$uuid_main" && -n "$type_main" ]] || die "无法读取 $MAIN_DEV 的 UUID/文件系统类型"
  line="$(fs_options "$type_main")"; IFS='|' read -r fs_main opts_main <<< "$line"
  c_info "主盘：$MAIN_DEV UUID=$uuid_main 类型=$type_main → $MOUNT_MAIN ($fs_main)"

  # 第二块盘（可选）
  local uuid_sec="" type_sec="" fs_sec="" opts_sec="" has_sec=0
  if [[ -b "$SECOND_DEV" ]]; then
    uuid_sec="$(blkid -o value -s UUID "$SECOND_DEV" || true)"
    type_sec="$(blkid -o value -s TYPE "$SECOND_DEV" || true)"
    if [[ -n "$uuid_sec" && -n "$type_sec" ]]; then
      line="$(fs_options "$type_sec")"; IFS='|' read -r fs_sec opts_sec <<< "$line"
      # ★ 可选：直接指定第二块盘用 ntfs-3g（等价于用户手写 `-t ntfs`），
      #   跳过 ntfs3 严格校验。--second-fstype=ntfs-3g|ntfs|ntfs3
      if [[ -n "$SECOND_FSTYPE" && "$type_sec" == "ntfs" ]]; then
        fs_sec="$SECOND_FSTYPE"
        opts_sec="defaults,nofail,noatime,uid=0,gid=0,umask=0000,big_writes,windows_names,x-systemd.device-timeout=${DEV_TIMEOUT}s"
        c_info "第二块盘按参数强制使用 $fs_sec（跳过 ntfs3 严格校验）"
      fi
      has_sec=1
      c_info "第二块盘：$SECOND_DEV UUID=$uuid_sec 类型=$type_sec → $MOUNT_SECOND ($fs_sec)"
    else
      c_warn "$SECOND_DEV 存在但读不到 UUID/类型，跳过第二块盘挂载"
    fi
  else
    c_warn "未发现 $SECOND_DEV（可选第二块盘），共享目录只扫描 $MOUNT_MAIN；可用 --second-dev=... 指定"
  fi

  fstab_rebuild "$uuid_main" "$fs_main" "$opts_main" "$uuid_sec" "$fs_sec" "$opts_sec" "$has_sec"

  # ★ 两块盘各自走同一套「选项降级 → 驱动降级」链，不再只盯着主盘。
  #   主盘/第二块盘任一被 ntfs3 拒绝，都会自动切 ntfs-3g 并把最终组合回写 fstab。
  if ! mount_try_chain "$uuid_main" "$MOUNT_MAIN" "$fs_main" "$opts_main"; then
    die "挂载失败：请检查 ① NTFS 是否被 Windows 快速启动/休眠锁成只读（Windows 执行 powercfg /h off 并正常关机）② dmesg | tail 里的 ntfs3/USB 报错 ③ 用 --main-dev=/dev/xxx1 指定正确分区。已保留 /etc/fstab.bak.armbian-nas 备份"
  fi
  fs_main="$TRY_FS"; opts_main="$TRY_OPTS"
  findmnt -rn --target "$MOUNT_MAIN" >/dev/null 2>&1 && c_ok "$MOUNT_MAIN 已挂载（$fs_main）"
  if [[ "$has_sec" -eq 1 ]]; then
    if mount_try_chain "$uuid_sec" "$MOUNT_SECOND" "$fs_sec" "$opts_sec"; then
      fs_sec="$TRY_FS"; opts_sec="$TRY_OPTS"
      c_ok "$MOUNT_SECOND 已挂载（$fs_sec）；若发生驱动降级，下面会固化进 fstab"
    else
      c_warn "$MOUNT_SECOND 本次未挂上（不阻塞）；开机补挂单元会每 90s 重试一次并自动降级驱动"
      c_warn "  立即诊断：sudo dmesg | tail -30  |  sudo journalctl -b | grep -i sdb1"
    fi
  fi
  # 用最终成功组合重建 fstab：reboot 后 systemd 直接读到的就是对的驱动
  fstab_rebuild "$uuid_main" "$fs_main" "$opts_main" "$uuid_sec" "$fs_sec" "$opts_sec" "$has_sec"
  install_mount_helper

  findmnt -rn --target "$MOUNT_MAIN" >/dev/null 2>&1 || die "$MOUNT_MAIN 未挂载成功"
  local tf="$MOUNT_MAIN/.armbian-nas-write-test"
  touch "$tf" 2>/dev/null || die "$MOUNT_MAIN 不可写。若 NTFS 来自 Windows，请先在 Windows 执行 powercfg /h off 并正常关机，避免休眠/快速启动导致只读。"
  rm -f "$tf"
  c_ok "挂载可读写，已有电影等数据保持原样"
  init_state_area
}

# ------------------------------ 各步骤实现 -----------------------------------
step_layout(){
  mkdir -p \
    "$WEB_ROOT" "$BASE/logs/nginx" "$BASE/logs/samba" "$BASE/db" \
    "$BASE/downloads/aria2" "$BASE/downloads/incomplete" "$BASE/downloads/complete" \
    "$BASE/downloads/watch" "$BASE/qb" "$BASE/transmission" "$BASE/verysync" \
    "$BASE/minidlna/db" "$BASE/aria2" "$WEB_ROOT/ariang" "$STATE_DIR"
  touch "$BASE/aria2/aria2.session"
  chmod 700 "$STATE_DIR"
  c_ok "目录结构：$BASE/{web,logs,db,downloads,qb,transmission,verysync,minidlna,aria2,.deploy}"
  c_info "Docker 自身数据仍在 /var/lib/docker（NTFS 不能跑 overlay2），仅容器配置与下载落在 $BASE"
}

step_apt_base(){
  apt_update
  apt_install ca-certificates curl wget unzip zip gnupg lsb-release \
    util-linux hdparm ntfs-3g whiptail python3 openssl \
    iproute2 procps tmux
  command -v curl >/dev/null || die "curl 安装失败"
  c_ok "基础依赖就绪"
}

# ---------------------------------------------------------------------------
# PHP 8.2 专用：仓库准备、扩展包安装、pecl 兜底
# ---------------------------------------------------------------------------
ensure_php82_repo(){
  local cand codename sury_list=/etc/apt/sources.list.d/sury-php.list
  cand="$(apt-cache policy "$PHP_BIN-fpm" 2>/dev/null | awk '/Candidate:/{print $2; exit}' || true)"
  if [[ -n "$cand" && "$cand" != "(none)" ]]; then
    c_info "系统源已提供 $PHP_BIN-fpm（候选 $cand），无需额外仓库"
    return 0
  fi
  # ★ 实机日志：php8.2-fpm 明明已装 8.2.35，脚本却报「当前源没有 PHP 8.2 包」。
  #   这不是源缺失，而是 apt 索引陈旧（刚换过源 / lists 被清过 / 刚 apt-get install
  #   但没 update）。先刷新一次索引重试，别急着加源、别重复下载 GPG key。
  if command -v "$PHP_BIN" >/dev/null 2>&1 \
     && "$PHP_BIN" -r 'exit((PHP_VERSION_ID>=80200 && PHP_VERSION_ID<80300)?0:1);' 2>/dev/null; then
    c_info "检测到 $PHP_BIN 已是 8.2（$("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null)），仅 apt 索引里暂无候选；先刷新索引重试"
    apt_update
    cand="$(apt-cache policy "$PHP_BIN-fpm" 2>/dev/null | awk '/Candidate:/{print $2; exit}' || true)"
    if [[ -n "$cand" && "$cand" != "(none)" ]]; then
      c_ok "刷新索引后候选恢复：$cand（源本来就在，无需重建）"
      return 0
    fi
  fi
  # Sury 源已经配置过就只刷新索引，不再下载 key / 覆盖 list（幂等、省流量）
  if [[ -f "$sury_list" ]]; then
    c_info "Sury 源已存在（$sury_list），刷新索引后重试，不重复下载 GPG key"
    apt_update
    cand="$(apt-cache policy "$PHP_BIN-fpm" 2>/dev/null | awk '/Candidate:/{print $2; exit}' || true)"
    [[ -n "$cand" && "$cand" != "(none)" ]] \
      && { c_ok "刷新索引后候选恢复：$cand"; return 0; }
  fi
  c_warn "apt 索引确实解析不到 PHP $PHP_VER 候选（非「源里没有 8.2」；多为索引未更新），补齐/重建 Sury PHP 仓库"
  apt_install_quiet ca-certificates curl gnupg lsb-release apt-transport-https \
    || c_warn "Sury 依赖安装有告警"
  codename="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")"
  if [[ -z "$codename" ]]; then codename="$(lsb_release -cs 2>/dev/null || true)"; fi
  [[ -n "$codename" ]] || die "无法识别系统代号，无法添加 Sury PHP 源；请手工安装 PHP 8.2 后重跑 --redo=03"
  mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
  if ! curl -fsSL --retry 2 --connect-timeout 15 https://packages.sury.org/php/apt.gpg \
        -o /usr/share/keyrings/sury-php.gpg; then
    die "Sury GPG key 下载失败。可改用国内镜像或手工配置 PHP 8.2 源，然后重跑 --redo=03"
  fi
  printf 'deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ %s main\n' \
    "$codename" > /etc/apt/sources.list.d/sury-php.list
  apt_update
  cand="$(apt-cache policy "$PHP_BIN-fpm" 2>/dev/null | awk '/Candidate:/{print $2; exit}' || true)"
  [[ -n "$cand" && "$cand" != "(none)" ]] \
    || die "已添加 Sury 源但仍看不到 $PHP_BIN-fpm（代号 $codename 可能不被支持）。请检查 /etc/apt/sources.list.d/sury-php.list 后重跑 --redo=03"
  c_ok "Sury PHP 源就绪（$codename），候选 $cand"
}

pecl_fallback(){ # pecl_fallback <扩展名> <pecl包名>
  local ext="$1" pkg="$2" ini
  c_info "尝试 pecl 补装 $ext ..."
  # 编译依赖本身也是一次 apt 安装，实时显示（以前被 >/dev/null 吞掉，最像死机）
  if ! apt_install php-pear "$PHP_BIN-dev" build-essential pkg-config \
        libzstd-dev libevent-dev; then
    c_warn "pecl 编译依赖安装失败，跳过 $ext"; return 1
  fi
  # pecl 编译 event/redis 等扩展在 1G 内存的 S905X 上可能要好几分钟，
  # 用 long_op 包一层：gcc 输出实时可见，且每隔 10 秒有心跳。
  if ! long_op "pecl 编译安装 PHP 扩展 $pkg（首次编译较慢）" \
        bash -c "printf '\n\n\n' | pecl install '$pkg'"; then
    c_warn "pecl install $pkg 失败，跳过 $ext"; return 1
  fi
  ini="$PHP_ETC/mods-available/$ext.ini"
  printf 'extension=%s.so\n' "$ext" > "$ini"
  mkdir -p "$PHP_ETC/fpm/conf.d" "$PHP_ETC/cli/conf.d"
  ln -sfn "$ini" "$PHP_ETC/fpm/conf.d/30-$ext.ini"
  ln -sfn "$ini" "$PHP_ETC/cli/conf.d/30-$ext.ini"
  c_ok "pecl 已补装并启用 $ext"
}

# ---------------------------------------------------------------------------
# nginx sites-enabled 清理（实机步骤 04 失败的根因）
# ---------------------------------------------------------------------------
# nginx.conf 里是 `include /etc/nginx/sites-enabled/*;` —— 【所有】文件都会被读，
# 不管后缀是 .conf 还是 .bak / .disabled / *~。上一版把官方 default 站点改名成
#   /etc/nginx/sites-enabled/default.bak.armbian-nas
# 却仍留在 sites-enabled 里，于是它自带的 `listen 80 default_server;` 和
# armbian-nas 的 `listen 80 default_server;` 冲突：
#   nginx: [emerg] a duplicate default server for 0.0.0.0:80 in ...
# 修法：把冲突文件【移出】sites-enabled，放到 /etc/nginx/sites-disabled.armbian-nas/
# （该目录不被任何 include 扫到），保留原件可随时回退。
# 幂等：--redo=04 / 直接重跑都会再清一次，用户机器上已存在的 .bak 残留也会被挪走。
# ---------------------------------------------------------------------------
nginx_disable_conflicting_defaults(){
  local se=/etc/nginx/sites-enabled
  local park=/etc/nginx/sites-disabled.armbian-nas
  local f base moved=0
  [[ -d "$se" ]] || return 0
  mkdir -p "$park"
  for f in "$se"/*; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    [[ "$base" == "armbian-nas" ]] && continue       # 我们自己的站点，保留
    # ① 明显的备份 / 禁用残留一律移走：含上一版自己造的 default.bak.armbian-nas
    case "$base" in
      default*|*.bak*|*.disabled*|*.old|*.dpkg-*|*~)
        mv -f "$f" "$park/$base" 2>/dev/null || { c_warn "无法移出 $f"; continue; }
        c_warn "已把 $base 移出 sites-enabled → $park（避免与 armbian-nas 抢 80/default_server）"
        moved=$((moved+1)); continue ;;
    esac
    # ② 其它文件：只有确实在 80 端口声明 default_server 才移走，
    #    避免误伤用户自己的 443 / 非默认站点。
    #    命中：listen 80 default_server; 与 listen [::]:80 default_server;
    #    不命中：listen 8080 ... / listen 443 ssl default_server;
    if grep -q 'default_server' "$f" 2>/dev/null \
       && grep -qE 'listen[[:space:]]+(\[::\]:)?80([[:space:]]|;)' "$f" 2>/dev/null; then
      mv -f "$f" "$park/$base" 2>/dev/null || { c_warn "无法移出 $f"; continue; }
      c_warn "已把 $base 移出 sites-enabled → $park（它也声明了 80 default_server）"
      moved=$((moved+1))
    fi
  done
  (( moved > 0 )) && c_ok "共清理 $moved 个冲突站点文件；nginx -t 不会再报 duplicate default server"
  return 0
}

# 供 --check 使用：sites-enabled 里除 armbian-nas 外不应再有任何 default_server
nginx_sites_enabled_clean(){
  local se=/etc/nginx/sites-enabled f b
  [[ -d "$se" ]] || return 1
  for f in "$se"/*; do
    [[ -e "$f" ]] || continue
    b="$(basename "$f")"
    [[ "$b" == "armbian-nas" ]] && continue
    case "$b" in default*|*.bak*|*.disabled*|*.old|*.dpkg-*|*~) return 1 ;; esac
    # 只把「80 端口 + default_server」视为冲突；443 ssl default_server 不冲突，
    # 不能像 ② 之前那样 grep 到 default_server 就判 FAIL（会误伤用户自己的站点）。
    if grep -q 'default_server' "$f" 2>/dev/null \
       && grep -qE 'listen[[:space:]]+(\[::\]:)?80([[:space:]]|;)' "$f" 2>/dev/null; then
      return 1
    fi
  done
  return 0
}

step_nginx_php(){
  ensure_php82_repo

  # 核心包：显式带 8.2 前缀，绝不使用 php-fpm / php-cli 这类跟随系统默认版本的 meta 包
  local -a core=(
    "$PHP_BIN-cli" "$PHP_BIN-fpm" "$PHP_BIN-common" "$PHP_BIN-opcache"
    "$PHP_BIN-bcmath" "$PHP_BIN-curl" "$PHP_BIN-gd" "$PHP_BIN-gmp"
    "$PHP_BIN-imap" "$PHP_BIN-intl" "$PHP_BIN-mbstring" "$PHP_BIN-mysql"
    "$PHP_BIN-pgsql" "$PHP_BIN-sqlite3" "$PHP_BIN-soap" "$PHP_BIN-xml"
    "$PHP_BIN-zip"
  )
  # 第三方扩展：Sury 源一般都有；源里没有时逐个降级为 pecl
  local -a extra=( "$PHP_BIN-redis" "$PHP_BIN-igbinary" "$PHP_BIN-zstd" "$PHP_BIN-event" )
  local p
  if ! apt_install nginx sqlite3 "${core[@]}"; then
    c_warn "核心包未能一次装齐，改为逐包安装（便于定位缺哪个）"
    local _i=0 _tot=$(( 2 + ${#core[@]} ))
    for p in nginx sqlite3 "${core[@]}"; do
      _i=$((_i+1))
      c_info "  ▸ 逐包重试 [$_i/$_tot]：$p"
      apt_install "$p" || c_warn "包未装上：$p"
    done
  fi
  local _j=0
  for p in "${extra[@]}"; do
    _j=$((_j+1))
    c_info "  ▸ 第三方扩展 [$_j/${#extra[@]}]：$p"
    apt_install "$p" || c_warn "源里没有 $p，稍后用 pecl 兜底"
  done

  command -v "$PHP_BIN" >/dev/null || die "$PHP_BIN 未安装成功"
  command -v sqlite3 >/dev/null || die "sqlite3 命令未安装成功"
  if ! "$PHP_BIN" -v 2>/dev/null | awk 'NR==1' | grep -qF "PHP $PHP_VER"; then
    die "PHP 版本不是 $PHP_VER：$("$PHP_BIN" -v 2>/dev/null | awk 'NR==1')。请检查是否混装了其它版本"
  fi

  # 对仍缺失的第三方扩展做 pecl 兜底
  if [[ "$PECL_FALLBACK" -eq 1 ]]; then
    for p in igbinary redis zstd event; do
      if ! "$PHP_BIN" -m 2>/dev/null | grep -qi "^$p$"; then
        pecl_fallback "$p" "$p" || true
      fi
    done
  fi

  systemctl enable --now nginx
  local svc; svc="$(php_service)"
  if [[ -n "$svc" ]]; then
    systemctl enable --now "$svc"
    systemctl restart "$svc"
  else
    die "未找到 $PHP_FPM_SVC，PHP 8.2 FPM 未装上"
  fi
  # 若机器上还有别的 php*-fpm，只提示不擅自停用（可能影响用户其它站点）
  local others
  others="$(systemctl list-unit-files --type=service --no-legend 2>/dev/null \
    | awk '/php[0-9.]+-fpm\.service/{print $1}' | grep -vF "$PHP_FPM_SVC" | paste -sd, - || true)"
  if [[ -n "$others" ]]; then c_info "检测到其它版本 FPM（$others），本脚本仅使用 $PHP_FPM_SVC"; fi

  # 写期望清单并逐项核对
  printf '%s\n' "$PHP_EXT_WANT" > "$PHP_EXT_FILE"
  if php_ext_audit; then
    c_ok "PHP $PHP_VER 扩展清单全部齐全（$(wc -l < "$PHP_EXT_FILE") 行，去重后逐项核对）"
  else
    c_warn "PHP $PHP_VER 扩展仍有缺失：$(paste -sd, "$PHP_EXT_MISSING" 2>/dev/null || true)"
    c_warn "清单：$PHP_EXT_FILE ；缺失明细：$PHP_EXT_MISSING（最终自检会判为 FAIL）"
  fi
  c_ok "nginx $(nginx -v 2>&1 | awk -F/ '{print $2}') / $("$PHP_BIN" -v | awk 'NR==1') / $PHP_FPM_SVC"
}

# 生成 probe.php：期望清单在生成时内嵌，探针本身不读任何文件。
# 这样 open_basedir 可以严格收口，.deploy（含 RPC 密钥）对 PHP 完全不可达。
write_probe_php(){
  php_ext_want_ensure
  local wanted_php
  # ★ probe.php 由 FPM 执行，期望清单必须与 php_ext_audit_fpm 一致，
  #   剔除 pcntl 等 CLI 专有扩展，否则网页侧永远输出 PHP_EXT_FAIL（假故障）。
  wanted_php="$(php_ext_want_fpm | sed "s/.*/'&'/" | paste -sd, -)"
  cat > "$WEB_ROOT/probe.php" <<'PHPFILE'
<?php
// armbian-nas PHP 8.2 环境探针（分区表格版）
// ★ 页面最后保留「机器可读输出」：PHP_SQLITE_OK / PHP_EXT_ALL_OK /
//   --- loaded extensions (PHP + Zend) --- + 每行一个扩展名。
//   脚本的 php_ext_audit_fpm() 与 --check 都靠 curl 抓这些标记，不能删。
$want = array_values(array_unique(array_map('strtolower', [ __WANTED_PHP__ ])));
$raw  = array_merge(get_loaded_extensions(false), get_loaded_extensions(true));
$loaded = array_map('strtolower', $raw);
$loaded = array_map(function($e){ return $e === 'zend opcache' ? 'opcache' : $e; }, $loaded);
$missing = array_values(array_diff($want, $loaded));
$ok = !$missing;

// ---- 按功能分区（仅用于展示，缺失判定仍按全量 $want vs $loaded）----
$groups = [
  '核心与基础'   => ['core','date','libxml','pcre','standard','spl','session','json','random','reflection','tokenizer','ctype','filter','hash','iconv','phar','fileinfo','zlib'],
  '数据库'       => ['sqlite3','pdo','pdo_sqlite','pdo_mysql','mysqli','mysqlnd','pdo_pgsql','pgsql'],
  '网络 / 协议 / XML' => ['curl','dom','ftp','openssl','soap','xml','xmlreader','xmlwriter','simplexml'],
  '图像与多媒体' => ['gd','exif'],
  '字符 / 数学 / 国际化' => ['mbstring','intl','gettext','bcmath','gmp'],
  '压缩 / 序列化 / 缓存' => ['zip','zstd','igbinary','redis','opcache','sodium'],
  '系统 / 进程 / IPC' => ['pcntl','posix','shmop','sysvsem','sockets','event','imap'],
];
$grouped = [];
foreach ($groups as $g => $xs) foreach ($xs as $x) $grouped[$x] = $g;
$other = array_values(array_diff($want, array_keys($grouped)));

// ---- SQLite3 ----
$dbPath = '__BASE__/db/nas.sqlite3';
$sqliteVer = '-'; $dbOk = false; $dbErr = ''; $meta = [];
try {
  $pdo = new PDO('sqlite:' . $dbPath);
  $sqliteVer = $pdo->query('select sqlite_version()')->fetchColumn();
  foreach ($pdo->query('select k,v from meta') as $r) $meta[] = [$r['k'], $r['v']];
  $dbOk = true;
} catch (Throwable $e) { $dbErr = $e->getMessage(); }

function h($v){ return htmlspecialchars((string)$v, ENT_QUOTES, 'UTF-8'); }
function yn($b){ return $b ? '<span class="yes">✔ 正常</span>' : '<span class="no">✘ 异常</span>'; }
header('Content-Type: text/html; charset=utf-8');
?><!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>PHP 8.2 环境探针 · armbian-nas</title>
<style>
:root{--fs:16px;--bg:#f4f7fb;--card:#fff;--txt:#1c2536;--sub:#64748b;--line:#dfe6f0;--acc:#2563eb;--ok:#0f9d58;--bad:#dc2626;--soft:#f1f5fa}
*{box-sizing:border-box}
body{margin:0;padding:24px 16px 48px;background:var(--bg);color:var(--txt);
     font:var(--fs)/1.7 system-ui,-apple-system,"Segoe UI","Microsoft YaHei",sans-serif}
.wrap{max-width:1080px;margin:0 auto}
header{display:flex;flex-wrap:wrap;align-items:baseline;gap:12px;border-bottom:1px solid var(--line);padding-bottom:14px;margin-bottom:18px}
h1{font-size:calc(var(--fs) + 10px);margin:0}h1 span{color:var(--acc)}
.sub{color:var(--sub);font-size:calc(var(--fs) - 2px)}
.tools{margin-left:auto;display:flex;gap:6px;align-items:center}
.tools button{font-size:calc(var(--fs) - 3px);padding:3px 10px;border:1px solid var(--line);background:var(--card);border-radius:7px;cursor:pointer;color:var(--txt)}
.tools button:hover{border-color:var(--acc);color:var(--acc)}
section{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px 18px;margin:0 0 16px;box-shadow:0 2px 8px #16233a0a}
h2{font-size:calc(var(--fs) + 2px);margin:0 0 12px;display:flex;align-items:center;gap:8px}
h2 .n{font-size:calc(var(--fs) - 4px);color:var(--sub);font-weight:400}
table{width:100%;border-collapse:collapse;font-size:var(--fs)}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top}
tr:last-child td,tr:last-child th{border-bottom:0}
th{font-size:calc(var(--fs) - 2px);color:var(--sub);font-weight:700;letter-spacing:.3px;background:var(--soft)}
td.k{width:34%;font-weight:600;word-break:break-word}
td.v{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:calc(var(--fs) - 1px);word-break:break-all}
.yes{color:var(--ok);font-weight:700}.no{color:var(--bad);font-weight:700}
.badge{display:inline-block;font-size:calc(var(--fs) - 3px);padding:2px 9px;border-radius:999px;border:1px solid var(--line);background:var(--soft)}
.badge.g{color:var(--ok);border-color:#bfe8d5;background:#e7f6ef}
.badge.r{color:var(--bad);border-color:#f3c9c9;background:#fdf0f0}
.ext{display:flex;flex-wrap:wrap;gap:5px;margin-top:6px}
.ext i{font-style:normal;font-size:calc(var(--fs) - 3px);padding:2px 8px;border-radius:6px;border:1px solid #bfe8d5;background:#e7f6ef;color:#0b6e40}
.ext i.miss{border-color:#f3c9c9;background:#fdf0f0;color:var(--bad);font-weight:700}
.note{color:var(--sub);font-size:calc(var(--fs) - 2px);margin-top:8px}
details{margin-top:10px}summary{cursor:pointer;color:var(--sub);font-size:calc(var(--fs) - 2px)}
pre{background:var(--soft);border:1px solid var(--line);border-radius:8px;padding:12px;overflow:auto;font-size:calc(var(--fs) - 3px)}
a{color:var(--acc)}
footer{text-align:center;color:var(--sub);font-size:calc(var(--fs) - 3px);margin-top:20px}
</style></head><body><div class="wrap">
<header>
  <h1>🐘 PHP <span>8.2</span> 环境探针</h1>
  <div class="sub">armbian-nas · 分区表格版 · 生成时间 <?php echo h(date('Y-m-d H:i:s')); ?></div>
  <div class="tools">字号
    <button type="button" onclick="fs(-1)">A−</button>
    <button type="button" onclick="fs(0)">A</button>
    <button type="button" onclick="fs(1)">A＋</button>
  </div>
</header>

<section>
  <h2>① 概览 <span class="n">当前网页运行在 FPM 真实环境</span></h2>
  <table><thead><tr><th>项目</th><th>值</th><th>状态</th></tr></thead><tbody>
  <tr><td class="k">PHP 版本</td><td class="v"><?php echo h(PHP_VERSION); ?></td><td><?php echo (strpos(PHP_VERSION,'8.2')===0?yn(true):yn(false)); ?></td></tr>
  <tr><td class="k">运行方式 SAPI</td><td class="v"><?php echo h(php_sapi_name()); ?></td><td><?php echo yn(true); ?></td></tr>
  <tr><td class="k">Web 服务器</td><td class="v"><?php echo h(isset($_SERVER['SERVER_SOFTWARE']) ? $_SERVER['SERVER_SOFTWARE'] : '-'); ?></td><td><?php echo yn(true); ?></td></tr>
  <tr><td class="k">操作系统</td><td class="v"><?php echo h(php_uname()); ?></td><td><?php echo yn(true); ?></td></tr>
  <tr><td class="k">扩展清单核对（FPM 侧）</td><td class="v">要求 <?php echo count($want); ?> 项 ｜ 缺失 <?php echo count($missing); ?> 项</td><td><?php echo yn($ok); ?></td></tr>
  <tr><td class="k">SQLite3 数据库</td><td class="v"><?php echo h($dbPath); ?></td><td><?php echo yn($dbOk); ?></td></tr>
  </tbody></table>
  <div class="note">CLI 专有扩展（不在 FPM 侧核对）：<b><?php echo h('__CLI_ONLY__'); ?></b> —— 上游 php8.2-fpm 二进制不编译，属正常，不是缺失。</div>
</section>

<section>
  <h2>② PHP 关键配置 <span class="n">php.ini / FPM pool</span></h2>
  <table><thead><tr><th>配置项</th><th>当前值</th></tr></thead><tbody>
<?php
$inis = ['disable_functions','open_basedir','memory_limit','max_execution_time','max_input_time',
         'upload_max_filesize','post_max_size','date.timezone','error_log','display_errors','log_errors',
         'opcache.enable','opcache.enable_cli','opcache.memory_consumption','session.save_path',
         'allow_url_fopen','expose_php','max_file_uploads'];
foreach ($inis as $k) {
  $v = ini_get($k); if ($v === false || $v === '') $v = '(none)';
  echo '<tr><td class="k">' . h($k) . '</td><td class="v">' . h($v) . '</td></tr>';
}
?>
  </tbody></table>
</section>

<section>
  <h2>③ SQLite3 / 数据库 <span class="n">网站数据落在外置盘</span></h2>
  <table><thead><tr><th>项目</th><th>值</th></tr></thead><tbody>
  <tr><td class="k">SQLite 库版本</td><td class="v"><?php echo h($sqliteVer); ?></td></tr>
  <tr><td class="k">PDO 可用驱动</td><td class="v"><?php echo h(implode(', ', PDO::getAvailableDrivers())); ?></td></tr>
  <tr><td class="k">数据库文件</td><td class="v"><?php echo h($dbPath); ?></td></tr>
  <tr><td class="k">连接结果</td><td class="v"><?php echo $dbOk ? 'PHP_SQLITE_OK' : h('SQLITE_FAIL: ' . $dbErr); ?></td></tr>
<?php foreach ($meta as $m) echo '<tr><td class="k">meta · ' . h($m[0]) . '</td><td class="v">' . h($m[1]) . '</td></tr>'; ?>
  </tbody></table>
</section>

<section>
  <h2>④ 扩展核对（按功能分区） <span class="n">绿色=已装 ｜ 红色=缺失</span></h2>
  <table><thead><tr><th>分区</th><th>要求 / 已装</th><th>明细</th></tr></thead><tbody>
<?php
$rows = [];
foreach ($want as $x) { $g = isset($grouped[$x]) ? $grouped[$x] : '其它 / 未归类'; $rows[$g][] = $x; }
foreach ($rows as $g => $xs) {
  $miss = array_values(array_intersect($xs, $missing));
  echo '<tr><td class="k">' . h($g) . '</td><td class="v">' . count($xs) . ' / ' . (count($xs)-count($miss)) . '</td><td>';
  echo '<div class="ext">';
  foreach ($xs as $x) echo '<i class="' . (in_array($x,$miss,true)?'miss':'') . '">' . h($x) . '</i>';
  echo '</div>';
  if ($miss) echo '<div class="note no">缺失：' . h(implode(', ', $miss)) . '</div>';
  echo '</td></tr>';
}
?>
  </tbody></table>
  <div class="note">总判定：<span class="badge <?php echo $ok?'g':'r'; ?>"><?php echo $ok?'PHP_EXT_ALL_OK':'PHP_EXT_FAIL'; ?></span>
  <?php echo $ok ? '　所有要求扩展在 FPM 侧均已加载。' : '　缺失：' . h(implode(', ', $missing)); ?></div>
</section>

<section>
  <h2>⑤ 已加载扩展全表 <span class="n">PHP + Zend，共 <?php echo count($raw); ?> 项</span></h2>
  <table><thead><tr><th>#</th><th>扩展名</th><th>#</th><th>扩展名</th></tr></thead><tbody>
<?php
sort($raw, SORT_NATURAL | SORT_FLAG_CASE);
$half = (int)ceil(count($raw)/2);
for ($i=0; $i<$half; $i++) {
  $j = $i + $half;
  echo '<tr><td class="v">' . ($i+1) . '</td><td class="v">' . h($raw[$i]) . '</td>';
  echo '<td class="v">' . ($j+1) . '</td><td class="v">' . h(isset($raw[$j]) ? $raw[$j] : '') . '</td></tr>';
}
?>
  </tbody></table>
</section>

<section>
  <h2>⑥ 机器可读输出 <span class="n">部署脚本自检靠这段，别删</span></h2>
  <details><summary>展开查看（curl 也能直接抓到纯文本标记）</summary><pre>
<?php
echo "PHP: " . PHP_VERSION . "\n";
echo "SAPI: " . php_sapi_name() . "\n";
echo "CLI_ONLY_SKIP: __CLI_ONLY__ (CLI SAPI 专有扩展，FPM 二进制不编译，不计入缺失)\n";
echo "DISABLE_FUNCTIONS: " . (ini_get('disable_functions') ?: '(none)') . "\n";
echo "OPEN_BASEDIR: " . (ini_get('open_basedir') ?: '(none)') . "\n";
echo "PDO drivers: " . implode(',', PDO::getAvailableDrivers()) . "\n";
if ($dbOk) {
  echo "SQLite: " . $sqliteVer . "\n";
  foreach ($meta as $m) echo "meta: {$m[0]}={$m[1]}\n";
  echo "PHP_SQLITE_OK\n";
} else { echo "SQLITE_FAIL: " . $dbErr . "\n"; }
echo "EXT_WANTED: " . count($want) . "\n";
echo "EXT_MISSING: " . ($missing ? implode(',', $missing) : 'none') . "\n";
echo $ok ? "PHP_EXT_ALL_OK\n" : "PHP_EXT_FAIL\n";
echo "--- loaded extensions (PHP + Zend) ---\n";
// ★ 最后只输出扩展名，后面不再输出任何 HTML：保证 php_ext_audit_fpm()
//   用 awk 从 marker 之后取到的全是干净扩展名。HTML 未闭合标签由浏览器自动补全。
foreach (array_merge(get_loaded_extensions(false), get_loaded_extensions(true)) as $e) echo $e . "\n";

PHPFILE
  sed -i "s|__BASE__|$BASE|g; s|__WANTED_PHP__|$wanted_php|g; s|__CLI_ONLY__|$PHP_CLI_ONLY_EXTS|g" "$WEB_ROOT/probe.php"
  chmod 644 "$WEB_ROOT/probe.php"
}

# ---------------------------------------------------------------------------
# nginx 日志目录 → 外置盘（真机修复）
#   旧写法 `ln -sfn "$BASE/logs/nginx" /var/log/nginx` 有个隐蔽 bug：
#   当 /var/log/nginx 是【真实目录】而不是软链时，GNU ln 会把链接创建到
#   目录【里面】（/var/log/nginx/nginx），而不是替换它。若此时 mv 备份又因
#   目标已存在而失败（nginx 正在写日志 / 之前备份过），软链永远建不上，
#   `--check` 的 `-L /var/log/nginx` 就恒为假。
#   修法：用 `ln -sfnT`（-T = 不把 LINK 当目录），并先清掉真实目录。
# ---------------------------------------------------------------------------
relocate_nginx_log(){
  # 路径做成可覆盖变量：生产用默认 /var/log/nginx；单元自测可注入临时目录，
  # 避免在测试机/沙盒里真的去动系统日志目录。
  local target="$BASE/logs/nginx" \
        link="${NGINX_LOG_LINK:-/var/log/nginx}" \
        bak="${NGINX_LOG_BAK:-/var/log/nginx.bak.armbian-nas}"
  mkdir -p "$target"
  if [[ -L "$link" && "$(readlink -f "$link" 2>/dev/null || true)" == "$target" ]]; then
    c_ok "nginx 日志已在外置盘：$link → $target（幂等跳过）"
    return 0
  fi
  if [[ -d "$link" && ! -L "$link" ]]; then
    # 只留一份备份，避免 mv 把新目录塞进旧备份里
    if [[ -e "$bak" ]]; then rm -rf "$bak"; fi
    mv "$link" "$bak" 2>/dev/null || rm -rf "$link"
    c_info "已把原 /var/log/nginx 移为 $bak（未删除，可回退）"
  elif [[ -L "$link" ]]; then
    rm -f "$link"   # 指向错误位置的旧软链
  fi
  ln -sfnT "$target" "$link" || { c_warn "创建 $link 软链失败"; return 1; }
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  c_ok "nginx 日志已重定向到外置盘：$link → $target（-sfnT，不会建到目录里）"
  return 0
}

step_nginx_site(){
  local sock pass pool confd
  # 只认 8.2 的 socket，避免误连系统里其它版本的 php-fpm
  if [[ -S "$PHP_SOCK" ]]; then
    sock="$PHP_SOCK"
  else
    sock="$(grep -hoE '^listen *= *[^ ;]+' "$PHP_ETC/fpm/pool.d/www.conf" 2>/dev/null | head -1 | awk '{print $3}' || true)"
  fi
  if [[ -z "$sock" ]]; then sock="127.0.0.1:9000"; c_warn "未探测到 $PHP_SOCK，回退 $sock（请确认 $PHP_FPM_SVC 已启动）"; fi
  if [[ "$sock" == /* ]]; then pass="unix:$sock"; else pass="$sock"; fi

  # 系统 nginx 日志目录 → 外置盘（幂等；用 -sfnT 修「链接建到目录里」的真 bug）
  relocate_nginx_log
  # php8.2-fpm 错误日志 → 外置盘
  pool="$PHP_ETC/fpm/pool.d/www.conf"
  if [[ -f "$pool" ]]; then
    if ! grep -q 'armbian-nas-log' "$pool"; then
      cat >> "$pool" <<EOF

; armbian-nas-log
php_admin_value[error_log] = $BASE/logs/php-fpm-error.log
php_admin_flag[log_errors] = on
EOF
    fi
  else
    c_warn "未找到 $pool，跳过 php-fpm 日志重定向"
  fi
  confd="$PHP_ETC/fpm/conf.d"
  if [[ -d "$confd" ]]; then
    cat > "$confd/99-armbian-nas.ini" <<EOF
; armbian-nas：日志与上传落在非系统盘
error_log = $BASE/logs/php-error.log
upload_tmp_dir = $BASE/downloads
EOF
  else
    c_warn "未找到 $confd，跳过 php.ini 附加配置"
  fi

  # nginx 站点
  cat > /etc/nginx/sites-available/armbian-nas <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root __BASE__/web;
    index index.html index.php index.htm;
    access_log __BASE__/logs/nginx/access.log;
    error_log  __BASE__/logs/nginx/error.log warn;
    client_max_body_size 4096m;

    location / { try_files $uri $uri/ =404; }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_pass __PHP_PASS__;
    }

    # Aria2 RPC 同源反代：AriaNg 里填 http://<IP>/jsonrpc 即可，无需暴露 6800
    location /jsonrpc {
        proxy_pass http://127.0.0.1:6800/jsonrpc;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_buffering off;
    }

    location ~ /\. { deny all; }

    # Transmission 可选反代：片段默认内容是 404，--tr-proxy=1 时才写真实反代
    include /etc/nginx/snippets/armbian-nas-transmission.conf;
    # 网页终端 ttyd：片段由步骤 21 覆盖；未安装时片段内容是 404，保证 nginx -t 永远能过
    include /etc/nginx/snippets/armbian-nas-ttyd.conf;
}
NGINX
  # 片段占位文件必须比 nginx -t 先存在，否则 include 会让站点配置校验失败
  mkdir -p /etc/nginx/snippets
  # Transmission 反代占位：默认直连 :9091，/transmission/ 返回 404。
  # 片段必须比 nginx -t 先存在，否则 include 会让整站配置校验失败。
  if [[ ! -f "$TR_PROXY_SNIPPET" ]]; then
    cat > "$TR_PROXY_SNIPPET" <<'SNIP'
# 占位：未启用 --tr-proxy=1 时 /transmission/ 直接 404；WebUI 直连 :9091 不受影响
location ^~ /transmission/ { return 404; }
SNIP
  fi
  if [[ ! -f /etc/nginx/snippets/armbian-nas-ttyd.conf ]]; then
    # 占位路径必须跟着 --ttyd-path 走，否则改过路径后旧入口没人守。
    cat > /etc/nginx/snippets/armbian-nas-ttyd.conf <<SNIP
# 占位：ttyd 组件未安装（或已卸载）时，${TTYD_PATH}/ 直接 404，绝不误连到 7681
location ${TTYD_PATH}/ { return 404; }
SNIP
  fi
  # WebSocket 升级用的 map（http 块，conf.d 内；名字带 armbian_ 避免和别的配置撞车）
  cat > /etc/nginx/conf.d/00-armbian-nas-ttyd-map.conf <<'MAP'
map $http_upgrade $armbian_conn_upgrade {
    default upgrade;
    ''      close;
}
MAP
  sed -i "s|__BASE__|$BASE|g; s|__PHP_PASS__|$pass|g" /etc/nginx/sites-available/armbian-nas
  ln -sfn /etc/nginx/sites-available/armbian-nas /etc/nginx/sites-enabled/armbian-nas
  # ★ 绝不能把 default 的备份留在 sites-enabled 里（include 会连 .bak 一起读）。
  #   统一移出，并顺带清理上一版已留下的 default.bak.armbian-nas 残留。
  nginx_disable_conflicting_defaults

  # SQLite 数据库
  sqlite3 "$BASE/db/nas.sqlite3" <<'SQL'
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
INSERT OR REPLACE INTO meta(k,v) VALUES ('deployed_at', datetime('now','localtime'));
SQL

  # 默认首页由步骤 18 生成 index.html；这里只放备用状态页 + PHP 探针
  cat > "$WEB_ROOT/status.php" <<'PHPFILE'
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<title>armbian-nas 备用状态页</title>
<style>body{font:15px/1.8 system-ui,sans-serif;max-width:820px;margin:40px auto;color:#222}
a{color:#0969da}code{background:#f2f2f2;padding:2px 6px;border-radius:4px}</style></head><body>
<h1>armbian-nas 备用状态页</h1>
<p><a href="/">← 返回一键导航页</a></p>
<p>网站根目录与日志、下载、索引均位于 <code>__BASE__</code>，不随系统盘重装丢失。</p>
<ul>
<li><a href="/ariang/">AriaNg</a> · RPC 地址填 <code>http://<?= preg_replace('/:\d+$/','',$_SERVER['HTTP_HOST']) ?>/jsonrpc</code></li>
<li><a href="/probe.php">PHP 8.2 + SQLite3 + 扩展核对探针</a></li>
<li>Samba：<code>\\<?= preg_replace('/:\d+$/','',$_SERVER['HTTP_HOST']) ?>\</code> · DLNA 播放器搜索 <code>armbian-nas</code></li>
</ul>
<p>aria2 RPC 密钥在 <code>__BASE__/.deploy/secrets.env</code>（不放进 Web 目录，避免泄露）。</p>
<p>部署状态：<code>bash 脚本 --status</code>；最终报告：<code>__BASE__/.deploy/final-report.txt</code></p>
</body></html>
PHPFILE
  sed -i "s|__BASE__|$BASE|g" "$WEB_ROOT/status.php"
  write_probe_php

  nginx -t || die "nginx -t 未通过"
  systemctl restart nginx
  local svc; svc="$(php_service)"; if [[ -n "$svc" ]]; then systemctl restart "$svc"; fi
  http_ok "http://127.0.0.1/" || c_warn "本机 HTTP 暂未返回 2xx/3xx，请稍后检查 nginx 日志"
  c_ok "站点根目录 $WEB_ROOT；fastcgi_pass $pass；日志已重定向"
}

# ---------------------------------------------------------------------------
# Docker 的 Web 管理界面：Portainer CE
#   * 只在【用户明确选择安装 Docker】时才部署；--no-docker 完全不会拉镜像，
#     这样「按 eMMC 容量选择性安装」的原则不被破坏。
#   * 容器名固定 armbian-nas-portainer，只认这个名字，绝不删用户自己的容器。
#   * 数据卷 $BASE/portainer 在外置盘；镜像层在 /var/lib/docker（或外置 loop）。
#   * 拉不到镜像只 WARN，不让整个步骤 05 失败（离线机器也能继续部署）。
#   * 首次打开 :9000 需在 5 分钟内创建 admin 密码，超时重启容器即可。
# ---------------------------------------------------------------------------
docker_portainer_setup(){
  if [[ "${PORTAINER_ENABLED:-1}" -ne 1 ]]; then
    c_info "已用 --no-portainer 关闭 Docker Web 管理界面（省镜像层与内存）"
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    c_info "Docker 未就绪，跳过 Portainer（装好 Docker 后重跑 --with-docker --redo=05）"
    return 0
  fi
  mkdir -p "$BASE/portainer"
  if docker inspect armbian-nas-portainer >/dev/null 2>&1; then
    if ! docker inspect -f '{{.State.Running}}' armbian-nas-portainer 2>/dev/null | grep -q true; then
      docker start armbian-nas-portainer >/dev/null 2>&1 || c_warn "Portainer 容器启动失败：sudo docker logs armbian-nas-portainer"
    fi
    c_ok "Portainer 容器已存在：http://<本机IP>:$PORT_PORTAINER/（数据卷 $BASE/portainer）"
    return 0
  fi
  c_info "部署 Docker Web 管理界面 Portainer CE（容器 armbian-nas-portainer，端口 $PORT_PORTAINER）..."
  c_info "首次拉镜像会显示进度；若网络不可达只告警，不影响其余步骤继续"
  if docker run -d --name armbian-nas-portainer --restart unless-stopped \
       -p "$PORT_PORTAINER:9000" \
       -v /var/run/docker.sock:/var/run/docker.sock \
       -v "$BASE/portainer:/data" \
       portainer/portainer-ce:latest; then
    c_ok "Portainer 已启动：http://<本机IP>:$PORT_PORTAINER/（首次打开自行创建 admin 密码）"
  else
    c_warn "Portainer 镜像拉取/启动失败（多为网络不可达）；稍后可执行 sudo bash $SCRIPT_PATH --with-docker --redo=05 重试"
    c_warn "导航页 Docker 卡片会置灰，状态页里那条一键命令可随时补装"
  fi
  return 0
}

step_docker(){
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    c_ok "Docker 已存在：$(docker --version)"
  else
    local sh="/tmp/armbian-nas-get-docker.sh"
    c_info "安装 Docker（官方便捷脚本）..."
    if download_show "下载 Docker 官方便捷安装脚本" https://get.docker.com "$sh"; then
      if [[ -n "$DOCKER_MIRROR" ]]; then sh "$sh" --mirror "$DOCKER_MIRROR"; else sh "$sh"; fi
    else
      c_warn "get.docker.com 不可达，回退发行版仓库安装 docker.io"
      apt_install docker.io docker-compose-plugin || apt_install docker.io docker-compose
    fi
  fi
  systemctl enable --now docker
  docker info >/dev/null 2>&1 || die "Docker 服务未就绪"

  # NTFS 不能作为 docker data-root（overlay2 需要 xattr/upperdir 语义）
  if [[ -n "$DOCKER_DATA_ROOT" ]]; then
    mkdir -p "$DOCKER_DATA_ROOT"
    local fst; fst="$(stat -f -c %T "$DOCKER_DATA_ROOT" 2>/dev/null || echo unknown)"
    case "$fst" in
      ext4|xfs|btrfs|ext3)
        mkdir -p /etc/docker
        printf '{\n  "data-root": "%s",\n  "log-driver": "json-file",\n  "log-opts": {"max-size": "10m", "max-file": "3"}\n}\n' "$DOCKER_DATA_ROOT" > /etc/docker/daemon.json
        systemctl restart docker
        c_ok "Docker data-root → $DOCKER_DATA_ROOT ($fst)" ;;
      *) c_warn "拒绝把 Docker data-root 放到 $fst（$DOCKER_DATA_ROOT）：NTFS 不支持 overlay2，保持 /var/lib/docker" ;;
    esac
  else
    c_info "Docker 数据保留 /var/lib/docker（推荐；容器配置与下载卷仍挂 $BASE）"
  fi
  local u="${SUDO_USER:-root}"
  [[ "$u" != "root" ]] && usermod -aG docker "$u" 2>/dev/null || true
  c_ok "Docker 就绪：$(docker --version)"
  # ★ 用户要求：常用 Web 界面里要有 Docker 的 Web 管理入口
  docker_portainer_setup
}

step_verysync(){
  local unit installer
  installer="$STATE_DIR/go-installer.sh"
  if [[ ! -x /usr/bin/verysync/verysync ]]; then
    c_info "下载微力同步官方 Linux 安装器..."
    curl -kfsSL https://www.verysync.com/shell/verysync-linux-installer/go-installer.sh -o "$installer" \
      || die "微力同步安装器下载失败；可手动下载后加 --version / 本地安装，或稍后 --redo=06 重试"
    chmod +x "$installer"
    # -d 指定索引/配置目录到外置盘；-u root 保证能写 NTFS 挂载点
    bash "$installer" -d "$BASE/verysync" -u root
  else
    c_ok "微力同步主程序已存在，跳过下载"
  fi
  mkdir -p "$BASE/verysync"
  unit="$(systemctl list-unit-files --no-legend 2>/dev/null | awk '/verysync.*\.service/{print $1; exit}' || true)"
  if [[ -z "$unit" ]]; then unit="verysync.service"; fi
  local unitfile="/etc/systemd/system/$unit"
  # 用 drop-in 覆盖官方 ExecStart，确保 WebUI 监听全网段且 --home 落在外置盘
  mkdir -p "/etc/systemd/system/$unit.d"
  cat > "/etc/systemd/system/$unit.d/10-armbian-nas.conf" <<EOF
[Service]
User=root
Group=root
WorkingDirectory=$BASE/verysync
ExecStart=
ExecStart=/usr/bin/verysync/verysync serve --gui-address 0.0.0.0:8886 --no-browser --no-restart --logflags=0 --home "$BASE/verysync"
Restart=on-failure
RestartSec=3
EOF
  systemctl daemon-reload
  systemctl enable --now "$unit"
  sleep 2
  svc_active "$unit" || c_warn "微力同步服务未处于 active，请 journalctl -u $unit 查看"
  c_ok "微力同步 WebUI：http://$(lan_ip):8886 ，索引目录 $BASE/verysync"
}

# ★ 真机教训（Armbian 26.8.11 resolute / Ubuntu 26.04）：
#   旧版只用 install.zerotier.com 官方脚本。该脚本按 codename 拼仓库地址，
#   对新版本曾出现 "Unknown or unsupported distribution! Aborting"（jammy 时
#   也踩过同类 bug），脚本静默退出后 systemctl enable --now zerotier-one 报
#   "Unit zerotier-one.service not found"；而 tmux 窗口一闪而过把输出全清掉，
#   用户只看到 [exited]，完全不知道为什么没装上。
#   Debian/Ubuntu 官方安装指南本身就推荐 apt install zerotier-one，所以改为
#   ① apt 优先（不受 codename 影响）→ ② 官方脚本兜底 → ③ 仍无 unit 则明确
#   打印诊断与可复制的手动命令，绝不静默失败。
zt_unit_ok(){
  command -v zerotier-cli >/dev/null 2>&1 || return 1
  systemctl list-unit-files 2>/dev/null | grep -q '^zerotier-one\.service' && return 0
  systemctl list-unit-files 2>/dev/null | grep -q 'zerotier-one' && return 0
  [[ -f /lib/systemd/system/zerotier-one.service \
     || -f /usr/lib/systemd/system/zerotier-one.service \
     || -f /etc/systemd/system/zerotier-one.service ]] && return 0
  return 1
}
zt_apt_candidate(){
  local c
  c="$(apt-cache policy zerotier-one 2>/dev/null | awk '/Candidate:/{print $2; exit}' || true)"
  [[ -n "$c" && "$c" != "(none)" ]]
}
step_zerotier(){
  local zt="$STATE_DIR/zt-install.sh" zt_log="$LOG_DIR/zerotier-install.log"
  mkdir -p "$STATE_DIR" "$LOG_DIR"

  if ! zt_unit_ok; then
    c_info "未检测到 zerotier-one 服务，开始安装（apt 优先 → 官方脚本兜底）"

    # ① apt 优先：Ubuntu/Debian 官方指南推荐；universe 里有包时最稳
    if command -v apt-get >/dev/null 2>&1; then
      if [[ -z "$(ls -A /var/lib/apt/lists 2>/dev/null | head -1)" ]]; then
        c_info "apt 索引为空，先刷新一次（否则会误报 Unable to locate package）"
        apt_update
      fi
      if ! zt_apt_candidate; then
        c_warn "apt 索引里暂无 zerotier-one（可能未启用 universe），刷新并尝试启用 universe"
        if command -v add-apt-repository >/dev/null 2>&1; then
          add-apt-repository -y universe >/dev/null 2>&1 || true
        fi
        apt_update
      fi
      if zt_apt_candidate; then
        c_info "源里有 zerotier-one，直接 apt 安装（不走 install.zerotier.com）"
        if ! apt_install zerotier-one; then
          c_warn "apt 安装 zerotier-one 失败，转官方脚本兜底"
        fi
      else
        c_warn "apt 源确实没有 zerotier-one，转官方脚本兜底"
      fi
      systemctl daemon-reload 2>/dev/null || true
    fi

    # ② 官方脚本兜底：输出落盘，失败时打印尾部，不再让错误消失在 tmux 里
    if ! zt_unit_ok; then
      c_info "apt 路径未装上，改用官方安装脚本（完整输出写入 $zt_log）"
      if download_show "下载 ZeroTier 安装脚本" https://install.zerotier.com/ "$zt" \
         || download_show "换备用地址下载 ZeroTier 安装脚本" https://install.www.zerotier.com/ "$zt"; then
        if ! bash "$zt" >"$zt_log" 2>&1; then
          c_warn "官方安装脚本执行失败；最后 15 行（完整见 $zt_log）："
          tail -15 "$zt_log" >&2 || true
        fi
        systemctl daemon-reload 2>/dev/null || true
      else
        c_warn "官方安装脚本下载失败（网络 / 证书 / DNS）"
      fi
    fi

    # ③ 仍然没有 unit → 明确失败 + 可复制的手动命令
    if ! zt_unit_ok; then
      c_err "★ zerotier-one 没装上：systemctl 里找不到 zerotier-one.service"
      c_err "  排查：apt-cache policy zerotier-one ; dpkg -l | grep zerotier ; tail -30 '$zt_log'"
      c_err "  手动补装：sudo apt-get update && sudo apt-get install -y zerotier-one"
      c_err "  或：curl -s https://install.zerotier.com | sudo bash（新 codename 可能不被识别）"
      c_err "  装好后重跑：sudo bash $SCRIPT_PATH --with-zerotier --redo=07"
      c_err "  本次完整日志：$BOOT_LOG"
      return 1
    fi
  fi

  systemctl enable --now zerotier-one \
    || die "zerotier-one 服务启用/启动失败：systemctl status zerotier-one ; journalctl -u zerotier-one -n 50"
  sleep 2
  zerotier-cli info >/dev/null 2>&1 \
    || die "zerotier-one 未就绪：journalctl -u zerotier-one -n 50"
  if [[ -n "$ZT_NETWORK_ID" ]]; then
    zerotier-cli join "$ZT_NETWORK_ID" || die "zerotier-cli join 失败"
    c_ok "已加入 ZeroTier 网络 $ZT_NETWORK_ID"
    c_warn "私有网络还必须到 ZeroTier Central 勾选授权本设备，否则 listnetworks 显示 ACCESS_DENIED"
    c_info "查看：zerotier-cli listnetworks"
  else
    c_warn "未提供 --zt-network=NETWORK_ID，已装好但未加入网络"
    c_info "稍后执行：sudo zerotier-cli join <16位网络ID>；再到 Central 授权"
    c_info "或重跑：sudo bash $SCRIPT_PATH --zt-network=<ID> --redo=07"
  fi
  c_ok "ZeroTier 安装完成"
}

# ---------------------------------------------------------------------------
# qBittorrent / Transmission：直接 apt 装进系统，不跑 Docker 容器。
# 配置目录、下载目录、WebUI 静态文件全部放在外置盘 $BASE 下。
# ---------------------------------------------------------------------------
remove_legacy_bt_container(){
  # 旧版脚本曾把 BT 放进 Docker。只删除「确实由本脚本创建」的同名容器，避免误伤。
  local name="$1" vol="$2" mounts
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0
  docker inspect "$name" >/dev/null 2>&1 || return 0
  mounts="$(docker inspect -f '{{json .Mounts}}' "$name" 2>/dev/null || true)"
  if [[ "$mounts" == *"$vol"* ]]; then
    if docker rm -f "$name" >/dev/null 2>&1; then
      c_ok "已移除旧版 Docker 容器 $name（配置卷 $vol 保留，原生版会继续用）"
    else
      c_warn "旧容器 $name 删除失败，可能与原生版抢 8080/9091 端口；请手工 docker rm -f $name"
    fi
  else
    c_warn "发现同名容器 $name 但未挂 $vol，不是本脚本创建的，未删除；请注意端口是否冲突"
  fi
}

qb_conf_set(){ # 幂等写 QSettings ini（保持键大小写，不用 configparser 的默认小写化）
  python3 - "$@" <<'PY'
import sys, configparser
p = sys.argv[1]
cp = configparser.RawConfigParser(strict=False)   # 容忍重复键，避免整份 conf 读失败后丢配置
cp.optionxform = str
try:
    cp.read(p, encoding='utf-8')
except Exception:
    pass
for pair in sys.argv[2:]:
    sec, kv = pair.split('|', 1)
    k, v = kv.split('=', 1)
    if not cp.has_section(sec): cp.add_section(sec)
    cp.set(sec, k, v)
with open(p, 'w', encoding='utf-8') as f:
    cp.write(f, space_around_delimiters=False)
PY
}
qb_conf_del(){
  python3 - "$@" <<'PY'
import sys, configparser
p = sys.argv[1]
cp = configparser.RawConfigParser(strict=False); cp.optionxform = str
try: cp.read(p, encoding='utf-8')
except Exception: pass
for pair in sys.argv[2:]:
    sec, k = pair.split('|', 1)
    if cp.has_section(sec) and cp.has_option(sec, k): cp.remove_option(sec, k)
with open(p, 'w', encoding='utf-8') as f:
    cp.write(f, space_around_delimiters=False)
PY
}

# ★ qBittorrent WebUI 账号：默认 admin / adminadmin（局域网自用，用户明确要求写死明文）。
# 密码以 qB 原生 PBKDF2 形式写入 [Preferences] WebUI\Password_PBKDF2。
# 下面是 adminadmin 的标准 PBKDF2-HMAC-SHA512 哈希（salt=ARQ77eY1NUZaQsuDHbIMCA==），
# 与 qB 官方文档/社区通行值一致；可用 --qb-password= 指定别的密码（会自动重算哈希）。
QB_WEBUI_USER="admin"
QB_WEBUI_SIMPLE_PASS="adminadmin"
QB_WEBUI_PBKDF2_ADMINADMIN='@ByteArray(ARQ77eY1NUZaQsuDHbIMCA==:0WMRkYTUWVT9wVvdDtHAjU9b3b7uB8NR1Gur2hmQCvCDpm39Q+PsJRJPaCU51dEiz+dTzh8qbPsL8WkFljQYFQ==)'

# 生成 qB 的 Password_PBKDF2 值；入参=明文。qB 用 PBKDF2-HMAC-SHA512、100000 轮、16 字节 salt。
# 依赖 python3（脚本本就强依赖）。生成失败返回非空 1，调用方回退到内置 adminadmin 哈希。
qb_pbkdf2_gen(){
  local pw="${1:-}" salt_b64 iter_b64
  [[ -n "$pw" ]] || return 1
  # salt 用 16 字节随机数；qB 存的是 base64(salt) 与 base64(dk)
  read -r salt_b64 iter_b64 < <(python3 - "$pw" <<'PY' 2>/dev/null || true
import sys, os, base64, hashlib
pw = sys.argv[1].encode('utf-8')
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac('sha512', pw, salt, 100000, dklen=64)  # ★ qB 固定 64 字节，32 会登录失败
print(base64.b64encode(salt).decode(), base64.b64encode(dk).decode())
PY
)
  [[ -n "${salt_b64:-}" && -n "${iter_b64:-}" ]] || return 1
  printf '@ByteArray(%s:%s)' "$salt_b64" "$iter_b64"
}

# 统一的 WebUI 密码哈希入口：$1=明文，输出 qB 的 @ByteArray(salt:hash)。
# adminadmin 用已验证过的内置固定哈希（见下方真机验证），其它密码现场计算。
qb_webui_pbkdf2(){
  local pw="${1:-}" g
  # ★ 不能写死 adminadmin：用户 --qb-password=自定义密码 时，这里若仍用默认值，
  #   写进 conf 的 hash 与用户以为的密码不一致，登录照样报 Invalid Username or Password。
  [[ -n "$pw" ]] || pw="$(qb_effective_password)"
  if [[ "$pw" == "$QB_WEBUI_SIMPLE_PASS" ]]; then
    printf '%s' "$QB_WEBUI_PBKDF2_ADMINADMIN"
    return 0
  fi
  g="$(qb_pbkdf2_gen "$pw")" || return 1
  [[ -n "$g" ]] || return 1
  printf '%s' "$g"
}

# 本次实际生效的明文密码：优先 --qb-password，其次落盘记录，最后 adminadmin。
# 落盘记录让【只跑 --check】时也能用正确密码做 curl 登录自检。
qb_effective_password(){
  local p="${QB_WEBUI_PASS_OVERRIDE:-}"
  if [[ -z "$p" && -r "${QB_PASS_FILE:-}" ]]; then
    p="$(tr -d '\r\n' < "$QB_PASS_FILE" 2>/dev/null || true)"
  fi
  printf '%s' "${p:-$QB_WEBUI_SIMPLE_PASS}"
}

# 把生效密码落盘（600 权限）。只在「会写系统」的部署/自愈流程里调用，
# --check / --status / --help / --dry-run 全只读，不碰这个文件。
qb_save_effective_password(){
  local p; p="$(qb_effective_password)"
  mkdir -p "$(dirname "$QB_PASS_FILE")" 2>/dev/null || return 0
  printf '%s\n' "$p" > "$QB_PASS_FILE" 2>/dev/null || true
  chmod 600 "$QB_PASS_FILE" 2>/dev/null || true
}

# ★ qB WebUI 真实登录自检（停服→写配置→起服之后的最后一道验证）
#   只 curl 首页看 200 不够：qB 的 /api/v2/auth/login 无论成功失败都返回 HTTP 200，
#   成功 body 为 "Ok."，失败为 "Fails."（真机症状 "Invalid Username or Password.
#   Server response: Fails."）。所以必须用 admin/<密码> POST 一次并比对 body 前缀。
# 入参1(可选)=明文密码，默认取 --qb-password= / 内置 adminadmin。返回 0=真的能登录。
qb_curl_login_check(){
  local pw="${1:-}"
  # ★ 只跑 --check（不带任何参数）时也要拿对密码：优先 --qb-password，
  #   其次读 QB_PASS_FILE 里上次落盘的明文，最后才是内置 adminadmin。
  [[ -n "$pw" ]] || pw="$(qb_effective_password)"
  local user="${QB_WEBUI_USER:-admin}"
  local body_file cookie_file code body
  command -v curl >/dev/null 2>&1 || return 1
  body_file="$(mktemp 2>/dev/null || echo "/tmp/qbbody.$$")"
  cookie_file="$(mktemp 2>/dev/null || echo "/tmp/qbcookie.$$")"
  code="$(curl -s -o "$body_file" -w '%{http_code}' --max-time 8 \
    -c "$cookie_file" -b "$cookie_file" \
    -H "Referer: http://127.0.0.1:$PORT_QB/" \
    --data-urlencode "username=$user" \
    --data-urlencode "password=$pw" \
    "http://127.0.0.1:$PORT_QB/api/v2/auth/login" 2>/dev/null || echo '000')"
  body="$(head -c 200 "$body_file" 2>/dev/null || true)"
  rm -f "$body_file" "$cookie_file" 2>/dev/null || true
  [[ "$code" == "200" ]] || return 1
  [[ "$body" == Ok* ]] || return 1      # qB 登录成功固定返回 "Ok."
  return 0
}

# ★ 统一固化流程：停服 → 写 [Preferences] 凭据 → 起服 → curl 登录自检。
#   供 step_qb 与 --repair 自愈共用，保证「停服再写、写完真验」只有一份实现。
# 入参1=conf 路径；入参2(可选，1)=连同 /root/.config 也写一份（兼容旧路径）。
# 返回 0=配置写成功且 curl 登录通过；非 0=写了但登录未确认（调用方据此告警）。
qb_apply_config(){
  local conf="$1" also_root="${2:-0}"
  [[ -n "$conf" ]] || conf="$BASE/qb/config/qBittorrent/qBittorrent.conf"
  mkdir -p "$(dirname "$conf")"
  # ★ 关键：先停服。运行中的 qB 退出时 QSettings 会把内存里的旧值覆写回 conf，
  #   边跑边改会被冲掉；这也解释了真机上「killall 之后手改才生效」。
  if svc_active qbittorrent-nox 2>/dev/null; then
    c_info "  qB 正在运行：先停服再写配置（避免退出时覆盖）"
    systemctl stop qbittorrent-nox >/dev/null 2>&1 || true
    pkill -x qbittorrent-nox >/dev/null 2>&1 || true
    sleep 1
  fi
  # 已有配置先备份，便于回滚（不删数据）
  [[ -f "$conf" ]] && cp -a "$conf" "$conf.bak.$(date +%F-%H%M%S)" 2>/dev/null || true
  qb_conf_write_auth "$conf"
  if [[ "$also_root" == "1" ]]; then
    mkdir -p /root/.config/qBittorrent
    [[ -f /root/.config/qBittorrent/qBittorrent.conf ]] \
      && cp -a /root/.config/qBittorrent/qBittorrent.conf \
               /root/.config/qBittorrent/qBittorrent.conf.bak.$(date +%F-%H%M%S) 2>/dev/null || true
    qb_conf_write_auth /root/.config/qBittorrent/qBittorrent.conf
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  # ★ 必须 restart：服务已在跑时 `enable --now` 不会重启，内存里仍是旧凭据，
  #   而且退出时 QSettings 会把旧值覆写回刚写好的 conf —— 自愈等于白做。
  systemctl enable qbittorrent-nox >/dev/null 2>&1 || true
  systemctl restart qbittorrent-nox >/dev/null 2>&1 \
    || systemctl start qbittorrent-nox >/dev/null 2>&1 || true
  # 起服后等 WebUI 就绪再验（最多约 8s）
  local i
  for i in 1 2 3 4 5 6 7 8; do
    svc_active qbittorrent-nox 2>/dev/null || break
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT_QB/" 2>/dev/null && break
    sleep 1
  done
  if qb_curl_login_check; then
    c_ok "qB WebUI 登录自检通过：${QB_WEBUI_USER:-admin} / ${QB_WEBUI_SIMPLE_PASS:-adminadmin}（HTTP 200 + Ok.）"
    return 0
  fi
  c_warn "qB 配置已写但登录自检未通过（HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:$PORT_QB/ 2>/dev/null || echo '-')）；journalctl -u qbittorrent-nox -n 30"
  return 1
}

# ---------------------------------------------------------------------------
# ★ qBittorrent WebUI 凭据固化（真机：Invalid Username or Password / Fails）
#
# 现象：打开 :8080 输入 admin/adminadmin 仍提示
#       "Invalid Username or Password. Server response: Fails."
# 根因两层，都不是「密码记错了」：
#   ① [Preferences] 缺 WebUI\Username 与 WebUI\Password_PBKDF2 —— qB 5.x 改用
#      一次性临时密码（只写在 journalctl 里），默认口令自然登不上。
#   ② 即便密码正确，HostHeaderValidation / CSRFProtection 会拦截来自局域网 IP
#      的请求，并且【伪装成密码错误】，让人反复怀疑凭据。
# 修法：停服 → 把完整字段写进 [Preferences] → 重启。
#   ★ 必须停服：qB 退出时 QSettings 会把内存里的旧值覆写回 conf，边跑边改无效。
#   ★ 幂等且尊重用户：conf 里已有 Password_PBKDF2 时【保留】你在 WebUI 改过的
#     密码，只补齐安全策略；显式 --qb-password= 才重新计算并覆盖 hash。
# ---------------------------------------------------------------------------
qb_conf_write_auth(){
  local conf="$1" has_hash=0 hash="" user
  [[ -f "$conf" ]] || : > "$conf"
  grep -qF 'WebUI\Password_PBKDF2=' "$conf" 2>/dev/null && has_hash=1
  user="${QB_WEBUI_USER:-admin}"

  # 总是补齐：中文界面 / 认证子网白名单 / Host 头校验 / CSRF / 用户名 / 端口
  qb_conf_set "$conf" \
    "LegalNotice|Accepted=true" \
    "Preferences|General\\Locale=zh_CN" \
    "Preferences|MailNotification\\req_auth=true" \
    "Preferences|WebUI\\Port=$PORT_QB" \
    "Preferences|WebUI\\Address=*" \
    "Preferences|WebUI\\HostHeaderValidation=false" \
    "Preferences|WebUI\\CSRFProtection=false" \
    "Preferences|WebUI\\AuthSubnetWhitelistEnabled=false" \
    "Preferences|WebUI\\AuthSubnetWhitelist=@Invalid()" \
    "Preferences|WebUI\\Username=$user"

  # 密码 hash：缺字段 / 显式指定密码 → 写；否则保留用户改过的
  if [[ -n "${QB_WEBUI_PASS_OVERRIDE:-}" || "$has_hash" -eq 0 ]]; then
    hash="$(qb_webui_pbkdf2)"
    # ★ 按真机实测格式加外层双引号：QSettings ini 里这是标准字符串写法，
    #   qB 读取时会去掉引号；用户手改 conf 时也是这种形式，两边保持一致。
    qb_conf_set "$conf" "Preferences|WebUI\\Password_PBKDF2=\"$hash\""
    # ★ 把本次实际生效的明文落盘（600）。否则以后只跑 --check / 收尾自愈时，
    #   qb_curl_login_check 不知道用户用了 --qb-password=自定义密码，会拿默认
    #   adminadmin 去登录 → 误报 FAIL，甚至 qb_auth_heal 反复重修也修不动。
    local _qpf="${QB_PASS_FILE:-$STATE_DIR/qb-webui.pass}"
    mkdir -p "$(dirname "$_qpf")" 2>/dev/null || true
    printf '%s\n' "$(qb_effective_password)" > "$_qpf" 2>/dev/null || true
    chmod 600 "$_qpf" 2>/dev/null || true
    c_info "  已固化 WebUI 凭据：$user / $(qb_effective_password) → $conf（明文记录 $_qpf，600）"
  else
    c_info "  $conf 已有 Password_PBKDF2：保留你改过的密码（重置用 --qb-password=adminadmin）"
  fi
  chmod 600 "$conf" 2>/dev/null || true
}

# 自检 helper：服务实际读的那份 conf 必须字段齐全，且 unit 的 XDG 指向它
qb_auth_ok(){
  local conf="$BASE/qb/config/qBittorrent/qBittorrent.conf" k
  [[ -f "$conf" ]] || return 1
  for k in 'WebUI\Username=' 'WebUI\Password_PBKDF2=' \
           'WebUI\CSRFProtection=false' 'WebUI\HostHeaderValidation=false' \
           'WebUI\AuthSubnetWhitelist=@Invalid()' 'General\Locale=zh_CN'; do
    grep -qF "$k" "$conf" || return 1
  done
  grep -qF "XDG_CONFIG_HOME=$BASE/qb/config" \
    /etc/systemd/system/qbittorrent-nox.service 2>/dev/null || return 1
  return 0
}

# 收尾自愈 / --repair：步骤 08 已 done 被跳过时，真机 conf 仍是旧的，照样登不上
qb_auth_heal(){
  component_decision qb >/dev/null 2>&1 || return 0
  [[ "$(component_decision qb)" == "chosen" ]] || return 0
  local conf="$BASE/qb/config/qBittorrent/qBittorrent.conf"
  [[ -f "$conf" ]] || return 0
  # ★ 双重判据：字段齐 + 真实可登录，任一不满足才修。
  #   只看字段会在「字段在但密码被首启临时密码覆盖」时漏修（真机登不上的主因）。
  if qb_auth_ok && qb_curl_login_check; then return 0; fi
  c_info "qB WebUI 需重修：停服 → 写 [Preferences] 凭据 → 起服 → curl 登录自检（不动下载数据）"
  # 统一走 qb_apply_config：停服 → 写两份 conf → 起服 → curl 登录自检，一份实现不漂移
  qb_apply_config "$conf" 1 >/dev/null 2>&1 || true
  if qb_auth_ok && qb_curl_login_check; then
    c_ok "qB WebUI 凭据已修复并登录验证通过：admin / adminadmin（中文界面，HTTP 200 + Ok.）"
  elif qb_auth_ok; then
    c_warn "qB 字段已补齐但登录自检未过：journalctl -u qbittorrent-nox -n 30；或 --qb-password= 重设"
  else
    c_warn "qB 配置仍缺字段：sudo bash $SCRIPT_PATH --with-qb --redo=08"
  fi
  return 0
}

step_qb(){
  remove_legacy_bt_container qbittorrent "$BASE/qb"

  apt_install qbittorrent-nox
  command -v qbittorrent-nox >/dev/null 2>&1 || die "qbittorrent-nox 安装失败（源里没有该包？可 --redo=08 重试）"
  mkdir -p "$BASE/qb/config/qBittorrent" "$BASE/qb/data" "$BASE/qb/cache" \
           "$BASE/webui/qbittorrent" \
           "$BASE/downloads/complete" "$BASE/downloads/incomplete" "$BASE/downloads/watch"

  # ★ 必须【先停服再写 conf】：qBittorrent-nox 退出时 QSettings 会把内存里的旧
  #   配置覆写回 qBittorrent.conf。服务还在跑时改文件，重启后又被打回原样，
  #   表现就是「明明写了账号密码、依然 Invalid Username or Password」。
  if svc_active qbittorrent-nox; then
    c_info "  qB 正在运行：先停服，避免退出时覆写刚写好的 WebUI 凭据"
    systemctl stop qbittorrent-nox >/dev/null 2>&1 || true
    sleep 1
  fi
  pkill -x qbittorrent-nox >/dev/null 2>&1 || true   # 手工启动 / killall 场景兜底

  # 1) WebUI 静态文件 → 外置盘（系统原文件保持不动，只是复制）
  local src="" d
  for d in /usr/share/qbittorrent/webui /usr/share/qbittorrent/public \
           /usr/share/qbittorrent/www /usr/share/qbittorrent/WebUI; do
    [[ -f "$d/index.html" ]] && { src="$d"; break; }
  done
  local webui_ext=0
  if [[ -n "$src" ]]; then
    cp -a "$src/." "$BASE/webui/qbittorrent/" 2>/dev/null || true
    [[ -f "$BASE/webui/qbittorrent/index.html" ]] && webui_ext=1
  fi
  if [[ "$webui_ext" -eq 1 ]]; then
    c_ok "qB WebUI 静态文件已外置：$src → $BASE/webui/qbittorrent"
  else
    c_warn "未找到系统自带 qB WebUI 静态文件（或复制失败），改用 qB 内嵌 WebUI；功能不受影响"
  fi

  # 2) 配置文件也在外置盘（QSettings 路径 = $XDG_CONFIG_HOME/qBittorrent/qBittorrent.conf）
  #    账号/PBKDF2/中文界面/Host 头校验/CSRF/认证子网白名单统一由 qb_conf_write_auth 写入，
  #    避免这里写一套、--repair 自愈写另一套，字段不一致导致自检永远判 FAIL。
  local conf="$BASE/qb/config/qBittorrent/qBittorrent.conf"
  [[ -f "$conf" ]] || : > "$conf"
  qb_conf_write_auth "$conf"
  qb_conf_set "$conf" \
    "Preferences|Downloads\\SavePath=$BASE/downloads/complete" \
    "Preferences|Downloads\\TempPathEnabled=true" \
    "Preferences|Downloads\\TempPath=$BASE/downloads/incomplete"
  if [[ "$webui_ext" -eq 1 ]]; then
    qb_conf_set "$conf" \
      "Preferences|WebUI\\AlternativeUIEnabled=true" \
      "Preferences|WebUI\\RootFolder=$BASE/webui/qbittorrent"
  else
    qb_conf_del "$conf" "Preferences|WebUI\\AlternativeUIEnabled" "Preferences|WebUI\\RootFolder"
  fi

  # ★ /root/.config 那份是「不带 XDG 环境变量手工启动 qbittorrent-nox」时读的。
  #   真机上两份都缺字段，所以同步写一份，避免换种启动方式又登不上。
  local rootconf="/root/.config/qBittorrent/qBittorrent.conf"
  mkdir -p /root/.config/qBittorrent
  qb_conf_write_auth "$rootconf"
  c_info "  两份配置已同步：$conf（服务实际读，unit 的 XDG_CONFIG_HOME 指向它） + $rootconf（手工启动兜底）"

  # 3) systemd unit：用 XDG 环境变量把整个 profile 落到外置盘（不依赖 --profile 参数是否存在）
  cat > /etc/systemd/system/qbittorrent-nox.service <<EOF
[Unit]
Description=qBittorrent-nox (armbian-nas, native)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
UMask=002
Environment=HOME=$BASE/qb
Environment=XDG_CONFIG_HOME=$BASE/qb/config
Environment=XDG_DATA_HOME=$BASE/qb/data
Environment=XDG_CACHE_HOME=$BASE/qb/cache
Environment=QT_QPA_PLATFORM=offscreen
ExecStart=/usr/bin/qbittorrent-nox --webui-port=$PORT_QB
Restart=on-failure
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  # ★ 必须 restart 而不是 enable --now：服务已在跑时 --now 不会重启，
  #   内存里仍是旧凭据；只有真正重启才会重新读取刚写好的 qBittorrent.conf。
  systemctl enable qbittorrent-nox >/dev/null 2>&1 || true
  systemctl restart qbittorrent-nox >/dev/null 2>&1 \
    || systemctl start qbittorrent-nox >/dev/null 2>&1 || true
  sleep 1
  svc_active qbittorrent-nox && c_ok "qbittorrent-nox 服务已运行" \
    || c_warn "qbittorrent-nox 未 active，请 journalctl -u qbittorrent-nox -n 50"
  c_ok "qBittorrent 原生安装完成：WebUI http://$(lan_ip):$PORT_QB"
  c_info "  配置 $conf · 下载 $BASE/downloads/complete · WebUI $BASE/webui/qbittorrent"
  c_ok "WebUI 账号已写入配置：用户名 $QB_WEBUI_USER / 密码 $QB_WEBUI_SIMPLE_PASS（中文界面，已关闭 Host 头校验与 CSRF）"
  # ★ 起服后【真实登录自检】：用 admin/<密码> POST /api/v2/auth/login，比对 body 的 "Ok."
  #   只 curl 首页看 200 不够——qB 登录成功/失败都返回 200，失败 body 是 "Fails."。
  #   这一步直接验证真机症状「Invalid Username or Password / Fails」是否已消除。
  local _i
  for _i in 1 2 3 4 5 6; do
    qb_curl_login_check && break
    sleep 2
  done
  if qb_curl_login_check; then
    c_ok "qB WebUI 登录自检通过：http://127.0.0.1:$PORT_QB 用 $QB_WEBUI_USER / $QB_WEBUI_SIMPLE_PASS 可登录（HTTP 200 + Ok.）"
  else
    c_warn "qB 配置已写但登录自检未过（首页 HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:$PORT_QB/ 2>/dev/null || echo '-')）；journalctl -u qbittorrent-nox -n 30，或 --qb-password= 重设"
  fi
  if [[ "${QB_WEBUI_PASS_OVERRIDE:-}" == "$QB_WEBUI_SIMPLE_PASS" || -z "${QB_WEBUI_PASS_OVERRIDE:-}" ]]; then
    c_warn "内网自用默认口令 admin/adminadmin，局域网内任何人可登录；建议登录后立即在 WebUI 里改密"
  fi
}

# ---------------------------------------------------------------------------
# ★ Transmission 中文增强 WebUI：TrguiNG 汉化版（jayzcoder/TrguiNG）
#
# 背景：Transmission 自带 WebUI 是英文、功能较简。用户在步骤 09 会看到一个
#   「是否安装中文增强界面？[Y/n]」选择，输入 y（或直接回车）即整合 TrguiNG
#   汉化版：简体中文 + 目录分组 / Tracker 二级过滤 / 批量改 tracker /
#   多链接下载 / 字体大小调整等更多设置。
#
# 来源与许可：
#   github.com/jayzcoder/TrguiNG        基于 openscopeproject/TrguiNG 汉化并改进
#   github.com/openscopeproject/TrguiNG 上游（TypeScript/React + Tauri，AGPL-3.0）
#   完整署名见 armbian-nas-使用说明.md「开源组件与致谢」章节。
#
# ★ 为什么拉 release 而不是现场编译源码：
#   上游 README 要求 Node.js 16+ / Rust 1.69+ / GeoIP mmdb，再 npm install +
#   npm run build 才产出 dist。这台机器只有 1G 内存，编译必然 OOM。
#   所以脚本拉取仓库【已编译好的 WebUI 静态包】trguing-web-*-zh-*.zip
#   （约 349 KB），这才是 Transmission 能直接托管的东西。
#
# ★ 整合方式（Transmission 官方机制，非 hack）：
#   daemon 支持环境变量 TRANSMISSION_WEB_HOME 指向自定义 Web 资源目录，
#   该目录下必须【直接】放 index.html（不能再嵌套一层文件夹）。
#   step_tr 已经用 systemd drop-in 写这个变量，这里只需把它的值换成中文包目录。
#   不改 settings.json、不覆盖 /usr/share/transmission/web、不动 RPC 配置，
#   切回官方英文界面只要 --tr-webui=official --redo=09 重写 drop-in。
#
# ★ 失败策略：GitHub 不可达只 WARN 并保留官方英文界面，绝不让步骤 09 失败；
#   用户可 --tr-webui-zip=/本地/xxx.zip 离线补装，或用 --github-mirror 加速。
# ---------------------------------------------------------------------------
TR_WEBUI_REPO="jayzcoder/TrguiNG"
TR_WEBUI_UPSTREAM="openscopeproject/TrguiNG"
TR_WEBUI_FALLBACK_ASSET="trguing-web-v1.3.0-zh-240607a"
TR_WEBUI_FALLBACK_URL="https://github.com/jayzcoder/TrguiNG/releases/download/${TR_WEBUI_FALLBACK_ASSET}/${TR_WEBUI_FALLBACK_ASSET}.zip"

tr_webui_dir(){          printf '%s/webui/trguing-zh' "$BASE"; }
tr_webui_choice_file(){  printf '%s/tr-webui.choice' "$STATE_DIR"; }
tr_webui_version_file(){ printf '%s/tr-webui.version' "$STATE_DIR"; }

# 界面选择四态：trguing / official / failed / undecided
#   读命令行参数优先，其次读上次落盘的选择；全新机器是 undecided。
tr_webui_decision(){
  local f v
  v="${TR_WEBUI:-ask}"
  case "$v" in
    trguing|zh|yes|y)      echo trguing;   return 0 ;;
    official|en|off|no|n)  echo official;  return 0 ;;
  esac
  f="$(tr_webui_choice_file)"
  if [[ -r "$f" ]]; then
    case "$(head -1 "$f" 2>/dev/null || true)" in
      trguing)  echo trguing;  return 0 ;;
      official) echo official; return 0 ;;
      failed)   echo failed;   return 0 ;;
    esac
  fi
  echo undecided
}

# 交互询问。统一走 /dev/tty：main 里 exec > >(tee ...) 已把 fd1 变成管道，
# 用 stdin 会被重定向吞掉；这和 component_gate / probe_ask 是同一套通道。
tr_webui_ask(){
  local dec ans tty
  mkdir -p "$STATE_DIR"
  # 显式传 --tr-webui=ask 表示「重新询问」：先清掉上次落盘的选择，
  # 否则会一直沿用上次决定（这是文档里那条命令的语义）。只生效一次。
  if [[ "${TR_WEBUI_RESELECT:-0}" -eq 1 ]]; then
    rm -f "$(tr_webui_choice_file)"
    TR_WEBUI_RESELECT=0
    c_info "已按 --tr-webui=ask 清除上次界面选择，下面重新询问"
  fi
  dec="$(tr_webui_decision)"
  if [[ "$dec" == "trguing" || "$dec" == "official" ]]; then
    c_info "Transmission 界面沿用上次选择：$dec（改选用 --tr-webui=trguing|official --redo=09）"
    printf '%s\n' "$dec" > "$(tr_webui_choice_file)"
    return 0
  fi
  # dec=failed（上次下载失败）也允许重新询问，方便联网后重试
  if [[ "${NONINTERACTIVE:-0}" -eq 1 || "${ASSUME_YES:-0}" -eq 1 || ! -r /dev/tty || ! -w /dev/tty ]]; then
    c_info "非交互模式：Transmission 界面按默认【安装中文增强版 TrguiNG】；--tr-webui=official 可切回英文"
    printf 'trguing\n' > "$(tr_webui_choice_file)"
    return 0
  fi
  tty=/dev/tty
  {
    printf '\n────────────────────────────────────────────────────────────\n'
    printf '  [Transmission 界面选择] 中文增强 WebUI（TrguiNG 汉化版）\n'
    printf '  官方自带 WebUI 是英文、功能较简。是否换成简体中文增强界面？\n'
    printf '    · 更多设置：目录分组 / Tracker 二级过滤 / 批量改 tracker /\n'
    printf '      多链接下载 / 字体大小调整 / 分享率精度等\n'
    printf '    · 来源：github.com/jayzcoder/TrguiNG（基于 openscopeproject/TrguiNG，AGPL-3.0）\n'
    printf '    · 只下载 release 里已编译好的静态包（约 349 KB）到外置盘，\n'
    printf '      不在本机 npm/rust 编译；不改 settings.json、不动系统自带 WebUI\n'
    printf '    · 用 Transmission 官方 TRANSMISSION_WEB_HOME 切换，随时可切回英文\n'
    printf '  是否安装中文增强界面？ 直接回车 / y = 安装，输入 n = 保留官方英文  [Y/n] '
  } > "$tty"
  ans=""
  read -r ans < "$tty" || ans=""
  printf '\n' > "$tty"
  case "${ans,,}" in
    n|no|0)
      printf 'official\n' > "$(tr_webui_choice_file)"
      c_warn "选择保留官方英文界面（下次可用 --tr-webui=trguing --redo=09 改选）" ;;
    *)
      printf 'trguing\n' > "$(tr_webui_choice_file)"
      c_ok "选择安装中文增强界面 TrguiNG 汉化版" ;;
  esac
  return 0
}

# 给 GitHub 下载链接加可选加速前缀（如 https://ghproxy.net/）
gh_mirror_url(){
  local u="$1"
  if [[ -n "${GITHUB_MIRROR:-}" ]]; then
    printf '%s/%s' "${GITHUB_MIRROR%/}" "$u"
  else
    printf '%s' "$u"
  fi
}

# 解析最新中文 WebUI 包的下载地址：
#   ① 用户用 --tr-webui-tag 指定资产名 → 直接拼 release 直链
#   ② 否则查 GitHub releases API，挑第一个 trguing-web*zh*.zip
#   ③ API 不通 → 回落到已知中文版固定直链
tr_webui_resolve_url(){
  local api="https://api.github.com/repos/${TR_WEBUI_REPO}/releases" tmp u asset
  if [[ -n "${TR_WEBUI_TAG:-}" ]]; then
    asset="$TR_WEBUI_TAG"
    [[ "$asset" == trguing-web* ]] || asset="trguing-web-$asset"
    printf 'https://github.com/%s/releases/download/%s/%s.zip' "$TR_WEBUI_REPO" "$asset" "$asset"
    return 0
  fi
  tmp="$(mktemp)"
  if curl -fsSL --connect-timeout 10 --max-time 25 "$api" -o "$tmp" 2>/dev/null; then
    u="$(python3 - "$tmp" <<'PY'
import json, sys
try:
    rels = json.load(open(sys.argv[1], encoding='utf-8'))
    for rel in rels:
        for a in rel.get('assets', []):
            n = a.get('name', '')
            if n.startswith('trguing-web') and 'zh' in n.lower() and n.endswith('.zip'):
                print(a.get('browser_download_url', ''))
                sys.exit(0)
except Exception:
    pass
PY
)" || true
    if [[ -n "$u" ]]; then
      rm -f "$tmp"; printf '%s' "$u"; return 0
    fi
  fi
  rm -f "$tmp"
  c_info "GitHub releases API 不可达，回落到已知中文版：$TR_WEBUI_FALLBACK_ASSET"
  printf '%s' "$TR_WEBUI_FALLBACK_URL"
  return 0
}

# 校验解压产物：WEB_HOME 下必须直接有 index.html + 至少一个 js/css 资源
tr_webui_files_ok(){
  local d="$1" one
  [[ -f "$d/index.html" ]] || return 1
  one="$(find "$d" -maxdepth 3 -type f \( -name '*.js' -o -name '*.css' \) -print -quit 2>/dev/null || true)"
  [[ -n "$one" ]] || return 1
  return 0
}

# 下载 / 解压 / 扁平化 / 落版本记录。成功返回 0；失败返回 1 但【不中止部署】。
tr_webui_install(){
  local dir zipf tmpd idx src url rc=0 marker
  dir="$(tr_webui_dir)"
  mkdir -p "$dir" "$STATE_DIR"
  # 幂等：已完整就位就不重复下载（--redo=09 重跑也很快）
  if tr_webui_files_ok "$dir" && [[ -s "$(tr_webui_version_file)" ]]; then
    c_ok "中文增强 WebUI 已就位：$dir（$(head -1 "$(tr_webui_version_file)" 2>/dev/null || echo 版本未知)）"
    printf 'trguing\n' > "$(tr_webui_choice_file)"
    return 0
  fi
  zipf="$(mktemp)"; tmpd="$(mktemp -d)"
  c_info "开始整合 TrguiNG 中文增强 WebUI → $dir"
  if [[ -n "${TR_WEBUI_ZIP:-}" ]]; then
    if [[ -f "$TR_WEBUI_ZIP" ]]; then
      cp -f "$TR_WEBUI_ZIP" "$zipf" || rc=1
      c_info "使用离线界面包：$TR_WEBUI_ZIP"
    else
      download_show "下载指定的 TrguiNG 界面包" "$(gh_mirror_url "$TR_WEBUI_ZIP")" "$zipf" || rc=1
    fi
  else
    url="$(tr_webui_resolve_url)"
    c_info "界面包地址：$url"
    if ! download_show "下载 TrguiNG 中文增强 WebUI（github.com/$TR_WEBUI_REPO release）" \
         "$(gh_mirror_url "$url")" "$zipf"; then
      if [[ -z "${GITHUB_MIRROR:-}" ]]; then
        c_warn "GitHub 直连失败，自动尝试 ghproxy 镜像一次..."
        rm -f "$zipf"
        if ! download_show "经 ghproxy 下载 TrguiNG 界面包" "https://ghproxy.net/$url" "$zipf"; then rc=1; fi
      else
        rc=1
      fi
    fi
  fi
  if [[ "$rc" -ne 0 || ! -s "$zipf" ]]; then
    rm -rf "$tmpd" "$zipf"
    c_warn "TrguiNG 界面包下载失败（GitHub 不可达？）。★保留官方英文 WebUI，Transmission 仍可正常使用"
    c_warn "离线补装：下载 trguing-web-*-zh-*.zip 后执行"
    c_warn "  sudo bash $SCRIPT_PATH --tr-webui-zip=/路径/xxx.zip --redo=09"
    c_warn "或用加速：--github-mirror=https://ghproxy.net/ --redo=09"
    printf 'failed\n' > "$(tr_webui_choice_file)"
    return 1
  fi
  if ! unzip -q -o "$zipf" -d "$tmpd" 2>/dev/null; then
    rm -rf "$tmpd" "$zipf"
    c_warn "界面包不是有效 zip（可能下到 HTML 错误页）；保留官方英文 WebUI"
    printf 'failed\n' > "$(tr_webui_choice_file)"
    return 1
  fi
  # ★ 扁平化：Transmission 要求 TRANSMISSION_WEB_HOME 下【直接】是 index.html，
  #   而 release 包可能多套一层目录。找到 index.html 所在目录再拷贝其内容。
  idx="$(find "$tmpd" -type f -name index.html -print -quit 2>/dev/null || true)"
  if [[ -z "$idx" ]]; then
    rm -rf "$tmpd" "$zipf"
    c_warn "界面包里没有 index.html，无法作为 WebUI；保留官方英文 WebUI"
    printf 'failed\n' > "$(tr_webui_choice_file)"
    return 1
  fi
  src="$(dirname "$idx")"
  rm -rf "$dir"; mkdir -p "$dir"
  cp -a "$src/." "$dir/" 2>/dev/null || true
  chmod -R a+rX "$dir" 2>/dev/null || true
  if ! tr_webui_files_ok "$dir"; then
    rm -rf "$tmpd" "$zipf"
    c_warn "界面包内容不完整（缺 index.html 或 js/css）；保留官方英文 WebUI"
    printf 'failed\n' > "$(tr_webui_choice_file)"
    return 1
  fi
  marker="$(basename "${TR_WEBUI_ZIP:-$url}" 2>/dev/null || echo TrguiNG-zh)"
  {
    printf 'TrguiNG 汉化版 · %s\n' "$marker"
    printf '来源：https://github.com/%s（上游 %s，AGPL-3.0）\n' "$TR_WEBUI_REPO" "$TR_WEBUI_UPSTREAM"
    printf '安装时间：%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '目录：%s\n' "$dir"
  } > "$(tr_webui_version_file)"
  printf 'trguing\n' > "$(tr_webui_choice_file)"
  c_ok "中文增强 WebUI 整合完成：$dir（index.html 直接位于 WEB_HOME，无嵌套目录）"
  c_info "  首次打开 http://<本机IP>:9091 若仍是英文，按 Ctrl+F5 强刷浏览器缓存"
  rm -rf "$tmpd" "$zipf"
  return 0
}

# 自检 helper：只有「确实选了中文 + 文件齐全 + drop-in 指向它」才算 OK
tr_webui_ok(){
  local d
  [[ "$(tr_webui_decision)" == "trguing" ]] || return 1
  d="$(tr_webui_dir)"
  tr_webui_files_ok "$d" || return 1
  [[ -s "$(tr_webui_version_file)" ]] || return 1
  grep -qF "Environment=TRANSMISSION_WEB_HOME=$d" \
    /etc/systemd/system/transmission-daemon.service.d/10-armbian-nas.conf 2>/dev/null || return 1
  return 0
}

# ---------------------------------------------------------------------------
# ★ Transmission WebUI 403: Forbidden —— 真因与修法（见第二十一章）
#
# 首页卡片是【直连 http://<IP>:9091/】，压根不经过 nginx，所以「nginx 没配好
# 反代」不是 403 的原因。Transmission 自己有两道白名单：
#   ① rpc-whitelist（客户端 IP）
#   ② rpc-host-whitelist（HTTP Host 头）——3.0+ 默认开启，daemon 只认识
#      localhost / 启动时绑定的主机名；用 192.168.6.219:9091 访问时 Host
#      不在表里，直接回 403: Forbidden（正文 "invalid Host header"）。
# 内网自用，两道都关掉。★ daemon 退出会覆写 settings.json，必须停服→改→启服。
# ★ 更要紧的：步骤 09 一旦 done 就会被跳过，真机上「脚本已修、settings.json
#   仍是旧的」照样 403。所以这个函数也由 --repair 与收尾自愈直接调用，
#   不重装、不询问、不改步骤状态。
# ---------------------------------------------------------------------------
tr_settings_fix(){
  local sj="$1"
  [[ -f "$sj" ]] || return 1
  python3 - "$sj" "$BASE" "$PORT_TR" <<'PY'
import json, sys
p, base, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(p, 'r', encoding='utf-8') as f: d = json.load(f)
d['download-dir'] = base + '/downloads/complete'
d['incomplete-dir'] = base + '/downloads/incomplete'
d['incomplete-dir-enabled'] = True
d['watch-dir'] = base + '/downloads/watch'
d['watch-dir-enabled'] = True
d['rpc-port'] = port
d['rpc-bind-address'] = '0.0.0.0'
# ① 客户端 IP 白名单（键必须是【逗号分隔字符串】，写成 list 会被 daemon 忽略）
d['rpc-whitelist-enabled'] = False
d['rpc-whitelist'] = '127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16'
# ② ★ Host 头白名单：用局域网 IP 访问 :9091 报 403 的真正根因
d['rpc-host-whitelist-enabled'] = False
d['rpc-host-whitelist'] = '127.0.0.1,localhost,*'
with open(p, 'w', encoding='utf-8') as f: json.dump(d, f, indent=2, ensure_ascii=False)
PY
}

# 真发一次 HTTP：光看 settings.json 的键不够，200 才算界面能打开
tr_http_code(){
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://127.0.0.1:${PORT_TR}/" 2>/dev/null || echo 000
}
tr_http_ok(){ [[ "$(tr_http_code)" == "200" ]]; }

# 两道白名单是否都已关闭（只读）
tr_settings_ok(){
  local sj="$BASE/transmission/settings.json"
  [[ -f "$sj" ]] || return 1
  python3 - "$sj" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    raise SystemExit(1)
ok = (not d.get('rpc-whitelist-enabled', True)) and (not d.get('rpc-host-whitelist-enabled', True))
raise SystemExit(0 if ok else 1)
PY
}

# 收尾自愈 / --repair：不重装、不询问，只重修配置并验证 WebUI
tr_repair_403(){
  local sj="$BASE/transmission/settings.json"
  [[ -f "$sj" ]] || return 0
  # ★ 幂等：已经 200 且配置正确就【零动作】，不打断正在下载的任务
  if tr_http_ok && tr_settings_ok; then return 0; fi
  c_info "Transmission 配置/WebUI 需要修：停服 → 重写 settings.json → 启服 → 验证"
  systemctl stop transmission-daemon >/dev/null 2>&1 || true
  tr_settings_fix "$sj" || { c_warn "settings.json 重写失败"; systemctl start transmission-daemon >/dev/null 2>&1 || true; return 1; }
  systemctl start transmission-daemon >/dev/null 2>&1 || true
  sleep 2
  if tr_http_ok; then c_ok "Transmission WebUI 已可访问（HTTP 200，403 已消除）"
  else c_warn "Transmission WebUI 仍为 $(tr_http_code)：curl -i http://127.0.0.1:$PORT_TR/ 看正文；journalctl -u transmission-daemon -n 50"; fi
  return 0
}

# 兼容旧调用点（收尾自愈 / --repair 编排）的薄封装：
# 真正的实现统一在 qb_conf_write_auth / qb_auth_ok / qb_auth_heal，
# 避免三套并行的 qB 凭据逻辑写出互相矛盾的字段。
qb_creds_ok(){ qb_auth_ok; }
qb_creds_heal(){ qb_auth_heal; }

# 可选：80 端口统一入口 /transmission/。默认不开，WebUI 直连 :9091。
# ★ 用户贴的配置有三处错，这里全部避开：
#   ① proxy_pass :9091; 缺 http:// 与主机 → nginx -t 直接失败
#   ② proxy_pass http://127.0.0.1:9091/; 【带尾斜杠】会把 /transmission/rpc
#      剥成 /rpc，而 Transmission 的 RPC 端点恰恰叫 /transmission/rpc → 404
#   ③ proxy_set_header Host $host 丢端口，还会再次触发 Host 白名单校验
#   正确写法：不带尾斜杠 + 传 $http_host + ^~ 跳过正则 location。
# 自检 helper：反代片段必须是「不带尾斜杠 + ^~ + $http_host」的正确写法
tr_proxy_ok(){
  local f="$TR_PROXY_SNIPPET"
  [[ -r "$f" ]] || return 1
  grep -q 'location \^~ /transmission/' "$f" || return 1
  grep -qE 'proxy_pass http://127\.0\.0\.1:[0-9]+;' "$f" || return 1
  # 带尾斜杠会把 /transmission/rpc 剥成 /rpc → 必须失败
  grep -qE 'proxy_pass http://127\.0\.0\.1:[0-9]+/;' "$f" && return 1
  grep -qF 'proxy_set_header Host              $http_host;' "$f" || return 1
  nginx -t >/dev/null 2>&1 || return 1
  return 0
}

tr_proxy_apply(){
  [[ "${TR_PROXY:-0}" -eq 1 ]] || return 0
  mkdir -p /etc/nginx/snippets
  cat > "$TR_PROXY_SNIPPET" <<'SNIP'
# armbian-nas：Transmission WebUI 经 80 端口反代（--tr-proxy=1）
# ★ proxy_pass 结尾【不要】加 /，否则 /transmission/rpc 会被剥成 /rpc
location ^~ /transmission/ {
    proxy_pass http://127.0.0.1:__PORT_TR__;
    proxy_http_version 1.1;
    proxy_set_header Host              $http_host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_redirect off;
    proxy_buffering off;
}
SNIP
  sed -i "s|__PORT_TR__|$PORT_TR|g" "$TR_PROXY_SNIPPET"
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx >/dev/null 2>&1 || true
    c_ok "Transmission 反代已启用：http://<本机IP>/transmission/（直连 :$PORT_TR 仍可用）"
  else
    c_warn "nginx -t 未通过，反代未生效；检查 $TR_PROXY_SNIPPET"
  fi
}

step_tr(){
  remove_legacy_bt_container transmission "$BASE/transmission"

  apt_install transmission-daemon
  command -v transmission-daemon >/dev/null 2>&1 || die "transmission-daemon 安装失败（--redo=09 重试）"
  mkdir -p "$BASE/transmission" "$BASE/webui/transmission" \
           "$BASE/downloads/complete" "$BASE/downloads/incomplete" "$BASE/downloads/watch"

  # 1) WebUI 静态文件 → 外置盘
  local src="" d webhome="" webui_ext=0
  for d in /usr/share/transmission/web /usr/share/transmission/public_html \
           /usr/share/transmission/webui; do
    [[ -f "$d/index.html" ]] && { src="$d"; break; }
  done
  if [[ -n "$src" ]]; then
    cp -a "$src/." "$BASE/webui/transmission/" 2>/dev/null || true
    if [[ -f "$BASE/webui/transmission/index.html" ]]; then
      webui_ext=1; webhome="$BASE/webui/transmission"
    fi
  fi
  if [[ "$webui_ext" -eq 1 ]]; then
    c_ok "Transmission WebUI 静态文件已外置：$src → $webhome"
  else
    webhome="${src:-/usr/share/transmission/web}"
    c_warn "未找到可复制的 Transmission WebUI 文件，改用系统路径 $webhome"
  fi

  # 1.5) ★ 中文增强 WebUI（TrguiNG 汉化版）：交互选择，只改 TRANSMISSION_WEB_HOME
  #      选 y 会把 webhome 换成 $BASE/webui/trguing-zh；下载失败自动回退官方英文。
  tr_webui_ask
  case "$(tr_webui_decision)" in
    trguing)
      if tr_webui_install; then
        webhome="$(tr_webui_dir)"
        c_ok "Transmission 将使用中文增强界面：http://$(lan_ip):9091 → $webhome"
      else
        c_warn "中文界面未启用，TRANSMISSION_WEB_HOME 仍指向官方英文界面：$webhome"
      fi ;;
    official)
      c_info "Transmission 保留官方英文 WebUI：$webhome" ;;
    *)
      c_info "Transmission 使用官方英文 WebUI：$webhome" ;;
  esac

  # ★ TRANSMISSION_WEB_HOME 指向的目录必须有 index.html；空目录/解压层级不对时
  #   daemon 也会返回 403/404，与 nginx 无关。显式校验并回退官方界面。
  if [[ ! -f "$webhome/index.html" ]]; then
    c_warn "★ WebUI 目录 $webhome 没有 index.html（会 403/404），回退系统官方界面"
    webhome="${src:-/usr/share/transmission/web}"
    [[ -f "$webhome/index.html" ]] || webhome="/usr/share/transmission/web"
  fi

  # 2) settings.json 也放外置盘（先停服务，避免退出时覆写）
  systemctl stop transmission-daemon 2>/dev/null || true
  local sj="$BASE/transmission/settings.json"
  if [[ ! -f "$sj" && -f /etc/transmission-daemon/settings.json ]]; then
    cp -a /etc/transmission-daemon/settings.json "$sj"
  fi
  # ★ 停服后写，避免 daemon 退出时把改动覆写回去
  if tr_settings_fix "$sj"; then
    c_info "  settings.json 已写入：rpc-whitelist / rpc-host-whitelist 均关闭（消除 403）"
  else
    c_warn "未找到 settings.json 模板，Transmission 首次启动会自行生成；稍后自动补修"
  fi


  # 3) drop-in：自定义 config-dir + WebUI 目录（systemd 环境变量，官方支持）
  #    $webhome 此时可能是【中文增强界面目录】或【官方英文界面目录】，由 1.5) 决定。
  mkdir -p /etc/systemd/system/transmission-daemon.service.d
  cat > /etc/systemd/system/transmission-daemon.service.d/10-armbian-nas.conf <<EOF
[Service]
User=root
Group=root
Environment=TRANSMISSION_WEB_HOME=$webhome
ExecStart=
ExecStart=/usr/bin/transmission-daemon -f --log-error -g $BASE/transmission
Restart=on-failure
RestartSec=5
EOF
  systemctl daemon-reload
  systemctl enable --now transmission-daemon >/dev/null 2>&1 || systemctl enable --now transmission-daemon
  svc_active transmission-daemon && c_ok "transmission-daemon 服务已运行" \
    || c_warn "transmission-daemon 未 active，请 journalctl -u transmission-daemon -n 50"
  sleep 2
  if tr_http_ok; then
    c_ok "Transmission WebUI HTTP 200（无 403）"
  else
    c_warn "★ WebUI 返回 HTTP $(tr_http_code)：403 多半是 Host 头白名单，不是 nginx 反代"
    tr_repair_403
  fi
  tr_proxy_apply
  c_ok "Transmission 原生安装完成：WebUI http://$(lan_ip):9091（界面：$(
        case "$(tr_webui_decision)" in trguing) echo 'TrguiNG 中文增强版' ;; *) echo '官方英文' ;; esac)）"
  c_info "  配置 $sj · 下载 $BASE/downloads/complete · WebUI $webhome"
  if [[ "$(tr_webui_decision)" == "trguing" ]]; then
    c_info "  中文界面来源：github.com/$TR_WEBUI_REPO（上游 $TR_WEBUI_UPSTREAM，AGPL-3.0）"
    c_info "  切回英文：sudo bash $SCRIPT_PATH --tr-webui=official --redo=09"
  fi
}

step_aria2(){
  apt_install aria2 unzip
  local secret; secret="$(secret_get ARIA_RPC_SECRET)"
  mkdir -p "$BASE/aria2" "$BASE/downloads/aria2" "$WEB_ROOT/ariang"
  touch "$BASE/aria2/aria2.session"
  cat > "$BASE/aria2/aria2.conf" <<EOF
# armbian-nas aria2 配置（文件本身也在非系统盘）
dir=$BASE/downloads/aria2
enable-rpc=true
rpc-listen-all=false
rpc-listen-port=6800
rpc-secret=$secret
rpc-allow-origin-all=true
rpc-max-request-size=8M
continue=true
input-file=$BASE/aria2/aria2.session
save-session=$BASE/aria2/aria2.session
save-session-interval=60
max-concurrent-downloads=5
max-connection-per-server=8
split=8
min-split-size=4M
disk-cache=16M
file-allocation=none
log=$BASE/logs/aria2.log
log-level=warn
EOF
  cat > /etc/systemd/system/aria2.service <<EOF
[Unit]
Description=aria2 (armbian-nas)
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/aria2c --conf-path=$BASE/aria2/aria2.conf
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now aria2
  sleep 2
  port_open 6800 || c_warn "aria2 RPC 6800 暂未监听，请 journalctl -u aria2 查看"

  # AriaNg 静态页：优先本地 zip → 官方 release → 每日构建
  local zip ok=0 tmp src u
  tmp="$(mktemp -d)"
  if [[ -n "$ARIA_NG_ZIP" && -f "$ARIA_NG_ZIP" ]]; then
    zip="$ARIA_NG_ZIP"
  else
    zip="$tmp/ariang.zip"
    for u in \
      "https://github.com/mayswind/AriaNg/releases/download/1.3.7/AriaNg-1.3.7.zip" \
      "https://github.com/mayswind/AriaNg-DailyBuild/archive/master.zip"; do
      if curl -fL --retry 2 --connect-timeout 10 -o "$zip" "$u"; then ok=1; break; fi
    done
  fi
  if [[ -f "$zip" ]] && unzip -q -o "$zip" -d "$tmp/unpack" 2>/dev/null; then
    src="$(find "$tmp/unpack" -type f -name index.html -printf '%h\n' 2>/dev/null | head -1 || true)"
    if [[ -n "$src" && -d "$src" ]]; then
      cp -a "$src/." "$WEB_ROOT/ariang/"
      ok=1
      c_ok "AriaNg 静态页已部署到 $WEB_ROOT/ariang/"
    else ok=0; fi
  fi
  if [[ "$ok" -eq 0 || ! -f "$WEB_ROOT/ariang/index.html" ]]; then
    cat > "$WEB_ROOT/ariang/index.html" <<EOF
<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>AriaNg</title>
<body style="font:16px/1.8 system-ui;max-width:700px;margin:40px auto">
<h2>AriaNg 静态页未自动下载成功</h2>
<p>aria2 服务本身已经可用。请手动下载
<a href="https://github.com/mayswind/AriaNg/releases">AriaNg Release</a> 解压到
<code>$WEB_ROOT/ariang/</code>，或下载 zip 后重跑：
<code>sudo bash $SCRIPT_PATH --aria-ng-zip=/路径/AriaNg.zip --redo=10</code></p>
<p>RPC 地址：<code>http://$(lan_ip)/jsonrpc</code>；密钥见 <code>$SECRETS_FILE</code></p>
</body></html>
EOF
    c_warn "AriaNg 自动下载失败，已放置说明页；服务不受影响"
  fi
  rm -rf "$tmp"
  c_ok "aria2 RPC 密钥已写入 $SECRETS_FILE；AriaNg：http://$(lan_ip)/ariang/ （RPC 填 http://$(lan_ip)/jsonrpc）"
}

step_shares(){
  local mp cands=() d chosen=() i items=() line picked=""
  if [[ -f "$SHARES_FILE" && "$RESELECT" -eq 0 ]]; then
    mapfile -t chosen < <(grep -v '^\s*$' "$SHARES_FILE" 2>/dev/null || true)
    if (( ${#chosen[@]} > 0 )); then
      c_ok "复用上次选择的共享目录（$SHARES_FILE）；换目录用 --reselect 或 --shares=... --redo=11"
      printf '       %s\n' "${chosen[@]}"
      return 0
    fi
  fi
  if [[ -n "$SHARE_DIRS" ]]; then
    mapfile -t chosen < <(printf '%s\n' "$SHARE_DIRS" | tr ',' '\n' | sed '/^\s*$/d')
  else
    # ★★ 真机修复：旧逻辑把所有盘的「关键词命中」混在一起判断，
    #    只要 sda1 命中一个目录，`${#chosen[@]} == 0` 就不成立，
    #    于是 sdb1 上名字不含关键词的目录【整块盘被跳过】，smb.conf 里
    #    永远只有一块盘。现在改成【每块盘独立判定、独立兜底】：
    #      本盘命中关键词目录 → 用它们；
    #      本盘一个都没命中   → 取本盘一级目录；
    #      本盘连一级目录都没有 → 至少共享挂载点本身。
    #    这样 /mnt/sda1 与 /mnt/sdb1 都必然出现在共享清单里。
    for mp in "$MOUNT_MAIN" "$MOUNT_SECOND"; do
      if [[ ! -d "$mp" ]]; then
        c_warn "挂载点不存在，跳过这块盘：$mp（lsblk -f 确认盘符）"
        continue
      fi
      local disk_hits=()
      mapfile -t cands < <(find "$mp" -mindepth 1 -maxdepth 2 -type d \
        ! -path '*/.*' ! -name '$RECYCLE.BIN' ! -name 'System Volume Information' \
        ! -name 'lost+found' ! -name 'www' ! -name '.deploy' \
        -print 2>/dev/null | sort -u | head -40)
      for d in "${cands[@]}"; do
        [[ -d "$d" ]] || continue
        if grep -Eiq '(video|视频|电影|影视|movie|media|movies|tv|剧集|蓝光|原盘|下载|download|4k|hdr|蓝光原盘|动画|纪录片)' \
             <<< "$(basename "$d")"; then
          disk_hits+=("$d")
        fi
      done
      if (( ${#disk_hits[@]} == 0 )); then
        mapfile -t cands < <(find "$mp" -mindepth 1 -maxdepth 1 -type d \
          ! -name '.*' ! -name '$RECYCLE.BIN' ! -name 'System Volume Information' \
          ! -name 'lost+found' ! -name 'www' -print 2>/dev/null | sort -u | head -8)
        for d in "${cands[@]}"; do
          [[ -d "$d" ]] && disk_hits+=("$d")
        done
      fi
      # 本盘实在没有子目录，就共享挂载点本身（保证这块盘不缺席）
      (( ${#disk_hits[@]} > 0 )) || disk_hits+=("$mp")
      c_info "  $mp → 候选 ${#disk_hits[@]} 个：$(printf '%s ' "${disk_hits[@]}")"
      for d in "${disk_hits[@]}"; do chosen+=("$d"); done
    done
    # ★★ 交互勾选（修掉「界面从未出现过」的老缺陷）：
    #    原来要求 [[ -t 0 && -t 1 ]]，但 main 里 exec > >(tee ...) 已把 fd1
    #    变成管道，-t 1 恒为假 → 这个分支永远不进，共享目录只能吃自动匹配结果。
    #    现在改用 main 在重定向前算好的全局 NAS_INTERACTIVE。
    #    另外 whiptail 的 UI 画在 stdout、结果写在 stderr（默认是 2），
    #    所以即使进了分支，若 fd1 仍是 tee 管道，界面会被写进日志里看不到。
    #    这里把 fd 显式钉到 /dev/tty：
    #      3>&1        先保存命令替换的「捕获管道」到 fd3
    #      1>$NAS_TTY  UI 画到真终端（绕开 tee 管道）
    #      2>&3        结果写回捕获管道 → picked
    #      <$NAS_TTY   键盘输入来自真终端（curses 需要）
    #    不依赖 --output-fd，兼容所有 whiptail/newt 版本。
    if (( ${#chosen[@]} > 0 )) && [[ "${NAS_INTERACTIVE:-0}" -eq 1 && "$NONINTERACTIVE" -eq 0 ]] \
        && command -v whiptail >/dev/null; then
      items=()
      for d in "${chosen[@]}"; do items+=("$d" "" "ON"); done
      if picked="$(whiptail --title 'armbian-nas 共享目录' \
          --checklist '空格勾选要共享给 MiniDLNA / Samba 的视频目录（同网段播放器会发现 armbian-nas）' \
          22 100 $(( ${#chosen[@]} > 18 ? 18 : (${#chosen[@]} > 0 ? ${#chosen[@]} : 8) )) \
          --separate-output "${items[@]}" \
          3>&1 1>"$NAS_TTY" 2>&3 <"$NAS_TTY")"; then
        mapfile -t chosen <<< "$picked"
        c_ok "交互勾选完成：共 ${#chosen[@]} 个共享目录"
      else
        c_warn "已取消交互选择，沿用自动匹配结果"
      fi
    fi
  fi
  # 去重 + 校验
  local uniq=() seen=" "
  for d in "${chosen[@]}"; do
    d="${d%\"}"; d="${d#\"}"
    d="${d#"${d%%[![:space:]]*}"}"; d="${d%"${d##*[![:space:]]}"}"
    [[ -d "$d" ]] || { c_warn "目录不存在，跳过：$d"; continue; }
    if [[ "$seen" == *" $d "* ]]; then continue; fi
    seen="$seen$d "; uniq+=("$d")
  done
  chosen=("${uniq[@]}")
  if (( ${#chosen[@]} == 0 )); then
    mkdir -p "$BASE/video"
    chosen=("$BASE/video")
    c_warn "未找到可共享的视频目录，已新建 $BASE/video；请把影片放进去，或用 --shares='/mnt/sda1/电影,/mnt/sdb1/影视' --redo=11 指定"
  fi
  printf '%s\n' "${chosen[@]}" > "$SHARES_FILE"
  c_ok "已选择 ${#chosen[@]} 个共享目录："
  printf '       %s\n' "${chosen[@]}"
  c_info "清单：$SHARES_FILE（MiniDLNA 与 Samba 都读它）"
}

read_shares(){ mapfile -t SHARE_LIST < <(grep -v '^\s*$' "$SHARES_FILE" 2>/dev/null || true); }

step_minidlna(){
  apt_install minidlna
  read_shares
  (( ${#SHARE_LIST[@]} > 0 )) || die "共享目录清单为空，请先完成步骤 11"
  local media="" d ip iface bak
  for d in "${SHARE_LIST[@]}"; do media+="media_dir=V,$d"$'\n'; done
  ip="$(lan_ip)"; iface="$(lan_ifaces)"; [[ -n "$iface" ]] || iface="eth0"
  bak="/etc/minidlna.conf.bak.armbian-nas"; [[ -f "$bak" ]] || cp /etc/minidlna.conf "$bak" 2>/dev/null || true
  cat > /etc/minidlna.conf <<EOF
# armbian-nas 媒体库（同网段 DLNA/UPnP 播放器搜索 "armbian-nas"）
friendly_name=armbian-nas
network_interface=$iface
port=8200
${media}db_dir=$BASE/minidlna/db
log_dir=$BASE/logs
log_level=general,artwork,database,inotify,scanner,metadata,http,ssdp,tivo=warn
inotify=yes
notify_interval=895
presentation_url=http://$ip:8200/
EOF
  mkdir -p "$BASE/minidlna/db" "$BASE/logs"
  systemctl enable --now minidlna
  systemctl restart minidlna
  sleep 2
  svc_active minidlna || c_warn "minidlna 服务未 active，请 journalctl -u minidlna 查看（常见原因：NTFS 权限）"
  c_ok "MiniDLNA：friendly_name=armbian-nas，端口 8200，只索引 V(视频)"
  c_info "播放器需与主机同网段/同广播域；跨 VLAN、AP 隔离会挡住 SSDP 发现"
}

step_samba(){
  apt_install samba
  read_shares
  (( ${#SHARE_LIST[@]} > 0 )) || die "共享目录清单为空，请先完成步骤 11"
  local blocks="" d i=0 ro="yes" bak iface iface_sp
  if [[ "$SMB_WRITABLE" -eq 1 ]]; then ro="no"; fi
  iface="$(lan_ifaces)"; [[ -n "$iface" ]] || iface="eth0"
  iface_sp="${iface//,/ }"
  for d in "${SHARE_LIST[@]}"; do
    i=$((i+1))
    blocks+="$(printf '\n[video-%02d]\n   comment = %s\n   path = %s\n   browseable = yes\n   read only = %s\n   guest ok = yes\n   force user = root\n   create mask = 0666\n   directory mask = 0777\n' "$i" "$d" "$d" "$ro")"$'\n'
  done
  bak="/etc/samba/smb.conf.bak.armbian-nas"; [[ -f "$bak" ]] || cp /etc/samba/smb.conf "$bak" 2>/dev/null || true
  # ★★ 真机修复：用户「已经装好配置好、只是重新运行脚本时点了跳过」，
  #    旧版仍然无条件 `cat > smb.conf` 覆盖并重启服务。现在先写临时文件，
  #    与现有配置逐字节比对：完全一致就【不覆盖、不重启】，明确保持原样。
  #    共享清单（含第二块盘）真的变了才重建，避免无谓地打断 Samba 连接。
  local _smb_tmp; _smb_tmp="$(mktemp)"
  cat > "$_smb_tmp" <<EOF
# armbian-nas 自动生成（原文件已备份为 $bak；如原有自定义共享请手工合并）
[global]
   workgroup = WORKGROUP
   server string = armbian-nas
   netbios name = armbian-nas
   security = user
   map to guest = Bad User
   guest account = nobody
   log file = $BASE/logs/samba/log.%m
   max log size = 1000
   logging = file
   panic action = /usr/share/samba/panic-action %d
   server role = standalone server
   obey pam restrictions = yes
   unix password sync = no
   dns proxy = no
   interfaces = 127.0.0.0/8 $iface_sp
   bind interfaces only = no
$blocks
EOF
  mkdir -p "$BASE/logs/samba"
  if [[ -f /etc/samba/smb.conf ]] && cmp -s "$_smb_tmp" /etc/samba/smb.conf; then
    rm -f "$_smb_tmp"
    c_ok "smb.conf 与本次清单完全一致（${#SHARE_LIST[@]} 个共享，含所有外置盘）→ 保持原样，不重写、不重启"
    c_info "  共享清单：$SHARES_FILE；要换目录用 --shares='...' --redo=11 或 --reselect --redo=11"
    return 0
  fi
  mv -f "$_smb_tmp" /etc/samba/smb.conf
  testparm -s >/dev/null 2>&1 || die "smb.conf 语法检查未通过（testparm）"
  systemctl enable --now smbd
  systemctl enable --now nmbd 2>/dev/null || true
  systemctl restart smbd
  sleep 2
  svc_active smbd || c_warn "smbd 未 active，请 testparm -s 与 journalctl -u smbd 查看"
  c_ok "Samba 共享 ${#SHARE_LIST[@]} 个目录，read only=$ro，访问 \\\\$(lan_ip)\\"
  c_warn "NTFS 权限由 fstab 的 uid/gid/umask 统一映射，请勿对电影目录 chmod -R / chown -R"
}

# ---------------------------------------------------------------------------
# 把自由文本清洗成可安全写进「会被 source 的配置文件」的双引号值。
# 去掉反斜杠 / 双引号 / $ / 反引号即可，剩下的空格、中文、括号、★ 在双引号内都合法。
# 不这么做的话，FAN_PIN_DESC=J9 Pin35 GPIOAO_3（用户实测）被 source 时，
# shell 会去执行 Pin35 这条「命令」，温控服务或 --fan-probe-apply 直接失败。
shell_quote_safe(){
  local s="$1"
  s="${s//\\/}"; s="${s//\"/}"; s="${s//\$/}"; s="${s//\`/}"
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# 板型识别：比特米盒刷的是 Khadas VIM1 的 Armbian 镜像，两者同为 Amlogic S905X。
# 只做「读字符串」的静态识别，绝不访问任何 GPIO，也不扫描线号。
# 依据：/etc/armbian-release（BOARD_NAME/BOARDFAMILY）、设备树 compatible、主机名。
# ---------------------------------------------------------------------------
board_is_s905x(){
  local t=" "
  [[ -r /etc/armbian-release ]] && t+=" $(tr 'A-Z' 'a-z' < /etc/armbian-release 2>/dev/null) "
  if [[ -r /proc/device-tree/compatible ]]; then
    t+=" $(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null | tr 'A-Z' 'a-z') "
  fi
  [[ -r /boot/uEnv.txt ]] && t+=" $(tr 'A-Z' 'a-z' < /boot/uEnv.txt 2>/dev/null) "
  [[ -r /boot/armbianEnv.txt ]] && t+=" $(tr 'A-Z' 'a-z' < /boot/armbianEnv.txt 2>/dev/null) "
  t+=" $(hostname 2>/dev/null | tr 'A-Z' 'a-z') "
  # 比特米盒别名很多：私家云二代 / CumeBox2 / cumebox2；ophub 镜像常用 p212 的 dtb。
  case "$t" in
    *s905x*|*vim1*|*"khadas vim"*|*bitemi*|*比特米*|*私家云*|*cumebox*|*p212*|*meson-gxl*|*s905*) return 0 ;;
    *) return 1 ;;
  esac
}

# libgpiod 大版本：v1 用 --mode=wait；v2 已移除 --mode，改 -c 且默认常驻。
fan_gpiod_major(){
  local v
  [[ "$FAN_GPIOD_MAJOR" == "1" || "$FAN_GPIOD_MAJOR" == "2" ]] && { echo "$FAN_GPIOD_MAJOR"; return 0; }
  v="$(gpioset --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)"
  [[ "$v" == "2" ]] && echo 2 || echo 1
}

# sysfs GPIO 接口是否可用（新内核可能整个移除 /sys/class/gpio）。
# 单独抽成函数，便于在测试桩里覆盖，也避免在多处重复写硬编码路径判断。
fan_sysfs_available(){
  [[ -d /sys/class/gpio && ( -w /sys/class/gpio/export || -d /sys/class/gpio/gpiochip0 ) ]]
}

# 运行期决定用哪套 GPIO 映射。三套互斥、取决于 dtb；★本机已实测，auto 不再猜编号。
# auto 规则（优先级从高到低）：
#   1) 显式 --fan-on-cmd/--fan-off-cmd → custom
#   2) --fan-confirmed=N               → sysfs（用户已人工测过，直接采用编号 N）
#   3) 显式 --fan-mode=xxx             → 原样采用（sysfs504/sysfs_legacy 归一为 sysfs）
#   4) 有两轮确认的实测结果文件       → 按记录来
#   5) S905X + /sys/class/gpio 可用   → sysfs，编号默认【515】（fan.sh 实测，不联动 LED）
#   6) S905X + 仅有 gpioset           → libgpiod（另一套 dtb 的备选）
#   7) 其它板型按 --fan-pwm-chip / --fan-gpio 的老逻辑
# 任何情况都不会自动逐线扫描 GPIO。
fan_mode_resolve(){
  local s905=0 sysfs=0 gset=0
  board_is_s905x && s905=1
  fan_sysfs_available && sysfs=1
  command -v gpioset >/dev/null 2>&1 && gset=1
  if [[ -n "$FAN_ON_CMD" && -n "$FAN_OFF_CMD" ]]; then echo custom; return 0; fi
  # ① 用户已用 fan.sh 实测并传了 --fan-confirmed=N → 直接用 sysfs，不再猜
  if [[ -n "$FAN_CONFIRMED_PIN" ]]; then echo sysfs; return 0; fi
  # ② 显式 --fan-mode：把旧别名归一到统一的 sysfs 模式（编号由 FAN_SYSFS_FAN 决定）
  if [[ "$FAN_MODE" != "auto" ]]; then
    case "$FAN_MODE" in sysfs504|sysfs_legacy) echo sysfs; return 0 ;; esac
    echo "$FAN_MODE"; return 0
  fi
  # ③ 有针脚实测结果文件 → 按记录来（两轮确认都通过才存在）
  local pf="$FAN_PROBE_FILE"
  [[ -r "$pf" ]] || pf="$MIRROR_DIR/fan-probe.env"
  if [[ -r "$pf" ]] && grep -qx 'PROBE_CONFIRMED_OFF=1' "$pf"; then
    echo "$(grep -F 'FAN_MODE=' "$pf" | tail -1 | cut -d= -f2)"; return 0
  fi
  # ④ S905X/VIM1 + sysfs 可用 → 默认用【用户实测的 515】，绝不联动面板灯
  if [[ "$s905" -eq 1 && "$sysfs" -eq 1 ]]; then echo sysfs; return 0; fi
  if [[ "$s905" -eq 1 && "$gset" -eq 1 ]]; then echo libgpiod; return 0; fi
  if [[ -n "$FAN_PWM_CHIP" ]]; then echo pwm; return 0; fi
  if [[ -n "$FAN_GPIO" && "$sysfs" -eq 1 ]]; then echo sysfs; return 0; fi
  if [[ "$gset" -eq 1 ]]; then echo libgpiod; return 0; fi
  echo none
}

step_fan(){
  mkdir -p "$BASE/logs"
  local mode="" on="" off="" on_q="" off_q="" configured=1 gmaj=""
  local pwmdir pwm gp gpoff led_eff=0

  mode="$(fan_mode_resolve)"
  # --fan-confirmed / 实测记录 / --fan-gpio 都把编号统一写到 FAN_SYSFS_FAN
  [[ -n "$FAN_CONFIRMED_PIN" ]] && FAN_SYSFS_FAN="$FAN_CONFIRMED_PIN"
  c_info "风扇控制方式探测结果：$mode，sysfs 全局编号 gpio$FAN_SYSFS_FAN（$FAN_PIN_DESC）"
  c_info "  三套映射互斥：515(本机实测) / 504(p212 dtb+面板灯) / libgpiod line3"

  case "$mode" in
    custom)
      on="$FAN_ON_CMD"; off="$FAN_OFF_CMD"
      c_info "使用用户自定义命令（优先级最高）"
      ;;
    sysfs|sysfs504|sysfs_legacy)
      # 统一 sysfs 模式：编号由 FAN_SYSFS_FAN 决定（默认 515 = 用户实测）。
      # 走温控脚本里的 fan_sysfs_set()：export → direction=out → value=开/关电平。
      # sysfs 是内核态保持电平，不需要 libgpiod 那种常驻进程。
      if ! fan_sysfs_available; then
        c_warn "/sys/class/gpio 不存在（新内核已移除 sysfs GPIO），请改用 --fan-mode=libgpiod"
        configured=0
      else
        local on_lv="$FAN_ACTIVE_HIGH" off_lv=$((1-FAN_ACTIVE_HIGH))
        # ★ 默认绝不联动面板灯：只有显式 --fan-led=on，或编号=504 且 --fan-led=auto
        #   才动 474/476/477。515 这套 dtb 下那些编号是别的线，误写有风险。
        if [[ "$FAN_LED" == "on" ]] || \
           [[ "$FAN_LED" == "auto" && "$FAN_SYSFS_FAN" == "504" ]]; then led_eff=1; fi
        on="fan_sysfs_set $on_lv"; off="fan_sysfs_set $off_lv"
        c_ok "选用 sysfs：gpio$FAN_SYSFS_FAN（$FAN_PIN_DESC）；高电平=$FAN_ACTIVE_HIGH；面板灯联动=$led_eff"
        if [[ "$FAN_SYSFS_FAN" == "515" ]]; then
          c_ok "  ✔ 与你的 fan.sh 实测一致：拉高 515 = 风扇转，拉低 = 风扇停"
          c_info "  引脚：J9 排针 Pin35 / GPIOAO_3 / AO 域 base=512+3"
          c_warn "  ⚠ 这套 dtb 下 474/476/477 不是面板灯 → 已默认关闭联动，别去写它们"
        fi
        if [[ "$led_eff" -eq 1 ]]; then
          c_info "  面板灯 蓝=$FAN_LED_BLUE 红=$FAN_LED_RED 绿=$FAN_LED_GREEN"
        fi
        if [[ "$FAN_ACTIVE_HIGH" == "0" ]]; then
          c_warn "  ⚠ 低电平触发模式：开=写 0 / 关=写 1（fan.sh 提示的反相情况）"
        fi
        c_warn "  ⚠ 换 dtb 后编号会变：504 用 --fan-sysfs-fan=504 --fan-led=on --redo=14；"
        c_warn "     libgpiod 用 --fan-mode=libgpiod --fan-gpio-chip=gpiochip0 --fan-gpio-line=3 --redo=14"
        c_warn "  ⚠⚠ 严禁测试 gpiochip1 的【line 70~80】（会掉线需拔电）；脚本绝不自动扫描"
      fi
      ;;
    libgpiod)
      if ! command -v gpioset >/dev/null 2>&1; then
        apt_install_quiet gpiod || true
      fi
      if ! command -v gpioset >/dev/null 2>&1; then
        c_warn "gpioset 不可用（gpiod 装不上？），风扇保持待配置，不会乱拉 GPIO"
        configured=0
      else
        gmaj="$(fan_gpiod_major)"
        on="fan_gpio_set $FAN_ACTIVE_HIGH"
        off="fan_gpio_set $((1-FAN_ACTIVE_HIGH))"
        c_ok "选用 libgpiod：$FAN_GPIO_CHIP line $FAN_GPIO_LINE（v$gmaj）"
        c_info "  v1 用 --mode=wait 常驻；v2 用 -c 且默认常驻（脚本自动适配）"
        c_warn "  ⚠ 不同批次引脚不同；若风扇不转先 systemctl stop armbian-fan 再改线号"
        c_warn "  ⚠⚠ 严禁测试 gpiochip1 的 70~80 线号（会掉线需拔电）；脚本绝不自动扫描"
      fi
      ;;

    pwm)
      pwmdir="/sys/class/pwm/$FAN_PWM_CHIP"
      pwm="$pwmdir/pwm$FAN_PWM_CHANNEL"
      on="sh -c '[ -d $pwm ] || echo $FAN_PWM_CHANNEL > $pwmdir/export; echo 1000000 > $pwm/period; echo 1000000 > $pwm/duty_cycle; echo 1 > $pwm/enable'"
      off="sh -c 'echo 0 > $pwm/duty_cycle; echo 0 > $pwm/enable'"
      c_warn "标准 PWM 模式（比特米盒/S905X 无 PWM 驱动，此模式在本机无效）"
      ;;
    *)
      configured=0
      c_warn "没能自动确定风扇控制方式，服务写好但不启用，避免乱拉 GPIO 烧板"
      ;;
  esac
  [[ "$configured" -eq 1 ]] || { on="true"; off="true"; }

  printf -v on_q '%q' "$on"
  printf -v off_q '%q' "$off"
  cat > /etc/default/armbian-fan <<EOF
# armbian-nas 风扇温控配置；改完执行：systemctl restart armbian-fan
# 比特米盒 / Khadas VIM1 (S905X)：风扇不走 PWM，走 GPIO。
# 本机实测（fan.sh）：风扇 = sysfs 全局 515 / GPIOAO_3 / J9 Pin35，高=开低=关。
# 三套互斥映射：sysfs515(本机) / sysfs504(p212 dtb+面板灯) / libgpiod line3。
FAN_CONFIGURED=$configured
FAN_MODE=$mode
FAN_MODE_EFF=${mode/sysfs504/sysfs}
FAN_SYSFS_FAN=$FAN_SYSFS_FAN
FAN_PIN_DESC="$(shell_quote_safe "$FAN_PIN_DESC")"
FAN_GPIO_CHIP=$FAN_GPIO_CHIP
FAN_GPIO_LINE=$FAN_GPIO_LINE
FAN_GPIOD_MAJOR=${gmaj:-1}
FAN_ACTIVE_HIGH=$FAN_ACTIVE_HIGH
FAN_LED_BLUE=$FAN_LED_BLUE
FAN_LED_RED=$FAN_LED_RED
FAN_LED_GREEN=$FAN_LED_GREEN
FAN_LED_EFF=$led_eff
FAN_FAILSAFE=$FAN_FAILSAFE
FAN_ON_TEMP=$FAN_ON_TEMP
FAN_OFF_TEMP=$FAN_OFF_TEMP
FAN_POLL=$FAN_POLL
FAN_MIN_RUN=$FAN_MIN_RUN
FAN_TEMP_FILE=$FAN_TEMP_FILE
FAN_LOG=$BASE/logs/fan.log
FAN_ON_CMD=$on_q
FAN_OFF_CMD=$off_q
EOF

  # ---------------------------------------------------------------------------
  # 温控主脚本。本轮全面检查修掉的 4 个真实问题：
  #   ① 原来 state=off 却从不下发 OFF —— 若上电风扇默认转，就会一直转。
  #      现在启动强制调用一次 FAN_OFF_CMD，把初始状态钉死。
  #   ② 原来所有温度源读不到时 read_temp 返回 0，风扇永远不开且无告警。
  #      现在统计有效源数量，连续 3 次为 0 就 fail-safe 开风扇（散热优先）+ ERROR 日志。
  #      ★★ 致命坑（本轮修）：温度值/源数量【必须用全局变量返回】，绝不能写
  #         `t="$(read_temp)"` —— 命令替换会在【子 shell】里执行，函数里对
  #         TEMP_SRC_N 的赋值传不回父进程，父 shell 恒读到 0，于是
  #         `if (( nsrc == 0 || t <= 0 ))` 永远成立：15 秒后强制开风扇且
  #         再也进不了 else 分支 → 风扇永远转、温控彻底失效、日志刷 FAILSAFE。
  #   ③ 原来 eval 命令失败仍标记 state=on，属于「假装成功」。
  #      现在检查返回码，失败记 ERROR 且不改状态。
  #   ④ 原来退出只释放 libgpiod line，sysfs 模式风扇可能保持转。
  #      现在 sysfs 模式退出时显式关风扇并切绿灯。
  # ---------------------------------------------------------------------------
  cat > /usr/local/sbin/armbian-fan-control <<'FANSH'
#!/usr/bin/env bash
# 读取 /etc/default/armbian-fan；温度 >= ON 开，<= OFF 关，带滞回与最短运行时间。
set -u
source /etc/default/armbian-fan
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >> "${FAN_LOG:-/var/log/armbian-fan.log}"; }

# ---- A) sysfs 全局编号（sysfs504 / sysfs_legacy）---------------------------
# 网上脚本用 `echo high > direction` 同时设方向+初始电平，这是 Linux sysfs 的
# 简写写法；但它每次都重写 direction 且不便重复切换。这里改成规范做法：
#   export → direction=out → value=1/0
# 面板灯联动：开风扇 蓝/红 high、绿 low；关风扇 蓝/红 low、绿 high。
sysfs_export(){
  # ★★ 真机致命 bug（65℃ 风扇不转的真正根因）：
  #    `local n="$1" d="...gpio$n"` 在【同一行】引用 $n —— bash 先展开整行
  #    再逐个赋值，此刻 n 还没赋值，温控脚本开了 set -u，会直接报
  #    "n: unbound variable" 并退出（systemd Restart 又把它拉起来再崩）。
  #    独立测试脚本没有 set -u，所以「测试能转、部署的服务不转」。
  #    修法：拆成两行，先赋 n 再算 d。
  local n="$1" d
  d="/sys/class/gpio/gpio$n"
  if [[ ! -e "$d/direction" ]]; then
    printf '%s' "$n" > /sys/class/gpio/export 2>/dev/null || return 1
    sleep 0.1
  fi
  [[ -e "$d/value" && -e "$d/direction" ]]
}
sysfs_write(){
  # 同上：local 同一行引用 $n 在 set -u 下会崩，必须拆开
  local n="$1" v="$2" d
  d="/sys/class/gpio/gpio$n"
  sysfs_export "$n" || { log "ERROR export GPIO $n 失败（编号不属于当前 dtb？）"; return 1; }
  if ! grep -qx out "$d/direction" 2>/dev/null; then
    printf 'out' > "$d/direction" 2>/dev/null || { log "ERROR 设 GPIO $n 方向失败"; return 1; }
  fi
  printf '%s' "$v" > "$d/value" 2>/dev/null || { log "ERROR 写 GPIO $n = $v 失败"; return 1; }
}
fan_sysfs_set(){
  local v="$1" rc=0
  sysfs_write "$FAN_SYSFS_FAN" "$v" || rc=1
  if [[ "${FAN_LED_EFF:-0}" == "1" ]]; then
    sysfs_write "$FAN_LED_BLUE"  "$v"        || rc=1
    sysfs_write "$FAN_LED_RED"   "$v"        || rc=1
    sysfs_write "$FAN_LED_GREEN" "$((1-v))"  || rc=1
  fi
  return "$rc"
}

# ---- B) libgpiod 常驻持有 --------------------------------------------------
# gpioset 只在「进程活着」时保证 line 电平；进程退出 line 被内核释放、电平未定义。
# 所以起一个常驻后台进程并记住 PID，切换电平时先杀旧再起新。绝不扫描其它线。
GPIO_PID=""
fan_gpio_set(){
  local v="$1"
  if [[ -n "$GPIO_PID" ]] && kill -0 "$GPIO_PID" 2>/dev/null; then
    kill "$GPIO_PID" 2>/dev/null || true
    wait "$GPIO_PID" 2>/dev/null || true
  fi
  if [[ "${FAN_GPIOD_MAJOR:-1}" -ge 2 ]]; then
    gpioset -c "$FAN_GPIO_CHIP" "$FAN_GPIO_LINE=$v" </dev/null >/dev/null 2>&1 &
  else
    gpioset --mode=wait "$FAN_GPIO_CHIP" "$FAN_GPIO_LINE=$v" </dev/null >/dev/null 2>&1 &
  fi
  GPIO_PID=$!
  sleep 0.3
  if ! kill -0 "$GPIO_PID" 2>/dev/null; then
    log "ERROR gpioset 启动失败（line 可能被占用）：gpioinfo -c $FAN_GPIO_CHIP $FAN_GPIO_LINE"
    GPIO_PID=""
    return 1
  fi
  log "GPIO $FAN_GPIO_CHIP line $FAN_GPIO_LINE = $v (libgpiod v${FAN_GPIOD_MAJOR:-1}, pid=$GPIO_PID)"
}

cleanup(){
  trap - EXIT INT TERM
  if [[ "${FAN_MODE_EFF:-}" == sysfs* ]]; then
    # 关电平由 FAN_ACTIVE_HIGH 取反；sysfs 是内核态保持，服务退出后电平仍在，
    # 所以必须显式关一次。面板灯联动由 FAN_LED_EFF 决定（515 默认 0）。
    fan_sysfs_set $((1-${FAN_ACTIVE_HIGH:-1})) >/dev/null 2>&1 || true
    log "STOP 已显式关闭风扇（sysfs gpio${FAN_SYSFS_FAN}）"
  elif [[ -n "$GPIO_PID" ]] && kill -0 "$GPIO_PID" 2>/dev/null; then
    kill "$GPIO_PID" 2>/dev/null || true
    wait "$GPIO_PID" 2>/dev/null || true
    log "STOP GPIO line 已释放（风扇回到硬件默认状态）"
  else
    log "STOP 温控服务退出"
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

if [[ "${FAN_CONFIGURED:-0}" != "1" ]]; then
  log "ERROR FAN_CONFIGURED=0：风扇针脚还没做过「开→转 / 关→停」两轮人工确认，服务按设计不动作"
  log "       ★ 先跑：sudo bash SCRIPT --fan-probe  （或已实测过就 --fan-confirmed=515 --repair）"
  log "       这是「65℃ 风扇不转」最常见的原因：服务没配置，不是温度读不到、也不是 GPIO 坏"
  exit 0
fi
log "START mode=${FAN_MODE_EFF:-?} on=${FAN_ON_TEMP}C off=${FAN_OFF_TEMP}C poll=${FAN_POLL}s failsafe=${FAN_FAILSAFE:-1}"

# ① 启动时强制关一次，钉死初始状态（修掉「上电默认转就一直转」）
if eval "$FAN_OFF_CMD"; then
  log "INIT 风扇已关闭（初始状态强制下发 OFF）"
else
  log "ERROR 初始关风扇命令执行失败，请检查 GPIO 编号/权限"
fi

# 温度来源：S905X 常见 thermal_zone*/temp（毫摄氏度）、hwmon temp1_input、
# Armbian 的 soctemp。取最大值，并统计有效源数量供 fail-safe 判断。
# ★★ 温度读取的返回通道：两个【全局变量】。
#    绝对不要用 t="$(read_temp)"：命令替换 = 子 shell，函数内对 TEMP_SRC_N
#    的赋值传不回父进程，父 shell 永远看到 0 → 误判「温度源不可用」→
#    fail-safe 永久开风扇、else 分支（正常温控）永远进不去。
#    正确姿势：直接调用 read_temp（同一 shell），随后读 TEMP_VAL / TEMP_SRC_N。
TEMP_VAL=0
TEMP_SRC_N=0
TEMP_DETAIL=""
# ★ 真机修复（6.18 meson64 / Armbian 26.11）：旧版只扫 3 个固定路径，
#   新内核的 hwmon 编号 / thermal_zone 编号会变，容易一个都找不到。
#   现在遍历【所有】hwmon*/temp*_input 与 thermal_zone*/temp，
#   并补 Armbian 新版 soctemp 的多个候选位置。
#   另外把每个源的原始读数记进 TEMP_DETAIL，启动与每 5 分钟写日志，
#   「65℃ 风扇不转」时一眼就能看出到底读没读到温度。
collect_temp_files(){
  TEMP_FILES=()
  local f
  [[ -n "${FAN_TEMP_FILE:-}" && -r "$FAN_TEMP_FILE" ]] && TEMP_FILES+=("$FAN_TEMP_FILE")
  for f in /etc/armbianmonitor/datasources/soctemp \
           /etc/armbianmonitor/datasources/soctemp_mhz \
           /sys/class/thermal/thermal_zone*/temp \
           /sys/devices/virtual/thermal/thermal_zone*/temp \
           /sys/class/hwmon/hwmon*/temp*_input \
           /sys/devices/platform/soc/*/temp*_input; do
    [[ -r "$f" ]] && TEMP_FILES+=("$f")
  done
}
read_temp(){
  local max=0 v raw f
  collect_temp_files
  TEMP_SRC_N=${#TEMP_FILES[@]}
  TEMP_DETAIL=""
  for f in "${TEMP_FILES[@]}"; do
    raw="$(cat "$f" 2>/dev/null | tr -d '\r\n' || true)"
    v="$(awk '{print int($1)}' "$f" 2>/dev/null || echo 0)"
    [[ -z "$v" ]] && v=0
    (( v > 1000 )) && v=$((v/1000))        # 毫摄氏度 → 摄氏度
    # 明显异常的读数（>200℃ 或 < -50℃）直接丢弃，避免坏传感器带偏判断
    if (( v > 200 || v < -50 )); then
      TEMP_DETAIL="${TEMP_DETAIL} [$(basename "$(dirname "$f")")/$(basename "$f")=INVALID($raw)]"
      continue
    fi
    TEMP_DETAIL="${TEMP_DETAIL} [$(basename "$(dirname "$f")")/$(basename "$f")=$raw→${v}C]"
    (( v > max )) && max=$v
  done
  TEMP_VAL="$max"          # 写全局；不 echo、不命令替换
  return 0
}
# 启动时把所有源打印一遍，方便诊断
read_temp
log "TEMP_SCAN src=$TEMP_SRC_N max=${TEMP_VAL}C detail:${TEMP_DETAIL:- <一个温度源都没找到>}"
if (( TEMP_SRC_N == 0 )); then
  log "ERROR 本机没扫到任何温度源。可指定：sudo bash SCRIPT --fan-temp-file=/绝对路径/temp --redo=14"
  log "       常见路径：/sys/class/thermal/thermal_zone0/temp（毫摄氏度）、/etc/armbianmonitor/datasources/soctemp"
fi

state=off; last_on=0; last_log=0; no_temp=0
while true; do
  read_temp                       # ← 直接调用，结果在 TEMP_VAL / TEMP_SRC_N
  t="$TEMP_VAL"; nsrc="$TEMP_SRC_N"; now="$(date +%s)"
  if (( nsrc == 0 || t <= 0 )); then
    # ② 读不到温度：fail-safe 开风扇，绝不默默当 0℃ 处理
    no_temp=$((no_temp+1))
    if (( no_temp >= 3 )) && [[ "${FAN_FAILSAFE:-1}" == "1" ]] && [[ "$state" != "on" ]]; then
      if eval "$FAN_ON_CMD"; then
        state=on; last_on=$now
        log "FAILSAFE 温度源不可用，已强制开启风扇（散热优先）"
      else
        log "ERROR FAILSAFE 开风扇命令执行失败 rc=$? cmd=$FAN_ON_CMD"
      fi
    fi
    (( no_temp % 12 == 0 )) && log "ERROR 温度源仍不可用（连续 $no_temp 次）；检查 /sys/class/thermal/"
  else
    no_temp=0
    if (( t >= FAN_ON_TEMP )); then
      if [[ "$state" != "on" ]]; then
        # ③ 命令失败不标记成功
        if eval "$FAN_ON_CMD"; then state=on; last_on=$now; log "FAN ON  ${t}C"
        else log "ERROR 开风扇命令失败（$t℃）rc=$? cmd=$FAN_ON_CMD，保持当前状态"; fi
      fi
    elif (( t <= FAN_OFF_TEMP )); then
      if [[ "$state" == "on" ]] && (( now - last_on >= FAN_MIN_RUN )); then
        if eval "$FAN_OFF_CMD"; then state=off; log "FAN OFF ${t}C"
        else log "ERROR 关风扇命令失败（$t℃），保持当前状态"; fi
      fi
    fi
  fi
  (( now - last_log >= 300 )) && { log "TEMP ${t}C src=$nsrc state=$state detail:${TEMP_DETAIL:-<无>}"; last_log=$now; }
  sleep "${FAN_POLL:-5}"
done
FANSH
  chmod +x /usr/local/sbin/armbian-fan-control

  cat > /etc/systemd/system/armbian-fan.service <<EOF
[Unit]
Description=armbian-nas CPU 温度控制风扇（比特米盒/S905X）
After=network.target
[Service]
Type=simple
EnvironmentFile=/etc/default/armbian-fan
ExecStart=/usr/local/sbin/armbian-fan-control
# ★ 未配置时温控脚本会 exit 0；用 on-failure 避免 systemd 每 5 秒无限重启刷屏
Restart=on-failure
RestartSec=5
# 默认 KillMode=control-group：停机时连常驻 gpioset 一起回收，line 释放。
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  if [[ "$configured" -eq 1 ]]; then
    systemctl enable --now armbian-fan >/dev/null 2>&1 || systemctl enable --now armbian-fan
    sleep 1
    svc_active armbian-fan || c_warn "风扇服务未 active，请 journalctl -u armbian-fan -n 50 查看"
    c_ok "温控已启动：≥${FAN_ON_TEMP}℃ 开，≤${FAN_OFF_TEMP}℃ 关（滞回 ${FAN_ON_TEMP}-${FAN_OFF_TEMP}℃，最少运行 ${FAN_MIN_RUN}s）"
    c_info "  模式 $mode；日志 tail -f $BASE/logs/fan.log"
    case "$mode" in
      sysfs504)
        c_info "  确认 GPIO：ls /sys/class/gpio/gpio{$FAN_SYSFS_FAN,$FAN_LED_BLUE,$FAN_LED_RED,$FAN_LED_GREEN}/value"
        c_info "  切换另一套映射：--fan-mode=libgpiod --fan-gpio-chip=gpiochip0 --fan-gpio-line=3 --redo=14"
        ;;
      libgpiod)
        c_info "  确认占用：gpioinfo -c $FAN_GPIO_CHIP $FAN_GPIO_LINE ；pgrep -af gpioset"
        c_info "  切换另一套映射：--fan-mode=sysfs504 --redo=14"
        ;;
    esac
  else
    systemctl disable armbian-fan 2>/dev/null || true
    systemctl stop armbian-fan 2>/dev/null || true
    c_warn "未配置风扇控制方式：服务已写好但未启用，避免乱拉 GPIO 烧板"
    c_info "  S905X/p212 dtb： --fan-mode=sysfs504 --redo=14（504 + 面板灯）"
    c_info "  用户实测映射：  --fan-mode=libgpiod --fan-gpio-chip=gpiochip0 --fan-gpio-line=3 --redo=14"
    c_info "  自定义命令：    --fan-on-cmd='...' --fan-off-cmd='...' --redo=14"
    c_info "  USB 直连风扇无控制线时，此项保持「待配置」属正常"
  fi
}

# 由秒数换算 hdparm -S 的档位值，供部署与报告共用（单一来源，避免两处公式漂移）。
# 规则：5 秒粒度向上取整 → 钳到 1..240。0 是「禁用休眠」、241+ 是 30 分钟档，都不能用。
hdparm_spindown_units(){
  local t="${HD_IDLE_TIMEOUT:-600}" u
  [[ "$t" =~ ^[0-9]+$ ]] || t=600
  (( t < 5 )) && t=5
  u=$(( (t + 4) / 5 ))
  (( u < 1 )) && u=1
  (( u > 240 )) && u=240
  printf '%s' "$u"
}

step_hd_idle(){
  # -------------------------------------------------------------------------
  # ★ hdparm -S 的坑（本轮修）：单位是【5 秒】，而且 0 = 【禁用休眠】，
  #   不是「立刻休眠」。旧写法 $((HD_IDLE_TIMEOUT/5)) 在 --hd-idle=1..4 时
  #   整除得 0，语义直接反转为「永不休眠」；另外 241..251 是 30 分钟档、
  #   252/253/255 是厂商特殊值，>1200 秒也会落进完全另一套编码。
  #   这里：正整数校验 → 向上取整 (t+4)/5 → 钳到 1..240 → 明确告警。
  #   hd-idle 走的是秒，不受 5 秒粒度限制；但 <5 秒同样按 5 秒处理，
  #   避免两块盘一个 3 秒一个 5 秒、反复被唤醒。
  # -------------------------------------------------------------------------
  [[ "$HD_IDLE_TIMEOUT" =~ ^[0-9]+$ ]] \
    || die "--hd-idle 必须是正整数秒（当前：'$HD_IDLE_TIMEOUT'）；例：--hd-idle=600"
  local t="$HD_IDLE_TIMEOUT" spindown_units
  (( t >= 1 )) || die "--hd-idle 必须 >= 1 秒（当前：$t）"
  if (( t < 5 )); then
    c_warn "--hd-idle=${t}s 小于 hdparm -S 的 5 秒粒度，按 5 秒处理（避免整除得 0 反而【禁用】休眠）"
    t=5
  fi
  # 注意：hdparm_spindown_units() 内部已钳到 1..240，所以这里必须用【原始秒数 t】
  # 判断，不能用钳过的结果再比一次（否则 >1200 秒的告警永远不会触发）。
  if (( t > 1200 )); then
    c_warn "--hd-idle=${t}s 超过 hdparm -S 线性档上限 240（=1200 秒 / 20 分钟）；"
    c_warn "  hd-idle 与 hdparm 回退方案都钳到 1200s（241+ 是 30 分钟档，语义不同，不敢乱用）"
    t=1200
  fi
  spindown_units="$(hdparm_spindown_units)"   # 向上取整 + 钳到 1..240，恒 >= 1
  c_info "休眠参数：hd-idle -i ${t}s；hdparm -S ${spindown_units}（≈$((spindown_units*5))s，仅回退方案用）"

  apt_install hdparm || c_warn "hdparm 安装失败"
  apt_install hd-idle || c_warn "hd-idle 包不可用，稍后使用 hdparm 定时回退"
  local devs=() p
  for p in "$MAIN_DEV" "$SECOND_DEV"; do
    [[ -b "$p" ]] || continue
    p="$(lsblk -rno PKNAME "$p" 2>/dev/null | head -1 | tr -d ' ' || true)"
    [[ -n "$p" && -b "/dev/$p" ]] && devs+=("$p")
  done
  (( ${#devs[@]} > 0 )) || die "未解析出物理磁盘名（sda/sdb）"
  local opts="-i 0 -l $BASE/logs/hd-idle.log" d
  for d in "${devs[@]}"; do opts+=" -a $d -i $t"; done
  if dpkg -s hd-idle >/dev/null 2>&1; then
    cat > /etc/default/hd-idle <<EOF
START_HD_IDLE=true
HD_IDLE_OPTS="$opts"
EOF
    systemctl enable --now hd-idle
    systemctl restart hd-idle
    svc_active hd-idle || c_warn "hd-idle 未 active，请 journalctl -u hd-idle 查看"
    c_ok "hd-idle：${devs[*]} 空闲 ${t}s 后休眠"
  else
    c_warn "回退方案：systemd timer 每 10 分钟下发 hdparm -S（部分 USB 桥不透传 ATA 命令）"
    cat > /etc/systemd/system/armbian-hdparm.service <<EOF
[Unit]
Description=armbian-nas hdparm spindown fallback
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for d in ${devs[*]}; do hdparm -S $spindown_units /dev/\$d >/dev/null 2>&1 || true; done'
EOF
    cat > /etc/systemd/system/armbian-hdparm.timer <<'EOF'
[Unit]
Description=armbian-nas hdparm spindown timer
[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now armbian-hdparm.timer
    c_ok "已启用 hdparm 定时回退"
  fi
  # 避免 updatedb / 索引器半夜把盘唤醒
  if [[ -f /etc/updatedb.conf ]] && ! grep -q "$MOUNT_MAIN" /etc/updatedb.conf; then
    sed -i "s|PRUNEPATHS=\"|PRUNEPATHS=\"$MOUNT_MAIN $MOUNT_SECOND |" /etc/updatedb.conf
    c_info "已把两块挂载点加入 updatedb PRUNEPATHS"
  fi
  c_info "用 hdparm -C /dev/sda 看 active/standby；若反复唤醒，检查 smartd、MiniDLNA 扫描、播放器缩略图"
}

step_firewall(){
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    local p
    for p in 80/tcp ${PORT_BLOG}/tcp 8080/tcp ${PORT_FB}/tcp ${PORT_PORTAINER}/tcp 9091/tcp 6800/tcp 8200/tcp 8886/tcp 445/tcp 139/tcp 6881/tcp 6881/udp 51413/tcp 51413/udp 1900/udp 9993/udp; do
      ufw allow "$p" >/dev/null 2>&1 || true
    done
    c_ok "ufw 已放通 Web / SMB / DLNA(1900 UDP) / BT / ZeroTier(9993 UDP) 端口"
  else
    c_info "未启用 ufw，无需放通（若装了 firewalld 请自行放行 80/8080/9091/8200/445/1900udp/9993udp）"
  fi
  c_warn "Docker 发布的端口会绕过 ufw，请勿把 8080/9091/8886/$PORT_PORTAINER 直接映射到公网"
  c_info "ttyd 的 7681 只听 127.0.0.1，【故意不放通】；网页终端走 80 端口的 /ttyd/ 反代 + 密码"
  c_warn "网页终端等于一个 ${TTYD_USER} shell：不要把本机 80 端口映射到公网"
}

step_gui(){
  # 是否安装由 run_step 的组件 gate 决定（输入 n 会记 skip，下次再问）
  c_warn "图形界面会占用约 1-2GB 存储与额外内存，8G eMMC 强烈不建议，小主机建议只用 Web 管理"
  apt_install xfce4 xfce4-goodies lightdm xrdp
  systemctl set-default graphical.target
  systemctl enable xrdp 2>/dev/null || true
  systemctl enable lightdm 2>/dev/null || true
  c_ok "XFCE + xrdp 已安装；桌面环境也可通过 sudo armbian-config → System → Desktop 调整"
}

# ---------------------------------------------------------------------------
# 导航页存储快照：用 os.statvfs 直接读文件系统容量，避免解析 df 输出。
# index.html 是静态页，所以这里是「部署那一刻」的快照，页面会标注采集时间。
# 想刷新：sudo bash 脚本 --redo=18（或直接重跑脚本）。
# ---------------------------------------------------------------------------
disk_snapshot_json(){
  python3 - "$MOUNT_MAIN" "$MOUNT_SECOND" "$BASE" <<'PY'
import sys, os, json, subprocess
paths = ['/'] + [p for p in sys.argv[1:4] if p]
seen, out = set(), []
for p in paths:
    if p in seen or not os.path.isdir(p):
        continue
    seen.add(p)
    try:
        st = os.statvfs(p)
        total = st.f_blocks * st.f_frsize
        free  = st.f_bavail * st.f_frsize
        used  = total - st.f_bfree * st.f_frsize
    except Exception:
        continue
    dev, fst = '-', '-'
    try:
        r = subprocess.run(['findmnt', '-rn', '-o', 'SOURCE,FSTYPE', '--target', p],
                           capture_output=True, text=True, timeout=3)
        v = r.stdout.strip().split()
        if len(v) >= 2:
            dev, fst = v[0], v[1]
    except Exception:
        pass
    out.append({'path': p, 'dev': dev, 'fstype': fst,
                'total': total, 'used': used, 'free': free,
                'pct': round(used * 100.0 / total, 1) if total else 0})
sys.stdout.write(json.dumps(out, ensure_ascii=False).replace('<', '\\u003c'))
PY
}

# ---------------------------------------------------------------------------
# 完整 PHP 探针（X-Prober / 雅黑探针风格）
#   优先级：① --prober-php=<路径> ② 脚本同目录 prober.php（随包交付的 X-Prober）
#           ③ 网站根目录已有 prober.php（用户自己放的）④ 脚本内置生成一个
#   第 ④ 项保证：哪怕只拷一个 .sh 上机，「PHP 完整探针」卡片也一定点得开。
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 完整 PHP 环境探针 prober.php：★ 来自开源项目 X-Prober（X 探针 / 刘海探针）
#   作者：Km.Van / INN STUDIO    仓库：https://github.com/kmvan/x-prober
#   脚本只是把上游单文件【原样复制】到网站目录，并给 nginx 加一条
#   PHP_ADMIN_VALUE open_basedir=/ 的放行；未修改其源码。版权/许可证归原作者。
#   若脚本目录没有 prober.php，才生成一份自写的简化兜底探针（非上游代码）。
#   完整署名见 armbian-nas-使用说明.md「开源组件与致谢」章节。
# ---------------------------------------------------------------------------
install_prober(){
  local src="" dst="$WEB_ROOT/prober.php"
  mkdir -p "$WEB_ROOT"
  if [[ -n "$PROBER_PHP" && -f "$PROBER_PHP" ]]; then
    src="$PROBER_PHP"
  elif [[ -f "$(dirname "$SCRIPT_PATH")/prober.php" ]]; then
    src="$(dirname "$SCRIPT_PATH")/prober.php"
  elif [[ -f "$dst" && "$(wc -c < "$dst")" -gt 20000 ]]; then
    c_ok "沿用已有的完整 PHP 探针：$dst（$(wc -c < "$dst") 字节）"
    nginx_prober_location
    return 0
  fi
  if [[ -n "$src" ]]; then
    cp -f "$src" "$dst" && chmod 644 "$dst"
    c_ok "已安装完整 PHP 探针（X-Prober）：$dst ← $src（$(wc -c < "$dst") 字节）"
    nginx_prober_location
    return 0
  fi
  # ④ 内置兜底探针：纯 PHP 内置函数，不依赖 /proc、不依赖 shell_exec，
  #    在 open_basedir 收紧后依然能显示 phpinfo / 扩展 / ini / 磁盘。
  cat > "$dst" <<'PROBERPHP'
<?php
// armbian-nas 内置完整 PHP 环境探针（无外部依赖；有 X-Prober 时脚本会优先用 X-Prober）
header('Content-Type: text/html; charset=utf-8');
$exts = get_loaded_extensions(); sort($exts);
$ini  = ['disable_functions'=>'disable_functions',
         'open_basedir'=>'open_basedir','memory_limit'=>'memory_limit',
         'upload_max_filesize'=>'upload_max_filesize','post_max_size'=>'post_max_size',
         'max_execution_time'=>'max_execution_time','opcache.enable'=>'opcache.enable',
         'allow_url_fopen'=>'allow_url_fopen','display_errors'=>'display_errors'];
function h($s){ return htmlspecialchars((string)$s, ENT_QUOTES, 'UTF-8'); }
function hb($n){ $u=['B','KB','MB','GB','TB']; $i=0; while($n>=1024 && $i<4){$n/=1024;$i++;}
  return number_format($n,2).' '.$u[$i]; }
$dirs = [__DIR__, '/'];
?><!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>PHP 完整探针 · armbian-nas</title><style>
:root{--bg:#f4f7fb;--card:#fff;--txt:#16233a;--sub:#5b6b82;--line:#dbe3ee;--acc:#1d64d8;--ok:#059669}
*{box-sizing:border-box}body{margin:0;padding:26px 16px 60px;background:var(--bg);color:var(--txt);
font:14px/1.7 system-ui,-apple-system,"Segoe UI","Microsoft YaHei",sans-serif}
.wrap{max-width:1100px;margin:0 auto}h1{font-size:24px;margin:0 0 6px}h1 span{color:var(--acc)}
.meta{color:var(--sub);font-size:13px;margin-bottom:20px}
section{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 18px;margin:14px 0;
box-shadow:0 1px 3px #16233a0d}h2{font-size:16px;margin:0 0 12px;padding-bottom:8px;border-bottom:1px solid var(--line)}
table{width:100%;border-collapse:collapse;font-size:13px}td,th{padding:6px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{width:230px;color:var(--sub);font-weight:600}code{background:#eef3fb;border:1px solid var(--line);border-radius:5px;padding:1px 6px;
font:12px/1.6 ui-monospace,Menlo,Consolas,monospace;word-break:break-all}
.chips{display:flex;flex-wrap:wrap;gap:6px}.chip{background:#eaf1fd;color:#12459c;border:1px solid #c9dcfb;
border-radius:999px;padding:2px 10px;font:12px/1.7 ui-monospace,Menlo,Consolas,monospace}
.ok{color:var(--ok);font-weight:600}.warn{color:#b45309}
a{color:var(--acc)}.phpinfo{background:#fff;border:1px solid var(--line);border-radius:10px;padding:10px;overflow:auto}
</style></head><body><div class="wrap">
<h1>🐘 PHP <span>完整探针</span></h1>
<div class="meta">armbian-nas · <?=h(php_uname())?> · 生成于 <?=h(date('Y-m-d H:i:s'))?><br>
返回 <a href="/">一键导航页</a> · <a href="/probe.php">扩展核对探针</a> · <a href="/status.php">备用状态页</a></div>

<section><h2>运行环境</h2><table>
<tr><th>PHP 版本</th><td><b><?=h(PHP_VERSION)?></b> · SAPI <?=h(php_sapi_name())?></td></tr>
<tr><th>服务端软件</th><td><?=h(isset($_SERVER['SERVER_SOFTWARE']) ? $_SERVER['SERVER_SOFTWARE'] : '-')?></td></tr>
<tr><th>操作系统</th><td><?=h(php_uname('s').' '.php_uname('r').' '.php_uname('m'))?></td></tr>
<tr><th>脚本路径</th><td><code><?=h(__FILE__)?></code></td></tr>
<tr><th>网站根目录</th><td><code><?=h(isset($_SERVER['DOCUMENT_ROOT']) ? $_SERVER['DOCUMENT_ROOT'] : __DIR__)?></code></td></tr>
<tr><th>当前用户</th><td><?=h(get_current_user())?> (uid=<?=h(getmyuid())?>)</td></tr>
</table></section>

<section><h2>已加载扩展（<?=count($exts)?> 个）</h2>
<div class="chips"><?php foreach($exts as $e): ?><span class="chip"><?=h($e)?></span><?php endforeach; ?></div>
</section>

<section><h2>关键配置 php.ini</h2><table>
<?php foreach($ini as $k=>$label): $v = ini_get($k); if($v===''||$v===false) $v='(none)'; ?>
<tr><th><?=h($label)?></th><td><code><?=h($v)?></code></td></tr><?php endforeach; ?>
<tr><th>禁用函数冲突检查</th><td><?php
  $df = ini_get('disable_functions');
  if($df===''||$df==='(none)') echo '<span class="ok">disable_functions 为空：脚本 / 扩展函数全部可用 ✔</span>';
  else echo '<span class="warn">已禁用：'.h($df).'（若影响扩展，见脚本文档「完整命令速查」章节）</span>';
?></td></tr>
</table></section>

<section><h2>磁盘空间</h2><table>
<tr><th>挂载点</th><th>总空间</th><th>剩余</th><th>已用</th><th>文件系统</th></tr>
<?php foreach(array_unique($dirs) as $d):
  if(!is_dir($d)) continue;
  $t=@disk_total_space($d); $f=@disk_free_space($d);
  if($t===false||$f===false) continue; ?>
<tr><td><code><?=h($d)?></code></td><td><?=h(hb($t))?></td><td class="ok"><?=h(hb($f))?></td>
<td><?=h(hb($t-$f))?> (<?=h(number_format(($t-$f)*100/$t,1))?>%)</td><td>-</td></tr>
<?php endforeach; ?></table>
<p style="color:var(--sub);font-size:12px;margin:8px 0 0">受 PHP open_basedir 限制时，这里只会列出允许访问的目录；导航页有全部挂载点。</p>
</section>

<section><h2>完整 phpinfo()</h2><div class="phpinfo">
<?php ob_start(); phpinfo(); $pi=ob_get_clean();
  // 去掉 phpinfo 自带的外层 html/body，只留内容，避免嵌套破坏页面
  $pi = preg_replace('#^.*?<body[^>]*>#s','',$pi);
  $pi = preg_replace('#</body>.*$#s','',$pi);
  echo $pi; ?>
</div></section>
</div></body></html>
PROBERPHP
  chmod 644 "$dst"
  c_ok "已生成内置完整 PHP 探针：$dst（把随包 prober.php 放到脚本同目录可换成 X-Prober）"
  nginx_prober_location
}

# X-Prober 会读 /proc/cpuinfo、/proc/stat、执行 shell_exec('df -k')，
# 而步骤 19 的 open_basedir 会挡住这些路径。给 /prober.php 单独一个精确
# location，用 PHP_ADMIN_VALUE 把 open_basedir 放开到 /（只对这一个请求生效，
# 不改动全站安全基线）。幂等：已写过就不重复插，写完 nginx -t 才 reload。
nginx_prober_location(){
  local site=/etc/nginx/sites-available/armbian-nas
  [[ -f "$site" ]] || { c_warn "未找到 $site，跳过 prober 的 nginx 放行（内置探针仍可用）"; return 0; }
  # ★ 幂等判据拆开：/prober.php 与 /diskstat.php 各自独立，
  #   老站点可能只有 prober 的放行，这里要能把 diskstat 的补上。
  local pass
  pass="$(grep -hoE 'fastcgi_pass[[:space:]]+[^;]+' "$site" 2>/dev/null | head -1 | sed 's/^fastcgi_pass[[:space:]]*//' || true)"
  [[ -n "$pass" ]] || pass="unix:$PHP_SOCK"
  python3 - "$site" "$pass" <<'PY'
import sys
p, pas = sys.argv[1], sys.argv[2]
s = open(p, encoding='utf-8').read()
def loc(name):
    return ("    # %s：单独放开 open_basedir（读 /proc、df、外置盘）\n" % name
            + "    location = /" + name + " {\n"
            + "        include fastcgi_params;\n"
            + "        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;\n"
            + "        fastcgi_param PHP_ADMIN_VALUE \"open_basedir=/\";\n"
            + "        fastcgi_pass " + pas + ";\n"
            + "    }\n\n")
need = []
for name in ('prober.php', 'diskstat.php'):
    if ('location = /' + name) not in s:
        need.append(loc(name))
if need:
    block = ''.join(need)
    anchor = '    location ~ \\.php$ {'
    if anchor in s:
        s = s.replace(anchor, block + anchor, 1)
    else:
        i = s.rfind('\n}')
        s = s[:i] + '\n' + block.rstrip() + s[i:]
    open(p, 'w', encoding='utf-8').write(s)
    print("INSERTED")
else:
    print("ALREADY")
PY
  if [[ "$(python3 - "$site" "$pass" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
print('OK' if 'location = /diskstat.php' in s else 'MISS')
PY
)" != "OK" ]]; then
    c_warn "diskstat.php 的 nginx 放行未写入，动态磁盘会回退到静态快照"
  fi
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx >/dev/null 2>&1 || true
    c_ok "nginx 已为 /prober.php 与 /diskstat.php 放行 open_basedir 并重载（fastcgi_pass $pass）"
  else
    c_warn "插入 location 后 nginx -t 未通过，已保留改动但未重载；请检查 $site"
  fi
}

# ---------------------------------------------------------------------------
# 动态磁盘接口 /diskstat.php：导航页每 5 秒 fetch 一次，实时显示
#   挂载点 / 设备 / 文件系统 / 总空间 / 已用 / 剩余 / 使用率。
# 用 PHP 的 disk_total_space() / disk_free_space()，读 /proc/mounts 找设备名，
# 不依赖 shell_exec（很多加固配置会禁用它）。
# ★ 需要 nginx 给这个 location 单独放行 open_basedir=/（见 nginx_prober_location）。
#   若接口不可用，导航页自动回退到部署时内嵌的静态快照，不会白屏。
# ---------------------------------------------------------------------------
write_diskstat_php(){
  [[ -d "$WEB_ROOT" ]] || { c_warn "$WEB_ROOT 不存在，跳过 diskstat.php"; return 1; }
  cat > "$WEB_ROOT/diskstat.php" <<'DISKPHP'
<?php
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');
error_reporting(0);
$paths = array('/', '__MOUNT_MAIN__', '__MOUNT_SECOND__', '__BASE__');
$mounts = array();
if (is_readable('/proc/mounts')) {
  $ls = @file('/proc/mounts', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
  if ($ls) foreach ($ls as $l) {
    $p = preg_split('/\s+/', trim($l));
    if (count($p) >= 3) $mounts[$p[1]] = array($p[0], $p[2]);
  }
}
function best_mount($path, $mounts){
  $best = ''; $len = -1;
  foreach ($mounts as $mp => $v) {
    if ($mp === '/' || $path === $mp || strpos($path, rtrim($mp,'/') . '/') === 0) {
      if (strlen($mp) > $len) { $len = strlen($mp); $best = $mp; }
    }
  }
  return $best;
}
$out = array(); $seen = array();
foreach ($paths as $p) {
  if ($p === '' || isset($seen[$p]) || !is_dir($p)) continue;
  $seen[$p] = 1;
  $t = @disk_total_space($p); $f = @disk_free_space($p);
  if ($t === false || $f === false || $t <= 0) continue;
  $used = $t - $f;
  $mp = best_mount($p, $mounts);
  $dev = isset($mounts[$mp][0]) ? $mounts[$mp][0] : '-';
  $fst = isset($mounts[$mp][1]) ? $mounts[$mp][1] : '-';
  $out[] = array('path'=>$p, 'dev'=>$dev, 'fstype'=>$fst,
                 'total'=>$t, 'used'=>$used, 'free'=>$f,
                 'pct'=>round($used * 100.0 / $t, 1));
}
echo json_encode(array('time'=>date('Y-m-d H:i:s'), 'dynamic'=>true,
                       'items'=>$out), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
DISKPHP
  sed -i "s|__MOUNT_MAIN__|$MOUNT_MAIN|g; s|__MOUNT_SECOND__|$MOUNT_SECOND|g; s|__BASE__|$BASE|g" "$WEB_ROOT/diskstat.php"
  chmod 644 "$WEB_ROOT/diskstat.php"
  c_ok "动态磁盘接口：$WEB_ROOT/diskstat.php（导航页每 5 秒自动刷新）"
}

# ---------------------------------------------------------------------------
# 前置空间阈值：装软件发生在「apt 缓存外置」之前
# ---------------------------------------------------------------------------
# 步骤 19 才把 apt 缓存 / lists 挪到外置盘，而步骤 02/03 的 .deb 下载与解包
# 已经落在 eMMC。以前只有 --check 末尾的「剩余空间」告警，部署【前】没有门槛，
# 老机器塞满时会在装到一半才失败。这里在挂载外置盘之前先拦一次。
#   * 默认要求根分区剩余 >= 1.5 GiB（--min-root-space=<MiB> 可调，0=关闭）
#   * 只在【首次 deploy 且步骤状态为空】时硬中止；断点续跑 / --force-low-space
#     只告警不拦，避免把正在续跑的人卡在门外
#   * --check / --repair / --status / --dry-run 完全不受影响
#   * 全新系统实测部署后 7.0G 用 2.1G（30%），剩 4.9G，远低于触发线
# ---------------------------------------------------------------------------
preflight_root_space(){
  [[ "$MODE" == "deploy" ]] || return 0
  [[ "$MIN_ROOT_SPACE_MB" =~ ^[0-9]+$ ]] || MIN_ROOT_SPACE_MB=1536
  (( MIN_ROOT_SPACE_MB > 0 )) || return 0
  local avail_kb use_pct min_kb
  avail_kb="$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}')"
  use_pct="$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5);print $5}')"
  [[ "${avail_kb:-}" =~ ^[0-9]+$ ]] || { c_warn "无法读取根分区剩余空间，跳过前置空间门槛"; return 0; }
  min_kb=$(( MIN_ROOT_SPACE_MB * 1024 ))
  if (( avail_kb >= min_kb )); then
    c_ok "前置空间检查：根分区剩余 $((avail_kb/1024)) MiB（门槛 ≥${MIN_ROOT_SPACE_MB} MiB，使用率 ${use_pct:-?}%）"
    return 0
  fi
  local msg="根分区仅剩 $((avail_kb/1024)) MiB（门槛 ≥${MIN_ROOT_SPACE_MB} MiB，使用率 ${use_pct:-?}%）。装软件时 apt 缓存尚未外置，可能装到一半失败"
  if [[ "$FORCE_LOW_SPACE" -eq 1 || -s "$STATE_FILE" || -s "$MIRROR_FILE" ]]; then
    c_warn "$msg；检测到已有部署状态或 --force-low-space，只告警不中止"
    return 0
  fi
  die "$msg。建议：df -h / 确认 → 清理 /var/cache/apt 或卸载不用的组件 → 用 --no-docker --no-gui 部署；确需继续加 --force-low-space（或 --min-root-space=0 关闭门槛）"
}

# ---------------------------------------------------------------------------
# ★ simple 凭据合法性：--fb-password 太短必须【部署前】拦下。
#   否则 step_filebrowser 的 users add 会被上游拒绝，静默退化成 no_auth 免密，
#   而状态页仍显示 admin / <短密码>，又变成「假配置」。
# ---------------------------------------------------------------------------
validate_simple_creds(){
  [[ "${CRED_MODE:-simple}" == "simple" ]] || return 0
  if (( ${#FB_SIMPLE_PASS} < FB_PASS_MIN )); then
    c_err "★ --fb-password 太短：${#FB_SIMPLE_PASS} 位，FileBrowser 上游要求至少 ${FB_PASS_MIN} 位"
    c_err "  CLI 会报 'Error: password is too short, minimum length is 12'"
    c_err "  用默认 adminadmin123，或 sudo bash $SCRIPT_PATH --fb-password=你的12位以上密码"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# ★ 定向模式最小依赖兜底（真机：sudo bash 脚本 --with-zerotier --redo=07）
#   --with-X / --redo=N 会跳过步骤 01/02，但目标步骤仍然需要 $STATE_DIR、
#   curl、python3 这些基础条件。全新系统 / 重刷后直接跑定向命令时，缺一个就
#   在 run_step 的子 shell 里静默失败，tmux 窗口一闪而过用户完全看不到。
#   这里只做幂等的「建目录 + 补真正缺失的基础命令」：
#     · 不安装任何目标软件、不询问、不改任何步骤状态、不碰外置盘已有数据
#     · MODE 必须是 deploy；--check / --status / --repair / --dry-run 全部跳过
# ---------------------------------------------------------------------------
targeted_prereqs(){
  [[ "${TARGETED:-0}" -eq 1 ]] || return 0
  [[ "$MODE" == "deploy" ]] || return 0
  mkdir -p "$STATE_DIR" "$LOG_DIR" "$WEB_ROOT" 2>/dev/null || true
  local missing=() c
  for c in curl python3; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  command -v gpg >/dev/null 2>&1 || missing+=(gnupg)
  if (( ${#missing[@]} )); then
    c_info "★ 定向模式：步骤 02 被跳过，先补齐目标步骤缺失的基础命令：${missing[*]}"
    apt_update
    if ! apt_install "${missing[@]}"; then
      c_warn "基础命令补装未全部成功；可先跑一次不带参数的完整部署，或手动 sudo apt-get install -y ${missing[*]}"
    fi
  else
    c_info "定向模式：基础目录与命令已就绪（未改动任何步骤状态）"
  fi
}


# 自检 helper：确认前置门槛真的接在 main 里，且位置早于 ensure_mounts。
preflight_space_ok(){
  local f pl ml
  f="$(deployer_src)"; [[ -r "$f" ]] || return 1
  grep -q '^preflight_root_space(){' "$f" || return 1
  pl="$(grep -n '^[[:space:]]\+preflight_root_space$' "$f" | head -1 | cut -d: -f1)"
  ml="$(grep -n '^[[:space:]]\+ensure_mounts$' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$pl" && -n "$ml" && "$pl" -lt "$ml" ]] || return 1
  grep -q 'MIN_ROOT_SPACE_MB="${MIN_ROOT_SPACE_MB:-1536}"' "$f" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 在线脚本文档：把同目录的 armbian-nas-使用说明.md 发布成 /docs.html
# ---------------------------------------------------------------------------
# 用户要求：导航页最顶端有一个链接，点开【新标签页】就能在线看脚本说明文档，
#           不用再开 SSH 去 cat 文件。
#   * 纯静态、无 CDN、离线可用：这里用 Python 标准库把 Markdown 转成 HTML，
#     带左侧目录 + 全文高亮搜索 + 原始 .md 下载链接。
#   * 文档里包含「完整命令速查」与「开源组件致谢（X-Prober 署名）」两节，
#     所以在线页面同样能看到，不会漏。
#   * 找不到 .md 时生成一个可用的兜底页（含常用完整命令与上游署名），不致命。
# ---------------------------------------------------------------------------
write_docs_page(){
  local dir="$(dirname "$SCRIPT_PATH")" src="" dst_html="$WEB_ROOT/docs.html"
  local dst_md="$WEB_ROOT/armbian-nas-使用说明.md"
  local c
  for c in "$dir/armbian-nas-使用说明.md" \
           "$BASE/config/armbian-nas-使用说明.md" \
           /root/armbian-nas-使用说明.md \
           "$PWD/armbian-nas-使用说明.md" \
           "$dst_md"; do
    if [[ -r "$c" && -s "$c" ]]; then src="$c"; break; fi
  done

  if [[ -z "$src" ]]; then
    c_warn "未找到 armbian-nas-使用说明.md，生成兜底版在线文档（把 .md 与主脚本放同目录重跑 --redo=18 可得完整版）"
    cat > "$dst_html" <<'DOCHTML'
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>armbian-nas 脚本文档（兜底版）</title>
<style>body{margin:0;background:#f4f7fb;color:#16233a;font:16px/1.75 system-ui,"Microsoft YaHei",sans-serif}
.wrap{max-width:860px;margin:32px auto;background:#fff;border:1px solid #dfe6f0;border-radius:14px;padding:28px}
h1{margin:0 0 10px;font-size:24px}code{background:#eef3fb;border:1px solid #dfe6f0;border-radius:5px;padding:2px 6px}
table{width:100%;border-collapse:collapse;font-size:14px}td,th{padding:9px;border-bottom:1px solid #dfe6f0;text-align:left}
.note{background:#fff8e8;border:1px solid #f2d9a2;border-radius:9px;padding:12px;color:#7c4a06;font-size:14px}
a{color:#1d64d8}</style></head><body><div class="wrap">
<h1>📖 armbian-nas 脚本文档</h1>
<div class="note"><b>未找到完整说明文档。</b>请把 <code>armbian-nas-使用说明.md</code> 与
<code>armbian-nas-一键部署.sh</code> 放在同一个目录，然后执行
<code>sudo ./armbian-nas-一键部署.sh --redo=18</code>，本页就会变成完整文档（含目录与全文搜索）。</div>
<h2>常用完整命令</h2><table>
<tr><th>功能</th><th>完整命令</th></tr>
<tr><td>首次部署（省 eMMC）</td><td><code>sudo ./armbian-nas-一键部署.sh --no-docker --no-gui</code></td></tr>
<tr><td>重建导航页</td><td><code>sudo ./armbian-nas-一键部署.sh --redo=18</code></td></tr>
<tr><td>一键修复</td><td><code>sudo ./armbian-nas-一键部署.sh --repair</code></td></tr>
<tr><td>仅自检</td><td><code>sudo ./armbian-nas-一键部署.sh --check</code></td></tr>
<tr><td>看进度</td><td><code>sudo ./armbian-nas-一键部署.sh --status</code></td></tr>
<tr><td>重建本地博客</td><td><code>sudo ./armbian-nas-一键部署.sh --redo=23</code></td></tr>
<tr><td>风扇针脚两轮实测</td><td><code>sudo bash ./风扇针脚测试.sh</code></td></tr>
</table>
<h2>开源组件致谢</h2>
<p>本脚本随附的 <code>prober.php</code> 完整 PHP 环境探针来自
<b>X-Prober / X 探针 / 刘海探针</b>（作者 Km.Van / INN STUDIO），
开源地址：<a href="https://github.com/kmvan/x-prober" target="_blank" rel="noopener noreferrer">https://github.com/kmvan/x-prober</a>。
脚本只是把上游单文件原样放到网站目录并加 nginx 放行，未修改其源码，版权与许可证归原作者所有。</p>
</div></body></html>
DOCHTML
    chmod 644 "$dst_html"
    return 0
  fi

  # 原始 Markdown 也发布一份，供下载/离线查；同时存一份到外置盘 config，
  # 这样以后即便脚本目录被清理，--redo=18 仍能找到文档。
  if [[ "$src" != "$dst_md" ]]; then cp -f "$src" "$dst_md" 2>/dev/null || true; fi
  mkdir -p "$BASE/config"
  if [[ "$src" != "$BASE/config/armbian-nas-使用说明.md" ]]; then
    cp -f "$src" "$BASE/config/armbian-nas-使用说明.md" 2>/dev/null || true
  fi
  chmod 644 "$dst_md" 2>/dev/null || true

  python3 - "$src" "$dst_html" <<'DOCPY'
# -*- coding: utf-8 -*-
# 极简 Markdown → HTML 转换器（只用标准库，无 CDN、离线可用）。
# 支持：标题 / 表格 / 围栏代码块 / 引用 / 有序无序列表 / 分隔线 /
#       粗体 / 行内代码 / 链接 / 裸 URL。生成左侧目录 + 全文高亮搜索。
import sys, re, html, json
src, dst = sys.argv[1], sys.argv[2]
md = open(src, encoding='utf-8').read()

def inline(t):
    codes = []
    def stash_code(m):
        codes.append('<code>' + html.escape(m.group(1), quote=False) + '</code>')
        return '\x02%d\x02' % (len(codes) - 1)
    t = re.sub(r'`([^`]+)`', stash_code, t)
    t = html.escape(t, quote=False)
    links = []
    def stash_link(m):
        label, url = m.group(1), m.group(2)
        links.append('<a href="' + url + '" target="_blank" rel="noopener noreferrer">' + label + '</a>')
        return '\x03%d\x03' % (len(links) - 1)
    t = re.sub(r'\[([^\]]+)\]\(([^)\s]+)\)', stash_link, t)
    # Markdown 的 <https://...> 自动链接：此时尖括号已被 html.escape 成 &lt; / &gt;，
    # 必须单独收进 token，否则下面的裸 URL 正则会把 &gt; 一起吃进 href。
    def stash_angle(m):
        url = m.group(1)
        links.append('<a href="' + url + '" target="_blank" rel="noopener noreferrer">' + url + '</a>')
        return '\x03%d\x03' % (len(links) - 1)
    t = re.sub(r'&lt;(https?://[^\s&<>]+)&gt;', stash_angle, t)
    t = re.sub(r'(?<!["\'/=&])(https?://[^\s<)\]>&|]+)',
               r'<a href="\1" target="_blank" rel="noopener noreferrer">\1</a>', t)
    t = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', t)
    for i, a in enumerate(links):
        t = t.replace('\x03%d\x03' % i, a)
    for i, c in enumerate(codes):
        t = t.replace('\x02%d\x02' % i, c)
    return t

def cells(l):
    l = l.strip()
    if l.startswith('|'): l = l[1:]
    if l.endswith('|'): l = l[:-1]
    prot = []
    def st(m):
        prot.append(m.group(0)); return '\x04%d\x04' % (len(prot) - 1)
    l = re.sub(r'`[^`]*`', st, l)
    parts = [c.strip() for c in l.split('|')]
    return [re.sub(r'\x04(\d+)\x04', lambda m: prot[int(m.group(1))], p) for p in parts]

lines = md.split('\n')
out, toc = [], []
i, n = 0, len(lines)
while i < n:
    line = lines[i]; st = line.strip()
    if st.startswith('```'):
        i += 1; buf = []
        while i < n and not lines[i].strip().startswith('```'):
            buf.append(lines[i]); i += 1
        i += 1
        out.append('<pre class="code"><code>' + html.escape('\n'.join(buf)) + '</code></pre>')
        continue
    if not st:
        i += 1; continue
    m = re.match(r'^(#{1,6})\s+(.*)$', line)
    if m:
        lv, txt = len(m.group(1)), m.group(2).strip()
        hid = 'sec%d' % len(toc)
        toc.append((lv, txt, hid))
        out.append('<h%d id="%s">%s</h%d>' % (lv, hid, inline(txt), lv))
        i += 1; continue
    if st in ('---', '***', '___', '----'):
        out.append('<hr>'); i += 1; continue
    if st.startswith('|') and i + 1 < n and re.match(r'^\s*\|[\s:|\-]+\|\s*$', lines[i + 1]):
        hdr = cells(lines[i]); i += 2; rows = []
        while i < n and lines[i].strip().startswith('|'):
            rows.append(cells(lines[i])); i += 1
        t = '<div class="tw"><table><thead><tr>' + ''.join('<th>' + inline(c) + '</th>' for c in hdr) + '</tr></thead><tbody>'
        for r in rows:
            t += '<tr>' + ''.join('<td>' + inline(c) + '</td>' for c in r) + '</tr>'
        out.append(t + '</tbody></table></div>')
        continue
    if st.startswith('>'):
        buf = []
        while i < n and lines[i].strip().startswith('>'):
            buf.append(lines[i].strip().lstrip('>').strip()); i += 1
        out.append('<blockquote>' + inline(' '.join(buf)) + '</blockquote>')
        continue
    if re.match(r'^\s*(?:[-*+]\s+|\d+[.)]\s+)', line):
        ordered = bool(re.match(r'^\s*\d+[.)]\s+', line))
        items = []
        while i < n and re.match(r'^\s*(?:[-*+]\s+|\d+[.)]\s+)', lines[i]):
            items.append(re.sub(r'^\s*(?:[-*+]\s+|\d+[.)]\s+)', '', lines[i]).rstrip()); i += 1
        tag = 'ol' if ordered else 'ul'
        out.append('<' + tag + '>' + ''.join('<li>' + inline(x) + '</li>' for x in items) + '</' + tag + '>')
        continue
    buf = [line.rstrip()]; i += 1
    while (i < n and lines[i].strip()
           and not re.match(r'^\s*(?:#{1,6}\s|[-*+]\s|\d+[.)]\s|>|```|\|)', lines[i])
           and lines[i].strip() not in ('---', '***', '___', '----')):
        buf.append(lines[i].strip()); i += 1
    out.append('<p>' + inline(' '.join(buf)) + '</p>')

toc_html = []
for lv, txt, hid in toc:
    if lv == 1:
        continue
    toc_html.append('<a class="lv%d" href="#%s">%s</a>' % (lv, hid, html.escape(re.sub(r'[*`]', '', txt))))
body = '\n'.join(out)
doc = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>armbian-nas 脚本文档（在线查看）</title>
<style>
*{box-sizing:border-box}
:root{--bg:#f4f7fb;--card:#fff;--txt:#16233a;--sub:#5b6b82;--line:#dbe3ee;--acc:#1d64d8;--soft:#f1f5fb}
body{margin:0;background:var(--bg);color:var(--txt);font:15.5px/1.75 system-ui,-apple-system,"Segoe UI","Microsoft YaHei",sans-serif}
.top{position:sticky;top:0;z-index:9;background:#fff;border-bottom:1px solid var(--line);padding:10px 18px;display:flex;flex-wrap:wrap;gap:10px;align-items:center}
.top b{font-size:15px;margin-right:6px}
.top a{color:var(--acc);text-decoration:none;font-size:13px;border:1px solid var(--line);border-radius:7px;padding:4px 10px;background:var(--soft)}
.top input{flex:1;min-width:190px;max-width:380px;border:1px solid var(--line);border-radius:8px;padding:7px 11px;font:inherit;font-size:13.5px}
.top .cnt{font-size:12px;color:var(--sub)}
.layout{display:flex;gap:18px;max-width:1400px;margin:0 auto;padding:20px 18px 60px;align-items:flex-start}
.toc{position:sticky;top:62px;flex:0 0 262px;max-height:calc(100vh - 82px);overflow:auto;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 10px}
.toc a{display:block;color:var(--sub);text-decoration:none;font-size:12.5px;padding:4px 8px;border-radius:6px;line-height:1.45}
.toc a:hover{background:var(--soft);color:var(--acc)}
.toc a.lv2{font-weight:700;color:var(--txt);margin-top:5px}
.toc a.lv3{padding-left:20px;font-size:12px}
#content{flex:1;min-width:0;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:24px 30px 48px}
h1{font-size:25px;margin:0 0 14px;color:var(--acc)}h2{font-size:19px;margin:30px 0 12px;padding-bottom:8px;border-bottom:1px solid var(--line)}
h3{font-size:16px;margin:22px 0 10px}h4,h5,h6{font-size:14px;margin:18px 0 8px;color:var(--sub)}
p{margin:9px 0}a{color:var(--acc)}code{background:var(--soft);border:1px solid var(--line);border-radius:5px;padding:1px 6px;font:13px/1.6 ui-monospace,Menlo,Consolas,monospace;word-break:break-word}
pre.code{background:#0f172a;color:#e2e8f0;border-radius:10px;padding:14px 16px;overflow:auto;font:12.5px/1.65 ui-monospace,Menlo,Consolas,monospace;margin:12px 0}
pre.code code{background:none;border:0;padding:0;color:inherit;font:inherit}
blockquote{margin:12px 0;padding:8px 14px;background:var(--soft);border-left:3px solid var(--acc);border-radius:0 8px 8px 0;color:var(--sub)}
.tw{overflow-x:auto;margin:12px 0}table{border-collapse:collapse;width:100%;font-size:13.5px}
th,td{border:1px solid var(--line);padding:8px 10px;text-align:left;vertical-align:top}
th{background:var(--soft);font-weight:700}tr:nth-child(even) td{background:#fafcff}
ul,ol{padding-left:24px;margin:9px 0}li{margin:4px 0}hr{border:0;border-top:1px solid var(--line);margin:26px 0}
mark{background:#ffe58f;color:#5c3b00;border-radius:3px;padding:0 2px}
footer{text-align:center;color:var(--sub);font-size:12px;margin:22px 0 0}
@media(max-width:900px){.layout{display:block}.toc{position:static;max-height:none;margin-bottom:14px}#content{padding:18px}}
</style></head><body>
<div class="top"><b>📖 armbian-nas 脚本文档</b>
  <input id="q" type="search" placeholder="全文搜索 / 过滤目录（例如：--repair、风扇、X-Prober）" autocomplete="off">
  <span class="cnt" id="cnt">共 __TOC_N__ 个章节</span>
  <a href="armbian-nas-使用说明.md" download>⬇ 下载 Markdown</a>
  <a href="/" target="_blank" rel="noopener noreferrer">← 返回导航页</a>
</div>
<div class="layout"><nav class="toc" id="toc">__TOC__</nav>
<main id="content">__BODY__</main></div>
<footer>本页由 armbian-nas 部署脚本从 armbian-nas-使用说明.md 生成 · 纯静态 / 无 CDN / 局域网离线可用</footer>
<script>
function clearMarks(){
  var ms=document.querySelectorAll('#content mark');
  for(var i=0;i<ms.length;i++){var m=ms[i],p=m.parentNode;p.replaceChild(document.createTextNode(m.textContent),m);p.normalize();}
}
function highlight(q){
  clearMarks(); if(!q) return 0;
  var w=document.createTreeWalker(document.getElementById('content'),NodeFilter.SHOW_TEXT,null,false);
  var nodes=[],nd; while(nd=w.nextNode()){if(nd.nodeValue.toLowerCase().indexOf(q.toLowerCase())!==-1&&nd.parentNode.nodeName!=='MARK')nodes.push(nd);}
  var cnt=0;
  nodes.forEach(function(node){
    var text=node.nodeValue,low=text.toLowerCase(),lq=q.toLowerCase(),pos=0,idx;
    var f=document.createDocumentFragment();
    while((idx=low.indexOf(lq,pos))!==-1){
      f.appendChild(document.createTextNode(text.slice(pos,idx)));
      var mk=document.createElement('mark');mk.textContent=text.slice(idx,idx+q.length);f.appendChild(mk);
      pos=idx+q.length;cnt++;
    }
    f.appendChild(document.createTextNode(text.slice(pos)));
    node.parentNode.replaceChild(f,node);
  });
  return cnt;
}
var qi=document.getElementById('q');
qi.addEventListener('input',function(){
  var q=qi.value.trim(),lq=q.toLowerCase(),shown=0;
  var as=document.querySelectorAll('#toc a');
  for(var i=0;i<as.length;i++){var ok=!q||as[i].textContent.toLowerCase().indexOf(lq)!==-1;as[i].style.display=ok?'':'none';if(ok)shown++;}
  var c=highlight(q);
  document.getElementById('cnt').textContent=q?('找到 '+c+' 处 · 目录 '+shown+' 项'):'共 __TOC_N__ 个章节';
  if(q&&c>0){var m=document.querySelector('#content mark');if(m)m.scrollIntoView({block:'center',behavior:'smooth'});}
});
</script></body></html>"""
doc = (doc.replace('__TOC__', '\n'.join(toc_html))
          .replace('__BODY__', body)
          .replace('__TOC_N__', str(len(toc_html))))
open(dst, 'w', encoding='utf-8').write(doc)
print('DOCS OK')
DOCPY
  chmod 644 "$dst_html"
  if [[ -s "$dst_html" ]]; then
    c_ok "在线脚本文档：$dst_html（← $src；新标签页打开，含目录与全文搜索）"
  else
    c_warn "docs.html 生成失败；在线文档入口会显示兜底内容"
  fi
}

# ---------------------------------------------------------------------------
# 本机全部 IP + 来访主机 IP：/hostinfo.php 动态接口
# ---------------------------------------------------------------------------
# 用户要求：导航页「当前主机」那里要能看到【所有本机 IP】（含 ZeroTier /
# docker / 虚拟网卡、IPv6），以及【来访主机 IP】。
#   * 静态 HTML 拿不到这些，所以用 PHP 接口：net_get_interfaces() 是 PHP 7.3+
#     内置函数，直接问内核，不读文件、不 shell_exec，因此不受 open_basedir 限制。
#   * 来访 IP 取 $_SERVER['REMOTE_ADDR']（nginx 直连时就是浏览器所在机器），
#     代理头 X-Forwarded-For 单独显示并标注「仅代理环境可信」。
#   * 前端先用「部署时快照」渲染，再 fetch 动态刷新；接口挂了自动回退。
# ---------------------------------------------------------------------------
write_hostinfo_php(){
  [[ -d "$WEB_ROOT" ]] || { c_warn "$WEB_ROOT 不存在，跳过 hostinfo.php"; return 1; }
  cat > "$WEB_ROOT/hostinfo.php" <<'HOSTPHP'
<?php
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');
error_reporting(0);
$out = array(
  'time'          => date('Y-m-d H:i:s'),
  'hostname'      => (function_exists('gethostname') ? @gethostname() : (function_exists('php_uname') ? @php_uname('n') : '-')),
  'server_addr'   => isset($_SERVER['SERVER_ADDR']) ? $_SERVER['SERVER_ADDR'] : '',
  'http_host'     => isset($_SERVER['HTTP_HOST']) ? $_SERVER['HTTP_HOST'] : '',
  'client_ip'     => isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '',
  'forwarded_for' => isset($_SERVER['HTTP_X_FORWARDED_FOR']) ? $_SERVER['HTTP_X_FORWARDED_FOR'] : '',
  'interfaces'    => array(),
);
// net_get_interfaces() 是 PHP 内置函数：不读文件、不执行命令，open_basedir 不影响它。
if (function_exists('net_get_interfaces')) {
  $ifs = @net_get_interfaces();
  if (is_array($ifs)) {
    foreach ($ifs as $name => $info) {
      $addrs = array();
      if (!empty($info['unicast']) && is_array($info['unicast'])) {
        foreach ($info['unicast'] as $u) {
          if (empty($u['address'])) continue;
          $a = preg_replace('/%.*$/', '', (string)$u['address']);
          $addrs[] = array('family' => (strpos($a, ':') !== false ? 'IPv6' : 'IPv4'), 'address' => $a);
        }
      }
      $out['interfaces'][] = array(
        'name'  => $name,
        'up'    => isset($info['up']) ? (bool)$info['up'] : true,
        'addrs' => $addrs,
      );
    }
  }
}
if (empty($out['interfaces'])) {
  $arr = array();
  if ($out['server_addr'] !== '') {
    $arr[] = array('family' => (strpos($out['server_addr'], ':') !== false ? 'IPv6' : 'IPv4'),
                   'address' => $out['server_addr']);
  }
  $out['interfaces'][] = array('name' => '（回退 SERVER_ADDR）', 'up' => true, 'addrs' => $arr);
}
echo json_encode($out, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT);
HOSTPHP
  chmod 644 "$WEB_ROOT/hostinfo.php"
  c_ok "本机 IP / 来访 IP 接口：$WEB_ROOT/hostinfo.php（net_get_interfaces，不受 open_basedir 限制）"
}

# 部署时静态快照：即使 /hostinfo.php 不可用，导航页也能显示所有本机 IP。
host_ips_static_json(){
  python3 - <<'HOSTPY'
import json, subprocess, socket
addrs = []
try:
    out = subprocess.check_output(['hostname', '-I'], text=True, timeout=3)
    addrs += [x for x in out.split() if x]
except Exception:
    pass
try:
    out = subprocess.check_output(['ip', '-6', '-o', 'addr', 'show', 'scope', 'global'], text=True, timeout=3)
    for l in out.splitlines():
        p = l.split()
        if len(p) >= 4:
            a = p[3].split('/')[0].split('%')[0]
            if a and a not in addrs: addrs.append(a)
except Exception:
    pass
seen, arr = set(), []
for a in addrs:
    if a in seen: continue
    seen.add(a)
    arr.append({'family': 'IPv6' if ':' in a else 'IPv4', 'address': a})
print(json.dumps({
    'time': '部署时快照', 'hostname': socket.gethostname(),
    'client_ip': '-', 'forwarded_for': '', 'server_addr': '', 'http_host': '',
    'interfaces': [{'name': '部署时快照', 'up': True, 'addrs': arr}],
}, ensure_ascii=False))
HOSTPY
}

# ---------------------------------------------------------------------------
# ★ 用户要求：每次运行脚本的最后，都重新生成一次导航页。
#   步骤 18 一旦记 done，run_step 会跳过它；之后装/卸软件、改端口、改文档
#   都不会自动刷新首页。所以在 final_check 开头统一重建一次，
#   deploy / --check / --repair / --uninstall 的收尾都会走到。
#   纯查询类（--help / --status / --dry-run）在 main 更早处 return，不会进来。
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# ★ 真机反馈自愈：prober.php 可访问 / Samba 共享段落数
#
# 日志里这两项 FAIL 的根因：步骤 18、13 早已 done，后续任何运行都被 run_step
# 跳过，旧配置一直没机会重建。这里在「每次运行收尾」做一次真实探测 + 幂等修复，
# 只在确实不对时才动系统；--check 是只读模式，不触发任何写入。
# ---------------------------------------------------------------------------
prober_heal(){
  [[ -d "$WEB_ROOT" ]] || return 0
  local body=""
  install_prober >/dev/null 2>&1 || true
  # nginx_prober_location 内部会 reload，这里再兜一次（站点配置刚改过的情况）
  if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
    systemctl reload nginx >/dev/null 2>&1 || true
  fi
  body="$(curl -fsS --max-time 8 'http://127.0.0.1/prober.php' 2>/dev/null | head -c 8192 || true)"
  [[ -n "$body" ]] && return 0
  # 兜底：X-Prober 在当前 PHP/open_basedir 组合下若始终拿不到内容，
  # 生成一个纯内置函数的完整探针（phpinfo + 扩展表），保证页面可用。
  c_warn "★ 自愈：/prober.php 当前 HTTP 取不到内容，改用内置完整探针（不读 /proc，不受 open_basedir 限制）"
  [[ -f "$WEB_ROOT/prober.php" ]] && mv -f "$WEB_ROOT/prober.php" "$WEB_ROOT/prober.xprober.bak"
  cat > "$WEB_ROOT/prober.php" <<'PHP'
<?php
header('Content-Type: text/html; charset=utf-8');
?><!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>PHP 完整探针 · armbian-nas</title></head>
<body><h1>PHP 完整探针（内置兜底）</h1>
<p>PHP 版本：<?= PHP_VERSION ?> ｜ SAPI：<?= php_sapi_name() ?> ｜ Zend：<?= zend_version() ?></p>
<h2>已加载扩展（<?= count(get_loaded_extensions()) ?>）</h2>
<ul><?php foreach (get_loaded_extensions() as $e) echo '<li>' . htmlspecialchars($e) . '</li>'; ?></ul>
<h2>phpinfo()</h2><?php phpinfo(); ?></body></html>
PHP
  chmod 644 "$WEB_ROOT/prober.php"
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  body="$(curl -fsS --max-time 8 'http://127.0.0.1/prober.php' 2>/dev/null | head -c 8192 || true)"
  if [[ -n "$body" ]]; then c_ok "  内置探针已可访问：$WEB_ROOT/prober.php"; else c_warn "  内置探针仍不可访问，请检查 nginx / php8.2-fpm"; fi
  return 0
}
samba_heal_if_needed(){
  [[ "$(component_decision samba)" == "chosen" ]] || return 0
  command -v smbd >/dev/null 2>&1 || return 0
  [[ -s "$SHARES_FILE" ]] || return 0
  local want have
  read_shares
  want=${#SHARE_LIST[@]}
  have="$(grep -c '^\[video-' /etc/samba/smb.conf 2>/dev/null || echo 0)"
  (( want > 0 )) || return 0
  (( have >= want )) && return 0
  c_warn "★ 自愈：Samba 共享段落 $have/$want 不足（通常是旧配置只含一块盘），幂等重建 smb.conf"
  if step_samba >/dev/null 2>&1; then
    systemctl restart smbd >/dev/null 2>&1 || true
    systemctl restart nmbd >/dev/null 2>&1 || true
    c_ok "  smb.conf 已重建：$(grep -c '^\[video-' /etc/samba/smb.conf 2>/dev/null || echo 0)/$want 个共享"
  else
    c_warn "  Samba 自愈失败，可单独 sudo bash $SCRIPT_PATH --repair"
  fi
  return 0
}

nav_final_regenerate(){
  if [[ ! -d "$WEB_ROOT" ]]; then
    c_info "跳过本次导航页末尾重建：$WEB_ROOT 尚不存在（首次部署跑到步骤 18 才会生成）"
    return 0
  fi
  if ! declare -F step_nav >/dev/null 2>&1; then
    c_warn "step_nav 未定义，跳过导航页末尾重建"
    return 0
  fi
  c_info "按要求：本次运行结束前重新生成一次导航页与状态页（组件状态 / 在线文档 / 本机 IP / 一键命令全部刷新）"
  if step_nav >/dev/null 2>&1; then
    c_ok "导航页与状态页已在本次运行末尾重建：$WEB_ROOT/index.html + $WEB_ROOT/status.html"
  else
    c_warn "导航页末尾重建失败（不影响已有页面）；可单独 sudo bash $SCRIPT_PATH --redo=18"
  fi
  # ★ 收尾自愈：只在「会写系统」的模式里做；--check / --status 保持只读。
  if [[ "$MODE" != "check" && "$MODE" != "status" ]]; then
    prober_heal
    samba_heal_if_needed
    qb_creds_heal
    tr_repair_403
  fi
  return 0
}

# ---- 自检 helper（防止以后又把末尾重建 / 在线文档 / IP 接口弄丢）----
# ★ SC2318 防回归：全脚本【代码行】不得出现 `local x="..." ... $x` 同行自引用。
#   bash 先展开整行再赋值，set -Eeuo pipefail 下会直接 unbound variable 退出。
#   注释里的反面教材（故意留的说明文字）以 # 开头，不会被扫到。
local_selfref_ok(){
  python3 - "$SCRIPT_PATH" <<'PY'
import sys, re
hits = 0
for ln, raw in enumerate(open(sys.argv[1], encoding='utf-8'), 1):
    st = raw.lstrip()
    if not st.startswith('local '):
        continue
    m = re.match(r'local\s+([A-Za-z_][A-Za-z0-9_]*)=', st)
    if not m:
        continue
    var = m.group(1)
    rest = st[m.end():]
    if re.search(r'\$\{?' + re.escape(var) + r'\b|\$\{' + re.escape(var) + r'[:\[}]', rest):
        hits += 1
sys.exit(1 if hits else 0)
PY
}
# ★ tmux 断线保护兜底：步骤 02 依赖清单含 tmux + 守卫处缺了自动补装（不再静默跳过）
tmux_autoinstall_ok(){
  local f="$SCRIPT_PATH" n g
  n="$(grep -n '^step_apt_base(){' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$n" ]] || return 1
  sed -n "${n},$((n+8))p" "$f" | grep -qw tmux || return 1
  # ★ 锚点必须带「行首两空格 + #」：裸字符串会先命中 helper 自己这行源码，
  #   sed 取错段导致恒 FAIL（和温控注释 / 占位符检查同源的坑）。
  g="$(grep -n '^  # SSH 断线保护：自动放进 tmux' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$g" ]] || return 1
  sed -n "${g},$((g+80))p" "$f" | grep -q '自动补装' || return 1
  sed -n "${g},$((g+80))p" "$f" | grep -q 'apt_install tmux' || return 1
  # 外层 if 不再把 command -v tmux 当必备条件（否则缺了整段跳过）
  sed -n "${g},$((g+14))p" "$f" | grep -q '&& command -v tmux' && return 1
  return 0
}
# ★ ZeroTier 安装兜底（真机：resolute 下官方脚本失败 → Unit not found）
zt_install_fallback_ok(){
  local f a b
  f="$(deployer_src)"; [[ -r "$f" ]] || return 1
  a="$(grep -n '^step_zerotier(){' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$a" ]] || return 1
  b="$(grep -n '^zt_unit_ok(){' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$b" ]] || return 1
  sed -n "${b},$((a+80))p" "$f" | grep -q 'apt_install zerotier-one' || return 1
  sed -n "${b},$((a+80))p" "$f" | grep -q 'install.zerotier.com' || return 1
  sed -n "${b},$((a+80))p" "$f" | grep -q 'zerotier-one.service' || return 1
  sed -n "${b},$((a+80))p" "$f" | grep -q '手动补装' || return 1
  return 0
}
# ★ 定向模式最小依赖兜底：跳过步骤 02 时仍保证目标步骤有基础目录/命令
targeted_prereqs_ok(){
  local f d c
  f="$(deployer_src)"; [[ -r "$f" ]] || return 1
  d="$(grep -n '^targeted_prereqs(){' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$d" ]] || return 1
  c="$(grep -n '^  targeted_prereqs$' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$c" ]] || return 1
  sed -n "${d},$((d+26))p" "$f" | grep -q 'MODE" == "deploy"' || return 1
  sed -n "${d},$((d+26))p" "$f" | grep -q 'mkdir -p "\$STATE_DIR"' || return 1
  sed -n "${d},$((d+26))p" "$f" | grep -q 'apt_install "\${missing\[@\]}"' || return 1
  return 0
}
# ★ tmux 可观测性：失败保留窗口，进会话前明确告知日志路径与 --no-tmux
tmux_visible_ok(){
  local f g
  f="$(deployer_src)"; [[ -r "$f" ]] || return 1
  g="$(grep -n '^  # SSH 断线保护：自动放进 tmux' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$g" ]] || return 1
  sed -n "${g},$((g+95))p" "$f" | grep -q 'bash -c' || return 1
  sed -n "${g},$((g+95))p" "$f" | grep -q 'exec bash -l' || return 1
  sed -n "${g},$((g+95))p" "$f" | grep -q 'tail -80 \$BOOT_LOG' || return 1
  sed -n "${g},$((g+95))p" "$f" | grep -q -- '--no-tmux --with-zerotier' || return 1
  sed -n "${g},$((g+95))p" "$f" | grep -q '\${@:3}' || return 1
  return 0
}
# ★ FileBrowser 密码策略：上游强制 ≥12 位，simple 默认值与所有显示必须一致
fb_password_policy_ok(){
  local f a b
  f="$(deployer_src)"; [[ -r "$f" ]] || return 1
  grep -q '^FB_SIMPLE_PASS="${FB_SIMPLE_PASS:-adminadmin123}"' "$f" || return 1
  grep -q '^FB_PASS_MIN=12' "$f" || return 1
  (( ${#FB_SIMPLE_PASS} >= FB_PASS_MIN )) || return 1
  # secret_get 的 simple 分支必须把 FILEBROWSER_PASS 单独返回长密码
  a="$(grep -n '^secret_get(){' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$a" ]] || return 1
  b="$(awk -v s="$a" 'NR>s && /^}/{print NR; exit}' "$f")"
  sed -n "${a},${b}p" "$f" | grep -q 'FILEBROWSER_PASS).*FB_SIMPLE_PASS' || return 1
  # fb_set_password 里必须有长度预检与中文提示
  a="$(grep -n '^fb_set_password(){' "$f" | head -1 | cut -d: -f1)"
  b="$(awk -v s="$a" 'NR>s && /^}/{print NR; exit}' "$f")"
  sed -n "${a},${b}p" "$f" | grep -q 'password is too short' || return 1
  sed -n "${a},${b}p" "$f" | grep -q '${#pw} < FB_PASS_MIN' || return 1
  # ★ 正/反面检查都锚定【状态页模板行】：全文件 grep 会先命中 helper 自己
  #   源码里同样的字符串，导致检查恒真/恒假（和温控注释、占位符、tmux 同源的坑）。
  grep -q '^    <div class="prow"><span class="plabel">FileBrowser</span><code>sudo systemctl stop armbian-filebrowser<br>' "$f" || return 1
  grep -q '^    <div class="prow"><span class="plabel">FileBrowser</span><code>sudo systemctl stop armbian-filebrowser<br>sudo filebrowser.*至少12位的新密码' "$f" || return 1
  grep -q '^    <b>FileBrowser = <code>admin / __FB_PASS__</code></b>.*密码至少 12 位' "$f" || return 1
  return 0
}
# ★ FileBrowser 改密顺序（bbolt 独占锁）：停服 → users update → 启服，且失败也拉回服务
fb_password_order_ok(){
  local f a b ss se sf sef
  f="$(deployer_src)"; [[ -r "$f" ]] || return 1
  a="$(grep -n '^fb_set_password(){' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$a" ]] || return 1
  b="$(awk -v s="$a" 'NR>s && /^}/{print NR; exit}' "$f")"
  [[ -n "$b" ]] || return 1
  sed -n "${a},${b}p" "$f" | grep -q 'systemctl stop armbian-filebrowser' || return 1
  sed -n "${a},${b}p" "$f" | grep -q 'systemctl start armbian-filebrowser' || return 1
  sed -n "${a},${b}p" "$f" | grep -q 'users update admin --password' || return 1
  sed -n "${a},${b}p" "$f" | grep -q '${#pw} < FB_PASS_MIN' || return 1
  sed -n "${a},${b}p" "$f" | grep -q '无论成败都把服务拉回来' || return 1
  # sync_simple_creds 必须走 helper，不能残留「|| true + 无条件 c_ok」
  ss="$(grep -n '^sync_simple_creds(){' "$f" | head -1 | cut -d: -f1)"
  se="$(awk -v s="$ss" 'NR>s && /^}/{print NR; exit}' "$f")"
  [[ -n "$ss" && -n "$se" ]] || return 1
  sed -n "${ss},${se}p" "$f" | grep -q 'fb_set_password "\$FB_SIMPLE_PASS"' || return 1
  sed -n "${ss},${se}p" "$f" | grep -qE 'users update admin .*\|\| true' && return 1
  # step_filebrowser 重配时也要先停服
  sf="$(grep -n '^step_filebrowser(){' "$f" | head -1 | cut -d: -f1)"
  sef="$(awk -v s="$sf" 'NR>s && /^}/{print NR; exit}' "$f")"
  [[ -n "$sf" && -n "$sef" ]] || return 1
  sed -n "${sf},${sef}p" "$f" | grep -q 'systemctl stop armbian-filebrowser' || return 1
  # 状态页模板：给三步命令，绝不再给「&& restart」的撞锁写法。
  # ★ 反面检查必须锚定【模板行首】：直接全文件 grep 那串会先命中 helper 自己
  #   这行源码，导致恒 FAIL（和温控注释 / 占位符 / tmux 注释同源的坑）。
  grep -q '^    <div class="prow"><span class="plabel">FileBrowser</span><code>sudo filebrowser' "$f" && return 1
  grep -q '^    <div class="prow"><span class="plabel">FileBrowser</span><code>sudo systemctl stop armbian-filebrowser<br>' "$f" || return 1
  grep -q 'bbolt 独占锁' "$f" || return 1
  return 0
}
# ★ 定向模式：--with-<组件> / --redo=<步骤> 只跑目标步骤，不询问、不改写其它组件状态
targeted_mode_ok(){
  local f="$SCRIPT_PATH" gs ms
  grep -q '^TARGETED=0' "$f" || return 1
  grep -q '^step_for_component(){' "$f" || return 1
  grep -q '^reset_only(){' "$f" || return 1
  grep -q '定向模式：直接执行' "$f" || return 1
  gs="$(grep -n '^component_gate(){' "$f" | head -1 | cut -d: -f1)"
  sed -n "${gs},$((gs+22))p" "$f" | grep -q 'TARGETED' || return 1
  ms="$(grep -n '定向模式：跳过 \$desc' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$ms" ]] || return 1
  return 0
}
# ★ 统一凭据 admin/admin
simple_creds_ok(){
  local f="$SCRIPT_PATH" e="$SECRETS_FILE"
  grep -q 'CRED_MODE="${CRED_MODE:-simple}"' "$f" || return 1
  grep -q 'TTYD_AUTH_USER="${TTYD_AUTH_USER:-admin}"' "$f" || return 1
  grep -q '^sync_simple_creds(){' "$f" || return 1
  [[ "${CRED_MODE:-simple}" == "simple" ]] || return 0   # random 模式不强制文件内容
  [[ -f "$e" ]] || return 1
  grep -qF 'TTYD_WEB_PASS=admin' "$e" || return 1
  grep -qF 'ARIA_RPC_SECRET=admin' "$e" || return 1
  # ★ FileBrowser 上游 ≥12 位，不能一律 admin
  grep -qF "FILEBROWSER_PASS=$FB_SIMPLE_PASS" "$e" || return 1
  return 0
}
# ★ aria2 RPC 已从首页搬到状态页
rpc_moved_ok(){
  local idx="$WEB_ROOT/index.html" st="$WEB_ROOT/status.html"
  [[ -f "$idx" && -f "$st" ]] || return 1
  grep -q 'id="rpc"' "$idx" && return 1
  grep -qF "getElementById('rpc')" "$idx" && return 1
  grep -q 'id="rpc-status"' "$st" || return 1
  grep -q '统一凭据' "$st" || return 1
  grep -q '改密方法' "$st" || return 1
  return 0
}
# ★ 收尾自愈设施存在且 check 模式不写入
final_heal_ok(){
  local f="$SCRIPT_PATH" n
  grep -q '^prober_heal(){' "$f" || return 1
  grep -q '^samba_heal_if_needed(){' "$f" || return 1
  n="$(grep -n '^nav_final_regenerate(){' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$n" ]] || return 1
  sed -n "${n},$((n+40))p" "$f" | grep -q 'prober_heal' || return 1
  sed -n "${n},$((n+40))p" "$f" | grep -q '"$MODE" != "check"' || return 1
  return 0
}
nav_final_regen_ok(){
  local ln
  ln="$(grep -n '^final_check(){' "$SCRIPT_PATH" 2>/dev/null | head -1 | cut -d: -f1)"
  [[ -n "$ln" ]] || return 1
  sed -n "${ln},$((ln+40))p" "$SCRIPT_PATH" 2>/dev/null | grep -q 'nav_final_regenerate'
}
docs_page_ok(){
  local f="$WEB_ROOT/index.html"
  [[ -f "$f" ]] || return 1
  grep -qF 'href="/docs.html"' "$f" || return 1
  grep -qF 'target="_blank"' "$f" || return 1
  [[ -s "$WEB_ROOT/docs.html" ]] || return 1
  grep -qF 'kmvan/x-prober' "$WEB_ROOT/docs.html" || return 1
  return 0
}
hostinfo_ok(){
  local f="$WEB_ROOT/index.html"
  [[ -f "$f" ]] || return 1
  [[ -s "$WEB_ROOT/hostinfo.php" ]] || return 1
  grep -qF 'net_get_interfaces' "$WEB_ROOT/hostinfo.php" || return 1
  grep -qF 'id="ip-all"' "$f" || return 1
  grep -qF 'id="ip-client"' "$f" || return 1
  grep -qF '/hostinfo.php' "$f" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 独立状态页 /status.html
#   用户要求：把「软件装在哪 / 运行状态 / SSH 命令 / 默认密码 / 路径清单」
#   从首页搬出来另开一页，首页只留快捷入口，保持整洁清爽。
#   * 与首页共用同一份 COMP JSON 快照和同一套主题变量；
#   * 卡片按「① 常用 Web → ② 媒体库与网络 → ③ 环境与后台」分组，
#     顺序与首页分区一一对应；
#   * 每张卡片【最后】新增「本脚本一键安装 / 重装 / 修复」命令 + 复制按钮，
#     例如 FileBrowser 没装就复制 --with-filebrowser --redo=22 到 SSH 执行。
#   * 纯静态、无 CDN、离线可用；装/卸软件后重新运行脚本即可刷新。
# ---------------------------------------------------------------------------
write_status_page(){
  [[ -d "$WEB_ROOT" ]] || return 1
  cat > "$WEB_ROOT/status.html" <<'STATUSPAGE'
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>armbian-nas · 软件状态与路径清单</title>
<style>
__THEME_VARS__
*{box-sizing:border-box}
body{margin:0;padding:28px 18px 60px;background:linear-gradient(180deg,var(--bg2) 0,var(--bg) 340px);
     color:var(--txt);font:15px/1.65 system-ui,-apple-system,"Segoe UI","Microsoft YaHei",sans-serif;min-height:100vh}
.wrap{max-width:1120px;margin:0 auto}
.topbar{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin-bottom:14px}
.topbar a{display:inline-block;text-decoration:none;font-size:12.5px;font-weight:600;padding:6px 13px;
  border-radius:8px;border:1px solid var(--line);background:var(--card);color:var(--txt)}
.topbar a.pri{background:var(--acc);color:#fff;border-color:var(--acc)}
h1{font-size:24px;margin:0;letter-spacing:.5px}
h1 span{color:var(--acc)}
.meta{color:var(--sub);font-size:13px;margin:8px 0 0}
.meta code{background:var(--soft);border:1px solid var(--line);padding:2px 7px;border-radius:5px;color:var(--txt)}
h2{font-size:14px;font-weight:700;color:var(--sub);margin:26px 0 12px;letter-spacing:1px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(330px,1fr));gap:14px}
.stat{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 15px;font-size:12px;line-height:1.75;
      box-shadow:0 1px 3px #16233a0a}
.stat.off{opacity:.72;border-style:dashed}
.stat b{color:var(--txt);font-size:13.5px}
.stat .hd{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:6px}
.stat .pill{font-size:10.5px;padding:1px 8px;border-radius:999px;border:1px solid var(--line);white-space:nowrap;background:var(--soft)}
.stat .on{color:var(--ok);border-color:#bfe8d5;background:#e7f6ef}
.stat .off2{color:#b45309;border-color:#f5d9a8;background:#fff6e6}
.stat .bad{color:#b91c1c;border-color:#f3c9c9;background:#fdf0f0}
.stat .line{color:var(--sub);margin:2px 0;word-break:break-word}
.stat .sec{margin:10px 0 4px;font-size:11px;font-weight:700;color:var(--sub);letter-spacing:.5px;
           border-top:1px dashed var(--line);padding-top:7px}
.stat .prow{display:flex;flex-wrap:wrap;gap:5px;align-items:baseline;margin:3px 0}
.stat .plabel{color:var(--sub);min-width:104px}
.stat code{background:var(--soft);border:1px solid var(--line);border-radius:5px;padding:1px 6px;
           color:var(--txt);font:11.5px/1.6 ui-monospace,Menlo,Consolas,monospace;word-break:break-all;flex:1;min-width:150px}
.stat button{font-size:10px;padding:1px 7px;white-space:nowrap;border:1px solid var(--line);
  background:var(--soft);color:var(--txt);border-radius:6px;cursor:pointer}
.stat button:hover{border-color:var(--acc);color:var(--acc)}
.stat .cmd code{background:#eef3fd;border-color:#cfdefa;color:#12459c}
.stat .secret{background:#fff8e8;border:1px solid #f2d9a2;border-radius:7px;padding:6px 9px;margin:4px 0;
              color:#7c4a06;word-break:break-word;font-size:12px}
.stat .secret code{background:#fff3d6;border-color:#eed6a5;color:#7c4a06}
/* ★ 一键安装命令放在卡片最下面，做得醒目一点 */
.stat .install{background:#eaf5ee;border:1px solid #bfe8d5;border-radius:8px;padding:8px 10px;margin-top:8px}
.stat .install .sec{border:0;margin:0 0 4px;padding:0;color:#136f43;font-size:11.5px}
.stat .install code{background:#fff;border-color:#bfe8d5;color:#0f5132;font-weight:600}
.stat .hint{color:var(--sub);font-size:11px;margin-top:5px}
.note{margin-top:26px;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 18px;font-size:13px;color:var(--sub)}
.note b{color:var(--txt)}
.note code{background:var(--soft);border:1px solid var(--line);padding:2px 6px;border-radius:4px;color:var(--txt)}
.groupn{font-size:11px;color:var(--sub);font-weight:400;margin-left:6px}
footer{margin-top:26px;text-align:center;color:var(--sub);font-size:12px}
@media(max-width:760px){.grid{grid-template-columns:1fr}}
</style>
</head>
<body>
<div class="wrap">
  <div class="topbar">
    <h1>armbian<span>-nas</span> · 软件状态</h1>
    <a class="pri" href="/" >← 返回导航页</a>
    <a href="/docs.html" >📖 在线脚本文档</a>
    <a href="/prober.php" >🐘 PHP 完整探针</a>
  </div>
  <div class="meta">数据目录 <code>__BASE__</code> · 本页是部署时生成的<b>静态快照</b>；装了或卸了软件后，重新运行脚本即可刷新（脚本每次运行末尾也会自动重建）。</div>

  <div class="note">
    <b>每张卡片依次列出：</b>安装 / 运行状态 → 版本、预计 eMMC 占用、访问入口
    → <b>SSH 启动 / 停止 / 重启 / 查看日志命令</b>（点「复制」直接粘到终端）
    → <b>默认密码 / 初始凭据</b>（局域网自用，明文显示）
    → <b>程序 / 配置 / 网页 / 数据 / 日志路径</b>
    → <b>【最后】本脚本一键安装 / 重装 / 修复该软件的 SSH 命令</b>。<br>
    带「当前不存在」的路径表示这个软件还没装；卡片灰掉但一键命令始终可用。
    卡片分组与首页一一对应：① 常用 Web 界面 → ② 媒体库与网络 → ③ 环境与后台。
  </div>

  <h2>① 常用 Web 界面 <span class="groupn">网页终端 · 下载器 · 文件管理器 · Docker 管理</span></h2>
  <div id="g1" class="grid"></div>
  <h2>② 媒体库与网络 <span class="groupn">DLNA / SMB / 内网穿透</span></h2>
  <div id="g2" class="grid"></div>
  <h2>③ 环境与后台 <span class="groupn">nginx / PHP / 风扇 / 休眠 / 桌面</span></h2>
  <div id="g3" class="grid"></div>

  <div class="note" style="margin-top:22px">
    <b>🔑 aria2 RPC（已从导航页搬到这里）</b><br>
    RPC 地址：<code id="rpc-status">http://-/jsonrpc</code>
    <button type="button" onclick="window.copyText(document.getElementById('rpc-status').textContent)">复制</button>
    ｜ RPC 密钥：<code>__ARIA_SECRET__</code>（AriaNg → 设置 → RPC → 密钥栏填入）<br>
    原始密钥文件：<code>__SECRETS__</code>；aria2 配置：<code>__BASE__/aria2/aria2.conf</code>。
  </div>

  <div class="note" style="margin-top:16px">
    <b>🔐 统一凭据（内网自用版默认）</b><br>
    ttyd 网页终端、aria2 RPC 密钥 = <code>admin / admin</code>；
    <b>FileBrowser = <code>admin / __FB_PASS__</code></b>（上游强制<b>密码至少 12 位</b>，
    <code>admin</code> 5 位、<code>adminadmin</code> 10 位都会被拒；自定义用 <code>--fb-password=</code>）。
    <b>qB = <code>admin / adminadmin</code></b>（脚本已把 PBKDF2 哈希写进 <code>[Preferences]</code>，中文界面，
    并关闭 Host 头校验 / CSRF / 认证子网白名单）；Transmission 默认免密，Portainer 首次自行创建密码。<br>
    qB <b>登不上时不是密码记错</b>：缺 <code>WebUI\Username</code> / <code>WebUI\Password_PBKDF2</code> 会让 qB 改用一次性临时密码，
    而 Host 头校验 / CSRF 会把拦截请求<b>伪装成密码错误</b>；跑 <code>sudo bash __SCRIPT__ --repair</code> 会停服→写两份配置→重启→真实登录自检。<br>
    <b>改密方法（复制到 SSH 执行，或在各软件 Web 界面里改）：</b>
    <div class="prow"><span class="plabel">ttyd</span><code>sudo htpasswd -bcB /etc/nginx/.ttydpasswd 新用户名 新密码 &amp;&amp; sudo systemctl reload nginx</code></div>
    <div class="prow"><span class="plabel">FileBrowser</span><code>sudo systemctl stop armbian-filebrowser<br>sudo filebrowser -d __FB_DB__ users update admin --password 至少12位的新密码<br>sudo systemctl start armbian-filebrowser</code></div>
    <div class="prow"><span class="plabel">★ 改密前先核对数据库路径</span><code>sudo systemctl cat armbian-filebrowser | grep ExecStart</code> —— 里面的 <code>-d</code> 才是服务真正在用的库；若与 <code>__FB_DB__</code> 不一致，跑 <code>sudo bash __SCRIPT__ --repair</code> 会自动迁移并统一密码。</div>
    <div class="prow"><span class="plabel">aria2 RPC</span><code>把 __SECRETS__ 的 ARIA_RPC_SECRET 与 __BASE__/aria2/aria2.conf 的 rpc-secret 改成同一个值 &amp;&amp; sudo systemctl restart aria2</code></div>
    <div class="prow"><span class="plabel">qBittorrent</span><code>WebUI → 工具 → 选项 → WebUI → 身份验证 改密；忘记密码强制重置：sudo bash __SCRIPT__ --with-qb --redo=08 --qb-password=adminadmin；自定义：--qb-password=你的密码（脚本现算 PBKDF2）</code></div>
    <div class="prow"><span class="plabel">Transmission</span><code>__BASE__/transmission/settings.json 的 rpc-username / rpc-password / rpc-authentication-required，改完 sudo systemctl restart transmission-daemon</code></div>
    <div class="prow"><span class="plabel">Portainer</span><code>WebUI → 用户管理里改；或 sudo docker restart armbian-nas-portainer 后重新设置</code></div>
    <div class="prow"><span class="plabel">恢复随机密钥</span><code>sudo bash __SCRIPT__ --creds=random --redo=21（再分别对 10 / 22 重跑）</code></div>
    <div style="margin-top:8px;color:#b45309">⚠ <b>FileBrowser 必须先停服再改密再启服</b>：它的 <code>filebrowser.db</code> 是 bbolt 独占锁，服务运行时直接执行 <code>users update</code> 会报 <code>Error: timeout</code>，密码<b>并没有改成功</b>，后面用 <code>&amp;&amp;</code> 连的 restart 也不会执行。
    <b>另一个常见错误</b>：<code>Error: password is too short, minimum length is 12</code> —— 新密码必须 ≥12 位，
    该校验发生在打开数据库之前，所以短密码连 timeout 都遇不到就被拒。<br>
    若你手动改过密码，本页显示的是脚本默认值（ttyd/aria2 <code>admin / admin</code>、FileBrowser <code>admin / __FB_PASS__</code>），
    实际以你设置的为准；状态页是部署时快照，重跑脚本会刷新。</div>
    <div style="margin-top:8px;color:#b45309">⚠ 本页明文显示密码，仅适用于可信局域网 / ZeroTier；<b>不要把 80 / 81 / 8082 端口映射到公网</b>。
    想隐藏首页与状态页的密码栏：<code>--no-nav-secrets</code>。</div>
  </div>

  <div class="note" style="margin-top:22px">
    <b>一键命令怎么用：</b>没装的软件（例如 FileBrowser）直接复制它卡片最后那条命令到 SSH 执行，
    脚本会自动从该软件那一步接着跑；已经装过的软件执行同一条命令则是幂等重配 / 修复，不会装第二份。
    <code>--with-&lt;组件&gt;</code> 表示不再询问「装不装」，<code>--redo=&lt;步骤号&gt;</code> 表示从该步重跑。<br>
    <b>断点续跑：</b><code>sudo bash __SCRIPT__ --status</code> ｜
    <b>一键修复：</b><code>sudo bash __SCRIPT__ --repair</code> ｜
    <b>仅自检：</b><code>sudo bash __SCRIPT__ --check</code><br>
    <b>最终报告：</b><code>__REPORT__</code> ｜ 密钥原文件：<code>__SECRETS__</code>
  </div>
  <footer>armbian-nas · 独立状态页 · 与导航页共用同一份组件快照 · 无外部 CDN 依赖</footer>
</div>
<script>
(function(){
  var COMP = __COMP_JSON__;
  // aria2 RPC 地址按当前访问的主机名拼接；IPv6 加方括号
  var _rh = location.hostname || '127.0.0.1';
  var _rh2 = _rh.indexOf(':') !== -1 ? '[' + _rh + ']' : _rh;
  var _rpcEl = document.getElementById('rpc-status');
  if (_rpcEl) _rpcEl.textContent = 'http://' + _rh2 + '/jsonrpc';
  Array.prototype.forEach.call(document.querySelectorAll('a'), function(a){
    a.setAttribute('target', '_blank');
    a.setAttribute('rel', 'noopener noreferrer');
  });
  function el(tag, cls, txt){
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (txt !== undefined && txt !== null) e.textContent = txt;
    return e;
  }
  window.copyText = function(t){
    function fallback(v){
      var i = document.createElement('input'); i.value = v;
      document.body.appendChild(i); i.select();
      try { document.execCommand('copy'); } catch(e) {}
      document.body.removeChild(i);
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(t).catch(function(){ fallback(t); });
    } else { fallback(t); }
  };
  function cmdRow(d, p, kind){
    var row = el('div', 'prow' + (kind ? ' ' + kind : ''));
    row.appendChild(el('span', 'plabel', p.label));
    row.appendChild(el('code', null, p.value));
    var b = el('button', null, '复制');
    b.type = 'button';
    b.onclick = function(){ window.copyText(p.value); };
    row.appendChild(b);
    d.appendChild(row);
  }
  // ★ 分组顺序与首页分区一一对应；COMP 自身也按同一 ORDER 排过序
  var GROUPS = [
    {id:'g1', keys:['ttyd','qb','transmission','aria2','filebrowser','verysync','blog','docker']},
    {id:'g2', keys:['minidlna','samba','zerotier']},
    {id:'g3', keys:['nginx','php','fan','hd_idle','gui']}
  ];
  var byKey = {};
  (COMP || []).forEach(function(c){ byKey[c.key] = c; });
  function renderCard(c){
    var installed = (c.installed === '已安装');
    var running = (c.running === '运行中');
    var d = el('div', 'stat' + (installed ? '' : ' off'));
    var hd = el('div', 'hd');
    hd.appendChild(el('b', null, c.name));
    hd.appendChild(el('span', 'pill ' + (running ? 'on' : (installed ? 'off2' : 'bad')),
                  running ? '运行中' : (installed ? '已安装·未运行' : '未安装')));
    d.appendChild(hd);
    d.appendChild(el('div', 'line', '选择：' + c.chosen + ' ｜ 安装：' + c.installed + ' ｜ 运行：' + c.running));
    d.appendChild(el('div', 'line', '版本：' + c.version + ' ｜ 预计占用 eMMC：' + c.size));
    d.appendChild(el('div', 'line', '访问入口：' + c.entry));
    if (c.cmds && c.cmds.length) {
      d.appendChild(el('div', 'sec', '⌨️ SSH 操作命令（复制到终端执行）'));
      c.cmds.forEach(function(p){ cmdRow(d, p, 'cmd'); });
    }
    if (c.creds && c.creds.length) {
      d.appendChild(el('div', 'sec', '🔑 默认密码 / 初始凭据'));
      c.creds.forEach(function(p){
        var s = el('div', 'secret');
        s.appendChild(el('div', null, p.label));
        var row = el('div', 'prow');
        row.appendChild(el('code', null, p.value));
        var b = el('button', null, '复制');
        b.type = 'button'; b.onclick = function(){ window.copyText(p.value); };
        row.appendChild(b); s.appendChild(row); d.appendChild(s);
      });
    }
    if (c.paths && c.paths.length) {
      d.appendChild(el('div', 'sec', '📁 配置与路径'));
      c.paths.forEach(function(p){ cmdRow(d, p, ''); });
    }
    // ★ 用户要求：放在卡片【最后】——本脚本一键安装 / 重装 / 修复命令
    if (c.install) {
      var box = el('div', 'install');
      box.appendChild(el('div', 'sec', '🚀 本脚本一键安装 / 重装 / 修复（复制到 SSH 执行）'));
      cmdRow(box, {label:'一键命令', value:c.install}, 'cmd');
      box.appendChild(el('div', 'hint', '未安装时用于补装；已安装时用于幂等重配 / 修复。执行后会自动从该软件那一步接着跑。'));
      d.appendChild(box);
    }
    return d;
  }
  var used = {};
  GROUPS.forEach(function(g){
    var box = document.getElementById(g.id);
    if (!box) return;
    g.keys.forEach(function(k){
      var c = byKey[k];
      if (c) { used[k] = 1; box.appendChild(renderCard(c)); }
    });
  });
  // 兜底：以后新增的组件不会因为没进分组而丢失
  var extra = document.getElementById('g3');
  (COMP || []).forEach(function(c){
    if (!used[c.key] && extra) extra.appendChild(renderCard(c));
  });
})();
</script>
</body>
</html>
STATUSPAGE
  chmod 644 "$WEB_ROOT/status.html"
  return 0
}

step_nav(){
  # 默认目录（nginx root）下的静态导航页：纯 HTML，无外部依赖，离线可用
  mkdir -p "$WEB_ROOT"
  # 旧版脚本生成过 index.php，重命名保留内容，避免抢占默认首页
  if [[ -f "$WEB_ROOT/index.php" ]]; then
    mv -f "$WEB_ROOT/index.php" "$WEB_ROOT/index.php.legacy"
    c_info "旧版 index.php 已保留为 index.php.legacy"
  fi

  # 先装完整 PHP 探针、动态磁盘接口、本机/来访 IP 接口、在线文档，再生成页面
  install_prober
  write_diskstat_php  || c_warn "动态磁盘接口生成失败，导航页会回退到静态快照"
  write_hostinfo_php  || c_warn "本机 IP 接口生成失败，导航页会回退到部署时快照"
  write_docs_page     || c_warn "在线文档生成失败，顶部链接会打开兜底说明页"

  cat > "$WEB_ROOT/index.html" <<'HTMLPAGE'
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>armbian-nas · 一键导航</title>
<style>
__THEME_VARS__
*{box-sizing:border-box}
body{margin:0;padding:28px 18px 48px;background:linear-gradient(180deg,var(--bg2) 0,var(--bg) 340px);
     color:var(--txt);font:15px/1.65 system-ui,-apple-system,"Segoe UI","Microsoft YaHei",sans-serif;min-height:100vh}
.wrap{max-width:1120px;margin:0 auto}
header{display:block;border-bottom:1px solid var(--line);padding-bottom:18px;margin-bottom:8px}
.docbar{display:flex;flex-wrap:wrap;align-items:center;gap:12px;margin-bottom:9px}
.doclink{display:inline-block;background:var(--acc);color:#fff;text-decoration:none;font-size:12.5px;font-weight:600;
  padding:6px 13px;border-radius:8px;border:1px solid var(--acc);white-space:nowrap}
.doclink.sec{background:var(--soft);color:var(--txt);border-color:var(--line)}
.doclink:hover{filter:brightness(1.07)}
.ipbar{margin:8px 0 0;padding:10px 12px;background:var(--soft);border:1px solid var(--line);border-radius:10px;
  font-size:12.5px;color:var(--sub)}
/* ★ 本机网络信息整栏可折叠，默认收起，首页更清爽 */
#ip-sec .dsum{margin:11px 0 0;font-size:13px;padding:8px 12px;box-shadow:none}
#ip-sec .dsum .groupn{font-weight:400}
.iplabel{font-weight:700;color:var(--txt);margin-right:6px}
.ipchips{display:inline-flex;flex-wrap:wrap;gap:5px;margin-right:8px;vertical-align:middle}
.ipchip{display:inline-flex;align-items:center;gap:5px;background:var(--card);border:1px solid var(--line);
  border-radius:999px;padding:2px 9px;font:11.5px/1.5 ui-monospace,Menlo,Consolas,monospace;color:var(--txt)}
.ipchip .ifn{color:var(--sub);font-size:10.5px}
.ipchip.virt{border-color:#c7d7fa;background:#eef4ff}
.ipchip.loop{opacity:.62}.ipchip.v6{font-size:10.5px}
.ipbar code{background:var(--card);border:1px solid var(--line);padding:2px 7px;border-radius:5px;color:var(--txt);
  font:11.5px/1.5 ui-monospace,Menlo,Consolas,monospace}
.ipbar button{border:1px solid var(--line);background:var(--card);color:var(--txt);border-radius:6px;
  padding:3px 9px;font-size:11.5px;cursor:pointer}
#ip-src{font-size:11px;margin-left:6px}
h1{font-size:26px;margin:0;letter-spacing:.5px}
h1 span{color:var(--acc)}
.meta{color:var(--sub);font-size:13px}
.meta code{background:var(--soft);border:1px solid var(--line);padding:2px 7px;border-radius:5px;color:var(--txt)}
.badge{display:inline-block;background:#e7f6ef;color:var(--ok);font-size:11px;padding:2px 8px;border-radius:999px;margin-left:6px;border:1px solid #bfe8d5}
h2{font-size:14px;font-weight:700;color:var(--sub);margin:26px 0 12px;letter-spacing:1px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(228px,1fr));gap:14px}
a.card{display:block;text-decoration:none;color:inherit;background:var(--card);
       border:1px solid var(--line);border-radius:14px;padding:18px 18px 16px;transition:.18s;position:relative;
       box-shadow:0 2px 8px #16233a0a}
a.card:hover{transform:translateY(-3px);border-color:var(--acc);box-shadow:0 12px 28px #16233a1c}
a.card:active{transform:translateY(-1px)}
.ico{font-size:26px;line-height:1;margin-bottom:10px;display:block}
.tt{font-weight:700;font-size:16px;margin-bottom:4px}
.ds{color:var(--sub);font-size:12.5px}
.url{color:var(--acc);font-size:12px;margin-top:10px;word-break:break-all;font-family:ui-monospace,Menlo,Consolas,monospace}
.tag{position:absolute;right:12px;top:12px;font-size:10.5px;color:var(--sub);background:var(--soft);border:1px solid var(--line);border-radius:6px;padding:1px 6px}
a.card.off{opacity:.58;filter:grayscale(.5);background:var(--soft)}
/* 灰卡片仍可点：跳到独立状态页复制「一键安装」命令 */
a.card.off:hover{transform:none;border-color:var(--acc);box-shadow:none;cursor:pointer}
.stat{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 15px;font-size:12px;line-height:1.75;
      box-shadow:0 1px 3px #16233a0a}
.stat.off{opacity:.68;border-style:dashed}
.stat b{color:var(--txt);font-size:13.5px}
.stat .hd{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:6px}
.stat .pill{font-size:10.5px;padding:1px 8px;border-radius:999px;border:1px solid var(--line);white-space:nowrap;background:var(--soft)}
.stat .on{color:var(--ok);border-color:#bfe8d5;background:#e7f6ef}
.stat .off2{color:#b45309;border-color:#f5d9a8;background:#fff6e6}
.stat .bad{color:#b91c1c;border-color:#f3c9c9;background:#fdf0f0}
.stat .line{color:var(--sub);margin:2px 0;word-break:break-word}
.stat .sec{margin:10px 0 4px;font-size:11px;font-weight:700;color:var(--sub);letter-spacing:.5px;
           border-top:1px dashed var(--line);padding-top:7px}
.stat .prow{display:flex;flex-wrap:wrap;gap:5px;align-items:baseline;margin:3px 0}
.stat .plabel{color:var(--sub);min-width:104px}
.stat code{background:var(--soft);border:1px solid var(--line);border-radius:5px;padding:1px 6px;
           color:var(--txt);font:11.5px/1.6 ui-monospace,Menlo,Consolas,monospace;word-break:break-all;flex:1;min-width:150px}
.stat button{font-size:10px;padding:1px 7px;white-space:nowrap}
.stat .cmd code{background:#eef3fd;border-color:#cfdefa;color:#12459c}
.stat .secret{background:#fff8e8;border:1px solid #f2d9a2;border-radius:7px;padding:6px 9px;margin:4px 0;
              color:#7c4a06;word-break:break-word;font-size:12px}
.stat .secret code{background:#fff3d6;border-color:#eed6a5;color:#7c4a06}
.note{margin-top:28px;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 18px;font-size:13px;color:var(--sub)}
.note b{color:var(--txt)}
.note code{background:var(--soft);border:1px solid var(--line);padding:2px 6px;border-radius:4px;color:var(--txt)}
.rowline{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:7px 0}
button{background:var(--soft);color:var(--txt);border:1px solid var(--line);border-radius:7px;padding:4px 10px;cursor:pointer;font-size:12px}
button:hover{border-color:var(--acc);color:var(--acc)}
footer{margin-top:26px;text-align:center;color:var(--sub);font-size:12px}
/* 存储概览：挂载点 / 总空间 / 剩余 / 使用率 */
.disk{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:6px 16px 14px;box-shadow:0 1px 3px #16233a0a}
.disk .drow{display:grid;grid-template-columns:minmax(150px,1.1fr) minmax(120px,1fr) 96px 96px 96px;gap:10px;
            align-items:center;padding:9px 2px;border-bottom:1px solid var(--line);font-size:13px}
.disk .drow:last-child{border-bottom:0}
.disk .dh{font-size:11px;color:var(--sub);font-weight:700;letter-spacing:.5px;background:var(--soft);border-radius:6px;padding:7px 8px}
.disk .mp{font:12.5px/1.5 ui-monospace,Menlo,Consolas,monospace;color:var(--txt);word-break:break-all}
.disk .dev{font-size:11.5px;color:var(--sub);word-break:break-all}
.disk .num{font:12.5px/1.5 ui-monospace,Menlo,Consolas,monospace;text-align:right;color:var(--txt)}
.disk .free{color:var(--ok);font-weight:700}
.bar{height:7px;border-radius:99px;background:var(--soft);border:1px solid var(--line);overflow:hidden;margin-top:5px}
.bar i{display:block;height:100%;background:var(--acc);border-radius:99px}
.bar.hot i{background:#d97706}.bar.full i{background:#dc2626}
.disk .pct{font-size:11px;color:var(--sub);margin-top:3px}
.dsum{font-size:15px;font-weight:700;color:var(--txt);cursor:pointer;list-style:none;padding:11px 16px;
      background:var(--card);border:1px solid var(--line);border-radius:12px;margin:26px 0 10px;
      display:flex;align-items:center;gap:10px;box-shadow:0 1px 3px #16233a0a;user-select:none}
.dsum::-webkit-details-marker{display:none}
.dsum::before{content:'▾';color:var(--acc);font-size:13px}
details:not([open]) .dsum::before{content:'▸'}
.live{font-size:10.5px;padding:1px 9px;border-radius:999px;border:1px solid #bfe8d5;background:#e7f6ef;color:var(--ok);font-weight:400}
.live.static{color:#b45309;border-color:#f5d9a8;background:#fff6e6}
.disk-tools{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin:9px 0 0;color:var(--sub);font-size:12px}
.disk-tools label{display:flex;align-items:center;gap:5px;cursor:pointer}
.disk-tools code{background:var(--soft);border:1px solid var(--line);padding:1px 6px;border-radius:5px;color:var(--txt)}
.groupn{font-size:11px;color:var(--sub);font-weight:400;margin-left:6px}
@media(max-width:760px){.disk .drow{grid-template-columns:1fr 1fr;gap:4px}.disk .dh{display:none}}
</style>
</head>
<body>
<div class="wrap">
<header>
  <!-- ★ 最顶端：在线脚本文档，新标签页打开，不用再开 SSH 去 cat 文件 -->
  <div class="docbar">
    <h1>armbian<span>-nas</span> · 一键导航</h1>
    <a class="doclink" href="/docs.html" target="_blank" rel="noopener noreferrer">📖 在线查看脚本文档</a>
    <a class="doclink sec" href="/armbian-nas-使用说明.md" target="_blank" rel="noopener noreferrer">⬇ 原始 Markdown</a>
  </div>
  <div class="meta">当前主机 <code id="host">-</code> · 数据目录 <code>__BASE__</code> · PHP <b>8.2</b><span class="badge">已部署</span></div>
  <!-- ★ 本机网络信息：整栏可折叠、默认折叠（用户要求首页整洁）。
       展开后显示全部本机 IP（含 ZeroTier / docker 虚拟网卡、IPv6）、
       来访主机 IP、访问地址、主机名；折叠状态下 JS 仍会定时刷新数据。 -->
  <details id="ip-sec">
  <summary class="dsum">🌐 本机网络信息 · 全部 IP / 来访主机 / 访问地址 / 主机名
    <span class="groupn">默认折叠，点击展开</span></summary>
  <div class="ipbar">
    <div><span class="iplabel">本机全部 IP</span><span class="ipchips" id="ip-all">加载中…</span>
      <button type="button" onclick="window.refreshHostInfo()">刷新</button>
      <span id="ip-src">来源：部署时快照</span></div>
    <div style="margin-top:7px">
      <span class="iplabel">来访主机 IP</span><code id="ip-client">-</code>
      <span class="iplabel" style="margin-left:10px">访问地址</span><code id="ip-http">-</code>
      <span class="iplabel" style="margin-left:10px">主机名</span><code id="ip-hostname">-</code>
    </div>
    <div id="ip-fwd" style="margin-top:6px;font-size:11px"></div>
  </div>
  </details>
</header>



<h2>① 常用 Web 界面 <span class="groupn">网页终端 · 下载器 · 文件管理器 · Docker 管理</span></h2>
<div class="grid">
  <a class="card" data-comp="ttyd" href="__TTYD_PATH__/">
    <span class="tag">终端</span><span class="ico">💻</span>
    <div class="tt">ttyd 网页终端</div><div class="ds">浏览器里直接开终端，不用再开 SSH；用户名密码见状态页卡片</div>
    <div class="url">http://<span class="h">-</span>__TTYD_PATH__/</div></a>
  <a class="card" data-comp="qb" data-port="__PORT_QB__" data-path="/" href="#">
    <span class="tag">WebUI</span><span class="ico">🧲</span>
    <div class="tt">qBittorrent</div><div class="ds">BT / 磁力下载、RSS、分类做种</div>
    <div class="url" data-url></div></a>
  <a class="card" data-comp="transmission" data-port="__PORT_TR__" data-path="/" href="#">
    <span class="tag">WebUI</span><span class="ico">📡</span>
    <div class="tt">Transmission</div><div class="ds">轻量 BT 客户端，可放 /watch 自动加种；简体中文增强界面 TrguiNG（分组 / Tracker 过滤 / 更多设置）</div>
    <div class="url" data-url></div></a>
  <a class="card" data-comp="aria2" data-path="/ariang/" href="/ariang/">
    <span class="tag">Nginx</span><span class="ico">⬇️</span>
    <div class="tt">AriaNg</div><div class="ds">aria2 网页界面，HTTP / BT / 磁力；RPC 密钥见状态页卡片</div>
    <div class="url">http://<span class="h">-</span>/ariang/</div></a>
  <a class="card" data-comp="filebrowser" data-port="__PORT_FB__" data-path="/" href="#">
    <span class="tag">文件管理</span><span class="ico">📁</span>
    <div class="tt">FileBrowser 文件管理器</div><div class="ds">网页浏览 / 上传 / 编辑两块外置硬盘的文件</div>
    <div class="url" data-url></div></a>
  <a class="card" data-comp="verysync" data-port="__PORT_VS__" data-path="/" href="#">
    <span class="tag">WebUI</span><span class="ico">🔄</span>
    <div class="tt">微力同步 Verysync</div><div class="ds">P2P 文件同步与备份</div>
    <div class="url" data-url></div></a>
  <a class="card" data-comp="blog" data-port="__PORT_BLOG__" data-path="/" href="#">
    <span class="tag">:81</span><span class="ico">📝</span>
    <div class="tt">本地博客</div><div class="ds">端口 81 独立站点，目录 boke；放进博客程序即可用（新标签页打开）</div>
    <div class="url" data-url></div></a>
  <!-- ★ 用户要求：常用 Web 界面里要有 Docker 的 Web 管理入口 -->
  <a class="card" data-comp="docker" data-port="__PORT_PORTAINER__" data-path="/" href="#">
    <span class="tag">Docker</span><span class="ico">🐳</span>
    <div class="tt">Docker Web 管理 (Portainer)</div>
    <div class="ds">容器 / 镜像 / 卷 / 日志可视化管理；装 Docker 时自动部署，首次打开自行创建 admin 密码</div>
    <div class="url" data-url></div></a>
</div>

<details id="disk-sec" open>
<summary class="dsum">💾 存储空间 · 挂载点（总空间 / 剩余空间）
  <span class="live static" id="disk-live">静态快照</span>
  <span class="groupn">已移到「常用 Web 界面」下方 · 点击标题可折叠 / 展开</span></summary>
<div class="disk" id="disk-box">
  <div class="drow dh"><span>挂载点</span><span>设备 / 文件系统</span><span style="text-align:right">总空间</span><span style="text-align:right">已用</span><span style="text-align:right">剩余</span></div>
</div>
<div class="disk-tools">
  <span>采集时间 <code id="disk-time">__DISK_TIME__</code></span>
  <span id="disk-src">来源：部署时快照</span>
  <button type="button" onclick="window.refreshDisk()">立即刷新</button>
  <label><input type="checkbox" id="disk-auto" checked> 每 5 秒自动刷新</label>
  <span>eMMC 是系统盘；<code>/mnt/sda1</code> / <code>/mnt/sdb1</code> 是外置硬盘，下载、网站、日志都在外置盘。</span>
</div>
</details>

<h2>② 媒体库与文件共享 <span class="groupn">局域网播放 / SMB</span></h2>
<div class="grid">
  <a class="card" data-comp="minidlna" data-port="__PORT_DLNA__" data-path="/" href="#">
    <span class="tag">DLNA</span><span class="ico">📺</span>
    <div class="tt">MiniDLNA 状态页</div><div class="ds">播放器在同网段搜索 <b>armbian-nas</b></div>
    <div class="url" data-url></div></a>
  <a class="card" data-comp="samba" data-smb href="#">
    <span class="tag">SMB</span><span class="ico">🗂️</span>
    <div class="tt">Samba 文件共享</div><div class="ds">共享名 video-01…；Windows 资源管理器可直接打开</div>
    <div class="url" data-url></div></a>
</div>

<h2>③ 环境与状态 <span class="groupn">不常用：探针 / nginx / PHP / ZeroTier</span></h2>
<div class="grid">
  <a class="card" data-comp="php" href="__PROBER_URL__">
    <span class="tag">环境探针</span><span class="ico">🐘</span>
    <div class="tt">PHP 完整环境探针</div><div class="ds">X-Prober 风格：phpinfo、扩展、ini、CPU / 内存 / 磁盘全站环境</div>
    <div class="url">http://<span class="h">-</span>__PROBER_URL__</div></a>
  <a class="card" data-comp="php" href="/probe.php">
    <span class="tag">核对</span><span class="ico">🔍</span>
    <div class="tt">PHP 8.2 扩展核对</div><div class="ds">分区表格逐项比对要求的扩展清单，缺哪个一目了然</div>
    <div class="url">http://<span class="h">-</span>/probe.php</div></a>
  <a class="card" data-comp="nginx" href="/">
    <span class="tag">:80</span><span class="ico">🌐</span>
    <div class="tt">nginx Web 服务器</div><div class="ds">承载本导航页、AriaNg、ttyd 反代；运行状态见状态页卡片</div>
    <div class="url">http://<span class="h">-</span>/</div></a>
  <a class="card" data-comp="zerotier" href="https://my.zerotier.com/">
    <span class="tag">外部</span><span class="ico">🌍</span>
    <div class="tt">ZeroTier Central</div><div class="ds">加入网络后需在此勾选授权本机；命令行看 zerotier-cli listnetworks</div>
    <div class="url">https://my.zerotier.com/</div></a>
  <a class="card" href="/status.php">
    <span class="tag">备用</span><span class="ico">📄</span>
    <div class="tt">备用状态页</div><div class="ds">站点目录、RPC 说明、报告路径</div>
    <div class="url">http://<span class="h">-</span>/status.php</div></a>
</div>

<!-- ★ 用户要求：详细状态/路径/命令另开页面，首页保持整洁清爽 -->
<h2>④ 软件状态与路径清单 <span class="groupn">新标签页打开独立页面</span></h2>
<div class="grid">
  <a class="card" href="/status.html">
    <span class="tag">详情页</span><span class="ico">🗂️</span>
    <div class="tt">软件装在哪 · 运行状态 · 一键安装命令</div>
    <div class="ds">每张卡片依次列出：安装/运行状态 → SSH 启停 / 重启 / 日志命令 → 默认密码 / 初始凭据
      → 程序 / 配置 / 网页 / 数据 / 日志路径 → 【最后】本脚本一键安装 / 重装 / 修复该软件的 SSH 命令。
      点开新标签页查看；未装的软件在这里复制命令即可补装。</div>
    <div class="url">http://<span class="h">-</span>/status.html</div></a>
</div>

<div class="note">
  <b>aria2 RPC 地址与密钥已移到「状态页」</b>（<code>/status.html</code> 的 aria2 卡片与「统一凭据」区块），本页保持清爽。
  <div class="rowline" style="margin-top:14px"><b>断点续跑</b> <code>sudo bash __SCRIPT__ --status</code>
    <code>sudo bash __SCRIPT__ --check</code></div>
  <div class="rowline"><b>最终报告</b> <code>__REPORT__</code>
    · <b>部署日志</b> <code>__BASE__/logs/deploy.log</code></div>
  <div class="rowline"><span>若换 IP 或用域名访问，本页会自动按当前地址拼接端口，无需重新生成。</span></div>
</div>

<footer>armbian-nas · 静态导航页 · 白色明亮主题 · 详细状态见 /status.html · 无外部 CDN 依赖</footer>
</div>
<script>
(function(){
  // 部署时内嵌的三份快照：组件状态 / 命令 / 密码 / 路径，以及磁盘容量。
  // 页面纯静态、不联网、不需要后端；重新部署或卸载后刷新。
  var COMP = __COMP_JSON__;
  var DISK = __DISK_JSON__;
  // 部署时采集的本机 IP 静态快照；/hostinfo.php 可用时会被动态结果覆盖
  var HOST = __HOST_IPS_JSON__;
  // ★ 所有卡片一律【新标签页】打开，保留导航页不跳走；noopener 防反向控制
  Array.prototype.forEach.call(document.querySelectorAll('a.card'), function(a){
    a.setAttribute('target', '_blank');
    a.setAttribute('rel', 'noopener noreferrer');
  });
  var raw = location.hostname || '127.0.0.1';
  var host = raw.indexOf(':') !== -1 ? '[' + raw + ']' : raw;   // 兼容 IPv6
  document.getElementById('host').textContent = raw;
  Array.prototype.forEach.call(document.querySelectorAll('.h'), function(e){ e.textContent = host; });
  Array.prototype.forEach.call(document.querySelectorAll('[data-port]'), function(a){
    var p = a.getAttribute('data-port'), path = a.getAttribute('data-path') || '/';
    var u = 'http://' + host + ':' + p + path;
    a.href = u;
    var d = a.querySelector('[data-url]'); if (d) d.textContent = u;
  });
  var smb = document.querySelector('[data-smb]');
  if (smb) {
    smb.href = 'smb://' + host + '/';
    smb.querySelector('[data-url]').textContent = 'smb://' + host + '/   （Windows: \\\\' + raw + '\\）';
  }
  window.cp = function(id){
    var t = document.getElementById(id).textContent;
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(t).catch(function(){ fallback(t); });
    } else { fallback(t); }
  };
  function fallback(t){
    var i = document.createElement('input'); i.value = t;
    document.body.appendChild(i); i.select();
    try { document.execCommand('copy'); } catch(e) {}
    document.body.removeChild(i);
  }
  window.copyText = function(t){
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(t).catch(function(){ fallback(t); });
    } else { fallback(t); }
  };
  function el(tag, cls, txt){
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (txt !== undefined && txt !== null) e.textContent = txt;
    return e;
  }
  function hsize(n){
    if (!n && n !== 0) return '-';
    var u = ['B','KB','MB','GB','TB'], i = 0;
    while (n >= 1024 && i < 4) { n /= 1024; i++; }
    return n.toFixed(2) + ' ' + u[i];
  }
  function jesc(t){
    return String(t === null || t === undefined ? '' : t)
      .replace(/[&<>"']/g, function(c){
        return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];
      });
  }

  // ---- 本机全部 IP（含虚拟网卡 / IPv6）+ 来访主机 IP ----
  // 初始先用部署时快照渲染，保证 /hostinfo.php 不可用时页面也不空；
  // 之后 fetch 动态接口拿到真实网卡列表与 $_SERVER['REMOTE_ADDR']。
  window.renderHostInfo = function(j){
    var box = document.getElementById('ip-all');
    if (!box) return;
    var chips = [];
    var ifs = (j && j.interfaces) || [];
    ifs.forEach(function(it){
      var nm = it.name || '';
      (it.addrs || []).forEach(function(a){
        var addr = (typeof a === 'string') ? a : (a && a.address);
        if (!addr) return;
        var cls = 'ipchip';
        if (nm === 'lo' || addr === '127.0.0.1' || addr === '::1') cls += ' loop';
        else if (/^(zt|docker|veth|br-|tun|tap|wg|virbr|tailscale|tunl|ip6tnl)/.test(nm)) cls += ' virt';
        if ((a && a.family) === 'IPv6' || addr.indexOf(':') !== -1) cls += ' v6';
        chips.push('<span class="' + cls + '" title="' + jesc(nm) + '">' +
                   '<span class="ifn">' + jesc(nm) + '</span>' + jesc(addr) + '</span>');
      });
    });
    box.innerHTML = chips.length ? chips.join('') : '<span class="ipchip">（未采集到 IP）</span>';
    var set = function(id, v){ var e = document.getElementById(id); if (e) e.textContent = v; };
    set('ip-client', (j && j.client_ip && j.client_ip !== '-') ? j.client_ip : '（需 /hostinfo.php）');
    set('ip-http', (j && j.http_host) ? j.http_host : location.host);
    set('ip-hostname', (j && j.hostname) ? j.hostname : (location.hostname || '-'));
    var fwd = document.getElementById('ip-fwd');
    if (fwd) fwd.textContent = (j && j.forwarded_for)
      ? '代理头 X-Forwarded-For：' + j.forwarded_for + '（仅在你确实走了反向代理时可信）' : '';
  };
  window.refreshHostInfo = function(){
    fetch('/hostinfo.php', {cache:'no-store'})
      .then(function(r){ if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
      .then(function(j){
        window.renderHostInfo(j);
        var e = document.getElementById('ip-src');
        if (e) e.textContent = '来源：/hostinfo.php（实时） · ' + (j.time || '');
      })
      .catch(function(e){
        var el2 = document.getElementById('ip-src');
        if (el2) el2.textContent = '来源：部署时快照（/hostinfo.php 不可达：' + e.message + '）';
      });
  };
  window.renderHostInfo(HOST || {});
  window.refreshHostInfo();
  setInterval(window.refreshHostInfo, 10000);

  // ---- 存储概览：可折叠 + /diskstat.php 每 5 秒动态刷新 ----
  // 初始先用部署时内嵌的静态快照渲染，保证 PHP 接口不可用时页面也不空。
  var dbox = document.getElementById('disk-box');
  window.renderDisk = function(list, timeText, live){
    if (!dbox) return;
    while (dbox.children.length > 1) dbox.removeChild(dbox.lastChild);
    if (!list || !list.length) {
      dbox.appendChild(el('div', 'drow', '未采集到磁盘信息（重新运行脚本 --redo=18 刷新）'));
      return;
    }
    list.forEach(function(d){
      var r = el('div', 'drow');
      var c1 = el('div');
      c1.appendChild(el('div', 'mp', d.path));
      c1.appendChild(el('div', 'dev', d.dev + ' · ' + d.fstype));
      r.appendChild(c1);
      r.appendChild(el('div', 'dev', d.path === '/' ? '系统盘 eMMC' : '外置硬盘'));
      r.appendChild(el('div', 'num', hsize(d.total)));
      r.appendChild(el('div', 'num', hsize(d.used)));
      var c5 = el('div');
      c5.appendChild(el('div', 'num free', hsize(d.free)));
      var bar = el('div', 'bar' + (d.pct >= 90 ? ' full' : (d.pct >= 75 ? ' hot' : '')));
      var fill = el('i'); fill.style.width = Math.min(100, Math.max(0, d.pct)) + '%';
      bar.appendChild(fill); c5.appendChild(bar);
      c5.appendChild(el('div', 'pct', '已用 ' + d.pct + '%'));
      r.appendChild(c5);
      dbox.appendChild(r);
    });
    var t = document.getElementById('disk-time'); if (t && timeText) t.textContent = timeText;
    var src = document.getElementById('disk-src');
    if (src) src.textContent = live ? '来源：/diskstat.php（实时）' : '来源：部署时快照';
    var b = document.getElementById('disk-live');
    if (b) { b.textContent = live ? '实时刷新中' : '静态快照'; b.className = 'live' + (live ? '' : ' static'); }
  };
  window.refreshDisk = function(){
    fetch('/diskstat.php', {cache:'no-store'})
      .then(function(r){ if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
      .then(function(j){ window.renderDisk(j.items || [], j.time, true); })
      .catch(function(e){
        var b = document.getElementById('disk-live');
        if (b) { b.textContent = '动态接口不可用 · 显示快照'; b.className = 'live static'; }
        var src = document.getElementById('disk-src');
        if (src) src.textContent = '来源：部署时快照（/diskstat.php 不可达：' + e.message + '）';
      });
  };
  window.renderDisk(Array.isArray(DISK) ? DISK : ((DISK && DISK.items) || []), '__DISK_TIME__', false);
  window.refreshDisk();
  setInterval(function(){
    var a = document.getElementById('disk-auto');
    if (a && a.checked) window.refreshDisk();
  }, 5000);

  // ★ 详细状态卡片已搬到独立页面 /status.html，首页只保留 byKey 用于置灰判断。
  //   两个页面共用同一份 COMP 快照，卡片顺序与分组一一对应。
  var byKey = {};
  (COMP || []).forEach(function(c){ byKey[c.key] = c; });

  // ---- 顶部快捷卡片：没装的软件灰掉，但【点击可跳状态页复制一键安装命令】----
  //   用户明确要求：FileBrowser 之类没装时，要能一眼看到「用什么命令装」。
  Array.prototype.forEach.call(document.querySelectorAll('[data-comp]'), function(a){
    var c = byKey[a.getAttribute('data-comp')];
    if (!c || c.installed !== '已安装') {
      a.classList.add('off');
      a.setAttribute('href', '/status.html');
      var u = a.querySelector('[data-url]');
      if (u) u.textContent = '未安装 · 点此打开状态页，复制「一键安装」命令';
    }
  });
})();
</script>
</body>
</html>
HTMLPAGE

  # ★ 独立状态页 /status.html：详细卡片、路径、SSH 命令、一键安装命令都在这里
  if write_status_page; then
    c_ok "独立状态页模板已生成：$WEB_ROOT/status.html（稍后注入组件快照）"
  else
    c_warn "状态页生成失败；首页仍可用，可 --redo=18 重建"
  fi

  # 所有页面通用占位符一起替换（index.html + status.html）
  local _pages=( "$WEB_ROOT/index.html" )
  [[ -f "$WEB_ROOT/status.html" ]] && _pages+=( "$WEB_ROOT/status.html" )
  sed -i \
    -e "s|__BASE__|$BASE|g" \
    -e "s|__FB_DB__|$FB_DB|g" \
    -e "s|__SCRIPT__|$SCRIPT_PATH|g" \
    -e "s|__REPORT__|$REPORT_FILE|g" \
    -e "s|__SECRETS__|$SECRETS_FILE|g" \
    -e "s|__ARIA_SECRET__|$(secret_get ARIA_RPC_SECRET)|g" \
    -e "s|__FB_PASS__|$(secret_get FILEBROWSER_PASS)|g" \
    -e "s|__PORT_QB__|$PORT_QB|g" \
    -e "s|__PORT_TR__|$PORT_TR|g" \
    -e "s|__PORT_VS__|$PORT_VS|g" \
    -e "s|__PORT_DLNA__|$PORT_DLNA|g" \
    -e "s|__PORT_FB__|$PORT_FB|g" \
    -e "s|__PORT_BLOG__|$PORT_BLOG|g" \
    -e "s|__PORT_PORTAINER__|$PORT_PORTAINER|g" \
    -e "s|__TTYD_PATH__|$TTYD_PATH|g" \
    -e "s|__PROBER_URL__|/prober.php|g" \
    -e "s|__DISK_TIME__|$(date '+%Y-%m-%d %H:%M:%S')|g" \
    "${_pages[@]}"

  # 把组件快照、磁盘快照、主题变量一起注入。用 python 做替换而不是 sed：
  # JSON / 路径里可能有 | / \ 等字符；component_snapshot_json 已把 < > & 转义。
  local _json_tmp _disk_tmp _host_tmp _json_err
  _json_tmp="$(mktemp)"; _disk_tmp="$(mktemp)"; _host_tmp="$(mktemp)"; _json_err="$(mktemp)"
  if ! component_snapshot_json > "$_json_tmp" 2>"$_json_err" || [[ ! -s "$_json_tmp" ]]; then
    printf '[]\n' > "$_json_tmp"
    c_warn "组件状态快照生成失败，首页状态区块将为空；可 --redo=18 重建"
    c_warn "失败原因：$(head -c 300 "$_json_err" 2>/dev/null | tr '\n' ' ')"
  fi
  if ! disk_snapshot_json > "$_disk_tmp" 2>>"$_json_err" || [[ ! -s "$_disk_tmp" ]]; then
    printf '[]\n' > "$_disk_tmp"
    c_warn "磁盘容量快照采集失败，首页存储区块将为空；可 --redo=18 重建"
  fi
  if ! host_ips_static_json > "$_host_tmp" 2>>"$_json_err" || [[ ! -s "$_host_tmp" ]]; then
    printf '{"interfaces":[],"client_ip":"-"}\n' > "$_host_tmp"
    c_warn "本机 IP 静态快照采集失败，首页会等 /hostinfo.php 动态补齐"
  fi
  # ★ 两个页面共用同一份 COMP 快照：首页用它判断快捷卡片是否置灰，
  #   状态页用它渲染详细卡片与一键安装命令，顺序天然一致。
  python3 - "$WEB_ROOT/index.html" "$WEB_ROOT/status.html" "$_json_tmp" "$_disk_tmp" "$_host_tmp" "$NAV_THEME" <<'PY'
import sys, os
pages = sys.argv[1:3]
comp_path, disk_path, host_path, theme = sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
with open(comp_path, 'r', encoding='utf-8') as f:
    comp = f.read().strip() or '[]'
with open(disk_path, 'r', encoding='utf-8') as f:
    disk = f.read().strip() or '[]'
with open(host_path, 'r', encoding='utf-8') as f:
    host = f.read().strip().replace('<', '\\u003c') or '{}'
light = ("--bg:#f4f7fb;--bg2:#eaf1fb;--card:#ffffff;--soft:#f1f5fb;--txt:#16233a;"
         "--sub:#5b6b82;--line:#dbe3ee;--acc:#1d64d8;--ok:#059669")
dark  = ("--bg:#0f172a;--bg2:#16233a;--card:#1e293b;--soft:#243449;--txt:#e2e8f0;"
         "--sub:#94a3b8;--line:#334155;--acc:#38bdf8;--ok:#34d399")
theme_vars = ':root{' + (dark if theme == 'dark' else light) + '}'
for page in pages:
    if not os.path.isfile(page):
        continue
    with open(page, 'r', encoding='utf-8') as f:
        html = f.read()
    html = html.replace('__THEME_VARS__', theme_vars)
    html = html.replace('__COMP_JSON__', comp)
    html = html.replace('__DISK_JSON__', disk)
    html = html.replace('__HOST_IPS_JSON__', host)
    with open(page, 'w', encoding='utf-8') as f:
        f.write(html)
PY
  rm -f "$_json_tmp" "$_disk_tmp" "$_host_tmp" "$_json_err"
  chmod 644 "$WEB_ROOT/index.html"
  [[ -f "$WEB_ROOT/status.html" ]] && chmod 644 "$WEB_ROOT/status.html"
  http_ok "http://127.0.0.1/" || c_warn "本机 HTTP 暂未返回 2xx/3xx，请检查 nginx 与默认站点"
  c_ok "导航页：$WEB_ROOT/index.html（白色明亮 · 在线文档 · IP 默认折叠 · 常用 Web 含 Docker 管理 · 存储概览下移 · 状态页入口）"
  c_ok "独立状态页：$WEB_ROOT/status.html（SSH 命令 · 默认密码 · 路径清单 · 每卡片末尾一键安装/重装命令）"
  c_ok "完整 PHP 探针：$WEB_ROOT/prober.php（X-Prober 上游单文件，署名见说明文档「开源组件与致谢」）"
  c_ok "在线脚本文档：$WEB_ROOT/docs.html（顶部「📖 在线查看脚本文档」新标签页直达）"
}

# ------------------------------ 步骤 19：eMMC 瘦身与 PHP 安全基线 -------------
# 绝对不能写进 disable_functions 的函数：脚本自身、扩展、进程/IPC/网络都要用
PHP_KEEP_FUNCS="file_get_contents,fopen,fread,fwrite,file,is_readable,glob,scandir,get_loaded_extensions,function_exists,ini_get,php_sapi_name,exec,shell_exec,system,passthru,proc_open,proc_close,popen,escapeshellarg,pcntl_fork,pcntl_exec,pcntl_wait,pcntl_signal,posix_kill,posix_getpid,posix_setuid,shmop_open,shmop_read,sem_get,sem_acquire,msg_get_queue,socket_create,socket_connect,stream_socket_client,fsockopen,imap_open,curl_init,curl_exec,curl_setopt,opcache_get_status,opcache_reset,opcache_invalidate,exif_read_data,finfo_open,gmp_init,mb_strlen,json_encode,json_decode,preg_replace,preg_match,sqlite3_open,pdo_sqlite"

relocate_dir(){ # 把系统盘上的可再生缓存目录迁到外置盘并留软链（幂等）
  local src="$1" dst="$2"
  mkdir -p "$dst"
  if [[ -L "$src" ]]; then
    [[ "$(readlink -f "$src" 2>/dev/null || true)" == "$dst" ]] && { c_ok "已迁移：$src → $dst"; return 0; }
    rm -f "$src"
  elif [[ -d "$src" ]]; then
    cp -a "$src/." "$dst/" 2>/dev/null || true
    rm -rf "$src"          # apt 缓存/lists 均可再生，不占 eMMC
  fi
  ln -sfn "$dst" "$src"
  c_ok "已迁移：$src → $dst"
}

docker_daemon_baseline(){ # 幂等合并 daemon.json，返回是否需要重启 docker
  mkdir -p /etc/docker
  local p=/etc/docker/daemon.json before after
  before="$(cat "$p" 2>/dev/null || true)"
  python3 - "$p" "$DOCKER_LOG_MAX_SIZE" "$DOCKER_LOG_MAX_FILE" <<'PY'
import json, sys
p, ms, mf = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(p, 'r', encoding='utf-8') as f:
        d = json.load(f)
    if not isinstance(d, dict): d = {}
except Exception:
    d = {}
d['log-driver'] = 'json-file'
o = d.get('log-opts') or {}
if not isinstance(o, dict): o = {}
o['max-size'] = ms
o['max-file'] = mf
d['log-opts'] = o
with open(p, 'w', encoding='utf-8') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write('\n')
PY
  after="$(cat "$p" 2>/dev/null || true)"
  if [[ "$before" == "$after" ]]; then
    c_ok "Docker 日志轮转已生效（max-size=$DOCKER_LOG_MAX_SIZE × $DOCKER_LOG_MAX_FILE），无需重启"
    return 1
  fi
  c_ok "已写 /etc/docker/daemon.json：log-opts max-size=$DOCKER_LOG_MAX_SIZE max-file=$DOCKER_LOG_MAX_FILE"
  return 0
}

docker_rebuild_for_logconfig(){
  # daemon.json 的日志配置只对「新建容器」生效；存量容器需 recreate 才继承新设置。
  # qB / Transmission 已改为 apt 原生安装；脚本创建的容器只有 Portainer
  # （docker_portainer_setup，装 Docker 时才带）。这里只检查并提示，
  # 绝不擅自删除或重建你自己的容器。
  if ! component_chosen docker; then
    c_info "Docker 组件已跳过，跳过容器日志检查"
    return 0
  fi
  command -v docker >/dev/null 2>&1 || { c_info "Docker 尚未安装，跳过容器日志检查"; return 0; }
  docker info >/dev/null 2>&1 || { c_warn "Docker 未就绪，跳过容器日志检查"; return 0; }
  local ids id nm cur stale=""
  ids="$(docker ps -aq 2>/dev/null || true)"
  for id in $ids; do
    cur="$(docker inspect -f '{{index .HostConfig.LogConfig.Config "max-size"}}' "$id" 2>/dev/null || true)"
    [[ "$cur" == "$DOCKER_LOG_MAX_SIZE" ]] && continue
    nm="$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null || echo "$id")"
    stale+=" ${nm#/}"
  done
  if [[ -z "$stale" ]]; then
    c_ok "Docker 容器日志配置已符合（或暂无容器），无需重建"
  else
    c_warn "以下存量容器仍用创建时的日志配置：${stale# }（daemon.json 只对新容器生效）"
    c_info "如需生效请自行重建：docker rm -f <容器> 后重新 docker run，或 docker compose up -d --force-recreate"
  fi
}

docker_external_setup(){
  # 可选：把 /var/lib/docker 整体迁到「NTFS 里的 ext4 loop 镜像」
  # NTFS 不支持 overlay2 所需的 d_type / upperdir / xattr 语义，直接 --data-root 到
  # /mnt/sda1/www 会启动失败或被迫退回 vfs（极慢、空间翻倍）。loop-ext4 是唯一
  # 能同时保住 overlay2 与「数据在外置盘」的做法；代价是 USB 掉盘/断电有风险，
  # 故默认关闭，且开机依赖用 Wants（软依赖）——挂不上时 Docker 仍能用 eMMC 正常起。
  [[ "$DOCKER_EXTERNAL" -eq 1 ]] || return 0
  command -v docker >/dev/null 2>&1 || { c_warn "Docker 未安装，跳过 data-root 外置"; return 0; }
  local mp=/var/lib/docker
  mkdir -p "$(dirname "$DOCKER_LOOP_IMG")"

  cat > "$DOCKER_EXT_HELPER" <<'HELPER'
#!/usr/bin/env bash
# 由 armbian-nas 步骤 19 生成：把 ext4 loop 镜像挂到 /var/lib/docker
set -u
IMG="__IMG__"
MP="/var/lib/docker"
DEVFILE="/run/armbian-docker-loop.dev"
attach(){
  [[ -f "$IMG" ]] || exit 1
  findmnt -rn --target "$MP" >/dev/null 2>&1 && exit 0
  local dev
  dev="$(losetup -f --show "$IMG" 2>/dev/null)" || exit 1
  printf '%s\n' "$dev" > "$DEVFILE"
  if ! mount -o noatime,commit=60 "$dev" "$MP" 2>/dev/null; then
    losetup -d "$dev" 2>/dev/null || true
    rm -f "$DEVFILE"
    exit 1
  fi
}
detach(){
  local dev; dev="$(cat "$DEVFILE" 2>/dev/null || true)"
  umount "$MP" 2>/dev/null || true
  [[ -n "$dev" ]] && losetup -d "$dev" 2>/dev/null || true
  rm -f "$DEVFILE"
}
case "${1:-}" in attach) attach;; detach) detach;; *) exit 2;; esac
HELPER
  sed -i "s|__IMG__|$DOCKER_LOOP_IMG|g" "$DOCKER_EXT_HELPER"
  chmod 755 "$DOCKER_EXT_HELPER"

  cat > "/etc/systemd/system/$DOCKER_EXT_UNIT" <<EOF
[Unit]
Description=armbian-nas: ext4 loop image on external disk for Docker data-root
RequiresMountsFor=$MOUNT_MAIN
After=local-fs.target
Before=docker.service containerd.service
ConditionPathExists=$DOCKER_LOOP_IMG

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$DOCKER_EXT_HELPER attach
ExecStop=$DOCKER_EXT_HELPER detach
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF
  # 软依赖：外置盘没插 / loop 挂不上时，Docker 照常启动并使用 eMMC 上的旧目录
  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/10-armbian-nas-external.conf <<EOF
[Unit]
Wants=$DOCKER_EXT_UNIT
After=$DOCKER_EXT_UNIT
EOF
  systemctl daemon-reload

  if [[ ! -f "$DOCKER_LOOP_IMG" ]]; then
    c_info "创建 ext4 loop 镜像 $DOCKER_LOOP_IMG（$DOCKER_LOOP_SIZE，NTFS 上的单个文件，不动分区）"
    truncate -s "$DOCKER_LOOP_SIZE" "$DOCKER_LOOP_IMG" \
      || { c_warn "truncate 失败，跳过 data-root 外置"; return 0; }
    mkfs.ext4 -F -q "$DOCKER_LOOP_IMG" \
      || { c_warn "mkfs.ext4 失败，跳过 data-root 外置"; rm -f "$DOCKER_LOOP_IMG"; return 0; }
  fi

  if ! findmnt -rn --target "$mp" >/dev/null 2>&1; then
    c_info "首次启用：迁移现有镜像层到 loop-ext4（约 1–2GB，USB 盘上请耐心）"
    systemctl stop docker containerd 2>/dev/null || true
    rm -rf "${mp}.emmc-bak"
    [[ -d "$mp" && ! -L "$mp" ]] && mv "$mp" "${mp}.emmc-bak"
    mkdir -p "$mp"
    if ! "$DOCKER_EXT_HELPER" attach; then
      c_warn "loop 挂载失败 → 自动回退到 eMMC，Docker 不受影响"
      rmdir "$mp" 2>/dev/null || true
      [[ -d "${mp}.emmc-bak" ]] && mv "${mp}.emmc-bak" "$mp"
      rm -f /etc/systemd/system/docker.service.d/10-armbian-nas-external.conf
      systemctl daemon-reload
      systemctl start docker 2>/dev/null || true
      return 0
    fi
    if [[ -d "${mp}.emmc-bak" ]]; then
      cp -a "${mp}.emmc-bak/." "$mp/" 2>/dev/null \
        || c_warn "旧镜像层拷贝失败，容器会重新拉取（配置卷仍在 $BASE，不丢数据）"
      c_info "旧目录保留为 ${mp}.emmc-bak，确认一切正常后可自行删除释放 eMMC"
    fi
  else
    c_ok "$mp 已挂载（loop-ext4），跳过迁移"
  fi
  systemctl enable "$DOCKER_EXT_UNIT" >/dev/null 2>&1 || true
  systemctl start "$DOCKER_EXT_UNIT" >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || true
  local fst
  fst="$(stat -f -c %T "$mp" 2>/dev/null || echo unknown)"
  if [[ "$fst" == "ext4" ]]; then
    c_ok "Docker data-root 已落在外置盘：$mp（$fst / overlay2 可用）"
    c_warn "USB 拔盘或意外断电可能损坏容器层；${mp}.emmc-bak 是回退保险，稳定后再删"
  else
    c_warn "$mp 文件系统=$fst（非 ext4），请检查；Docker 仍在运行不影响服务"
  fi
}

# ===========================================================================
#              zram 优先 / 磁盘 swapfile 兜底  （步骤 19 调用）
# ---------------------------------------------------------------------------
# 目标：8G eMMC + 512M swapfile 的机器，BT 多连接时别动不动就往 eMMC 写。
#   zram = 内存里的压缩 swap，快几个数量级、完全不碰 eMMC；
#   磁盘 swapfile 保留（休眠需要它，且是 OOM 前的最后兜底），但优先级调低。
#
# 【优先级怎么比】swapon 的 pri 数字越大越先用。
#   Armbian 老镜像：armbian-zram-config.service → zram pri=5，磁盘 -2
#   新版 Ubuntu/Debian：zram-tools（/etc/default/zramswap 的 PRIORITY=100）
#                       或 systemd-zram-generator（swap-priority=100）
#   脚本的通用做法：不管 zram 由谁管、pri 是 5 还是 100，都把 fstab 里所有
#   「磁盘型 swap」行改成 pri=-2 —— 这样 zram 一定排前面，且不用去猜各发行版
#   配置文件的变量名（写错了会被静默忽略，反而不稳）。
#
# 【vm.swappiness 的内核差异】
#   内核 < 5.8：上限 100，写 150 会报 Invalid argument；
#   内核 >= 5.8：上限放宽到 200，专门给 zram/zswap 这类内存 swap 用，
#                 官方内核文档建议 >100（常见 150~180）。
#   脚本用 sysctl -w 实测探测，失败自动回落 100，绝不假装成功。
#   有 zram 时另设 vm.page-cluster=0（内存 swap 没有寻道，预读纯浪费）。
#   没有 zram 时保持 10：此时提高 swappiness 等于疯狂写 eMMC，适得其反。
#
# 【稳定性边界】
#   * 只识别、不覆盖 Armbian 自带 zram 服务的大小/算法（它还管着 /var/log 的 zram）
#   * 绝不重复安装第二套管理器去抢 /dev/zram0
#   * 磁盘 swap 当前 USED>0 时绝不 swapoff（可能触发 OOM），只写 fstab 等重启
#   * 不删任何 swap 文件；zram 不能用于休眠，磁盘 swap 必须留着
#   * zswap 与 zram 同时开会重复压缩：只提示，不擅自关闭用户的内核参数
# ===========================================================================
SWAP_FSTAB_BAK="/etc/fstab.bak.armbian-nas-swap"

swap_table(){
  swapon --show=NAME,TYPE,PRIO,USED --noheadings 2>/dev/null || \
  awk 'NR>1{printf "%s %s %s %s\n", $1, $2, $5, $4}' /proc/swaps 2>/dev/null
}

zram_active(){
  grep -q '^/dev/zram' /proc/swaps 2>/dev/null
}

zram_owner(){
  local u
  u="$(systemctl list-unit-files --no-legend 2>/dev/null || true)"
  if grep -qi 'armbian-zram-config' <<< "$u"; then echo armbian
  elif [[ -f /etc/default/zramswap ]] || grep -qi 'zramswap\.service' <<< "$u"; then echo zram-tools
  elif [[ -f /etc/systemd/zram-generator.conf ]] || grep -qi 'systemd-zram-setup@' <<< "$u"; then echo generator
  else echo none; fi
}

# 内存总量（MiB）。1G 内存的 S905X 必须用它来限 zram 大小与 php-fpm 进程数。
mem_total_mib(){
  awk '/MemTotal:/{printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null || echo 0
}
is_low_mem(){
  local m; m="$(mem_total_mib)"
  [[ "$m" -gt 0 && "$m" -le "$LOW_MEM_MIB" ]]
}

# 计算 zram 目标大小（KiB）。低内存机器自动把比例从 50% 降到 25%，
# 并夹在 64M~512M 之间 —— 1G RAM 给 512M zram 反而会挤掉可用内存。
zram_target_kib(){
  local kb pct
  # 统一走 mem_total_mib，避免和 is_low_mem 判断读到两套不同的内存数值
  local m
  m="$(mem_total_mib)"; (( m > 0 )) || m=1024
  kb=$(( m * 1024 ))
  pct="$ZRAM_SIZE_PERCENT"
  is_low_mem && pct=25
  local sz=$(( kb * pct / 100 ))
  (( sz < 65536 )) && sz=65536
  (( sz > 524288 )) && sz=524288
  echo "$sz"
}

# 最后兜底：不依赖任何发行版包，直接用内核 zram 自建一个 oneshot 服务。
# 部分旧发行版源里【没有】zram-tools（Ubuntu 22.04 系 / Armbian 23.x 常见；
# Debian 12 / Ubuntu 24.04+ / 26.04 resolute 一般有），只装一个包会静默失败。
zram_native_unit(){
  local sz algo
  sz="$(zram_target_kib)"; algo="$ZRAM_ALGO"
  # 内核不支持指定算法时退回 lz4（S905X 老四核，lz4 也最省 CPU）
  cat > /usr/local/sbin/armbian-zram-setup <<EOF
#!/usr/bin/env bash
# armbian-nas 自建 zram（无 zram-tools / generator 可用时的兜底）
set -u
SIZE_KB=$sz
ALGO=$algo
modprobe zram num_devices=1 >/dev/null 2>&1 || exit 0
if grep -q "^/dev/zram0 " /proc/swaps 2>/dev/null; then exit 0; fi
if [[ -w /sys/block/zram0/comp_algorithm ]]; then
  if grep -qw "\$ALGO" /sys/block/zram0/comp_algorithm 2>/dev/null; then
    printf '%s' "\$ALGO" > /sys/block/zram0/comp_algorithm 2>/dev/null || true
  else
    printf 'lz4' > /sys/block/zram0/comp_algorithm 2>/dev/null || true
  fi
fi
printf '%sK' "\$SIZE_KB" > /sys/block/zram0/disksize 2>/dev/null || exit 0
mkswap -L armbian-zram /dev/zram0 >/dev/null 2>&1 || exit 0
swapon -p $ZRAM_PRIORITY /dev/zram0 >/dev/null 2>&1 || exit 0
EOF
  chmod +x /usr/local/sbin/armbian-zram-setup
  cat > /etc/systemd/system/armbian-zram.service <<EOF
[Unit]
Description=armbian-nas 自建 zram 压缩 swap（兜底方案）
Before=swap.target
After=modprobe@zram.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/armbian-zram-setup
ExecStop=/bin/sh -c '/sbin/swapoff /dev/zram0 2>/dev/null || true'
[Install]
WantedBy=swap.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable --now armbian-zram.service >/dev/null 2>&1 || \
    /usr/local/sbin/armbian-zram-setup >/dev/null 2>&1 || true
  c_ok "已自建 zram：$algo / ${sz}KiB / pri=$ZRAM_PRIORITY（不依赖发行版包）"
}

zram_setup_new(){
  local owner; owner="$(zram_owner)"
  if [[ "$owner" == "armbian" ]]; then
    systemctl enable --now armbian-zram-config.service >/dev/null 2>&1 || true
    c_info "检测到 Armbian 自带 zram 服务：已启用（保留它自带的大小/算法，不动 /var/log 的 zram）"
    return 0
  fi
  if [[ "$owner" != "none" ]]; then
    c_info "已有 zram 管理器：$owner（$([[ "$owner" == generator ]] && echo /etc/systemd/zram-generator.conf || echo /etc/default/zramswap)），不重复安装"
    return 0
  fi

  local pct; pct="$ZRAM_SIZE_PERCENT"; is_low_mem && pct=25
  c_info "未检测到启用中的 zram；内存 $(mem_total_mib) MiB，目标比例 ${pct}%（上限 512M）"

  # ① Debian 12 / Ubuntu 24.04
  if apt_install_quiet zram-tools; then
    cat > /etc/default/zramswap <<EOF
# armbian-nas 生成：zram 优先、磁盘 swap 兜底
# zram-tools 读本文件；PRIORITY 越大越优先。
ALGO=$ZRAM_ALGO
PERCENT=$pct
PRIORITY=$ZRAM_PRIORITY
EOF
    systemctl enable --now zramswap >/dev/null 2>&1 || \
      systemctl restart zramswap >/dev/null 2>&1 || true
    zram_active && { c_ok "zram-tools 已启用：$ZRAM_ALGO / ${pct}% RAM / PRIORITY=$ZRAM_PRIORITY"; return 0; }
    c_warn "zram-tools 装上了但 /dev/zram0 没起来，继续尝试下一个方案"
  fi

  # ② Debian 13 / Ubuntu 25.04+ / Fedora
  if apt_install_quiet systemd-zram-generator; then
    cat > /etc/systemd/zram-generator.conf <<EOF
# armbian-nas 生成：zram 优先、磁盘 swap 兜底
[zram0]
zram-size = $(( $(zram_target_kib) / 1024 ))
compression-algorithm = $ZRAM_ALGO
swap-priority = $ZRAM_PRIORITY
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl start systemd-zram-setup@zram0.service >/dev/null 2>&1 || true
    zram_active && { c_ok "systemd-zram-generator 已启用（pri=$ZRAM_PRIORITY）"; return 0; }
    c_warn "zram-generator 未生效，继续尝试下一个方案"
  fi

  # ③ 部分旧发行版提供的是 zram-config，不是 zram-tools
  if apt_install_quiet zram-config; then
    systemctl enable --now zram-config.service >/dev/null 2>&1 || true
    zram_active && { c_ok "zram-config 已启用（老版 userland 兜底）"; return 0; }
    c_warn "zram-config 未生效，使用原生自建方案"
  fi

  # ④ 全部失败 → 原生自建，保证分层一定成立
  c_warn "发行版源里没有可用的 zram 包，改用内核原生自建 unit（不依赖任何发行版包）"
  zram_native_unit
}

# 把 fstab 里所有磁盘型 swap 行的 pri 改成 $SWAP_PRIORITY（幂等、先备份）
swap_demote_disk(){
  [[ -r /etc/fstab ]] || { c_info "无 /etc/fstab，跳过磁盘 swap 优先级调整"; return 0; }
  [[ -f "$SWAP_FSTAB_BAK" ]] || cp /etc/fstab "$SWAP_FSTAB_BAK" 2>/dev/null || true
  local rc
  rc="$(python3 - /etc/fstab "$SWAP_PRIORITY" <<'PY'
import re, sys
p, prio = sys.argv[1], sys.argv[2]
lines = open(p, encoding='utf-8').read().splitlines(True)
out, changed = [], 0
for ln in lines:
    has_nl = ln.endswith('\n')
    core = ln.rstrip('\n')
    if core.lstrip().startswith('#') or not core.strip():
        out.append(ln); continue
    f = core.split()
    m = re.match(r'^(\s*\S+\s+\S+\s+swap\s+)(\S+)(\s+.*)$', core)
    if m and len(f) >= 4 and f[2] == 'swap' and not f[0].startswith('/dev/zram'):
        opts = [o for o in m.group(2).split(',') if o and not o.startswith('pri=')]
        opts.append('pri=' + str(prio))
        new = ','.join(opts)
        if new != m.group(2):
            core = m.group(1) + new + m.group(3)
            changed += 1
    out.append(core + ('\n' if has_nl else ''))
if changed:
    open(p, 'w', encoding='utf-8').writelines(out)
print(changed)
PY
)"
  if [[ "$rc" =~ ^[0-9]+$ ]] && (( rc > 0 )); then
    c_ok "已把 $rc 条磁盘 swap 的 fstab 选项改为 pri=$SWAP_PRIORITY（备份 $SWAP_FSTAB_BAK）"
  else
    c_info "磁盘 swap 的 fstab 优先级已是 pri=$SWAP_PRIORITY 或没有 swap 行，无需改动"
  fi

  # 让新优先级立即生效：只 swapoff 当前 USED=0 的磁盘 swap，再 swapon -a。
  # USED>0 时绝不 swapoff —— 把正在使用的换出页搬回内存可能直接 OOM。
  local line dev typ sz used pri busy=0
  while IFS= read -r line; do
    set -- $line
    [[ $# -ge 5 ]] || continue
    dev="$1"; typ="$2"; sz="$3"; used="$4"; pri="$5"
    [[ "$dev" == /dev/zram* ]] && continue
    [[ -e "$dev" ]] || continue
    if [[ "$used" == "0" ]]; then
      swapoff "$dev" >/dev/null 2>&1 || true
    else
      busy=1
    fi
  done < <(tail -n +2 /proc/swaps 2>/dev/null)
  swapon -a >/dev/null 2>&1 || true
  if [[ "$busy" -eq 1 ]]; then
    c_warn "有磁盘 swap 正在被使用（USED>0），未执行 swapoff；新 pri 将在下次重启后生效"
    c_info "  想立即生效可在内存空闲时手工执行：sudo swapoff <swapfile> && sudo swapon -a"
  fi
  return 0
}

zram_baseline(){
  c_step "[19] zram 优先 / 磁盘 swap 兜底（按发行版与内核版本自适应）"
  local owner="" has_zram=0 sw="" cur="" pc=""

  # 用明确的 if/else 而不是 &&/|| 链：在 set -e 下，块内最后一条命令的返回码
  # 若非 0 会把整个 &&/|| 链判成失败，进而误伤步骤 19。
  if [[ "$ZRAM_MODE" == "off" ]]; then
    c_warn "已指定 --zram=off：完全不碰 zram，仅按 --swappiness 写 sysctl"
  else
    owner="$(zram_owner)"
    c_info "zram 管理器识别结果：$owner"
    if [[ "$ZRAM_MODE" == "force" || ( "$ZRAM_MODE" == "auto" && "$owner" == "none" ) ]]; then
      zram_setup_new || true
    elif [[ "$owner" == "armbian" ]]; then
      c_info "Armbian 自带 zram：只做优先级分层，不改它自带的大小/算法"
    fi
    swap_demote_disk || true
  fi

  zram_active && has_zram=1
  if [[ "$has_zram" -eq 1 ]]; then
    c_ok "zram 已启用：$(zramctl 2>/dev/null | tail -n +2 | head -3 | tr '\n' ';' || true)"
  else
    c_warn "当前未检测到启用中的 zram（可能需重启，或源里没有 zram-tools）"
  fi

  # ---- swappiness：用户显式值优先；auto 按「有没有 zram」选基准值 ----
  sw="$SWAPPINESS"
  if [[ "$SWAPPINESS" == "auto" || "$SWAPPINESS_USER_SET" -eq 0 ]]; then
    if [[ "$has_zram" -eq 1 ]]; then sw=150; else sw=10; fi
  fi
  # 内核 >=5.8 才允许 >100；用 sysctl -w 实测，失败就回落 100
  if ! sysctl -w vm.swappiness="$sw" >/dev/null 2>&1; then
    c_warn "内核不支持 vm.swappiness=$sw（<5.8 上限 100），自动回落到 100"
    sw=100
    sysctl -w vm.swappiness=100 >/dev/null 2>&1 || sw="$(sysctl -n vm.swappiness 2>/dev/null || echo 60)"
  fi
  SWAPPINESS_EFF="$sw"
  {
    printf 'vm.swappiness=%s\n' "$sw"
    [[ "$has_zram" -eq 1 ]] && printf 'vm.page-cluster=0\n'
  } > /etc/sysctl.d/99-armbian-nas.conf
  sysctl -p /etc/sysctl.d/99-armbian-nas.conf >/dev/null 2>&1 || true
  pc="$(sysctl -n vm.page-cluster 2>/dev/null || echo '?')"

  # zswap 与 zram 同时开 = 重复压缩，只提示不擅自关
  if [[ -r /sys/module/zswap/parameters/enabled ]] && \
     grep -qi '^Y' /sys/module/zswap/parameters/enabled 2>/dev/null; then
    c_warn "检测到 zswap 已启用：它和 zram 是两套机制，同时开会重复压缩 CPU；"
    c_warn "  Armbian 默认可能开 zswap。若不需要，可在 /boot/armbianEnv.txt 里关掉（脚本不擅自改内核参数）"
  fi

  c_ok "vm.swappiness=$sw（zram=$has_zram，page-cluster=$pc；磁盘 swapfile 仅兜底）"
  c_info "  当前 swap 分层（NAME TYPE PRIO USED）："
  swap_table | sed 's/^/    /' || true
  c_info "  验证：swapon --show ；zramctl ；sysctl vm.swappiness vm.page-cluster"
}

# ===========================================================================
#          低内存自适应（比特米盒 S905X 只有 1G RAM）
# ---------------------------------------------------------------------------
# 之前所有容量分析只算了 8G eMMC，没算内存 —— 这是全面检查时发现的一个漏项。
# 1G 内存下最危险的是 php8.2-fpm 默认的 dynamic 池（可能一下开好几个子进程），
# 加上 nginx + qB/Transmission + 微力同步 + zram，很容易 OOM。
# 这里把池改成 ondemand、最多 3 个子进程、空闲 10s 回收；不删任何配置，先备份。
# ===========================================================================
lowmem_baseline(){
  local m pool
  m="$(mem_total_mib)"
  if ! is_low_mem; then
    c_info "内存 ${m} MiB > ${LOW_MEM_MIB} MiB，跳过低内存自适应"
    return 0
  fi
  c_step "[19] 低内存自适应（本机仅 ${m} MiB RAM）"
  c_warn "1G 内存机器上，Docker 镜像层 / qB 多连接 / php-fpm 子进程最容易触发 OOM"

  pool="${PHP_ETC}/fpm/pool.d/www.conf"
  if [[ -r "$pool" ]]; then
    [[ -f "${pool}.bak.armbian-nas" ]] || cp "$pool" "${pool}.bak.armbian-nas" 2>/dev/null || true
    python3 - "$pool" <<'PY'
import re, sys
p = sys.argv[1]
want = {'pm': 'ondemand', 'pm.max_children': '3', 'pm.process_idle_timeout': '10s'}
drop = {'pm.start_servers', 'pm.min_spare_servers', 'pm.max_spare_servers'}
out, seen = [], set()
for ln in open(p, encoding='utf-8').read().splitlines(True):
    st = ln.lstrip()
    if st.startswith(';'):
        out.append(ln); continue
    m = re.match(r'^(pm(?:\.\w+)?)\s*=\s*(.*)$', st)
    if m:
        k = m.group(1)
        if k in want:
            out.append('%s = %s\n' % (k, want[k])); seen.add(k)
        elif k in drop:
            # ondemand 不用这三个参数，注释掉而不是删掉，方便回滚
            out.append(';' + ln.rstrip('\n') + '  ; armbian-nas 低内存\n')
        else:
            out.append(ln)
    else:
        out.append(ln)
for k, v in want.items():
    if k not in seen:
        out.append('%s = %s\n' % (k, v))
open(p, 'w', encoding='utf-8').writelines(out)
PY
    systemctl reload php8.2-fpm >/dev/null 2>&1 || \
      systemctl restart php8.2-fpm >/dev/null 2>&1 || true
    c_ok "php8.2-fpm 池改为 ondemand / max_children=3 / idle=10s（原文件已备份）"
  else
    c_info "未找到 $pool，跳过 php-fpm 调整（PHP 组件可能未装）"
  fi

  mkdir -p "$BASE/config"
  cat > "$BASE/config/低内存建议.md" <<EOF
# 本机内存仅 ${m} MiB，建议（脚本已自动做第 1 条）

1. 已自动把 php8.2-fpm 改成 pm=ondemand、pm.max_children=3、空闲 10s 回收。
2. zram 比例自动从 ${ZRAM_SIZE_PERCENT}% 降到 25%，且总大小上限 512M：
   1G 内存给 512M zram 反而会挤掉可用内存。
3. 尽量在组件选择时跳过 Docker（镜像层 + containerd 常驻）和图形界面。
4. qBittorrent 别开太多同时连接/做种；Transmission 可设 cache-size-mb 小一点。
5. 512M 磁盘 swapfile 只作 OOM 前兜底；zram 优先由步骤 19 保证。
6. 内存排查：free -h ; swapon --show ; zramctl ; dmesg | grep -i oom
EOF
  c_info "已写 $BASE/config/低内存建议.md"
  return 0
}

# ===========================================================================
#          步骤 23：本地博客站点（独立端口 81 / 目录 boke）
# ---------------------------------------------------------------------------
# 用户要求：nginx 装好后一并创建一个网站，端口 81、目录 boke，首页卡片
#           「本地博客」点开新标签页直达 http://<本机IP>:81/。
#   * 网站根目录：$BASE/boke（外置盘，与「数据放外置盘」的整体设计一致）
#   * 独立 server 块 /etc/nginx/sites-available/armbian-blog，listen 81，
#     【不写 default_server】—— 避免被 nginx_disable_conflicting_defaults()
#     误伤，也不会和 80 端口的 armbian-nas 抢 default_server。
#   * 同时支持 PHP 8.2 FPM：把 Typecho / WordPress / Halo 等程序放进
#     $BLOG_DIR 即可用；默认首页是静态 index.html，保证端口一定能打开。
#   * 幂等：已存在的 index.html【不覆盖】（用户可能已经放了自己的博客首页）；
#     info.php 与站点配置每次重跑都重建，nginx -t 通过才 reload。
# ===========================================================================
step_blog(){
  c_step "[23] 本地博客站点：端口 $PORT_BLOG / 目录 $BLOG_DIR"
  init_state_area
  mkdir -p "$BLOG_DIR" "$BASE/logs/nginx" /etc/nginx/sites-available /etc/nginx/sites-enabled

  # ---- ① 默认首页（只在不存在时生成，绝不覆盖用户自己的博客首页）----
  if [[ ! -f "$BLOG_DIR/index.html" ]]; then
    cat > "$BLOG_DIR/index.html" <<'BLOGHTML'
<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>本地博客 · armbian-nas</title>
<style>
*{box-sizing:border-box}
body{margin:0;padding:32px 18px;background:#f4f7fb;color:#1c2536;
font:16px/1.75 system-ui,-apple-system,"Segoe UI","Microsoft YaHei",sans-serif}
.wrap{max-width:820px;margin:0 auto;background:#fff;border:1px solid #dfe6f0;
border-radius:16px;padding:30px 32px;box-shadow:0 2px 10px #16233a0d}
h1{font-size:26px;margin:0 0 6px}h1 span{color:#2563eb}
.sub{color:#64748b;font-size:13px;margin-bottom:22px}
h2{font-size:16px;margin:24px 0 10px;padding-bottom:8px;border-bottom:1px solid #dfe6f0}
code{background:#eef3fb;border:1px solid #dfe6f0;border-radius:5px;padding:2px 7px;
font:13px/1.6 ui-monospace,Menlo,Consolas,monospace;word-break:break-all}
table{width:100%;border-collapse:collapse;font-size:14px}
td{padding:8px 10px;border-bottom:1px solid #dfe6f0}td:first-child{width:38%;color:#64748b}
a{color:#2563eb}.btn{display:inline-block;background:#2563eb;color:#fff;text-decoration:none;
padding:8px 16px;border-radius:8px;font-size:14px;margin-right:8px}
.btn.gray{background:#eef3fb;color:#1c2536;border:1px solid #dfe6f0}
.note{background:#fff8e8;border:1px solid #f2d9a2;border-radius:9px;padding:12px 14px;
color:#7c4a06;font-size:13.5px;margin-top:18px}
footer{text-align:center;color:#94a3b8;font-size:12px;margin-top:22px}
</style></head><body><div class="wrap">
<h1>📝 本地<span>博客</span></h1>
<div class="sub">armbian-nas · 独立站点 · 端口 <b>81</b> · 由部署脚本自动创建</div>
<p>站点已经跑起来了。这是一个空白站点骨架，把你的博客程序放进当前目录即可开始用。</p>
<p>
  <a class="btn" href="info.php">检查 PHP 8.2 环境</a>
  <a class="btn gray" href="/">返回 80 端口导航页</a>
</p>
<h2>站点信息</h2>
<table>
<tr><td>访问端口</td><td><b>81</b>（http://&lt;本机IP&gt;:81/）</td></tr>
<tr><td>网站根目录</td><td><code id="dir">见下方说明</code></td></tr>
<tr><td>站点配置文件</td><td><code>/etc/nginx/sites-available/armbian-blog</code></td></tr>
<tr><td>访问日志</td><td><code>/mnt/sda1/www/logs/nginx/blog-access.log</code></td></tr>
<tr><td>错误日志</td><td><code>/mnt/sda1/www/logs/nginx/blog-error.log</code></td></tr>
<tr><td>PHP</td><td>已接 <code>php8.2-fpm</code>，支持 .php</td></tr>
</table>
<h2>怎么用</h2>
<p>把 Typecho / WordPress / 静态博客生成器的文件上传到网站根目录，
<b>删掉或改名本文件（index.html）</b>，让程序的 <code>index.php</code> 成为首页即可。
nginx 已配置 <code>index index.html index.php</code> 与 PHP 8.2 FPM 转发。</p>
<div class="note">
  <b>提示：</b>如果博客程序需要伪静态（WordPress 固定链接等），在
  <code>armbian-blog</code> 的 <code>location /</code> 里改成
  <code>try_files $uri $uri/ /index.php?$args;</code>，然后
  <code>sudo nginx -t &amp;&amp; sudo systemctl reload nginx</code>。<br>
  本目录在<b>外置硬盘</b>上，重装系统不会丢博客文件。
</div>
<footer>armbian-nas · 本地博客站点 · 白色明亮主题 · 无外部 CDN 依赖</footer>
</div></body></html>
BLOGHTML
    sed -i "s|<code id=\"dir\">见下方说明</code>|<code>$BLOG_DIR</code>|" "$BLOG_DIR/index.html"
    c_ok "已生成默认首页：$BLOG_DIR/index.html"
  else
    c_ok "沿用已有首页（不覆盖你的博客文件）：$BLOG_DIR/index.html"
  fi

  # ---- ② PHP 验证页（每次重跑都重建，方便确认 FPM 通了）----
  cat > "$BLOG_DIR/info.php" <<'BLOGPHP'
<?php
header('Content-Type: text/html; charset=utf-8');
?><!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<title>PHP 8.2 正常 · 本地博客</title>
<style>body{font:16px/1.7 system-ui,"Microsoft YaHei",sans-serif;background:#f4f7fb;
color:#1c2536;padding:30px}.c{max-width:680px;margin:0 auto;background:#fff;border:1px solid #dfe6f0;
border-radius:14px;padding:26px}h1{margin:0 0 10px;font-size:22px}.ok{color:#0f9d58;font-weight:700}
code{background:#eef3fb;padding:2px 6px;border-radius:5px}</style></head><body><div class="c">
<h1>✅ PHP 8.2 FPM 正常</h1>
<p>端口 <b>81</b> 的站点已经成功把 <code>.php</code> 交给 php8.2-fpm 执行。</p>
<table style="width:100%;border-collapse:collapse">
<tr><td style="color:#64748b;width:38%">PHP 版本</td><td><?php echo htmlspecialchars(PHP_VERSION); ?></td></tr>
<tr><td style="color:#64748b">SAPI</td><td><?php echo htmlspecialchars(php_sapi_name()); ?></td></tr>
<tr><td style="color:#64748b">服务器</td><td><?php echo htmlspecialchars($_SERVER['SERVER_SOFTWARE'] ?? '-'); ?></td></tr>
<tr><td style="color:#64748b">网站目录</td><td><?php echo htmlspecialchars(__DIR__); ?></td></tr>
<tr><td style="color:#64748b">SQLite3</td><td><?php echo extension_loaded('sqlite3') ? '<span class="ok">已启用</span>' : '未启用'; ?></td></tr>
</table>
<p style="margin-top:18px"><a href="/">← 返回首页</a>（确认无误后可删除本文件）</p>
</div></body></html>
BLOGPHP
  chmod 644 "$BLOG_DIR/index.html" "$BLOG_DIR/info.php"

  # ---- ③ 探测 php8.2-fpm socket（与步骤 04 同一套逻辑）----
  local sock pass
  if [[ -S "$PHP_SOCK" ]]; then
    sock="$PHP_SOCK"
  else
    sock="$(grep -hoE '^listen *= *[^ ;]+' "$PHP_ETC/fpm/pool.d/www.conf" 2>/dev/null | head -1 | awk '{print $3}' || true)"
  fi
  if [[ -z "$sock" ]]; then sock="127.0.0.1:9000"; c_warn "未探测到 $PHP_SOCK，回退 $sock"; fi
  if [[ "$sock" == /* ]]; then pass="unix:$sock"; else pass="$sock"; fi

  # ---- ④ nginx 独立 server 块：listen 81，绝不写 default_server ----
  cat > "$BLOG_SITE" <<'NGINX'
# armbian-nas 生成（步骤 23）：本地博客独立站点
# ★ 本 server 块不声明「默认站点」标记：80 端口的 armbian-nas 已经声明，
#   这里若也声明会与之冲突，并被站点清理逻辑移出 sites-enabled。
server {
    listen __PORT_BLOG__;
    listen [::]:__PORT_BLOG__;
    server_name _;
    root __BLOG_DIR__;
    index index.html index.php index.htm;
    access_log __BASE__/logs/nginx/blog-access.log;
    error_log  __BASE__/logs/nginx/blog-error.log warn;
    client_max_body_size 4096m;

    location / { try_files $uri $uri/ =404; }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_index index.php;
        fastcgi_pass __PHP_PASS__;
    }
    location ~ /\. { deny all; }
}
NGINX
  sed -i "s|__PORT_BLOG__|$PORT_BLOG|g; s|__BLOG_DIR__|$BLOG_DIR|g; s|__BASE__|$BASE|g; s|__PHP_PASS__|$pass|g" "$BLOG_SITE"
  # -sfnT：避免 ln -sfn 把链接建到目录里面的老 bug
  ln -sfnT "$BLOG_SITE" /etc/nginx/sites-enabled/armbian-blog

  if ! nginx -t >/dev/null 2>&1; then
    nginx -t
    die "加入 81 端口站点后 nginx -t 未通过；检查 $BLOG_SITE（端口是否被占用 / 语法）"
  fi
  systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true

  # ---- ⑤ 防火墙（步骤 16 已跑过，这里补一次才生效）----
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${PORT_BLOG}/tcp" >/dev/null 2>&1 || true
    c_info "ufw 已放通 ${PORT_BLOG}/tcp"
  fi

  sleep 1
  if port_open "$PORT_BLOG"; then
    c_ok "本地博客已就绪：http://<本机IP>:$PORT_BLOG/   （网站目录：$BLOG_DIR）"
  else
    c_warn "端口 $PORT_BLOG 暂未监听；检查 nginx -t 与 journalctl -u nginx -n 30"
  fi
  c_info "  把博客程序放进 $BLOG_DIR，删掉默认 index.html 即可；info.php 可验证 PHP 8.2"

  # 组件快照是步骤 18 生成的；这里建完站点再刷新一次首页，
  # 保证「本地博客」卡片不会被判成未安装而灰掉。
  if [[ -d "$WEB_ROOT" ]] && declare -F step_nav >/dev/null 2>&1; then
    step_nav >/dev/null 2>&1 || c_warn "首页刷新失败，可 --redo=18 重建"
  fi
  return 0
}

# ===========================================================================
#          步骤 20（占位）：面板 OLED —— ★★ 已按真机实测【整体移除】
# ---------------------------------------------------------------------------
# 【为什么要移除 · 根因定位】
#   用户实测：每次部署跑到这一步就「网络短线，整个路由器内网全部连不上」，
#   往往需要拔电重启。查代码后，本步骤是全脚本【唯一】会主动枚举并写
#   硬件总线的操作：
#
#     1) `apt_install_quiet i2c-tools`
#        安装 i2c-tools 会触发内核加载 i2c-dev，把 SoC 上【所有】I2C
#        适配器暴露成 /dev/i2c-0、/dev/i2c-1 ...（不只是接 OLED 那一路）。
#     2) `for b in /dev/i2c-*; do i2cdetect -y "$n"; done`
#        i2cdetect -y 会对每条总线的 0x03–0x77 【全地址】发 SMBus 探测帧
#        （quick write / read byte）。S905X / Khadas VIM1 的内部 I2C 上还
#        挂着 PMIC、以太网 PHY / MDIO、HDMI DDC(EDID)、音频 Codec 等器件：
#          * 命中 PMIC / PHY 的保留地址可能改写寄存器、触发 PHY 复位；
#          * 器件 clock-stretching 会把 I2C 控制器锁死；
#          * RGMII/MDIO 与 I2C 复用引脚被 i2c-dev 抢占后 MAC 挂死，
#            异常帧/广播风暴会把上级路由器 LAN 一起拖住 —— 表现正是
#            「盒子网口掉 + 整个内网连不上」。
#     3) 次要：若用户传过 --oled-bin，armbian-oled.service 是
#        `Restart=always / RestartSec=10`，程序反复访问 I2C 崩溃重启，
#        每 10 秒持续轰总线，掉线后很难自己恢复。
#
#   这与用户早先警告的「测试 gpiochip1 的 line 70~80 会掉线、需拔电重启」
#   是同一类硬件踩踏，只是从 GPIO 命名空间换到了 I2C 命名空间。
#   其它所有步骤都只写文件/服务单元，不会碰硬件总线。
#
# 【现在的做法】
#   * 组件 oled 从 COMP_KEYS / 清单 / 首页 / 自检 / 卸载菜单全部删除；
#   * 不再安装 i2c-tools、不再 i2cdetect、不再 modprobe、不改 dtb、不碰 GPIO；
#   * 保留编号 20 作为【安全清理占位】：只停掉可能残留的 armbian-oled
#     服务/timer 并删单元文件，防止旧机器开机后继续访问 I2C；
#   * $BASE/oled 下已有的配置模板/README 保留，不删任何用户文件。
# ===========================================================================
step_oled_removed(){
  c_step "[20] 面板 OLED：已移除（只做安全清理，不再扫描 I2C）"
  c_warn "★ 真机实测确认：旧版在此处装 i2c-tools 并对所有 /dev/i2c-* 跑 i2cdetect -y"
  c_warn "  全地址扫描会命中 PMIC / 网口 PHY，导致网口掉线、整个内网连不上（常需拔电重启）"
  c_info "  本版已彻底移除该功能：不装 i2c-tools、不扫描 I2C、不改 dtb、不碰 GPIO"
  oled_cleanup
  c_ok "[20] 完成：面板 OLED 功能已移除，网络不会再被这一步打断"
  return 0
}

# ===========================================================================
#          步骤 21：ttyd 网页终端
# ---------------------------------------------------------------------------
# 用户诉求：不用每次开电脑 SSH，浏览器里随时能开终端。
#
# 【为什么这样配，而不是 ttyd -W bash 直接跑】
#   ttyd 默认【没有任何认证】且监听 0.0.0.0:7681 —— 直接跑等于把一台 root
#   shell 发给同网段（甚至公网）所有人。所以脚本做三层收紧：
#     1) ttyd 只听 127.0.0.1（-i 127.0.0.1），外部连不到 7681
#     2) nginx 反代 /ttyd/ 并强制 auth_basic，密码只存 .deploy/secrets.env
#        （.deploy 是 700、且被 PHP open_basedir 排除，网页读不到）
#     3) 首页只显示「密码在哪个文件」，绝不把密码值写进 HTML
#   不用 ttyd 自带的 -c user:pass：命令行明文密码会暴露在 ps / /proc 里，
#   反而不安全。nginx 已经做了认证，ttyd 侧再加一层是重复且有害的。
#
# 【安装来源】Ubuntu 22.04+ universe 通常自带 ttyd（22.04 自带 1.6.3，
# 26.04 resolute 自带更新版）；若源里没有，
# 回退到 GitHub release 的静态二进制（aarch64 用 ttyd.aarch64）。
# 不在 1G 内存的机器上源码编译（cmake + libwebsockets 太重，容易 OOM）。
# ===========================================================================
ttyd_install_program(){
  local url="" bin="" arch
  if command -v ttyd >/dev/null 2>&1; then
    c_info "ttyd 已存在：$(command -v ttyd)（$(ttyd --version 2>/dev/null || echo '版本未知')）"
    return 0
  fi
  apt_install_quiet ttyd || true
  command -v ttyd >/dev/null 2>&1 && return 0

  arch="$(uname -m)"
  case "$arch" in
    aarch64|arm64) bin="ttyd.aarch64" ;;
    armv7*|armhf*) bin="ttyd.armhf" ;;
    x86_64|amd64)  bin="ttyd.x86_64" ;;
    i?86)          bin="ttyd.i686" ;;
    *) c_warn "未知架构 $arch，稍后仍会尝试 aarch64 二进制"; bin="ttyd.aarch64" ;;
  esac
  url="${TTYD_BIN_URL:-https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${bin}}"
  c_info "apt 源里没有 ttyd，下载静态二进制：$url"
  mkdir -p /usr/local/bin
  if [[ -f "$url" ]]; then
    cp -f "$url" /usr/local/bin/ttyd
  else
    curl -fL --max-time 90 -o /usr/local/bin/ttyd "$url" >/dev/null 2>&1 || true
  fi
  chmod +x /usr/local/bin/ttyd 2>/dev/null || true
  if [[ -x /usr/local/bin/ttyd ]] && /usr/local/bin/ttyd --version >/dev/null 2>&1; then
    c_ok "ttyd 静态二进制已装到 /usr/local/bin/ttyd（$arch → $bin）"
    return 0
  fi
  rm -f /usr/local/bin/ttyd
  return 1
}

step_ttyd(){
  c_step "[21] ttyd 网页终端（浏览器里直接开终端，带密码保护）"
  init_state_area
  TTYD_PATH="${TTYD_PATH%/}"        # 用户若传 /ttyd/ 也规范化成 /ttyd
  [[ -n "$TTYD_PATH" ]] || TTYD_PATH="/ttyd"
  mkdir -p "$BASE/ttyd" "$BASE/logs" /etc/nginx/snippets /etc/nginx/conf.d
  # 降权运行时先把用户建好，否则 systemd 会起不来（小白容易漏这一步）
  if [[ "$TTYD_USER" != "root" ]] && ! id -u "$TTYD_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$TTYD_USER" >/dev/null 2>&1 \
      && c_ok "已创建低权限终端用户 $TTYD_USER（sudo 仍需密码，记得 sudo passwd $TTYD_USER）" \
      || c_warn "创建 $TTYD_USER 失败，请手工 useradd 后再 --redo=21"
  fi

  ttyd_install_program || die "ttyd 安装失败。可手动下载对应架构二进制后 --ttyd-bin-url=/路径/ttyd --redo=21"

  # ---- 网页密码：只生成一次，存 secrets.env，绝不在页面/命令行里出现 ----
  local pw passfile="/etc/nginx/.ttydpasswd"
  pw="$(secret_get TTYD_WEB_PASS)"
  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -bcB "$passfile" "$TTYD_AUTH_USER" "$pw" >/dev/null 2>&1 || true
  fi
  if [[ ! -s "$passfile" ]] && command -v openssl >/dev/null 2>&1; then
    # apache2-utils 没装时的回退：openssl passwd -apr1 生成 nginx 认得的格式
    printf '%s:%s\n' "$TTYD_AUTH_USER" "$(openssl passwd -apr1 "$pw")" > "$passfile"
  fi
  [[ -s "$passfile" ]] || die "生成 nginx 密码文件失败（需要 apache2-utils 或 openssl）"
  chown root:www-data "$passfile" 2>/dev/null || true
  chmod 640 "$passfile"
  c_ok "网页登录：$TTYD_AUTH_USER / 密码存于 $SECRETS_FILE（TTYD_WEB_PASS，页面不显示）"

  # ---- nginx 反代片段：WebSocket 必须带 Upgrade 头 ----
  # ★★ 真机修复（登录密码正确后 404）：
  #    旧写法 `proxy_pass http://127.0.0.1:7681;`【不带 URI】把 /ttyd/
  #    前缀原样转给 ttyd，而 ttyd 各版本对 -b /ttyd 处理不一致 ——
  #    1.6.x / 1.7.x 常见结果就是首页 404、静态资源 404。
  #    通用可靠方案：
  #      * nginx `proxy_pass http://127.0.0.1:7681/;`【尾部带 /】剥掉前缀；
  #      * ttyd 启动【不加 -b】，按根路径服务；
  #      * 补 `location = /ttyd { return 301 /ttyd/; }` 处理漏写斜杠。
  #    --ttyd-path 改成任意路径都成立。
  cat > /etc/nginx/snippets/armbian-nas-ttyd.conf <<EOF
# armbian-nas 生成（步骤 21）。ttyd 只听 127.0.0.1:$TTYD_PORT，认证在 nginx 这层做。
# 不带尾斜杠的访问 301 补上，避免落到别的 location 上。
location = ${TTYD_PATH} {
    return 301 ${TTYD_PATH}/;
}
location ${TTYD_PATH}/ {
    auth_basic "armbian-nas web terminal";
    auth_basic_user_file $passfile;

    # ★ 尾部斜杠 = 剥掉 ${TTYD_PATH}/ 前缀；ttyd 不带 -b
    proxy_pass http://127.0.0.1:${TTYD_PORT}/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$armbian_conn_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_redirect off;
    proxy_read_timeout 3600;
    proxy_send_timeout 3600;
    proxy_buffering off;
}
EOF
  # map 在 http 块（conf.d），名字唯一，避免和别的站点配置冲突
  cat > /etc/nginx/conf.d/00-armbian-nas-ttyd-map.conf <<'MAP'
map $http_upgrade $armbian_conn_upgrade {
    default upgrade;
    ''      close;
}
MAP
  nginx -t >/dev/null 2>&1 || die "nginx -t 未通过（ttyd 反代片段有误），检查 /etc/nginx/snippets/armbian-nas-ttyd.conf"
  systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true

  # ---- systemd unit：-i 只听本地；-W 允许输入；-b 配合子路径；-m 限并发 ----
  local ttybin; ttybin="$(command -v ttyd)"
  cat > /etc/systemd/system/armbian-ttyd.service <<EOF
[Unit]
Description=armbian-nas ttyd web terminal (loopback only, auth via nginx)
After=network.target nginx.service
[Service]
Type=simple
User=$TTYD_USER
Environment=TERM=xterm-256color
# ★ 不加 -b：由 nginx 剥掉子路径前缀，ttyd 按根路径服务（修 404）
ExecStart=$ttybin -i 127.0.0.1 -p $TTYD_PORT -W -m $TTYD_MAX_CLIENTS -t fontSize=16 -t disableLeaveAlert=true $TTYD_CMD
Restart=always
RestartSec=3
StandardOutput=append:$BASE/logs/ttyd.log
StandardError=append:$BASE/logs/ttyd.log
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now armbian-ttyd >/dev/null 2>&1 || systemctl enable --now armbian-ttyd
  sleep 1
  svc_active armbian-ttyd || c_warn "ttyd 服务未 active：journalctl -u armbian-ttyd -n 50"
  c_ok "ttyd 已启动：http://<本机IP>${TTYD_PATH}/ （80 端口反代，只经 nginx，密码 $TTYD_AUTH_USER）"
  c_info "  ★ 注意：:8080 是 qBittorrent 的 WebUI，不是网页终端；ttyd 走 ${TTYD_PATH}/"
  c_info "  验证：curl -u '$TTYD_AUTH_USER:<密码>' -o /dev/null -w '%{http_code}' http://127.0.0.1${TTYD_PATH}/  → 应为 200"
  c_warn "⚠ 这等于浏览器里的 ${TTYD_USER} shell：绝不要把本机 80 端口映射到公网；"
  c_warn "  ZeroTier 也只在可信网络里用。想降权可 --ttyd-user=nasweb（但 sudo 会要密码）"
  c_info "  改密码：删 $SECRETS_FILE 里的 TTYD_WEB_PASS 后 --redo=21"
  c_info "  登录密码查看：sudo grep TTYD_WEB_PASS $SECRETS_FILE"

  # 组件状态变了，刷新首页（会重读 COMP 快照把 ttyd 卡片点亮）
  if declare -F step_nav >/dev/null 2>&1; then step_nav >/dev/null 2>&1 || c_warn "首页刷新失败，可 --redo=18 重建"; fi
  return 0
}

uninstall_ttyd(){
  svc_stop_disable armbian-ttyd
  rm_paths /etc/systemd/system/armbian-ttyd.service /etc/nginx/.ttydpasswd \
           /etc/nginx/conf.d/00-armbian-nas-ttyd-map.conf \
           /usr/local/bin/ttyd
  # 片段必须恢复成 404 占位：否则站点里的 include 会让 nginx -t 失败
  cat > /etc/nginx/snippets/armbian-nas-ttyd.conf <<SNIP
# 占位：ttyd 已卸载，${TTYD_PATH}/ 直接 404，绝不误连到 7681
location ${TTYD_PATH}/ { return 404; }
SNIP
  apt_purge ttyd >/dev/null 2>&1 || true
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  c_ok "ttyd 已卸载；密码仍留在 $SECRETS_FILE，首页卡片已灰显"
  c_info "重跑 --redo=18 可刷新首页；或 --with-ttyd --redo=21 装回来"
}

# ---------------------------------------------------------------------------
# FileBrowser：单二进制 Go 程序，网页里浏览 / 上传 / 编辑两块外置硬盘。
#   * 二进制装 /usr/local/bin（≈15 MiB，占 eMMC 极少）
#   * 数据库与配置放 $BASE/filebrowser（外置盘）
#   * 根目录默认 /mnt —— 这样 /mnt/sda1 与 /mnt/sdb1 都能看到
#   * 端口 8082（避开 8080 qB / 9091 tr / 8886 微力 / 8200 DLNA）
#   * 密码写进 secrets.env，首页卡片明文显示（局域网自用）
# 下载失败不会中断整个部署：给出 --fb-bin=<本地文件> 的离线安装提示。
# ---------------------------------------------------------------------------
fb_install_binary(){
  local arch bin url tmp out="/usr/local/bin/filebrowser"
  if [[ -x "$out" ]] && "$out" --version >/dev/null 2>&1; then
    c_ok "FileBrowser 二进制已在位：$out（幂等跳过下载）"
    return 0
  fi
  mkdir -p /usr/local/bin "$BASE/filebrowser/.dl"
  if [[ -n "$FB_BIN" && -f "$FB_BIN" ]]; then
    case "$FB_BIN" in
      *.tar.gz|*.tgz)
        tar -xzf "$FB_BIN" -C "$BASE/filebrowser/.dl" filebrowser 2>/dev/null || true
        [[ -f "$BASE/filebrowser/.dl/filebrowser" ]] && mv -f "$BASE/filebrowser/.dl/filebrowser" "$out" ;;
      *) cp -f "$FB_BIN" "$out" ;;
    esac
    chmod +x "$out" 2>/dev/null || true
    if [[ -x "$out" ]]; then c_ok "已从本地文件安装 FileBrowser：$FB_BIN"; return 0; fi
  fi
  arch="$(uname -m)"
  case "$arch" in
    aarch64|arm64) bin="linux-arm64-filebrowser.tar.gz" ;;
    armv7l|armhf|armv6l) bin="linux-armv7-filebrowser.tar.gz" ;;
    x86_64|amd64)  bin="linux-amd64-filebrowser.tar.gz" ;;
    *) c_warn "未识别架构 $arch，请用 --fb-bin=<本地 filebrowser 二进制>"; return 1 ;;
  esac
  if [[ "$FB_VERSION" == "latest" ]]; then
    url="https://github.com/filebrowser/filebrowser/releases/latest/download/$bin"
  else
    url="https://github.com/filebrowser/filebrowser/releases/download/$FB_VERSION/$bin"
  fi
  tmp="$BASE/filebrowser/.dl/$bin"
  c_info "下载 FileBrowser（$arch → $bin），带进度条，请稍候…"
  if download_show "FileBrowser $bin" "$url" "$tmp"; then
    tar -xzf "$tmp" -C "$BASE/filebrowser/.dl" filebrowser 2>/dev/null || true
    if [[ -f "$BASE/filebrowser/.dl/filebrowser" ]]; then
      mv -f "$BASE/filebrowser/.dl/filebrowser" "$out"
      chmod +x "$out"
      c_ok "FileBrowser 二进制已装：$out"
      rm -f "$tmp"
      return 0
    fi
  fi
  c_warn "FileBrowser 下载/解压失败（GitHub 在国内常被墙）。其余软件不受影响。"
  c_warn "离线补装：把 linux-arm64-filebrowser.tar.gz 或 filebrowser 二进制放到机器上，"
  c_warn "  然后 sudo bash $SCRIPT_PATH --fb-bin=/绝对路径/filebrowser --redo=22"
  return 1
}

step_filebrowser(){
  c_step "[22] FileBrowser 网页文件管理器（外置盘数据库，根目录 /mnt）"
  init_state_area
  mkdir -p "$BASE/filebrowser" "$BASE/logs"
  [[ -d "$FB_ROOT" ]] || { c_warn "根目录 $FB_ROOT 不存在，回退 /mnt"; FB_ROOT=/mnt; mkdir -p /mnt; }

  if ! fb_install_binary; then
    c_warn "本步骤标记为未完成（不算致命错误）；补装后 --redo=22 即可"
    return 0
  fi
  local fb="/usr/local/bin/filebrowser" fbdb="$FB_DB" pw
  # ★ pw 来自 secret_get：simple 模式是 adminadmin123（≥12 位）。
  #   旧版把 FileBrowser 也收敛成 5 位 admin，users add / users update 全被上游拒绝，
  #   最后静默退化成 no_auth 免密，状态页却仍显示 admin / admin —— 属于「假配置」。
  pw="$(secret_get FILEBROWSER_PASS)"

  # ★ bbolt 独占锁：--redo=22 重配时服务可能正在运行，下面的 config init /
  #   users add|update / users ls / config set 全都会报 Error: timeout。
  #   先停服，函数末尾统一 enable --now 拉起；中途没有提前 return，服务一定回来。
  if svc_active armbian-filebrowser; then
    c_info "  FileBrowser 正在运行：先停服释放数据库锁（--redo=22 重配时必需）"
    systemctl stop armbian-filebrowser >/dev/null 2>&1 || true
    if [[ -f "$fbdb" ]]; then
      local _i
      for _i in 1 2 3 4 5; do
        "$fb" -d "$fbdb" users ls >/dev/null 2>&1 && break
        sleep 1
      done
    fi
  fi

  # config init 只需一次；之后 users / config set 都是幂等更新
  [[ -f "$fbdb" ]] || "$fb" -d "$fbdb" config init >/dev/null 2>&1 || true
  rm -f "$BASE/filebrowser/auth-noauth"
  # 不同 filebrowser 版本的 CLI 参数略有差异，逐级兜底
  if ! "$fb" -d "$fbdb" users add admin "$pw" --perm.admin >/dev/null 2>&1; then
    if ! "$fb" -d "$fbdb" users add admin "$pw" >/dev/null 2>&1; then
      "$fb" -d "$fbdb" users update admin --password "$pw" >/dev/null 2>&1 || true
    fi
  fi
  # 验证是否真的有账号；没有就切免密，并在首页卡片里说明
  if ! "$fb" -d "$fbdb" users ls 2>/dev/null | grep -q 'admin'; then
    "$fb" -d "$fbdb" config set --auth.method no_auth >/dev/null 2>&1 \
      || "$fb" -d "$fbdb" config set --auth.method=no_auth >/dev/null 2>&1 || true
    : > "$BASE/filebrowser/auth-noauth"
    c_warn "本机 FileBrowser CLI 不支持建用户，已切免密登录（局域网自用）"
  fi
  "$fb" -d "$fbdb" config set --address 0.0.0.0 --port "$PORT_FB" --root "$FB_ROOT" >/dev/null 2>&1 || true
  "$fb" -d "$fbdb" config set --locale zh-cn >/dev/null 2>&1 || true

  cat > /etc/systemd/system/armbian-filebrowser.service <<EOF
[Unit]
Description=armbian-nas FileBrowser web file manager
After=network.target
[Service]
Type=simple
User=root
ExecStart=$fb -d $fbdb -a 0.0.0.0 -p $PORT_FB -r $FB_ROOT
Restart=on-failure
RestartSec=3
StandardOutput=append:$BASE/logs/filebrowser.log
StandardError=append:$BASE/logs/filebrowser.log
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now armbian-filebrowser >/dev/null 2>&1 || systemctl enable --now armbian-filebrowser || true
  sleep 1
  if svc_active armbian-filebrowser; then
    c_ok "FileBrowser 已启动：http://<本机IP>:$PORT_FB   （根目录 $FB_ROOT，含两块外置硬盘）"
  else
    c_warn "FileBrowser 未 active；诊断：journalctl -u armbian-filebrowser -n 30；tail $BASE/logs/filebrowser.log"
  fi
  c_ok "登录：admin / $pw（密码存 $SECRETS_FILE，首页卡片明文显示）"
  c_info "  数据库：$fbdb（在外置盘，卸载默认保留）"
  return 0
}

uninstall_filebrowser(){
  svc_stop_disable armbian-filebrowser
  rm_paths /etc/systemd/system/armbian-filebrowser.service /usr/local/bin/filebrowser
  systemctl daemon-reload >/dev/null 2>&1 || true
  c_ok "FileBrowser 已卸载；数据库 $BASE/filebrowser 默认保留（--purge-data 才删）"
  c_info "重跑 --redo=18 刷新首页；--with-filebrowser --redo=22 装回来"
}

# ===========================================================================
#          风扇针脚实测：--fan-probe / --fan-test-on / --fan-test-off
# ---------------------------------------------------------------------------
# 人工确认一律走【控制终端 /dev/tty】，与 component_gate / confirm_yes 保持
# 同一通道。绝不读 stdin：风扇探测常被 `sudo bash ... < file`、tmux 管道、
# ssh 非交互调用，stdin 被重定向或 EOF 时 read 静默失败 → 两轮确认永远
# 变成「否」→ 明明风扇转了却不写服务。FAN_PROBE_TTY 仅供单元自测注入。
FAN_PROBE_TTY="${FAN_PROBE_TTY:-/dev/tty}"

# ---------------------------------------------------------------------------
# 用户要求的操作顺序（脚本严格照做，绝不先写死服务）：
#   ① 逐个候选执行「开」→ 等几秒 → 人工确认风扇转了吗？
#   ② 只有回答 y，才执行「关」→ 等几秒 → 人工确认风扇停了吗？
#   ③ 两轮都 y 才把 on/off 写进 /etc/default/armbian-fan，并生成/启用服务
#   ④ 两轮有任一 n → 立即恢复关闭，试下一个候选；全都不行就【不写服务】
#
# 【安全边界】
#   * 绝不自动逐线扫描 GPIO；只测资料里明确给出的候选 + 你 --probe-* 指定的线
#   * ⚠⚠ 严禁 gpiochip1 的 70~80 线号区间（会掉线、必须拔电重启），全程打印警告
#   * libgpiod 的 gpioset 必须常驻才保证电平（v1 用 --mode=wait，v2 用 -c），
#     所以这里起后台进程并记 PID，切换时先杀旧的
#   * 任何中断（Ctrl+C / 退出）都会尽力把风扇恢复到关闭，不会让它一直转
#   * systemctl stop 报 "Unit not loaded" 是【正常】的：说明脚本还没部署到这台机器
# ===========================================================================
PROBE_PID=""
probe_gpio_write(){
  local chip="$1" line="$2" maj="$3" v="$4"
  if [[ -n "$PROBE_PID" ]] && kill -0 "$PROBE_PID" 2>/dev/null; then
    kill "$PROBE_PID" 2>/dev/null || true; wait "$PROBE_PID" 2>/dev/null || true
  fi
  if [[ "$maj" -ge 2 ]]; then
    gpioset -c "$chip" "$line=$v" </dev/null >/dev/null 2>&1 &
  else
    gpioset --mode=wait "$chip" "$line=$v" </dev/null >/dev/null 2>&1 &
  fi
  PROBE_PID=$!
  sleep 0.3
  if ! kill -0 "$PROBE_PID" 2>/dev/null; then
    PROBE_PID=""; return 1
  fi
  return 0
}
probe_sysfs_write(){
  # ★★ 必崩修复（本轮真机报告）：主脚本是 set -Eeuo pipefail，
  #   `local n="$1" ... d="/sys/class/gpio/gpio$n"` 在同一行引用刚赋值的 $n，
  #   bash 先展开整行再逐个赋值 → "n: unbound variable" 直接退出（SC2318）。
  #   影响：--fan-probe / --scan / --fan-test-on/off 连第一次「开风扇」都执行不到，
  #   实测记录文件生不出来 → 步骤 14 拒绝写温控服务。
  #   注：写给 systemd 的温控脚本里同款写法已在此前修好（sysfs_export/sysfs_write），
  #   已部署的服务不受影响；坏的是【针脚探测】这条路径。
  local n="$1" v="$2" d
  d="/sys/class/gpio/gpio$n"
  if [[ ! -e "$d/value" ]]; then
    printf '%s' "$n" > /sys/class/gpio/export 2>/dev/null || return 1
    sleep 0.1
  fi
  [[ -e "$d/value" ]] || return 1
  grep -qx out "$d/direction" 2>/dev/null || printf 'out' > "$d/direction" 2>/dev/null || return 1
  printf '%s' "$v" > "$d/value" 2>/dev/null || return 1
  return 0
}
probe_release(){
  if [[ -n "$PROBE_PID" ]] && kill -0 "$PROBE_PID" 2>/dev/null; then
    kill "$PROBE_PID" 2>/dev/null || true; wait "$PROBE_PID" 2>/dev/null || true
  fi
  PROBE_PID=""
}
# 把某候选的「开/关」动作真正执行一遍；返回 0 表示命令本身没报错。
# 参数 v 是【语义】1=开风扇 / 0=关风扇，内部按 FAN_ACTIVE_HIGH 映射成物理电平，
# 这样低电平触发（--fan-active-high=0）时 cleanup 写 0 依旧是「关」，不会反着来。
probe_action(){
  local typ="$1" chip="$2" line="$3" maj="$4" n="$5" v="$6" rc=0
  local ah="${FAN_ACTIVE_HIGH:-1}" lv
  if [[ "$v" == "1" ]]; then lv="$ah"; else lv=$((1-ah)); fi
  case "$typ" in
    libgpiod) probe_gpio_write "$chip" "$line" "$maj" "$lv" || rc=1 ;;
    sysfs|sysfs504)
      probe_sysfs_write "$n" "$lv" || rc=1
      # ★ 面板灯联动只在 504 那套 dtb 且用户明确要求时做。
      #   515（本机实测）是纯风扇引脚，474/476/477 在这套 dtb 下是别的线，绝不误写。
      if [[ "$n" == "504" && "$FAN_LED" != "off" ]]; then
        probe_sysfs_write "$FAN_LED_BLUE"  "$lv"      || rc=1
        probe_sysfs_write "$FAN_LED_RED"   "$lv"      || rc=1
        probe_sysfs_write "$FAN_LED_GREEN" "$((1-lv))" || rc=1
      fi
      ;;
    *) return 1 ;;
  esac
  return "$rc"
}
probe_ask(){
  local q="$1" ans=""
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    c_warn "非交互模式跳过人工确认：$q（请用交互终端跑 --fan-probe）"; return 1
  fi
  # ★ 与 component_gate 统一：提示写 /dev/tty、回答从 /dev/tty 读，
  #   不受 stdin/stdout 重定向影响。没有控制终端时明确报错，绝不静默当「否」。
  if [[ ! -r "$FAN_PROBE_TTY" || ! -w "$FAN_PROBE_TTY" ]]; then
    c_warn "无可用控制终端（$FAN_PROBE_TTY）：跳过人工确认「$q」（请在交互终端跑 --fan-probe）"
    return 1
  fi
  {
    printf '\n  ─────────────────────────────────────────────\n'
    printf '  %s\n' "$q"
    printf '  请输入 y（是）/ n 或直接回车（否）： '
  # 用 >> 而不是 >：/dev/tty 是字符设备，两者完全等价；但单元自测会把
  # FAN_PROBE_TTY 指向一个普通文件并预写答案，> 会先把它截断成提示文本，
  # 答案就丢了。>> 不会破坏预写内容，read 仍从第一行取到答案。
  } >> "$FAN_PROBE_TTY"
  IFS= read -r ans < "$FAN_PROBE_TTY" || ans=""
  printf '\n' >> "$FAN_PROBE_TTY"
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

fan_probe_cleanup(){
  probe_action "$P_TYPE" "$P_CHIP" "$P_LINE" "$P_MAJ" "$P_N" 0 >/dev/null 2>&1 || true
  probe_release
  c_warn "探测结束/中断：已尽力把风扇恢复到关闭状态（随后由温控服务接管）"
}

fan_probe(){
  c_step "风扇针脚实测（先确认「开→转」「关→停」，再写服务）"
  need_root
  # 实测结果优先写外置盘；外置盘没插/没挂时自动回退到本地镜像目录，
  # 这样单独测针脚不依赖 NAS 数据盘，也不会误改 /etc/fstab。
  if mkdir -p "$STATE_DIR" 2>/dev/null && [[ -w "$STATE_DIR" ]]; then
    FAN_PROBE_FILE="$STATE_DIR/fan-probe.env"
  else
    FAN_PROBE_FILE="$MIRROR_DIR/fan-probe.env"
    mkdir -p "$MIRROR_DIR" 2>/dev/null || true
    c_info "外置盘状态目录不可写，实测结果改存 $FAN_PROBE_FILE"
  fi
  mkdir -p "$BASE/logs" 2>/dev/null || true

  # 用户遇到的 "Failed to stop ... Unit not loaded" 完全正常，不算错误
  c_info "先停掉旧的温控服务（若提示 Unit not loaded 属正常，说明还没部署过）"
  systemctl stop armbian-fan 2>/dev/null || true
  systemctl disable armbian-fan 2>/dev/null || true

  c_warn "⚠⚠ 全程【绝不自动扫描 GPIO 线号】！严禁测试 gpiochip1 的 70~80 区间（会掉线，需拔电重启）"
  c_warn "⚠ 测试时请看着/听着风扇；任何时候按 Ctrl+C 都会尽力把风扇恢复关闭"
  c_info "本机：$(hostname)  架构=$(uname -m)  内核=$(uname -r)"
  c_info "设备树 compatible：$(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null || echo '<读不到>')"
  if command -v gpiodetect >/dev/null 2>&1; then gpiodetect 2>/dev/null | sed 's/^/    /'; fi
  if command -v gpioset >/dev/null 2>&1; then c_info "gpioset：$(gpioset --version 2>/dev/null || echo '?')"; fi
  c_info "/sys/class/gpio：$([[ -d /sys/class/gpio ]] && echo 存在 || echo '不存在（新内核可能已移除）')"

  if ! command -v gpioset >/dev/null 2>&1 && ! fan_sysfs_available; then
    apt_install_quiet gpiod || true
  fi
  command -v gpioset >/dev/null 2>&1 || c_warn "gpioset 不可用：libgpiod 候选将自动跳过，只测 sysfs"
  local maj; maj="$(fan_gpiod_major)"

  # ---- 候选清单：只列「资料里明确给出的安全引脚」，绝不枚举线号区间 ----
  # 来自用户 fan.sh 的 10 个排针引脚（AO 域 515-518 / Periphs 域 544-548、622），
  # 515 已实测确认，排第一。再补两套历史映射作为可选候选。
  local -a CAND=()
  local p n desc
  if [[ -n "$FAN_CONFIRMED_PIN" ]]; then
    # --fan-confirmed=515：用户已用 fan.sh 测过，只再跑一遍两轮确认就写服务
    CAND+=("sysfs|-|-|-|$FAN_CONFIRMED_PIN|★用户 fan.sh 实测确认（J9 Pin35 GPIOAO_3）")
    c_ok "已指定实测编号 $FAN_CONFIRMED_PIN，只验证这一根（开→转 / 关→停 两轮确认）"
  else
    if fan_sysfs_available; then
      for p in "${FAN_PROBE_PINS[@]}"; do
        n="${p%%:*}"; desc="${p#*: }"
        CAND+=("sysfs|-|-|-|$n|$desc")
      done
      # p212 dtb 的 504（带面板灯）作为可选备选，排在 10 个之后
      CAND+=("sysfs|-|-|-|504|另一套 dtb：p212 风扇+面板灯 474/476/477")
    fi
    if command -v gpioset >/dev/null 2>&1; then
      CAND+=("libgpiod|$FAN_GPIO_CHIP|$FAN_GPIO_LINE|$maj|-|另一套 dtb：libgpiod gpiochip0 line 3")
    fi
    if [[ -n "$PROBE_CHIP" && -n "$PROBE_LINE" ]] && command -v gpioset >/dev/null 2>&1; then
      CAND+=("libgpiod|$PROBE_CHIP|$PROBE_LINE|$maj|-|用户显式指定")
    fi
    if [[ -n "$PROBE_SYSFS" ]]; then
      CAND+=("sysfs|-|-|-|$PROBE_SYSFS|用户显式指定")
    fi
  fi
  (( ${#CAND[@]} > 0 )) || die "没有任何可测的候选：请装 gpiod / 确认 /sys/class/gpio，或用 --probe-sysfs= 指定"

  c_info "候选共 ${#CAND[@]} 个（按顺序逐个试，不扫描）："
  c_info "  有效电平：高电平开=$([[ ${FAN_ACTIVE_HIGH:-1} == 1 ]] && echo 是 || echo '否(低电平触发)')"
  c_warn "  ⚠ 这些是 sysfs【全局编号】；之前警告的 gpiochip1【line 70~80】是另一套命名空间，脚本绝不碰"
  local i item typ chip line cm
  for i in "${!CAND[@]}"; do
    IFS='|' read -r typ chip line cm n desc <<< "${CAND[$i]}"
    if [[ "$typ" == "libgpiod" ]]; then
      c_info "  #$((i+1))  libgpiod $chip line $line（gpiod v$cm）$desc"
    else
      c_info "  #$((i+1))  sysfs 全局编号 $n — $desc"
    fi
  done

  # 中断保护：无论 Ctrl+C / 退出 / 报错，都先尽力把风扇恢复到关闭，
# 并且 INT/TERM 必须真的退出（不能让脚本在被打断后继续测下一根线）。
  P_TYPE=""; P_CHIP=""; P_LINE=""; P_MAJ="1"; P_N=""
  trap fan_probe_cleanup EXIT
  trap 'exit 130' INT TERM

  local found=0 ok_on=0 ok_off=0
  for item in "${CAND[@]}"; do
    IFS='|' read -r typ chip line cm n desc <<< "$item"
    P_TYPE="$typ"; P_CHIP="$chip"; P_LINE="$line"; P_MAJ="$cm"; P_N="$n"
    c_step "测试候选：$typ $chip $line $n — $desc"
    if [[ "$typ" == "libgpiod" ]]; then
      c_info "  将执行【开】：gpioset ${cm} ${chip} ${line}=${FAN_ACTIVE_HIGH}（常驻进程保持电平）"
      c_warn "  这是另一套 dtb 的实测值；不同批次/不同 dtb 可能不同"
    else
      c_info "  将执行【开】：export $n → direction=out → value=${FAN_ACTIVE_HIGH}"
      if [[ "$n" == "515" ]]; then
        c_ok "  ✔ 与你的 fan.sh 实测一致：J9 Pin35 / GPIOAO_3，拉高风扇转"
      elif [[ "$n" == "504" ]]; then
        c_warn "  这套 504 只在 meson-gxl-s905x-p212.dtb 上验证过，且会联动面板灯"
      fi
    fi

    if ! probe_action "$typ" "$chip" "$line" "$cm" "$n" 1; then
      c_warn "  【开】命令执行失败（线被占用 / 编号不属于当前 dtb？），跳过该候选"
      probe_action "$typ" "$chip" "$line" "$cm" "$n" 0 >/dev/null 2>&1 || true
      probe_release; continue
    fi
    sleep "$FAN_PROBE_HOLD"
    if probe_ask "【第 1 轮】风扇现在转了吗？（看扇叶 / 听声音）"; then
      ok_on=1
      c_ok "  ✔ 已确认【开】有效：$typ $chip $line $n"
      c_info "  现在执行【关】，同样要你亲口确认停了，才会采用"
      if ! probe_action "$typ" "$chip" "$line" "$cm" "$n" 0; then
        c_warn "  【关】命令执行失败，该候选不采用"
        probe_release; continue
      fi
      sleep "$FAN_PROBE_HOLD"
      if probe_ask "【第 2 轮】风扇现在停了吗？"; then
        ok_off=1; found=1
        c_ok "  ✔ 已确认【关】有效 → 采用这套针脚，准备写入服务"
        break
      else
        c_warn "  ✘ 【关】没停：可能是低电平有效、或这根线不是风扇。恢复关闭并试下一个"
        probe_action "$typ" "$chip" "$line" "$cm" "$n" 0 >/dev/null 2>&1 || true
        probe_release; ok_on=0; continue
      fi
    else
      c_warn "  ✘ 【开】没转：这根线不是风扇（或电平反了）。恢复关闭并试下一个"
      probe_action "$typ" "$chip" "$line" "$cm" "$n" 0 >/dev/null 2>&1 || true
      probe_release; continue
    fi
  done

  trap 'sync_log' EXIT
  trap - INT TERM
  probe_release

  if [[ "$found" -ne 1 ]]; then
    c_warn "════════════════════════════════════════════════════════"
    c_warn "没有任何候选通过「开→转 + 关→停」两轮确认 → 【绝不写入温控服务】"
    c_warn "下一步建议："
    c_warn "  1) 确认当前 dtb：grep FDT /boot/uEnv.txt  或  cat /proc/device-tree/compatible"
    c_warn "  2) 只测你明确指定的一根线：--probe-chip=gpiochipX --probe-line=N --fan-probe"
    c_warn "  3) 或 sysfs 编号：--probe-sysfs=504 --fan-probe"
    c_warn "  4) 已有现成脚本就直接用：--fan-mode=custom --fan-on-cmd='...' --fan-off-cmd='...' --redo=14"
    c_warn "  5) ⚠⚠ 绝对不要去试 gpiochip1 的 70~80 区间（掉线需拔电重启）"
    return 1
  fi

  # ---- 两轮都确认了，才把结果落盘 ----
  # ★ 本文件会被 --fan-probe-apply 直接 source，所以每一行都必须是合法的
  #   shell 赋值：① 同一变量绝不写两次（后写者胜出会覆盖实测结果）；
  #   ② 自由文本必须加双引号并清洗，否则「J9 Pin35 ...」会被当成命令执行。
  #   /etc/default/armbian-fan 同理（温控脚本会 source 它）。
  # 旧版这里曾重复写 FAN_ACTIVE_HIGH=1 / FAN_SYSFS_FAN=504 / FAN_LED=auto，
  # 导致 --fan-active-high=0 的探测结果落盘后被改回 1（风扇开关反相）、
  # 504 候选被迫联动面板灯。已全部删除，只保留探测当时的真实值。
  local probe_fan_pin="$FAN_SYSFS_FAN" probe_pin_desc probe_desc_safe
  if [[ "$typ" == sysfs* && -n "$n" && "$n" != "-" ]]; then
    probe_fan_pin="$n"
  fi
  probe_pin_desc="${desc:-${FAN_PIN_DESC:-用户实测}}"
  probe_desc_safe="$(shell_quote_safe "$probe_pin_desc")"
  cat > "$FAN_PROBE_FILE" <<EOF
# armbian-nas 风扇针脚实测结果（$(date '+%F %T')）
# 生成前提：人工确认「开→风扇转」且「关→风扇停」两轮均通过。
# 本文件会被 --fan-probe-apply source：每个变量只写一次，文本字段带双引号。
FAN_MODE=${typ/sysfs504/sysfs}
FAN_MODE_EFF=${typ/sysfs504/sysfs}
FAN_SYSFS_FAN=$probe_fan_pin
FAN_PIN_DESC="$probe_desc_safe"
FAN_ACTIVE_HIGH=$FAN_ACTIVE_HIGH
FAN_GPIO_CHIP=${chip:-gpiochip0}
FAN_GPIO_LINE=${line:--}
FAN_GPIOD_MAJOR=${cm:-1}
FAN_FAILSAFE=$FAN_FAILSAFE
PROBE_CONFIRMED_ON=$ok_on
PROBE_CONFIRMED_OFF=$ok_off
PROBE_TYPE=$typ
PROBE_CHIP=${chip:--}
PROBE_LINE=${line:--}
PROBE_SYSFS=$probe_fan_pin
PROBE_PIN_DESC="$probe_desc_safe"
PROBE_ACTIVE_HIGH=$FAN_ACTIVE_HIGH
PROBE_GPIOD_MAJOR=${cm:-1}
EOF
  # FAN_LED 刻意【不写进结果文件】：它属于 LED 联动偏好、与针脚无关，
  # 让 --fan-probe-apply 沿用调用时的参数（默认 off，515 绝不联动面板灯）。
  chmod 600 "$FAN_PROBE_FILE"
  c_ok "两轮确认结果已写入 $FAN_PROBE_FILE"
  c_info "  模式=$typ  chip=$chip line=$line  sysfs=$n（$desc）  gpiod=v${cm:-1}  高电平开=${FAN_ACTIVE_HIGH}"

  if [[ "$FAN_PROBE_ONLY" -eq 1 ]]; then
    c_warn "已指定 --fan-probe-only：只记录结果，不启用服务"
    c_info "  确认无误后执行：sudo bash $SCRIPT_PATH --fan-probe-apply"
    return 0
  fi
  fan_probe_apply
}

# 把实测结果套进 step_fan 生成温控服务（也可单独用 --fan-probe-apply 调用）
fan_probe_apply(){
  # 结果可能在本地镜像目录（单独测针脚、外置盘未挂载时）
  if [[ ! -r "$FAN_PROBE_FILE" && -r "$MIRROR_DIR/fan-probe.env" ]]; then
    FAN_PROBE_FILE="$MIRROR_DIR/fan-probe.env"
  fi
  [[ -r "$FAN_PROBE_FILE" ]] || die "没有实测结果文件 $FAN_PROBE_FILE，请先跑 --fan-probe 并完成两轮确认"
  # shellcheck disable=SC1090
  source "$FAN_PROBE_FILE"
  # 清掉可能存在的自定义命令，否则 fan_mode_resolve 会优先走 custom 覆盖实测结果
  FAN_ON_CMD=""; FAN_OFF_CMD=""
  c_step "把实测针脚写入温控服务并启用"
  probe_release     # 先释放探测进程，避免和服务的常驻 gpioset 抢同一条 line
  step_fan
  c_ok "温控服务已按实测结果启用：≥${FAN_ON_TEMP}℃ 开 / ≤${FAN_OFF_TEMP}℃ 关"
  c_info "  实时日志：tail -f $BASE/logs/fan.log"
  c_info "  想再手动验证一次：sudo bash $SCRIPT_PATH --fan-test-on  （保持 ${FAN_PROBE_HOLD}s 后自动恢复服务）"
  return 0
}

# 装好服务后的手动开关测试：临时停服务 → 保持 N 秒 → 自动恢复服务
fan_test_action(){
  local act="$1" hold="${FAN_PROBE_HOLD:-10}" typ chip line maj n
  need_root
  [[ -r /etc/default/armbian-fan ]] || die "没有 /etc/default/armbian-fan，请先跑 --fan-probe 或 --redo=14"
  # 只读需要的字段，不 source 整个文件（里面的 FAN_ON_CMD 依赖温控脚本内部函数）
  typ="$(grep -F 'FAN_MODE_EFF=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2)"
  [[ -z "$typ" ]] && typ="$(grep -F 'FAN_MODE=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2)"
  chip="$(grep -F 'FAN_GPIO_CHIP=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2)"
  line="$(grep -F 'FAN_GPIO_LINE=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2)"
  maj="$(grep -F 'FAN_GPIOD_MAJOR=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2)"
  n="$(grep -F 'FAN_SYSFS_FAN=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2)"
  c_info "当前温控模式=$typ；临时停服务避免抢 GPIO"
  systemctl stop armbian-fan 2>/dev/null || true
  trap 'probe_action "$typ" "$chip" "$line" "${maj:-1}" "${n:-504}" 0 >/dev/null 2>&1 || true; probe_release; systemctl start armbian-fan >/dev/null 2>&1 || true; c_info "温控服务已恢复"' EXIT
  trap 'exit 130' INT TERM
  local v=1; [[ "$act" == "off" ]] && v=0
  if probe_action "$typ" "$chip" "$line" "${maj:-1}" "${n:-504}" "$v"; then
    c_ok "已执行【$act】，保持 ${hold}s 请观察风扇（Ctrl+C 可提前结束并恢复服务）"
    sleep "$hold"
  else
    c_warn "【$act】命令执行失败，检查 GPIO 是否被占用"
  fi
  probe_action "$typ" "$chip" "$line" "${maj:-1}" "${n:-504}" 0 >/dev/null 2>&1 || true
  probe_release
  trap - EXIT INT TERM
  systemctl start armbian-fan >/dev/null 2>&1 || true
  c_info "温控服务已恢复；日志 tail -f $BASE/logs/fan.log"
  return 0
}

step_emmc_baseline(){
  c_step "[19] eMMC 瘦身与 PHP 安全基线"
  local before_kb after_kb
  before_kb="$(df -k / 2>/dev/null | awk 'NR==2{print $3}' || echo 0)"

  # 1) Docker 日志轮转 + 存量容器检查（Docker 被跳过时整段略过）
  if component_chosen docker && command -v docker >/dev/null 2>&1; then
    if docker_daemon_baseline; then
      systemctl restart docker 2>/dev/null || c_warn "重启 Docker 失败，日志轮转将在下次重启后生效"
    fi
    docker_rebuild_for_logconfig
    # 2) 可选：整个 data-root 挪到外置盘（默认关）
    docker_external_setup
  else
    c_info "Docker 组件未安装/已跳过：跳过 daemon.json 日志轮转与 data-root 外置（其余瘦身照常做）"
  fi

  # 3) journald 限额（Armbian 常见 /var/log 挂 zram，此时再提示不重复搬）
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/99-armbian-nas.conf <<EOF
[Journal]
SystemMaxUse=$JOURNALD_MAX_USE
MaxRetentionSec=$JOURNALD_RETENTION
EOF
  systemctl restart systemd-journald 2>/dev/null || true
  journalctl --vacuum-size="$JOURNALD_MAX_USE" >/dev/null 2>&1 || true
  local logsrc; logsrc="$(findmnt -rn --target /var/log -o SOURCE 2>/dev/null || true)"
  if [[ "$logsrc" == *zram* || "$logsrc" == *tmpfs* ]]; then
    c_ok "journald 限额 $JOURNALD_MAX_USE；/var/log 已在 $logsrc（内存，不占 eMMC）"
  else
    c_ok "journald 限额 $JOURNALD_MAX_USE / $JOURNALD_RETENTION（/var/log 在 $logsrc）"
  fi

  # 4) zram 优先 / 磁盘 swap 兜底 + swappiness（按内核版本自适应，详见上方注释）
  zram_baseline
  # 5) 低内存自适应（1G RAM 的 S905X 必须限制 php-fpm 进程数）
  lowmem_baseline

  # 6) 根分区保留块 5% → 1%
  local rootdev rootfst
  rootdev="$(findmnt -no SOURCE / 2>/dev/null || true)"
  rootfst="$(stat -f -c %T / 2>/dev/null || echo unknown)"
  if command -v tune2fs >/dev/null 2>&1 && [[ "$rootdev" == /dev/* ]] \
     && [[ "$rootfst" == ext4 || "$rootfst" == ext3 || "$rootfst" == ext2 ]]; then
    tune2fs -m "$EXT4_RESERVE_PCT" "$rootdev" >/dev/null 2>&1 \
      && c_ok "根分区 $rootdev 保留块 5% → $EXT4_RESERVE_PCT%（8G 盘约释放 300MB）" \
      || c_warn "tune2fs 调整失败（只读根文件系统？），跳过"
  else
    c_info "根分区 $rootdev ($rootfst) 非 ext 家族设备，跳过保留块调整"
  fi

  # 7) 部署日志限额（tee -a 持有 fd，必须 copytruncate）
  if [[ -d /etc/logrotate.d ]]; then
    cat > /etc/logrotate.d/armbian-nas-deploy <<EOF
$BOOT_LOG {
    size $BOOT_LOG_MAX_SIZE
    rotate 3
    compress
    missingok
    notifempty
    copytruncate
}
EOF
    c_ok "$BOOT_LOG 日志轮转上限 $BOOT_LOG_MAX_SIZE × 3"
  fi

  # 8) apt 缓存/lists 挪到外置盘（可再生缓存，零稳定性风险）
  if [[ "$APT_CACHE_ON_EXTERNAL" -eq 1 ]]; then
    mkdir -p "$BASE/apt/archives/partial" "$BASE/apt/lists/partial"
    relocate_dir /var/cache/apt/archives "$BASE/apt/archives"
    relocate_dir /var/lib/apt/lists    "$BASE/apt/lists"
    cat > /etc/apt/apt.conf.d/99-armbian-nas.conf <<EOF
// armbian-nas：缓存与索引落在外置盘，节约 eMMC
Dir::Cache::archives "$BASE/apt/archives";
Dir::State::lists    "$BASE/apt/lists";
// NTFS 由 fstab uid/gid/umask 统一映射，_apt 沙箱用户不一定能写，故用 root 下载
APT::Sandbox::User "root";
EOF
    c_ok "apt 缓存/lists 已外置到 $BASE/apt"
  fi

  # 9) PHP 安全基线：open_basedir 收口，.deploy（含 RPC 密钥）对 PHP 完全不可达
  local cfg="$BASE/config" secini="$PHP_ETC/fpm/conf.d/99-armbian-nas-security.ini"
  mkdir -p "$cfg" "$BASE/php-sessions" "$BASE/logs" \
           "$PHP_ETC/fpm/conf.d" "$PHP_ETC/fpm/pool.d" \
    || die "无法创建 PHP 配置目录，请确认 php$PHP_VER-fpm 已正确安装"
  cat > "$secini" <<EOF
; armbian-nas PHP 8.2 安全基线（步骤 19）
; 只放行站点运行必需的目录，刻意不含 $STATE_DIR —— secrets.env 等敏感文件不可被 PHP 读取
open_basedir    = $WEB_ROOT:$BASE/db:$BASE/downloads:$BASE/logs:$BASE/php-sessions:/tmp:/usr/share/php
allow_url_fopen  = Off
allow_url_include = Off
expose_php       = Off
display_errors   = Off
log_errors       = On
session.save_path = $BASE/php-sessions
; 这里刻意不写 disable_functions：下方生成「不能禁」白名单与冲突检查报告
EOF

  # admin 池模板：默认只生成模板，不落地 root 池，避免开箱即暴露提权面
  local cidr; cidr="$(lan_ip | awk -F. 'NF==4{print $1"."$2"."$3".0/24"}' || true)"
  [[ -n "$cidr" ]] || cidr="192.168.1.0/24"
  cat > "$cfg/nas-admin.pool.conf.template" <<EOF
; armbian-nas admin FPM 池模板（需要时手动启用）
; 用途：给「必须能调 exec / pcntl / sockets / shmop / imap」的 PHP 运维脚本单独用
; 默认不放入 $PHP_ETC/fpm/pool.d/；启用见下方启用命令
[nas-admin]
user = root
group = root
listen = 127.0.0.1:9001
pm = ondemand
pm.max_children = 2
pm.process_idle_timeout = 30s
clear_env = yes
php_admin_value[disable_functions] = none
php_admin_value[open_basedir] = $BASE/:/tmp
php_admin_value[error_log] = $BASE/logs/php-admin-error.log
EOF
  cat > "$cfg/nas-admin.nginx.snippet" <<'EOF'
# 把本片段 include 进 server{} 之前，先创建密码文件：
#   htpasswd -c /etc/nginx/.htpasswd nasadmin     （apache2-utils / nginx-extras 提供）
location ^~ /admin/ {
    allow __CIDR__;
    deny  all;
    auth_basic           "nas-admin";
    auth_basic_user_file /etc/nginx/.htpasswd;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    fastcgi_pass 127.0.0.1:9001;
}
EOF
  sed -i "s|__CIDR__|$cidr|g" "$cfg/nas-admin.nginx.snippet"
  if [[ "$ENABLE_ADMIN_POOL" -eq 1 ]]; then
    cp -f "$cfg/nas-admin.pool.conf.template" "$PHP_ETC/fpm/pool.d/nas-admin.conf"
    if "/usr/sbin/php-fpm$PHP_VER" -t >/dev/null 2>&1; then
      systemctl reload "$PHP_FPM_SVC" 2>/dev/null || systemctl restart "$PHP_FPM_SVC" 2>/dev/null || true
      c_ok "admin 池已落地（仅 127.0.0.1:9001，nginx 未引用）；Web 入口需手动 include $cfg/nas-admin.nginx.snippet"
    else
      c_warn "php-fpm -t 未通过，已移除 admin 池以免影响站点"
      rm -f "$PHP_ETC/fpm/pool.d/nas-admin.conf"
    fi
  else
    c_ok "admin 池模板：$cfg/nas-admin.pool.conf.template（未启用，零风险）"
    c_info "需要时：sudo bash $SCRIPT_PATH --enable-admin-pool --redo=19"
  fi

  # disable_functions 冲突检查 + 建议文档（全程不擅自改动用户已有加固配置）
  cat > "$cfg/disable_functions-建议.md" <<'EOF'
# PHP 8.2 disable_functions 处理建议

## 硬限制（先记住）
- `disable_functions` 只能禁「函数」，**禁不了 `eval`**（它是语言结构），也**禁不了类方法**
  （`PDO::query`、`Redis::get`、`EventBase::loop` 等）。要挡 eval 只能靠 Suhosin 或代码审计。
- `php8.2 -m` 只说明「扩展已加载」，`function_exists()` 才说明「函数能调」。
- CLI 与 FPM 是两套 ini，改完必须两边都验。

## 本脚本绝对不能禁的函数
| 分组 | 函数 | 原因 |
|---|---|---|
| 探针/站点自身 | file_get_contents, fopen, fread, fwrite, file, is_readable, glob, scandir, get_loaded_extensions, function_exists, ini_get, php_sapi_name | probe.php、扩展核对、状态页 |
| 进程与系统 | exec, shell_exec, system, passthru, proc_open, proc_close, popen, escapeshellarg, pcntl_fork, pcntl_exec, pcntl_wait, pcntl_signal, posix_kill, posix_getpid, posix_setuid | pcntl / posix / 以后调 zerotier-cli、hdparm -C、docker ps |
| IPC 与网络 | shmop_open, shmop_read, sem_get, sem_acquire, msg_get_queue, socket_create, socket_connect, stream_socket_client, fsockopen | shmop / sysvsem / sockets |
| 扩展函数 | imap_open, curl_init, curl_exec, curl_setopt, opcache_get_status, opcache_reset, opcache_invalidate, exif_read_data, finfo_open, gmp_init, mb_strlen, json_encode, json_decode, preg_replace, preg_match | imap / curl / Zend OPcache / exif / fileinfo / gmp / mbstring / json / pcre |

## 推荐做法：不要全局黑名单，改「分池隔离」
1. 默认 www 池：`open_basedir` 收口（本脚本已做），`disable_functions` 留空。
2. 需要 exec/socket/shmop 的运维脚本：放进 admin 池（模板见同目录），
   `disable_functions=none` + nginx `allow 内网` + `auth_basic` + 独立 socket。
3. 真要加固时，只禁与业务确认无关的函数，且改完立刻跑：
   `php8.2 -r 'foreach(["exec","shell_exec",...] as $f) echo $f,":",function_exists($f)?"OK":"DISABLED","\n";'`
   并在浏览器打开 `/probe.php` 看 FPM 侧 `DISABLE_FUNCTIONS:` 与 `PHP_EXT_ALL_OK`。

## 检查命令
    grep -R "disable_functions" /etc/php/8.2/
    php8.2 -i | grep -i disable_functions
    /usr/sbin/php-fpm8.2 -i | grep -i disable_functions
    curl -s http://127.0.0.1/probe.php | grep -E 'DISABLE_FUNCTIONS|PHP_EXT_'
EOF
  local probe df_line blocked="" f
  probe="$(curl -fsS --max-time 8 'http://127.0.0.1/probe.php' 2>/dev/null || true)"
  df_line="$(printf '%s\n' "$probe" | awk -F': ' '/^DISABLE_FUNCTIONS:/{print $2; exit}')"
  if [[ -n "$df_line" && "$df_line" != "(none)" ]]; then
    local -a dfa=()
    IFS=',' read -ra dfa <<< "$df_line"
    for f in "${dfa[@]}"; do
      f="$(printf '%s' "$f" | tr -d ' \t')"
      [[ -z "$f" ]] && continue
      [[ ",$PHP_KEEP_FUNCS," == *",$f,"* ]] && blocked+=" $f"
    done
  fi
  if [[ -n "$blocked" ]]; then
    c_warn "FPM 当前 disable_functions 命中「不能禁」白名单：$blocked"
    c_warn "探针可能误报、扩展函数可能失效；详见 $cfg/disable_functions-建议.md（脚本未擅自改动你的配置）"
  else
    c_ok "disable_functions 未误伤白名单（当前 FPM 值：${df_line:-未取到}）"
  fi

  # 10) CLI / FPM 双端扩展核对：重写探针保证内嵌清单最新，再分别比对
  write_probe_php
  systemctl reload "$PHP_FPM_SVC" 2>/dev/null || systemctl restart "$PHP_FPM_SVC" 2>/dev/null || true
  sleep 1
  if php_ext_audit; then
    c_ok "CLI 侧 $PHP_BIN -m：清单全部齐全"
  else
    c_warn "CLI 侧缺失：$(paste -sd, "$PHP_EXT_MISSING" 2>/dev/null || true)"
  fi
  if php_ext_audit_fpm; then
    c_ok "FPM 侧（网页真实环境）：清单全部齐全，与 CLI 一致"
  else
    c_warn "FPM 侧缺失：$(paste -sd, "$PHP_EXT_MISSING_FPM" 2>/dev/null || true)"
    c_warn "CLI 与 FPM 的 conf.d 加载不一致时，检查 $PHP_ETC/{cli,fpm}/conf.d/ 与 $secini"
  fi

  # 11) 清理可再生缓存，打印前后对比
  apt-get clean >/dev/null 2>&1 || true
  docker system prune -f >/dev/null 2>&1 || true
  [[ -f "$secini" ]] || c_warn "安全基线 ini 未写入，请检查 $PHP_ETC/fpm/conf.d 权限后 --redo=19"
  after_kb="$(df -k / 2>/dev/null | awk 'NR==2{print $3}' || echo 0)"
  c_ok "eMMC 根分区已用：${before_kb}KB → ${after_kb}KB（写入配置会让数值略升，收益在于日志/缓存不再无限增长）"
  c_info "$(df -h / 2>/dev/null | awk 'NR==2{print "  " $1 "  " $2 " 已用 " $3 " 可用 " $4 " (" $5 ")"}')"
  c_info "巡检：df -h / · docker system df -v · journalctl --disk-usage · du -sh $BASE"
}

# ------------------------------ 组件清单（安装 / 运行 / 配置）----------------
INVENTORY_TEXT=""
component_running(){
  local k="$1"
  case "$k" in
    docker)       docker info >/dev/null 2>&1 ;;
    verysync)     port_open 8886 || svc_active verysync ;;
    zerotier)     svc_active zerotier-one ;;
    qb)           svc_active qbittorrent-nox && port_open 8080 ;;
    transmission) svc_active transmission-daemon && port_open 9091 ;;
    aria2)        svc_active aria2 && port_open 6800 ;;
    minidlna)     svc_active minidlna ;;
    samba)        svc_active smbd ;;
    fan)          svc_active armbian-fan ;;
    filebrowser)  svc_active armbian-filebrowser && port_open "$PORT_FB" ;;
    hd_idle)      svc_active hd-idle || svc_active armbian-hdparm.timer ;;
    gui)          # ★ 真机反馈：Armbian 镜像默认可能就是 graphical.target，
                  #   单看它会把「选择跳过」误显示成「已安装 / 运行中」。
                  #   必须同时确认 XFCE 本体确实在。
                  { command -v startxfce4 >/dev/null 2>&1 || \
                    dpkg -s xfce4 >/dev/null 2>&1 || \
                    dpkg -s xfce4-session >/dev/null 2>&1; } && \
                  systemctl get-default 2>/dev/null | grep -q graphical ;;
    *)            return 1 ;;
  esac
}
component_version(){
  local k="$1" v=""
  case "$k" in
    docker)       v="$(docker --version 2>/dev/null | awk '{print $3}' | tr -d , || true)" ;;
    verysync)     v="$([[ -x /usr/bin/verysync/verysync ]] && echo 已部署 || echo -)" ;;
    zerotier)     v="$(zerotier-cli info 2>/dev/null | awk '{print $3}' || true)" ;;
    qb)           v="$(qbittorrent-nox --version 2>/dev/null | awk '{print $2}' || true)" ;;
    transmission) v="$(transmission-daemon --version 2>/dev/null | head -1 || true)" ;;
    aria2)        v="$(aria2c --version 2>/dev/null | head -1 | awk '{print $3}' || true)" ;;
    minidlna)     v="$(dpkg-query -W -f='${Version}' minidlna 2>/dev/null || true)" ;;
    samba)        v="$(smbd --version 2>/dev/null | awk '{print $2}' || true)" ;;
    fan)          v="脚本温控" ;;
    hd_idle)      v="$(dpkg-query -W -f='${Version}' hd-idle 2>/dev/null || echo hdparm回退)" ;;
    gui)          v="$(dpkg-query -W -f='${Version}' xfce4 2>/dev/null || true)" ;;
    filebrowser)  v="$(/usr/local/bin/filebrowser version 2>/dev/null | head -1 || /usr/local/bin/filebrowser --version 2>/dev/null | head -1 || true)" ;;
  esac
  printf '%s' "${v:--}"
}
component_config_text(){
  local k="$1"
  case "$k" in
    docker)
      printf 'unit=docker.service | daemon.json=%s | data-root=%s | 日志轮转=%s×%s\n' \
        /etc/docker/daemon.json "$(stat -f -c %T /var/lib/docker 2>/dev/null || echo 未安装)" \
        "$DOCKER_LOG_MAX_SIZE" "$DOCKER_LOG_MAX_FILE"
      printf '  外置盘镜像=%s（--docker-external=%s）| 用户组 docker\n' "$DOCKER_LOOP_IMG" "$DOCKER_EXTERNAL" ;;
    verysync)
      printf 'unit=%s(drop-in) | WebUI :8886 | --home=%s | --gui-address=0.0.0.0:8886\n' \
        "$(systemctl list-unit-files --no-legend 2>/dev/null | awk '/verysync.*\.service/{print $1;exit}' || echo verysync.service)" \
        "$BASE/verysync" ;;
    zerotier)
      printf 'unit=zerotier-one | 9993/udp | NetworkID=%s | 授权：ZeroTier Central 勾选\n' \
        "${ZT_NETWORK_ID:-<未加入>}" ;;
    qb)
      printf 'unit=qbittorrent-nox.service | WebUI :8080 | 已写入 admin/adminadmin（中文界面）\n'
      printf '  conf=%s | WebUI文件=%s\n' "$BASE/qb/config/qBittorrent/qBittorrent.conf" "$BASE/webui/qbittorrent"
      printf '  下载=%s | 临时=%s | BT端口=6881\n' "$BASE/downloads/complete" "$BASE/downloads/incomplete" ;;
    transmission)
      printf 'unit=transmission-daemon.service (+10-armbian-nas.conf) | WebUI :9091\n'
      printf '  conf=%s | WebUI文件=%s (TRANSMISSION_WEB_HOME)\n' \
        "$BASE/transmission/settings.json" "$BASE/webui/transmission"
      printf '  下载=%s | 监视=%s | BT端口=51413\n' "$BASE/downloads/complete" "$BASE/downloads/watch" ;;
    aria2)
      printf 'unit=aria2.service | RPC :6800 + nginx /jsonrpc 反代 | AriaNg=%s\n' "$WEB_ROOT/ariang"
      printf '  conf=%s | session=%s | 密钥=%s\n' \
        "$BASE/aria2/aria2.conf" "$BASE/aria2/aria2.session" "$SECRETS_FILE" ;;
    minidlna)
      printf 'unit=minidlna.service | 状态页 :8200 | friendly_name=armbian-nas | 1900/udp SSDP\n'
      printf '  conf=/etc/minidlna.conf | db=%s | 共享清单=%s\n' "$BASE/minidlna/db" "$SHARES_FILE" ;;
    samba)
      printf 'unit=smbd.service | 445/139 | read only=%s | 共享段落 [video-*]\n' \
        "$([[ "$SMB_WRITABLE" -eq 1 ]] && echo no || echo yes)"
      printf '  conf=/etc/samba/smb.conf | 共享清单=%s\n' "$SHARES_FILE" ;;
    fan)
      local _fmode _fpin _fah _fled
      _fmode="$(grep -F 'FAN_MODE=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo '<待配置>')"
      _fpin="$(grep -F 'FAN_SYSFS_FAN=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo 515)"
      _fah="$(grep -F 'FAN_ACTIVE_HIGH=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo 1)"
      _fled="$(grep -F 'FAN_LED_EFF=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo 0)"
      printf 'unit=armbian-fan.service | ≥%s℃开 / ≤%s℃关 | 轮询%ss | 最少运行%ss\n' \
        "$FAN_ON_TEMP" "$FAN_OFF_TEMP" "$FAN_POLL" "$FAN_MIN_RUN"
      printf '  ★控制方式=%s | sysfs全局编号=%s（%s）| 高电平开=%s | 面板灯联动=%s\n' \
        "$_fmode" "$_fpin" "$FAN_PIN_DESC" "$_fah" "$_fled"
      printf '  开=写%s /sys/class/gpio/gpio%s/value，关=写%s；fail-safe=%s\n' \
        "$_fah" "$_fpin" "$((1-_fah))" "$FAN_FAILSAFE"
      printf '  ⚠ 515 是纯风扇引脚，474/476/477 是别的线，绝不联动；禁止扫描 gpiochip1 line 70~80\n'
      printf '  备选映射：504(p212 dtb,--fan-sysfs-fan=504 --fan-led=on) / libgpiod line3 | 日志=%s\n' \
        "$BASE/logs/fan.log" ;;
    hd_idle)
      printf 'unit=hd-idle.service（或 armbian-hdparm.timer 回退）| 空闲%ss 休眠 | hdparm -S=%s（5秒粒度，向上取整并钳到1..240）\n' \
        "$HD_IDLE_TIMEOUT" "$(hdparm_spindown_units)"
      printf '  日志=%s | 设备=%s,%s\n' "$BASE/logs/hd-idle.log" "$MAIN_DEV" "$SECOND_DEV" ;;
    ttyd)
      printf 'unit=armbian-ttyd.service | :%s 仅 127.0.0.1 | nginx %s/ + auth_basic\n' "$TTYD_PORT" "$TTYD_PATH"
      printf '  命令=%s -i 127.0.0.1 -p %s -b %s -W -m %s %s\n' \
        "$(command -v ttyd 2>/dev/null || echo /usr/local/bin/ttyd)" "$TTYD_PORT" "$TTYD_PATH" "$TTYD_MAX_CLIENTS" "$TTYD_CMD"
      printf '  用户=%s | 网页登录名=%s | 密码=%s（TTYD_WEB_PASS，页面不显示值）\n' \
        "$TTYD_USER" "$TTYD_AUTH_USER" "$SECRETS_FILE"
      printf '  ⚠ 等于浏览器里的 root shell：不要暴露公网；密码别写进网页\n'
      ;;
    gui)
      printf 'default-target=%s | xrdp :3389 | 桌面=XFCE\n' \
        "$(systemctl get-default 2>/dev/null || echo 未安装)" ;;
  esac
}
component_inventory(){
  local k chosen inst run ver cfg
  INVENTORY_TEXT=""
  for k in "${COMP_KEYS[@]}"; do
    case "$(component_decision "$k")" in
      chosen)      chosen="安装" ;;
      uninstalled) chosen="已卸载（下次运行会再问）" ;;
      skip)        chosen="已跳过（下次运行会再问）" ;;
      *)           chosen="尚未部署（未选择，下次运行会询问）" ;;
    esac
    if component_installed "$k"; then inst="已安装"; else inst="未安装"; fi
    if [[ "$inst" == "未安装" ]]; then run="—"
    elif component_running "$k"; then run="运行中"
    else run="未运行"; fi
    ver="$(component_version "$k")"
    cfg="$(component_config_text "$k")"
    INVENTORY_TEXT+="[${COMP_STEP[$k]}] ${COMP_NAME[$k]}
  选择: $chosen   安装: $inst   运行: $run   版本: ${ver:--}   eMMC≈${COMP_SIZE[$k]}
  配置: $cfg
"
  done
  printf '%s' "$INVENTORY_TEXT"
}

# 纯文本版「路径清单」：终端自检和最终报告用。
# 和首页 JSON 快照共用同一份 component_path_rows()，保证三处显示一致，不会
# 出现「首页说在 A 目录、报告说在 B 目录」这种让新手更迷糊的情况。
INVENTORY_PATHS_TEXT=""
component_paths_text(){
  local k label value out=""
  for k in "${COMP_KEYS[@]}"; do
    out+="[${COMP_STEP[$k]}] ${COMP_NAME[$k]}"$'\n'
    while IFS=$'\t' read -r label value; do
      [[ -z "$label" ]] && continue
      out+="$(printf '   %-22s %s\n' "$label" "${value:-}")"$'\n'
    done < <(component_path_rows "$k")
    out+=$'\n'
  done
  INVENTORY_PATHS_TEXT="$out"
  printf '%s' "$out"
}

# ===========================================================================
#                            卸 载 功 能
# ---------------------------------------------------------------------------
# 面向不熟悉 Linux 的用户，卸载按下面几条规矩设计，请先看懂再改：
#
# 【规矩 1】默认只卸「软件本体 + 系统里的配置」，绝不动外置盘上的用户数据。
#   也就是说：卸载 qBittorrent 之后，你已经下载好的电影/种子、保存的设置，
#   仍然原封不动躺在 /mnt/sda1/www 里。以后想装回来，设置还在。
#   想连这些数据一起删，必须显式加 --purge-data，并且会再确认一次。
#
# 【规矩 2】共用目录永远不删，哪怕加了 --purge-data。
#   $BASE/downloads 是 qB、Transmission、aria2 三家共用的下载目录；
#   $BASE/web 是网站根目录；$BASE/logs、$BASE/db、$BASE/.deploy 装的是
#   日志、数据库、RPC 密钥和断点续跑状态。删了会连带弄坏别的功能，
#   所以下面 safe_purge_dir() 里有一份明确的「保护名单」。
#
# 【规矩 3】卸载前一定要二次确认（输入 yes 才动手），并把「将删除 / 将保留」
#   两类路径分别列出来，让你看清楚再决定。批量脚本可加 --yes 跳过。
#
# 【规矩 4】卸载后把该步骤状态写成 uninstalled，而不是 done 或 skip。
#   run_step 看到 uninstalled 不会跳过，会重新弹出「是否安装？」，
#   于是「下次运行脚本 → 输入 y → 装回来」这条路径是通的，和跳过的行为一致。
#
# 【规矩 5】只 purge 本脚本装过的包，不做 apt-get autoremove。
#   autoremove 有可能顺手删掉别的组件还在用的依赖（例如 unzip），
#   对小白来说太难排查，宁可留一点无害的残留也不冒险。
# ===========================================================================

# ---- 通用小工具 -------------------------------------------------------------

# 停掉并取消开机自启；不存在的服务直接忽略，不报错
svc_stop_disable(){
  local u
  for u in "$@"; do
    [[ -n "$u" ]] || continue
    systemctl disable --now "$u" >/dev/null 2>&1 || true
  done
  systemctl daemon-reload 2>/dev/null || true
}

# 删除明确列出的文件或目录。只接受「一个个写死的路径」，不接受通配符，
# 避免 rm -rf 误伤；路径不存在就安静跳过。
rm_paths(){
  local p
  for p in "$@"; do
    [[ -n "$p" && "$p" != "/" ]] || continue
    if [[ -e "$p" || -L "$p" ]]; then
      rm -rf -- "$p" && c_info "已删除：$p" \
        || c_warn "删除失败（权限？）：$p"
    fi
  done
}

# purge 软件包；包本来就没装时 apt 会报错，这里降级为提示，不中断整个卸载
apt_purge(){
  (( $# > 0 )) || return 0
  c_info "apt purge：$*"
  DEBIAN_FRONTEND=noninteractive apt-get purge -y "$@" >/dev/null 2>&1 \
    || c_info "（部分包本来就没装或已被移除，继续清理残留文件）"
}

# 二次确认：ASSUME_YES=1（--yes）时直接通过；否则必须在终端输入 yes
confirm_yes(){
  local prompt="$1" ans
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    c_warn "$prompt → --yes 已跳过交互确认"
    return 0
  fi
  # 没有可交互终端（定时任务、管道、CI、部分容器）时绝不阻塞等待输入，
  # 直接取消并告诉用户怎么明确确认，避免「脚本挂住一整晚」。
  if [[ "$NONINTERACTIVE" -eq 1 || ! -r /dev/tty || ! -w /dev/tty ]]; then
    c_warn "当前没有可交互终端且未加 --yes，已取消操作。请加 --yes 明确确认，或在 SSH 终端里运行"
    return 1
  fi
  printf '\n%s  [输入 yes 继续 / 其它任意键取消]：' "$prompt" > /dev/tty
  read -r ans < /dev/tty || ans=""
  printf '\n' > /dev/tty
  [[ "${ans,,}" == "yes" || "${ans,,}" == "y" ]]
}

# 安全地删除「组件专属」数据目录（仅 --purge-data 时调用）。
# 三重保险：① 必须在 $BASE 之下；② 不能是 $BASE 自己；③ 不能命中保护名单。
safe_purge_dir(){
  local d="$1" base_abs
  base_abs="$(readlink -f "$BASE" 2>/dev/null || printf '%s' "$BASE")"
  d="${d%/}"
  [[ -n "$d" && "$d" != "/" && "$d" != "$base_abs" ]] \
    || { c_warn "拒绝删除根目录/数据根：$d"; return 1; }
  case "$d" in
    "$base_abs"/web|"$base_abs"/downloads|"$base_abs"/logs|"$base_abs"/db|\
    "$base_abs"/.deploy|"$base_abs"/apt|"$base_abs"/config|"$base_abs"/video)
      c_warn "保护目录（其它功能在用），跳过删除：$d"
      return 1 ;;
  esac
  case "$d" in
    "$base_abs"/*) : ;;
    *) c_warn "不在 $BASE 下，拒绝删除：$d"; return 1 ;;
  esac
  if [[ -e "$d" ]]; then
    local n; n="$(find "$d" -mindepth 1 2>/dev/null | wc -l || echo 0)"
    c_warn "将删除 $d （约 $n 个条目）"
    rm -rf -- "$d" && c_ok "已删除组件数据目录：$d" \
      || c_warn "删除失败：$d"
  fi
}

# 每个组件「专属数据目录」清单（--purge-data 用）。
# 注意：这里刻意不含 $BASE/downloads / web / logs / db，它们是共用的。
component_purge_dirs(){
  # 只列「组件专属的用户数据目录」：默认保留，--purge-data 时才删。
  # 网页界面文件（$BASE/webui/*、$WEB_ROOT/ariang）属于程序界面，
  # 由各 uninstall_* 函数默认删除，不放在这里，避免预览和实际行为不一致。
  case "$1" in
    qb)           printf '%s\n' "$BASE/qb" ;;
    transmission) printf '%s\n' "$BASE/transmission" ;;
    aria2)        printf '%s\n' "$BASE/aria2" ;;
    verysync)     printf '%s\n' "$BASE/verysync" ;;
    minidlna)     printf '%s\n' "$BASE/minidlna" ;;
    ttyd)         printf '%s\n' "$BASE/ttyd" ;;
    filebrowser)  printf '%s\n' "$BASE/filebrowser" ;;
    docker)       printf '%s\n' "$BASE/.docker-ext4.img" ;;
    *)            return 0 ;;   # 其余组件没有独立数据目录
  esac
}

# 卸载预览：把「会删」和「会留」讲清楚
uninstall_preview(){
  local k="$1" d
  c_warn "──────── ${COMP_NAME[$k]} ────────"
  c_info "  将删除：程序本体、systemd 服务、/etc 下的参数文件，以及网页界面文件"
  c_info "          （WebUI 静态文件属于软件界面，不是你的数据，卸载时一起删）"
  c_info "  默认保留（外置盘数据，以后装回来设置还在）："
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    [[ -e "$d" ]] && c_info "    $d"
  done < <(component_purge_dirs "$k")
  c_info "  永远保留：$BASE/downloads（共用下载）、$BASE/web（网站根）、"
  c_info "            $BASE/logs、$BASE/db、$BASE/.deploy（状态与密钥）"
  if [[ "$PURGE_DATA" -eq 1 ]]; then
    c_warn "  ⚠ 已指定 --purge-data：上面的组件专属目录也会被删除，且不可恢复"
  fi
}

# ---- 各组件的卸载动作 -------------------------------------------------------
# 每个函数只管「这一个软件」，互不牵连；顺序上先停服务再删文件再卸包。

uninstall_qb(){
  svc_stop_disable qbittorrent-nox
  # 旧版脚本可能留下同名 Docker 容器，会占着 8080 端口，顺手清掉
  remove_legacy_bt_container qbittorrent "$BASE/qb"
  rm_paths /etc/systemd/system/qbittorrent-nox.service
  # WebUI 静态文件属于「界面」，卸载时删掉；配置留在外置盘 $BASE/qb 供以后重装复用
  rm_paths "$BASE/webui/qbittorrent"
  apt_purge qbittorrent-nox
  c_ok "qBittorrent 已卸载；下载文件与设置在 $BASE/qb、$BASE/downloads 中保留"
}

uninstall_transmission(){
  svc_stop_disable transmission-daemon
  remove_legacy_bt_container transmission "$BASE/transmission"
  rm_paths /etc/systemd/system/transmission-daemon.service.d/10-armbian-nas.conf
  rmdir /etc/systemd/system/transmission-daemon.service.d 2>/dev/null || true
  rm_paths "$BASE/webui/transmission"
  apt_purge transmission-daemon transmission-common
  c_ok "Transmission 已卸载；设置在 $BASE/transmission 中保留"
  c_info "中文增强界面包 $(tr_webui_dir) 与界面选择记录也保留；重新 --with-transmission --redo=09 会直接沿用"
}

uninstall_aria2(){
  svc_stop_disable aria2
  rm_paths /etc/systemd/system/aria2.service "$WEB_ROOT/ariang"
  apt_purge aria2
  c_ok "aria2 / AriaNg 已卸载；RPC 密钥与下载文件保留"
}

uninstall_verysync(){
  local unit
  unit="$(systemctl list-unit-files --no-legend 2>/dev/null | awk '/verysync.*\.service/{print $1; exit}' || true)"
  [[ -n "$unit" ]] || unit="verysync.service"
  svc_stop_disable "$unit"
  rm_paths "/etc/systemd/system/$unit.d/10-armbian-nas.conf" \
           "/etc/systemd/system/$unit" /usr/bin/verysync
  rmdir "/etc/systemd/system/$unit.d" 2>/dev/null || true
  c_ok "微力同步已卸载；同步索引在 $BASE/verysync 中保留"
}

uninstall_zerotier(){
  # 先离开已加入的网络，避免 Central 里留着一台永远离线的设备
  if command -v zerotier-cli >/dev/null 2>&1 && [[ -n "$ZT_NETWORK_ID" ]]; then
    zerotier-cli leave "$ZT_NETWORK_ID" >/dev/null 2>&1 || true
  fi
  svc_stop_disable zerotier-one
  apt_purge zerotier-one
  c_ok "ZeroTier 已卸载（如曾加入网络，Central 里的设备记录请自行删除）"
}

uninstall_minidlna(){
  svc_stop_disable minidlna
  # 优先把部署前的原始配置恢复回去，比直接删更友好
  if [[ -f /etc/minidlna.conf.bak.armbian-nas ]]; then
    mv -f /etc/minidlna.conf.bak.armbian-nas /etc/minidlna.conf
    c_info "已恢复卸载前的 /etc/minidlna.conf"
  fi
  apt_purge minidlna
  c_ok "MiniDLNA 已卸载；媒体索引库在 $BASE/minidlna/db 中保留"
}

uninstall_samba(){
  svc_stop_disable smbd nmbd
  if [[ -f /etc/samba/smb.conf.bak.armbian-nas ]]; then
    mv -f /etc/samba/smb.conf.bak.armbian-nas /etc/samba/smb.conf
    c_info "已恢复卸载前的 /etc/samba/smb.conf"
  fi
  apt_purge samba samba-common
  c_ok "Samba 已卸载；共享目录清单 $SHARES_FILE 保留（电影文件不动）"
}

uninstall_fan(){
  svc_stop_disable armbian-fan
  rm_paths /etc/systemd/system/armbian-fan.service \
           /etc/default/armbian-fan \
           /usr/local/sbin/armbian-fan-control
  c_ok "风扇温控服务已卸载（风扇会保持最后一次的状态，请留意散热）"
  c_warn "若风扇当时正转，建议手工断电或按主板引脚关闭，避免一直转"
}

uninstall_hd_idle(){
  svc_stop_disable hd-idle armbian-hdparm.timer armbian-hdparm.service
  rm_paths /etc/systemd/system/armbian-hdparm.service \
           /etc/systemd/system/armbian-hdparm.timer \
           /etc/default/hd-idle
  apt_purge hd-idle
  c_ok "硬盘休眠已卸载（hdparm 保留，它是通用硬盘工具，不影响别的组件）"
}

uninstall_gui(){
  svc_stop_disable xrdp lightdm
  systemctl set-default multi-user.target >/dev/null 2>&1 || true
  apt_purge xfce4 xfce4-goodies lightdm xrdp
  c_ok "图形界面已卸载，已切回命令行启动（multi-user.target）"
  c_warn "重启后生效；远程桌面连接会断开，请用 SSH 管理"
}

uninstall_docker(){
  # 先处理「loop 镜像挂到 /var/lib/docker」的情况：必须按顺序卸载挂载点，
  # 否则直接 purge 会留下一个挂着的 loop 设备，以后很难清理。
  if findmnt -rn --target /var/lib/docker >/dev/null 2>&1; then
    if [[ -x "$DOCKER_EXT_HELPER" ]]; then
      "$DOCKER_EXT_HELPER" detach >/dev/null 2>&1 || true
    else
      umount /var/lib/docker >/dev/null 2>&1 || true
    fi
  fi
  svc_stop_disable "$DOCKER_EXT_UNIT" docker containerd
  rm_paths "$DOCKER_EXT_HELPER" \
           "/etc/systemd/system/$DOCKER_EXT_UNIT" \
           /etc/systemd/system/docker.service.d/10-armbian-nas-external.conf \
           /etc/docker/daemon.json
  rmdir /etc/systemd/system/docker.service.d /etc/docker 2>/dev/null || true
  # 如果当初迁移时留了 eMMC 备份且当前目录空着，恢复回去，避免 /var/lib/docker 丢失
  if [[ -d /var/lib/docker.emmc-bak && ! -e /var/lib/docker ]]; then
    mv /var/lib/docker.emmc-bak /var/lib/docker
    c_info "已恢复 /var/lib/docker.emmc-bak → /var/lib/docker"
  fi
  apt_purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
            docker-compose-plugin docker.io docker-compose
  c_ok "Docker 引擎已卸载；/var/lib/docker 中的镜像与容器默认保留"
  c_warn "若确认不再需要，可手工执行：sudo rm -rf /var/lib/docker（此操作不可恢复）"
}

# ---------------------------------------------------------------------------
# ★ 面板 OLED 已整体移除：只保留一个「安全清理」函数。
#   【绝不】调用 i2cdetect / 装 i2c-tools / modprobe i2c-dev / 改 dtb / 碰 GPIO。
#   仅停掉可能残留的 armbian-oled 服务与 timer、删掉我们生成过的单元文件。
#   目的：防止旧机器上残留的 OLED 服务开机后继续访问 I2C 把网口搞挂。
#   $BASE/oled 下的 config.json 模板与 README 保留，不删用户数据。
# ---------------------------------------------------------------------------
oled_cleanup(){
  local units=(/etc/systemd/system/armbian-oled.service
               /etc/systemd/system/armbian-oled-refresh.service
               /etc/systemd/system/armbian-oled-refresh.timer
               /usr/local/sbin/armbian-oled-refresh)
  local found=0 f
  for f in "${units[@]}"; do [[ -e "$f" ]] && found=1; done
  [[ "$found" -eq 1 ]] || return 0
  # 先停服务再删文件；任何一步失败都不阻断后续
  systemctl stop armbian-oled.service armbian-oled-refresh.timer >/dev/null 2>&1 || true
  systemctl disable armbian-oled.service armbian-oled-refresh.timer >/dev/null 2>&1 || true
  for f in "${units[@]}"; do rm -f "$f" 2>/dev/null || true; done
  systemctl daemon-reload >/dev/null 2>&1 || true
  c_ok "已清理面板 OLED 残留服务（不再扫描 I2C，网口/内网不会再被它打断）"
  c_info "  $BASE/oled 里的配置模板保留，未删除任何用户文件；本功能已从脚本移除"
}

# 分发器：按 key 调对应函数
uninstall_one(){
  local k="$1"
  case "$k" in
    docker)       uninstall_docker ;;
    verysync)     uninstall_verysync ;;
    zerotier)     uninstall_zerotier ;;
    qb)           uninstall_qb ;;
    transmission) uninstall_transmission ;;
    aria2)        uninstall_aria2 ;;
    minidlna)     uninstall_minidlna ;;
    samba)        uninstall_samba ;;
    fan)          uninstall_fan ;;
    hd_idle)      uninstall_hd_idle ;;
    gui)          uninstall_gui ;;
    ttyd)         uninstall_ttyd ;;
    filebrowser)  uninstall_filebrowser ;;
    *) c_warn "未知组件 $k，跳过"; return 1 ;;
  esac
}

# ---- 交互菜单：不带参数运行 --uninstall 时用它 -------------------------------
# 只列出「当前确实装了」的组件，避免小白对着一堆没装的东西不知道选哪个。
uninstall_menu(){
  local -a available=() parts=()
  local k i ans picked p x
  # 非交互（--noninteractive / 无 TTY 的定时任务）不能弹菜单等输入，
  # 否则脚本会一直卡在 read 上。明确提示改用命令行写法后安全退出。
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    c_warn "非交互模式无法弹出卸载菜单；请改用 --uninstall=<组件名> 或 --uninstall-all"
    return 0
  fi
  for k in "${COMP_KEYS[@]}"; do
    component_installed "$k" && available+=("$k")
  done
  if (( ${#available[@]} == 0 )); then
    c_info "目前没有检测到任何已安装的可选组件，无需卸载"
    return 0
  fi
  if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    c_warn "没有可交互终端，无法弹出菜单；请改用 --uninstall=<组件名>"
    return 1
  fi
  {
    printf '\n========== 卸载菜单：当前已安装的软件 ==========\n'
    for i in "${!available[@]}"; do
      k="${available[$i]}"
      printf '  %2d) %-14s %-24s  数据目录 %s\n' \
        "$((i+1))" "$k" "${COMP_NAME[$k]}" "${COMP_DATA[$k]}"
    done
    printf '  输入编号或组件名（逗号分隔，如 1,3 或 qb,transmission）；\n'
    printf '  输入 all = 全部卸载；输入 q 或回车 = 取消：'
  } > /dev/tty
  read -r ans < /dev/tty || ans=""
  printf '\n' > /dev/tty
  case "${ans,,}" in
    ""|q|quit|exit|n|no) c_info "已取消，未做任何改动"; return 0 ;;
    all) UNINSTALL_LIST="$(IFS=,; echo "${available[*]}")" ;;
    *)
      picked=""
      IFS=',' read -ra parts <<< "$ans"
      for p in "${parts[@]}"; do
        p="$(printf '%s' "$p" | tr -d ' ')"
        [[ -z "$p" ]] && continue
        if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= ${#available[@]} )); then
          p="${available[$((p-1))]}"
        fi
        picked+=",$p"
      done
      UNINSTALL_LIST="${picked#,}"
      ;;
  esac
  return 0
}

# ---- 卸载主入口 -------------------------------------------------------------
do_uninstall(){
  c_step "卸载软件（默认保留外置盘数据）"

  # 基本防呆：BASE 不能是 / 或空，否则后面所有 rm 都危险
  [[ -n "$BASE" && "$BASE" != "/" ]] \
    || die "数据根 BASE 不合法（$BASE），为安全起见拒绝卸载"

  if [[ "$UNINSTALL_MENU" -eq 1 ]]; then
    uninstall_menu || return 1
  fi
  if [[ "$UNINSTALL_ALL" -eq 1 ]]; then
    UNINSTALL_LIST="$(IFS=,; echo "${COMP_KEYS[*]}")"
  fi
  if [[ -z "$UNINSTALL_LIST" ]]; then
    c_info "没有指定要卸载的组件。用法示例："
    c_info "  sudo bash $SCRIPT_PATH --uninstall            # 交互菜单"
    c_info "  sudo bash $SCRIPT_PATH --uninstall=qb --yes   # 直接卸 qB"
    c_info "  sudo bash $SCRIPT_PATH --uninstall=qb,transmission"
    return 0
  fi

  # 校验 key，避免拼错后静默什么都不做
  local -a targets=() raw=()
  local k hit x d okc=0 failc=0
  # 把 "qb,transmission" 这样的字符串拆成数组（逗号分隔，去空格）
  IFS=',' read -ra raw <<< "$UNINSTALL_LIST"
  for k in "${raw[@]}"; do
    k="$(printf '%s' "$k" | tr -d ' ')"
    [[ -z "$k" ]] && continue
    hit=0
    for x in "${COMP_KEYS[@]}"; do [[ "$x" == "$k" ]] && hit=1; done
    if [[ "$hit" -eq 0 ]]; then
      c_warn "未知组件名 '$k'（可用：${COMP_KEYS[*]}），已忽略"
    else
      targets+=("$k")
    fi
  done
  (( ${#targets[@]} > 0 )) || { c_warn "没有有效的卸载目标"; return 0; }

  # 先整体预览，再整体确认一次；这一步能看到所有将被影响的软件
  c_warn "即将卸载 ${#targets[@]} 个组件：${targets[*]}"
  for k in "${targets[@]}"; do uninstall_preview "$k"; done
  if [[ "$PURGE_DATA" -eq 1 ]]; then
    c_warn "⚠⚠ --purge-data 已开启：组件专属数据目录会被永久删除！"
    confirm_yes "再次确认：真的要连同外置盘上的组件数据一起删除吗？" \
      || { c_info "已取消，未做任何改动"; return 0; }
  fi
  confirm_yes "确认卸载以上组件？（外置盘下载文件默认保留）" \
    || { c_info "已取消，未做任何改动"; return 0; }

  # 真正执行；单个组件失败不阻断其它组件（okc/failc 已在上面声明）
  for k in "${targets[@]}"; do
    c_step "卸载：${COMP_NAME[$k]} ($k)"
    if uninstall_one "$k"; then
      # 关键：写成 uninstalled，run_step 下次会重新问「是否安装」
      state_set "${COMP_STEP[$k]}" "uninstalled"
      if [[ "$PURGE_DATA" -eq 1 ]]; then
        while IFS= read -r d; do
          [[ -n "$d" ]] && safe_purge_dir "$d"
        done < <(component_purge_dirs "$k")
      fi
      okc=$((okc+1))
    else
      failc=$((failc+1))
      c_warn "${COMP_NAME[$k]} 卸载过程有报错，状态未改；可查看日志后重试"
    fi
  done

  # 卸载会改变「哪些卡片能点」，所以重新生成一次静态导航页（不需要重装任何东西）
  if [[ -d "$WEB_ROOT" ]] && declare -F step_nav >/dev/null 2>&1; then
    c_info "刷新首页导航（把已卸载的软件灰显）..."
    step_nav >/dev/null 2>&1 || c_warn "首页刷新失败，可稍后执行 --redo=18 重建"
  fi

  c_step "卸载完成：成功 $okc 个 / 失败 $failc 个"
  c_info "当前所有软件的安装状态与所在路径如下："
  component_inventory
  component_paths_text
  c_info "下次直接运行 sudo bash $SCRIPT_PATH ，被卸载/跳过的软件会再次询问是否安装；"
  c_info "  想直接装回：sudo bash $SCRIPT_PATH --with-qb --redo=<对应步骤>"
  c_info "  不想再被问：sudo bash $SCRIPT_PATH --no-qb（换成对应组件名）"
  c_info "  查看完整检查表：sudo bash $SCRIPT_PATH --check"
  c_info "  首页已刷新：http://$(lan_ip)/"
  return 0
}

# ------------------------------ 最终检查 -------------------------------------
declare -a R_LV R_NM R_DT
declare -ga SHARE_LIST=()
row(){ R_LV+=("$1"); R_NM+=("$2"); R_DT+=("$3"); }
ck(){ # ck 级别 名称 shell测试 说明
  local lv="$1" nm="$2" cmd="$3" hint="$4"
  # 检查里常用 cmd | grep -q，提前关闭管道会在 pipefail 下误判，故在子 shell 关闭 pipefail
  if ( set +o pipefail; eval "$cmd" ) >/dev/null 2>&1; then row "$lv" "$nm" "OK"; else row "FAIL" "$nm" "$hint"; fi
}
ck_todo(){ row "TODO" "$1" "$2"; }

# ---------------------------------------------------------------------------
# 检查生成的温控脚本是否仍用「全局变量通道」读温度（防致命 bug 回归）。
# ★ 坑：温控脚本的注释里故意写了 `t="$(read_temp)"` 作为反面教材，
#   所以【不能】用 `grep -q '$(read_temp)'` 扫全文件，否则自己把自己判 FAIL。
#   只匹配【代码行】里的命令替换赋值（行首空白后直接是 t=，注释行以 # 开头
#   不会被命中）。
# ---------------------------------------------------------------------------
# 部署器自身：安装过程是否可见（实机反馈「装 PHP 卡住像死机」）。
# 只检查【正面设施存在】，不做反面 grep —— helper 自己也会写这些字符串。
install_progress_ok(){
  local f
  f="$(deployer_src)"; [[ -r "$f" ]] || return 1
  grep -q '^INSTALL_PROGRESS="\${INSTALL_PROGRESS:-1}"' "$f" || return 1
  grep -q '^long_op(){' "$f" || return 1
  grep -q '^download_show(){' "$f" || return 1
  grep -q '^apt_install_quiet(){' "$f" || return 1
  grep -qF 'c_info "  ▸ apt 安装 $# 个包' "$f" || return 1
  # run_step 必须带总步数与耗时
  grep -qF 'local _step_tag="[$id/${#STEPS[@]}]"' "$f" || return 1
  grep -qF '本步耗时' "$f" || return 1
  return 0
}

# 导航页增补项（折叠 / 动态 / 新标签页 / FileBrowser 卡片）
# 防回归：针脚探测函数不得再出现「local 同一行引用 $n」的写法（set -u 下必崩）。
# 只检查 probe_sysfs_write 函数体，避免扫到本 helper 自己的反面示例文字。
probe_sysfs_local_ok(){
  local body
  body="$(sed -n '/^probe_sysfs_write(){/,/^}/p' "$SCRIPT_PATH" 2>/dev/null)"
  [[ -n "$body" ]] || return 1
  grep -qF 'local n="$1" v="$2" d' <<<"$body" || return 1
  grep -qF 'd="/sys/class/gpio/gpio$n"' <<<"$body" || return 1
  ! grep -qE '^[[:space:]]*local .*d="[^"]*gpio\$n"' <<<"$body"
}

nav_extras_ok(){
  local f="$WEB_ROOT/index.html"
  [[ -f "$f" ]] || return 1
  grep -qF 'id="disk-sec"' "$f" || return 1
  grep -qF "setAttribute('target', '_blank')" "$f" || return 1
  [[ -f "$WEB_ROOT/diskstat.php" ]] || return 1
  grep -qF 'data-comp="filebrowser"' "$f" || return 1
  grep -qF 'data-comp="blog"' "$f" || return 1
  grep -qF 'href="/docs.html"' "$f" || return 1
  grep -qF 'id="ip-all"' "$f" || return 1
  grep -qF 'id="ip-client"' "$f" || return 1
  grep -qF '<details id="ip-sec">' "$f" || return 1      # IP 栏可折叠、默认折叠
  grep -qF 'data-comp="docker"' "$f" || return 1         # Docker Web 管理卡片
  grep -qF 'href="/status.html"' "$f" || return 1        # 独立状态页入口
  [[ -s "$WEB_ROOT/status.html" ]] || return 1
  [[ -s "$WEB_ROOT/docs.html" && -s "$WEB_ROOT/hostinfo.php" ]] || return 1
  return 0
}
# ★ 独立状态页完整性：一键安装命令 / SSH / 密码 / 分组 / 主题 / 无残留占位符
status_page_ok(){
  local f="$WEB_ROOT/status.html"
  [[ -s "$f" ]] || return 1
  grep -qE '__[A-Z][A-Z0-9_]*__' "$f" && return 1
  if ! grep -qF -- '--bg:#f4f7fb' "$f" && ! grep -qF -- '--bg:#0f172a' "$f"; then return 1; fi
  grep -qF 'SSH 操作命令' "$f" || return 1
  grep -qF '默认密码 / 初始凭据' "$f" || return 1
  grep -qF '本脚本一键安装 / 重装 / 修复' "$f" || return 1
  # 命令必须真的注入到页面里（不是只写在模板注释中）
  grep -qF -- '--with-filebrowser --redo=22' "$f" || return 1
  grep -qF -- '--with-docker --redo=05' "$f" || return 1
  grep -qF 'id="g1"' "$f" || return 1
  grep -qF 'id="g2"' "$f" || return 1
  grep -qF 'id="g3"' "$f" || return 1
  return 0
}
# ★ Docker 的 Web 管理入口（首页卡片 + 状态页一键安装命令）
docker_web_card_ok(){
  local f="$WEB_ROOT/index.html" g="$WEB_ROOT/status.html"
  [[ -s "$f" && -s "$g" ]] || return 1
  grep -qF 'data-comp="docker"' "$f" || return 1
  grep -qF 'Portainer' "$f" || return 1
  grep -qF -- '--portainer-port' "$SCRIPT_PATH" 2>/dev/null || return 1
  grep -qF -- '--with-docker --redo=05' "$g" || return 1
  return 0
}
# 导航页完整性：白色主题 / IP 默认折叠 / 存储下移 / Docker 卡片 / 状态页入口 / nginx+php / 探针
#   （SSH 命令 / 默认密码 / 路径清单已搬到 /status.html，由 status_page_ok 单独检查）
nav_page_ok(){
  local f="$WEB_ROOT/index.html" site=/etc/nginx/sites-available/armbian-nas
  [[ -f "$f" ]] || return 1
  # 占位符必须全部被替换掉，否则页面会显示 __XXX__。
  # ★ 本轮修复：原来只列了 __COMP_JSON__/__DISK_JSON__/__THEME_VARS__/__PROBER_URL__，
  #   漏掉新增的 __HOST_IPS_JSON__ —— 一旦替换失败，模板里
  #   `var HOST = __HOST_IPS_JSON__;` 会让整页 JS 直接抛语法错误，
  #   连带存储概览、组件状态卡片全部失效。
  #   改成通用正则：任何 __大写__ 残留都会被抓到，以后新增占位符也不会再漏。
  grep -qE '__[A-Z][A-Z0-9_]*__' "$f" && return 1
  # 主题变量已注入即可（light 与 dark 都算通过）。
  # ★ 本轮修复：原来写死 --bg:#f4f7fb，用 --nav-theme=dark 生成的深色首页
  #   会被这条判据误报 FAIL。而且页面是【上次生成的】，本次 --check 传的参数
  #   未必和页面一致，所以不能拿 $NAV_THEME 去比，只看产物里有没有注入主题。
  #   模式以 -- 开头，必须加 `--` 结束选项，否则 grep 报 unrecognized option。
  if ! grep -qF -- '--bg:#f4f7fb' "$f" && \
     ! grep -qF -- '--bg:#0f172a' "$f"; then return 1; fi    # 白色 / 深色主题
  grep -qF '存储空间 · 挂载点' "$f" || return 1                 # 存储概览
  grep -qF 'id="disk-sec"' "$f" || return 1                     # 可折叠
  grep -qF 'window.refreshDisk' "$f" || return 1                # 动态刷新
  grep -qF "setAttribute('target', '_blank')" "$f" || return 1 # 新标签页
  grep -qF 'data-comp="filebrowser"' "$f" || return 1           # FileBrowser 卡片
  grep -qF 'data-comp="docker"' "$f" || return 1                # Docker Web 管理卡片
  grep -qF 'href="/status.html"' "$f" || return 1              # 独立状态页入口
  # ★ IP 栏必须【默认折叠】：出现 <details id="ip-sec" open> 即为回归
  grep -qF '<details id="ip-sec">' "$f" || return 1
  grep -qF '<details id="ip-sec" open>' "$f" && return 1
  # ★ 存储区必须排在「① 常用 Web 界面」之后
  local _w1 _w2
  _w1="$(grep -n '<h2>① 常用 Web 界面' "$f" | head -1 | cut -d: -f1)"
  _w2="$(grep -n 'id="disk-sec"' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$_w1" && -n "$_w2" && "$_w2" -gt "$_w1" ]] || return 1
  grep -qF 'data-comp="nginx"' "$f" || return 1                # nginx 卡片
  grep -qF 'data-comp="php"' "$f" || return 1                  # php 卡片
  grep -qF '/prober.php' "$f" || return 1                      # 完整探针入口
  [[ -f "$WEB_ROOT/prober.php" ]] || return 1                  # 探针文件本身
  return 0
}

fan_temp_channel_ok(){
  local f=/usr/local/sbin/armbian-fan-control
  [[ -r "$f" ]] || return 1
  # ① 代码行里不得再出现 t="$(read_temp)"（子 shell 通道）
  grep -qE '^[[:space:]]*t="\$\(read_temp\)"' "$f" && return 1
  # ② 两个全局变量必须初始化
  grep -qx 'TEMP_VAL=0' "$f"   || return 1
  grep -qx 'TEMP_SRC_N=0' "$f" || return 1
  # ③ 主循环必须【直接调用】read_temp（不是 $(...)）
  grep -qE '^[[:space:]]+read_temp([[:space:]]|$)' "$f" || return 1
  # ④ 主循环必须从全局变量取温度与源数量
  grep -qF 't="$TEMP_VAL"' "$f"     || return 1
  grep -qF 'nsrc="$TEMP_SRC_N"' "$f" || return 1
  return 0
}
ck_skip(){ row "SKIP" "$1" "$2"; }
ck_warn(){ row "WARN" "$1" "$2"; }

# ---------------------------------------------------------------------------
# 部署器自身完整性（防「断线保护永不生效 / 参数静默丢失」回归）。
# 这三个 helper 检查的是【主脚本自身的代码位置与写法】，不依赖是否已部署。
# ★ 关键陷阱：helper 自己的源码里就写着「反面模式」字符串（例如 && -t 1 ]]、
#   ${args[@]}），若全文件 grep 会扫到自己 → 恒判 FAIL（和温控注释那个坑同源）。
#   所以【反面检查一律限定在目标代码段内】，用 sed 取函数体/检测段再 grep。
# ---------------------------------------------------------------------------
deployer_src(){ printf '%s' "$SCRIPT_PATH"; }

# FileBrowser 数据库路径必须只有单一来源，且状态页改密命令用占位符
fb_db_single_source_ok(){
  local f
  f="$(deployer_src)"; [[ -r "$f" ]] || return 1
  grep -q '^FB_DB="$FB_DB_DIR/filebrowser.db"' "$f" || return 1
  grep -q '^fb_db_reconcile(){' "$f" || return 1
  grep -q '^fb_db_path_ok(){' "$f" || return 1
  grep -qF -- '-d __FB_DB__ users update admin' "$f" || return 1
  grep -qF -- '-e "s|__FB_DB__|$FB_DB|g"' "$f" || return 1
  # 不允许再出现拼出来的字面量（注释里的说明除外）
  local n; n="$(grep -c 'filebrowser/filebrowser.db' "$f" || true)"
  (( n <= 2 )) || return 1
  return 0
}

# Transmission 403：写配置时必须同时关两道白名单，且有 HTTP 200 验证
tr_403_fix_ok(){
  local f
  f="$(deployer_src)"; [[ -r "$f" ]] || return 1
  grep -qF "d['rpc-whitelist-enabled'] = False" "$f" || return 1
  grep -qF "d['rpc-host-whitelist-enabled'] = False" "$f" || return 1
  grep -qF "d['rpc-host-whitelist'] =" "$f" || return 1
  grep -q '^tr_http_ok(){' "$f" || return 1
  grep -q '^tr_repair_403(){' "$f" || return 1
  return 0
}

# ★ 两块外置盘都必须真的挂上：旧自检只看主盘，sdb1 永远挂不上也会报全 OK。
#   解析 fstab 标记块：设备没插（blkid -U 找不到）不算失败，插了却没挂才 FAIL。
all_disks_mounted_ok(){
  local line uuid mp dev f
  [[ -r /etc/fstab ]] || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS='|' read -r uuid mp f <<< "$line"
    [[ -n "$uuid" && -n "$mp" ]] || continue
    dev="$(blkid -U "$uuid" 2>/dev/null || true)"
    [[ -n "$dev" && -b "$dev" ]] || continue     # 盘未接入，不算失败
    findmnt -rn --target "$mp" >/dev/null 2>&1 || return 1
  done < <(python3 - /etc/fstab <<'PY' 2>/dev/null
import sys
ls=open(sys.argv[1],encoding='utf-8',errors='replace').read().splitlines()
inside=False
for l in ls:
    if l.startswith('# >>> armbian-nas-deploy >>>'): inside=True; continue
    if l.startswith('# <<< armbian-nas-deploy <<<'): inside=False; continue
    if not inside or not l.strip() or l.lstrip().startswith('#'): continue
    f=l.split()
    if len(f)>=4 and f[0].startswith('UUID='):
        print('|'.join([f[0][5:], f[1], f[2]]))
PY
)
  return 0
}

# ★ 开机补挂自愈：systemd 直接读 fstab 时不会跑主脚本，必须有独立单元。
mount_helper_ok(){
  local f h
  f="$(deployer_src)"; [[ -r "$f" ]] || return 1
  grep -q '^install_mount_helper(){' "$f" || return 1
  grep -q '^mount_try_chain(){' "$f" || return 1
  grep -q '^MOUNT_HELPER_TIMER="armbian-nas-mounts.timer"' "$f" || return 1
  grep -q '^DEV_TIMEOUT="\${DEV_TIMEOUT:-120}"' "$f" || return 1
  h="${MOUNT_HELPER:-/usr/local/sbin/armbian-nas-mount-helper}"
  [[ -x "$h" ]] || return 1
  [[ -f "/etc/systemd/system/${MOUNT_HELPER_TIMER:-armbian-nas-mounts.timer}" ]] || return 1
  systemctl is-enabled "${MOUNT_HELPER_TIMER:-armbian-nas-mounts.timer}" >/dev/null 2>&1 || return 1
  # helper 必须含「ntfs3 被拒 → ntfs-3g」与「不 force / 不 ntfsfix」安全边界
  grep -q 'ntfs3 被拒，已用' "$h" || return 1
  grep -q '脚本不会 force' "$h" || return 1
  return 0
}

# ① tmux 判断必须在 exec > >(tee ...) 【之前】，且判据用 -t 0。
#    tee 一重定向 fd1 就变管道，-t 1 恒假 → 分支永远进不去。
tmux_guard_order_ok(){
  local f tline teeline seg
  f="$(deployer_src)"; [[ -r "$f" ]] || return 1
  # 必须锚定【代码行】：helper 自己也写着这串字符串，不加 ^  会先命中自己
  tline="$(grep -n '^[[:space:]]\+exec env NAS_IN_TMUX=1 tmux new' "$f" | head -1 | cut -d: -f1)"
  teeline="$(grep -n '^[[:space:]]\+exec > >(tee -a' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$tline" && -n "$teeline" ]] || return 1
  (( tline < teeline )) || return 1
  # 只取 tmux 检测段（exec 行往前 80 行，覆盖 NAS_INTERACTIVE 定义行、判据行、
  # 自动补装块与新加的说明注释），绝不扫到 helper 区；40 行在加了 tmux 自动
  # 补装兜底之后已不够，会漏掉交互标志定义行导致假报 FAIL。
  seg="$(sed -n "$((tline-80)),${tline}p" "$f")"
  grep -qF -- '"$NAS_INTERACTIVE" -eq 1 && -z "${TMUX:-}"' <<< "$seg" || return 1
  grep -qF -- '&& -n "${SSH_TTY:-}"' <<< "$seg" && return 1   # 防回归：sudo env_reset 会清掉它
  grep -qF -- '&& -t 1 ]]' <<< "$seg" && return 1
  # 交互标志必须在重定向前算好（同样只在 seg 里查，避免 helper 自匹配恒真）
  grep -qF 'if [[ -t 0 && -r "$NAS_TTY" && -w "$NAS_TTY" ]]; then NAS_INTERACTIVE=1; fi' <<< "$seg" || return 1
  return 0
}

# ①b 防回归：断线保护不得再依赖 SSH_TTY 之类会被 sudo env_reset 清掉的环境变量。
tmux_no_sshtty_ok(){
  local f tline seg
  f="$(deployer_src)"; [[ -r "$f" ]] || return 1
  tline="$(grep -n '^[[:space:]]\+exec env NAS_IN_TMUX=1 tmux new' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$tline" ]] || return 1
  seg="$(sed -n "$((tline-80)),${tline}p" "$f")"
  grep -qF -- '&& -n "${SSH_TTY:-}"' <<< "$seg" && return 1
  grep -qF -- '"$NAS_INTERACTIVE" -eq 1' <<< "$seg" || return 1
  return 0
}

# ①c 防回归：usage() 用不带引号的 cat <<EOF（为了展开 $BASE 等变量），
#   正文里一旦出现反引号或 $(...) 就会被当命令替换【真的执行】。
#   实证：--help 曾冒出 "line 7864: i2cdetect: command not found"。
#   只检查 usage 的 heredoc 段，不扫全文件（helper 自己就写着这些字面串）。
usage_no_cmdsubst_ok(){
  local f u h e seg
  f="$(deployer_src)"; [[ -r "$f" ]] || return 1
  u="$(grep -n '^usage(){' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$u" ]] || return 1
  h="$(awk -v u="$u" 'NR>u && /cat <<EOF/{print NR; exit}' "$f")"
  [[ -n "$h" ]] || return 1
  e="$(awk -v h="$h" 'NR>h && /^EOF$/{print NR; exit}' "$f")"
  [[ -n "$e" ]] || return 1
  seg="$(sed -n "$((h+1)),$((e-1))p" "$f")"
  grep -qF '`' <<< "$seg" && return 1     # 反引号命令替换
  grep -qF '$(' <<< "$seg" && return 1    # $(...) 命令替换
  grep -qF 'i2cdetect' <<< "$seg" || return 1   # 说明文字仍在（别把整段删了）
  return 0
}

# ② 命令行参数必须原样透传：全局 TMUX_ARGS，exec 用它，且无局部 args 残留。
tmux_args_passthrough_ok(){
  local f execline pa_start pa_end
  f="$(deployer_src)"; [[ -r "$f" ]] || return 1
  grep -q '^TMUX_ARGS=("\$@")' "$f" || return 1
  # 正面也只看真实 exec 行：helper 里同样写着 TMUX_ARGS 这个串，全文件 grep 会恒真
  local ln seg
  ln="$(grep -n '^[[:space:]]\+exec env NAS_IN_TMUX=1 tmux new' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$ln" ]] || return 1
  # ★ 本轮 tmux 改成 bash -c 包装（失败保留窗口），参数从 ${@:3} 透传。
  #   检查范围从「只有 exec 一行」扩到「exec 起 30 行」，覆盖包装全部参数。
  seg="$(sed -n "${ln},$((ln+30))p" "$f")"
  grep -qF 'bash -c' <<< "$seg" || return 1
  grep -qF '${@:3}' <<< "$seg" || return 1
  grep -qF '"${TMUX_ARGS[@]}"' <<< "$seg" || return 1
  grep -qF '"$SCRIPT_PATH"' <<< "$seg" || return 1
  grep -qF '${args[@]}' <<< "$seg" && return 1
  # 反面：parse_args 函数体内不得再声明 local -a args=
  pa_start="$(grep -n '^parse_args(){' "$f" | head -1 | cut -d: -f1)"
  pa_end="$(grep -n '^parse_args "\$@"' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$pa_start" && -n "$pa_end" ]] || return 1
  sed -n "${pa_start},${pa_end}p" "$f" | grep -qF 'local -a args=' && return 1
  return 0
}

# ③ 共享目录勾选：判据用 NAS_INTERACTIVE，whiptail 的 fd 显式钉到 NAS_TTY。
shares_interactive_ok(){
  local f ss_start ss_end seg
  f="$(deployer_src)"; [[ -r "$f" ]] || return 1
  ss_start="$(grep -n '^step_shares(){' "$f" | head -1 | cut -d: -f1)"
  ss_end="$(awk -v s="$ss_start" 'NR>s && /^}/{print NR; exit}' "$f")"
  [[ -n "$ss_start" && -n "$ss_end" ]] || return 1
  seg="$(sed -n "${ss_start},${ss_end}p" "$f")"
  grep -qF '[[ "${NAS_INTERACTIVE:-0}" -eq 1 && "$NONINTERACTIVE" -eq 0 ]]' <<< "$seg" || return 1
  grep -qF '3>&1 1>"$NAS_TTY" 2>&3 <"$NAS_TTY"' <<< "$seg" || return 1
  # 只匹配【代码 if 行】里的旧判据，注释里的「原来要求 [[ -t 0 && -t 1 ]]」不算
  grep -qE '^[[:space:]]*if .*\[\[ -t 0 && -t 1 ' <<< "$seg" && return 1
  return 0
}

final_check(){
  c_step "最终安装状态检查"
  R_LV=(); R_NM=(); R_DT=()
  # ★ 用户要求：每次运行脚本的最后都重新生成一次导航页。
  #   步骤 18 记 done 后 run_step 会跳过它，装/卸软件、改文档、换端口都不会
  #   自动刷新首页；这里在最终自检【之前】统一重建，deploy/--check/--repair 全覆盖。
  nav_final_regenerate
  local ip svc secret share_n zt_state fan_cfg gui_state st d
  # 全新机器直接 --check：步骤状态文件为空，可选组件应显示「尚未部署」而非 FAIL
  if [[ ! -s "$STATE_FILE" && ! -s "$MIRROR_FILE" ]]; then
    c_warn "检测到尚未执行过部署（步骤状态为空）：以下可选组件统一标为 SKIP『尚未部署』，这是正常状态，不是安装失败"
  fi
  # 组件检查辅助：若该软件被选择跳过，则明确记为 SKIP，而不是误报 FAIL
  ck_comp(){
    local _cdec; _cdec="$(component_decision "$1")"
    if [[ "$_cdec" == "chosen" ]]; then
      ck OK "$2" "$3" "$4"
    else
      case "$_cdec" in
        uninstalled) ck_skip "$2" "已卸载（下次运行会重新询问；--with-$1 可直接装回）" ;;
        skip)        ck_skip "$2" "已选择跳过（下次运行会再询问；--with-$1 可直接补装）" ;;
        *)           ck_skip "$2" "尚未部署（该可选步骤还没执行，不算安装失败；运行脚本到该步会询问，或 --with-$1 直接安装）" ;;
      esac
    fi
  }

  ip="$(lan_ip)"; [[ -n "$ip" ]] || ip="127.0.0.1"
  # --check 单独运行时没跑步骤 19，这里补读实际生效值，报告不显示 "?"
  [[ -n "$SWAPPINESS_EFF" ]] || SWAPPINESS_EFF="$(sysctl -n vm.swappiness 2>/dev/null || echo '?')"
  secret="$(secret_get ARIA_RPC_SECRET)"
  svc="$(php_service)"
  fan_cfg="$(grep -F 'FAN_CONFIGURED=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo 0)"
  zt_state="$(zerotier-cli listnetworks 2>/dev/null | tail -n +2 | head -1 || true)"
  gui_state="$(state_get 17)"
  read_shares; share_n=${#SHARE_LIST[@]}

  # ===== 1) 所有软件的安装 / 运行状态与配置项（用户要求：最后一定要显示）=====
  c_step "软件组件清单（选择 / 安装 / 运行 / 配置项）"
  component_inventory
  c_step "软件路径清单（程序 / 服务 / 配置 / 界面 / 数据 / 日志 分别在哪）"
  component_paths_text
  local _n_install=0 _n_skip=0 _n_undecided=0 _n_run=0 _kk _cdec
  for _kk in "${COMP_KEYS[@]}"; do
    _cdec="$(component_decision "$_kk")"
    case "$_cdec" in
      chosen)    _n_install=$((_n_install+1)) ;;
      undecided) _n_undecided=$((_n_undecided+1)) ;;
      *)         _n_skip=$((_n_skip+1)) ;;
    esac
    component_running "$_kk" && _n_run=$((_n_run+1)) || true
  done
  c_info "组件汇总：已选/已装 $_n_install 个 / 主动跳过或卸载 $_n_skip 个 / 尚未部署 $_n_undecided 个 / 当前运行 $_n_run 个"
  c_info "尚未部署与主动跳过的组件，下次运行脚本都会再次询问；--with-<组件名> 安装、--no-<组件名> 跳过"

  # ===== 2) 基础环境（不可跳过，始终检查）=====
  ck OK "主盘挂载 $MOUNT_MAIN 可读写" "findmnt -rn --target '$MOUNT_MAIN' >/dev/null && touch '$MOUNT_MAIN/.armbian-nas-check' && rm -f '$MOUNT_MAIN/.armbian-nas-check'" "检查 fstab / Windows 快速启动"
  # ★ 内核 ntfs3 不认 ntfs-3g 的 windows_names / big_writes，带上去会挂载失败
  if grep -qE '^[^#].*[[:space:]]ntfs3[[:space:]]' /etc/fstab 2>/dev/null; then
    ck OK "fstab ntfs3 不含 ntfs-3g 专属选项（windows_names/big_writes）" \
      "! grep -E '^[^#].*[[:space:]]ntfs3[[:space:]]' /etc/fstab | grep -qE 'windows_names|big_writes'" \
      "内核 ntfs3 传这些选项会 Invalid argument；删掉后重跑挂载步骤（fstab 备份 /etc/fstab.bak.armbian-nas）"
  else
    ck_skip "fstab ntfs3 选项检查" "当前未使用 ntfs3（ntfs-3g 或 ext4/exfat 等）"
  fi
  if [[ -b "$SECOND_DEV" ]]; then
    ck OK "第二块盘 $MOUNT_SECOND 挂载" "findmnt -rn --target '$MOUNT_SECOND' >/dev/null" "检查 /dev/sdb1 与 fstab"
  else ck_skip "第二块盘 $MOUNT_SECOND" "未接第二块硬盘，属可选"; fi
  # ★ 逐盘检查 + 开机补挂自愈（sdb1 永久挂不上就是这里漏检的）
  if [[ -f /etc/fstab.bak.armbian-nas ]]; then
    ck OK "两块外置盘均已挂载（逐盘判定，未接入不算失败）" "all_disks_mounted_ok" \
      "sdb1 插着却没挂：sudo systemctl start armbian-nas-mounts ; tail -30 /var/log/armbian-nas-mounts.log"
    ck OK "开机补挂自愈（nofail 跳过 / USB 晚到 / ntfs3 拒绝）" "mount_helper_ok" \
      "sudo /root/armbian-nas-一键部署.sh --repair 重建单元；或 --second-fstype=ntfs-3g --repair 直接强制"
  else
    ck_skip "两块外置盘均已挂载 / 开机补挂自愈" "尚未部署（首次跑一键部署后才会检查）"
  fi
  ck OK "数据目录结构 $BASE" "[[ -d '$WEB_ROOT' && -d '$BASE/logs' && -d '$BASE/db' && -d '$BASE/downloads' ]]" "重跑 --from=01"

  ck OK "nginx 服务" "svc_active nginx && nginx -t" "systemctl status nginx"
  # 全新机器只跑 --check 时 nginx 还没装，不该因 sites-enabled 不存在就判 FAIL
  if command -v nginx >/dev/null 2>&1 && [[ -d /etc/nginx/sites-enabled ]]; then
    ck OK "nginx sites-enabled 无冲突 default_server 残留" \
      "nginx_sites_enabled_clean" \
      "include sites-enabled/* 会连 .bak 一起读；重跑 --redo=04 会自动把 default*/*.bak* 移到 /etc/nginx/sites-disabled.armbian-nas/"
  else
    ck_skip "nginx sites-enabled 冲突检查" "nginx 尚未部署（不算安装失败）"
  fi
  ck OK "nginx 站点首页 HTTP" "http_ok 'http://127.0.0.1/'" "curl -v http://127.0.0.1/"
  # ★ 功能优先：probe.php 能执行就说明 FPM 活着。真机上出现过 unit 名探测
  #   失败但 FPM 正常服务的情况，仅凭 svc_active <名字> 会误报 FAIL。
  ck OK "$PHP_FPM_SVC 服务（FPM 功能可用）" "php_fpm_running_ok" \
    "systemctl status $PHP_FPM_SVC；curl http://127.0.0.1/probe.php；重跑 --redo=03"
  ck OK "PHP 严格锁定 $PHP_VER（不装其它版本 meta 包）" "'$PHP_BIN' -v | grep -qF 'PHP $PHP_VER'" "重跑 --redo=03；检查是否误装 php-fpm"
  ck OK "PHP + SQLite3 探针" "curl -fsS 'http://127.0.0.1/probe.php' | grep -q PHP_SQLITE_OK" "查看 $BASE/logs/nginx/error.log"
  if php_ext_audit; then
    ck OK "PHP $PHP_VER 扩展清单逐项核对" "true" ""
  else
    row FAIL "PHP $PHP_VER 扩展清单逐项核对" \
      "缺失：$(paste -sd, "$PHP_EXT_MISSING" 2>/dev/null || true) → 见 $PHP_EXT_MISSING，补装后 --redo=03"
  fi
  ck OK "PHP 探针扩展核对输出" "curl -fsS 'http://127.0.0.1/probe.php' | grep -q PHP_EXT_ALL_OK" \
    "probe.php 用 FPM 清单（已排除 $PHP_CLI_ONLY_EXTS）；若仍 FAIL 用 --repair 重建 probe.php"
  ck OK "sqlite3 命令与数据库" "command -v sqlite3 && [[ -f '$BASE/db/nas.sqlite3' ]]" "重跑 --redo=04"
  ck OK "HTML 导航页（默认目录 index.html）" "[[ -f '$WEB_ROOT/index.html' ]] && curl -fsS --max-time 5 'http://127.0.0.1/' | grep -q '一键导航'" "重跑 --redo=18"
  ck OK "导航页：白色主题 / IP默认折叠 / 存储下移 / Docker卡片 / 状态页入口 / nginx+php / 完整探针" \
    "nav_page_ok" \
    "sudo bash $SCRIPT_PATH --repair 一键重建；或 --redo=18（X-Prober 要读 /proc，靠 PHP_ADMIN_VALUE 放行）"
  ck OK "独立状态页 /status.html（一键安装 · SSH · 密码 · 路径 · 分组）" \
    "status_page_ok" \
    "sudo bash $SCRIPT_PATH --repair 或 --redo=18 重建；状态页与首页共用同一份组件快照"
  ck OK "Docker Web 管理界面入口（Portainer :$PORT_PORTAINER 卡片 + 一键命令）" \
    "docker_web_card_ok" \
    "装 Docker 时自动部署 Portainer；没装时卡片置灰，状态页有 --with-docker --redo=05 一键命令；--no-portainer 可关闭"
  # 新机只跑 --check（还没部署过）时导航页还不存在，这两项应 SKIP 而不是 FAIL
  if [[ -f "$WEB_ROOT/index.html" ]]; then
    ck OK "在线脚本文档 /docs.html（顶部链接 · 新标签页 · 含 X-Prober 署名）" \
      "docs_page_ok" \
      "把 armbian-nas-使用说明.md 与主脚本放同目录，再 sudo bash $SCRIPT_PATH --redo=18"
    ck OK "本机全部 IP + 来访主机 IP（/hostinfo.php 动态接口）" \
      "hostinfo_ok" \
      "重跑 --redo=18；net_get_interfaces 是 PHP 内置函数，不受 open_basedir 限制"
  else
    ck_skip "在线脚本文档 / 本机 IP 接口" "尚未部署：首次部署跑到步骤 18 才会生成导航页，属正常状态"
  fi
  ck OK "完整 PHP 探针 prober.php 可访问" \
    "[[ -s '$WEB_ROOT/prober.php' ]] && curl -fsS --max-time 8 'http://127.0.0.1/prober.php' | grep -qiE 'PHP|phpinfo|X-Prober|探针|<html'" \
    "末尾收尾会自动自愈；或 sudo bash $SCRIPT_PATH --repair / --redo=18；原 X-Prober 会备份为 prober.xprober.bak"
  ck OK "prober.php 的 open_basedir 放行（X-Prober 要读 /proc）" \
    "grep -q 'PHP_ADMIN_VALUE' /etc/nginx/sites-available/armbian-nas" \
    "sudo bash $SCRIPT_PATH --repair 会幂等补写；nginx -t 后 reload"
  ck OK "安装过程可见：apt 实时输出 / 心跳 / [n/N] 进度 / 耗时" \
    "install_progress_ok" \
    "脚本自身缺失进度设施；--quiet 只关显示，不删设施"
  ck OK "本地博客站点 :$PORT_BLOG HTTP 可访问" \
    "curl -fsS --max-time 8 'http://127.0.0.1:$PORT_BLOG/' | grep -q '本地博客'" \
    "sudo bash $SCRIPT_PATH --repair 或 --redo=23；检查 $BLOG_SITE 与 nginx -t"
  ck OK "博客网站目录 boke 在外置盘" \
    "[[ -d '$BLOG_DIR' && -f '$BLOG_DIR/index.html' && -f '$BLOG_DIR/info.php' ]]" \
    "重跑 --redo=23；目录 $BLOG_DIR"
  # ★ 只检查 listen 行：生成配置的注释里出现过「默认站点」相关说明文字，
  #   用 grep 全文会把注释也算进去 → 误报 FAIL。
  ck OK "博客 nginx 站点配置（:$PORT_BLOG，无默认站点标记冲突）" \
    "[[ -f '$BLOG_SITE' ]] && ! grep -qE '^[[:space:]]*listen[[:space:]].*default_server' '$BLOG_SITE' && grep -q 'listen $PORT_BLOG;' '$BLOG_SITE' && [[ -L /etc/nginx/sites-enabled/armbian-blog ]]" \
    "重跑 --redo=23；绝不能给 listen 加 default_server，否则与 80 的 armbian-nas 抢默认站点"
  ck OK "导航页：折叠存储 / 动态磁盘接口 / 新标签页 / 卡片重排" \
    "nav_extras_ok" \
    "sudo bash $SCRIPT_PATH --repair 一键重建；或 --redo=18"
  ck OK "动态磁盘接口 /diskstat.php 返回 JSON" \
    "curl -fsS --max-time 8 'http://127.0.0.1/diskstat.php' | grep -q '"items"'" \
    "检查 nginx 的 location = /diskstat.php 与 PHP_ADMIN_VALUE 放行；--repair 会幂等补写"
  ck OK "probe.php 分区表格版（含总判定标记）" \
    "curl -fsS --max-time 8 'http://127.0.0.1/probe.php' | grep -q 'PHP_EXT_ALL_OK' && grep -q '④ 扩展核对' '$WEB_ROOT/probe.php' 2>/dev/null" \
    "sudo bash $SCRIPT_PATH --repair 会重建 probe.php"
  ck OK "日志重定向到非系统盘" "[[ -L /var/log/nginx && -f '$LOG_FILE' ]]" \
    "sudo bash $SCRIPT_PATH --repair 会用 ln -sfnT 修好（旧 ln -sfn 会把链接建到目录里）"

  # ===== 3) 步骤 19：eMMC 瘦身与 PHP 安全基线 =====
  ck_comp docker "Docker 日志轮转 daemon.json" \
    "grep -q '\"max-size\"' /etc/docker/daemon.json 2>/dev/null && grep -q '\"max-file\"' /etc/docker/daemon.json 2>/dev/null" \
    "重跑 --redo=19；Docker 未装时本项应为 SKIP"
  ck OK "journald 限额" "grep -q '^SystemMaxUse=' /etc/systemd/journald.conf.d/99-armbian-nas.conf 2>/dev/null" "重跑 --redo=19"
  ck OK "sysctl 持久化与部署日志轮转" "grep -q '^vm.swappiness=' /etc/sysctl.d/99-armbian-nas.conf 2>/dev/null && [[ -f /etc/logrotate.d/armbian-nas-deploy ]]" "重跑 --redo=19"
  # zram 优先于磁盘 swap：直接读 /proc/swaps 的第 5 列 PRIO 做数值比较
  local _zp _dp _zt
  _zp="$(awk 'NR>1 && $1 ~ /^\/dev\/zram/ {print $5}' /proc/swaps 2>/dev/null | sort -rn | head -1)"
  _dp="$(awk 'NR>1 && $1 !~ /^\/dev\/zram/ {print $5}' /proc/swaps 2>/dev/null | sort -n | head -1)"
  _zt="$(awk 'NR>1 && $1 ~ /^\/dev\/zram/ {print $1}' /proc/swaps 2>/dev/null | paste -sd, - || true)"
  if [[ -n "$_zp" && -n "$_dp" ]]; then
    if (( _zp > _dp )); then
      ck OK "zram 优先于磁盘 swap" "true" "zram pri=$_zp > 磁盘 pri=$_dp；设备 $_zt；swapon --show 可查"
    else
      ck_warn "zram 优先级不高于磁盘 swap" "zram pri=$_zp / 磁盘 pri=$_dp；重跑 --redo=19（会改 fstab 的 pri=）"
    fi
  elif [[ -n "$_zp" ]]; then
    ck OK "zram 已启用（无磁盘 swap）" "true" "pri=$_zp；vm.swappiness=${SWAPPINESS_EFF:-?}"
  else
    ck_warn "未检测到启用中的 zram" "磁盘 swap 仍在使用；--redo=19 会尝试启用 zram-tools（或检查 --zram=off）"
  fi
  if [[ -n "$_zp" ]]; then
    ck OK "vm.page-cluster=0（内存 swap 不做预读）" "grep -qx 'vm.page-cluster=0' /etc/sysctl.d/99-armbian-nas.conf 2>/dev/null" "重跑 --redo=19"
  else
    ck_skip "vm.page-cluster=0" "未启用 zram，不需要该参数"
  fi
  # ★ 配 --no-apt-external 时本来就不该有软链，用 ck OK 会误报 FAIL；
  #   全新机器只跑 --check（步骤 19 未执行）同样不该报错。
  if [[ "$APT_CACHE_ON_EXTERNAL" -eq 0 ]]; then
    ck_skip "apt 缓存/lists 已外置" "已用 --no-apt-external 关闭：缓存留 eMMC，属预期，不是失败"
  elif [[ ! -s "$STATE_FILE" && ! -s "$MIRROR_FILE" ]]; then
    ck_skip "apt 缓存/lists 已外置" "尚未部署（步骤 19 未执行，不算安装失败）"
  else
    ck OK "apt 缓存/lists 已外置" "[[ -L /var/cache/apt/archives && -L /var/lib/apt/lists ]]" "重跑 --redo=19（或 --no-apt-external 关闭）"
  fi
  ck OK "PHP open_basedir 安全基线" "grep -q '^open_basedir' '$PHP_ETC/fpm/conf.d/99-armbian-nas-security.ini' 2>/dev/null && curl -fsS 'http://127.0.0.1/probe.php' | grep -q '^OPEN_BASEDIR: '" "重跑 --redo=19；.deploy 对 PHP 不可达"

  local _df _hit=0 _f _arr=()
  _df="$(curl -fsS --max-time 8 'http://127.0.0.1/probe.php' 2>/dev/null | awk -F': ' '/^DISABLE_FUNCTIONS:/{print $2; exit}' || true)"
  if [[ -n "$_df" && "$_df" != "(none)" ]]; then
    IFS=',' read -ra _arr <<< "$_df"
    for _f in "${_arr[@]}"; do
      _f="$(printf '%s' "$_f" | tr -d ' \t')"
      [[ -z "$_f" ]] && continue
      if [[ ",$PHP_KEEP_FUNCS," == *",$_f,"* ]]; then _hit=1; break; fi
    done
  fi
  if [[ "$_hit" -eq 0 ]]; then
    ck OK "disable_functions 未误伤必要函数" "true" "${_df:-未启用禁用}；清单见 $BASE/config/disable_functions-建议.md"
  else
    row FAIL "disable_functions 未误伤必要函数" "命中白名单：$_df → 见 $BASE/config/disable_functions-建议.md"
  fi
  if php_ext_audit; then ck OK "CLI 侧 $PHP_BIN -m 扩展清单" "true" ""
  else row FAIL "CLI 侧 $PHP_BIN -m 扩展清单" "缺失 $(paste -sd, "$PHP_EXT_MISSING" 2>/dev/null || true) → --redo=03"; fi
  if php_ext_audit_fpm; then
    ck OK "FPM 侧（网页真实环境）扩展清单" "true" \
      "与 CLI 一致；CLI 专有扩展已排除：$PHP_CLI_ONLY_EXTS（php8.2-fpm 二进制不编译，非故障）"
  else
    row FAIL "FPM 侧（网页真实环境）扩展清单" \
      "缺失 $(paste -sd, "$PHP_EXT_MISSING_FPM" 2>/dev/null || true) → 检查 $PHP_ETC/{cli,fpm}/conf.d/；CLI 专有例外=$PHP_CLI_ONLY_EXTS；--repair 可重建 probe.php"
  fi

  if [[ -f "$PHP_ETC/fpm/pool.d/nas-admin.conf" ]]; then
    ck OK "admin FPM 池" "true" "仅 127.0.0.1:9001；nginx 入口需手动 include"
  else ck_skip "admin FPM 池" "默认只生成模板（$BASE/config/）；--enable-admin-pool --redo=19 启用"; fi
  local _dfst _avail
  _dfst="$(stat -f -c %T /var/lib/docker 2>/dev/null || echo unknown)"
  if ! component_chosen docker; then
    ck_skip "Docker data-root 位置" "Docker 组件已跳过，无 data-root 需检查"
  elif [[ "$DOCKER_EXTERNAL" -eq 1 && "$_dfst" == ext4 ]]; then
    ck OK "Docker data-root 外置盘" "true" "/var/lib/docker = ext4 loop（$DOCKER_LOOP_IMG）；注意 USB 掉盘风险"
  else
    ck_warn "Docker data-root 位置" "在 eMMC 的 /var/lib/docker（$_dfst）；可选 --docker-external=1 --redo=19 迁移"
  fi
  _avail="$(df -k / 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
  local _use_pct
  _use_pct="$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}' || echo 0)"
  # 只看剩余 KB 会漏掉「7G 盘剩 840MB(=88%)，但仍 >512000KB」这种紧平衡；
  # 百分比 >=85% 就额外 WARN。这是【动态判断】，全新系统部署后实测 30%，不会触发；
  # 部署前的硬门槛已由 preflight_root_space() 在挂载外置盘之前拦下。
  if [[ "${_use_pct:-0}" =~ ^[0-9]+$ ]] && (( _use_pct >= 85 )); then
    ck_warn "eMMC 根分区使用率 ${_use_pct}%" "剩余 ${_avail}KB；建议跳过 Docker/图形界面、--docker-external=1，或 docker image prune -f"
  elif [[ "$_avail" -lt 512000 ]]; then
    ck_warn "eMMC 剩余空间" "仅 ${_avail}KB，偏低；可跳过更多组件或启用 --docker-external=1"
  else ck OK "eMMC 剩余空间" "true" "${_avail}KB 可用（使用率 ${_use_pct:-?}%）"; fi

  # ===== 4) 各软件：按「是否选择安装」逐项检查，跳过项显示 SKIP =====
  ck_comp docker "Docker 引擎" "docker info >/dev/null 2>&1" "systemctl status docker / 重跑 --redo=05"
  ck_comp verysync "微力同步服务 :8886" \
    "port_open 8886 && systemctl list-units --no-legend 2>/dev/null | grep -qi verysync" "journalctl -u verysync"
  ck_comp zerotier "ZeroTier 服务" \
    "command -v zerotier-cli && svc_active zerotier-one && zerotier-cli info >/dev/null 2>&1" "systemctl status zerotier-one"
  if ! component_chosen zerotier; then
    ck_skip "ZeroTier 加入网络" "组件已跳过"
  elif [[ -n "$ZT_NETWORK_ID" && -n "$zt_state" ]]; then
    ck_warn "ZeroTier 网络 $ZT_NETWORK_ID" "$zt_state（若 ACCESS_DENIED 请到 Central 授权）"
  else ck_todo "ZeroTier 加入网络" "执行 zerotier-cli join <ID>，并在 ZeroTier Central 勾选授权；或 --zt-network=<ID> --redo=07"; fi

  ck_comp qb "qBittorrent-nox 原生服务 :8080" "svc_active qbittorrent-nox && port_open 8080" \
    "journalctl -u qbittorrent-nox -n 50；重跑 --redo=08"
  # ★ Debian/Ubuntu 官方 qbittorrent-nox 包【不提供】/usr/share/qbittorrent/webui
  #   静态文件，WebUI 编译在二进制里。旧判据要求外置盘有 index.html，于是
  #   「功能完全正常」却判 FAIL，说明里还写「属正常」，自相矛盾。
  if [[ -f "$BASE/webui/qbittorrent/index.html" ]]; then
    ck_comp qb "qB WebUI（外置盘静态界面）" "true" "静态文件：$BASE/webui/qbittorrent"
  else
    ck_comp qb "qB WebUI（qB 内嵌界面，官方包正常行为）" \
      "curl -fsS --max-time 5 -o /dev/null 'http://127.0.0.1:8080/'" \
      "qB :8080 应有响应；官方包无 /usr/share/qbittorrent/webui 属正常，不必 --redo=08"
  fi
  ck_comp qb "qB 配置落在外置盘" "[[ -f '$BASE/qb/config/qBittorrent/qBittorrent.conf' ]]" "重跑 --redo=08"
  # ★ 关键回归：配置文件里必须真的有 WebUI\Username 与 WebUI\Password_PBKDF2，
  #   否则用 admin/adminadmin 登录会一直 “Invalid Username or Password / Fails”。
  ck_comp qb "qB WebUI 凭据与安全策略已固化（不会 Invalid Username or Password）" "qb_auth_ok" \
    "★ 缺字段或 Host/CSRF 没关都会伪装成密码错误；sudo bash $SCRIPT_PATH --repair 会停服→写两份 conf→重启"
  ck_comp qb "qB WebUI 真实登录通过（admin/adminadmin → body Ok.）" "qb_curl_login_check" \
    "qB 登录成功/失败都返回 HTTP 200，必须比对 body；sudo bash $SCRIPT_PATH --with-qb --redo=08 --qb-password=adminadmin"
  ck_comp transmission "Transmission 原生服务 :9091" "svc_active transmission-daemon && port_open 9091" \
    "journalctl -u transmission-daemon -n 50；重跑 --redo=09"
  ck_comp transmission "Transmission WebUI 静态文件在外置盘" "[[ -f '$BASE/webui/transmission/index.html' ]]" \
    "未找到系统 WebUI 文件时会用系统目录；重跑 --redo=09"
  ck_comp transmission "Transmission 配置落在外置盘" "[[ -f '$BASE/transmission/settings.json' ]]" "重跑 --redo=09"
  # ★ 403 真因：RPC 白名单（rpc-whitelist-enabled / rpc-host-whitelist-enabled）。
  #   不是 nginx 反代没配——Transmission 走 :9091 直连。两道白名单都关了才算过。
  if [[ -f "$BASE/transmission/settings.json" ]]; then
    local _trwl=1
    _trwl="$(python3 - "$BASE/transmission/settings.json" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception:
    print(1); raise SystemExit
bad = d.get('rpc-whitelist-enabled', True) or d.get('rpc-host-whitelist-enabled', True)
print(1 if bad else 0)
PY
)"
    if [[ "$_trwl" == "0" ]]; then
      ck OK "Transmission RPC 白名单已关闭（局域网可打开 :9091，不会 403）" "true" "OK"
    else
      ck FAIL "Transmission RPC 白名单已关闭（局域网可打开 :9091，不会 403）" "false" \
        "settings.json 里 rpc-whitelist-enabled / rpc-host-whitelist-enabled 需为 false；--repair 或 --redo=09 自动修"
    fi
  fi
  ck_comp transmission "Transmission WebUI 实际可打开（HTTP 200，非 403）" "tr_http_ok" \
    "★ 403 不是 nginx 反代问题：--repair 会重修 settings.json；诊断 curl -i http://127.0.0.1:$PORT_TR/"
  if [[ "${TR_PROXY:-0}" -eq 1 ]]; then
    ck OK "Transmission nginx 反代 /transmission/ 配置正确" "tr_proxy_ok" \
      "重跑 sudo bash $SCRIPT_PATH --tr-proxy=1 --repair"
  else
    ck_skip "Transmission nginx 反代 /transmission/" "默认关闭（--tr-proxy=1 开启；WebUI 直连 :$PORT_TR）"
  fi
  # ★ Transmission 中文增强 WebUI：与组件四态解耦，单独按界面选择显示。
  #   下载失败 / 主动选英文 / 尚未部署都标 SKIP，不误报 FAIL。
  case "$(tr_webui_decision)" in
    trguing)
      ck OK "Transmission 中文增强 WebUI（TrguiNG 汉化版 · :9091）" "tr_webui_ok" \
        "sudo bash $SCRIPT_PATH --with-transmission --redo=09；离线包 --tr-webui-zip=/路径/xxx.zip" ;;
    official)
      ck_skip "Transmission 中文增强 WebUI" "已选择保留官方英文界面；--tr-webui=trguing --redo=09 可随时切换" ;;
    failed)
      ck_skip "Transmission 中文增强 WebUI" "GitHub 下载失败，仍用官方英文界面（不是安装失败）；--tr-webui-zip=离线包 --redo=09 补装，或 --github-mirror=加速" ;;
    *)
      ck_skip "Transmission 中文增强 WebUI" "尚未部署：首次部署到步骤 09 会询问，输入 y（或直接回车）安装中文增强界面" ;;
  esac
  ck OK "下载目录落在外置盘" "[[ -d '$BASE/downloads' ]]" "重跑 --from=01"

  ck_comp aria2 "aria2 服务 :6800" "svc_active aria2 && port_open 6800" "journalctl -u aria2"
  ck_comp aria2 "aria2 RPC 可用" \
    "curl -s --max-time 5 -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"method\":\"aria2.getVersion\",\"id\":\"nas\",\"params\":[\"token:$secret\"]}' http://127.0.0.1:6800/jsonrpc | grep -q '\"version\"'" \
    "检查 $BASE/aria2/aria2.conf 的 rpc-secret"
  ck_comp aria2 "AriaNg Web 界面" "[[ -f '$WEB_ROOT/ariang/index.html' ]] && http_ok 'http://127.0.0.1/ariang/'" \
    "下载 AriaNg zip 后 --aria-ng-zip=... --redo=10"
  ck_comp aria2 "nginx /jsonrpc 反代" \
    "curl -s --max-time 5 -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"method\":\"aria2.getVersion\",\"id\":\"nas\",\"params\":[\"token:$secret\"]}' http://127.0.0.1/jsonrpc | grep -q '\"version\"'" \
    "重跑 --redo=04"

  ck OK "共享目录清单（$share_n 个）" "[[ -s '$SHARES_FILE' ]]" "重跑 --reselect --redo=11"
  ck_comp minidlna "MiniDLNA 服务 :8200" "svc_active minidlna && (port_open 8200 || curl -fsS --max-time 5 'http://$ip:8200/' >/dev/null)" "journalctl -u minidlna"
  ck_comp minidlna "MiniDLNA 名称 armbian-nas" "grep -q '^friendly_name=armbian-nas' /etc/minidlna.conf" "重跑 --redo=12"
  ck_comp samba "Samba smbd :445" "svc_active smbd && testparm -s >/dev/null 2>&1 && port_open 445" "testparm -s / journalctl -u smbd"
  ck_comp samba "Samba 共享段落数（应有 $share_n 个 [video-*]）" \
    "[[ \$(grep -c '^\\[video-' /etc/samba/smb.conf 2>/dev/null) -ge $share_n ]]" \
    "smb.conf 段落数不足（旧配置通常只含一块盘）；收尾会自动自愈，或 sudo bash $SCRIPT_PATH --repair（不删数据、不改共享清单）"

  if ! component_chosen fan; then
    ck_skip "风扇温控服务" "组件已跳过（下次运行会再问）"
  elif [[ "$fan_cfg" == "1" ]]; then
    local _fm _fc _fl _gv _sf _ah _led _blue _red _green
    _fm="$(grep -F 'FAN_MODE=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo '<未知>')"
    _fc="$(grep -F 'FAN_GPIO_CHIP=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo '-')"
    _fl="$(grep -F 'FAN_GPIO_LINE=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo '-')"
    _gv="$(grep -F 'FAN_GPIOD_MAJOR=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo '-')"
    _sf="$(grep -F 'FAN_SYSFS_FAN=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo 515)"
    _ah="$(grep -F 'FAN_ACTIVE_HIGH=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo 1)"
    _led="$(grep -F 'FAN_LED_EFF=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo 0)"
    _blue="$(grep -F 'FAN_LED_BLUE=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo 474)"
    _red="$(grep -F 'FAN_LED_RED=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo 476)"
    _green="$(grep -F 'FAN_LED_GREEN=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo 477)"
    # ★ 若还没做「开→转 / 关→停」两轮人工确认，服务按设计【不启用】。
    #   此时把「服务/GPIO/INIT OFF」标 TODO（等待用户操作），而不是刷 3 个 FAIL。
    local _pf="$FAN_PROBE_FILE" _probe_ok=0 _fan_wait=0
    [[ -r "$_pf" ]] || _pf="$MIRROR_DIR/fan-probe.env"
    if [[ -f "$_pf" ]] && grep -qx 'PROBE_CONFIRMED_ON=1' "$_pf" \
        && grep -qx 'PROBE_CONFIRMED_OFF=1' "$_pf"; then _probe_ok=1; fi
    if ! svc_active armbian-fan && [[ "$_probe_ok" -eq 0 && -z "$FAN_CONFIRMED_PIN" ]]; then
      _fan_wait=1
    fi
    if [[ "$_fan_wait" -eq 1 ]]; then
      ck_todo "风扇温控服务（等待针脚实测）" \
        "模式=$_fm / gpio$_sf；按你的要求「测对了才写服务」，先跑：sudo bash $SCRIPT_PATH --fan-probe 完成两轮确认；或 --fan-confirmed=515 --repair"
      ck_todo "风扇 sysfs GPIO gpio$_sf（服务启用后出现）" \
        "服务启用并 export 后才有 /sys/class/gpio/gpio$_sf/value；当前按设计未启用"
      ck_todo "启动强制下发 OFF（服务启用后写入）" \
        "服务启用后 fan.log 才会出现「INIT 风扇已关闭」"
    else
      ck OK "风扇温控服务（≥${FAN_ON_TEMP}℃ 开 / ≤${FAN_OFF_TEMP}℃ 关）" "svc_active armbian-fan" \
        "模式=$_fm；sysfs全局编号=$_sf（高电平开=$_ah）；libgpiod=$_fc line $_fl (v$_gv)；journalctl -u armbian-fan -n 50；tail $BASE/logs/fan.log；--repair 可重建参数文件并重启"
    fi
    # 按模式检查，避免 sysfs 模式下用 pgrep gpioset 误报 FAIL
    case "$_fm" in
      sysfs|sysfs504)
        if [[ "$_fan_wait" -eq 1 ]]; then
          ck_todo "风扇 sysfs GPIO gpio$_sf（等待服务启用）" "两轮确认后 --fan-confirmed=515 --repair 或 --redo=14"
        else
          ck OK "风扇 sysfs GPIO 已就绪（gpio$_sf）" "[[ -e /sys/class/gpio/gpio$_sf/value ]]" \
            "★本机实测 515/J9 Pin35；换 p212 dtb 用 --fan-sysfs-fan=504；--repair 会重建参数文件后重启服务"
        fi
        ck OK "515 实测编号与配置一致" "[[ '$_sf' == '515' ]] || [[ -n '$FAN_CONFIRMED_PIN' ]] || grep -qx 'FAN_SYSFS_FAN=504' /etc/default/armbian-fan 2>/dev/null" \
          "若你换过 dtb 编号，请 --fan-confirmed=<编号> --redo=14 明确指定"
        if [[ "$_led" == "1" ]]; then
          ck OK "面板灯 3 路 GPIO 已就绪" \
            "[[ -e /sys/class/gpio/gpio$_blue/value && -e /sys/class/gpio/gpio$_red/value && -e /sys/class/gpio/gpio$_green/value ]]" \
            "蓝=$_blue 红=$_red 绿=$_green；开风扇=蓝红亮绿灭，关风扇=绿亮"
        else
          ck_skip "面板灯联动" "已关闭（★515 纯风扇引脚：474/476/477 是别的线，绝不误写）"
        fi
        ;;
      libgpiod)
        if [[ "$_fan_wait" -eq 1 ]]; then
          ck_todo "风扇 GPIO 常驻持有进程（等待服务启用）" "两轮确认后再启用"
        else
          ck OK "风扇 GPIO 常驻持有进程" "pgrep -f 'gpioset.*$_fc' >/dev/null 2>&1" \
            "gpioset 退出会释放 line；gpioinfo -c $_fc $_fl；journalctl -u armbian-fan"
        fi
        ;;
      *) ck_skip "风扇 GPIO 细项" "模式 $_fm 无需检查特定 GPIO 接口" ;;
    esac
    if [[ "$_fan_wait" -eq 1 ]]; then
      ck_todo "启动已强制下发 OFF（等待服务启用）" "服务启用后 fan.log 出现「INIT 风扇已关闭」"
    else
      ck OK "启动已强制下发 OFF（初始状态钉死）" \
        "grep -q 'INIT 风扇已关闭' '$BASE/logs/fan.log' 2>/dev/null" \
        "避免上电风扇默认转就一直转；--repair 重建参数文件后重启服务"
    fi
    # ★★ 防回归：温度读取的返回通道。若有人改回 `t="$(read_temp)"`，
    #    子 shell 会让 TEMP_SRC_N 恒为 0 → fail-safe 永久开风扇、温控全废。
    ck OK "温控 read_temp 返回通道（非子 shell，风扇不会永远转）" \
      "fan_temp_channel_ok" \
      "温度值/源数量必须走全局变量 TEMP_VAL / TEMP_SRC_N，直接调用 read_temp；重跑 --redo=14"
    # 用户主动 --fan-failsafe=0 时用 WARN，别用 OK 级判成故障
    if grep -qx 'FAN_FAILSAFE=1' /etc/default/armbian-fan 2>/dev/null; then
      ck OK "温度源失效保护（fail-safe 开风扇）" "true" "温度源全读不到时散热优先；详见 fan.log"
    else
      ck_warn "温度源失效保护已关闭（--fan-failsafe=0）" "读不到温度时不会强制开风扇，请留意散热"
    fi
  else ck_todo "风扇温控" "未配置控制方式：本机实测 515 用 --fan-confirmed=515 --redo=14；p212 dtb 用 --fan-sysfs-fan=504 --fan-led=on --redo=14"; fi
  # 风扇针脚实测记录（两轮人工确认都通过才允许存在）
  # 单独测针脚时结果可能落在本地镜像目录；部署流程里两者都查一遍
  local probe_file="$FAN_PROBE_FILE"
  [[ -r "$probe_file" ]] || probe_file="$MIRROR_DIR/fan-probe.env"
  if [[ -f "$probe_file" ]]; then
    ck OK "风扇针脚实测记录（开→转 / 关→停 两轮确认）" \
      "grep -qx 'PROBE_CONFIRMED_ON=1' '$probe_file' && grep -qx 'PROBE_CONFIRMED_OFF=1' '$probe_file'" \
      "$(grep -F 'PROBE_TYPE=' "$probe_file" 2>/dev/null | cut -d= -f2 || echo '?')；结果文件 $probe_file"
  else
    ck_todo "风扇针脚实测记录" "建议先跑 --fan-probe 完成两轮人工确认（脚本不会替你猜引脚）"
  fi
  ck_comp hd_idle "硬盘休眠" "svc_active hd-idle || svc_active armbian-hdparm.timer" "journalctl -u hd-idle；hdparm -C /dev/sda"
  ck_comp filebrowser "FileBrowser 服务 :$PORT_FB（网页文件管理器）" \
    "svc_active armbian-filebrowser && port_open '$PORT_FB'" \
    "sudo bash $SCRIPT_PATH --repair 或 --redo=22；诊断 journalctl -u armbian-filebrowser -n 30"
  ck_comp filebrowser "FileBrowser 数据库落在外置盘且 unit 路径一致" "fb_db_path_ok" \
    "★ 若 unit 的 -d 指向别的目录，改密会改错库：sudo bash $SCRIPT_PATH --repair 自动迁移；或 --redo=22"
  ck_comp filebrowser "FileBrowser 根目录覆盖两块外置盘" \
    "grep -q -- '-r $FB_ROOT' /etc/systemd/system/armbian-filebrowser.service 2>/dev/null" \
    "默认 -r /mnt（sda1 + sdb1 都能浏览）；可用 --fb-root= 改"
  ck_comp ttyd "ttyd 服务运行（网页终端）" "svc_active armbian-ttyd" \
    "sudo bash $SCRIPT_PATH --repair 会重建单元并重启；诊断 journalctl -u armbian-ttyd -n 50 / systemctl status armbian-ttyd"
  ck_comp ttyd "ttyd 只监听 127.0.0.1:$TTYD_PORT" \
    "grep -q -- '-i 127.0.0.1' /etc/systemd/system/armbian-ttyd.service 2>/dev/null" \
    "重跑 --redo=21；绝不能让 7681 直接对外"
  ck_comp ttyd "nginx /ttyd/ 强制密码（未认证应返回 401）" \
    "curl -s -o /dev/null -w '%{http_code}' --max-time 5 'http://127.0.0.1${TTYD_PATH}/' | grep -q '^401$'" \
    "检查 /etc/nginx/.ttydpasswd 与 snippets/armbian-nas-ttyd.conf；--redo=21"
  # ★ 真机修复：登录密码正确后 404。带认证访问必须拿到 200，
  #   否则说明 nginx 没剥掉子路径前缀 / ttyd 还带着 -b。
  ck_comp ttyd "网页终端带密码访问返回 200（不是 404）" \
    "curl -s -u '$TTYD_AUTH_USER:$(secret_get TTYD_WEB_PASS)' -o /dev/null -w '%{http_code}' --max-time 8 'http://127.0.0.1${TTYD_PATH}/' | grep -q '^200$'" \
    "sudo bash $SCRIPT_PATH --repair 会重建剥前缀反代；或 --redo=21；★:8080 是 qB 不是终端"
  ck_comp ttyd "密码文件不在 Web 目录且权限 640" \
    "[[ -s /etc/nginx/.ttydpasswd && ! -e '$WEB_ROOT/.ttydpasswd' ]]" \
    "密码明文只在 $SECRETS_FILE；页面不显示值"
  ck_comp ttyd "首页导航有 ttyd 卡片" \
    "grep -q 'data-comp=\"ttyd\"' '$WEB_ROOT/index.html' 2>/dev/null" "--redo=18"
  # ★ hdparm -S 0 = 禁用休眠（语义反转），241+ 是 30 分钟档，都属配置错误
  if [[ -f /etc/systemd/system/armbian-hdparm.service ]]; then
    local _hsv
    _hsv="$(grep -oE 'hdparm -S [0-9]+' /etc/systemd/system/armbian-hdparm.service 2>/dev/null | head -1 | grep -oE '[0-9]+$' || echo 0)"
    ck OK "硬盘休眠 hdparm -S 值合法（1..240，非 0）" \
      "[[ '$_hsv' -ge 1 && '$_hsv' -le 240 ]]" \
      "当前值 $_hsv；0=禁用休眠、241+=30分钟档。重跑 --redo=15（--hd-idle=600 生成 120）"
  fi
  # ★ 面板 OLED 已整体移除：真机实测跑到该步会打断网口/整个内网
  ck OK "面板 OLED 残留服务已清理（不再扫描 I2C）" \
    "[[ ! -f /etc/systemd/system/armbian-oled.service && ! -f /etc/systemd/system/armbian-oled-refresh.timer ]]" \
    "sudo bash $SCRIPT_PATH --repair 会安全停服务并删单元；脚本绝不再跑 i2cdetect"
  ck_skip "面板 OLED（SSD1306）" "★ 功能已按真机实测移除：i2cdetect 全总线扫描会命中 PMIC/PHY 打断网口与内网"
  if is_low_mem; then
    ck OK "低内存：php-fpm 池已收敛" \
      "grep -q '^pm = ondemand' '${PHP_ETC}/fpm/pool.d/www.conf' 2>/dev/null" \
      "本机仅 $(mem_total_mib) MiB；重跑 --redo=19；详见 $BASE/config/低内存建议.md"
  else
    ck_skip "低内存自适应" "内存 $(mem_total_mib) MiB > ${LOW_MEM_MIB} MiB，无需收敛"
  fi
  if component_chosen gui; then
    ck OK "图形界面" "systemctl get-default | grep -q graphical" "systemctl set-default graphical.target；重跑 --redo=17"
  else ck_skip "图形界面" "已选择跳过（下次运行会再问；--with-gui 可直接安装）"; fi

  # 残留 running/failed 状态（skip 不算异常，是用户主动选择）
  local bad=""; for d in "${STEPS[@]}"; do
    IFS='|' read -r i x f o <<< "$d"
    st="$(state_get "$i")"
    if [[ "$st" == running || "$st" == failed ]]; then bad+=" $i=$st"; fi
  done
  if [[ -n "$bad" ]]; then ck_warn "部署步骤状态" "仍有未完成：$bad（直接重跑脚本会继续）"
  else ck OK "部署步骤状态" "true" ""; fi
  ck OK "剩余空间" "df -h '$BASE' >/dev/null" "df -h"

  # ===== 部署器自身完整性：断线保护 / 参数透传 / 共享目录勾选 =====
  c_step "部署器自身完整性（防止 SSH 断线与参数丢失回归）"
  # ck OK 成功时表格只显示 "OK"、不显示说明，所以关键配置单独打一行，保证终端/日志可见
  c_info "本次运行：NAS_INTERACTIVE=$NAS_INTERACTIVE（1=可用 /dev/tty）  NO_TMUX=$NO_TMUX  NAS_IN_TMUX=${NAS_IN_TMUX:-0}  TMUX_ARGS=${#TMUX_ARGS[@]} 个参数"
  ck OK "SSH 断线保护：tmux 检测在日志重定向【之前】且判据用 -t 0" \
    "tmux_guard_order_ok" \
    "exec > >(tee) 会把 fd1 变成管道令 -t 1 恒假；重跑不会修脚本自身，请换用新版本脚本"
  ck OK "tmux 重启参数原样透传（--no-docker / --redo= / --zt-network= 不丢）" \
    "tmux_args_passthrough_ok" \
    "必须用全局 TMUX_ARGS；parse_args 里的 local -a args 返回即失效，Bash 5.x 静默展开为空"
  ck OK "共享目录可交互勾选（whiptail 走 /dev/tty，不受 tee 管道影响）" \
    "shares_interactive_ok" \
    "判据用 NAS_INTERACTIVE；whiptail UI 画 stdout、结果写 stderr，需 3>&1 1>tty 2>&3"
  ck OK "本次运行交互状态" "true" \
    "NAS_INTERACTIVE=$NAS_INTERACTIVE（1=可用，0=非交互/无 tty）；NO_TMUX=$NO_TMUX；NAS_IN_TMUX=${NAS_IN_TMUX:-0}"
  ck OK "断线保护不依赖 SSH_TTY（sudo env_reset 下仍进 tmux）" \
    "tmux_no_sshtty_ok" \
    "sudo 默认会清掉 SSH_TTY；判据改用重定向前算好的 NAS_INTERACTIVE。验证：sudo bash -c 'echo SSH_TTY=\$SSH_TTY'"
  ck OK "部署前置空间门槛（≥1.5G，早于挂载外置盘）" \
    "preflight_space_ok" \
    "装软件时 apt 缓存尚未外置；--min-root-space=<MiB> / --force-low-space 可调整"
  ck OK "帮助文本无命令替换（--help 不执行反引号 / i2cdetect）" \
    "usage_no_cmdsubst_ok" \
    "usage 用不带引号的 cat <<EOF；正文里出现反引号会被真的执行。验证：bash 脚本 --help 2>&1 | grep 'command not found' 应为空"
  ck OK "风扇针脚探测无 set -u 同行引用崩溃（SC2318）" \
    "probe_sysfs_local_ok" \
    "local n=\"\$1\" ... d=\"/sys/class/gpio/gpio\$n\" 同行引用会在 set -Eeuo pipefail 下直接退出；请换新脚本"
  ck OK "FileBrowser 数据库路径单一来源（不会再改错库）" "fb_db_single_source_ok" \
    "重跑 sudo bash $SCRIPT_PATH --repair 自动迁移旧库"
  ck OK "Transmission 403 修复（两道白名单 + HTTP 200 验证）" "tr_403_fix_ok" \
    "重跑 sudo bash $SCRIPT_PATH --repair"
  ck OK "导航页每次运行末尾都会重建" \
    "nav_final_regen_ok" \
    "final_check 开头必须调用 nav_final_regenerate()，否则步骤 18 done 后首页永久不刷新"
  ck OK "定向模式：指定软件不再弹其它组件的安装提示" "targeted_mode_ok" \
    "--with-<组件> / --redo=<步骤> 只跑目标步骤；不带参数的一键部署才逐个询问"
  ck OK "统一凭据（ttyd/aria2=admin；FileBrowser≥12位）" "simple_creds_ok" \
    "检查 $SECRETS_FILE 三个密钥；FileBrowser 上游强制 ≥12 位，改密方法见状态页"
  ck OK "aria2 RPC 已移到状态页（首页不再显示）" "rpc_moved_ok" "重跑 --redo=18 重建两页"
  ck OK "收尾自愈：prober.php 与 Samba 段落" "final_heal_ok" "收尾自愈仅在非 --check / --status 模式触发；--repair 也会执行"
  ck OK "全脚本无 local 同行自引用（SC2318）" "local_selfref_ok" \
    "component_install_cmd 曾靠外层同名 k「巧合正确」，外层改名即崩；用 bash -n / shellcheck 复查"
  ck OK "tmux 断线保护有自动补装兜底（不再静默跳过）" "tmux_autoinstall_ok" \
    "步骤 02 依赖清单含 tmux，且守卫处缺 tmux 会 apt 补装；sudo apt-get install -y tmux 可手动补"
  ck OK "ZeroTier 安装：apt 优先 + 官方脚本兜底 + 失败可诊断" "zt_install_fallback_ok" \
    "install.zerotier.com 对新 codename（如 resolute）可能报 unsupported distribution；apt 优先避免"
  ck OK "定向模式最小依赖兜底（跳过步骤 02 也不缺命令）" "targeted_prereqs_ok" \
    "mkdir -p \$STATE_DIR + 补 curl/python3/gnupg；不装软件、不询问、不改状态"
  ck OK "tmux 失败保留窗口且输出可查（不再只剩 [exited]）" "tmux_visible_ok" \
    "失败时 exec bash -l 保留窗口；进会话前打印 tail -80 日志路径与 --no-tmux 排查法"
  ck OK "FileBrowser 改密先停服再启服（避开 bbolt Error: timeout）" "fb_password_order_ok" \
    "服务运行时直接 users update 会超时；状态页给的三步命令：stop → update → start"
  ck OK "FileBrowser 密码满足上游 ≥12 位策略" "fb_password_policy_ok" \
    "admin/adminadmin 会被拒；默认 adminadmin123，长度预检给出中文提示，显示与 secrets.env 一致"

  # 输出表格
  local i ok=0 warn=0 fail=0 todo=0 skip=0
  printf '\n%-6s %-46s %s\n' "状态" "检查项" "说明"
  printf '%s\n' "--------------------------------------------------------------------------------------------------------"
  for i in "${!R_NM[@]}"; do
    printf '%-6s %-46s %s\n' "${R_LV[$i]}" "${R_NM[$i]}" "${R_DT[$i]}"
    case "${R_LV[$i]}" in OK) ok=$((ok+1));; WARN) warn=$((warn+1));; FAIL) fail=$((fail+1));; TODO) todo=$((todo+1));; SKIP) skip=$((skip+1));; esac
  done
  printf '%s\n' "--------------------------------------------------------------------------------------------------------"
  printf '汇总：OK=%d  WARN=%d  FAIL=%d  TODO=%d  SKIP=%d\n' "$ok" "$warn" "$fail" "$todo" "$skip"

  {
    echo "armbian-nas 部署最终报告  $(date '+%F %T')  v$VERSION"
    echo "主机 IP: $ip   数据根: $BASE   Web 默认目录: $WEB_ROOT   PHP: $PHP_VER ($PHP_FPM_SVC)"
    echo "状态文件: $STATE_FILE   扩展清单: $PHP_EXT_FILE   CLI 缺失: $PHP_EXT_MISSING   FPM 缺失: $PHP_EXT_MISSING_FPM"
    echo "eMMC: $(df -h / 2>/dev/null | awk 'NR==2{print $3" 已用 / "$2" 总量，可用 "$4}')"
    echo "Swap 分层(NAME/TYPE/PRIO/USED): $(swap_table 2>/dev/null | tr '\n' ';')"
    echo "vm.swappiness=${SWAPPINESS_EFF:-?}  vm.page-cluster=$(sysctl -n vm.page-cluster 2>/dev/null || echo -)  zram管理器=$(zram_owner 2>/dev/null || echo -)"
    echo "风扇: mode=$(grep -F 'FAN_MODE=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo -)  ★sysfs全局编号=$(grep -F 'FAN_SYSFS_FAN=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo -)  引脚=$(grep -F 'FAN_PIN_DESC=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2- | tr -d '"' || echo -)  高电平开=$(grep -F 'FAN_ACTIVE_HIGH=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo -)  LED联动=$(grep -F 'FAN_LED_EFF=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo -)  failsafe=$(grep -F 'FAN_FAILSAFE=' /etc/default/armbian-fan 2>/dev/null | cut -d= -f2 || echo -)"
    echo "内存: $(mem_total_mib) MiB  zram目标=$(zram_target_kib) KiB  zram管理器=$(zram_owner 2>/dev/null || echo -)"
    echo "面板 OLED: ★已移除（不再安装/不再扫描 I2C；残留服务由 --repair 安全清理）"
    echo "Docker data-root: /var/lib/docker ($(stat -f -c %T /var/lib/docker 2>/dev/null || echo unknown))"
    echo "步骤19 产物: /etc/docker/daemon.json · $BASE/config/ · $PHP_ETC/fpm/conf.d/99-armbian-nas-security.ini"
    printf '汇总：OK=%d WARN=%d FAIL=%d TODO=%d SKIP=%d\n' "$ok" "$warn" "$fail" "$todo" "$skip"
    printf '组件汇总：选择安装 %d 个 / 跳过 %d 个 / 当前运行 %d 个\n\n' "$_n_install" "$_n_skip" "$_n_run"
    echo "===== 软件组件清单（安装 / 运行 / 配置项）====="
    printf '%s\n' "$INVENTORY_TEXT"
    echo "===== 软件路径清单（每个文件都在哪，小白按这个找）====="
    printf '%s\n' "$INVENTORY_PATHS_TEXT"
    echo "===== 检查项明细 ====="
    for i in "${!R_NM[@]}"; do printf '%-6s %-46s %s\n' "${R_LV[$i]}" "${R_NM[$i]}" "${R_DT[$i]}"; done
    cat <<EOF

===== 访问地址 =====
一键导航页(默认) : http://$ip/   → $WEB_ROOT/index.html（自动按当前主机拼端口）
在线脚本文档     : http://$ip/docs.html  （顶部「📖 在线查看脚本文档」新标签页直达；原始 .md 可下载）
本机/来访 IP     : http://$ip/hostinfo.php（导航页顶部实时显示全部网卡 IP 与浏览器来源 IP）
PHP 8.2 扩展核对 : http://$ip/probe.php   备用状态页: http://$ip/status.php
PHP 完整环境探针 : http://$ip/prober.php  （X-Prober / phpinfo / 扩展 / CPU / 内存 / 磁盘）
ttyd 网页终端    : http://$ip${TTYD_PATH}/   登录名 $TTYD_AUTH_USER，密码见 $SECRETS_FILE（TTYD_WEB_PASS，页面不显示）
AriaNg           : http://$ip/ariang/   RPC: http://$ip/jsonrpc
aria2 RPC 密钥   : $SECRETS_FILE （ARIA_RPC_SECRET）
qBittorrent      : http://$ip:8080   （原生 apt 安装；脚本已写入 admin/adminadmin；自定义：--qb-password= 重跑 --redo=08）
本地博客         : http://$ip:$PORT_BLOG/   （独立 81 端口；网站目录 $BLOG_DIR；配置 $BLOG_SITE）
FileBrowser      : http://$ip:$PORT_FB   （admin / $(secret_get FILEBROWSER_PASS 2>/dev/null || echo 见 secrets.env)；根目录 $FB_ROOT 含两块外置盘）
Transmission     : http://$ip:9091
MiniDLNA 状态页  : http://$ip:8200   （播放器搜索 armbian-nas）
微力同步         : http://$ip:8886
Samba            : \\\\$ip\\   共享名：$(grep '^\[video-' /etc/samba/smb.conf 2>/dev/null | tr -d '[]' | paste -sd, - || true)
ZeroTier         : zerotier-cli listnetworks（私有网络需 Central 授权）
风扇日志         : $BASE/logs/fan.log
部署日志         : $LOG_FILE
断点状态         : bash $SCRIPT_PATH --status
★ 定向只重跑某步 : bash $SCRIPT_PATH --redo=ID   （不再询问其它组件，末尾重建两页）
EOF
  } > "$REPORT_FILE"
  sync_log
  c_info "完整报告：$REPORT_FILE"

  cat <<EOF

===== 常用入口 =====
  状态/续跑   : sudo bash $SCRIPT_PATH --status      （直接重跑脚本 = 自动接着跑）
  仅自检      : sudo bash $SCRIPT_PATH --check
  一键修复    : sudo bash $SCRIPT_PATH --repair   （自检有 FAIL 时先跑这个，幂等、不增删软件）
  指定共享目录: sudo bash $SCRIPT_PATH --shares='/mnt/sda1/电影,/mnt/sdb1/影视' --redo=11
  加入 ZT     : sudo bash $SCRIPT_PATH --zt-network=<16位ID> --redo=07
  中文 TR 界面: sudo bash $SCRIPT_PATH --tr-webui=trguing --redo=09   （装 TrguiNG 汉化版）
  英文 TR 界面: sudo bash $SCRIPT_PATH --tr-webui=official --redo=09  （切回官方 WebUI）
  重建导航页  : sudo bash $SCRIPT_PATH --redo=18  （同时重建 /status.html 状态页）
  状态页      : http://$ip/status.html  （每卡片末尾有该软件的一键安装/重装命令）
  本地博客    : sudo bash $SCRIPT_PATH --redo=23   （http://<本机IP>:$PORT_BLOG/，目录 $BLOG_DIR）
  重查 PHP    : sudo bash $SCRIPT_PATH --redo=03
  瘦身/安全   : sudo bash $SCRIPT_PATH --redo=19
  Docker 外置 : sudo bash $SCRIPT_PATH --docker-external=1 --redo=19  （可选，见风险说明）
  admin 池    : sudo bash $SCRIPT_PATH --enable-admin-pool --redo=19
  补装某软件  : sudo bash $SCRIPT_PATH --with-qb          （★ 定向模式：只装 qB，不再询问其它组件）
  指定单步    : sudo bash $SCRIPT_PATH --redo=18          （★ 只重建导航页+状态页，末尾自动自检）
  恢复随机密钥: sudo bash $SCRIPT_PATH --creds=random --redo=21（再分别对 10 / 22 重跑）
  永久跳过    : sudo bash $SCRIPT_PATH --no-docker --no-transmission
  全部安装    : sudo bash $SCRIPT_PATH --all-yes
  全部跳过    : sudo bash $SCRIPT_PATH --all-no
  SSH 重连    : tmux attach -t armbian-nas
EOF

  if (( fail > 0 )); then
    c_err "有 $fail 项失败。★一键修复：sudo bash $SCRIPT_PATH --repair"
    c_err "  （幂等重建配置项：不重装软件、不重新询问组件、不删数据；修完自动再跑一次 --check）"
    return 1
  fi
  c_ok "全部必需项通过；TODO/WARN 为需要你按主板与网络环境补齐的配置项"
  return 0
}

# ---------------------------------------------------------------------------
# --fan-status：一条命令诊断「65℃ 风扇不转」
#   显示：服务是否 active / 参数文件 / 每个温度源原始读数与换算值 /
#         当前 GPIO value / 最近 20 行 fan.log / 修复建议。
#   不改动系统，可反复跑。
# ---------------------------------------------------------------------------
fan_status(){
  need_root
  c_step "风扇温控诊断（$(date '+%F %T')）"
  local cfg=/etc/default/armbian-fan logf="$BASE/logs/fan.log" n v raw
  printf '\n── ① 服务状态 ──\n'
  systemctl status armbian-fan --no-pager -l 2>&1 | head -12 || true
  printf '\n── ② 参数文件 %s ──\n' "$cfg"
  if [[ -r "$cfg" ]]; then
    grep -E '^FAN_(CONFIGURED|MODE|SYSFS_FAN|ACTIVE_HIGH|ON_TEMP|OFF_TEMP|POLL|FAILSAFE|TEMP_FILE|ON_CMD|OFF_CMD)=' "$cfg" || true
    if grep -qx 'FAN_CONFIGURED=0' "$cfg"; then
      c_err "  ★★ FAN_CONFIGURED=0 —— 这就是风扇不转的原因：服务按设计不动作"
      c_err "     已实测过引脚就跑：sudo bash $SCRIPT_PATH --fan-confirmed=515 --repair"
      c_err "     没实测过就跑：sudo bash $SCRIPT_PATH --fan-probe（两轮都输 y）"
    fi
  else
    c_warn "  参数文件不存在，先 --redo=14"
  fi
  printf '\n── ③ 温度源扫描（原始值 → 摄氏度）──\n'
  local found=0 max=0
  for f in /etc/armbianmonitor/datasources/soctemp \
           /sys/class/thermal/thermal_zone*/temp \
           /sys/devices/virtual/thermal/thermal_zone*/temp \
           /sys/class/hwmon/hwmon*/temp*_input; do
    [[ -r "$f" ]] || continue
    found=$((found+1))
    raw="$(cat "$f" 2>/dev/null | tr -d '\r\n' || echo '')"
    v="$(awk '{print int($1)}' "$f" 2>/dev/null || echo 0)"
    (( v > 1000 )) && v=$((v/1000))
    (( v > max )) && max=$v
    printf '  %-62s raw=%-10s → %s℃\n' "$f" "$raw" "$v"
  done
  if (( found == 0 )); then
    c_warn "  ★ 一个温度源都没找到！用 --fan-temp-file=<路径> --redo=14 明确指定"
    c_warn "    fail-safe 会强制开风扇；若风扇仍不转，多半是服务根本没启用（看①）"
  else
    c_ok "  共 $found 个温度源，当前最高 ${max}℃（阈值 $(grep -F 'FAN_ON_TEMP=' "$cfg" 2>/dev/null | cut -d= -f2 || echo 50)℃ 开 / $(grep -F 'FAN_OFF_TEMP=' "$cfg" 2>/dev/null | cut -d= -f2 || echo 48)℃ 关）"
  fi
  printf '\n── ④ 风扇 GPIO 当前电平 ──\n'
  n="$(grep -F 'FAN_SYSFS_FAN=' "$cfg" 2>/dev/null | cut -d= -f2 || echo 515)"
  if [[ -r "/sys/class/gpio/gpio$n/value" ]]; then
    printf '  /sys/class/gpio/gpio%s/value = %s （1=开 / 0=关，按 FAN_ACTIVE_HIGH 解释）\n' \
      "$n" "$(cat "/sys/class/gpio/gpio$n/value" 2>/dev/null)"
  else
    c_warn "  gpio$n 未 export —— 说明温控服务【从没成功下发过命令】，或参数没生效"
    c_warn "   对比：独立测试脚本能转，说明引脚没问题；这里是服务侧没跑起来"
  fi
  printf '\n── ⑤ 最近 20 行 fan.log ──\n'
  tail -20 "$logf" 2>/dev/null || c_warn "  日志还没生成：$logf"
  printf '\n── ⑥ 建议 ──\n'
  c_info "  手动开/关验证：sudo bash $SCRIPT_PATH --fan-test-on / --fan-test-off"
  c_info "  重建并启用：sudo bash $SCRIPT_PATH --fan-confirmed=515 --repair"
  c_info "  重新测针脚：sudo bash $SCRIPT_PATH --fan-probe"
  return 0
}

# ---------------------------------------------------------------------------
# --repair：一键修复「真机自检里可自动修的存量问题」
#
# 设计边界（很重要，避免好心办坏事）：
#   * 【不】重新跑 run_step，所以不会重新询问「装不装」、不会把主动跳过的
#     Docker / 图形界面等又装回来；
#   * 【不】调用任何 component_gate / 卸载逻辑，组件选择状态原样保留；
#   * 【不】删外置盘上的下载、配置、数据库、电影；所有重建都是覆盖配置文本；
#   * 风扇在没有「开→转 / 关→停」两轮实测记录时【保持停用】，绝不自作主张
#     对没确认过的 GPIO 拉电平（这是用户反复强调的硬要求）。
#
# 对应真机自检里那 13 个 FAIL，本函数能自动修的：
#   日志重定向(ln -sfn 建到目录里) / probe.php 的 pcntl 例外 /
#   导航页白色主题 + 存储 + 命令 + 密码 + nginx+php 卡片 / X-Prober + 放行 /
#   Samba [video-*] 段落 / ttyd 单元启动 / 风扇参数文件(source 崩) 与服务。
# 另两项（php8.2-fpm 服务名误报、qB 内嵌 WebUI）已在自检判据里修好，
# 不需要动系统 —— 这就是「先修判据，再修存量」的顺序。
# ---------------------------------------------------------------------------
do_repair(){
  c_step "一键修复：按自检失败项幂等重建配置，随后自动复查"
  c_info "边界：不重装软件、不重新询问组件选择、不删数据、不格式化；跳过的组件保持跳过"
  local n=0

  # ---- ⓪ 面板 OLED 安全清理（★ 已整体移除）----
  # 旧机器步骤 20 可能已是 done 状态，run_step 会跳过；但残留的
  # armbian-oled 服务开机后仍可能访问 I2C 把网口搞挂。这里无条件清一次，
  # 只停服务/删单元，绝不调 i2cdetect、不装 i2c-tools、不改 dtb、不碰 GPIO。
  oled_cleanup

  # ---- ① nginx 日志软链（ln -sfnT 真 bug） ----
  c_info "① 修 nginx 日志软链（旧 ln -sfn 会把链接建到目录里面）"
  if relocate_nginx_log; then n=$((n+1)); else c_warn "  日志软链未修好，看上一行输出"; fi

  # ---- ② probe.php：FPM 侧剔除 CLI 专有扩展 ----
  c_info "② 重建 probe.php（期望清单排除 CLI 专有扩展：$PHP_CLI_ONLY_EXTS）"
  if [[ -d "$WEB_ROOT" ]]; then
    if write_probe_php; then
      c_ok "  probe.php 已重建；FPM 侧不再把 pcntl 误判为缺失"
      n=$((n+1))
    else c_warn "  probe.php 重建失败"; fi
  else
    c_warn "  $WEB_ROOT 不存在，先跑一次部署或 --redo=04"
  fi

  # ---- ③ 白色导航页 + X-Prober + nginx 放行 ----
  c_info "③ 重建白色导航页（IP折叠 / 存储下移 / Docker卡片）+ 独立状态页 /status.html（一键安装命令）"
  # 只要求网站根目录存在：step_nav 内部会生成页面/探针，nginx 放行片段
  # 若站点配置不在标准路径会自己 warn 并跳过，不影响导航页修好。
  if [[ -d "$WEB_ROOT" ]]; then
    if step_nav; then n=$((n+1)); else c_warn "  导航页重建失败，可单独 --redo=18"; fi
  else
    c_warn "  $WEB_ROOT 不存在，请先跑一次部署或 --redo=04"
  fi

  # ---- ④ Samba 共享段落 ----
  # ★ 真机反馈：曾经「选择跳过」或「已卸载」的组件，--repair 不该把它们
  #   的配置又写回去（哪怕系统里恰好还残着 smbd 二进制）。用四态判定严格保护。
  local _samba_dec; _samba_dec="$(component_decision samba)"
  if [[ "$_samba_dec" == "skip" || "$_samba_dec" == "uninstalled" || "$_samba_dec" == "undecided" ]]; then
    c_info "④ Samba 状态=$_samba_dec → 按你的选择跳过，不重写 smb.conf"
  elif ! command -v smbd >/dev/null 2>&1 || [[ ! -s "$SHARES_FILE" ]]; then
    c_info "④ Samba 未安装或共享清单为空 → 跳过"
  else
    c_info "④ 重建 Samba 共享段落（按 $SHARES_FILE，不删任何数据）"
    if step_samba; then
      systemctl restart smbd >/dev/null 2>&1 || true
      systemctl restart nmbd >/dev/null 2>&1 || true
      c_ok "  smb.conf 已重建并重载：$(grep -c '^\[video-' /etc/samba/smb.conf 2>/dev/null || echo 0) 个共享"
      n=$((n+1))
    else c_warn "  Samba 重建失败，可单独 --redo=13"; fi
  fi

  # ---- ⑤ ttyd 单元与启动 ----
  if component_chosen ttyd && command -v ttyd >/dev/null 2>&1; then
    c_info "⑤ 重建 ttyd 单元并重启"
    if step_ttyd; then
      sleep 1
      if svc_active armbian-ttyd; then
        c_ok "  ttyd 已 active；入口 http://<本机IP>${TTYD_PATH}/"
        n=$((n+1))
      else
        c_warn "  ttyd 仍未 active，诊断如下（这些是修复关键，请照抄查看）："
        systemctl status armbian-ttyd --no-pager -l 2>&1 | head -12 || true
        journalctl -u armbian-ttyd -n 15 --no-pager 2>&1 | tail -15 || true
        c_warn "  常见原因：ttyd 二进制路径变了 / -i 参数版本不支持 / 日志目录不可写"
      fi
    else c_warn "  ttyd 重建失败，可单独 --redo=21"; fi
  else
    c_info "⑤ ttyd 未安装 / 已跳过 → 跳过"
  fi

  # ---- ⑥ 风扇参数文件 / 温控脚本 / 服务 ----
  if component_chosen fan; then
    # ★ 真机修复：用户是跑【独立的 风扇针脚测试.sh】做的实测，
    #   结果文件可能落在脚本同目录 / /root / $STATE_DIR / $MIRROR_DIR，
    #   旧版只查两处 → 明明测过却仍判「未确认」→ 直接 disable 服务
    #   → 65℃ 风扇也不转。现在把这些位置都扫一遍。
    local pf="" probe_ok=0 cand
    for cand in "$FAN_PROBE_FILE" "$MIRROR_DIR/fan-probe.env" \
                "$(dirname "$SCRIPT_PATH")/fan-probe.env" \
                /root/fan-probe.env "$STATE_DIR/fan-probe.env"; do
      if [[ -f "$cand" ]] && grep -qx 'PROBE_CONFIRMED_ON=1' "$cand" \
          && grep -qx 'PROBE_CONFIRMED_OFF=1' "$cand"; then
        pf="$cand"; probe_ok=1; break
      fi
    done
    [[ "$probe_ok" -eq 1 ]] && c_ok "  找到针脚两轮实测记录：$pf（据此启用温控服务）"
    c_info "⑥ 重建风扇参数文件 / 温控脚本 / systemd 单元（修旧版 FAN_PIN_DESC 裸值导致 source 崩溃）"
    if step_fan; then
      if [[ "$probe_ok" -eq 1 || -n "$FAN_CONFIRMED_PIN" ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart armbian-fan >/dev/null 2>&1 || true
        sleep 1
        if svc_active armbian-fan; then
          c_ok "  风扇温控已 active（≥${FAN_ON_TEMP}℃ 开 / ≤${FAN_OFF_TEMP}℃ 关）"
          n=$((n+1))
        else
          c_warn "  风扇仍未 active，诊断："
          systemctl status armbian-fan --no-pager -l 2>&1 | head -12 || true
          journalctl -u armbian-fan -n 15 --no-pager 2>&1 | tail -15 || true
        fi
      else
        # 用户硬要求「测对了才写温控服务」：没有两轮确认就保持停用。
        # ★ 但若用户已经手动 enable 并跑起来了，别把它停掉（只提示）。
        if svc_active armbian-fan; then
          c_warn "  服务当前是 active（你手动启用过）→ 保持运行，不擅自停掉"
          c_warn "  建议补一次实测留档：sudo bash $SCRIPT_PATH --fan-probe"
        else
          systemctl disable --now armbian-fan >/dev/null 2>&1 || true
          c_warn "  参数/脚本/单元已重建，但【按你的要求保持停用】：还没做两轮人工确认"
        fi
        c_warn "  先跑：sudo bash $SCRIPT_PATH --fan-probe   （确认「开→转」「关→停」）"
        c_warn "  已实测过就加 --fan-confirmed=515 --repair 直接启用"
        n=$((n+1))
      fi
    else c_warn "  风扇重建失败，可单独 --redo=14"; fi
  else
    c_info "⑥ 风扇组件已跳过 → 跳过"
  fi

  # ---- ⑨ FileBrowser（最后建，避免前面 nginx 重载打断）----
  local _fb_dec; _fb_dec="$(component_decision filebrowser)"
  if [[ "$_fb_dec" == "chosen" ]] && [[ -x /usr/local/bin/filebrowser ]]; then
    c_info "⑨ 重建 FileBrowser 服务单元并重启（幂等，不重新下载二进制）"
    if step_filebrowser; then n=$((n+1)); else c_warn "  FileBrowser 重建失败，可单独 --redo=22"; fi
  else
    c_info "⑨ FileBrowser 状态=$_fb_dec / 未安装 → 跳过"
  fi

  # ---- ⑩ 本地博客站点（:81 / boke）----
  c_info "⑩ 重建本地博客站点（端口 $PORT_BLOG，目录 $BLOG_DIR；不覆盖已有首页）"
  if step_blog; then n=$((n+1)); else c_warn "  博客站点重建失败，可单独 --redo=23"; fi

  # ---- ⑪ qB WebUI 凭据自愈（真机：步骤 08 已 done 被跳过，配置缺 WebUI\Username/Password_PBKDF2 → 登录报 Invalid Username or Password）----
  local _qb_dec; _qb_dec="$(component_decision qb)"
  if [[ "$_qb_dec" == "chosen" ]] && command -v qbittorrent-nox >/dev/null 2>&1; then
    c_info "⑪ 重修 qB WebUI 账号密码并写中文界面/关 Host·CSRF，再 curl 登录自检（不重装、不动下载数据）"
    qb_creds_heal
    # ★ 判据升级：不仅字段齐，还要用 admin/adminadmin 真实登录成功（HTTP 200 + Ok.）
    if qb_creds_ok && qb_curl_login_check; then
      c_ok "qB WebUI 登录自检通过（admin / adminadmin，中文界面）"
      n=$((n+1))
    else
      c_warn "qB WebUI 登录自检未过：sudo bash $SCRIPT_PATH --with-qb --redo=08"
    fi
  else
    c_info "⑪ qB 状态=$_qb_dec / 未安装 → 跳过"
  fi

  # ---- ⑫ Transmission 403 自愈（真机：步骤 09 已 done 被跳过，settings.json 仍是旧的）----
  local _tr_dec; _tr_dec="$(component_decision transmission)"
  if [[ "$_tr_dec" == "chosen" ]] && [[ -f "$BASE/transmission/settings.json" ]]; then
    c_info "⑪ 重修 Transmission 白名单并验证 WebUI（不重装、不询问、不动下载数据）"
    if tr_repair_403; then n=$((n+1)); fi
    tr_proxy_apply
  else
    c_info "⑫ Transmission 状态=$_tr_dec / 未配置 → 跳过"
  fi

  # ---- ⑦ nginx 语法与重载 ----
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
    c_ok "⑦ nginx -t 通过并已重载"
  else
    c_warn "⑦ nginx -t 未通过，请手工检查：nginx -t"
  fi

  # ---- ⑧ FPM 重载（probe.php 是静态文件其实不需要，但顺手确认服务在） ----
  if php_fpm_running_ok; then c_ok "⑧ PHP 8.2 FPM 功能正常"
  else c_warn "⑧ PHP 8.2 FPM 功能检查未过：systemctl status $PHP_FPM_SVC"; fi

  c_ok "一键修复完成：共 $n 项幂等重建（组件选择与数据完全未动）"
  c_step "自动复查：重新跑一次完整自检"
  final_check
  return $?
}

# ------------------------------ 状态 / 帮助 ---------------------------------
print_status(){
  local s i d f o st mirror=""; c_step "部署进度（$(date '+%F %T')）"
  if [[ ! -r "$STATE_FILE" && -r "$MIRROR_FILE" ]]; then
    mirror="（外置盘状态不可读，使用镜像 $MIRROR_FILE）"
  fi
  if [[ -n "$mirror" ]]; then c_warn "$mirror"; fi
  printf '%-4s %-48s %-10s %s\n' "ID" "步骤" "状态" "更新时间"
  for s in "${STEPS[@]}"; do
    IFS='|' read -r i d f o <<< "$s"
    if [[ -r "$STATE_FILE" ]]; then
      st="$(grep -F "$i=" "$STATE_FILE" | tail -1 | cut -d= -f2- || true)"
    else
      st="$(grep -F "$i=" "$MIRROR_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    fi
    local state="${st%%|*}" tm="${st#*|}"
    case "$state" in
      running)     state="中断?" ;;
      failed)      state="失败" ;;
      skip)        state="跳过" ;;
      uninstalled) state="已卸载" ;;
      done)        state="完成" ;;
      *)           state="未开始"; tm="" ;;
    esac
    printf '%-4s %-48s %-10s %s\n' "$i" "$d" "$state" "$tm"
  done
  local bad="" skipped=""
  for s in "${STEPS[@]}"; do
    IFS='|' read -r i d f o <<< "$s"
    st="$(state_get "$i")"
    if [[ "$st" == running || "$st" == failed ]]; then bad+=" [$i] $d"; fi
    if [[ "$st" == skip && "$o" != "-" ]]; then skipped+=" [$i] $d"; fi
  done
  local uninst=""
  for s in "${STEPS[@]}"; do
    IFS='|' read -r i d f o <<< "$s"
    [[ "$(state_get "$i")" == uninstalled && "$o" != "-" ]] && uninst+=" [$i] $d"
  done
  if [[ -n "$skipped" ]]; then
    c_info "已选择跳过的组件：$skipped（下次运行会再次询问，输入 y 即可补装）"
  fi
  if [[ -n "$uninst" ]]; then
    c_info "已卸载的组件：$uninst（下次运行会再次询问是否重新装回）"
  fi
  if [[ -n "$bad" ]]; then
    c_warn "检测到未完成步骤：$bad"
    c_info "直接执行：sudo bash $SCRIPT_PATH  即从这些步骤继续（已完成的自动跳过）"
    c_info "若 SSH 曾断线，先看会话：tmux attach -t armbian-nas"
  else
    c_info "没有中断记录。想重新检查安装结果：sudo bash $SCRIPT_PATH --check"
  fi
}

usage(){
  cat <<EOF
armbian-nas 一键部署 v$VERSION

用法： sudo bash $SCRIPT_PATH [选项]

默认（不带参数）= 部署 + 自动断点续跑：先挂载外置盘，再从第一个未完成步骤继续，最后自检。

运行模式：
  --status              只看进度，不改系统
  --check               只跑最终安装状态检查（含软件清单与路径），不改动系统
  --repair              ★一键修复：按自检失败项【幂等重建配置】后自动复查。
                        不重新安装软件、不重新询问组件选择、不删数据、不格式化。
                        会修：nginx 日志软链(ln -sfnT) / probe.php 的 pcntl 例外 /
                        白色导航页 + X-Prober + nginx 放行 / Samba 共享段落 /
                        ttyd 单元与启动 / 风扇参数文件与温控脚本。
                        风扇未做针脚两轮确认时保持停用，请先 --fan-probe。
  --reset               清空步骤状态后全量重跑（配置幂等，不会卸载已装软件）
  --uninstall           交互菜单：列出已装软件，选编号卸载
  --uninstall=<key>     直接卸载指定软件，多个用逗号隔开
                        例：--uninstall=qb  或  --uninstall=qb,transmission
  --uninstall-all       卸载全部可选组件（会二次确认）
  --purge-data          卸载时连「组件专属数据目录」一起删（默认绝不删数据！）
  --yes / -y            跳过交互确认（写给自动化脚本用，别随手加）
  --redo=ID             ★ 定向模式：只重跑该步（11 连带 12/13；03 连带 04），
                        不再询问其它组件，末尾自动重建导航页与状态页
  --from=ID             从 [ID] 开始一直跑到尾（完整续跑语义，不用定向）
  --reselect            重新选择共享目录（配合 --redo=11）
  --keep-going          某步失败也继续后续步骤（默认停下，便于定位）
  --fan-probe           风扇针脚实测：先确认「开→转」「关→停」，两轮都过了才写服务
                        （默认只验证已实测的 515）
  --scan                逐个试 10 个安全 sysfs 编号（主脚本与 风扇针脚测试.sh 都支持）
  --fan-probe-only      只记录两轮确认结果，暂不启用服务
  --fan-probe-apply     按上次实测结果启用温控服务
  --fan-test-on         临时停服务并强制开风扇几秒，验证后自动恢复服务
  --fan-test-off        临时停服务并强制关风扇几秒，验证后自动恢复服务
  --dry-run             只打印配置与步骤清单，不执行
  --no-tmux             不自动放进 tmux（断线保护不依赖 SSH_TTY，sudo 下同样生效）
                        ★ 缺 tmux 时脚本会自动 apt 补装，不会静默放弃断线保护
                        ★ 排查单个软件补装失败时推荐加它：输出留在当前终端不被 tmux 清屏
  --min-root-space=N    部署前要求根分区至少剩 N MiB（默认 1536=1.5G，0=关闭）
  --force-low-space     空间不足时只告警不中止（断点续跑默认也只告警）
  --noninteractive      不做交互询问（组件按默认值，共享目录按自动匹配）
  --all-yes             所有可选组件都安装，不逐个询问
  --all-no              所有可选组件都跳过，不逐个询问
  --with-<组件>         指定安装某组件，如 --with-qb / --with-docker
  --no-<组件>           指定跳过某组件，如 --no-transmission / --no-docker
  --with-gui            额外安装 XFCE + xrdp 图形界面
  --no-pecl             跳过第三方扩展的 pecl 编译兜底（pecl 卡住时用）
  --quiet / --no-install-progress
                        静默模式：不显示 apt 实时输出与心跳（默认【显示】）
  --install-progress    显式开启安装进度输出（默认已开启）
  --heartbeat=10        长操作心跳间隔秒数（默认 10；看到心跳=没死机）
  --no-nav-secrets      导航页卡片不显示默认密码/密钥（默认【显示】，局域网自用）
  --nav-theme=light|dark 导航页主题：light=白色明亮（默认），dark=旧深色
  --portainer-port=N     Docker Web 管理界面 Portainer 端口（默认 9000）
  --no-portainer         装 Docker 时不带 Portainer（省镜像层与内存）
  状态页 /status.html：每卡片末尾有该软件的一键安装/重装命令，例如
    sudo bash <脚本> --with-filebrowser --redo=22
  --fan-status          ★风扇一键诊断：服务状态 / 参数 / 每个温度源原始读数 / GPIO 当前电平 / 最近日志
  --blog-port=81         本地博客独立端口（默认 81）
  --blog-dir=<目录>      本地博客网站根目录（默认 $BASE/boke，在外置盘）
  --fb-bin=<路径>       离线安装 FileBrowser：本地 tar.gz 或二进制（GitHub 下不了时用）
  --fb-root=<目录>      FileBrowser 可浏览根目录（默认 /mnt，两块外置硬盘都在下面）
  --fb-port=<端口>      FileBrowser 端口（默认 8082）
  --prober-php=<路径>   指定 X-Prober 单文件 prober.php，装到网站根目录做完整 PHP 探针
                        （随包的 prober.php 放在脚本同目录会自动识别）

导航页（步骤 18）默认：白色明亮主题 + 顶部在线文档 + 可折叠（默认收起）的
  本机全部 IP / 来访主机 / 访问地址 / 主机名 + 常用 Web 界面卡片（含 Docker 的
  Portainer Web 管理）+ 存储挂载点/总空间/剩余空间 + 独立状态页入口 + PHP 探针。
  ★「软件装在哪 / 运行状态 / SSH 命令 / 默认密码 / 路径清单」已搬到独立页面
  /status.html（新标签页打开），首页保持整洁；每张状态卡片【最后一条】是本脚本
  一键安装/重装/修复该软件的 SSH 命令，复制即可用，例如 FileBrowser 没装就复制
  sudo bash <脚本> --with-filebrowser --redo=22。密码默认明文显示（局域网自用）。
  --no-apt-external     apt 缓存/lists 不外置（默认外置）
  --enable-admin-pool   落地 root 权限 admin FPM 池（默认只生成模板，不启用）
  --docker-external=1   把 Docker 镜像层迁到外置盘的 ext4 loop 镜像（默认关闭，有掉盘风险）
  --docker-loop-size=12G  loop 镜像大小（配合 --docker-external=1）
  --swappiness=<值|auto> vm.swappiness：auto=有 zram 用 150/无 zram 用 10，
                        并自动探测内核上限（<5.8 回落 100）
  --zram=auto|off|force   zram 策略：auto=识别现有管理器/必要时装 zram-tools；
                        off=完全不碰 zram；force=强制安装 zram-tools
  --zram-priority=100    新建 zram 的 swap 优先级（越大越优先）
  --swap-priority=-2     磁盘 swapfile 的优先级（越低越靠后）
  --zram-percent=50      zram 容量占内存百分比
  --zram-algo=lz4        zram 压缩算法（S905X 建议 lz4）
  --journal-max=100M     journald 上限

路径 / 硬盘：
  --base=/mnt/sda1/www         数据根目录
  --main-dev=/dev/sda1         主盘分区（NTFS 500G 移动硬盘）
  --second-dev=/dev/sdb1       第二块盘分区
  --config=/path/conf          读取 shell 变量配置文件

服务参数：
  --zt-network=<16位ID>        ZeroTier 网络 ID（仍需到 Central 授权）
  --docker-mirror=Aliyun       Docker 安装镜像加速
  --shares='目录1,目录2'       直接指定共享目录
  --smb-writable=1             Samba 允许写入（默认只读）
  --hd-idle=600                空闲多少秒休眠（默认 600）。hdparm -S 按 5 秒粒度
                              向上取整并钳到 1..240（=5s..20min）；<5 秒按 5 秒处理，
                              避免旧算法整除得 0 反而【禁用休眠】；>1200 秒 hd-idle
                              仍按原值，但 hdparm 回退会钳到 1200 秒并告警
  --aria-ng-zip=/path/zip      离线提供 AriaNg 静态包
  --ttyd-port=7681             ttyd 本地监听端口（只听 127.0.0.1，不放通防火墙）
  --ttyd-path=/ttyd            nginx 反代路径
  --ttyd-user=root             ttyd 进程用户（改低权限用户后 sudo 会要密码）
  --ttyd-auth-user=nasadmin    网页登录用户名
  --ttyd-max-clients=3         最大并发终端数
  --ttyd-bin-url=/本地/路径     apt 装不上时改用的静态二进制（本地文件或 URL）
  --tr-proxy=1              ★ 在 80 端口加 /transmission/ 反代（默认关闭，WebUI 直连 :9091）
                              正确写法见第二十一章；403 与反代无关，先 --repair 修白名单
  --second-fstype=ntfs-3g   ★ 第二块盘强制用 ntfs-3g（等价手写 fstab 写 ntfs 类型；
                              绕开内核 ntfs3 对脏位/休眠的严格校验）
  --mount-timeout=120         fstab 等 USB 设备出现的秒数（双盘 spin-up，30s 太短）
  --no-mount-helper           不装开机补挂 timer（默认装：nofail 跳过后每 90s 自愈重试）
  --fb-password=<值>          FileBrowser 默认密码（上游强制 ≥12 位；默认 adminadmin123）
  --qb-password=<值>          ★ qB WebUI 密码（默认 adminadmin，脚本现算 PBKDF2 写入 conf；
                              重置回默认：--with-qb --redo=08 --qb-password=adminadmin）
  --creds=simple|random        ★ 统一凭据：simple（默认）= ttyd/aria2 为 admin / admin，
                              FileBrowser 为 admin / adminadmin123（≥12 位）；
                              random = 恢复旧版随机密钥
  --tr-webui=ask|trguing|official
                              Transmission 界面：ask=步骤 09 询问（默认，回车/y 装中文增强界面；
                              显式传 ask 会清除上次选择、重新询问），
                              trguing=直接装中文，official=保留官方英文界面
  --tr-webui-zip=/路径 或 URL   离线提供 TrguiNG 中文 WebUI 包（GitHub 不可达时用）
  --tr-webui-tag=<资产名>       指定 release 版本，例 trguing-web-v1.3.0-zh-240607a
  --github-mirror=<前缀>        GitHub 下载加速前缀，例 https://ghproxy.net/

★ 定向模式（指定软件只装该软件）：
  命令行一旦带 --with-<组件> 或 --redo=<步骤>，就【只执行目标步骤】，
  然后末尾自动重建导航页 + 状态页并跑自检。不会再弹出 Docker / 图形界面 /
  ttyd 等「上次已跳过」组件的安装提示，也绝不改写其它组件的状态。
  例：sudo bash <脚本> --with-filebrowser --redo=22  → 只装 FileBrowser。
  只有不带这些参数、直接运行的一键部署才逐个询问所有可选组件。

★ 内网自用统一凭据（默认）：
  ttyd 网页终端、aria2 RPC 密钥 = admin / admin；
  FileBrowser = admin / adminadmin123 —— 不是脚本不肯统一，是 FileBrowser v2.6x
  强制密码 ≥12 位（admin 5 位、adminadmin 10 位都会报
  "password is too short, minimum length is 12"）。可用 --fb-password= 自定义 ≥12 位值。
  首页与状态页卡片直接显示明文，无需查文件。
  ★ qB = admin / adminadmin：脚本已把 PBKDF2 固化进 [Preferences]（中文界面，
    并关掉 Host 头校验 / CSRF / 认证子网白名单），不再是 qB 的一次性临时密码。
    登录报 "Invalid Username or Password / Fails." 时跑 --repair 即可（停服→写
    两份 qBittorrent.conf→重启→真实登录自检）。自定义/重置：
      sudo bash <脚本> --with-qb --redo=08 --qb-password=你的密码
  Transmission 默认免密，Portainer 首次自行创建密码，状态页给出改密方法。
  想恢复随机密钥用 --creds=random。

★ Transmission 中文增强界面（步骤 09 · TrguiNG 汉化版）：
  官方自带 WebUI 是英文且功能较简。部署到步骤 09 会询问
  「是否安装中文增强界面？直接回车 / y = 安装，输入 n = 保留官方英文  [Y/n]」。
  选 y 即拉取 github.com/jayzcoder/TrguiNG 的 release 静态包（约 349 KB），
  解压到 $BASE/webui/trguing-zh，用 Transmission 官方支持的
  TRANSMISSION_WEB_HOME 环境变量切换；不改 settings.json、不动系统自带 WebUI。
  ★ 不在 1G 内存小主机上 npm/rust 编译源码，用的是仓库已编译好的 WebUI 产物。
  GitHub 不可达时只告警并保留官方英文界面，不会让部署失败；离线补装：
    sudo bash <脚本> --tr-webui-zip=/路径/trguing-web-xxx-zh.zip --redo=09
  切回官方英文：sudo bash <脚本> --tr-webui=official --redo=09
  上游 openscopeproject/TrguiNG，AGPL-3.0；署名见说明文档「开源组件与致谢」章节。

★ 导航页顶部「📖 在线查看脚本文档」：/docs.html（由同目录 armbian-nas-使用说明.md
  生成，纯静态 / 无 CDN / 局域网离线可用，含目录与全文搜索）。
★ 每次运行脚本到最后（deploy / --check / --repair）都会重新生成一次导航页，
  保证组件状态、在线文档、本机全部 IP 与来访主机 IP 都是最新快照。
★ prober.php 完整 PHP 探针来自 X-Prober（https://github.com/kmvan/x-prober），
  署名与许可证说明见使用说明「开源组件与致谢」章节。

★ 新机只跑 --check 时：还没执行过的可选组件会显示「尚未部署 / SKIP」，
  不会再被误当成「计划安装」去检查服务而报一堆 FAIL。四态：
  chosen(已选/已装) / skip(主动跳过) / uninstalled(已卸载) / undecided(尚未跑到)。

软件选择（每个软件到那一步都会问一次，可对着 eMMC 估算决定装不装）：
  组件 key：docker / verysync / zerotier / qb / transmission / aria2 /
            minidlna / samba / fan / hd_idle / gui / ttyd / filebrowser
  ★ ttyd（网页终端）默认安装；★ 面板 OLED 已整体移除（见下方说明）。
  交互：运行到该步时显示「预计占用 eMMC + 数据目录 + 访问入口」，
        直接回车或 y = 安装；输入 n = 跳过。
  跳过记为 skip 状态（不是 done），所以【下次运行脚本会再次询问】；
  那时输入 y 就补装，装完记 done，之后自动跳过。
  非交互式：--with-<key>=安装 / --no-<key>=跳过 / --all-yes / --all-no，
            也可在 --config 文件里写 INSTALL_QB=1、INSTALL_DOCKER=0 等。
  例：sudo bash $SCRIPT_PATH --no-docker --no-qb --with-transmission
     （忽略 Docker 与 qB，只装 Transmission，其余仍逐个询问）

风扇针脚实测（第一次装风扇强烈建议先跑这个，别直接 --redo=14）：
  sudo bash $SCRIPT_PATH --fan-probe
  或更省事：sudo bash ./风扇针脚测试.sh
  严格按你要求的操作顺序，脚本【绝不先写死服务】：
    ① 停旧温控服务（报 "Unit armbian-fan.service not loaded" 完全正常，
       说明脚本还没部署到这台机器，不是故障）
    ② 逐个候选执行【开】→ 等 ${FAN_PROBE_HOLD}s → 问「风扇转了吗？」必须亲口输入 y
    ③ 只有 y 才执行【关】→ 再等 ${FAN_PROBE_HOLD}s → 问「风扇停了吗？」必须再输入 y
    ④ 两轮都 y 才把 on/off 写进 /etc/default/armbian-fan，生成温控服务并 enable
    ⑤ 任一 n → 立即恢复关闭，试下一个候选；全失败 → 【不写服务】，明确给排查建议
  ★ 默认只验证你已实测的 515（J9 Pin35 / GPIOAO_3），两轮确认后直接写服务。
  --scan 才逐个试 fan.sh 的 10 个安全 sysfs 全局编号（515/516/517/518/
  544/545/546/547/548/622）+ 504 备选 + libgpiod 备选，【绝不枚举区间】。
  ★ --scan 主脚本自己也认（等价于清空 --fan-confirmed 后跑 --fan-probe）；
    风扇针脚测试.sh --scan 只是转发到这里，两条命令效果完全一样。
  ⚠ 515 是纯风扇引脚，默认绝不联动 474/476/477 面板灯。
  ⚠⚠ 严禁测试 gpiochip1 的【line 70~80】：会掉线需拔电重启。那是 libgpiod 的
     line 编号，与这里的 sysfs 全局编号 515 不是同一命名空间，别混淆。
  sysfs 由内核态保持电平，不需常驻进程；服务启动时强制 INIT OFF，退出时显式关风扇。
  libgpiod 备选分支才会起常驻 gpioset（v1 --mode=wait / v2 -c）。
  --fan-probe-only  只记录结果   --fan-probe-apply  之后启用服务
  --fan-test-on / --fan-test-off  装好后再验证，保持几秒自动恢复服务
  --probe-hold=4    每轮等待秒数

ttyd 网页终端（步骤 21，默认安装，不用再开 SSH）：
  入口：http://<本机IP>${TTYD_PATH}/   登录名 $TTYD_AUTH_USER（可用 --ttyd-path 改，默认 /ttyd）
  查密码：sudo grep TTYD_WEB_PASS $SECRETS_FILE
  ⚠ ttyd 默认【无认证】且监听 0.0.0.0，直接跑等于把 shell 送人。脚本三层收紧：
     ttyd 只听 127.0.0.1:$TTYD_PORT → nginx 反代 ${TTYD_PATH}/ + auth_basic
     → 密码只在 .deploy/secrets.env（700，PHP open_basedir 够不到），首页不显示值
  ⚠ 这等于浏览器里的 $TTYD_USER shell：绝不要把本机 80 端口映射到公网，
     ZeroTier 也只在可信网络里用；想降权用 --ttyd-user=nasweb（但 sudo 会要密码）
  安装来源：发行版 universe 的 ttyd（22.04 自带 1.6.3 / 本机 26.04 resolute 自带更新版）；
           源里没有就自动下 GitHub release 静态二进制（1G 内存不源码编译）
     静态二进制（aarch64 → ttyd.aarch64），不在 1G 内存机器上源码编译
  卸载：--uninstall=ttyd（nginx 片段自动恢复 404 占位，nginx -t 不会挂）

qBittorrent / Transmission = apt 原生安装（不再放进 Docker）：
  直接 apt 装 qbittorrent-nox / transmission-daemon，systemd 管服务；
  配置、下载、WebUI 静态文件全部在 $BASE 下：
    qB  conf=$BASE/qb/config/qBittorrent/qBittorrent.conf
        WebUI=$BASE/webui/qbittorrent（WebUI\\RootFolder）
    TR  conf=$BASE/transmission/settings.json
        WebUI=$BASE/webui/transmission（TRANSMISSION_WEB_HOME）
    下载=$BASE/downloads/{complete,incomplete,watch}
  若检测到旧版脚本创建的同名 Docker 容器（挂载 $BASE/qb 或 $BASE/transmission），
  会自动移除以免抢 8080/9091 端口；不是本脚本创建的同名容器不会动。
  Docker 本身变成完全可选组件，只供你自己跑别的容器。

PHP（严格 8.2）：
  只安装 php8.2-* 包，不装 php-fpm / php-cli 这类会跟随系统默认版本的 meta 包；
  nginx 只连 /run/php/php8.2-fpm.sock。源里没有 8.2 时自动添加 Sury 仓库。
  扩展按 $PHP_EXT_FILE 清单逐项核对（含 redis / igbinary / zstd / event / imap /
  gmp / pgsql / pdo_pgsql / exif / fileinfo / Zend OPcache 等），缺失会写进
  $PHP_EXT_MISSING 并在最终自检标 FAIL；源里缺的第三方扩展自动用 pecl 补装。
  重查：sudo bash $SCRIPT_PATH --redo=03

默认导航页（步骤 18）：
  生成 $WEB_ROOT/index.html + $WEB_ROOT/status.html（静态、无 CDN、按当前访问
  主机自动拼端口）。一键直达 ttyd / qBittorrent / Transmission（中文增强界面可选）/ AriaNg /
  FileBrowser / 微力同步 / 本地博客 / Portainer(Docker Web 管理) / MiniDLNA /
  Samba / ZeroTier Central / PHP 探针；未安装的软件卡片置灰，点开可跳到状态页
  复制一键安装命令。重建：sudo bash $SCRIPT_PATH --redo=18

步骤 19 · eMMC 瘦身与 PHP 安全基线（8G eMMC 必看）：
  zram 优先 / 磁盘 swap 兜底：识别已有管理器，缺包时多级 fallback 到原生自建 unit，
    把 fstab 里磁盘 swap 改成 pri=-2；swappiness 按内核上限自适应（>=5.8 可 >100）。
  低内存自适应：1G RAM 时压 zram 比例、收敛 php-fpm 子进程数。
  Docker 段仅在 Docker 组件已安装时执行：daemon.json 设
    max-size=$DOCKER_LOG_MAX_SIZE × $DOCKER_LOG_MAX_FILE；除 Portainer 外脚本不创建
    下载器容器（qB/Transmission 走 apt 原生）。存量容器只做检查与提示
    （全局日志配置只对新建容器生效），不会擅自删除你的容器。
  journald 上限 $JOURNALD_MAX_USE、apt 缓存/lists 外置、部署日志 logrotate、
    vm.swappiness=$SWAPPINESS、ext4 保留块 5% → $EXT4_RESERVE_PCT%。
  PHP：open_basedir 收口到站点必需目录，$STATE_DIR 对 PHP 不可达（RPC 密钥不会被读）；
    disable_functions 保持为空并做「不能禁」白名单冲突检查。
    绝不禁用 exec/pcntl/posix/sockets/shmop/sysvsem/imap/curl/opcache/fileinfo/gmp 等
    以及 probe.php 依赖的 file_get_contents/get_loaded_extensions/ini_get。
    eval 是语言结构、类方法不受 disable_functions 约束，详见 $BASE/config/disable_functions-建议.md
  admin 池：默认只生成模板（零风险），--enable-admin-pool 才落地 127.0.0.1:9001。
  CLI / FPM 双端扩展核对：php8.2 -m 与 probe.php（网页真实环境）分别比对同一份清单。

zram 优先 / 磁盘 swap 兜底（步骤 19，8G eMMC 必看）：
  目标：让内存里的压缩 swap 先被用，512M eMMC swapfile 只在溢出时才写，
        既省 eMMC 寿命又不会一卡就猛写盘。
  脚本会先识别「谁在管 zram」，绝不重复装第二套抢 /dev/zram0：
    Armbian 自带   → armbian-zram-config.service（只启用，不改它的大小/算法）
    zram-tools     → /etc/default/zramswap 的 PRIORITY=100
    zram-generator → /etc/systemd/zram-generator.conf 的 swap-priority=100
    都没有          → 安装 zram-tools 并设 PRIORITY=100
  然后把 /etc/fstab 里所有磁盘型 swap 行改成 pri=-2（幂等、先备份）。
  这是跨发行版最稳的做法：不管 zram 的 pri 是 5 还是 100，都一定高于磁盘。
  若该 swap 当前 USED=0 会 swapoff+swapon -a 立即生效；USED>0 只写 fstab，
  提示重启生效，绝不强行 swapoff 以免触发 OOM。
  vm.swappiness 按内核能力自适应：>=5.8 允许 >100（有 zram 时用 150），
  <5.8 写 150 会报 Invalid argument，脚本实测后自动回落 100；
  有 zram 同时设 vm.page-cluster=0（内存 swap 没有寻道，预读纯浪费）。
  没有 zram 时保持 10，不提高，避免疯狂写 eMMC。
  zswap 与 zram 是两套机制，同时开会重复压缩：脚本只提示，不擅自关闭。
  验证：swapon --show（看 PRIO 列）、zramctl、sysctl vm.swappiness vm.page-cluster
  关闭整套调整：--zram=off

比特米盒 / Khadas VIM1 (S905X) 风扇（步骤 14）—— ★已按你的实测结果定为 515：
  你用 fan.sh 在 khadas-vim1 上实测：
    [1/10] GPIO 515 - J9排针 Pin35 (GPIOAO_3) → 输入 y 确认
    → 风扇 = sysfs 全局编号 515，高电平(写1)开、低电平(写0)关。
  脚本默认就用 515（不再是 504 / gpiochip0 line 3），路径：
    /sys/class/gpio/gpio515/value
  规范写法：export 515 → direction=out → value=1/0（内核态保持电平，
  不需要常驻进程；这点和 libgpiod 不同）。

  ★★★ 默认【绝不联动面板灯】：474/476/477 在你这套 dtb 下是别的线，
  误写可能触发其它功能。只有明确 --fan-led=on 或编号=504 时才会动它们。

  三套映射【互斥】，取决于 dtb / 镜像，绝不能混用：
    A) sysfs 515  —— ★本机实测，纯风扇，J9 Pin35 / GPIOAO_3 / AO域 base=512+3
    B) sysfs 504  —— 网上 bitbox_on/off.sh，p212 dtb；风扇504 + 面板灯
                      474蓝/476红/477绿（开：504,474,476=high / 477=low）
    C) libgpiod gpiochip0 line 3 —— 另一套 dtb 的实测值
  换 CumeBox2 的 v.dtb 后 B 会失效（博客原话），所以 dtb 决定编号。

  fan.sh 里 10 个「排针引出、未被系统关键功能占用」的安全 sysfs 全局编号
  已作为 --fan-probe 候选（515/516/517/518/544/545/546/547/548/622），逐个
  【显式列出】测试，绝不枚举区间。⚠ 澄清命名空间：这些是【sysfs 全局编号】，
  和严禁测试的 gpiochip1【line 70~80】不是一回事 —— 后者会掉线需拔电重启，
  脚本绝不碰。

  --fan-mode=auto：有实测记录 → 按记录；否则 S905X + /sys/class/gpio 可用
  → A(515)；否则有 gpioset → C。--fan-mode=sysfs|libgpiod 可强制。
  --fan-confirmed=515  表示「已人工测过，只验证一根就写服务」
  --fan-active-high=0  低电平触发（fan.sh 提示的反相情况）：开写0/关写1
  --fan-sysfs-fan=504 --fan-led=on  切到 p212 dtb 那套

  温控安全：启动强制 INIT OFF；温度源全失效连续 3 次 fail-safe 开风扇；
  控制命令失败记 ERROR 不假装成功；服务退出时 sysfs 模式显式关风扇。
  温度来源：thermal_zone*/temp、hwmon temp1_input、Armbian soctemp。
  查看：tail -f $BASE/logs/fan.log ；journalctl -u armbian-fan -f
  完全自定义：--fan-mode=custom --fan-on-cmd='...' --fan-off-cmd='...'

本地博客（步骤 23，必需，随部署自动创建）：
  * 端口 81，独立 nginx server 块 $BLOG_SITE；网站目录 $BLOG_DIR（外置盘）
  * 首页卡片「本地博客」点开【新标签页】直达 http://<本机IP>:81/
  * 默认生成一个白色静态首页 + info.php（验证 PHP 8.2 FPM 通了）
  * 把 Typecho / WordPress / 静态博客放进 $BLOG_DIR，删掉默认 index.html 即可
  * 站点不写 default_server，不与 80 端口 armbian-nas 冲突；ufw 已放通 81/tcp
  * 换端口/目录：--blog-port=8081 --blog-dir=/mnt/sda1/boke --redo=23
  * 状态卡片里也有「本地博客站点」一项，列配置/日志路径与 nginx 运维命令

面板 OLED（★ 已整体移除，步骤 20 改为安全清理占位）：
  真机实测：每次部署跑到这一步就网络短线、整个路由器内网全部连不上。
  根因：旧版在此处 apt 装 i2c-tools（内核随之加载 i2c-dev，暴露 SoC 上
  所有 /dev/i2c-*），然后对【每条总线】跑 i2cdetect -y 全地址扫描
  （0x03–0x77）。S905X 内部 I2C 上还挂着 PMIC / 以太网 PHY / HDMI DDC，
  探测帧可能改写寄存器、触发 PHY 复位或锁死总线，RGMII/MDIO 复用引脚
  被抢占后 MAC 挂死，异常帧把上级路由器 LAN 一起拖住 —— 常需拔电重启。
  这与「gpiochip1 line 70~80 会导致掉线」是同一类硬件踩踏。
  ★ 本版不再安装 i2c-tools、不再 i2cdetect、不改 dtb、不碰 GPIO；
    步骤 20 只停掉旧机器残留的 armbian-oled 服务并删单元文件。
  ★ 旧参数 --oled-bin / --oled-config / --oled-i2c-* 会被提示并忽略；
    --with-oled / --no-oled 也不再报错。$BASE/oled 里的旧模板保留不删。


★ 设备与实测环境（步骤 19 等）：
  设备是【比特米盒 CumeBox2】，刷 Khadas VIM1 开发板镜像；本脚本在【全新系统】下部署。
  root@khadas-vim1 实测：Armbian 26.8.11 resolute（Ubuntu 26.04）、
  内核 6.18.57-current-meson64、PHP 8.2.35（Sury 的 ubuntu26.04 包）、
  /sys/class/gpio 下 gpiochip512(AO)+gpiochip523(Periphs)、911M 内存、
  系统自带 1.89G zram 已启用、CPU 57℃。
  全新部署（--no-docker --no-gui）后：根 7.0G 用 2.1G / 剩 4.9G / 30%，eMMC 很宽裕；
  两块 466G 外置盘各剩约 13G（原有电影占用，注意下载余量）。
  脚本【不写死版本】，全部运行时探测：
    * PHP 源：先 apt-cache policy，本机已装 8.2.35 会直接跳过 Sury；需要时
      按 /etc/os-release 的 VERSION_CODENAME 写源（jammy / noble / resolute 通用）
    * swappiness：sysctl -w 实测内核是否接受 >100（>=5.8 才允许），失败回落 100
    * libgpiod：gpioset --version 判 v1/v2（resolute 多为 v2）
    * zram：识别现有管理器；没有才依次试 zram-tools → generator →
      zram-config → 内核原生自建 unit，保证分层一定成立、不静默失败
    * 1G 内存：zram 比例 50%→25% 上限 512M；php8.2-fpm 池改
      ondemand / max_children=3 / 空闲 10s 回收（先备份 www.conf）
    * 根设备：findmnt 自动识别（SD 卡的 mmcblk0/1 或 eMMC 都行），不写死
  ⚠ 部署【前】会检查根分区剩余 >=1.5G（--min-root-space 可调）：装软件时 apt 缓存
    还没外置，老机器塞满要提前拦下；-check 另在 >=85% 使用率时告警。
    全新系统部署后实测仅用 30%，无需担心，--no-docker --no-gui 即可。
  历史兼容：Ubuntu 22.04 / 内核 5.x / Armbian 23.x / Debian 11 只是老镜像的例子，不是本机版本。
  全面检查已修：三套 GPIO 映射互斥、zram 包缺失兜底、1G 内存漏算、
  温控 4 个 bug（初始 OFF / 温度失效保护 / 命令失败不假装成功 / 退出关风扇）、
  自检按模式分支。逐项结论与空间占用数据见使用说明「常见问题与状态解读」章节。

关于 Docker data-root 放外置盘（--docker-external=1）：
  NTFS 不支持 overlay2（缺 d_type/upperdir/xattr 语义），直接 --data-root 到
  $BASE 会启动失败或被迫退回 vfs（极慢、空间翻倍）。脚本的可选方案是在 NTFS 里
  建一个 ext4 loop 镜像 $BASE/.docker-ext4.img，再挂回 /var/lib/docker，
  用 systemd 软依赖（Wants）保证开机顺序；挂不上时 Docker 自动回退 eMMC，不阻塞启动。
  代价：USB 掉盘/意外断电可能损坏容器层，旧目录保留 /var/lib/docker.emmc-bak 可回退，
  故默认关闭。SWAP 文件不能放 NTFS（swapon 会因不支持无洞文件报 Invalid argument）。

风扇（按主板实际接线选一种）：
  --fan-mode=auto|sysfs|libgpiod|pwm|custom
                        风扇 GPIO 映射【三套互斥，取决于 dtb】：
                          sysfs 515  = ★本机实测（J9 Pin35 / GPIOAO_3，默认）
                          sysfs 504  = p212 dtb 的风扇 + 474/476/477 面板灯
                          libgpiod   = gpiochip0 line 3（另一套 dtb）
  --fan-confirmed=515    ★你已用 fan.sh 实测过，只验证这一根就写温控服务
  --fan-sysfs-fan=515    sysfs 风扇全局编号（p212 dtb 改成 504）
  --fan-gpio=515         同 --fan-sysfs-fan（兼容 fan.sh 里 FAN_GPIO 的叫法）
  --fan-active-high=1|0  1=高电平开（本机实测）；0=低电平触发，开/关取反
  --fan-led=off|on|auto  面板灯联动（★默认 off：515 是纯风扇，绝不误写 474/476/477）
  --fan-failsafe=1|0     温度源全失效时强制开风扇（默认 1，散热优先）
  --fan-board=auto|bitemi|generic  板型预设；auto 识别 S905X/VIM1/CumeBox2
  --fan-gpio-chip=gpiochip0     libgpiod 芯片名（比特米盒实测 gpiochip0）
  --fan-gpio-line=3             libgpiod 线号（比特米盒实测 3）
  --fan-gpiod-major=1|2|auto   libgpiod 大版本，auto=从 gpioset --version 探测
  --fan-gpio=<内核GPIO编号>    旧 sysfs GPIO 模式（新内核已移除，仅老系统用）
  --fan-active-high=0|1        GPIO 有效电平，默认 1
  --fan-pwm-chip=pwmchip0      PWM 模式（比特米盒无效，见下方专节）
  --fan-pwm-channel=0
  --fan-on-cmd='...'           自定义开风扇命令（优先级最高）
  --fan-off-cmd='...'          自定义关风扇命令
  --fan-on-temp=50             达到该温度开风扇
  --fan-off-temp=48            低于等于该温度关风扇；设 50 为严格模式（可能抖动）
  --fan-temp-file=/sys/...     指定温度文件，留空自动探测
  --probe-hold=4               针脚实测每轮等待秒数（默认 4）
  --probe-sysfs=515            --fan-probe 额外试一个 sysfs 全局编号
  --low-mem=1200               低内存阈值（MiB）；1G RAM 会自动收敛 php-fpm 与 zram 大小
  --oled-*（全部）              ★ 已移除：会被提示并忽略，不触发任何 I2C 操作

示例：
  sudo bash $SCRIPT_PATH --zt-network=1234567890abcdef \\
      --fan-gpio=17 --shares='/mnt/sda1/电影,/mnt/sdb1/video'

卸载功能（新手请先读完这段）：
  问题场景：qBittorrent 装好了，过一阵子不想用了，想卸掉腾出 eMMC 空间。
  做法：
    sudo bash $SCRIPT_PATH --uninstall            # 弹菜单，按编号选，最不容易出错
    sudo bash $SCRIPT_PATH --uninstall=qb         # 直接卸 qB，会再问一次 yes
    sudo bash $SCRIPT_PATH --uninstall=qb --yes  # 不交互，直接卸（自动化用）

  卸载时脚本会先列出「将删除什么 / 将保留什么」，输入 yes 才真的动手。
  默认【只删软件本体和系统配置】，以下用户数据一律保留：
    $BASE/qb、$BASE/transmission、$BASE/aria2、$BASE/verysync、$BASE/minidlna
    $BASE/downloads（三个下载软件共用，永远不动）、$BASE/web、$BASE/logs、$BASE/db
  所以卸载后电影、种子、设置都还在；以后装回来，设置还能接着用。

  如果确实想连组件数据一起删，必须显式加 --purge-data，并且会再确认一次：
    sudo bash $SCRIPT_PATH --uninstall=qb --purge-data
  即便如此，共用的 downloads / web / logs / db / .deploy 仍然不会删，
  因为删了会连带弄坏别的软件或丢掉断点续跑状态。

  卸载完成后：
    * 该步骤状态记为 uninstalled（不是 done），所以【下次运行脚本会重新问
      「是否安装？」】，输入 y 就装回来，和第一次一样的体验。
    * 想直接装回：--with-qb --redo=08（步骤号按软件查 --dry-run）
    * 不想再被问：--no-qb（换成对应组件名）
    * 首页会自动刷新，把已卸载的软件灰显，避免点了打不开。
    * 卸载本身不做 apt autoremove，避免误删其它组件还在用的依赖包。

最终状态显示：
  脚本最后依次打印：
    1) 「软件组件清单」——选择 / 安装 / 运行 / 版本 / eMMC估算 / 配置项
       （unit、端口、配置文件、WebUI 目录、下载目录、密钥路径等）
    2) 「软件路径清单」——程序本体、服务单元、配置文件、网页界面文件、
       数据目录、日志、访问地址，一条一条列出来，标「当前不存在」的
       表示还没装，装好之后会出现在那儿
    3) 逐项检查表。被跳过 / 已卸载的显示 SKIP（不是 FAIL），并注明下次会再问。
  同一份清单会写进 $REPORT_FILE，随时可回看；独立状态页也有对应的卡片。

独立状态页 /status.html：
  静态生成、不联网、不依赖后端，从首页点「软件装在哪 / 运行状态」卡片新标签页打开。
  每个软件一张卡片，按「常用 Web → 媒体库 → 环境/后台」分组，顺序与首页一致：
  安装/运行状态 → 版本/eMMC 估算/入口 → SSH 启停重启与日志命令 → 默认密码/凭据
  → 程序/配置/网页/数据/日志路径 → 【最后】本脚本一键安装/重装/修复命令。
  每条命令右边都有「复制」按钮。没装的软件卡片灰掉，但一键命令始终可用。

详细结果：$REPORT_FILE
状态文件：$STATE_FILE（另有镜像 $MIRROR_FILE，硬盘掉了也能查进度）
EOF
}

# ------------------------------ 参数解析 -------------------------------------
# ★★ 全局保存【原始命令行参数】：SSH 断线自动进 tmux 时，要用它原样重启脚本。
#    绝不能用 parse_args() 里的 local -a args —— 函数一返回数组就失效，
#    "${args[@]}" 在 Bash 5.x 会静默展开成空（更老的 bash 直接 unbound variable），
#    于是 --no-docker --no-gui / --redo= / --zt-network= / --fan-mode= 在 tmux 里
#    全部丢失，变成「无参运行」。这是以前 tmux 分支不可达时被掩盖的连带缺陷。
TMUX_ARGS=("$@")

# 先预读 --config，使配置文件里的默认值可被命令行覆盖。
# 这一段保持在【全局作用域】：被 source 的配置文件里的变量必须是全局的。
for _pa in "$@"; do case "$_pa" in --config=*) CONFIG_FILE="${_pa#*=}";; esac; done
if [[ -f "$CONFIG_FILE" ]]; then set +u; source "$CONFIG_FILE"; set -u; c_info "已加载配置 $CONFIG_FILE"; fi

# ---------------------------------------------------------------------------
# 参数解析包成函数，只为两件事：
#   ① 临时变量一律 local，不再残留到全局命名空间；
#   ② 组件 key 改叫 ckey —— 原来用 `ck=`，和自检里的 ck() 函数同名。
#      bash 里函数与变量是不同命名空间，功能上不冲突，但读代码极易误解，
#      而且 ck 会残留成一个全局值。
# 注意：函数里给 MODE / FAN_* / INSTALL_* 等【未声明 local】的变量赋值，
#       bash 仍然写到全局，所以配置语义完全不变。
# ---------------------------------------------------------------------------
parse_args(){
  local a i ckey cv cv_found cv_var _k
  # 局部副本改名 _argv：不再叫 args，避免和全局 TMUX_ARGS 混淆，
  # 也避免有人以后又误用这个局部数组去重启脚本。
  local -a _argv=("$@")
  i=0
  while (( i < ${#_argv[@]} )); do
    a="${_argv[$i]}"
    case "$a" in
    -h|--help)             MODE=help ;;
    --status)              MODE=status ;;
    --check)               MODE=check ;;
    --repair)              MODE=repair ;;
    --reset)               MODE=reset ;;
    --uninstall)           MODE=uninstall; UNINSTALL_MENU=1 ;;
    --uninstall=*)         MODE=uninstall; UNINSTALL_LIST="${a#*=}" ;;
    --uninstall-all)       MODE=uninstall; UNINSTALL_ALL=1 ;;
    --purge-data)          PURGE_DATA=1 ;;
    --yes|-y)              ASSUME_YES=1 ;;
    --dry-run)             MODE=dry-run ;;
    --keep-going)          KEEP_GOING=1 ;;
    --no-tmux)             NO_TMUX=1 ;;
    --min-root-space=*)    MIN_ROOT_SPACE_MB="${a#*=}" ;;
    --force-low-space)     FORCE_LOW_SPACE=1 ;;
    --noninteractive)      NONINTERACTIVE=1 ;;
    --all-yes)             ALL_YES=1 ;;
    --all-no)              ALL_NO=1 ;;
    --reselect)            RESELECT=1 ;;
    --with-gui)            INSTALL_GUI=1 ;;
    --no-pecl)             PECL_FALLBACK=0 ;;
    --quiet|--no-install-progress) INSTALL_PROGRESS=0 ;;
    --install-progress)    INSTALL_PROGRESS=1 ;;
    --heartbeat=*)         HEARTBEAT_SEC="${a#*=}" ;;
    --min-root-space=*)    MIN_ROOT_SPACE_MB="${a#*=}" ;;
    --force-low-space)     FORCE_LOW_SPACE=1 ;;
    --no-nav-secrets)      NAV_SECRETS=0 ;;
    --nav-secrets)         NAV_SECRETS=1 ;;
    --creds=*)             CRED_MODE="${a#*=}" ;;
    --nav-theme=*)         NAV_THEME="${a#*=}" ;;
    --prober-php=*)        PROBER_PHP="${a#*=}" ;;
    --no-apt-external)     APT_CACHE_ON_EXTERNAL=0 ;;
    --enable-admin-pool)   ENABLE_ADMIN_POOL=1 ;;
    --docker-external=*)   DOCKER_EXTERNAL="${a#*=}" ;;
    --docker-loop-size=*)  DOCKER_LOOP_SIZE="${a#*=}" ;;
    --swappiness=*)        SWAPPINESS="${a#*=}"; SWAPPINESS_USER_SET=1 ;;
    --low-mem=*)           LOW_MEM_MIB="${a#*=}" ;;
    # ★ 面板 OLED 已移除：明确提示，绝不再设置任何 OLED_* 变量（不触发 I2C）
    --oled-bin=*|--oled-config=*|--oled-i2c-bus=*|--oled-i2c-addr=*|--oled-refresh-sec=*)
      c_warn "面板 OLED 功能已移除（i2cdetect 全总线扫描会打断网口/内网），忽略参数：$a" ;;
    --zram=*)              ZRAM_MODE="${a#*=}" ;;
    --zram-priority=*)     ZRAM_PRIORITY="${a#*=}" ;;
    --swap-priority=*)     SWAP_PRIORITY="${a#*=}" ;;
    --zram-percent=*)      ZRAM_SIZE_PERCENT="${a#*=}" ;;
    --zram-algo=*)         ZRAM_ALGO="${a#*=}" ;;
    --journal-max=*)       JOURNALD_MAX_USE="${a#*=}" ;;
    --config=*)            : ;;
    --redo=*)              REDO_ID="${a#*=}"; TARGETED=1 ;;
    --from=*)              FROM_ID="${a#*=}" ;;
    --base=*)              BASE="${a#*=}" ;;
    --main-dev=*)          MAIN_DEV="${a#*=}" ;;
    --second-dev=*)        SECOND_DEV="${a#*=}" ;;
    --zt-network=*|--zt=*) ZT_NETWORK_ID="${a#*=}" ;;
    --bt-mode=*)           c_warn "--bt-mode 已废弃：qBittorrent / Transmission 固定 apt 原生安装，忽略该参数" ;;
    --docker-mirror=*)     DOCKER_MIRROR="${a#*=}" ;;
    --docker-data-root=*)  DOCKER_DATA_ROOT="${a#*=}" ;;
    --shares=*)            SHARE_DIRS="${a#*=}" ;;
    --smb-writable=*)      SMB_WRITABLE="${a#*=}" ;;
    --hd-idle=*)           HD_IDLE_TIMEOUT="${a#*=}" ;;
    --aria-ng-zip=*)       ARIA_NG_ZIP="${a#*=}" ;;
    --fan-mode=*)          FAN_MODE="${a#*=}" ;;
    --fan-sysfs-fan=*)     FAN_SYSFS_FAN="${a#*=}"; FAN_PIN_DESC="用户显式指定的 sysfs 编号 $FAN_SYSFS_FAN" ;;
    --fan-confirmed=*)     FAN_CONFIRMED_PIN="${a#*=}"; FAN_SYSFS_FAN="${a#*=}" ;;
    --fan-led=*)           FAN_LED="${a#*=}" ;;
    --fan-failsafe=*)      FAN_FAILSAFE="${a#*=}" ;;
    --fan-board=*)         FAN_BOARD="${a#*=}" ;;
    --fan-gpio-chip=*)     FAN_GPIO_CHIP="${a#*=}" ;;
    --fan-gpio-line=*)     FAN_GPIO_LINE="${a#*=}" ;;
    --fan-gpiod-major=*)   FAN_GPIOD_MAJOR="${a#*=}" ;;
    --fan-gpio=*)          FAN_GPIO="${a#*=}"; FAN_SYSFS_FAN="${a#*=}"; FAN_PIN_DESC="--fan-gpio 指定的 sysfs 编号 $FAN_SYSFS_FAN" ;;
    --fan-active-high=*)   FAN_ACTIVE_HIGH="${a#*=}" ;;
    --fan-pwm-chip=*)      FAN_PWM_CHIP="${a#*=}" ;;
    --fan-pwm-channel=*)   FAN_PWM_CHANNEL="${a#*=}" ;;
    --fan-on-cmd=*)        FAN_ON_CMD="${a#*=}" ;;
    --fan-off-cmd=*)       FAN_OFF_CMD="${a#*=}" ;;
    --fan-on-temp=*)       FAN_ON_TEMP="${a#*=}" ;;
    --fan-off-temp=*)      FAN_OFF_TEMP="${a#*=}" ;;
    --fan-temp-file=*)     FAN_TEMP_FILE="${a#*=}" ;;
    --fan-probe)           MODE=fan-probe ;;
    --scan)                FAN_PROBE_SCAN=1 ;;  # MODE 交给下面的归一化决定，不抢 --help/--check
    --fan-probe-only)      MODE=fan-probe; FAN_PROBE_ONLY=1 ;;
    --fan-probe-apply)     MODE=fan-probe-apply ;;
    --fan-test-on)         MODE=fan-test-on ;;
    --fan-test-off)        MODE=fan-test-off ;;
    --fan-status)          MODE=fan-status ;;
    --probe-chip=*)        PROBE_CHIP="${a#*=}" ;;
    --probe-line=*)        PROBE_LINE="${a#*=}" ;;
    --probe-sysfs=*)       PROBE_SYSFS="${a#*=}" ;;
    --probe-hold=*)        FAN_PROBE_HOLD="${a#*=}" ;;
    --ttyd-port=*)         TTYD_PORT="${a#*=}" ;;
    --ttyd-path=*)         TTYD_PATH="${a#*=}" ;;
    --ttyd-user=*)         TTYD_USER="${a#*=}" ;;
    --ttyd-auth-user=*)    TTYD_AUTH_USER="${a#*=}" ;;
    --fb-bin=*)            FB_BIN="${a#*=}" ;;
    --fb-password=*)       FB_SIMPLE_PASS="${a#*=}" ;;
    --fb-root=*)           FB_ROOT="${a#*=}" ;;
    --second-fstype=*)     SECOND_FSTYPE="${a#*=}" ;;
    --mount-timeout=*)     DEV_TIMEOUT="${a#*=}" ;;
    --no-mount-helper)     MOUNT_HELPER_ENABLED=0 ;;
    --fb-port=*)           PORT_FB="${a#*=}" ;;
    --portainer-port=*)    PORT_PORTAINER="${a#*=}" ;;
    --no-portainer)        PORTAINER_ENABLED=0 ;;
    --fb-version=*)        FB_VERSION="${a#*=}" ;;
    --blog-port=*)         PORT_BLOG="${a#*=}" ;;
    --blog-dir=*)          BLOG_DIR="${a#*=}" ;;
    --tr-proxy=*)          TR_PROXY="${a#*=}"; [[ "$TR_PROXY" == "1" ]] || TR_PROXY=0 ;;
    --tr-webui=*)          TR_WEBUI="${a#*=}"; [[ "$TR_WEBUI" == "ask" ]] && TR_WEBUI_RESELECT=1 ;;
    --qb-password=*)       QB_WEBUI_PASS_OVERRIDE="${a#*=}" ;;
    --tr-webui-zip=*)      TR_WEBUI_ZIP="${a#*=}" ;;
    --tr-webui-tag=*)      TR_WEBUI_TAG="${a#*=}" ;;
    --github-mirror=*)     GITHUB_MIRROR="${a#*=}" ;;
    --ttyd-max-clients=*)  TTYD_MAX_CLIENTS="${a#*=}" ;;
    --ttyd-version=*)      TTYD_VERSION="${a#*=}" ;;
    --ttyd-bin-url=*)      TTYD_BIN_URL="${a#*=}" ;;
    --with-*|--no-*)
      if [[ "$a" == --with-* ]]; then ckey="${a#--with-}"; cv=1
      else ckey="${a#--no-}"; cv=0; fi
      # --with-<组件> = 明确「只装这个软件」→ 定向模式
      if [[ "$a" == --with-* ]]; then
        TARGETED=1
        TARGET_COMPS+=("${ckey//-/_}")
      fi
      ckey="${ckey//-/_}"
      if [[ "$ckey" == "oled" ]]; then
        c_warn "面板 OLED 组件已移除（原因见 --help），忽略参数：$a"
      else
        cv_found=0
        for _k in "${COMP_KEYS[@]}"; do [[ "$_k" == "$ckey" ]] && cv_found=1; done
        [[ "$cv_found" -eq 1 ]] || die "未知组件：$ckey（可用：${COMP_KEYS[*]}）"
        cv_var="INSTALL_${ckey^^}"
        printf -v "$cv_var" '%s' "$cv"
      fi
      ;;
    *) die "未知参数：$a（用 --help 查看）" ;;
    esac
    i=$((i+1))
  done
}
parse_args "$@"

# --scan 与 --fan-confirmed 的优先级归一化（放在循环结束后，避免受参数顺序影响）：
# --scan 表示「重新逐个排查 10 个安全引脚」，必须清掉已实测编号，否则 fan_probe
# 会走「只验证一根」的快速路径。风扇针脚测试.sh --scan 也是转发到这个分支。
if [[ "$FAN_PROBE_SCAN" -eq 1 ]]; then
  FAN_CONFIRMED_PIN=""
  # 只在用户没指定其它模式时才切到风扇探测；--help / --check / --dry-run 优先，
  # 否则 "主脚本 --scan --help" 会莫名其妙开始测 GPIO。
  case "$MODE" in
    deploy|fan-probe) MODE=fan-probe ;;
    *)                : ;;
  esac
fi

# 路径类变量派生（--base / 配置文件可能改过 BASE，这里统一刷新）
BASE="${BASE%/}"
WEB_ROOT="$BASE/web"
STATE_DIR="$BASE/.deploy"; STATE_FILE="$STATE_DIR/state"
SECRETS_FILE="$STATE_DIR/secrets.env"; SHARES_FILE="$STATE_DIR/share_dirs.txt"
REPORT_FILE="$STATE_DIR/final-report.txt"; LOG_DIR="$BASE/logs"; LOG_FILE="$LOG_DIR/deploy.log"
PHP_EXT_FILE="$STATE_DIR/php-extensions-wanted.txt"
PHP_EXT_MISSING="$STATE_DIR/php-extensions-missing.txt"
PHP_EXT_MISSING_FPM="$STATE_DIR/php-extensions-missing-fpm.txt"
DOCKER_LOOP_IMG="$BASE/.docker-ext4.img"
PHP_BIN="php$PHP_VER"; PHP_FPM_SVC="php$PHP_VER-fpm.service"
PHP_ETC="/etc/php/$PHP_VER"; PHP_SOCK="/run/php/php$PHP_VER-fpm.sock"
# ★ FileBrowser 数据库：全脚本只认这一个路径（真机教训：旧版/手工 unit 曾写成
#   $BASE/filebrowse/filebrowser.db（少一个 r），状态页与改密命令却写 filebrowser，
#   结果「改密成功却登录不上」——改到了另一个库。见第二十一章）。
#   所有引用点一律用 $FB_DB，禁止再出现字面量拼接。
FB_DB_DIR="$BASE/filebrowser"
FB_DB="$FB_DB_DIR/filebrowser.db"
FB_LEGACY_DB_DIR="$BASE/filebrowse"          # 旧版残留目录，仅用于迁移提示
# --ttyd-path 可能改过入口：数组在文件头部按默认值初始化，这里按最终值刷新，
# 组件清单 / 首页 JSON 快照 / 交互提示才会显示同一个地址（不再写死 /ttyd/）。
COMP_ENTRY[ttyd]="${TTYD_PATH%/}/（nginx 反代 + 密码）"
# ★ Transmission 界面按最终选择刷新入口文案（首页卡片 / 状态页 / 报告共用同一份快照）
case "$(tr_webui_decision)" in
  trguing) COMP_ENTRY[transmission]=":9091（TrguiNG 中文增强界面）" ;;
  *)       COMP_ENTRY[transmission]=":9091（官方英文界面）" ;;
esac

# ------------------------------ 主流程 ---------------------------------------
main(){
  # ★ 短密码必须在任何写操作之前拦住（help 仍可正常查看用法）
  if ! validate_simple_creds; then
    [[ "$MODE" == "help" || "$MODE" == "dry-run" || "$MODE" == "check" || "$MODE" == "status" ]] \
      || return 1
  fi
  case "$MODE" in
    help)    usage; return 0 ;;
    status)  print_status; return 0 ;;
    # 风扇针脚实测 / 手动开关：只测 GPIO，不挂外置盘、不改 fstab、不进 tmux。
    # 这一步常在完整部署之前做，若走 ensure_mounts 会因为盘没插好而失败甚至改 fstab。
    fan-probe|fan-probe-apply|fan-test-on|fan-test-off|fan-status)
      need_root
      case "$MODE" in
        fan-probe)       fan_probe; return $? ;;
        fan-probe-apply) fan_probe_apply; return $? ;;
        fan-test-on)     fan_test_action on; return $? ;;
        fan-test-off)    fan_test_action off; return $? ;;
        fan-status)      fan_status; return $? ;;
      esac ;;
    dry-run)
      c_info "DRY-RUN：不会改动系统。当前配置："
      if [[ "$TARGETED" -eq 1 ]]; then
        printf '  ★ 定向模式：本次只执行步骤 [%s]（--with-* / --redo=*），其它步骤保持原状态、不询问\n' \
          "${REDO_ID:-${TARGET_COMPS[*]}}"
      fi
      printf '  BASE=%s  WEB_ROOT=%s  MAIN_DEV=%s  SECOND_DEV=%s\n  PHP=%s (%s)  导航页=%s/index.html\n  ZT_NETWORK_ID=%s  FAN_GPIO=%s  FAN_PWM_CHIP=%s\n' \
        "$BASE" "$WEB_ROOT" "$MAIN_DEV" "$SECOND_DEV" "$PHP_VER" "$PHP_FPM_SVC" "$WEB_ROOT" \
        "${ZT_NETWORK_ID:-<空>}" "${FAN_GPIO:-<空>}" "${FAN_PWM_CHIP:-<空>}"
      printf '  BT 客户端：固定 apt 原生安装（qBittorrent / Transmission 各自可选，WebUI+下载在外置盘）\n'
      printf '  步骤19: Docker日志=%s×%s  journald=%s  apt外置=%s  admin池=%s  Docker外置=%s(%s)\n' \
        "$DOCKER_LOG_MAX_SIZE" "$DOCKER_LOG_MAX_FILE" "$JOURNALD_MAX_USE" \
        "$APT_CACHE_ON_EXTERNAL" "$ENABLE_ADMIN_POOL" "$DOCKER_EXTERNAL" "$DOCKER_LOOP_SIZE"
      printf '  内存分层: zram=%s (pri=%s, %s%% %s)  磁盘swap pri=%s  swappiness=%s(自动探测内核上限)\n' \
        "$ZRAM_MODE" "$ZRAM_PRIORITY" "$ZRAM_SIZE_PERCENT" "$ZRAM_ALGO" "$SWAP_PRIORITY" "$SWAPPINESS"
      printf '  风扇板型: %s  模式=%s  ★sysfs全局编号=%s（%s，高电平开=%s，LED联动=%s）\n' \
        "$FAN_BOARD" "$FAN_MODE" "$FAN_SYSFS_FAN" "$FAN_PIN_DESC" "$FAN_ACTIVE_HIGH" "$FAN_LED"
      printf '  备选: sysfs504=%s/LED %s,%s,%s  libgpiod=%s line %s (v%s)  已实测=%s\n' \
        "504" "$FAN_LED_BLUE" "$FAN_LED_RED" \
        "$FAN_LED_GREEN" "$FAN_GPIO_CHIP" "$FAN_GPIO_LINE" "$FAN_GPIOD_MAJOR" \
        "${FAN_CONFIRMED_PIN:-<未指定>}"
      printf '  内存=%s MiB(低内存阈值=%s)  面板OLED=★已移除（不再扫描 I2C）\n' \
        "$(mem_total_mib)" "$LOW_MEM_MIB"
      printf '  本地博客: :%s  目录=%s  站点配置=%s\n' "$PORT_BLOG" "$BLOG_DIR" "$BLOG_SITE"
      printf '  ttyd: :%s 仅本机 → nginx %s/ + 密码(用户=%s)\n' \
        "$TTYD_PORT" "$TTYD_PATH" "$TTYD_AUTH_USER"
      printf '  风扇实测: 风扇针脚测试.sh（默认 515，两轮确认后写服务）  候选 10 个安全引脚\n'
      printf '  组件选择（空=运行时询问）：\n'
      for _k in "${COMP_KEYS[@]}"; do
        _v="INSTALL_${_k^^}"; printf '    %-14s %-22s 默认=%s  eMMC≈%s\n' \
          "$_k" "${COMP_NAME[$_k]}" "${COMP_DEFAULT[$_k]}" "${COMP_SIZE[$_k]}"
      done
      for s in "${STEPS[@]}"; do
        IFS='|' read -r i d f o <<< "$s"
        printf '  [%s] %-46s %s\n' "$i" "$d" "$([[ "$o" != "-" ]] && echo "[可选:$o]" || echo "[必需]")"
      done
      return 0 ;;
  esac

  need_root
  mkdir -p "$(dirname "$BOOT_LOG")"

  # ★★ 交互能力必须在【日志重定向之前】判定并保存：
  #    下面那句 exec > >(tee ...) 会把 fd1 变成管道，从那一刻起 -t 1 恒为假。
  #    以前 tmux 判断写在重定向【之后】且要求 -t 1，于是【永远不会触发】——
  #    SSH 一断脚本就被 SIGHUP 杀掉，只能重连后靠断点续跑补救；同一个 -t 1
  #    还让 step_shares 的 whiptail 勾选界面从未出现过。
  #    这里用 -t 0（stdin 未被重定向，SSH 登录时是真 TTY）判交互，并把结果存进
  #    全局 NAS_INTERACTIVE，供后面的 whiptail / component_gate / probe_ask 使用。
  NAS_INTERACTIVE=0
  if [[ -t 0 && -r "$NAS_TTY" && -w "$NAS_TTY" ]]; then NAS_INTERACTIVE=1; fi

  # SSH 断线保护：自动放进 tmux；重连后 tmux attach -t armbian-nas
  # ★★ 本轮修复：判据【不再依赖任何环境变量】。
  #   以前要求 SSH_TTY 非空，但 sudo 默认 env_reset 只保留 TERM/PATH/HOME/
  #   SHELL/LOGNAME/USER 等最小集，SSH_TTY 会被清掉：
  #     root 直登 → 变量还在 → 保护生效；
  #     sudo ./armbian-nas-一键部署.sh → 变量为空 → 静默失效（不崩，只是没保护）。
  #   现在直接复用上面在【日志重定向之前】算好的 NAS_INTERACTIVE
  #   （-t 0 + /dev/tty 可读写），SSH pts 与物理串口 ttyAML0 都能进 tmux；
  #   另加 -z "${TMUX:-}" 防止在已有 tmux 里嵌套 new。
  #   验证：sudo bash -c 'echo SSH_TTY=$SSH_TTY'  为空也不影响断线保护。
  if [[ "$MODE" == "deploy" && "$NO_TMUX" -eq 0 && "${NAS_IN_TMUX:-0}" != "1" \
        && "$NAS_INTERACTIVE" -eq 1 && -z "${TMUX:-}" ]]; then
    # ★★ 真机反馈：旧版把 `command -v tmux` 写在外层 if 里，精简镜像上
    #    缺 tmux 就【整段静默跳过】——用户以为有断线保护，实际 SSH 一掉
    #    脚本被 SIGHUP 杀掉，只能靠断点续跑补救。这里改成主动补装兜底。
    #    此时还在 tee 重定向之前，输出直接打在终端；用 if ! ... 包住，
    #    set -e 不会因安装失败把整个脚本干掉。
    if ! command -v tmux >/dev/null 2>&1; then
      c_warn "★ 未检测到 tmux：SSH 断线保护会形同虚设，正在自动补装（只装这 1 个包）…"
      if ! apt_install tmux; then
        c_warn "  首次安装未成功，刷新 apt 索引后重试一次…"
        apt_update
        apt_install tmux || true
      fi
      if command -v tmux >/dev/null 2>&1; then
        c_ok "  tmux 已自动补装，本次运行具备断线保护"
        printf '%s [INFO] tmux 自动补装成功（步骤 02 之前）\n' \
          "$(date '+%F %T')" >> "$BOOT_LOG" 2>/dev/null || true
      else
        c_warn "  ★ tmux 自动补装失败：本次运行【没有 SSH 断线保护】，SSH 掉线会被 SIGHUP 杀掉"
        c_warn "    断线后直接重跑脚本即可从断点继续；也可手动：sudo apt-get update && sudo apt-get install -y tmux"
        c_warn "    步骤 02 的依赖清单里也有 tmux，装完系统后下次运行会自动进 tmux"
        printf '%s [WARN] tmux 自动补装失败，本次无断线保护\n' \
          "$(date '+%F %T')" >> "$BOOT_LOG" 2>/dev/null || true
      fi
    fi
    if command -v tmux >/dev/null 2>&1; then
      if tmux has-session -t armbian-nas 2>/dev/null; then
        c_warn "已存在部署会话 armbian-nas。重连查看：tmux attach -t armbian-nas"
        c_warn "若会话里脚本已退出，执行：tmux kill-session -t armbian-nas 后重跑，或用 --status 看进度"
        return 0
      fi
      c_info "检测到交互终端，自动进入 tmux；断线后重连：tmux attach -t armbian-nas"
      c_info "断线保护判据：NAS_INTERACTIVE=$NAS_INTERACTIVE、SSH_TTY=${SSH_TTY:-（空，已不依赖）}、TMUX=${TMUX:-（空）}"
      # ★★ 真机教训：tmux 里的命令一结束，窗口关闭会清屏，用户只看到 [exited]，
      #   完全看不到里面的 FAIL（ZeroTier 没装上就是这样被掩盖的）。
      #   进 tmux 之前先把「去哪看输出」打在屏幕上，这两行不会被清掉。
      c_info "★ tmux 窗口内全部输出同时写入 $BOOT_LOG；窗口一闪而过时直接：tail -80 $BOOT_LOG"
      c_info "★ 想让输出留在当前终端排查（推荐单个软件补装）：加 --no-tmux"
      c_info "  例如：sudo bash $SCRIPT_PATH --no-tmux --with-zerotier --redo=07"
      # 这两行还没被 tee 接管，直接补写一次日志，保证 BOOT_LOG 里有进 tmux 的记录
      printf '%s [INFO] 自动进入 tmux（参数 %d 个，原样透传）\n' \
        "$(date '+%F %T')" "${#TMUX_ARGS[@]}" >> "$BOOT_LOG" 2>/dev/null || true
      # ★ 必须用【全局】TMUX_ARGS：parse_args 里的局部数组早已失效，
      #   "${args[@]}" 会静默变成空，所有 --no-* / --redo= / --zt-network= 全丢。
      # ★ 包一层 bash -c：失败时【保留 tmux 窗口】，用户 attach 就能看到完整错误；
      #   成功时照常退出，不改变原有体验。rc 同时追加到 BOOT_LOG，便于事后查。
      #   $1=SCRIPT_PATH  $2=BOOT_LOG  $3..=原始参数（${@:3} 原样透传）
      exec env NAS_IN_TMUX=1 tmux new -s armbian-nas -- \
        bash -c '
          set +e
          bash "$1" "${@:3}"
          rc=$?
          printf "\n[%s] [INFO] tmux 内脚本结束：rc=%s（透传参数 %d 个）\n" \
            "$(date "+%F %T")" "$rc" "$(( $# - 2 ))" >> "$2" 2>/dev/null || true
          if (( rc != 0 )); then
            printf "\n===== ★ 脚本执行失败（rc=%s），窗口保留供排查 =====\n" "$rc"
            printf "完整日志：%s\n" "$2"
            printf "最后 30 行：tail -30 %s\n" "$2"
            printf "常用排查：tail -80 %s ; sudo bash %s --status\n" "$2" "$1"
            printf "本窗口不会关闭，排查完输入 exit 退出；断线重连：tmux attach -t armbian-nas\n"
            exec bash -l
          fi
          printf "\n[INFO] 脚本成功结束（rc=0）。窗口即将关闭；完整输出见 %s\n" "$2"
          exit 0
        ' _ "$SCRIPT_PATH" "$BOOT_LOG" "${TMUX_ARGS[@]}"
    fi
  fi

  exec > >(tee -a "$BOOT_LOG") 2>&1
  c_info "armbian-nas v$VERSION 启动：$(date '+%F %T')  主机=$(hostname)  架构=$(uname -m)"
  c_info "日志：$BOOT_LOG（挂载完成后同步到 $LOG_FILE）"
  c_info "交互终端：NAS_INTERACTIVE=$NAS_INTERACTIVE（1=可用 /dev/tty，0=非交互）"

  # 单实例锁
  if command -v flock >/dev/null 2>&1; then
    exec 9>/run/lock/armbian-nas-deploy.lock
    flock -n 9 || die "已有部署实例在运行。查看：tmux attach -t armbian-nas 或 bash $SCRIPT_PATH --status"
  fi

  [[ -f /etc/armbian-release ]] && c_info "系统：$(. /etc/armbian-release; echo "${BOARD_NAME:-Armbian} / ${VERSION:-}")" \
    || c_warn "未检测到 /etc/armbian-release，将按 Debian/Ubuntu 通用方式处理"

  # ★ 部署前先查根分区剩余（装软件发生在 apt 缓存外置之前），不足 1.5G 直接拦下
  preflight_root_space

  # 前置挂载：每次运行都做，幂等且不记入步骤状态
  ensure_mounts
  sync_log
  # ★ 统一凭据收敛（幂等；--creds=random 时整段跳过）
  sync_simple_creds

  # ★ 定向模式（--with-X --redo=N）跳过步骤 02，目标步骤仍需要基础目录/命令。
  #   这里幂等补齐，不装软件、不询问、不改状态（函数内部只在 MODE=deploy 生效）。
  targeted_prereqs

  if [[ "$MODE" == "reset" ]]; then
    : > "$STATE_FILE"
    cp -f "$STATE_FILE" "$MIRROR_FILE" 2>/dev/null || true
    c_info "已清空步骤状态，接下来全量重跑（不会卸载已装软件）"
  fi

  # ★ --check / --status 是只读模式：即使命令行带了 --redo / --from，
  #   也绝不清状态（否则「仅自检」会悄悄改动断点续跑记录）。
  if [[ "$MODE" == "check" || "$MODE" == "status" ]]; then
    c_info "只读模式（$MODE）：忽略本次的 --redo / --from，不改动任何步骤状态"
  # ★ 定向模式：先把最终步骤集合算出来（参数解析后、路径派生后都可用）
  elif [[ "$TARGETED" -eq 1 ]]; then
    local _k _st
    for _k in "${TARGET_COMPS[@]}"; do
      _st="$(step_for_component "$_k" 2>/dev/null || true)"
      [[ -n "$_st" ]] && TARGET_STEPS+=("$_st")
    done
    [[ -n "$REDO_ID" ]] && TARGET_STEPS+=("$REDO_ID")
    # --redo=11（重选共享目录）必须连带重建 12 MiniDLNA / 13 Samba，否则清单改了配置没改
    if [[ "$REDO_ID" == "11" ]]; then TARGET_STEPS+=(12 13); fi
    # --redo=03（重装 PHP）连带 04 站点配置
    if [[ "$REDO_ID" == "03" ]]; then TARGET_STEPS+=(04); fi
    # 去重（保留顺序）
    local -A _seen=(); local _u=()
    for _st in "${TARGET_STEPS[@]}"; do
      [[ -n "${_seen[$_st]:-}" ]] && continue
      _seen["$_st"]=1; _u+=("$_st")
    done
    TARGET_STEPS=("${_u[@]}")
    c_info "★ 定向模式：本次只执行步骤 [${TARGET_STEPS[*]}]，其它步骤一律跳过（不询问、不改写状态）"
    reset_only "${TARGET_STEPS[@]}"
  elif [[ -n "$REDO_ID" ]]; then
    reset_from "$REDO_ID"
  elif [[ -n "$FROM_ID" ]]; then
    reset_from "$FROM_ID"
  fi
  if [[ "$RESELECT" -eq 1 ]]; then rm -f "$SHARES_FILE"; c_info "共享目录清单已清除，步骤 11 会重新选择"; fi

  if [[ "$MODE" == "check" ]]; then
    final_check; return $?
  fi
  if [[ "$MODE" == "repair" ]]; then
    do_repair; return $?
  fi
  if [[ "$MODE" == "uninstall" ]]; then
    do_uninstall; return $?
  fi

  # ★ 无论步骤 20 是不是 done，都无条件做一次 OLED 安全清理：
  #   旧机器上 20=done 会被 run_step 跳过，残留服务开机后仍可能访问 I2C。
  #   oled_cleanup 只停服务/删单元，不碰任何硬件总线。
  oled_cleanup

  local s id desc func opt
  for s in "${STEPS[@]}"; do
    IFS='|' read -r id desc func opt <<< "$s"
    # ★ 定向模式：非目标步骤【完全不碰】——不调用 run_step，
    #   于是不会触发 component_gate 的交互询问，也不会把状态写成 skip。
    if [[ "$TARGETED" -eq 1 ]] && ! in_target_steps "$id"; then
      c_info "[$id] 定向模式：跳过 $desc（保持原状态不变）"
      continue
    fi
    run_step "$id" "$desc" "$func" "$opt"
  done

  c_step "全部步骤执行完毕，开始最终自检"
  final_check
}

trap 'sync_log' EXIT
main
