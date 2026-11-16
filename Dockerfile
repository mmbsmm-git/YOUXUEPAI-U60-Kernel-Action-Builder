# 内核编译容器：Ubuntu 20.04 (focal)
# 选它的唯一原因：MTK DrvGen(DWS -> cust.dtsi) 是 Python 2 脚本，
# focal 的 universe 里仍有 python2.7 / python-is-python2，22.04+ 默认源已移除。
#
# 首次构建推送到 GHCR，之后 workflow 直接 pull，跳过重复 apt。
# 依赖逐个安装，失败记下来继续装；CORE 缺失则中止，避免缓存坏镜像。
FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

COPY install-deps.sh /tmp/install-deps.sh
RUN bash /tmp/install-deps.sh && rm -f /tmp/install-deps.sh

# 工具链(clang-4691093 / gcc 4.9) 不固化进镜像，由 workflow 按需下载，
# 这样换版本时不用重建镜像。
RUN python2 --version && \
    python3 --version && \
    dtc --version

WORKDIR /workspace
CMD ["/bin/bash"]
