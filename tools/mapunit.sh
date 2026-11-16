#!/bin/zsh
# mapunit.sh <unit> <outdir> : maps knob bit positions for one unit via the edit buffer
U=$1; OUT=$2; T=$(dirname $0)/../.build/debug/g5tool
typeset -A TY MX
TY=(2 53 3 7 4 16 5 105 6 32 7 12 8 30 9 0); MX=(2 5022 3 2014 4 2014 5 199 6 150 7 150 8 150 9 150)
for P in 2 3 4 5 6 7 8 9; do
  $T sweep $U 1 ${TY[$P]} > /dev/null
  VALS=(0); v=1; while (( v <= ${MX[$P]} )); do VALS+=($v); (( v *= 2 )); done
  $T sweep $U $P ${VALS[@]} | grep -v firmware > $OUT/u${U}_p${P}.txt
done
