#!/usr/bin/env python3
"""Report proven fields from Samsung HI1337 Parameter Parser V3.5.1 blobs.

Offline only; never accesses a device. This is a deliberately narrow decoder,
not a generic Chromatix parser. Unknown versions/layouts fail closed. Scalar
slaveInfo order follows chi-cdk/api/sensor/camxsensordriver.xsd:
https://github.com/comprehensive9/vendor_qcom_proprietary/blob/master/chi-cdk/api/sensor/camxsensordriver.xsd
The V3 section/node envelope and Samsung optional-field prefix were verified
against this device's three CRC-valid descriptors. Power configuration enums
remain raw. Resolution records and simple writes use the verified Samsung layout.
"""

import argparse
import hashlib
import json
import re
from pathlib import Path
import struct
import sys
import zlib


MAX_SIZE = 16 * 1024 * 1024


def decode(path, compare_tables=None):
    if path.stat().st_size > MAX_SIZE:
        raise ValueError("descriptor exceeds 16 MiB limit")
    blob = path.read_bytes()
    if len(blob) < 384 or not blob.startswith(b"QTI Chromatix Header"):
        raise ValueError("not a Chromatix descriptor")
    if struct.unpack_from("<I", blob, 28)[0] != len(blob) - 4:
        raise ValueError("declared descriptor length mismatch")
    if zlib.crc32(blob[:-4]) != struct.unpack_from("<I", blob, len(blob) - 4)[0]:
        raise ValueError("descriptor CRC32 mismatch")
    version = blob[40:88].split(b"\0", 1)[0].decode("ascii")
    if version != "Parameter Parser V3.5.1 (2207122229)":
        raise ValueError("unsupported parser version")
    if struct.unpack_from("<II", blob, 160) != (168, 3):
        raise ValueError("unsupported section directory")
    sections = []
    for index in range(3):
        kind, offset, size = struct.unpack_from("<III", blob, 168 + 12 * index)
        if kind != index or offset < 204 or offset + size > len(blob) - 4:
            raise ValueError("invalid section bounds or order")
        sections.append((offset, size))
    schema_offset, schema_size = sections[0]
    data_offset, data_size = sections[1]
    if schema_offset != 204 or schema_size % 60:
        raise ValueError("unsupported node table layout")
    nodes = []
    node_ids = {}
    for offset in range(schema_offset, schema_offset + schema_size, 60):
        row = blob[offset:offset + 60]
        node_id = struct.unpack_from("<I", row)[0]
        name = row[4:36].split(b"\0", 1)[0].decode("ascii")
        relative, size, reference = struct.unpack_from("<III", row, 48)
        if relative + size > data_size:
            raise ValueError("node payload exceeds data section")
        nodes.append((name, reference, relative, blob[data_offset + relative:data_offset + relative + size]))
        if node_id in node_ids:
            raise ValueError("duplicate node ID")
        node_ids[node_id] = (name, nodes[-1][3])

    def resolve(node_id, expected_name):
        node = node_ids.get(node_id)
        if node is None or node[0] != expected_name:
            raise ValueError(f"invalid {expected_name} node reference {node_id}")
        return node[1]

    def registers(node_id):
        data = resolve(node_id, "regSetting")
        if not data or len(data) % 40:
            raise ValueError("unsupported register setting layout")
        result = []
        for row in struct.iter_unpack("<10I", data):
            if row[0] != 0 or row[3] != 1 or row[5:8] != (2, 2, 0) or row[8] not in (0, 1):
                raise ValueError("unsupported register operation or width")
            value = resolve(row[4], "registerData")
            delay = resolve(row[9], "delayUs")
            if len(value) != 4 or len(delay) not in (0, 4):
                raise ValueError("invalid register data or delay payload")
            result.append({"address": row[2], "value": struct.unpack("<I", value)[0],
                           "delay_us": struct.unpack("<I", delay)[0] if delay else 0})
        return result

    def comparison(settings):
        if compare_tables is None:
            return None
        pairs = [(setting["address"], setting["value"]) for setting in settings]
        matches = []
        for table, body in re.findall(r"static const struct hi1337_reg (\w+)\[\] = \{(.*?)\n\};", compare_tables.read_text(), re.S):
            expected = [tuple(int(value, 16) for value in pair)
                        for pair in re.findall(r"\{\s*(0x[0-9a-f]+),\s*(0x[0-9a-f]+)\s*\}", body)]
            if pairs == expected:
                matches.append(table)
        return {"header": str(compare_tables), "exact_register_sequence_matches": matches,
                "all_delays_zero": all(setting["delay_us"] == 0 for setting in settings)}
    name, _, _, payload = nodes[0]
    if name != "sensorDriverData" or len(payload) != 752:
        raise ValueError("unsupported Samsung sensor root layout")
    # Four references precede scalar slaveInfo (name and three optional fields).
    references = struct.unpack_from("<4I", payload, 16)[::2]
    if resolve(references[0], "sensorName") != b"hi1337\0":
        raise ValueError("unsupported sensor name/reference")
    address, addr_type, data_type, id_reg, sensor_id, mask, frequency = struct.unpack_from("<7I", payload, 44)
    if address > 0xFE or address & 1 or (addr_type, data_type) != (2, 2):
        raise ValueError("unsupported slave address or register width")
    if (id_reg, sensor_id, mask) != (0x0714, 0x2000, 0xFFFFFFFF):
        raise ValueError("unsupported HI1337 identity layout")
    power = []
    modes = []
    for name, reference, relative, data in nodes:
        if name == "powerSetting" and data:
            if len(data) % 12:
                raise ValueError("invalid powerSetting payload")
            power.append({"reference": reference, "data_offset": data_offset + relative,
                          "settings": [{"config_type_raw": kind, "value": value, "delay_ms": delay}
                                       for kind, value, delay in struct.iter_unpack("<III", data)]})
        if name == "resolutionData" and data:
            if len(data) % 288:
                raise ValueError("unsupported Samsung resolution record layout")
            for index in range(len(data) // 288):
                row = struct.unpack_from("<72I", data, index * 288)
                streams = resolve(row[8], "streamConfiguration")
                if row[7] not in (1, 2) or len(streams) != row[7] * 60 or row[22] != 4 or row[26] not in (0, 1):
                    raise ValueError("unsupported stream, lane or PHY configuration")
                configurations = []
                for stream in struct.iter_unpack("<15I", streams):
                    vc = resolve(stream[1], "vc")
                    if stream[0] != 1 or len(vc) != 4:
                        raise ValueError("unsupported virtual channel layout")
                    configurations.append({"virtual_channel": struct.unpack("<I", vc)[0],
                                           "data_type": stream[2], "width": stream[5],
                                           "height": stream[6], "bit_width": stream[7]})
                settings = registers(row[30])
                modes.append({"index": index, "data_offset": data_offset + relative + index * 288,
                              "streams": configurations, "line_length_pixel_clock": row[11],
                              "frame_length_lines": row[12], "output_pixel_clock": row[15],
                              "frame_rate": struct.unpack_from("<d", data, index * 288 + 72)[0],
                              "lane_count": row[22], "settle_time_ns": row[25], "is_3_phase": row[26],
                              "phy_mode": "C-PHY" if row[26] else "D-PHY",
                              "register_settings": settings, "table_comparison": comparison(settings)})
    init_arrays = []
    for name, _, _, data in nodes:
        if name == "initSettings" and data:
            if len(data) != 12:
                raise ValueError("unsupported initSettings layout")
            settings = registers(struct.unpack_from("<I", data, 8)[0])
            init_arrays.append({"register_settings": settings, "table_comparison": comparison(settings)})
    return {"file": str(path), "size": len(blob), "sha256": hashlib.sha256(blob).hexdigest(),
            "crc32_verified": True, "parser": version, "sensor_name": "hi1337",
            "slave_info_offset": data_offset + 44,
            "slave_info": {"write_address_8bit": address, "linux_address_7bit": address >> 1,
                           "register_address_bytes": addr_type, "register_data_bytes": data_type,
                           "sensor_id_register": id_reg, "sensor_id": sensor_id,
                           "sensor_id_mask": mask, "frequency_enum_raw": frequency},
            "power_arrays": power, "resolution_modes": modes, "init_arrays": init_arrays,
            "phy_mode": "D-PHY" if modes and all(mode["is_3_phase"] == 0 for mode in modes) else "mixed or unknown"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("descriptors", type=Path, nargs="+")
    parser.add_argument("--compare-tables", type=Path, help="compare decoded writes with a hi1337 table header")
    args = parser.parse_args()
    try:
        reports = [decode(path, args.compare_tables) for path in args.descriptors]
    except (OSError, ValueError, struct.error, UnicodeError) as error:
        print(f"camera descriptor: {error}", file=sys.stderr)
        return 1
    print(json.dumps(reports, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
