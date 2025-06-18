#[compute]
#version 450
#extension GL_EXT_nonuniform_qualifier           : enable
#extension GL_EXT_samplerless_texture_functions : enable

/*────────────────────────────────────────────────────────────────────────────*/
/* Godot 4.4 – volumetric clouds with silver rim + correctly dark undersides */
/*────────────────────────────────────────────────────────────────────────────*/

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

/* ── bindings ───────────────────────────────────────────────────────────── */
layout(rgba16f, binding = 0, set = 0) uniform image2D  screen_tex;
layout(binding   = 0, set = 1)          uniform sampler2D  depth_tex;
layout(binding   = 0, set = 2)          uniform sampler3D  noise_tex;
layout(binding   = 0, set = 3)          uniform samplerCube sky_cubemap;

/* ── push constants (from Godot) ─────────────────────────────────────────── */
layout(push_constant, std430) uniform Params {
    mat4  camera_transform;
    vec4  sun_time;              /* xyz = sun dir (unit), w = seconds     */
    vec2  cloud_heights;         /* x = base, y = top (metres)            */
    vec2  screen_size;
    float fov_rad;
    float inv_proj_2w;
    float inv_proj_3w;
} params;

/* ── tunables ───────────────────────────────────────────────────────────── */
#define SUN_ENERGY        20.0
#define AMBIENT_STRENGTH   0.20

#define WIND_DIR          vec3(1.0,0.0,0.0)
#define WIND_SPEED        45.0
#define EVOLUTION_RATE    5.75
#define NOISE_SCALE       0.0001
#define SCATTERING_COEFF  0.05  /* Controls brightness AND opacity. Higher = brighter, denser clouds. */
#define ABSORPTION_COEFF  0.001  /* Light lost in the medium. Higher = darker, "stormier" clouds. */

#define UNDERSIDE_FADE_HEIGHT 0.1  /* 0-1, how far up the darkness extends */
#define RIM_LIGHT_INTENSITY   10.0  /* How bright the silver lining is     */
#define AMBIENT_MULTIPLIER    0.65  /* Control ambient light contribution */

/* rim-light */
#define RIM_SAMPLE_DIST   60.0
#define RIM_FADE_START     0.15
#define RIM_FADE_END       0.55

/* underside attenuation */
#define UNDER_MIN_BRIGHT   0.12   /* 0 = totally black, 1 = no dim         */
#define OVERBURDEN_STEPS        4  /* upward probes                         */
#define OVERBURDEN_STEP_DIST   12.5/* metres per probe                      */
#define OVER_TAU_SCALE        0.7  /* scale factor for “mass” → dimming     */

/* shorthand */
#define SUN_DIR       normalize(params.sun_time.xyz)
#define WORLD_TIME    params.sun_time.w
#define CLOUD_MIN     params.cloud_heights.x
#define CLOUD_MAX     params.cloud_heights.y

/* ── helpers ───────────────────────────────────────────────────────────────*/
float Hash(float n){ return fract(sin(n)*43758.5453); }

float HorizonMask(float y){ return smoothstep(0.00,0.04,y); }
float DistanceMask(float t){
    const float S=1.0e4,E=1.0e5;
    return 1.0-clamp((t-S)/(E-S),0.0,1.0);
}

vec3 WorldRay(vec2 pix){
    vec2 flip = vec2(pix.x, params.screen_size.y-pix.y);
    vec2 uv = (2.0*flip-params.screen_size)/params.screen_size.y;

    vec3 r = params.camera_transform[0].xyz;
    vec3 u = params.camera_transform[1].xyz;
    vec3 f =-params.camera_transform[2].xyz;
    float focal = 1.0/tan(params.fov_rad*0.5);
    return normalize(f*focal + r*uv.x + u*uv.y);
}

bool SlabIntersect(vec3 ro, vec3 rd, out float t0,out float t1){
    if(abs(rd.y)<0.0001){
        if(ro.y<CLOUD_MIN||ro.y>CLOUD_MAX){t1=-1.0;return false;}
        t0=0.0; t1=1e9; return true;
    }
    float h1=(CLOUD_MIN-ro.y)/rd.y;
    float h2=(CLOUD_MAX-ro.y)/rd.y;
    t0=max(0.0,min(h1,h2));
    t1=max(h1,h2);
    return t1>t0;
}

float Density(vec3 p){
    vec3 n=p*NOISE_SCALE+WIND_DIR*WIND_SPEED*WORLD_TIME*NOISE_SCALE;
    n.z+=WORLD_TIME*EVOLUTION_RATE*NOISE_SCALE;
    float d = texture(noise_tex,n).r;
    d=mix(d,texture(noise_tex,n*2.0).r*0.5,0.5);
    d=mix(d,texture(noise_tex,n*4.0).r*0.25,0.25);
    return clamp(d,0.0,1.0);
}

float PhaseHG(float c,float g){
    return (1.0-g*g)/pow(max(1.0+g*g-2.0*g*c,1e-3),1.5);
}
float PhaseHG_Safe(float c,float g){
    c=clamp(c,-0.999,0.999);
    return PhaseHG(c,g);
}

/* ── kernel ─────────────────────────────────────────────────────────────── */
void main(){
    uvec2 pix=gl_GlobalInvocationID.xy;
    if(pix.x>=uint(params.screen_size.x)||pix.y>=uint(params.screen_size.y)) return;

    float raw=texelFetch(depth_tex,ivec2(pix),0).r;
    float camZ=1.0/(raw*params.inv_proj_2w+params.inv_proj_3w);
    float maxT=(raw>1e-5)?camZ:1e6;

    vec3 ro=params.camera_transform[3].xyz;
    vec3 rd=WorldRay(vec2(pix));

    float t0,t1;
    if(!SlabIntersect(ro,rd,t0,t1)||t0>maxT||(t1-t0)<5.0) return;
    t1=min(t1,maxT);

    const int STEPS=96;
    float step=(t1-t0)/float(STEPS);
    vec3 sumCol=vec3(0.0);
    float trans=1.0;

    const float EXTINCTION_COEFF = SCATTERING_COEFF + ABSORPTION_COEFF;

    for(int i=0;i<STEPS&&trans>0.01;++i){
        float jitter=Hash(float(i)+WORLD_TIME);
        float t=t0+(float(i)+jitter)*step;
        vec3 pos=ro+rd*t;

        float dens=Density(pos);
        dens=smoothstep(0.30,1.10,dens);
        dens*=HorizonMask(rd.y*0.05)*DistanceMask(t);
        if(dens<=0.001) continue;

        /* Rim light calculation */
        float densB=Density(pos+SUN_DIR*RIM_SAMPLE_DIST);
        float rim=clamp(dens-densB,0.0,1.0);
        rim=smoothstep(RIM_FADE_START,RIM_FADE_END,rim);

        /* Underside dimming based on world height */
        float height_norm = (pos.y - CLOUD_MIN) / (CLOUD_MAX - CLOUD_MIN);
        float undersideDim = mix(UNDER_MIN_BRIGHT, 1.0, 
                                 smoothstep(0.0, UNDERSIDE_FADE_HEIGHT, height_norm));

        /* Cone shadow (light transmittance from sun) */
        float light=1.0;
        vec3 lpos=pos;
        for(int j=0;j<4&&light>0.01;++j){
            lpos+=SUN_DIR*50.0;
            light*=1.0-Density(lpos)*0.01;
        }

        //++[ UNIFIED SCATTERING & ABSORPTION MODEL ]++

        // 1. Calculate incoming light at the sample point.
        float cosT = dot(rd, SUN_DIR);
        float basePhase = mix(PhaseHG_Safe(cosT, 0.85), PhaseHG_Safe(cosT, -0.25), 0.45);
        vec3 directLight = vec3(1.0,0.97,0.92) * (light * basePhase * SUN_ENERGY);

        float aoc = exp(-dens*8.0);
        vec3 ambientLight = textureLod(sky_cubemap, rd, 0.0).rgb * (AMBIENT_STRENGTH * aoc * dens * AMBIENT_MULTIPLIER);
        
        // 2. Combine and attenuate for underside darkness.
        vec3 totalIncomingLight = (directLight + ambientLight) * undersideDim;

        // 3. The scattered color is the incoming light multiplied by the SCATTERING coefficient.
        //    This is the crucial step that links brightness to the physical properties.
        vec3 scatteredColor = totalIncomingLight * SCATTERING_COEFF;

        // 4. Add the artistic rim light. It's also scaled by scattering to keep it consistent.
        vec3 rimLight = vec3(1.0,0.97,0.92) * rim * RIM_LIGHT_INTENSITY * light * SCATTERING_COEFF;
        
        vec3 col = scatteredColor + rimLight;

        /* composite slice */
        // The opacity of the slice now depends on the total extinction.
        float absorb = dens * step * EXTINCTION_COEFF;
        
        // We can add a color shift due to absorption for extra detail (e.g., sunset clouds)
        // For now, we assume uniform absorption. A more advanced shader could make this color-dependent.
        vec3 attenuation = exp(-vec3(absorb));
        
        float a = 1.0 - attenuation.r; // Use one channel for alpha calculation
        
        sumCol += col * a * trans;
        trans *= (1.0 - a);

        step*=mix(1.0,0.5,dens);
    }

    vec3 prev=imageLoad(screen_tex,ivec2(pix)).rgb;
    vec3 outc=mix(sumCol,prev,trans);
    imageStore(screen_tex,ivec2(pix),vec4(outc,1.0));
}