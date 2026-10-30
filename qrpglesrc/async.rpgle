**free
// ------------------------------------------------------------------
// ASYNC - async/await for ILE RPG, built on POSIX threads
//
// Async_Run starts a procedure on a new detached thread and hands
// back a task handle. Async_Await blocks until the task is done and
// returns its result or, if the task ended with an escape message,
// sends that message again to the caller of Async_Await, so
// MONITOR around Async_Await works like try { await } catch.
//
// All task state is guarded by one mutex and one condition
// variable. Every state change broadcasts the condition and waiters
// re-check whatever they are waiting for. Task procedures never run
// with the mutex held.
//
// A handle is gen * ASYNC_MAX_TASKS + slot - 1, where gen counts
// how often the slot was used, so a freed handle stays invalid when
// its slot is reused.
//
// ASYNC runs in its caller's activation group, and so do its
// threads. When that activation group ends, its storage goes, so no
// task thread may still be running: an exit registered with
// CEE4RAGE asks every task to cancel and waits for all threads to
// end before the activation group is destroyed.
// ------------------------------------------------------------------
ctl-opt nomain thread(*concurrent) option(*srcstmt: *nodebugio)
        bnddir('QC2LE') text('Async/await for ILE RPG');

/copy qrpglesrc/async.rpgleinc

dcl-c KIND_RUN 1;
dcl-c KIND_PROMISE 2;
dcl-c KIND_DELAY 3;
dcl-c KIND_THEN 4;

dcl-c WAIT_ALL 1;
dcl-c WAIT_ANY 2;

dcl-c MAX_GEN 500000;
dcl-c PTHREAD_CREATE_DETACHED 1;

// "QP0WMTX UNNAMED" in CCSID 37, from PTHREAD_MUTEX_INITIALIZER
dcl-c PTHREAD_INIT_NAME x'D8D7F0E6D4E3E740E4D5D5C1D4C5C400';

dcl-ds task_t qualified template;
  handle int(10);
  kind int(10);
  state int(10);
  proc pointer(*proc);
  arg pointer;
  source int(10);
  delayMs int(10);
  result pointer;
  resultBuf pointer;
  resultLen int(10);
  threadActive ind;
  cancelReq ind;
  autoFree ind;
  errId char(7);
  errMsgf char(20);
  errData varchar(1024);
  errText varchar(1024);
end-ds;

// ------------------------------------------------------------ pthreads
dcl-ds pthread_t qualified template align;
  reserved pointer;
  hiId uns(10);
  loId uns(10);
  handle uns(10);
  reservedC uns(10);
  reserved1 pointer;
end-ds;

dcl-ds pthread_attr_t qualified template align;
  reserved uns(10) dim(4);
  reserved1 pointer;
end-ds;

dcl-ds mutex_t qualified template align;
  reserved pointer inz(*null);
  name char(16) inz(PTHREAD_INIT_NAME);
end-ds;

dcl-ds cond_t qualified template align;
  reserved pointer inz(*null);
  name char(16) inz(PTHREAD_INIT_NAME);
  reserved2 pointer dim(3) inz(*null);
end-ds;

dcl-ds timespec_t qualified template;
  tv_sec int(10);
  tv_nsec int(10);
end-ds;

dcl-pr pthread_create int(10) extproc('pthread_create');
  thread likeds(pthread_t);
  attr likeds(pthread_attr_t) const;
  start pointer(*proc) value;
  arg pointer value;
end-pr;

dcl-pr pthread_attr_init int(10) extproc('pthread_attr_init');
  attr likeds(pthread_attr_t);
end-pr;

dcl-pr pthread_attr_setdetachstate int(10)
       extproc('pthread_attr_setdetachstate');
  attr likeds(pthread_attr_t);
  state int(10) value;
end-pr;

dcl-pr pthread_attr_destroy int(10) extproc('pthread_attr_destroy');
  attr likeds(pthread_attr_t);
end-pr;

dcl-pr pthread_mutex_lock int(10) extproc('pthread_mutex_lock');
  mutex likeds(mutex_t);
end-pr;

dcl-pr pthread_mutex_unlock int(10) extproc('pthread_mutex_unlock');
  mutex likeds(mutex_t);
end-pr;

dcl-pr pthread_cond_wait int(10) extproc('pthread_cond_wait');
  cond likeds(cond_t);
  mutex likeds(mutex_t);
end-pr;

dcl-pr pthread_cond_timedwait int(10) extproc('pthread_cond_timedwait');
  cond likeds(cond_t);
  mutex likeds(mutex_t);
  abstime likeds(timespec_t) const;
end-pr;

dcl-pr pthread_cond_broadcast int(10) extproc('pthread_cond_broadcast');
  cond likeds(cond_t);
end-pr;

dcl-pr pthread_get_expiration_np int(10)
       extproc('pthread_get_expiration_np');
  delta likeds(timespec_t) const;
  abstime likeds(timespec_t);
end-pr;

dcl-pr pthread_delay_np int(10) extproc('pthread_delay_np');
  interval likeds(timespec_t) const;
end-pr;

dcl-pr memcpy pointer extproc('memcpy');
  dest pointer value;
  src pointer value;
  len uns(10) value;
end-pr;

// ------------------------------------------------------------ messages
dcl-ds errc_t qualified template;
  bytesProv int(10) inz(0);
  bytesAvail int(10) inz(0);
  msgId char(7);
  reserved char(1);
  data char(256);
end-ds;

dcl-ds rcvm0200_t qualified template;
  bytesRet int(10) pos(1);
  bytesAvail int(10) pos(5);
  msgId char(7) pos(13);
  msgType char(2) pos(20);
  msgf char(10) pos(26);
  msgfLib char(10) pos(46);
  dataLen int(10) pos(153);
  textLen int(10) pos(161);
  var char(4000) pos(177);
end-ds;

dcl-pr QMHSNDPM extpgm('QMHSNDPM');
  msgId char(7) const;
  msgf char(20) const;
  msgData char(1024) const options(*varsize);
  msgDataLen int(10) const;
  msgType char(10) const;
  callStackEntry char(10) const;
  callStackCounter int(10) const;
  msgKey char(4);
  errCode likeds(errc_t);
end-pr;

dcl-pr QMHRCVPM extpgm('QMHRCVPM');
  rcvVar likeds(rcvm0200_t);
  rcvLen int(10) const;
  format char(8) const;
  callStackEntry char(10) const;
  callStackCounter int(10) const;
  msgType char(10) const;
  msgKey char(4) const;
  waitTime int(10) const;
  action char(10) const;
  errCode likeds(errc_t);
end-pr;

dcl-pr CEE4RAGE extproc('CEE4RAGE');
  exitProc pointer(*proc) const;
  feedback char(12) options(*omit);
end-pr;

dcl-ds psds psds qualified;
  excId char(7) pos(40);
  excData char(80) pos(91);
end-ds;

// ------------------------------------------------------------ state
// Shared by all threads, guarded by gMutex
dcl-ds gMutex likeds(mutex_t) inz(*likeds) static(*allthread);
dcl-ds gCond likeds(cond_t) inz(*likeds) static(*allthread);
dcl-s gTask pointer dim(ASYNC_MAX_TASKS) inz(*null) static(*allthread);
dcl-s gGen int(10) dim(ASYNC_MAX_TASKS) inz(0) static(*allthread);
dcl-s gNextSlot int(10) inz(1) static(*allthread);
// Task threads still running, freed tasks included
dcl-s gThreads int(10) inz(0) static(*allthread);
// The activation group is ending: every task counts as canceled
dcl-s gEnding ind inz(*off) static(*allthread);
dcl-s gExitRegistered ind inz(*off) static(*allthread);

// One per thread (THREAD(*CONCURRENT) globals are thread local)
dcl-s tCurrent int(10) inz(0);
dcl-s tTask pointer inz(*null);
dcl-s tCancelThrown ind inz(*off);
dcl-s tProc pointer(*proc);

// ==================================================================
// Starting tasks
// ==================================================================

dcl-proc Async_Run export;
  dcl-pi *n int(10);
    proc pointer(*proc) value;
    arg pointer value options(*nopass);
  end-pi;
  dcl-s a pointer inz(*null);

  if %parms >= 2;
    a = arg;
  endif;
  return startThread(KIND_RUN: proc: a: 0: 0);
end-proc;

dcl-proc Async_Then export;
  dcl-pi *n int(10);
    task int(10) value;
    proc pointer(*proc) value;
  end-pi;
  dcl-s known ind;

  mutexLock();
  known = findTask(task) <> *null;
  mutexUnlock();
  if not known;
    fail(badHandle(task));
  endif;
  return startThread(KIND_THEN: proc: *null: task: 0);
end-proc;

dcl-proc Async_Delay export;
  dcl-pi *n int(10);
    ms int(10) value;
  end-pi;

  return startThread(KIND_DELAY: *null: *null: 0: ms);
end-proc;

dcl-proc Async_Promise export;
  dcl-pi *n int(10);
  end-pi;
  dcl-s p pointer;
  dcl-ds t likeds(task_t) based(p);
  dcl-s h int(10);

  mutexLock();
  p = newTask(KIND_PROMISE);
  if p <> *null;
    h = t.handle;
  endif;
  mutexUnlock();
  if p = *null;
    fail('Async: more than ' + %char(ASYNC_MAX_TASKS)
       + ' tasks exist; Async_Free tasks you are done with');
  endif;
  return h;
end-proc;

// Create a task and the thread that runs it
dcl-proc startThread;
  dcl-pi *n int(10);
    kind int(10) value;
    proc pointer(*proc) value;
    arg pointer value;
    source int(10) value;
    delayMs int(10) value;
  end-pi;
  dcl-s p pointer;
  dcl-ds t likeds(task_t) based(p);
  dcl-s h int(10);
  dcl-s rc int(10);
  dcl-ds thread likeds(pthread_t);
  dcl-ds attr likeds(pthread_attr_t);

  mutexLock();
  p = newTask(kind);
  if p <> *null;
    t.proc = proc;
    t.arg = arg;
    t.source = source;
    t.delayMs = delayMs;
    t.threadActive = *on;
    h = t.handle;
    gThreads += 1;
    if not gExitRegistered;
      CEE4RAGE(%paddr(activationGroupEnding): *omit);
      gExitRegistered = *on;
    endif;
  endif;
  mutexUnlock();
  if p = *null;
    fail('Async: more than ' + %char(ASYNC_MAX_TASKS)
       + ' tasks exist; Async_Free tasks you are done with');
  endif;

  pthread_attr_init(attr);
  pthread_attr_setdetachstate(attr: PTHREAD_CREATE_DETACHED);
  rc = pthread_create(thread: attr: %paddr(threadMain): p);
  pthread_attr_destroy(attr);

  if rc <> 0;
    mutexLock();
    destroyTask(p);
    gThreads -= 1;
    mutexUnlock();
    fail('Async: could not start a thread (errno ' + %char(rc)
       + '). Does the job allow threads? Use ALWMLTTHD(*YES)');
  endif;
  return h;
end-proc;

// Start routine of every task thread; p is the task
dcl-proc threadMain;
  dcl-pi *n pointer;
    p pointer value;
  end-pi;
  dcl-ds t likeds(task_t) based(p);
  dcl-pr callProc pointer extproc(tProc);
    arg pointer value;
  end-pr;
  dcl-s arg pointer;
  dcl-s res pointer;
  dcl-s ok ind;
  dcl-s runIt ind inz(*on);

  // kind, proc and arg do not change once the thread is started
  tCurrent = t.handle;
  tTask = p;
  tCancelThrown = *off;
  tProc = t.proc;
  arg = t.arg;

  if t.kind = KIND_DELAY;
    runDelay(p);
    runIt = *off;
  elseif t.kind = KIND_THEN;
    runIt = awaitSource(p: arg);
  endif;

  if runIt;
    monitor;
      res = callProc(arg);
      ok = *on;
    on-error;
      ok = *off;
    endmon;

    if ok;
      mutexLock();
      settle(p: ASYNC_FULFILLED: res);
      mutexUnlock();
    else;
      captureError(p);
    endif;
  endif;

  tCurrent = 0;
  tTask = *null;

  // Last use of activation group storage: once gThreads drops, the
  // activation group may end at any moment
  mutexLock();
  t.threadActive = *off;
  if t.autoFree;
    destroyTask(p);
  endif;
  gThreads -= 1;
  pthread_cond_broadcast(gCond);
  mutexUnlock();
  return *null;
end-proc;

// Delay task: wait delayMs or until canceled
dcl-proc runDelay;
  dcl-pi *n;
    p pointer value;
  end-pi;
  dcl-ds t likeds(task_t) based(p);
  dcl-ds deadline likeds(timespec_t);

  mutexLock();
  if t.delayMs > 0;
    expiration(t.delayMs: deadline);
    dow not t.cancelReq and not gEnding;
      if pthread_cond_timedwait(gCond: gMutex: deadline) <> 0;
        leave;
      endif;
    enddo;
  endif;
  if t.cancelReq or gEnding;
    settle(p: ASYNC_CANCELED: *null);
  else;
    settle(p: ASYNC_FULFILLED: *null);
  endif;
  mutexUnlock();
end-proc;

// Then task: wait for the source task. *on and arg = its result if
// it was fulfilled; otherwise this task is settled the same way.
dcl-proc awaitSource;
  dcl-pi *n ind;
    p pointer value;
    arg pointer;
  end-pi;
  dcl-ds t likeds(task_t) based(p);
  dcl-s sp pointer;
  dcl-ds s likeds(task_t) based(sp);
  dcl-s run ind inz(*off);

  mutexLock();
  dow '1';
    sp = findTask(t.source);
    if sp = *null;
      t.errId = 'CPF9898';
      t.errMsgf = 'QCPFMSG   *LIBL';
      t.errText = 'Async: task ' + %char(t.source)
                + ' was freed before it was done';
      t.errData = t.errText;
      settle(p: ASYNC_REJECTED: *null);
      leave;
    endif;
    if s.state <> ASYNC_PENDING;
      if s.state = ASYNC_FULFILLED;
        arg = s.result;
        run = *on;
      elseif s.state = ASYNC_REJECTED;
        t.errId = s.errId;
        t.errMsgf = s.errMsgf;
        t.errData = s.errData;
        t.errText = s.errText;
        settle(p: ASYNC_REJECTED: *null);
      else;
        settle(p: ASYNC_CANCELED: *null);
      endif;
      leave;
    endif;
    if t.cancelReq or gEnding;
      settle(p: ASYNC_CANCELED: *null);
      leave;
    endif;
    pthread_cond_wait(gCond: gMutex);
  enddo;
  mutexUnlock();
  return run;
end-proc;

// Record the escape message the task procedure ended with (still
// in threadMain's call message queue) and reject or cancel the task
dcl-proc captureError;
  dcl-pi *n;
    p pointer value;
  end-pi;
  dcl-ds t likeds(task_t) based(p);
  dcl-ds m likeds(rcvm0200_t) inz;
  dcl-ds ec likeds(errc_t) inz(*likeds);
  dcl-s id char(7);
  dcl-s msgf char(20);
  dcl-s data varchar(1024);
  dcl-s text varchar(1024);
  dcl-s dataLen int(10);
  dcl-s textLen int(10);

  ec.bytesProv = %size(ec);
  QMHRCVPM(m: %size(m): 'RCVM0200': '*': 1: '*EXCP': *blanks: 0:
           '*SAME': ec);
  if ec.bytesAvail = 0 and m.bytesRet > 0 and m.msgId <> *blanks;
    id = m.msgId;
    msgf = m.msgf + m.msgfLib;
    dataLen = %min(m.dataLen: %len(m.var): 1024);
    if dataLen > 0;
      data = %subst(m.var: 1: dataLen);
    endif;
    textLen = %min(m.textLen: %len(m.var) - dataLen: 1024);
    if textLen > 0;
      text = %subst(m.var: dataLen + 1: textLen);
    endif;
  else;
    id = psds.excId;
    text = %trim(psds.excData);
  endif;
  if text = '';
    text = 'Async task failed with ' + id;
  endif;

  mutexLock();
  t.errId = id;
  t.errMsgf = msgf;
  t.errData = data;
  t.errText = text;
  if tCancelThrown;
    settle(p: ASYNC_CANCELED: *null);
  else;
    settle(p: ASYNC_REJECTED: *null);
  endif;
  mutexUnlock();
end-proc;

// ==================================================================
// Awaiting
// ==================================================================

dcl-proc Async_Await export;
  dcl-pi *n pointer;
    task int(10) value;
  end-pi;

  return awaitOne(task);
end-proc;

dcl-proc Async_AwaitAll export;
  dcl-pi *n;
    tasks int(10) dim(ASYNC_MAX_TASKS) const options(*varsize);
    count int(10) value;
  end-pi;
  dcl-s i int(10);
  dcl-ds snap likeds(task_t);

  waitTasks(tasks: count: WAIT_ALL: ASYNC_FOREVER);
  for i = 1 to count;
    if not snapshot(tasks(i): snap);
      fail(badHandle(tasks(i)));
    endif;
    if snap.state <> ASYNC_FULFILLED;
      rethrow(snap);
    endif;
  endfor;
end-proc;

dcl-proc Async_AwaitAny export;
  dcl-pi *n int(10);
    tasks int(10) dim(ASYNC_MAX_TASKS) const options(*varsize);
    count int(10) value;
  end-pi;

  if count < 1;
    fail('Async_AwaitAny: no tasks to wait for');
  endif;
  return waitTasks(tasks: count: WAIT_ANY: ASYNC_FOREVER);
end-proc;

dcl-proc Async_Wait export;
  dcl-pi *n ind;
    task int(10) value;
    timeoutMs int(10) value;
  end-pi;
  dcl-s one int(10) dim(1);

  one(1) = task;
  return waitTasks(one: 1: WAIT_ALL: timeoutMs) > 0;
end-proc;

dcl-proc Async_WaitAll export;
  dcl-pi *n ind;
    tasks int(10) dim(ASYNC_MAX_TASKS) const options(*varsize);
    count int(10) value;
    timeoutMs int(10) value;
  end-pi;

  if count < 1;
    return *on;
  endif;
  return waitTasks(tasks: count: WAIT_ALL: timeoutMs) > 0;
end-proc;

dcl-proc Async_WaitAny export;
  dcl-pi *n int(10);
    tasks int(10) dim(ASYNC_MAX_TASKS) const options(*varsize);
    count int(10) value;
    timeoutMs int(10) value;
  end-pi;

  if count < 1;
    fail('Async_WaitAny: no tasks to wait for');
  endif;
  return waitTasks(tasks: count: WAIT_ANY: timeoutMs);
end-proc;

// Wait for one task; its result, or its error sent to the program
// that called into ASYNC
dcl-proc awaitOne;
  dcl-pi *n pointer;
    task int(10) value;
  end-pi;
  dcl-s one int(10) dim(1);
  dcl-ds snap likeds(task_t);

  if task = tCurrent and task <> 0;
    fail('Async: task ' + %char(task) + ' cannot await itself');
  endif;
  one(1) = task;
  waitTasks(one: 1: WAIT_ALL: ASYNC_FOREVER);
  if not snapshot(task: snap);
    fail(badHandle(task));
  endif;
  if snap.state <> ASYNC_FULFILLED;
    rethrow(snap);
  endif;
  return snap.result;
end-proc;

// Block until all (WAIT_ALL) or one (WAIT_ANY) of tasks(1..count)
// are done or timeoutMs passes. Returns: WAIT_ALL count, WAIT_ANY
// the index of the first done task, 0 on timeout. Unknown handles
// end the program that called into ASYNC with CPF9898.
dcl-proc waitTasks;
  dcl-pi *n int(10);
    tasks int(10) dim(ASYNC_MAX_TASKS) const options(*varsize);
    count int(10) value;
    mode int(10) value;
    timeoutMs int(10) value;
  end-pi;
  dcl-s p pointer;
  dcl-ds t likeds(task_t) based(p);
  dcl-ds deadline likeds(timespec_t);
  dcl-s expired ind inz(*off);
  dcl-s i int(10);
  dcl-s done int(10);
  dcl-s first int(10);
  dcl-s bad int(10) inz(0);
  dcl-s rc int(10) inz(0);

  if count < 1;
    return 0;
  endif;
  if count > ASYNC_MAX_TASKS;
    fail('Async: cannot wait for more than ' + %char(ASYNC_MAX_TASKS)
       + ' tasks');
  endif;

  mutexLock();
  if timeoutMs > 0;
    expiration(timeoutMs: deadline);
  endif;
  dow bad = 0;
    done = 0;
    first = 0;
    for i = 1 to count;
      p = findTask(tasks(i));
      if p = *null;
        bad = i;
        leave;
      endif;
      if t.state <> ASYNC_PENDING;
        done += 1;
        if first = 0;
          first = i;
        endif;
      endif;
    endfor;
    if bad > 0;
      leave;
    endif;
    if mode = WAIT_ANY and first > 0;
      rc = first;
      leave;
    endif;
    if mode = WAIT_ALL and done = count;
      rc = count;
      leave;
    endif;
    if expired or timeoutMs = 0;
      leave;
    endif;

    if timeoutMs < 0;
      pthread_cond_wait(gCond: gMutex);
    elseif pthread_cond_timedwait(gCond: gMutex: deadline) <> 0;
      expired = *on;
    endif;
  enddo;
  mutexUnlock();

  if bad > 0;
    fail(badHandle(tasks(bad)));
  endif;
  return rc;
end-proc;

// Copy of a task's state, taken under the lock; *off if unknown
dcl-proc snapshot;
  dcl-pi *n ind;
    task int(10) value;
    snap likeds(task_t);
  end-pi;
  dcl-s p pointer;
  dcl-ds t likeds(task_t) based(p);

  mutexLock();
  p = findTask(task);
  if p <> *null;
    snap = t;
  endif;
  mutexUnlock();
  return p <> *null;
end-proc;

// ==================================================================
// Settling, canceling, freeing
// ==================================================================

dcl-proc Async_Resolve export;
  dcl-pi *n ind;
    task int(10) value;
    result pointer value options(*nopass);
    len int(10) value options(*nopass);
  end-pi;
  dcl-s p pointer;
  dcl-ds t likeds(task_t) based(p);
  dcl-s res pointer inz(*null);
  dcl-s copyLen int(10) inz(0);
  dcl-s settled ind inz(*off);

  if %parms >= 2;
    res = result;
  endif;
  if %parms >= 3;
    copyLen = len;
  endif;

  mutexLock();
  p = findTask(task);
  if p <> *null and t.state = ASYNC_PENDING;
    if copyLen > 0 and res <> *null;
      keepResult(p: res: copyLen);
      res = t.resultBuf;
    endif;
    settled = settle(p: ASYNC_FULFILLED: res);
  endif;
  mutexUnlock();
  if p = *null;
    fail(badHandle(task));
  endif;
  return settled;
end-proc;

dcl-proc Async_Reject export;
  dcl-pi *n ind;
    task int(10) value;
    text varchar(1024) const;
  end-pi;
  dcl-s p pointer;
  dcl-ds t likeds(task_t) based(p);
  dcl-s settled ind inz(*off);

  mutexLock();
  p = findTask(task);
  if p <> *null and t.state = ASYNC_PENDING;
    t.errId = 'CPF9898';
    t.errMsgf = 'QCPFMSG   *LIBL';
    t.errData = text;
    t.errText = text;
    settled = settle(p: ASYNC_REJECTED: *null);
  endif;
  mutexUnlock();
  if p = *null;
    fail(badHandle(task));
  endif;
  return settled;
end-proc;

dcl-proc Async_Cancel export;
  dcl-pi *n ind;
    task int(10) value;
  end-pi;
  dcl-s p pointer;
  dcl-ds t likeds(task_t) based(p);
  dcl-s pending ind inz(*off);

  mutexLock();
  p = findTask(task);
  if p <> *null and t.state = ASYNC_PENDING;
    pending = *on;
    t.cancelReq = *on;
    if t.kind = KIND_PROMISE;
      settle(p: ASYNC_CANCELED: *null);
    else;
      // wake delays and thens so they see cancelReq
      pthread_cond_broadcast(gCond);
    endif;
  endif;
  mutexUnlock();
  if p = *null;
    fail(badHandle(task));
  endif;
  return pending;
end-proc;

dcl-proc Async_Free export;
  dcl-pi *n;
    task int(10) value;
  end-pi;
  dcl-s p pointer;
  dcl-ds t likeds(task_t) based(p);

  mutexLock();
  p = findTask(task);
  if p <> *null;
    // a running task leaves the table now; its thread frees the
    // storage when it ends
    gTask(%rem(task: ASYNC_MAX_TASKS) + 1) = *null;
    if t.threadActive;
      t.autoFree = *on;
    else;
      destroyTask(p);
    endif;
    // waiters on this task must see that it is gone
    pthread_cond_broadcast(gCond);
  endif;
  mutexUnlock();
end-proc;

// ==================================================================
// Inspecting
// ==================================================================

dcl-proc Async_Status export;
  dcl-pi *n int(10);
    task int(10) value;
  end-pi;
  dcl-ds snap likeds(task_t);

  if not snapshot(task: snap);
    fail(badHandle(task));
  endif;
  return snap.state;
end-proc;

dcl-proc Async_IsDone export;
  dcl-pi *n ind;
    task int(10) value;
  end-pi;
  dcl-ds snap likeds(task_t);

  if not snapshot(task: snap);
    fail(badHandle(task));
  endif;
  return snap.state <> ASYNC_PENDING;
end-proc;

dcl-proc Async_Result export;
  dcl-pi *n pointer;
    task int(10) value;
  end-pi;
  dcl-ds snap likeds(task_t);

  if not snapshot(task: snap);
    fail(badHandle(task));
  endif;
  if snap.state <> ASYNC_FULFILLED;
    return *null;
  endif;
  return snap.result;
end-proc;

dcl-proc Async_ResultLen export;
  dcl-pi *n int(10);
    task int(10) value;
  end-pi;
  dcl-ds snap likeds(task_t);

  if not snapshot(task: snap);
    fail(badHandle(task));
  endif;
  if snap.state <> ASYNC_FULFILLED or snap.result <> snap.resultBuf;
    return 0;
  endif;
  return snap.resultLen;
end-proc;

dcl-proc Async_ErrorId export;
  dcl-pi *n char(7);
    task int(10) value;
  end-pi;
  dcl-ds snap likeds(task_t);

  if not snapshot(task: snap);
    fail(badHandle(task));
  endif;
  return snap.errId;
end-proc;

dcl-proc Async_ErrorText export;
  dcl-pi *n varchar(1024);
    task int(10) value;
  end-pi;
  dcl-ds snap likeds(task_t);

  if not snapshot(task: snap);
    fail(badHandle(task));
  endif;
  return snap.errText;
end-proc;

// ==================================================================
// Inside a task
// ==================================================================

dcl-proc Async_Return export;
  dcl-pi *n pointer;
    data pointer value;
    len int(10) value;
  end-pi;
  dcl-s p pointer;
  dcl-ds t likeds(task_t) based(p);
  dcl-s res pointer inz(*null);

  p = tTask;
  mutexLock();
  if p <> *null;
    keepResult(p: data: len);
    res = t.resultBuf;
  endif;
  mutexUnlock();
  if p = *null;
    fail('Async_Return: not called from a task');
  endif;
  return res;
end-proc;

dcl-proc Async_Throw export;
  dcl-pi *n;
    text varchar(1024) const;
  end-pi;

  fail(text);
end-proc;

dcl-proc Async_IsCancelRequested export;
  dcl-pi *n ind;
  end-pi;
  dcl-s p pointer;
  dcl-ds t likeds(task_t) based(p);
  dcl-s canceled ind inz(*off);

  p = tTask;
  mutexLock();
  if p <> *null;
    canceled = t.cancelReq or gEnding;
  endif;
  mutexUnlock();
  return canceled;
end-proc;

dcl-proc Async_ThrowIfCanceled export;
  dcl-pi *n;
  end-pi;

  if Async_IsCancelRequested();
    tCancelThrown = *on;
    fail('Async: task ' + %char(tCurrent) + ' was canceled');
  endif;
end-proc;

dcl-proc Async_Current export;
  dcl-pi *n int(10);
  end-pi;

  return tCurrent;
end-proc;

dcl-proc Async_Sleep export;
  dcl-pi *n;
    ms int(10) value;
  end-pi;
  dcl-ds interval likeds(timespec_t);

  if ms > 0;
    interval.tv_sec = %div(ms: 1000);
    interval.tv_nsec = %rem(ms: 1000) * 1000000;
    pthread_delay_np(interval);
  endif;
end-proc;

// ==================================================================
// Activation group end
// ==================================================================

// Called (CEE4RAGE) when the activation group ASYNC runs in ends.
// Cancels every task and waits for every task thread to end, so none
// is left running in storage that is about to be destroyed. Tasks
// that do not check for cancellation are waited for until they
// return.
dcl-proc activationGroupEnding;
  dcl-pi *n;
    agMark uns(10);
    reason uns(10);
    resultCode uns(10);
    userRc uns(10);
  end-pi;
  dcl-s p pointer;
  dcl-ds t likeds(task_t) based(p);
  dcl-s i int(10);

  mutexLock();
  gEnding = *on;
  for i = 1 to ASYNC_MAX_TASKS;
    p = gTask(i);
    if p <> *null;
      if t.state = ASYNC_PENDING and t.kind = KIND_PROMISE;
        settle(p: ASYNC_CANCELED: *null);
      endif;
    endif;
  endfor;
  pthread_cond_broadcast(gCond);
  dow gThreads > 0;
    pthread_cond_wait(gCond: gMutex);
  enddo;
  mutexUnlock();
end-proc;

// ==================================================================
// Task table (call these with gMutex held)
// ==================================================================

dcl-proc findTask;
  dcl-pi *n pointer;
    handle int(10) value;
  end-pi;
  dcl-s p pointer;
  dcl-ds t likeds(task_t) based(p);

  if handle <= 0;
    return *null;
  endif;
  p = gTask(%rem(handle: ASYNC_MAX_TASKS) + 1);
  if p = *null;
    return *null;
  endif;
  if t.handle <> handle;
    return *null;
  endif;
  return p;
end-proc;

dcl-proc newTask;
  dcl-pi *n pointer;
    kind int(10) value;
  end-pi;
  dcl-s p pointer;
  dcl-ds t likeds(task_t) based(p);
  dcl-s slot int(10);
  dcl-s tries int(10);

  slot = gNextSlot;
  for tries = 1 to ASYNC_MAX_TASKS;
    if gTask(slot) = *null;
      leave;
    endif;
    slot = %rem(slot: ASYNC_MAX_TASKS) + 1;
  endfor;
  if gTask(slot) <> *null;
    return *null;
  endif;

  p = %alloc(%size(task_t));
  clear t;
  gGen(slot) = %rem(gGen(slot): MAX_GEN) + 1;
  t.handle = gGen(slot) * ASYNC_MAX_TASKS + slot - 1;
  t.kind = kind;
  t.state = ASYNC_PENDING;
  t.arg = *null;
  t.proc = *null;
  t.result = *null;
  t.resultBuf = *null;
  gTask(slot) = p;
  gNextSlot = %rem(slot: ASYNC_MAX_TASKS) + 1;
  return p;
end-proc;

dcl-proc destroyTask;
  dcl-pi *n;
    p pointer value;
  end-pi;
  dcl-ds t likeds(task_t) based(p);
  dcl-s slot int(10);

  slot = %rem(t.handle: ASYNC_MAX_TASKS) + 1;
  // the slot may hold a newer task if this one was freed running
  if gTask(slot) = p;
    gTask(slot) = *null;
  endif;
  if t.resultBuf <> *null;
    dealloc t.resultBuf;
  endif;
  dealloc p;
end-proc;

// Settle a pending task and wake every waiter; *off if it was done
dcl-proc settle;
  dcl-pi *n ind;
    p pointer value;
    state int(10) value;
    result pointer value;
  end-pi;
  dcl-ds t likeds(task_t) based(p);

  if t.state <> ASYNC_PENDING;
    return *off;
  endif;
  t.state = state;
  t.result = result;
  pthread_cond_broadcast(gCond);
  return *on;
end-proc;

// Copy len bytes at data into the task's own result storage
dcl-proc keepResult;
  dcl-pi *n;
    p pointer value;
    data pointer value;
    len int(10) value;
  end-pi;
  dcl-ds t likeds(task_t) based(p);
  dcl-s buf pointer;

  // one byte at least, so the result is never *null; copied before
  // the old storage goes, in case data points into it
  buf = %alloc(%max(len: 1));
  if len > 0 and data <> *null;
    memcpy(buf: data: len);
  endif;
  if t.resultBuf <> *null;
    dealloc t.resultBuf;
  endif;
  t.resultBuf = buf;
  t.resultLen = %max(len: 0);
end-proc;

dcl-proc mutexLock;
  pthread_mutex_lock(gMutex);
end-proc;

dcl-proc mutexUnlock;
  pthread_mutex_unlock(gMutex);
end-proc;

// ==================================================================
// Errors
// ==================================================================

dcl-proc badHandle;
  dcl-pi *n varchar(100);
    task int(10) value;
  end-pi;

  return 'Async: ' + %char(task) + ' is not a task handle (or was freed)';
end-proc;

// Abnormal end of a task: send its message again
dcl-proc rethrow;
  dcl-pi *n;
    snap likeds(task_t) const;
  end-pi;

  if snap.state = ASYNC_CANCELED;
    fail('Async: task ' + %char(snap.handle) + ' was canceled');
  endif;
  if snap.errId <> *blanks and snap.errMsgf <> *blanks;
    sendEscape(snap.errId: snap.errMsgf: snap.errData);
  endif;
  fail(snap.errText);
end-proc;

// CPF9898 escape to the program that called into ASYNC
dcl-proc fail;
  dcl-pi *n;
    text varchar(1024) const;
  end-pi;

  sendEscape('CPF9898': 'QCPFMSG   *LIBL': text);
end-proc;

// Send an escape message to the call stack entry before the oldest
// consecutive ASYNC entry (*PGMBDY): the caller of the exported
// procedure. Returns only if the message could not be sent.
dcl-proc sendEscape;
  dcl-pi *n;
    msgId char(7) const;
    msgf char(20) const;
    data varchar(1024) const;
  end-pi;
  dcl-s buf char(1024);
  dcl-s key char(4);
  dcl-ds ec likeds(errc_t) inz(*likeds);

  buf = data;
  ec.bytesProv = %size(ec);
  QMHSNDPM(msgId: msgf: buf: %len(data): '*ESCAPE': '*PGMBDY': 1:
           key: ec);
end-proc;

// Absolute time ms milliseconds from now
dcl-proc expiration;
  dcl-pi *n;
    ms int(10) value;
    abstime likeds(timespec_t);
  end-pi;
  dcl-ds delta likeds(timespec_t);

  delta.tv_sec = %div(ms: 1000);
  delta.tv_nsec = %rem(ms: 1000) * 1000000;
  pthread_get_expiration_np(delta: abstime);
end-proc;
