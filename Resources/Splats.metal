#include <metal_stdlib>
using namespace metal;

struct Gaussian {
    float3 position;
    float4 rotation;
    float3 scale;
    float4 dcAndOpacity;
};

struct Camera {
    float4 right;
    float4 up;
    float4 forward;
    float4 eye;
    float4 viewport; // width, height, focal length in pixels, near plane
};

struct Vertex {
    float4 position [[position]];
    float2 local;
    float4 color;
};

float3 rotateVector(float4 q, float3 v) {
    return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
}

float2 projectAxis(float3 axis, float3 right, float3 up, float3 forward, float3 point, float focal) {
    float axial = dot(axis, forward) / point.z;
    return focal / point.z * (float2(dot(axis, right), dot(axis, up)) - point.xy * axial);
}

vertex Vertex splatVertex(uint corner [[vertex_id]], uint instance [[instance_id]],
                          const device Gaussian *points [[buffer(0)]],
                          const device uint *order [[buffer(1)]],
                          constant Camera &camera [[buffer(2)]]) {
    Gaussian g = points[order[instance]];
    float3 relative = g.position - camera.eye.xyz;
    float3 right = camera.right.xyz, up = camera.up.xyz, forward = camera.forward.xyz;
    float3 view = float3(dot(relative, right), dot(relative, up), dot(relative, forward));
    if (view.z <= camera.viewport.w) {
        return { float4(2, 2, 0, 1), float2(0), float4(0) };
    }

    float focal = camera.viewport.z;
    float4 q = g.rotation / max(length(g.rotation), 1e-6f);
    float2 x = projectAxis(rotateVector(q, float3(g.scale.x, 0, 0)), right, up, forward, view, focal);
    float2 y = projectAxis(rotateVector(q, float3(0, g.scale.y, 0)), right, up, forward, view, focal);
    float2 z = projectAxis(rotateVector(q, float3(0, 0, g.scale.z)), right, up, forward, view, focal);
    // Project the oriented 3D covariance and take its 2D Cholesky factor.
    float xx = dot(float3(x.x, y.x, z.x), float3(x.x, y.x, z.x)) + 0.3;
    float yy = dot(float3(x.y, y.y, z.y), float3(x.y, y.y, z.y)) + 0.3;
    float xy = x.x * x.y + y.x * y.y + z.x * z.y;
    float l00 = sqrt(xx);
    float l10 = xy / l00;
    float l11 = sqrt(max(0.3f, yy - l10 * l10));
    float2 local = float2((corner & 1) ? 3.0 : -3.0, (corner & 2) ? 3.0 : -3.0);
    float2 offset = float2(l00 * local.x, l10 * local.x + l11 * local.y);
    float2 ndc = (focal / view.z * view.xy + offset) * 2.0 / camera.viewport.xy;
    float3 rgb = clamp(0.5 + 0.2820947918 * g.dcAndOpacity.xyz, 0.0, 1.0);
    return { float4(ndc, 0, 1), local, float4(rgb, g.dcAndOpacity.w) };
}

fragment float4 splatFragment(Vertex in [[stage_in]]) {
    float power = dot(in.local, in.local);
    float alpha = min(0.995f, in.color.a * exp(-0.5 * power));
    if (power > 9.0 || alpha < (1.0 / 255.0)) discard_fragment();
    return float4(in.color.rgb * alpha, alpha);
}
