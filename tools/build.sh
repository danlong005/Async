#!/bin/bash
# ------------------------------------------------------------------
# build.sh - build ASYNC on IBM i from the IFS and run its tests
#
#   tools/build.sh LIB DIR [notest]
#
# LIB  library to build into (ASYNC* objects in it are replaced)
# DIR  IFS directory holding this source tree
#
# Creates LIB/ASYNC *SRVPGM, LIB/ASYNC *BNDDIR, LIB/ASYNCTEST and
# LIB/ASYNCDEMO, then runs ASYNCTEST. Where iRPGUnit is installed
# (library RPGUNIT), ASYNCTEST is built with RUCRTRPG and run with
# RUCALLTST; elsewhere it is a plain program that prints its
# results. Compile errors are read from the events file
# (OPTION(*EVENTF)) LIB/EVFEVENT. Exit status is non-zero if a step
# or a test fails.
# ------------------------------------------------------------------
set -u
LIB=$1
DIR=$2
TEST=${3:-test}
failed=0
irpgunit=no
[ -e /QSYS.LIB/RPGUNIT.LIB/RUCRTRPG.CMD ] && irpgunit=yes

. "$(dirname "$0")/common.sh"

echo "== building into $LIB"
rpgmod ASYNC qrpglesrc/async.rpgle &&
compile ASYNC "CRTSRVPGM SRVPGM($LIB/ASYNC) MODULE($LIB/ASYNC) \
  SRCSTMF('$DIR/qsrvsrc/async.bnd') ACTGRP(*CALLER) \
  TEXT('Async/await for ILE RPG') REPLACE(*YES)" || exit 1

if [ ! -e "/QSYS.LIB/$LIB.LIB/ASYNC.BNDDIR" ]; then
  system "CRTBNDDIR BNDDIR($LIB/ASYNC) TEXT('Async/await for ILE RPG')" \
    2>&1 | msgs
  system "ADDBNDDIRE BNDDIR($LIB/ASYNC) OBJ(($LIB/ASYNC *SRVPGM))" \
    2>&1 | msgs
fi

if [ $irpgunit = yes ]; then
  compile ASYNCTEST "RPGUNIT/RUCRTRPG TSTPGM($LIB/ASYNCTEST) \
    SRCSTMF('$DIR/qtestsrc/asynctest.rpgle') DEFINE(IRPGUNIT) \
    INCDIR('$DIR') TGTCCSID(*JOB) DBGVIEW(*SOURCE) \
    BNDSRVPGM(($LIB/ASYNC))"
  progs="ASYNCDEMO:examples/asyncdemo.rpgle"
else
  progs="ASYNCTEST:qtestsrc/asynctest.rpgle ASYNCDEMO:examples/asyncdemo.rpgle"
fi

for p in $progs; do
  name=${p%%:*}
  rpgmod "$name" "${p#*:}" &&
  compile "$name" "CRTPGM PGM($LIB/$name) MODULE($LIB/$name) \
    BNDSRVPGM(($LIB/ASYNC)) ACTGRP(*NEW) REPLACE(*YES)"
done
[ $failed = 0 ] || exit 1
[ "$TEST" = notest ] && exit 0

echo "== ASYNCTEST"
if [ $irpgunit = yes ]; then
  # A batch job that allows threads (jobs started from SSH may not);
  # the results come back as a JUnit XML file
  xml=$DIR/asynctest.xml
  rm -f "$xml"
  job=$(submit ASYNCTEST '*YES' "RPGUNIT/RUCALLTST \
          TSTPGM($LIB/ASYNCTEST) DETAIL(*ALL) XMLSTMF('$xml')")
  [ -n "$job" ] || { echo "!! could not submit ASYNCTEST"; exit 1; }
  waitjob "$job"
  if [ ! -s "$xml" ]; then
    echo "!! ASYNCTEST wrote no results; see the job log of $job"
    exit 1
  fi
  junit "$xml" || exit 1
else
  out=$(system "CALL PGM($LIB/ASYNCTEST)" 2>&1)
  echo "$out" | grep -vE '^(CPC|CPI)'
  echo "$out" | grep -q '^ASYNCTEST OK' || exit 1
fi
