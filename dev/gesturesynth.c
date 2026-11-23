// Emit synthetic multi-finger gestures on the uinput touchpad created by uitp.
// Usage: ./tg <swipe3|swipe4|swipe4-left|swipe4-up|pinch|hold> [count]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <math.h>
#include <time.h>

#define MAX_X 1805
#define MAX_Y 1292
#define NSLOT 5

static int fd;

static void emit(int type, int code, int value) {
	struct input_event ie;
	memset(&ie, 0, sizeof(ie));
	ie.type = type;
	ie.code = code;
	ie.value = value;
	if (write(fd, &ie, sizeof(ie)) < 0)
		perror("write");
}

static void syn(void) { emit(EV_SYN, SYN_REPORT, 0); }

static void nap(long us) { usleep(us); }

static void down(int slot, int x, int y, int tid) {
	emit(EV_ABS, ABS_MT_SLOT, slot);
	emit(EV_ABS, ABS_MT_TRACKING_ID, tid);
	emit(EV_ABS, ABS_MT_POSITION_X, x);
	emit(EV_ABS, ABS_MT_POSITION_Y, y);
	emit(EV_ABS, ABS_MT_TOUCH_MAJOR, 8);
	emit(EV_ABS, ABS_MT_PRESSURE, 30);
	emit(EV_ABS, ABS_X, x);
	emit(EV_ABS, ABS_Y, y);
	emit(EV_ABS, ABS_PRESSURE, 30);
	emit(EV_KEY, BTN_TOUCH, 1);
}

static void move(int slot, int x, int y) {
	emit(EV_ABS, ABS_MT_SLOT, slot);
	emit(EV_ABS, ABS_MT_POSITION_X, x);
	emit(EV_ABS, ABS_MT_POSITION_Y, y);
	emit(EV_ABS, ABS_MT_TOUCH_MAJOR, 8);
	emit(EV_ABS, ABS_MT_PRESSURE, 30);
	emit(EV_ABS, ABS_X, x);
	emit(EV_ABS, ABS_Y, y);
	emit(EV_ABS, ABS_PRESSURE, 30);
}

static void up(int slot) {
	emit(EV_ABS, ABS_MT_SLOT, slot);
	emit(EV_ABS, ABS_MT_TRACKING_ID, -1);
}

static void lift_all(int n) {
	for (int i = 0; i < n; i++)
		up(i);
	emit(EV_KEY, BTN_TOUCH, 0);
	syn();
}

static void do_swipe(int fingers, int dx, int dy, int steps, long dt_us) {
	int ys[5];
	for (int i = 0; i < fingers; i++)
		ys[i] = MAX_Y * (50 + (i - (fingers - 1) / 2.0) * 18) / 100;
	for (int i = 0; i < fingers; i++)
		down(i, MAX_X * 50 / 100, ys[i], 100 + i);
	syn();
	nap(30000);
	for (int s = 1; s <= steps; s++) {
		for (int i = 0; i < fingers; i++)
			move(i, MAX_X * 50 / 100 + dx * s / steps,
			     ys[i] + dy * s / steps);
		syn();
		nap(dt_us);
	}
	lift_all(fingers);
}

/* A true PINCH requires the FIRST TWO touches to move in OPPOSITE
 * directions (libinput tp_gesture_same_directions()). A radial "all fingers
 * outward" motion is seen as a SWIPE. So: 2 fingers placed apart on the X
 * axis, sliding away from each other, and any extra fingers held still in
 * between (libinput only looks at touches[0] and touches[1]).
 *
 * Also note libinput requires >40mm horizontal (or >7mm vertical) separation
 * from the initial points within DEFAULT_GESTURE_SWIPE_TIMEOUT (150ms)
 * before it will not just call it a scroll/swipe. */
static void do_pinch(int fingers, double scale, int steps, long dt_us) {
	int y = MAX_Y / 2;
	int half = MAX_X * 0.30;          /* 30mm from centre at 19 res/mm */
	/* fingers 0 and 1 do the pinch; 2..n stay put */
	down(0, MAX_X / 2 - half, y, 200);
	down(1, MAX_X / 2 + half, y, 201);
	for (int i = 2; i < fingers; i++)
		down(i, MAX_X / 2 + (i - 2) * 60, MAX_Y / 2 + 200, 200 + i);
	syn();
	nap(20000);
	for (int s = 1; s <= steps; s++) {
		double f = 1.0 + (scale - 1.0) * s / steps;
		int d = (int)(half * f);
		/* move fast enough to beat the 150ms swipe timeout */
		move(0, MAX_X / 2 - d, y);
		move(1, MAX_X / 2 + d, y);
		syn();
		nap(dt_us);
	}
	lift_all(fingers);
}

static void do_hold(int fingers, long secs_us) {
	for (int i = 0; i < fingers; i++)
		down(i, MAX_X * 50 / 100, MAX_Y * (40 + 20 * i) / 100, 300 + i);
	syn();
	nap(secs_us);
	lift_all(fingers);
}

static void run_gesture(const char *cmd) {
	if (!strcmp(cmd, "swipe3"))         do_swipe(3,  400, 0, 24, 8000);
	else if (!strcmp(cmd, "swipe3-left"))  do_swipe(3, -400, 0, 24, 8000);
	else if (!strcmp(cmd, "swipe3-up"))    do_swipe(3, 0, -400, 24, 8000);
	else if (!strcmp(cmd, "swipe3-down"))  do_swipe(3, 0,  400, 24, 8000);
	else if (!strcmp(cmd, "swipe4"))       do_swipe(4,  400, 0, 24, 8000);
	else if (!strcmp(cmd, "swipe4-left"))  do_swipe(4, -400, 0, 24, 8000);
	else if (!strcmp(cmd, "swipe4-up"))    do_swipe(4, 0, -400, 24, 8000);
	else if (!strcmp(cmd, "swipe4-down"))  do_swipe(4, 0,  400, 24, 8000);
	else if (!strcmp(cmd, "pinch-in3"))    do_pinch(3, 0.55, 24, 8000);
	else if (!strcmp(cmd, "pinch-out3"))   do_pinch(3, 1.8, 24, 8000);
	else if (!strcmp(cmd, "pinch-in4"))    do_pinch(4, 0.55, 24, 8000);
	else if (!strcmp(cmd, "pinch-out4"))   do_pinch(4, 1.8, 24, 8000);
	else if (!strcmp(cmd, "hold3"))       do_hold(3, 700000);
	else fprintf(stderr, "unknown cmd %s\n", cmd);
}

int main(int argc, char **argv) {
	const char *cmd = argc > 1 ? argv[1] : "swipe4";
	int count = argc > 2 ? atoi(argv[2]) : 1;

	fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
	if (fd < 0) { perror("open"); return 1; }

	/* Attach to the already-created device by writing to its event node is
	 * not possible; instead we create our own identical device here. */
	if (ioctl(fd, UI_SET_EVBIT, EV_SYN) < 0) { perror("EV_SYN"); return 1; }
	ioctl(fd, UI_SET_EVBIT, EV_KEY);
	ioctl(fd, UI_SET_KEYBIT, BTN_LEFT);
	ioctl(fd, UI_SET_KEYBIT, BTN_TOUCH);
	ioctl(fd, UI_SET_KEYBIT, BTN_TOOL_FINGER);
	ioctl(fd, UI_SET_EVBIT, EV_ABS);
	int axes[] = { ABS_X, ABS_Y, ABS_PRESSURE, ABS_MT_SLOT,
		       ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID,
		       ABS_MT_TOUCH_MAJOR, ABS_MT_PRESSURE };
	int mn[9] = { 0,0,0,0,0,0,0,0,0 };
	int mx[9] = { MAX_X, MAX_Y, 255, NSLOT-1, MAX_X, MAX_Y, 65535, 255, 255 };
	int rs[9] = { 19,19,0,0,19,19,0,0,0 };
	for (int i = 0; i < 9; i++)
		ioctl(fd, UI_SET_ABSBIT, axes[i]);
	ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_BUTTONPAD);
	for (int i = 0; i < 9; i++) {
		struct uinput_abs_setup a;
		memset(&a, 0, sizeof(a));
		a.code = (unsigned short)axes[i];
		a.absinfo.minimum = mn[i];
		a.absinfo.maximum = mx[i];
		a.absinfo.resolution = rs[i];
		ioctl(fd, UI_ABS_SETUP, &a);
	}
	struct uinput_setup us;
	memset(&us, 0, sizeof(us));
	snprintf(us.name, sizeof(us.name), "NyxGestureSynthesizer: 0000:0000 Touchpad");
	us.id.bustype = BUS_VIRTUAL;
	ioctl(fd, UI_DEV_SETUP, &us);
	if (ioctl(fd, UI_DEV_CREATE) < 0) { perror("UI_DEV_CREATE"); return 1; }
	sleep(1);
	fprintf(stderr, "READY\n");

	/* "serve" keeps the device alive and executes one gesture per line of
	 * stdin. This exists because the device is destroyed on exit: without it
	 * there is no window in which an external process can attach and take an
	 * exclusive EVIOCGRAB on the node, which is what makes observing gestures
	 * safe - while a grabber holds the device, GNOME's own libinput context
	 * cannot read it, so nothing reaches the live desktop. */
	if (!strcmp(cmd, "serve")) {
		char line[64];
		while (fgets(line, sizeof(line), stdin)) {
			if (!strncmp(line, "quit", 4))
				break;
			char *nl = strchr(line, '\n');
			if (nl) *nl = 0;
			if (line[0] == 0)
				continue;
			fprintf(stderr, "GO %s\n", line);
			run_gesture(line);
			fprintf(stderr, "DONE %s\n", line);
			nap(400000);
		}
		ioctl(fd, UI_DEV_DESTROY);
		close(fd);
		return 0;
	}

	for (int c = 0; c < count; c++) {
		run_gesture(cmd);
		nap(500000);
	}
	ioctl(fd, UI_DEV_DESTROY);
	close(fd);
	return 0;
}
