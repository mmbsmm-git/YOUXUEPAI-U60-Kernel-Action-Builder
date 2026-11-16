#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""优学派 U60 / P709 —— 内核源码取证比对报告生成器

在容器里由 build_and_diff.sh 调用；只读 baseline/ 与编译产物，
生成 Markdown 报告。任何输入缺失都降级为 N/A，不抛异常中断流水线。
"""
import argparse
import json
import os
import re
from datetime import datetime

ap = argparse.ArgumentParser()
ap.add_argument('--base', required=True)
ap.add_argument('--src', required=True)
ap.add_argument('--out', required=True)
ap.add_argument('--logs', required=True)
ap.add_argument('--status', required=True)
a = ap.parse_args()


def readlines(p):
    try:
        with open(p, encoding='utf-8', errors='replace') as f:
            return f.read().splitlines()
    except Exception:
        return []


def readtext(p):
    try:
        with open(p, encoding='utf-8', errors='replace') as f:
            return f.read()
    except Exception:
        return ''


def exists(p):
    return 'OK' if os.path.isfile(p) and os.path.getsize(p) > 0 else 'MISSING'


B, S, O, L = a.base, a.src, a.out, a.logs
P = lambda *x: os.path.join(*x)

# ---------------------------------------------------------------- 步骤状态
steps = []
for line in readlines(a.status):
    parts = line.split('\t')
    if len(parts) >= 2:
        steps.append((parts[0], parts[1], parts[2] if len(parts) > 2 else ''))

ico = {'OK': '✅', 'FAIL': '❌', 'SKIP': '⏭️'}

# ---------------------------------------------------------------- 工具链
clang_v = readtext(P(L, 'clang_version.txt'))
clang_ok = ('6.0.2' in clang_v and 'r316199' in clang_v) or '4691093' in clang_v
clang_line = next((x.strip() for x in clang_v.splitlines() if 'clang version' in x), '（无输出）')

# ---------------------------------------------------------------- 源码提交
head = readlines(P(L, 'kernel_head.txt'))

# ---------------------------------------------------------------- 私有符号
PRIVATE_EXPORTED = [
    'noah_get_mount_flag', 'noah_eeprom_getdata', 'noah_eeprom_readdata',
    'noah_eeprom_setdata', 'set_noahmic_interlop', 'send_yxp_heaset_event',
    'yxp_usbmic_led_on', 'yxp_usbmic_led_off', 'yxp_get_vbus',
    'mt6370_chgdet_handler_yxp', 'mt6370_enable_chg_type_det_yxp',
    'noahmicusb_work_deal', 'Open_DSI_clk_yxp', 'Close_DSI_clk_yxp',
    'AudDrv_yxp_usb_audio_switch',
]
ALL_PRIVATE = PRIVATE_EXPORTED + ['buf_handler_register_yxp']
priv_files = [x for x in readlines(P(L, 'private_symbol_hits.txt')) if x.strip()]
board_files = [x for x in readlines(P(L, 'board_hardware_hits.txt')) if x.strip()]

# 在源码树里逐个查私有符号名（比"文件命中"更精确）
priv_hit_syms, priv_miss_syms = [], []
if os.path.isdir(S):
    # 逐文件扫描（内核树 5 万+ 文件，不拼接大字符串，避免 OOM）
    found = set()
    for root, _dirs, files in os.walk(S):
        if '.git' in root.split(os.sep):
            continue
        for fn in files:
            if not fn.endswith(('.c', '.h', '.S', '.dts', '.dtsi')):
                continue
            txt = readtext(os.path.join(root, fn))
            for sym in ALL_PRIVATE:
                if sym not in found and sym in txt:
                    found.add(sym)
            if len(found) == len(ALL_PRIVATE):
                break
        if len(found) == len(ALL_PRIVATE):
            break
    for sym in ALL_PRIVATE:
        (priv_hit_syms if sym in found else priv_miss_syms).append(sym)
else:
    priv_miss_syms = list(ALL_PRIVATE)

# ---------------------------------------------------------------- 符号 diff
base_syms = set(x.strip() for x in readlines(P(B, 'kallsyms_syms.txt')) if x.strip())
src_syms = set(x.strip() for x in readlines(P(O, 'src_syms.txt')) if x.strip())
sym_missing = sorted(base_syms - src_syms) if src_syms else []
sym_extra = sorted(src_syms - base_syms) if src_syms else []
sym_priv_in_src = [s for s in ALL_PRIVATE if s in src_syms]

# ---------------------------------------------------------------- CRC diff
def parse_ko_versions(p):
    d = {}
    for line in readlines(p)[1:]:
        if '\t' not in line:
            continue
        n, c = line.split('\t')[:2]
        try:
            d[n.strip()] = int(c.strip(), 16)
        except Exception:
            pass
    return d


def parse_module_symvers(p):
    d = {}
    for line in readlines(p):
        f = line.split('\t')
        if len(f) < 2:
            continue
        try:
            d[f[1].strip()] = int(f[0].strip(), 16)
        except Exception:
            pass
    return d


ko_crc = parse_ko_versions(P(B, 'ko_versions.tsv'))
ms_crc = parse_module_symvers(P(O, 'Module.symvers'))
crc_rows = []
if ms_crc:
    for n, c in sorted(ko_crc.items()):
        m = ms_crc.get(n)
        crc_rows.append((n, c, m, 'OK' if m == c else ('MISSING' if m is None else 'MISMATCH')))
    crc_bad = [r for r in crc_rows if r[3] != 'OK']
else:
    crc_bad = []
crc_ok_n = len(crc_rows) - len(crc_bad)

# ---------------------------------------------------------------- 板级 / dts
def compat_of(text):
    # dts 里常见 compatible = "a", "b"; —— 要把每个字符串都取出来
    out = set()
    for m in re.findall(r'compatible\s*=\s*([^;]+);', text):
        out |= set(re.findall(r'"([^"]+)"', m))
    return out


base_compat = set()
for fn in ('dtbo.00.dts', 'dtbo.01.dts', 'dtbo.02.dts'):
    base_compat |= compat_of(readtext(P(B, 'dtbo_dts', fn)))

src_compat = set()
src_dts_files = 0
if os.path.isdir(S):
    for root, _dirs, files in os.walk(S):
        if '.git' in root.split(os.sep):
            continue
        for fn in files:
            if fn.endswith(('.dts', '.dtsi')):
                src_dts_files += 1
                src_compat |= compat_of(readtext(os.path.join(root, fn)))

compat_hit = sorted(base_compat & src_compat)
compat_miss = sorted(base_compat - src_compat)

yxp_list = [l.split()[-1] for l in readlines(P(B, 'yxp_private_syms.txt')) if l.startswith('0')]
hw_text = readtext(P(B, 'board_hardware.txt'))

# ---------------------------------------------------------------- 配置 diff
# 用编译产物 autoconf.h 反查 u60.config：本机开了、但这棵树的 Kconfig 里
# 根本不存在的选项，就是「板级功能缺口」的精确清单（比数 compatible 更准）。
def parse_config(path):
    d = {}
    for line in readlines(path):
        m = re.match(r'(CONFIG_[A-Za-z0-9_]+)=(.*)$', line.strip())
        if m:
            d[m.group(1)] = m.group(2)
    return d


def parse_autoconf(path):
    return set(re.findall(r'^#define\s+(CONFIG_[A-Za-z0-9_]+)\b',
                          readtext(path), re.M))


cfg_base = parse_config(P(B, 'u60.config'))
cfg_hdr = parse_autoconf(P(O, 'artifacts', 'autoconf.h'))
# tristate =m 在 autoconf.h 里是 CONFIG_X_MODULE，不算丢失
cfg_lost = [k for k in sorted(cfg_base)
            if k not in cfg_hdr and k + '_MODULE' not in cfg_hdr]
cfg_extra = [k for k in sorted(cfg_hdr)
             if k not in cfg_base and not k.endswith('_MODULE')]

# ---------------------------------------------------------------- 编译日志
build_log = readtext(P(L, 'build.log'))
build_errs = [x for x in build_log.splitlines()
              if re.search(r'(^|\s)(error:|Error \d+|fatal error:|No such file or directory)', x)][:15]

# ---------------------------------------------------------------- 结论
verdicts = []
if not priv_hit_syms:
    verdicts.append(
        '**源码树不含任何优学派私有符号** → 这是 OEM 公版树（Realme/OPPO 版），'
        '不是优学派那份。`wlan_drv_gen3.ko` 依赖 `buf_handler_register_yxp`、'
        '`noah_eeprom_readdata`，用这棵树编出的内核即使 CRC 全对，也会 '
        '`Unknown symbol`。需要继续 GPL 索取优学派补丁，或在同源树里按符号名把这些钩子补回去。')
else:
    verdicts.append('源码树命中 %d/%d 个优学派私有符号，方向对了，继续核对 CRC 与 dts。'
                    % (len(priv_hit_syms), len(ALL_PRIVATE)))
if crc_rows:
    if not crc_bad:
        verdicts.append('**CRC 全部一致（%d/%d）**：编译产物可直接加载 vendor 的 7 个 .ko（'
                        '`CONFIG_MODULE_SIG is not set`，无需重签名）。' % (crc_ok_n, len(crc_rows)))
    else:
        verdicts.append('CRC 不一致 %d/%d 项，加载时会 `disagrees about version of symbol`；'
                        '多半是工具链版本或 config 差异。' % (len(crc_bad), len(crc_rows)))
else:
    verdicts.append('未生成 Module.symvers（编译未成功或跳过），CRC 比对未执行。')
if src_syms:
    verdicts.append('符号 diff：源码 vmlinux %d 个 / 本机 kallsyms %d 个，'
                    '本机独有 %d 个、源码独有 %d 个。'
                    % (len(src_syms), len(base_syms), len(sym_missing), len(sym_extra)))
if not clang_ok:
    verdicts.append('⚠️ clang 版本未确认为 6.0.2 / r316199，MODVERSIONS CRC 很可能对不上。')

# ---------------------------------------------------------------- 报告
md = []
md.append('# 优学派 U60 / P709 —— 内核源码核对报告')
md.append('')
md.append('> 生成时间：%s  ' % datetime.now().strftime('%Y-%m-%d %H:%M:%S'))
md.append('> 基线：本机 root 提取的 `u60.config`、`kallsyms.txt`、7 个 vendor `.ko` 的 `__versions`、3 份 DTBO overlay。')
md.append('')
md.append('## 结论')
md.append('')
for i, v in enumerate(verdicts, 1):
    md.append('%d. %s' % (i, v))
md.append('')
md.append('## 运行步骤')
md.append('')
md.append('| 步骤 | 状态 | 说明 |')
md.append('|---|---|---|')
for n, st, msg in steps:
    md.append('| `%s` | %s %s | %s |' % (n, ico.get(st, '·'), st, msg.replace('|', '\\|')))
md.append('')
md.append('## 环境')
md.append('')
md.append('- clang：`%s` %s' % (clang_line, '✅' if clang_ok else '❌ 版本不符'))
md.append('- 源码提交：%s' % ('`%s`' % head[0] if head else 'N/A'))
if len(head) > 2:
    md.append('- 提交日期：%s' % head[1])
    md.append('- 提交说明：%s' % head[2])
md.append('- 设备树文件：%d 个（源码侧）' % src_dts_files)
md.append('')
md.append('## 1. 优学派私有内核符号（判断「是不是那份源码」）')
md.append('')
md.append('本机 `kallsyms.txt` 里有 30 个 `noah_*` / `*_yxp` 符号，其中 15 个 EXPORT_SYMBOL，'
          '加上 vendor 模块依赖的 `buf_handler_register_yxp`，共 %d 个核对项。' % len(ALL_PRIVATE))
md.append('')
md.append('| 结果 | 数量 | 符号 |')
md.append('|---|---|---|')
md.append('| ✅ 源码树命中 | %d | %s |' % (len(priv_hit_syms), ', '.join('`%s`' % x for x in priv_hit_syms) or '—'))
md.append('| ❌ 源码树缺失 | %d | %s |' % (len(priv_miss_syms), ', '.join('`%s`' % x for x in priv_miss_syms) or '—'))
md.append('')
md.append('- 命中文件数：%d（见 `logs/private_symbol_hits.txt`）' % len(priv_files))
md.append('- 基线里的完整私有符号清单（%d 条）：`baseline/yxp_private_syms.txt`，'
          '可直接抄进 GPL 索取函。' % len(yxp_list))
md.append('')
md.append('## 2. MODVERSIONS CRC（判断「vendor .ko 能不能加载」）')
md.append('')
md.append('基线：7 个 `.ko` 的 `__versions` 共 **%d** 个唯一内核符号，'
          '全部 `vermagic=4.4.146 SMP preempt mod_unload modversions aarch64`，'
          '`module_layout=0x95be...` 一致。' % len(ko_crc))
md.append('')
if crc_rows:
    md.append('| 结果 | 数量 |')
    md.append('|---|---|')
    md.append('| ✅ CRC 一致 | %d / %d |' % (crc_ok_n, len(crc_rows)))
    md.append('| ❌ 不一致 / 源码无此符号 | %d |' % len(crc_bad))
    md.append('')
    if crc_bad:
        md.append('前 25 条异常：')
        md.append('')
        md.append('| 符号 | 本机 CRC | 源码 CRC | 结果 |')
        md.append('|---|---|---|---|')
        for n, c, m, st in crc_bad[:25]:
            md.append('| `%s` | `0x%08x` | %s | %s |'
                      % (n, c, ('`0x%08x`' % m if m is not None else '—'), st))
else:
    md.append('未执行（需要 `out/Module.symvers`）。')
md.append('')
md.append('## 3. 符号 diff（判断「源码树完不完整」）')
md.append('')
if src_syms:
    md.append('- 源码 `vmlinux`：**%d** 个唯一符号' % len(src_syms))
    md.append('- 本机 `kallsyms.txt`：**%d** 个（注意 `CONFIG_KALLSYMS_ALL is not set`，只含文本符号）' % len(base_syms))
    md.append('- 本机独有（源码缺）：**%d** 个；源码独有：**%d** 个' % (len(sym_missing), len(sym_extra)))
    md.append('- 其中的优学派私有符号：%s' % (', '.join('`%s`' % x for x in sym_priv_in_src) or '无'))
    md.append('')
    if sym_missing:
        md.append('本机独有符号前 30 个：`' + '`, `'.join(sym_missing[:30]) + '`')
else:
    md.append('未执行（需要编译出 `out/vmlinux`）。')
md.append('')
md.append('## 4. 设备树 / 板级硬件')
md.append('')
md.append('基线 DTBO 共 3 个 overlay（00=evb6771_64_emmc，01/02 逐字节相同），'
          '抽出 **%d** 个 compatible 值。' % len(base_compat))
md.append('')
md.append('| 结果 | 数量 |')
md.append('|---|---|')
md.append('| ✅ 源码 dts 命中 | %d |' % len(compat_hit))
md.append('| ❌ 源码 dts 缺失 | %d |' % len(compat_miss))
md.append('')
if compat_miss:
    md.append('缺失的 compatible（重点核对这些驱动是否要补）：')
    md.append('')
    md.append('`' + '`, `'.join(compat_miss[:60]) + '`')
    md.append('')
md.append('板级关键芯片命中文件数：%d（见 `logs/board_hardware_hits.txt`）；'
          '重点：`ssd2858` + `nt35595` 桥接屏、`HX83102`、`GF3626`、`tfa98xx`、`rt9465`。' % len(board_files))
md.append('')
md.append('基线板级硬件清单（`baseline/board_hardware.txt`）：')
md.append('')
md.append('```')
md.append(hw_text.strip()[:1000])
md.append('```')
md.append('')
md.append('## 5. 配置 diff（olddefconfig 静默丢掉的本机选项）')
md.append('')
if cfg_hdr:
    md.append('本机 `u60.config` 显式设置 **%d** 项，编译生成的 `autoconf.h` 定义 '
              '**%d** 项。其中 **%d** 项在这棵树的 Kconfig 里不存在，被 '
              '`olddefconfig` 无声删除；另有 **%d** 项是这棵树自带的选项。'
              % (len(cfg_base), len(cfg_hdr), len(cfg_lost), len(cfg_extra)))
    md.append('')
    md.append('| 功能 | 丢弃项 |')
    md.append('|---|---|')
    CAT = [
        ('触摸（GT9271 / HX83102 / ELAN）', ['GTP_', 'GT9271', 'HIMAX', 'TOUCHSCREEN']),
        ('传感器（霍尔 / 加速度 / 光距）', ['HALL_', 'MTK_AP322', 'MTK_BMA', 'MTK_CS503']),
        ('语音唤醒（DBMDX）', ['DBMDX']),
        ('摄像头 EEPROM', ['EEPROM_CAM']),
        ('其他（安全/无关 erratum）', ['HARDEN_', 'QCOM_', 'TCP_CONG', 'USB_GSPCA', 'GATOR']),
    ]
    for name, keys in CAT:
        hit = [k for k in cfg_lost if any(x in k for x in keys)]
        if hit:
            md.append('| %s | %d：%s |' % (name, len(hit), ', '.join('`%s`' % x for x in hit)))
    md.append('')
    md.append('树里新增（OPPO/360 定制）：%s' %
              (', '.join('`%s`' % x for x in cfg_extra) or '无'))
else:
    md.append('未执行（需要 `out/artifacts/autoconf.h`）。')
md.append('')
md.append('## 6. 编译日志摘要')
md.append('')
if build_errs:
    md.append('```')
    md.extend(build_errs)
    md.append('```')
    md.append('')
    md.append('完整日志见 `logs/build.log`。')
elif build_log:
    md.append('编译日志已生成，未检出典型 error 行，共 %d 行。' % len(build_log.splitlines()))
else:
    md.append('未编译（BUILD_KERNEL=false 或缺少源码/工具链）。')
md.append('')
md.append('## 下一步')
md.append('')
md.append('1. 私有符号全缺 → 换树或继续 GPL 索取。检索关键词：'
          '`alps-mp-p0.mp1-V5.166_k71v1.64.bsp`、`noah_eeprom_getdata`、'
          '`buf_handler_register_yxp`、`ssd2858 nt35595`。')
md.append('2. CRC 不一致 → 先确认 clang 是 `4691093 / r316199 / clang 6.0.2`，'
          '再确认 `.config` 由 `u60.config` 经 `olddefconfig` 生成、未被 OEM defconfig 覆盖。')
md.append('3. 编译报 DrvGen 相关错 → 容器是 focal + python2，若仍失败直接用源码树里现成的 `cust.dtsi` 跳过 DWS 生成。')
md.append('4. GPL 函补充材料：`ro.product.version=3.6.17`、'
          '`alps-mp-p0.mp1-V5.166_k71v1.64.bsp`、15 个导出私有符号名、boot.img 哈希。')
md.append('')

report = '\n'.join(md) + '\n'
with open(P(O, 'U60_源码核对报告.md'), 'w', encoding='utf-8') as f:
    f.write(report)

# 给 GitHub Step Summary 的精简版
sm = ['## U60 内核源码核对',
      '', '| 项 | 结果 |', '|---|---|',
      '| clang 版本 | %s |' % (clang_line or 'N/A'),
      '| 私有符号命中 | %d / %d |' % (len(priv_hit_syms), len(ALL_PRIVATE)),
      '| CRC 一致 | %s |' % ('%d / %d' % (crc_ok_n, len(crc_rows)) if crc_rows else '未执行'),
      '| 符号 diff | %s |' % ('源码 %d / 本机 %d' % (len(src_syms), len(base_syms)) if src_syms else '未执行'),
      '| dts compatible 命中 | %d / %d |' % (len(compat_hit), len(base_compat)),
      '| 配置丢弃项 | %d |' % len(cfg_lost),
      '']
for v in verdicts:
    sm.append('- ' + v)
sm.append('')
sm.append('完整报告：`U60_源码核对报告.md`（Artifact 内）')
with open(P(O, 'summary.md'), 'w', encoding='utf-8') as f:
    f.write('\n'.join(sm) + '\n')

with open(P(O, 'summary.json'), 'w', encoding='utf-8') as f:
    json.dump({
        'clang_ok': clang_ok,
        'clang_line': clang_line,
        'kernel_head': head,
        'private_hit': priv_hit_syms,
        'private_miss': priv_miss_syms,
        'crc_total': len(crc_rows),
        'crc_ok': crc_ok_n,
        'crc_bad': [{'sym': n, 'ko': '0x%08x' % c,
                     'src': ('0x%08x' % m if m is not None else None), 'why': st}
                    for n, c, m, st in crc_bad[:50]],
        'base_syms': len(base_syms),
        'src_syms': len(src_syms),
        'sym_missing': len(sym_missing),
        'sym_extra': len(sym_extra),
        'compat_hit': len(compat_hit),
        'config_lost': cfg_lost,
        'config_extra': cfg_extra,
        'compat_missing': compat_miss[:60],
        'steps': [{'name': n, 'status': st, 'msg': m} for n, st, m in steps],
    }, f, ensure_ascii=False, indent=2)

print('报告已生成：', P(O, 'U60_源码核对报告.md'))
print('私有符号 %d/%d，CRC %d/%d，compatible %d/%d'
      % (len(priv_hit_syms), len(ALL_PRIVATE), crc_ok_n,
         len(crc_rows) if crc_rows else 0, len(compat_hit), len(base_compat)))
