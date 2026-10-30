#!/bin/bash
# ------------------------------------------------------------------
# integration.sh - build and run the ASYNC integration tests on IBM i
#
#   tools/integration.sh LIB DIR [SCENARIO...]
#
# LIB       library holding ASYNC (built by build.sh); ASYNCIT,
#           ASYNCAGE and ASYNCNTS are built into it too
# DIR       IFS directory holding this source tree
# SCENARIO  scenarios of qtestsrc/asyncit.sqlrpgle to run (all if
#           none are given)
#
# Each scenario runs as its own batch job, so one that ends its job
# fails alone. A scenario passes if its log, /tmp/asyncit-NAME.log,
# ends with "PASS NAME". A job still running after its time limit is
# ended and fails. Exit status is non-zero if anything failed.
# ------------------------------------------------------------------
set -u
LIB=$1
DIR=$2
shift 2
failed=0
. "$(dirname "$0")/common.sh"

ALL="stress awaiters freerace cancelrace leak limit sql ifs agend
     nothreadsafe nothreads"
SCENARIOS=${*:-$ALL}

# Job log messages that fail a scenario even if it passed: machine
# checks, function checks, unhandled RPG errors, ended threads
BADMSGS='^ *(MCH[0-9A-F]{4}|CPF9999|CEE9901|RNQ[0-9]{4}|RNX[0-9]{4}) '


echo "== building the integration tests into $LIB"
compile ASYNCIT "CRTSQLRPGI OBJ($LIB/ASYNCIT) \
  SRCSTMF('$DIR/qtestsrc/asyncit.sqlrpgle') OBJTYPE(*MODULE) \
  COMMIT(*NONE) DBGVIEW(*SOURCE) OPTION(*EVENTF) RPGPPOPT(*LVL2) \
  COMPILEOPT('TGTCCSID(*JOB) INCDIR(''$DIR'')') REPLACE(*YES)" &&
compile ASYNCIT "CRTPGM PGM($LIB/ASYNCIT) MODULE($LIB/ASYNCIT) \
  BNDSRVPGM(($LIB/ASYNC)) ACTGRP(*NEW) REPLACE(*YES)"
rpgmod ASYNCAGE qtestsrc/asyncage.rpgle &&
compile ASYNCAGE "CRTPGM PGM($LIB/ASYNCAGE) MODULE($LIB/ASYNCAGE) \
  BNDSRVPGM(($LIB/ASYNC)) ACTGRP(*NEW) REPLACE(*YES)"
rpgmod ASYNCNTS qtestsrc/asyncnts.rpgle &&
compile ASYNCNTS "CRTPGM PGM($LIB/ASYNCNTS) MODULE($LIB/ASYNCNTS) \
  BNDSRVPGM(($LIB/ASYNC)) ACTGRP(*NEW) REPLACE(*YES)"
[ $failed = 0 ] || exit 1

passed=0
total=0
for s in $SCENARIOS; do
  total=$((total + 1))
  log=/tmp/asyncit-$s.log
  rm -f "$log"
  : > "$log" && /QOpenSys/usr/bin/setccsid 819 "$log"
  threads='*YES'
  [ "$s" = nothreads ] && threads='*NO'

  echo "== $s"
  start=$(date +%s)
  job=$(submit ASYNCIT "$threads" "CALL PGM($LIB/ASYNCIT) PARM('$s')")
  if [ -z "$job" ]; then
    echo "!! could not submit $s"
    failed=1
    continue
  fi
  timedout=no
  waitjob "$job" 600 || timedout=yes
  sed 's/^/   /' "$log"
  if [ $timedout = yes ]; then
    echo "!! $s still running after 600 s; ended job $job"
    failed=1
  elif ! tail -1 "$log" | grep -qx "PASS $s"; then
    echo "!! $s did not pass; job log of $job:"
    joblog "$job" | head -40 | sed 's/^/   /'
    failed=1
  elif ! messages=$(joblog "$job"); then
    echo "!! $s passed, but its job log ($job) could not be read to check it"
    failed=1
  elif bad=$(echo "$messages" | grep -E "$BADMSGS") && [ -n "$bad" ]; then
    # passed, but something went wrong on a thread it did not see
    echo "!! $s passed, but its job log ($job) has:"
    echo "$bad" | head -20 | sed 's/^/   /'
    failed=1
  else
    passed=$((passed + 1))
    echo "   ($(( $(date +%s) - start )) s)"
  fi
done

echo "== $passed of $total scenarios passed"
exit $failed
