/*
Copyright (c) 2021, NVIDIA CORPORATION. All rights reserved.

NVIDIA CORPORATION and its licensors retain all intellectual property
and proprietary rights in and to this software, related documentation
and any modifications thereto. Any use, reproduction, disclosure or
distribution of this software and related documentation without an express
license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "_Poisson.hlsl"

NRI_RESOURCE( SamplerState, gNearestClamp, s, 0, 0 );
NRI_RESOURCE( SamplerState, gNearestMirror, s, 1, 0 );
NRI_RESOURCE( SamplerState, gLinearClamp, s, 2, 0 );
NRI_RESOURCE( SamplerState, gLinearMirror, s, 3, 0 );

// Constants

#define NRD_RADIANCE_COMPRESSION_MODE_NONE                      0
#define NRD_RADIANCE_COMPRESSION_MODE_MODERATE                  1
#define NRD_RADIANCE_COMPRESSION_MODE_LESS_MID_ROUGHNESS        2
#define NRD_RADIANCE_COMPRESSION_MODE_BETTER_LOW_ROUGHNESS      3
#define NRD_RADIANCE_COMPRESSION_MODE_SIMPLER_LOW_ROUGHNESS     4

#define NRD_FRAME                                               0
#define NRD_PIXEL                                               1
#define NRD_RANDOM                                              2 // for experiments only

#define NRD_INF                                                 1e6

//==================================================================================================================
// DEFAULT SETTINGS (can be modified)
//==================================================================================================================

#ifndef NRD_USE_QUADRATIC_DISTRIBUTION
    #define NRD_USE_QUADRATIC_DISTRIBUTION                      0 // bool
#endif

#ifndef NRD_USE_CATROM_RESAMPLING
    #define NRD_USE_CATROM_RESAMPLING                           1 // bool
#endif

#ifndef NRD_BILATERAL_WEIGHT_VIEWZ_SENSITIVITY
    #define NRD_BILATERAL_WEIGHT_VIEWZ_SENSITIVITY              500.0 // w = 1 / (1 + this * z)
#endif

#ifndef NRD_BILATERAL_WEIGHT_CUTOFF
    #define NRD_BILATERAL_WEIGHT_CUTOFF                         0.05 // normalized %
#endif

#ifndef NRD_CATROM_SHARPNESS
    #define NRD_CATROM_SHARPNESS                                0.5 // [0; 1], 0.5 matches Catmull-Rom
#endif

#ifndef NRD_RADIANCE_COMPRESSION_MODE
    #define NRD_RADIANCE_COMPRESSION_MODE                       NRD_RADIANCE_COMPRESSION_MODE_BETTER_LOW_ROUGHNESS
#endif

//==================================================================================================================

// CTA & preloading

#ifdef NRD_CTA_8X8
    #define GROUP_X                                             8
    #define GROUP_Y                                             8
#else
    #define GROUP_X                                             16
    #define GROUP_Y                                             16
#endif

#ifdef NRD_USE_BORDER_2
    #define BORDER                                              2
#else
    #define BORDER                                              1
#endif

#define BUFFER_X                                                ( GROUP_X + BORDER * 2 )
#define BUFFER_Y                                                ( GROUP_Y + BORDER * 2 )
#define RENAMED_GROUP_Y                                         ( ( GROUP_X * GROUP_Y ) / BUFFER_X )

// TODO: ignore out-of-screen texels or use "NearestClamp"
#define PRELOAD_INTO_SMEM \
    float linearId = ( threadIndex + 0.5 ) / BUFFER_X; \
    int2 newId = int2( frac( linearId ) * BUFFER_X, linearId ); \
    int2 groupBase = pixelPos - threadId - BORDER; \
    if( newId.y < RENAMED_GROUP_Y ) \
        Preload( newId, groupBase + newId ); \
    newId.y += RENAMED_GROUP_Y; \
    if( newId.y < BUFFER_Y ) \
        Preload( newId, groupBase + newId ); \
    GroupMemoryBarrierWithGroupSync( )

// Misc

// sigma = standard deviation, variance = sigma ^ 2
#define GetStdDev( m1, m2 ) sqrt( abs( m2 - m1 * m1 ) ) // sqrt( max( m2 - m1 * m1, 0.0 ) )

// To avoid biasing compression for high roughness should be avoided. The compression function must be monotonic for full roughness range
float GetColorCompressionExposure( float linearRoughness )
{
    // http://fooplot.com/#W3sidHlwZSI6MCwiZXEiOiIwLjUvKDErNTAqeCkiLCJjb2xvciI6IiNGNzBBMEEifSx7InR5cGUiOjAsImVxIjoiMC41KigxLXgpLygxKzYwKngpIiwiY29sb3IiOiIjMkJGRjAwIn0seyJ0eXBlIjowLCJlcSI6IjAuNSooMS14KS8oMSsxMDAwKngqeCkrKDEteF4wLjUpKjAuMDMiLCJjb2xvciI6IiMwMDU1RkYifSx7InR5cGUiOjAsImVxIjoiMC42KigxLXgqeCkvKDErNDAwKngqeCkiLCJjb2xvciI6IiMwMDAwMDAifSx7InR5cGUiOjEwMDAsIndpbmRvdyI6WyIwIiwiMSIsIjAiLCIxIl0sInNpemUiOlsyOTUwLDk1MF19XQ--

    // Moderate compression
    #if( NRD_RADIANCE_COMPRESSION_MODE == NRD_RADIANCE_COMPRESSION_MODE_MODERATE )
        return 0.5 / ( 1.0 + 50.0 * linearRoughness );
    // Less compression for mid-high roughness
    #elif( NRD_RADIANCE_COMPRESSION_MODE == NRD_RADIANCE_COMPRESSION_MODE_LESS_MID_ROUGHNESS )
        return 0.5 * ( 1.0 - linearRoughness ) / ( 1.0 + 60.0 * linearRoughness );
    // Close to the previous one, but offers more compression for low roughness
    #elif( NRD_RADIANCE_COMPRESSION_MODE == NRD_RADIANCE_COMPRESSION_MODE_BETTER_LOW_ROUGHNESS )
        return 0.5 * ( 1.0 - linearRoughness ) / ( 1.0 + 1000.0 * linearRoughness * linearRoughness ) + ( 1.0 - sqrt( saturate( linearRoughness ) ) ) * 0.03;
    // A modification of the preious one ( simpler )
    #elif( NRD_RADIANCE_COMPRESSION_MODE == NRD_RADIANCE_COMPRESSION_MODE_SIMPLER_LOW_ROUGHNESS )
        return 0.6 * ( 1.0 - linearRoughness * linearRoughness ) / ( 1.0 + 400.0 * linearRoughness * linearRoughness );
    // No compression
    #else
        return 0;
    #endif
}

float PixelRadiusToWorld( float unproject, float isOrtho, float pixelRadius, float viewZ )
{
     return pixelRadius * unproject * lerp( viewZ, 1.0, abs( isOrtho ) );
}

float4 GetBlurKernelRotation( compiletime const uint mode, uint2 pixelPos, float4 baseRotator, uint frameIndex )
{
    float4 rotator = float4( 1, 0, 0, 1 );

    if( mode == NRD_PIXEL )
    {
        float angle = STL::Sequence::Bayer4x4( pixelPos, frameIndex );
        rotator = STL::Geometry::GetRotator( angle * STL::Math::Pi( 2.0 ) );
    }
    else if( mode == NRD_RANDOM )
    {
        STL::Rng::Initialize( pixelPos, frameIndex );
        float4 rnd = STL::Rng::GetFloat4( );
        rotator = STL::Geometry::GetRotator( rnd.z * STL::Math::Pi( 2.0 ) );
        rotator *= 1.0 + ( rnd.w * 2.0 - 1.0 ) * 0.5;
    }

    rotator = STL::Geometry::CombineRotators( baseRotator, rotator );

    return rotator;
}

float IsInScreen( float2 uv )
{
    return float( all( saturate( uv ) == uv ) );
}

float IsInScreen2x2( float2 uv, float2 screenSize ) // TODO: ideally needs to be per pixel
{
    float2 t = 1.5 / screenSize;

    return uv.x > t.x && uv.x < 1.0 - t.x && uv.y > t.y && uv.y < 1.0 - t.y;
}

float2 ApplyCheckerboard( inout float2 uv, uint mode, uint counter, float2 screenSize, float2 invScreenSize, uint frameIndex )
{
    int2 uvi = int2( uv * screenSize );
    bool hasData = STL::Sequence::CheckerBoard( uvi, frameIndex ) == mode;
    if( !hasData )
        uvi.y += ( ( counter & 0x1 ) == 0 ) ? -1 : 1;
    uv = ( float2( uvi ) + 0.5 ) * invScreenSize;

    return float2( uv.x * 0.5, uv.y );
}

// Kernel

float2 GetKernelSampleCoordinates( float4x4 mViewToClip, float3 offset, float3 Xv, float3 Tv, float3 Bv, float4 rotator = float4( 1, 0, 0, 1 ) )
{
    #if( NRD_USE_QUADRATIC_DISTRIBUTION == 1 )
        offset.xy *= offset.z;
    #endif

    // We can't rotate T and B instead, because T is skewed
    offset.xy = STL::Geometry::RotateVector( rotator, offset.xy );

    float3 p = Xv + Tv * offset.x + Bv * offset.y;
    float3 clip = STL::Geometry::ProjectiveTransform( mViewToClip, p ).xyw;
    clip.xy /= clip.z; // TODO: clip.z can't be 0, but what if a point is behind the near plane?
    clip.y = -clip.y;
    float2 uv = clip.xy * 0.5 + 0.5;

    return uv;
}

// Weight parameters

float2 GetGeometryWeightParams( float planeDistSensitivity, float3 Xv, float3 Nv, float scale = 1.0 )
{
    float a = scale * planeDistSensitivity / ( 1.0 + Xv.z );
    float b = -dot( Nv, Xv ) * a;

    return float2( a, b );
}

// Weights

#define _ComputeWeight( p, value ) STL::Math::SmoothStep01( 1.0 - abs( value * p.x + p.y ) )

float GetGeometryWeight( float2 params0, float3 n0, float3 p )
{
    float d = dot( n0, p );

    return _ComputeWeight( params0, d );
}

#define _GetBilateralWeight( z, zc, cutoff ) \
    z = abs( z - zc ) * rcp( min( abs( z ), abs( zc ) ) + 0.001 ); \
    z = rcp( 1.0 + NRD_BILATERAL_WEIGHT_VIEWZ_SENSITIVITY * z ) * step( z, cutoff );

float GetBilateralWeight( float z, float zc, float cutoff = NRD_BILATERAL_WEIGHT_CUTOFF )
{ _GetBilateralWeight( z, zc, cutoff ); return z; }

float2 GetBilateralWeight( float2 z, float zc, float cutoff = NRD_BILATERAL_WEIGHT_CUTOFF )
{ _GetBilateralWeight( z, zc, cutoff ); return z; }

float4 GetBilateralWeight( float4 z, float zc, float cutoff = NRD_BILATERAL_WEIGHT_CUTOFF )
{ _GetBilateralWeight( z, zc, cutoff ); return z; }

// Upsampling

float4 BicubicFilterNoCorners( Texture2D<float4> tex, SamplerState samp, float2 samplePos, float2 invTextureSize, float sharpness = NRD_CATROM_SHARPNESS )
{
    #if( NRD_USE_CATROM_RESAMPLING == 1 )
        float2 centerPos = floor( samplePos - 0.5 ) + 0.5;
        float2 f = samplePos - centerPos;
        float2 f2 = f * f;
        float2 f3 = f * f2;
        float2 w0 = -sharpness * f3 + 2.0 * sharpness * f2 - sharpness * f;
        float2 w1 = ( 2.0 - sharpness ) * f3 - ( 3.0 - sharpness ) * f2 + 1.0;
        float2 w2 = -( 2.0 - sharpness ) * f3 + ( 3.0 - 2.0 * sharpness ) * f2 + sharpness * f;
        float2 w3 = sharpness * f3 - sharpness * f2;
        float2 wl2 = w1 + w2;
        float2 tc2 = invTextureSize * ( centerPos + w2 * STL::Math::PositiveRcp( wl2 ) );
        float2 tc0 = invTextureSize * ( centerPos - 1.0 );
        float2 tc3 = invTextureSize * ( centerPos + 2.0 );

        float w = wl2.x * w0.y;
        float4 color = tex.SampleLevel( samp, float2( tc2.x, tc0.y ), 0 ) * w;
        float sum = w;

        w = w0.x  * wl2.y;
        color += tex.SampleLevel( samp, float2( tc0.x, tc2.y ), 0 ) * w;
        sum += w;

        w = wl2.x * wl2.y;
        color += tex.SampleLevel( samp, float2( tc2.x, tc2.y ), 0 ) * w;
        sum += w;

        w = w3.x  * wl2.y;
        color += tex.SampleLevel( samp, float2( tc3.x, tc2.y ), 0 ) * w;
        sum += w;

        w = wl2.x * w3.y;
        color += tex.SampleLevel( samp, float2( tc2.x, tc3.y ), 0 ) * w;
        sum += w;

        color *= STL::Math::PositiveRcp( sum );

        return max( color, 0.0 ); // Won't work for YCoCg
    #else
        return tex.SampleLevel( samp, samplePos * invTextureSize, 0 );
    #endif
}

float BicubicFilterNoCorners( Texture2D<float> tex, SamplerState samp, float2 samplePos, float2 invTextureSize, float sharpness = NRD_CATROM_SHARPNESS )
{
    #if( NRD_USE_CATROM_RESAMPLING == 1 )
        float2 centerPos = floor( samplePos - 0.5 ) + 0.5;
        float2 f = samplePos - centerPos;
        float2 f2 = f * f;
        float2 f3 = f * f2;
        float2 w0 = -sharpness * f3 + 2.0 * sharpness * f2 - sharpness * f;
        float2 w1 = ( 2.0 - sharpness ) * f3 - ( 3.0 - sharpness ) * f2 + 1.0;
        float2 w2 = -( 2.0 - sharpness ) * f3 + ( 3.0 - 2.0 * sharpness ) * f2 + sharpness * f;
        float2 w3 = sharpness * f3 - sharpness * f2;
        float2 wl2 = w1 + w2;
        float2 tc2 = invTextureSize * ( centerPos + w2 * STL::Math::PositiveRcp( wl2 ) );
        float2 tc0 = invTextureSize * ( centerPos - 1.0 );
        float2 tc3 = invTextureSize * ( centerPos + 2.0 );

        float w = wl2.x * w0.y;
        float color = tex.SampleLevel( samp, float2( tc2.x, tc0.y ), 0 ) * w;
        float sum = w;

        w = w0.x  * wl2.y;
        color += tex.SampleLevel( samp, float2( tc0.x, tc2.y ), 0 ) * w;
        sum += w;

        w = wl2.x * wl2.y;
        color += tex.SampleLevel( samp, float2( tc2.x, tc2.y ), 0 ) * w;
        sum += w;

        w = w3.x  * wl2.y;
        color += tex.SampleLevel( samp, float2( tc3.x, tc2.y ), 0 ) * w;
        sum += w;

        w = wl2.x * w3.y;
        color += tex.SampleLevel( samp, float2( tc2.x, tc3.y ), 0 ) * w;
        sum += w;

        color *= STL::Math::PositiveRcp( sum );

        return max( color, 0.0 ); // Won't work for YCoCg
    #else
        return tex.SampleLevel( samp, samplePos * invTextureSize, 0 );
    #endif
}
