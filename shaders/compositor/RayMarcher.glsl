#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
layout(rgba16f, binding = 0, set = 0) uniform image2D screen_tex;
layout(set = 1, binding = 0) uniform sampler2D depth_tex;
layout(set = 2, binding = 0) uniform sampler3D noise_tex;

#define SUN_DIR   normalize(params.sun_time.xyz)
#define WORLD_TIME params.sun_time.w
#define CLOUD_MIN params.cloud_heights.x
#define CLOUD_MAX params.cloud_heights.y

layout(push_constant, std430) uniform Params {
    mat4 camera_transform;
    vec4 sun_time;            //  4  (xyz = sun_dir, w = time)
    vec2 cloud_heights;       //  2  (x = base, y = top)    
    vec2 screen_size;
    float fov_rad;
    float inv_proj_2w;
    float inv_proj_3w;
} params;

float Hash(float n){ return fract(sin(n)*43758.5453); }

vec3 WorldRay(vec2 pix)
{
    // Step 1: Create Normalized Device Coordinates (NDC) from pixel coordinates.
    // We flip pix.y because in a compute shader gl_GlobalInvocationID.y starts from the top,
    // but we want a standard coordinate system where Y points "up".
    vec2 flipped_pix = vec2(pix.x, params.screen_size.y - pix.y);
    
    // Step 2: Calculate UVs that correctly handle the aspect ratio.
    // The result 'uv' will be in the range [-aspect, aspect] for x and [-1, 1] for y.
    // Dividing by screen_size.y is correct because it scales the horizontal component
    // by the aspect ratio (sx/sy) while keeping the vertical component in the [-1, 1] range.
    vec2 uv = (2.0 * flipped_pix - params.screen_size) / params.screen_size.y;

    // Step 3: Get camera orientation vectors from the camera's transform matrix.
    vec3 ro        = params.camera_transform[3].xyz;
    vec3 cam_right = params.camera_transform[0].xyz;
    vec3 cam_up    = params.camera_transform[1].xyz;    // <-- Use the standard up-vector, NOT negated.
    vec3 cam_fwd   = -params.camera_transform[2].xyz;   // The camera looks down its local -Z axis.

    // Step 4: Calculate the focal length from the vertical FOV.
    float focal    = 1.0 / tan(params.fov_rad * 0.5);

    // Step 5: Construct the final world-space ray direction and normalize it.
    vec3 rd        = normalize(cam_fwd * focal + cam_right * uv.x + cam_up * uv.y);
    
    return rd;
}

bool SlabIntersect(vec3 ro, vec3 rd, out float t_enter, out float t_exit)
{
    // If the ray is nearly parallel to the cloud slab (the source of the black circle)
    if (abs(rd.y) < 0.0001) {
        // If the camera is not inside the cloud layer, it can never hit
        if (ro.y < CLOUD_MIN || ro.y > CLOUD_MAX) {
            t_enter = 0.0;
            t_exit = -1.0; // Negative exit signifies no intersection
            return false;
        }
        // If the camera is inside the slab, the intersection starts immediately
        // and extends for a very long distance.
        else {
            t_enter = 0.0;
            t_exit = 1e9; // A very large number
            return true;
        }
    }

    float h1 = (CLOUD_MIN - ro.y) / rd.y;
    float h2 = (CLOUD_MAX - ro.y) / rd.y;
    t_enter  = max(0.0, min(h1, h2));
    t_exit   = max(h1, h2);
    return t_exit > t_enter;
}

/* simple FBM in a 3-D tile - returns [0,1] */
float Density(vec3 wpos)
{
    float time = params.sun_time.w * 0.04;
    vec3 n = wpos * 0.001;                    // scale controls cloud size
    n.x+=time*0.11;
    n.y+=time;
    n.z+=time*0.3;
    float d  = texture(noise_tex, n).r;
    d = mix(d, texture(noise_tex, n*2.0).r*0.5, 0.5);
    d = mix(d, texture(noise_tex, n*4.0).r*0.25,0.25);
    return clamp(d,0.0,1.0);
}

/* single-scattering lighting (cheap but convincing) */
float PhaseHG(float cosTheta, float g){ return (1.0-g*g)/pow(1.0+g*g-2.0*g*cosTheta,1.5); }

/* -------------------------------------------------------------------------- */
void main()
{
    uvec2 pix = gl_GlobalInvocationID.xy;
    if(pix.x >= uint(params.screen_size.x) || pix.y >= uint(params.screen_size.y)) return;

    vec2 uv = vec2(pix) / params.screen_size;
    float rawDepth = texelFetch(depth_tex, ivec2(pix), 0).r;
    float camZ     = 1.0 / (rawDepth * params.inv_proj_2w + params.inv_proj_3w);   // metres in view space
    float maxT     = (rawDepth < 1.0) ? camZ : 1e9;                      // stop at scene geometry

    vec3 ro = params.camera_transform[3].xyz;
    vec3 rd = WorldRay(pix);

    /* ray / cloud-slab intersection -------------------------------------------------------- */
    float t0, t1;
    if(!SlabIntersect(ro, rd, t0, t1) || t0 > maxT) return;              // no clouds on this ray

    t1 = min(t1, maxT);                                                  // clip by geometry

    /* volumetric integration -------------------------------------------------------------- */
    const int   STEPS = 300;
    float step = (t1-t0)/float(STEPS);
    vec3  sumColor = vec3(0.0);
    float trans    = 1.0;                                                // accumulated transmittance
    vec3 sun_dir = params.sun_time.xyz;
    float steps = 0;
    for(int i=0;i<STEPS && trans>0.01;i++)
    {
        steps += 1.0;
        float t = t0 + (float(i)+Hash(float(i)+params.sun_time.w))*step;            // jitter
        vec3  pos = ro + rd*t;
        float dens = Density(pos);
        dens = smoothstep(0.3, 0.8, dens);                               // threshold & thickening
        if(dens<=0.001) continue;

        /* cheap light probe – march 4 steps towards the sun */
        float light = 1.0;
        vec3 lpos = pos;
        const int LIGHT_STEPS = 4;
        const float lStep = 100.0;
        for(int j=0;j<LIGHT_STEPS && light>0.05;j++){
            lpos += sun_dir * lStep;
            light *= 1.0 - Density(lpos)*0.6;
        }

        float phase = PhaseHG(dot(rd, sun_dir), 0.65);
        vec3  sampleCol = vec3(1.0,0.95,0.9)*light*phase*5.0;            // tweak to taste

        float absorb = dens*step*0.02;                                   // 0.02 → thickness
        float a      = 1.0 - exp(-absorb);                               // alpha of this slice
        sampleCol   *= a;

        sumColor += sampleCol * trans;
        trans    *= 1.0 - a;
        if(trans<0.01) break;
    }

    /* -------------------------------------------------------------------------- */
    vec4 prev = imageLoad(screen_tex, ivec2(pix));
    vec3 outc = mix(sumColor, prev.rgb, trans);   // under-composite
    imageStore(screen_tex, ivec2(pix), vec4(outc,1.0));
}