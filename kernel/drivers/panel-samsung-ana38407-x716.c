// SPDX-License-Identifier: GPL-2.0-only
/*
 * DRM panel driver for the Samsung AMSA10FA01 (Anapass ANA38407 DDIC) as
 * fitted to the Galaxy Tab S9 5G (SM-X716B, "gts9-5g").
 *
 * 2560x1600 command-mode DSI panel, 4 lanes, DSC 1.1 (2 slices 1280x100,
 * 8bpp). Forked from ubuntu-galaxy-tab-s9ultra's panel-samsung-ana38407.c
 * (same ANA38407 DDIC family, different physical part AMSA46AS02 on the
 * sibling SM-X910 Ultra tablet) -- structure, power sequencing and the
 * "cold boot answers garbage, needs one suspend/resume" quirk are all
 * carried over from that proven driver. The actual DCS init/exit byte
 * sequences below are NOT carried over, though: they were re-derived
 * specifically for THIS panel part from Samsung's own downstream source
 * (android_kernel_samsung_gts9/.../display-drivers/msm/samsung/
 * GTS9_ANA38407_AMSA10FA01/ and .../panel_data_file/GTS9_ANA38407_AMSA10FA01.dat
 * -- see docs/porting-log.md's Session 5 entry for the extraction and
 * exact source citations). Only the mass-production revision path
 * (Samsung calls it "rev C-Z") is implemented -- the downstream source
 * also has a separate rev-A-only path (different sleep-out delay, an
 * extra TSP_SYNC_ON macro instead of TSP_SYNC_SETTING) that real
 * hardware is unlikely to still be running and isn't implemented here.
 *
 * Deliberately NOT ported from the downstream source: Samsung's
 * optical-fingerprint HBM timing machinery (panel_hbm_entry/exit_delay,
 * finger-mask-aware dimming bytes 0x20/0xE0 vs 0x28/0xE8). The downstream
 * DTS node does carry samsung,support-optical-fingerprint and real
 * vsync-relative HBM timing code for it, which at first reads like this
 * panel needs the reference driver's FOD machinery too -- but the Tab S9
 * series ships a side-mounted capacitive fingerprint sensor on the power
 * button (a separate SPI device, see kernel/dts/sm8550-samsung-x716b.dts's
 * gpio-reserved-ranges comment), not an in-display optical one, so this
 * flag is almost certainly inert boilerplate inherited from a phone panel
 * definition with no HAL ever driving it. If real hardware ever needs it
 * revisited, the plain (non-finger-mask) dimming path below is what's
 * implemented either way.
 *
 * Also not ported: Samsung's VRR/SLEW_BOOSTING/ACL/mdnie machinery (same
 * reasoning as the reference driver -- only one fixed mode is exposed
 * here, so there's no runtime VRR switching to matter), and the
 * "HBM_FlatZ_SETTING" indirect register write the downstream .dat
 * applies unconditionally for rev B-Z inside its brightness-dimming
 * macro (byte-identical to the reference driver's own FOD-path write,
 * confusingly -- its real purpose on THIS panel is unclear from the
 * source alone, so it's left out rather than guessed at; see
 * docs/porting-log.md if the panel lights up with visibly wrong gamma).
 */

#include <linux/backlight.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/regulator/consumer.h>

#include <drm/display/drm_dsc.h>
#include <drm/display/drm_dsc_helper.h>
#include <drm/drm_mipi_dsi.h>
#include <drm/drm_modes.h>
#include <drm/drm_panel.h>

/*
 * DCS 0x51 carries 11 significant bits on this DDIC (WRDISBV 0-2047), not
 * 12 or 8: confirmed from the downstream candela-map tables (normal range
 * tops out at WRDISBV 2047 = 420 cd/m2, HBM range also tops at 2047 but a
 * different luminance table, up to 600 cd/m2) -- same bit width as the
 * sibling AMSA46AS02 panel, just independently re-confirmed here rather
 * than assumed.
 */
#define ANA38407_X716_MAX_BRIGHTNESS	0x07ff

/*
 * Expected manufacture-ID bytes (0xDA/0xDB/0xDC), byte 0 fixed at 0x80 for
 * this DDIC vendor/family; bytes 1-2 vary by fab/revision and the
 * downstream driver treats either of these two as a normal, valid part
 * (GTS9_ANA38407_AMSA10FA01_panel.c:196-197). Logged as a warning (not a
 * hard failure) if neither matches, same reasoning as the sibling driver:
 * on a cold boot this DDIC family is known to answer 00:00:00 regardless,
 * recovering only after a suspend/resume -- so a mismatch here is
 * informative, not by itself proof of a wiring bug.
 */
static const u8 ana38407_x716_expected_ids[][3] = {
	{ 0x80, 0x00, 0x03 },
	{ 0x80, 0x00, 0x04 },
};

struct ana38407_x716 {
	struct drm_panel panel;
	struct mipi_dsi_device *dsi;
	struct drm_dsc_config dsc;
	struct regulator_bulk_data *supplies;
	struct gpio_desc *reset_gpio;
	struct mutex lock;
	u16 user_brightness;
	bool prepared;
	bool enabled;
	u8 id[3];
};

/*
 * Panel rails, all required (devm_regulator_bulk_get_const below fails
 * probe if any is missing from DT): vddio 1.8V, vdd 1.2V, vci 3.0V (all
 * measured from X716's own stock DTS dsi_panel_pwr_supply table -- see
 * kernel/dts/sm8550-samsung-x716b.dts's panel@0 node) and avdd, the
 * AMOLED ELVDD (~5.5V) behind a GPIO load switch.
 */
static const struct regulator_bulk_data ana38407_x716_supplies[] = {
	{ .supply = "vddio" },
	{ .supply = "vdd" },
	{ .supply = "vci" },
	{ .supply = "avdd" },
};

static inline struct ana38407_x716 *to_ana38407_x716(struct drm_panel *panel)
{
	return container_of(panel, struct ana38407_x716, panel);
}

/*
 * Sequenced rather than raised together, matching X716's own stock
 * dsi_panel_pwr_supply table exactly: vddio first, then a
 * qcom,supply-post-on-sleep of 0x14 = 20ms (same figure the sibling
 * AMSA46AS02 driver independently arrived at for its own panel's vddio),
 * before vdd/vci/avdd.
 */
static int ana38407_x716_power_on(struct ana38407_x716 *ctx)
{
	int ret;

	ret = regulator_enable(ctx->supplies[0].consumer);	/* vddio */
	if (ret)
		return ret;

	msleep(20);

	ret = regulator_bulk_enable(ARRAY_SIZE(ana38407_x716_supplies) - 1,
				    &ctx->supplies[1]);		/* vdd, vci, avdd */
	if (ret)
		regulator_disable(ctx->supplies[0].consumer);

	return ret;
}

/* Pack a signed DSC range BPG offset into the 6-bit field. */
#define DSC_BPG_OFFSET(x)	((u8)((x) & DSC_RANGE_BPG_OFFSET_MASK))

/*
 * qcom,mdss-dsi-reset-sequence <0 10 1 1> from X716's own stock DTS
 * (android_kernel_samsung_gts9/.../gts9_eur_openx_w00_r00.dts:8421):
 * drive low, hold 10ms; drive high, hold 1ms. Unlike the sibling driver's
 * three-phase toggle (which was never independently confirmed against
 * X716 itself), this is the literal, measured two-phase sequence for
 * this exact panel -- reproduce it as-is rather than adding phases.
 */
static void ana38407_x716_reset(struct ana38407_x716 *ctx)
{
	gpiod_set_value_cansleep(ctx->reset_gpio, 0);
	usleep_range(10000, 11000);
	gpiod_set_value_cansleep(ctx->reset_gpio, 1);
	usleep_range(1000, 1500);
}

/*
 * Power-on DCS sequence, transcribed from Samsung's downstream panel data
 * file (panel_data_file/GTS9_ANA38407_AMSA10FA01.dat), mass-production
 * ("rev C-Z") path only -- see this file's header. Level keys 0xF0/0xF1
 * 0x5A 0x5A unlock; 0xA5 0xA5 relock. The 0xC0/0xB0/0xC1 triples are this
 * DDIC's Anapass-TCON indirect register writes (0xC1 carries the data
 * byte, 0xC0's payload selects a 16-bit internal TCON register address to
 * write it to) -- a different indirect-access convention than the
 * Samsung-DDIC "gpara" triples (0xB0/0xC1) the sibling AMSA46AS02 uses,
 * confirmed by X716's own DT flag samsung,anapass-power-seq (stock DTS).
 */
static int ana38407_x716_on(struct ana38407_x716 *ctx)
{
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = ctx->dsi };
	struct drm_dsc_picture_parameter_set pps;
	u8 id[3] = {};
	bool id_ok = false;
	int i;

	ctx->dsi->mode_flags |= MIPI_DSI_MODE_LPM;

	/* sleep out (POWER_ON_PRE_SETTING, mass-production path: 50ms) */
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x11);
	mipi_dsi_msleep(&dsi_ctx, 50);

	/*
	 * Confirm the DDIC answers on the DSI link, under the level-1 key
	 * (samsung,manufacture_id{0,1,2}_rx_cmds_revA read 0xDA/0xDB/0xDC
	 * each under LEVEL1_KEY in the generic downstream code).
	 */
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf1, 0x5a, 0x5a);
	mipi_dsi_dcs_read(ctx->dsi, 0xda, &id[0], 1);
	mipi_dsi_dcs_read(ctx->dsi, 0xdb, &id[1], 1);
	mipi_dsi_dcs_read(ctx->dsi, 0xdc, &id[2], 1);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf1, 0xa5, 0xa5);
	memcpy(ctx->id, id, sizeof(ctx->id));
	dev_info(&ctx->dsi->dev, "ana38407 panel id: %02x %02x %02x\n",
		 id[0], id[1], id[2]);
	for (i = 0; i < ARRAY_SIZE(ana38407_x716_expected_ids); i++) {
		if (!memcmp(id, ana38407_x716_expected_ids[i], sizeof(id))) {
			id_ok = true;
			break;
		}
	}
	if (!id_ok)
		dev_warn(&ctx->dsi->dev,
			 "panel id %02x %02x %02x not in the expected list: the panel may stay dark until a suspend/resume re-initialises the DSI host\n",
			 id[0], id[1], id[2]);

	/* MX_IP_ENABLE */
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf1, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xc1, 0x23);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x03);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xc0, 0x0f, 0x00, 0x00, 0x00, 0x09, 0xb2, 0x81);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf1, 0xa5, 0xa5);

	/* TCON_INTR_SETTING (TE active low) */
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf1, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xc1, 0x02);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x03);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xc0, 0x0f, 0x00, 0x00, 0x00, 0x14, 0x46, 0x81);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xc1, 0x13);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x03);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xc0, 0x0f, 0x00, 0x00, 0x00, 0x08, 0xcf, 0x81);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xc1, 0x05);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x03);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xc0, 0x0f, 0x00, 0x00, 0x00, 0x09, 0xcd, 0x81);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf1, 0xa5, 0xa5);

	/* SSCG_OFF_SETTING (rev C+ baseline -- see file header) */
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf1, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xc1, 0x24);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x03);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xc0, 0x0f, 0x00, 0x00, 0x00, 0x03, 0x8a, 0x81);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf1, 0xa5, 0xa5);

	/* TE_ON */
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x35, 0x00);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);

	/* TSP_SYNC_SETTING (rev C-Z path) */
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x0b, 0xb9);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb9, 0xcc);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);

	/*
	 * DSC: enable compression and send the Picture Parameter Set as a
	 * proper MIPI PPS packet generated from drm_dsc_config -- X716's
	 * stock DTS sets samsung,no_qcom_pps (the DSI host's automatic PPS
	 * generation is disabled for this panel), meaning the panel driver
	 * itself must send compression-mode + PPS, exactly what this does.
	 */
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_compression_mode_multi(&dsi_ctx, true);
	drm_dsc_pps_payload_pack(&pps, &ctx->dsc);
	mipi_dsi_picture_parameter_set_multi(&dsi_ctx, &pps);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);

	/* DIA_SETTING (digital image adjust on) */
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x91, 0x02);

	/*
	 * BRIGHTNESS: dimming control (plain path, no finger-mask variant
	 * -- see file header) + an explicit non-zero 0x51 brightness.
	 * Without a real 0x51 write the DDIC emits black even with the
	 * display on (same finding as the sibling AMSA46AS02 driver).
	 */
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x53, 0x28);
	mipi_dsi_dcs_write_var_seq_multi(&dsi_ctx, 0x51,
					 ctx->user_brightness >> 8,
					 ctx->user_brightness & 0xff);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);

	/* SP_SETTING */
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xc3, 0x02);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);

	mipi_dsi_msleep(&dsi_ctx, 20);

	/*
	 * X716's stock DTS declares samsung,delayed-display-on: complete
	 * initialisation here, but keep the OLED dark until the bridge's
	 * enable phase (0x29 is sent from ana38407_x716_enable(), not
	 * here) -- same structure the sibling AMSA46AS02 driver already
	 * uses for the same reason (unsynchronised DSC data visible right
	 * after resume otherwise), now independently confirmed for this
	 * panel too rather than just assumed by analogy.
	 */

	return dsi_ctx.accum_err;
}

static int ana38407_x716_enable(struct drm_panel *panel)
{
	struct ana38407_x716 *ctx = to_ana38407_x716(panel);
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = ctx->dsi };
	int ret = 0;

	mutex_lock(&ctx->lock);
	if (!ctx->prepared) {
		ret = -EPIPE;
		goto out_unlock;
	}
	if (ctx->enabled)
		goto out_unlock;

	ctx->dsi->mode_flags |= MIPI_DSI_MODE_LPM;
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_set_display_on_multi(&dsi_ctx);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	ret = dsi_ctx.accum_err;
	if (!ret)
		ctx->enabled = true;

out_unlock:
	mutex_unlock(&ctx->lock);
	return ret;
}

static int ana38407_x716_disable(struct drm_panel *panel)
{
	struct ana38407_x716 *ctx = to_ana38407_x716(panel);
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = ctx->dsi };
	int ret = 0;

	mutex_lock(&ctx->lock);
	if (!ctx->enabled)
		goto out_unlock;

	ctx->dsi->mode_flags |= MIPI_DSI_MODE_LPM;
	mipi_dsi_dcs_set_display_off_multi(&dsi_ctx);
	ret = dsi_ctx.accum_err;
	ctx->enabled = false;

out_unlock:
	mutex_unlock(&ctx->lock);
	return ret;
}

static int ana38407_x716_sleep_in(struct ana38407_x716 *ctx)
{
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = ctx->dsi };

	ctx->dsi->mode_flags |= MIPI_DSI_MODE_LPM;
	mipi_dsi_dcs_enter_sleep_mode_multi(&dsi_ctx);
	mipi_dsi_msleep(&dsi_ctx, 100);

	return dsi_ctx.accum_err;
}

static int ana38407_x716_prepare(struct drm_panel *panel)
{
	struct ana38407_x716 *ctx = to_ana38407_x716(panel);
	int ret;

	mutex_lock(&ctx->lock);
	if (ctx->prepared) {
		ret = 0;
		goto out_unlock;
	}

	ret = ana38407_x716_power_on(ctx);
	if (ret)
		goto out_unlock;

	ana38407_x716_reset(ctx);

	ret = ana38407_x716_on(ctx);
	if (ret) {
		gpiod_set_value_cansleep(ctx->reset_gpio, 0);
		regulator_bulk_disable(ARRAY_SIZE(ana38407_x716_supplies), ctx->supplies);
		goto out_unlock;
	}
	ctx->prepared = true;

out_unlock:
	mutex_unlock(&ctx->lock);
	return ret;
}

static int ana38407_x716_unprepare(struct drm_panel *panel)
{
	struct ana38407_x716 *ctx = to_ana38407_x716(panel);
	int ret = 0;

	mutex_lock(&ctx->lock);
	if (!ctx->prepared)
		goto out_unlock;

	ret = ana38407_x716_sleep_in(ctx);
	ctx->enabled = false;
	ctx->prepared = false;
	gpiod_set_value_cansleep(ctx->reset_gpio, 0);
	regulator_bulk_disable(ARRAY_SIZE(ana38407_x716_supplies), ctx->supplies);

out_unlock:
	mutex_unlock(&ctx->lock);
	return ret;
}

/*
 * Both modes from X716's own stock DTS display-timings (wqxga120hs /
 * wqxga60hs), hactive/vactive 2560x1600 -- the 5th-cell DSC/porch entries
 * used here for the .clock computation, not guessed.
 */
static const struct drm_display_mode ana38407_x716_modes[] = {
	{	/* 120 Hz -- wqxga120hs */
		.clock = (2560 + 34 + 64 + 34) * (1600 + 42 + 64 + 32) * 120 / 1000,
		.hdisplay = 2560, .hsync_start = 2560 + 34, .hsync_end = 2560 + 34 + 64,
		.htotal = 2560 + 34 + 64 + 34,
		.vdisplay = 1600, .vsync_start = 1600 + 42, .vsync_end = 1600 + 42 + 64,
		.vtotal = 1600 + 42 + 64 + 32,
	},
	{	/* 60 Hz -- wqxga60hs */
		.clock = (2560 + 128 + 512 + 203) * (1600 + 127 + 512 + 257) * 60 / 1000,
		.hdisplay = 2560, .hsync_start = 2560 + 128, .hsync_end = 2560 + 128 + 512,
		.htotal = 2560 + 128 + 512 + 203,
		.vdisplay = 1600, .vsync_start = 1600 + 127, .vsync_end = 1600 + 127 + 512,
		.vtotal = 1600 + 127 + 512 + 257,
	},
};

static int ana38407_x716_get_modes(struct drm_panel *panel,
				   struct drm_connector *connector)
{
	struct drm_display_mode *mode;
	int i, count = 0;

	for (i = 0; i < ARRAY_SIZE(ana38407_x716_modes); i++) {
		mode = drm_mode_duplicate(connector->dev, &ana38407_x716_modes[i]);
		if (!mode)
			continue;
		mode->type = DRM_MODE_TYPE_DRIVER;
		if (i == 0)
			mode->type |= DRM_MODE_TYPE_PREFERRED;
		/* 236mm x 148mm, measured (X716 stock DTS physical-width/
		 * height-dimension properties). */
		mode->width_mm = 236;
		mode->height_mm = 148;
		drm_mode_set_name(mode);
		drm_mode_probed_add(connector, mode);
		count++;
	}

	connector->display_info.width_mm = 236;
	connector->display_info.height_mm = 148;

	return count;
}

static const struct drm_panel_funcs ana38407_x716_panel_funcs = {
	.prepare = ana38407_x716_prepare,
	.enable = ana38407_x716_enable,
	.disable = ana38407_x716_disable,
	.unprepare = ana38407_x716_unprepare,
	.get_modes = ana38407_x716_get_modes,
};

static int ana38407_x716_bl_update(struct backlight_device *bl)
{
	struct ana38407_x716 *ctx = bl_get_data(bl);
	u16 brightness = min_t(u16, backlight_get_brightness(bl),
			       ANA38407_X716_MAX_BRIGHTNESS);
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = ctx->dsi };
	unsigned long mode_flags;
	int ret = 0;

	mutex_lock(&ctx->lock);
	ctx->user_brightness = brightness;
	if (ctx->prepared) {
		mode_flags = ctx->dsi->mode_flags;
		ctx->dsi->mode_flags &= ~MIPI_DSI_MODE_LPM;
		mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
		mipi_dsi_dcs_write_var_seq_multi(&dsi_ctx, 0x51,
						 brightness >> 8, brightness & 0xff);
		mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
		ctx->dsi->mode_flags = mode_flags;
		ret = dsi_ctx.accum_err;
	}
	mutex_unlock(&ctx->lock);

	return ret;
}

static const struct backlight_ops ana38407_x716_bl_ops = {
	.update_status = ana38407_x716_bl_update,
};

static struct backlight_device *ana38407_x716_create_backlight(struct ana38407_x716 *ctx)
{
	struct device *dev = &ctx->dsi->dev;
	const struct backlight_properties props = {
		.type = BACKLIGHT_RAW,
		.brightness = ANA38407_X716_MAX_BRIGHTNESS,
		.max_brightness = ANA38407_X716_MAX_BRIGHTNESS,
	};

	return devm_backlight_device_register(dev, dev_name(dev), dev, ctx,
					      &ana38407_x716_bl_ops, &props);
}

/*
 * DSC config decoded byte-for-byte from the panel's own 88-byte PPS
 * payload (panel_data_file/GTS9_ANA38407_AMSA10FA01.dat's DSC_SETTING
 * macro) -- DSC 1.1, 2560x1600, two 1280x100 slices, 8bpc, 8.0bpp. The
 * rc_buf_thresh/rc_range_params tables decode to exactly the VESA/DSC
 * 8bpp spec-standard values (same table the sibling AMSA46AS02 driver
 * uses), not a custom tuning -- cross-checked against this panel's own
 * DTS DSC properties (kernel/dts/sm8550-samsung-x716b.dts's panel@0 node
 * / X716 stock DTS's display-timings block), which agree exactly. The
 * msm DSI host fills convert_rgb/line_buf_depth and calls
 * drm_dsc_compute_rc_parameters() for the derived fields, so those are
 * left out, matching the sibling driver's own approach.
 */
static const struct drm_dsc_config ana38407_x716_dsc_template = {
	.dsc_version_major = 1,
	.dsc_version_minor = 1,
	.slice_height = 100,
	.slice_width = 1280,
	.slice_count = 2,
	.bits_per_component = 8,
	.bits_per_pixel = 8 << 4,
	.block_pred_enable = true,
	.pic_width = 2560,
	.pic_height = 1600,
	.rc_buf_thresh = {
		14, 28, 42, 56, 70, 84, 98, 105, 112, 119, 121, 123, 125, 126
	},
	.rc_model_size = DSC_RC_MODEL_SIZE_CONST,
	.rc_edge_factor = DSC_RC_EDGE_FACTOR_CONST,
	.rc_tgt_offset_high = DSC_RC_TGT_OFFSET_HI_CONST,
	.rc_tgt_offset_low = DSC_RC_TGT_OFFSET_LO_CONST,
	.mux_word_size = DSC_MUX_WORD_SIZE_8_10_BPC,
	.line_buf_depth = 9,
	.first_line_bpg_offset = 12,
	.initial_xmit_delay = 512,
	.initial_offset = 6144,
	.rc_quant_incr_limit0 = 11,
	.rc_quant_incr_limit1 = 11,
	.rc_range_params = {
		{ 0,  4, DSC_BPG_OFFSET(2)},
		{ 0,  4, DSC_BPG_OFFSET(0)},
		{ 1,  5, DSC_BPG_OFFSET(0)},
		{ 1,  6, DSC_BPG_OFFSET(-2)},
		{ 3,  7, DSC_BPG_OFFSET(-4)},
		{ 3,  7, DSC_BPG_OFFSET(-6)},
		{ 3,  7, DSC_BPG_OFFSET(-8)},
		{ 3,  8, DSC_BPG_OFFSET(-8)},
		{ 3,  9, DSC_BPG_OFFSET(-8)},
		{ 3, 10, DSC_BPG_OFFSET(-10)},
		{ 5, 10, DSC_BPG_OFFSET(-10)},
		{ 5, 11, DSC_BPG_OFFSET(-12)},
		{ 5, 11, DSC_BPG_OFFSET(-12)},
		{ 9, 12, DSC_BPG_OFFSET(-12)},
		{12, 13, DSC_BPG_OFFSET(-12)},
	},
	.slice_chunk_size = 1280,
};

static void ana38407_x716_dsc_config(struct ana38407_x716 *ctx)
{
	ctx->dsc = ana38407_x716_dsc_template;
}

static int ana38407_x716_probe(struct mipi_dsi_device *dsi)
{
	struct device *dev = &dsi->dev;
	struct ana38407_x716 *ctx;
	int ret;

	ctx = devm_drm_panel_alloc(dev, struct ana38407_x716, panel,
				   &ana38407_x716_panel_funcs,
				   DRM_MODE_CONNECTOR_DSI);
	if (IS_ERR(ctx))
		return PTR_ERR(ctx);

	ret = devm_regulator_bulk_get_const(dev, ARRAY_SIZE(ana38407_x716_supplies),
					    ana38407_x716_supplies, &ctx->supplies);
	if (ret < 0)
		return dev_err_probe(dev, ret, "failed to get panel regulators\n");

	ctx->reset_gpio = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(ctx->reset_gpio))
		return dev_err_probe(dev, PTR_ERR(ctx->reset_gpio),
				     "failed to get reset gpio\n");

	ctx->dsi = dsi;
	mipi_dsi_set_drvdata(dsi, ctx);
	mutex_init(&ctx->lock);
	ctx->user_brightness = ANA38407_X716_MAX_BRIGHTNESS;

	dsi->lanes = 4;
	dsi->format = MIPI_DSI_FMT_RGB888;
	dsi->mode_flags = MIPI_DSI_MODE_LPM | MIPI_DSI_CLOCK_NON_CONTINUOUS;

	ctx->panel.prepare_prev_first = true;

	ctx->panel.backlight = ana38407_x716_create_backlight(ctx);
	if (IS_ERR(ctx->panel.backlight))
		return dev_err_probe(dev, PTR_ERR(ctx->panel.backlight),
				     "failed to create backlight\n");

	drm_panel_add(&ctx->panel);

	ana38407_x716_dsc_config(ctx);
	dsi->dsc = &ctx->dsc;

	ret = mipi_dsi_attach(dsi);
	if (ret < 0) {
		drm_panel_remove(&ctx->panel);
		return dev_err_probe(dev, ret, "failed to attach to DSI host\n");
	}

	return 0;
}

static void ana38407_x716_remove(struct mipi_dsi_device *dsi)
{
	struct ana38407_x716 *ctx = mipi_dsi_get_drvdata(dsi);
	int ret;

	ret = mipi_dsi_detach(dsi);
	if (ret < 0)
		dev_err(&dsi->dev, "failed to detach from DSI host: %d\n", ret);

	drm_panel_remove(&ctx->panel);
}

static const struct of_device_id ana38407_x716_of_match[] = {
	{ .compatible = "samsung,ana38407-amsa10fa01" },
	{ }
};
MODULE_DEVICE_TABLE(of, ana38407_x716_of_match);

static struct mipi_dsi_driver ana38407_x716_driver = {
	.probe = ana38407_x716_probe,
	.remove = ana38407_x716_remove,
	.driver = {
		.name = "panel-samsung-ana38407-x716",
		.of_match_table = ana38407_x716_of_match,
	},
};
module_mipi_dsi_driver(ana38407_x716_driver);

MODULE_DESCRIPTION("Samsung ANA38407 AMSA10FA01 (gts9-5g) DSI panel driver");
MODULE_LICENSE("GPL");
