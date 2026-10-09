#version 450

// SDL 3.4 GPU renderer: COLOR0 at location 0, TEXCOORD0 at location 1.
// glslangValidator -V --target-env vulkan1.0 -Os -S frag -o saturation.spv saturation.frag
layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;
layout(location = 0) out vec4 o_color;

layout(set = 2, binding = 0) uniform sampler2D u_texture;
layout(std140, set = 3, binding = 0) uniform Context {
    vec4 parameters; // x: saturation; yzw: reserved; upload 16 bytes to slot 0.
};

void main() {
    vec4 color = texture(u_texture, v_uv) * v_color;
    float luminance = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
    o_color = vec4(mix(vec3(luminance), color.rgb, parameters.x), color.a);
}
