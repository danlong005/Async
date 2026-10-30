**free
// ------------------------------------------------------------------
// ASYNCNTS - helper for ASYNCIT scenario "nothreadsafe"
//
// Compiled WITHOUT THREAD(*CONCURRENT): runs a task procedure from
// this module on another thread and reports what happened in
// outcome.
// ------------------------------------------------------------------
ctl-opt main(main) option(*srcstmt: *nodebugio);

/copy qrpgleref/async.rpgleinc

dcl-ds psds psds qualified;
  excId char(7) pos(40);
  excData char(80) pos(91);
end-ds;

dcl-proc main;
  dcl-pi *n;
    outcome char(100);
  end-pi;
  dcl-s n int(10) inz(10);
  dcl-s task int(10);
  dcl-s p pointer;
  dcl-s total int(20) based(p);

  monitor;
    task = Async_Run(%paddr(sumTo): %addr(n));
    p = Async_Await(task);
    outcome = 'task ran; result ' + %char(total);
  on-error;
    outcome = 'error ' + psds.excId + ' ' + %trim(psds.excData);
  endmon;
end-proc;

dcl-proc sumTo;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s n int(10) based(arg);
  dcl-s total int(20) static;
  dcl-s i int(10);

  total = 0;
  for i = 1 to n;
    total += i;
  endfor;
  return %addr(total);
end-proc;
