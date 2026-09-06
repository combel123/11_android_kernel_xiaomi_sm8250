#!/bin/bash

# Some logics of this script are copied from [scripts/build_kernel]. Thanks to UtsavBalar1231.

# Exit on command or pipeline failures. This is important for remote setup/patch
# downloads: a failed curl must never be hidden by the command behind the pipe.
set -eo pipefail

# ==========================================
# Argument Parsing
# ==========================================
if [ -z "$1" ]; then
    echo "[!] Error: No device specified."
    echo "Usage: $0 <device_name> [ksu] [miui|aosp]"
    echo "Example: $0 lmi"
    echo "         $0 lmi ksu"
    echo "         $0 lmi ksu miui"
    echo "         $0 lmi aosp"
    exit 1
fi

DEVICE_NAME="$1"
DEFCONFIG="${DEVICE_NAME}_defconfig"
DEFCONFIG_PATH="arch/arm64/configs/${DEFCONFIG}"

if [ ! -f "$DEFCONFIG_PATH" ]; then
    echo "[!] Error: Defconfig not found at $DEFCONFIG_PATH"
    echo "[!] Please verify the device name and try again."
    exit 1
fi

ENABLE_KSU=0
TARGET_OS="both"

shift
# Parse remaining arguments loosely
for arg in "$@"; do
    case "$arg" in
        ksu) ENABLE_KSU=1 ;;
        miui) TARGET_OS="miui" ;;
        aosp) TARGET_OS="aosp" ;;
    esac
done

# ==========================================
# Configuration & Environment
# ==========================================
KERNEL_DIR="$(pwd)"
TOOLCHAIN_BIN="$HOME/zyc-clang/bin"

export PATH="${TOOLCHAIN_BIN}:${PATH}"
export ARCH="arm64"
export SUBARCH="arm64"

# ccache Setup
export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
export CCACHE_EXEC=$(command -v ccache)

if [ -z "$CCACHE_EXEC" ]; then
    echo "[!] ccache not found! Please install ccache first."
    exit 1
fi

export USE_CCACHE=1
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"

echo "[*] Checking Clang version..."
clang --version || { echo "[!] Clang not found at ${TOOLCHAIN_BIN}. Please check the path."; exit 1; }

echo "[*] Setting up ccache in $CCACHE_DIR..."
mkdir -p "$CCACHE_DIR"

# ==========================================
# Droidspaces Constants & Functions
# ==========================================
DROIDSPACES_VERSION="${DROIDSPACES_VERSION:-v6.4.5}"
DROIDSPACES_PATCH_BASE="https://raw.githubusercontent.com/ravindu644/Droidspaces-OSS/${DROIDSPACES_VERSION}/Documentation/resources/kernel-patches/non-GKI"
DROIDSPACES_XT_QTAGUID_SHA256="f71898942e0f872c5cf28ebaef0dcd9b9efe7e02f0dfc8310441efa8772fed7d"
DROIDSPACES_CGROUP_SHA256="6d2c9dbe5aa394328c35845e416ac274bade7dce36994b945de75769448219cc"

apply_droidspaces_patch() {
    local description="$1"
    local url="$2"
    local expected_sha256="$3"
    local patch_file="$4"

    echo "Download Droidspaces patch: ${description}"
    curl -fLSs --retry 3 --connect-timeout 20 -o "$patch_file" "$url"
    printf '%s  %s\n' "$expected_sha256" "$patch_file" | sha256sum -c -

    if git apply --check --whitespace=nowarn "$patch_file" 2>/dev/null; then
        git apply --whitespace=nowarn "$patch_file"
        echo "Applied Droidspaces patch: ${description}"
    elif git apply --reverse --check --whitespace=nowarn "$patch_file" 2>/dev/null; then
        echo "Droidspaces patch already applied: ${description}"
    else
        git apply --check --whitespace=nowarn "$patch_file" || true
        echo "ERROR: Droidspaces patch is incompatible with this kernel tree: ${description}"
        echo "Do not continue building a kernel that only passes config checks; this patch prevents a runtime kernel panic."
        exit 1
    fi
}

integrate_droidspaces_non_gki() {
    local kernel_version kernel_patchlevel kernel_series patch_dir

    kernel_version=$(awk '$1 == "VERSION" { print $3; exit }' Makefile)
    kernel_patchlevel=$(awk '$1 == "PATCHLEVEL" { print $3; exit }' Makefile)
    kernel_series="${kernel_version}.${kernel_patchlevel}"

    case "$kernel_series" in
        3.18|4.4|4.9|4.14|4.19)
            ;;
        *)
            echo "ERROR: Detected Linux ${kernel_series}. This script carries Droidspaces non-GKI patches only."
            echo "For a GKI kernel, use the version-specific kABI patches from the official Droidspaces guide."
            exit 1
            ;;
    esac

    if [ ! -f kernel/cgroup/cgroup.c ]; then
        echo "ERROR: This legacy kernel tree lacks kernel/cgroup/cgroup.c."
        exit 1
    fi

    patch_dir=$(mktemp -d /tmp/droidspaces-kernel-patches.XXXXXX)

    if [ -f net/netfilter/xt_qtaguid.c ]; then
        apply_droidspaces_patch \
            "avoid xt_qtaguid kernel panic when container interfaces change" \
            "${DROIDSPACES_PATCH_BASE}/01.fix_kernel_panic_in_xt_qtaguid.patch" \
            "$DROIDSPACES_XT_QTAGUID_SHA256" \
            "${patch_dir}/01-xt_qtaguid-panic.patch"
    else
        echo "xt_qtaguid is not present in this kernel tree; its panic path is absent, so patch 01 is not applicable."
    fi

    apply_droidspaces_patch \
        "restore cgroup file prefixes for Droidspaces/LXC" \
        "${DROIDSPACES_PATCH_BASE}/02.fix_restore%20cgroup%20file%20prefix%20handling%20.patch" \
        "$DROIDSPACES_CGROUP_SHA256" \
        "${patch_dir}/02-cgroup-prefix.patch"

    rm -r -- "$patch_dir"
    echo "Droidspaces ${DROIDSPACES_VERSION} non-GKI runtime patches are ready."
}

configure_droidspaces_non_gki() {
    local out_dir="$1"
    local missing=0 symbol
    local critical_configs=(
        SYSCTL SYSVIPC POSIX_MQUEUE
        NAMESPACES PID_NS UTS_NS IPC_NS
        SECCOMP SECCOMP_FILTER
        CGROUPS CGROUP_DEVICE CGROUP_PIDS MEMCG CGROUP_SCHED
        FAIR_GROUP_SCHED CGROUP_FREEZER
        DEVTMPFS OVERLAY_FS
        NET_NS VETH BRIDGE NETFILTER BRIDGE_NETFILTER
        NF_CONNTRACK IP_NF_IPTABLES IP_NF_FILTER NF_NAT NF_TABLES
        IP_NF_TARGET_MASQUERADE
        NETFILTER_XT_TARGET_TCPMSS NETFILTER_XT_MATCH_ADDRTYPE
        NF_CT_NETLINK NF_NAT_REDIRECT
        IP_ADVANCED_ROUTER IP_MULTIPLE_TABLES
    )

    echo "Enable official Droidspaces non-GKI kernel configuration..."
    scripts/config --file "${out_dir}/.config" \
        -e SYSCTL \
        -e SYSVIPC \
        -e POSIX_MQUEUE \
        -e NAMESPACES \
        -e PID_NS \
        -e UTS_NS \
        -e IPC_NS \
        -e SECCOMP \
        -e SECCOMP_FILTER \
        -e CGROUPS \
        -e CGROUP_DEVICE \
        -e CGROUP_PIDS \
        -e MEMCG \
        -e CGROUP_SCHED \
        -e FAIR_GROUP_SCHED \
        -e CGROUP_FREEZER \
        -e CGROUP_NET_PRIO \
        -e DEVTMPFS \
        -e OVERLAY_FS \
        -e TMPFS_POSIX_ACL \
        -e TMPFS_XATTR \
        -e FW_LOADER \
        -e FW_LOADER_USER_HELPER \
        -e FW_LOADER_COMPRESS \
        -e NET_NS \
        -e VETH \
        -e BRIDGE \
        -e NETFILTER \
        -e BRIDGE_NETFILTER \
        -e NETFILTER_ADVANCED \
        -e NF_CONNTRACK \
        -e IP_NF_IPTABLES \
        -e IP_NF_FILTER \
        -e NF_NAT \
        -e NF_TABLES \
        -e IP_NF_TARGET_MASQUERADE \
        -e NETFILTER_XT_TARGET_MASQUERADE \
        -e NETFILTER_XT_TARGET_TCPMSS \
        -e NETFILTER_XT_MATCH_ADDRTYPE \
        -e NF_CT_NETLINK \
        -e NF_CONNTRACK_NETLINK \
        -e NF_NAT_REDIRECT \
        -e IP_ADVANCED_ROUTER \
        -e IP_MULTIPLE_TABLES \
        -e NF_CONNTRACK_IPV4 \
        -e NF_NAT_IPV4 \
        -e IP_NF_NAT \
        -d USER_NS \
        -d ANDROID_PARANOID_NETWORK

    # Resolve dependencies now
    make "${MAKE_OPTS[@]}" olddefconfig 2>/dev/null || true

    if grep -Eq '^CONFIG_PERF_HUMANTASK=(y|m)$' "${out_dir}/.config"; then
        echo "ERROR: CONFIG_PERF_HUMANTASK was re-enabled by Kconfig."
        echo "Droidspaces container startup is unsafe; aborting before compilation."
        exit 1
    fi
    echo "CONFIG_PERF_HUMANTASK is disabled for Droidspaces compatibility."

    for symbol in "${critical_configs[@]}"; do
        if ! grep -qx "CONFIG_${symbol}=y" "${out_dir}/.config"; then
            echo "ERROR: CONFIG_${symbol}=y did not survive olddefconfig."
            missing=1
        fi
    done

    if [ "$missing" -ne 0 ]; then
        echo "ERROR: Required Droidspaces configuration is incomplete; aborting before compilation."
        exit 1
    fi

    echo "Droidspaces critical configuration verified after olddefconfig."
}

# ==========================================
# KernelSU Setup & SUSFS v2.3.0 Adaptation
# ==========================================
if [ "$ENABLE_KSU" -eq 1 ]; then
    echo "==========================================="
    echo " [*] Initializing KernelSU (ReSukiSU) Setup"
    echo "==========================================="
    echo "[*] Downloading and running ReSukiSU remote setup script..."
    curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash
    echo "[+] KernelSU setup finished."

    if [ -f include/linux/susfs.h ]; then
        echo "=========================================================================="
        echo " [*] Backporting official GKI SUSFS v2.3.0 onto Linux 4.19 i_state + hooks"
        echo "=========================================================================="
        
        GKI_BASE='https://gitlab.com/simonpunk/susfs4ksu/-/raw/gki-android12-5.10/kernel_patches'
        mkdir -p "$KERNEL_DIR/.susfs23-upstream"
        curl -fLSs "$GKI_BASE/fs/susfs.c" -o "$KERNEL_DIR/.susfs23-upstream/susfs.c"
        curl -fLSs "$GKI_BASE/include/linux/susfs.h" -o "$KERNEL_DIR/.susfs23-upstream/susfs.h"
        curl -fLSs "$GKI_BASE/include/linux/susfs_def.h" -o "$KERNEL_DIR/.susfs23-upstream/susfs_def.h"

        # 1. Backport core SUSFS files to 4.19 format
        python3 -u - <<'PY'
from pathlib import Path
import os

ws = Path(os.environ.get('GITHUB_WORKSPACE', '.'))
up = ws / '.susfs23-upstream'
gki_c = (up / 'susfs.c').read_text()
gki_h = (up / 'susfs.h').read_text()
gki_d = (up / 'susfs_def.h').read_text()
old_c = Path('fs/susfs.c').read_text()

old_start = old_c.find('static SUSFS_DECL_FSNOTIFY_OPS(susfs_handle_sdcard_inode_event)')
old_end = old_c.find('static int susfs_sdcard_monitor_fn')

c = gki_c.replace('i_mapping->flags', 'i_state')
d = gki_d.replace('inode->i_mapping->flags', 'inode->i_state').replace('i_mapping->flags', 'i_state')
d = d.replace(
    "inode->i_mapping->flags => A 'unsigned long' type storing flag 'AS_FLAGS_",
    "inode->i_state => A 'unsigned long' type storing flag 'AS_FLAGS_",
)

if '#include <linux/version.h>' not in d:
    if '#include <linux/bits.h>' in d:
        d = d.replace('#include <linux/bits.h>', '#include <linux/bits.h>\n#include <linux/version.h>\n#include <linux/cred.h>', 1)
    else:
        d = d.replace('#define KSU_SUSFS_DEF_H', '#define KSU_SUSFS_DEF_H\n\n#include <linux/version.h>\n#include <linux/cred.h>', 1)

if 'SUSFS_DECL_FSNOTIFY_OPS' not in d:
    helper = r'''
/* 4.19 / non-GKI fsnotify compatibility */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0)
typedef const struct qstr *susfs_fname_t;
#define susfs_fname_len(f) ((f)->len)
#define susfs_fname_arg(f) ((f)->name)
#else
typedef const unsigned char *susfs_fname_t;
#define susfs_fname_len(f) (strlen(f))
#define susfs_fname_arg(f) (f)
#endif

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
#define SUSFS_DECL_FSNOTIFY_OPS(name)                                          \
int name(struct fsnotify_mark *mark, u32 mask, struct inode *inode,    \
struct inode *dir, const struct qstr *file_name, u32 cookie)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(4, 18, 0)
#define SUSFS_DECL_FSNOTIFY_OPS(name)                                          \
int name(struct fsnotify_group *group, struct inode *inode, u32 mask,  \
const void *data, int data_type, susfs_fname_t file_name,       \
u32 cookie, struct fsnotify_iter_info *iter_info)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(4, 12, 0)
#define SUSFS_DECL_FSNOTIFY_OPS(name)                                          \
int name(struct fsnotify_group *group, struct inode *inode,            \
struct fsnotify_mark *inode_mark,                              \
struct fsnotify_mark *vfsmount_mark, u32 mask,                 \
const void *data, int data_type, susfs_fname_t file_name,       \
u32 cookie, struct fsnotify_iter_info *iter_info)
#else
#define SUSFS_DECL_FSNOTIFY_OPS(name)                                          \
int name(struct fsnotify_group *group, struct inode *inode,            \
struct fsnotify_mark *inode_mark,                              \
struct fsnotify_mark *vfsmount_mark, u32 mask, void *data,    \
int data_type, susfs_fname_t file_name, u32 cookie)
#endif
'''
    d = d.replace('#endif // #ifndef KSU_SUSFS_DEF_H', helper + '\n#endif // #ifndef KSU_SUSFS_DEF_H')

d = d.replace(
    '''static inline bool susfs_is_current_proc_umounted_app(void) {
    return (likely(test_thread_flag(TIF_PROC_UMOUNTED)) &&
            current_uid().val >= 10000);
}''',
    '''static inline bool susfs_is_current_proc_umounted_app(void) {
    return (likely(test_thread_flag(TIF_PROC_UMOUNTED)) &&
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 12, 0)
            __kuid_val(current_uid()) >= 10000);
#else
            current_uid().val >= 10000);
#endif
}'''
)

g_start = c.find('static int susfs_handle_sdcard_inode_event')
g_end = c.find('static int susfs_sdcard_monitor_fn')
if g_start >= 0 and g_end >= 0 and old_start >= 0 and old_end >= 0:
    c = c[:g_start] + old_c[old_start:old_end] + c[g_end:]

if 'int susfs_open_redirect_spoof_show_map_vma(' not in c:
    wrap = '''
#ifdef CONFIG_KSU_SUSFS
int susfs_open_redirect_spoof_show_map_vma(struct inode *inode, unsigned long *out_ino, dev_t *out_dev, char *spoofed_name)
{
    char *name = NULL;
    int ret;

    if (!spoofed_name)
        return 0;
    ret = susfs_open_redirect_spoof_show_map_vma_srcu(inode, out_ino, out_dev, &name);
    if (ret && name)
        strscpy(spoofed_name, name, SUSFS_MAX_LEN_PATHNAME);
    return ret;
}
#endif
'''
    c = c.replace('void susfs_start_sdcard_monitor_fn(void)', wrap + '\nvoid susfs_start_sdcard_monitor_fn(void)', 1)

Path('include/linux/susfs.h').write_text(gki_h)
Path('include/linux/susfs_def.h').write_text(d)
Path('fs/susfs.c').write_text(c)
print('Successfully backported GKI SUSFS v2.3.0 core onto 4.19.')
PY

        # 2. Apply robust inline hook updates for exec.c, open.c, stat.c
        python3 -u - <<'PY'
from pathlib import Path

def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f'{label}: expected block not found')
    return text.replace(old, new, 1)

# ---- fs/exec.c : TIF_PROC_UMOUNTED -> TIF_PROC_NO_SU ----
p = Path('fs/exec.c')
t = p.read_text()
old = """#ifdef CONFIG_KSU_SUSFS
    if (likely(susfs_is_current_proc_umounted()))
        goto orig_flow;
"""
new = """#ifdef CONFIG_KSU_SUSFS
    if (likely(susfs_is_current_proc_no_su()))
        goto orig_flow;
"""
t = must_replace(t, old, new, 'fs/exec.c early-out')
p.write_text(t)
print('rewrote fs/exec.c sucompat early-out to susfs_is_current_proc_no_su', flush=True)

# ---- fs/open.c : getname_flags + filename_lookup + filename** ----
p = Path('fs/open.c')
t = p.read_text()
old = """extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,
            int *flags);
#endif
long do_faccessat(int dfd, const char __user *filename, int mode)
{
    const struct cred *old_cred;
    struct cred *override_cred;
    struct path path;
    struct inode *inode;
    struct vfsmount *mnt;
    int res;
    unsigned int lookup_flags = LOOKUP_FOLLOW;

#ifdef CONFIG_KSU_SUSFS
    if (likely(susfs_is_current_proc_umounted()))
        goto orig_flow;
    if (static_branch_likely(&ksu_su_compat_enabled))
        if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val))) {
            ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
    }

orig_flow:
#endif
"""
new = """extern int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode,
            int *flags);
#endif
long do_faccessat(int dfd, const char __user *filename, int mode)
{
    const struct cred *old_cred;
    struct cred *override_cred;
    struct path path;
    struct inode *inode;
    struct vfsmount *mnt;
    int res;
    unsigned int lookup_flags = LOOKUP_FOLLOW;
#ifdef CONFIG_KSU_SUSFS
    struct filename *fname = NULL;
#endif
"""
t = must_replace(t, old, new, 'fs/open.c proto + early-out')

old = """retry:
    res = user_path_at(dfd, filename, lookup_flags, &path);
    if (res)
        goto out;
"""
new = """retry:
#ifdef CONFIG_KSU_SUSFS
    fname = getname_flags(filename, lookup_flags, NULL);
    if (likely(susfs_is_current_proc_no_su()))
        goto orig_faccessat;
    if (static_branch_likely(&ksu_su_compat_enabled)) {
        if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))
            ksu_handle_faccessat(&dfd, &fname, &mode, NULL);
    }
orig_faccessat:
    res = filename_lookup(dfd, fname, lookup_flags, &path, NULL);
#else
    res = user_path_at(dfd, filename, lookup_flags, &path);
#endif
    if (res)
        goto out;
"""
t = must_replace(t, old, new, 'fs/open.c user_path_at')
p.write_text(t)
print('rewrote fs/open.c do_faccessat to getname_flags + filename_lookup', flush=True)

# ---- fs/stat.c : same split ----
p = Path('fs/stat.c')
t = p.read_text()
if '#include "internal.h"' not in t:
    if '#include <linux/syscalls.h>' in t:
        t = t.replace('#include <linux/syscalls.h>',
                      '#include <linux/syscalls.h>\n#include "internal.h"', 1)
    else:
        t = '#include "internal.h"\n' + t

old = """extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#endif

int vfs_statx(int dfd, const char __user *filename, int flags,
          struct kstat *stat, u32 request_mask)
{
    struct path path;
    int error = -EINVAL;
    unsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;

#ifdef CONFIG_KSU_SUSFS
    if (likely(susfs_is_current_proc_umounted()))
        goto orig_flow;
    if (static_branch_likely(&ksu_su_compat_enabled)) {
        if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))
            ksu_handle_stat(&dfd, &filename, &flags);
    }
orig_flow:
#endif
"""
new = """extern int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
#endif

int vfs_statx(int dfd, const char __user *filename, int flags,
          struct kstat *stat, u32 request_mask)
{
    struct path path;
    int error = -EINVAL;
    unsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;
#ifdef CONFIG_KSU_SUSFS
    struct filename *fname = NULL;
#endif
"""
t = must_replace(t, old, new, 'fs/stat.c proto + early-out')

old = """retry:
    error = user_path_at(dfd, filename, lookup_flags, &path);
    if (error)
        goto out;
"""
new = """retry:
#ifdef CONFIG_KSU_SUSFS
    fname = getname_flags(filename, lookup_flags, NULL);
    if (likely(susfs_is_current_proc_no_su()))
        goto orig_statx;
    if (static_branch_likely(&ksu_su_compat_enabled)) {
        if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))
            ksu_handle_stat(&dfd, &fname, &flags);
    }
orig_statx:
    error = filename_lookup(dfd, fname, lookup_flags, &path, NULL);
#else
    error = user_path_at(dfd, filename, lookup_flags, &path);
#endif
    if (error)
        goto out;
"""
t = must_replace(t, old, new, 'fs/stat.c user_path_at')
p.write_text(t)
print('rewrote fs/stat.c vfs_statx to getname_flags + filename_lookup', flush=True)

# sanity checks
for f, needles, forbidden in (
    ('fs/exec.c', ['susfs_is_current_proc_no_su()'], []),
    ('fs/open.c', ['getname_flags(filename, lookup_flags, NULL)',
                   'filename_lookup(dfd, fname, lookup_flags, &path, NULL)',
                   'ksu_handle_faccessat(&dfd, &fname, &mode, NULL)',
                   'susfs_is_current_proc_no_su()'],
     ['ksu_handle_faccessat(&dfd, &filename']),
    ('fs/stat.c', ['getname_flags(filename, lookup_flags, NULL)',
                   'filename_lookup(dfd, fname, lookup_flags, &path, NULL)',
                   'ksu_handle_stat(&dfd, &fname, &flags)',
                   'susfs_is_current_proc_no_su()'],
     ['ksu_handle_stat(&dfd, &filename']),
):
    text = Path(f).read_text()
    for n in needles:
        if n not in text:
            raise SystemExit(f'{f} missing {n!r}')
    for n in forbidden:
        if n in text:
            raise SystemExit(f'{f} still has old call {n!r}')

print('hook rewrite verified', flush=True)
PY

        # 3. Align ReSukiSU sucompat handlers
        python3 -u - <<'PY'
from pathlib import Path
candidates = ['KernelSU/kernel/feature/sucompat.c', 'drivers/kernelsu/feature/sucompat.c', 'KernelSU/kernel/sucompat.c']
suc = next((Path(f) for f in candidates if Path(f).exists()), None)
if not suc:
    found = list(Path('.').rglob('sucompat.c'))
    suc = found[0] if found else None

if suc and suc.exists():
    t = suc.read_text()
    t = t.replace('susfs_is_current_proc_umounted()', 'susfs_is_current_proc_no_su()')
    t = t.replace('susfs_set_current_proc_umounted()', 'susfs_set_current_proc_no_su()')
    suc.write_text(t)
    print('Aligned ReSukiSU sucompat to SUSFS v2.3.0 successfully.')
PY
    fi
fi

# ==========================================
# Baseband-guard Setup
# ==========================================
echo "==========================================="
echo " [*] Initializing Baseband-guard Setup"
echo "==========================================="
echo "[*] Downloading and running Baseband-guard remote setup script..."
wget -O- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash

echo "[*] Patching security/Kconfig for baseband_guard..."
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig
echo "[+] Baseband-guard setup finished."
echo "==========================================="

# ==========================================
# Droidspaces Source Code Integration
# ==========================================
echo "==========================================="
echo " [*] Integrating Droidspaces Non-GKI Patches"
echo "==========================================="
integrate_droidspaces_non_gki
echo "[+] Droidspaces source patches integrated."
echo "==========================================="

# ==========================================
# AnyKernel3 Setup
# ==========================================
echo "==========================================="
echo " [*] Initializing AnyKernel3 Workspace"
echo "==========================================="
rm -rf anykernel
echo "[*] Cloning AnyKernel3..."
git clone https://github.com/AstideLabs/AnyKernel3 -b kona --single-branch --depth=1 anykernel
echo "[+] AnyKernel3 cloned successfully."
echo "[*] Adjusting AnyKernel3..."
sed -i "s/^device\.name1=.*/device.name1=${DEVICE_NAME}/" anykernel/anykernel.sh
echo "[*] AnyKernel3 adjusted successfully."
echo "==========================================="

# ==========================================
# Modular Build Function
# ==========================================
build_target() {
    local OS_TYPE=$1
    echo "==========================================="
    echo " Starting Kernel Compilation for ${DEVICE_NAME} (Target: $OS_TYPE)"
    echo "==========================================="
    
    local OUT_DIR="${KERNEL_DIR}/out_${OS_TYPE}"
    
    MAKE_OPTS=(
        -j"$(nproc)"
        O="${OUT_DIR}"
        ARCH="${ARCH}"
        SUBARCH="${SUBARCH}"
        LLVM=1
        LLVM_IAS=1
        CC="ccache clang"
        HOSTCC="ccache clang"
        CROSS_COMPILE="${CROSS_COMPILE}"
        CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}"
    )

    echo "[*] Cleaning ${OUT_DIR}..."
    rm -rf "${OUT_DIR}"
    mkdir -p "${OUT_DIR}"

    local DTS_SOURCE="arch/arm64/boot/dts/vendor/qcom"
    local DTS_BACKUP=".dts.bak.${OS_TYPE}"

    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Applying MIUI DTS patches..."
        cp -a "${DTS_SOURCE}" "${DTS_BACKUP}"
        
        sed -i 's/<154>/<1537>/g' ${DTS_SOURCE}/dsi-panel-j1s* || true
        sed -i 's/<154>/<1537>/g' ${DTS_SOURCE}/dsi-panel-j2* || true
        sed -i 's/<155>/<1544>/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true
        sed -i 's/<155>/<1545>/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/<155>/<1546>/g' ${DTS_SOURCE}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<155>/<1546>/g' ${DTS_SOURCE}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<71>/<710>/g' ${DTS_SOURCE}/dsi-panel-j1s* || true
        sed -i 's/<71>/<710>/g' ${DTS_SOURCE}/dsi-panel-j2* || true

        sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${DTS_SOURCE}/dsi-panel* || true

        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi || true
        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi || true
        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi || true
        sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true

        sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi || true
    fi

    echo "[*] Making defconfig: ${DEFCONFIG}..."
    make "${MAKE_OPTS[@]}" "${DEFCONFIG}"

    # 1. Baseband-guard configuration
    echo "[*] Injecting Baseband-guard configuration..."
    scripts/config --file "${OUT_DIR}/.config" -e BBG

    # 2. KernelSU configurations
    if [ "$ENABLE_KSU" -eq 1 ]; then
        echo "[*] Injecting KernelSU & SUSFS configurations..."
        scripts/config --file "${OUT_DIR}/.config" \
            -e KSU \
            -e THREAD_INFO_IN_TASK \
            -e KSU_SUSFS
    fi

    # 3. Droidspaces Non-GKI configurations
    configure_droidspaces_non_gki "${OUT_DIR}"

    # 4. MIUI configurations
    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Injecting MIUI specific configurations..."
        scripts/config --file "${OUT_DIR}/.config" \
            --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
            -e PERF_CRITICAL_RT_TASK \
            -e SF_BINDER \
            -e OVERLAY_FS \
            -e MIGT \
            -e MIGT_ENERGY_MODEL \
            -e MIHW \
            -e PACKAGE_RUNTIME_INFO \
            -e BINDER_OPT \
            -e KPERFEVENTS \
            -e PERF_HUMANTASK \
            -d LTO_CLANG \
            -e LTO_NONE \
            -d SHADOW_CALL_STACK \
            -e XIAOMI_MIUI \
            -d MI_MEMORY_SYSFS \
            -e TASK_DELAY_ACCT \
            -e MIUI_ZRAM_MEMORY_TRACKING \
            -e PERF_HELPER \
            -e BOOTUP_RECLAIM \
            -e MI_RECLAIM \
            -e RTMM \
            -e MILLET_CGROUP \
            -e MILLET_SIG \
            -e MILLET_BINDER \
            -e MILLET_PKG \
            -e MILLET_BINDER_GKI \
            -e MILLET_CORE \
            -e MILLET_HS \
            -e BINDER_PRIO \
            -d REKERNEL \
            -d REKERNEL_NETWORK
    fi

    # 5. AOSP configurations
    if [ "$OS_TYPE" == "aosp" ]; then
        echo "[*] Injecting AOSP specific configurations..."
        scripts/config --file "${OUT_DIR}/.config" \
            -e REKERNEL \
            -e REKERNEL_NETWORK
    fi

    echo "[*] Updating config (make olddefconfig)..."
    make "${MAKE_OPTS[@]}" olddefconfig

    echo "[*] Building kernel..."
    make "${MAKE_OPTS[@]}" 

    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Restoring DTS backups..."
        rm -rf "${DTS_SOURCE}"
        mv "${DTS_BACKUP}" "${DTS_SOURCE}"
    fi

    echo "==========================================="
    if [ -f "${OUT_DIR}/arch/arm64/boot/Image" ]; then
        echo "[+] $OS_TYPE Build Successful!"
        echo "[+] Kernel Image path: ${OUT_DIR}/arch/arm64/boot/Image"

        echo "[*] Packaging to AnyKernel3 ($OS_TYPE)..."
        rm -rf anykernel/kernels/*
        mkdir -p "anykernel/kernels/${OS_TYPE}/"
        
        cp "${OUT_DIR}/arch/arm64/boot/Image" "anykernel/kernels/${OS_TYPE}/"
        cp "${OUT_DIR}/arch/arm64/boot/dtb" "anykernel/kernels/${OS_TYPE}/"
        
        if [ -f "${OUT_DIR}/arch/arm64/boot/dtbo.img" ]; then
            cp "${OUT_DIR}/arch/arm64/boot/dtbo.img" "anykernel/kernels/${OS_TYPE}/"
        fi
        
        local KSU_ZIP_STR="NoKernelSU"
        if [ "$ENABLE_KSU" -eq 1 ]; then
            KSU_ZIP_STR="ReSukiSU-SuSFS"
        fi
        local GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD 2>/dev/null || echo "unknown")
        local OS_UPPER=$(echo "$OS_TYPE" | tr '[:lower:]' '[:upper:]')
        local ZIP_FILENAME="APTKernel_${OS_UPPER}_${DEVICE_NAME}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip"
        
        echo "[*] Zipping $ZIP_FILENAME ..."
        pushd anykernel > /dev/null
        zip -r9 "$ZIP_FILENAME" ./* -x .git .gitignore out/ ./*.zip > /dev/null
        mv "$ZIP_FILENAME" ../
        popd > /dev/null
        
        echo "[+] $OS_TYPE kernel binaries successfully packed into: $ZIP_FILENAME"
    else
        echo "[-] $OS_TYPE Build Failed. Kernel Image not found."
        exit 1
    fi
}

# ==========================================
# Execute builds based on target OS
# ==========================================
if [ "$TARGET_OS" == "aosp" ] || [ "$TARGET_OS" == "both" ]; then
    build_target "aosp"
fi

if [ "$TARGET_OS" == "miui" ] || [ "$TARGET_OS" == "both" ]; then
    build_target "miui"
fi

echo "==========================================="
echo "[*] ccache stats:"
ccache -s
echo "[+] All requested builds completed!"
