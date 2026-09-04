#!/system/bin/sh
# Add acm.kgdb to the live USB gadget composition.
#
# configfs refuses composition changes while the UDC is bound (EINVAL), and
# writing "" to UDC works but something re-binds within ~2s, so the
# unbind -> symlink -> rebind sequence must be back-to-back with no sleeps.
# Meta's vendor.usb_default service re-asserts the composition, so stop it
# first.
#
# Run detached; the UDC bounce kills the adb shell that launched it.
# acm-watchdog.sh MUST already be running (this script starts it) or a
# failure here leaves the headset with no USB at all.
exec > /data/local/tmp/acm-compose.log 2>&1
set -x
G=/config/usb_gadget/g1
C=$G/configs/b.1
U=$(getprop sys.usb.controller)

# Safety net first, before anything can go wrong.
nohup setsid sh /data/local/tmp/acm-watchdog.sh >/dev/null 2>&1 &
sleep 1

mkdir $G/functions/acm.kgdb 2>/dev/null   # volatile across reboots

stop vendor.usb_default
echo "" > $G/UDC
ln -s $G/functions/acm.kgdb $C/function2
LNRC=$?
echo "$U" > $G/UDC
BINDRC=$?

sleep 4
echo "ln=$LNRC bind=$BINDRC UDC=[$(cat $G/UDC)]"
ls -l $C/
start vendor.usb_default
