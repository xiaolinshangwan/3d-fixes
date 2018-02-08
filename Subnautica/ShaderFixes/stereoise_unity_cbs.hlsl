// Not positive if this will apply in the general case - Unity is known to only
// update matrices in the constant buffers that are actually being used.

#include "unity_cbuffers.hlsl"

cbuffer UnityPerCamera : register(b11)
{
	struct UnityPerCamera MonoPerCamera;
}
RWStructuredBuffer<struct UnityPerCamera> StereoPerCamera : register(u0);

#if 0
// Disabled UnityPerDraw redirect for now - unecessary for SSR, and a per-draw
// fixup would be expensive
//
// Can use b12 safely because this is not a vertex or domain shader, so the
// 3D Vision driver won't touch it.
cbuffer UnityPerDraw : register(b12)
{
	struct UnityPerDraw MonoPerDraw;
}
RWStructuredBuffer<struct UnityPerDraw> StereoPerDraw : register(u1);
#endif

cbuffer UnityPerFrame : register(b13)
{
	struct UnityPerFrame MonoPerFrame;
}
RWStructuredBuffer<struct UnityPerFrame> StereoPerFrame : register(u2);

#if 0
// Disabled $Globals redirect, since that really harms the fps.

// Shader specific globals buffers:
struct SSR_PS_Globals
{
	float4 pad1[7];

	/*  7 */ row_major matrix _UweCameraToVolumeMatrix;

	float4 pad2[18];

	/* 29 */ row_major matrix _WorldToClipMatrix;
};

cbuffer SSR_PS_Globals : register(b10)
{
	struct SSR_PS_Globals MonoPSGlobals;
}

RWStructuredBuffer<struct SSR_PS_Globals> StereoPSGlobals : register(u3);
#endif

#include "matrix.hlsl"

Texture1D<float4> IniParams : register(t120);
Texture2D<float4> StereoParams : register(t125);

[numthreads(1, 1, 1)]
void main(uint3 tid: SV_DispatchThreadID)
{
	// What we are essentially trying to do is remove the inverse
	// projection matrix and replace it with a modified version that has a
	// stereo correction embedded, but in a manner that works regardless of
	// the matrix we are modifying is a pure inverse projection matrix
	// (which we could do much simpler than this), or a composite inverse
	// VP or inverse MVP matrix.
	//
	// Mathematically we can remove an inverse projection matrix from the
	// start of an arbitrary composite by multiplying by its forwards, then
	// we can multiply by the new stereo corrected projection matrix
	// (called 1/SP): 1/SP * P * 1/P * 1/V * 1/M
	//
	// But matrix maths allows us to do the 1/SP * P multiplication first,
	// so if we can find that matrix then we would have a single matrix
	// that we can multiply any inverse MVP, inverse VP or inverse P matrix
	// by to inject a stereo correction.

	float4 s = StereoParams.Load(0);
	float sep = s.x, conv = s.y;

	// For Unity we are deriving the stereo injection matrix from first
	// principles. We start by creating a pair of projection matrices with
	// built in stereo corrections:

	matrix stereo_projection = MonoPerFrame.glstate_matrix_projection;
	stereo_projection._m20 = -sep; // EXPLAIN ME: Why negative when UE4 is positive?
	stereo_projection._m30 = -sep * conv;

	// FIXME: If we have UnityPerFrameRare, we can get the inverse projection matrix from there
	// FIXME: Use inverse optimised for projection matrices
	matrix inv_projection = inverse(MonoPerFrame.glstate_matrix_projection);

	// Calculate the forwards stereo injection matrices, by multiplying the
	// inverse projection matrix by the forwards stereo projection matrix:
	matrix stereo_injection_f = mul(inv_projection, stereo_projection);
	// Get the inverse stereo injection matrices:
	//matrix stereo_injection_i = inverse(stereo_injection_f);

	// Note: This may replace the driver correction, so be sure to --disable-driver-stereo-cb
	StereoPerFrame[0].unity_MatrixVP = mul(MonoPerFrame.unity_MatrixVP, stereo_injection_f);

	// unity_MatrixInvV may be the identity matrix, so inverse it ourselves:
	matrix inv_view = inverse(MonoPerFrame.unity_MatrixV);

	// Calculate the camera offset in various spaces to correct reflections:
	float4 cam_adj_clip = float4(-sep * conv, 0, 0, 0);
	float3 cam_adj_view = mul(cam_adj_clip, inv_projection).xyz;
	float3 cam_adj_world = mul(float4(cam_adj_view, 0), inv_view).xyz;

	StereoPerCamera[0]._WorldSpaceCameraPos = MonoPerCamera._WorldSpaceCameraPos - cam_adj_world;

	// Adjusting the view matrix doesn't seem to make a difference, but
	// potentially could for some effects.
#undef ADJUST_VIEW_MATRIX
#ifdef ADJUST_VIEW_MATRIX
	matrix view_injection_f = translation_matrix(cam_adj_view);
	matrix view_injection_i = translation_matrix(-cam_adj_view);

	StereoPerFrame[0].unity_MatrixV = mul(MonoPerFrame.unity_MatrixV, view_injection_f);

	// If we adjust the view matrix, we must remove the camera adjustment
	// from the projection matrix:
	matrix stereo_view_projection = stereo_projection;
	stereo_view_projection._m30 = 0;
	StereoPerFrame[0].glstate_matrix_projection = stereo_view_projection;
#else
	// If we are not adjusting the view matrix, the projection includes
	// both parts of the stereo correction:
	StereoPerFrame[0].glstate_matrix_projection = stereo_projection;
#endif

#if 0
	// No difference to SSR that I can see, at least on the menu.
	// Disabled $Globals redirect, since that really harms the fps.
	StereoPSGlobals[0]._UweCameraToVolumeMatrix = mul(view_injection_i, MonoPSGlobals._UweCameraToVolumeMatrix);
	StereoPSGlobals[0]._WorldToClipMatrix = mul(MonoPSGlobals._WorldToClipMatrix, stereo_injection_f);
#endif
}
