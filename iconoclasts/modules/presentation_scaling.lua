-- Iconoclasts final presentation scaling module.
--
-- Final FBO presentation policy (patch-owned geometry):
--   any aspect-fit scale below 1x     -> trilinear mipmaps with -0.35 LOD bias
--   exact integer scale (1x, 2x, ...) -> GL_NEAREST
--   fractional upscale                -> shimmerless upscale shader
--

-- The shimmerless shader is a GLSL 1.20 port of the supplied HLSL math.
-- It samples the existing final FBO texture with linear filtering.

local ffi = aa.ffi
local module_name = ...
local M = {}

local GL_FRAGMENT_SHADER_ARB = 0x8B30
local GL_OBJECT_COMPILE_STATUS_ARB = 0x8B81
local GL_OBJECT_LINK_STATUS_ARB = 0x8B82
local GL_TEXTURE_2D = 0x0DE1
local GL_TEXTURE_MAG_FILTER = 0x2800
local GL_TEXTURE_MIN_FILTER = 0x2801
local GL_NEAREST = 0x2600
local GL_LINEAR = 0x2601
local GL_LINEAR_MIPMAP_NEAREST = 0x2701
local GL_LINEAR_MIPMAP_LINEAR = 0x2703
local GL_TEXTURE_FILTER_CONTROL = 0x8500
local GL_TEXTURE_LOD_BIAS = 0x8501
local DOWNSCALE_LOD_BIAS = -0.35
local FRAME_SAMPLE_INTERVAL = 120
local PROFILE_ENABLED = (function()
    local value = os.getenv("AA_PROFILE")
    return value ~= nil and value ~= "" and value ~= "0"
end)()

local fragment_source = [[
#version 120
uniform sampler2D texture;
uniform vec2 TexSize;
uniform vec2 Scale;

void main()
{
    vec2 vTexCoord = gl_TexCoord[0].xy * TexSize;
    vec2 texel_floored = floor(vTexCoord);
    vec2 s = fract(vTexCoord);
    vec2 region_range = vec2(0.5) - vec2(0.5) / Scale;
    vec2 center_dist = s - vec2(0.5);
    vec2 f = (center_dist - clamp(center_dist, -region_range, region_range)) * Scale + vec2(0.5);
    vec2 mod_texel = texel_floored + f;
    gl_FragColor = texture2D(texture, mod_texel / TexSize);
}
]]

local function exact_first(expected)
    return function(ctx)
        local insn = ctx:decode(0, 16, 1)
        return #insn == 1 and insn[1].mnemonic == expected
    end
end

local function rel32_target(address)
    local bytes = aa.read(address, 5)
    assert(bytes ~= nil and #bytes == 5,
           "failed reading rel32 instruction")
    local displacement = string.unpack("<i4", bytes, 2)
    return address + 5 + displacement
end

local function imm32(address, offset)
    local bytes = aa.read(address + offset, 4)
    assert(bytes ~= nil and #bytes == 4,
           "failed reading imm32")
    return string.unpack("<I4", bytes)
end

local function rip32_target(address, displacement_offset, instruction_size)
    local bytes = aa.read(address + displacement_offset, 4)
    assert(bytes ~= nil and #bytes == 4,
           "failed reading RIP-relative displacement")
    local displacement = string.unpack("<i4", bytes)
    return address + instruction_size + displacement
end

local function write_u32(address, value)
    aa.write(address, string.pack("<I4", value))
end

local function write_i32(address, value)
    aa.write(address, string.pack("<i4", value))
end

local function write_u64(address, value)
    aa.write(address, string.pack("<I8", value))
end

local function prepare(options)
    options = options or {}

    local mod = aa.patch("iconoclasts-presentation-scaling")
    mod:consts {
        GL_TEXTURE_2D = GL_TEXTURE_2D,
        GL_TEXTURE_MAG_FILTER = GL_TEXTURE_MAG_FILTER,
        GL_TEXTURE_MIN_FILTER = GL_TEXTURE_MIN_FILTER,
        GL_NEAREST = GL_NEAREST,
        GL_LINEAR = GL_LINEAR,
        GL_LINEAR_MIPMAP_NEAREST = GL_LINEAR_MIPMAP_NEAREST,
        GL_LINEAR_MIPMAP_LINEAR = GL_LINEAR_MIPMAP_LINEAR,
        GL_TEXTURE_FILTER_CONTROL = GL_TEXTURE_FILTER_CONTROL,
        GL_TEXTURE_LOD_BIAS = GL_TEXTURE_LOD_BIAS,

        PRESENTATION_INTEGER = 1,
        PRESENTATION_DOWNSCALE = 2,
        PRESENTATION_SHIMMERLESS = 3,
        FILTER_STOCK_NEAREST = 1,
        FILTER_LINEAR = 2,
        FILTER_MIPMAP_NEAREST = 3,
        FILTER_MIPMAP_LINEAR = 4,

        STARTUP_FALLBACK_WIDTH = 0x500,
        STARTUP_FALLBACK_HEIGHT = 0x2D0,
        STARTUP_FALLBACK_POSITION = 0x2FFF0000,
        STARTUP_MAX_DIMENSION = 0x8000,
        -- SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE. Fullscreen/windowed user
        -- preference is normalized away here; borderless usable-bounds sizing is
        -- applied immediately after SDL_CreateWindow succeeds.
        STARTUP_WINDOW_FLAGS = 0x22,
        FRAME_SAMPLE_INTERVAL = FRAME_SAMPLE_INTERVAL,
    }


    -- Startup window creation hard-codes a centered 1280x720 resizable window
    -- immediately before SDL_CreateWindow. Replace the full x/y/w/h/flags setup
    -- with the primary display's usable rectangle and a borderless OpenGL window.
    -- This deliberately ignores Chowdren's fullscreen/windowed preference so the
    -- drawable can occupy the device's usable region exactly from frame one.
    local startup_window_size = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "41 89 D9",
            "41 B8 D0 02 00 00",
            "B9 00 05 00 00",
            "BA 00 00 FF 2F",
            "BE 00 00 FF 2F",
            "BF ?? ?? ?? ??",
            "E8 ?? ?? ?? ??",
            "48 89 C7",
            "48 89 05 ?? ?? ?? ??",
        }, " "),
        matches = "one",
        validate = exact_first("mov"),
    }

    -- Chowdren exposes separate runtime policies that can later undo our device
    -- geometry: a fullscreen toggle and an integer window-scale setter. WL-081
    -- owns this geometry completely, so resolve both and neutralize them below.
    local fullscreen_policy = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "53",
            "89 FB",
            "BF ?? ?? ?? ??",
            "E8 ?? ?? ?? ??",
            "0F B6 FB",
            "E8 ?? ?? ?? ??",
            "BF 0A 00 00 00",
        }, " "),
        matches = "one",
        validate = exact_first("push"),
    }

    local window_scale_policy = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "85 FF",
            "75 04",
            "C3",
            "0F 1F 00",
            "41 55",
            "41 54",
            "55",
            "69 EF D0 02 00 00",
            "53",
            "8D 1C BF",
        }, " "),
        matches = "one",
        validate = exact_first("test"),
    }

    -- End of GL/window setup: final 1280x720 FBO is created immediately before
    -- this epilogue. Hook here so the GL context and ARB entry points are live.
    local post_create_window = startup_window_size + 0x25
    local window_slot = rip32_target(post_create_window, 3, 7)

    local startup_x_slot = mod:alloc {
        size = 4, permissions = "rw", near = startup_window_size,
        symbol = "PresentationStartupX",
    }
    local startup_y_slot = mod:alloc {
        size = 4, permissions = "rw", near = startup_window_size,
        symbol = "PresentationStartupY",
    }
    local startup_width_slot = mod:alloc {
        size = 4, permissions = "rw", near = startup_window_size,
        symbol = "PresentationStartupWidth",
    }
    local startup_height_slot = mod:alloc {
        size = 4, permissions = "rw", near = startup_window_size,
        symbol = "PresentationStartupHeight",
    }
    write_i32(startup_x_slot, 0)
    write_i32(startup_y_slot, 0)
    write_i32(startup_width_slot, 0)
    write_i32(startup_height_slot, 0)

    local context_fbo_init = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "BA D0 02 00 00",
            "BE 00 05 00 00",
            "BF ?? ?? ?? ??",
            "E8 ?? ?? ?? ??",
            "48 83 C4 28",
            "5B",
            "5D",
            "C3",
        }, " "),
        matches = "one",
        validate = exact_first("mov"),
    }
    local context_ready = context_fbo_init + 20
    local final_fbo = imm32(context_fbo_init, 11)
    mod:extern {
        FinalFbo = final_fbo,
    }


    -- Final FBO texture is already bound when execution reaches this sequence.
    -- r13-r15/r12 encode destination rectangle endpoints/offsets:
    --   dest_w = r13d - r15d
    --   dest_h = r12d - r14d
    local final_pass = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "F3 41 0F 2A CF",
            "48 8B 05 ?? ?? ?? ??",
            "F3 41 0F 2A DD",
            "89 1D ?? ?? ?? ??",
            "F3 0F 10 15 ?? ?? ?? ??",
        }, " "),
        matches = "one",
        validate = exact_first("cvtsi2ss"),
    }

    -- Take ownership of final presentation geometry after Chowdren has chosen
    -- its own destination size but before it computes centering offsets, clear
    -- policy, or final quad coordinates. The live drawable dimensions remain in
    -- PresentFrame's stack locals at rsp+0x1c (width) and rsp+0x10 (height).
    local presentation_geometry = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "44 89 E2",
            "89 E8",
            "BF ?? ?? ?? ??",
            "29 F2",
            "29 C8",
            "89 D6",
            "C1 EE 1F",
            "01 F2",
            "D1 FA",
            "89 15 ?? ?? ?? ??",
        }, " "),
        matches = "one",
        validate = exact_first("mov"),
    }

    local game_presentation_width =
        rip32_target(presentation_geometry - 0x14, 2, 6)
    local game_presentation_height =
        rip32_target(presentation_geometry - 0x06, 2, 6)
    mod:extern {
        ChowdrenPresentationWidth = game_presentation_width,
        ChowdrenPresentationHeight = game_presentation_height,
    }

    -- Scope the shimmerless program to the final composite draw itself.
    -- PresentFrame recomputes drawable geometry every frame; binding/unbinding
    -- here prevents a fractional-upscale shader from leaking into later modes.
    local final_draw = mod:scan {
        module = "Chowdren",
        pattern = table.concat({
            "E8 ?? ?? ?? ??",
            "BF E2 0B 00 00",
            "E8 ?? ?? ?? ??",
            "31 FF",
            "FF 15 ?? ?? ?? ??",
            "31 C9",
            "31 D2",
            "BE 06 14 00 00",
            "BF 04 00 00 00",
        }, " "),
        matches = "one",
        validate = exact_first("call"),
    }

    local program_slot = mod:alloc {
        size = 4, permissions = "rw", near = final_pass,
        symbol = "PresentationShimmerlessProgram",
    }
    local texsize_slot = mod:alloc {
        size = 4, permissions = "rw", near = final_pass,
        symbol = "PresentationTexSizeLocation",
    }
    local scale_slot = mod:alloc {
        size = 4, permissions = "rw", near = final_pass,
        symbol = "PresentationScaleLocation",
    }
    local use_program_slot = mod:alloc {
        size = 8, permissions = "rw", near = final_pass,
        symbol = "PresentationUseProgram",
    }
    local uniform2f_slot = mod:alloc {
        size = 8, permissions = "rw", near = final_pass,
        symbol = "PresentationUniform2f",
    }
    local tex_parameteri_slot = mod:alloc {
        size = 8, permissions = "rw", near = final_pass,
        symbol = "PresentationTexParameteri",
    }
    local generate_mipmap_slot = mod:alloc {
        size = 8, permissions = "rw", near = final_draw,
        symbol = "PresentationGenerateMipmap",
    }
    local tex_envf_slot = mod:alloc {
        size = 8, permissions = "rw", near = final_draw,
        symbol = "PresentationTexEnvf",
    }
    local downscale_lod_bias_slot = mod:alloc {
        size = 4, permissions = "rw", near = final_draw,
        symbol = "PresentationDownscaleLodBias",
    }
    local filter_mode_slot = mod:alloc {
        size = 4, permissions = "rw", near = final_pass,
        symbol = "PresentationFilterMode",
    }
    local presentation_mode_slot = mod:alloc {
        size = 4, permissions = "rw", near = final_pass,
        symbol = "PresentationMode",
    }
    local shader_bound_slot = mod:alloc {
        size = 4, permissions = "rw", near = final_draw,
        symbol = "PresentationShaderBound",
    }
    local dest_width_slot = mod:alloc {
        size = 4, permissions = "rw", near = final_pass,
        symbol = "PresentationDestWidth",
    }
    local dest_height_slot = mod:alloc {
        size = 4, permissions = "rw", near = final_pass,
        symbol = "PresentationDestHeight",
    }
    local frame_sample_counter_slot = mod:alloc {
        size = 4, permissions = "rw", near = final_draw,
        symbol = "PresentationFrameSampleCounter",
    }

    write_u32(program_slot, 0)
    write_i32(texsize_slot, -1)
    write_i32(scale_slot, -1)
    write_u64(use_program_slot, 0)
    write_u64(uniform2f_slot, 0)
    write_u64(tex_parameteri_slot, 0)
    write_u64(generate_mipmap_slot, 0)
    write_u64(tex_envf_slot, 0)
    aa.write(downscale_lod_bias_slot, string.pack("<f", DOWNSCALE_LOD_BIAS))
    write_u32(filter_mode_slot, 0)
    write_u32(presentation_mode_slot, 0)
    write_u32(shader_bound_slot, 0)
    write_u32(dest_width_slot, 0)
    write_u32(dest_height_slot, 0)
    write_u32(frame_sample_counter_slot, 0)

    local source_memory = mod:alloc {
        size = #fragment_source + 1,
        permissions = "rw",
        near = context_ready,
        symbol = "PresentationFragmentSource",
    }
    local source_pointer = mod:alloc {
        size = 8,
        permissions = "rw",
        near = context_ready,
        symbol = "PresentationFragmentSourcePointer",
    }
    local status_memory = mod:alloc {
        size = 4,
        permissions = "rw",
        near = context_ready,
        symbol = "PresentationShaderStatus",
    }
    local log_memory = mod:alloc {
        size = 8192,
        permissions = "rw",
        near = context_ready,
        symbol = "PresentationShaderLog",
    }
    local startup_diag_memory = mod:alloc {
        size = 64,
        permissions = "rw",
        near = context_ready,
        symbol = "PresentationStartupDiagnostics",
    }

    aa.write(source_memory, fragment_source .. "\0")
    write_u64(source_pointer, source_memory)
    write_i32(status_memory, 0)
    aa.write(log_memory, string.rep("\0", 8192))

    local VoidPtr = ffi.void_ptr
    local I32Ptr = ffi.pointer(ffi.i32)
    local current_process = ffi.library(nil)
    local SDL_GetDisplayUsableBounds =
        current_process:symbol("SDL_GetDisplayUsableBounds")
    local get_display_usable_bounds_address =
        ffi.address(SDL_GetDisplayUsableBounds)
    assert(get_display_usable_bounds_address ~= 0,
           "failed resolving SDL_GetDisplayUsableBounds")
    local SDL_GetDisplayBounds =
        current_process:symbol("SDL_GetDisplayBounds")
    local get_display_bounds_address = ffi.address(SDL_GetDisplayBounds)
    assert(get_display_bounds_address ~= 0,
           "failed resolving SDL_GetDisplayBounds")
    local function process_symbol_address(name)
        local symbol = current_process:symbol(name)
        local address = ffi.address(symbol)
        assert(address ~= 0, "failed resolving " .. name)
        return address
    end

    mod:extern {
        PresentationGetDisplayUsableBounds =
            get_display_usable_bounds_address,
        PresentationGetDisplayBounds = get_display_bounds_address,
        PresentationGetWindowDisplayIndex =
            process_symbol_address("SDL_GetWindowDisplayIndex"),
        PresentationSetWindowFullscreen =
            process_symbol_address("SDL_SetWindowFullscreen"),
        PresentationSetWindowBordered =
            process_symbol_address("SDL_SetWindowBordered"),
        PresentationSetWindowPosition =
            process_symbol_address("SDL_SetWindowPosition"),
        PresentationSetWindowSize =
            process_symbol_address("SDL_SetWindowSize"),
    }

    local SDL_GetWindowSize = current_process:cfunc("SDL_GetWindowSize", {
        abi = "sysv64", returns = ffi.void,
        args = { VoidPtr, I32Ptr, I32Ptr },
    })
    local SDL_GL_GetDrawableSize = current_process:cfunc("SDL_GL_GetDrawableSize", {
        abi = "sysv64", returns = ffi.void,
        args = { VoidPtr, I32Ptr, I32Ptr },
    })
    local SDL_GetWindowDisplayIndex =
        current_process:cfunc("SDL_GetWindowDisplayIndex", {
            abi = "sysv64", returns = ffi.i32, args = { VoidPtr },
        })
    local SDL_GetCurrentDisplayMode =
        current_process:cfunc("SDL_GetCurrentDisplayMode", {
            abi = "sysv64", returns = ffi.i32,
            args = { ffi.i32, VoidPtr },
        })
    local SDL_GL_GetSwapInterval =
        current_process:cfunc("SDL_GL_GetSwapInterval", {
            abi = "sysv64", returns = ffi.i32, args = {},
        })
    local SDL_GetPerformanceCounter =
        current_process:cfunc("SDL_GetPerformanceCounter", {
            abi = "sysv64", returns = ffi.u64, args = {},
        })
    local SDL_GetPerformanceFrequency =
        current_process:cfunc("SDL_GetPerformanceFrequency", {
            abi = "sysv64", returns = ffi.u64, args = {},
        })

    local SDL_GL_GetProcAddress = current_process:cfunc("SDL_GL_GetProcAddress", {
        abi = "sysv64",
        returns = VoidPtr,
        args = { ffi.cstring },
    })

    local function bind_proc(name, returns, args)
        local pointer = SDL_GL_GetProcAddress(name)
        assert(pointer ~= nil, "SDL_GL_GetProcAddress failed for " .. name)
        local address = ffi.address(pointer)
        return ffi.cfunc {
            address = address,
            abi = "sysv64",
            returns = returns,
            args = args,
        }, address
    end

    local function read_status()
        return string.unpack("<i4", aa.read(status_memory, 4))
    end

    local function object_log(glGetInfoLogARB, object)
        aa.write(log_memory, string.rep("\0", 8192))
        glGetInfoLogARB(
            object,
            8191,
            nil,
            ffi.cast(VoidPtr, log_memory))
        local raw = aa.read(log_memory, 8191)
        local zero = raw:find("\0", 1, true)
        if zero ~= nil then
            raw = raw:sub(1, zero - 1)
        end
        return raw
    end

    mod:lua_method {
        name = "ReportPresentationScalingMode",
        near = final_pass,
        fn = function()
            local mode = string.unpack("<I4", aa.read(presentation_mode_slot, 4))
            local dest_w = string.unpack("<I4", aa.read(dest_width_slot, 4))
            local dest_h = string.unpack("<I4", aa.read(dest_height_slot, 4))
            local src_w = string.unpack("<I4", aa.read(final_fbo, 4))
            local src_h = string.unpack("<I4", aa.read(final_fbo + 4, 4))
            local names = {
                [1] = "INTEGER",
                [2] = "DOWNSCALE",
                [3] = "FRACTIONAL_UPSCALE",
            }
            local detail = mode == 3 and "shimmerless" or
                           (mode == 2 and "trilinear-lod-bias(-0.35)" or "nearest")
            print(string.format(
                "Presentation mode: %s src=%dx%d dst=%dx%d policy=%s",
                names[mode] or ("UNKNOWN(" .. tostring(mode) .. ")"),
                src_w, src_h, dest_w, dest_h, detail))
        end,
    }

    local frame_timing_previous = nil
    mod:lua_method {
        name = "ReportPresentationFrameTiming",
        near = final_draw,
        fn = function()
            if not PROFILE_ENABLED then
                return
            end

            local now = SDL_GetPerformanceCounter()
            local frequency = SDL_GetPerformanceFrequency()
            if frame_timing_previous ~= nil and frequency ~= 0 then
                local elapsed = (now - frame_timing_previous) / frequency
                if elapsed > 0 then
                    local fps = FRAME_SAMPLE_INTERVAL / elapsed
                    local frame_ms = elapsed * 1000.0 / FRAME_SAMPLE_INTERVAL
                    print(string.format(
                        "Presentation timing: %.2f fps %.3f ms/frame over %d frames",
                        fps, frame_ms, FRAME_SAMPLE_INTERVAL))
                end
            end
            frame_timing_previous = now
        end,
    }

    mod:lua_method {
        name = "InitializePresentationScaling",
        near = context_ready,
        fn = function()
            local startup_x = string.unpack(
                "<i4", aa.read(startup_x_slot, 4))
            local startup_y = string.unpack(
                "<i4", aa.read(startup_y_slot, 4))
            local startup_width = string.unpack(
                "<I4", aa.read(startup_width_slot, 4))
            local startup_height = string.unpack(
                "<I4", aa.read(startup_height_slot, 4))

            local window_address = string.unpack(
                "<I8", aa.read(window_slot, 8))
            local window = ffi.cast(VoidPtr, window_address)
            local diag = startup_diag_memory
            aa.write(diag, string.rep("\0", 64))
            SDL_GetWindowSize(
                window,
                ffi.cast(I32Ptr, diag),
                ffi.cast(I32Ptr, diag + 4))
            SDL_GL_GetDrawableSize(
                window,
                ffi.cast(I32Ptr, diag + 8),
                ffi.cast(I32Ptr, diag + 12))

            local window_width = string.unpack("<i4", aa.read(diag, 4))
            local window_height = string.unpack("<i4", aa.read(diag + 4, 4))
            local drawable_width = string.unpack("<i4", aa.read(diag + 8, 4))
            local drawable_height = string.unpack("<i4", aa.read(diag + 12, 4))
            local display_index = SDL_GetWindowDisplayIndex(window)
            local mode_result = SDL_GetCurrentDisplayMode(
                display_index, ffi.cast(VoidPtr, diag + 16))
            local mode_width, mode_height, refresh_rate = 0, 0, 0
            if mode_result == 0 then
                mode_width = string.unpack("<i4", aa.read(diag + 20, 4))
                mode_height = string.unpack("<i4", aa.read(diag + 24, 4))
                refresh_rate = string.unpack("<i4", aa.read(diag + 28, 4))
            end
            local swap_interval = SDL_GL_GetSwapInterval()

            print(string.format(
                "Presentation startup: usable=(%d,%d %dx%d) window=%dx%d drawable=%dx%d display=%d mode=%dx%d@%d swap=%d",
                startup_x, startup_y, startup_width, startup_height,
                window_width, window_height,
                drawable_width, drawable_height,
                display_index, mode_width, mode_height, refresh_rate,
                swap_interval))

            local glCreateShaderObjectARB =
                bind_proc("glCreateShaderObjectARB", ffi.u32, { ffi.u32 })
            local glShaderSourceARB =
                bind_proc("glShaderSourceARB", ffi.void, {
                    ffi.u32, ffi.i32, VoidPtr, VoidPtr,
                })
            local glCompileShaderARB =
                bind_proc("glCompileShaderARB", ffi.void, { ffi.u32 })
            local glGetObjectParameterivARB =
                bind_proc("glGetObjectParameterivARB", ffi.void, {
                    ffi.u32, ffi.u32, I32Ptr,
                })
            local glGetInfoLogARB =
                bind_proc("glGetInfoLogARB", ffi.void, {
                    ffi.u32, ffi.i32, I32Ptr, VoidPtr,
                })
            local glCreateProgramObjectARB =
                bind_proc("glCreateProgramObjectARB", ffi.u32, {})
            local glAttachObjectARB =
                bind_proc("glAttachObjectARB", ffi.void, {
                    ffi.u32, ffi.u32,
                })
            local glLinkProgramARB =
                bind_proc("glLinkProgramARB", ffi.void, { ffi.u32 })
            local glUseProgramObjectARB, use_program_address =
                bind_proc("glUseProgramObjectARB", ffi.void, { ffi.u32 })
            local glGetUniformLocationARB =
                bind_proc("glGetUniformLocationARB", ffi.i32, {
                    ffi.u32, ffi.cstring,
                })
            local glUniform1iARB =
                bind_proc("glUniform1iARB", ffi.void, {
                    ffi.i32, ffi.i32,
                })
            local _, uniform2f_address =
                bind_proc("glUniform2fARB", ffi.void, {
                    ffi.i32, ffi.u32, ffi.u32,
                })
            local _, tex_parameteri_address =
                bind_proc("glTexParameteri", ffi.void, {
                    ffi.u32, ffi.u32, ffi.i32,
                })

            local tex_envf_pointer = SDL_GL_GetProcAddress("glTexEnvf")
            assert(tex_envf_pointer ~= nil,
                   "SDL_GL_GetProcAddress failed for glTexEnvf")
            local tex_envf_address = ffi.address(tex_envf_pointer)

            local generate_mipmap_pointer =
                SDL_GL_GetProcAddress("glGenerateMipmap")
            if generate_mipmap_pointer == nil then
                generate_mipmap_pointer =
                    SDL_GL_GetProcAddress("glGenerateMipmapEXT")
            end
            assert(generate_mipmap_pointer ~= nil,
                   "SDL_GL_GetProcAddress failed for glGenerateMipmap/EXT")
            local generate_mipmap_address =
                ffi.address(generate_mipmap_pointer)

            local shader = glCreateShaderObjectARB(GL_FRAGMENT_SHADER_ARB)
            assert(shader ~= 0, "glCreateShaderObjectARB returned 0")

            glShaderSourceARB(
                shader,
                1,
                ffi.cast(VoidPtr, source_pointer),
                nil)
            glCompileShaderARB(shader)

            write_i32(status_memory, 0)
            glGetObjectParameterivARB(
                shader,
                GL_OBJECT_COMPILE_STATUS_ARB,
                ffi.cast(I32Ptr, status_memory))
            assert(
                read_status() ~= 0,
                "shimmerless fragment compile failed: " ..
                object_log(glGetInfoLogARB, shader))

            local program = glCreateProgramObjectARB()
            assert(program ~= 0, "glCreateProgramObjectARB returned 0")
            glAttachObjectARB(program, shader)
            glLinkProgramARB(program)

            write_i32(status_memory, 0)
            glGetObjectParameterivARB(
                program,
                GL_OBJECT_LINK_STATUS_ARB,
                ffi.cast(I32Ptr, status_memory))
            assert(
                read_status() ~= 0,
                "shimmerless program link failed: " ..
                object_log(glGetInfoLogARB, program))

            local texture_location =
                glGetUniformLocationARB(program, "texture")
            local texsize_location =
                glGetUniformLocationARB(program, "TexSize")
            local scale_location =
                glGetUniformLocationARB(program, "Scale")

            assert(texture_location >= 0,
                   "shimmerless shader missing texture uniform")
            assert(texsize_location >= 0,
                   "shimmerless shader missing TexSize uniform")
            assert(scale_location >= 0,
                   "shimmerless shader missing Scale uniform")

            glUseProgramObjectARB(program)
            glUniform1iARB(texture_location, 0)
            glUseProgramObjectARB(0)

            write_u32(program_slot, program)
            write_i32(texsize_slot, texsize_location)
            write_i32(scale_slot, scale_location)
            write_u64(use_program_slot, use_program_address)
            write_u64(uniform2f_slot, uniform2f_address)
            write_u64(tex_parameteri_slot, tex_parameteri_address)
            write_u64(generate_mipmap_slot, generate_mipmap_address)
            write_u64(tex_envf_slot, tex_envf_address)
            write_u32(filter_mode_slot, 0)

            local stored_use = string.unpack("<I8", aa.read(use_program_slot, 8))
            local stored_uniform2f = string.unpack("<I8", aa.read(uniform2f_slot, 8))
            local stored_texparam = string.unpack("<I8", aa.read(tex_parameteri_slot, 8))
            local stored_generate = string.unpack("<I8", aa.read(generate_mipmap_slot, 8))
            local stored_texenvf = string.unpack("<I8", aa.read(tex_envf_slot, 8))
            print(string.format(
                "Presentation GL procs: use=0x%X/0x%X uniform2f=0x%X/0x%X texparam=0x%X/0x%X mipmap=0x%X/0x%X texenvf=0x%X/0x%X",
                use_program_address, stored_use,
                uniform2f_address, stored_uniform2f,
                tex_parameteri_address, stored_texparam,
                generate_mipmap_address, stored_generate,
                tex_envf_address, stored_texenvf))

            print(string.format(
                "Iconoclasts presentation shader ready: program=%d source=%dx%d",
                program,
                string.unpack("<I4", aa.read(final_fbo, 4)),
                string.unpack("<I4", aa.read(final_fbo + 4, 4))))
        end,
    }

    assert(mod:hook {
        name = "InitializePresentationScaling",
        at = context_ready,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = [[
            @lua InitializePresentationScaling
            @original
            @return
        ]],
    } == 1)

    local geometry_asm = [[
        mov r10d, dword ptr [rsp + 0x1c]
        mov r11d, dword ptr [rsp + 0x10]
        test r10d, r10d
        jle presentation_geometry_done
        test r11d, r11d
        jle presentation_geometry_done

        mov r8d, dword ptr [%FinalFbo]
        mov r9d, dword ptr [%FinalFbo + 4]
        test r8d, r8d
        jle presentation_geometry_done
        test r9d, r9d
        jle presentation_geometry_done

        mov rax, r10
        imul rax, r9
        mov rdx, r11
        imul rdx, r8
        cmp rax, rdx
        jbe presentation_width_limited

    presentation_height_limited:
        mov rax, r11
        imul rax, r8
        xor edx, edx
        div r9
        mov esi, eax
        mov ecx, r11d
        jmp presentation_geometry_commit

    presentation_width_limited:
        mov rax, r10
        imul rax, r9
        xor edx, edx
        div r8
        mov esi, r10d
        mov ecx, eax

    presentation_geometry_commit:
        mov dword ptr [%ChowdrenPresentationWidth], esi
        mov dword ptr [%ChowdrenPresentationHeight], ecx

    presentation_geometry_done:
        @original
        @return
    ]]

    local final_asm = [[
        mov r10d, r13d
        sub r10d, r15d
        mov r11d, r12d
        sub r11d, r14d

        mov dword ptr [%PresentationDestWidth], r10d
        mov dword ptr [%PresentationDestHeight], r11d

        mov r8d, dword ptr [%FinalFbo]
        mov r9d, dword ptr [%FinalFbo + 4]

        cmp r10d, r8d
        jl presentation_downscale
        cmp r11d, r9d
        jl presentation_downscale

        mov eax, r10d
        xor edx, edx
        div r8d
        test edx, edx
        jne presentation_shimmerless
        mov ecx, eax

        mov eax, r11d
        xor edx, edx
        div r9d
        test edx, edx
        jne presentation_shimmerless
        cmp eax, ecx
        jne presentation_shimmerless

    presentation_integer:
        cmp dword ptr [%PresentationMode], PRESENTATION_INTEGER
        je presentation_integer_logged
        mov dword ptr [%PresentationMode], PRESENTATION_INTEGER
        @lua ReportPresentationScalingMode
    presentation_integer_logged:
        cmp dword ptr [%PresentationFilterMode], FILTER_STOCK_NEAREST
        je presentation_done

        mov r11, qword ptr [%PresentationTexParameteri]
        test r11, r11
        jz presentation_done
        mov edi, GL_TEXTURE_2D
        mov esi, GL_TEXTURE_MAG_FILTER
        mov edx, GL_NEAREST
        call r11

        mov r11, qword ptr [%PresentationTexParameteri]
        mov edi, GL_TEXTURE_2D
        mov esi, GL_TEXTURE_MIN_FILTER
        mov edx, GL_NEAREST
        call r11

        mov dword ptr [%PresentationFilterMode], FILTER_STOCK_NEAREST
        jmp presentation_done

    presentation_downscale:
        cmp dword ptr [%PresentationMode], PRESENTATION_DOWNSCALE
        je presentation_downscale_logged
        mov dword ptr [%PresentationMode], PRESENTATION_DOWNSCALE
        @lua ReportPresentationScalingMode
    presentation_downscale_logged:
        cmp dword ptr [%PresentationFilterMode], FILTER_MIPMAP_LINEAR
        je presentation_done

        mov r11, qword ptr [%PresentationTexParameteri]
        test r11, r11
        jz presentation_done
        mov edi, GL_TEXTURE_2D
        mov esi, GL_TEXTURE_MAG_FILTER
        mov edx, GL_LINEAR
        call r11

        mov r11, qword ptr [%PresentationTexParameteri]
        mov edi, GL_TEXTURE_2D
        mov esi, GL_TEXTURE_MIN_FILTER
        mov edx, GL_LINEAR_MIPMAP_LINEAR
        call r11

        mov dword ptr [%PresentationFilterMode], FILTER_MIPMAP_LINEAR
        jmp presentation_done

    presentation_shimmerless:
        cmp dword ptr [%PresentationMode], PRESENTATION_SHIMMERLESS
        je presentation_shimmerless_logged
        mov dword ptr [%PresentationMode], PRESENTATION_SHIMMERLESS
        @lua ReportPresentationScalingMode
    presentation_shimmerless_logged:
        cmp dword ptr [%PresentationFilterMode], FILTER_LINEAR
        je presentation_done

        mov r11, qword ptr [%PresentationTexParameteri]
        test r11, r11
        jz presentation_done
        mov edi, GL_TEXTURE_2D
        mov esi, GL_TEXTURE_MAG_FILTER
        mov edx, GL_LINEAR
        call r11

        mov r11, qword ptr [%PresentationTexParameteri]
        mov edi, GL_TEXTURE_2D
        mov esi, GL_TEXTURE_MIN_FILTER
        mov edx, GL_LINEAR
        call r11

        mov dword ptr [%PresentationFilterMode], FILTER_LINEAR

    presentation_done:
        @original
        @return
    ]]

    local draw_asm = [[
        inc dword ptr [%PresentationFrameSampleCounter]
        cmp dword ptr [%PresentationFrameSampleCounter], FRAME_SAMPLE_INTERVAL
        jb presentation_frame_sample_done
        mov dword ptr [%PresentationFrameSampleCounter], 0
        @lua ReportPresentationFrameTiming
    presentation_frame_sample_done:

        mov dword ptr [%PresentationShaderBound], 0

        cmp dword ptr [%PresentationMode], PRESENTATION_DOWNSCALE
        jne presentation_draw_check_shimmerless
        mov r11, qword ptr [%PresentationGenerateMipmap]
        test r11, r11
        jz presentation_draw
        mov edi, GL_TEXTURE_2D
        call r11

        mov r11, qword ptr [%PresentationTexEnvf]
        test r11, r11
        jz presentation_draw
        mov edi, GL_TEXTURE_FILTER_CONTROL
        mov esi, GL_TEXTURE_LOD_BIAS
        movss xmm0, dword ptr [%PresentationDownscaleLodBias]
        call r11
        jmp presentation_draw

    presentation_draw_check_shimmerless:
        cmp dword ptr [%PresentationMode], PRESENTATION_SHIMMERLESS
        jne presentation_draw

        mov edi, dword ptr [%PresentationShimmerlessProgram]
        test edi, edi
        jz presentation_draw

        mov r10, qword ptr [%PresentationUseProgram]
        test r10, r10
        jz presentation_draw

        mov r11, qword ptr [%PresentationUniform2f]
        test r11, r11
        jz presentation_draw

        call r10
        mov dword ptr [%PresentationShaderBound], 1

        mov edi, dword ptr [%PresentationTexSizeLocation]
        cvtsi2ss xmm0, dword ptr [%FinalFbo]
        cvtsi2ss xmm1, dword ptr [%FinalFbo + 4]
        mov r11, qword ptr [%PresentationUniform2f]
        call r11

        mov edi, dword ptr [%PresentationScaleLocation]
        cvtsi2ss xmm0, dword ptr [%PresentationDestWidth]
        cvtsi2ss xmm1, dword ptr [%PresentationDestHeight]
        cvtsi2ss xmm2, dword ptr [%FinalFbo]
        divss xmm0, xmm2
        cvtsi2ss xmm2, dword ptr [%FinalFbo + 4]
        divss xmm1, xmm2
        mov r11, qword ptr [%PresentationUniform2f]
        call r11

    presentation_draw:
        mov edi, 4
        xor esi, esi
        mov edx, 6
        @original

        cmp dword ptr [%PresentationMode], PRESENTATION_DOWNSCALE
        jne presentation_draw_restore_shader
        mov r11, qword ptr [%PresentationTexEnvf]
        test r11, r11
        jz presentation_draw_restore_shader
        mov edi, GL_TEXTURE_FILTER_CONTROL
        mov esi, GL_TEXTURE_LOD_BIAS
        xor eax, eax
        movd xmm0, eax
        call r11

    presentation_draw_restore_shader:
        cmp dword ptr [%PresentationShaderBound], 0
        je presentation_draw_done

        mov r11, qword ptr [%PresentationUseProgram]
        test r11, r11
        jz presentation_draw_clear
        xor edi, edi
        call r11

    presentation_draw_clear:
        mov dword ptr [%PresentationShaderBound], 0

    presentation_draw_done:
        @return
    ]]

    assert(mod:hook {
        name = "OwnPresentationGeometry",
        at = presentation_geometry,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = geometry_asm,
    } == 2)

    assert(mod:hook {
        name = "SelectPresentationScaling",
        at = final_pass,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = final_asm,
    } == 3)

    assert(mod:hook {
        name = "DrawPresentationScaling",
        at = final_draw,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = draw_asm,
    } == 4)

    assert(mod:hook {
        name = "NormalizeStartupWindowMode",
        at = startup_window_size,
        -- Replace Chowdren's fullscreen-dependent flags and retain its stock
        -- centered 1280x720 bootstrap only long enough to create SDL_Window.
        -- The next hook adapts that window before GL context creation.
        overwrite = 24,
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = [[
            mov r9d, STARTUP_WINDOW_FLAGS
            mov r8d, STARTUP_FALLBACK_HEIGHT
            mov ecx, STARTUP_FALLBACK_WIDTH
            mov edx, STARTUP_FALLBACK_POSITION
            mov esi, STARTUP_FALLBACK_POSITION
            @return
        ]],
    } == 5)

    assert(mod:hook {
        name = "AdaptCreatedWindowToUsableBounds",
        at = post_create_window,
        -- Entry is immediately after Chowdren has copied SDL_CreateWindow's
        -- return into RDI. The overwritten original stores RAX into the global
        -- SDL_Window* slot; restore both RAX/RDI before replaying it.
        overwrite = 7,
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = [[
            sub rsp, 0x20
            mov qword ptr [rsp], rdi

            mov r11, %PresentationGetWindowDisplayIndex
            call r11
            mov dword ptr [rsp + 0x18], eax

            mov edi, eax
            lea rsi, [rsp + 8]
            mov r11, %PresentationGetDisplayUsableBounds
            call r11
            test eax, eax
            jne post_create_try_full_bounds
            jmp post_create_validate_bounds

        post_create_try_full_bounds:
            mov edi, dword ptr [rsp + 0x18]
            lea rsi, [rsp + 8]
            mov r11, %PresentationGetDisplayBounds
            call r11
            test eax, eax
            jne post_create_done

        post_create_validate_bounds:
            mov ecx, dword ptr [rsp + 0x10]
            mov r8d, dword ptr [rsp + 0x14]
            test ecx, ecx
            jle post_create_done
            test r8d, r8d
            jle post_create_done
            cmp ecx, STARTUP_MAX_DIMENSION
            jg post_create_done
            cmp r8d, STARTUP_MAX_DIMENSION
            jg post_create_done

            mov rax, qword ptr [rsp]
            mov rdi, rax
            xor esi, esi
            mov r11, %PresentationSetWindowFullscreen
            call r11

            mov rdi, qword ptr [rsp]
            xor esi, esi
            mov r11, %PresentationSetWindowBordered
            call r11

            mov rdi, qword ptr [rsp]
            mov esi, dword ptr [rsp + 8]
            mov edx, dword ptr [rsp + 0x0C]
            mov r11, %PresentationSetWindowPosition
            call r11

            mov rdi, qword ptr [rsp]
            mov esi, dword ptr [rsp + 0x10]
            mov edx, dword ptr [rsp + 0x14]
            mov r11, %PresentationSetWindowSize
            call r11

            mov eax, dword ptr [rsp + 8]
            mov dword ptr [%PresentationStartupX], eax
            mov eax, dword ptr [rsp + 0x0C]
            mov dword ptr [%PresentationStartupY], eax
            mov eax, dword ptr [rsp + 0x10]
            mov dword ptr [%PresentationStartupWidth], eax
            mov eax, dword ptr [rsp + 0x14]
            mov dword ptr [%PresentationStartupHeight], eax

        post_create_done:
            mov rax, qword ptr [rsp]
            mov rdi, rax
            add rsp, 0x20
            @original
            @return
        ]],
    } == 6)

    assert(mod:hook {
        name = "IgnoreChowdrenFullscreenPolicy",
        at = fullscreen_policy,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = [[
            ret
        ]],
    } == 7)

    assert(mod:hook {
        name = "IgnoreChowdrenWindowScalePolicy",
        at = window_scale_policy,
        overwrite = "auto",
        detour = "near",
        preserve = "none",
        threads = "stop",
        asm = [[
            ret
        ]],
    } == 8)

    print(string.format(
        "Iconoclasts presentation scaling prepared: startup=0x%X postcreate=0x%X fullscreen=0x%X scale=0x%X fbo=0x%X init=0x%X geometry=0x%X select=0x%X draw=0x%X",
        startup_window_size,
        post_create_window,
        fullscreen_policy,
        window_scale_policy,
        final_fbo,
        context_ready,
        presentation_geometry,
        final_pass,
        final_draw))

    return mod
end

function M.install(options)
    local mod = prepare(options)
    assert(mod:install() == 8)
    return mod
end

if module_name ~= nil then
    return M
end

return prepare {}
