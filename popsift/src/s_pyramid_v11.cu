#include "s_pyramid.h"

#include "gauss_filter.h"
#include "clamp.h"
#include "debug_macros.h"
#include "assist.h"
#include <cuda_runtime.h>

/*************************************************************
 * V11: device side
 *************************************************************/

#define V11_EDGE_LEN    32
#define V11_RANGE    4 // RANGES from 1 to 8 are possible
#define V11_GAUSS_BASE   ( GAUSS_ONE_SIDE_RANGE - V11_RANGE )
#define V11_FILTERSIZE   ( V11_RANGE + 1        + V11_RANGE )
#define V11_LEVELS       _levels

namespace popart {

__global__
void filter_gauss_horiz_v11( Plane2D_float src_data,
                             Plane2D_float dst_data )
{

    __shared__ float loaddata[V11_EDGE_LEN][V11_RANGE + V11_EDGE_LEN + V11_RANGE];

    const int src_w = src_data.getWidth();
    const int src_h = src_data.getHeight();

    int block_x = blockIdx.x * V11_EDGE_LEN;
    int block_y = blockIdx.y * V11_EDGE_LEN;
    int idx     = threadIdx.x;
    int idy     = threadIdx.y;
    for( ; idx < V11_EDGE_LEN+2*V11_RANGE; idx += V11_EDGE_LEN) {
        int read_x = clamp( block_x + idx - V11_RANGE, src_w );
        int read_y = clamp( block_y + idy,            src_h );
        loaddata[idy][idx] = src_data.ptr(read_y)[read_x];
    }
    __syncthreads();

    float g;
    float val;
    float out = 0;

    for( int offset = V11_RANGE; offset>0; offset-- ) {
        g  = popart::d_gauss_filter[GAUSS_ONE_SIDE_RANGE - offset];

        idx = threadIdx.x - offset;
        val = loaddata[threadIdx.y][idx+V11_RANGE];
        out += ( val * g );

        idx = threadIdx.x + offset;
        val = loaddata[threadIdx.y][idx+V11_RANGE];
        out += ( val * g );
    }

    g  = popart::d_gauss_filter[GAUSS_ONE_SIDE_RANGE];
    idx = threadIdx.x;
    val = loaddata[threadIdx.y][idx+V11_RANGE];
    out += ( val * g );

    idx = block_x+threadIdx.x;
    idy = block_y+threadIdx.y;
    if( idx >= src_w ) return;
    if( idy >= src_h ) return;

    dst_data.ptr(idy)[idx] = out;
}

__global__
void filter_gauss_horiz_v11( cudaTextureObject_t src_data,
                             Plane2D_float       dst_data )
{
    int block_x = blockIdx.x * blockDim.x;
    int block_y = blockIdx.y * blockDim.y;
    int idx;
    int idy     = threadIdx.y;

    float g;
    float val;
    float out = 0;

    for( int offset = V11_RANGE; offset>0; offset-- ) {
        g  = popart::d_gauss_filter[GAUSS_ONE_SIDE_RANGE - offset];

        idx = threadIdx.x - offset;
        val = tex2D<float>( src_data, block_x + idx, block_y + idy );
        out += ( val * g );

        idx = threadIdx.x + offset;
        val = tex2D<float>( src_data, block_x + idx, block_y + idy );
        out += ( val * g );
    }

    g  = popart::d_gauss_filter[GAUSS_ONE_SIDE_RANGE];
    idx = threadIdx.x;
    val = tex2D<float>( src_data, block_x + idx, block_y + idy );
    out += ( val * g );

    idx = block_x+threadIdx.x;
    idy = block_y+threadIdx.y;
    const int dst_w = dst_data.getWidth();
    const int dst_h = dst_data.getHeight();
    if( idx >= dst_w ) return;
    if( idy >= dst_h ) return;

    dst_data.ptr(idy)[idx] = out;
}

__global__
void filter_gauss_horiz_v11_by_2( cudaTextureObject_t src_data,
                                  Plane2D_float       dst_data )
{
    int block_x = blockIdx.x * blockDim.x;
    int block_y = blockIdx.y * blockDim.y;
    int idx;
    int idy     = threadIdx.y;

    float g;
    float val;
    float out = 0;

    for( int offset = V11_RANGE; offset>0; offset-- ) {
        g  = popart::d_gauss_filter[GAUSS_ONE_SIDE_RANGE - offset];

        idx = threadIdx.x - offset;
        val = tex2D<float>( src_data, 2 * ( block_x + idx ), 2 * ( block_y + idy ) );
        out += ( val * g );

        idx = threadIdx.x + offset;
        val = tex2D<float>( src_data, 2 * ( block_x + idx ), 2 * ( block_y + idy ) );
        out += ( val * g );
    }

    g  = popart::d_gauss_filter[GAUSS_ONE_SIDE_RANGE];
    idx = threadIdx.x;
    val = tex2D<float>( src_data, 2 * ( block_x + idx ), 2 * ( block_y + idy ) );
    out += ( val * g );

    idx = block_x+threadIdx.x;
    idy = block_y+threadIdx.y;
    const int dst_w = dst_data.getWidth();
    const int dst_h = dst_data.getHeight();
    if( idx >= dst_w ) return;
    if( idy >= dst_h ) return;

    dst_data.ptr(idy)[idx] = out;
}


__device__ inline
float filter_gauss_vert_v11_sub( cudaTextureObject_t src_data,
                                 Plane2D_float       dst_data )
{
    int block_x = blockIdx.x * blockDim.x;
    int block_y = blockIdx.y * blockDim.y;
    int idx     = threadIdx.x;
    int idy;

    float g;
    float val;
    float out = 0;

    for( int offset = V11_RANGE; offset>0; offset-- ) {
        g  = popart::d_gauss_filter[GAUSS_ONE_SIDE_RANGE - offset];

        idy = threadIdx.y - offset;
        val = tex2D<float>( src_data, block_x + idx, block_y + idy );
        out += ( val * g );

        idy = threadIdx.y + offset;
        val = tex2D<float>( src_data, block_x + idx, block_y + idy );
        out += ( val * g );
    }

    g  = popart::d_gauss_filter[GAUSS_ONE_SIDE_RANGE];
    idy = threadIdx.y;
    val = tex2D<float>( src_data, block_x + idx, block_y + idy );
    out += ( val * g );

    idx = block_x+threadIdx.x;
    idy = block_y+threadIdx.y;
    const int dst_w = dst_data.getWidth();
    const int dst_h = dst_data.getHeight();
    if( idx >= dst_w ) return 0;
    if( idy >= dst_h ) return 0;

    dst_data.ptr(idy)[idx] = out;

    return out;
}

__global__
void filter_gauss_vert_v11( cudaTextureObject_t src_data,
                            Plane2D_float       dst_data )
{
    filter_gauss_vert_v11_sub( src_data, dst_data );
}

__global__
void filter_gauss_vert_v11_dog( cudaTextureObject_t src_data,
                                Plane2D_float       dst_data,
                                cudaTextureObject_t top_data,
                                Plane2D_float       dog_data )
{
    float b = filter_gauss_vert_v11_sub( src_data, dst_data );

    const int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const int idy = blockIdx.y * blockDim.y + threadIdx.y;

    float a;
    a = tex2D<float>( top_data, idx, idy );
    a = fabs( a - b );

    const int width  = dog_data.getWidth();
    const int height = dog_data.getHeight();
    if( idx >= width ) return;
    if( idy >= height ) return;

    dog_data.ptr(idy)[idx] = a;
}

/*************************************************************
 * V11: host side
 *************************************************************/
__host__
void Pyramid::build_v11( Image* base )
{
#if (PYRAMID_PRINT_DEBUG==1)
    cerr << "Entering " << __FUNCTION__ << " with base image "  << endl
         << "    type size         : " << base->type_size << endl
         << "    aligned byte size : " << base->a_width << "x" << base->a_height << endl
         << "    pitch size        : " << base->pitch << "x" << base->a_height << endl
         << "    original byte size: " << base->u_width << "x" << base->u_height << endl
         << "    aligned pix size  : " << base->a_width/base->type_size << "x" << base->a_height << endl
         << "    original pix size : " << base->u_width/base->type_size << "x" << base->u_height << endl;
#endif // (PYRAMID_PRINT_DEBUG==1)

    for( int octave=0; octave<_num_octaves; octave++ ) {
        for( int level=0; level<V11_LEVELS; level++ ) {
#if 0
        cerr << "Configuration for octave " << octave << endl
             << "  Horiz: layer size: "
             << _octaves[octave].getData(level).getWidth() << "x" << _octaves[octave].getData(level).getHeight() << endl
             << "  Vert: layer size: "
             << _octaves[octave].getIntermediateData().getWidth() << "x" << _octaves[octave].getIntermediateData().getHeight() << endl
             << "  grid: "
             << "(" << grid.x << "," << grid.y << "," << grid.z << ")"
             << " block: "
             << "(" << block.x << "," << block.y << "," << block.z << ")" << endl;
#endif

            const int width  = _octaves[octave].getData(0).getWidth();
            const int height = _octaves[octave].getData(0).getHeight();

            dim3 h_block( 64, 2 );
            dim3 h_grid;
            h_grid.x = grid_divide( width,  h_block.x );
            h_grid.y = grid_divide( height, h_block.y );

            dim3 v_block( 64, 2 );
            dim3 v_grid;
            v_grid.x = grid_divide( width,  v_block.x );
            v_grid.y = grid_divide( height, v_block.y );

            dim3 d_block( 32, 1 );
            dim3 d_grid;
            d_grid.x = grid_divide( width,  d_block.x );
            d_grid.y = grid_divide( height, d_block.y );

            if( level == 0 ) {
                if( octave == 0 ) {
                    dim3 block;
                    block.x = V11_EDGE_LEN;
                    block.y = V11_EDGE_LEN;

                    dim3 grid;
                    const int width  = _octaves[octave].getData(0).getWidth();
                    const int height = _octaves[octave].getData(0).getHeight();
                    grid.x = grid_divide( width,  V11_EDGE_LEN );
                    grid.y = grid_divide( height, V11_EDGE_LEN );

                    filter_gauss_horiz_v11
                        <<<grid,block>>>
                        ( base->array,
                          _octaves[octave].getIntermediateData( ) );
                } else {
                    filter_gauss_horiz_v11_by_2
                        <<<h_grid,h_block>>>
                        ( _octaves[octave-1]._data_tex[ V11_LEVELS-3 ],
                          _octaves[octave].getIntermediateData( ) );
                }
            } else {
                filter_gauss_horiz_v11
                    <<<h_grid,h_block>>>
                    ( _octaves[octave]._data_tex[ level-1 ],
                      _octaves[octave].getIntermediateData( ) );
            }

            if( level == 0 ) {
                filter_gauss_vert_v11
                    <<<v_grid,v_block>>>
                    ( _octaves[octave]._interm_data_tex,
                      _octaves[octave].getData( level ) );
            } else {
                filter_gauss_vert_v11_dog
                    <<<d_grid,d_block>>>
                    ( _octaves[octave]._interm_data_tex,
                      _octaves[octave].getData( level ),
                      _octaves[octave]._data_tex[level-1],
                      _octaves[octave].getDogData( level-1 ) );
            }
        }
    }
    cudaDeviceSynchronize( );
    cudaError_t err = cudaGetLastError();
    POP_CUDA_FATAL_TEST( err, "filter_gauss_horiz_v11 failed: " );
}

} // namespace popart

