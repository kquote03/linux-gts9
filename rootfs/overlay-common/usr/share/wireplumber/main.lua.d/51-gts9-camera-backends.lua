-- Camera bring-up session. Adapted from ubuntu-galaxy-tab-s9ultra's own
-- 51-gts9u-camera-backends.lua, trimmed to this device's two cameras.
--
-- GNOME's Camera/Snapshot app consumes the native PipeWire/libcamera nodes
-- directly, while browsers and OBS consume the V4L2 relays (gts9-camera-
-- relays.service). Give both layers the same names so every application
-- presents the same camera list. WirePlumber must expose these nodes as
-- Video/Source for Snapshot to see them at all.
local gts9_cameras = {
  {
    name = "libcamera_input._base_soc_0_cci_ac15000_i2c-bus_1_camera_21",
    description = "X716B Rear",
  },
  {
    name = "libcamera_input._base_soc_0_cci_ac16000_i2c-bus_1_camera_20",
    description = "X716B Front",
  },
}

for _, camera in ipairs(gts9_cameras) do
  table.insert(libcamera_monitor.rules, {
    matches = {
      {
        { "node.name", "equals", camera.name },
      },
    },
    apply_properties = {
      ["media.class"] = "Video/Source",
      ["node.description"] = camera.description,
    },
  })
end
