-- OnionDAO Tetris for OnionOS
-- Display: 264x176 landscape
-- Controls: left/right=move, up=rotate, down=soft drop, select=hard drop, cancel=pause

local ok, qr = pcall(dofile, "/scripts_qr.lua")
if not ok then qr = { render = function() onion.log("QR unavailable") end } end

-- ── Layout constants ──────────────────────────────────────────────────────────
local CELL      = 8
local COLS      = 10
local ROWS      = 20
local BX        = 4
local BY        = 4
local HUD_X     = BX + COLS * CELL + 8   -- x=92

-- ── Tetromino definitions ─────────────────────────────────────────────────────
local PIECES = {
  -- I
  { {0,0,0,0, 1,1,1,1, 0,0,0,0, 0,0,0,0},
    {0,0,1,0, 0,0,1,0, 0,0,1,0, 0,0,1,0} },
  -- O
  { {0,1,1,0, 0,1,1,0, 0,0,0,0, 0,0,0,0} },
  -- T
  { {0,1,0,0, 1,1,1,0, 0,0,0,0, 0,0,0,0},
    {0,1,0,0, 0,1,1,0, 0,1,0,0, 0,0,0,0},
    {0,0,0,0, 1,1,1,0, 0,1,0,0, 0,0,0,0},
    {0,1,0,0, 1,1,0,0, 0,1,0,0, 0,0,0,0} },
  -- S
  { {0,1,1,0, 1,1,0,0, 0,0,0,0, 0,0,0,0},
    {1,0,0,0, 1,1,0,0, 0,1,0,0, 0,0,0,0} },
  -- Z
  { {1,1,0,0, 0,1,1,0, 0,0,0,0, 0,0,0,0},
    {0,1,0,0, 1,1,0,0, 1,0,0,0, 0,0,0,0} },
  -- J
  { {1,0,0,0, 1,1,1,0, 0,0,0,0, 0,0,0,0},
    {0,1,1,0, 0,1,0,0, 0,1,0,0, 0,0,0,0},
    {0,0,0,0, 1,1,1,0, 0,0,1,0, 0,0,0,0},
    {0,1,0,0, 0,1,0,0, 1,1,0,0, 0,0,0,0} },
  -- L
  { {0,0,1,0, 1,1,1,0, 0,0,0,0, 0,0,0,0},
    {0,1,0,0, 0,1,0,0, 0,1,1,0, 0,0,0,0},
    {0,0,0,0, 1,1,1,0, 1,0,0,0, 0,0,0,0},
    {1,1,0,0, 0,1,0,0, 0,1,0,0, 0,0,0,0} },
}

local SCORE_TABLE = {40, 100, 300, 1200}

-- ── Game state ────────────────────────────────────────────────────────────────
local board    = {}
local piece    = nil
local nxt      = nil
local score    = 0
local level    = 1
local lines    = 0
local paused   = false
local over     = false
local tick_ms  = 1000
local elapsed  = 0
local dirty    = true
local POLL_MS  = 50
local prev_btn = {}

-- ── Board helpers ─────────────────────────────────────────────────────────────
local function new_board()
  local b = {}
  for r = 1, ROWS do
    b[r] = {}
    for c = 1, COLS do b[r][c] = 0 end
  end
  return b
end

local function shape(t, r)
  return PIECES[t][ ((r-1) % #PIECES[t]) + 1 ]
end

local function can_place(t, rot, px, py)
  local s = shape(t, rot)
  for i = 0, 15 do
    if s[i+1] == 1 then
      local c = px + (i % 4)
      local r = py + math.floor(i / 4)
      if c < 1 or c > COLS or r > ROWS then return false end
      if r >= 1 and board[r][c] ~= 0 then return false end
    end
  end
  return true
end

local function lock_piece()
  local s = shape(piece.type, piece.rot)
  for i = 0, 15 do
    if s[i+1] == 1 then
      local c = piece.x + (i % 4)
      local r = piece.y + math.floor(i / 4)
      if r >= 1 and r <= ROWS then board[r][c] = piece.type end
    end
  end
end

local function clear_lines()
  local cleared = 0
  local r = ROWS
  while r >= 1 do
    local full = true
    for c = 1, COLS do
      if board[r][c] == 0 then full = false; break end
    end
    if full then
      table.remove(board, r)
      table.insert(board, 1, {0,0,0,0,0,0,0,0,0,0})
      cleared = cleared + 1
    else
      r = r - 1
    end
  end
  if cleared > 0 then
    score = score + (SCORE_TABLE[cleared] or 1200) * level
    lines = lines + cleared
    level = math.floor(lines / 10) + 1
    tick_ms = math.max(100, 1000 - (level - 1) * 100)
  end
  return cleared
end

local function spawn_piece()
  local t = nxt or math.random(1, #PIECES)
  nxt = math.random(1, #PIECES)
  local p = { type=t, rot=1, x=4, y=0 }
  if not can_place(p.type, p.rot, p.x, p.y) then
    over = true
  end
  piece = p
end

-- ── Rendering ─────────────────────────────────────────────────────────────────
-- Black background, white pieces/text
local function draw_cell(c, r, filled)
  local x = BX + (c-1)*CELL
  local y = BY + (r-1)*CELL
  local col = filled and "white" or "black"
  onion.display_rect(x, y, CELL-1, CELL-1, {fill=true, color=col})
end

local function draw_piece_cells(p, filled)
  local s = shape(p.type, p.rot)
  for i = 0, 15 do
    if s[i+1] == 1 then
      local c = p.x + (i % 4)
      local r = p.y + math.floor(i / 4)
      if r >= 1 and r <= ROWS then draw_cell(c, r, filled) end
    end
  end
end

-- y values are GFX baselines; FreeMono9pt7b ascent ~11px so first visible y=14
local function draw_hud()
  local x = HUD_X
  local O = {clear=false, color="white", background="black"}

  onion.display_text("SCORE",          x, 16,  O)
  onion.display_text(tostring(score),  x, 28,  O)

  onion.display_text("LEVEL",          x, 46,  O)
  onion.display_text(tostring(level),  x, 58,  O)

  onion.display_text("LINES",          x, 76,  O)
  onion.display_text(tostring(lines),  x, 88,  O)

  onion.display_text("NEXT",           x, 106, O)
  if nxt then
    local s = shape(nxt, 1)
    for i = 0, 15 do
      if s[i+1] == 1 then
        local pc = (i % 4)
        local pr = math.floor(i / 4)
        local px2 = x + pc*6
        local py2 = 118 + pr*6
        -- color="white" so preview is visible on black background
        onion.display_rect(px2, py2, 5, 5, {fill=true, color="white"})
      end
    end
  end

  onion.display_text("L/R:move",  x, 152, O)
  onion.display_text("UP:rotate", x, 164, O)
end

local function full_redraw()
  -- Black background
  onion.display_rect(0, 0, 264, 176, {fill=true, color="black"})
  -- Board border (white)
  onion.display_rect(BX-2, BY-2, COLS*CELL+4, ROWS*CELL+4, {fill=false, color="white"})
  -- Settled cells
  for r = 1, ROWS do
    for c = 1, COLS do
      if board[r][c] ~= 0 then draw_cell(c, r, true) end
    end
  end
  -- Active piece
  if piece then draw_piece_cells(piece, true) end
  -- HUD
  draw_hud()
  -- Divider
  onion.display_line(BX + COLS*CELL + 4, 0, BX + COLS*CELL + 4, 176, {color="white"})
  onion.flush()
end

local function draw_paused()
  onion.display_rect(0, 0, 264, 176, {fill=true, color="black"})
  onion.display_text("PAUSED",           90, 72,  {clear=false, color="white", background="black", font="bold"})
  onion.display_text("CANCEL to resume", 40, 100, {clear=false, color="white", background="black"})
  onion.flush()
end

-- ── Game over + QR ────────────────────────────────────────────────────────────
local function show_game_over()
  onion.display_rect(0, 0, 264, 176, {fill=true, color="black"})
  onion.display_text("GAME OVER",          50, 16, {clear=false, color="white", background="black", font="bold"})
  onion.display_text("Score: " .. score,   50, 34, {clear=false, color="white", background="black"})
  onion.display_text("Level: " .. level,   50, 48, {clear=false, color="white", background="black"})
  onion.display_text("Lines: " .. lines,   50, 62, {clear=false, color="white", background="black"})
  onion.display_text("Scan to submit:",    50, 78, {clear=false, color="white", background="black"})

  local hw  = onion.hardware_id() or "000000000000"
  local oid = tostring(onion.onion_id() or 0)
  local wlt = onion.wallet() or ""
  local url = "https://onion-tetris.vercel.app/s"
            .. "?i="   .. hw
            .. "&oid=" .. oid
            .. "&sc="  .. tostring(score)
            .. "&l="   .. tostring(lines)
            .. "&lv="  .. tostring(level)
            .. "&w="   .. wlt

  qr.render(url, 140, 76, 2)

  if oid ~= "0" then
    onion.display_text("Onion ID: " .. oid,      10, 155, {clear=false, color="white", background="black"})
  end
  onion.display_text("onion-tetris.vercel.app",  10, 168, {clear=false, color="white", background="black"})
  onion.flush()
end

-- ── Input ─────────────────────────────────────────────────────────────────────
local function handle_input(btn)
  if btn.cancel and not prev_btn.cancel then
    paused = not paused
    if paused then draw_paused() else dirty = true end
  end

  if paused then prev_btn = btn; return end

  if btn.left and not prev_btn.left then
    if can_place(piece.type, piece.rot, piece.x-1, piece.y) then
      piece.x = piece.x - 1
      dirty = true
    end
  end

  if btn.right and not prev_btn.right then
    if can_place(piece.type, piece.rot, piece.x+1, piece.y) then
      piece.x = piece.x + 1
      dirty = true
    end
  end

  if btn.up and not prev_btn.up then
    local new_rot = piece.rot % #PIECES[piece.type] + 1
    if can_place(piece.type, new_rot, piece.x, piece.y) then
      piece.rot = new_rot
      dirty = true
    end
  end

  if btn.down and not prev_btn.down then
    if can_place(piece.type, piece.rot, piece.x, piece.y+1) then
      piece.y = piece.y + 1
      dirty = true
    end
    elapsed = 0
  end

  if btn.select and not prev_btn.select then
    while can_place(piece.type, piece.rot, piece.x, piece.y+1) do
      piece.y = piece.y + 1
    end
    lock_piece()
    clear_lines()
    if not over then spawn_piece() end
    dirty = true
  end

  prev_btn = btn
end

-- ── Gravity tick ──────────────────────────────────────────────────────────────
local function gravity_tick()
  if paused or over or not piece then return end
  if can_place(piece.type, piece.rot, piece.x, piece.y+1) then
    piece.y = piece.y + 1
    dirty = true
  else
    lock_piece()
    clear_lines()
    if not over then spawn_piece() end
    dirty = true
  end
end

-- ── Main ──────────────────────────────────────────────────────────────────────
math.randomseed(42)
board = new_board()
spawn_piece()
full_redraw()
dirty = false  -- initial draw done; prevent extra refresh on first loop iteration

while not over do
  local btn = onion.buttons()
  handle_input(btn)

  elapsed = elapsed + POLL_MS
  if elapsed >= tick_ms then
    elapsed = 0
    gravity_tick()  -- sets dirty=true
  end

  if dirty then
    full_redraw()
    dirty = false
    elapsed = 0
    -- Snapshot button state after the refresh so held buttons don't
    -- double-trigger on the next iteration.
    prev_btn = onion.buttons()
  end

  onion.sleep(POLL_MS)
end

show_game_over()

local done = false
while not done do
  local b = onion.buttons()
  if b.cancel or b.select then done = true end
  onion.sleep(100)
end
onion.release_display()
