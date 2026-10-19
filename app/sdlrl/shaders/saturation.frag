#version 450

// SDL 3.4 GPU renderer: COLOR0 at location 0, TEXCOORD0 at location 1.
// glslangValidator -V --target-env vulkan1.0 -Os -S frag -o saturation.spv saturation.frag
layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;
layout(location = 0) out vec4 o_color;

layout(set = 2, binding = 0) uniform sampler2D u_texture;
layout(std140, set = 3, binding = 0) uniform Context {
    vec4 parameters; // saturation, grain frame + 1 (0 disables), output width and height.
};

void main() {
    vec4 color = texture(u_texture, v_uv) * v_color;
    float luminance = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
    vec3 graded = mix(vec3(luminance), color.rgb, parameters.x);
    if (parameters.y > 0.5) {
        uvec2 pixel = uvec2(v_uv * parameters.zw);
        uint hash = (pixel.x / 2u) ^ ((pixel.y / 2u) * 0x9e3779b9u) ^
                    (uint(parameters.y - 1.0) * 0xc2b2ae35u);
        hash = (hash ^ (hash >> 16u)) * 0x85ebca6bu;
        hash ^= hash >> 13u;
        uint fine = (hash >> ((pixel.x % 2u + pixel.y % 2u * 2u) * 8u)) & 255u;
        float grain =
            (float(hash & 255u) / 255.0 - 0.5) * 0.12 + (float(fine) / 255.0 - 0.5) * 0.035;
        graded = clamp(graded + vec3(grain), 0.0, 1.0);
    }
    o_color = vec4(graded, color.a);
}
