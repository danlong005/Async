# ------------------------------------------------------------------
# common.sh - shell helpers for build.sh and integration.sh (sourced)
#
# Expects LIB (library being built) and failed (set to 1 on a failed
# compile) in the caller.
# ------------------------------------------------------------------

# Messages from a command, without the routine completion chatter
msgs() {
  grep -E '^[A-Z]{3}[0-9A-F]{4}:' | grep -vE '^(CPC|CPI|RNS9304)' || true
}

# Severity 10+ diagnostics of the last compile of member $1
events() {
  local mbr=/QSYS.LIB/$LIB.LIB/EVFEVENT.FILE/$1.MBR
  [ -f "$mbr" ] || return 0
  # records are 400 bytes, with or without line ends
  /QOpenSys/usr/bin/iconv -f "$(printf 'IBM-%03d' "$(attr "$mbr" CCSID)")" \
    -t ISO8859-1 "$mbr" | fold -w400 |
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
  if echo "$out" | grep -qE "^(RNS9309|RNS9310|SQL9019|CPF)"; then
    echo "!! $name failed"
    echo "$out" | msgs
    events "$name"
    failed=1
    return 1
  fi
  echo "   $name ok"
  events "$name"
}

# waitjob JOB [SECONDS]: wait for a submitted job (number/user/name)
# to end. After SECONDS (default: no limit) the job is ended and
# waitjob fails.
waitjob() {
  local s waited=0
  while :; do
    s=$(system "DSPJOB JOB($1) OPTION(*STSA)" 2>&1 || true)
    echo "$s" | grep -qE 'CPF1070|OUTQ' && return 0
    if [ -n "${2:-}" ] && [ $waited -ge "$2" ]; then
      system "ENDJOB JOB($1) OPTION(*IMMED)" >/dev/null 2>&1
      return 1
    fi
    sleep 3
    waited=$((waited + 3))
  done
}

# submit NAME ALWMLTTHD COMMAND: submit COMMAND as batch job NAME,
# keeping its job log; prints the qualified job name
submit() {
  system "SBMJOB CMD($3) JOB($1) ALWMLTTHD($2) LOG(4 00 *SECLVL)" 2>&1 |
    sed -n "s/.*Job \\([0-9]*\\/[A-Z0-9#@\$]*\\/$1\\) submitted.*/\\1/p"
}

# Summarise a JUnit XML file: one line per test, then the totals.
# Fails if any test failed or ended in error.
junit() {
  tr -d '\n' < "$1" | sed 's/<testcase/\
<testcase/g; s/<\/testsuite>/\
&/g' | awk '
    /^<testcase/ {
      match($0, /name="[^"]*"/); name = substr($0, RSTART + 6, RLENGTH - 7)
      tests++
      if ($0 ~ /<(failure|error)/) {
        bad++
        match($0, /message="[^"]*"/)
        printf "FAIL %s: %s\n", name, substr($0, RSTART + 9, RLENGTH - 10)
      } else
        printf "ok   %s\n", name
    }
    END { printf "%d tests, %d failed\n", tests, bad; exit bad > 0 }'
}

rpgmod() {
  compile "$1" "CRTRPGMOD MODULE($LIB/$1) SRCSTMF('$DIR/$2') \
    TGTCCSID(*JOB) INCDIR('$DIR') OPTION(*EVENTF *SRCSTMT) \
    DBGVIEW(*SOURCE) REPLACE(*YES)"
}

# joblog JOB: the messages in the job log of an ended job (needs its
# QPJOBLOG spooled file), without routine start/end chatter
joblog() {
  /QOpenSys/usr/bin/qsh -c "db2 -S \"select spooled_data from table(
      systools.spooled_file_data(job_name => '$1',
                                 spooled_file_name => 'QPJOBLOG')) x\"" \
    2>/dev/null |
    awk '/^ *[A-Z][A-Z][A-Z][0-9A-F][0-9A-F][0-9A-F][0-9A-F] / {
           keep = $1 !~ /^(CPF1124|CPI1125|CPF1164|CPC)/ }
         keep && /^ *([A-Z][A-Z][A-Z][0-9A-F]+ |.*(Message|To procedure|Statement) \. )/'
}
