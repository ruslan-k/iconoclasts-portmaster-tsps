-- Iconoclasts Chowdren FPS-target / max-FPS bypass port.
-- Target: pinned Linux x86-64 Chowdren build.
--
-- Legacy 32-bit behavior:
--   maxfps_disabled = 1
--   fps_target = CHOWDREN_FPS (default 30)
--   return from the native frame-rate limiter/setup routine
--
-- This is intentionally a semantic port rather than a byte-for-byte rewrite.
-- The 64-bit routine and both globals are resolved from instruction semantics
-- at runtime; no target data address is hardcoded.


local module_name = ...
local M = {}

local function prepare(options)
    options = options or {}
    local function configured_fps(explicit)
        if explicit ~= nil then
            assert(type(explicit) == "number", "fps_target must be numeric")
            assert(explicit == math.floor(explicit), "fps_target must be an integer")
            assert(explicit >= 1 and explicit <= 1000, "fps_target must be in [1, 1000]")
            return explicit
        end

        local text = os.getenv("CHOWDREN_FPS")
        if text == nil or text == "" then
            return 30
        end

        local value = tonumber(text)
        assert(value ~= nil, "CHOWDREN_FPS must be numeric")
        assert(value == math.floor(value),
               "CHOWDREN_FPS must be an integer")
        assert(value >= 1 and value <= 1000,
               "CHOWDREN_FPS must be in [1, 1000]")
        return value
    end

    local function exact_limiter_entry(ctx)
        local first = ctx:decode(0, 5, 2)
        if #first ~= 2 or
           first[1].mnemonic ~= "push" or
           first[2].mnemonic ~= "sub" then
            return false
        end

        local flag_insn = ctx:decode(5, 7, 1)
        if #flag_insn ~= 1 or
           flag_insn[1].mnemonic ~= "cmp" or
           not flag_insn[1].rip_relative or
           flag_insn[1].rip_target == nil then
            return false
        end

        local target_insn = ctx:decode(0x2a, 8, 1)
        if #target_insn ~= 1 or
           target_insn[1].mnemonic ~= "cvtsi2sd" or
           not target_insn[1].rip_relative or
           target_insn[1].rip_target == nil then
            return false
        end

        return true
    end

    local function rip_target(address, instruction_size, displacement_offset)
        local bytes = aa.read(address, instruction_size)
        assert(bytes ~= nil and #bytes == instruction_size,
               "failed reading RIP-relative instruction")
        local displacement = string.unpack("<i4", bytes, displacement_offset + 1)
        return address + instruction_size + displacement
    end

    local fps = configured_fps(options.fps_target)
    local mod = aa.patch("iconoclasts-fps-target")

    local limiter = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "53",
            "48 83 EC 20",
            "80 3D ?? ?? ?? ?? 00",
            "0F 84 ?? ?? ?? ??",
            "48 8B 3D ?? ?? ?? ??",
            "E8 ?? ?? ?? ??",
            "A8 48",
            "75 ??",
            "F2 0F 10 05 ?? ?? ?? ??",
            "F2 0F 2A 0D ?? ?? ?? ??",
        }, " "),
        matches = "one",
        validate = exact_limiter_entry,
    }

    -- CMP byte ptr [RIP+disp32],0 at limiter+5: displacement starts at +2.
    local maxfps_disabled = rip_target(limiter + 5, 7, 2)
    -- CVTSI2SD xmm1,dword ptr [RIP+disp32] at limiter+0x2a: displacement +4.
    local fps_target = rip_target(limiter + 0x2a, 8, 4)

    -- These are semantic sanity checks against the two instruction widths/types.
    assert(#aa.read(maxfps_disabled, 1) == 1,
           "resolved max-FPS flag is unreadable")
    assert(#aa.read(fps_target, 4) == 4,
           "resolved FPS target is unreadable")

    -- The legacy patch replaced the entire native routine. The detour is entered
    -- by JMP, so RET here returns directly to PumpSDLEvents' caller continuation.
    -- The two stores are repeated on every invocation, matching the old payload.
    local replacement = string.format([[
        mov byte ptr [0x%X], 1
        mov dword ptr [0x%X], 0x%X
        ret
    ]], maxfps_disabled, fps_target, fps)

    assert(mod:hook {
        name = "OverrideFrameRateLimiter",
        at = limiter,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = replacement,
    } == 1)

    print(string.format(
        "Iconoclasts FPS-target fix prepared: target=%d limiter=0x%X maxfps_disabled=0x%X fps_target=0x%X",
        fps,
        limiter,
        maxfps_disabled,
        fps_target))

    return mod
end

function M.install(options)
    local mod = prepare(options)
    assert(mod:install() == 1)
    return mod
end

if module_name ~= nil then
    return M
end

local config = aa.config {
    fps_target = 30,
}

return prepare {
    fps_target = config.fps_target,
}
