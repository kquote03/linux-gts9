#!/usr/bin/env python3
"""Compile the actual patched ath11k callbacks against a mock WMI transport.

Usage: test-ath11k-wmm-quirk.py [path/to/ath11k/mac.c]
Run after build-mainline-kernel.sh applies the patches. No device required.
"""
import os
import re
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parent.parent
source = Path(sys.argv[1]) if len(sys.argv) > 1 else repo / "kernel/linux/drivers/net/wireless/ath/ath11k/mac.c"
text = source.read_text()


def function(name):
    # These callbacks use an unindented closing brace only at function end.
    start = re.search(r"^static \w+ " + re.escape(name) + r"\(", text, re.M).start()
    end = text.index("\n}", text.index(name + "(", start)) + 2
    return text[start:end]


prefix = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
typedef uint16_t u16;
#define GENMASK(h, l) (((1U << ((h) + 1)) - 1) & ~((1U << (l)) - 1))
#define u8_get_bits(v, m) (((v) & (m)) >> __builtin_ctz(m))
#define WARN_ON(v) (v)
#define mutex_lock(p) ((void)(p))
#define mutex_unlock(p) ((void)(p))
#define ath11k_warn(...) ((void)0)
enum { IEEE80211_AC_VO, IEEE80211_AC_VI, IEEE80211_AC_BE, IEEE80211_AC_BK };
enum { WMI_WMM_PARAM_TYPE_LEGACY, WMI_WMM_PARAM_TYPE_11AX_MU_EDCA };
struct wmi_wmm_params_arg { unsigned cwmin, cwmax, aifs, txop; };
struct wmi_wmm_params_all_arg { struct wmi_wmm_params_arg ac_be, ac_bk, ac_vi, ac_vo; };
struct ath11k_vif { unsigned vdev_id; bool is_started;
    struct wmi_wmm_params_all_arg wmm_params, muedca_params; };
struct ath11k_base { struct { struct { char fw_build_id[128]; } target; } qmi; };
struct ath11k { struct ath11k_base *ab; int conf_mutex; };
struct ieee80211_hw { struct ath11k *priv; };
struct ieee80211_vif { struct ath11k_vif arvif; };
#define ath11k_vif_to_arvif(vif) (&(vif)->arvif)
struct ieee80211_tx_queue_params { unsigned cw_min, cw_max, aifs, txop;
    bool mu_edca, uapsd;
    struct { unsigned ecw_min_max, aifsn, mu_edca_timer; } mu_edca_param_rec; };
static int ath11k_skip_legacy_wmm_params = -1;
static unsigned sends[2], uapsd_calls;
static int send_error;
static int ath11k_wmi_send_wmm_update_cmd_tlv(struct ath11k *ar, unsigned id,
        struct wmi_wmm_params_all_arg *params, unsigned type)
{
    (void)ar; (void)params; assert(id == 7); assert(type < 2);
    sends[type]++; return send_error;
}
static int ath11k_conf_tx_uapsd(struct ath11k *ar, struct ieee80211_vif *vif,
        u16 ac, bool enabled)
{
    (void)ar; (void)vif; (void)ac; (void)enabled; uapsd_calls++; return 0;
}
'''
main = r'''
int main(void)
{
    struct ath11k_base ab = {0};
    struct ath11k ar = { .ab = &ab };
    struct ieee80211_hw hw = { .priv = &ar };
    struct ieee80211_vif vif = { .arvif = { .vdev_id = 7, .is_started = true } };
    struct ieee80211_tx_queue_params p = { .cw_min = 3, .cw_max = 7,
        .aifs = 2, .txop = 47, .mu_edca = true, .uapsd = true,
        .mu_edca_param_rec = { .ecw_min_max = 0x32, .aifsn = 2, .mu_edca_timer = 255 } };
    const char *builds[] = { "WLAN.HSP.2.0.c11-00358-test", "WLAN.HSP.1.1-04523-test", "" };
    for (unsigned fw = 0; fw < 3; fw++) {
        strcpy(ab.qmi.target.fw_build_id, builds[fw]);
        for (int mode = -1; mode <= 1; mode++) {
            ath11k_skip_legacy_wmm_params = mode;
            bool skip = mode == 1 || (mode == -1 && fw == 0);
            memset(sends, 0, sizeof(sends)); uapsd_calls = 0;
            for (u16 ac = 0; ac < 4; ac++)
                assert(ath11k_mac_op_conf_tx(&hw, &vif, 0, ac, &p) == 0);
            assert(sends[0] == (skip ? 0 : 4));
            assert(sends[1] == (skip ? 0 : 4));
            assert(uapsd_calls == 4);
            assert(vif.arvif.muedca_params.ac_vo.cwmin == 2);
            assert(vif.arvif.muedca_params.ac_vo.cwmax == 3);
            assert(vif.arvif.muedca_params.ac_vo.txop == 255);
            assert(vif.arvif.wmm_params.ac_vo.txop == 47);
        }
    }
    /* Legacy-only APs do not gain MU sends; pre-start callbacks stay deferred. */
    ath11k_skip_legacy_wmm_params = 0;
    p.mu_edca = false; memset(sends, 0, sizeof(sends));
    assert(ath11k_mac_op_conf_tx(&hw, &vif, 0, 0, &p) == 0);
    assert(sends[0] == 1 && sends[1] == 0);
    vif.arvif.is_started = false; p.mu_edca = true;
    memset(sends, 0, sizeof(sends)); uapsd_calls = 0;
    assert(ath11k_mac_op_conf_tx(&hw, &vif, 0, 0, &p) == 0);
    assert(sends[0] == 0 && sends[1] == 0 && uapsd_calls == 0);
    /* Unaffected firmware still reports transport errors and invalid ACs. */
    send_error = -EIO;
    assert(ath11k_mac_op_conf_tx_mu_edca(&hw, &vif, 0, 0, &p) == -EIO);
    assert(ath11k_mac_op_conf_tx_mu_edca(&hw, &vif, 0, 99, &p) == -EINVAL);
    puts("PASS: firmware selection, overrides, all ACs, U-APSD, cache, deferral and errors");
    return 0;
}
'''
callbacks = "\n".join(function(name) for name in (
    "ath11k_mac_skip_legacy_wmm_params", "ath11k_mac_op_conf_tx_mu_edca", "ath11k_mac_op_conf_tx"))
with tempfile.TemporaryDirectory(prefix="ath11k-wmm-test-") as tmp:
    c = Path(tmp) / "test.c"
    binary = Path(tmp) / "test"
    c.write_text(prefix + callbacks + main)
    subprocess.run([*shlex.split(os.environ.get("HOSTCC", "cc")), "-std=c11", "-Wall", "-Wextra",
                    "-Werror", "-Wno-unused-parameter", str(c), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
