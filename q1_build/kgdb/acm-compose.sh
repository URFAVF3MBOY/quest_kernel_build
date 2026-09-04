#!/system/bin/sh
# Add acm.kgdb to the live USB gadget composition (Quest 1 / monterey).
#
# configfs refuses composition changes while the UDC is bound (EINVAL), so
# the unbind -> symlink -> rebind sequence must be back-to-back with no
# sleeps in between.
#
# Unlike the Quest 3 script, there is NO vendor.usb_default service to stop
# here. On this device the composition is driven entirely by
# "on property:sys.usb.config=..." triggers in /init.usb.configfs.rc and
# /init.monterey.usb.rc - nothing polls or re-asserts it - so as long as we
# leave sys.usb.config alone, init will not fight us for the config.
#
# The stock composition uses the symlink names function0 (ffs.xrsp) and
# function1 (ffs.adb), so function2 is ours.
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

echo "" > $G/UDC
ln -s $G/functions/acm.kgdb $C/function2
LNRC=$?
echo "$U" > $G/UDC
BINDRC=$?

sleep 4
echo "ln=$LNRC bind=$BINDRC UDC=[$(cat $G/UDC)]"
ls -l $C/
