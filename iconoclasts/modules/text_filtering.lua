-- Iconoclasts accessibility-text filtering module.
--
-- Only BaseFont glyph instances created by the two shared text-controller glyph
-- paths are eligible. At creation time they are tagged iff the controller's
-- effective +0x2b8 scale is greater than 1.0.
--
-- Filtering is draw-scoped because animation/image textures are shared:
--   tagged glyph -> temporarily GL_LINEAR for its image draw -> restore stock
--   untagged glyph -> untouched
--
-- OpenGL note: trilinear mip filtering is a minification mode. For scale > 1,
-- GL_TEXTURE_MAG_FILTER uses GL_LINEAR; this is the filtered sampling mode that
-- actually affects the enlarged accessibility text. Chowdren's native FontShader
-- is also rewritten once at compile time with a selectable alpha profile:
--   lowres -> canonical coverage lift; preferred across current presentation modes
--   sharp  -> deprecated centered-alpha compatibility profile
--   off    -> stock alpha response
-- The rewrite adds no per-glyph shader/program state churn under Box64.

local module_name = ...
local M = {}

local GL_FRAGMENT_SHADER_ARB = 0x8B30
local GL_TEXTURE_2D = 0x0DE1
local GL_TEXTURE_MAG_FILTER = 0x2800
local GL_NEAREST = 0x2600
local GL_LINEAR = 0x2601

local alpha_lines = {
    sharp = "c.a=clamp((c.a-.5)*1.35+.5,0.,1.);",
    lowres = "c.a=clamp(c.a+.40*c.a*(1.-c.a),0.,1.);",
    off = "",
}

local function configured_alpha_profile(explicit)
    local value = explicit
    if value == nil then
        value = os.getenv("ICONOCLASTS_TEXT_ALPHA_PROFILE") or "lowres"
    end

    assert(type(value) == "string",
           "text_alpha_profile must be a string")

    value = value:lower()
    assert(alpha_lines[value] ~= nil,
           "text_alpha_profile must be one of: lowres, sharp, off")
    return value
end

local TAG_SLOTS = 0x10000
local TAG_MASK = TAG_SLOTS - 1
local TAG_BYTES = TAG_SLOTS * 8
local ONE_DOUBLE_BITS = 0x3ff0000000000000

local function exact_first(expected)
    return function(ctx)
        local insn = ctx:decode(0, 16, 1)
        return #insn == 1 and insn[1].mnemonic == expected
    end
end

local function rel32_target(address)
    local bytes = aa.read(address, 5)
    assert(bytes ~= nil and #bytes == 5,
           "failed reading rel32 branch")
    local displacement = string.unpack("<i4", bytes, 2)
    return address + 5 + displacement
end

local function rip32_target(address, displacement_offset, instruction_size)
    local bytes = aa.read(address + displacement_offset, 4)
    assert(bytes ~= nil and #bytes == 4,
           "failed reading RIP-relative displacement")
    local displacement = string.unpack("<i4", bytes)
    return address + instruction_size + displacement
end

local function prepare(options)
    options = options or {}

    local TEXT_ALPHA_PROFILE =
        configured_alpha_profile(options.text_alpha_profile)
    local alpha_line = alpha_lines[TEXT_ALPHA_PROFILE]

    if TEXT_ALPHA_PROFILE == "sharp" then
        print("Iconoclasts text alpha profile 'sharp' is deprecated; prefer 'lowres'")
    end

    local font_fragment_source = table.concat({
        "#version 120\n",
        "varying vec2 texture_coordinate;\n",
        "uniform sampler2D texture;\n",
        "void main(){\n",
        "vec4 c=texture2D(texture,texture_coordinate);\n",
        alpha_line,
        alpha_line ~= "" and "\n" or "",
        "c.rgb=vec3(1.);\n",
        "gl_FragColor=c*gl_Color;\n",
        "}\n",
    })

    local mod = aa.patch("iconoclasts-text-filtering")

    -- Chowdren's native FontShader descriptor is statically initialized with
    -- vtable 0x00F60500. Derive the descriptor address from the RIP-relative
    -- store rather than hard-coding its .bss address.
    local font_shader_descriptor_init = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "48 C7 05 ?? ?? ?? ?? 00 05 F6 00",
            "C6 05 ?? ?? ?? ?? 00",
            "C7 05 ?? ?? ?? ?? 43 00 00 00",
        }, " "),
        matches = "one",
        validate = exact_first("mov"),
    }
    local font_shader_descriptor =
        rip32_target(font_shader_descriptor_init, 3, 11)

    -- In Chowdren's shader compiler this sequence runs after the source has
    -- been read into a temporary malloc buffer and immediately before
    -- glShaderSourceARB. R15 is the shader descriptor, R14D the stage, EBX the
    -- source length, and [rsp+0x30] the temporary source buffer.
    local shader_source_submit = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "89 EF",
            "89 1C 24",
            "48 89 E1",
            "48 8D 54 24 30",
            "BE 01 00 00 00",
            "FF 15 ?? ?? ?? ??",
            "48 8B 7C 24 30",
        }, " "),
        matches = "one",
        validate = exact_first("mov"),
    }

    local create_basefont = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "41 54",
            "41 89 F4",
            "55",
            "89 FD",
            "53",
            "48 83 EC 10",
            "E8 ?? ?? ?? ??",
            "48 85 C0",
            "48 89 C3",
            "0F 84 ?? ?? ?? ??",
            "48 89 C7",
            "89 EE",
            "B9 A3 00 00 00",
            "44 89 E2",
            "E8 ?? ?? ?? ??",
            "48 8B 43 30",
        }, " "),
        matches = "one",
        validate = exact_first("push"),
    }
    local create_basefont_tail = create_basefont + 0x174


    local glyph_create_a = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "E8 ?? ?? ?? ??",
            "44 89 FA",
            "48 89 C6",
            "4C 89 EF",
            "E8 ?? ?? ?? ??",
            "49 89 C7",
            "48 8B 45 30",
            "4C 89 E7",
        }, " "),
        matches = "one",
        validate = exact_first("call"),
    }
    local glyph_mark_a = glyph_create_a + 5

    local glyph_create_b = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "E8 ?? ?? ?? ??",
            "44 89 FA",
            "48 89 C6",
            "4C 89 F7",
            "E8 ?? ?? ?? ??",
            "48 89 C3",
            "48 8B 45 30",
            "4C 89 E7",
        }, " "),
        matches = "one",
        validate = exact_first("call"),
    }
    local glyph_mark_b = glyph_create_b + 5

    local render_glyph = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "48 8B B7 90 00 00 00",
            "48 85 F6",
            "74 06",
            "80 7F 73 00",
            "75 06",
            "F3 C3",
            "0F 1F 40 00",
            "8B 4F 0C",
            "8B 57 08",
            "44 8B 47 70",
        }, " "),
        matches = "one",
        validate = exact_first("mov"),
    }

    -- Follow the verified BaseFont native call chain rather than scanning a
    -- lookalike generic renderer:
    --   RenderBaseFontGlyph +0x3A -> glyph draw helper
    --   glyph draw helper   +0x41 -> generic image draw
    local glyph_draw_helper = rel32_target(render_glyph + 0x3A)
    local image_draw = rel32_target(glyph_draw_helper + 0x41)
    local image_draw_tail = image_draw + 0x3E7

    local draw_tail_bytes = aa.read(image_draw_tail, 10)
    assert(draw_tail_bytes ~= nil and #draw_tail_bytes == 10 and
           draw_tail_bytes:byte(1) == 0xBF and
           draw_tail_bytes:byte(6) == 0xE9,
           "derived BaseFont image-draw tail does not match expected mov/jmp")


    local set_filtering = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "55",
            "40 0F B6 C6",
            "89 F5",
            "C1 E0 05",
            "53",
            "48 83 EC 08",
            "0F B7 57 02",
            "8B 5F 10",
            "83 E2 DF",
            "09 D0",
            "85 DB",
            "66 89 47 02",
        }, " "),
        matches = "one",
        validate = exact_first("push"),
    }

    local gl_draw_arrays = rel32_target(image_draw_tail + 5)

    -- SetImageLinearFiltering calls glTexParameteri twice (MIN + MAG). At this
    -- draw site the target image texture is already bound, and accessibility
    -- text is magnified (>1.0), so only MAG filtering affects the sample.
    -- Resolve glTexParameteri from the verified setter callsite and avoid the
    -- redundant MIN update plus guest setter call on every glyph.
    local set_filtering_call = set_filtering + 0x5E
    local set_filtering_call_bytes = aa.read(set_filtering_call, 5)
    assert(set_filtering_call_bytes ~= nil and
           #set_filtering_call_bytes == 5 and
           set_filtering_call_bytes:byte(1) == 0xE8,
           "SetImageLinearFiltering glTexParameteri callsite moved")
    local gl_tex_parameteri = rel32_target(set_filtering_call)

    assert(#font_fragment_source <= 214,
           "patched FontShader fragment source exceeds stock allocation")
    local font_fragment_memory = mod:alloc {
        size = #font_fragment_source,
        permissions = "rw",
        near = shader_source_submit,
        symbol = "AccessibleTextFontFragmentSource",
    }
    aa.write(font_fragment_memory, font_fragment_source)

    local tag_table = mod:alloc {
        size = TAG_BYTES,
        permissions = "rw",
        near = render_glyph,
        symbol = "AccessibleTextGlyphTags",
    }

    local pending_image = mod:alloc {
        size = 8,
        permissions = "rw",
        near = render_glyph,
        symbol = "AccessibleTextPendingImage",
    }

    local current_draw_image = mod:alloc {
        size = 8,
        permissions = "rw",
        near = image_draw,
        symbol = "AccessibleTextCurrentDrawImage",
    }

    aa.write(tag_table, string.rep("\0", TAG_BYTES))
    aa.write(pending_image, string.rep("\0", 8))
    aa.write(current_draw_image, string.rep("\0", 8))

    mod:consts {
        ACCESSIBLE_TEXT_TAG_MASK = TAG_MASK,
        ONE_DOUBLE_BITS = ONE_DOUBLE_BITS,
        GL_FRAGMENT_SHADER_ARB = GL_FRAGMENT_SHADER_ARB,
        GL_TEXTURE_2D = GL_TEXTURE_2D,
        GL_TEXTURE_MAG_FILTER = GL_TEXTURE_MAG_FILTER,
        GL_NEAREST = GL_NEAREST,
        GL_LINEAR = GL_LINEAR,
        FONT_FRAGMENT_SOURCE_LENGTH = #font_fragment_source,
    }

    mod:extern {
        AccessibleTextTexParameteri = gl_tex_parameteri,
        AccessibleTextDrawArrays = gl_draw_arrays,
        FontShaderDescriptor = font_shader_descriptor,
    }

    assert(mod:hook {
        name = "ClearBaseFontAccessibilityTag",
        at = create_basefont_tail,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = [[
            mov rax, rbx
            shr rax, 4
            and eax, ACCESSIBLE_TEXT_TAG_MASK
            lea rcx, [%AccessibleTextGlyphTags]
            cmp qword ptr [rcx + rax * 8], rbx
            jne text_filter_clear_done
            mov qword ptr [rcx + rax * 8], 0

        text_filter_clear_done:
            @original
            @return
        ]],
    } == 1)

    local function install_mark_hook(name, at)
        return mod:hook {
            name = name,
            at = at,
            overwrite = "auto",
            detour = "near",
            preserve = "none",
            threads = "stop",
            asm = [[
                mov rcx, qword ptr [rbp + 0x30]
                test rcx, rcx
                jz text_filter_mark_done

                mov rcx, qword ptr [rcx + 0x2B8]
                mov rdx, ONE_DOUBLE_BITS
                cmp rcx, rdx
                jbe text_filter_mark_done

                mov rcx, rax
                shr rcx, 4
                and ecx, ACCESSIBLE_TEXT_TAG_MASK
                lea rdx, [%AccessibleTextGlyphTags]
                mov qword ptr [rdx + rcx * 8], rax

            text_filter_mark_done:
                @original
                @return
            ]],
        }
    end

    assert(install_mark_hook("TagAccessibleTextGlyphA", glyph_mark_a) == 2)
    assert(install_mark_hook("TagAccessibleTextGlyphB", glyph_mark_b) == 3)

    assert(mod:hook {
        name = "SelectAccessibleTextGlyphImage",
        at = render_glyph,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = [[
            mov qword ptr [%AccessibleTextPendingImage], 0

            mov rax, rdi
            shr rax, 4
            and eax, ACCESSIBLE_TEXT_TAG_MASK
            lea rcx, [%AccessibleTextGlyphTags]
            cmp qword ptr [rcx + rax * 8], rdi
            jne text_filter_render_done

            mov rax, qword ptr [rdi + 0x90]
            test rax, rax
            jz text_filter_render_done

            cmp byte ptr [rdi + 0x73], 0
            je text_filter_render_done

            mov qword ptr [%AccessibleTextPendingImage], rax

        text_filter_render_done:
            @original
            @return
        ]],
    } == 4)

    assert(mod:hook {
        name = "BindAccessibleTextDrawScope",
        at = image_draw,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = [[
            mov qword ptr [%AccessibleTextCurrentDrawImage], 0
            mov rax, qword ptr [%AccessibleTextPendingImage]
            test rax, rax
            jz text_filter_draw_scope_done
            cmp rax, rdi
            jne text_filter_draw_scope_done

            mov qword ptr [%AccessibleTextPendingImage], 0
            mov qword ptr [%AccessibleTextCurrentDrawImage], rax

        text_filter_draw_scope_done:
            @original
            @return
        ]],
    } == 5)

    assert(mod:hook {
        name = "DrawAccessibleTextWithLinearFiltering",
        at = image_draw_tail,
        overwrite = 10,
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = [[
            sub rsp, 8

            mov rax, qword ptr [%AccessibleTextCurrentDrawImage]
            mov qword ptr [%AccessibleTextCurrentDrawImage], 0
            test rax, rax
            jz text_filter_plain_draw

            test word ptr [rax + 0x02], 0x20
            jnz text_filter_plain_draw

            mov edi, GL_TEXTURE_2D
            mov esi, GL_TEXTURE_MAG_FILTER
            mov edx, GL_LINEAR
            mov r11, %AccessibleTextTexParameteri
            call r11

            mov edi, 4
            xor esi, esi
            mov edx, 6
            mov r11, %AccessibleTextDrawArrays
            call r11

            mov edi, GL_TEXTURE_2D
            mov esi, GL_TEXTURE_MAG_FILTER
            mov edx, GL_NEAREST
            mov r11, %AccessibleTextTexParameteri
            call r11

            add rsp, 8
            ret

        text_filter_plain_draw:
            mov edi, 4
            xor esi, esi
            mov edx, 6
            mov r11, %AccessibleTextDrawArrays
            call r11
            add rsp, 8
            ret
        ]],
    } == 6)

    assert(mod:hook {
        name = "SharpenNativeFontShaderAlpha",
        at = shader_source_submit,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = [[
            cmp r15, %FontShaderDescriptor
            jne text_filter_font_source_done
            cmp r14d, GL_FRAGMENT_SHADER_ARB
            jne text_filter_font_source_done
            cmp ebx, FONT_FRAGMENT_SOURCE_LENGTH
            jb text_filter_font_source_done

            mov rdi, qword ptr [rsp + 0x30]
            test rdi, rdi
            jz text_filter_font_source_done
            lea rsi, [%AccessibleTextFontFragmentSource]
            mov ecx, FONT_FRAGMENT_SOURCE_LENGTH
            cld
            rep movsb
            mov ebx, FONT_FRAGMENT_SOURCE_LENGTH

        text_filter_font_source_done:
            @original
            @return
        ]],
    } == 7)

    print(string.format(
        "Iconoclasts accessibility text filtering prepared: tags=%d render=0x%X draw=0x%X texparam=0x%X alpha-profile=%s source-bytes=%d",
        TAG_SLOTS,
        render_glyph,
        image_draw,
        gl_tex_parameteri,
        TEXT_ALPHA_PROFILE,
        #font_fragment_source))

    return mod
end

function M.install(options)
    local mod = prepare(options)
    assert(mod:install() == 7)
    return mod
end

if module_name ~= nil then
    return M
end

local config = aa.config {
    text_alpha_profile = "lowres",
}

return prepare {
    text_alpha_profile = config.text_alpha_profile,
}
