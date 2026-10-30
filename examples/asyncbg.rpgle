**free
// ------------------------------------------------------------------
// ASYNCBG - fire-and-forget background work
//
//   SBMJOB CMD(CALL ASYNCBG) ALWMLTTHD(*YES)    (output: QPRINT,
//                                                /tmp/asyncbg.log)
//
// Writes three audit lines in the background while main carries on,
// without waiting for them: each task is freed as soon as it is
// started (Async_Run, then Async_Free), so nobody awaits it.
//
// Things to know about fire and forget:
//
// - The task's argument must outlive the caller's variables, so each
//   one gets its own copy on the heap (%alloc), which the task
//   deallocates when it is done.
// - Nobody sees the task's result or its errors. If they matter,
//   handle or log them inside the task.
// - When the program ends with background tasks still running, ASYNC
//   waits for them: main returns at once, but the job's program call
//   ends only when all three lines are written. Run it and then look
//   at /tmp/asyncbg.log: all three lines are there.
// ------------------------------------------------------------------
ctl-opt main(main) thread(*concurrent) option(*srcstmt: *nodebugio)
        bnddir('QC2LE');

/copy qrpgleref/async.rpgleinc

dcl-pr printf int(10) extproc('printf');
  format pointer value options(*string);
  text pointer value options(*string: *nopass);
end-pr;

dcl-c LOG_FILE '/tmp/asyncbg.log';

dcl-c O_WRONLY 2;
dcl-c O_CREAT 8;
dcl-c O_CCSID 32;
dcl-c O_APPEND 256;
dcl-c O_TEXTDATA 16777216;
dcl-c O_TEXT_CREAT 33554432;

dcl-pr ifsOpen int(10) extproc('open');
  path pointer value options(*string);
  flags int(10) value;
  mode uns(10) value options(*nopass);
  ccsid uns(10) value options(*nopass);
  textCcsid uns(10) value options(*nopass);
end-pr;

dcl-pr ifsWrite int(10) extproc('write');
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

dcl-proc main;
  dcl-s i int(10);

  ifsUnlink(LOG_FILE);
  for i = 1 to 3;
    audit('order ' + %char(100 + i) + ' shipped');
  endfor;
  say('main: three audit lines are being written in the background');
  say('main: returning now; ASYNC waits for them before the program ends');
  say('Done.');
end-proc;

// Start a background write of text and forget about it
dcl-proc audit;
  dcl-pi *n;
    text varchar(200) const;
  end-pi;
  dcl-s copy pointer;
  dcl-s line varchar(200) based(copy);

  // the task gets its own copy; text goes away when audit returns
  copy = %alloc(%size(line));
  line = text;
  Async_Free(Async_Run(%paddr(writeAudit): copy));
end-proc;

// The task: arg is a varchar(200) on the heap, which it deallocates.
// Appends one line to LOG_FILE.
dcl-proc writeAudit;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s text varchar(200) based(arg);
  dcl-s line varchar(240);
  dcl-s fd int(10);

  Async_Sleep(500);         // stands in for a slow disk or network
  line = %char(%timestamp()) + ' ' + text + x'25';
  dealloc arg;

  // CCSID 819 file, written from the job's CCSID
  fd = ifsOpen(LOG_FILE: O_WRONLY + O_CREAT + O_APPEND + O_CCSID
                         + O_TEXTDATA + O_TEXT_CREAT: 420: 819: 0);
  if fd >= 0;
    ifsWrite(fd: %addr(line: *data): %len(line));
    ifsClose(fd);
  endif;
  return *null;
end-proc;

// One line to standard output (QPRINT in batch); x'25' is LF
dcl-proc say;
  dcl-pi *n;
    text varchar(1024) const;
  end-pi;

  printf('%s' + x'25': text);
end-proc;
