// what the glasses of the cab (mat_rain_windscreen, mat_bugs_windscreen) see through themselves: the scene of this frame copied with
// its mipmaps just before they're drawn (SCENE_COPY_TEX: the opaque scene, the translucent world, the rain falling). the drops bend
// it and the haze blurs it right in the glass, as the materials of glass with refraction do in other games; nothing of the
// post-processing (the taa, the motion blur, dlss) knows about the glasses. scene_ubs.rain_state.w holds the levels of the copy, 0
// when there's none in this frame (the views without the cab, the first frame): the glasses fall back to the history of the
// reflections then (the last frame) and to no haze
#ifndef WINDSCREEN_VIEW_GLSL
#define WINDSCREEN_VIEW_GLSL

layout(binding = SCENE_COPY_TEX) uniform sampler2D scene_copy;

const float WSV_RADIUS    = 0.014;   // the largest radius of the haze, a share of the height of the screen
const int   WSV_TAPS      = 16;
const float WSV_HAZE_LIGHT_CAP = 12.0;   // the most a light adds to the haze around it (brightness, scene units)
const float WSV_INSIDE    = 0.3;     // metres beyond the glass nearer than which the copy is the inside of the cab
// the lights in the drops: a drop is a wide-angle lens and lights up near a bright light (signals, lamps, headlights)
const float WSV_LIGHT_GAIN     = 1.0;   // brightness of the lights in the drops (0 = off)
const float WSV_LIGHT_CAP      = 8.0;   // the most the glow adds to a drop (brightness, scene units)
const float WSV_LIGHT_MIN_LUM  = 1.0;   // a light: the fine level at least this bright (scene units) above the place around it ...
const float WSV_LIGHT_CONTRAST = 3.0;   // ... and this many times brighter than it
const float WSV_LIGHT_FINE     = 3.5;   // mip levels: the drop's own neighbourhood (~11 px), a wider one (~32 px), the place around
const float WSV_LIGHT_MID      = 5.0;
const float WSV_LIGHT_WIDE     = 7.0;
const float WSV_LIGHT_MID_SHARE = 0.5;  // how much the lights a little further away count

// the copy of the scene is there in this frame
bool wsvCopy()
{
	return rain_state.w >= 1.0;
}

// the place of a pixel of the screen (gl_FragCoord) in the copy
vec2 wsvUV(vec2 pixel)
{
	return pixel / vec2(textureSize(scene_copy, 0));
}

// a colour of the picture made safe: a very bright light can be an infinity in the half float image (and a broken pixel a nan)
vec3 wsvSafe(vec3 c)
{
	return any(isnan(c)) ? vec3(0.0) : clamp(c, vec3(0.0), vec3(65000.0));
}

vec3 wsvFetch(vec2 uv, float lod)
{
	return wsvSafe(textureLod(scene_copy, uv, clamp(lod, 0.0, rain_state.w - 1.0)).rgb);
}

float wsvLum(vec3 c)
{
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

// the weight of a colour in an average that a single very bright pixel must not take over
float wsvKaris(vec3 c)
{
	return 1.0 / (1.0 + wsvLum(c));
}

// the copy at Uv is the inside of the cab: much nearer than the glass (its dashboard, frame and roof aren't seen through it)
bool wsvInside(vec2 uv)
{
	ivec2 size  = textureSize(scene_depth, 0);
	float depth = texelFetch(scene_depth, clamp(ivec2(uv * vec2(size)), ivec2(0), size - 1), 0).r;
	return (depth > 0.0) && (projection[3][2] / depth < -f_pos.z + WSV_INSIDE);
}

// the scene at Uv blurred by the haze of the glass, for a haze of BlurAmt (> 0): a disc of taps, rotated per pixel, of the scene
// behind the glass only (not of the cab)
vec3 wsvHaze(vec2 uv, float blurAmt)
{
	vec2  texel  = 1.0 / vec2(textureSize(scene_copy, 0));
	float aspect = texel.x / texel.y;   // height / width
	vec3  sharp  = wsvFetch(uv, 0.0);
	float radius = WSV_RADIUS * blurAmt;
	// interleaved gradient noise rotates the disc per pixel: no banding
	float rot = 6.2831853 * fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
	float wsum   = wsvKaris(sharp);
	vec3  sum    = sharp * wsum;
	float psum_w = 1.0;             // the plain average beside it
	vec3  psum   = sharp;
	for (int i = 0; i < WSV_TAPS; ++i)
	{
		float r = sqrt((float(i) + 0.5) / float(WSV_TAPS));
		float a = float(i) * 2.3999632 + rot;   // golden angle
		vec2  o = vec2(cos(a), sin(a)) * r * radius;
		o.x *= aspect;
		vec2  tap = uv + o;
		// weighed by 1 / (1 + brightness) (karis average): a very bright light isn't smeared over the whole disc
		float w = wsvInside(tap) ? 0.0 : 1.0;
		vec3  c = wsvFetch(tap, 0.0);
		psum   += c * w;
		psum_w += w;
		w   *= wsvKaris(c);
		sum  += c * w;
		wsum += w;
	}
	// the karis average alone almost wipes small bright lights out of the haze: the light the plain average has above it comes
	// back, up to WSV_HAZE_LIGHT_CAP
	vec3  blurred = sum / wsum;
	vec3  extra   = max(psum / psum_w - blurred, vec3(0.0));
	float extraL  = wsvLum(extra);
	return blurred + extra * min(1.0, WSV_HAZE_LIGHT_CAP / max(extraL, 1e-4));
}

// the copy around Uv as blurred as its mip level Lod, but round: a level of the mipmaps is a grid of squares, and a light read from
// it alone lit the drops in a square around it. a ring of taps of the finer level gives the same blur without the squares
vec3 wsvRound(vec2 uv, float lod)
{
	float level = min(lod, rain_state.w - 1.0);
	float finer = max(level - 1.0, 0.0);
	vec2  pixel = 1.0 / vec2(textureSize(scene_copy, 0));
	float radius = 0.6 * exp2(level);
	vec3  sum = wsvFetch(uv, finer) * 0.2;
	for (int i = 0; i < 8; ++i)
	{
		float a = (float(i) + 0.5) * 0.7853982;
		sum += wsvFetch(uv + vec2(cos(a), sin(a)) * radius * pixel, finer) * 0.06;
		sum += wsvFetch(uv + vec2(cos(a + 0.3927), sin(a + 0.3927)) * (2.0 * radius) * pixel, finer) * 0.04;
	}
	return sum;
}

vec3 wsvLightExcess(vec2 uv, float lod, vec3 wide)
{
	vec3 excess = max(wsvRound(uv, lod) - wide * WSV_LIGHT_CONTRAST, vec3(0.0));
	// no threshold with an edge: a light dims away from it; full from twice WSV_LIGHT_MIN_LUM above the place around
	return excess * clamp(wsvLum(excess) / (2.0 * WSV_LIGHT_MIN_LUM), 0.0, 1.0);
}

// the lights near the place Uv of the copy which a drop there picks up
vec3 wsvLightGlow(vec2 uv)
{
	if (WSV_LIGHT_GAIN <= 0.0)
		return vec3(0.0);
	vec3  wide = wsvRound(uv, WSV_LIGHT_WIDE);
	// the near light in full, the one a little further away fading with it squared
	vec3  mid  = wsvLightExcess(uv, WSV_LIGHT_MID, wide);
	float midF = clamp(wsvLum(mid) / (2.0 * WSV_LIGHT_MIN_LUM), 0.0, 1.0);
	vec3  glow = (wsvLightExcess(uv, WSV_LIGHT_FINE, wide) + WSV_LIGHT_MID_SHARE * mid * midF) * WSV_LIGHT_GAIN;
	// a light close by is kept to the brightness of one light
	return glow * min(1.0, WSV_LIGHT_CAP / max(wsvLum(glow), 1e-4));
}

#endif
