-- Thin launcher. Do not put real logic here (same pattern AutoSubs uses).
-- EDIT THIS PATH to wherever you put the BulkShortsGenerator folder:
local CORE_PATH = os.getenv("APPDATA") ..
    "\\Blackmagic Design\\DaVinci Resolve\\Support\\Fusion\\Scripts\\Utility\\BulkShortsGenerator\\BulkShorts.lua"

local f = io.open(CORE_PATH, "r")
if not f then
  print("[BulkShorts] Could not find core script at: " .. CORE_PATH)
  print("[BulkShorts] Edit CORE_PATH in this launcher file.")
  return
end
f:close()

dofile(CORE_PATH)
