# Async: async/await for ILE RPG

[![pub400](https://github.com/danlong005/Async/actions/workflows/pub400.yml/badge.svg?branch=main)](https://github.com/danlong005/Async/actions/workflows/pub400.yml)

ASYNC is a service program that gives RPG tasks you can start, `await`,
combine, chain and cancel, much like JavaScript promises or .NET tasks.
Each task runs on its own POSIX thread.

```rpgle
task = Async_Run(%paddr(SlowSquare): %addr(n));   // start: runs on a new thread
// ... do other work while it runs ...
p = Async_Await(task);                            // wait; p points to the result
Async_Free(task);
```

| JavaScript / .NET                          | RPG with ASYNC                              |
|--------------------------------------------|---------------------------------------------|
| `Task.Run(f)` / call an `async` function   | `Async_Run(%paddr(f): arg)`                 |
| `await t`                                  | `Async_Await(t)`                            |
| `try { await t } catch (e) {}`             | `monitor; Async_Await(t); on-error; endmon` |
| `Promise.all` / `Task.WhenAll`             | `Async_AwaitAll(tasks: n)`                  |
| `Promise.race` / `Task.WhenAny`            | `Async_AwaitAny(tasks: n)`                  |
| `t.then(f)` / `ContinueWith`               | `Async_Then(t: %paddr(f))`                  |
| `Task.Delay(ms)`                           | `Async_Delay(ms)`                           |
| `new Promise(...)` / `TaskCompletionSource` | `Async_Promise()`, `Async_Resolve`, `Async_Reject` |
| `CancellationToken`                        | `Async_Cancel(t)`, `Async_ThrowIfCanceled()` |
| `t.Wait(timeout)`                          | `Async_Wait(t: ms)`                         |

## Requirements

- **The job must allow threads.** Use `SBMJOB ... ALWMLTTHD(*YES)` or a job
  description with `ALWMLTTHD(*YES)`. Whether interactive and SSH jobs allow
  threads depends on the system: on pub400 they do, on an IBM i 7.6 system
  we tested they do not. Without threads, `Async_Run` fails with CPF9898
  "could not start a thread". It doesn't crash.
- **Modules with task procedures must be `THREAD(*CONCURRENT)`** (or
  `*SERIALIZE`), because those procedures run on other threads. RPG does not
  stop you from running a procedure from a module without it, and in a
  simple test it even works. But such a module's storage is shared by
  every thread with no protection, so two tasks can corrupt each other's
  data.
- In a `THREAD(*CONCURRENT)` module, global variables belong to one thread
  each. A task does not see the caller's globals, so pass data to it
  through its `arg` pointer.
- Code that a task calls must be threadsafe. Most SQL, IFS and API calls
  are. Record-level file I/O shared between threads needs care.

## Writing a task

A task procedure takes one pointer and returns one pointer:

```rpgle
ctl-opt thread(*concurrent) bnddir('ASYNC');
/copy qrpgleref/async.rpgleinc

dcl-proc SlowSquare;
  dcl-pi *n pointer;
    arg pointer value;
  end-pi;
  dcl-s n int(10) based(arg);
  dcl-s answer int(20);

  answer = n * n;
  return Async_Return(%addr(answer): %size(answer));
end-proc;
```

`Async_Return` copies the value into storage that the task owns, so the
result is still there after the procedure returns. That storage is freed
by `Async_Free`. Every type works this way, text included. The caller reads
the result through a `based` variable of the same type the task returned:

```rpgle
// in the task
dcl-s name varchar(50);
name = 'Ada Lovelace';
return Async_Return(%addr(name): %size(name));

// in the caller
dcl-s p pointer;
dcl-s name varchar(50) based(p);
p = Async_Await(task);
```

Nothing checks that the two types match, so declare them alike, for example
from a shared template or `LIKE` definition.

If the procedure returns a pointer of its own, it must point to storage
that outlives the procedure, such as `%alloc` or static storage. A local
variable does not.

The `arg` pointer is passed through as is. Whatever it points to must stay
alive until the task is done with it.

## Errors

If a task ends with an escape message, such as `MCH1211` (divide by zero), a
message from `Async_Throw('text')`, or any unmonitored error, the task is
**rejected**. `Async_Await` then sends that same message again, to the
caller of `Async_Await`, so it is caught as usual:

```rpgle
monitor;
  p = Async_Await(task);
on-error;
  // psds shows the task's own message id, e.g. MCH1211
  dsply %subst(Async_ErrorId(task) + ' ' + Async_ErrorText(task): 1: 52);
endmon;
```

`Async_Wait`, `Async_WaitAll`, `Async_WaitAny` and `Async_AwaitAny` only wait.
They never send the task's error; check `Async_Status(task)` afterwards.

## Cancellation

Cancellation is cooperative, as in .NET. `Async_Cancel(task)` cancels a
promise or delay at once. A running task stops when it next calls
`Async_ThrowIfCanceled()`, or when it checks `Async_IsCancelRequested()`
and returns. Awaiting a canceled task sends CPF9898.

## When the program ends

ASYNC and its task threads live in the caller's activation group. When that
activation group ends, for example when an `ACTGRP(*NEW)` program returns,
ASYNC does not leave threads running in storage that is about to be
destroyed:

1. Every pending promise and delay is canceled, and every running task is
   asked to cancel.
2. The activation group's end waits until every task thread has ended.

Tasks that check `Async_ThrowIfCanceled` stop quickly. A task that never
checks is waited for until it returns, so a long task that ignores
cancellation delays the end of the program that started it. If you want to
leave early, await or cancel your tasks before you return.

## Handles

Tasks are `int(10)` handles. Each one holds a slot until `Async_Free(task)`,
and up to `ASYNC_MAX_TASKS` (4096) can exist at once. A freed handle stays
invalid even after its slot is reused. To fire and forget, call `Async_Run`
and then `Async_Free` straight away; the task is released when it ends.

## API

See [qrpgleref/async.rpgleinc](qrpgleref/async.rpgleinc) for every
procedure. States are `ASYNC_PENDING`, `ASYNC_FULFILLED`, `ASYNC_REJECTED`
and `ASYNC_CANCELED`.

## Building

```sh
tools/pvs-build.sh             # copy to the pvs system, build, unit tests
tools/pvs-build.sh it          # ... and the integration tests
tools/pub400-build.sh          # copy to pub400, build, unit tests
tools/build.sh LIB DIR         # on IBM i: build from IFS directory DIR into LIB
tools/integration.sh LIB DIR   # on IBM i: integration tests
```

`build.sh` creates `LIB/ASYNC` (`*SRVPGM` and `*BNDDIR`), `LIB/ASYNCTEST` and
`LIB/ASYNCDEMO`, then runs `ASYNCTEST`. It replaces only those objects.
Compile errors are read from `LIB/EVFEVENT`. `pvs-build.sh` uses the ssh
host `pvs`, library `ASYNC` and directory `/home/dlong/async`; set `HOST`,
`LIB` and `DIR` to change them. `pub400-build.sh` defaults to
user `LONGDM`, library `LONGDM1` and directory `/home/LONGDM/async`; set
`USR`, `LIB` and `DIR` to change them.

GitHub Actions ([.github/workflows/pub400.yml](.github/workflows/pub400.yml))
runs the same build and tests on pub400 for every push to `main` and every
pull request. It uses its own IFS directory (`/home/LONGDM/async-ci`) and
needs a repository secret `PUB400_SSH_KEY` holding a private key the pub400
user accepts. Without the secret the job is skipped with a warning.

Bind your programs with `BNDDIR('ASYNC')` or `BNDSRVPGM((ASYNC))`. The
binder source ([qsrvsrc/async.bnd](qsrvsrc/async.bnd)) has a fixed
signature, so only ever add new exports at the end.

## Tests

**Unit tests** ([qtestsrc/asynctest.rpgle](qtestsrc/asynctest.rpgle)) cover
the API, one exported `test_` procedure each. Where iRPGUnit is installed,
`build.sh` compiles them with `RUCRTRPG ... DEFINE(IRPGUNIT)` and runs
`RUCALLTST` in a batch job that allows threads, reading the results from its
JUnit XML. Without iRPGUnit (pub400, CI), the same source builds a plain
program with stand-in `assert`, `iEqual` and `aEqual`.

**Integration tests** ([qtestsrc/asyncit.sqlrpgle](qtestsrc/asyncit.sqlrpgle))
check that ASYNC holds up under load and in awkward situations.
`tools/integration.sh` runs each scenario as its own batch job, so one that
crashes fails alone. A scenario that hangs is ended after 10 minutes and
fails. A scenario also fails if its job log shows a machine check, function
check or unhandled RPG error, even one on a thread the scenario never looked
at.

| Scenario       | What it checks |
|----------------|----------------|
| `stress`       | 20 rounds of 200 tasks at once; every result checked |
| `awaiters`     | 50 tasks awaiting one promise all get its value |
| `freerace`     | a task freed by another task while being awaited: result or clean error, never a hang |
| `cancelrace`   | cancel at random points in a task's life always stops it |
| `leak`         | 100,000 tasks; job temporary storage does not grow |
| `limit`        | 4096 handles, then a clean error, then handles again once freed |
| `sql`          | embedded SQL in 8 tasks at once |
| `ifs`          | 8 tasks writing and reading back their own IFS files |
| `agend`        | a program returns with tasks still running (see [When the program ends](#when-the-program-ends)) |
| `nothreadsafe` | a task procedure from a module without `THREAD(*CONCURRENT)` |
| `nothreads`    | a job with `ALWMLTTHD(*NO)`: `Async_Run` fails cleanly |

## Layout

```
qrpgleref/async.rpgleinc   prototypes and constants (copy this)
qrpglesrc/async.rpgle      the service program
qsrvsrc/async.bnd          binder source
qtestsrc/asynctest.rpgle   unit tests (iRPGUnit or standalone)
qtestsrc/asyncit.sqlrpgle  integration tests
qtestsrc/asyncage.rpgle    helper for the agend scenario
qtestsrc/asyncnts.rpgle    helper for the nothreadsafe scenario
examples/asyncdemo.rpgle   three lookups at once, try/catch, then
tools/                     build scripts
```

## License

MIT. See [LICENSE](LICENSE).
