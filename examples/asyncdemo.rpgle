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
    say('Customer ' + %char(ids(i)) + ': ' + Async_AwaitText(tasks(i)));
    Async_Free(tasks(i));
  endfor;
  say('Three lookups took '
     + %char(%int(%diff(%timestamp(): start: *mseconds) / 1000)) + ' ms');

  // try { await lookUp(999) } catch (e) { ... }
  task = Async_Run(%paddr(lookUp): %addr(missing));
  monitor;
    say(Async_AwaitText(task));
  on-error;
    say('Caught: ' + Async_ErrorText(task));
  endmon;
  Async_Free(task);

  // lookUp(1).then(toUpper)
  task = Async_Run(%paddr(lookUp): %addr(ids(1)));
  shout = Async_Then(task: %paddr(toUpper));
  say('Then: ' + Async_AwaitText(shout));
  Async_Free(shout);
  Async_Free(task);
end-proc;

// arg: int(10) customer id. Result: the customer's name (text)
dcl-proc lookUp;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s id int(10) based(arg);

  Async_Sleep(1000);      // stands in for a slow file, SQL or HTTP call
  select;
  when id = 1;
    return Async_ReturnText('Ada Lovelace');
  when id = 2;
    return Async_ReturnText('Grace Hopper');
  when id = 3;
    return Async_ReturnText('Frances Allen');
  endsl;
  Async_Throw('No customer ' + %char(id));
  return *null;
end-proc;

// arg: the text result of the task this continues
dcl-proc toUpper;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s name varchar(65535) based(arg);

  return Async_ReturnText(%upper(name));
end-proc;

// One line to standard output (x'25' is LF in EBCDIC)
dcl-proc say;
  dcl-pi *n;
    text varchar(1024) const;
  end-pi;

  printf('%s' + x'25': text);
end-proc;
