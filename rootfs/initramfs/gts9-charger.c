// SPDX-License-Identifier: MIT
/*
 * gts9-charger: the off-mode charging screen, run from the initramfs when the
 * tablet is powered on by plugging in a charger rather than by the power key.
 *
 * It draws a battery gauge on /dev/fb0, keeps the panel dark most of the time
 * (the panel is the biggest load on the board; a dark idle tablet charges even
 * from a 500 mA USB port), and either
 *   - exits 0 when the user holds the power key: /init then carries on with the
 *     normal boot, or
 *   - powers the tablet off once the charger has been unplugged for a few
 *     seconds.
 * Exit 1 means "could not run" (no framebuffer, ...): /init boots normally, so
 * a broken charger screen can never keep the tablet from starting.
 *
 * Static, no libraries beyond libc.  Build: scripts/build-real-root-initramfs.sh.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/reboot.h>
#include <time.h>
#include <unistd.h>

#define PS_DIR		"/sys/class/power_supply"
#define BL_DIR		"/sys/class/backlight"
#define HOLD_MS		1500	/* power-key hold that means "boot now" */
#ifndef SCREEN_MS
#define SCREEN_MS	30000	/* how long the screen stays lit after a key */
#endif
#define UNPLUG_MS	6000	/* charger absent this long -> power off */
#define MIN_BOOT_PCT	3	/* refuse to start the full boot below this */

/*
 * Minimal %s / %d / %% formatter.  libc snprintf drags in the long-double
 * printing code, which needs soft-float runtime symbols this static build
 * does not have.
 */
static void sfmt(char *out, size_t len, const char *fmt, ...)
{
	va_list ap;
	size_t n = 0;

	va_start(ap, fmt);
	for (; *fmt && n + 1 < len; fmt++) {
		if (*fmt != '%') {
			out[n++] = *fmt;
			continue;
		}
		fmt++;
		if (*fmt == 's') {
			const char *s = va_arg(ap, const char *);

			while (*s && n + 1 < len)
				out[n++] = *s++;
		} else if (*fmt == 'd') {
			char tmp[12];
			int v = va_arg(ap, int), i = 0;
			unsigned int u = v < 0 ? -(unsigned int)v : (unsigned int)v;

			do
				tmp[i++] = '0' + u % 10;
			while ((u /= 10) && i < 11);
			if (v < 0 && n + 1 < len)
				out[n++] = '-';
			while (i && n + 1 < len)
				out[n++] = tmp[--i];
		} else if (*fmt == '%') {
			out[n++] = '%';
		} else {
			break;
		}
	}
	va_end(ap);
	out[n] = 0;
}

static uint8_t *fb;
static struct fb_var_screeninfo vi;
static struct fb_fix_screeninfo fi;
static int fbfd;
static char bl_path[256];
static int bl_max = 1;

static long now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static int read_int(const char *path, int def)
{
	char buf[64];
	ssize_t n;
	int fd = open(path, O_RDONLY);

	if (fd < 0)
		return def;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return def;
	buf[n] = 0;
	return atoi(buf);
}

static void read_str(const char *path, char *out, size_t len)
{
	ssize_t n;
	int fd = open(path, O_RDONLY);

	out[0] = 0;
	if (fd < 0)
		return;
	n = read(fd, out, len - 1);
	close(fd);
	if (n < 0)
		n = 0;
	out[n] = 0;
	out[strcspn(out, "\n")] = 0;
}

static void write_int(const char *path, int v)
{
	char buf[16];
	int fd = open(path, O_WRONLY);

	if (fd < 0)
		return;
	sfmt(buf, sizeof(buf), "%d", v);
	if (write(fd, buf, strlen(buf)) < 0)
		;
	close(fd);
}

/* Any power supply of type USB/Mains that reports online counts as a charger. */
static int charger_online(void)
{
	DIR *d = opendir(PS_DIR);
	struct dirent *e;
	int online = 0;

	if (!d)
		return 1;	/* unknown: never power off on a guess */
	while ((e = readdir(d))) {
		char p[300], type[32];

		if (e->d_name[0] == '.')
			continue;
		sfmt(p, sizeof(p), PS_DIR "/%s/type", e->d_name);
		read_str(p, type, sizeof(type));
		if (strcmp(type, "USB") && strcmp(type, "Mains") &&
		    strcmp(type, "USB_PD") && strcmp(type, "USB_DCP"))
			continue;
		sfmt(p, sizeof(p), PS_DIR "/%s/online", e->d_name);
		if (read_int(p, 0) > 0)
			online = 1;
	}
	closedir(d);
	return online;
}

static int battery_path(char *out, size_t len, const char *attr)
{
	DIR *d = opendir(PS_DIR);
	struct dirent *e;
	int found = 0;

	if (!d)
		return 0;
	while ((e = readdir(d))) {
		char p[300], type[32];

		if (e->d_name[0] == '.')
			continue;
		sfmt(p, sizeof(p), PS_DIR "/%s/type", e->d_name);
		read_str(p, type, sizeof(type));
		if (strcmp(type, "Battery"))
			continue;
		sfmt(out, len, PS_DIR "/%s/%s", e->d_name, attr);
		found = 1;
		break;
	}
	closedir(d);
	return found;
}

static void find_backlight(void)
{
	DIR *d = opendir(BL_DIR);
	struct dirent *e;

	if (!d)
		return;
	while ((e = readdir(d))) {
		char p[300];

		if (e->d_name[0] == '.')
			continue;
		sfmt(bl_path, sizeof(bl_path), BL_DIR "/%s/brightness",
			 e->d_name);
		sfmt(p, sizeof(p), BL_DIR "/%s/max_brightness", e->d_name);
		bl_max = read_int(p, 1);
		break;
	}
	closedir(d);
}

static void screen(int on)
{
	if (bl_path[0])
		write_int(bl_path, on ? bl_max / 5 : 0);
	/* FB_BLANK_POWERDOWN takes the panel itself down, not just the light. */
	ioctl(fbfd, FBIOBLANK, on ? FB_BLANK_UNBLANK : FB_BLANK_POWERDOWN);
}

static void fill(int x, int y, int w, int h, uint32_t rgb)
{
	int bpp = vi.bits_per_pixel / 8;
	int yy, xx;

	if (x < 0) { w += x; x = 0; }
	if (y < 0) { h += y; y = 0; }
	if (x + w > (int)vi.xres) w = vi.xres - x;
	if (y + h > (int)vi.yres) h = vi.yres - y;
	for (yy = y; yy < y + h; yy++) {
		uint8_t *row = fb + (size_t)(yy + vi.yoffset) * fi.line_length +
			       (size_t)x * bpp;

		for (xx = 0; xx < w; xx++) {
			if (bpp == 4) {
				((uint32_t *)row)[xx] = rgb;
			} else if (bpp == 2) {
				((uint16_t *)row)[xx] =
					((rgb >> 8) & 0xf800) |
					((rgb >> 5) & 0x07e0) |
					((rgb >> 3) & 0x001f);
			}
		}
	}
}

/* 5x7 glyphs, one 5-bit row per byte, MSB = leftmost column. */
struct glyph { char c; uint8_t r[7]; };
static const struct glyph font[] = {
	{'0', {0x0e, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0e}},
	{'1', {0x04, 0x0c, 0x04, 0x04, 0x04, 0x04, 0x0e}},
	{'2', {0x0e, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1f}},
	{'3', {0x1f, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0e}},
	{'4', {0x02, 0x06, 0x0a, 0x12, 0x1f, 0x02, 0x02}},
	{'5', {0x1f, 0x10, 0x1e, 0x01, 0x01, 0x11, 0x0e}},
	{'6', {0x06, 0x08, 0x10, 0x1e, 0x11, 0x11, 0x0e}},
	{'7', {0x1f, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08}},
	{'8', {0x0e, 0x11, 0x11, 0x0e, 0x11, 0x11, 0x0e}},
	{'9', {0x0e, 0x11, 0x11, 0x0f, 0x01, 0x02, 0x0c}},
	{'%', {0x18, 0x19, 0x02, 0x04, 0x08, 0x13, 0x03}},
	{'A', {0x0e, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11}},
	{'C', {0x0e, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0e}},
	{'D', {0x1e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1e}},
	{'E', {0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x1f}},
	{'F', {0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x10}},
	{'G', {0x0e, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0f}},
	{'H', {0x11, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11}},
	{'I', {0x0e, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0e}},
	{'L', {0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1f}},
	{'N', {0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11}},
	{'O', {0x0e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e}},
	{'P', {0x1e, 0x11, 0x11, 0x1e, 0x10, 0x10, 0x10}},
	{'R', {0x1e, 0x11, 0x11, 0x1e, 0x14, 0x12, 0x11}},
	{'S', {0x0f, 0x10, 0x10, 0x0e, 0x01, 0x01, 0x1e}},
	{'T', {0x1f, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04}},
	{'U', {0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e}},
	{'W', {0x11, 0x11, 0x11, 0x15, 0x15, 0x1b, 0x11}},
};

static void text(int x, int y, int scale, uint32_t rgb, const char *s)
{
	for (; *s; s++, x += 6 * scale) {
		size_t i;

		for (i = 0; i < sizeof(font) / sizeof(font[0]); i++) {
			int r, c;

			if (font[i].c != *s)
				continue;
			for (r = 0; r < 7; r++)
				for (c = 0; c < 5; c++)
					if (font[i].r[r] & (0x10 >> c))
						fill(x + c * scale,
						     y + r * scale, scale,
						     scale, rgb);
		}
	}
}

static int text_w(int scale, const char *s)
{
	return (int)strlen(s) * 6 * scale - scale;
}

/*
 * The panel is OLED: every lit pixel costs power, so the screen is small,
 * dim and mostly black.  Elements are stacked with fixed gaps (no absolute
 * positions), so nothing can overlap whichever way the framebuffer is turned.
 */
static void draw(int pct, const char *status, int full, int hint)
{
	static const char *hint_txt = "HOLD POWER TO START";
	char num[8], msg[32];
	int u = (vi.xres < vi.yres ? vi.xres : vi.yres) / 100;	/* base unit */
	int ns = u > 1 ? u : 1;				/* percentage scale */
	int ms = u / 2 > 1 ? u / 2 : 1;			/* status scale */
	int hs = u / 3 > 1 ? u / 3 : 1;			/* hint scale */
	int bw = u * 12, bh = u * 6, t = u > 2 ? u / 2 : 1;
	int gap = u * 2;
	int total = bh + gap + 7 * ns + gap + 7 * ms + (hint ? gap + 7 * hs : 0);
	int cx = (int)vi.xres / 2, y = ((int)vi.yres - total) / 2;
	int bx = cx - bw / 2, fillw;
	uint32_t col = full || pct > 15 ? 0x1c7a3c : 0x9a2a2a;

	fill(0, 0, vi.xres, vi.yres, 0x000000);
	/* body outline, terminal nub, and the level fill */
	fill(bx, y, bw, t, 0x707070);
	fill(bx, y + bh - t, bw, t, 0x707070);
	fill(bx, y, t, bh, 0x707070);
	fill(bx + bw - t, y, t, bh, 0x707070);
	fill(bx + bw, y + bh / 3, t * 2, bh / 3, 0x707070);
	fillw = (bw - 4 * t) * (pct < 0 ? 0 : pct > 100 ? 100 : pct) / 100;
	fill(bx + 2 * t, y + 2 * t, fillw, bh - 4 * t, col);
	y += bh + gap;

	sfmt(num, sizeof(num), "%d%%", pct);
	text(cx - text_w(ns, num) / 2, y, ns, 0x909090, num);
	y += 7 * ns + gap;

	sfmt(msg, sizeof(msg), "%s", full ? "FULL" : status);
	text(cx - text_w(ms, msg) / 2, y, ms, 0x606060, msg);
	y += 7 * ms + gap;

	if (hint)
		text(cx - text_w(hs, hint_txt) / 2, y, hs, 0x484848, hint_txt);
}

/*
 * Input devices appear as their drivers probe, and the PMIC power-key driver
 * can come up after this program starts, so keep trying the missing
 * /dev/input/eventN nodes instead of scanning once.
 */
#define MAX_INPUTS 32
static int input_fd[MAX_INPUTS];

static void scan_inputs(void)
{
	int i;

	for (i = 0; i < MAX_INPUTS; i++) {
		char p[32];

		if (input_fd[i] >= 0)
			continue;
		sfmt(p, sizeof(p), "/dev/input/event%d", i);
		input_fd[i] = open(p, O_RDONLY | O_NONBLOCK);
	}
}

/*
 * Progress trail for a screen nobody can see the console of: each step is
 * appended to the log file /init passes in and synced, so if the tablet hangs
 * the last line says how far it got.
 */
static const char *log_path;

static void tlog(const char *a, int v)
{
	char line[96];
	int fd;

	if (!log_path)
		return;
	sfmt(line, sizeof(line), "charger: t=%d %s %d\n", (int)(now_ms() % 1000000), a, v);
	fd = open(log_path, O_WRONLY | O_APPEND | O_CREAT, 0644);
	if (fd < 0)
		return;
	if (write(fd, line, strlen(line)) < 0)
		;
	fsync(fd);
	close(fd);
}

int main(int argc, char **argv)
{
	char cap_path[300] = "", st_path[300] = "";
	long last_key = now_ms(), press_at = 0, unplug_at = 0, last_scan = 0;
	int lit = 1, last_pct = -2, last_full = -1, last_lit = -1, tries, i;
	char last_status[32] = "";

	for (i = 0; i < MAX_INPUTS; i++)
		input_fd[i] = -1;

	for (tries = 0; tries < 100; tries++) {	/* panel probe is async */
		fbfd = open("/dev/fb0", O_RDWR);
		if (fbfd >= 0)
			break;
		usleep(100000);
	}
	if (fbfd < 0 || ioctl(fbfd, FBIOGET_VSCREENINFO, &vi) ||
	    ioctl(fbfd, FBIOGET_FSCREENINFO, &fi))
		return 1;
	if (vi.bits_per_pixel != 32 && vi.bits_per_pixel != 16)
		return 1;
	fb = mmap(NULL, fi.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED, fbfd, 0);
	if (fb == MAP_FAILED)
		return 1;

	if (argc > 1)
		log_path = argv[1];
	tlog("fb xres", (int)vi.xres);
	tlog("fb yres", (int)vi.yres);
	tlog("fb bpp", (int)vi.bits_per_pixel);
	tlog("fb smem_len", (int)fi.smem_len);
	find_backlight();
	battery_path(cap_path, sizeof(cap_path), "capacity");
	battery_path(st_path, sizeof(st_path), "status");
	tlog("screen on", 1);
	screen(1);
	tlog("screen on done", 1);

	for (;;) {
		struct pollfd pfd[MAX_INPUTS];
		int n = 0, map[MAX_INPUTS], pct, full;
		char status[32];
		long t = now_ms();

		if (t - last_scan >= 1000) {
			scan_inputs();
			last_scan = t;
		}
		for (i = 0; i < MAX_INPUTS; i++) {
			if (input_fd[i] < 0)
				continue;
			pfd[n].fd = input_fd[i];
			pfd[n].events = POLLIN;
			map[n++] = i;
		}
		if (n)
			poll(pfd, n, 100);
		else
			usleep(500000);

		for (i = 0; i < n; i++) {
			struct input_event ev;
			ssize_t r;

			while ((r = read(input_fd[map[i]], &ev, sizeof(ev))) ==
			       sizeof(ev)) {
				if (ev.type != EV_KEY || ev.value > 1)
					continue;
				/* Volume and power keys wake the screen; only a held
				 * power key starts the boot. */
				if (ev.code != KEY_POWER && ev.code != KEY_VOLUMEUP &&
				    ev.code != KEY_VOLUMEDOWN)
					continue;
				tlog("key", ev.code * 10 + ev.value);
				if (ev.value == 1) {
					last_key = now_ms();
					if (!lit) {
						lit = 1;
					}
					if (ev.code == KEY_POWER)
						press_at = last_key;
				} else if (ev.code == KEY_POWER) {
					press_at = 0;
					last_key = now_ms();
				}
			}
			/* A device that went away (ENODEV) is dropped and re-found. */
			if (r < 0 && errno == ENODEV) {
				close(input_fd[map[i]]);
				input_fd[map[i]] = -1;
			}
		}

		t = now_ms();
		pct = cap_path[0] ? read_int(cap_path, 0) : 0;
		read_str(st_path, status, sizeof(status));
		full = pct >= 100 || !strcmp(status, "Full");

		/* Held long enough while lit: hand over to the normal boot. */
		if (press_at && lit && t - press_at >= HOLD_MS &&
		    pct >= MIN_BOOT_PCT) {
			tlog("hold: continue boot", pct);
			screen(1);
			return 0;
		}

		if (!charger_online()) {
			if (!unplug_at)
				unplug_at = t;
			if (t - unplug_at >= UNPLUG_MS) {
				sync();
				tlog("unplugged: power off", 0);
				reboot(RB_POWER_OFF);
			}
		} else {
			unplug_at = 0;
		}

		if (lit && t - last_key >= SCREEN_MS)
			lit = 0;
		/*
		 * Redraw before the panel is switched on, so the gauge is already in
		 * the framebuffer when the light comes up instead of appearing a
		 * moment later; the panel content may be gone after a blank, so a
		 * wake always redraws.
		 */
		if (lit && (lit != last_lit || pct != last_pct || full != last_full ||
			    strcmp(status, last_status))) {
			tlog("draw pct", pct);
			draw(pct, !strcmp(status, "Charging") ? "CHARGING" :
			     "NOT CHARGING", full, 1);
			last_pct = pct;
			last_full = full;
			sfmt(last_status, sizeof(last_status), "%s", status);
			tlog("draw done", pct);
		}
		if (lit != last_lit) {
			tlog("screen", lit);
			screen(lit);
			tlog("screen done", lit);
			last_lit = lit;
		}
	}
}
