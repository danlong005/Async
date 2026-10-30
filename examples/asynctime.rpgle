**free
// ------------------------------------------------------------------
// ASYNCTIME - give up on slow work after a deadline
//
//   SBMJOB CMD(CALL ASYNCTIME) ALWMLTTHD(*YES)  (output: QPRINT)
//
// Calls a "service" that answers in 300 ms and one that needs 3 s,
// each with a 1 s deadline. The work and a timer (Async_Delay) race;
// Async_AwaitAny says which finished first. If the timer wins, the
// work is canceled. Like this JavaScript:
//
//   const winner = await Promise.race([work, delay(1000)]);
//
// The second part does the same with Async_Wait(task: ms), which is
// simpler when there is only one task to watch.
// ------------------------------------------------------------------
ctl-opt main(main) thread(*concurrent) option(*srcstmt: *nodebugio)
        bnddir('QC2LE');

/copy qrpglesrc/async.rpgleinc

dcl-pr printf int(10) extproc('printf');
  format pointer value options(*string);
  text pointer value options(*string: *nopass);
end-pr;

dcl-proc main;
  dcl-s ms int(10);
  dcl-s task int(10);

  say('Racing the work against a timer:');
  callWithDeadline(300: 1000);
  callWithDeadline(3000: 1000);

  say('With Async_Wait:');
  ms = 3000;
  task = Async_Run(%paddr(slowService): %addr(ms));
  if Async_Wait(task: 500);
    say('  answered within 500 ms');
  else;
    say('  no answer within 500 ms; canceling');
    Async_Cancel(task);
    Async_Wait(task: ASYNC_FOREVER);
  endif;
  say('  final state: ' + stateName(Async_Status(task)));
  Async_Free(task);
  say('Done.');
end-proc;

// Run slowService(workMs), but wait at most deadlineMs for it
dcl-proc callWithDeadline;
  dcl-pi *n;
    workMs int(10) value;
    deadlineMs int(10) value;
  end-pi;
  dcl-s race int(10) dim(2);
  dcl-s p pointer;
  dcl-s answer varchar(50) based(p);
  dcl-s start timestamp;

  start = %timestamp();
  race(1) = Async_Run(%paddr(slowService): %addr(workMs));
  race(2) = Async_Delay(deadlineMs);

  if Async_AwaitAny(race: 2) = 1;
    p = Async_Await(race(1));
    say('  ' + %char(workMs) + ' ms of work: "' + answer + '" after '
      + elapsed(start) + ' ms');
    Async_Cancel(race(2));          // the timer is no longer needed
  else;
    Async_Cancel(race(1));
    Async_Wait(race(1): ASYNC_FOREVER);
    say('  ' + %char(workMs) + ' ms of work: gave up after '
      + elapsed(start) + ' ms; the work is '
      + stateName(Async_Status(race(1))));
  endif;
  Async_Free(race(1));
  Async_Free(race(2));
end-proc;

// The task: arg is int(10) ms of work. Checks for cancellation as it
// goes, so a canceled call stops promptly. Result: varchar(50).
dcl-proc slowService;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s ms int(10) based(arg);
  dcl-s answer varchar(50);
  dcl-s waited int(10) inz(0);

  dow waited < ms;
    Async_ThrowIfCanceled();
    Async_Sleep(50);
    waited += 50;
  enddo;
  answer = 'the answer is 42';
  return Async_Return(%addr(answer): %size(answer));
end-proc;

dcl-proc stateName;
  dcl-pi *n varchar(10);
    state int(10) value;
  end-pi;

  select;
  when state = ASYNC_PENDING;
    return 'pending';
  when state = ASYNC_FULFILLED;
    return 'fulfilled';
  when state = ASYNC_REJECTED;
    return 'rejected';
  other;
    return 'canceled';
  endsl;
end-proc;

dcl-proc elapsed;
  dcl-pi *n varchar(20);
    start timestamp const;
  end-pi;

  return %char(%int(%diff(%timestamp(): start: *mseconds) / 1000));
end-proc;

// One line to standard output (QPRINT in batch); x'25' is LF
dcl-proc say;
  dcl-pi *n;
    text varchar(1024) const;
  end-pi;

  printf('%s' + x'25': text);
end-proc;
