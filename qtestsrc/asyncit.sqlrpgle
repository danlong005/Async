**free
// ------------------------------------------------------------------
// ASYNCIT - integration tests for service program ASYNC
//
//   SBMJOB CMD(CALL ASYNCIT PARM('stress')) ALWMLTTHD(*YES)
//
// Runs one scenario per call, meant to be its own batch job so that
// a scenario that ends the job takes only itself down. Results are
// appended to /tmp/asyncit-<scenario>.log (created by the caller);
// the last line is "PASS <scenario>" or "FAIL <scenario>". A job
// that dies or hangs leaves no PASS line. tools/integration.sh runs
// them all.
//
// Scenarios:
//   stress        20 rounds of 200 tasks at once, every result checked
//   awaiters      50 tasks awaiting one promise
//   freerace      tasks freed by another task while being awaited
//   cancelrace    cancel at random moments in a task's life
//   leak          100,000 tasks; job temporary storage must not grow
//   limit         ASYNC_MAX_TASKS handles, then a clean error
//   sql           embedded SQL in tasks running at once
//   ifs           IFS files written and read back by tasks at once
//   agend         a program ends its activation group with tasks
//                 still running: ASYNC cancels and waits for them
//   nothreadsafe  task procedure in a module without THREAD(*CONCURRENT)
//   nothreads     job with ALWMLTTHD(*NO): Async_Run must fail cleanly
// ------------------------------------------------------------------
ctl-opt main(main) thread(*concurrent) option(*srcstmt: *nodebugio)
        bnddir('QC2LE');

/copy qrpglesrc/async.rpgleinc

dcl-c O_WRONLY 2;
dcl-c O_RDONLY 1;
dcl-c O_CREAT 8;
dcl-c O_TRUNC 64;
dcl-c O_APPEND 256;
dcl-c O_TEXTDATA 16777216;

dcl-pr ifsOpen int(10) extproc('open');
  path pointer value options(*string);
  flags int(10) value;
  mode uns(10) value options(*nopass);
end-pr;

dcl-pr ifsWrite int(10) extproc('write');
  fd int(10) value;
  buf pointer value;
  len uns(10) value;
end-pr;

dcl-pr ifsRead int(10) extproc('read');
  fd int(10) value;
  buf pointer value;
  len uns(10) value;
end-pr;

dcl-pr ifsClose int(10) extproc('close');
  fd int(10) value;
end-pr;

dcl-pr ifsUnlink int(10) extproc('unlink');
  path pointer value options(*string);
end-pr;

dcl-ds psds psds qualified;
  excId char(7) pos(40);
  excData char(80) pos(91);
  pgmLib char(10) pos(81);
end-ds;

// A task handle and a delay, for freeAfter
dcl-ds victim_t qualified template;
  task int(10);
  ms int(10);
end-ds;

dcl-s gLog varchar(64);
dcl-s gFailures int(10);

dcl-proc main;
  dcl-pi *n;
    scenario char(32) const;
  end-pi;
  dcl-s name varchar(32);

  name = %lower(%trim(scenario));
  gLog = '/tmp/asyncit-' + name + '.log';
  gFailures = 0;
  log('start ' + name);

  monitor;
    select;
    when name = 'stress';
      stress();
    when name = 'awaiters';
      awaiters();
    when name = 'freerace';
      freeRace();
    when name = 'cancelrace';
      cancelRace();
    when name = 'leak';
      leak();
    when name = 'limit';
      limit();
    when name = 'sql';
      sqlInTasks();
    when name = 'ifs';
      ifsInTasks();
    when name = 'agend';
      agEnd();
    when name = 'nothreadsafe';
      noThreadsafe();
    when name = 'nothreads';
      noThreads();
    other;
      check(*off: 'unknown scenario');
    endsl;
  on-error;
    check(*off: 'unexpected ' + psds.excId + ': ' + %trim(psds.excData));
  endmon;

  if gFailures = 0;
    log('PASS ' + name);
  else;
    log('FAIL ' + name);
  endif;
end-proc;

// ==================================================================
// Scenarios
// ==================================================================

dcl-proc stress;
  dcl-c ROUNDS 20;
  dcl-c COUNT 200;
  dcl-s n int(10) dim(COUNT);
  dcl-s tasks int(10) dim(COUNT);
  dcl-s p pointer;
  dcl-s total int(20) based(p);
  dcl-s round int(10);
  dcl-s i int(10);
  dcl-s wrong int(10) inz(0);
  dcl-s start timestamp;

  start = %timestamp();
  for round = 1 to ROUNDS;
    for i = 1 to COUNT;
      n(i) = i * 100 + round;
      tasks(i) = Async_Run(%paddr(sumTo): %addr(n(i)));
    endfor;
    Async_AwaitAll(tasks: COUNT);
    for i = 1 to COUNT;
      p = Async_Result(tasks(i));
      if total <> n(i) * (n(i) + 1) / 2;
        wrong += 1;
      endif;
      Async_Free(tasks(i));
    endfor;
  endfor;
  check(wrong = 0: %char(wrong) + ' wrong results');
  log(%char(ROUNDS * COUNT) + ' tasks in '
    + %char(%int(%diff(%timestamp(): start: *mseconds) / 1000))
    + ' ms');
end-proc;

dcl-proc awaiters;
  dcl-c COUNT 50;
  dcl-s promise int(10);
  dcl-s tasks int(10) dim(COUNT);
  dcl-s value int(20) inz(7);
  dcl-s p pointer;
  dcl-s got int(20) based(p);
  dcl-s i int(10);
  dcl-s wrong int(10) inz(0);

  promise = Async_Promise();
  for i = 1 to COUNT;
    tasks(i) = Async_Run(%paddr(awaitPromise): %addr(promise));
  endfor;
  Async_Sleep(200);
  check(Async_WaitAny(tasks: COUNT: 0) = 0: 'an awaiter finished early');
  Async_Resolve(promise: %addr(value): %size(value));
  check(Async_WaitAll(tasks: COUNT: 10000): 'awaiters still waiting');
  for i = 1 to COUNT;
    p = Async_Result(tasks(i));
    if p = *null or got <> 7;
      wrong += 1;
    endif;
    Async_Free(tasks(i));
  endfor;
  check(wrong = 0: %char(wrong) + ' awaiters got a wrong value');
  Async_Free(promise);
end-proc;

// Another task frees the task we are awaiting. Each await must end
// with the result or with the "not a task handle" error, never hang.
dcl-proc freeRace;
  dcl-c ROUNDS 500;
  dcl-s ms int(10) dim(4);
  dcl-ds victim likeds(victim_t);
  dcl-s freer int(10);
  dcl-s round int(10);
  dcl-s results int(10) inz(0);
  dcl-s freed int(10) inz(0);

  ms(1) = 0;
  ms(2) = 1;
  ms(3) = 2;
  ms(4) = 3;
  for round = 1 to ROUNDS;
    victim.task = Async_Run(%paddr(sleepFor): %addr(ms(%rem(round: 4) + 1)));
    victim.ms = %rem(round * 7: 4);
    freer = Async_Run(%paddr(freeAfter): %addr(victim));
    monitor;
      Async_Await(victim.task);
      results += 1;
    on-error;
      freed += 1;
    endmon;
    Async_Await(freer);
    Async_Free(freer);
    Async_Free(victim.task);
  endfor;
  log(%char(results) + ' awaits got the result, ' + %char(freed)
    + ' saw the task freed');
  check(results + freed = ROUNDS: 'lost awaits');
end-proc;

dcl-proc cancelRace;
  dcl-c ROUNDS 300;
  dcl-s task int(10);
  dcl-s round int(10);
  dcl-s stuck int(10) inz(0);
  dcl-s notCanceled int(10) inz(0);

  for round = 1 to ROUNDS;
    task = Async_Run(%paddr(untilCanceled));
    Async_Sleep(%rem(round: 3));
    Async_Cancel(task);
    if not Async_Wait(task: 5000);
      stuck += 1;
    elseif Async_Status(task) <> ASYNC_CANCELED;
      notCanceled += 1;
    endif;
    Async_Free(task);
  endfor;
  check(stuck = 0: %char(stuck) + ' canceled tasks did not stop');
  check(notCanceled = 0: %char(notCanceled) + ' tasks not canceled');
end-proc;

// Run, await and free many tasks: the job's temporary storage must
// stay about the same once the first round has warmed up
dcl-proc leak;
  dcl-c ROUNDS 50;
  dcl-c COUNT 2000;
  dcl-s n int(10) inz(10);
  dcl-s tasks int(10) dim(COUNT);
  dcl-s round int(10);
  dcl-s i int(10);
  dcl-s before int(10);
  dcl-s after int(10);

  for round = 0 to ROUNDS;
    if round = 1;
      before = tempStorage();
    endif;
    // half run on threads, half are promises
    for i = 1 to COUNT;
      if %rem(i: 2) = 0;
        tasks(i) = Async_Run(%paddr(sumTo): %addr(n));
      else;
        tasks(i) = Async_Promise();
        Async_Resolve(tasks(i): %addr(n): %size(n));
      endif;
      if %rem(i: 200) = 0;
        Async_AwaitAll(%subarr(tasks: i - 199: 200): 200);
      endif;
    endfor;
    for i = 1 to COUNT;
      Async_Free(tasks(i));
    endfor;
  endfor;
  after = tempStorage();
  log('temporary storage ' + %char(before) + ' MB after warm-up, '
    + %char(after) + ' MB after ' + %char(ROUNDS * COUNT) + ' tasks');
  check(after - before <= 4:
        'grew ' + %char(after - before) + ' MB');
end-proc;

dcl-proc limit;
  dcl-s tasks int(10) dim(ASYNC_MAX_TASKS);
  dcl-s count int(10) inz(0);
  dcl-s failed ind inz(*off);
  dcl-s extra int(10);
  dcl-s i int(10);

  for i = 1 to ASYNC_MAX_TASKS + 1;
    monitor;
      extra = Async_Promise();
      if i <= ASYNC_MAX_TASKS;
        tasks(i) = extra;
        count += 1;
      endif;
    on-error;
      failed = *on;
      leave;
    endmon;
  endfor;
  check(count = ASYNC_MAX_TASKS: 'only ' + %char(count) + ' handles');
  check(failed: 'no error past ' + %char(ASYNC_MAX_TASKS) + ' handles');

  for i = 1 to count;
    Async_Free(tasks(i));
  endfor;
  extra = Async_Promise();
  check(extra > 0: 'no handle after freeing');
  Async_Free(extra);
end-proc;

dcl-proc sqlInTasks;
  dcl-c COUNT 8;
  dcl-s expected int(10);
  dcl-s tasks int(10) dim(COUNT);
  dcl-s p pointer;
  dcl-s got int(10) based(p);
  dcl-s i int(10);

  exec sql select count(*) into :expected from qsys2.systables
           where table_schema = 'QSYS2';
  check(sqlcode = 0: 'sqlcode ' + %char(sqlcode));
  for i = 1 to COUNT;
    tasks(i) = Async_Run(%paddr(countTables));
  endfor;
  monitor;
    Async_AwaitAll(tasks: COUNT);
  on-error;
    check(*off: 'a task failed: ' + Async_ErrorText(tasks(1)));
  endmon;
  for i = 1 to COUNT;
    if Async_Status(tasks(i)) = ASYNC_FULFILLED;
      p = Async_Result(tasks(i));
      check(got = expected: 'task ' + %char(i) + ' counted '
          + %char(got) + ', expected ' + %char(expected));
    else;
      check(*off: 'task ' + %char(i) + ': ' + Async_ErrorText(tasks(i)));
    endif;
    Async_Free(tasks(i));
  endfor;
end-proc;

dcl-proc ifsInTasks;
  dcl-c COUNT 8;
  dcl-s ids int(10) dim(COUNT);
  dcl-s tasks int(10) dim(COUNT);
  dcl-s p pointer;
  dcl-s ok ind based(p);
  dcl-s i int(10);

  for i = 1 to COUNT;
    ids(i) = i;
    tasks(i) = Async_Run(%paddr(writeAndRead): %addr(ids(i)));
  endfor;
  Async_AwaitAll(tasks: COUNT);
  for i = 1 to COUNT;
    p = Async_Result(tasks(i));
    check(ok: 'file ' + %char(i) + ' did not read back the same');
    Async_Free(tasks(i));
  endfor;
end-proc;

// ASYNCAGE starts two tasks and returns at once, ending its *NEW
// activation group while they run. ASYNC must cancel the one that
// checks for cancellation and wait for the one that does not (2 s)
// before the activation group goes. A thread left running in it
// would end with MCH3402, which tools/integration.sh looks for in
// the job log.
dcl-proc agEnd;
  dcl-pr asyncAge extpgm(agePgm);
  end-pr;
  dcl-s agePgm char(21);
  dcl-s n int(10) inz(10);
  dcl-s task int(10);
  dcl-s p pointer;
  dcl-s total int(20) based(p);
  dcl-s start timestamp;
  dcl-s ms int(20);

  agePgm = %trim(psds.pgmLib) + '/ASYNCAGE';
  start = %timestamp();
  asyncAge();
  ms = %diff(%timestamp(): start: *mseconds) / 1000;
  log('ASYNCAGE returned after ' + %char(ms) + ' ms');
  check(ms >= 1500: 'returned before its 2 s task ended');
  check(ms < 8000: 'waited for the task that should be canceled');

  Async_Sleep(1000);
  task = Async_Run(%paddr(sumTo): %addr(n));
  p = Async_Await(task);
  check(total = 55: 'ASYNC no longer works here');
  Async_Free(task);
end-proc;

// ASYNCNTS runs a task procedure from a module compiled without
// THREAD(*CONCURRENT) and returns what happened
dcl-proc noThreadsafe;
  dcl-pr asyncNts extpgm(ntsPgm);
    outcome char(100);
  end-pr;
  dcl-s ntsPgm char(21);
  dcl-s outcome char(100);

  ntsPgm = %trim(psds.pgmLib) + '/ASYNCNTS';
  asyncNts(outcome);
  log('ASYNCNTS: ' + %trim(outcome));
end-proc;

dcl-proc noThreads;
  dcl-s n int(10) inz(10);
  dcl-s task int(10);
  dcl-s failed ind inz(*off);

  monitor;
    task = Async_Run(%paddr(sumTo): %addr(n));
  on-error;
    failed = *on;
    log('Async_Run: ' + psds.excId + ' ' + %trim(psds.excData));
  endmon;
  check(failed: 'Async_Run started a thread in a job without threads');
  if not failed;
    Async_Await(task);
    Async_Free(task);
  endif;
end-proc;

// ==================================================================
// Task procedures
// ==================================================================

// arg: int(10) n. Result: int(20) 1 + 2 + ... + n
dcl-proc sumTo;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s n int(10) based(arg);
  dcl-s total int(20) inz(0);
  dcl-s i int(10);

  for i = 1 to n;
    total += i;
  endfor;
  return Async_Return(%addr(total): %size(total));
end-proc;

// arg: int(10) ms
dcl-proc sleepFor;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s ms int(10) based(arg);

  Async_Sleep(ms);
  return Async_Return(%addr(ms): %size(ms));
end-proc;

// arg: victim_t. Frees victim.task after victim.ms
dcl-proc freeAfter;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-ds victim likeds(victim_t) based(arg);

  Async_Sleep(victim.ms);
  Async_Free(victim.task);
  return *null;
end-proc;

// arg: int(10) promise handle. Result: int(20) the promise's value
dcl-proc awaitPromise;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s promise int(10) based(arg);
  dcl-s p pointer;
  dcl-s value int(20) based(p);
  dcl-s copy int(20);

  p = Async_Await(promise);
  copy = value;
  return Async_Return(%addr(copy): %size(copy));
end-proc;

dcl-proc untilCanceled;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s i int(10);

  for i = 1 to 1000;
    Async_ThrowIfCanceled();
    Async_Sleep(1);
  endfor;
  return *null;
end-proc;

// Result: int(10) number of QSYS2 tables
dcl-proc countTables;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s count int(10);

  exec sql select count(*) into :count from qsys2.systables
           where table_schema = 'QSYS2';
  if sqlcode <> 0;
    Async_Throw('sqlcode ' + %char(sqlcode));
  endif;
  return Async_Return(%addr(count): %size(count));
end-proc;

// arg: int(10) id. Writes 64 KB to a file of its own, reads it back.
// Result: ind, *on if the same came back
dcl-proc writeAndRead;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s id int(10) based(arg);
  dcl-s path varchar(64);
  dcl-s written char(65536);
  dcl-s readBack char(65536);
  dcl-s fd int(10);
  dcl-s got int(10);
  dcl-s ok ind inz(*off);

  path = '/tmp/asyncit-ifs-' + %char(id) + '.dat';
  written = %char(id) + ' ' + %char(%timestamp());
  %subst(written: 65000) = 'end of file ' + %char(id);
  fd = ifsOpen(path: O_WRONLY + O_CREAT + O_TRUNC: 438);
  if fd >= 0;
    ifsWrite(fd: %addr(written): %size(written));
    ifsClose(fd);
    fd = ifsOpen(path: O_RDONLY);
  endif;
  if fd >= 0;
    got = ifsRead(fd: %addr(readBack): %size(readBack));
    ifsClose(fd);
    ok = got = %size(written) and readBack = written;
  endif;
  ifsUnlink(path);
  return Async_Return(%addr(ok): %size(ok));
end-proc;

// ==================================================================
// Helpers
// ==================================================================

// Job's temporary storage in MB
dcl-proc tempStorage;
  dcl-pi *n int(10);
  end-pi;
  dcl-s mb int(10) inz(0);

  exec sql select temporary_storage into :mb
           from table(qsys2.active_job_info(
                  job_name_filter => '*', detailed_info => 'NONE')) x;
  return mb;
end-proc;

dcl-proc check;
  dcl-pi *n;
    condition ind const;
    msg varchar(512) const;
  end-pi;

  if not condition;
    gFailures += 1;
    log('  failed: ' + msg);
  endif;
end-proc;

// Append a line to the scenario's log (the file's CCSID is kept)
dcl-proc log;
  dcl-pi *n;
    text varchar(1024) const;
  end-pi;
  dcl-s line varchar(1026);
  dcl-s fd int(10);

  line = text + x'25';
  fd = ifsOpen(gLog: O_WRONLY + O_APPEND + O_TEXTDATA);
  if fd >= 0;
    ifsWrite(fd: %addr(line: *data): %len(line));
    ifsClose(fd);
  endif;
end-proc;
