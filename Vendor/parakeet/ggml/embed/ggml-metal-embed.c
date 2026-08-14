// Embeds the merged Metal shader source produced by regenerate.sh into the binary,
// under the section and symbol names ggml-metal-device.m:122-129 loads at runtime.
//
// Upstream generates an equivalent .s file from CMake; SwiftPM has no code-generation
// step, so the same directives live in a committed C translation unit and the .incbin
// path resolves through the target's `embed` header search path.
__asm__(
    ".section __DATA,__ggml_metallib\n"
    ".globl _ggml_metallib_start\n"
    "_ggml_metallib_start:\n"
    ".incbin \"ggml-metal-embed.metal\"\n"
    ".globl _ggml_metallib_end\n"
    "_ggml_metallib_end:\n"
);
