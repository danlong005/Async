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
  description with `ALWMLTTHD(*YES)`. Jobs started by PASE (SSH, QSH,
  `system`) already do. Without it `Async_Run` fails with CPF9898
  "could not start a thread".
- **Modules with task procedures must be `THREAD(*CONCURRENT)`** (or
  `*SERIALIZE`), because those procedures run on other threads.
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
tools/pub400-build.sh          # from this machine: copy to pub400, build, test
tools/build.sh LIB DIR         # on IBM i: build from IFS directory DIR into LIB
```

`build.sh` creates `LIB/ASYNC` (`*SRVPGM` and `*BNDDIR`), `LIB/ASYNCTEST` and
`LIB/ASYNCDEMO`, then runs `ASYNCTEST`. It replaces only those objects.
Compile errors are read from `LIB/EVFEVENT`. `pub400-build.sh` defaults to
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

`qtestsrc/asynctest.rpgle` holds the tests, one `test_` procedure each. Its
`assert`, `iEqual` and `aEqual` take the same parameters as iRPGUnit's. To
move to iRPGUnit: export the `test_` procedures, bind `RUTESTCASE` instead of
the helpers at the bottom of the file, and drop `main`.

## Layout

```
qrpgleref/async.rpgleinc   prototypes and constants (copy this)
qrpglesrc/async.rpgle      the service program
qsrvsrc/async.bnd          binder source
qtestsrc/asynctest.rpgle   tests
examples/asyncdemo.rpgle   three lookups at once, try/catch, then
tools/                     build scripts
```

## License

MIT. See [LICENSE](LICENSE).
