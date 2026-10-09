// SDL 3.4 GPU renderer tri_texture.vert.hlsl output interface.
// dxc -T ps_6_0 -E main -O3 -Fo saturation.dxil saturation.hlsl
cbuffer Context : register(b0, space3) {
    float4 parameters; // x: saturation; yzw: reserved; upload 16 bytes to slot 0.
};

Texture2D<float4> u_texture : register(t0, space2);
SamplerState u_sampler : register(s0, space2);

struct PSInput {
    float4 v_color : COLOR0;
    float2 v_uv : TEXCOORD0;
};

float4 main(PSInput input) : SV_Target0 {
    float4 color = u_texture.Sample(u_sampler, input.v_uv) * input.v_color;
    float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    return float4(lerp(luminance.xxx, color.rgb, parameters.x), color.a);
}
