#!/bin/zsh
# The Liquid Glass sweep: the bar and the pill, both appearances, over the
# opposing ground, at tint 0 / 0.5 / 1, plus matching-ground controls.
# Measured 2026-09-14 on macOS 27.0; run again on each OS beta.
# usage: batch.sh [outdir]   (default: .build/glass-sweep) — needs `swift build`
# first, and takes the screen for about two minutes.
here=${0:A:h}; root=${here:h:h}
out=${1:-$root/.build/glass-sweep}; mkdir -p $out
[[ -x $out/measure ]] || swiftc -O $here/measure.swift -o $out/measure
shoot() { # name variant appearance ground tint [K=V...]
  local name=$1 v=$2 a=$3 g=$4 t=$5; shift 5
  $here/shoot.sh $out/$name.png $v $a $t LODESTAR_GROUND=$g "$@" >/dev/null
  $out/measure $out/$name.png $a --ground $g --crop $out/$name-crop.png
}
for a in dark light; do
  g=$([[ $a = dark ]] && echo light || echo dark)
  for t in 0 0.5 1; do
    shoot bar-$a-g$g-t$t 16 $a $g $t
    shoot pill-$a-g$g-t$t 19 $a $g $t PILL=typing
  done
done
shoot bar-dark-gdark-t0 16 dark dark 0
shoot bar-dark-gdark-t1 16 dark dark 1
shoot bar-light-glight-t0 16 light light 0
shoot bar-light-glight-t1 16 light light 1
