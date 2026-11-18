# armbian-nas · Armbian 小主机 NAS 一键部署脚本

> 一个面向 ARM 小主机的**可选择性安装、可断点续跑、可逐项卸载**的 NAS / 下载机 / 媒体库部署脚本。
> 本文件可直接作为 GitHub 仓库的 `README.md` 使用；脚本会把它发布成 `http://<本机IP>/docs.html`，局域网内浏览器直接看，不用开 SSH。

| 项目 | 说明 |
|---|---|
| 主脚本 | `armbian-nas-一键部署.sh` |
| 文档 | `armbian-nas-使用说明.md`（本文） |
| 可选随附 | `prober.php`（完整 PHP 环境探针）、`风扇针脚测试.sh`（风扇两轮实测） |
| 运行方式 | 必须 root / `sudo` |
| 部署形态 | 单脚本、23 个步骤、状态文件断点续跑、组件逐个询问装不装 |
| 数据位置 | 网站、日志、数据库、下载、容器配置全部落在**外置硬盘**，不动盘上原有文件 |

---

## 一、这个脚本是什么

它把一台刷了 Armbian 的 ARM 小主机，部署成一台**家庭局域网 NAS**：

- Web 服务器（nginx）+ 严格锁定 **PHP 8.2** + 你指定的全套扩展 + SQLite3；
- 下载器 qBittorrent / Transmission（**apt 原生安装，不放进 Docker**）、aria2 + AriaNg 网页界面；
  Transmission 可在部署时选择换成**简体中文增强界面 TrguiNG 汉化版**（更多设置项）；
- 文件管理：FileBrowser 网页文件管理器、微力同步、Samba 共享、MiniDLNA 媒体库；
- 网页终端 ttyd（浏览器里直接开 shell，不用每次 SSH）；
- 可选 Docker 引擎 + Portainer Web 管理界面、ZeroTier 内网穿透、图形界面；
- 硬件层：CPU 温度控制风扇（≥50℃ 开 / ≤48℃ 关）、空闲硬盘休眠、zram 优先于磁盘 swap；
- 一个白色导航页、一个独立状态页、一个在线文档页、一个完整 PHP 探针、一个本地博客站点。

### 部署完成后你会得到什么

1. 打开 `http://<本机IP>/`：**白色导航页**，所有常用 Web 界面一键直达（新标签页打开）。
2. 打开 `http://<本机IP>/status.html`：**独立状态页**，每个软件一张卡片，含安装/运行状态、版本号、预计 eMMC 占用、访问入口、SSH 启停/重启/日志命令、默认密码、程序/配置/网页/数据/日志路径；**每张卡片最后一条是「本脚本一键安装 / 重装 / 修复该软件」的完整 SSH 命令**，复制即可执行。
3. 打开 `http://<本机IP>/docs.html`：本文的在线版，带左侧目录和全文搜索，纯静态、无 CDN、离线可用。
4. 打开 `http://<本机IP>/prober.php`：X-Prober 风格的完整 PHP 环境探针；`/probe.php` 是分区表格化的扩展逐项核对页。
5. 打开 `http://<本机IP>:81/`：独立的本地博客站点（目录 `boke`，放进 Typecho / WordPress 即可用）。
6. 局域网播放器搜索 `armbian-nas` 能发现 DLNA 视频；Windows 资源管理器输入 `\\<本机IP>\` 能看到 Samba 共享。
7. `http://<本机IP>:9091/` 若部署时选了 `y`，就是**简体中文的 TrguiNG 增强界面**（目录分组、Tracker 过滤、批量改 tracker、多链接下载等），而非官方英文 WebUI。
8. 内网自用统一凭据：ttyd / aria2 RPC 为 **admin / admin**，FileBrowser 为 **admin / adminadmin123**（上游强制密码 ≥12 位）；指定装某个软件时只装那一个，不会再把 Docker / 图形界面 / 网页终端挨个问一遍。
7. 终端里 `sudo ./armbian-nas-一键部署.sh --check` 会打印**所有软件的安装、运行、配置状态表**，并写一份最终报告。

### 设计原则

- **不格式化、不改动外置硬盘已有数据**。电影等原文件原样保留，只在 `/mnt/sda1/www/` 下新建目录。
- **系统盘只放程序，增长型数据全在外置盘**：网站根目录、nginx/php/samba 日志、SQLite 库、下载 complete/incomplete/watch、容器 `/config`、微力同步索引、MiniDLNA 数据库、aria2 会话、apt 缓存与 lists。
- **每个软件都能选装或跳过**：跑到某一步会显示预计占用的 eMMC 空间和当前内存余量，输入 `n` 跳过；下次运行会再问，想装时输入 `y` 即可。
- **断线可恢复**：SSH 掉线自动进 `tmux`，`tmux attach -t armbian-nas` 继续看；每一步都有状态记录，重跑自动接着没做完的地方走。**精简镜像若没装 `tmux`，脚本会在进会话前自动补装**，不再静默跳过保护。
- **不猜硬件**：风扇引脚必须两轮人工实测（先确认「开→转」，再确认「关→停」）才写 systemd 服务；ZeroTier 网络 ID 需要你提供。

---

## 二、兼容性与实测环境

### 2.1 已实测平台

> 原话：「我是的设备是比特米盒（CumeBox2）安装的vim1开发板的系统。这个脚本是在全新的系统下进行部署。」

规范描述：硬件为 **比特米盒 CumeBox2**（Amlogic S905X），刷 **Khadas VIM1 开发板的 Armbian 镜像**，在**全新系统**下一次性部署。

| 项 | 实测值 |
|---|---|
| 发行版 | Armbian **26.8.11 resolute**（Ubuntu **26.04**，`VERSION_CODENAME=resolute`） |
| 内核 | `6.18.57-current-meson64`，`aarch64` |
| PHP | 8.2.35（Sury 的 `ubuntu26.04` 包，脚本检测到已在位会跳过补源） |
| 内存 | 911 MiB，系统自带 zram 已启用（`/var/log` 挂在 zram1） |
| GPIO | `/sys/class/gpio` 下 `gpiochip512`(AO 域) + `gpiochip523`(Periphs 域)，风扇实测 **sysfs 全局编号 515** |
| CPU 温度 | 部署时 57℃ |
| 8G eMMC 部署后 | 7.0G 用 **2.1G** / 剩 **4.9G** / **30%** |
| 外置盘 | `/dev/sda1` 466G（剩 13G）、`/dev/sdb1` 466G（剩 14G），均为 NTFS，盘上原有电影 |

### 2.2 支持矩阵

| 类别 | 支持范围 | 说明 |
|---|---|---|
| 发行版 | Armbian（Ubuntu 系 / Debian 系）、Ubuntu、Debian | 依赖 `apt`、`systemd`、`bash`；脚本按 `VERSION_CODENAME` 运行时探测，不写死版本 |
| 已验证 | Ubuntu 26.04 / Armbian 26.8.11 resolute | 见上表 |
| 兼容举例 | Debian 11/12/13、Ubuntu 22.04/24.04 系、Armbian 23.x | 老镜像举例；系统源没有 PHP 8.2 时自动加 Sury 仓库 |
| 架构 | `aarch64` / `arm64` / `armv7` | 静态二进制与 Docker 镜像按架构选择 |
| 内核 | 5.10 及以上 | 需要内核 `ntfs3` 驱动（失败自动降级 `ntfs-3g`）、sysfs GPIO；`vm.swappiness > 100` 需 ≥5.8，脚本实测失败自动回落 |
| 外置盘 | NTFS（默认内核 ntfs3，个别卷自动降级 ntfs-3g）、ext4、xfs | `sda1` 为主盘、`sdb1` 为可选第二块盘；**绝不格式化** |
| 权限 | root 或 sudo | 需要写 `/etc`、`systemctl`、挂载点 |

### 2.3 不适用 / 明确边界

| 场景 | 结论 |
|---|---|
| 非 systemd 系统（OpenWrt、Alpine、容器里） | 不支持 |
| 非 Debian/Ubuntu 系（CentOS、Arch） | 不支持，`apt_install` 会失败 |
| 没有外置硬盘 | 不支持：脚本的设计前提就是数据落外置盘 |
| 把 Docker 数据目录直接放 NTFS | 不支持：`overlay2` 需要 `d_type`/`xattr`，脚本提供 ext4 loop 镜像方案 |
| 把 swapfile 放到 NTFS 移动硬盘 | 不支持：`swapon` 会因「文件有洞」失败；512M swap 留 eMMC 或改用 zram |
| 面板 OLED（SSD1306） | **已整体移除**：实测扫描 I2C 总线会踩到 PMIC / 以太网 PHY，导致盒子掉线、整个路由器内网断连、需拔电重启。脚本不再装 `i2c-tools`、不再调用 `i2cdetect`、不改 dtb |
| `disable_functions` 全局加固 | 脚本保持为空，只做「不能禁」白名单冲突检查；`eval` 是语言结构，禁不了 |

### 2.4 硬件前提

1. 一台能跑 Armbian 的 ARM 小主机，建议 ≥1 GiB 内存、≥8 GB 系统盘。
2. 一块通过 USB 转 SATA 接入的 NTFS 移动硬盘（示例 500G，盘上可以有电影等原有数据），设备名为 `/dev/sda1`；可选第二块 `/dev/sdb1`。
3. 首次部署前确认根分区剩余 ≥1.5G（脚本会在挂载外置盘**之前**自动检查）。
4. 风扇为 GPIO 电平控制（非 PWM）；若没有可控风扇，跑到步骤 14 输入 `n` 跳过。

---

## 三、快速开始

### 3.1 文件放在一起

```bash
# 建议把这四个文件放在同一个目录（例如 /root/）
#   armbian-nas-一键部署.sh   主脚本
#   armbian-nas-使用说明.md   本文（会发布成 /docs.html）
#   prober.php                X-Prober 完整 PHP 探针（可选，随包交付）
#   风扇针脚测试.sh           风扇两轮实测（可选）
sudo cp armbian-nas-一键部署.sh armbian-nas-使用说明.md prober.php 风扇针脚测试.sh /root/
sudo chmod +x /root/armbian-nas-一键部署.sh
```

> 只传主脚本也能跑：会自己生成内置 PHP 探针与兜底在线文档。带上 `prober.php` 会优先使用完整的 X-Prober；带上 `.md` 会发布完整在线文档。

### 3.2 首次部署（省 eMMC 的推荐命令）

```bash
sudo ./armbian-nas-一键部署.sh --no-docker --no-gui
```

这条命令跳过 Docker 与图形界面，是 8G eMMC 小主机最稳妥的组合。脚本会逐个询问其余组件，回车=安装，输入 `n`=跳过。

> 跑到**步骤 09（Transmission）**时还会多问一句「是否安装中文增强界面？`[Y/n]`」——**输入 `y` 或直接回车**即拉取 `github.com/jayzcoder/TrguiNG` 的中文 WebUI 静态包整合进去；输入 `n` 保留官方英文界面。详见 5.4.1 节。

想在全新系统上把所有可选组件都装上：

```bash
sudo ./armbian-nas-一键部署.sh --all-yes
```

### 3.3 部署后验证

```bash
df -h /
sudo ./armbian-nas-一键部署.sh --check
curl -I http://127.0.0.1/
curl -I http://127.0.0.1/status.html
curl -I http://127.0.0.1/docs.html
sudo ./armbian-nas-一键部署.sh --status
```

### 3.4 常用入口（完整命令）

| 用途 | 完整命令 |
|---|---|
| 查看进度 / 断点续跑 | `sudo ./armbian-nas-一键部署.sh --status` |
| 直接续跑（自动接着跑） | `sudo ./armbian-nas-一键部署.sh` |
| 仅自检（不改软件、不改步骤状态；统一凭据会幂等对齐一次） | `sudo ./armbian-nas-一键部署.sh --check` |
| 一键修复自检里的 FAIL | `sudo ./armbian-nas-一键部署.sh --repair` |
| 重建导航页 + 状态页 | `sudo ./armbian-nas-一键部署.sh --redo=18` |
| ★ 只装 / 重装一个软件（定向模式） | `sudo ./armbian-nas-一键部署.sh --with-filebrowser --redo=22` |
| ★ 只重跑一个步骤（定向模式） | `sudo ./armbian-nas-一键部署.sh --tr-webui=trguing --redo=09` |
| 恢复随机密钥（不再统一 admin/admin） | `sudo ./armbian-nas-一键部署.sh --creds=random --redo=21`（再分别对 10 / 22 重跑） |
| 查看全部参数 | `sudo ./armbian-nas-一键部署.sh --help` |
| 只打印配置与步骤清单 | `sudo ./armbian-nas-一键部署.sh --dry-run` |
| SSH 断线后重连 | `tmux attach -t armbian-nas` |

> 下文所有命令默认在脚本所在目录执行。若脚本放在 `/root/`，请写成 `sudo /root/armbian-nas-一键部署.sh ...`。

> **★ 定向模式（真机反馈修复）**：命令行一旦带 `--with-<组件>` 或 `--redo=<步骤>`，脚本就**只执行目标步骤**，然后末尾自动重建导航页 + 状态页并跑自检。
> 不会再把「上次选了跳过」的 Docker / 图形界面 / ttyd 弹出来重新问，也**绝不改写其它组件的状态**（旧版会把已装好的 ttyd 误写成"已跳过"）。
> 只有**不带这些参数、直接运行** `sudo ./armbian-nas-一键部署.sh` 的一键部署，才逐个询问所有可选组件。
> 例外：`--redo=11`（重选共享目录）会连带重建 12 MiniDLNA / 13 Samba；`--redo=03`（重装 PHP）会连带 04 站点配置。`--from=N` 仍保留"从 N 跑到尾"的原语义。

---

## 四、功能清单（23 个步骤）

| 步骤 | 功能 | 可选 | 端口 / 入口 | 数据与配置落点 | 预计 eMMC 占用 |
|---|---|---|---|---|---|
| 01 | 准备外置盘目录结构 | 否 | — | `/mnt/sda1/www/{web,logs,db,downloads,...}` | 0 |
| 02 | 基础依赖与工具（含 `tmux`，断线保护必备） | 否 | — | 系统盘 | 几 MiB |
| 03 | nginx + **PHP 8.2** + 指定扩展 + SQLite3 | 否 | :80 | 系统盘；站点数据外置 | ~70 MiB |
| 04 | 网站根目录、探针、日志重定向 | 否 | :80 | `$BASE/web`、`$BASE/logs/nginx` | ~1 MiB |
| 05 | Docker 引擎 + Portainer Web 管理 | **是** | `:9000` | `/var/lib/docker`、`$BASE/portainer` | ~350 MiB + 镜像层 |
| 06 | 微力同步 Verysync | **是** | `:8886` | `$BASE/verysync` | ~30 MiB |
| 07 | ZeroTier 内网穿透 | **是** | 9993/udp | `/var/lib/zerotier-one` | ~15 MiB |
| 08 | qBittorrent-nox（apt 原生） | **是** | `:8080` | `$BASE/qb`、`$BASE/downloads` | ~90 MiB |
| 09 | Transmission（apt 原生）+ 可选中文增强 WebUI | **是** | `:9091` | `$BASE/transmission`、`$BASE/downloads`、`$BASE/webui/trguing-zh` | ~25 MiB（中文包 349 KB 在外置盘，不占 eMMC） |
| 10 | aria2 + AriaNg | **是** | `/ariang/`、`/jsonrpc`、6800 | `$BASE/aria2`、`$BASE/web/ariang` | ~15 MiB |
| 11 | 选择共享目录（可交互勾选） | 否 | — | `$BASE/config/shares.txt` | 0 |
| 12 | MiniDLNA 媒体库 | **是** | `:8200` | `$BASE/minidlna/db` | ~10 MiB |
| 13 | Samba 共享 | **是** | 445/139 | `/etc/samba/smb.conf` | ~60 MiB |
| 14 | CPU 温度控制风扇 | **是** | 无界面 | `/etc/default/armbian-fan`、`$BASE/logs/fan.log` | ~0 |
| 15 | 空闲硬盘休眠 | **是** | 无界面 | `/etc/default/hd-idle` | ~2 MiB |
| 16 | 防火墙放通局域网端口 | 否 | — | ufw 规则 | 0 |
| 17 | XFCE + xrdp 图形界面 | **是** | `:3389` | 系统盘 | **1–2 GiB（不建议）** |
| 18 | 生成导航页 + 独立状态页 + 在线文档 | 否 | :80 | `$BASE/web/` | ~1 MiB |
| 19 | eMMC 瘦身与 PHP 安全基线 | 否 | — | journald / sysctl / apt 缓存 | 释放空间 |
| 20 | 清理旧版面板 OLED 残留 | 否 | — | 只停服务删单元 | 0 |
| 21 | ttyd 网页终端（默认装） | **是** | `/ttyd/`（80 反代） | `$BASE/ttyd` | ~1 MiB |
| 22 | FileBrowser 文件管理器 | **是** | `:8082` | `$BASE/filebrowser` | ≈15 MiB |
| 23 | 本地博客站点 | 否 | `:81` | `$BASE/boke` | 0（复用 nginx） |

> `$BASE` 默认是 `/mnt/sda1/www`。所有标「外置」的路径都在这块盘上，重装系统不会丢。

### 端口一览

| 端口 | 服务 |
|---|---|
| 80 | 导航页 / 状态页 / 在线文档 / AriaNg / ttyd 反代 / 探针 / 动态磁盘与主机信息接口 |
| 81 | 本地博客（独立 nginx server 块，不写 `default_server`） |
| 8080 / 9091 | qBittorrent / Transmission WebUI（9091 可切 TrguiNG 中文增强界面） |
| 8886 / 8200 / 8082 | 微力同步 / MiniDLNA / FileBrowser |
| 9000 | Portainer（Docker Web 管理，装 Docker 时自动部署） |
| 6800 / 7681 | aria2 RPC / ttyd（**两者只听 127.0.0.1**，外部经 nginx 反代） |
| 445 / 139 / 1900udp / 9993udp | Samba / DLNA / ZeroTier |

---

## 五、每个模块的完整命令

### 5.1 部署、续跑与自检

```bash
sudo ./armbian-nas-一键部署.sh --no-docker --no-gui          # 首次部署（推荐）
sudo ./armbian-nas-一键部署.sh                                # 断点续跑
sudo ./armbian-nas-一键部署.sh --status                       # 只看步骤状态
sudo ./armbian-nas-一键部署.sh --check                        # 全量自检表 + 最终报告
sudo ./armbian-nas-一键部署.sh --repair                       # 幂等重建配置，修完自动复查
sudo ./armbian-nas-一键部署.sh --redo=03                      # 从步骤 03 起重跑
sudo ./armbian-nas-一键部署.sh --dry-run                      # 只看配置与 23 步清单
sudo ./armbian-nas-一键部署.sh --help                         # 全部参数
sudo ./armbian-nas-一键部署.sh --reset                        # 清空步骤状态，全量重跑（不卸软件）
```

`--repair` 的边界：**不重装软件、不重新询问组件选择、不删数据、不格式化**；跳过的组件保持跳过。

### 5.2 选装 / 跳过 / 重装 / 卸载（逐组件）

每个软件跑到自己那一步会问一次；`--with-<组件>` 直接装（不再询问），`--no-<组件>` 直接跳过，`--uninstall=<组件>` 卸载。
**状态页 `/status.html` 里每张卡片最后一条已经按组件生成好了完整命令，直接复制即可。**

| 组件 | 步骤 | 一键安装 / 重装 / 修复的完整命令 | 跳过 | 卸载 |
|---|---:|---|---|---|
| Docker + Portainer | 05 | `sudo ./armbian-nas-一键部署.sh --with-docker --redo=05` | `--no-docker` | `--uninstall=docker` |
| 微力同步 | 06 | `sudo ./armbian-nas-一键部署.sh --with-verysync --redo=06` | `--no-verysync` | `--uninstall=verysync` |
| ZeroTier | 07 | `sudo ./armbian-nas-一键部署.sh --with-zerotier --redo=07` | `--no-zerotier` | `--uninstall=zerotier` |

> **ZeroTier 安装顺序（针对 Ubuntu 26.04 resolute / Armbian 26.8.11）**：先 `apt install -y zerotier-one`（不受发行版 codename 影响），源里没有才用 `install.zerotier.com` 官方脚本兜底，并把脚本输出写入 `/mnt/sda1/www/logs/zerotier-install.log`。官方脚本按 codename 拼仓库地址，对新版本曾出现 `Unknown or unsupported distribution! Aborting`；装完若 `systemctl` 里仍找不到 `zerotier-one.service`，脚本会明确打印诊断与手动补装命令，不会静默失败。
| qBittorrent | 08 | `sudo ./armbian-nas-一键部署.sh --with-qb --redo=08` | `--no-qb` | `--uninstall=qb` |
| Transmission | 09 | `sudo ./armbian-nas-一键部署.sh --with-transmission --redo=09` | `--no-transmission` | `--uninstall=transmission` |
| aria2 + AriaNg | 10 | `sudo ./armbian-nas-一键部署.sh --with-aria2 --redo=10` | `--no-aria2` | `--uninstall=aria2` |
| MiniDLNA | 12 | `sudo ./armbian-nas-一键部署.sh --with-minidlna --redo=12` | `--no-minidlna` | `--uninstall=minidlna` |
| Samba | 13 | `sudo ./armbian-nas-一键部署.sh --with-samba --redo=13` | `--no-samba` | `--uninstall=samba` |
| 风扇温控 | 14 | `sudo ./armbian-nas-一键部署.sh --with-fan --redo=14 --fan-confirmed=515` | `--no-fan` | `--uninstall=fan` |
| 硬盘休眠 | 15 | `sudo ./armbian-nas-一键部署.sh --with-hd_idle --redo=15` | `--no-hd_idle` | `--uninstall=hd_idle` |
| 图形界面 | 17 | `sudo ./armbian-nas-一键部署.sh --with-gui --redo=17` | `--no-gui` | `--uninstall=gui` |
| ttyd 网页终端 | 21 | `sudo ./armbian-nas-一键部署.sh --with-ttyd --redo=21` | `--no-ttyd` | `--uninstall=ttyd` |
| FileBrowser | 22 | `sudo ./armbian-nas-一键部署.sh --with-filebrowser --redo=22` | `--no-filebrowser` | `--uninstall=filebrowser` |
| nginx + PHP 8.2 | 03 | `sudo ./armbian-nas-一键部署.sh --redo=03` | 必需 | 不提供 |
| 网站 / 探针 / 日志 | 04 | `sudo ./armbian-nas-一键部署.sh --redo=04` | 必需 | 不提供 |
| 共享目录清单 | 11 | `sudo ./armbian-nas-一键部署.sh --shares='/mnt/sda1/电影,/mnt/sdb1/影视' --redo=11` | 必需 | 不提供 |
| 导航页 + 状态页 | 18 | `sudo ./armbian-nas-一键部署.sh --redo=18` | 必需 | 不提供 |
| 瘦身 / 安全基线 | 19 | `sudo ./armbian-nas-一键部署.sh --redo=19` | 必需 | 不提供 |
| 本地博客 | 23 | `sudo ./armbian-nas-一键部署.sh --redo=23` | 必需 | 不提供 |

#### 5.2.1 统一凭据（内网自用版默认）

| 软件 | 账号 / 密码 | 说明 |
|---|---|---|
| ttyd 网页终端 | `admin / admin` | nginx basic auth |
| aria2 RPC 密钥 | `admin` | AriaNg → 设置 → RPC |
| **FileBrowser** | **`admin / adminadmin123`** | **上游强制 ≥12 位**，不能设成 `admin` |

首页与状态页卡片直接显示明文，不用再查 `secrets.env`。脚本在每次运行开头幂等收敛这三把密钥，并同步 `aria2.conf`、nginx 的 `.ttydpasswd` 哈希、`filebrowser.db` 里的账号（值不一致才动，一致时零中断）。

> **为什么 FileBrowser 不能统一成 `admin / admin`**：FileBrowser v2.6x 起 `users add/update --password` 强制**密码至少 12 位**，`admin`(5 位)、`adminadmin`(10 位) 都会报 `Error: password is too short, minimum length is 12`。旧版脚本把 5 位 `admin` 写进去，三条建号命令全被拒，最后静默退化成 `no_auth` 免密登录，状态页却仍显示 `admin / admin` —— 属于「假配置」。现在默认用 13 位、仍是 admin 系、好记的 `adminadmin123`；可用 `sudo ./armbian-nas-一键部署.sh --fb-password=你的12位以上密码 --redo=22` 自定义，短于 12 位会在部署前被脚本拦下。

```bash
# 完整命令：自定义 FileBrowser 密码（必须 ≥12 位）
sudo ./armbian-nas-一键部署.sh --fb-password=adminadmin123 --redo=22
# 恢复随机密钥（三处都变随机）
sudo ./armbian-nas-一键部署.sh --creds=random --redo=21
```

**三处由上游机制决定、脚本不擅自改**：qB 首次仍是 `admin / adminadmin`（WebUI 里可改成 admin）、Transmission 默认免密（改 `settings.json`）、Portainer 首次自行创建密码。状态页逐条给了改密命令。

> **FileBrowser 改密必须按顺序执行三条**（它的 `filebrowser.db` 是 bbolt 独占锁）：

```bash
sudo systemctl stop armbian-filebrowser
sudo filebrowser -d /mnt/sda1/www/filebrowser/filebrowser.db users update admin --password 至少12位的新密码
sudo systemctl start armbian-filebrowser
```

> ⚠ 新密码必须 **≥12 位**，否则会报 `Error: password is too short, minimum length is 12`（这个校验在打开数据库之前，连 timeout 都遇不到就被拒）。

不能写成 `filebrowser ... users update ... && sudo systemctl restart ...`：服务运行时 CLI 拿不到数据库锁，会报 `Error: timeout`，密码没改成功，`&&` 后面的 restart 也不会执行。

#### 5.2.2 定向模式：指定软件只装该软件

```bash
sudo ./armbian-nas-一键部署.sh --with-filebrowser --redo=22   # 只装 FileBrowser
sudo ./armbian-nas-一键部署.sh --with-qb                      # 只装 qBittorrent（自动定位到步骤 08）
sudo ./armbian-nas-一键部署.sh --redo=18                     # 只重建导航页 + 状态页
sudo ./armbian-nas-一键部署.sh --tr-webui=trguing --redo=09  # 只给 Transmission 换中文界面
```

行为：非目标步骤打印一行「定向模式：跳过…（保持原状态不变）」后完全不碰；目标步骤不再弹「是否安装」；末尾照常重建两页并跑自检。`--redo=22` 只清 22 自身的状态，不会像旧版那样把 23 本地博客也重跑一遍。

批量控制：

```bash
sudo ./armbian-nas-一键部署.sh --all-yes                     # 所有可选组件都装，不逐个问
sudo ./armbian-nas-一键部署.sh --all-no                      # 所有可选组件都跳过
sudo ./armbian-nas-一键部署.sh --no-docker --no-transmission # 永久跳过（本次）
sudo ./armbian-nas-一键部署.sh --reselect                    # 已跳过的重新询问
sudo ./armbian-nas-一键部署.sh --uninstall                   # 交互菜单逐个卸载
sudo ./armbian-nas-一键部署.sh --uninstall=filebrowser       # 直接卸一个
sudo ./armbian-nas-一键部署.sh --uninstall-all               # 卸全部可选组件
```

> **卸载默认保留外置盘数据**，只删程序与服务；确需连数据一起删才加 `--purge-data`（危险，先备份）。

### 5.3 网站、PHP 8.2 与探针

```bash
sudo ./armbian-nas-一键部署.sh --redo=03                      # 重装 nginx + PHP 8.2 + 扩展
sudo ./armbian-nas-一键部署.sh --redo=04                      # 重建站点 / probe.php / 日志软链
sudo ./armbian-nas-一键部署.sh --redo=18                      # 重建导航页 / 状态页 / 在线文档 / prober.php
sudo ./armbian-nas-一键部署.sh --blog-port=8081 --blog-dir=/mnt/sda1/boke --redo=23
sudo ./armbian-nas-一键部署.sh --no-pecl                     # 跳过第三方扩展 pecl 编译兜底
sudo ./armbian-nas-一键部署.sh --prober-php=/绝对路径/prober.php --redo=18
php8.2 -m | sort                                            # CLI 侧扩展
curl -fsS http://127.0.0.1/probe.php | grep PHP_EXT_ALL_OK  # 网页真实环境逐项核对
```

浏览器入口：`/prober.php`（完整环境探针）、`/probe.php`（扩展核对）、`/status.php`（备用状态页）、`/docs.html`（本文在线版）、`/armbian-nas-使用说明.md`（原始 Markdown）。

### 5.4 下载器

```bash
sudo ./armbian-nas-一键部署.sh --with-qb --redo=08
sudo ./armbian-nas-一键部署.sh --with-transmission --redo=09
sudo ./armbian-nas-一键部署.sh --with-aria2 --redo=10
sudo journalctl -u qbittorrent-nox -n 50                     # qB 首次/临时密码也在这里
sudo journalctl -u qbittorrent-nox | grep -i password
grep ARIA_RPC_SECRET /mnt/sda1/www/.deploy/secrets.env       # AriaNg RPC 密钥
```

- qB 默认 `admin / adminadmin`；显示 `Unauthorized` 是它自己的登录认证，不是故障。
- `:8080` 是 qB 的 WebUI，**不是网页终端**；网页终端走 80 端口的 `/ttyd/`。
- qB / Transmission 是 apt 原生安装，配置、WebUI 静态文件、下载目录都在 `$BASE` 下，不依赖 Docker。

#### 5.4.1 Transmission 中文增强界面（TrguiNG 汉化版）

官方自带 WebUI 是英文且功能较简。部署到步骤 09 会出现一个选择：

```text
[Transmission 界面选择] 中文增强 WebUI（TrguiNG 汉化版）
  是否安装中文增强界面？ 直接回车 / y = 安装，输入 n = 保留官方英文  [Y/n]
```

**输入 `y`（或直接回车）** 即整合简体中文增强界面：目录分组、Tracker 二级过滤、批量改 tracker、多链接下载、字体大小调整、分享率精度等更多设置。

| 用途 | 完整命令 |
|---|---|
| 装 / 重装中文增强界面（不再询问） | `sudo ./armbian-nas-一键部署.sh --tr-webui=trguing --redo=09` |
| 切回官方英文界面（不删中文包） | `sudo ./armbian-nas-一键部署.sh --tr-webui=official --redo=09` |
| 重新询问（清除上次选择） | `sudo ./armbian-nas-一键部署.sh --tr-webui=ask --redo=09` |
| 离线补装（GitHub 不可达时） | `sudo ./armbian-nas-一键部署.sh --tr-webui-zip=/路径/trguing-web-v1.3.0-zh-240607a.zip --redo=09` |
| 指定 release 版本 | `sudo ./armbian-nas-一键部署.sh --tr-webui-tag=trguing-web-v1.3.0-zh-240607a --redo=09` |
| GitHub 下载加速 | `sudo ./armbian-nas-一键部署.sh --github-mirror=https://ghproxy.net/ --redo=09` |
| 查看当前界面与版本记录 | `cat /mnt/sda1/www/.deploy/tr-webui.version` |
| 看 drop-in 里指向哪个目录 | `grep TRANSMISSION_WEB_HOME /etc/systemd/system/transmission-daemon.service.d/10-armbian-nas.conf` |

实现要点（写在这里方便排查）：

- 来源 **https://github.com/jayzcoder/TrguiNG** （基于 **https://github.com/openscopeproject/TrguiNG** 汉化并增加功能，**AGPL-3.0**，署名见第十五章）。
- 拉的是 release 里**已编译好的 WebUI 静态包** `trguing-web-*-zh-*.zip`（约 349 KB），解压到 `$BASE/webui/trguing-zh`。**不在 1G 内存小主机上跑 `npm install` / Rust 编译**——上游构建要求 Node.js 16+ 与 Rust 1.69+，在这台机器上必然 OOM。
- 用 Transmission 官方支持的 `TRANSMISSION_WEB_HOME` 环境变量切换（systemd drop-in），`index.html` 直接放在该目录下（脚本会自动把压缩包里多套的一层目录拍平）。**不改 `settings.json`、不覆盖 `/usr/share/transmission/web`、不动 RPC 与下载配置**。
- GitHub 不可达时只 WARN 并保留官方英文界面，**不会让步骤 09 失败**；自检里该项标 `SKIP` 而不是 `FAIL`。用离线包或加速前缀补装即可。
- 界面选择会记在 `$BASE/.deploy/tr-webui.choice`，以后重跑默认沿用；只有显式传 `--tr-webui=ask --redo=09` 才会清掉记录重新询问。
- 首次打开 `http://<本机IP>:9091/` 若还是英文，按 `Ctrl+F5` 强刷浏览器缓存。
- 卸载 Transmission 时中文界面包与选择记录都会保留在 `$BASE`，重新 `--with-transmission --redo=09` 会直接沿用。

> 自检里这一项有四种显示：`OK`（中文界面已生效）、`SKIP 已选择保留官方英文`、`SKIP GitHub 下载失败仍用英文`、`SKIP 尚未部署`。只有第一种会真正检查 `index.html` + 静态资源 + drop-in 指向。

### 5.5 文件共享、媒体库与文件管理

```bash
sudo ./armbian-nas-一键部署.sh --shares='/mnt/sda1/电影,/mnt/sdb1/影视' --redo=11
sudo ./armbian-nas-一键部署.sh --with-minidlna --redo=12
sudo ./armbian-nas-一键部署.sh --with-samba --redo=13
sudo ./armbian-nas-一键部署.sh --with-filebrowser --redo=22
sudo ./armbian-nas-一键部署.sh --with-verysync --redo=06
sudo systemctl restart smbd nmbd minidlna
```

脚本会为**每块外置盘**分别挑选共享目录并写进 `smb.conf`（`[video-01]`…）；已有配置一致时不会覆盖、不会重启服务。FileBrowser 根目录是 `/mnt`，两块外置盘都能浏览。

### 5.6 网络与内网穿透

```bash
sudo ./armbian-nas-一键部署.sh --with-zerotier --redo=07
sudo ./armbian-nas-一键部署.sh --zt-network=<16位网络ID> --redo=07
sudo zerotier-cli info
sudo zerotier-cli listnetworks
```

加入私有网络后还需到 `https://my.zerotier.com/` 勾选授权本机，否则显示 `ACCESS_DENIED`。

### 5.7 Docker 与 Portainer

```bash
sudo ./armbian-nas-一键部署.sh --with-docker --redo=05             # 装引擎并自动带 Portainer
sudo ./armbian-nas-一键部署.sh --no-portainer                       # 装 Docker 但不带 Web 管理（省镜像层）
sudo ./armbian-nas-一键部署.sh --portainer-port=9001 --redo=05      # 改端口
sudo ./armbian-nas-一键部署.sh --docker-external=1 --docker-loop-size=12G --redo=19
sudo docker ps
sudo docker logs armbian-nas-portainer
sudo docker system df -v
```

Portainer 首次打开 `http://<本机IP>:9000/` 需在 5 分钟内创建 admin 密码，超时重启容器即可。数据卷在 `$BASE/portainer`。**Docker 发布的端口会绕过 ufw**，不要把管理口映射到公网。

> 如果 Docker 早已装好、步骤 05 已是 `done`（例如从旧版脚本升级过来），`--repair` 不会替你拉镜像；执行 `sudo ./armbian-nas-一键部署.sh --with-docker --redo=05` 会幂等补上 Portainer，不动已有容器。用 `--no-portainer` 可以只装引擎不带 Web 管理。

### 5.8 风扇温控

```bash
sudo bash ./风扇针脚测试.sh                                   # ★ 先做两轮实测（开→转 / 关→停）
sudo ./armbian-nas-一键部署.sh --fan-probe                     # 等价，走主脚本探测模式
sudo ./armbian-nas-一键部署.sh --fan-confirmed=515 --repair    # 已确认 515，直接启用服务
sudo ./armbian-nas-一键部署.sh --fan-status                    # 服务/温度源/当前电平/最近日志
sudo ./armbian-nas-一键部署.sh --fan-test-on                   # 临时强制开几秒后自动恢复
sudo ./armbian-nas-一键部署.sh --fan-test-off                  # 临时强制关几秒后自动恢复
sudo ./armbian-nas-一键部署.sh --scan                          # 重新逐个排查 10 个安全 sysfs 编号
sudo systemctl status armbian-fan
tail -f /mnt/sda1/www/logs/fan.log
```

- 本机实测：比特米盒 CumeBox2（刷 VIM1 镜像）风扇是 **sysfs 全局编号 515**（J9 排针 Pin35 / GPIOAO_3，AO 域 base 512 + 3），**高电平开、低电平关**，不是 PWM、不是 libgpiod 的 `gpiochip0 line 3`。
- 阈值默认 **≥50℃ 开 / ≤48℃ 关**；启动时强制下发 OFF，温度源全部读不到时 fail-safe 开风扇。
- **严禁测试 `gpiochip1` 的 line 70~80**（会掉线、需拔电重启）；它与 sysfs 全局编号 515 不是同一套命名空间。
- 换镜像 / 换 dtb 后 GPIO 编号可能变化（504、515、libgpiod line 3 三套互斥），**务必重新跑一次两轮实测**。

### 5.9 硬盘休眠、zram 与 swap

```bash
sudo ./armbian-nas-一键部署.sh --with-hd_idle --redo=15
sudo hdparm -C /dev/sda
sudo ./armbian-nas-一键部署.sh --zram=auto --redo=19          # zram 优先 pri=100，磁盘 swap pri=-2
sudo ./armbian-nas-一键部署.sh --swappiness=auto --redo=19
sudo ./armbian-nas-一键部署.sh --no-apt-external --redo=19    # 不把 apt 缓存外置（一般不推荐）
cat /proc/swaps
```

`hdparm -S` 的单位是 5 秒且 `0=禁用休眠`，脚本会向上取整并钳到 `1..240`；NTFS 上放 swapfile 会失败，512M swap 只能留 eMMC 或改 zram。

### 5.10 导航页、状态页、在线文档与博客

```bash
sudo ./armbian-nas-一键部署.sh --redo=18                      # 重建 index.html + status.html + docs.html
sudo ./armbian-nas-一键部署.sh --nav-theme=dark --redo=18     # 切深色主题
sudo ./armbian-nas-一键部署.sh --no-nav-secrets --redo=18     # 卡片不显示明文密码
sudo ./armbian-nas-一键部署.sh --ttyd-path=/term --redo=21    # 改网页终端入口
sudo ./armbian-nas-一键部署.sh --fb-port=8083 --redo=22
sudo ./armbian-nas-一键部署.sh --blog-port=81 --redo=23
sudo ./armbian-nas-一键部署.sh --min-root-space=2048         # 部署前要求根分区剩 ≥2G
sudo ./armbian-nas-一键部署.sh --force-low-space             # 空间不足但坚持继续
```

> **每次运行脚本到最后（部署 / `--check` / `--repair`）都会重新生成一次导航页与状态页**，所以装了、卸了软件或换了端口后，不用记 `--redo=18`，直接重跑脚本即可刷新。

---

## 六、★ 省 eMMC 空间专题

### 6.1 实测容量账本

全新系统 + `--no-docker --no-gui` 部署完成后的 `df -h`：

```text
/dev/mmcblk1p1  7.0G  2.1G  4.9G  30%  /          ← 8G eMMC，装完全套软件仍很宽裕
/dev/sda1       466G  454G   13G  98%  /mnt/sda1  ← 原有电影，注意下载余量
/dev/sdb1       466G  453G   14G  98%  /mnt/sdb1
/dev/zram1       47M  2.2M   42M   5%  /var/log   ← Armbian 自带，不占 eMMC
```

**结论：eMMC 不是瓶颈。** 真正要留意的是两块外置盘已 98%，下载目录 `/mnt/sda1/www/downloads` 只剩约 13G，BT 下载请留余量。

### 6.2 哪些命令能省 eMMC（按效果排序）

| 完整命令 | 省下什么 | 代价 / 说明 |
|---|---|---|
| `sudo ./armbian-nas-一键部署.sh --no-docker --no-gui` | Docker 引擎 ~350 MiB + 镜像层 0.8–1.2 GiB + 图形界面 1–2 GiB | 没有 Docker 与桌面；qB/Transmission 本来就是原生安装，不受影响 |
| `sudo ./armbian-nas-一键部署.sh --no-gui` | 1–2 GiB | 无远程桌面 |
| `sudo ./armbian-nas-一键部署.sh --no-docker` | ~350 MiB + 镜像层 | 无 Portainer 与自建容器 |
| `sudo ./armbian-nas-一键部署.sh --no-portainer` | Portainer 镜像层约 150–250 MiB | 装了 Docker 但没 Web 管理界面 |
| `sudo ./armbian-nas-一键部署.sh --all-no` | 全部可选组件 | 只留 nginx/PHP/站点/导航页/博客等必需项 |
| `sudo ./armbian-nas-一键部署.sh --no-qb --no-transmission --no-aria2` | 约 130 MiB | 没有下载器 |
| `sudo ./armbian-nas-一键部署.sh --tr-webui=trguing --redo=09` | **0 MiB eMMC** | 中文增强界面包 349 KB 完全落在外置盘 `$BASE/webui/trguing-zh`，换界面不增加系统盘占用 |
| `sudo ./armbian-nas-一键部署.sh --docker-external=1 --docker-loop-size=12G --redo=19` | 把镜像层从 eMMC 迁到外置盘的 ext4 loop 镜像 | USB 掉盘 / 意外断电可能损坏容器层；挂不上时 Docker 自动回退 eMMC，不阻塞开机 |
| `sudo ./armbian-nas-一键部署.sh --min-root-space=2048` | 不直接省，但会在装软件**之前**拦下空间不足的机器 | 装软件时 apt 缓存还没外置，这是唯一的前置硬门槛 |
| `sudo ./armbian-nas-一键部署.sh --redo=19` | 把 apt 缓存/lists 外置、journald 限额、部署日志 logrotate、ext4 保留块 5%→1% | 默认部署已自动执行；重跑幂等 |

**默认就在省空间的机制**（无需额外命令）：网站/日志/数据库/下载全在外置盘；apt 缓存与 lists 外置；Docker 日志 `max-size=10m × max-file=3`；journald `SystemMaxUse=100M`；zram 优先、磁盘 swap 兜底；`vm.page-cluster=0`；pecl 编译链只在补第三方扩展时安装。

### 6.3 上线后巡检与清理

```bash
df -h /
docker system df -v
docker image prune -f
sudo apt-get clean
sudo journalctl --vacuum-size=100M
du -sh /var/log /var/lib/docker 2>/dev/null
```

以后**不再编译 PHP 扩展**时，可以卸掉编译链（注意 `--redo=03` 会装回来）：

```bash
sudo apt-get purge -y php8.2-dev build-essential libevent-dev libzstd-dev && sudo apt-get autoremove -y
```

### 6.4 不要这样做

- 不要 `--no-apt-external`：apt 缓存/lists 留在 eMMC，反而更占空间。
- 不要 `--all-yes` 又不看内存：1G 内存机器同时开 Docker + 图形界面 + 多个下载器容易 OOM。
- 不要把 Docker 的 `data-root` 直接指到 NTFS 目录：必须用 `--docker-external=1` 的 ext4 loop 方案。
- 不要把 swapfile 放 NTFS 移动硬盘：`swapon` 会报 `Invalid argument` / `swapfile has holes`。

---

## 七、断点续跑与 SSH 断线保护

- 每个步骤的状态写在 `$BASE/.deploy/`（外置盘）并镜像一份到本地，硬盘掉了也能查进度。
- 状态四态：`done` 跳过、`running/failed` 重跑、`skip` 下次再问、`undecided`（新机尚未部署）自检标 SKIP 而不是 FAIL。
- 交互运行时脚本自动进入 `tmux`（判据基于 `-t 0` 与 `/dev/tty`，**不依赖会被 `sudo env_reset` 清掉的 `SSH_TTY`**）；命令行参数原样透传，不会变成无参运行。
- **窗口一闪而过（`[exited]`）不代表脚本没跑**：tmux 里命令结束会关闭窗口并清屏。窗口内的全部输出同时写入 `/var/log/armbian-nas-deploy.log`（挂载后同步到 `/mnt/sda1/www/logs/deploy.log`）。脚本**失败时窗口会保留**，可直接 `tmux attach -t armbian-nas` 看完整错误；成功时窗口关闭，用 `tail -80 /var/log/armbian-nas-deploy.log` 回看。
- **排查单个软件补装失败时，推荐加 `--no-tmux`**，输出直接留在当前终端，不被清屏：
- **`tmux` 有两道保障**：① 步骤 02 的基础依赖清单里已含 `tmux`；② 进会话前的守卫发现缺 `tmux` 会**自动 `apt` 补装**（首次失败会刷新索引再试一次），补装成功才进会话。两道都失败时会明确打印 `★ tmux 自动补装失败：本次运行没有 SSH 断线保护`，不再"静默假装受保护"。手动补装：

```bash
sudo apt-get update && sudo apt-get install -y tmux
# 验证：command -v tmux && tmux -V
```
- 断线后重连：

```bash
tmux attach -t armbian-nas
```

- 不想进 tmux（排查时最有用）：

```bash
sudo ./armbian-nas-一键部署.sh --no-tmux --with-zerotier --redo=07
sudo bash -c 'echo SSH_TTY=$SSH_TTY'    # 输出空白也正常，保护已不依赖它
command -v tmux || sudo apt-get install -y tmux   # 精简镜像上先确认有 tmux
tail -80 /var/log/armbian-nas-deploy.log         # tmux 内输出的持久副本
```

- 交互勾选（组件 / 共享目录 / 风扇确认）统一走 `/dev/tty`，不受日志 `tee` 管道影响。

---

## 八、导航页与独立状态页

| 页面 | 地址 | 内容 |
|---|---|---|
| 导航页 | `http://<本机IP>/` | 顶部在线文档；**默认折叠**的本机全部 IP / 来访主机 IP / 访问地址 / 主机名；① 常用 Web 界面（含 Transmission `:9091` 中文增强界面卡片、Docker 的 Portainer）；💾 存储空间（挂载点、总空间、已用、剩余、使用率，每 5 秒动态刷新，可折叠）；② 媒体库；③ 环境探针；④ 状态页入口 |
| 状态页 | `http://<本机IP>/status.html` | 每软件一张卡片，按「① 常用 Web → ② 媒体库与网络 → ③ 环境与后台」分组；含运行状态、版本、eMMC 估算、入口、SSH 命令、默认密码、路径清单、**最后一条一键安装命令**；另含「🔑 aria2 RPC」与「🔐 统一凭据与改密方法」两个区块 |
| 在线文档 | `http://<本机IP>/docs.html` | 本文的 HTML 版，左侧目录 + 全文搜索，纯静态无 CDN |
| 完整探针 | `http://<本机IP>/prober.php` | X-Prober 风格 phpinfo / 扩展 / ini / CPU / 内存 / 磁盘 |
| 扩展核对 | `http://<本机IP>/probe.php` | 分区表格逐项比对你指定的扩展清单 |
| 本地博客 | `http://<本机IP>:81/` | 独立站点，目录 `$BASE/boke` |

状态页的 Transmission 卡片会列出中文增强界面的目录、版本记录、来源、装/切回/离线补装三条完整命令，以及 `TRANSMISSION_WEB_HOME` 的切换原理。

**aria2 RPC 已从导航页移到状态页**：首页底部的「aria2 RPC」栏整体搬走（首页更清爽），状态页给出 RPC 地址（按当前访问 IP 自动拼）、RPC 密钥、复制按钮与原始文件路径。

所有带 Web 界面的卡片一律**新标签页打开**（`target="_blank" rel="noopener noreferrer"`）；页面按当前访问的主机名/IP 自动拼端口，换 IP 或用域名都不用重新生成。未安装的软件卡片会置灰，点击可跳到状态页复制一键安装命令。

---

## 九、外置硬盘与共享目录

- 主盘 `/dev/sda1` → `/mnt/sda1`，第二块 `/dev/sdb1` → `/mnt/sdb1`，默认用内核 `ntfs3`；选项里**不含** `windows_names` / `big_writes`（那是 ntfs-3g 专属，传进去会挂载失败）。
- **两块盘各自独立降级**：任一块被 ntfs3 拒绝，脚本会自动精简选项 → 切到 `ntfs-3g`，并把成功的驱动/选项**回写 fstab**，下次 reboot 直接生效。
- `x-systemd.device-timeout` 默认 **120s**（两块 USB 盘同时上电 spin-up，30s 太短）；`nofail` 保证盘没插也能开机。
- **开机补挂自愈**：`armbian-nas-mounts.timer`（开机 25s 首次、之后每 90s）检查每块盘，把「USB 晚到 / nofail 跳过 / ntfs3 拒绝」的盘补挂回来并固化 fstab。日志 `/var/log/armbian-nas-mounts.log`。
- 相关完整命令见第二十章：`--second-fstype=ntfs-3g`、`--mount-timeout=120`、`--no-mount-helper`。
- `nofail` 兜底：外置盘没插好也不阻塞开机。
- 脚本**不格式化、不分区、不改动盘上已有电影**；只在 `$BASE` 下新建目录。
- 共享目录可交互勾选（whiptail），也可直接指定：

```bash
sudo ./armbian-nas-一键部署.sh --shares='/mnt/sda1/电影,/mnt/sdb1/影视' --redo=11
```

- 两块盘都会分别挑出目录写进 `smb.conf` 的 `[video-*]` 段落；MiniDLNA 名称为 `armbian-nas`。

---

## 十、PHP 8.2 与扩展策略

- 全部使用 `php8.2-*` 显式包名，不装 `php-fpm` / `php-cli` 这类跟随系统默认版本的 meta 包；nginx 只连 `/run/php/php8.2-fpm.sock`。
- 系统源没有 8.2 时自动加 Sury；装不出 8.2 会明确停在步骤 03，不会退成别的版本。
- 扩展清单逐项核对 CLI 与 FPM **两侧**。注意 `pcntl` 是 CLI SAPI 专有，上游 `php8.2-fpm` 二进制不编译它，FPM 侧会把它排除，避免误报 `PHP_EXT_FAIL`。
- 官方源缺的第三方扩展先试 Sury 包，再用 `pecl` 编译（`--no-pecl` 可跳过）。
- `open_basedir` 收口到站点必需目录；`.deploy/secrets.env` 对 PHP 不可达。`prober.php` 单独用 `PHP_ADMIN_VALUE open_basedir=/` 放行（仅这一个 location），以便读取 `/proc` 与 `df`。
- `disable_functions` **保持为空**。以下分组不能禁：探针自身依赖（`file_get_contents`、`get_loaded_extensions`、`ini_get`…）、进程/系统（`pcntl_*`、`posix_*`、`exec`、`proc_open`…）、IPC/网络（`shmop_*`、`sem_*`、`socket_*`、`fsockopen`…）、扩展函数（`imap_*`、`curl_*`、`opcache_*`、`exif_*`、`finfo_*`、`gmp_*`、`igbinary_*`、`zstd_*`…）。类方法不受 `disable_functions` 约束，`eval` 是语言结构也禁不了。
- 需要放开 `exec` 的运维 PHP 脚本建议单独 admin 池（默认只生成模板）：

```bash
sudo ./armbian-nas-一键部署.sh --enable-admin-pool --redo=19
```

---

## 十一、安全边界

1. **导航页状态卡片明文显示默认密码与 RPC 密钥**（局域网自用设计）。ttyd / aria2 为 `admin / admin`，FileBrowser 为 `admin / adminadmin123`（上游 ≥12 位）。改密方法写在状态页（FileBrowser 必须按「停服 → 改密 → 启服」三步，且新密码 ≥12 位，见第五章与第十九章）。不要把本机 80 / 81 / 8082 端口映射到公网；只在可信局域网 / ZeroTier 里使用。想隐藏加 `--no-nav-secrets`，想恢复随机密钥加 `--creds=random`。
2. ttyd 只监听 `127.0.0.1:7681`，由 nginx 反代 `/ttyd/` 并强制 `auth_basic` + WebSocket Upgrade；密码只在 700 权限的 `secrets.env`，不出现在 Web 目录，也不用 `-c user:pass`（命令行明文会进 `ps`）。
3. 网页终端等于一个 shell，风险等同 SSH。
4. `.deploy/` 目录 `chmod 700`；探针把清单内嵌进文件，不读外部清单，避免权限误判。
5. Docker 发布端口会绕过 ufw，Portainer / qB / Transmission 都不要直接暴露公网。
6. ZeroTier 私有网络必须在 Central 勾选授权设备。

---

## 十二、自检结果怎么读

`--check` 会打印全部软件的安装、运行、配置状态，并写一份最终报告到 `$BASE/.deploy/final-report.txt`。

| 标记 | 含义 |
|---|---|
| `OK` | 检查通过 |
| `SKIP` | 组件被主动跳过 / 已卸载 / 尚未部署（新机直接 `--check` 时正常，不是失败） |
| `TODO` | 需要你按硬件或网络补的配置，例如 ZeroTier 网络 ID、风扇针脚实测 |
| `WARN` | 可用但有风险或可优化，例如根分区使用率 ≥85%、Docker data-root 在 eMMC |
| `FAIL` | 确实需要处理；先跑 `--repair` |

```bash
sudo ./armbian-nas-一键部署.sh --check
sudo ./armbian-nas-一键部署.sh --repair
cat /mnt/sda1/www/.deploy/final-report.txt
tail -f /mnt/sda1/www/logs/deploy.log
```

自检里也包含「部署器自身完整性」检查：断线保护判据、参数原样透传、`read_temp` 全局返回通道（防止风扇永远转）、`--help` 无命令替换、占位符无残留、导航页末尾重建、**定向模式不误问其它组件**、**统一凭据 admin/admin**、**aria2 RPC 已移到状态页**、**收尾自愈设施**、**全脚本无 `local` 同行自引用（SC2318）**、**tmux 自动补装兜底**、**ZeroTier apt 优先兜底**、**定向模式最小依赖**、**tmux 失败保留窗口**等。

> `--check` / `--status` 是只读模式：带 `--redo` / `--from` 也不会清步骤状态；收尾自愈不触发。唯一例外是开头会把统一凭据（ttyd/aria2 `admin`、FileBrowser `adminadmin123`）幂等对齐一次（值已一致时零动作）。

**收尾自愈**：每次 deploy / 定向 / `--repair` 运行到最终自检之前，会自动探测并修复两类常见的历史 FAIL——`prober.php` HTTP 取不到内容（必要时回退内置完整探针，原 X-Prober 备份为 `prober.xprober.bak`）、Samba 共享段落数少于清单数量（幂等重建 `smb.conf`）。`--check` / `--status` 保持只读，不触发自愈。


> **SC2318 必修记录**：`component_install_cmd()` 曾写成 `local k="$1" step="${COMP_STEP[$k]:-}" ...`——bash 先展开整行再逐个赋值，`$k` 此刻不存在，`set -Eeuo pipefail` 下直接 `k: unbound variable` 退出。当时两个调用点外层恰好都有同名 `k`，靠 Bash 动态作用域"巧合正确"；外层一改名或新增调用点，步骤 18 生成导航页会整体崩掉。现已拆成两行赋值，并加 `local_selfref_ok()` 逐行扫描全脚本代码行防回归（注释里的反面教材不会被误扫）。

---

## 十三、卸载与数据保留

```bash
sudo ./armbian-nas-一键部署.sh --uninstall                   # 交互菜单
sudo ./armbian-nas-一键部署.sh --uninstall=filebrowser       # 卸一个
sudo ./armbian-nas-一键部署.sh --uninstall-all               # 卸全部可选组件
sudo ./armbian-nas-一键部署.sh --uninstall=ttyd --purge-data # 连外置盘数据一起删（危险）
```

卸载会停服务、删程序与单元文件、恢复被改的配置（如 nginx 片段），**默认保留 `$BASE` 里的下载、配置、数据库**。卸载过的组件下次运行会重新询问是否安装。

---

## 十四、常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `duplicate default server for 0.0.0.0:80` | 旧 `default.bak.armbian-nas` 残留在 `sites-enabled`；脚本会自动移到 `sites-disabled.armbian-nas`，`--repair` 可修 |
| `--help` 出现 `command not found` | 旧版帮助文本里的反引号被命令替换执行；当前版本已修，自检有防回归项 |
| qB `:8080` 显示 `Unauthorized` | qB 自身登录认证，默认 `admin/adminadmin`；改过或 4.x 临时密码查 `journalctl -u qbittorrent-nox` |
| ttyd 输对密码后 404 | nginx 反代 `proxy_pass` 尾斜杠剥前缀问题；`--repair` 幂等重建 |
| 风扇一直转 / 一直不转 | 用 `sudo ./armbian-nas-一键部署.sh --fan-status` 看温度源与当前电平；确认针脚两轮实测记录存在 |
| 换镜像后风扇不转 | dtb 变了、GPIO 编号可能不同，重新跑 `sudo bash ./风扇针脚测试.sh` |
| FPM 侧报缺 `pcntl` | 上游编译期决定，FPM 无此扩展也无 `.so`；`--repair` 重建 `probe.php` 把它从 FPM 清单排除 |
| 根分区莫名变满 | `docker system df -v`、`journalctl --disk-usage`、`du -sh /var/log`；见第六章 |
| 整个路由器内网断连 | 面板 OLED 的 I2C 全地址扫描会踩到 PHY；该组件已整体移除，旧机器 `--repair` 会清残留服务 |
| Transmission `:9091` 还是英文 | 步骤 09 当时输入了 `n`，或中文包下载失败。先看 `sudo ./armbian-nas-一键部署.sh --check` 里「中文增强 WebUI」那行；执行 `--tr-webui=trguing --redo=09`（离线用 `--tr-webui-zip=`），然后 `Ctrl+F5` 强刷浏览器 |
| 中文界面打开是空白 / 404 | 多半是 `TRANSMISSION_WEB_HOME` 目录下多套了一层文件夹。脚本会自动拍平；若手动放过包，删掉 `$BASE/webui/trguing-zh` 后 `--tr-webui=trguing --redo=09` 重建 |
| 指定装 FileBrowser，却又弹出 Docker / 图形界面 / ttyd 的安装提示 | 旧版 `--redo=22` 会把后面所有 `skip` 状态的组件重新问一遍。当前版本是**定向模式**：带 `--with-*` 或 `--redo=*` 只跑目标步骤，其它一律「保持原状态不变」 |
| `完整 PHP 探针 prober.php 可访问` FAIL | 步骤 18 早已 done 被跳过，旧站点配置没机会刷新。现在每次运行收尾会自动自愈（必要时回退内置完整探针）；也可 `sudo ./armbian-nas-一键部署.sh --repair` |
| `Samba 共享段落数` FAIL（清单 7 个但段落不足） | 旧配置往往只含第一块盘。现在收尾会自动按最新清单幂等重建 `smb.conf`，不删数据、不改共享清单；或 `--repair` |
| 想把 admin/admin 换成自己的密码 | 状态页「🔐 统一凭据与改密方法」逐条给了 ttyd / FileBrowser / aria2 / qB / Transmission / Portainer 的改密命令；**FileBrowser 必须先 `systemctl stop armbian-filebrowser`** |
| `filebrowser users update` 报 `Error: timeout` | 服务运行时占用 bbolt 数据库锁；按「停服 → 改密 → 启服」三条执行，见第十八章 |
| `filebrowser users update` 报 `Error: password is too short, minimum length is 12` | FileBrowser 上游强制密码 ≥12 位；用 `adminadmin123` 或自定义 ≥12 位，见第十九章 |
| 第二块盘 `sdb1` 开机总挂不上，`df -h` 里没有它 | 多为内核 ntfs3 拒绝该卷 + `nofail` 跳过后不重试；见第二十章诊断与完整命令 |
| Transmission WebUI 打开显示 `403: Forbidden` | **不是 nginx 反代没配**（首页卡片直连 `:9091`）。是 Transmission 自己的 RPC / Host 头白名单；见第二十一章，一条 `--repair` 即可 |
| FileBrowser 改密成功却依然登录不上 | `ps -ef \| grep filebrowser` 看 `-d` 实际路径；脚本状态页曾写 `filebrowser`，旧 unit 写 `filebrowse`（少一个 r），改到了另一个库。见第二十一章 |
| 为什么 FileBrowser 不是 `admin / admin` | 上游不允许 5 位密码；脚本默认 `admin / adminadmin123`，`--fb-password=` 可自定义 |

---

### Q：跑 `--with-zerotier --redo=07` 只看到 `[exited]`，随后 `systemctl start zerotier-one` 报 `Unit zerotier-one.service not found`

这是两个问题叠在一起，都已修复：

1. **输出被 tmux 清屏**：脚本确实进了 tmux，但窗口一闪而过，里面的 `[FAIL]` 全被清掉，只剩 `[exited]`。现在进 tmux 前会打印日志路径，失败时窗口保留（`exec bash -l`），rc 也追加进日志。
2. **官方安装脚本不认新 codename**：旧版只走 `install.zerotier.com`，在 Ubuntu 26.04 `resolute` 上可能 `Unknown or unsupported distribution! Aborting`，于是 `zerotier-one.service` 根本没生成。现在改为 **apt 优先**（`apt install -y zerotier-one`）→ 官方脚本兜底 → 仍无 unit 则明确报错并给手动命令。
3. **定向模式跳过步骤 02**：`--with-* / --redo=*` 只跑目标步骤，全新系统/重刷后直接跑定向命令会缺 `$STATE_DIR`、`curl`、`python3`。现在 `targeted_prereqs()` 幂等补齐，不装软件、不询问、不改状态。

**不等新脚本也能立刻排查/补装**：

```bash
tail -80 /var/log/armbian-nas-deploy.log
sudo apt-get update && sudo apt-get install -y zerotier-one
sudo systemctl enable --now zerotier-one && sudo zerotier-cli info
# 或让输出留在当前终端重跑：
sudo bash /root/armbian-nas-一键部署.sh --no-tmux --with-zerotier --redo=07
```

装好后加入网络：`sudo bash /root/armbian-nas-一键部署.sh --zt-network=<16位ID> --redo=07`，再去 ZeroTier Central 勾选授权。

### Q：为什么 `--with-filebrowser --redo=22` 这类定向命令不会重装其它软件，但偶尔仍会失败？

定向模式只执行目标步骤，其余 22 步的状态**完全不碰**、也不会弹「是否安装」。失败多半是目标步骤依赖的前置条件缺失（见上一条的最小依赖兜底），或网络拉不到二进制。用 `--no-tmux` 重跑一次即可看到完整错误；脚本每次运行末尾都会重建导航页与状态页，所以补装成功后的入口会自动刷新。

### Q：`sudo filebrowser -d ... users update admin --password adminadmin` 回显 `Error: timeout`

`No config file used` / `Using database` 两行是正常的提示，不是错误。真正的问题是 **FileBrowser 正在运行**：它用 bbolt 存 `filebrowser.db`，同一时刻只允许一个进程持有写锁，服务不释放锁，CLI 等锁超时就报 `Error: timeout`。**密码并没有改成功**，而命令里的 `&& sudo systemctl restart armbian-filebrowser` 因为前一条失败也不会执行。

正确顺序（三条，逐条执行，不要写成一行 `&&`）：

```bash
sudo systemctl stop armbian-filebrowser
sudo filebrowser -d /mnt/sda1/www/filebrowser/filebrowser.db users update admin --password adminadmin123
sudo systemctl start armbian-filebrowser
```

验证：`sudo systemctl is-active armbian-filebrowser`，然后浏览器用 `admin / adminadmin123`（≥12 位）登录 `http://<本机IP>:8082`。若仍报 timeout，查占用 `sudo lsof /mnt/sda1/www/filebrowser/filebrowser.db` 或 `sudo fuser -v ...`。
> ⚠ 这里也不能填 `adminadmin`（10 位），否则会先撞上第十九章的 `password is too short`：两个错误是**叠加**的，长密码 + 停服两个条件都要满足。

脚本内部也已修：`sync_simple_creds` 与 `--redo=22` 重配都会先停服再改数据库，且**改密失败也会把服务拉回来**，不会再出现「`|| true` 吞掉错误 + 无条件打印已更新」的假成功。

## 十五、开源组件与致谢

| 项目 | 说明 |
|---|---|
| **X-Prober / X 探针 / 刘海探针** | 随附的 `prober.php` 完整 PHP 环境探针来自 **Km.Van / INN STUDIO**，仓库：**https://github.com/kmvan/x-prober** 。脚本只是把上游单文件原样复制到网站目录，并为它加一条 nginx `open_basedir` 放行，**未修改其源码**；版权与许可证归原作者所有（仓库当前标注 GPL-3.0，旧版 tag README 曾写 GPL-v2，一律以仓库 `LICENSE` 原文为准）。对外分发时请保留署名与许可证。 |
| **Armbian** | 本项目是**第三方部署脚本，不是 Armbian 官方项目**。系统/内核/板级问题请走社区：官网 https://www.armbian.com ，论坛 https://forum.armbian.com ，问题反馈 https://www.armbian.com/bugs 。 |
| **Portainer CE** | Docker 的 Web 管理界面，装 Docker 时由脚本拉取官方镜像 `portainer/portainer-ce`，版权归 Portainer.io。 |
| **TrguiNG 汉化版（Transmission 中文增强 WebUI）** | 步骤 09 可选的中文界面来自 **https://github.com/jayzcoder/TrguiNG** 「基于 openscopeproject/TrguiNG 汉化和改进」，上游为 **https://github.com/openscopeproject/TrguiNG** 。项目按 **GNU Affero General Public License v3 (AGPL-3.0)** 发布，版权归原作者所有。脚本只下载 release 中已编译好的 `trguing-web-*-zh-*.zip` 静态包并通过 `TRANSMISSION_WEB_HOME` 挂载，**未修改其源码、未重新编译**；对外分发时请保留署名与 AGPL-3.0 许可证。 |
| **qBittorrent / Transmission / aria2 / AriaNg / MiniDLNA / Samba / FileBrowser / ttyd / ZeroTier / 微力同步** | 各软件版权归各自上游；脚本只做 apt 安装或下载官方二进制并写配置。 |
| **SSD1306_OLED_json** | 比特米盒面板屏参考项目 https://github.com/bearcatl/SSD1306_OLED_json 。因 I2C 扫描会导致断网，本脚本**已移除** OLED 集成，仅保留资料链接。 |

---

## 十六、许可证与免责

- 本脚本与文档按「原样」提供，用于你在自己的设备上部署；使用前请备份重要数据。
- 脚本不会格式化硬盘、不会删除外置盘上已有的电影等文件，但**挂载、分区、容器、卸载（尤其 `--purge-data`）本身有风险**，请自行确认设备名（`lsblk -f`）后再执行。
- 风扇 GPIO、ZeroTier 网络 ID 等硬件/网络相关参数必须由你实测或提供，脚本不会猜测，也不会假装配置成功。
- 第三方组件的许可证以其上游仓库为准；发布本脚本时请一并保留第十五章的署名（尤其 X-Prober 与 TrguiNG 的 AGPL/GPL 要求）。

---

> 反馈与改进：把 `--check` 的完整输出、`/mnt/sda1/www/logs/deploy.log` 与 `df -h` 一起附上，能最快定位问题。

---

## 十七、真机案例：`[exited]` 与 ZeroTier 装不上（完整复盘）

**环境**：比特米盒（CumeBox2）刷 Khadas VIM1 镜像，Armbian 26.8.11 resolute / Ubuntu 26.04 / 内核 6.18.57-current-meson64 / aarch64。

**现象**：

```text
root@khadas-vim1:~# sudo bash /root/armbian-nas-一键部署.sh --with-zerotier --redo=07
[INFO] 检测到交互终端，自动进入 tmux；断线后重连：tmux attach -t armbian-nas
[INFO] 断线保护判据：NAS_INTERACTIVE=1、SSH_TTY=（空，已不依赖）、TMUX=（空）
[exited]
root@khadas-vim1:~# sudo systemctl start zerotier-one
Failed to start zerotier-one.service: Unit zerotier-one.service not found.
```

**根因链**：

| 层 | 问题 | 后果 |
|---|---|---|
| 可观测性 | `tmux new -s ... -- bash 脚本` 里命令一结束窗口就关闭并清屏 | 用户只看到 `[exited]`，看不到里面的 `[FAIL]` 与诊断，误以为"脚本什么都没做" |
| 安装路径 | 旧版只用 `install.zerotier.com`，该脚本按 codename 拼仓库地址 | Ubuntu 26.04 `resolute` 属新版本，历史上出现过 `Unknown or unsupported distribution! Aborting`（22.04 jammy 时也踩过同类 bug），脚本退出后 unit 不存在 |
| 定向模式 | `--with-zerotier --redo=07` 只跑步骤 07，跳过 01/02 | 全新/重刷系统直接跑定向命令时，`$STATE_DIR`、`curl`、`python3` 可能缺失，目标步骤在子 shell 里静默失败 |

**修复**：

1. **ZeroTier 三级兜底**：`apt install -y zerotier-one`（Debian/Ubuntu 官方指南推荐，不受 codename 影响）→ 官方脚本兜底（输出落盘到 `/mnt/sda1/www/logs/zerotier-install.log`，失败打印尾部）→ 仍无 `zerotier-one.service` 则明确报错 + 可复制的手动命令。
2. **`targeted_prereqs()`**：定向模式且 `MODE=deploy` 时，幂等 `mkdir -p $STATE_DIR/$LOG_DIR/$WEB_ROOT`，补齐真正缺失的 `curl / python3 / gnupg`；不装软件、不询问、不改步骤状态。
3. **tmux 失败保留窗口**：进会话前打印 `tail -80 /var/log/armbian-nas-deploy.log` 与 `--no-tmux` 排查法；会话内包一层 `bash -c`，`rc≠0` 时 `exec bash -l` 保留窗口，`rc=0` 照常退出；rc 与参数个数追加进日志。
4. 新增 3 个自检项：`ZeroTier 安装：apt 优先 + 官方脚本兜底 + 失败可诊断`、`定向模式最小依赖兜底`、`tmux 失败保留窗口且输出可查`。

**立即排查命令（不依赖新脚本）**：

```bash
tail -80 /var/log/armbian-nas-deploy.log
sudo apt-get update && sudo apt-get install -y zerotier-one
sudo systemctl enable --now zerotier-one && sudo zerotier-cli info
sudo bash /root/armbian-nas-一键部署.sh --no-tmux --with-zerotier --redo=07
```

---

## 十八、真机案例：FileBrowser 改密 `Error: timeout`（完整复盘）

**环境**：比特米盒（CumeBox2）刷 Khadas VIM1 镜像，Armbian 26.8.11 resolute / Ubuntu 26.04 / FileBrowser v2.63.23。

**现象**：

```text
root@khadas-vim1:~# sudo filebrowser -d /mnt/sda1/www/filebrowser/filebrowser.db users update admin --password adminadmin && sudo systemctl restart armbian-filebrowser
2026/11/16 20:36:37 No config file used
2026/11/16 20:36:37 Using database: /mnt/sda1/www/filebrowser/filebrowser.db
Error: timeout
root@khadas-vim1:~#
```

**根因**：

| 项 | 说明 |
|---|---|
| `No config file used` / `Using database` | 正常 Info 输出，不是报错 |
| `Error: timeout` | FileBrowser 用 **bbolt(bolt) 单文件数据库**，靠 `flock` 独占写锁。`armbian-filebrowser.service` 正在运行并持有锁，另一条 `filebrowser` CLI 打开同一个 `filebrowser.db` 会一直等锁，超时即退出 |
| `&& sudo systemctl restart ...` 没执行 | `&&` 只在前一条成功时运行；CLI 失败后整条被短路 |
| 用户以为改成功了 | 实际**密码没变**，状态页显示的仍是脚本默认值（ttyd/aria2 `admin / admin`、FileBrowser `admin / adminadmin123`） |

**同一根因在脚本里的第二处**：`sync_simple_creds()` 旧版在服务运行时直接 `users update ... || true`，错误被吞掉后还无条件打印 `c_ok "FileBrowser 账号已更新：admin / …"`；`step_filebrowser --redo=22` 重配时 `config init / users add / config set` 也会撞同一把锁。

**修复**：

1. 新增 `fb_set_password()`：**停服 → 等锁释放（最多 5 次）→ `users update` → 启服**；无论改密成功与否都把服务拉回来，失败时打印三条正确命令与 `lsof` / `fuser` 排查法，返回非 0，绝不假装成功。
2. `sync_simple_creds()` 的 FileBrowser 段改走该 helper，失败明确 `WARN`，不再无条件 `OK`。
3. `step_filebrowser()` 在写数据库前先停服，函数末尾 `systemctl enable --now` 统一拉起（中途无提前 return）。
4. 状态页「🔐 统一凭据与改密方法」把 FileBrowser 命令改成**三行三步**，并加 bbolt 锁说明 + 「手动改密后本页显示的是脚本默认值」提示；`--no-nav-secrets` 不受影响。
5. 自检新增 `FileBrowser 改密先停服再启服（避开 bbolt Error: timeout）`。

**现在最省事的写法**（想改成 `adminadmin`）：

```bash
sudo systemctl stop armbian-filebrowser
sudo filebrowser -d /mnt/sda1/www/filebrowser/filebrowser.db users update admin --password adminadmin
sudo systemctl start armbian-filebrowser
sudo systemctl is-active armbian-filebrowser
```

> 注意：脚本默认是 ttyd/aria2 `admin / admin`、FileBrowser `admin / adminadmin123`。手动改过密码后，只要不改动 `$BASE/.deploy/secrets.env`，下次运行脚本的 simple 收敛仍会用默认值覆盖数据库（因为值不一致）；想长期保留自定义密码请同步改 `secrets.env` 或用 `--fb-password=` + `--redo=22`。状态页是部署时快照，重跑脚本会刷新显示。
>
> **续见第十九章**：把密码改成 ≥12 位后，`password is too short` 会消失；但若只改长度不停服，仍会回到本章的 timeout。两个条件缺一不可。

---

## 十九、真机案例：`password is too short, minimum length is 12`（完整复盘）

**现象**（紧接着第十八章那次 timeout 之后）：

```text
root@khadas-vim1:~# sudo filebrowser -d /mnt/sda1/www/filebrowser/filebrowser.db users update admin --password adminadmin && sudo systemctl restart armbian-filebrowser
2026/11/16 20:47:29 No config file used
2026/11/16 20:47:29 Using database: /mnt/sda1/www/filebrowser/filebrowser.db
Error: password is too short, minimum length is 12
root@khadas-vim1:~#
```

**根因**：FileBrowser v2.6x 起对 `users add / users update --password` 强制**密码至少 12 位**。

- `admin` = 5 位、`adminadmin` = 10 位，都被拒；
- 这个校验发生在**打开数据库之前**，所以短密码连第十八章的 `Error: timeout`（bbolt 锁）都遇不到就失败了 —— 不是锁问题消失了，是**两个错误叠加，校验顺序更早**；
- `&& sudo systemctl restart armbian-filebrowser` 再次被短路，服务状态没变。

**连带发现一个「假配置」**：脚本此前按用户要求把 FileBrowser 也收敛成 5 位 `admin`，于是 `step_filebrowser` 里 `users add admin admin` → `users add admin admin --perm.admin` → `users update admin --password admin` 三条全被拒，脚本走到兜底分支把 FileBrowser 切成了 `no_auth` **免密登录**。也就是说：你之前能用 `admin / admin` 打开 FileBrowser，很可能不是密码生效，而是它压根没在校验密码；状态页却一直显示 `admin / admin`。

**修复（脚本侧）**：

1. 新增 `FB_SIMPLE_PASS`（默认 **`adminadmin123`**，13 位，仍是 admin 系、好记）与 `FB_PASS_MIN=12`。simple 模式下 `secret_get FILEBROWSER_PASS` 单独返回它；ttyd / aria2 仍为 `admin`。
2. `sync_simple_creds()` 按 key 分别收敛期望值；FileBrowser 段调用 `fb_set_password "$FB_SIMPLE_PASS"`，失败明确 `WARN`，不再假 `OK`。
3. `fb_set_password()` 加**长度预检**：短于 12 位直接给中文提示 + 可用示例并返回 1，不再让用户去猜英文报错；错误文案补上 `password is too short` 的映射。顺手修了它误用 `FB_BIN`（那是 `--fb-bin` 离线包路径变量）取 CLI 的问题，改用独立的 `FB_CLI`。
4. 新增 `--fb-password=<≥12位>`；`validate_simple_creds()` 在**任何写操作之前**拦下过短参数，防止又静默退化成免密。
5. 首页 / 状态页 / 组件卡片 / 最终报告统一显示真实值；状态页新增 `__FB_PASS__` 占位符并接入替换链，改密示例改成 `至少12位的新密码`，加「密码至少 12 位」醒目说明。
6. 自检 `simple_creds_ok` 按 key 校验，新增 `fb_password_policy_ok` 与 `FileBrowser 密码满足上游 ≥12 位策略` 一行。

**立即改密（两个条件都要满足）**：

```bash
sudo systemctl stop armbian-filebrowser                       # ① 释放 bbolt 锁
sudo filebrowser -d /mnt/sda1/www/filebrowser/filebrowser.db \
  users update admin --password adminadmin123                # ② ≥12 位
sudo systemctl start armbian-filebrowser                     # ③ 拉回服务
sudo systemctl is-active armbian-filebrowser
```

浏览器用 `admin / adminadmin123` 登录 `http://<本机IP>:8082`。

完整命令（让脚本自己重配，包含停服/启服）：

```bash
sudo ./armbian-nas-一键部署.sh --with-filebrowser --redo=22
sudo ./armbian-nas-一键部署.sh --fb-password=你的12位以上密码 --with-filebrowser --redo=22
```

> 坚持「内网不想输密码」也可以：FileBrowser 支持 `no_auth` 免密，脚本在 CLI 建号失败时本来就会自动切过去；手动 `sudo filebrowser -d <db> config set --auth.method no_auth` 后重启服务即可，状态页显示的默认密码此时不适用。

---

## 二十、真机案例：`sdb1` 永远挂不上，手写 `ntfs` 却能挂（完整复盘）

**环境**：比特米盒（CumeBox2）刷 Khadas VIM1 镜像，Armbian 26.8.11 resolute / 内核 6.18.57；两块 500G NTFS 移动硬盘经 USB 转 SATA 接入。

**现象**：

```text
/etc/fstab（脚本生成）：
UUID=116C6CB4E3583E50 /mnt/sda1 ntfs3 defaults,nofail,noatime,uid=0,gid=0,umask=0000,x-systemd.device-timeout=30s 0 0
UUID=EEA0744EA0741EF1 /mnt/sdb1 ntfs3 defaults,nofail,noatime,uid=0,gid=0,umask=0000,x-systemd.device-timeout=30s 0 0

df -h → 只有 /dev/sda1 挂在 /mnt/sda1，sdb1 不在列表里；reboot 依旧。
blkid → /dev/sdb1 正常存在，UUID/TYPE=ntfs 都对。
modinfo ntfs3 → 驱动在，intree: Y。
```

把第二块盘那行手改成下面这样就**能挂**：

```text
UUID=EEA0744EA0741EF1 /mnt/sdb1 ntfs defaults,nofail,0 0
```

### 为什么「换成 ntfs 就能挂」已经给出了答案

Debian/Ubuntu 里 `/sbin/mount.ntfs` 是 `mount.ntfs-3g` 的符号链接，最终指向 `/usr/bin/ntfs-3g`。所以 fstab 写 `ntfs` 或 `ntfs-3g` 都走**用户态 FUSE 驱动 ntfs-3g**；内核原生驱动的别名是 `fs-ntfs3`，只有显式写 `ntfs3` 才会用它 。

两者的关键差异：

| | 内核 ntfs3 | 用户态 ntfs-3g |
|---|---|---|
| 性能 | 高 | 略低（FUSE） |
| 卷被标记 dirty / Windows 快速启动休眠 | **默认拒绝读写挂载**，日志 `volume is dirty and "force" flag is not set!` | 容忍度高，通常仍能挂（必要时回退只读/告警） |
| 个别 NTFS 元数据、中文卷标、压缩属性 | 校验更严格，可能 `Invalid argument` | 兼容性更好 |

也就是说：**盘没坏、UUID 没错、线没松**，是 sdb1 这个卷上有让 ntfs3 拒绝的状态（最常见是 Windows 快速启动留下的脏位/休眠标记，或上一次未正常卸载），ntfs-3g 能容忍 。

### 为什么 reboot 一直不行、脚本重跑也没修

三层叠加：

1. **脚本原来只给主盘做降级**。`ensure_mounts` 的「精简选项 → 切 ntfs-3g」链只在 `$MOUNT_MAIN` 没挂上时执行；第二块盘只 `mount -a` 一次，失败就打一行 WARN，**不降级、不回写 fstab**。而且主盘若已挂载，整段降级逻辑直接跳过。
2. **重启后 systemd 直接读 fstab，根本不跑脚本**。脚本里那份降级链只有运行脚本那一刻有效，fstab 里留下的仍是 `ntfs3` —— 于是每次开机都重复同一个失败。
3. **`nofail` + `x-systemd.device-timeout=30s` 让它永久跳过**。`nofail` 下该挂载对 `local-fs.target` 只是「想要」而非「必需」，等设备 30 秒不到就跳过，**systemd 不会重试**；两块 USB 盘同时上电时第二块枚举/spin-up 往往更慢，30s 更不够 。

### 一锤定音的诊断命令

```bash
sudo systemctl status mnt-sdb1.mount        # 看 Timed out waiting for device / Dependency failed
sudo journalctl -b | grep -iE 'sdb1|ntfs3|mount'
sudo dmesg | tail -30                       # 关键行：volume is dirty and "force" flag is not set!
                                           #      或 Windows is hibernated / Invalid argument
sudo mount -t ntfs3 -o defaults,noatime,uid=0,gid=0,umask=0000 /dev/sdb1 /mnt/sdb1 -v
sudo mount -t ntfs-3g -o defaults,noatime,uid=0,gid=0,umask=0000 /dev/sdb1 /mnt/sdb1 -v
```

若 `ntfs3` 报脏位而 `ntfs-3g` 成功，就是驱动兼容性；若两条都报 `Timed out waiting for device`，是 USB 枚举时序。

> ⚠ 脚本**不会**自动加 `force`、不会自动跑 `ntfsfix`：强制挂载脏卷或清脏位可能造成元数据损坏。根治办法是在 Windows 里 `powercfg /h off` + 彻底关机（不是「重启」），或用 Windows `chkdsk` 修复后再接回。

### 立即修复（不升级脚本也能用）

```bash
sudo cp /etc/fstab /etc/fstab.bak.$(date +%F)
sudo sed -i 's|^\(UUID=EEA0744EA0741EF1 /mnt/sdb1 \)ntfs3 .*|\1ntfs-3g defaults,nofail,noatime,uid=0,gid=0,umask=0000,big_writes,windows_names,x-systemd.device-timeout=120s 0 0|' /etc/fstab
sudo systemctl daemon-reload
sudo mount -a
df -h | grep sdb1
```

> 顺带纠正手写行里的笔误：`defaults,nofail,0 0` 的第 3 个字段是**选项列**，那个 `0` 被当成了一个挂载选项（ntfs-3g 恰好容忍了它）。规范写法是 `defaults,nofail 0 0`（选项、`dump`、`pass` 三列用空格分开）。

### 脚本已修（推荐做法）

| 改动 | 效果 |
|---|---|
| 新增 `mount_try_chain()`，主盘 / 第二块盘**各自**走同一套「精简 ntfs3 选项 → 切 ntfs-3g」链 | 第二块盘不再只 WARN 了事 |
| 成功后 `fstab_rebuild` 把**最终驱动与选项回写 fstab** | reboot 后 systemd 直接读到正确组合 |
| `x-systemd.device-timeout` 30s → **120s**（`--mount-timeout=` 可调） | 双 USB 盘 spin-up 来不及的问题 |
| 新增 `armbian-nas-mounts.timer` + `/usr/local/sbin/armbian-nas-mount-helper` | 开机 25s 首次、之后每 90s 检查每块盘；设备晚到 / nofail 跳过 / ntfs3 拒绝都能自动补挂并固化 fstab；日志 `/var/log/armbian-nas-mounts.log` |
| `--second-fstype=ntfs-3g` | 直接强制第二块盘用 ntfs-3g，等价于手写 `-t ntfs`，跳过 ntfs3 严格校验 |
| 自检新增 2 项 | 「两块外置盘均已挂载（逐盘判定）」「开机补挂自愈」 |

完整命令：

```bash
# 一键重建挂载配置 + 补挂单元（幂等，不动数据）
sudo ./armbian-nas-一键部署.sh --repair

# 直接强制第二块盘用 ntfs-3g（最快）
sudo ./armbian-nas-一键部署.sh --second-fstype=ntfs-3g --repair

# 手动立刻触发一次补挂并看日志
sudo systemctl start armbian-nas-mounts
sudo tail -30 /var/log/armbian-nas-mounts.log
sudo systemctl status armbian-nas-mounts.timer

# 不想要自愈单元
sudo ./armbian-nas-一键部署.sh --no-mount-helper --repair
```

> 补挂 helper 只改 fstab 的「文件系统类型 + 选项」两列，不动 UUID、挂载点，绝不对已挂载的盘 `umount`，绝不格式化、绝不 `force`、绝不 `ntfsfix`。

---

## 第二十一章 Transmission 打开显示 403 + FileBrowser 改密成功仍登不上（真机复盘）

### 21.1 Transmission WebUI 显示 `403: Forbidden`——不是 nginx 反代没配

**结论先行：Transmission 走 `:9091` 直连，不经过 nginx，你不需要、也不该往 nginx 里加 `location /transmission/`。**

有人会想当然地在 nginx 配一段：

```nginx
location /transmission/ {
    proxy_pass :9091;          # ✗ 无效：缺 scheme 与 host，nginx 直接报配置错
    proxy_set_header Host $host;
}
```

这段有三处问题：① `proxy_pass :9091` 不是合法地址（要写 `http://127.0.0.1:9091`）；② 若写成 `proxy_pass http://127.0.0.1:9091/;`（**带尾斜杠**），nginx 会把 `/transmission/rpc` 剥成 `/rpc`，而 **Transmission 的 RPC 端点恰恰叫 `/transmission/rpc`**，结果全 404；③ **它根本治不了 403**。另外 `$host` 不含端口，应传 `$http_host`。

**403 的真因是 Transmission 的 RPC 白名单。** 纯文本一行 `403: Forbidden` 正是白名单拒绝时的响应体。现代 Transmission（3.0+/4.x）有**两道**白名单，缺一都会 403：

| 键 | 作用 | 默认 |
|---|---|---|
| `rpc-whitelist-enabled` | IP 白名单，默认只放 `127.0.0.1` | 从别的机器访问 → 403 |
| `rpc-host-whitelist-enabled` | **Host 头白名单**，用 IP 访问时 Host 不在表里 → 403 | 直接 `http://IP:9091` 也会 403 |

脚本此前只关了第一道，**漏了 `rpc-host-whitelist-enabled`**。现已两道都关，并放行常见局域网段：

```python
d['rpc-whitelist-enabled'] = False
d['rpc-host-whitelist-enabled'] = False
d['rpc-host-whitelist'] = '127.0.0.1,localhost,*'
d['rpc-whitelist'] = '127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16'   # ★ 必须是字符串；写成 list 会被 daemon 忽略
```

立刻修（不用等新版）：

```bash
sudo systemctl stop transmission-daemon
sudo python3 - <<'PY'
import json
p="/mnt/sda1/www/transmission/settings.json"
d=json.load(open(p,encoding='utf-8'))
d['rpc-whitelist-enabled']=False
d['rpc-host-whitelist-enabled']=False
d['rpc-whitelist']='127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16'
d['rpc-host-whitelist-enabled']=False
d['rpc-host-whitelist']='127.0.0.1,localhost,*'
json.dump(d,open(p,'w',encoding='utf-8'),indent=2,ensure_ascii=False)
PY
sudo systemctl start transmission-daemon
curl -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9091/   # 应为 200
```

浏览器用 `http://<本机IP>:9091/` 打开（若之前选过中文增强界面，仍是这个地址，**不是** `/transmission/`）；首次若还是英文，按 `Ctrl+F5` 强刷缓存。

#### 21.1.1 如果你确实想要 80 端口统一入口（可选，与修 403 无关）

直连 `:9091` 已经够用；只是想在 `http://<IP>/transmission/` 打开时，才需要反代。**正确写法**：

```nginx
# /etc/nginx/snippets/armbian-nas-transmission.conf
location ^~ /transmission/ {
    proxy_pass http://127.0.0.1:9091;      # ★ 结尾【不要】加 /
    proxy_http_version 1.1;
    proxy_set_header Host              $http_host;   # 带端口，不是 $host
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_redirect off;
    proxy_buffering off;
}
```

`^~` 用来跳过 `location ~ \.php$` 等正则匹配。脚本一键生成（**默认关闭**，片段默认是 404 占位，直连 `:9091` 不受影响）：

```bash
sudo ./armbian-nas-一键部署.sh --tr-proxy=1 --repair
```

#### 21.1.2 为什么「脚本里明明修了，真机还是 403」

步骤 09 的状态已是 `done`，`run_step` 会跳过它 —— 代码改了不等于机器上的 `settings.json` 被重写过。本轮把重修接进了 `--repair`（⑪ 幂等：不重装、不询问、不动下载数据），并加了**真发 HTTP 请求**的校验：光检查配置文件里的键不算数，必须拿到 `200`。

顺带修了两处旧代码：`rpc-whitelist` 曾被写成 Python list（Transmission 要逗号分隔字符串，写成 list 会被忽略）；自检里 `ck FAIL` 少传一个参数，导致白名单即使已关也永远判 FAIL。现在自检会同时显示「RPC 白名单已关闭」和「WebUI 实际可打开（HTTP 200）」两项。

### 21.2 FileBrowser 改密成功却依然登不上——服务读的是另一个库

**现象**：`ps -ef | grep filebrowser` 显示

```
/usr/local/bin/filebrowser -d /mnt/sda1/www/filebrowse/filebrowser.db ...
```

注意是 `filebrowse`（**少一个 r**），而状态页 / 改密命令 / 文档全写 `filebrowser`。你 `users update` 改的是 `filebrowser/filebrowser.db`，服务却读 `filebrowse/filebrowser.db`——**改到了另一个库，旧密码当然不变**。

**这不是当前脚本的 bug**：现行 `step_filebrowser`（第 7041 行 unit、`fbdb` 变量）全程用正确拼写。它是**某个中间版本 / 手工改过的 unit** 遗留下来的；之后步骤 22 一直 `done` 被跳过，错误路径就一直留着。

**脚本已内置自愈**：每次运行开头 `sync_simple_creds → fb_db_reconcile()`（第 1428 行）会读取 unit 里真正的 `-d` 路径，与规范路径不一致时：停服 → 把「实际在用的库」`cp` 到规范路径（旧文件保留备份、不删数据）→ 重写 unit 的 `-d` → 收敛统一密码 → 启服。所以**只要用新版脚本重跑一次即可自动修好**：

```bash
sudo bash /root/armbian-nas-一键部署.sh --with-filebrowser --redo=22
# 或整表自愈（幂等，不动数据、不重装、不重新询问）：
sudo bash /root/armbian-nas-一键部署.sh --repair
sudo bash /root/armbian-nas-一键部署.sh --check | grep -E 'FileBrowser 数据库路径|Transmission 白名单'
```

不想重跑也能手动修（三选一）：

```bash
# 方案 A：让 unit 追随「实际在用的库」，并改其密码（最快，不搬数据）
sudo systemctl stop armbian-filebrowser
sudo filebrowser -d /mnt/sda1/www/filebrowse/filebrowser.db users update admin --password adminadmin123
sudo sed -i 's#-d /mnt/sda1/www/filebrowser/filebrowser.db#-d /mnt/sda1/www/filebrowse/filebrowser.db#' /etc/systemd/system/armbian-filebrowser.service
sudo systemctl daemon-reload && sudo systemctl start armbian-filebrowser

# 方案 B：把库搬到规范路径并让 unit 指过去（和脚本自愈等价）
sudo systemctl stop armbian-filebrowser
sudo cp -a /mnt/sda1/www/filebrowse/filebrowser.db /mnt/sda1/www/filebrowser/filebrowser.db
sudo sed -i 's#-d /mnt/sda1/www/filebrowse/filebrowser.db#-d /mnt/sda1/www/filebrowser/filebrowser.db#' /etc/systemd/system/armbian-filebrowser.service
sudo filebrowser -d /mnt/sda1/www/filebrowser/filebrowser.db users update admin --password adminadmin123
sudo systemctl daemon-reload && sudo systemctl start armbian-filebrowser
```

**两个坑仍要记住**（前两章已讲）：① FileBrowser 密码上游要求 **≥12 位**，`admin` / `adminadmin` 会被拒，统一默认用 `adminadmin123`；② `users update` 前**必须先停服**，否则 bbolt 独占锁报 `Error: timeout`、密码没改成功。

**教训**：状态页 / 文档里显示的数据库路径，一定要和运行进程 `ps -ef` 里的 `-d` 一致；显示路径来自模板、而真实路径来自 unit，两者一旦漂移就会「改密成功却登不上」。新增自检项会持续核对这两处。

本轮又收紧了三处：① 全脚本只用**单一来源** `FB_DB="$BASE/filebrowser/filebrowser.db"`，unit、改密、状态页、路径清单、自检全部引用它，禁止再拼字面量；② 状态页改密命令改用 `__FB_DB__` 占位符注入，页面显示的路径永远等于脚本实际用的路径，并新增一行「改密前先 `systemctl cat armbian-filebrowser | grep ExecStart` 核对 `-d`」；③ 自检新增 `fb_db_path_ok`（库存在且 unit 指向同一路径）与 `fb_db_single_source_ok`（防再次漂移）。

---

### 21.3 一条命令把两个问题一起修完

```bash
sudo cp armbian-nas-一键部署.sh armbian-nas-使用说明.md prober.php /root/
sudo /root/armbian-nas-一键部署.sh --repair
```

`--repair` 幂等：不重装软件、不重新询问组件、不删数据。本轮新增 ⑪ 会重修 Transmission 白名单并验证 `HTTP 200`；开头 `sync_simple_creds → fb_db_reconcile()` 会自动完成 FileBrowser 数据库迁移与统一密码收敛。

验证清单：

```bash
curl -I http://127.0.0.1:9091/                            # 应为 200，不再是 403
sudo systemctl cat armbian-filebrowser | grep ExecStart    # -d 应指向 .../filebrowser/filebrowser.db
curl -I http://<本机IP>:8082                              # 登录页应能打开
sudo /root/armbian-nas-一键部署.sh --check | grep -E '数据库路径|白名单|HTTP 200'
```

浏览器打开 `http://<本机IP>:8082`，账号 `admin`、密码 `adminadmin123`（≥12 位，见第十九章）；状态页「统一凭据」区块也会显示。改密永远按「停服 → 改 `-d` 指向的那个库 → 启服」三步走（见第十八、十九章）。

## 第二十二章 qB WebUI 登录报 `Invalid Username or Password / Server response: Fails.`（完整复盘）

### 22.1 现象与根因

打开 `http://<本机IP>:8080` 输入账号密码，页面提示：

```
Invalid Username or Password.
Server response: Fails.
```

三个原因叠加：

1. **配置里没有 WebUI 账号字段。** qBittorrent 4.6+ / 5.x 不再使用固定的 `admin/adminadmin`；首次启动会生成随机临时密码（见 systemd 日志）。如果 `$BASE/qb/config/qBittorrent/qBittorrent.conf` 里缺 `WebUI\Username` 和 `WebUI\Password_PBKDF2`，任何密码都会被拒绝。
2. **安全策略拦截登录请求。** 用局域网 IP 直接访问时，`WebUI\HostHeaderValidation` 和 `WebUI\CSRFProtection` 会让登录请求被拦下，返回的却同样是“密码错误”提示，非常容易误判。
3. **边运行边改配置会被冲掉。** qB 退出时把自己内存里的配置写回文件，运行中直接改 conf 会被覆盖。这正是真机上“`killall qbittorrent-nox` 之后再改才生效”的原因。

### 22.2 脚本的统一实现：停服 → 写配置 → 起服 → curl 自检

脚本把整个流程收敛成一对函数，步骤 08（`step_qb`）和 `--repair` 自愈共用同一份实现，不会出现两份逻辑漂移。

`qb_apply_config <conf> [也写/root/.config]`：

| 阶段 | 动作 |
|---|---|
| ① 停服 | 服务在跑才停：`systemctl stop qbittorrent-nox`，再 `pkill -x qbittorrent-nox`，`sleep 1` 等端口释放 |
| ② 备份 | `cp -a` 成 `qBittorrent.conf.bak.<时间戳>`，可回滚，不删下载数据 |
| ③ 写配置 | `qb_conf_write_auth` 用 Python 现算 PBKDF2 哈希写入（见下表） |
| ④ 同步 | 可选同步写 `/root/.config/qBittorrent/qBittorrent.conf`，消除旧路径残留 |
| ⑤ 起服 | `daemon-reload` → `enable --now`（失败回退 `start`） |
| ⑥ 等就绪 | 最多 8 秒轮询 `http://127.0.0.1:<PORT>/` |
| ⑦ curl 自检 | `qb_curl_login_check`：POST `/api/v2/auth/login`，带 Referer 和 cookie jar，判断 **HTTP 200 且响应体以 `Ok.` 开头**。qB 登录成功返回 `Ok.`，失败返回 `Fails.`，**两者 HTTP 都是 200**，所以必须看响应体 |

写入的 `[Preferences]` 关键字段：

```ini
[LegalNotice]
Accepted=true

[Preferences]
General\Locale=zh_CN          # 中文界面
WebUI\Port=8080
WebUI\Address=*
WebUI\HostHeaderValidation=false
WebUI\CSRFProtection=false
WebUI\AuthSubnetWhitelistEnabled=false
WebUI\AuthSubnetWhitelist=@Invalid()
WebUI\Username=admin
WebUI\Password_PBKDF2=@ByteArray(<salt_b64>:<hash_b64>)
```

- 密码算法：`PBKDF2-HMAC-SHA512`，迭代 100000 次，16 字节随机盐，派生密钥 **64 字节**（写 32 字节 qB 会登录失败）。`@ByteArray(...)` 外层加不加双引号等价：脚本按真机实测格式写入**带双引号**的形式，与用户手改 conf 的写法一致，QSettings 读取时会去掉引号。
- 已有配置里已经有 `Password_PBKDF2` 时**保留不改**；只有第一次写入或显式指定 `--qb-password=<新密码>` 时才重新计算。
- `step_qb` 起服后最多重试 6 次（每次间隔 2 秒）做 curl 登录自检，成功打印 `[OK]`，失败打印排查命令。
- 自愈判据升级：**字段齐全 + 真实登录成功**，两者都满足才算通过。只查字段会在“字段在、但密码被首次启动的临时密码覆盖”时漏修，这正是真机登不上的主因。

### 22.3 完整命令

```bash
# 重新部署 qB（写入凭据 + curl 自检）
sudo ./armbian-nas-一键部署.sh --with-qb --redo=08

# 自定义 WebUI 密码（至少 12 位）
sudo ./armbian-nas-一键部署.sh --qb-password='你的新密码' --redo=08

# --repair 第 ⑪ 项：字段缺或登录不了都会自动重修（不重装、不动下载数据）
sudo ./armbian-nas-一键部署.sh --repair

# 只看自检结果
sudo ./armbian-nas-一键部署.sh --check | grep -A2 qB
```

验证：

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/        # 期望 200
systemctl cat qbittorrent-nox | grep XDG_CONFIG_HOME                   # 应指向 $BASE/qb/config
grep -E 'WebUI\\(Username|Password_PBKDF2)' /mnt/sda1/www/qb/config/qBittorrent/qBittorrent.conf
```

浏览器打开 `http://<本机IP>:8080`，用 **admin / adminadmin** 登录，界面是中文。

### 22.4 手动修复（不跑脚本）

```bash
sudo systemctl stop qbittorrent-nox
sudo pkill -x qbittorrent-nox || true
CONF=/mnt/sda1/www/qb/config/qBittorrent/qBittorrent.conf
sudo cp -a "$CONF" "$CONF.bak.$(date +%F-%H%M%S)"
HASH=$(python3 - <<'PY'
import hashlib, base64, os
pw=b"adminadmin"; salt=os.urandom(16)
dk=hashlib.pbkdf2_hmac("sha512", pw, salt, 100000)
print("@ByteArray(%s:%s)" % (base64.b64encode(salt).decode(), base64.b64encode(dk).decode()))
PY
)
sudo python3 - "$CONF" "$HASH" <<'PY'
import sys, re
conf, h = sys.argv[1], sys.argv[2]
kv = {"General\\Locale":"zh_CN", "WebUI\\Port":"8080", "WebUI\\Address":"*",
      "WebUI\\HostHeaderValidation":"false", "WebUI\\CSRFProtection":"false",
      "WebUI\\Username":"admin", "WebUI\\Password_PBKDF2":h}
txt = open(conf, encoding="utf-8").read() if __import__("os").path.exists(conf) else ""
if "[Preferences]" not in txt:
    txt += "\n[Preferences]\n"
for k, v in kv.items():
    line = "%s=%s" % (k, v)
    if re.search(r"^%s=" % re.escape(k), txt, re.M):
        txt = re.sub(r"^%s=.*$" % re.escape(k), line, txt, flags=re.M)
    else:
        txt = txt.replace("[Preferences]", "[Preferences]\n" + line, 1)
open(conf, "w", encoding="utf-8").write(txt)
PY
sudo systemctl enable --now qbittorrent-nox
```

### 22.5 注意事项

- 不要手填网上流传的固定 `Password_PBKDF2` 串，换密码就失效；用 `--qb-password=` 让脚本现算。
- `/root/.config/qBittorrent/` 是旧路径留下的副本，真正生效的是 unit 里 `XDG_CONFIG_HOME` 指向的 `$BASE/qb/config`。脚本两份都写，但以 `$BASE` 那份为准，不要只改 `/root/.config`。
- 关掉 `HostHeaderValidation` / `CSRFProtection` 只适合**信任内网**。把 8080 映射到公网前，改回 `true` 并加反向代理鉴权。
- 默认口令只适合内网自用，登录后建议在 WebUI 里改密；改完再跑脚本不会被覆盖（脚本只在字段缺失或 `--qb-password=` 时才重写）。
