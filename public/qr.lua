-- Minimal QR Code encoder for OnionOS (Version 1-7, Error Correction L)
-- Renders directly to e-paper via onion.display_rect()
-- MIT License — adapted from lua-qrcode by Tobias Schrödel

local M = {}

-- ── GF(256) tables (generator polynomial 0x11D) ──────────────────────────────
local GF_EXP = {}
local GF_LOG = {}
do
  local x = 1
  for i = 0, 254 do
    GF_EXP[i] = x
    GF_LOG[x] = i
    x = x * 2
    if x > 255 then x = x ~ 0x11D end  -- XOR with primitive polynomial
  end
  GF_EXP[255] = GF_EXP[0]
end

local function gf_mul(a, b)
  if a == 0 or b == 0 then return 0 end
  return GF_EXP[(GF_LOG[a] + GF_LOG[b]) % 255]
end

-- ── Reed-Solomon error correction ────────────────────────────────────────────
local function rs_generator(n)
  local g = {1}
  for i = 0, n-1 do
    local ng = {}
    for j = 1, #g+1 do ng[j] = 0 end
    for j = 1, #g do
      ng[j]   = ng[j]   ~ gf_mul(g[j], GF_EXP[i])
      ng[j+1] = ng[j+1] ~ g[j]
    end
    g = ng
  end
  return g
end

local function rs_encode(data, n_ec)
  local gen = rs_generator(n_ec)
  local msg = {}
  for i = 1, #data do msg[i] = data[i] end
  for i = 1, n_ec do msg[#msg+1] = 0 end
  for i = 1, #data do
    local coef = msg[i]
    if coef ~= 0 then
      for j = 1, #gen do
        msg[i+j-1] = msg[i+j-1] ~ gf_mul(coef, gen[j])
      end
    end
  end
  local ec = {}
  for i = #data+1, #msg do ec[#ec+1] = msg[i] end
  return ec
end

-- ── Version / capacity tables (EC level L) ───────────────────────────────────
-- {version, total_codewords, ec_codewords_per_block, blocks, data_codewords}
local VER_L = {
  {1,  26,  7, 1, 19},
  {2,  44, 10, 1, 34},
  {3,  70, 15, 1, 55},
  {4, 100, 20, 1, 80},
  {5, 134, 26, 1,108},
  {6, 172, 36, 1,136},
  {7, 196, 40, 1,156},
}

local function pick_version(byte_len)
  -- byte mode: 4 bits mode + 8 bits length + 8*len bits data + 4 bits terminator
  local needed = math.ceil((4 + 8 + byte_len*8 + 4) / 8)
  for _, v in ipairs(VER_L) do
    if v[5] >= needed then return v end
  end
  error("String too long for QR Version 7")
end

-- ── Data encoding (byte mode) ────────────────────────────────────────────────
local function encode_data(str, cap)
  local bits = {}
  local function push(val, n)
    for i = n-1, 0, -1 do
      bits[#bits+1] = (val >> i) & 1
    end
  end
  push(0x4, 4)          -- mode indicator: byte
  push(#str, 8)         -- character count
  for i = 1, #str do
    push(str:byte(i), 8)
  end
  -- Terminator
  for i = 1, math.min(4, cap*8 - #bits) do bits[#bits+1] = 0 end
  -- Pad to byte boundary
  while #bits % 8 ~= 0 do bits[#bits+1] = 0 end
  -- Pad codewords
  local pad = {0xEC, 0x11}
  local pi = 1
  while #bits < cap*8 do
    push(pad[pi], 8)
    pi = pi % 2 + 1
  end
  -- Pack to bytes
  local bytes = {}
  for i = 1, #bits, 8 do
    local b = 0
    for j = 0, 7 do b = b*2 + (bits[i+j] or 0) end
    bytes[#bytes+1] = b
  end
  return bytes
end

-- ── Matrix helpers ────────────────────────────────────────────────────────────
local function new_matrix(size)
  local m = {}
  for r = 1, size do
    m[r] = {}
    for c = 1, size do m[r][c] = -1 end  -- -1 = unset
  end
  return m
end

local function place(m, r, c, v)
  if r >= 1 and r <= #m and c >= 1 and c <= #m then m[r][c] = v end
end

local function finder(m, tr, tc)
  for dr = 0, 6 do
    for dc = 0, 6 do
      local v = 0
      if dr == 0 or dr == 6 or dc == 0 or dc == 6 then v = 1
      elseif dr >= 2 and dr <= 4 and dc >= 2 and dc <= 4 then v = 1 end
      place(m, tr+dr, tc+dc, v)
    end
  end
  -- Separator (white border)
  for i = 0, 7 do
    place(m, tr+7,  tc+i,  0)
    place(m, tr+i,  tc+7,  0)
    place(m, tr-1,  tc+i,  0)
    place(m, tr+i,  tc-1,  0)
  end
end

local function timing(m, size)
  for i = 8, size-9 do
    local v = (i % 2 == 0) and 1 or 0
    place(m, 7, i+1, v)
    place(m, i+1, 7, v)
  end
end

local function alignment(m, size)
  -- Alignment pattern center positions for versions 2+
  local pos = {
    [2]={6,18}, [3]={6,22}, [4]={6,26}, [5]={6,30},
    [6]={6,34}, [7]={6,22,38}
  }
  local ver = (size - 17) // 4
  local pts = pos[ver]
  if not pts then return end
  for _, ar in ipairs(pts) do
    for _, ac in ipairs(pts) do
      -- Skip if overlaps finder patterns
      if not ((ar <= 8 and ac <= 8) or (ar <= 8 and ac >= size-7) or
              (ar >= size-7 and ac <= 8)) then
        for dr = -2, 2 do
          for dc = -2, 2 do
            local v = 0
            if math.abs(dr) == 2 or math.abs(dc) == 2 or (dr == 0 and dc == 0) then v = 1 end
            place(m, ar+dr, ac+dc, v)
          end
        end
      end
    end
  end
end

-- Format info (EC level L, mask pattern 0)
-- Precomputed for EC=L (01) and masks 0-7
local FORMAT_BITS = {
  [0]=0x77C4, [1]=0x72F3, [2]=0x7DAA, [3]=0x789D,
  [4]=0x662F, [5]=0x6318, [6]=0x6C41, [7]=0x6976,
}

local function format_info(m, size, mask)
  local fb = FORMAT_BITS[mask]
  local bits = {}
  for i = 14, 0, -1 do bits[15-i] = (fb >> i) & 1 end

  -- Place around top-left finder
  local bi = 1
  for i = 1, 6 do place(m, 9, i,      bits[bi]); bi=bi+1 end
  place(m, 9, 8, bits[bi]); bi=bi+1
  place(m, 8, 9, bits[bi]); bi=bi+1
  for i = 7, 1, -1 do place(m, i, 9,  bits[bi]); bi=bi+1 end

  -- Place around top-right and bottom-left finders
  bi = 1
  for i = size, size-6, -1 do place(m, 9, i, bits[bi]); bi=bi+1 end
  for i = size-7, size, 1 do
    if i ~= size-7 then place(m, i+1-size+size-7, 9, bits[bi]); bi=bi+1 end
  end
  bi = 8
  for i = size-6, size do place(m, i, 9, bits[bi]); bi=bi+1 end
end

-- ── Data placement (zigzag) ───────────────────────────────────────────────────
local function place_data(m, data_bits, size)
  local di = 1
  local col = size
  while col >= 1 do
    if col == 7 then col = col - 1 end  -- skip vertical timing column
    local up = true
    for i = 0, size-1 do
      local r = up and (size - i) or (i + 1)
      for dc = 0, 1 do
        local c = col - dc
        if c >= 1 and m[r][c] == -1 then
          m[r][c] = data_bits[di] or 0
          di = di + 1
        end
      end
    end
    col = col - 2
    up = not up
  end
end

-- ── Masking ───────────────────────────────────────────────────────────────────
local MASK_FN = {
  [0] = function(r,c) return (r+c) % 2 == 0 end,
  [1] = function(r,c) return r % 2 == 0 end,
  [2] = function(r,c) return c % 3 == 0 end,
  [3] = function(r,c) return (r+c) % 3 == 0 end,
  [4] = function(r,c) return (math.floor(r/2)+math.floor(c/3)) % 2 == 0 end,
  [5] = function(r,c) return (r*c)%2+(r*c)%3 == 0 end,
  [6] = function(r,c) return ((r*c)%2+(r*c)%3)%2 == 0 end,
  [7] = function(r,c) return ((r+c)%2+(r*c)%3)%2 == 0 end,
}

local function apply_mask(m, mask_id)
  local fn = MASK_FN[mask_id]
  local size = #m
  for r = 1, size do
    for c = 1, size do
      if m[r][c] ~= -1 then
        -- Only mask data modules (not function patterns)
        -- We'll use a copy for the final matrix
      end
    end
  end
end

local function penalty(m)
  local size = #m
  local p = 0
  -- Rule 1: 5+ in a row
  for r = 1, size do
    local run, cur = 0, -1
    for c = 1, size do
      local v = m[r][c]
      if v == cur then run=run+1 else run=1; cur=v end
      if run == 5 then p=p+3 elseif run > 5 then p=p+1 end
    end
  end
  for c = 1, size do
    local run, cur = 0, -1
    for r = 1, size do
      local v = m[r][c]
      if v == cur then run=run+1 else run=1; cur=v end
      if run == 5 then p=p+3 elseif run > 5 then p=p+1 end
    end
  end
  return p
end

-- ── Build full QR matrix ──────────────────────────────────────────────────────
local function build_qr(url)
  local ver_info = pick_version(#url)
  local ver   = ver_info[1]
  local ec_cw = ver_info[3]
  local dcap  = ver_info[5]
  local size  = ver * 4 + 17

  -- Encode data
  local data_bytes = encode_data(url, dcap)
  local ec_bytes   = rs_encode(data_bytes, ec_cw)

  -- Interleave (single block for these versions)
  local all_bytes = {}
  for _, b in ipairs(data_bytes) do all_bytes[#all_bytes+1] = b end
  for _, b in ipairs(ec_bytes)   do all_bytes[#all_bytes+1] = b end

  -- Bits
  local data_bits = {}
  for _, b in ipairs(all_bytes) do
    for i = 7, 0, -1 do data_bits[#data_bits+1] = (b >> i) & 1 end
  end
  -- Remainder bits
  local rem = {0,7,7,7,7,7,0}
  for i = 1, (rem[ver] or 0) do data_bits[#data_bits+1] = 0 end

  -- Build template matrix (function patterns, no data)
  local tmpl = new_matrix(size)
  finder(tmpl, 1, 1)
  finder(tmpl, 1, size-7)
  finder(tmpl, size-7, 1)
  timing(tmpl, size)
  alignment(tmpl, size)
  -- Dark module
  place(tmpl, size-7, 9, 1)
  -- Reserve format areas (set to 0 temporarily)
  format_info(tmpl, size, 0)

  -- Try mask 0 (simplest — good enough for most URLs)
  local best_mask = 0
  local best_pen  = math.huge
  for mask_id = 0, 3 do   -- try first 4 masks for speed
    local m = {}
    for r = 1, size do
      m[r] = {}
      for c = 1, size do m[r][c] = tmpl[r][c] end
    end
    place_data(m, data_bits, size)
    -- Apply mask to data modules
    local fn = MASK_FN[mask_id]
    for r = 1, size do
      for c = 1, size do
        if tmpl[r][c] == -1 then   -- was unset = data module
          if fn(r-1, c-1) then m[r][c] = 1 - m[r][c] end
        end
      end
    end
    format_info(m, size, mask_id)
    local p = penalty(m)
    if p < best_pen then best_pen=p; best_mask=mask_id end
  end

  -- Build final matrix with best mask
  local final = {}
  for r = 1, size do
    final[r] = {}
    for c = 1, size do final[r][c] = tmpl[r][c] end
  end
  place_data(final, data_bits, size)
  local fn = MASK_FN[best_mask]
  for r = 1, size do
    for c = 1, size do
      if tmpl[r][c] == -1 then
        if fn(r-1, c-1) then final[r][c] = 1 - final[r][c] end
      end
    end
  end
  format_info(final, size, best_mask)

  return final
end

-- ── Public API ────────────────────────────────────────────────────────────────
function M.render(url, x, y, module_size)
  module_size = module_size or 2
  local ok, result = pcall(build_qr, url)
  if not ok then
    onion.log("QR error: " .. tostring(result))
    -- Fallback: show URL as text
    onion.display_text(url:sub(1,30), x, y, 1, {color="black"})
    return
  end
  local matrix = result
  local sz = #matrix
  -- Quiet zone: 4 modules of white (already white from clear_display)
  local qz = module_size * 2   -- 2-module quiet zone (compact)
  for r = 1, sz do
    for c = 1, sz do
      if matrix[r][c] == 1 then
        onion.display_rect(
          x + qz + (c-1)*module_size,
          y + qz + (r-1)*module_size,
          module_size, module_size,
          {fill=true, color="black"}
        )
      end
    end
  end
end

return M
