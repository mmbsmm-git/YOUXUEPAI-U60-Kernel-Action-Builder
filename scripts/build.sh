#!/usr/bin/env bash
# 优学派 U60 / P709 —— 基线内核「纯编译」脚本（在 ubuntu:20.04 容器内执行）
#
# 架构（重构后）：
#   内核源码仓库  = techyminati/alps-4.4 @ 5a1d479b 的干净单 commit 基线
#                   + 之后所有适配 / 驱动 / 符号 / dts 都作为 commit 提交上去
#   本编译仓库    = 只做 clone → config → make → 上传产物
#                   ★ 零源码补丁、零 sed、零 grep 源码、零比对报告
#
# 本阶段目标只有一个：build OK。CRC / 符号 diff / 驱动挂载全部延后。
# 若编译报错，修复请提交到【内核源码仓库】，不要改这个脚本。
#
# 路径约定（由 workflow 的 docker run 挂载）：
#   /repo           只读：本仓库（baseline/u60.config、scripts/）
#   /workspace      可写：工具链、源码树、编译输出
#
# 环境变量（由 workflow -e 传入）：
#   KERNEL_REPO  内核源码仓库 URL
#   KERNEL_REF   分支 / tag / sha（默认 main）
#   BUILD_KERNEL true / false
#   CLANG_URL    clang-4691093 包地址
set -uo pipefail

WS=/workspace
REPO=/repo
BASE=$REPO/baseline
OUT=$WS/out
SRC=$WS/src/kernel
TC=$WS/toolchain
LOGS=$OUT/logs
ART=$OUT/artifacts
mkdir -p "$OUT" "$LOGS" "$TC" "$ART" "$(dirname "$SRC")"

STATUS=$OUT/steps.tsv
: > "$STATUS"
step() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STATUS"; echo "[$2] $1: $3"; }
log()  { echo "----- $* -----"; }

echo "=========================================================="
echo " U60 基线内核 | 纯编译（不做分析）"
echo " 容器 $(grep -E '^VERSION_ID' /etc/os-release)"
echo " python2: $(python2 --version 2>&1) | python3: $(python3 --version 2>&1)"
echo "=========================================================="

###############################################################################
# 1. 工具链
###############################################################################
log "1/4 下载 AOSP 工具链（版本必须对齐 clang 6.0.2 / r316199 / 4691093）"

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
# 2. 取内核源码（纯 clone，不打任何补丁）
###############################################################################
log "2/4 取内核源码"

KERNEL_REPO=${KERNEL_REPO:-"https://github.com/mmbsmm-git/YOUXUEPAI_U60_Kernel"}
KERNEL_REF=${KERNEL_REF:-"main"}

if [ -f "$SRC/Makefile" ]; then
  step fetch_kernel OK "已存在，跳过 clone"
else
  if git clone --depth=1 -b "$KERNEL_REF" "$KERNEL_REPO" "$SRC" \
       >"$LOGS/kernel_fetch.log" 2>&1; then
    step fetch_kernel OK "$(cd "$SRC" && git log -1 --format='%h %ad %s' --date=short)"
    echo "commit 总数: $(cd "$SRC" && git rev-list --count HEAD)" >>"$LOGS/kernel_fetch.log"
  else
    step fetch_kernel FAIL "clone 失败，见 kernel_fetch.log；确认源码仓库已初始化且为 public"
  fi
fi

###############################################################################
# 3. 配置 + 编译
###############################################################################
log "3/4 配置并编译 vmlinux"

BUILD_KERNEL=${BUILD_KERNEL:-"true"}
if [ "$BUILD_KERNEL" != "true" ]; then
  step build SKIP "BUILD_KERNEL=false"
elif [ ! -f "$SRC/Makefile" ]; then
  step build SKIP "无源码树"
elif [ ! -x "$TC/clang-4691093/bin/clang" ]; then
  step build SKIP "clang 缺失"
else
  cd "$SRC"

  # 工具链环境变量（MTK 4.4 老 Makefile 认 REAL_CC / CLANG_TRIPLE）
  export ARCH=arm64 SUBARCH=arm64
  export CROSS_COMPILE=aarch64-linux-android-
  export CROSS_COMPILE_ARM32=arm-linux-androideabi-
  export CLANG_TRIPLE=aarch64-linux-gnu-
  export REAL_CC="$TC/clang-4691093/bin/clang"

  # 配置输入：本机 root 抠出的 u60.config，作为唯一基线
  cp "$BASE/u60.config" "$OUT/.config"
  step config_input OK "cp baseline/u60.config -> .config（不改动源码）"

  # 唯一的编译开关：modpost 的 section mismatch 降级为警告。
  # 这是 make 变量，不是源码补丁；不设的话 Makefile.modpost 传 -E 把警告当 FATAL。
  if ! grep -q '^CONFIG_SECTION_MISMATCH_WARN_ONLY=y' "$OUT/.config"; then
    printf 'CONFIG_SECTION_MISMATCH_WARN_ONLY=y\n' >> "$OUT/.config"
  fi

  if make O="$OUT" olddefconfig >"$LOGS/olddefconfig.log" 2>&1; then
    step olddefconfig OK "以 u60.config 为基线生成 .config"
  else
    step olddefconfig FAIL "见 olddefconfig.log"
  fi

  MAKEV="CC=clang REAL_CC=$REAL_CC CONFIG_SECTION_MISMATCH_WARN_ONLY=y"
  if make O="$OUT" -j"$(nproc --all)" $MAKEV vmlinux \
       2>&1 | tee "$LOGS/build.log"; then
    step build OK "vmlinux 编译完成"
    # 可刷镜像，失败不致命（这一阶段只要 vmlinux）
    if make O="$OUT" -j"$(nproc --all)" $MAKEV Image.gz-dtb \
         >>"$LOGS/build.log" 2>&1; then
      step image_gz_dtb OK "Image.gz-dtb 已生成"
    else
      step image_gz_dtb SKIP "未生成，不影响本阶段目标"
    fi
  else
    step build FAIL "vmlinux 编译失败；完整日志见 build.log（修复请提交到内核源码仓库）"
  fi
fi

###############################################################################
# 4. 归集产物 + 极简 summary（本阶段不跑任何比对报告）
###############################################################################
log "4/4 归集产物"

for f in "$OUT/.config" "$OUT/include/generated/autoconf.h" \
         "$OUT/vmlinux" "$OUT/Module.symvers" \
         "$OUT/arch/arm64/boot/Image.gz-dtb" "$OUT/arch/arm64/boot/Image.gz"; do
  [ -f "$f" ] && cp -f "$f" "$ART/" 2>/dev/null || true
done
[ -f "$OUT/.config" ] && cp -f "$OUT/.config" "$ART/u60_final.config"

BUILD_STATUS=$(awk -F'\t' '$1=="build"{print $2}' "$STATUS" | tail -1)
[ -z "$BUILD_STATUS" ] && BUILD_STATUS="SKIP"
{
  echo "# U60 基线内核 · 纯编译"
  echo
  echo "| 项 | 结果 |"
  echo "|---|---|"
  echo "| 目标 | \`build OK\`（本阶段不做 CRC / 符号 / dts 分析） |"
  echo "| build | **$BUILD_STATUS** |"
  echo "| 源码 | $KERNEL_REPO @ $KERNEL_REF |"
  echo "| 配置 | baseline/u60.config |"
  echo
  echo "产物：\`vmlinux\` / \`Module.symvers\` / \`Image.gz-dtb\` / \`autoconf.h\` / \`build.log\`"
  echo
  echo "> 编译失败时，把修复提交到**内核源码仓库**，本仓库脚本不动。"
} > "$OUT/summary.md"

step done OK "summary.md 已生成；build=$BUILD_STATUS"
