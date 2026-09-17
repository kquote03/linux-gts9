#!/usr/bin/env python3
"""Compile the real SPA control enumerator with fake controls, without hardware."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile


def extract_function(text):
    match = re.search(r"\bint\s+spa_libcamera_enum_controls\s*\(", text)
    if not match:
        raise ValueError("unsupported source: control enumerator not found")
    opening = text.index("{", match.end())
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    function = text[match.start():end]
    if not re.search(r"uint32_t\s+offset", function):
        raise ValueError("missing upstream PropInfo pagination offset fix")
    if not re.search(r"skip\s*&&\s*it\s*!=\s*info.end\(\)", function):
        raise ValueError("missing upstream control iterator bound fix")
    return function


STUBS = r'''
#include <cassert>
#include <cinttypes>
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>
#define spa_auto(t) t
#define spa_log_debug(...) ((void)0)
constexpr int SPA_PARAM_PropInfo = 1, SPA_RESULT_TYPE_NODE_PARAMS = 1;
struct spa_pod { bool reject = false; };
struct spa_pod_builder {};
struct spa_pod_dynamic_builder { spa_pod_builder b; };
struct spa_pod_builder_state {};
struct spa_result_node_params {
 uint32_t id = 0, index = 0, next = 0; const spa_pod *param = nullptr;
};
struct ControlId {
 std::string vendor() const { return "fake"; }
 std::string name() const { return "control"; }
};
struct ControlInfo { bool supported; };
using ControlInfoMap = std::map<const ControlId *, ControlInfo>;
struct Camera { ControlInfoMap info; const auto &controls() const { return info; } };
struct impl { Camera *camera; void *log = nullptr; int hooks = 0; };
struct port {};
std::vector<spa_result_node_params> results;
void spa_pod_dynamic_builder_init(spa_pod_dynamic_builder *, void *, size_t, size_t) {}
void spa_pod_builder_get_state(spa_pod_builder *, spa_pod_builder_state *) {}
void spa_pod_builder_reset(spa_pod_builder *, spa_pod_builder_state *) {}
const spa_pod *control_details_to_pod(spa_pod_builder &, const ControlId &, const ControlInfo &info) {
 static spa_pod pod; return info.supported ? &pod : nullptr;
}
int spa_pod_filter(spa_pod_builder *, const spa_pod **out, const spa_pod *pod, const spa_pod *filter) {
 if (filter && filter->reject) return -1; *out = pod; return 0;
}
void spa_node_emit_result(int *, int, int, int, const spa_result_node_params *result) {
 results.push_back(*result);
}
'''

TESTS = r'''
int main() {
 Camera camera; impl node{&camera}; port output;
 ControlId ids[5];
 for (int i = 0; i < 5; ++i) camera.info[&ids[i]] = {i != 1 && i != 3};
 for (uint32_t offset : {0u, 2u}) {
  uint32_t start = offset, emitted = 0;
  for (int calls = 0; calls < 10; ++calls) {
   results.clear();
   assert(spa_libcamera_enum_controls(&node, &output, 0, start, offset, 1, nullptr) == 0);
   if (results.empty()) break;
   assert(results.size() == 1);
   assert(results[0].index >= start && results[0].next > start);
   assert(results[0].next == results[0].index + 1);
   start = results[0].next; ++emitted;
  }
  assert(emitted == 3 && start == offset + 5);
  for (uint32_t beyond : {offset + 5, offset + 6, UINT32_MAX}) {
   results.clear();
   assert(spa_libcamera_enum_controls(&node, &output, 0, beyond, offset, 1, nullptr) == 0);
   assert(results.empty());
  }
  spa_pod rejecting{true}; results.clear();
  assert(spa_libcamera_enum_controls(&node, &output, 0, offset, offset, 100, &rejecting) == 0);
  assert(results.empty());
  results.clear();
  assert(spa_libcamera_enum_controls(&node, &output, 0, offset, offset, 100, nullptr) == 0);
  assert(results.size() == 3);
 }
 camera.info.clear(); results.clear();
 assert(spa_libcamera_enum_controls(&node, &output, 0, 2, 2, 1, nullptr) == 0);
 assert(results.empty());
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_dir", type=Path)
    args = parser.parse_args()
    plugin_dir = args.source_dir / "spa/plugins/libcamera"
    source = (plugin_dir / "libcamera-source.cpp").read_text()
    utils = plugin_dir / "libcamera-utils.cpp"
    combined = source + (utils.read_text() if utils.exists() else "")
    function = extract_function(combined)
    # Validate call sites too: the helper alone cannot fix a node-local offset.
    calls = re.findall(r"return\s+spa_libcamera_enum_controls\s*\((.*?)\);", source, re.S)
    calls = [re.sub(r"GET_OUT_PORT\([^)]*\)", "output_port", call) for call in calls]
    if len(calls) != 2 or any(len(call.split(",")) != 7 for call in calls):
        raise ValueError("unsupported source: expected node/port calls with explicit offset")
    # Current releases expose controls directly at node index 0. Older trees
    # insert device/deviceName first and must use offset 2 for the node call.
    expected_offset = "2" if "SPA_PROP_deviceName" in source else "0"
    if calls[0].split(",")[-3].strip() != expected_offset or calls[1].split(",")[-3].strip() != "0":
        raise ValueError("incorrect node/port PropInfo offsets")
    with tempfile.TemporaryDirectory(prefix="gts9-spa-pagination-") as directory:
        test = Path(directory) / "test.cpp"
        binary = Path(directory) / "test"
        test.write_text(STUBS + function + TESTS)
        subprocess.run(["c++", "-std=c++20", "-O0", "-g", "-D_GLIBCXX_ASSERTIONS",
                        str(test), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=10)
    print("SPA control pagination: actual source regression passed")


if __name__ == "__main__":
    main()
