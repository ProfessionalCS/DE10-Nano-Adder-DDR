#!/bin/sh
# fix_dts.sh - Add bridge-enable property to FPGA bridge nodes in modified.dts
# Run on DE10-Nano: bash /root/fix_dts.sh

awk '
{
  print $0
  # After printing a status = "okay" line inside a bridge node, add bridge-enable
  if (in_bridge && $0 ~ /status = "okay"/) {
    # Match the indentation of current line
    match($0, /^[[:space:]]*/)
    indent = substr($0, RSTART, RLENGTH)
    printf "%sbridge-enable = <1>;\n", indent
    in_bridge = 0
  }
}
/fpga.bridge@/ || /fpga_bridge@/ { in_bridge = 1 }
/^[[:space:]]*};/ { in_bridge = 0 }
' /root/modified.dts > /root/modified_new.dts

mv /root/modified_new.dts /root/modified.dts
echo "bridge-enable lines added:"
grep -c "bridge-enable" /root/modified.dts
grep -B1 "bridge-enable" /root/modified.dts
