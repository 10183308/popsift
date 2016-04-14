#include "s_image.h"
#include "clamp.h"
#include "assist.h"

#include <iostream>
#include <sstream>
#include <map>

#undef FIND_BLOCK_SIZE

using namespace std;

namespace popart {

__global__
void p_upscale_5( Plane2D_float dst, cudaTextureObject_t src )
{
    int idx  = blockIdx.x * blockDim.x + threadIdx.x;
    int idy  = blockIdx.y * blockDim.y + threadIdx.y;
    if( idx >= dst.getCols() ) return;
    if( idy >= dst.getRows() ) return;
    // const float src_x = (float(idx))/float(dst.getCols());
    // const float src_y = (float(idy))/float(dst.getRows());
    const float src_x = (float(idx)+0.5f)/float(dst.getCols());
    const float src_y = (float(idy)+0.5f)/float(dst.getRows());
    // const float src_x = (float(idx)-0.5f)/float(dst.getCols());
    // const float src_y = (float(idy)-0.5f)/float(dst.getRows());
    float d = tex2D<float>( src, src_x, src_y );
    dst.ptr(idy)[idx] = d * 255.0f;
}

#ifdef FIND_BLOCK_SIZE
int condition[][2] = {
    // { 1, 1 }, { 8, 1 },
    { 32, 1 },
    { 64, 1 },
    { 128, 1 }, // this is the winner for GeForce GT 650M, CC 3.0 (MAC)
    { 256, 1 },
    { 1024, 1 },
    // { 1, 2 }, { 8, 2 },
    { 32, 2 }, { 64, 2 }, { 128, 2 }, { 256, 2 }, { 512, 2 },
    { 8, 8 }, { 32, 8 }, { 64, 8 }, { 128, 8 },
    { 32, 32 },
    { 0, 0 } };
__host__
void Image::upscale_v5( cudaTextureObject_t & tex )
{
    std::map<float,string> logtimes;

    cudaEvent_t start;
    cudaEvent_t stop;
    cudaEventCreate( &start );
    cudaEventCreate( &stop );
    for( int cond=0; condition[cond][0]!=0; cond++ ) {
        int blockx = condition[cond][0];
        int blocky = condition[cond][1];

        int loops  = 100;

        cudaEventRecord( start, 0 );
        for( int i=0; i<loops; i++ ) {
            int gridx = grid_divide( this->_upscaled_image_d.getCols(), blockx );
            int gridy = grid_divide( this->_upscaled_image_d.getRows(), blocky );
            dim3 grid( gridx, gridy );
            dim3 block( blockx, blocky );

            p_upscale_5<<<grid,block>>> ( this->_upscaled_image_d, tex );
        }
        cudaEventRecord( stop, 0 );
        cudaDeviceSynchronize( );
        float diff;
        cudaEventElapsedTime( &diff, start, stop );

        std::pair<float,string> datum;
        ostringstream ostr;
        ostr << "(" << blockx << ", " << blocky << ")";
        datum.first  = diff/loops;
        datum.second = ostr.str();
        logtimes.insert( datum );
    }

    std::map<float,string>::const_iterator it  = logtimes.begin();
    std::map<float,string>::const_iterator end = logtimes.end();
    for( ; it != end; it++ ) {
        const std::pair<float,string>& g = *it;
        cerr << "avg times: " << g.first
             << ": " << g.second
             << endl;
    }
    cudaEventDestroy( start );
    cudaEventDestroy( stop );
}
#else // not FIND_BLOCK_SIZE
__host__
void Image::upscale_v5( cudaTextureObject_t & tex )
{
    dim3 block( 64, 2 );
    int gridx = grid_divide( this->_upscaled_image_d.getCols(), block.x );
    int gridy = grid_divide( this->_upscaled_image_d.getRows(), block.y );
    dim3 grid( gridx, gridy );

    p_upscale_5
        <<<grid,block>>>
        ( this->_upscaled_image_d,
          tex );

    test_last_error( __FILE__,  __LINE__ );
}
#endif // not FIND_BLOCK_SIZE

} // namespace popart

