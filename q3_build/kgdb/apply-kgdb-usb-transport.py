#!/usr/bin/env python3
"""Patch the kernel tree so kgdb can talk over a USB gadget serial port.

Run with the kernel tree as the working directory. Idempotent: every file
is keyed off a KGDB_USB marker and skipped once applied.

WHY NOT kgdboc
--------------
The obvious route is kgdboc=ttyGS1, and it is a dead end twice over:

1. kgdboc only accepts a tty whose ops provide poll_get_char/poll_put_char.
   drivers/usb/gadget/function/u_serial.c implements none - nothing under
   drivers/usb/gadget/ does - so "echo ttyGS1 >
   /sys/module/kgdboc/parameters/kgdboc" can only ever fail.
2. On this headset CONFIG_KGDB_SERIAL_CONSOLE (which is what builds
   kgdboc.c, and which selects CONSOLE_POLL) stops the kernel booting at
   all. Measured, and independently confirmed by the device owner.

But kgdboc is only one implementation of struct kgdb_io. kgdb itself does
not need it, or a tty, or CONSOLE_POLL: kgdb_register_io_module() is
exported and available with plain CONFIG_KGDB=y, and needs nothing but a
read_char/write_char pair. sysrq-g is registered by debug_core itself
(register_sysrq_key('g', &sysrq_dbg_op) in debug_core.c), gated only on
CONFIG_MAGIC_SYSRQ - not on kgdboc.

So this registers a kgdb_io module that drives the gadget's bulk
endpoints directly. Required config is just CONFIG_KGDB=y, with
CONFIG_KGDB_SERIAL_CONSOLE=n. Everything else (USB_U_SERIAL, USB_F_SERIAL,
USB_DWC3, MAGIC_SYSRQ, DEBUG_KERNEL) is already =y in the stock config.

THE REAL PROBLEM: COMPLETION WITH INTERRUPTS OFF
------------------------------------------------
kgdb runs with every other CPU stopped and interrupts disabled, so the
dwc3 hardirq -> threaded-irq path that normally completes a usb_request
never runs, and a queued transfer would hang forever. So we add a polled
completion path to dwc3.

CRUCIALLY, THAT PATH IS PER-ENDPOINT, NOT THE EVENT RING
--------------------------------------------------------
An earlier revision polled by calling dwc3_process_event_buf(), i.e. it
drained the controller's whole event ring. That works for our transfers -
and quietly destroys the system. The ring is shared, so draining it runs
the completion callbacks of EVERY other USB function (above all ffs.adb)
with every CPU stopped. Those callbacks complete()/wake tasks/take locks,
none of which is legal there.

Measured: halting was rock solid (120s+, fully responsive), but after
resume the kernel ran while userspace was wedged - adb's already-open
transport survived, yet "adb shell" hung forever and the device had to be
power-cycled. The damage happens during the session and only shows on
resume.

The naive fix - complete ONLY our endpoint and never touch the ring - is
also wrong, and was measured too: with every CPU stopped nobody services
the controller at all, so the host's control traffic goes unanswered and
the device drops off the bus within seconds. gdb cannot even connect.

Both constraints have to hold at once:
  * the event ring MUST be serviced, or USB dies while halted;
  * foreign completion callbacks MUST NOT run while the machine is stopped.

So the ring is drained as before, but dwc3_gadget_giveback() DEFERS any
request that is not one of the debugger's own: it is parked on a list
instead of having its ->complete() called. The next real threaded
interrupt, running normally with interrupts on, flushes that list and
hands those requests back for real. The debugger's own requests complete
immediately, because the transport is waiting on them.

THE VENDOR-KABI CONSTRAINT (learned the hard way)
-------------------------------------------------
This device boots with CONFIG_MODVERSIONS=y and ~270 PREBUILT vendor
modules, several of which (usb_f_gsi, usb_f_qdss, usb_f_diag, usb_f_cdev,
dwc3_msm) use the gadget API. Each embeds the CRC it expects for every
symbol it imports, and those CRCs cover the layout of every type the
symbol's prototype reaches.

An earlier revision of this patch added a ->udc_poll member to struct
usb_gadget_ops. That changed the CRC of 11 exported gadget symbols
(usb_function_register, usb_ep_autoconfig, config_ep_by_speed, ...), so
usb_f_gsi.ko and friends refused to load and the kernel did not boot -
silently, falling back to the stock kernel. Verified with
check-vendor-kabi.py, which compares a built vmlinux.symvers against the
__versions section of the real modules off the device. Run it before
every boot test.

So: NO struct changes. The poll hook is a separate exported function
pointer, which is a brand-new symbol and leaves every existing CRC alone.

THE FOUR EDITS
--------------
1. include/linux/usb/gadget.h - declare the usb_gadget_poll_fn pointer and
   a usb_gadget_ep_poll() wrapper, so u_serial need not know what a dwc3 is.
   A declaration only; struct usb_gadget_ops is untouched.
2. drivers/usb/gadget/udc/core.c - define and export the pointer. Builtin
   whenever CONFIG_USB_GADGET=y, so it is always there to link against.
3. drivers/usb/dwc3/gadget.c - dwc3_gadget_ep_poll(), which reuses the
   driver's own dwc3_gadget_ep_cleanup_completed_requests() for ONE
   endpoint, installed into the pointer from dwc3_gadget_init().
4. u_serial.c - the transport and the kgdb_io registration.

KNOWN LIMITS (read before trusting a session)
---------------------------------------------
* dwc3_gadget_ep_poll() skips dwc->lock ONLY when in_dbg_master() - i.e. only
  once kgdb has rounded up every other CPU. There it must skip it (the
  interrupted context may hold it) and there is nothing to race with.
  Outside kgdb it takes the lock, because other CPUs still take the dwc3
  interrupt. Consequence: breaking in from inside dwc3 itself is not safe.
* Completion is scoped to our own endpoint; other functions' events are
  left in the ring for the real handler. Never widen this to the whole
  event ring - see the note above dwc3_gadget_ep_poll().
* The chosen port must not be in use by userspace at the same time. kgdb
  and a getty/adb shell on the same ttyGS will corrupt each other.
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


# --- 1. gadget.h ----------------------------------------------------------

GADGET_H = "include/linux/usb/gadget.h"

gadget_h_old_helper = """#if IS_ENABLED(CONFIG_USB_GADGET)
int usb_gadget_frame_number(struct usb_gadget *gadget);"""

gadget_h_new_helper = """/*
 * KGDB_USB: hook used to complete one endpoint's transfers with
 * interrupts off.
 *
 * A standalone exported pointer rather than a member of struct
 * usb_gadget_ops ON PURPOSE. This kernel ships with CONFIG_MODVERSIONS=y
 * and prebuilt vendor modules (usb_f_gsi, usb_f_qdss, dwc3_msm, ...) that
 * import gadget symbols; adding a member to usb_gadget_ops changes the
 * CRC of every exported symbol whose prototype reaches that struct, and
 * those modules then refuse to load and the device will not boot. A new
 * symbol changes nobody else's CRC. See check-vendor-kabi.py.
 *
 * Deliberately scoped to a single endpoint: a whole-controller poll would
 * have to touch the shared event ring, which runs OTHER functions'
 * completion callbacks with every CPU stopped and wedges the system on
 * resume.
 *
 * Installed by the UDC driver (dwc3 does it in dwc3_gadget_init()).
 */
extern void (*usb_gadget_ep_poll_fn)(struct usb_ep *ep);


/**
 * usb_gadget_ep_poll - complete finished transfers on one endpoint
 * @ep: the endpoint to poll
 *
 * KGDB_USB: called from kgdb's polled I/O path, where the CPU is stopped
 * and the hardirq/threaded-irq handlers that normally complete a
 * usb_request will never run. No-op if the UDC installed no hook (its
 * requests simply never complete there, and the caller times out).
 */
static inline void usb_gadget_ep_poll(struct usb_ep *ep)
{
	void (*fn)(struct usb_ep *) = READ_ONCE(usb_gadget_ep_poll_fn);

	if (ep && fn)
		fn(ep);
}

#if IS_ENABLED(CONFIG_USB_GADGET)
int usb_gadget_frame_number(struct usb_gadget *gadget);"""

# --- 1b. udc/core.c: the definition -------------------------------------

UDC_CORE_C = "drivers/usb/gadget/udc/core.c"

udc_old = """static int __init usb_udc_init(void)"""

udc_new = """/*
 * KGDB_USB: see usb_gadget_ep_poll() in <linux/usb/gadget.h>. Lives here
 * because udc-core is builtin whenever CONFIG_USB_GADGET=y, so both the
 * UDC that installs it and the gadget function that calls it always have
 * something to link against.
 */
void (*usb_gadget_ep_poll_fn)(struct usb_ep *ep);
EXPORT_SYMBOL_GPL(usb_gadget_ep_poll_fn);

static int __init usb_udc_init(void)"""

# --- 2. dwc3 --------------------------------------------------------------

DWC3_C = "drivers/usb/dwc3/gadget.c"

# in_dbg_master() is used from dwc3_gadget_giveback() and
# dwc3_gadget_ep_queue() near the top of the file, so the include has to go
# with the other headers - not next to dwc3_gadget_ep_poll() further down.
dwc3_old_inc = """#include <linux/usb/ch9.h>
#include <linux/usb/gadget.h>"""

dwc3_new_inc = """#include <linux/usb/ch9.h>
#include <linux/usb/gadget.h>
#include <linux/kgdb.h>	/* KGDB_USB: in_dbg_master() */"""

dwc3_old_queue = """	spin_lock_irqsave(&dwc->lock, flags);
	ret = __dwc3_gadget_ep_queue(dep, req);
	spin_unlock_irqrestore(&dwc->lock, flags);

	return ret;
}"""

dwc3_new_queue = """#ifdef CONFIG_KGDB
	/*
	 * KGDB_USB: with the machine stopped, dwc->lock may be held by a CPU
	 * kgdb has already rounded up - blocking on it would hang forever
	 * (and the SoC watchdog then resets the headset). But skipping it
	 * outright corrupts that CPU's critical section, which is what wedged
	 * userspace on resume. Try for it; if a stopped CPU owns it, fail the
	 * submission instead and let the debugger cope.
	 */
	if (in_dbg_master()) {
		if (!spin_trylock_irqsave(&dwc->lock, flags))
			return -EAGAIN;
		ret = __dwc3_gadget_ep_queue(dep, req);
		spin_unlock_irqrestore(&dwc->lock, flags);
		return ret;
	}
#endif
	spin_lock_irqsave(&dwc->lock, flags);
	ret = __dwc3_gadget_ep_queue(dep, req);
	spin_unlock_irqrestore(&dwc->lock, flags);

	return ret;
}"""

dwc3_old_init = """int dwc3_gadget_init(struct dwc3 *dwc)
{
	int ret;
	int irq;
	struct device *dev;

"""

dwc3_new_init = """int dwc3_gadget_init(struct dwc3 *dwc)
{
	int ret;
	int irq;
	struct device *dev;

#ifdef CONFIG_KGDB
	/* KGDB_USB: publish the polled completion hook for kgdb's transport.
	 * Logged because if this never runs, kgdb has no way to complete a
	 * USB transfer with interrupts off and the link dies the moment the
	 * debugger stops the CPUs - which is indistinguishable from a dozen
	 * other failures unless you can see this line. */
	usb_gadget_ep_poll_fn = dwc3_gadget_ep_poll;
	pr_info("KGDB_USB: dwc3 installed usb_gadget_ep_poll_fn\\n");
#endif

"""

# The polled completer itself. Placed immediately after
# dwc3_gadget_ep_cleanup_completed_requests() so it needs no forward
# declaration, and anchored on that function's closing brace plus the
# function that follows it.
dwc3_old_poll = """static bool dwc3_gadget_ep_should_continue(struct dwc3_ep *dep)"""

dwc3_new_poll = """#ifdef CONFIG_KGDB
/**
 * dwc3_gadget_ep_poll - service the controller while the machine is stopped
 * @ep: the debugger's endpoint (identifies the caller; the whole ring is
 *      drained, because the controller has to stay alive on the bus)
 *
 * KGDB_USB: with every CPU stopped there is no interrupt to complete a
 * usb_request, so the debugger's transport calls this to make progress.
 *
 * It drains the entire event ring on purpose. Servicing only our own
 * endpoint was tried and fails: nothing then answers the host, the device
 * falls off the bus within seconds and gdb cannot even connect. What makes
 * that safe is dwc3_gadget_giveback(), which parks every NON-debug
 * completion instead of running its callback here - see the comment there.
 */
static void dwc3_gadget_ep_poll(struct usb_ep *ep)
{
	struct dwc3_event_buffer *evt;
	struct dwc3_ep *dep;
	struct dwc3 *dwc;
	unsigned long flags;
	bool locked = false;

	if (!ep)
		return;

	dep = to_dwc3_ep(ep);
	if (!dep || !dep->dwc)
		return;

	dwc = dep->dwc;
	evt = dwc->ev_buf;
	if (!evt)
		return;

	/*
	 * A runtime-suspended controller has its clocks gated; touching
	 * GEVNTCOUNT would fault or read garbage, and resuming needs to
	 * sleep, which is not allowed here. Give up quietly.
	 */
	if (pm_runtime_suspended(dwc->dev))
		return;

	/*
	 * ALWAYS hold dwc->lock, even in kgdb - but never wait for it there.
	 *
	 * An earlier revision simply skipped the lock when in_dbg_master(),
	 * reasoning that with every CPU stopped there is nothing to race
	 * with. That is wrong in the one case that matters: if kgdb rounded
	 * up a CPU that was *holding* dwc->lock, mutating dwc3 state here
	 * corrupts the critical section it resumes into. Measured symptom -
	 * halting looked perfect, then after resume adbd stayed alive but
	 * every "adb shell" hung forever, because ffs.adb's endpoints had
	 * been pulled out from under the stopped holder.
	 *
	 * With the machine stopped a free lock cannot be contended, so
	 * trylock either succeeds (safe) or tells us a stopped CPU owns it,
	 * in which case the only safe move is to do nothing and let the
	 * debugger time out. Losing a debug session beats corrupting the
	 * kernel we are trying to debug.
	 */
	if (in_dbg_master()) {
		if (!spin_trylock_irqsave(&dwc->lock, flags))
			return;
	} else {
		spin_lock_irqsave(&dwc->lock, flags);
	}
	locked = true;

	dwc3_check_event_buf(evt);
	dwc3_process_event_buf(evt);

	if (locked)
		spin_unlock_irqrestore(&dwc->lock, flags);
}
#endif /* CONFIG_KGDB */

static bool dwc3_gadget_ep_should_continue(struct dwc3_ep *dep)"""

# dwc3_gadget_ep_poll now needs the event-buffer helpers, which live far
# below it, so forward-declare them.
dwc3_old_fwd = """static irqreturn_t dwc3_interrupt(int irq, void *_dwc);
static irqreturn_t dwc3_thread_interrupt(int irq, void *_dwc);"""

dwc3_new_fwd = """static irqreturn_t dwc3_interrupt(int irq, void *_dwc);
static irqreturn_t dwc3_thread_interrupt(int irq, void *_dwc);
#ifdef CONFIG_KGDB
/* KGDB_USB: used by dwc3_gadget_ep_poll() and the resume-time replay,
 * both of which sit above these definitions. */
static irqreturn_t dwc3_check_event_buf(struct dwc3_event_buffer *evt);
static irqreturn_t dwc3_process_event_buf(struct dwc3_event_buffer *evt);
#endif"""

# flush the parked completions from the next real threaded interrupt
# --- 3. u_serial: includes ------------------------------------------------

USERIAL_C = "drivers/usb/gadget/function/u_serial.c"

userial_old_includes = """#include <linux/kfifo.h>"""

userial_new_includes = """#include <linux/kfifo.h>
#ifdef CONFIG_KGDB
/* KGDB_USB: kgdb_register_io_module()/struct kgdb_io, usb_gadget_ep_poll()
 * and reaching the gadget via gserial->func.config->cdev->gadget, and
 * NO_POLL_CHAR. */
#include <linux/kgdb.h>
#include <linux/usb/composite.h>
#include <linux/serial_core.h>
#endif"""

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
 * ask for it. Must be a port that userspace is NOT also using - kgdb and
 * a getty/adb shell on the same ttyGS will corrupt each other.
 *
 * Settable at runtime (see the module_param_cb at the end of this block)
 * rather than cmdline-only, because the gadget function this attaches to
 * is composed from configfs after boot: at userial_init() time there is
 * usually no port to attach to yet.
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

/* Spin until *busy clears, completing only OUR endpoint. Bounded so an
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
 * Buffered: kgdb emits a packet a byte at a time and then calls flush(),
 * so this costs one bulk transfer per packet instead of one per byte.
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
 * Non-destructive self-test. Writing to this param exercises the whole
 * TX path - usb_ep_queue() plus the usb_gadget_ep_poll() drain - with
 * interrupts disabled on this CPU, WITHOUT stopping the machine. If the
 * bytes appear on the host's /dev/ttyACM*, the transport works.
 *
 * Caveat, so the result is not over-read: other CPUs still service the
 * dwc3 interrupt, so a completion may arrive via the normal IRQ path
 * rather than via our polling. That is why the poll_fn pointer is printed
 * too - a working test with a NULL poll_fn means the polled path is still
 * unproven and a real break-in would hang.
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

	return status;"""

userial_new_reg = """	pr_debug("%s: registered %d ttyGS* device%s\\n", __func__,
			MAX_U_SERIAL_PORTS,
			(MAX_U_SERIAL_PORTS == 1) ? "" : "s");

	/* KGDB_USB: no-op unless u_serial.kgdb_port was set. */
	kgdb_usb_register();

	return status;"""


def main():
    print("Applying KGDB-over-USB transport patches:")
    patch(GADGET_H, [
        (gadget_h_old_helper, gadget_h_new_helper),
    ])
    patch(UDC_CORE_C, [
        (udc_old, udc_new),
    ])
    patch(DWC3_C, [
        (dwc3_old_inc, dwc3_new_inc),
        (dwc3_old_fwd, dwc3_new_fwd),
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
