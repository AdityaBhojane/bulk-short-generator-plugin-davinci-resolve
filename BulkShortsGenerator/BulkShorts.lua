-- BulkShorts.lua (V15)
-- Place in: ...Scripts\Utility\BulkShortsGenerator\BulkShorts.lua
-- gui.html and ljsocket.lua must be in this same folder.
-- Run via: Resolve -> Workspace -> Scripts -> Utility -> BulkShorts (the launcher stub)

local ffi = require("ffi")
ffi.cdef[[ void Sleep(unsigned int ms); ]]
local function sleep_ms(ms) ffi.C.Sleep(ms) end

local script_dir = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
package.path = script_dir .. "?.lua;" .. package.path
local socket = require("ljsocket")

local PORT = "56010"
local SETTINGS_PATH = script_dir .. "settings.json"
local BATCH_PATH = script_dir .. "batch.json"

-----------------------------------------------------------------------
-- JSON
-----------------------------------------------------------------------
local json = {}
function json.encode(v)
  local t = type(v)
  if t == "nil" then return "null"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number" then return tostring(v)
  elseif t == "string" then
    return '"' .. v:gsub('[\\"]', '\\%0'):gsub('\n', '\\n') .. '"'
  elseif t == "table" then
    if #v > 0 then
      local parts = {}
      for _, item in ipairs(v) do parts[#parts+1] = json.encode(item) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, val in pairs(v) do
        parts[#parts+1] = json.encode(tostring(k)) .. ":" .. json.encode(val)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

function json.decode(str)
  local pos = 1
  local function skip_ws() while pos <= #str and str:sub(pos,pos):match("%s") do pos = pos + 1 end end
  local parse_value
  local function parse_string()
    pos = pos + 1
    local out = {}
    while true do
      local c = str:sub(pos, pos)
      if c == '"' then pos = pos + 1; break end
      if c == '\\' then
        local nxt = str:sub(pos+1, pos+1)
        if nxt == 'n' then out[#out+1] = '\n'
        elseif nxt == 't' then out[#out+1] = '\t'
        else out[#out+1] = nxt end
        pos = pos + 2
      else
        out[#out+1] = c; pos = pos + 1
      end
    end
    return table.concat(out)
  end
  local function parse_number()
    local start = pos
    while pos <= #str and str:sub(pos,pos):match("[%d%.%-eE%+]") do pos = pos + 1 end
    return tonumber(str:sub(start, pos-1))
  end
  local function parse_object()
    pos = pos + 1
    local obj = {}
    skip_ws()
    if str:sub(pos,pos) == "}" then pos = pos + 1; return obj end
    while true do
      skip_ws()
      local key = parse_string()
      skip_ws(); pos = pos + 1; skip_ws()
      obj[key] = parse_value()
      skip_ws()
      local c = str:sub(pos,pos)
      if c == "," then pos = pos + 1 else pos = pos + 1; break end
    end
    return obj
  end
  local function parse_array()
    pos = pos + 1
    local arr = {}
    skip_ws()
    if str:sub(pos,pos) == "]" then pos = pos + 1; return arr end
    while true do
      skip_ws()
      arr[#arr+1] = parse_value()
      skip_ws()
      local c = str:sub(pos,pos)
      if c == "," then pos = pos + 1 else pos = pos + 1; break end
    end
    return arr
  end
  parse_value = function()
    skip_ws()
    local c = str:sub(pos,pos)
    if c == '"' then return parse_string()
    elseif c == "{" then return parse_object()
    elseif c == "[" then return parse_array()
    elseif str:sub(pos,pos+3) == "true" then pos=pos+4; return true
    elseif str:sub(pos,pos+4) == "false" then pos=pos+5; return false
    elseif str:sub(pos,pos+3) == "null" then pos=pos+4; return nil
    else return parse_number() end
  end
  local ok, result = pcall(parse_value)
  if not ok then return nil end
  return result
end

-----------------------------------------------------------------------
-- File helpers
-----------------------------------------------------------------------
local function sanitize_filename(name)
  name = tostring(name or "")
  -- Strip anything outside plain printable ASCII (32-126). This removes
  -- emoji and other Unicode symbols, which is necessary because Lua's file
  -- functions on Windows (io.open, os.remove, existence checks) go through
  -- the ANSI C runtime rather than Windows' Unicode-aware file APIs. An
  -- emoji cannot be represented in that ANSI encoding at all, so a filename
  -- containing one becomes invisible to Lua's own file checks even though
  -- Resolve (which IS Unicode-native) rendered it correctly -- this was the
  -- actual cause of "rendered file not found" errors and files that
  -- silently failed to get cleaned up. Only the file name is affected; your
  -- clip's title text elsewhere is untouched.
  local out = {}
  for i = 1, #name do
    local b = name:byte(i)
    if b >= 32 and b <= 126 then
      out[#out+1] = string.char(b)
    end
  end
  name = table.concat(out)
  -- Strip filesystem-illegal characters AND apostrophes/quotes. Apostrophes
  -- are legal in Windows filenames but break the ffmpeg concat list format
  -- (which wraps paths in single quotes), so we strip them at the source
  -- going forward rather than relying only on escaping downstream.
  name = name:gsub('[\\/:%*%?"<>|\']', "_")
  name = name:gsub("%s+", " ") -- collapse repeated spaces left behind by stripped characters
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if #name == 0 then name = "Short" end
  return name:sub(1, 100)
end

local function get_project()
  local pm = resolve:GetProjectManager()
  if not pm then return nil, "Could not get ProjectManager" end
  local project = pm:GetCurrentProject()
  if not project then return nil, "No project is open" end
  return project
end

local function get_timeline(project)
  local timeline = project:GetCurrentTimeline()
  if not timeline then return nil, "No timeline is open. Open the timeline you want to cut Shorts from." end
  return timeline
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

-- Retries a few times with a short pause, since a freshly-written file can
-- briefly be locked (e.g. antivirus/indexing scanning it right after the
-- process that wrote it exits). The os.remove() call itself is wrapped in
-- pcall: if it throws for any reason (rather than just returning false),
-- this must NOT crash the caller -- an uncaught error here previously meant
-- a stitch job's "done" status never got recorded, which caused the whole
-- stitch (including re-running ffmpeg) to silently restart every second,
-- forever, since the background checker kept seeing it as unfinished.
local function remove_file_retry(path, tries, delay_ms)
  tries = tries or 8
  delay_ms = delay_ms or 150
  for i = 1, tries do
    local ok, removed = pcall(os.remove, path)
    if ok and removed then return true end
    sleep_ms(delay_ms)
  end
  return false
end

-- Waits for a file to appear, since Resolve reporting the render queue as
-- "done" doesn't guarantee every job's file has finished being flushed and
-- closed on disk that exact instant -- with more jobs rendered back to
-- back, there's a higher chance the last one or two are still finalizing.
local function wait_for_file(path, tries, delay_ms)
  tries = tries or 10
  delay_ms = delay_ms or 300
  for i = 1, tries do
    if file_exists(path) then return true end
    sleep_ms(delay_ms)
  end
  return false
end

-- Retries a few times with a short pause, since a freshly-written file can
-- briefly be locked by antivirus/indexing right after the process that
-- created it exits.
local function remove_file_retry(path, tries, delay_ms)
  tries = tries or 5
  delay_ms = delay_ms or 100
  for i = 1, tries do
    if os.remove(path) then return true end
    sleep_ms(delay_ms)
  end
  return false
end

local function read_json_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return json.decode(content)
end

local function write_json_file(path, tbl)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(json.encode(tbl))
  f:close()
  return true
end

local function read_settings() return read_json_file(SETTINGS_PATH) or {} end
local function write_settings(tbl) return write_json_file(SETTINGS_PATH, tbl) end

-----------------------------------------------------------------------
-- Active batch state (survives window close/reopen; persisted to disk too)
-----------------------------------------------------------------------
local batch_state = {
  targetDir = "",
  presetName = "",
  jobs = {},          -- { {title=..., jobId=..., filename=..., presetApplied=bool|nil}, ... }
  outroPath = "",      -- fallback only; live stitching reads settings.json instead (see check_batch_completion)
  outputExt = "mp4",
  addOutro = false,
  deleteRaw = false,
  renderStarted = false,
  stitchDone = false,
  outroStatus = {},   -- jobId -> { ok=bool, finalPath=..., error=... }
}

local function persist_batch()
  write_json_file(BATCH_PATH, batch_state)
end

do
  local loaded = read_json_file(BATCH_PATH)
  if loaded then batch_state = loaded end
end

-- One-time cleanup sweep on startup: if a previous session left any concat
-- list .txt files behind (e.g. before this fix existed), remove them now.
if batch_state.targetDir and batch_state.targetDir ~= "" and batch_state.jobs then
  for _, job in ipairs(batch_state.jobs) do
    if job.filename then
      local strayPath = batch_state.targetDir .. "\\_bulkshorts_concat_" .. job.filename .. ".txt"
      if file_exists(strayPath) then
        remove_file_retry(strayPath, 5, 150)
      end
    end
  end
end

-----------------------------------------------------------------------
-- Outro stitching core (shared by manual handler + automatic background check)
-----------------------------------------------------------------------
local function ffmpeg_escape_concat_path(path)
  -- The concat demuxer wraps each 'file' entry in single quotes. If the path
  -- itself contains a single quote (e.g. an apostrophe in a clip title like
  -- "Croft's"), that quote closes the string early and ffmpeg tries to open
  -- a truncated, garbled path. Escape it with the standard '\'' technique:
  -- close the quote, insert an escaped literal quote, reopen the quote.
  return path:gsub("'", "'\\''")
end

local function read_log_tail(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local content = f:read("*a") or ""
  f:close()
  if #content == 0 then return "" end
  return content:sub(math.max(1, #content - 350)):gsub("\n", " ")
end

local function do_stitch(jobId, targetDir, filename, ext, outroPath, deleteRaw)
  local result

  if not targetDir or not filename then
    result = { ok = false, error = "Missing targetDir/filename" }
  elseif not outroPath or outroPath == "" then
    result = { ok = false, error = "No outro file path given" }
  elseif not file_exists(outroPath) then
    result = { ok = false, error = "Outro file not found: " .. outroPath }
  else
    local rawPath = targetDir .. "\\" .. filename .. "." .. ext
    local finalPath = targetDir .. "\\" .. filename .. "_final." .. ext
    local listPath = targetDir .. "\\_bulkshorts_concat_" .. filename .. ".txt"
    local logPath = listPath .. ".log"

    if not file_exists(rawPath) then
      result = { ok = false, error = "Rendered file not found: " .. rawPath }
    else
      local listFile = io.open(listPath, "w")
      if not listFile then
        result = { ok = false, error = "Could not write concat list file" }
      else
        listFile:write("file '" .. ffmpeg_escape_concat_path(rawPath:gsub("\\", "/")) .. "'\n")
        listFile:write("file '" .. ffmpeg_escape_concat_path(outroPath:gsub("\\", "/")) .. "'\n")
        listFile:close()

        local cmd = string.format(
          'ffmpeg -y -f concat -safe 0 -i "%s" -c copy "%s" > "%s" 2>&1',
          listPath, finalPath, logPath
        )
        os.execute(cmd)
        remove_file_retry(listPath)

        if not file_exists(finalPath) then
          local tail = read_log_tail(logPath)
          result = { ok = false, error = "ffmpeg did not produce an output file." .. (tail ~= "" and (" ffmpeg said: " .. tail) or " Check the .log file next to your renders.") }
        else
        if deleteRaw then remove_file_retry(rawPath, 5, 150) end
          result = { ok = true, finalPath = finalPath }
        end
      end
    end
  end

  batch_state.outroStatus[jobId] = result
  persist_batch()
  return result
end

-----------------------------------------------------------------------
-- Native file/folder browse dialogs.
-- We don't have fu.UIManager available in this scripting context, and a
-- browser window can only ever return a bare filename (never a real path)
-- from <input type=file> for security reasons. So instead we shell out to
-- PowerShell's built-in .NET dialogs (System.Windows.Forms), which are part
-- of every Windows install and don't need any extra downloads.
--
-- We launch PowerShell directly via CreateProcessA with CREATE_NO_WINDOW
-- (raw Win32, not io.popen) so no cmd.exe wrapper window flashes on screen --
-- io.popen always spawns a visible cmd.exe console on Windows since it has
-- no "hidden window" option of its own. The dialog script writes its result
-- to a small temp file, which we read back after the process exits, since
-- CreateProcessA doesn't give us the shell's ">" redirection syntax.
-----------------------------------------------------------------------
ffi.cdef[[
typedef struct _STARTUPINFOA {
  unsigned long cb;
  char* lpReserved;
  char* lpDesktop;
  char* lpTitle;
  unsigned long dwX;
  unsigned long dwY;
  unsigned long dwXSize;
  unsigned long dwYSize;
  unsigned long dwXCountChars;
  unsigned long dwYCountChars;
  unsigned long dwFillAttribute;
  unsigned long dwFlags;
  unsigned short wShowWindow;
  unsigned short cbReserved2;
  unsigned char* lpReserved2;
  void* hStdInput;
  void* hStdOutput;
  void* hStdError;
} STARTUPINFOA;

typedef struct _PROCESS_INFORMATION {
  void* hProcess;
  void* hThread;
  unsigned long dwProcessId;
  unsigned long dwThreadId;
} PROCESS_INFORMATION;

int CreateProcessA(
  const char* lpApplicationName,
  char* lpCommandLine,
  void* lpProcessAttributes,
  void* lpThreadAttributes,
  int bInheritHandles,
  unsigned long dwCreationFlags,
  void* lpEnvironment,
  const char* lpCurrentDirectory,
  STARTUPINFOA* lpStartupInfo,
  PROCESS_INFORMATION* lpProcessInformation
);
unsigned long WaitForSingleObject(void* hHandle, unsigned long dwMilliseconds);
int CloseHandle(void* hObject);
]]

local CREATE_NO_WINDOW = 0x08000000
local INFINITE = 0xFFFFFFFF

-- Directory listing, used by the standalone "Add Outros Manually" recovery
-- tool. Implemented via raw FindFirstFileA/FindNextFileA (same family of
-- API as the CreateProcessA call above) rather than shelling out to `dir`,
-- so it's fast, synchronous, and never flashes a console window.
ffi.cdef[[
typedef struct _FILETIME { unsigned long dwLowDateTime; unsigned long dwHighDateTime; } FILETIME;
typedef struct _WIN32_FIND_DATAA {
  unsigned long dwFileAttributes;
  FILETIME ftCreationTime;
  FILETIME ftLastAccessTime;
  FILETIME ftLastWriteTime;
  unsigned long nFileSizeHigh;
  unsigned long nFileSizeLow;
  unsigned long dwReserved0;
  unsigned long dwReserved1;
  char cFileName[260];
  char cAlternateFileName[14];
} WIN32_FIND_DATAA;
void* FindFirstFileA(const char* lpFileName, WIN32_FIND_DATAA* lpFindFileData);
int FindNextFileA(void* hFindFile, WIN32_FIND_DATAA* lpFindFileData);
int FindClose(void* hFindFile);
]]

local bit = require("bit")
local FILE_ATTRIBUTE_DIRECTORY = 0x10

local function list_files_with_ext(folder, ext)
  local results = {}
  local pattern = folder .. "\\*." .. ext
  local findData = ffi.new("WIN32_FIND_DATAA")
  local handle = ffi.C.FindFirstFileA(pattern, findData)
  if tonumber(ffi.cast("intptr_t", handle)) == -1 then
    return results
  end
  repeat
    local name = ffi.string(findData.cFileName)
    local isDir = bit.band(findData.dwFileAttributes, FILE_ATTRIBUTE_DIRECTORY) ~= 0
    if name ~= "." and name ~= ".." and not isDir then
      results[#results+1] = name
    end
  until ffi.C.FindNextFileA(handle, findData) == 0
  ffi.C.FindClose(handle)
  return results
end

-- Runs a command line completely windowless and waits for it to exit.
-- Returns true if the process was successfully launched (regardless of
-- what it did once running), or false if CreateProcessA itself failed.
local function run_hidden(cmdline)
  local si = ffi.new("STARTUPINFOA")
  si.cb = ffi.sizeof("STARTUPINFOA")
  local pi = ffi.new("PROCESS_INFORMATION")
  local buf = ffi.new("char[?]", #cmdline + 1)
  ffi.copy(buf, cmdline)
  local ok = ffi.C.CreateProcessA(nil, buf, nil, nil, 0, CREATE_NO_WINDOW, nil, nil, si, pi)
  if ok == 0 then return false end
  ffi.C.WaitForSingleObject(pi.hProcess, INFINITE)
  ffi.C.CloseHandle(pi.hProcess)
  ffi.C.CloseHandle(pi.hThread)
  return true
end

-- Runs a PowerShell script windowless. The script must, on success, write
-- its result to the literal text "TEMPPATH" (which we substitute with a
-- real temp file path) using [System.IO.File]::WriteAllText('TEMPPATH', $result).
-- Returns the trimmed file contents, or nil if the user cancelled / nothing
-- was written.
local function run_powershell_dialog_hidden(psBodyWithPlaceholder)
  local tempPath = (os.getenv("TEMP") or "C:\\Windows\\Temp")
    .. "\\bulkshorts_dlg_" .. os.time() .. "_" .. tostring(os.clock()):gsub("[%.%-]", "") .. ".txt"

  local script = psBodyWithPlaceholder:gsub("TEMPPATH", tempPath)
  local cmdline = 'powershell.exe -NoProfile -WindowStyle Hidden -Command "' .. script:gsub('"', '\\"') .. '"'

  local launched = run_hidden(cmdline)
  if not launched then return nil, "Could not launch the file browser." end

  local result = nil
  local f = io.open(tempPath, "r")
  if f then
    result = f:read("*a")
    f:close()
    os.remove(tempPath)
  end
  if result then
    result = result:gsub("^%s+", ""):gsub("%s+$", "")
    if result == "" then result = nil end
  end
  return result
end

-----------------------------------------------------------------------
-- Handlers
-----------------------------------------------------------------------
local handlers = {}
local running = true

handlers["Ping"] = function(data)
  return { ok = true, message = "BulkShorts Lua server is alive" }
end

handlers["Shutdown"] = function(data)
  print("[BulkShorts] Shutdown request received. Stopping...")
  running = false
  return { ok = true, message = "Server shutting down" }
end

handlers["GetTimelineInfo"] = function(data)
  local project, err = get_project()
  if not project then return { error = err } end
  local timeline, terr = get_timeline(project)
  if not timeline then return { error = terr } end

  local fps = tonumber(timeline:GetSetting("timelineFrameRate")) or 30
  return {
    ok = true,
    name = timeline:GetName(),
    fps = fps,
    startFrame = timeline:GetStartFrame(),
    endFrame = timeline:GetEndFrame(),
    durationSeconds = (timeline:GetEndFrame() - timeline:GetStartFrame()) / fps,
  }
end

-- Settings persistence
handlers["GetSettings"] = function(data)
  return { ok = true, settings = read_settings() }
end

handlers["SaveSettings"] = function(data)
  local existing = read_settings()
  for k, v in pairs(data.settings or {}) do existing[k] = v end
  if not write_settings(existing) then return { error = "Could not write settings.json" } end
  return { ok = true }
end

-- Native browse dialogs
handlers["BrowseFile"] = function(data)
  local filter = data.filter or "All Files|*.*"
  local ps = string.format(
    "Add-Type -AssemblyName System.Windows.Forms; " ..
    "$f = New-Object System.Windows.Forms.OpenFileDialog; " ..
    "$f.Filter = '%s'; " ..
    "if ($f.ShowDialog() -eq 'OK') { $result = $f.FileName } else { $result = '' }; " ..
    "if ($result -ne '') { [System.IO.File]::WriteAllText('TEMPPATH', $result) }",
    filter
  )
  local output, err = run_powershell_dialog_hidden(ps)
  if err then return { error = err } end
  if not output then return { ok = true, path = nil, cancelled = true } end
  return { ok = true, path = output }
end

handlers["BrowseFolder"] = function(data)
  -- Uses the file-open dialog with a fake filename rather than the older
  -- FolderBrowserDialog, since that gives the same modern Explorer-style
  -- window as file selection instead of the old tree-view "Browse For
  -- Folder" dialog. Taking the parent directory of the fake filename gives
  -- us the folder the person navigated into.
  local ps =
    "Add-Type -AssemblyName System.Windows.Forms; " ..
    "$f = New-Object System.Windows.Forms.OpenFileDialog; " ..
    "$f.ValidateNames = $false; " ..
    "$f.CheckFileExists = $false; " ..
    "$f.CheckPathExists = $true; " ..
    "$f.FileName = 'Folder Selection.'; " ..
    "$f.Title = 'Select Output Folder'; " ..
    "if ($f.ShowDialog() -eq 'OK') { $result = Split-Path $f.FileName -Parent } else { $result = '' }; " ..
    "if ($result -ne '') { [System.IO.File]::WriteAllText('TEMPPATH', $result) }"

  local output, err = run_powershell_dialog_hidden(ps)
  if err then return { error = err } end
  if not output then return { ok = true, path = nil, cancelled = true } end
  return { ok = true, path = output }
end

-- Active batch (restores UI state after window close/reopen)
handlers["GetActiveBatch"] = function(data)
  return { ok = true, batch = batch_state }
end

handlers["ClearActiveBatch"] = function(data)
  batch_state = {
    targetDir = "", presetName = "", jobs = {}, outroPath = "", outputExt = "mp4",
    addOutro = false, deleteRaw = false, renderStarted = false,
    stitchDone = false, outroStatus = {},
  }
  persist_batch()
  return { ok = true }
end

-- Render presets (reads YOUR saved Deliver-page presets; we never invent codec settings)
handlers["GetRenderPresets"] = function(data)
  local project, err = get_project()
  if not project then return { error = err } end
  local ok, list = pcall(function() return project:GetRenderPresetList() end)
  if not ok or not list then return { ok = true, presets = {} } end

  local names = {}
  for _, entry in ipairs(list) do
    local name = nil
    if type(entry) == "table" then
      name = entry.PresetName or entry.Name or entry.name
      if not name then
        for k, v in pairs(entry) do
          if type(v) == "string" then name = v; break end
        end
      end
    elseif type(entry) == "string" then
      name = entry
    end
    if name then names[#names+1] = name end
  end
  return { ok = true, presets = names }
end

handlers["QueueRenderJobs"] = function(data)
  local project, err = get_project()
  if not project then return { error = err } end
  local timeline, terr = get_timeline(project)
  if not timeline then return { error = terr } end

  local fps = tonumber(timeline:GetSetting("timelineFrameRate")) or 30
  local startFrame = timeline:GetStartFrame()
  local endFrame = timeline:GetEndFrame()

  if data.clearQueueFirst then
    project:DeleteAllRenderJobs()
  end

  local targetDir = data.targetDir
  if not targetDir or targetDir == "" then
    targetDir = (os.getenv("USERPROFILE") or "C:\\Users\\Public") .. "\\Videos\\BulkShorts"
  end
  os.execute('mkdir "' .. targetDir .. '" 2> nul')

  local presetName = data.renderPresetName
  local results = {}
  local usedNames = {}

  for i, clip in ipairs(data.clips or {}) do
    local startSec = tonumber(clip.startSeconds)
    local endSec = tonumber(clip.endSeconds)

    if not startSec or not endSec then
      results[#results+1] = { title = clip.title, ok = false, error = "Missing/invalid start or end time" }
    else
      local markIn  = startFrame + math.floor(startSec * fps + 0.5)
      local markOut = startFrame + math.floor(endSec * fps + 0.5) - 1

      if markIn < startFrame then markIn = startFrame end
      if markOut > endFrame then markOut = endFrame end

      if markOut <= markIn then
        results[#results+1] = { title = clip.title, ok = false, error = "Range is outside the timeline or end <= start" }
      else
        local baseName = sanitize_filename(clip.title ~= "" and clip.title or ("Short_" .. i))
        local finalName = baseName
        local dupeIndex = 1
        while usedNames[finalName] do
          dupeIndex = dupeIndex + 1
          finalName = baseName .. "_" .. dupeIndex
        end
        usedNames[finalName] = true

        -- IMPORTANT: reload the preset right before THIS job, every time.
        -- SetRenderSettings() can silently reset codec/format fields back to
        -- Resolve's current default, so loading the preset once at the top
        -- of the batch is not reliable -- it has to be reasserted immediately
        -- before every single AddRenderJob() call.
        local presetApplied = nil
        if presetName and presetName ~= "" then
          presetApplied = project:LoadRenderPreset(presetName) and true or false
        end

        project:SetRenderSettings({
          SelectAllFrames = false,
          MarkIn = markIn,
          MarkOut = markOut,
          TargetDir = targetDir,
          CustomName = finalName,
        })
        local jobId = project:AddRenderJob()

        if jobId then
          results[#results+1] = {
            title = clip.title, ok = true, jobId = jobId,
            markIn = markIn, markOut = markOut, filename = finalName,
            presetApplied = presetApplied,
          }
        else
          results[#results+1] = { title = clip.title, ok = false, error = "AddRenderJob failed", presetApplied = presetApplied }
        end
      end
    end
  end

  -- Store this as the new active batch, so it survives window close/reopen.
  -- Note: outroPath/outputExt/addOutro/deleteRaw stored here are only a
  -- FALLBACK snapshot. The actual background stitcher (check_batch_completion)
  -- reads the LIVE values from settings.json at stitch time, so changing the
  -- outro section after queueing (a very normal thing to do) still works.
  local newJobs = {}
  for _, r in ipairs(results) do
    if r.ok then
      newJobs[#newJobs+1] = { title = r.title, jobId = r.jobId, filename = r.filename, presetApplied = r.presetApplied }
    end
  end
  batch_state = {
    targetDir = targetDir,
    presetName = presetName or "",
    jobs = newJobs,
    outroPath = data.outroPath or "",
    outputExt = data.outputExt or "mp4",
    addOutro = data.addOutro and true or false,
    deleteRaw = data.deleteRaw and true or false,
    renderStarted = false,
    stitchDone = false,
    outroStatus = {},
  }
  persist_batch()

  return { ok = true, results = results, targetDir = targetDir, presetName = presetName or "" }
end

handlers["StartRenderAll"] = function(data)
  local project, err = get_project()
  if not project then return { error = err } end
  if not data.jobIds or #data.jobIds == 0 then return { error = "No job ids given" } end
  if project:IsRenderingInProgress() then return { error = "Render already in progress" } end
  local started = project:StartRendering(data.jobIds, false)
  if started ~= false then
    batch_state.renderStarted = true
    batch_state.stitchDone = false
    persist_batch()
  end
  return { ok = started ~= false }
end

handlers["GetRenderStatus"] = function(data)
  local project, err = get_project()
  if not project then return { error = err } end
  local statuses = {}
  for _, id in ipairs(data.jobIds or {}) do
    local st = project:GetRenderJobStatus(id)
    statuses[#statuses+1] = {
      jobId = id,
      status = st and st.JobStatus or "Unknown",
      pct = st and tonumber(st.CompletionPercentage) or 0,
    }
  end
  return { ok = true, inProgress = project:IsRenderingInProgress(), statuses = statuses }
end

handlers["StopRendering"] = function(data)
  local project, err = get_project()
  if not project then return { error = err } end
  project:StopRendering()
  batch_state.renderStarted = false
  persist_batch()
  return { ok = true }
end

handlers["ClearQueue"] = function(data)
  local project, err = get_project()
  if not project then return { error = err } end
  project:DeleteAllRenderJobs()
  return { ok = true }
end

-- ---- Manual outro recovery tool: works on any folder, independent of any tracked batch ----

handlers["ScanFolderForClips"] = function(data)
  local folder = data.targetDir
  local ext = data.extension or "mp4"
  if not folder or folder == "" then return { error = "No folder given" } end

  local ok, files = pcall(list_files_with_ext, folder, ext)
  if not ok then return { error = "Could not scan folder: " .. tostring(files) } end

  local clips = {}
  local extLen = #ext + 1 -- ".ext"
  for _, fname in ipairs(files) do
    if fname:sub(-extLen) == "." .. ext and not fname:match("^_bulkshorts_concat_") then
      local base = fname:sub(1, -(extLen + 1))
      if not base:match("_final$") then
        local finalExists = file_exists(folder .. "\\" .. base .. "_final." .. ext)
        clips[#clips+1] = { filename = base, alreadyDone = finalExists }
      end
    end
  end
  return { ok = true, clips = clips }
end

handlers["StitchFolderClip"] = function(data)
  local targetDir = data.targetDir
  local filename = data.filename
  local ext = data.extension or "mp4"
  local outroPath = data.outroPath
  local deleteRaw = data.deleteRaw

  if not targetDir or not filename then return { error = "Missing targetDir/filename" } end
  if not outroPath or outroPath == "" then return { error = "No outro file path given" } end
  if not file_exists(outroPath) then return { error = "Outro file not found: " .. outroPath } end

  local rawPath = targetDir .. "\\" .. filename .. "." .. ext
  local finalPath = targetDir .. "\\" .. filename .. "_final." .. ext
  local listPath = targetDir .. "\\_bulkshorts_concat_" .. filename .. ".txt"
  local logPath = listPath .. ".log"

  if not file_exists(rawPath) then return { error = "Clip not found: " .. rawPath } end

  local listFile = io.open(listPath, "w")
  if not listFile then return { error = "Could not write concat list file" } end
  listFile:write("file '" .. ffmpeg_escape_concat_path(rawPath:gsub("\\", "/")) .. "'\n")
  listFile:write("file '" .. ffmpeg_escape_concat_path(outroPath:gsub("\\", "/")) .. "'\n")
  listFile:close()

  local cmd = string.format('ffmpeg -y -f concat -safe 0 -i "%s" -c copy "%s" > "%s" 2>&1', listPath, finalPath, logPath)
  os.execute(cmd)
  remove_file_retry(listPath)

  if not file_exists(finalPath) then
    local tail = read_log_tail(logPath)
    return { error = "ffmpeg did not produce an output file." .. (tail ~= "" and (" ffmpeg said: " .. tail) or "") }
  end

  if deleteRaw then remove_file_retry(rawPath, 5, 150) end
  return { ok = true, finalPath = finalPath }
end

-- ---- Batch-tracked outro stitching ----

handlers["CheckFfmpeg"] = function(data)
  local handle = io.popen("ffmpeg -version 2>&1")
  if not handle then return { ok = false, error = "Could not launch ffmpeg process" } end
  local output = handle:read("*a") or ""
  handle:close()
  local version = output:match("ffmpeg version (%S+)")
  if version then return { ok = true, version = version } end
  return { ok = false, error = "ffmpeg not found on PATH. Install it and restart Resolve." }
end

-- Manual/on-demand stitch. Used both for a single job "Retry" click from the
-- UI, and as the underlying implementation for the automatic background pass.
handlers["StitchOutro"] = function(data)
  local result = do_stitch(data.jobId or (data.filename or "manual"), data.targetDir, data.filename, data.extension or "mp4", data.outroPath, data.deleteRaw)
  if not result.ok then return { error = result.error } end
  return { ok = true, finalPath = result.finalPath }
end

-----------------------------------------------------------------------
-- Background check: fires automatically when rendering finishes, even if
-- no browser window is connected. Runs whether or not a request is pending.
-----------------------------------------------------------------------
local function check_batch_completion()
  if not batch_state.renderStarted or batch_state.stitchDone then return end

  local project, err = get_project()
  if not project then return end -- project temporarily unavailable, try again next tick

  local inProgress = project:IsRenderingInProgress()
  if inProgress then return end

  -- Rendering just finished. Read the LIVE outro settings (whatever the
  -- person last saved, even if they changed it after queueing), falling
  -- back to what was captured at queue time only if nothing newer exists.
  local liveSettings = read_settings()
  local addOutro = liveSettings.addOutro
  if addOutro == nil then addOutro = batch_state.addOutro end
  local outroPath = liveSettings.outroPath
  if outroPath == nil or outroPath == "" then outroPath = batch_state.outroPath end
  local outputExt = liveSettings.outputExt
  if outputExt == nil or outputExt == "" then outputExt = batch_state.outputExt end
  local deleteRaw = liveSettings.deleteRaw
  if deleteRaw == nil then deleteRaw = batch_state.deleteRaw end

  if addOutro and outroPath and outroPath ~= "" then
    for _, job in ipairs(batch_state.jobs) do
      if not batch_state.outroStatus[job.jobId] then
        do_stitch(job.jobId, batch_state.targetDir, job.filename, outputExt, outroPath, deleteRaw)
      end
    end
  end

  batch_state.renderStarted = false
  batch_state.stitchDone = true
  persist_batch()

  -- Second-chance cleanup sweep: by now every ffmpeg process from this batch
  -- has long since exited, so any lingering lock from the first attempt
  -- should have cleared.
  for _, job in ipairs(batch_state.jobs) do
    if job.filename then
      local strayPath = batch_state.targetDir .. "\\_bulkshorts_concat_" .. job.filename .. ".txt"
      if file_exists(strayPath) then
        remove_file_retry(strayPath, 5, 150)
      end
    end
  end
end

-----------------------------------------------------------------------
-- HTTP server
-----------------------------------------------------------------------
local function parse_http_request(raw)
  local method = raw:match("^(%u+)%s+%S+%s+HTTP")
  local content_length = tonumber(raw:match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
  local header_end = raw:find("\r\n\r\n")
  local body = header_end and raw:sub(header_end + 4) or ""
  return method, body, content_length, header_end
end

local function build_response(status, body_str)
  local headers = {
    "HTTP/1.1 " .. status,
    "Content-Type: application/json",
    "Content-Length: " .. #body_str,
    "Access-Control-Allow-Origin: *",
    "Access-Control-Allow-Headers: Content-Type",
    "Connection: close",
    "", ""
  }
  return table.concat(headers, "\r\n") .. body_str
end

-- Loops until the full response has been handed to the socket, since a
-- non-blocking send() can return having written fewer bytes than given.
local function send_all(client, data)
  local total = #data
  local sent = 0
  local tries = 0
  while sent < total and tries < 200 do
    local n = client:send(data:sub(sent + 1))
    if n and n > 0 then
      sent = sent + n
    else
      tries = tries + 1
      sleep_ms(5)
    end
  end
  return sent >= total
end

local gui_path = (script_dir .. "gui.html"):gsub("\\", "/")
local function launch_gui()
  os.execute('start "" msedge --app="file:///' .. gui_path .. '" --window-size=800,920')
end

print("[BulkShorts] Starting server on 127.0.0.1:" .. PORT)

local ok_create, server = pcall(function()
  local s = assert(socket.create("inet", "stream", "tcp"))
  s:set_blocking(false)
  local ok_bind, bind_err = s:bind("127.0.0.1", PORT)
  if not ok_bind then error("bind failed: " .. tostring(bind_err)) end
  assert(s:listen())
  return s
end)

if not ok_create then
  local msg = tostring(server)
  if msg:find("bind failed") then
    print("[BulkShorts] A server is already running from a previous session. Reopening the window instead of starting a new one.")
    launch_gui()
  else
    print("[BulkShorts] FAILED TO START: " .. msg)
  end
  return
end

print("[BulkShorts] Listening.")
launch_gui()

local lastBgCheck = os.time()

while running do
  local client = server:accept()

  if os.time() - lastBgCheck >= 1 then
    lastBgCheck = os.time()
    pcall(check_batch_completion)
  end

  if client then
    client:set_blocking(false)

    local raw = ""
    local tries = 0
    while tries < 400 do
      local chunk = client:receive()
      if chunk then raw = raw .. chunk end
      local _, _, content_length, header_end = parse_http_request(raw)
      if header_end then
        local body_so_far = #raw - (header_end + 3)
        if not content_length or body_so_far >= content_length then break end
      end
      tries = tries + 1
      sleep_ms(5)
    end

    local method, body = parse_http_request(raw)

    if method == "OPTIONS" then
      send_all(client, build_response("200 OK", ""))
    else
      local reqData = {}
      if body and #body > 0 then reqData = json.decode(body) or {} end

      local funcName = reqData.func
      local handler = funcName and handlers[funcName]
      local result

      if not funcName then
        result = { error = "No 'func' field in request body" }
      elseif not handler then
        result = { error = "Unknown function: " .. tostring(funcName) }
      else
        local ok, res = pcall(handler, reqData)
        result = ok and res or { error = "Handler failed", detail = tostring(res), func = funcName }
      end

      send_all(client, build_response("200 OK", json.encode(result)))
    end

    sleep_ms(10) -- give the socket a moment before tearing down the connection
    client:close()
  else
    sleep_ms(15)
  end
end

server:close()
print("[BulkShorts] Server stopped cleanly. You can re-run the script now.")
