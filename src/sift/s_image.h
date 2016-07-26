#pragma once

#include <stdint.h>
#include "c_util_img.h"
#include "plane_2d.h"
#include "sift_conf.h"

namespace popart {

struct Image
{
    /** Create a device-sided buffer of the given dimensions */
    Image( size_t w, size_t h );

    ~Image( );

    /** Load a new image, copy to device and upscale */
    void load( const Config& conf, const imgStream& inp );

    void debug_out( );
    void test_last_error( const char* file, int line );

    inline Plane2D_float& getUpscaledImage() {
        return _upscaled_image_d;
    }

    inline cudaTextureObject_t& getUpscaledTexture() {
        return _upscaled_image_tex;
    }

private:
    void upscale_v5( const Config& conf, cudaTextureObject_t & tex );

    int _w;
    int _h;

    /* 2D plane holding input image on host for uploading
     * to device. */
    Plane2D_uint8 _input_image_h;

    /* 2D plane holding input image on device for upscaling */
    Plane2D_uint8 _input_image_d;

    /** 2D plane holding upscaled image, allocated on device */
    Plane2D_float _upscaled_image_d;

    /* Texture information for input image on device */
    cudaTextureObject_t _input_image_tex;
    cudaTextureDesc     _input_image_texDesc;
    cudaResourceDesc    _input_image_resDesc;

    /* Texture information for upscaled image on device */
    cudaTextureObject_t _upscaled_image_tex;
    cudaTextureDesc     _upscaled_image_texDesc;
    cudaResourceDesc    _upscaled_image_resDesc;
};

} // namespace popart
