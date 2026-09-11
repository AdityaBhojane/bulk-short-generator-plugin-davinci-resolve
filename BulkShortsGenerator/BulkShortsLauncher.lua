local CORE_PATH = os.getenv("APPDATA") ..
    "\\Blackmagic Design\\DaVinci Resolve\\Support\\Fusion\\Scripts\\Utility\\BulkShortsGenerator\\BulkShorts.lua"
local f = io.open(CORE_PATH, "r")
if not f then
  print("[BulkShorts] Could not find core script at: " .. CORE_PATH)
  return
end
f:close()
dofile(CORE_PATH)