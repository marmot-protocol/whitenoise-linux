#include <metal_stdlib>
using namespace metal;

// SDL 3.4 GPU renderer uses these user locations for COLOR0 and TEXCOORD0.
// SDL_CreateGPUShader compiles this source with entrypoint "main0".
struct PSInput {
    float4 v_color [[user(locn0)]];
    float2 v_uv [[user(locn1)]];
};

struct Context {
    float4 parameters; // saturation, grain frame + 1 (0 disables), output width and height.
};

fragment float4 main0(PSInput input [[stage_in]], constant Context &context [[buffer(0)]],
                      texture2d<float> u_texture [[texture(0)]], sampler u_sampler [[sampler(0)]]) {
    float4 color = u_texture.sample(u_sampler, input.v_uv) * input.v_color;
    float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    float3 graded = mix(float3(luminance), color.rgb, context.parameters.x);
    if (context.parameters.y > 0.5) {
        uint2 pixel = uint2(input.v_uv * context.parameters.zw);
        uint hash = (pixel.x / 2u) ^ ((pixel.y / 2u) * 0x9e3779b9u) ^
                    (uint(context.parameters.y - 1.0) * 0xc2b2ae35u);
        hash = (hash ^ (hash >> 16u)) * 0x85ebca6bu;
        hash ^= hash >> 13u;
        uint fine = (hash >> ((pixel.x % 2u + pixel.y % 2u * 2u) * 8u)) & 255u;
        float grain =
            (float(hash & 255u) / 255.0 - 0.5) * 0.12 + (float(fine) / 255.0 - 0.5) * 0.035;
        graded = clamp(graded + float3(grain), 0.0, 1.0);
    }
    return float4(graded, color.a);
}
