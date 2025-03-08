import os, windows/winlean
import base

{.pragma: libKernel32, stdcall, dynlib: "Kernel32.dll".}

type
  FILE_NOTIFY_INFORMATION* = object
    NextEntryOffset*: DWORD
    Action*: DWORD
    FileNameLength*: DWORD
    FileName*: UncheckedArray[Utf16Char]

const
  FILE_FLAG_WRITE_THROUGH* = 0x80000000
  FILE_FLAG_OVERLAPPED* = 0x40000000
  FILE_FLAG_NO_BUFFERING* = 0x20000000
  FILE_FLAG_RANDOM_ACCESS* = 0x10000000
  FILE_FLAG_SEQUENTIAL_SCAN* = 0x08000000
  FILE_FLAG_DELETE_ON_CLOSE* = 0x04000000
  FILE_FLAG_BACKUP_SEMANTICS* = 0x02000000
  FILE_FLAG_POSIX_SEMANTICS* = 0x01000000
  FILE_FLAG_SESSION_AWARE* = 0x00800000
  FILE_FLAG_OPEN_REPARSE_POINT* = 0x00200000
  FILE_FLAG_OPEN_NO_RECALL* = 0x00100000
  FILE_FLAG_FIRST_PIPE_INSTANCE* = 0x00080000

  FILE_NOTIFY_CHANGE_FILE_NAME* = 0x00000001
  FILE_NOTIFY_CHANGE_DIR_NAME* = 0x00000002
  FILE_NOTIFY_CHANGE_ATTRIBUTES* = 0x00000004
  FILE_NOTIFY_CHANGE_SIZE* = 0x00000008
  FILE_NOTIFY_CHANGE_LAST_WRITE* = 0x00000010
  FILE_NOTIFY_CHANGE_LAST_ACCESS* = 0x00000020
  FILE_NOTIFY_CHANGE_CREATION* = 0x00000040
  FILE_NOTIFY_CHANGE_SECURITY* = 0x00000100

  FILE_READ_DATA* = (0x00000001) ##  file & pipe
  FILE_LIST_DIRECTORY* = (0x00000001) ##  directory

  FILE_ACTION_ADDED* = 0x00000001
  FILE_ACTION_REMOVED* = 0x00000002
  FILE_ACTION_MODIFIED* = 0x00000003
  FILE_ACTION_RENAMED_OLD_NAME* = 0x00000004
  FILE_ACTION_RENAMED_NEW_NAME* = 0x00000005

proc readDirectoryChangesW*(
  hDirectory: Handle,
  lpBuffer: pointer,
  nBufferLength: DWORD,
  bWatchSubtree: WINBOOL,
  dwNotifyFilter: DWORD,
  lpBytesReturned: var DWORD,
  lpOverlapped: ptr OVERLAPPED,
  lpCompletionRoutine: POVERLAPPED_COMPLETION_ROUTINE
): WINBOOL {.libKernel32, importc: "ReadDirectoryChangesW".}

proc startQueue*(data: var PathEventData) =
  discard readDirectoryChangesW(data.handle, data.buffer.cstring,
              cast[DWORD](data.buffer.len), 0, FILE_NOTIFY_CHANGE_FILE_NAME or
              FILE_NOTIFY_CHANGE_DIR_NAME or
              FILE_NOTIFY_CHANGE_LAST_WRITE, data.reads, addr data.over, nil)


proc init(data: var PathEventData) =
  let name = newWideCString(data.name)
  data.name = expandFilename(data.name)
  data.exists = true
  data.buffer = newString(1024)
  data.handle = createFileW(name, FILE_LIST_DIRECTORY, FILE_SHARE_DELETE or FILE_SHARE_READ or FILE_SHARE_WRITE, nil,
                              OPEN_EXISTING, FILE_FLAG_OVERLAPPED or FILE_FLAG_BACKUP_SEMANTICS, 0)
  startQueue(data)

proc initDirEventData*(name: string, cb: EventCallback): PathEventData =
  result = PathEventData(kind: PathKind.Dir, name: name)
  result.cb = cb

  if dirExists(name):
    init(result)

# proc initDirEventData*(args: seq[tuple[name: string, cb: EventCallback]]): seq[DirEventData] =
#   result = newSeq[DirEventData](args.len)
#   for idx in 0 ..< args.len:
#     result[idx].name = args[idx].name
#     result[idx].cb = args[idx].cb

#     if dirExists(result[idx].name):
#       init(result[idx])

proc dircb*(data: var PathEventData) =
  if data.exists:
    if dirExists(data.name):
      if data.handle == 0:
        let name = newWideCString(data.name)
        data.handle = createFileW(name, FILE_LIST_DIRECTORY, FILE_SHARE_DELETE or FILE_SHARE_READ or FILE_SHARE_WRITE, nil,
                            OPEN_EXISTING, FILE_FLAG_OVERLAPPED or FILE_FLAG_BACKUP_SEMANTICS, 0)


      var event: seq[PathEvent]
      for _ in 0 ..< 2:
        if getOverlappedResult(data.handle, addr data.over, data.reads, 0) != 0:
          var buf = cast[pointer](data.buffer.substr(0, data.reads.int - 1).cstring)
          var oldName = ""
          var next: int

          while true:
            let info = cast[ptr FILE_NOTIFY_INFORMATION](cast[ByteAddress](buf) + next)

            if info == nil:
              break

            ## TODO reduce copy
            var tmp = newWideCString("", info.FileNameLength.int div 2)
            for idx in 0 ..< info.FileNameLength.int div 2:
              tmp[idx] = info.FileName[idx]

            let name = $tmp

            case info.Action
            of FILE_ACTION_ADDED:
              event.add(initPathEvent(name, FileEventAction.Create))
            of FILE_ACTION_REMOVED:
              event.add(initPathEvent(name,FileEventAction.Remove))
            of FILE_ACTION_MODIFIED:
              event.add(initPathEvent(name, FileEventAction.Modify))
            of FILE_ACTION_RENAMED_OLD_NAME:
              oldName = name
            of FILE_ACTION_RENAMED_NEW_NAME:
              event.add(initPathEvent(oldName, FileEventAction.Rename, name))
            else:
              discard

            if info.NextEntryOffset == 0:
              break

            inc(next, info.NextEntryOffset.int)

          call(data, event)
        startQueue(data)

    else:
      data.exists = false
      data.handle = 0
      call(data, @[initPathEvent("", FileEventAction.RemoveSelf)])

  else:
    if dirExists(data.name):
      init(data)
      call(data, @[initPathEvent("", FileEventAction.CreateSelf)])
