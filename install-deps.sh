#!/usr/bin/env bash
# U60 内核 4.4 编译环境依赖（Ubuntu 20.04 / focal）
# 逐个安装：失败的记录下来继续装，最后汇总；缺任何核心包就让镜像构建中止。
set -u
export DEBIAN_FRONTEND=noninteractive

FAILED=()
install_one() {
  if apt-get install -y --no-install-recommends "$1" >/dev/null 2>&1; then
    echo "[OK]   $1"
  else
    echo "[FAIL] $1"
    FAILED+=("$1")
  fi
}

echo "== apt update =="
apt-get update -y

echo "== 安装依赖 =="
PKGS="
git curl wget ca-certificates unzip p7zip-full zip
python2.7 python-is-python2 python3
build-essential bc bison flex gperf ccache
libncurses5 libtinfo5
zlib1g-dev libelf-dev libssl-dev
device-tree-compiler libfdt-dev
libxml2-utils xsltproc
lz4 liblz4-tool xz-utils lzop
"
for p in $PKGS; do install_one "$p"; done

echo
echo "=========================================="
echo " 安装结果"
echo "=========================================="
if [ ${#FAILED[@]} -eq 0 ]; then
  echo " 全部成功"
else
  echo " 以下包未装上："
  for f in "${FAILED[@]}"; do echo "   - $f"; done
  echo " 核心依赖缺失，中止镜像构建。"
  exit 1
fi
exit 0
