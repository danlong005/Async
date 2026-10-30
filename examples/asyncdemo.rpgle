**free
// ------------------------------------------------------------------
// ASYNCDEMO - async/await in RPG, side by side with JavaScript
//
//   CALL ASYNCDEMO       (in a job that allows threads)
//
// Looks up three "customers" at once. Each lookup takes about a
// second, so done one after another they take three seconds, done
// as tasks about one.
//
//   const tasks = ids.map(id => lookUp(id));          // Async_Run
//   const names = await Promise.all(tasks);           // Async_AwaitAll
//   try { await lookUp(999) } catch (e) { ... }       // MONITOR
//   const shout = lookUp(1).then(toUpper);            // Async_Then
// ------------------------------------------------------------------
ctl-opt main(main) thread(*concurrent) option(*srcstmt: *nodebugio)
        bnddir('QC2LE');

/copy qrpgleref/async.rpgleinc

dcl-pr printf int(10) extproc('printf');
  format pointer value options(*string);
  text pointer value options(*string: *nopass);
end-pr;

dcl-proc main;
  dcl-s ids int(10) dim(3);
  dcl-s tasks int(10) dim(3);
  dcl-s missing int(10) inz(999);
  dcl-s task int(10);
  dcl-s shout int(10);
  dcl-s start timestamp;
  dcl-s i int(10);
  dcl-s p pointer;
  dcl-s name varchar(50) based(p);    // the result of lookUp

  ids(1) = 1;
  ids(2) = 2;
  ids(3) = 3;

  // Start all three; none of them waits for the others
  start = %timestamp();
  for i = 1 to 3;
    tasks(i) = Async_Run(%paddr(lookUp): %addr(ids(i)));
  endfor;

  // await Promise.all(tasks)
  Async_AwaitAll(tasks: 3);
  for i = 1 to 3;
    p = Async_Await(tasks(i));
    say('Customer ' + %char(ids(i)) + ': ' + name);
    Async_Free(tasks(i));
  endfor;
  say('Three lookups took '
     + %char(%int(%diff(%timestamp(): start: *mseconds) / 1000)) + ' ms');

  // try { await lookUp(999) } catch (e) { ... }
  task = Async_Run(%paddr(lookUp): %addr(missing));
  monitor;
    p = Async_Await(task);
    say(name);
  on-error;
    say('Caught: ' + Async_ErrorText(task));
  endmon;
  Async_Free(task);

  // lookUp(1).then(toUpper)
  task = Async_Run(%paddr(lookUp): %addr(ids(1)));
  shout = Async_Then(task: %paddr(toUpper));
  p = Async_Await(shout);
  say('Then: ' + name);
  Async_Free(shout);
  Async_Free(task);
  say('Done.');
end-proc;

// arg: int(10) customer id. Result: varchar(50) customer name
dcl-proc lookUp;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s id int(10) based(arg);
  dcl-s name varchar(50);

  Async_Sleep(1000);      // stands in for a slow file, SQL or HTTP call
  select;
  when id = 1;
    name = 'Ada Lovelace';
  when id = 2;
    name = 'Grace Hopper';
  when id = 3;
    name = 'Frances Allen';
  other;
    Async_Throw('No customer ' + %char(id));
  endsl;
  return Async_Return(%addr(name): %size(name));
end-proc;

// arg: the varchar(50) result of the task this continues
dcl-proc toUpper;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s name varchar(50) based(arg);
  dcl-s upper varchar(50);

  upper = %upper(name);
  return Async_Return(%addr(upper): %size(upper));
end-proc;

// One line to standard output (x'25' is LF in EBCDIC)
dcl-proc say;
  dcl-pi *n;
    text varchar(1024) const;
  end-pi;

  printf('%s' + x'25': text);
end-proc;
