-- OnionDAO Tetris for OnionOS
-- Display: 264x176 landscape
-- Controls: left/right=move, up=rotate, down=soft drop, select=hard drop, cancel=pause

-- OnionOS stores scripts as /scripts_NAME.lua — use dofile instead of require
local ok, qr = pcall(dofile, "/scripts_qr.lua")
if not ok then qr = { render = function() onion.log("QR unavailable") end } end

-- ── Layout constants ──────────────────────────────────────────────────────────
local CELL      = 8          -- pixels per cell
local COLS      = 10
local ROWS      = 20
local BX        = 4          -- board left edge
local BY        = 4          -- board top edge
local HUD_X     = BX + COLS * CELL + 8   -- HUD left edge (x=92)

-- ── Tetromino definitions (pre-stored rotations, 4×4 flat, 1=filled) ─────────
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
local piece    = nil   -- {type, rot, x, y}
local nxt      = nil   -- next piece type index
local score    = 0
local level    = 1
local lines    = 0
local paused   = false
local over     = false
local tick_ms  = 1000
local elapsed  = 0
local dirty    = true
local POLL_MS  = 50

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
local function draw_cell(c, r, filled)
  local x = BX + (c-1)*CELL
  local y = BY + (r-1)*CELL
  if filled then
    onion.display_rect(x, y, CELL-1, CELL-1, {fill=true,  color="black"})
  else
    onion.display_rect(x, y, CELL-1, CELL-1, {fill=true,  color="white"})
  end
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

local function draw_hud()
  local x = HUD_X
  local O = {clear=false, color="black"}
  -- Score
  onion.display_text("SCORE",          x, 4,  O)
  onion.display_text(tostring(score),  x, 14, O)
  -- Level
  onion.display_text("LEVEL",          x, 30, O)
  onion.display_text(tostring(level),  x, 40, O)
  -- Lines
  onion.display_text("LINES",          x, 56, O)
  onion.display_text(tostring(lines),  x, 66, O)
  -- Next piece preview
  onion.display_text("NEXT",           x, 82, O)
  if nxt then
    local s = shape(nxt, 1)
    for i = 0, 15 do
      if s[i+1] == 1 then
        local pc = (i % 4)
        local pr = math.floor(i / 4)
        local px2 = x + pc*6
        local py2 = 94 + pr*6
        onion.display_rect(px2, py2, 5, 5, {fill=true, color="black"})
      end
    end
  end
  -- Controls hint
  onion.display_text("L/R:move", x, 136, O)
  onion.display_text("UP:rot",   x, 147, O)
  onion.display_text("DN:soft",  x, 158, O)
  onion.display_text("SEL:drop", x, 169, O)
end

local function full_redraw()
  onion.clear_display()
  -- Board border
  onion.display_rect(BX-2, BY-2, COLS*CELL+4, ROWS*CELL+4, {fill=false, color="black"})
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
  -- Divider between board and HUD
  onion.display_line(BX + COLS*CELL + 4, 0, BX + COLS*CELL + 4, 176, {color="black"})
end

local function draw_paused()
  onion.clear_display()
  onion.display_text("PAUSED",           90, 60,  {color="black", font="bold"})
  onion.display_text("CANCEL to resume", 60, 100, {color="black"})
end

-- ── Game over + QR ────────────────────────────────────────────────────────────
local function show_game_over()
  onion.clear_display()
  onion.display_text("GAME OVER",          50, 4,  {color="black", font="bold"})
  onion.display_text("Score: " .. score,   50, 28, {clear=false, color="black"})
  onion.display_text("Level: " .. level,   50, 40, {clear=false, color="black"})
  onion.display_text("Lines: " .. lines,   50, 52, {clear=false, color="black"})
  onion.display_text("Scan to submit:",    50, 68, {clear=false, color="black"})

  -- Build submission URL — includes hardware ID, Onion ID, wallet, and score
  local hw  = onion.hardware_id() or "000000000000"
  local oid = tostring(onion.onion_id() or 0)   -- Onion ID for oniondao.dev transfers
  local wlt = onion.wallet()      or ""
  local url = "https://onion-tetris.vercel.app/s"
            .. "?i="   .. hw
            .. "&oid=" .. oid
            .. "&sc="  .. tostring(score)
            .. "&l="   .. tostring(lines)
            .. "&lv="  .. tostring(level)
            .. "&w="   .. wlt

  -- Render QR (module_size=2 → fits on right side of display)
  qr.render(url, 140, 76, 2)

  -- Show Onion ID for manual prize lookup
  if oid ~= "0" then
    onion.display_text("Onion ID: " .. oid,      10, 155, {clear=false, color="black"})
  end
  onion.display_text("onion-tetris.vercel.app",  10, 165, {clear=false, color="black"})
end

-- ── Input ─────────────────────────────────────────────────────────────────────
local prev_btn = {}

local function handle_input(btn)
  if btn.cancel and not prev_btn.cancel then
    paused = not paused
    if paused then draw_paused() else dirty = true end
  end

  if paused then prev_btn = btn; return end

  if btn.left and not prev_btn.left then
    if can_place(piece.type, piece.rot, piece.x-1, piece.y) then
      draw_piece_cells(piece, false)
      piece.x = piece.x - 1
      draw_piece_cells(piece, true)
    end
  end

  if btn.right and not prev_btn.right then
    if can_place(piece.type, piece.rot, piece.x+1, piece.y) then
      draw_piece_cells(piece, false)
      piece.x = piece.x + 1
      draw_piece_cells(piece, true)
    end
  end

  if btn.up and not prev_btn.up then
    local new_rot = piece.rot % #PIECES[piece.type] + 1
    if can_place(piece.type, new_rot, piece.x, piece.y) then
      draw_piece_cells(piece, false)
      piece.rot = new_rot
      draw_piece_cells(piece, true)
    end
  end

  if btn.down and not prev_btn.down then
    if can_place(piece.type, piece.rot, piece.x, piece.y+1) then
      draw_piece_cells(piece, false)
      piece.y = piece.y + 1
      draw_piece_cells(piece, true)
    end
    elapsed = 0   -- reset gravity timer on soft drop
  end

  if btn.select and not prev_btn.select then
    -- Hard drop
    draw_piece_cells(piece, false)
    while can_place(piece.type, piece.rot, piece.x, piece.y+1) do
      piece.y = piece.y + 1
    end
    lock_piece()
    local cleared = clear_lines()
    if not over then spawn_piece() end
    dirty = true
  end

  prev_btn = btn
end

-- ── Gravity tick ──────────────────────────────────────────────────────────────
local function gravity_tick()
  if paused or over or not piece then return end
  if can_place(piece.type, piece.rot, piece.x, piece.y+1) then
    draw_piece_cells(piece, false)
    piece.y = piece.y + 1
    draw_piece_cells(piece, true)
  else
    lock_piece()
    local cleared = clear_lines()
    if not over then spawn_piece() end
    dirty = true
  end
end

-- ── Main ──────────────────────────────────────────────────────────────────────
math.randomseed(42)   -- deterministic seed (OnionOS may not have os.time)
board = new_board()
spawn_piece()
full_redraw()

while not over do
  local btn = onion.buttons()
  handle_input(btn)

  elapsed = elapsed + POLL_MS
  if elapsed >= tick_ms then
    elapsed = 0
    gravity_tick()
  end

  if dirty then
    full_redraw()
    dirty = false
  end

  onion.sleep(POLL_MS)
end

show_game_over()

-- Wait for any button press to exit
local done = false
while not done do
  local b = onion.buttons()
  if b.cancel or b.select then done = true end
  onion.sleep(100)
end
onion.release_display()
