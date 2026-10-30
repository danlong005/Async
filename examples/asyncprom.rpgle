**free
// ------------------------------------------------------------------
// ASYNCPROM - promises: results handed over by another thread
//
//   SBMJOB CMD(CALL ASYNCPROM) ALWMLTTHD(*YES)  (output: QPRINT)
//
// Three orders go to one "approver" task, which works through them in
// turn. Each order carries a promise: the caller awaits the promise,
// and the approver settles it with Async_Resolve (a decision) or
// Async_Reject (a bad order). Like .NET's TaskCompletionSource, or a
// JavaScript promise whose resolve function is handed to someone
// else.
//
// Use a promise whenever a result is produced by something other
// than a task procedure's return: a worker serving many requests, a
// data queue listener, a callback.
// ------------------------------------------------------------------
ctl-opt main(main) thread(*concurrent) option(*srcstmt: *nodebugio)
        bnddir('QC2LE');

/copy qrpglesrc/async.rpgleinc

dcl-pr printf int(10) extproc('printf');
  format pointer value options(*string);
  text pointer value options(*string: *nopass);
end-pr;

dcl-ds order_t qualified template;
  id int(10);
  amount packed(9: 2);
  promise int(10);          // settled by the approver
end-ds;

dcl-ds orders_t qualified template;
  count int(10);
  order likeds(order_t) dim(10);
end-ds;

dcl-ds decision_t qualified template;
  approved ind;
  note varchar(50);
end-ds;

dcl-proc main;
  dcl-ds orders likeds(orders_t) inz;
  dcl-s approver int(10);
  dcl-s p pointer;
  dcl-ds decision likeds(decision_t) based(p);
  dcl-s i int(10);

  orders.count = 3;
  orders.order(1).id = 101;
  orders.order(1).amount = 250;
  orders.order(2).id = 102;
  orders.order(2).amount = 99999;
  orders.order(3).id = 103;
  orders.order(3).amount = -5;
  for i = 1 to orders.count;
    orders.order(i).promise = Async_Promise();
  endfor;

  // orders must stay alive until the approver is done with it: it
  // is awaited below, before main returns
  approver = Async_Run(%paddr(approveAll): %addr(orders));
  say('Orders sent; main is free while the approver works');

  for i = 1 to orders.count;
    monitor;
      p = Async_Await(orders.order(i).promise);
      if decision.approved;
        say('Order ' + %char(orders.order(i).id) + ' approved: '
          + decision.note);
      else;
        say('Order ' + %char(orders.order(i).id) + ' declined: '
          + decision.note);
      endif;
    on-error;
      say('Order ' + %char(orders.order(i).id) + ' rejected: '
        + Async_ErrorText(orders.order(i).promise));
    endmon;
    Async_Free(orders.order(i).promise);
  endfor;

  Async_Await(approver);
  Async_Free(approver);
  say('Done.');
end-proc;

// The approver: arg is an orders_t. Settles each order's promise.
dcl-proc approveAll;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-ds orders likeds(orders_t) based(arg);
  dcl-ds decision likeds(decision_t);
  dcl-s i int(10);

  for i = 1 to orders.count;
    Async_Sleep(300);       // stands in for a credit check
    if orders.order(i).amount <= 0;
      Async_Reject(orders.order(i).promise: 'amount must be positive');
    else;
      decision.approved = orders.order(i).amount <= 1000;
      if decision.approved;
        decision.note = 'within the limit';
      else;
        decision.note = 'over the 1000.00 limit';
      endif;
      // Async_Resolve keeps a copy, so decision can be reused
      Async_Resolve(orders.order(i).promise: %addr(decision):
                    %size(decision));
    endif;
  endfor;
  return *null;
end-proc;

// One line to standard output (QPRINT in batch); x'25' is LF
dcl-proc say;
  dcl-pi *n;
    text varchar(1024) const;
  end-pi;

  printf('%s' + x'25': text);
end-proc;
