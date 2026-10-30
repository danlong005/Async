**free
// ------------------------------------------------------------------
// ASYNCSQL - run SQL queries as tasks
//
//   SBMJOB CMD(CALL ASYNCSQL) ALWMLTTHD(*YES)   (output: QPRINT)
//
// Gathers statistics on three schemas, first one after another, then
// as three tasks, and prints both timings. The first SQL statements
// in a job are slow while Db2 sets them up, so one untimed round
// runs first to keep the comparison fair.
//
// The pattern: write an ordinary procedure (schemaStats) and wrap it
// in a small task procedure (statsTask) that turns its pointer
// argument into parameters and its return value into
// Async_Return. The result type, stats_t, is a template that both the
// task and the caller use, so both read the same layout.
//
// Embedded SQL works in tasks, but do not expect queries to scale
// with the number of tasks: all threads of a job share its one SQL
// connection. On pub400, three such queries took 54 ms one after
// another and about 43 ms as tasks: some overlap, far from three
// times faster. Measure your own queries. Tasks pay off most when SQL
// is one step among others (IFS, HTTP, calculations), or to keep the
// caller free while SQL runs.
// ------------------------------------------------------------------
ctl-opt main(main) thread(*concurrent) option(*srcstmt: *nodebugio)
        bnddir('QC2LE');

/copy qrpgleref/async.rpgleinc

dcl-pr printf int(10) extproc('printf');
  format pointer value options(*string);
  text pointer value options(*string: *nopass);
end-pr;

dcl-ds stats_t qualified template;
  schema varchar(10);
  tables int(10);
  columns int(10);
end-ds;

dcl-proc main;
  dcl-s schemas varchar(10) dim(3);
  dcl-s tasks int(10) dim(3);
  dcl-ds stats likeds(stats_t);
  dcl-s p pointer;
  dcl-ds result likeds(stats_t) based(p);
  dcl-s start timestamp;
  dcl-s i int(10);

  schemas(1) = 'QSYS2';
  schemas(2) = 'SYSIBM';
  schemas(3) = 'SYSTOOLS';

  // untimed warm-up
  for i = 1 to 3;
    stats = schemaStats(schemas(i));
  endfor;

  say('One after another:');
  start = %timestamp();
  for i = 1 to 3;
    stats = schemaStats(schemas(i));
    show(stats);
  endfor;
  say('  took ' + elapsed(start) + ' ms');

  say('As tasks:');
  start = %timestamp();
  for i = 1 to 3;
    tasks(i) = Async_Run(%paddr(statsTask): %addr(schemas(i)));
  endfor;
  Async_AwaitAll(tasks: 3);
  for i = 1 to 3;
    p = Async_Result(tasks(i));
    show(result);
    Async_Free(tasks(i));
  endfor;
  say('  took ' + elapsed(start) + ' ms');
  say('Done.');
end-proc;

// The task: arg is a varchar(10) schema name. Result: a stats_t.
dcl-proc statsTask;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s schema varchar(10) based(arg);
  dcl-ds stats likeds(stats_t);

  stats = schemaStats(schema);
  return Async_Return(%addr(stats): %size(stats));
end-proc;

// An ordinary procedure; nothing in it knows about tasks
dcl-proc schemaStats;
  dcl-pi *n likeds(stats_t);
    schema varchar(10) const;
  end-pi;
  dcl-ds stats likeds(stats_t) inz;
  dcl-s name varchar(10);

  name = schema;
  stats.schema = schema;
  exec sql select count(*),
                  (select count(*) from qsys2.syscolumns
                    where table_schema = :name)
             into :stats.tables, :stats.columns
             from qsys2.systables
            where table_schema = :name;
  if sqlcode < 0;
    // in a task this rejects it; Async_Await then sends the message
    Async_Throw('SQL error ' + sqlstate + ' for ' + schema);
  endif;
  return stats;
end-proc;

dcl-proc show;
  dcl-pi *n;
    stats likeds(stats_t) const;
  end-pi;

  say('  ' + stats.schema + ': ' + %char(stats.tables) + ' tables, '
    + %char(stats.columns) + ' columns');
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
