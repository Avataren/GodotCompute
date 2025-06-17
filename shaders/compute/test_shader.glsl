#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba8) uniform writeonly image2D out_image;

layout(push_constant, std430) uniform Params {
    mat4 camera_transform;
    vec2 texture_size;
    float fov_rad;
} params;

// --- SDFs and Raymarching ---

const float REPETITION_SIZE = 2.5; 

float sdBox(vec3 p, vec3 b) {
    vec3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float sdMengerSponge(vec3 p, int iterations) {
    float d = sdBox(p, vec3(1.0));
    float s = 1.0;
    for (int i = 0; i < iterations; i++) {
        vec3 a = mod(p * s, 2.0) - 1.0;
        s *= 3.0;
        vec3 r = abs(1.0 - 3.0 * abs(a));
        float da = max(r.x, r.y);
        float db = max(r.y, r.z);
        float dc = max(r.z, r.x);
        float c = (min(da, min(db, dc)) - 1.0) / s;
        d = max(d, c);
    }
    return d;
}

// <<< MODIFIED: This function now describes an infinite field of sponges.
float sceneSDF_Low(vec3 p) {
    // Fold the world space coordinate 'p' into a single, centered cell.
    vec3 q = p;// mod(p, REPETITION_SIZE) - 0.5 * REPETITION_SIZE;
    // Then, run the Menger Sponge SDF on that single cell's coordinate.
    return sdMengerSponge(q, 6);
}

// <<< MODIFIED: Same logic for the high-detail version.
float sceneSDF_High(vec3 p) {
    // Fold the world space coordinate 'p' into a single, centered cell.
    vec3 q = p;//mod(p, REPETITION_SIZE) - 0.5 * REPETITION_SIZE;
    // Then, run the Menger Sponge SDF on that single cell's coordinate.
    return sdMengerSponge(q, 7);
}


vec3 getNormal(vec3 p) {
    const float eps = 0.0005;
    vec2 e = vec2(eps, 0);
    vec3 n = vec3(
        sceneSDF_Low(p + e.xyy) - sceneSDF_Low(p - e.xyy),
        sceneSDF_Low(p + e.yxy) - sceneSDF_Low(p - e.yxy),
        sceneSDF_Low(p + e.yyx) - sceneSDF_Low(p - e.yyx)
    );
    return normalize(n);
}

float raymarch(vec3 ro, vec3 rd) {
    float dO = 0.0;
    for (int i = 0; i < 200; i++) {
        vec3 p = ro + rd * dO;
        float dS = sceneSDF_High(p);
        dO += dS * 0.9;
        if (dS < (0.0001 * dO) || dO > 100.0) break;
    }
    return dO;
}

// --- Lighting Functions (Unchanged) ---
float getSoftShadow(vec3 ro, vec3 rd, float k) {
    float res = 1.0;
    float t = 0.01;
    for (int i = 0; i < 50; i++) {
        float h = sceneSDF_Low(ro + rd * t);
        if (h < 0.001) return 0.0;
        res = min(res, k * h / t);
        t += h;
        if (t > 50.0) break;
    }
    return clamp(res, 0.0, 1.0);
}

float getAmbientOcclusion(vec3 p, vec3 nor) {
    float occ = 0.0;
    float sca = 1.0;
    for (int i = 0; i < 16; i++) {
        float h = 0.01 + 0.12 * float(i) / 15.0;
        float d = sceneSDF_Low(p + h * nor);
        occ += (h - d) * sca;
        sca *= 0.85;
        if (occ > 1.0) break;
    }
    return clamp(1.0 - 2.0 * occ, 0.0, 1.0);
}


void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    if (coord.x >= int(params.texture_size.x) || coord.y >= int(params.texture_size.y)) return;

    vec2 uv = (2.0 * vec2(coord.x, params.texture_size.y - float(coord.y)) - params.texture_size) / params.texture_size.y;
    
    vec3 ro = params.camera_transform[3].xyz;
    vec3 cam_right = params.camera_transform[0].xyz;
    vec3 cam_up    = params.camera_transform[1].xyz;
    vec3 cam_fwd   = -params.camera_transform[2].xyz;

    float focal_length = 1.0 / tan(params.fov_rad / 2.0);

    vec3 rd_unnormalized = cam_fwd * focal_length + cam_right * uv.x + cam_up * uv.y;
    vec3 rd = normalize(rd_unnormalized);

    float d = raymarch(ro, rd);
    
    vec3 col = vec3(0.0, 0.0, 0.0);

    if (d < 100.0) {
        vec3 p = ro + rd * d;
        vec3 n = getNormal(p);
        vec3 v = -rd;

        // --- Material & Light Properties ---
        vec3 materialColor = vec3(0.85); 

        vec3 light1_pos = vec3(4.0, 5.0, -3.0);
        vec3 light1_col = vec3(1.0, 0.95, 0.85) * 1.0; 
        
        vec3 light2_pos = vec3(-3.0, -2.0, -4.0);
        vec3 light2_col = vec3(0.6, 0.8, 1.0) * 0.4;

        vec3 ambient = vec3(0.1, 0.15, 0.2);
        
        // --- Pre-calculate AO, Shadows, and Fresnel ---
        float ao = getAmbientOcclusion(p, n);
        float fresnel = pow(1.0 - clamp(dot(n, v), 0.0, 1.0), 5.0);
        vec3 light1_dir = normalize(light1_pos - p);
        float shadow1 = getSoftShadow(p + n * 0.002, light1_dir, 16.0);
        vec3 light2_dir = normalize(light2_pos - p);
        float shadow2 = getSoftShadow(p + n * 0.002, light2_dir, 16.0);
        
        // --- Lighting Calculation (RESTRUCTURED) ---
        vec3 outgoingLight = ambient * ao;
        float diff1 = max(0.0, dot(n, light1_dir));
        outgoingLight += diff1 * light1_col * shadow1;
        float diff2 = max(0.0, dot(n, light2_dir));
        outgoingLight += diff2 * light2_col * shadow2;

        col = materialColor * outgoingLight;

        vec3 h1 = normalize(light1_dir + v);
        float spec1 = pow(max(0.0, dot(n, h1)), 64.0);
        col += spec1 * light1_col * shadow1;

        vec3 h2 = normalize(light2_dir + v);
        float spec2 = pow(max(0.0, dot(n, h2)), 64.0);
        col += spec2 * light2_col * shadow2;
        
        col += vec3(0.2) * fresnel * ao;
    }
    
    imageStore(out_image, coord, vec4(col, 1.0));
}