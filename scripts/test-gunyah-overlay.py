#!/usr/bin/env python3
"""Compile the real RM filter against libfdt and exercise malformed overlays."""
from pathlib import Path
import subprocess
import tempfile
import os

root = Path(__file__).resolve().parents[1]
source = root / 'kernel/linux/drivers/virt/gunyah/qcom_bootinfo.c'
s = source.read_text()
fn = s[s.index('static int qcom_hyp_keep_rm_fragment'):s.index('static int qcom_hyp_apply_dtbo')]
harness = r'''
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <libfdt.h>
#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
#define cpu_to_fdt32(x) cpu_to_fdt32(x)
struct device_node { uint32_t phandle; };
static struct device_node gic = { 123 };
static struct device_node *of_find_compatible_node(void *a, void *b, const char *c)
{ (void)a; (void)b; (void)c; return &gic; }
static void of_node_put(struct device_node *p) { (void)p; }
'''.replace('#define cpu_to_fdt32(x) cpu_to_fdt32(x)\n','') + fn + r'''
#define ASSERT(x) do { if (!(x)) { fprintf(stderr,"failed line %d\n",__LINE__); return 1; } } while (0)
static int build(void *fdt, const char *target, int cells, int extra) {
 int f, o, h, rm;
 fdt_create_empty_tree(fdt, 4096);
 f=fdt_add_subnode(fdt, 0, "fragment@0");
 fdt_setprop_string(fdt,f,"target-path",target);
 o=fdt_add_subnode(fdt,f,"__overlay__");
 h=fdt_add_subnode(fdt,o,"hypervisor");
 rm=fdt_add_subnode(fdt,h,"resource-manager");
 fdt_setprop_string(fdt,rm,"compatible","qcom,resource-manager-1-0");
 fdt32_t irq[6]={cpu_to_fdt32(0),cpu_to_fdt32(17),cpu_to_fdt32(1),cpu_to_fdt32(0),cpu_to_fdt32(18),cpu_to_fdt32(1)};
 fdt_setprop(fdt,rm,"interrupts",irq,cells*4);
 if (extra) fdt_add_subnode(fdt,0,"fragment@9");
 return 0;
}
int main(void) {
 char fdt[4096]; int n, len; const fdt32_t *p;
 build(fdt,"/",6,0); ASSERT(!qcom_hyp_keep_rm_fragment(fdt));
 n=fdt_path_offset(fdt,"/fragment@0/__overlay__/hypervisor/resource-manager");
 p=fdt_getprop(fdt,n,"interrupts",&len); ASSERT(p && len==32);
 ASSERT(fdt32_to_cpu(p[1])==17 && fdt32_to_cpu(p[3])==0 && fdt32_to_cpu(p[5])==18 && fdt32_to_cpu(p[7])==0);
 p=fdt_getprop(fdt,n,"interrupt-parent",&len); ASSERT(p && fdt32_to_cpu(*p)==123);
 build(fdt,"/reserved-memory",6,0); ASSERT(qcom_hyp_keep_rm_fragment(fdt)<0);
 build(fdt,"/",5,0); ASSERT(qcom_hyp_keep_rm_fragment(fdt)<0);
 build(fdt,"/",6,1); ASSERT(qcom_hyp_keep_rm_fragment(fdt)<0);
 build(fdt,"/",6,0); gic.phandle=0; ASSERT(qcom_hyp_keep_rm_fragment(fdt)<0);
 puts("PASS actual Gunyah RM overlay filter"); return 0;
}
'''
with tempfile.TemporaryDirectory() as tmp:
    p = Path(tmp)
    (p/'test.c').write_text(harness)
    lib = root/'kernel/linux/scripts/dtc/libfdt'
    subprocess.run([os.environ.get('HOSTCC','cc'), '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                    '-I'+str(lib), str(p/'test.c'), *map(str, lib.glob('*.c')), '-o', str(p/'test')], check=True)
    subprocess.run([str(p/'test')], check=True)
