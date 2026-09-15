#!/usr/bin/env python3
"""Exercise the camera-config gate's failure modes with synthetic build trees."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("verify-camera-config.py")
spec = importlib.util.spec_from_file_location("verify_camera_config", SCRIPT)
camera = importlib.util.module_from_spec(spec)
spec.loader.exec_module(camera)

MINIMAL_DTS = """
/dts-v1/;
/ {
	#address-cells = <2>;
	#size-cells = <2>;
	soc@0 {
		#address-cells = <2>;
		#size-cells = <2>;
		isp@acb7000 {
			compatible = "qcom,sm8550-camss";
			status = "okay";
		};
		cci@ac15000 {
			compatible = "qcom,sm8550-cci";
			status = "okay";
			camera@21 {
				compatible = "hynix,hi1337-gts9-rear";
			};
		};
		cci@ac16000 {
			compatible = "qcom,sm8550-cci";
			status = "okay";
			camera@20 {
				compatible = "hynix,hi1337-gts9-front";
			};
		};
	};
};
"""


@unittest.skipUnless(shutil.which("dtc"), "needs dtc")
class CameraConfigChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.out = Path(self.tmp.name)
        (self.out / "modules-out").mkdir()
        (self.out / "arch/arm64/boot/dts/qcom").mkdir(parents=True)
        self.config_lines = [f"{s}=m" for s in camera.CONFIG_SYMBOLS]
        for stem in camera.MODULE_STEMS:
            (self.out / "modules-out" / f"{stem}.ko").write_bytes(b"")
        self.write_dtb(MINIMAL_DTS)

    def write_config(self):
        (self.out / ".config").write_text("\n".join(self.config_lines) + "\n")

    def write_dtb(self, dts_text, disable=None):
        if disable:
            dts_text = dts_text.replace(
                f"{disable}\";\n\t\t\tstatus = \"okay\"",
                f"{disable}\";\n\t\t\tstatus = \"disabled\"")
        dts_path = self.out / "board.dts"
        dts_path.write_text(dts_text)
        subprocess.run(["dtc", "-O", "dtb", "-o", str(self.out / "arch/arm64/boot/dts/qcom" / camera.BOARD_DTB),
                        str(dts_path)], check=True, capture_output=True)

    def run_check(self):
        return subprocess.run([sys.executable, str(SCRIPT), "--kernel-out", str(self.out)],
                              capture_output=True, text=True)

    def test_complete_build_passes(self):
        self.write_config()
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_config_symbol_rejected(self):
        self.config_lines = [f"{camera.CONFIG_SYMBOLS[0]}=m"]
        self.write_config()
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(camera.CONFIG_SYMBOLS[1], result.stderr)

    def test_module_not_set_rejected(self):
        self.config_lines = [f"# {camera.CONFIG_SYMBOLS[0]} is not set",
                             f"{camera.CONFIG_SYMBOLS[1]}=m"]
        self.write_config()
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)

    def test_missing_module_rejected(self):
        self.write_config()
        (self.out / "modules-out" / f"{camera.MODULE_STEMS[0]}.ko").unlink()
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(camera.MODULE_STEMS[0], result.stderr)

    def test_zst_compressed_module_accepted(self):
        self.write_config()
        stem = camera.MODULE_STEMS[0]
        (self.out / "modules-out" / f"{stem}.ko").unlink()
        (self.out / "modules-out" / f"{stem}.ko.zst").write_bytes(b"")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_disabled_camss_rejected(self):
        self.write_config()
        self.write_dtb(MINIMAL_DTS, disable="qcom,sm8550-camss")
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("isp@acb7000", result.stderr)

    def test_missing_sensor_node_rejected(self):
        self.write_config()
        self.write_dtb(MINIMAL_DTS.replace('camera@21 {\n\t\t\t\tcompatible = "hynix,hi1337-gts9-rear";\n\t\t\t};\n', ""))
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
