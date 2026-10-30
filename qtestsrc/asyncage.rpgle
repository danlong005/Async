**free
// ------------------------------------------------------------------
// ASYNCAGE - helper for ASYNCIT scenario "agend"
//
// Starts two tasks and returns at once without awaiting them:
// - one sleeps 2 s and never checks for cancellation
// - one would run for 10 s, but stops when canceled
// Created with ACTGRP(*NEW), so returning ends the activation group
// the tasks run in. ASYNC must cancel the second, wait for the
// first, and only then let the activation group go: returning takes
// about 2 s, and neither thread is left running in freed storage.
// ------------------------------------------------------------------
ctl-opt main(main) thread(*concurrent) option(*srcstmt: *nodebugio);

/copy qrpgleref/async.rpgleinc

dcl-proc main;
  dcl-s ms int(10) inz(2000) static(*allthread);

  Async_Run(%paddr(sleepFor): %addr(ms));
  Async_Run(%paddr(untilCanceled));
end-proc;

dcl-proc sleepFor;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s ms int(10) based(arg);

  Async_Sleep(ms);
  return *null;
end-proc;

dcl-proc untilCanceled;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s i int(10);

  for i = 1 to 1000;
    Async_ThrowIfCanceled();
    Async_Sleep(10);
  endfor;
  return *null;
end-proc;
