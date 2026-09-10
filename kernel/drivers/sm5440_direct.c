// SPDX-License-Identifier: GPL-2.0-only
/*
 * Silicon Mitus SM5440 2:1 direct charger for the Samsung SM-X716B
 * (base Galaxy Tab S9, 8400 mAh pack -- NOT the S9 Ultra).
 *
 * This is a deliberately small mainline-first driver.  Linux TCPM owns USB-PD
 * policy; this driver requests a PPS operating point, hands the battery path
 * over from SM5714, and runs a closed loop that walks this model's stock
 * 3-step direct-charge current profile (up to ~45 W) while measuring bus
 * current, die and pack temperature every tick.  An RTC-alarm keepalive keeps
 * the PPS contract alive across system suspend.  Every failure turns the pump
 * off and restores the fixed-PD switching charger.  All numeric constants are
 * this model's own (gts9_eur_openx stock DTS); see docs/charging.md.
 */

#include <linux/alarmtimer.h>
#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/pm_wakeup.h>
#include <linux/power_supply.h>
#include <linux/workqueue.h>

#define SM5440_REG_STATUS1		0x08
#define SM5440_REG_STATUS3		0x0a
#define  SM5440_STATUS3_VBUSPOK		BIT(5)
#define SM5440_REG_CNTL1		0x0c
#define  SM5440_CNTL1_SW_RESET		BIT(0)
#define  SM5440_CNTL1_WDT_EN		BIT(7)
#define  SM5440_CNTL1_WDT_30S		(4 << 4)
#define SM5440_REG_CNTL2		0x0d
#define SM5440_REG_CNTL3		0x0e
#define SM5440_REG_CNTL4		0x0f
#define SM5440_REG_CNTL5		0x10
#define  SM5440_CNTL5_OP_MODE_MASK	GENMASK(3, 2)
#define  SM5440_CNTL5_CHG_ON		BIT(2)
#define SM5440_REG_CNTL6		0x11
#define SM5440_REG_CNTL7		0x12
#define SM5440_REG_VBUSCNTL		0x13
#define SM5440_REG_VBATCNTL		0x14
#define SM5440_REG_VOUTCNTL		0x15
#define SM5440_REG_IBUSCNTL		0x16
#define SM5440_REG_PRTNCNTL		0x19
#define SM5440_REG_THEMCNTL1		0x1a
#define SM5440_REG_ADCCNTL1		0x1c
#define  SM5440_ADCCNTL1_AVG_32		BIT(3)
#define  SM5440_ADCCNTL1_CONTINUOUS	BIT(1)
#define  SM5440_ADCCNTL1_ENABLE	BIT(0)
#define SM5440_REG_ADCCNTL2		0x1d
#define SM5440_REG_ADC_VBUS1		0x1e
#define SM5440_REG_ADC_IBUS1		0x22
#define SM5440_REG_ADC_DIETEMP		0x26
#define SM5440_REG_ADC_VBAT1		0x27
#define SM5440_REG_DEVICEID		0x2b

#define SM5440_POLL_MS			1000
#define SM5440_RETRY_MS			30000

/*
 * Direct-charge step profile, taken verbatim from this exact model's stock
 * Samsung sec-battery node (SM-X716B, the base Tab S9 -- NOT the S9 Ultra,
 * which has a physically larger pack and its own numbers):
 *
 *   android_kernel_samsung_gts9/.../gts9/gts9_eur_openx_w00_r04.dts
 *     battery,dc_step_chg_cond_vol = <0x1022 0x109a 0x1158>  = 4130/4250/4440 mV
 *     battery,dc_step_chg_val_iout = <0x21d4 0x1cfc 0x1734>  = 8660/7420/5940 mA
 *
 * dc_step_chg_val_iout is the *battery-side* current; a 2:1 pump draws about
 * half that at its input, so sm5440_step_ibus_ma is that / 2.  As the pack
 * fills it moves DOWN the table (higher V -> lower I); the last cond_vol
 * (4440) is the CV float ceiling, so leaving step 2 hands the CV tail back
 * to the switching charger.
 */
#define SM5440_NR_STEPS			3
static const int sm5440_step_vpack_mv[SM5440_NR_STEPS] = { 4130, 4250, 4440 };
static const int sm5440_step_ibat_ma[SM5440_NR_STEPS]  = { 8660, 7420, 5940 };
static const int sm5440_step_ibus_ma[SM5440_NR_STEPS]  = { 4330, 3710, 2970 };

/*
 * Headroom the loop starts with, above twice the pack.  The board's stock
 * sm5440,r_ttl is 0.32 ohm; at a few amps that is over a volt of IR drop, so
 * the closed loop in sm5440_work() pushes the request up from here (bounded
 * by SM5440_MAX_HEADROOM_MV) until the measured input current arrives.
 */
#define SM5440_INITIAL_HEADROOM_MV	1100
#define SM5440_MAX_HEADROOM_MV		2000
#define SM5440_VSTEP_MV			40
#define SM5440_IBUS_TOLERANCE_MA	200

/*
 * Hard ceilings, never raised at runtime.  SM5440_VFLOAT_MV is this model's
 * stock chg_float_voltage; SM5440_VBATREG_MV is the pump's own VBAT-reg
 * backstop just below it.  Three independent layers (pump VBATREG, the stop
 * check in sm5440_work(), and sm5714_battery's own CV loop) hold the pack at
 * or under 4440 mV.
 */
#define SM5440_VFLOAT_MV		4440
#define SM5440_VBATREG_MV		4400
#define SM5440_CV_HANDOFF_MV		4430
#define SM5440_MIN_IBAT_MA		2000	/* stock charger,dchg_min_current */
#define SM5440_DCHG_MIN_VBAT_MV		3400	/* stock charger,dchg_min_vbat */
#define SM5440_IBUS_CLAMP_MARGIN_MA	400
#define SM5440_IBUS_CLAMP_MAX_MA	4800

/*
 * Switching frequency and its two thermal derate steps (stock sm5440,freq =
 * 850 kHz, sm5440,freq_siop = <450 650>).  CNTL7 encodes (kHz - 250) / 50.
 */
#define SM5440_FREQUENCY_KHZ		850
#define SM5440_FREQUENCY_SIOP1_KHZ	650
#define SM5440_FREQUENCY_SIOP2_KHZ	450

/*
 * Thermal limits in 0.1 degC.  The pack numbers are deliberately stricter
 * than Samsung's stock 65/70 degC gates: those watch a charger-side
 * thermistor, whereas POWER_SUPPLY_PROP_TEMP here is the pack thermistor,
 * which a 45 W charge must never push nearly that hot.  The die numbers are
 * the SM5440's own junction sensor.
 */
#define SM5440_PACK_DERATE_DC		400
#define SM5440_PACK_STOP_DC		440
#define SM5440_DIE_DERATE_DC1		800
#define SM5440_DIE_DERATE_DC2		950
#define SM5440_DIE_STOP_DC		1100

/* Suspend keepalive: re-Request the APDO this often (seconds) across s2ram. */
#define SM5440_KEEPALIVE_SEC		8

/* Module parameters -- bring-up knobs, all bounded so none can relax a guard. */
#define SM5440_PPS_OP_CURR_DEFAULT_MA	4500
#define SM5440_PPS_OP_CURR_MIN_MA	1000
#define SM5440_PPS_OP_CURR_MAX_MA	5000
#define SM5440_TARGET_IBUS_MIN_MA	800
#define SM5440_TARGET_IBUS_MAX_MA	4800

static unsigned int pps_op_curr_ma = SM5440_PPS_OP_CURR_DEFAULT_MA;
module_param(pps_op_curr_ma, uint, 0644);
MODULE_PARM_DESC(pps_op_curr_ma,
		 "operating current requested in the PPS contract, mA (default 4500; only raise with a 5 A / e-marked cable)");

static unsigned int target_ibus_ma;
module_param(target_ibus_ma, uint, 0644);
MODULE_PARM_DESC(target_ibus_ma,
		 "pin the pump input current the loop aims for, mA (0 = follow the step table; non-zero is for staged bring-up only)");

static bool verbose;
module_param(verbose, bool, 0644);
MODULE_PARM_DESC(verbose, "log every regulation tick");

int sm5714_battery_set_direct_charge(bool active);

struct sm5440_direct {
	struct device *dev;
	struct i2c_client *client;
	struct power_supply *tcpm;
	struct power_supply *battery;
	struct delayed_work work;
	int target_mv;
	int target_ma;
	int step;
	int freq_khz;
	unsigned int pps_ticks;
	unsigned int cv_ticks;
	bool active;

	struct alarm keepalive_alarm;
	struct wakeup_source *ws;
	bool keepalive_capable;
	bool keepalive_pending;
};

static int sm5440_update_bits(struct sm5440_direct *sm, u8 reg, u8 mask,
			      u8 val)
{
	int old;

	old = i2c_smbus_read_byte_data(sm->client, reg);
	if (old < 0)
		return old;

	return i2c_smbus_write_byte_data(sm->client, reg,
					 (old & ~mask) | (val & mask));
}

static int sm5440_read_adc_pair(struct sm5440_direct *sm, u8 reg)
{
	int high, low;

	high = i2c_smbus_read_byte_data(sm->client, reg);
	if (high < 0)
		return high;
	low = i2c_smbus_read_byte_data(sm->client, reg + 1);
	if (low < 0)
		return low;

	return (high << 5) | (low >> 3);
}

static int sm5440_adc_vbus_mv(struct sm5440_direct *sm)
{
	int raw = sm5440_read_adc_pair(sm, SM5440_REG_ADC_VBUS1);

	return raw < 0 ? raw : 4096 + raw;
}

static int sm5440_adc_ibus_ma(struct sm5440_direct *sm)
{
	int raw = sm5440_read_adc_pair(sm, SM5440_REG_ADC_IBUS1);

	return raw < 0 ? raw : (raw * 625) / 1000;
}

static int sm5440_adc_vbat_mv(struct sm5440_direct *sm)
{
	int raw = sm5440_read_adc_pair(sm, SM5440_REG_ADC_VBAT1);

	return raw < 0 ? raw : 2048 + (raw * 500) / 1000;
}

static int sm5440_adc_die_temp(struct sm5440_direct *sm)
{
	int raw = i2c_smbus_read_byte_data(sm->client,
					   SM5440_REG_ADC_DIETEMP);

	return raw < 0 ? raw : 225 + raw * 5;
}

static int sm5440_psy_get(struct power_supply *psy,
			  enum power_supply_property prop)
{
	union power_supply_propval val;
	int ret;

	ret = power_supply_get_property(psy, prop, &val);
	return ret ? ret : val.intval;
}

static int sm5440_psy_set(struct power_supply *psy,
			  enum power_supply_property prop, int value)
{
	union power_supply_propval val = { .intval = value };

	return power_supply_set_property(psy, prop, &val);
}

/* True only while the attached source advertises a PPS APDO. */
static bool sm5440_pps_source(struct sm5440_direct *sm)
{
	int t = sm5440_psy_get(sm->tcpm, POWER_SUPPLY_PROP_USB_TYPE);

	return t == POWER_SUPPLY_USB_TYPE_PD_PPS ||
	       t == POWER_SUPPLY_USB_TYPE_PD_PPS_SPR_AVS;
}

static int sm5440_pps_op_curr(void)
{
	return clamp_t(int, pps_op_curr_ma, SM5440_PPS_OP_CURR_MIN_MA,
		       SM5440_PPS_OP_CURR_MAX_MA);
}

/*
 * What to ask for in the Request at a given bus voltage: the knob, but never
 * below the current the 15 W PD floor needs there, rounded to the 50 mA a PPS
 * message can express.
 */
static int sm5440_request_ma(int target_mv)
{
	int floor_ma = DIV_ROUND_UP(DIV_ROUND_UP(15000000, target_mv), 50) * 50;

	return max(sm5440_pps_op_curr(), floor_ma);
}

/*
 * A 2:1 pump needs twice the pack plus enough to cover the cable/switch drop.
 * Both move while charging, so this is computed every tick, not remembered.
 */
static int sm5440_target_mv(int battery_uv)
{
	int mv = DIV_ROUND_UP((battery_uv / 1000) * 2 +
			      SM5440_INITIAL_HEADROOM_MV, 20) * 20;

	return clamp(mv, 8200, 10500);
}

/* Step-table index for a pack voltage in mV (pack climbs -> table descends). */
static int sm5440_step_index(int vpack_mv)
{
	int i;

	for (i = 0; i < SM5440_NR_STEPS - 1; i++)
		if (vpack_mv < sm5440_step_vpack_mv[i])
			break;
	return i;
}

/* Pump input current the loop aims for at a step (or the pinned knob). */
static int sm5440_target_ibus(int step)
{
	if (target_ibus_ma)
		return clamp_t(int, target_ibus_ma, SM5440_TARGET_IBUS_MIN_MA,
			       SM5440_TARGET_IBUS_MAX_MA);
	return sm5440_step_ibus_ma[step];
}

/* Program the pump's hardware input-current limit a margin above the aim. */
static int sm5440_program_ibus(struct sm5440_direct *sm, int step)
{
	int ma = min(sm5440_target_ibus(step) + SM5440_IBUS_CLAMP_MARGIN_MA,
		     SM5440_IBUS_CLAMP_MAX_MA);

	return i2c_smbus_write_byte_data(sm->client, SM5440_REG_IBUSCNTL,
					ma / 50);
}

/* Switching frequency for the current thermals (stock SIOP derate shape). */
static int sm5440_pick_freq_khz(int die_dc, int pack_dc)
{
	if (die_dc >= SM5440_DIE_DERATE_DC2)
		return SM5440_FREQUENCY_SIOP2_KHZ;
	if (die_dc >= SM5440_DIE_DERATE_DC1 || pack_dc >= SM5440_PACK_DERATE_DC)
		return SM5440_FREQUENCY_SIOP1_KHZ;
	return SM5440_FREQUENCY_KHZ;
}

static int sm5440_program_freq(struct sm5440_direct *sm, int khz)
{
	int ret = i2c_smbus_write_byte_data(sm->client, SM5440_REG_CNTL7,
					   (khz - 250) / 50);
	if (!ret)
		sm->freq_khz = khz;
	return ret;
}

static int sm5440_request_pps(struct sm5440_direct *sm, int mv, int ma)
{
	int ret;

	ret = sm5440_psy_set(sm->tcpm, POWER_SUPPLY_PROP_ONLINE, 2);
	if (ret)
		return ret;
	ret = sm5440_psy_set(sm->tcpm, POWER_SUPPLY_PROP_CURRENT_NOW,
			      ma * 1000);
	if (ret)
		goto fixed;
	ret = sm5440_psy_set(sm->tcpm, POWER_SUPPLY_PROP_VOLTAGE_NOW,
			      mv * 1000);
	if (!ret)
		return 0;

fixed:
	sm5440_psy_set(sm->tcpm, POWER_SUPPLY_PROP_ONLINE, 1);
	return ret;
}

static int sm5440_refresh_pps(struct sm5440_direct *sm)
{
	int ret;

	ret = sm5440_psy_set(sm->tcpm, POWER_SUPPLY_PROP_CURRENT_NOW,
			     sm->target_ma * 1000);
	if (ret)
		return ret;

	return sm5440_psy_set(sm->tcpm, POWER_SUPPLY_PROP_VOLTAGE_NOW,
			      sm->target_mv * 1000);
}

static void sm5440_restore_switching(struct sm5440_direct *sm)
{
	sm5440_update_bits(sm, SM5440_REG_CNTL5,
			   SM5440_CNTL5_OP_MODE_MASK, 0);
	sm5440_update_bits(sm, SM5440_REG_ADCCNTL1,
			   SM5440_ADCCNTL1_ENABLE, 0);
	sm5440_update_bits(sm, SM5440_REG_CNTL1,
			   SM5440_CNTL1_WDT_EN, 0);
	sm5440_psy_set(sm->tcpm, POWER_SUPPLY_PROP_ONLINE, 1);
	sm5714_battery_set_direct_charge(false);
	sm->pps_ticks = 0;
	sm->cv_ticks = 0;
	sm->active = false;
}

static void sm5440_put_power_supply(void *data)
{
	power_supply_put(data);
}

static int sm5440_hw_init(struct sm5440_direct *sm)
{
	int reg;
	int ret;
	int i;

	ret = i2c_smbus_write_byte_data(sm->client, SM5440_REG_CNTL1,
					 SM5440_CNTL1_SW_RESET);
	if (ret)
		return ret;
	for (i = 0; i < 255; i++) {
		usleep_range(1000, 2000);
		reg = i2c_smbus_read_byte_data(sm->client, SM5440_REG_CNTL1);
		if (reg < 0)
			return reg;
		if (!(reg & SM5440_CNTL1_SW_RESET))
			break;
	}
	if (i == 255)
		return -ETIMEDOUT;

#define SM5440_WRITE(_reg, _val) do {					\
	ret = i2c_smbus_write_byte_data(sm->client, (_reg), (_val));	\
	if (ret)							\
		return ret;						\
} while (0)

	SM5440_WRITE(SM5440_REG_CNTL1, SM5440_CNTL1_WDT_30S);
	SM5440_WRITE(SM5440_REG_CNTL2, 0xf2);
	SM5440_WRITE(SM5440_REG_CNTL3, 0xb8);
	SM5440_WRITE(SM5440_REG_CNTL4, 0xff);
	SM5440_WRITE(SM5440_REG_CNTL6, 0x09);
	SM5440_WRITE(SM5440_REG_CNTL7,
		     (SM5440_FREQUENCY_KHZ - 250) / 50);
	SM5440_WRITE(SM5440_REG_VBUSCNTL, 0x07);
	SM5440_WRITE(SM5440_REG_VBATCNTL,
		     ((SM5440_VBATREG_MV - 3800) * 10) / 125);
	SM5440_WRITE(SM5440_REG_VOUTCNTL, 0x3f);
	/*
	 * Bring the hardware input-current limit up at the lowest step's value;
	 * sm5440_start() raises it to the actual starting step right after this,
	 * and sm5440_work() tracks it per step.  Starting low means a glitch
	 * during bring-up cannot over-draw.
	 */
	SM5440_WRITE(SM5440_REG_IBUSCNTL,
		     sm5440_step_ibus_ma[SM5440_NR_STEPS - 1] / 50);
	SM5440_WRITE(SM5440_REG_PRTNCNTL, 0xfe);
	SM5440_WRITE(SM5440_REG_THEMCNTL1, 0x0c);
	SM5440_WRITE(SM5440_REG_ADCCNTL1,
		     SM5440_ADCCNTL1_AVG_32 |
		     SM5440_ADCCNTL1_CONTINUOUS |
		     SM5440_ADCCNTL1_ENABLE);
	SM5440_WRITE(SM5440_REG_ADCCNTL2, 0xdf);
#undef SM5440_WRITE

	/* Reading the four interrupt latches clears stale bootloader events. */
	for (i = 0; i < 4; i++) {
		ret = i2c_smbus_read_byte_data(sm->client, i);
		if (ret < 0)
			return ret;
	}

	return 0;
}

static int sm5440_start(struct sm5440_direct *sm)
{
	int battery_uv, target_mv, target_ma, step;
	int vbus_mv;
	int status3;
	int ret;
	int i;

	battery_uv = sm5440_psy_get(sm->battery,
				    POWER_SUPPLY_PROP_VOLTAGE_NOW);
	if (battery_uv < 0)
		return battery_uv;
	if (battery_uv < SM5440_DCHG_MIN_VBAT_MV * 1000) {
		dev_dbg(sm->dev, "pack too low for direct charge: %d uV\n",
			battery_uv);
		return -EAGAIN;
	}

	step = sm5440_step_index(battery_uv / 1000);
	target_mv = sm5440_target_mv(battery_uv);
	target_ma = sm5440_request_ma(target_mv);

	/*
	 * Open the SM5714 switching path while VBUS is still at its safe fixed
	 * 9 V contract.  Only then may the direct charger request >9 V PPS.
	 */
	ret = sm5714_battery_set_direct_charge(true);
	if (ret)
		return ret;

	ret = sm5440_hw_init(sm);
	if (ret)
		goto restore;
	sm->freq_khz = SM5440_FREQUENCY_KHZ;

	/* Raise the hardware input limit from hw_init's floor to this step. */
	ret = sm5440_program_ibus(sm, step);
	if (ret)
		goto restore;

	ret = sm5440_request_pps(sm, target_mv, target_ma);
	if (ret)
		goto restore;

	/*
	 * A PPS power_supply write completes before the adapter has necessarily
	 * reached the requested voltage.  Starting the 2:1 pump during that ramp
	 * loaded the still-9-V bus, made it collapse and latched REVBLK.  Let the
	 * SM5440 ADC prove that the physical bus is ready before enabling CHG_ON.
	 * The gate is 700 mV shy of target (was 500): the step profile asks for
	 * proportionally more headroom, so the bus lands lower relative to the
	 * request before it has actually settled.
	 */
	for (i = 0; i < 40; i++) {
		msleep(100);
		vbus_mv = sm5440_adc_vbus_mv(sm);
		if (vbus_mv < 0) {
			ret = vbus_mv;
			goto restore;
		}
		if (vbus_mv >= target_mv - 700)
			break;
	}
	if (i == 40) {
		dev_warn(sm->dev,
			 "PPS bus did not settle: target=%dmV measured=%dmV\n",
			 target_mv, vbus_mv);
		ret = -ETIMEDOUT;
		goto restore;
	}

	ret = sm5440_update_bits(sm, SM5440_REG_CNTL5,
				 SM5440_CNTL5_OP_MODE_MASK,
				 SM5440_CNTL5_CHG_ON);
	if (ret)
		goto restore;
	ret = sm5440_update_bits(sm, SM5440_REG_CNTL1,
				 SM5440_CNTL1_WDT_EN,
				 SM5440_CNTL1_WDT_EN);
	if (ret)
		goto restore;

	msleep(100);
	status3 = i2c_smbus_read_byte_data(sm->client, SM5440_REG_STATUS3);
	if (status3 < 0) {
		ret = status3;
		goto restore;
	}
	if (!(status3 & SM5440_STATUS3_VBUSPOK)) {
		ret = -ENOLINK;
		goto restore;
	}

	sm->active = true;
	sm->step = step;
	sm->target_mv = target_mv;
	sm->target_ma = target_ma;
	sm->pps_ticks = 0;
	sm->cv_ticks = 0;
	dev_info(sm->dev,
		 "direct charge started: step %d, PPS %d mV/%d mA (aim %d mA in / %d mA pack)\n",
		 step, target_mv, target_ma,
		 sm5440_target_ibus(step), sm5440_step_ibat_ma[step]);
	return 0;

restore:
	sm5440_restore_switching(sm);
	return ret;
}

static bool sm5440_eligible(struct sm5440_direct *sm)
{
	int capacity, online, temp, voltage;

	online = sm5440_psy_get(sm->tcpm, POWER_SUPPLY_PROP_ONLINE);
	capacity = sm5440_psy_get(sm->battery, POWER_SUPPLY_PROP_CAPACITY);
	temp = sm5440_psy_get(sm->battery, POWER_SUPPLY_PROP_TEMP);
	voltage = sm5440_psy_get(sm->battery, POWER_SUPPLY_PROP_VOLTAGE_NOW);

	/*
	 * Gate entry on the source actually advertising PPS.  TCPM sets
	 * usb_type PD_PPS only from a source APDO, and that same flag is what
	 * makes tcpm_pps_activate() return -EOPNOTSUPP (-95).  Without this the
	 * driver retried a PPS hand-off against every plain DCP / fixed-PD
	 * brick every 30 s, forever.
	 */
	return online > 0 && sm5440_pps_source(sm) &&
	       capacity >= 5 && capacity < 90 &&
	       temp >= 100 && temp < 420 &&
	       voltage >= 3500000 && voltage < 4350000;
}

static void sm5440_work(struct work_struct *work)
{
	struct sm5440_direct *sm =
		container_of(to_delayed_work(work), struct sm5440_direct, work);
	unsigned long delay = msecs_to_jiffies(SM5440_POLL_MS);
	int capacity, die_temp, ibus, op_mode, pack_temp, status3;
	int vbat, vbus, want, step, tibus, floor_mv, ceil_mv, freq_khz;
	bool cv_handoff = false;
	int ret;

	/*
	 * Suspend keepalive tail: the alarm callback set this and woke the
	 * system; the freezable workqueue only thaws once every bus is back, so
	 * this runs with I2C and the PD path fully alive.  Pet the pump's
	 * watchdog, bail out to the switching charger if the pack or die has
	 * drifted over a (stricter, asleep) limit, then renew the PPS Request
	 * so the programmable contract survives the next sleep window.
	 */
	if (sm->keepalive_pending) {
		sm->keepalive_pending = false;
		if (sm->active) {
			int pk = sm5440_psy_get(sm->battery, POWER_SUPPLY_PROP_TEMP);
			int dt = sm5440_adc_die_temp(sm);

			sm5440_update_bits(sm, SM5440_REG_CNTL1,
					   SM5440_CNTL1_WDT_EN,
					   SM5440_CNTL1_WDT_EN);

			if (pk >= SM5440_PACK_STOP_DC ||
			    dt >= SM5440_DIE_DERATE_DC1) {
				dev_warn(sm->dev,
					 "keepalive: over-limit asleep (pack=%d die=%d) -- handing back\n",
					 pk, dt);
				sm5440_restore_switching(sm);
			} else if (sm5440_refresh_pps(sm)) {
				dev_warn(sm->dev,
					 "keepalive: PPS refresh failed -- handing back\n");
				sm5440_restore_switching(sm);
			}
		}
		if (sm->ws)
			__pm_relax(sm->ws);
	}

	if (!sm->active) {
		if (!sm5440_eligible(sm)) {
			delay = msecs_to_jiffies(SM5440_RETRY_MS);
			goto out;
		}
		ret = sm5440_start(sm);
		if (ret) {
			if (ret != -EAGAIN)
				dev_warn(sm->dev,
					 "direct-charge start failed: %d\n", ret);
			delay = msecs_to_jiffies(SM5440_RETRY_MS);
		}
		goto out;
	}

	capacity = sm5440_psy_get(sm->battery, POWER_SUPPLY_PROP_CAPACITY);
	pack_temp = sm5440_psy_get(sm->battery, POWER_SUPPLY_PROP_TEMP);
	want = sm5440_psy_get(sm->battery, POWER_SUPPLY_PROP_VOLTAGE_NOW);
	op_mode = i2c_smbus_read_byte_data(sm->client, SM5440_REG_CNTL5);
	status3 = i2c_smbus_read_byte_data(sm->client, SM5440_REG_STATUS3);
	vbus = sm5440_adc_vbus_mv(sm);
	ibus = sm5440_adc_ibus_ma(sm);
	vbat = sm5440_adc_vbat_mv(sm);
	die_temp = sm5440_adc_die_temp(sm);

	if (capacity < 0 || pack_temp < 0 || want < 0 || op_mode < 0 ||
	    status3 < 0 || vbus < 0 || ibus < 0 || vbat < 0 || die_temp < 0 ||
	    capacity >= 90 || pack_temp >= SM5440_PACK_STOP_DC ||
	    !(op_mode & SM5440_CNTL5_CHG_ON) ||
	    !(status3 & SM5440_STATUS3_VBUSPOK) ||
	    vbus > 10800 || vbat > 4450 || die_temp >= SM5440_DIE_STOP_DC) {
		/*
		 * The part clears CHG_ON on its own and latches the reason in
		 * the interrupt registers.  Read the four latches here (they
		 * clear on read) so a stop at zero current and a stop at a
		 * couple of amps -- REVBLK is INT3/0x02 bit 1 -- can be told
		 * apart from the log instead of guessed at.
		 */
		int int1, int2, int3, int4, status1;

		int1 = i2c_smbus_read_byte_data(sm->client, 0x00);
		int2 = i2c_smbus_read_byte_data(sm->client, 0x01);
		int3 = i2c_smbus_read_byte_data(sm->client, 0x02);
		int4 = i2c_smbus_read_byte_data(sm->client, 0x03);
		status1 = i2c_smbus_read_byte_data(sm->client, SM5440_REG_STATUS1);

		dev_warn(sm->dev,
			 "stopping direct charge: cap=%d temp=%d mode=%#x "
			 "st1=%#x st3=%#x int=%#x/%#x/%#x/%#x "
			 "vbus=%d ibus=%d vbat=%d die=%d\n",
			 capacity, pack_temp, op_mode, status1, status3,
			 int1, int2, int3, int4, vbus, ibus, vbat, die_temp);
		sm5440_restore_switching(sm);
		delay = msecs_to_jiffies(SM5440_RETRY_MS);
		goto out;
	}

	/*
	 * Clean CV hand-off (not a fault): once the pack is within a hair of
	 * the float ceiling, or the pump input has tapered below half the
	 * stock dchg_min_current for three ticks running, stop the pump and
	 * let sm5714_battery finish the CV tail on the switching charger.  The
	 * eligibility check keeps it from restarting until the pack drops back.
	 */
	if (vbat >= SM5440_CV_HANDOFF_MV || want >= SM5440_CV_HANDOFF_MV * 1000)
		cv_handoff = true;
	if (ibus * 2 < SM5440_MIN_IBAT_MA) {
		if (++sm->cv_ticks >= 3)
			cv_handoff = true;
	} else {
		sm->cv_ticks = 0;
	}
	if (cv_handoff) {
		dev_info(sm->dev,
			 "direct charge -> CV hand-off: vbat=%dmV ibus=%dmA cap=%d\n",
			 vbat, ibus, capacity);
		sm5440_restore_switching(sm);
		delay = msecs_to_jiffies(SM5440_RETRY_MS);
		goto out;
	}

	/* Thermal frequency derate (stock SIOP shape), applied only on change. */
	freq_khz = sm5440_pick_freq_khz(die_temp, pack_temp);
	if (freq_khz != sm->freq_khz) {
		dev_info(sm->dev, "freq %d -> %d kHz (die=%d.%dC pack=%d.%dC)\n",
			 sm->freq_khz, freq_khz,
			 die_temp / 10, abs(die_temp % 10),
			 pack_temp / 10, abs(pack_temp % 10));
		sm5440_program_freq(sm, freq_khz);
	}

	/* Step-table walk: pick the step for the current pack voltage. */
	step = sm5440_step_index(want / 1000);
	if (step != sm->step) {
		dev_info(sm->dev,
			 "step %d -> %d at vbat=%dmV (aim %d mA in / %d mA pack)\n",
			 sm->step, step, want / 1000,
			 sm5440_target_ibus(step), sm5440_step_ibat_ma[step]);
		ret = sm5440_program_ibus(sm, step);
		if (ret) {
			sm5440_restore_switching(sm);
			delay = msecs_to_jiffies(SM5440_RETRY_MS);
			goto out;
		}
		sm->step = step;
	}

	/*
	 * Closed loop: aim the PPS voltage at the step's target input current.
	 * The chip's VBUS ADC disagrees with the adapter by hundreds of mV and
	 * the gap grows as current falls, so it cannot be corrected with a
	 * constant -- regulate on the current reading, which needs no such
	 * trust, and let the voltage find its own level.  The floor still
	 * tracks the pack (twice it plus the REVBLK headroom); the ceiling is
	 * twice the pack plus SM5440_MAX_HEADROOM_MV, hard-capped at 10.5 V.
	 */
	tibus = sm5440_target_ibus(step);
	floor_mv = sm5440_target_mv(want);
	ceil_mv = min((want / 1000) * 2 + SM5440_MAX_HEADROOM_MV, 10500);

	if (ibus < tibus - SM5440_IBUS_TOLERANCE_MA)
		sm->target_mv += SM5440_VSTEP_MV;
	else if (ibus > tibus + SM5440_IBUS_TOLERANCE_MA)
		sm->target_mv -= SM5440_VSTEP_MV;
	sm->target_mv = clamp(sm->target_mv, floor_mv, ceil_mv);
	sm->target_ma = sm5440_request_ma(sm->target_mv);

	/*
	 * Re-send the Request periodically or the source drops the programmable
	 * contract: the EP-T4510 fell back after ~5 s without a refresh and the
	 * VBUS step tripped REVBLK.  Every other tick (~2 s) is enough awake.
	 */
	if (++sm->pps_ticks >= 2) {
		sm->pps_ticks = 0;
		ret = sm5440_refresh_pps(sm);
		if (ret) {
			dev_warn(sm->dev, "failed to refresh PPS: %d\n", ret);
			sm5440_restore_switching(sm);
			delay = msecs_to_jiffies(SM5440_RETRY_MS);
			goto out;
		}
	}

	/* Rewriting CNTL1 services the hardware watchdog. */
	ret = sm5440_update_bits(sm, SM5440_REG_CNTL1,
				 SM5440_CNTL1_WDT_EN,
				 SM5440_CNTL1_WDT_EN);
	if (ret) {
		sm5440_restore_switching(sm);
		delay = msecs_to_jiffies(SM5440_RETRY_MS);
		goto out;
	}

	if (verbose)
		dev_info(sm->dev,
			 "tick: step=%d req=%dmV/%dmA aim=%dmA | vbus=%dmV "
			 "ibus=%dmA vbat=%dmV pack=%d.%dC die=%d.%dC\n",
			 step, sm->target_mv, sm->target_ma, tibus,
			 vbus, ibus, vbat,
			 pack_temp / 10, abs(pack_temp % 10),
			 die_temp / 10, abs(die_temp % 10));
	else
		dev_info_ratelimited(sm->dev,
				     "direct: pack=%d.%dC vbus=%dmV ibus=%dmA "
				     "vbat=%dmV die=%d.%dC\n",
				     pack_temp / 10, abs(pack_temp % 10),
				     vbus, ibus, vbat,
				     die_temp / 10, abs(die_temp % 10));
out:
	/*
	 * system_freezable_wq, not the plain system_wq: this work talks I2C
	 * over a GPI-DMA bus that suspends, and system suspend freezes this
	 * queue between .suspend and thaw -- so the poll simply does not run in
	 * that window (which is what used to fault with "Transfer while
	 * suspended" and collapse the PD contract to 5 V DCP).
	 */
	queue_delayed_work(system_freezable_wq, &sm->work, delay);
}

static void sm5440_keepalive_fire(struct alarm *a, ktime_t now)
{
	struct sm5440_direct *sm =
		container_of(a, struct sm5440_direct, keepalive_alarm);

	/*
	 * Runs in soft-irq context -- no sleeping.  Hold the wakeup source so
	 * the just-delivered RTC wake is not treated as spurious and the
	 * system does not descend straight back into suspend before the
	 * freezable work has had its post-thaw tick; sm5440_work() drops it.
	 */
	sm->keepalive_pending = true;
	if (sm->ws)
		__pm_stay_awake(sm->ws);
	queue_delayed_work(system_freezable_wq, &sm->work, 0);
}

static void sm5440_cancel_work(void *data)
{
	struct sm5440_direct *sm = data;

	alarm_cancel(&sm->keepalive_alarm);
	cancel_delayed_work_sync(&sm->work);
	if (sm->active)
		sm5440_restore_switching(sm);
}

static void sm5440_free_wakeup_source(void *data)
{
	wakeup_source_unregister(data);
}

static int sm5440_probe(struct i2c_client *client)
{
	struct sm5440_direct *sm;
	int id;
	int ret;

	if (!i2c_check_functionality(client->adapter,
				     I2C_FUNC_SMBUS_BYTE_DATA))
		return -EOPNOTSUPP;

	sm = devm_kzalloc(&client->dev, sizeof(*sm), GFP_KERNEL);
	if (!sm)
		return -ENOMEM;
	sm->dev = &client->dev;
	sm->client = client;
	i2c_set_clientdata(client, sm);

	id = i2c_smbus_read_byte_data(client, SM5440_REG_DEVICEID);
	if (id < 0)
		return dev_err_probe(sm->dev, id, "cannot read device ID\n");
	if ((id & 0x0f) != 1)
		return dev_err_probe(sm->dev, -ENODEV,
				     "unexpected device ID %#x\n", id);

	sm->tcpm = devm_power_supply_get_by_reference(sm->dev,
						      "tcpm-power-supply");
	if (IS_ERR(sm->tcpm))
		return dev_err_probe(sm->dev, PTR_ERR(sm->tcpm),
				     "cannot get TCPM power supply\n");
	if (!sm->tcpm)
		return dev_err_probe(sm->dev, -EPROBE_DEFER,
				     "TCPM power supply is not ready\n");

	sm->battery = power_supply_get_by_name("sm5714-battery");
	if (!sm->battery)
		return dev_err_probe(sm->dev, -EPROBE_DEFER,
				     "battery power supply is not ready\n");
	ret = devm_add_action_or_reset(sm->dev, sm5440_put_power_supply,
				       sm->battery);
	if (ret)
		return ret;

	/*
	 * Suspend keepalive: an ALARM_BOOTTIME alarm wakes the system every
	 * few seconds so the poll work can re-Request the PPS APDO, which the
	 * source otherwise drops within ~10 s of the sink going quiet in
	 * s2ram.  It only works if a wake-capable RTC is registered
	 * (CONFIG_RTC_DRV_PM8XXX=y for this SoC); without one, .suspend falls
	 * back to handing the pack to the switching charger for the sleep.
	 */
	sm->keepalive_capable = !!alarmtimer_get_rtcdev();
	alarm_init(&sm->keepalive_alarm, ALARM_BOOTTIME, sm5440_keepalive_fire);
	device_init_wakeup(sm->dev, true);
	sm->ws = wakeup_source_register(sm->dev, "sm5440-keepalive");
	if (sm->ws) {
		ret = devm_add_action_or_reset(sm->dev,
					       sm5440_free_wakeup_source, sm->ws);
		if (ret)
			return ret;
	}

	INIT_DELAYED_WORK(&sm->work, sm5440_work);
	ret = devm_add_action_or_reset(sm->dev, sm5440_cancel_work, sm);
	if (ret)
		return ret;
	queue_delayed_work(system_freezable_wq, &sm->work,
			   msecs_to_jiffies(10000));

	dev_info(sm->dev,
		 "SM5440 direct charger device ID %#x (suspend keepalive %s)\n",
		 id, sm->keepalive_capable ? "armed" : "unavailable, no wake RTC");
	return 0;
}

static int sm5440_suspend(struct device *dev)
{
	struct sm5440_direct *sm = dev_get_drvdata(dev);

	if (!sm->active)
		return 0;

	if (!sm->keepalive_capable) {
		/*
		 * No wake-capable RTC: do the mainline-normal thing and hand
		 * the pack back to the switching charger for the sleep.  The
		 * normal eligibility check picks direct charge back up on
		 * resume.
		 */
		sm5440_restore_switching(sm);
		return 0;
	}

	/*
	 * Keep direct charge running across the sleep.  Pet the watchdog so
	 * the pump survives the gap to the first wake, then arm the alarm; the
	 * alarmtimer core programs the soonest expiry into the RTC as the
	 * system goes down, and sm5440_work()'s keepalive tail renews the
	 * APDO after each wake.  A missed wake is self-limiting: WDT_30S
	 * disables the pump within 30 s and the next real resume restores the
	 * switching charger.
	 */
	sm5440_update_bits(sm, SM5440_REG_CNTL1, SM5440_CNTL1_WDT_EN,
			   SM5440_CNTL1_WDT_EN);
	alarm_start_timer(&sm->keepalive_alarm,
			  ktime_set(SM5440_KEEPALIVE_SEC, 0), true);
	return 0;
}

static int sm5440_resume(struct device *dev)
{
	struct sm5440_direct *sm = dev_get_drvdata(dev);

	alarm_cancel(&sm->keepalive_alarm);
	queue_delayed_work(system_freezable_wq, &sm->work, 0);
	return 0;
}

static DEFINE_SIMPLE_DEV_PM_OPS(sm5440_pm_ops, sm5440_suspend, sm5440_resume);

static const struct of_device_id sm5440_of_match[] = {
	{ .compatible = "siliconmitus,sm5440" },
	{ }
};
MODULE_DEVICE_TABLE(of, sm5440_of_match);

static struct i2c_driver sm5440_driver = {
	.driver = {
		.name = "sm5440-direct",
		.of_match_table = sm5440_of_match,
		.pm = pm_sleep_ptr(&sm5440_pm_ops),
	},
	.probe = sm5440_probe,
};
module_i2c_driver(sm5440_driver);

MODULE_DESCRIPTION("Silicon Mitus SM5440 direct charger for Samsung SM-X716B");
MODULE_LICENSE("GPL");
