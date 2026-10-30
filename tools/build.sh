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
# LIB/ASYNCDEMO, then runs ASYNCTEST. Compile errors are read from
# the events file (OPTION(*EVENTF)) LIB/EVFEVENT. Exit status is
# non-zero if a step or a test fails.
# ------------------------------------------------------------------
set -u
LIB=$1
DIR=$2
TEST=${3:-test}
failed=0

# Messages from a command, without the routine completion chatter
msgs() {
  grep -E '^[A-Z]{3}[0-9A-F]{4}:' | grep -vE '^(CPC|CPI|RNS9304)' || true
}

# Severity 10+ diagnostics of the last compile of member $1
events() {
  local mbr=/QSYS.LIB/$LIB.LIB/EVFEVENT.FILE/$1.MBR
  [ -f "$mbr" ] || return 0
  /QOpenSys/usr/bin/iconv -f IBM-$(attr "$mbr" CCSID) -t ISO8859-1 "$mbr" |
    awk '$1 == "ERROR" && $12 + 0 >= 10 {
           text = $0
           for (i = 0; i < 13; i++) sub(/^[^ ]+ +/, "", text)
           sub(/ +$/, "", text)
           printf "  %s line %d: %s\n", $10, $5, text }'
}

# compile NAME COMMAND: run COMMAND, report errors, note failure
compile() {
  local name=$1 out
  out=$(system "$2" 2>&1)
  if echo "$out" | grep -qE "^(RNS9309|RNS9310|CPF|CPD)"; then
    echo "!! $name failed"
    echo "$out" | msgs
    events "$name"
    failed=1
    return 1
  fi
  echo "   $name ok"
  events "$name"
}

rpgmod() {
  compile "$1" "CRTRPGMOD MODULE($LIB/$1) SRCSTMF('$DIR/$2') \
    TGTCCSID(*JOB) INCDIR('$DIR') OPTION(*EVENTF *SRCSTMT) \
    DBGVIEW(*SOURCE) REPLACE(*YES)"
}

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

for p in ASYNCTEST:qtestsrc/asynctest.rpgle \
         ASYNCDEMO:examples/asyncdemo.rpgle; do
  name=${p%%:*}
  rpgmod "$name" "${p#*:}" &&
  compile "$name" "CRTPGM PGM($LIB/$name) MODULE($LIB/$name) \
    BNDSRVPGM(($LIB/ASYNC)) ACTGRP(*NEW) REPLACE(*YES)"
done
[ $failed = 0 ] || exit 1
[ "$TEST" = notest ] && exit 0

echo "== ASYNCTEST"
out=$(system "CALL PGM($LIB/ASYNCTEST)" 2>&1)
echo "$out" | grep -vE '^(CPC|CPI)'
echo "$out" | grep -q '^ASYNCTEST OK' || exit 1
