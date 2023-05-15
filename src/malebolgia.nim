## (c) 2023 Andreas Rumpf

import std / [atomics, locks, tasks]

type
  Master* = object ## Masters can spawn new chan inside an `awaitAll` block.
    c: Cond
    L: Lock
    runningTasks: int
    stopToken: Atomic[bool]

proc `=destroy`(m: var Master) {.inline.} =
  deinitCond(m.c)
  deinitLock(m.L)

proc `=copy`(dest: var Master; src: Master) {.error.}
proc `=sink`(dest: var Master; src: Master) {.error.}

proc createMaster*(): Master =
  result = default(Master)
  initCond(result.c)
  initLock(result.L)

proc abort*(m: var Master) =
  ## Try to stop all running tasks immediately.
  ## This cannot fail but it might take longer than desired.
  store(m.stopToken, true, moRelaxed)

proc taskCreated(m: var Master) {.inline.} =
  acquire(m.L)
  inc m.runningTasks
  release(m.L)

proc taskCompleted(m: var Master) {.inline.} =
  acquire(m.L)
  dec m.runningTasks
  release(m.L)
  signal(m.c)

proc waitForCompletions(m: var Master) {.inline.} =
  acquire(m.L)
  while m.runningTasks > 0:
    wait(m.c, m.L)
  release(m.L)

# thread pool independent of the 'master':

const
  FixedChanSize {.intdefine.} = 64 ## must be power of two!
  FixedChanMask = FixedChanSize - 1

  ThreadPoolSize {.intdefine.} = 256

type
  PoolTask = object ## a task for the thread pool
    m: ptr Master   ## who is waiting for us
    t: Task         ## what to do

  FixedChan = object ## channel of a fixed size
    spaceAvailable, dataAvailable: Cond
    L: Lock
    head, tail, count: int
    data: array[FixedChanSize, PoolTask]

var
  thr: array[ThreadPoolSize, Thread[void]]
  chan: FixedChan
  globalStopToken: Atomic[bool]

proc send(item: sink PoolTask) =
  # see deques.addLast:
  acquire(chan.L)
  if chan.count >= FixedChanSize:
    wait(chan.spaceAvailable, chan.L)
  if chan.count < FixedChanSize:
    inc chan.count
    chan.data[chan.tail] = item
    chan.tail = (chan.tail + 1) and FixedChanMask
    release(chan.L)
    signal(chan.dataAvailable)
  else:
    release(chan.L)
    quit "logic bug: queue not empty after signal!"

proc worker() {.thread.} =
  var item: PoolTask
  while not globalStopToken.load(moRelaxed):
    acquire(chan.L)
    while chan.count == 0:
      wait(chan.dataAvailable, chan.L)
    if chan.count > 0:
      # see deques.popFirst:
      dec chan.count
      item = move chan.data[chan.head]
      chan.head = (chan.head + 1) and FixedChanMask
    release(chan.L)
    signal(chan.spaceAvailable)
    if not item.m.stopToken.load(moRelaxed):
      item.t.invoke()
      taskCompleted item.m[]

proc setup() =
  initCond(chan.dataAvailable)
  initCond(chan.spaceAvailable)
  initLock(chan.L)
  for i in 0..high(thr): createThread[void](thr[i], worker)

proc panicStop*() =
  ## Stops all threads.
  globalStopToken.store(true, moRelaxed)
  joinThreads(thr)

template spawn*(master: var Master; fn: typed) =
  taskCreated master
  send PoolTask(m: addr(master), t: toTask(fn))

template awaitAll*(master: var Master; body: untyped) =
  try:
    body
  finally:
    waitForCompletions(master)

when not defined(maleSkipSetup):
  setup()
