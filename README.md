# U60 内核源码复现与取证比对

给 **优学派 U60 / P709**（MT6771，Linux 4.4.146）用的 GitHub Actions 仓库：
拉同源内核源码 → 用精确版本的 AOSP 工具链编译 → 与手机 root 抠出的取证基线做比对 → 自动出报告。

本机只负责「准备文件 + 推送」，**下载、编译、比对全在 Actions 里跑**，不需要电脑性能。

---

## 仓库里只有这些文件

```
.github/workflows/build.yml   # 唯一的工作流
Dockerfile                    # Ubuntu 20.04 编译容器
install-deps.sh               # 容器依赖
scripts/build_and_diff.sh     # 容器内主流程
scripts/diff_report.py        # 报告生成
baseline/                     # 手机取证基线（CI 必需，自包含）
README.md / .gitignore / .gitattributes
```

`baseline/` 内容：`u60.config`（编译基线）、52,091 个内核符号、473 条 vendor 模块 CRC、30 个原厂私有符号、板级硬件清单、3 份 DTBO 反编译 dts、vendor build.prop。

交付的是**纯文件 zip，不含 .git**。你 `git init` 之后第一条 commit 就是干净的，没有任何历史记录。

---

## 一、本机准备（手机 Termux 就能做，电脑同理）

### 1. 生成 GitHub Token

手机浏览器打开 GitHub → 头像 → **Settings → Developer settings → Personal access tokens (classic) → Generate new token**：

- 勾选 **`repo`** 一项就够（私有仓库也够）
- 有效期选长一点，生成后**立刻复制**保存

> GHCR 推镜像用的是 Actions 自动注入的 `GITHUB_TOKEN`，权限在 workflow 里已声明，
> **不用**给这个 PAT 勾 `write:packages`。PAT 只用于下面的 `git push`。

### 2. 新建一个**空**仓库

GitHub 网页 → **New repository**：

- 名字随意，例如 `u60-kernel`
- 公开/私有都行
- **不要勾** `Add a README file` / `.gitignore` / `license`（勾了会和你本地 `git init` 冲突）

### 3. 把文件推上去

把我给的 zip 保存到手机 `Download` 目录，然后 Termux：

```sh
termux-setup-storage          # 首次，允许读 /sdcard
pkg install git unzip -y
cd ~
unzip /sdcard/Download/u60-kernel-builder.zip
cd u60-kernel-builder

git init -b main
git config user.name  "你的GitHub用户名"
git config user.email "你的邮箱"
git remote add origin https://github.com/<用户名>/<仓库名>.git
git add -A
git commit -m "U60 kernel source builder"
git push -u origin main
```

推送时：用户名填 GitHub 账号，**密码栏粘贴刚才的 PAT**（不是账号密码）。

> 想免得每次输：
> `git remote set-url origin https://<用户名>:<TOKEN>@github.com/<用户名>/<仓库名>.git`
> 注意 token 会明文存在 `.git/config`，别把整个目录打包分享给别人。

**如果建仓库时手滑勾了 README**，push 会报 non-fast-forward，先执行：
```sh
git pull --rebase origin main
git push -u origin main
```

电脑上的步骤完全一样，只是不需要 `termux-setup-storage`，zip 直接解压即可。

---

## 二、跑起来

push 完，仓库 → **Actions** → 左侧 `U60 内核源码复现与取证比对` → **Run workflow**。

| 输入 | 默认 | 说明 |
|---|---|---|
| `KERNEL_REPO` | `RMX1831/android_kernel_oppo_mt6771` | 换候选源码树时改这里 |
| `KERNEL_REF` | `AUTO` | 自动定位 `4.4.146` 那次提交；也可直接填 40 位 sha |
| `BUILD_KERNEL` | `true` | 只想先验「这棵树对不对」就选 `false`，几分钟出结果，不编译 |
| `CLANG_URL` | googlesource 的 `clang-4691093` | 下载失败时换成镜像包地址 |
| `UPLOAD_RELEASE` | `false` | 想额外发 Release 再开 |

首次运行会构建并缓存一次编译镜像（十几分钟），之后直接复用。整个任务上限 180 分钟。

结果看两处：**Step Summary**（页面顶部精简版）、**Artifacts → `u60-kernel-report-*`**（完整报告 + 日志 + 编译产物，保留 30 天）。

---

## 三、报告怎么读

| 项 | 期望 | 含义 |
|---|---|---|
| 私有符号 | 16/16 | `noah_*` / `*_yxp` / `buf_handler_register_yxp`。**0 个 = 公版 OEM 树**，`wlan_drv_gen3.ko` 会因 `Unknown symbol` 挂掉 |
| CRC | 473/473 | vendor 7 个 `.ko` 的 `__versions` vs 编译出的 `Module.symvers`；全对才能加载（`CONFIG_MODULE_SIG is not set`，无需重签名） |
| 符号 diff | 本机独有越少越好 | 源码 `vmlinux` vs 本机 52,091 个符号 |
| dts compatible | 命中越多越好 | 重点看 `ssd2858` + `nt35595` 桥接屏、`HX83102`、`GF3626` |

报告会自动给结论。任何一步失败都只记录、不中断，日志照样上传，静态扫描（私有符号 / 板级关键词 / dts）不依赖编译。

**预期结果**：同源 Realme/OPPO 树大概率私有符号 0/16。报告会明确写出「这是公版树，编出来也会 Unknown symbol」——这是要在 CI 里证出来的结论，不是脚本坏了。

---

## 四、几个会踩的坑

1. **不要整仓 clone 源码**：那个仓库 57 万+ commits，脚本用 `git fetch --depth=1 origin <sha>` 定点取。
2. **改了 `Dockerfile` / `install-deps.sh` 要换镜像名**：GHCR 已有镜像时 workflow 直接 pull、跳过重建。把 `build.yml` 里的 `IMAGE_TAG` 改成 `...:v2` 即可强制重建。
3. **clang 版本是硬约束**：必须 `4691093 / r316199 / clang 6.0.2`。换新版会让 MODVERSIONS CRC 全错，脚本会自检并写进报告。
4. **python 指向 py2**（`python-is-python2`），自写脚本一律显式 `python3`。
5. **DrvGen 报错**：直接用源码树里现成的 `cust.dtsi` 跳过 DWS 生成，别硬改成 py3。
6. **编译失败不等于白跑**：静态比对照样能判断树对不对。

---

## 五、GPL 索取时写全这些

同源树大概率不含原厂私有补丁，完整源码还得向分发者索取（主体：深圳市优学天下教育发展股份有限公司）：

```
P709 / k71v1_64_bsp / Linux 4.4.146 / #201 2023-03-01
alps-mp-p0.mp1-V5.166_k71v1.64.bsp
ro.product.version=3.6.17
导出符号：noah_eeprom_getdata / Open_DSI_clk_yxp /
          mt6370_enable_chg_type_det_yxp / AudDrv_yxp_usb_audio_switch 等 15 个
vendor 模块依赖：buf_handler_register_yxp、noah_eeprom_readdata
附：boot.img 哈希、购买凭证、/proc/version 截图
```

完整 30 个私有符号在 `baseline/yxp_private_syms.txt`。

---

## 六、验证状态

已在本机验证：两个 shell 脚本语法、Python 编译、workflow YAML 解析、报告生成的三种模拟场景（CRC 全一致 / 无编译产物 / 命中私有符号）。

**未验证**：真实 4.4 内核编译——本地环境无法访问代码托管站且无 ARM64 工具链，这一步要等 Actions 第一次跑才知道有没有 MTK 特有的编译错误。编译失败时日志会完整保留在 Artifact 里。
