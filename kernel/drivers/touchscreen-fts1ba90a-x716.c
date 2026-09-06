// SPDX-License-Identifier: GPL-2.0-only
/*
 * STMicroelectronics fts1ba90a touch controller, as fitted to the Galaxy
 * Tab S9 5G (SM-X716B, "gts9-5g") at i2c address 0x49 on qupv3_se4_i2c
 * (&i2c4).
 *
 * There is no usable mainline driver for this chip. Mainline's own
 * drivers/input/touchscreen/stmfts.c (compatible "st,stmfts") targets a much
 * older Galaxy S6/S7-era ST "FingerTip" part with a disjoint opcode set --
 * confirmed by reading both against Samsung's downstream fts1ba90a source
 * (drivers/input/touchscreen/stm/fts1ba90a/{fts_ts.c,fts_sec.c,fts_fwu.c} in
 * android_kernel_samsung_gts9/), which is what this driver is actually
 * ported from (opcodes, power sequencing, event-FIFO framing and bit
 * packing below are all read directly from that source, cited by function/
 * line as of that tree's checkout). See docs/porting-log.md and
 * docs/hardware-facts.md for the DTS/GPIO/regulator facts this was wired
 * up against.
 *
 * Deliberately NOT ported (all confirmed separable from basic multitouch
 * in the downstream source): firmware flashing/request_firmware() -- the
 * downstream driver's own version-compare logic shows the IC ships from
 * Samsung's factory line with valid firmware already resident, and "skip fw
 * update, ic version already current" (fts_fwu.c) is the normal outcome on
 * every subsequent boot, so this driver just talks to whatever firmware is
 * already on the chip; all of fts_sec.c (factory/sysfs/production-test
 * commands); TCLM calibration; gesture/AOD/sponge commands; DeX mode;
 * secure-touch (TUI); vbus notifier; and suspend/resume power-down (the
 * touch rail is left powered across suspend for now -- a later addition via
 * SET_SYSTEM_SLEEP_PM_OPS if that ever matters for battery life).
 *
 * Also different from the downstream driver on purpose: a chip-ID mismatch
 * after power-on is treated as a hard probe failure here. The downstream
 * driver logs it and continues anyway (fts_ts.c's second chip-ID retry
 * result is literally discarded, an unintentional-looking bug) -- not
 * behavior worth inheriting.
 */

#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/input.h>
#include <linux/input/mt.h>
#include <linux/input/touchscreen.h>
#include <linux/interrupt.h>
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/regulator/consumer.h>

/*
 * Opcodes and constants below are all read directly from the downstream
 * fts1ba90a driver's fts_ts.h, not guessed -- values that mattered enough
 * to double-check are cited by line.
 */
#define FTS1BA90A_READ_DEVICE_ID	0x22	/* fts_ts.h:111 */
#define FTS1BA90A_READ_FW_VERSION	0x24	/* fts_ts.h:113, logged only */
#define FTS1BA90A_SET_TOUCH_FUNCTION	0x30	/* fts_ts.h:115 */
#define FTS1BA90A_READ_ONE_EVENT	0x60	/* fts_ts.h:128 */
#define FTS1BA90A_READ_ALL_EVENT	0x61	/* fts_ts.h:129 */

#define FTS1BA90A_ID0			0x39	/* fts_ts.h:84 */
#define FTS1BA90A_ID1			0x36	/* fts_ts.h:85 */

#define FTS1BA90A_EVENT_SIZE		16	/* fts_ts.h:88 */
#define FTS1BA90A_FIFO_MAX		32	/* fts_ts.h:87 */

/* byte0 bits [5:2] of a status-type (eid==1) event, fts_ts.h's
 * struct fts_event_status. FTS1BA90A_INFO_READY_STATUS in byte1 (status_id)
 * of such an event is what fts_wait_for_ready() (fts_ts.c:923-1008) polls
 * for after power-on/reset.
 */
#define FTS1BA90A_EVENT_ID_STATUS	1
#define FTS1BA90A_STYPE_INFORMATION	2	/* fts_ts.h:195 */
#define FTS1BA90A_INFO_READY_STATUS	0x00	/* fts_ts.h:204 */

/* byte0 bits [1:0] of every event -- fts_ts.c:1754-1781's event_id switch */
#define FTS1BA90A_EVENT_ID_COORDINATE	0

/* byte0 bits [7:6] of a coordinate-type event, struct fts_event_coordinate's
 * tchsta field -- values are FTS_COORDINATE_ACTION_* (fts_ts.h:177-180).
 */
#define FTS1BA90A_ACTION_NONE		0
#define FTS1BA90A_ACTION_PRESS		1
#define FTS1BA90A_ACTION_MOVE		2
#define FTS1BA90A_ACTION_RELEASE	3

/* fts_set_touch_function()'s default touch_functions bitmask (fts_ts.c:1647,
 * FTS_TOUCHTYPE_DEFAULT_ENABLE = BIT_TOUCH|BIT_PALM|BIT_WET, fts_ts.h:
 * 221,226,227,229).
 */
#define FTS1BA90A_TOUCHTYPE_DEFAULT_ENABLE	0x61

/* fts_set_scanmode()'s scan-on write, fts_ts.c:612-651: opcode 0xA0 0x00
 * <mode>, mode = FTS_SCAN_MODE_DEFAULT = FTS_SCAN_MODE_MS_SS_SCAN = BIT(0)
 * (fts_ts.h:211,215).
 */
#define FTS1BA90A_SCAN_MODE_ON		0x01

#define FTS1BA90A_READY_TIMEOUT_MS	3000	/* ~ FTS_RETRY_COUNT*15 polls
						 * of 20ms, fts_ts.h:263 */
#define FTS1BA90A_READY_POLL_MS		20
#define FTS1BA90A_MAX_TOUCH		10	/* SEC_TS_SUPPORT_TOUCH_COUNT */

struct fts1ba90a {
	struct i2c_client *client;
	struct input_dev *input;
	struct touchscreen_properties prop;
	struct regulator *vddio;
	struct regulator *avdd;
	struct mutex lock;
};

static int fts1ba90a_write(struct i2c_client *client, const u8 *buf, size_t len)
{
	struct i2c_msg msg = {
		.addr = client->addr,
		.flags = 0,
		.len = len,
		.buf = (u8 *)buf,
	};
	int ret;

	ret = i2c_transfer(client->adapter, &msg, 1);
	if (ret != 1)
		return ret < 0 ? ret : -EIO;
	return 0;
}

/* Write a 1-byte opcode, then read back len bytes -- every read command
 * this chip has works this way (a plain write followed by a repeated-start
 * read, fts_read_reg(), fts_ts.c:328-...).
 */
static int fts1ba90a_read(struct i2c_client *client, u8 cmd, u8 *buf, size_t len)
{
	struct i2c_msg msgs[2] = {
		{
			.addr = client->addr,
			.flags = 0,
			.len = 1,
			.buf = &cmd,
		},
		{
			.addr = client->addr,
			.flags = I2C_M_RD,
			.len = len,
			.buf = buf,
		},
	};
	int ret;

	ret = i2c_transfer(client->adapter, msgs, 2);
	if (ret != 2)
		return ret < 0 ? ret : -EIO;
	return 0;
}

static int fts1ba90a_power_on(struct fts1ba90a *ts)
{
	int ret;

	/* Order and delay match sec_input_power(), sec_common_fn.c:1135-1181:
	 * vddio (tsp_io_ldo) first, 1ms settle, then avdd (tsp_avdd_ldo).
	 */
	ret = regulator_enable(ts->vddio);
	if (ret)
		return ret;
	usleep_range(1000, 1100);
	ret = regulator_enable(ts->avdd);
	if (ret) {
		regulator_disable(ts->vddio);
		return ret;
	}
	return 0;
}

static void fts1ba90a_power_off(struct fts1ba90a *ts)
{
	/* Reverse order, 4ms between rails -- sec_common_fn.c:1135-1181. */
	regulator_disable(ts->avdd);
	usleep_range(4000, 4100);
	regulator_disable(ts->vddio);
}

/*
 * Poll for the chip's power-on-ready event. Mirrors fts_wait_for_ready()
 * (fts_ts.c:923-1008), minus its FW-corruption/OSC-trim diagnostics (out of
 * scope here -- a plain timeout is enough to know something's wrong).
 */
static int fts1ba90a_wait_ready(struct fts1ba90a *ts)
{
	unsigned long deadline = jiffies + msecs_to_jiffies(FTS1BA90A_READY_TIMEOUT_MS);
	u8 data[FTS1BA90A_EVENT_SIZE];
	int ret;

	do {
		ret = fts1ba90a_read(ts->client, FTS1BA90A_READ_ONE_EVENT,
				     data, sizeof(data));
		if (ret)
			return ret;

		if (((data[0] >> 2) & 0xf) == FTS1BA90A_STYPE_INFORMATION &&
		    data[1] == FTS1BA90A_INFO_READY_STATUS)
			return 0;

		msleep(FTS1BA90A_READY_POLL_MS);
	} while (time_before(jiffies, deadline));

	return -ETIMEDOUT;
}

/*
 * In-band system reset. There is no reset-gpio on this board (confirmed:
 * the stock DTS touchscreen node has no reset-gpio/sec,reset_gpio property
 * at all) -- reset is this 6-byte memory-mapped-register write instead.
 * fts_systemreset(), fts_ts.c:1010-1034. (FTS_CMD_SW_RESET=0x12 also exists
 * in fts_ts.h but is dead code in the real downstream driver -- never used.)
 */
static int fts1ba90a_systemreset(struct fts1ba90a *ts)
{
	static const u8 cmd[6] = { 0xfa, 0x20, 0x00, 0x00, 0x24, 0x81 };
	int ret;

	ret = fts1ba90a_write(ts->client, cmd, sizeof(cmd));
	if (ret)
		return ret;
	msleep(30);
	return fts1ba90a_wait_ready(ts);
}

static int fts1ba90a_read_chip_id(struct fts1ba90a *ts)
{
	u8 val[5];
	int ret;

	ret = fts1ba90a_read(ts->client, FTS1BA90A_READ_DEVICE_ID, val, sizeof(val));
	if (ret)
		return ret;

	if (val[2] != FTS1BA90A_ID0 || val[3] != FTS1BA90A_ID1) {
		dev_err(&ts->client->dev,
			"unexpected chip id %02x %02x %02x %02x %02x\n",
			val[0], val[1], val[2], val[3], val[4]);
		return -ENODEV;
	}
	return 0;
}

/* fts_set_touch_function() + fts_set_scanmode()'s scan-enable write,
 * fts_ts.c:731-746,612-651 -- minus the vsync-scan read/disable branch
 * (info->board->disable_vsync_scan is never set on this board) and minus
 * the force-calibration/clear-all-event commands issued around them in
 * fts_init() (fts_ts.c:1651,1653), which are calibration/queue-flushing
 * niceties, not required to start receiving touch events.
 */
static int fts1ba90a_start_scan(struct fts1ba90a *ts)
{
	u8 touch_function[3] = {
		FTS1BA90A_SET_TOUCH_FUNCTION,
		FTS1BA90A_TOUCHTYPE_DEFAULT_ENABLE,
		0x00,
	};
	u8 scan_on[3] = { 0xa0, 0x00, FTS1BA90A_SCAN_MODE_ON };
	int ret;

	ret = fts1ba90a_write(ts->client, touch_function, sizeof(touch_function));
	if (ret)
		return ret;
	msleep(10);

	ret = fts1ba90a_write(ts->client, scan_on, sizeof(scan_on));
	if (ret)
		return ret;
	msleep(50);
	return 0;
}

/*
 * struct fts_event_coordinate (fts_ts.h:474-497), 16 bytes, unpacked by
 * hand here rather than as a bitfield struct to not depend on a particular
 * compiler's bitfield-in-byte ordering:
 *
 *   byte0: eid[1:0] tid[5:2] tchsta[7:6]
 *   byte1: x_11_4
 *   byte2: y_11_4
 *   byte3: y_3_0[3:0] x_3_0[7:4]
 *   byte4: major
 *   byte5: minor
 *   byte6: z[5:0] ttype_3_2[7:6]
 *   byte7: left_event[5:0] ttype_1_0[7:6]
 */
static void fts1ba90a_report_event(struct fts1ba90a *ts, const u8 *ev)
{
	unsigned int action, tid, x, y;

	if ((ev[0] & 0x3) != FTS1BA90A_EVENT_ID_COORDINATE)
		return;

	tid = (ev[0] >> 2) & 0xf;
	action = (ev[0] >> 6) & 0x3;

	if (tid >= FTS1BA90A_MAX_TOUCH)
		return;

	/* Release/none: don't refresh this slot -- input_mt_sync_frame()
	 * below releases any slot not touched this frame on its own, same
	 * idiom as the mainline goodix_berlin driver on the sibling tablet.
	 */
	if (action == FTS1BA90A_ACTION_RELEASE || action == FTS1BA90A_ACTION_NONE)
		return;

	x = (ev[1] << 4) | (ev[3] >> 4);
	y = (ev[2] << 4) | (ev[3] & 0xf);

	input_mt_slot(ts->input, tid);
	input_mt_report_slot_state(ts->input, MT_TOOL_FINGER, true);
	touchscreen_report_pos(ts->input, &ts->prop, x, y, true);
	input_report_abs(ts->input, ABS_MT_TOUCH_MAJOR, ev[4]);
	input_report_abs(ts->input, ABS_MT_TOUCH_MINOR, ev[5]);
}

/*
 * fts_event_handler_type_b(), fts_ts.c:1754-1781: one FTS1BA90A_READ_ONE_EVENT
 * read always happens first; its own byte7 bits[5:0] say how many MORE
 * events are queued, which (if nonzero) are then burst-read in one
 * FTS1BA90A_READ_ALL_EVENT transaction. That pending-count field sits at the
 * same byte offset in both the coordinate and status event layouts, so this
 * works regardless of the first event's actual type.
 */
static irqreturn_t fts1ba90a_irq_thread(int irq, void *data)
{
	struct fts1ba90a *ts = data;
	u8 buf[FTS1BA90A_FIFO_MAX * FTS1BA90A_EVENT_SIZE];
	unsigned int pending;
	unsigned int i;
	int ret;

	mutex_lock(&ts->lock);

	ret = fts1ba90a_read(ts->client, FTS1BA90A_READ_ONE_EVENT, buf,
			     FTS1BA90A_EVENT_SIZE);
	if (ret)
		goto out;

	pending = buf[7] & 0x3f;
	if (pending) {
		if (pending > FTS1BA90A_FIFO_MAX - 1)
			pending = FTS1BA90A_FIFO_MAX - 1;
		ret = fts1ba90a_read(ts->client, FTS1BA90A_READ_ALL_EVENT,
				     buf + FTS1BA90A_EVENT_SIZE,
				     pending * FTS1BA90A_EVENT_SIZE);
		if (ret)
			pending = 0;
	}

	for (i = 0; i <= pending; i++)
		fts1ba90a_report_event(ts, &buf[i * FTS1BA90A_EVENT_SIZE]);

	input_mt_sync_frame(ts->input);
	input_sync(ts->input);
out:
	mutex_unlock(&ts->lock);
	return IRQ_HANDLED;
}

static int fts1ba90a_hw_init(struct fts1ba90a *ts)
{
	int ret;

	ret = fts1ba90a_power_on(ts);
	if (ret)
		return dev_err_probe(&ts->client->dev, ret,
				      "failed to power on\n");

	ret = fts1ba90a_wait_ready(ts);
	if (ret) {
		/* One in-band reset retry, then one hard power-cycle retry --
		 * mirrors fts_init()'s escalation (fts_ts.c:1534-1571,1599),
		 * simplified to drop the FW-corruption/OSC-trim branches.
		 */
		ret = fts1ba90a_systemreset(ts);
		if (ret) {
			fts1ba90a_power_off(ts);
			msleep(20);
			ret = fts1ba90a_power_on(ts);
			if (ret)
				return dev_err_probe(&ts->client->dev, ret,
						      "failed to re-power\n");
			ret = fts1ba90a_wait_ready(ts);
		}
		if (ret) {
			fts1ba90a_power_off(ts);
			return dev_err_probe(&ts->client->dev, ret,
					      "controller never became ready\n");
		}
	}

	ret = fts1ba90a_read_chip_id(ts);
	if (ret) {
		fts1ba90a_power_off(ts);
		return dev_err_probe(&ts->client->dev, ret,
				      "chip id mismatch\n");
	}

	{
		u8 fw_ver[3];

		if (!fts1ba90a_read(ts->client, FTS1BA90A_READ_FW_VERSION,
				    fw_ver, sizeof(fw_ver)))
			dev_info(&ts->client->dev,
				 "resident firmware version %02x%02x%02x\n",
				 fw_ver[0], fw_ver[1], fw_ver[2]);
	}

	ret = fts1ba90a_start_scan(ts);
	if (ret) {
		fts1ba90a_power_off(ts);
		return dev_err_probe(&ts->client->dev, ret,
				      "failed to start scanning\n");
	}

	return 0;
}

static int fts1ba90a_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct fts1ba90a *ts;
	int ret;

	if (!i2c_check_functionality(client->adapter, I2C_FUNC_I2C))
		return -ENXIO;

	ts = devm_kzalloc(dev, sizeof(*ts), GFP_KERNEL);
	if (!ts)
		return -ENOMEM;
	ts->client = client;
	mutex_init(&ts->lock);
	i2c_set_clientdata(client, ts);

	ts->vddio = devm_regulator_get(dev, "vddio");
	if (IS_ERR(ts->vddio))
		return dev_err_probe(dev, PTR_ERR(ts->vddio),
				      "failed to get vddio supply\n");
	ts->avdd = devm_regulator_get(dev, "avdd");
	if (IS_ERR(ts->avdd))
		return dev_err_probe(dev, PTR_ERR(ts->avdd),
				      "failed to get avdd supply\n");

	ret = fts1ba90a_hw_init(ts);
	if (ret)
		return ret;

	ts->input = devm_input_allocate_device(dev);
	if (!ts->input) {
		ret = -ENOMEM;
		goto err_power_off;
	}
	ts->input->name = "fts1ba90a";
	ts->input->id.bustype = BUS_I2C;

	/* Placeholder range -- touchscreen_parse_properties() below overrides
	 * these with the real touchscreen-size-x/y from DT. */
	input_set_abs_params(ts->input, ABS_MT_POSITION_X, 0, 0xffff, 0, 0);
	input_set_abs_params(ts->input, ABS_MT_POSITION_Y, 0, 0xffff, 0, 0);
	input_set_abs_params(ts->input, ABS_MT_TOUCH_MAJOR, 0, 255, 0, 0);
	input_set_abs_params(ts->input, ABS_MT_TOUCH_MINOR, 0, 255, 0, 0);

	touchscreen_parse_properties(ts->input, true, &ts->prop);

	ret = input_mt_init_slots(ts->input, FTS1BA90A_MAX_TOUCH,
				  INPUT_MT_DIRECT | INPUT_MT_DROP_UNUSED);
	if (ret) {
		ret = dev_err_probe(dev, ret, "failed to init MT slots\n");
		goto err_power_off;
	}

	ret = input_register_device(ts->input);
	if (ret) {
		ret = dev_err_probe(dev, ret, "failed to register input device\n");
		goto err_power_off;
	}

	/* Requested last, same ordering as fts_probe() (fts_ts.c:2525): the
	 * IRQ flags are hardcoded IRQF_TRIGGER_LOW|IRQF_ONESHOT there
	 * regardless of the (confirmed dead) sec,irq_flag DT property.
	 */
	ret = devm_request_threaded_irq(dev, client->irq, NULL,
					fts1ba90a_irq_thread,
					IRQF_TRIGGER_LOW | IRQF_ONESHOT,
					client->name, ts);
	if (ret) {
		ret = dev_err_probe(dev, ret, "failed to request irq\n");
		goto err_power_off;
	}

	return 0;

err_power_off:
	fts1ba90a_power_off(ts);
	return ret;
}

static void fts1ba90a_remove(struct i2c_client *client)
{
	struct fts1ba90a *ts = i2c_get_clientdata(client);

	fts1ba90a_power_off(ts);
}

static const struct of_device_id fts1ba90a_of_match[] = {
	{ .compatible = "stm,fts_touch" },
	{ }
};
MODULE_DEVICE_TABLE(of, fts1ba90a_of_match);

static struct i2c_driver fts1ba90a_driver = {
	.driver = {
		.name = "fts1ba90a",
		.of_match_table = fts1ba90a_of_match,
	},
	.probe = fts1ba90a_probe,
	.remove = fts1ba90a_remove,
};
module_i2c_driver(fts1ba90a_driver);

MODULE_DESCRIPTION("STMicroelectronics fts1ba90a touchscreen (Galaxy Tab S9 5G)");
MODULE_LICENSE("GPL");
