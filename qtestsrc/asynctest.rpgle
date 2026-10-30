**free
// ------------------------------------------------------------------
// ASYNCTEST - self-tests for service program ASYNC
//
//   CALL ASYNCTEST       (in a job that allows threads)
//
// Prints one line per test and ends with "ASYNCTEST OK" or
// "ASYNCTEST FAILED".
//
// Each test_ procedure is one test. assert, iEqual and aEqual have
// iRPGUnit's signatures, so moving to iRPGUnit means exporting the
// test_ procedures, binding RUTESTCASE instead of the helpers at the
// bottom, and dropping main.
//
// The task procedures run on other threads; this module is
// THREAD(*CONCURRENT), so they get their data through arg only.
// ------------------------------------------------------------------
ctl-opt main(main) thread(*concurrent) option(*srcstmt: *nodebugio)
        bnddir('QC2LE');

/copy qrpgleref/async.rpgleinc

dcl-pr printf int(10) extproc('printf');
  format pointer value options(*string);
  text pointer value options(*string: *nopass);
end-pr;

dcl-ds psds psds qualified;
  excId char(7) pos(40);
  excData char(80) pos(91);
end-ds;

dcl-s gRun int(10);
dcl-s gFailed int(10);
dcl-s gFailMsg varchar(512);

dcl-proc main;
  run('runAndAwait': %paddr(test_runAndAwait));
  run('runsInParallel': %paddr(test_runsInParallel));
  run('errorIsRethrown': %paddr(test_errorIsRethrown));
  run('throwText': %paddr(test_throwText));
  run('promiseResolve': %paddr(test_promiseResolve));
  run('promiseReject': %paddr(test_promiseReject));
  run('resolveTwice': %paddr(test_resolveTwice));
  run('waitTimeout': %paddr(test_waitTimeout));
  run('awaitAny': %paddr(test_awaitAny));
  run('awaitAll': %paddr(test_awaitAll));
  run('awaitAllRethrows': %paddr(test_awaitAllRethrows));
  run('then': %paddr(test_then));
  run('thenRejected': %paddr(test_thenRejected));
  run('thenText': %paddr(test_thenText));
  run('cancelRunning': %paddr(test_cancelRunning));
  run('cancelDelay': %paddr(test_cancelDelay));
  run('cancelPromise': %paddr(test_cancelPromise));
  run('text': %paddr(test_text));
  run('invalidHandle': %paddr(test_invalidHandle));
  run('freedHandleStaysInvalid': %paddr(test_freedHandleStaysInvalid));
  run('freeWhileRunning': %paddr(test_freeWhileRunning));
  run('manyTasks': %paddr(test_manyTasks));
  run('nestedAwait': %paddr(test_nestedAwait));
  run('selfAwait': %paddr(test_selfAwait));

  say(%char(gRun) + ' tests, ' + %char(gFailed) + ' failed');
  if gFailed = 0;
    say('ASYNCTEST OK');
  else;
    say('ASYNCTEST FAILED');
  endif;
end-proc;

// ==================================================================
// Tests
// ==================================================================

dcl-proc test_runAndAwait;
  dcl-s n int(10) inz(100);
  dcl-s task int(10);
  dcl-s p pointer;
  dcl-s total int(20) based(p);

  task = Async_Run(%paddr(sumTo): %addr(n));
  p = Async_Await(task);
  iEqual(5050: total);
  iEqual(ASYNC_FULFILLED: Async_Status(task));
  iEqual(%size(total): Async_ResultLen(task));
  Async_Free(task);
end-proc;

// Four 500 ms tasks take about 500 ms, not 2000
dcl-proc test_runsInParallel;
  dcl-s ms int(10) dim(4) inz(500);
  dcl-s tasks int(10) dim(4);
  dcl-s start timestamp;
  dcl-s elapsed int(20);
  dcl-s i int(10);

  start = %timestamp();
  for i = 1 to 4;
    tasks(i) = Async_Run(%paddr(sleepFor): %addr(ms(i)));
  endfor;
  Async_AwaitAll(tasks: 4);
  elapsed = %diff(%timestamp(): start: *mseconds) / 1000;
  assert(elapsed < 1500: 'Took ' + %char(elapsed) + ' ms');
  for i = 1 to 4;
    Async_Free(tasks(i));
  endfor;
end-proc;

dcl-proc test_errorIsRethrown;
  dcl-s task int(10);
  dcl-s caught ind inz(*off);

  task = Async_Run(%paddr(divideByZero));
  monitor;
    Async_Await(task);
  on-error;
    caught = *on;
    // the caller gets the task's own message, not a generic one
    aEqual('MCH1211': psds.excId);
  endmon;
  assert(caught: 'Async_Await did not send the task''s error');
  iEqual(ASYNC_REJECTED: Async_Status(task));
  assert(Async_ErrorId(task) <> *blanks: 'No error id');
  say('     (divide by zero: ' + Async_ErrorId(task) + ' '
     + Async_ErrorText(task) + ')');
  Async_Free(task);
end-proc;

dcl-proc test_throwText;
  dcl-s task int(10);
  dcl-s caught ind inz(*off);

  task = Async_Run(%paddr(throwBoom));
  monitor;
    Async_Await(task);
  on-error;
    caught = *on;
    aEqual('CPF9898': psds.excId);
  endmon;
  assert(caught: 'Async_Await did not send the task''s error');
  aEqual('CPF9898': Async_ErrorId(task));
  assert(%scan('boom': Async_ErrorText(task)) > 0:
         'Error text is ' + Async_ErrorText(task));
  Async_Free(task);
end-proc;

dcl-proc test_promiseResolve;
  dcl-s promise int(10);
  dcl-s helper int(10);
  dcl-s p pointer;
  dcl-s value int(20) based(p);

  promise = Async_Promise();
  iEqual(ASYNC_PENDING: Async_Status(promise));
  helper = Async_Run(%paddr(resolveLater): %addr(promise));
  p = Async_Await(promise);
  iEqual(42: value);
  Async_Await(helper);
  Async_Free(helper);
  Async_Free(promise);
end-proc;

dcl-proc test_promiseReject;
  dcl-s promise int(10);
  dcl-s helper int(10);
  dcl-s caught ind inz(*off);

  promise = Async_Promise();
  helper = Async_Run(%paddr(rejectLater): %addr(promise));
  monitor;
    Async_Await(promise);
  on-error;
    caught = *on;
  endmon;
  assert(caught: 'Await of a rejected promise did not fail');
  aEqual('nope': Async_ErrorText(promise));
  Async_Await(helper);
  Async_Free(helper);
  Async_Free(promise);
end-proc;

dcl-proc test_resolveTwice;
  dcl-s promise int(10);
  dcl-s one int(10) inz(1);
  dcl-s two int(10) inz(2);
  dcl-s p pointer;
  dcl-s value int(10) based(p);

  promise = Async_Promise();
  assert(Async_Resolve(promise: %addr(one): %size(one)): 'First resolve');
  assert(not Async_Resolve(promise: %addr(two): %size(two)):
         'Second resolve should be ignored');
  assert(not Async_Reject(promise: 'late'): 'Reject should be ignored');
  p = Async_Await(promise);
  iEqual(1: value);
  Async_Free(promise);
end-proc;

dcl-proc test_waitTimeout;
  dcl-s task int(10);

  task = Async_Delay(1000);
  assert(not Async_Wait(task: 100): 'Delay(1000) done after 100 ms');
  assert(not Async_IsDone(task): 'IsDone after 100 ms');
  assert(Async_Wait(task: 5000): 'Delay(1000) not done after 5 s');
  iEqual(ASYNC_FULFILLED: Async_Status(task));
  Async_Free(task);
end-proc;

dcl-proc test_awaitAny;
  dcl-s tasks int(10) dim(3);
  dcl-s i int(10);

  tasks(1) = Async_Delay(2000);
  tasks(2) = Async_Delay(50);
  tasks(3) = Async_Delay(1000);
  iEqual(2: Async_AwaitAny(tasks: 3));
  iEqual(2: Async_WaitAny(tasks: 3: 0));
  for i = 1 to 3;
    Async_Cancel(tasks(i));
    Async_Free(tasks(i));
  endfor;
end-proc;

dcl-proc test_awaitAll;
  dcl-s n int(10) dim(3);
  dcl-s tasks int(10) dim(3);
  dcl-s p pointer;
  dcl-s total int(20) based(p);
  dcl-s i int(10);

  n(1) = 10;
  n(2) = 20;
  n(3) = 30;
  for i = 1 to 3;
    tasks(i) = Async_Run(%paddr(sumTo): %addr(n(i)));
  endfor;
  Async_AwaitAll(tasks: 3);
  p = Async_Result(tasks(1));
  iEqual(55: total);
  p = Async_Result(tasks(2));
  iEqual(210: total);
  p = Async_Result(tasks(3));
  iEqual(465: total);
  for i = 1 to 3;
    Async_Free(tasks(i));
  endfor;
end-proc;

dcl-proc test_awaitAllRethrows;
  dcl-s n int(10) inz(5);
  dcl-s tasks int(10) dim(2);
  dcl-s caught ind inz(*off);

  tasks(1) = Async_Run(%paddr(sumTo): %addr(n));
  tasks(2) = Async_Run(%paddr(throwBoom));
  monitor;
    Async_AwaitAll(tasks: 2);
  on-error;
    caught = *on;
  endmon;
  assert(caught: 'Async_AwaitAll did not send the error');
  // all were waited for
  assert(Async_IsDone(tasks(1)) and Async_IsDone(tasks(2)): 'Not done');
  Async_Free(tasks(1));
  Async_Free(tasks(2));
end-proc;

dcl-proc test_then;
  dcl-s n int(10) inz(10);
  dcl-s first int(10);
  dcl-s second int(10);
  dcl-s p pointer;
  dcl-s value int(20) based(p);

  first = Async_Run(%paddr(sumTo): %addr(n));
  second = Async_Then(first: %paddr(doubleIt));
  p = Async_Await(second);
  iEqual(110: value);
  Async_Free(second);
  Async_Free(first);
end-proc;

dcl-proc test_thenRejected;
  dcl-s first int(10);
  dcl-s second int(10);

  first = Async_Run(%paddr(throwBoom));
  second = Async_Then(first: %paddr(doubleIt));
  Async_Wait(second: ASYNC_FOREVER);
  iEqual(ASYNC_REJECTED: Async_Status(second));
  assert(%scan('boom': Async_ErrorText(second)) > 0:
         'Error text is ' + Async_ErrorText(second));
  Async_Free(second);
  Async_Free(first);
end-proc;

dcl-proc test_thenText;
  dcl-s name char(10) inz('RPG');
  dcl-s first int(10);
  dcl-s second int(10);

  first = Async_Run(%paddr(greet): %addr(name));
  second = Async_Then(first: %paddr(shout));
  aEqual('HELLO, RPG!': Async_AwaitText(second));
  Async_Free(second);
  Async_Free(first);
end-proc;

dcl-proc test_cancelRunning;
  dcl-s task int(10);
  dcl-s caught ind inz(*off);

  task = Async_Run(%paddr(untilCanceled));
  Async_Sleep(50);
  assert(Async_Cancel(task): 'Cancel of a running task');
  monitor;
    Async_Await(task);
  on-error;
    caught = *on;
  endmon;
  assert(caught: 'Await of a canceled task did not fail');
  iEqual(ASYNC_CANCELED: Async_Status(task));
  Async_Free(task);
end-proc;

dcl-proc test_cancelDelay;
  dcl-s task int(10);

  task = Async_Delay(30000);
  Async_Cancel(task);
  assert(Async_Wait(task: 2000): 'Canceled delay still pending');
  iEqual(ASYNC_CANCELED: Async_Status(task));
  assert(not Async_Cancel(task): 'Second cancel should do nothing');
  Async_Free(task);
end-proc;

dcl-proc test_cancelPromise;
  dcl-s promise int(10);

  promise = Async_Promise();
  assert(Async_Cancel(promise): 'Cancel of a pending promise');
  iEqual(ASYNC_CANCELED: Async_Status(promise));
  Async_Free(promise);
end-proc;

dcl-proc test_text;
  dcl-s name char(10) inz('RPG');
  dcl-s task int(10);
  dcl-s promise int(10);

  task = Async_Run(%paddr(greet): %addr(name));
  aEqual('Hello, RPG!': Async_AwaitText(task));
  Async_Free(task);

  promise = Async_Promise();
  Async_ResolveText(promise: 'resolved text');
  aEqual('resolved text': Async_AwaitText(promise));
  Async_Free(promise);
end-proc;

dcl-proc test_invalidHandle;
  dcl-s caught ind inz(*off);

  monitor;
    Async_Await(12345);
  on-error;
    caught = *on;
    aEqual('CPF9898': psds.excId);
  endmon;
  assert(caught: 'Await of an unknown handle did not fail');
  Async_Free(12345);
end-proc;

dcl-proc test_freedHandleStaysInvalid;
  dcl-s old int(10);
  dcl-s new int(10);
  dcl-s caught ind inz(*off);

  old = Async_Promise();
  Async_Free(old);
  new = Async_Promise();
  assert(new <> old: 'Handle reused');
  monitor;
    Async_Status(old);
  on-error;
    caught = *on;
  endmon;
  assert(caught: 'Freed handle still works');
  Async_Free(new);
end-proc;

dcl-proc test_freeWhileRunning;
  dcl-s ms int(10) inz(200);
  dcl-s task int(10);
  dcl-s caught ind inz(*off);

  task = Async_Run(%paddr(sleepFor): %addr(ms));
  Async_Free(task);
  monitor;
    Async_Status(task);
  on-error;
    caught = *on;
  endmon;
  assert(caught: 'Freed handle still works');
  // let the thread end and free the task itself
  Async_Sleep(400);
end-proc;

dcl-proc test_manyTasks;
  dcl-c COUNT 100;
  dcl-s n int(10) dim(COUNT);
  dcl-s tasks int(10) dim(COUNT);
  dcl-s p pointer;
  dcl-s total int(20) based(p);
  dcl-s i int(10);

  for i = 1 to COUNT;
    n(i) = i * 1000;
    tasks(i) = Async_Run(%paddr(sumTo): %addr(n(i)));
  endfor;
  Async_AwaitAll(tasks: COUNT);
  for i = 1 to COUNT;
    p = Async_Result(tasks(i));
    iEqual(n(i) * (n(i) + 1) / 2: total);
    Async_Free(tasks(i));
  endfor;
end-proc;

dcl-proc test_nestedAwait;
  dcl-s task int(10);
  dcl-s p pointer;
  dcl-s value int(20) based(p);

  task = Async_Run(%paddr(awaitOthers));
  p = Async_Await(task);
  iEqual(55 + 5050: value);
  Async_Free(task);
end-proc;

dcl-proc test_selfAwait;
  dcl-s task int(10);

  task = Async_Run(%paddr(awaitSelf));
  Async_Wait(task: ASYNC_FOREVER);
  iEqual(ASYNC_REJECTED: Async_Status(task));
  assert(%scan('itself': Async_ErrorText(task)) > 0:
         'Error text is ' + Async_ErrorText(task));
  Async_Free(task);
end-proc;

// ==================================================================
// Task procedures (these run on other threads)
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

// arg: int(10) ms. Sleeps ms, result: ms
dcl-proc sleepFor;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s ms int(10) based(arg);

  Async_Sleep(ms);
  return Async_Return(%addr(ms): %size(ms));
end-proc;

dcl-proc divideByZero;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s a int(10) inz(1);
  dcl-s b int(10) inz(0);
  dcl-s c int(10);

  c = a / b;
  return Async_Return(%addr(c): %size(c));
end-proc;

dcl-proc throwBoom;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;

  Async_Throw('boom');
  return *null;
end-proc;

// arg: int(20). Result: int(20) twice that
dcl-proc doubleIt;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s value int(20) based(arg);
  dcl-s twice int(20);

  twice = value * 2;
  return Async_Return(%addr(twice): %size(twice));
end-proc;

// Runs until canceled (gives up after 10 s)
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

// arg: int(10) promise handle; resolves it with int(20) 42
dcl-proc resolveLater;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s promise int(10) based(arg);
  dcl-s value int(20) inz(42);

  Async_Sleep(100);
  Async_Resolve(promise: %addr(value): %size(value));
  return *null;
end-proc;

// arg: int(10) promise handle; rejects it
dcl-proc rejectLater;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s promise int(10) based(arg);

  Async_Sleep(50);
  Async_Reject(promise: 'nope');
  return *null;
end-proc;

// arg: char(10) name. Result: text
dcl-proc greet;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s name char(10) based(arg);

  return Async_ReturnText('Hello, ' + %trim(name) + '!');
end-proc;

// arg: a text result. Result: it in upper case
dcl-proc shout;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s text varchar(65535) based(arg);

  return Async_ReturnText(%upper(text));
end-proc;

// Starts two tasks and awaits them. Result: int(20) their sum
dcl-proc awaitOthers;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s n int(10) dim(2);
  dcl-s tasks int(10) dim(2);
  dcl-s p pointer;
  dcl-s value int(20) based(p);
  dcl-s total int(20) inz(0);
  dcl-s i int(10);

  n(1) = 10;
  n(2) = 100;
  for i = 1 to 2;
    tasks(i) = Async_Run(%paddr(sumTo): %addr(n(i)));
  endfor;
  for i = 1 to 2;
    p = Async_Await(tasks(i));
    total += value;
    Async_Free(tasks(i));
  endfor;
  return Async_Return(%addr(total): %size(total));
end-proc;

dcl-proc awaitSelf;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;

  return Async_Await(Async_Current());
end-proc;

// ==================================================================
// Runner and assertions (iRPGUnit signatures)
// ==================================================================

dcl-proc run;
  dcl-pi *n;
    name varchar(50) const;
    testProc pointer(*proc) value;
  end-pi;
  dcl-pr callTest extproc(testProc);
  end-pr;
  dcl-s ok ind;

  gRun += 1;
  gFailMsg = '';
  monitor;
    callTest();
    ok = *on;
  on-error;
    ok = *off;
  endmon;

  if ok;
    say('ok   ' + name);
  else;
    gFailed += 1;
    if gFailMsg = '';
      gFailMsg = 'Unexpected ' + psds.excId + ': ' + %trim(psds.excData);
    endif;
    say('FAIL ' + name + ': ' + gFailMsg);
  endif;
end-proc;

dcl-proc assert;
  dcl-pi *n;
    condition ind const;
    msg varchar(512) const options(*nopass);
  end-pi;

  if not condition;
    gFailMsg = 'Assertion failed';
    if %parms >= 2;
      gFailMsg = msg;
    endif;
    snd-msg *escape %msg('CPF9898': 'QCPFMSG': gFailMsg);
  endif;
end-proc;

dcl-proc iEqual;
  dcl-pi *n;
    expected int(20) const;
    actual int(20) const;
  end-pi;

  if expected <> actual;
    gFailMsg = 'Expected ' + %char(expected) + ', but was '
             + %char(actual) + '.';
    snd-msg *escape %msg('CPF9898': 'QCPFMSG': gFailMsg);
  endif;
end-proc;

dcl-proc aEqual;
  dcl-pi *n;
    expected varchar(2048) const;
    actual varchar(2048) const;
  end-pi;

  if expected <> actual;
    gFailMsg = 'Expected ''' + expected + ''', but was ''' + actual
             + '''.';
    snd-msg *escape %msg('CPF9898': 'QCPFMSG': gFailMsg);
  endif;
end-proc;

// One line to standard output (x'25' is LF in EBCDIC)
dcl-proc say;
  dcl-pi *n;
    text varchar(1024) const;
  end-pi;

  printf('%s' + x'25': text);
end-proc;
