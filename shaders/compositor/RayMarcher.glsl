#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba16f, binding = 0, set = 0) uniform image2D screen_tex;
layout(binding = 0, set = 1) uniform sampler2D depth_tex;

layout(push_constant, std430) uniform Params {
    mat4 camera_transform;
    vec2 screen_size;
    float fov_rad;
    float inv_proj_2w;
    float inv_proj_3w;
} params;

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    vec2 size = params.screen_size;
    vec2 uv = pixel / size;

    if (pixel.x >= size.x || pixel.y >= size.y) return;

    float depth = texture(depth_tex, uv).r;
    float linear_depth = 1. / (depth * params.inv_proj_2w + params.inv_proj_3w);
    linear_depth = clamp(linear_depth / 50, 0.0, 1.0);

    vec4 color = imageLoad(screen_tex, pixel);
    color.rgb = vec3(linear_depth);
    imageStore(screen_tex, pixel, color);
}