#!/usr/bin/env python3
"""Patch the Quest 1 kernel tree so kgdb can talk over a USB gadget serial port.

Run with the kernel tree as the working directory. Idempotent: every file is
keyed off a KGDB_USB marker and skipped once applied.

This is the Quest 1 (monterey, MSM8998, kernel 4.4) port of the transport
originally written for Quest 3 (eureka, kernel 5.10) in
q3_build/kgdb/apply-kgdb-usb-transport.py. The design is unchanged; see that
file for the full rationale. WHAT DIFFERS ON THIS DEVICE is called out under
"QUEST 1 DELTAS" below, and every ported hunk carries the 4.4 detail that
made it different.

WHY NOT kgdboc
--------------
kgdboc only accepts a tty whose ops provide poll_get_char/poll_put_char, and
drivers/usb/gadget/function/u_serial.c implements neither - nothing under
drivers/usb/gadget/ does - so "echo ttyGS0 > /sys/module/kgdboc/parameters/
kgdboc" can only ever fail.

But kgdboc is only one implementation of struct kgdb_io. kgdb itself needs
neither it, nor a tty, nor CONSOLE_POLL: kgdb_register_io_module() is
exported with plain CONFIG_KGDB=y and wants nothing but a read_char/
write_char pair (kernel/debug/debug_core.c:982 - ->init is optional). sysrq-g
is registered by debug_core itself in kgdb_register_callbacks()
(debug_core.c:910), gated only on CONFIG_MAGIC_SYSRQ, which is already =y.

So this registers a kgdb_io module that drives the gadget's bulk endpoints
directly.

THE REAL PROBLEM: COMPLETION WITH INTERRUPTS OFF
------------------------------------------------
kgdb runs with every other CPU stopped and interrupts disabled, so the dwc3
hardirq -> kthread-worker path that normally completes a usb_request never
runs, and a queued transfer would hang forever. So we add a polled completion
path to dwc3.

THE LOCK RULE (the part that took longest to get right on Quest 3)
------------------------------------------------------------------
kgdb stops every other CPU, any of which may hold dwc->lock.

  * Waiting for it deadlocks - and the SoC watchdog then resets the headset,
    which looks exactly like "the kernel crashed".
  * Skipping it because "everything is stopped, nothing can race" is WRONG:
    if a stopped CPU holds it, mutating dwc3 state corrupts the critical
    section it resumes into. On Quest 3 the measured symptom was brutal -
    halting looked perfect for minutes, then after resume adbd stayed alive
    while every "adb shell" hung forever, because ffs.adb's endpoints had
    been pulled out from under the holder.

The rule is therefore: ALWAYS HOLD THE LOCK, NEVER WAIT FOR IT.
spin_trylock_irqsave() in kgdb context; if it fails, a stopped CPU owns it,
so do nothing and let the debugger time out. Losing a session beats
corrupting the kernel you are trying to debug. Because the lock is then
genuinely held, dwc3_gadget_giveback() needs no special case - its normal
drop/retake around the completion callback is correct as it stands, which is
why this patch does not touch it.

Two designs that were tried on Quest 3 and are wrong (do not revisit):
completing only our own endpoint without draining the event ring kills USB
(nothing answers the host, the device leaves the bus in seconds); draining
the ring but deferring other functions' completions connects and holds but
still wedges, because the lock was always the real cause.

QUEST 1 DELTAS vs the Quest 3 patch
-----------------------------------
1. NO VENDOR-MODULE KABI CONSTRAINT. Quest 3 boots ~270 prebuilt vendor
   modules with CONFIG_MODVERSIONS=y, so adding a member to any struct
   reachable from an exported symbol silently breaks boot. Quest 1 loads NO
   modules at all - `lsmod` is empty and /vendor/lib/modules does not exist -
   so that entire class of failure is absent here and config changes are
   cheap. The standalone usb_gadget_ep_poll_fn pointer is kept anyway: it is
   what is already debugged, and keeping the two trees' patches aligned is
   worth more than saving an indirection.

2. FILE LAYOUT. 4.4 has drivers/usb/gadget/udc/udc-core.c, not udc/core.c.

3. EVENT BUFFERS ARE AN ARRAY. 5.10 has a single dwc->ev_buf and helpers
   taking (struct dwc3_event_buffer *evt). 4.4 has dwc->ev_buffs[] with
   dwc->num_normal_event_buffers, and the helpers take (struct dwc3 *dwc,
   u32 buf) - so the polled completer loops over the buffers the way
   dwc3_interrupt()/dwc3_thread_interrupt() do.

4. NO FORWARD DECLARATIONS NEEDED. On 5.10 the poll function had to be
   placed above the event-buffer helpers and forward-declare them. In this
   tree it is inserted immediately after dwc3_check_event_buf() and before
   dwc3_interrupt(), so both helpers are already defined, and it is still
   above dwc3_gadget_init() which installs it.

5. dwc3_gadget_ep_queue() TAKES THE LOCK AT FUNCTION ENTRY. On 5.10 the lock
   wraps only the __dwc3_gadget_ep_queue() call. Here it is taken on the
   first line and every exit path leaves through the "out:" label, so the
   trylock replaces the entry acquisition rather than an inner one.

6. NO_POLL_CHAR is unconditional in this tree's include/linux/serial_core.h
   (line 97), not gated behind CONFIG_CONSOLE_POLL, so including it costs
   nothing.

7. THE WATCHDOG IS A CMDLINE TOKEN. On Quest 3, qcom_wdt_core is a prebuilt
   module whose disable_wdt param is 0444, which needed an extra cpio
   segment appended to the boot ramdisk. Here the watchdog is builtin
   (CONFIG_QCOM_WATCHDOG_V2=y, drivers/soc/qcom/watchdog_v2.c) and its own
   comment documents the interface: "On the kernel command line specify
   watchdog_v2.enable=1 to enable the watchdog". So a long halt just needs
   watchdog_v2.enable=0 in the boot.img cmdline - build.sh does this when
   KGDB_DISABLE_WDT=1.

KNOWN LIMITS (read before trusting a session)
---------------------------------------------
* Breaking in from inside dwc3 itself is not safe.
* The chosen port must not be in use by userspace at the same time. kgdb and
  a getty on the same ttyGS will corrupt each other.
* TX is buffered and flushed per gdb packet (kgdb_io.flush), so a packet
  costs one bulk transfer rather than one per byte.
"""

import sys

MARKER = "KGDB_USB"


def patch(path, edits, marker=MARKER):
    with open(path) as f:
        s = f.read()
    if marker in s:
        print(f"  {path}: already patched, skipping")
        return
    for old, new in edits:
        n = s.count(old)
        if n != 1:
            sys.exit(f"ERROR: {path}: anchor not unique (found {n}):\n{old[:200]}")
        s = s.replace(old, new)
    with open(path, "w") as f:
        f.write(s)
    print(f"  {path}: patched")


# --- 1. gadget.h: the hook's declaration ----------------------------------

GADGET_H = "include/linux/usb/gadget.h"

gadget_h_old = """/**
 * usb_gadget_frame_number - returns the current frame number
 * @gadget: controller that reports the frame number"""

gadget_h_new = """/*
 * KGDB_USB: hook used to complete one endpoint's transfers with interrupts
 * off.
 *
 * A standalone exported pointer rather than a member of struct
 * usb_gadget_ops. Quest 1 loads no modules, so unlike Quest 3 there is no
 * CRC/KABI reason it has to be - but it costs nothing, and it keeps this
 * patch line-for-line comparable with the Quest 3 one.
 *
 * Installed by the UDC driver (dwc3 does it in dwc3_gadget_init()).
 */
extern void (*usb_gadget_ep_poll_fn)(struct usb_ep *ep);


/**
 * usb_gadget_ep_poll - complete finished transfers on one endpoint
 * @ep: the endpoint whose controller should be serviced
 *
 * KGDB_USB: called from kgdb's polled I/O path, where the CPU is stopped and
 * the hardirq/kthread handlers that normally complete a usb_request will
 * never run. No-op if the UDC installed no hook (its requests simply never
 * complete there, and the caller times out).
 */
static inline void usb_gadget_ep_poll(struct usb_ep *ep)
{
	void (*fn)(struct usb_ep *) = READ_ONCE(usb_gadget_ep_poll_fn);

	if (ep && fn)
		fn(ep);
}

/**
 * usb_gadget_frame_number - returns the current frame number
 * @gadget: controller that reports the frame number"""

# --- 1b. udc-core.c: the hook's definition --------------------------------
# 4.4 names this file udc-core.c (5.10: udc/core.c). It is builtin whenever
# CONFIG_USB_GADGET=y, so both the UDC that installs the hook and the gadget
# function that calls it always have something to link against.

UDC_CORE_C = "drivers/usb/gadget/udc/udc-core.c"

udc_old = """static int __init usb_udc_init(void)"""

udc_new = """/* KGDB_USB: see usb_gadget_ep_poll() in <linux/usb/gadget.h>. */
void (*usb_gadget_ep_poll_fn)(struct usb_ep *ep);
EXPORT_SYMBOL_GPL(usb_gadget_ep_poll_fn);

static int __init usb_udc_init(void)"""

# --- 2. dwc3 --------------------------------------------------------------

DWC3_C = "drivers/usb/dwc3/gadget.c"

dwc3_old_inc = """#include <linux/usb/ch9.h>
#include <linux/usb/composite.h>
#include <linux/usb/gadget.h>
"""

dwc3_new_inc = """#include <linux/usb/ch9.h>
#include <linux/usb/composite.h>
#include <linux/usb/gadget.h>
#include <linux/kgdb.h>	/* KGDB_USB: in_dbg_master() */
"""

# 4.4 takes dwc->lock on the first line of dwc3_gadget_ep_queue() and every
# exit path leaves through "out:", so the trylock replaces that acquisition.
# (On 5.10 the lock wrapped only the __dwc3_gadget_ep_queue() call.)
dwc3_old_queue = """	unsigned long			flags;
	int				ret;

	spin_lock_irqsave(&dwc->lock, flags);
	if (!dep->endpoint.desc) {
"""

dwc3_new_queue = """	unsigned long			flags;
	int				ret;

#ifdef CONFIG_KGDB
	/*
	 * KGDB_USB: with the machine stopped, dwc->lock may be held by a CPU
	 * kgdb has already rounded up - blocking on it would hang forever and
	 * the SoC watchdog would then reset the headset. But skipping it
	 * outright corrupts that CPU's critical section. Try for it; if a
	 * stopped CPU owns it, fail the submission and let the debugger cope.
	 * Every exit below unlocks via "out:", so this is the only
	 * acquisition that needs the treatment.
	 */
	if (in_dbg_master()) {
		if (!spin_trylock_irqsave(&dwc->lock, flags))
			return -EAGAIN;
	} else {
		spin_lock_irqsave(&dwc->lock, flags);
	}
#else
	spin_lock_irqsave(&dwc->lock, flags);
#endif
	if (!dep->endpoint.desc) {
"""

# Inserted after dwc3_check_event_buf() and before dwc3_interrupt(): both
# event-buffer helpers are already defined at this point (no forward
# declarations needed, unlike the 5.10 patch), and this is still above
# dwc3_gadget_init(), which installs the hook.
dwc3_old_poll = """irqreturn_t dwc3_interrupt(int irq, void *_dwc)
{
"""

dwc3_new_poll = """#ifdef CONFIG_KGDB
/**
 * dwc3_gadget_ep_poll - service the controller while the machine is stopped
 * @ep: the debugger's endpoint. Only used to find the controller: the whole
 *      event ring is drained, because the controller has to stay alive on
 *      the bus.
 *
 * KGDB_USB: with every CPU stopped there is no interrupt to complete a
 * usb_request, so the debugger's transport calls this to make progress.
 *
 * It drains the entire event ring on purpose. Servicing only our own
 * endpoint was tried on Quest 3 and fails: nothing then answers the host,
 * the device falls off the bus within seconds and gdb cannot even connect.
 *
 * This mirrors what dwc3_interrupt() + dwc3_thread_interrupt() do between
 * them - check each buffer, then process it - except that both halves run
 * here, inline, under one lock acquisition. dwc3_check_event_buf() takes no
 * locks of its own, and dwc3_process_event_buf() expects dwc->lock held,
 * which is exactly the state it is called in from the kthread worker.
 */
static void dwc3_gadget_ep_poll(struct usb_ep *ep)
{
	struct dwc3_ep *dep;
	struct dwc3 *dwc;
	unsigned long flags;
	int i;

	if (!ep)
		return;

	dep = to_dwc3_ep(ep);
	if (!dep || !dep->dwc)
		return;

	dwc = dep->dwc;

	/*
	 * A runtime-suspended controller has its clocks gated; touching
	 * GEVNTCOUNT would fault or read garbage, and resuming needs to
	 * sleep, which is not allowed here. Give up quietly.
	 */
	if (pm_runtime_suspended(dwc->dev))
		return;

	/*
	 * ALWAYS hold dwc->lock, even in kgdb - but never wait for it there.
	 * See "THE LOCK RULE" at the top of apply-kgdb-usb-transport.py: a
	 * stopped CPU may own it, and mutating dwc3 state behind its back
	 * corrupts the critical section it resumes into. With the machine
	 * stopped a free lock cannot be contended, so trylock either succeeds
	 * (safe) or tells us to do nothing.
	 */
	if (in_dbg_master()) {
		if (!spin_trylock_irqsave(&dwc->lock, flags))
			return;
	} else {
		spin_lock_irqsave(&dwc->lock, flags);
	}

	for (i = 0; i < dwc->num_normal_event_buffers; i++) {
		dwc3_check_event_buf(dwc, i);
		dwc3_process_event_buf(dwc, i);
	}

	spin_unlock_irqrestore(&dwc->lock, flags);
}
#endif /* CONFIG_KGDB */

irqreturn_t dwc3_interrupt(int irq, void *_dwc)
{
"""

dwc3_old_init = """int dwc3_gadget_init(struct dwc3 *dwc)
{
	int					ret;

	INIT_WORK(&dwc->wakeup_work, dwc3_gadget_wakeup_work);
"""

dwc3_new_init = """int dwc3_gadget_init(struct dwc3 *dwc)
{
	int					ret;

#ifdef CONFIG_KGDB
	/*
	 * KGDB_USB: publish the polled completion hook for kgdb's transport.
	 * Logged because if this never runs, kgdb has no way to complete a USB
	 * transfer with interrupts off, and the link dies the moment the
	 * debugger stops the CPUs - which is indistinguishable from a dozen
	 * other failures unless you can see this line.
	 */
	usb_gadget_ep_poll_fn = dwc3_gadget_ep_poll;
	pr_info("KGDB_USB: dwc3 installed usb_gadget_ep_poll_fn\\n");
#endif

	INIT_WORK(&dwc->wakeup_work, dwc3_gadget_wakeup_work);
"""

# --- 3. u_serial: includes ------------------------------------------------
# 4.4's u_serial.c has no <linux/kfifo.h> (the 5.10 anchor), so this hangs
# off <linux/workqueue.h>, the last include before "u_serial.h".

USERIAL_C = "drivers/usb/gadget/function/u_serial.c"

userial_old_includes = """#include <linux/workqueue.h>
"""

userial_new_includes = """#include <linux/workqueue.h>
#ifdef CONFIG_KGDB
/* KGDB_USB: kgdb_register_io_module()/struct kgdb_io, usb_gadget_ep_poll()
 * and NO_POLL_CHAR (unconditional in this tree's serial_core.h, not gated
 * behind CONFIG_CONSOLE_POLL). */
#include <linux/kgdb.h>
#include <linux/serial_core.h>
#include <linux/usb/gadget.h>
#endif
"""

# --- 4. u_serial: the transport, inserted just before userial_init --------

userial_old_body = """static int userial_init(void)"""

userial_new_body = r'''#ifdef CONFIG_KGDB

/*
 * KGDB_USB: a struct kgdb_io transport over a USB gadget serial port.
 *
 * Runs with the CPU stopped and interrupts off, so it cannot wait on a
 * completion or rely on the dwc3 irq path. Each transfer is queued on the
 * function's bulk endpoint and then driven to completion by hand via
 * usb_gadget_ep_poll().
 *
 * Uses its own requests rather than the port's read/write pools so a
 * break-in cannot consume or reorder buffers the tty layer still owns.
 */

/* Which ttyGS port to attach to; -1 (the default) disables the transport
 * entirely, so a KGDB=y kernel behaves exactly like a stock one until you
 * ask for it. Must be a port userspace is NOT also using.
 *
 * Settable at runtime rather than cmdline-only, because the gadget function
 * this attaches to is composed from configfs after boot: at userial_init()
 * time there is usually no port to attach to yet.
 */
static int kgdb_port = -1;

static struct kgdb_usb {
	struct usb_request	*in_req;
	struct usb_request	*out_req;
	bool			in_busy;
	bool			out_busy;
	unsigned int		out_avail;
	unsigned int		out_pos;
	unsigned int		tx_len;
	bool			registered;
} kgdb_usb;

static void kgdb_usb_complete(struct usb_ep *ep, struct usb_request *req)
{
	*(bool *)req->context = false;
}

static struct gserial *kgdb_usb_gser(void)
{
	struct gs_port *port;

	if (kgdb_port < 0 || kgdb_port >= MAX_U_SERIAL_PORTS)
		return NULL;
	port = ports[kgdb_port].port;
	if (!port)
		return NULL;
	/* Only usable while the function is bound and the cable is up. */
	if (!port->port_usb || !port->port_usb->in || !port->port_usb->out)
		return NULL;
	return port->port_usb;
}

/*
 * Allocate the two dedicated requests on first use rather than at init:
 * kgdb is usually configured long before the endpoints are enabled.
 */
static int kgdb_usb_setup(struct gserial *gser)
{
	if (!kgdb_usb.in_req) {
		kgdb_usb.in_req = gs_alloc_req(gser->in, gser->in->maxpacket,
					       GFP_ATOMIC);
		if (!kgdb_usb.in_req)
			return -ENOMEM;
		kgdb_usb.in_req->complete = kgdb_usb_complete;
		kgdb_usb.in_req->context = &kgdb_usb.in_busy;
	}
	if (!kgdb_usb.out_req) {
		kgdb_usb.out_req = gs_alloc_req(gser->out,
						gser->out->maxpacket,
						GFP_ATOMIC);
		if (!kgdb_usb.out_req)
			return -ENOMEM;
		kgdb_usb.out_req->complete = kgdb_usb_complete;
		kgdb_usb.out_req->context = &kgdb_usb.out_busy;
	}

	return 0;
}

/* Spin until *busy clears, servicing the controller by hand. Bounded so an
 * unplugged or wedged controller cannot hang the debugger forever. */
static int kgdb_usb_drain(struct usb_ep *ep, bool *busy, int timeout_us)
{
	while (*busy && timeout_us-- > 0) {
		usb_gadget_ep_poll(ep);
		udelay(1);
	}
	if (*busy) {
		/* Give up on this transfer rather than wedge; the request is
		 * still owned by the controller, so drop our claim on it. */
		*busy = false;
		return -ETIMEDOUT;
	}
	return 0;
}

static void kgdb_usb_flush(void)
{
	struct gserial *gser = kgdb_usb_gser();

	if (!gser || !kgdb_usb.tx_len)
		return;
	if (kgdb_usb_setup(gser))
		return;
	if (kgdb_usb.in_busy &&
	    kgdb_usb_drain(gser->in, &kgdb_usb.in_busy, 500000))
		return;

	kgdb_usb.in_req->length = kgdb_usb.tx_len;
	kgdb_usb.in_req->zero = 0;
	kgdb_usb.in_busy = true;
	kgdb_usb.tx_len = 0;

	if (usb_ep_queue(gser->in, kgdb_usb.in_req, GFP_ATOMIC)) {
		kgdb_usb.in_busy = false;
		return;
	}
	kgdb_usb_drain(gser->in, &kgdb_usb.in_busy, 500000);
}

/*
 * Buffered: kgdb emits a packet a byte at a time and then calls flush(), so
 * this costs one bulk transfer per packet instead of one per byte.
 */
static void kgdb_usb_write_char(u8 ch)
{
	struct gserial *gser = kgdb_usb_gser();

	if (!gser || kgdb_usb_setup(gser))
		return;

	((u8 *)kgdb_usb.in_req->buf)[kgdb_usb.tx_len++] = ch;
	if (kgdb_usb.tx_len >= gser->in->maxpacket)
		kgdb_usb_flush();
}

static int kgdb_usb_read_char(void)
{
	struct gserial *gser = kgdb_usb_gser();

	if (!gser || kgdb_usb_setup(gser))
		return NO_POLL_CHAR;

	/* Still handing back bytes from the last completed OUT transfer. */
	if (kgdb_usb.out_pos < kgdb_usb.out_avail)
		return ((u8 *)kgdb_usb.out_req->buf)[kgdb_usb.out_pos++];

	if (!kgdb_usb.out_busy) {
		kgdb_usb.out_avail = 0;
		kgdb_usb.out_pos = 0;
		kgdb_usb.out_req->length = gser->out->maxpacket;
		kgdb_usb.out_busy = true;
		if (usb_ep_queue(gser->out, kgdb_usb.out_req, GFP_ATOMIC)) {
			kgdb_usb.out_busy = false;
			return NO_POLL_CHAR;
		}
	}

	/*
	 * Non-blocking: gdbstub_read_wait() loops on NO_POLL_CHAR, so
	 * returning promptly when the host has sent nothing is correct and
	 * keeps the debugger responsive.
	 */
	usb_gadget_ep_poll(gser->out);
	if (kgdb_usb.out_busy)
		return NO_POLL_CHAR;

	kgdb_usb.out_avail = kgdb_usb.out_req->actual;
	kgdb_usb.out_pos = 0;
	if (!kgdb_usb.out_avail)
		return NO_POLL_CHAR;

	return ((u8 *)kgdb_usb.out_req->buf)[kgdb_usb.out_pos++];
}

static struct kgdb_io kgdb_usb_io_ops = {
	.name		= "kgdb_usb",
	.read_char	= kgdb_usb_read_char,
	.write_char	= kgdb_usb_write_char,
	.flush		= kgdb_usb_flush,
};

/*
 * Non-destructive self-test. Writing to this param exercises the whole TX
 * path - usb_ep_queue() plus the usb_gadget_ep_poll() drain - with
 * interrupts disabled on this CPU, WITHOUT stopping the machine. If the
 * bytes appear on the host's /dev/ttyACM*, the transport works.
 *
 * Caveat, so the result is not over-read: other CPUs still service the dwc3
 * interrupt, so a completion may arrive via the normal IRQ path rather than
 * via our polling. That is why the poll_fn pointer is printed too - a
 * working test with a NULL poll_fn means the polled path is still unproven
 * and a real break-in would hang.
 */
static int kgdb_usb_selftest(const char *val, const struct kernel_param *kp)
{
	struct gserial *gser = kgdb_usb_gser();
	unsigned long flags;
	int i;

	pr_info("KGDB_USB: selftest: gser=%s port_usb=%s poll_fn=%s\n",
		gser ? "ok" : "NULL",
		(gser && gser->in && gser->out) ? "ok" : "NULL",
		usb_gadget_ep_poll_fn ? "INSTALLED" : "NULL(polled I/O will hang)");

	if (!gser)
		return -ENODEV;
	if (kgdb_usb_setup(gser)) {
		pr_info("KGDB_USB: selftest: request alloc failed\n");
		return -ENOMEM;
	}

	local_irq_save(flags);
	for (i = 0; i < 8; i++)
		kgdb_usb_write_char('A' + i);
	kgdb_usb_write_char('\n');
	kgdb_usb_flush();
	local_irq_restore(flags);

	pr_info("KGDB_USB: selftest: wrote ABCDEFGH, in_busy=%d\n",
		kgdb_usb.in_busy);
	return 0;
}

static const struct kernel_param_ops kgdb_usb_selftest_ops = {
	.set = kgdb_usb_selftest,
};
module_param_cb(kgdb_selftest, &kgdb_usb_selftest_ops, NULL, 0200);
MODULE_PARM_DESC(kgdb_selftest,
		 "write anything to send a test string over the kgdb transport");

static void kgdb_usb_register(void)
{
	if (kgdb_usb.registered || kgdb_port < 0)
		return;
	if (kgdb_register_io_module(&kgdb_usb_io_ops)) {
		pr_err("kgdb_usb: failed to register kgdb I/O module\n");
		return;
	}
	kgdb_usb.registered = true;
	/* Registering is also what makes debug_core install sysrq-g, so
	 * "debug(g)" only appears in the sysrq help from here on. */
	pr_info("kgdb_usb: kgdb transport on ttyGS%d; break in with sysrq-g\n",
		kgdb_port);
	pr_info("KGDB_USB: usb_gadget_ep_poll_fn=%s at registration\n",
		usb_gadget_ep_poll_fn ? "INSTALLED" : "NULL(polled I/O will hang)");
}

static int kgdb_usb_set_port(const char *val, const struct kernel_param *kp)
{
	int ret = param_set_int(val, kp);

	if (ret)
		return ret;
	kgdb_usb_register();
	return 0;
}

static const struct kernel_param_ops kgdb_usb_port_ops = {
	.set = kgdb_usb_set_port,
	.get = param_get_int,
};
module_param_cb(kgdb_port, &kgdb_usb_port_ops, &kgdb_port, 0644);
MODULE_PARM_DESC(kgdb_port,
		 "ttyGS port index to use as the kgdb transport (-1 = off)");
#else
static inline void kgdb_usb_register(void) { }
#endif /* CONFIG_KGDB */

static int userial_init(void)'''

userial_old_reg = """	pr_debug("%s: registered %d ttyGS* device%s\\n", __func__,
			MAX_U_SERIAL_PORTS,
			(MAX_U_SERIAL_PORTS == 1) ? "" : "s");

	return status;
"""

userial_new_reg = """	pr_debug("%s: registered %d ttyGS* device%s\\n", __func__,
			MAX_U_SERIAL_PORTS,
			(MAX_U_SERIAL_PORTS == 1) ? "" : "s");

	/* KGDB_USB: no-op unless u_serial.kgdb_port was set. */
	kgdb_usb_register();

	return status;
"""


def main():
    print("Applying KGDB-over-USB transport patches (Quest 1 / 4.4):")
    patch(GADGET_H, [
        (gadget_h_old, gadget_h_new),
    ])
    patch(UDC_CORE_C, [
        (udc_old, udc_new),
    ])
    patch(DWC3_C, [
        (dwc3_old_inc, dwc3_new_inc),
        (dwc3_old_poll, dwc3_new_poll),
        (dwc3_old_init, dwc3_new_init),
        (dwc3_old_queue, dwc3_new_queue),
    ])
    patch(USERIAL_C, [
        (userial_old_includes, userial_new_includes),
        (userial_old_body, userial_new_body),
        (userial_old_reg, userial_new_reg),
    ])
    print("Done.")


if __name__ == "__main__":
    main()
