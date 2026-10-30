**free
// ------------------------------------------------------------------
// ASYNCCNCL - canceling long-running work
//
//   SBMJOB CMD(CALL ASYNCCNCL) ALWMLTTHD(*YES)  (output: QPRINT)
//
// Two tasks each copy 50 batches (100 ms a batch) and are canceled
// about half a second in. Cancellation is cooperative: Async_Cancel
// only asks, and the task decides where to stop. They show the two
// ways a task can respond:
//
// - allOrNothing calls Async_ThrowIfCanceled between batches. It
//   ends as canceled, with no result; Async_Await of it sends
//   CPF9898. Use this when partial work is worthless.
//
// - whatYouCan checks Async_IsCancelRequested, stops, and returns how
//   far it got. It ends fulfilled, with a result. Use this when
//   partial work counts.
// ------------------------------------------------------------------
ctl-opt main(main) thread(*concurrent) option(*srcstmt: *nodebugio)
        bnddir('QC2LE');

/copy qrpgleref/async.rpgleinc

dcl-pr printf int(10) extproc('printf');
  format pointer value options(*string);
  text pointer value options(*string: *nopass);
end-pr;

dcl-c TOTAL_BATCHES 50;

dcl-proc main;
  dcl-s batches int(10) inz(TOTAL_BATCHES);
  dcl-s allTask int(10);
  dcl-s someTask int(10);
  dcl-s p pointer;
  dcl-s copied int(10) based(p);

  allTask = Async_Run(%paddr(allOrNothing): %addr(batches));
  someTask = Async_Run(%paddr(whatYouCan): %addr(batches));
  Async_Sleep(550);
  say('Canceling both after about 550 ms');
  Async_Cancel(allTask);
  Async_Cancel(someTask);

  monitor;
    p = Async_Await(allTask);
    say('allOrNothing finished all ' + %char(copied) + ' batches');
  on-error;
    // canceled: Async_Await sent CPF9898
    say('allOrNothing: ' + Async_ErrorText(allTask));
  endmon;

  p = Async_Await(someTask);
  say('whatYouCan stopped after ' + %char(copied) + ' of '
    + %char(TOTAL_BATCHES) + ' batches; its result is kept');

  Async_Free(allTask);
  Async_Free(someTask);
  say('Done.');
end-proc;

// arg: int(10) batches. Stops at the first check after a cancel.
dcl-proc allOrNothing;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s batches int(10) based(arg);
  dcl-s i int(10);

  for i = 1 to batches;
    Async_ThrowIfCanceled();
    copyBatch(i);
  endfor;
  return Async_Return(%addr(batches): %size(batches));
end-proc;

// arg: int(10) batches. Result: int(10) batches copied.
dcl-proc whatYouCan;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s batches int(10) based(arg);
  dcl-s copied int(10) inz(0);

  dow copied < batches and not Async_IsCancelRequested();
    copied += 1;
    copyBatch(copied);
  enddo;
  return Async_Return(%addr(copied): %size(copied));
end-proc;

dcl-proc copyBatch;
  dcl-pi *n;
    batch int(10) value;
  end-pi;

  Async_Sleep(100);         // stands in for real work
end-proc;

// One line to standard output (QPRINT in batch); x'25' is LF
dcl-proc say;
  dcl-pi *n;
    text varchar(1024) const;
  end-pi;

  printf('%s' + x'25': text);
end-proc;
