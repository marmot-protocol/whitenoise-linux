#include <metal_stdlib>
using namespace metal;

// SDL 3.4 GPU renderer uses these user locations for COLOR0 and TEXCOORD0.
// SDL_CreateGPUShader compiles this source with entrypoint "main0".
struct PSInput {
    float4 v_color [[user(locn0)]];
    float2 v_uv [[user(locn1)]];
};

struct Context {
    float4 parameters; // x: saturation; yzw: reserved; upload 16 bytes to slot 0.
};

fragment float4 main0(
    PSInput input [[stage_in]],
    constant Context& context [[buffer(0)]],
    texture2d<float> u_texture [[texture(0)]],
    sampler u_sampler [[sampler(0)]]) {
    float4 color = u_texture.sample(u_sampler, input.v_uv) * input.v_color;
    float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    return float4(mix(float3(luminance), color.rgb, context.parameters.x), color.a);
}
