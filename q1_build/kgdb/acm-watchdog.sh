#!/system/bin/sh
# Independent USB watchdog. Launched (detached) BEFORE any UDC bounce.
#
# On the Quest 3 side a UDC unbind twice left the headset with no USB at
# all, needing a physical power cycle. A single timed check is not enough:
# if the one rebind attempt fails, nothing retries. So this retries for
# ~90s, and if the UDC still will not bind it ROLLS BACK our added function
# and binds without it. Losing kgdb is fine; losing the headset is not.
exec > /data/local/tmp/acm-watchdog.log 2>&1
set -x
G=/config/usb_gadget/g1
C=$G/configs/b.1
U=$(getprop sys.usb.controller)

i=0
while [ $i -lt 45 ]; do
  sleep 2
  [ -n "$(cat $G/UDC 2>/dev/null)" ] && { echo "UDC bound, watchdog idle"; exit 0; }
  echo "UDC empty (try $i) - rebinding"
  echo "$U" > $G/UDC 2>/dev/null
  [ -n "$(cat $G/UDC 2>/dev/null)" ] && { echo "rebound OK"; exit 0; }
  # Would not bind with our function present: roll it back.
  echo "rebind failed - rolling back function2"
  rm -f $C/function2 2>/dev/null
  echo "$U" > $G/UDC 2>/dev/null
  [ -n "$(cat $G/UDC 2>/dev/null)" ] && { echo "rebound WITHOUT kgdb function"; exit 0; }
  i=$((i+1))
done
echo "watchdog giving up"
