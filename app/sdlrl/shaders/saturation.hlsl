// SDL 3.4 GPU renderer tri_texture.vert.hlsl output interface.
// dxc -T ps_6_0 -E main -O3 -Fo saturation.dxil saturation.hlsl
cbuffer Context : register(b0, space3) {
    float4 parameters; // saturation, grain frame + 1 (0 disables), output width and height.
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
    float3 graded = lerp(luminance.xxx, color.rgb, parameters.x);
    if (parameters.y > 0.5) {
        uint2 pixel = uint2(input.v_uv * parameters.zw);
        uint hash = (pixel.x / 2u) ^ ((pixel.y / 2u) * 0x9e3779b9u) ^
                    (uint(parameters.y - 1.0) * 0xc2b2ae35u);
        hash = (hash ^ (hash >> 16u)) * 0x85ebca6bu;
        hash ^= hash >> 13u;
        uint fine = (hash >> ((pixel.x % 2u + pixel.y % 2u * 2u) * 8u)) & 255u;
        float grain =
            (float(hash & 255u) / 255.0 - 0.5) * 0.12 + (float(fine) / 255.0 - 0.5) * 0.035;
        graded = saturate(graded + grain.xxx);
    }
    return float4(graded, color.a);
}
