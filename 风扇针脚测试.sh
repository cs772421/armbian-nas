#!/usr/bin/env bash
# ===========================================================================
# 比特米盒 / Khadas VIM1 (S905X) 风扇针脚测试 —— 小白专用入口
# ---------------------------------------------------------------------------
# 【你已经测出来了】fan.sh 实测结果：
#   [1/10] GPIO 515 - J9排针 Pin35 (GPIOAO_3)  →  输入 y 确认
#   → 风扇 = sysfs 全局编号 515，高电平(写1)开、低电平(写0)关。
#
# 所以本脚本默认就针对 515 再跑一遍严格的两轮确认，然后写入温控服务：
#   ① 执行【开】→ 等几秒 → 问「风扇转了吗？」必须输入 y
#   ② 只有 y 才执行【关】→ 再等几秒 → 问「风扇停了吗？」必须再输入 y
#   ③ 两轮都通过 → 生成 /etc/default/armbian-fan + systemd 服务并 enable
#      （≥50℃ 开 / ≤48℃ 关，带滞回、最短运行、温度失效保护）
#   ④ 任一 n → 立即恢复关闭，不写服务，给排查建议
#
# 【你只需要做】
#   sudo bash ./风扇针脚测试.sh
#   看着/听着风扇，按提示输入 y 或 n（一共两次）。
#
# 【想重新逐个排查 10 个引脚】
#   sudo bash ./风扇针脚测试.sh --scan
#   候选 = fan.sh 里那 10 个「排针引出、未被系统关键功能占用」的
#   sysfs 全局编号：515 516 517 518 544 545 546 547 548 622（+ 504 备选）。
#   脚本【逐个显式列出】测试，绝不枚举区间。
#
# 【其它变体】
#   --pin=516              换一个已实测编号（默认 515）
#   --probe-hold=8         每轮多等几秒
#   --fan-probe-only       只记录两轮确认结果，暂不启用服务
#   --fan-active-high=0    低电平触发（fan.sh 提示的反相情况）
#   --probe-sysfs=504      --scan 时额外加一个候选
#
# 【安全】
#   * 绝不自动逐线扫描 GPIO
#   * ⚠⚠ 严禁测试 gpiochip1 的【line 70~80】：会掉线，必须拔电重启。
#     注意那是 libgpiod 的 line 编号，和这里的 sysfs 全局编号 515 不是
#     同一套命名空间 —— 别混淆。
#   * 515 是纯风扇引脚：脚本【绝不联动】474/476/477 面板灯，
#     那三个编号在你这套 dtb 下是别的线，误写可能触发其它功能。
#   * 中途 Ctrl+C / 退出都会尽力把风扇恢复到关闭
#   * 若提示 "Unit armbian-fan.service not loaded" —— 完全正常，
#     说明脚本还没部署到这台机器，不是故障
#   * 本步骤不挂载外置盘、不改 /etc/fstab、不进 tmux，盘没插好也能测
#
# 真正干活的是同目录的 armbian-nas-一键部署.sh（--fan-probe 分支）。
# ===========================================================================
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN="$DIR/armbian-nas-一键部署.sh"

if [[ ! -r "$MAIN" ]]; then
  echo "找不到主脚本：$MAIN" >&2
  echo "请把本文件和 armbian-nas-一键部署.sh 放在同一个目录里。" >&2
  exit 1
fi
[[ "$(id -u)" -eq 0 ]] || { echo "请用 root 运行：sudo bash $0" >&2; exit 1; }

PIN=515
SCAN=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --scan)        SCAN=1 ;;
    --pin=*)       PIN="${a#*=}" ;;
    *)             ARGS+=("$a") ;;
  esac
done

echo "风扇针脚测试：本机实测 GPIO 515（J9 Pin35 / GPIOAO_3）"
if [[ "$SCAN" -eq 1 ]]; then
  echo "模式：--scan，逐个测试 fan.sh 的 10 个安全 sysfs 编号（两轮确认）"
  # 转发主脚本自己的 --scan 分支（主脚本会清空 --fan-confirmed 走全候选），
  # 不再只传 --fan-probe，保证两条命令走同一套逻辑。
  exec bash "$MAIN" --scan "${ARGS[@]}"
else
  echo "模式：只验证 GPIO $PIN 这一根（开→转 / 关→停 两轮确认），通过后写入温控服务"
  echo "想改成逐个排查：sudo bash $0 --scan"
  echo
  exec bash "$MAIN" --fan-probe --fan-confirmed="$PIN" "${ARGS[@]}"
fi
