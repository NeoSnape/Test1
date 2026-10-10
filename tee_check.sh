#!/system/bin/sh
# ============================================================================
#  tee_check.sh —— Android TEE / KeyMint / 启动验证 / Root 环境检测脚本
#
#  用法:
#    sh tee_check.sh            # 普通权限 (Termux / adb shell)
#    su -c sh tee_check.sh      # Root 权限 (结果最完整, 推荐)
#
#  选项:
#    -n          关闭彩色输出
#    -o <文件>   指定日志保存路径 (默认自动选择 /sdcard/Download 等)
#    -h          显示帮助
#
#  本脚本只读取信息, 不修改系统任何内容。兼容 mksh / toybox / dash / busybox。
# ============================================================================

VERSION="1.0"

# ---------------------------------------------------------------- 参数解析 --
USE_COLOR=1
LOG_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -n) USE_COLOR=0 ;;
        -o) shift; LOG_FILE="$1" ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "未知参数: $1 (使用 -h 查看帮助)"; exit 1 ;;
    esac
    shift
done
[ -t 1 ] || USE_COLOR=0

if [ "$USE_COLOR" = 1 ]; then
    R=$(printf '\033[31m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m')
    B=$(printf '\033[36m'); W=$(printf '\033[1m');  N=$(printf '\033[0m')
else
    R=""; G=""; Y=""; B=""; W=""; N=""
fi

# ---------------------------------------------------------------- 工具函数 --
PASS=0; WARN=0; FAIL=0
TEE_FOUND=""
SB_FOUND=""

GETPROP=getprop
command -v getprop >/dev/null 2>&1 || GETPROP=/system/bin/getprop

gp()      { $GETPROP "$1" 2>/dev/null; }
section() { printf '\n%s━━━ %s ━━━%s\n' "$W$B" "$*" "$N"; }
kv()      { printf '  %-36s %s\n' "$1" "${2:-<空>}"; }
ok()      { printf '  %s[PASS]%s %s\n' "$G" "$N" "$*"; PASS=$((PASS + 1)); }
warn()    { printf '  %s[WARN]%s %s\n' "$Y" "$N" "$*"; WARN=$((WARN + 1)); }
bad()     { printf '  %s[FAIL]%s %s\n' "$R" "$N" "$*"; FAIL=$((FAIL + 1)); }
info()    { printf '  %s[INFO]%s %s\n' "$B" "$N" "$*"; }
hit()     { printf '  %s[发现]%s %s\n' "$G" "$N" "$*"; }
skip()    { printf '  %s[跳过]%s %s\n' "$Y" "$N" "$*"; }

is_root() { [ "$(id -u 2>/dev/null)" = "0" ]; }

# 在常见库目录中查找 so 文件
find_lib() {
    for d in /vendor/lib64 /vendor/lib /odm/lib64 /odm/lib \
             /system/lib64 /system/lib /system_ext/lib64 /system_ext/lib; do
        [ -e "$d/$1" ] && { echo "$d/$1"; return 0; }
    done
    return 1
}

# 进程列表 (非 root 时 Android 7+ 通常只能看到自身进程)
load_ps() {
    PS_OUT=$(ps -A 2>/dev/null)
    [ "$(printf '%s\n' "$PS_OUT" | wc -l)" -lt 5 ] && PS_OUT=$(ps 2>/dev/null)
    if [ "$(printf '%s\n' "$PS_OUT" | wc -l)" -gt 30 ]; then
        PS_VISIBLE=1
    else
        PS_VISIBLE=0
    fi
}
proc_running() { printf '%s\n' "$PS_OUT" | grep -qE "(^|[ /])$1\$"; }

# 从 /proc/bootconfig 或 /proc/cmdline 读取 androidboot.* 参数 (需 root)
bootarg() {
    for f in /proc/bootconfig /proc/cmdline; do
        [ -r "$f" ] || continue
        v=$(grep -oE "androidboot\.$1 *= *\"?[A-Za-z0-9_.-]+" "$f" 2>/dev/null \
            | head -n 1 | sed -E 's/.*[= "]//')
        [ -n "$v" ] && { echo "$v"; return 0; }
    done
    return 1
}

# 解析 VINTF manifest, 输出 "HAL名|版本|实例" (不依赖 awk)
parse_vintf() {
    tr '>' '\n' | while read -r tok; do
        case "$tok" in
            "<hal"*)     inhal=1; hname=""; hver=""; hinst=""; iface="" ;;
            "</hal")     [ "$inhal" = 1 ] && echo "$hname|$hver|$hinst"; inhal=0 ;;
            *"</name")   v=${tok%</name}
                         if [ -z "$hname" ]; then hname=$v; else iface=$v; fi ;;
            *"</version")  hver="${hver:+$hver,}${tok%</version}" ;;
            *"</instance") hinst="${hinst:+$hinst }$iface/${tok%</instance}" ;;
            *"</fqname")   hinst="${hinst:+$hinst }${tok%</fqname}" ;;
        esac
    done
}

# 探测某种 TEE 实现: 名称 / 设备节点 / 进程 / 库 / 目录
probe_tee() {
    _name=$1; _ev=""
    for n in $2; do [ -e "$n" ] && _ev="$_ev $n"; done
    for p in $3; do proc_running "$p" && _ev="$_ev 进程:$p"; done
    for l in $4; do f=$(find_lib "$l") && _ev="$_ev $f"; done
    for d in $5; do
        if [ -d "$d" ]; then
            c=$(ls "$d" 2>/dev/null | wc -l | tr -d ' ')
            _ev="$_ev $d/(${c}项)"
        fi
    done
    if [ -n "$_ev" ]; then
        hit "$_name"
        for e in $_ev; do printf '         └ %s\n' "$e"; done
        TEE_FOUND="${TEE_FOUND:+$TEE_FOUND, }$_name"
        return 0
    fi
    return 1
}

# ================================================================ 检测项 ==
check_env() {
    section "0. 运行环境"
    kv "脚本版本" "$VERSION"
    kv "时间" "$(date '+%Y-%m-%d %H:%M:%S')"
    kv "用户" "$(id 2>/dev/null | cut -d' ' -f1-2)"
    if is_root; then
        ok "以 root 运行, 可进行完整检测"
    else
        case "$PREFIX" in
            *com.termux*) kv "运行于" "Termux (普通应用权限)" ;;
        esac
        [ "$(id -u)" = "2000" ] && kv "运行于" "adb shell"
        info "非 root: 进程/内核/启动参数/Root 痕迹等部分检测会受限"
        command -v su >/dev/null 2>&1 && info "检测到 su, 可用 'su -c sh $0' 获取完整结果"
    fi
    load_ps
    [ "$PS_VISIBLE" = 1 ] || info "无法查看系统进程列表 (hidepid), 进程类证据将缺失"
}

check_device() {
    section "1. 设备信息"
    kv "品牌 / 型号" "$(gp ro.product.brand) / $(gp ro.product.model)"
    kv "设备代号" "$(gp ro.product.device)"
    kv "制造商" "$(gp ro.product.manufacturer)"
    kv "SoC 平台 (ro.board.platform)" "$(gp ro.board.platform)"
    kv "SoC 型号 (ro.soc.model)" "$(echo "$(gp ro.soc.manufacturer) $(gp ro.soc.model)" | sed 's/^ *//; s/ *$//')"
    kv "硬件 (ro.hardware)" "$(gp ro.hardware)"
    kv "Android 版本 / SDK" "$(gp ro.build.version.release) / $(gp ro.build.version.sdk)"
    kv "首发 API (first_api_level)" "$(gp ro.product.first_api_level)"
    kv "Vendor API level" "$(gp ro.vendor.api_level)"
    kv "构建指纹" "$(gp ro.build.fingerprint)"
    kv "内核" "$(uname -r 2>/dev/null)"
}

check_boot() {
    section "2. 启动验证 / Bootloader 状态"
    vbs=$(gp ro.boot.verifiedbootstate)
    locked=$(gp ro.boot.flash.locked)
    devstate=$(gp ro.boot.vbmeta.device_state)
    kv "ro.boot.verifiedbootstate" "$vbs"
    kv "ro.boot.flash.locked" "$locked"
    kv "ro.boot.vbmeta.device_state" "$devstate"
    kv "ro.boot.veritymode" "$(gp ro.boot.veritymode)"
    kv "ro.boot.vbmeta.avb_version" "$(gp ro.boot.vbmeta.avb_version)"
    kv "ro.boot.vbmeta.digest" "$(gp ro.boot.vbmeta.digest | cut -c1-32)"
    kv "ro.oem_unlock_supported" "$(gp ro.oem_unlock_supported)"
    kv "sys.oem_unlock_allowed" "$(gp sys.oem_unlock_allowed)"
    kv "ro.build.type / tags" "$(gp ro.build.type) / $(gp ro.build.tags)"
    kv "ro.debuggable / ro.secure" "$(gp ro.debuggable) / $(gp ro.secure)"

    case "$vbs" in
        green)  ok "启动验证 green: Bootloader 已锁定且运行官方签名系统" ;;
        yellow) warn "启动验证 yellow: 已锁定但使用自定义密钥 (第三方 ROM 重锁)" ;;
        orange) bad "启动验证 orange: Bootloader 已解锁" ;;
        red)    bad "启动验证 red: 验证失败" ;;
        *)      warn "无法读取 verifiedbootstate" ;;
    esac
    [ "$locked" = "0" ] && bad "ro.boot.flash.locked=0 (已解锁)"
    [ "$devstate" = "unlocked" ] && bad "vbmeta.device_state=unlocked"
    [ "$(gp ro.build.tags)" = "test-keys" ] && warn "系统使用 test-keys 签名"
    [ "$(gp ro.debuggable)" = "1" ] && warn "ro.debuggable=1 (调试版系统)"

    # 三星 Knox 熔断位
    wb=$(gp ro.boot.warranty_bit); [ -z "$wb" ] && wb=$(gp ro.warranty_bit)
    if [ -n "$wb" ]; then
        kv "Samsung warranty_bit (Knox)" "$wb"
        case "$wb" in 0|0x0) ok "Knox 未熔断" ;; *) bad "Knox 已熔断 (warranty_bit=$wb), TEE 相关功能永久受限" ;; esac
    fi

    # 属性与内核启动参数交叉校验 (resetprop 伪装检测)
    if is_root; then
        kvbs=$(bootarg verifiedbootstate)
        kstate=$(bootarg vbmeta.device_state)
        kv "内核参数 verifiedbootstate" "$kvbs"
        kv "内核参数 vbmeta.device_state" "$kstate"
        if [ -n "$kvbs" ] && [ "$kvbs" != "$vbs" ]; then
            warn "属性 ($vbs) 与内核启动参数 ($kvbs) 不一致 → 属性被修改/伪装"
        elif [ -n "$kvbs" ]; then
            ok "属性与内核启动参数一致"
        fi
        if [ -n "$kstate" ] && [ -n "$devstate" ] && [ "$kstate" != "$devstate" ]; then
            warn "device_state 属性 ($devstate) 与内核参数 ($kstate) 不一致 → 属性被伪装"
        fi
    else
        skip "属性/内核启动参数交叉校验 (需 root)"
    fi
}

check_patch() {
    section "3. 安全补丁级别"
    sp=$(gp ro.build.version.security_patch)
    kv "系统安全补丁" "$sp"
    kv "Vendor 安全补丁" "$(gp ro.vendor.build.security_patch)"
    kv "Boot 补丁 (ro.bootimage)" "$(gp ro.bootimage.build.date)"
    if [ -n "$sp" ]; then
        py=${sp%%-*}; pm=${sp#*-}; pm=${pm%%-*}; pm=${pm#0}
        ny=$(date +%Y); nm=$(date +%m); nm=${nm#0}
        if [ -n "$py" ] && [ -n "$pm" ]; then
            age=$(( (ny * 12 + nm) - (py * 12 + pm) ))
            if [ "$age" -le 6 ]; then ok "安全补丁较新 (约 $age 个月前)"
            elif [ "$age" -le 12 ]; then warn "安全补丁约 $age 个月前"
            else warn "安全补丁已过期约 $age 个月, 部分应用 (强完整性) 可能不通过"
            fi
        fi
    fi
}

check_tee() {
    section "4. TEE 实现检测"
    probe_tee "Qualcomm QSEE / QTEE" \
        "/dev/qseecom /dev/smcinvoke" "qseecomd" "libQSEEComAPI.so" ""
    probe_tee "Trustonic Kinibi (<t-base)" \
        "/dev/mobicore /dev/mobicore-user /dev/t-base-tui" "mcDriverDaemon" \
        "libMcClient.so" "/vendor/app/mcRegistry"
    probe_tee "Samsung TEEGRIS" \
        "/dev/tzdev /dev/tziwsock" "tzdaemon tzts_daemon" "libteecl.so" "/vendor/tee"
    probe_tee "Huawei iTrustee" \
        "/dev/tc_ns_client /dev/tc_private /dev/tc_ns_cvm" "teecd" "libteec_vendor.so" ""
    probe_tee "OP-TEE" \
        "/dev/tee0 /dev/teepriv0" "tee-supplicant" "" \
        "/vendor/lib/optee_armtz /data/vendor/tee"
    probe_tee "Google Trusty" \
        "/dev/trusty-ipc-dev0" "storageproxyd" "libtrusty.so" ""
    probe_tee "Microtrust / Beanpod ISEE (MTK)" \
        "/dev/isee_tee0 /dev/teei_client /dev/teei_config /dev/teei_fp" "teei_daemon" "" ""

    [ -z "$TEE_FOUND" ] && warn "未识别到已知 TEE 实现 (可能是权限受限或未收录的实现)"

    # 通用 TEE 子系统
    [ -d /sys/bus/tee/devices ] && kv "/sys/bus/tee/devices" "$(ls /sys/bus/tee/devices 2>/dev/null | tr '\n' ' ')"
    [ -d /proc/device-tree/firmware ] && kv "设备树 firmware 节点" "$(ls /proc/device-tree/firmware 2>/dev/null | tr '\n' ' ')"

    # 高通 TA 镜像
    tas=$(ls /vendor/firmware_mnt/image /vendor/firmware 2>/dev/null \
          | grep -iE '^(keymaster|keymint|km4|gatekeeper|widevine|haventkn|uefisec|storsec)' \
          | sed 's/\..*//' | sort -u | tr '\n' ' ')
    [ -n "$tas" ] && kv "QSEE TA (固件)" "$tas"

    # TEE 相关设备节点汇总
    nodes=$(ls /dev 2>/dev/null | grep -iE 'qsee|smcinvoke|mobicore|tzdev|^tee|trusty|tc_ns|teei|isee|citadel|gsc|spcom' | tr '\n' ' ')
    kv "TEE 相关 /dev 节点" "$nodes"

    # StrongBox 安全芯片
    printf '\n  %sStrongBox 独立安全芯片:%s\n' "$W" "$N"
    _tee_before=$TEE_FOUND
    probe_tee "Google Titan M / M2" "/dev/citadel0 /dev/gsc0" "citadeld gscd" "" "" && SB_FOUND="Titan M"
    probe_tee "Qualcomm SPU (安全处理单元)" "/dev/spcom" "spdaemon" "" "" && SB_FOUND="${SB_FOUND:+$SB_FOUND, }Qualcomm SPU"
    TEE_FOUND=$_tee_before
    [ -z "$SB_FOUND" ] && info "未发现已知独立安全芯片 (三星/华为等可能使用 eSE, 见第 5 节 StrongBox 特性)"
}

check_keymint() {
    section "5. Keystore / KeyMint / Gatekeeper"

    # --- 系统特性 ---
    FEATS=$(pm list features 2>/dev/null)
    if [ -n "$FEATS" ]; then
        fv() { printf '%s\n' "$FEATS" | grep -E "^feature:$1(=|\$)" | head -n 1 | sed 's/^feature://'; }
        hk=$(fv android.hardware.hardware_keystore)
        if [ -n "$hk" ]; then
            ver=${hk#*=}
            case "$ver" in
                40) desc="Keymaster 4.0" ;; 41) desc="Keymaster 4.1" ;;
                100) desc="KeyMint 1.0" ;; 200) desc="KeyMint 2.0" ;;
                300) desc="KeyMint 3.0" ;; 400) desc="KeyMint 4.0" ;;
                *) desc="版本 $ver" ;;
            esac
            ok "硬件 Keystore: $desc ($hk)"
        else
            warn "未声明 android.hardware.hardware_keystore (Android 12 以下设备正常)"
        fi
        if [ -n "$(fv android.hardware.strongbox_keystore)" ]; then
            ok "支持 StrongBox Keystore ($(fv android.hardware.strongbox_keystore))"
        else
            info "不支持 StrongBox (仅 TEE 级密钥, 不影响正常使用)"
        fi
        for f in android.hardware.keystore.app_attest_key \
                 android.hardware.device_unique_attestation \
                 android.software.device_id_attestation \
                 android.hardware.identity_credential \
                 android.software.secure_lock_screen; do
            v=$(fv "$f")
            if [ -n "$v" ]; then kv "$f" "✔ ${v#*=}"; else kv "$f" "✘"; fi
        done
    else
        skip "无法执行 pm list features"
    fi

    # --- VINTF manifest 中的安全 HAL ---
    printf '\n  %sVINTF 声明的安全 HAL:%s\n' "$W" "$N"
    mf=""
    for f in /vendor/etc/vintf/manifest.xml /vendor/etc/vintf/manifest/*.xml \
             /odm/etc/vintf/manifest.xml /odm/etc/vintf/manifest/*.xml \
             /vendor/manifest.xml /odm/manifest.xml /apex/*/etc/vintf/*.xml; do
        [ -r "$f" ] && mf="$mf $f"
    done
    if [ -n "$mf" ]; then
        hals=$(cat $mf 2>/dev/null | parse_vintf \
               | grep -iE 'keymint|keymaster|gatekeeper|weaver|secureclock|sharedsecret|identity|authsecret|oemlock|confirmationui' \
               | sort -u)
        if [ -n "$hals" ]; then
            printf '%s\n' "$hals" | while IFS='|' read -r n v i; do
                printf '    • %s  %s\n' "$n${v:+ @$v}" "${i:+[$i]}"
            done
            printf '%s\n' "$hals" | grep -qi keymint && ok "已声明 KeyMint HAL"
            printf '%s\n' "$hals" | grep -qi keymaster && info "已声明 Keymaster (HIDL) HAL"
            printf '%s\n' "$hals" | grep -qi 'strongbox' && ok "HAL 含 strongbox 实例"
            printf '%s\n' "$hals" | grep -qiE 'keymint|keymaster' || bad "manifest 中未找到 KeyMint/Keymaster HAL"
        else
            warn "manifest 中未解析到安全相关 HAL"
        fi
    else
        skip "无法读取 VINTF manifest"
    fi

    # --- HAL 服务进程 / 二进制 ---
    bins=$(ls /vendor/bin/hw /vendor/bin 2>/dev/null \
           | grep -iE 'keymint|keymaster|gatekeeper|weaver|strongbox|secureclock|citadel' | sort -u | tr '\n' ' ')
    kv "HAL 服务二进制" "$bins"

    svc=$(service list 2>/dev/null | grep -iE 'keymint|keystore|gatekeeper|secureclock|sharedsecret|weaver|remotelyprovisioned' \
          | sed 's/^[0-9]*[[:space:]]*//; s/:.*//')
    if [ -n "$svc" ]; then
        printf '\n  %s已注册的 Binder 服务:%s\n' "$W" "$N"
        printf '%s\n' "$svc" | sed 's/^/    • /'
        printf '%s\n' "$svc" | grep -qi 'IRemotelyProvisionedComponent' && ok "支持远程密钥配置 (RKP)"
    else
        skip "无法执行 service list (应用权限受限, adb/root 下可用)"
    fi

    if command -v lshal >/dev/null 2>&1 && { is_root || [ "$(id -u)" = "2000" ]; }; then
        hidl=$(lshal 2>/dev/null | grep -iE 'keymaster|gatekeeper' | sed 's/^[[:space:]]*//; s/[[:space:]].*//' | sort -u)
        [ -n "$hidl" ] && { printf '\n  %sHIDL 服务 (lshal):%s\n' "$W" "$N"; printf '%s\n' "$hidl" | sed 's/^/    • /'; }
    fi

    # --- 关键进程 ---
    if [ "$PS_VISIBLE" = 1 ]; then
        printf '\n  %s关键进程:%s\n' "$W" "$N"
        if proc_running keystore2; then ok "keystore2 运行中"
        elif proc_running keystore; then ok "keystore 运行中"
        else bad "未发现 keystore/keystore2 进程"
        fi
        kmp=$(printf '%s\n' "$PS_OUT" | grep -iE 'keymint|keymaster' | sed 's/.*[ /]//' | sort -u | tr '\n' ' ')
        if [ -n "$kmp" ]; then ok "KeyMint/Keymaster HAL 进程: $kmp"
        else info "未看到独立 KeyMint/Keymaster 进程 (部分机型集成在其他进程中)"
        fi
        gkp=$(printf '%s\n' "$PS_OUT" | grep -iE 'gatekeeper' | sed 's/.*[ /]//' | sort -u | tr '\n' ' ')
        [ -n "$gkp" ] && kv "Gatekeeper 进程" "$gkp"
    fi

    # --- 相关属性 ---
    printf '\n  %s相关系统属性:%s\n' "$W" "$N"
    for p in ro.hardware.keystore ro.hardware.keystore_desede ro.hardware.gatekeeper \
             ro.hardware.egl ro.crypto.state ro.crypto.type ro.crypto.metadata.enabled \
             remote_provisioning.hostname keystore.boot_level; do
        v=$(gp "$p"); [ -n "$v" ] && kv "$p" "$v"
    done
    $GETPROP 2>/dev/null | grep -iE 'keymaster|keymint|strongbox|trusty|qsee|teegris|itrustee|tee\.|\.tee|attest' \
        | head -n 20 | sed 's/^/    /'

    cs=$(gp ro.crypto.state)
    case "$cs" in
        encrypted) ok "存储已加密 ($(gp ro.crypto.type))" ;;
        unencrypted) bad "存储未加密" ;;
    esac
}

check_selinux() {
    section "6. SELinux"
    se=$(getenforce 2>/dev/null)
    [ -z "$se" ] && [ -r /sys/fs/selinux/enforce ] && \
        se=$( [ "$(cat /sys/fs/selinux/enforce)" = 1 ] && echo Enforcing || echo Permissive )
    kv "SELinux 状态" "$se"
    case "$se" in
        Enforcing)  ok "SELinux Enforcing" ;;
        Permissive) bad "SELinux Permissive (宽容模式)" ;;
        *)          info "无法读取 SELinux 状态 (应用权限下常见, 通常为 Enforcing)" ;;
    esac
}

check_root() {
    section "7. Root / 模块 / 伪装环境"
    found=""
    for p in /system/bin/su /system/xbin/su /sbin/su /system/sbin/su /vendor/bin/su \
             /su/bin/su /data/local/su /data/local/bin/su /data/local/xbin/su; do
        [ -e "$p" ] && found="$found $p"
    done
    s=$(command -v su 2>/dev/null) && found="$found PATH:$s"
    if [ -n "$found" ]; then warn "发现 su:$found"; else ok "未在常见路径发现 su"; fi

    if ! is_root; then
        skip "/data/adb 下的 Magisk / KernelSU / APatch / 模块检测 (需 root)"
        return
    fi

    [ -d /data/adb/magisk ] && hit "Magisk ($(magisk -v 2>/dev/null) $(magisk -V 2>/dev/null))"
    [ -d /data/adb/ksu ]    && hit "KernelSU ($(ksud -V 2>/dev/null || /data/adb/ksud -V 2>/dev/null))"
    [ -d /data/adb/ap ]     && hit "APatch"
    [ -e /data/adb/ksu/.susfs ] || [ -e /data/adb/modules/susfs4ksu ] && hit "SUSFS"

    if [ -d /data/adb/modules ]; then
        mods=$(ls /data/adb/modules 2>/dev/null)
        cnt=$(printf '%s\n' "$mods" | grep -c .)
        kv "已安装模块数" "$cnt"
        for m in $mods; do
            mp=/data/adb/modules/$m
            name=$(grep '^name=' "$mp/module.prop" 2>/dev/null | head -n1 | cut -d= -f2-)
            ver=$(grep '^version=' "$mp/module.prop" 2>/dev/null | head -n1 | cut -d= -f2-)
            st=""
            [ -e "$mp/disable" ] && st=" (已禁用)"
            [ -e "$mp/remove" ] && st=" (待删除)"
            line="$m: ${name:-?} ${ver}$st"
            if printf '%s %s\n' "$m" "$name" | grep -qiE 'tricky|integrity|pif|tee|keybox|attest|shamiko|zygisk|hide|susfs|spoof|bootloader|vbmeta'; then
                printf '    %s★ %s%s\n' "$Y" "$line" "$N"
            else
                printf '    • %s\n' "$line"
            fi
        done
    fi

    # TrickyStore (TEE 证书伪装)
    if [ -d /data/adb/tricky_store ]; then
        hit "TrickyStore 配置目录 /data/adb/tricky_store"
        ts=/data/adb/tricky_store
        [ -f $ts/keybox.xml ] && {
            kv "keybox.xml" "存在 ($(grep -c 'BEGIN CERTIFICATE' $ts/keybox.xml 2>/dev/null) 张证书)"
            sn=$(grep -oE 'DeviceID="[^"]*"' $ts/keybox.xml 2>/dev/null | head -n1)
            [ -n "$sn" ] && kv "keybox DeviceID" "${sn#DeviceID=}"
        }
        [ -f $ts/target.txt ] && kv "target.txt 条目数" "$(grep -c . $ts/target.txt)"
        [ -f $ts/security_patch.txt ] && kv "security_patch.txt" "$(tr '\n' ' ' < $ts/security_patch.txt)"
        info "TrickyStore 会伪装证明链, 第 2/5 节结果可能被修改"
    fi
    [ -f /data/adb/pif.json ] && hit "Play Integrity Fix 配置 /data/adb/pif.json"
    for f in /data/adb/modules/playintegrityfix/custom.pif.json /data/adb/modules/playintegrityfix/pif.json; do
        [ -f "$f" ] && kv "PIF 配置" "$f"
    done

    # 内核日志中的 TEE 信息
    printf '\n  %s内核日志 (TEE 相关, 最后 15 行):%s\n' "$W" "$N"
    dm=$(dmesg 2>/dev/null | grep -iE 'qseecom|smcinvoke|optee|trusty|mobicore|tzdev|teegris|tc_ns|teei|isee|citadel|keymaster|keymint|tee_' | tail -n 15)
    if [ -n "$dm" ]; then printf '%s\n' "$dm" | cut -c1-140 | sed 's/^/    /'
    else info "dmesg 中无 TEE 相关记录 (或日志已轮转)"
    fi
}

summary() {
    section "8. 总结"
    kv "检测到的 TEE" "${TEE_FOUND:-未识别}"
    kv "StrongBox 安全芯片" "${SB_FOUND:-未发现}"
    kv "启动验证状态" "$(gp ro.boot.verifiedbootstate)"
    printf '  %sPASS: %d%s   %sWARN: %d%s   %sFAIL: %d%s\n' \
        "$G" "$PASS" "$N" "$Y" "$WARN" "$N" "$R" "$FAIL" "$N"
    cat <<EOF

  说明:
   • Shell 只能检测 TEE "是否存在/是否在运行" 和环境状态, 无法验证
     硬件证明 (Key Attestation) 证书链是否有效、keybox 是否被吊销。
   • 如需确认 "TEE 是否损坏"/证明链是否可信, 请配合以下 App:
       - Key Attestation (vvb2060)   查看证明链、Root of Trust、吊销状态
       - Play Integrity API Checker  查看 Play 完整性判定
   • 属性 (getprop) 可被 resetprop 修改; root 下第 2 节的内核参数交叉
     校验更可信。
EOF
}

main() {
    printf '%s╔══════════════════════════════════════════════╗%s\n' "$W$B" "$N"
    printf '%s║      Android TEE 环境检测脚本  v%-13s║%s\n' "$W$B" "$VERSION" "$N"
    printf '%s╚══════════════════════════════════════════════╝%s\n' "$W$B" "$N"
    check_env
    check_device
    check_boot
    check_patch
    check_tee
    check_keymint
    check_selinux
    check_root
    summary
}

# ---------------------------------------------------------------- 日志输出 --
if [ -z "$LOG_FILE" ]; then
    for d in /sdcard/Download /sdcard "$HOME" /data/local/tmp "$(dirname "$0")"; do
        if [ -n "$d" ] && [ -d "$d" ] && [ -w "$d" ]; then
            LOG_FILE="$d/tee_check_$(date +%Y%m%d_%H%M%S).log"
            break
        fi
    done
fi

if [ -n "$LOG_FILE" ] && : > "$LOG_FILE" 2>/dev/null; then
    TMP_LOG="$LOG_FILE.tmp"
    main 2>&1 | tee "$TMP_LOG"
    ESC=$(printf '\033')
    sed "s/${ESC}\[[0-9;]*m//g" "$TMP_LOG" > "$LOG_FILE" 2>/dev/null
    rm -f "$TMP_LOG"
    printf '\n日志已保存: %s\n' "$LOG_FILE"
else
    main 2>&1
fi
