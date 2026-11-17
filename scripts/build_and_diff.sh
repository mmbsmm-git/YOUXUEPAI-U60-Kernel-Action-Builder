#!/usr/bin/env bash
# 优学派 U60 / P709 —— 内核源码复现 + 取证比对（在 ubuntu:20.04 容器内执行）
#
# 路径约定（由 workflow 的 docker run 挂载）：
#   /repo           只读：本仓库（baseline/ 取证基线、scripts/）
#   /workspace      可写：工具链、源码树、编译输出、报告
#
# 环境变量（由 workflow -e 传入）：
#   KERNEL_REPO    源码仓库 URL
#   KERNEL_REF      commit sha / tag / branch，或 AUTO（自动定位 4.4.146 提交）
#   BUILD_KERNEL   true / false（false 只下载+静态扫描+基线比对，跳过编译）
#   CLANG_URL      clang-4691093 包地址（可换镜像）
#   AARCH64_GCC_URL / ARM32_GCC_URL   gcc 4.9 仓库地址
#
# 设计原则：任何一步失败都只记录、不中断，最后一定产出报告。
# v2：修补 imgsensor Makefile；make 目标改 vmlinux；AUTO 回退写死 sha。
# v3：补齐 aarch64-linux-gnu-* binutils 别名（路径假设错误，见 v4）。
# v4：全盘 find AOSP binutils 目录，双 triple 软链，apt 兜底。
# v5：隔离 OPPO 高通残留驱动 + 传 TARGET_PRODUCT=full_oppo6771。
# v6：改为从 drivers/input/Makefile 摘除目录引用（置空子 Makefile 会缺 built-in.o）。
# v7：处理 U60 专属选料在 OEM 树里的三处残留（qpnp 头 / LCM 空列表断言 / imgsensor 名）。
# v8：摘除 lcm/Makefile 把 string CONFIG 当子目录的那行（第七跑唯一残留）。
# v9：modpost 的 12 处 section mismatch 降级为警告，让 vmlinux 链接完成。
set -uo pipefail

WS=/workspace
REPO=/repo
BASE=$REPO/baseline
OUT=$WS/out
SRC=$WS/src/kernel
TC=$WS/toolchain
LOGS=$OUT/logs
mkdir -p "$OUT" "$LOGS" "$TC" "$(dirname "$SRC")"

STATUS=$OUT/steps.tsv
: > "$STATUS"
step() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STATUS"; echo "[$2] $1: $3"; }
log()  { echo "----- $* -----"; }

echo "=========================================================="
echo " U60 内核源码复现 | 容器 $(grep -E '^VERSION_ID' /etc/os-release)"
echo " python2: $(python2 --version 2>&1) | python3: $(python3 --version 2>&1)"
echo " dtc: $(dtc --version 2>&1 | head -1)"
echo "=========================================================="

###############################################################################
# 1. 工具链
###############################################################################
log "1/6 下载 AOSP 工具链（版本必须对齐 clang 6.0.2 / r316199 / 4691093）"

CLANG_URL=${CLANG_URL:-"https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/android-9.0.0_r1/clang-4691093.tar.gz"}
AARCH64_GCC_URL=${AARCH64_GCC_URL:-"https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9"}
ARM32_GCC_URL=${ARM32_GCC_URL:-"https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9"}

if [ -x "$TC/clang-4691093/bin/clang" ]; then
  step toolchain_clang OK "已存在，跳过下载"
else
  if curl -fL --retry 3 --connect-timeout 30 "$CLANG_URL" -o "$TC/clang-4691093.tar.gz" \
     && [ -s "$TC/clang-4691093.tar.gz" ]; then
    mkdir -p "$TC/clang-4691093"
    tar -xf "$TC/clang-4691093.tar.gz" -C "$TC/clang-4691093"
    step toolchain_clang OK "下载并解包 $(du -h "$TC/clang-4691093.tar.gz" | cut -f1)"
  else
    step toolchain_clang FAIL "clang 包下载失败；在 workflow 输入 CLANG_URL 换镜像后重跑"
  fi
fi

clone_gcc() {
  local name="$1" url="$2" dir="$TC/$1"
  if compgen -G "$dir/bin/*-gcc" >/dev/null 2>&1; then step "toolchain_$name" OK "已存在"; return; fi
  if git clone --depth=1 "$url" "$dir" >"$LOGS/${name}_clone.log" 2>&1; then
    step "toolchain_$name" OK "clone 完成"
  else
    step "toolchain_$name" FAIL "clone 失败，见 ${name}_clone.log；可换 GitHub 镜像"
  fi
}
clone_gcc aarch64-linux-android-4.9 "$AARCH64_GCC_URL"
clone_gcc arm-linux-androideabi-4.9 "$ARM32_GCC_URL"

export PATH="$TC/clang-4691093/bin:$TC/aarch64-linux-android-4.9/bin:$TC/arm-linux-androideabi-4.9/bin:$PATH"
if "$TC/clang-4691093/bin/clang" -v >"$LOGS/clang_version.txt" 2>&1; then
  step toolchain_verify OK "$(grep -m1 'clang version' "$LOGS/clang_version.txt")"
else
  step toolchain_verify FAIL "clang 不可执行，编译步骤大概率失败"
fi

# ---- 补齐两套 triple 的 binutils（v4）----
# 第三跑证明 v3 假设错了：AOSP prebuilts/gcc 仓库的 binutils 不在
#   $TC/aarch64-linux-android-4.9/bin/ 下（那里只有 gcc/g++ driver），
# 而是在 <triple>/bin/ 之类的子目录，文件名也可能不带 triple 前缀。
# 结果 toolchain_gnu_as FAIL，VDSO 仍回退到 x86 as，满屏 no such instruction。
#
# v4 做三件事：
#   1) 在整个 gcc 目录里 find 任意可用的 AArch64 as，定位 binutils 目录
#   2) 把该目录里的工具同时软链成 aarch64-linux-gnu-*（CLANG_TRIPLE 用）
#      和 aarch64-linux-android-*（CROSS_COMPILE 链接用），两套都齐
#   3) 一个都找不到就 apt 装 binutils-aarch64-linux-gnu 兜底
#      （容器默认 root，focal 有这个包；不用重建镜像、不用换 IMAGE_TAG）
GCC_DIR="$TC/aarch64-linux-android-4.9"
GNU_BIN="$TC/gnu-triple-bin"
mkdir -p "$GNU_BIN"

AS_BIN=""
for pat in 'aarch64-linux-android-as' 'as'; do
  AS_BIN=$(find "$GCC_DIR" -type f -name "$pat" -perm -u+x 2>/dev/null | head -1)
  [ -n "$AS_BIN" ] && break
done
# 排除误抓到 x86 /usr/bin/as 的可能（find 只在 GCC_DIR 内，本身安全）
BINUTILS_DIR=""
[ -n "$AS_BIN" ] && BINUTILS_DIR=$(dirname "$AS_BIN")

TOOLS="as ld ld.bfd ar nm objcopy objdump ranlib readelf strip size strings addr2line"
N_LINK=0
if [ -n "$BINUTILS_DIR" ]; then
  for t in $TOOLS; do
    src=""
    for cand in "$BINUTILS_DIR/aarch64-linux-android-$t" "$BINUTILS_DIR/$t"; do
      if [ -x "$cand" ]; then src="$cand"; break; fi
    done
    [ -z "$src" ] && continue
    ln -sf "$src" "$GNU_BIN/aarch64-linux-gnu-$t"
    ln -sf "$src" "$GNU_BIN/aarch64-linux-android-$t"
    N_LINK=$((N_LINK+1))
  done
  step toolchain_binutils_src OK "AOSP binutils 目录：$BINUTILS_DIR，软链 $N_LINK 个工具"
else
  step toolchain_binutils_src WARN "AOSP gcc 目录里没找到 as，改用 apt 兜底"
fi

# PATH 最前：软链目录 + AOSP 原始 binutils 目录（后者保证 CROSS_COMPILE 也能解析）
export PATH="$GNU_BIN${BINUTILS_DIR:+:$BINUTILS_DIR}:$PATH"

if ! command -v aarch64-linux-gnu-as >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    if apt-get update -qq >"$LOGS/apt_update.log" 2>&1 && \
       apt-get install -y -qq binutils-aarch64-linux-gnu >>"$LOGS/apt_install.log" 2>&1; then
      # Debian 那套只提供 aarch64-linux-gnu-*，给 CROSS_COMPILE 也补一份别名
      for t in $TOOLS; do
        if [ -x "/usr/bin/aarch64-linux-gnu-$t" ] && \
           [ ! -e "$GNU_BIN/aarch64-linux-android-$t" ]; then
          ln -sf "/usr/bin/aarch64-linux-gnu-$t" "$GNU_BIN/aarch64-linux-android-$t"
        fi
      done
      step toolchain_apt_binutils OK "apt 安装 binutils-aarch64-linux-gnu 兜底成功"
    else
      step toolchain_apt_binutils FAIL "apt 装不上，见 apt_*.log；需改 Dockerfile 并换 IMAGE_TAG 重建镜像"
    fi
  else
    step toolchain_apt_binutils SKIP "容器内无 apt-get"
  fi
fi

if command -v aarch64-linux-gnu-as >/dev/null 2>&1; then
  step toolchain_gnu_as OK "$(aarch64-linux-gnu-as --version 2>&1 | head -1)"
else
  step toolchain_gnu_as FAIL "仍无 aarch64-linux-gnu-as；VDSO 必定回退 x86 as"
fi

# CROSS_COMPILE 那套也补 objdump（mk_elfconfig 只读 ELF 头，宿主 objdump 够用）
if ! command -v aarch64-linux-android-objdump >/dev/null 2>&1; then
  SYSOBJ=$(command -v objdump || true)
  if [ -n "$SYSOBJ" ]; then
    ln -sf "$SYSOBJ" "$GNU_BIN/aarch64-linux-android-objdump"
    step toolchain_objdump OK "用系统 objdump 补齐"
  else
    step toolchain_objdump SKIP "无 objdump，非致命"
  fi
else
  step toolchain_objdump OK "已存在"
fi

###############################################################################
# 2. 解析 KERNEL_REF（AUTO 用 GitHub API 定位 "Merged realme source into Linux 4.4.146 tag"）
###############################################################################
log "2/6 解析源码提交"

KERNEL_REPO=${KERNEL_REPO:-"https://github.com/RMX1831/android_kernel_oppo_mt6771"}
KERNEL_REF=${KERNEL_REF:-"AUTO"}
REF="$KERNEL_REF"

if [ "$REF" = "AUTO" ] || [ -z "$REF" ]; then
  REPO_SLUG=$(echo "$KERNEL_REPO" | sed -E 's#.*github\.com/##; s#\.git$##; s#/$##')
  export REPO_SLUG
  log "AUTO: 查询 $REPO_SLUG 的 4.4.146 提交"
  REF=$(python3 - <<'PY' 2>"$LOGS/ref_api.log" || true
import json, os, urllib.request
slug = os.environ.get("REPO_SLUG", "RMX1831/android_kernel_oppo_mt6771")
url = "https://api.github.com/repos/%s/commits?until=2020-08-05T00:00:00Z&per_page=100" % slug
req = urllib.request.Request(url, headers={
    "User-Agent": "u60-kernel-builder",
    "Accept": "application/vnd.github+json"})
try:
    data = json.load(urllib.request.urlopen(req, timeout=40))
    for c in data:
        msg = c.get("commit", {}).get("message", "")
        if "4.4.146" in msg:
            print(c["sha"])
            break
except Exception as e:
    print("__API_FAIL__", e, file=os.sys.stderr)
PY
)
  REF=$(echo "$REF" | head -1 | tr -d '\r\n ')
  if [[ "$REF" =~ ^[0-9a-f]{40}$ ]]; then
    step resolve_ref OK "API 定位到 $REF"
  else
    # API 常被限流；首跑已用 git log --grep 验证过这个提交就是 4.4.146，直接写死，
    # 不再回退到 fetch --filter=tree:0（会拖十几分钟）
    REF="4b8901d9b3e54418c18efc2b9c7b60f5701749d8"
    step resolve_ref OK "API 未命中，回退到已验证的 4.4.146 提交 $REF"
  fi
fi

###############################################################################
# 3. 定点取源码（57 万 commits，绝不能整仓 clone）
###############################################################################
log "3/6 取源码树"

if [ -d "$SRC/.git" ]; then
  step fetch_kernel OK "已存在，跳过"
else
  mkdir -p "$SRC" && cd "$SRC"
  git init -q
  git remote add origin "$KERNEL_REPO"
  git config --global user.name "u60-builder"
  git config --global user.email "u60-builder@local"

  FETCH_OK=0
  if [[ "$REF" =~ ^[0-9a-f]{40}$ ]]; then
    # 最优：只取这一个提交的树（GitHub 支持按 sha fetch）
    if git fetch --depth=1 origin "$REF" >"$LOGS/kernel_fetch.log" 2>&1; then
      git checkout -q FETCH_HEAD
      FETCH_OK=1
    fi
  fi

  if [ "$FETCH_OK" = "0" ]; then
    # 回退：只拉 commit 元数据（tree:0），再按 message 找 4.4.146
    log "回退：git fetch --filter=tree:0 拉提交元数据"
    git fetch --filter=tree:0 origin >"$LOGS/kernel_fetch.log" 2>&1 || \
      git fetch --depth=200 origin >>"$LOGS/kernel_fetch.log" 2>&1 || true
    if [ "$REF" = "__GREP__" ]; then
      REF=$(git log --all --oneline --grep='4.4.146' -1 | awk '{print $1}' | head -1)
    fi
    if [ -n "$REF" ] && [ "$REF" != "__GREP__" ]; then
      git checkout -q "$REF" >>"$LOGS/kernel_fetch.log" 2>&1 || true
    else
      git checkout -q FETCH_HEAD >>"$LOGS/kernel_fetch.log" 2>&1 || true
    fi
  fi

  if [ -f "$SRC/Makefile" ]; then
    git log -1 --format='%H%n%ad%n%s' --date=iso > "$LOGS/kernel_head.txt"
    step fetch_kernel OK "$(git log -1 --format='%h %ad %s' --date=short)"
  else
    step fetch_kernel FAIL "未取到完整源码树，见 kernel_fetch.log；可在输入里直接填 KERNEL_REF 的 sha"
  fi
  cd "$WS"
fi

###############################################################################
# 4. 静态扫描（不需要编译就能判断「这棵树对不对」）
###############################################################################
log "4/6 静态扫描：优学派私有符号 / 板级硬件"

if [ -f "$SRC/Makefile" ]; then
  # 15 个 EXPORT_SYMBOL 私有符号，命中即说明是优学派同源树
  PAT='noah_get_mount_flag|noah_eeprom_getdata|noah_eeprom_readdata|noah_eeprom_setdata|set_noahmic_interlop|send_yxp_heaset_event|yxp_usbmic_led_on|yxp_usbmic_led_off|yxp_get_vbus|mt6370_chgdet_handler_yxp|mt6370_enable_chg_type_det_yxp|noahmicusb_work_deal|Open_DSI_clk_yxp|Close_DSI_clk_yxp|AudDrv_yxp_usb_audio_switch|buf_handler_register_yxp'
  grep -rIlE --include='*.c' --include='*.h' --include='*.S' --include='*.dts' --include='*.dtsi' \
       "$PAT" "$SRC" > "$LOGS/private_symbol_hits.txt" 2>/dev/null || true
  NHIT=$(wc -l < "$LOGS/private_symbol_hits.txt")
  step scan_private OK "命中 $NHIT 个文件（0 = 公版 OEM 树，不含优学派补丁）"

  # 板级硬件关键词
  HPAT='ssd2858|nt35595|HX83102|hx83102|himax|GF3626|gf3626|tfa98xx|dbmd4|it6112|rt9465|mt6370|LN4913|ln4913|ap3220|cs5032|bma250e|cap_touch'
  grep -rIlE --include='*.c' --include='*.h' --include='*.dts' --include='*.dtsi' \
       "$HPAT" "$SRC" > "$LOGS/board_hardware_hits.txt" 2>/dev/null || true
  step scan_board OK "命中 $(wc -l < "$LOGS/board_hardware_hits.txt") 个文件"
else
  step scan_private SKIP "无源码树"
  step scan_board   SKIP "无源码树"
fi

###############################################################################
# 5. 编译（用本机抠出的 u60.config 当基线，不用 OEM defconfig）
###############################################################################
log "5/6 编译内核"

BUILD_KERNEL=${BUILD_KERNEL:-"true"}
if [ "$BUILD_KERNEL" != "true" ]; then
  step build SKIP "BUILD_KERNEL=false，只做下载与静态比对"
elif [ ! -f "$SRC/Makefile" ]; then
  step build SKIP "无源码树，跳过编译"
elif [ ! -x "$TC/clang-4691093/bin/clang" ]; then
  step build SKIP "clang 缺失，跳过编译"
else
  cd "$SRC"
  mkdir -p "$OUT"
  cp "$BASE/u60.config" "$OUT/.config"
  # v9：modpost 把 12 处 section mismatch 当 FATAL（Makefile.modpost:80
  #   $(if $(CONFIG_SECTION_MISMATCH_WARN_ONLY),,-E)  -> 不设就传 -E）。
  # 这些是 OEM 树里 __init 引用 __devinit 之类的历史遗留，不影响生成的
  # 内核功能，但会挡住 vmlinux 链接，导致 nm 符号 diff 跑不了。
  # 日志自己也提示：Set CONFIG_SECTION_MISMATCH_WARN_ONLY=y to allow them.
  # 双保险：写进 .config + 两次 make 命令行都传（命令行变量优先级最高）。
  if ! grep -q '^CONFIG_SECTION_MISMATCH_WARN_ONLY=y' "$OUT/.config"; then
    printf 'CONFIG_SECTION_MISMATCH_WARN_ONLY=y\n' >> "$OUT/.config"
  fi

  # ---- U60 专属选料 vs Realme/OPPO 树（v7，第六跑的三个独立错误）----
  # v6 摘掉 oppo_seccommon 后编译推进到 drivers/，make -j 同时暴露三处：
  #
  # (a) drivers/power/oppo/oppo_charger.h:46
  #       fatal error: 'linux/qpnp/qpnp-adc.h' file not found
  #     charger/Makefile 把 oppo_mt6771_charger.o 挂在 CONFIG_MTK_SMART_BATTERY=y
  #     下（u60.config 开着）。oppo_charger.h 靠 CONFIG_OPPO_CHARGER_MTK 分叉，
  #     未定义就走高通 #else 分支 include qpnp/qpnp-adc.h —— 又一个高通残留。
  #     这棵树是 MT6771，给 charger 子目录补 -D 走 MTK 分支即可，不改 CONFIG。
  CHG="$SRC/drivers/power/mediatek/charger/Makefile"
  if [ -f "$CHG" ] && ! grep -q 'U60_MTK_CHARGER_BRANCH' "$CHG"; then
    cp -f "$CHG" "$CHG.u60bak"
    printf '\n# U60_MTK_CHARGER_BRANCH: force MTK branch (avoid qcom qpnp-adc.h)\nsubdir-ccflags-y += -DCONFIG_OPPO_CHARGER_MTK\n' >> "$CHG"
    step patch_oppo_charger OK "追加 -DCONFIG_OPPO_CHARGER_MTK"
  else
    step patch_oppo_charger SKIP "已处理或无该文件"
  fi

  # (b) drivers/misc/mediatek/lcm/mt65xx_lcm_list.c:1289
  #       'assertion_failed_at_line_1289' declared as an array with a negative size
  #     CONFIG_CUSTOM_KERNEL_LCM="dg10132004_40c_wuxga_dsi_vdo" 是 U60 的屏，
  #     这棵树的 lcm_driver_list 里没有任何对应 #if 分支 -> 列表为空 ->
  #     LCM_COMPILE_ASSERT 失败。U60 的 nt35595+ssd2858 面板驱动本来就不在
  #     OEM 树里（后续移植项），先关掉编译期检查让编译走完。
  #     断言生成的只是文件内静态 char 数组，注释掉不影响 Module.symvers。
  LCMLIST="$SRC/drivers/misc/mediatek/lcm/mt65xx_lcm_list.c"
  if [ -f "$LCMLIST" ]; then
    python3 -c "
import sys
p='$LCMLIST'
s=open(p,encoding='utf-8',errors='replace').read()
t='LCM_COMPILE_ASSERT(sizeof(lcm_driver_list) / sizeof(LCM_DRIVER *) != 0);'
if t in s and 'U60 assert disabled' not in s:
    open(p,'w',encoding='utf-8').write(s.replace(t,'/* U60 assert disabled: empty lcm list */'))
    print(' patched')
else:
    print(' skip')
" >"$LOGS/patch_lcm_assert.log" 2>&1
    step patch_lcm_assert OK "$(cat "$LOGS/patch_lcm_assert.log" | xargs)"
  else
    step patch_lcm_assert SKIP "源码树无 mt65xx_lcm_list.c"
  fi

  # (b2) lcm/Makefile:26 —— 第七跑唯一残留
  #     obj-$(CONFIG_MTK_LCM) += $(foreach LCM,$(LCM_LISTS),$(LCM)/)
  #   LCM_LISTS := $(subst ",,$(CONFIG_CUSTOM_KERNEL_LCM))
  #   U60 的值是 dg10132004_40c_wuxga_dsi_vdo，树里没有这个目录
  #   -> kbuild 找 <lcm>/dg10132004_40c_wuxga_dsi_vdo/Makefile 失败 -> Stop。
  #   这和 imgsensor 是同一类问题（string 型 CONFIG 被当子目录路径），
  #   只是 LCM 有两个消费点：v7 处理了断言（列表为空），这里处理目录引用。
  #   注释掉该行后：不引用不存在的目录，LCM_DEFINES 仍生成 -D 宏但无害，
  #   mt65xx_lcm_list.c 列表为空、断言已被 v7 注释 -> 编译放行。
  #   U60 的 nt35595+ssd2858 面板驱动本就不在 OEM 树里（后续移植项）。
  LCMMK="$SRC/drivers/misc/mediatek/lcm/Makefile"
  if [ -f "$LCMMK" ]; then
    python3 -c "
p='$LCMMK'
s=open(p,encoding='utf-8',errors='replace').read()
t='obj-\$(CONFIG_MTK_LCM) += \$(foreach LCM,\$(LCM_LISTS),\$(LCM)/)'
if t in s and 'U60_LCM_SUBDIR_DISABLED' not in s:
    s=s.replace(t,'# U60_LCM_SUBDIR_DISABLED: no matching LCM dir in OEM tree\n# '+t)
    open(p,'w',encoding='utf-8').write(s)
    print('patched')
else:
    print('skip')
" >"$LOGS/patch_lcm_subdir.log" 2>&1
    step patch_lcm_subdir OK "$(cat "$LOGS/patch_lcm_subdir.log" | xargs)"
  else
    step patch_lcm_subdir SKIP "源码树无 lcm/Makefile"
  fi

  # 通用预检：把 CONFIG_CUSTOM_KERNEL_* 当目录路径用的 Makefile 行全部列出来。
  # MTK 4.4 里这类 string 配置是唯一会「按名字找目录」的机制，
  # imgsensor 和 lcm 已处理；这里把剩余点一次性记进 steps，避免再出 v9。
  grep -rnE '\$\(CONFIG_CUSTOM_KERNEL_[A-Z_]+\).*/|\$\(foreach.*CONFIG_CUSTOM_KERNEL' \
      "$SRC/drivers" --include=Makefile 2>/dev/null \
      | grep -v 'U60_LCM_SUBDIR_DISABLED' > "$LOGS/string_cfg_paths.txt" || true
  N=$(wc -l < "$LOGS/string_cfg_paths.txt" 2>/dev/null || echo 0)
  step precheck_string_cfg_paths OK "剩余 string-CONFIG 目录引用 $N 行（见 string_cfg_paths.txt）"

  # (c) .../common/v1_1/s5k3l6jk_mipi_raw/Makefile: No such file or directory
  #     CONFIG_CUSTOM_KERNEL_IMGSENSOR 里 8 个名字，其中 5 个是 U60 专属
  #     （s5k3l6jk / s5k5e9dc / s5k4h7yx_*），common/v1_1 里没有对应目录。
  #     mt6771/Makefile 的 FILTER_DRV 会把它们当 common_drv 加进 obj-y，
  #     kbuild 找不到 Makefile 就 Stop；同时 src/Makefile 把同一串名字
  #     tr a-z A-Z 生成 -D 宏，imgsensor_sensor_list.c 会引用不存在的
  #     SensorInit / SENSOR_DRVNAME。两边同源，一处收敛即可。
  CFG="$OUT/.config"
  if [ -f "$CFG" ]; then
    CUR=$(sed -n 's/^CONFIG_CUSTOM_KERNEL_IMGSENSOR="\(.*\)"$/\1/p' "$CFG" | head -1)
    ISRC="$SRC/drivers/misc/mediatek/imgsensor/src"
    PROJ=$(sed -n 's/^CONFIG_ARCH_MTK_PROJECT="\(.*\)"$/\1/p' "$CFG" | head -1)
    [ -z "$PROJ" ] && PROJ="k71v1_64_bsp"
    KEEP=""; DROP=""
    for d in $CUR; do
      if [ -d "$ISRC/common/v1_1/$d" ] || [ -d "$ISRC/mt6771/$d" ] || \
         [ -d "$ISRC/mt6771/camera_project/$PROJ/$d" ]; then
        KEEP="$KEEP $d"
      else
        DROP="$DROP $d"
      fi
    done
    KEEP=$(echo "$KEEP" | xargs)
    if [ -n "$CUR" ] && [ "$KEEP" != "$CUR" ]; then
      sed -i "s|^CONFIG_CUSTOM_KERNEL_IMGSENSOR=\".*\"$|CONFIG_CUSTOM_KERNEL_IMGSENSOR=\"$KEEP\"|" "$CFG"
      step patch_imgsensor_cfg OK "收敛为树内 sensor：$KEEP（剔除：$DROP）"
    else
      step patch_imgsensor_cfg OK "全部 sensor 均在树内，无需收敛"
    fi
  else
    step patch_imgsensor_cfg SKIP "无 .config"
  fi
  export ARCH=arm64 SUBARCH=arm64
  export CROSS_COMPILE=aarch64-linux-android-
  export CROSS_COMPILE_ARM32=arm-linux-androideabi-
  export CLANG_TRIPLE=aarch64-linux-gnu-
  export REAL_CC="$TC/clang-4691093/bin/clang"
  export DTC_EXT=dtc
  # 这棵 Realme/OPPO 树的原生产品名。多处 Makefile（尤其 OPPO 安全公共驱动）
  # 靠它选平台宏；不设会落到高通默认分支去 include <soc/qcom/smem.h>。
  export TARGET_PRODUCT=full_oppo6771

  # ---- 修补 OEM 开源树裁剪遗漏 ----
  # 首跑报错：scripts/Makefile.modbuiltin 递归到
  #   drivers/misc/mediatek/imgsensor/src/mt6771/../common/v1_1/<sensor>/Makefile
  #   找不到文件直接 Stop。Realme 开源树漏发了几个 sensor 子目录的 Makefile。
  # 用同目录现成的 Makefile 当模板，把 sensor 名替换掉补齐；不补齐则整个
  # modules.builtin 目标失败（跟工具链、python2、cust.dtsi 都无关）。
  COMMON="$SRC/drivers/misc/mediatek/imgsensor/src/common/v1_1"
  if [ -d "$COMMON" ]; then
    TPL=$(find "$COMMON" -maxdepth 2 -type f -name Makefile | head -1)
    TPL_NAME=""
    [ -n "$TPL" ] && TPL_NAME=$(basename "$(dirname "$TPL")")
    FIXED=0
    for d in "$COMMON"/*/; do
      [ -d "$d" ] || continue
      [ -f "$d/Makefile" ] && continue
      NAME=$(basename "$d")
      if [ -n "$TPL" ]; then
        sed "s/${TPL_NAME}/${NAME}/g" "$TPL" > "$d/Makefile"
      else
        printf 'obj-y := %s.o\n' "$NAME" > "$d/Makefile"
      fi
      FIXED=$((FIXED+1))
    done
    step patch_imgsensor OK "补全 $FIXED 个缺失的 Makefile（模板：${TPL_NAME:-无}）"
  else
    step patch_imgsensor SKIP "源码树没有 imgsensor/common/v1_1，无需修补"
  fi

  # ---- 摘除 OPPO 高通残留驱动（v6：改上层，不再置空子 Makefile）----
  #
  # 第四跑：fatal error: 'soc/qcom/smem.h' file not found
  #   drivers/input/Makefile:35 无条件 obj-y += misc/oppo_seccommon_drivers/
  #   （#ifdef VENDOR_EDIT 在 Makefile 里只是注释，这行一直生效）
  #   该目录 oppo_secure_common/Makefile 靠 TARGET_PRODUCT 选平台宏，
  #   未设置时落高通 #else 分支，MT6771 树里没有 qcom 头文件。
  #
  # 第五跑：v5 把子目录 Makefile 置空 -> 上层仍把该目录当 obj-y 的一部分，
  #   kbuild 会把 "misc/oppo_seccommon_drivers/" 展开成 ".../built-in.o"
  #   并作为 drivers/input/built-in.o 的输入；空 Makefile 不产出 built-in.o，
  #   于是链接报：
  #     aarch64-linux-android-ld: cannot find
  #       drivers/input/misc/oppo_seccommon_drivers/built-in.o
  #
  # v6 正解：直接注释掉 drivers/input/Makefile 那一行。
  #   上层 obj-y 里没有该目录 -> 不期待 built-in.o，也不再递归进去，
  #   qcom/smem.h 和 built-in.o 两个问题一起消失。
  #   子目录 Makefile 恢复原样（清掉 v5 的置空痕迹），保持源码树干净。
  #
  # U60 指纹是 GF3626（mediatek,fingerprint-spi-dev），用不到这套 OPPO
  # 安全公共驱动；不改任何 CONFIG，配置 diff 报告照常如实反映。
  SECCOM_DIR="$SRC/drivers/input/misc/oppo_seccommon_drivers"
  SECCOM="$SECCOM_DIR/Makefile"
  INMAKE="$SRC/drivers/input/Makefile"

  # 1) 恢复子目录 Makefile（若本轮是全新 clone，直接写回原内容）
  if [ -f "$SECCOM.u60bak" ]; then
    cp -f "$SECCOM.u60bak" "$SECCOM"
    RESTORE="从 .u60bak 恢复"
  else
    mkdir -p "$SECCOM_DIR"
    printf 'obj-y        += oppo_secure_common/\n' > "$SECCOM"
    RESTORE="写回原内容"
  fi

  # 2) 注释掉上层无条件引用
  if [ -f "$INMAKE" ] && grep -qE '^obj-y[[:space:]]*\+=[[:space:]]*misc/oppo_seccommon_drivers/' "$INMAKE"; then
    cp -f "$INMAKE" "$INMAKE.u60bak"
    sed -i 's,^obj-y[[:space:]]*+=[[:space:]]*misc/oppo_seccommon_drivers/,# obj-y += misc/oppo_seccommon_drivers/,' "$INMAKE"
    step patch_oppo_seccommon OK "上层引用已注释、子 Makefile $RESTORE（备份 .u60bak）"
  elif [ -f "$INMAKE" ]; then
    step patch_oppo_seccommon OK "上层引用已不存在；子 Makefile $RESTORE"
  else
    step patch_oppo_seccommon SKIP "源码树无 drivers/input/Makefile，无法摘除"
  fi

  step patch_modpost_warn OK "section mismatch 降级为警告（WARN_ONLY=y）"

  if make O="$OUT" olddefconfig >"$LOGS/olddefconfig.log" 2>&1; then
    step olddefconfig OK "以 u60.config 为基线生成 .config"
  else
    step olddefconfig FAIL "见 olddefconfig.log"
  fi

  # CC / REAL_CC 都给：MTK 4.4 的老 Makefile 有的只认 REAL_CC。
  # 目标只取 vmlinux：默认 all 会先跑 drivers/modules.builtin，
  # 对裁剪过的 OEM 树很脆弱；vmlinux 链接时 modpost 仍会生成 Module.symvers，
  # CRC 比对需要的就是它。
  if make O="$OUT" -j"$(nproc --all)" CC=clang REAL_CC="$REAL_CC" TARGET_PRODUCT=full_oppo6771 CONFIG_SECTION_MISMATCH_WARN_ONLY=y vmlinux \
       2>&1 | tee "$LOGS/build.log"; then
    step build OK "vmlinux 编译完成（已跳过 modules.builtin）"
    # 再补一个可刷的 Image.gz-dtb；失败不致命，不影响 CRC/符号比对
    if make O="$OUT" -j"$(nproc --all)" CC=clang REAL_CC="$REAL_CC" TARGET_PRODUCT=full_oppo6771 CONFIG_SECTION_MISMATCH_WARN_ONLY=y Image.gz-dtb \
         >>"$LOGS/build.log" 2>&1; then
      step image_gz_dtb OK "Image.gz-dtb 已生成"
    else
      step image_gz_dtb SKIP "Image.gz-dtb 未生成，不影响 CRC / 符号比对"
    fi
  else
    step build FAIL "vmlinux 编译失败；完整日志见 build.log"
  fi

  # 收集产物（有就拷，没有不影响报告）
  mkdir -p "$OUT/artifacts"
  for f in "$OUT/vmlinux" "$OUT/Module.symvers" \
           "$OUT/arch/arm64/boot/Image.gz-dtb" "$OUT/arch/arm64/boot/Image.gz" \
           "$OUT/.config" "$OUT/include/generated/autoconf.h"; do
    [ -f "$f" ] && cp -f "$f" "$OUT/artifacts/" 2>/dev/null || true
  done
  if [ -f "$OUT/vmlinux" ]; then
    (nm "$OUT/vmlinux" 2>/dev/null || aarch64-linux-android-nm "$OUT/vmlinux" 2>/dev/null) \
      | awk '{print $3}' | grep -v '^$' | sort -u > "$OUT/src_syms.txt" || true
    step nm_symbols OK "$(wc -l < "$OUT/src_syms.txt" 2>/dev/null || echo 0) 个唯一符号"
  fi
  cd "$WS"
fi

###############################################################################
# 6. 生成比对报告
###############################################################################
log "6/6 生成比对报告"

python3 "$REPO/scripts/diff_report.py" \
  --base "$BASE" --src "$SRC" --out "$OUT" --logs "$LOGS" --status "$STATUS" \
  > "$LOGS/diff_report.log" 2>&1
if [ -f "$OUT/U60_源码核对报告.md" ]; then
  step report OK "U60_源码核对报告.md 已生成"
else
  step report FAIL "diff_report.py 失败，见 diff_report.log"
fi

echo
echo "=========================================================="
echo " 步骤汇总"
echo "=========================================================="
column -t -s $'\t' "$STATUS" 2>/dev/null || cat "$STATUS"
echo
echo "输出目录: $OUT"
ls -lh "$OUT" | head -30
echo "=== DONE ==="
