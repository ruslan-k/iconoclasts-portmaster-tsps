-- Iconoclasts three-way text accessibility scaling using aa.ffi and
-- Chowdren generated-event provenance.
-- Target: pinned Linux x86-64 Chowdren build.
-- SHA-256: 82fa486fe0912994a76d25873835aebc258ebc40c5b8fc9a847a79c7246ea12f
--
-- Policy:
--   Panel2-associated / nonnegative binding => dialogue scale (default 1.25x)
--   negative binding + craft-tutorial producer context => reflow + tutorial scale
--                                                     (default 1.25x)
--   all other negative-binding text => other scale (default 1.15x)
--
-- Dialogue Panel2 geometry correction is part of this same patch because it is
-- required by the dialogue scaling policy; it is not an independently toggleable
-- feature.
--
-- The pinned tutorial is width-limited at its original explicit line breaks.
-- For the three verified tutorial body controllers, this variant rewrites only
-- body {new} separators through the target libstdc++ std::string API, wrapping
-- at a conservative visible-glyph budget before applying the larger scale.
--
-- The generic Collide_92_95 renderer is shared. CRAFT semantic ownership is
-- recovered from Chowdren's compiled Fusion/MMF2 event hierarchy: controllers
-- constructed synchronously below Generated_CraftTweaksTutorialSequence inherit
-- craft-tutorial context. The CRAFT menu wrapper is tracked too for provenance,
-- but menu text follows the ordinary 1.15x policy.


local module_name = ...
local M = {}

local function prepare(options)
    options = options or {}
    local ffi = aa.ffi

    local function configured_scale(env_name, default, explicit)
        local text
        if explicit ~= nil then
            assert(type(explicit) == "number", env_name .. " option must be numeric")
            text = tostring(explicit)
        else
            text = os.getenv(env_name) or tostring(default)
        end
        local value = tonumber(text)

        assert(value ~= nil, env_name .. " must be numeric")
        assert(value == value and value ~= math.huge and value ~= -math.huge,
               env_name .. " must be finite")
        assert(value >= 0.5 and value <= 4.0,
               env_name .. " must be between 0.5 and 4.0")

        return value
    end

    local function exact_movsd_store(ctx)
        local insn = ctx:decode(0, 16, 1)
        return #insn == 1 and
               insn[1].mnemonic == "movsd" and
               insn[1].size == 8
    end

    local function exact_push(ctx)
        local insn = ctx:decode(0, 8, 1)
        return #insn == 1 and insn[1].mnemonic == "push"
    end

    local function exact_call(ctx)
        local insn = ctx:decode(0, 8, 1)
        return #insn == 1 and insn[1].mnemonic == "call"
    end

    local function exact_bytes(address, hex)
        local expected = {}
        for byte in hex:gmatch("%x%x") do
            expected[#expected + 1] = string.char(tonumber(byte, 16))
        end
        expected = table.concat(expected)
        local actual = aa.read(address, #expected)
        assert(actual == expected,
               string.format("dialogue layout signature moved at 0x%X", address))
    end

    local DialogueState = ffi.struct("IconoclastsAccessibleTextStateReflow", {
        text_data = ffi.void_ptr(0x000),
        binding = ffi.f64(0x260),
        controller_scale = ffi.f64(0x2b8),
    })

    local Controller = ffi.struct("IconoclastsAccessibleTextController", {
        state = ffi.ptr(0x30, DialogueState),
    })

    local StatePointerSlot = ffi.struct("TextAccessibilityStatePointerSlot", {
        value = ffi.ptr(0x00, DialogueState),
    })

    local ControllerPointerSlot = ffi.struct("TextAccessibilityControllerPointerSlot", {
        value = ffi.ptr(0x00, Controller),
    })

    local dialogue_scale = configured_scale("ICONOCLASTS_DIALOGUE_SCALE", 1.25, options.dialogue_scale)
    local tutorial_scale = configured_scale("ICONOCLASTS_TUTORIAL_SCALE", 1.25, options.tutorial_scale)
    local tutorial_wrap_columns = options.tutorial_wrap_columns or tonumber(os.getenv("ICONOCLASTS_TUTORIAL_WRAP_COLUMNS") or "50")
    assert(tutorial_wrap_columns ~= nil and tutorial_wrap_columns >= 32 and tutorial_wrap_columns <= 80,
           "ICONOCLASTS_TUTORIAL_WRAP_COLUMNS must be in [32, 80]")
    local other_scale = configured_scale("ICONOCLASTS_OTHER_TEXT_SCALE", 1.15, options.other_scale)

    local mod = aa.patch("iconoclasts-text-accessibility-three-way-reflow")


    -- Use the target's own old-ABI libstdc++ string assignment path. This keeps
    -- COW allocation/refcount/destruction semantics inside libstdc++ instead of
    -- manufacturing its private _Rep header from Lua.
    local libstdcpp = ffi.library("libstdc++.so.6")
    local std_string_assign = libstdcpp:cfunc("_ZNSs6assignEPKcm", {
        abi = "sysv64",
        returns = ffi.void_ptr,
        args = { ffi.void_ptr, ffi.cstring, ffi.u64 },
    })

    -- Shared +0x2b8 raw-scale writers. These are generation invalidation points;
    -- actual accessibility scaling happens once at the glyph/layout boundary.
    local default_scale_site = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "F2 0F 11 8A B8 02 00 00",
            "48 C7 82 30 02 00 00 00 00 00 00",
            "F2 0F 11 A2 C0 02 00 00",
        }, " "),
        matches = "one",
        validate = exact_movsd_store,
    }

    local size_parser_a_site = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "F2 0F 11 80 B8 02 00 00",
            "E8 ?? ?? ?? ??",
            "48 8B 44 24 20",
            "48 8D 78 E8",
        }, " "),
        matches = "one",
        validate = exact_movsd_store,
    }

    local size_parser_b_site = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "F2 0F 11 80 B8 02 00 00",
            "E9 ?? ?? ?? ??",
            "0F 1F 44 00 00",
            "4C 89 EF",
        }, " "),
        matches = "one",
        validate = exact_movsd_store,
    }

    local glyph_tick_a = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "41 57 41 56 41 55 49 89 FD",
            "41 54 55 48 89 F5 53",
            "48 83 EC 48",
            "48 8B 46 30",
            "48 8B 97 70 1A 00 00",
        }, " "),
        matches = "one",
        validate = exact_push,
    }

    local glyph_tick_b = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "41 57 41 56 49 89 FE",
            "41 55 41 54 55 48 89 F5 53",
            "48 83 EC 48",
            "48 8B 46 30",
            "48 8B 97 70 1A 00 00",
        }, " "),
        matches = "one",
        validate = exact_push,
    }

    local panel_layout_a = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "41 57 41 56 41 55 41 54 55",
            "48 89 FD 53 48 89 F3 48 83 EC 28",
            "44 8B 25 35 AE E6 00",
            "8B 87 80 10 00 00",
            "48 8B B7 88 10 00 00",
        }, " "),
        matches = "one",
    }

    local panel_layout_b = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "41 57 41 56 41 55 41 54 55",
            "48 89 FD 53 48 89 F3 48 83 EC 28",
            "44 8B 25 25 9A 78 00",
            "8B 87 80 10 00 00",
            "48 8B B7 88 10 00 00",
        }, " "),
        matches = "one",
    }

    -- Both mirrored layout wrappers position Panel2 before invoking the sizing
    -- helper. The SetObjectPositionDirect call is at the same +0xE43 offset from
    -- the verified SizeDialoguePanel base in both families.
    local panel_position_calls = {
        panel_layout_a + 0xE43,
        panel_layout_b + 0xE43,
    }
    exact_bytes(panel_position_calls[1], "E8 D8 25 F9 FF")
    exact_bytes(panel_position_calls[2], "E8 C8 11 8B FF")

    local dialogue_accessibility_delta_slot = mod:alloc {
        size = 8, permissions = "rw", symbol = "DialogueAccessibilityDelta",
    }
    aa.write(dialogue_accessibility_delta_slot,
             string.pack("<d", math.max(dialogue_scale - 1.0, 0.0)))

    local dialogue_line_coefficients = mod:alloc {
        size = 28, permissions = "rw", symbol = "DialogueLineCoefficients",
    }
    aa.write(dialogue_line_coefficients, string.pack(
        "<I4I4I4I4I4I4I4", 28, 18, 20, 6, 52, 20, 20))

    -- The stock subtype-5 dialogue pointer is projected toward its target and
    -- then clamped to Panel2. Accessibility can make Panel2 large enough to
    -- engulf that projected point, at which point the stock clamp deliberately
    -- leaves the pointer inside the box. Correct only that swallowed case.
    local dialogue_pointer_clamp = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "55 48 89 F5 53 48 89 FB 48 83 EC 18",
            "48 8B 87 88 10 00 00",
            "F2 0F 10 4E 10",
            "8B 50 08 85 D2",
            "0F 85 ?? ?? ?? ??",
        }, " "),
        matches = "one",
        validate = exact_push,
    }

    -- Pinned CreateCollide_92_95. Constructor-time context is copied to a durable
    -- per-controller/state mapping at the verified tail boundary.
    local collide_ctor = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "41 54 41 89 F4 55 89 FD 53 48 83 EC 10",
            "E8 ?? ?? ?? ??",
            "48 85 C0 48 89 C3",
            "0F 84 ?? ?? ?? ??",
            "89 EE 48 89 C7",
            "B9 58 00 00 00",
            "44 89 E2",
            "E8 ?? ?? ?? ??",
            "48 8B 7B 30",
            "48 C7 03 B0 6F F3 00",
        }, " "),
        matches = "one",
        validate = exact_push,
    }

    local collide_ctor_tail = collide_ctor + 0x324

    -- Top-level generated CRAFT wrapper CALLs in Generated_PauseMenuEventDispatcher.
    local craft_menu_dispatch_call = mod:scan {
        module = "Chowdren",
        pattern = "E8 8C 34 FF FF E9 E5 F8 FF FF 0F 1F 80 00 00 00",
        matches = "one",
        validate = exact_call,
    }

    local craft_tutorial_dispatch_call = mod:scan {
        module = "Chowdren",
        pattern = "E8 1E 26 FE FF E9 89 F8 FF FF 66 0F 1F 84 00 00",
        matches = "one",
        validate = exact_call,
    }

    local current_state_address = mod:alloc {
        size = 8,
        permissions = "rw",
        near = default_scale_site,
        symbol = "TextAccessibilityCurrentState",
    }

    local last_state_address = mod:alloc {
        size = 8,
        permissions = "rw",
        near = default_scale_site,
        symbol = "TextAccessibilityLastState",
    }

    local current_controller_address = mod:alloc {
        size = 8,
        permissions = "rw",
        near = glyph_tick_a,
        symbol = "TextAccessibilityCurrentController",
    }

    local ctor_controller_address = mod:alloc {
        size = 8,
        permissions = "rw",
        near = collide_ctor,
        symbol = "TextAccessibilityCtorController",
    }

    local current_state_slot = StatePointerSlot(current_state_address)
    local last_state_slot = StatePointerSlot(last_state_address)
    local current_controller_slot = ControllerPointerSlot(current_controller_address)
    local ctor_controller_slot = ControllerPointerSlot(ctor_controller_address)

    current_state_slot.value = nil
    last_state_slot.value = nil
    current_controller_slot.value = nil
    ctor_controller_slot.value = nil

    -- Generation bookkeeping and semantic provenance.
    local applied_scale = {}
    local reflowed_state = {}
    local tutorial_reflow_ok = {}
    local context_by_controller = {}
    local context_by_state = {}

    local context_stack = {}
    local current_context = "none"

    local function push_context(value)
        context_stack[#context_stack + 1] = current_context
        current_context = value
    end

    local function pop_context()
        local previous = context_stack[#context_stack]
        assert(previous ~= nil, "text accessibility context stack underflow")
        context_stack[#context_stack] = nil
        current_context = previous
    end

    mod:lua_method {
        name = "BeginCraftMenuTextContext",
        near = craft_menu_dispatch_call,
        fn = function()
            push_context("craft-menu")
        end,
    }

    mod:lua_method {
        name = "BeginCraftTutorialTextContext",
        near = craft_tutorial_dispatch_call,
        fn = function()
            push_context("craft-tutorial")
        end,
    }

    mod:lua_method {
        name = "EndCraftTextContext",
        near = craft_menu_dispatch_call,
        fn = pop_context,
    }

    mod:lua_method {
        name = "RememberAccessibleTextContext",
        near = collide_ctor_tail,
        fn = function()
            local controller = ctor_controller_slot.value
            if controller == nil then
                return
            end

            local state = controller.state
            if state == nil then
                return
            end

            context_by_controller[ffi.address(controller)] = current_context
            context_by_state[ffi.address(state)] = current_context
        end,
    }

    mod:lua_method {
        name = "InvalidateAccessibleTextScale",
        near = default_scale_site,
        fn = function()
            local state = current_state_slot.value
            if state ~= nil then
                local state_address = ffi.address(state)
                applied_scale[state_address] = nil
                reflowed_state[state_address] = nil
                tutorial_reflow_ok[state_address] = nil
            end
        end,
    }


    local function read_source_string(state)
        local pointer = state.text_data
        assert(pointer ~= nil, "tutorial reflow received null source string")

        local data_address = ffi.address(pointer)
        assert(data_address >= 0x18, "tutorial source pointer is below COW header")

        local length_bytes = aa.read(data_address - 0x18, 8)
        assert(length_bytes ~= nil and #length_bytes == 8,
               "tutorial reflow failed reading source length")

        local length = string.unpack("<I8", length_bytes)
        assert(length <= 64 * 1024, "tutorial source length is implausible")

        if length == 0 then
            return ""
        end

        local raw = aa.read(data_address, length)
        assert(raw ~= nil and #raw == length,
               "tutorial reflow failed reading source bytes")
        return raw
    end

    local function split_pipe_tokens(raw)
        local tokens = {}
        local start = 1
        while true do
            local stop = raw:find("|", start, true)
            if stop == nil then
                tokens[#tokens + 1] = raw:sub(start)
                break
            end
            tokens[#tokens + 1] = raw:sub(start, stop - 1)
            start = stop + 1
        end
        return tokens
    end

    local function visible_token_width(token)
        local number = tonumber(token)
        if number == nil or number == 1 or number == 2 then
            return 0
        end
        return 1
    end

    local function reflow_tutorial_raw(raw, max_columns)
        local tokens = split_pipe_tokens(raw)
        local lock_index = nil
        for i, token in ipairs(tokens) do
            if token == "{lock}" then
                lock_index = i
                break
            end
        end
        assert(lock_index ~= nil, "tutorial source is missing {lock}")

        local prefix = {}
        for i = 1, lock_index do
            prefix[#prefix + 1] = tokens[i]
        end

        -- Turn existing body line breaks back into word separators, then greedily
        -- insert new {new} tokens at spaces. Formatting commands stay attached to
        -- their surrounding glyphs and are therefore preserved byte-for-byte.
        local words = {}
        local current = {}
        local current_width = 0

        local function flush_word()
            if #current == 0 then
                return
            end
            words[#words + 1] = {
                tokens = current,
                width = current_width,
            }
            current = {}
            current_width = 0
        end

        for i = lock_index + 1, #tokens do
            local token = tokens[i]
            if token == "2" or token == "{new}" then
                flush_word()
            else
                current[#current + 1] = token
                current_width = current_width + visible_token_width(token)
            end
        end
        flush_word()

        assert(#words > 0, "tutorial source body contains no words")

        local tail = {}
        local line_width = 0
        for i, word in ipairs(words) do
            local separator = nil
            if i > 1 then
                if line_width > 0 and line_width + 1 + word.width > max_columns then
                    separator = "{new}"
                    line_width = 0
                else
                    separator = "2"
                end
                tail[#tail + 1] = separator
            end

            for _, token in ipairs(word.tokens) do
                tail[#tail + 1] = token
            end

            if separator == "{new}" or line_width == 0 then
                line_width = word.width
            else
                line_width = line_width + 1 + word.width
            end
        end

        local out = table.concat(prefix, "|") .. "|" .. table.concat(tail, "|")
        return out
    end

    local function controller_context(controller, state)
        return
            context_by_state[ffi.address(state)] or
            context_by_controller[ffi.address(controller)] or
            "none"
    end

    local function is_verified_tutorial_body_binding(binding)
        return binding == -551 or binding == -552 or binding == -553
    end

    local function prepare_tutorial_reflow(controller, state)
        local state_address = ffi.address(state)
        if reflowed_state[state_address] then
            return tutorial_reflow_ok[state_address] == true
        end

        reflowed_state[state_address] = true
        tutorial_reflow_ok[state_address] = false

        if controller_context(controller, state) ~= "craft-tutorial" then
            return false
        end

        if not is_verified_tutorial_body_binding(state.binding) then
            -- The tutorial title (-550) has ample width and needs no body reflow.
            if state.binding == -550 then
                tutorial_reflow_ok[state_address] = true
                return true
            end
            return false
        end

        local raw = read_source_string(state)
        local rewritten = reflow_tutorial_raw(raw, tutorial_wrap_columns)
        local result = std_string_assign(
            ffi.cast(ffi.void_ptr, state_address),
            rewritten,
            #rewritten)
        assert(result ~= nil, "std::string::assign failed during tutorial reflow")

        tutorial_reflow_ok[state_address] = true
        print(string.format(
            "Iconoclasts tutorial reflow: binding=%.0f columns=%d old_bytes=%d new_bytes=%d",
            state.binding,
            tutorial_wrap_columns,
            #raw,
            #rewritten))
        return true
    end

    local function choose_scale(controller, state)
        if state.binding >= 0 then
            return dialogue_scale, "dialogue"
        end

        local context = controller_context(controller, state)

        if context == "craft-tutorial" then
            if tutorial_reflow_ok[ffi.address(state)] then
                return tutorial_scale, "craft-tutorial-reflowed"
            end
            return math.min(tutorial_scale, 1.0), "craft-tutorial-safe-fallback"
        end

        -- craft-menu intentionally follows the ordinary unrelated-text scale.
        return other_scale, context == "craft-menu" and "craft-menu" or "other"
    end

    mod:lua_method {
        name = "ApplyAccessibleTextScale",
        near = glyph_tick_a,
        fn = function()
            local controller = current_controller_slot.value
            assert(controller ~= nil, "text accessibility received null controller")

            local state = controller.state
            assert(state ~= nil, "text accessibility received null controller state")

            local state_address = ffi.address(state)
            if applied_scale[state_address] ~= nil then
                return
            end

            local raw = state.controller_scale
            assert(raw == raw and raw ~= math.huge and raw ~= -math.huge,
                   "text controller scale is not finite")

            prepare_tutorial_reflow(controller, state)
            local multiplier, class = choose_scale(controller, state)

            -- Dialogue {size...} is an authored absolute scale relative to the
            -- normal 1.0 baseline. Accessibility should raise that baseline, not
            -- multiply the authored departure from it. Multiplication makes
            -- {size2.00} become 3.50 at dialogue=1.75 and breaks the game's
            -- glyph/panel geometry. Add the accessibility delta instead:
            --   raw 1.0 -> dialogue_scale
            --   raw 2.0 -> 2.0 + (dialogue_scale - 1.0)
            -- This preserves the authored {size} delta while accessibility
            -- raises only the normal dialogue baseline.
            local scaled
            if class == "dialogue" then
                scaled = raw + (multiplier - 1.0)
            else
                scaled = raw * multiplier
            end

            assert(scaled == scaled and scaled ~= math.huge and scaled ~= -math.huge,
                   "scaled text controller value is not finite")

            state.controller_scale = scaled
            applied_scale[state_address] = {
                value = scaled,
                class = class,
                multiplier = multiplier,
            }
        end,
    }

    -- Track generated CRAFT event ownership around the original native CALLs.
    assert(mod:hook {
        name = "CraftMenuTextContext",
        at = craft_menu_dispatch_call,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = [[
            @lua BeginCraftMenuTextContext
            @original
            @lua EndCraftTextContext
            @return
        ]],
    } == 1)

    assert(mod:hook {
        name = "CraftTutorialTextContext",
        at = craft_tutorial_dispatch_call,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = [[
            @lua BeginCraftTutorialTextContext
            @original
            @lua EndCraftTextContext
            @return
        ]],
    } == 2)

    -- At this verified constructor tail RBX is the completed Collide_92_95*.
    assert(mod:hook {
        name = "RememberAccessibleTextContext",
        at = collide_ctor_tail,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = [[
            mov qword ptr [%TextAccessibilityCtorController], rbx
            @lua RememberAccessibleTextContext
            @original
            @return
        ]],
    } == 3)

    -- Raw-scale generation reset: state pointer is RDX.
    assert(mod:hook {
        name = "TextScaleGenerationDefault",
        at = default_scale_site,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = [[
            mov qword ptr [%TextAccessibilityCurrentState], rdx
            mov qword ptr [%TextAccessibilityLastState], 0
            @lua InvalidateAccessibleTextScale
            @original
            @return
        ]],
    } == 4)

    -- {size} parser resets: state pointer is RAX.
    local parser_reset_asm = [[
        mov qword ptr [%TextAccessibilityCurrentState], rax
        mov qword ptr [%TextAccessibilityLastState], 0
        @lua InvalidateAccessibleTextScale
        @original
        @return
    ]]

    assert(mod:hook {
        name = "TextScaleGenerationSizeA",
        at = size_parser_a_site,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = parser_reset_asm,
    } == 5)

    assert(mod:hook {
        name = "TextScaleGenerationSizeB",
        at = size_parser_b_site,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = parser_reset_asm,
    } == 6)

    -- All shared text crosses these generated glyph/layout families. Unlike the old
    -- dialogue-only gate, negative bindings are not rejected: Lua chooses the
    -- semantic multiplier from binding + constructor provenance.
    local text_scale_asm = [[
        mov rax, qword ptr [rsi + 0x30]
        cmp rax, qword ptr [%TextAccessibilityLastState]
        je text_accessibility_ready

        mov qword ptr [%TextAccessibilityCurrentState], rax
        mov qword ptr [%TextAccessibilityCurrentController], rsi
        @lua ApplyAccessibleTextScale
        mov qword ptr [%TextAccessibilityLastState], rax

    text_accessibility_ready:
        @original
        @return
    ]]

    assert(mod:hook {
        name = "TextGlyphScaleA",
        at = glyph_tick_a,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = text_scale_asm,
    } == 7)

    assert(mod:hook {
        name = "TextGlyphScaleB",
        at = glyph_tick_b,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = text_scale_asm,
    } == 8)

    -- Stock Panel2 already accounts for the accessibility-induced size growth.
    -- The remaining mismatch is positional: enlarged current-line glyphs move
    -- relative to the controller-anchored panel origin. Compute the same
    -- accessibility-only overflow term, but apply it to the panel Y coordinate
    -- immediately before Chowdren's stock SetObjectPositionDirect call.
    --
    --   shift = min(max(line_coeff * live_scale - stock_allowance, 0),
    --               line_coeff * accessibility_delta)
    --
    -- This is exactly zero at dialogue_scale=1.0 and for normal text that still
    -- fits the stock allowance. Stock Panel2 height calculation is untouched.
    local panel_position_asm = string.format([[
        mov rax, 0x%X
        movsd xmm2, qword ptr [rax]
        xorpd xmm3, xmm3
        ucomisd xmm2, xmm3
        jbe text_accessibility_panel_position_done

        mov rax, qword ptr [r12 + 0x30]
        movsd xmm2, qword ptr [rax + 0x2B8]
        movsd xmm3, qword ptr [rax + 0x2D8]
        cvttsd2si ecx, xmm3
        cmp ecx, 0x06
        ja text_accessibility_panel_position_done

        mov rax, 0x%X
        mov eax, dword ptr [rax + rcx*4]
        cvtsi2sd xmm3, eax

        mulsd xmm2, xmm3
        mov rax, qword ptr [rdi + 0x30]
        subsd xmm2, qword ptr [rax + 0x218]
        xorpd xmm4, xmm4
        maxsd xmm2, xmm4

        mov rax, 0x%X
        mulsd xmm3, qword ptr [rax]
        minsd xmm2, xmm3
        maxsd xmm2, xmm4

        addsd xmm1, xmm2

    text_accessibility_panel_position_done:
        @original
        @return
    ]], dialogue_accessibility_delta_slot, dialogue_line_coefficients,
        dialogue_accessibility_delta_slot)

    local hook_index = 8
    for family, site in ipairs(panel_position_calls) do
        hook_index = hook_index + 1
        assert(mod:hook {
            name = string.format("ShiftPanelAccessibilityOverflow_%d", family),
            at = site,
            overwrite = "auto",
            detour = "near",
            preserve = "none",
            threads = "stop",
            asm = panel_position_asm,
        } == hook_index)
    end

    -- Preserve stock pointer projection/clamping whenever the proposed point
    -- is already outside Panel2. If the accessibility-expanded panel engulfs
    -- the point, move it one unit beyond the nearest stock clamp boundary; the
    -- original routine then performs its normal ObjectSetX/ObjectSetY snap.
    -- This is native and allocation-free on the per-frame path.
    local pointer_perimeter_asm = [[
        cmp qword ptr [rsi], 0xF36EB0
        jne text_accessibility_pointer_done
        mov rax, qword ptr [rsi + 0x30]
        test rax, rax
        jz text_accessibility_pointer_done
        cmp dword ptr [rax + 0x208], 0x0
        jne text_accessibility_pointer_done
        cmp dword ptr [rax + 0x20C], 0x40140000
        jne text_accessibility_pointer_done

        mov rax, qword ptr [rdi + 0x1088]
        test rax, rax
        jz text_accessibility_pointer_done
        mov ecx, dword ptr [rax + 0x8]
        test ecx, ecx
        jz text_accessibility_pointer_fallback
        shl rcx, 0x4
        mov rdx, qword ptr [rax + rcx]
        jmp text_accessibility_pointer_panel_ready

    text_accessibility_pointer_fallback:
        mov rdx, qword ptr [rdi + 0x1090]

    text_accessibility_pointer_panel_ready:
        test rdx, rdx
        jz text_accessibility_pointer_done

        movsd xmm0, qword ptr [rdx + 0x10]
        movsd xmm2, qword ptr [rdx + 0x18]
        mov eax, dword ptr [rdx + 0x58]
        cvtsi2sd xmm1, eax
        addsd xmm1, xmm0
        mov eax, 0x2
        cvtsi2sd xmm10, eax
        subsd xmm1, xmm10
        mov eax, dword ptr [rdx + 0x5C]
        cvtsi2sd xmm3, eax
        addsd xmm3, xmm2
        subsd xmm3, xmm10

        movsd xmm4, qword ptr [rsi + 0x10]
        movsd xmm5, qword ptr [rsi + 0x18]

        ucomisd xmm4, xmm0
        jp text_accessibility_pointer_done
        jbe text_accessibility_pointer_done
        ucomisd xmm4, xmm1
        jp text_accessibility_pointer_done
        jae text_accessibility_pointer_done
        ucomisd xmm5, xmm2
        jp text_accessibility_pointer_done
        jbe text_accessibility_pointer_done
        ucomisd xmm5, xmm3
        jp text_accessibility_pointer_done
        jae text_accessibility_pointer_done

        movapd xmm6, xmm4
        subsd xmm6, xmm0
        movapd xmm7, xmm1
        subsd xmm7, xmm4
        movapd xmm8, xmm5
        subsd xmm8, xmm2
        movapd xmm9, xmm3
        subsd xmm9, xmm5

        xor ecx, ecx
        movapd xmm11, xmm6
        ucomisd xmm7, xmm11
        jae text_accessibility_pointer_not_right
        movapd xmm11, xmm7
        mov ecx, 0x1

    text_accessibility_pointer_not_right:
        ucomisd xmm8, xmm11
        jae text_accessibility_pointer_not_top
        movapd xmm11, xmm8
        mov ecx, 0x2

    text_accessibility_pointer_not_top:
        ucomisd xmm9, xmm11
        jae text_accessibility_pointer_edge_ready
        mov ecx, 0x3

    text_accessibility_pointer_edge_ready:
        mov eax, 0x1
        cvtsi2sd xmm10, eax
        cmp ecx, 0x0
        je text_accessibility_pointer_left
        cmp ecx, 0x1
        je text_accessibility_pointer_right
        cmp ecx, 0x2
        je text_accessibility_pointer_top

        addsd xmm3, xmm10
        movsd qword ptr [rsi + 0x18], xmm3
        jmp text_accessibility_pointer_done

    text_accessibility_pointer_left:
        subsd xmm0, xmm10
        movsd qword ptr [rsi + 0x10], xmm0
        jmp text_accessibility_pointer_done

    text_accessibility_pointer_right:
        addsd xmm1, xmm10
        movsd qword ptr [rsi + 0x10], xmm1
        jmp text_accessibility_pointer_done

    text_accessibility_pointer_top:
        subsd xmm2, xmm10
        movsd qword ptr [rsi + 0x18], xmm2

    text_accessibility_pointer_done:
        @original
        @return
    ]]

    hook_index = hook_index + 1
    assert(mod:hook {
        name = "KeepDialoguePointerOnPanelPerimeter",
        at = dialogue_pointer_clamp,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = pointer_perimeter_asm,
    } == hook_index)

    print(string.format(
        "Iconoclasts text accessibility + dialogue origin/pointer + tutorial reflow prepared: dialogue=%.3f tutorial=%.3f wrap=%d other=%.3f default=0x%X sizeA=0x%X sizeB=0x%X tickA=0x%X tickB=0x%X craftMenu=0x%X craftTutorial=0x%X panelA=0x%X panelB=0x%X pointerClamp=0x%X position-sites=2",
        dialogue_scale,
        tutorial_scale,
        tutorial_wrap_columns,
        other_scale,
        default_scale_site,
        size_parser_a_site,
        size_parser_b_site,
        glyph_tick_a,
        glyph_tick_b,
        craft_menu_dispatch_call,
        craft_tutorial_dispatch_call,
        panel_layout_a,
        panel_layout_b,
        dialogue_pointer_clamp))

    return mod
end

function M.install(options)
    local mod = prepare(options)
    assert(mod:install() == 11)
    return mod
end

if module_name ~= nil then
    return M
end

local config = aa.config {
    dialogue_scale = 1.25,
    tutorial_scale = 1.25,
    tutorial_wrap_columns = 50,
    other_text_scale = 1.15,
}

return prepare {
    dialogue_scale = config.dialogue_scale,
    tutorial_scale = config.tutorial_scale,
    tutorial_wrap_columns = config.tutorial_wrap_columns,
    other_scale = config.other_text_scale,
}
