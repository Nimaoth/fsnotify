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
  lpBytesReturned: ptr DWORD,
  lpOverlapped: ptr OVERLAPPED,
  lpCompletionRoutine: POVERLAPPED_COMPLETION_ROUTINE
): WINBOOL {.libKernel32, importc: "ReadDirectoryChangesW".}

proc cancelIoEx(
  hFile: Handle,
  lpOverlapped: ptr OVERLAPPED
): WINBOOL {.libKernel32, importc: "CancelIoEx".}

const
  ERROR_IO_INCOMPLETE = 996'i32
  ERROR_OPERATION_ABORTED = 995'i32
  ERROR_NOT_FOUND = 1168'i32

proc raiseWin32Error(error: int32, message: string) =
  raiseOSError(OSErrorCode(error), message)

proc closeDirectoryHandle(data: var PathEventData): int32 =
  let handle = data.handle
  if handle == 0 or handle == INVALID_HANDLE_VALUE:
    data.handle = 0
    return 0

  data.handle = 0
  if data.over != nil:
    if cancelIoEx(handle, data.over[].addr) != 0:
      var bytes: DWORD
      if getOverlappedResult(handle, data.over[].addr, bytes, 1) == 0:
        let error = getLastError()
        if error != ERROR_OPERATION_ABORTED:
          result = error
    else:
      let error = getLastError()
      if error == ERROR_NOT_FOUND:
        var bytes: DWORD
        if getOverlappedResult(handle, data.over[].addr, bytes, 0) == 0:
          let resultError = getLastError()
          if resultError != ERROR_IO_INCOMPLETE:
            result = resultError
      else:
        result = error

  if closeHandle(handle) == 0 and result == 0:
    result = getLastError()

proc closeDirEventData*(data: var PathEventData) =
  let error = closeDirectoryHandle(data)
  if error != 0:
    raiseWin32Error(error, "Failed to close directory watcher")

proc startQueue*(data: var PathEventData) =
  data.reads = 0
  data.over[] = default(OVERLAPPED)
  if readDirectoryChangesW(data.handle, data.buffer[].cstring,
      cast[DWORD](data.buffer[].len), 0, FILE_NOTIFY_CHANGE_FILE_NAME or
      FILE_NOTIFY_CHANGE_DIR_NAME or FILE_NOTIFY_CHANGE_LAST_WRITE,
      nil, data.over[].addr, nil) == 0:
    let error = getLastError()
    if error != ERROR_IO_PENDING:
      let cleanupError = closeDirectoryHandle(data)
      if cleanupError != 0:
        raiseWin32Error(cleanupError,
          "ReadDirectoryChangesW failed with error " & $error &
          "; failed to close directory watcher")
      raiseWin32Error(error, "ReadDirectoryChangesW failed")

proc openDirectory(data: var PathEventData) =
  data.handle = createFileW(data.namew, FILE_LIST_DIRECTORY,
    FILE_SHARE_DELETE or FILE_SHARE_READ or FILE_SHARE_WRITE, nil,
    OPEN_EXISTING, FILE_FLAG_OVERLAPPED or FILE_FLAG_BACKUP_SEMANTICS, 0)
  if data.handle == INVALID_HANDLE_VALUE:
    let error = getLastError()
    data.handle = 0
    raiseWin32Error(error, "Failed to open directory watcher for " & data.name)
  startQueue(data)


proc init(data: var PathEventData) =
  data.name = expandFilename(data.name)
  data.namew = newWideCString(data.name)
  data.exists = true
  data.buffer[] = newString(1024)
  openDirectory(data)

proc initDirEventData*(name: string, cb: EventCallback): PathEventData =
  result = PathEventData(kind: PathKind.Dir, name: name)
  new(result.over)
  new(result.buffer)
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
        openDirectory(data)
        return

      if getOverlappedResult(data.handle, data.over[].addr, data.reads, 0) == 0:
        let error = getLastError()
        if error == ERROR_IO_INCOMPLETE:
          return
        let cleanupError = closeDirectoryHandle(data)
        if cleanupError != 0:
          raiseWin32Error(cleanupError,
            "GetOverlappedResult failed with error " & $error &
            "; failed to close directory watcher")
        raiseWin32Error(error, "GetOverlappedResult failed")

      var event: seq[PathEvent]
      var oldName = ""
      var next = 0
      let bytesRead = data.reads.int
      const fileNotifyHeaderSize = sizeof(DWORD) * 3

      while next <= bytesRead - fileNotifyHeaderSize:
        let info = cast[ptr FILE_NOTIFY_INFORMATION](data.buffer[][next].addr)
        let nameLength = info.FileNameLength.int
        if nameLength mod 2 != 0 or nameLength > bytesRead - next - fileNotifyHeaderSize:
          break

        ## TODO reduce copy
        var tmp = newWideCString(nameLength div 2)
        for idx in 0 ..< nameLength div 2:
          tmp[idx] = info.FileName[idx]

        let name = $tmp

        case info.Action
        of FILE_ACTION_ADDED:
          event.add(initPathEvent(name, FileEventAction.Create))
        of FILE_ACTION_REMOVED:
          event.add(initPathEvent(name, FileEventAction.Remove))
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
        let nextEntryOffset = info.NextEntryOffset.int
        if nextEntryOffset < fileNotifyHeaderSize or nextEntryOffset > bytesRead - next:
          break
        inc(next, nextEntryOffset)

      startQueue(data)
      call(data, event)

    else:
      data.exists = false
      let error = closeDirectoryHandle(data)
      if error != 0:
        raiseWin32Error(error, "Failed to close removed directory watcher")
      call(data, @[initPathEvent("", FileEventAction.RemoveSelf)])

  else:
    if dirExists(data.name):
      init(data)
      call(data, @[initPathEvent("", FileEventAction.CreateSelf)])
