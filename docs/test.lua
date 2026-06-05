-- Minimal test to find Tetris error
onion.log("test: start")

-- Test 1: basic display
onion.display_text("Tetris test", 10, 50, 2, {clear=true, color="black"})
onion.log("test: display ok")

-- Test 2: load qr module
local ok, qr = pcall(dofile, "/scripts_qr.lua")
if ok then
    onion.log("test: qr loaded ok")
else
    onion.log("test: qr fail:" .. tostring(qr):sub(1,30))
end

-- Test 3: math
math.randomseed(42)
local r = math.random(1, 7)
onion.log("test: math ok, r=" .. r)

-- Test 4: PIECES table (first piece only)
local PIECES = {
  { {0,0,0,0, 1,1,1,1, 0,0,0,0, 0,0,0,0},
    {0,0,1,0, 0,0,1,0, 0,0,1,0, 0,0,1,0} },
}
onion.log("test: pieces ok len=" .. #PIECES)

-- Test 5: buttons
local btn = onion.buttons()
onion.log("test: buttons ok")

onion.display_text("All tests passed!", 10, 90, 1, {clear=false, color="black"})
onion.log("test: DONE")
