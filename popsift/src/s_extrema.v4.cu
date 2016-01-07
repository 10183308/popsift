#include "s_extrema.v4.h"
#include "debug_macros.hpp"

#define DEBUG_MODE 1

#define DEBUG_

/*************************************************************
 * V5: device side
 *************************************************************/
__device__ __constant__ float d_sigma0;
__device__ __constant__ float d_sigma_k;

__device__
inline void extremum_cmp_v4( float val, float f, uint32_t& gt, uint32_t& lt, uint32_t mask )
{
    gt |= ( ( val > f ) ? mask : 0 );
    lt |= ( ( val < f ) ? mask : 0 );
}

__device__
inline uint32_t extrema_count_v4( uint32_t indicator, ExtremaMgmt* mgmt )
{
    uint32_t mask = __ballot( indicator ); // bitfield of warps with results

    uint32_t ct = __popc( mask );          // horizontal reduce

    uint32_t leader = __ffs(mask) - 1;     // the highest thread id with indicator==true

    uint32_t write_index;
    if( threadIdx.x == leader ) {
        // atomicAdd returns the old value, we consider this the based
        // index for this thread's write operation
        write_index = atomicAdd( &mgmt->counter, ct );
    }
    // broadcast from leader thread to all threads in warp
    write_index = __shfl( write_index, leader );

    // this thread's offset: count only bits below the bit of the own
    // thread index; this provides the 0 result and every result up to ct
    write_index += __popc( mask & ((1 << threadIdx.x) - 1) );

    return write_index;
}

__device__
inline bool is_extremum_v4( float* dog[3],
                            uint32_t y0, uint32_t y1, uint32_t y2,
                            uint32_t x0, uint32_t x1, uint32_t x2 )
{
    // somewhat annoying: to read center val, x1==31 requires a second 128-byte read
    // so: read left value first (one 128-byte read)
    //     read right value after (30 floats from cache, 2 from next 128-byte read)
    //     finally, read center value (from cache)
    uint32_t gt = 0;
    uint32_t lt = 0;

    float val0 = dog[1][y1+x0];
    float val2 = dog[1][y1+x2];
    float val  = dog[1][y1+x1];

    // bit indeces for neighbours:
    //     7 0 1    0x80 0x01 0x02
    //     6   2 -> 0x40      0x04
    //     5 4 3    0x20 0x10 0x08
    // upper layer << 24 ; own layer << 16 ; lower layer << 8
    // 1st group: left and right neigbhour
    extremum_cmp_v4( val, val0, gt, lt, 0x00400000 ); // ( 0x01<<6 ) << 16
    extremum_cmp_v4( val, val2, gt, lt, 0x00040000 ); // ( 0x01<<2 ) << 16

    if( ( gt != 0x00440000 ) && ( lt != 0x00440000 ) ) return false;

    // 2nd group: requires a total of 8 128-byte reads
    extremum_cmp_v4( val, dog[1][y0+x0], gt, lt, 0x00800000 ); // ( 0x01<<7 ) << 16
    extremum_cmp_v4( val, dog[1][y2+x0], gt, lt, 0x00200000 ); // ( 0x01<<5 ) << 16
    extremum_cmp_v4( val, dog[0][y0+x0], gt, lt, 0x80000000 ); // ( 0x01<<6 ) << 24
    extremum_cmp_v4( val, dog[0][y2+x0], gt, lt, 0x40000000 ); // ( 0x01<<6 ) << 24
    extremum_cmp_v4( val, dog[0][y1+x0], gt, lt, 0x20000000 ); // ( 0x01<<6 ) << 24
    extremum_cmp_v4( val, dog[2][y0+x0], gt, lt, 0x00008000 ); // ( 0x01<<6 ) <<  8
    extremum_cmp_v4( val, dog[2][y1+x0], gt, lt, 0x00004000 ); // ( 0x01<<6 ) <<  8
    extremum_cmp_v4( val, dog[2][y2+x0], gt, lt, 0x00002000 ); // ( 0x01<<6 ) <<  8

    if( ( gt != 0xe0e4e000 ) && ( lt != 0xe0e4e000 ) ) return false;

    // 3rd group: remaining 2 cache misses in own layer
    extremum_cmp_v4( val, dog[1][y0+x1], gt, lt, 0x00010000 ); // ( 0x01<<0 ) << 16
    extremum_cmp_v4( val, dog[1][y0+x2], gt, lt, 0x00020000 ); // ( 0x01<<1 ) << 16
    extremum_cmp_v4( val, dog[1][y2+x1], gt, lt, 0x00100000 ); // ( 0x01<<4 ) << 16
    extremum_cmp_v4( val, dog[1][y2+x2], gt, lt, 0x00080000 ); // ( 0x01<<3 ) << 16

    if( ( gt != 0xe0ffe000 ) && ( lt != 0xe0ffe000 ) ) return false;

    // 4th group: 3 cache misses higher layer
    extremum_cmp_v4( val, dog[0][y0+x1], gt, lt, 0x01000000 ); // ( 0x01<<0 ) << 24
    extremum_cmp_v4( val, dog[0][y0+x2], gt, lt, 0x02000000 ); // ( 0x01<<1 ) << 24
    extremum_cmp_v4( val, dog[0][y1+x1], gt, lt, 0x00000004 ); // ( 0x01<<2 )
    extremum_cmp_v4( val, dog[0][y1+x2], gt, lt, 0x04000000 ); // ( 0x01<<2 ) << 24
    extremum_cmp_v4( val, dog[0][y2+x1], gt, lt, 0x10000000 ); // ( 0x01<<4 ) << 24
    extremum_cmp_v4( val, dog[0][y2+x2], gt, lt, 0x08000000 ); // ( 0x01<<3 ) << 24

    if( ( gt != 0xffffe004 ) && ( lt != 0xffffe004 ) ) return false;

    // 5th group: 3 cache misses lower layer
    extremum_cmp_v4( val, dog[2][y0+x1], gt, lt, 0x00000100 ); // ( 0x01<<0 ) <<  8
    extremum_cmp_v4( val, dog[2][y0+x2], gt, lt, 0x00000200 ); // ( 0x01<<1 ) <<  8
    extremum_cmp_v4( val, dog[2][y1+x1], gt, lt, 0x00000001 ); // ( 0x01<<0 )
    extremum_cmp_v4( val, dog[2][y1+x2], gt, lt, 0x00000400 ); // ( 0x01<<2 ) <<  8
    extremum_cmp_v4( val, dog[2][y2+x1], gt, lt, 0x00001000 ); // ( 0x01<<4 ) <<  8
    extremum_cmp_v4( val, dog[2][y2+x2], gt, lt, 0x00000800 ); // ( 0x01<<3 ) <<  8

    if( ( gt != 0xffffff05 ) && ( lt != 0xffffff05 ) ) return false;
    
    return true;
}

__device__ bool solve( float A[3][3], float b[3] )
{
    // Gauss elimination
    for( int j = 0 ; j < 3 ; j++ ) {
            // look for leading pivot
            float maxa    = 0;
            float maxabsa = 0;
            int   maxi    = -1;
            for( int i = j ; i < 3 ; i++ ) {
                float a    = A[j][i];
                float absa = fabs( a );
                if ( absa > maxabsa ) {
                    maxa    = a;
                    maxabsa = absa;
                    maxi    = i;
                }
            }

            // singular?
            if( maxabsa < 1e-15 ) {
                return false;
            }

            int i = maxi;

            // swap j-th row with i-th row and
            // normalize j-th row
            for(int jj = j ; jj < 3 ; ++jj) {
                float tmp = A[jj][j];
                A[jj][j]  = A[jj][i];
                A[jj][i]  = tmp;
                A[jj][j] /= maxa;
            }
            float tmp = b[j];
            b[j]  = b[i];
            b[i]  = tmp;
            b[j] /= maxa;

            // elimination
            for(int ii = j+1 ; ii < 3 ; ++ii) {
                float x = A[j][ii];
                for( int jj = j ; jj < 3 ; jj++ ) {
                    A[jj][ii] -= x * A[jj][j];
                }
                b[ii] -= x * b[j] ;
            }
    }

    // backward substitution
    for( int i = 2 ; i > 0 ; i-- ) {
            float x = b[i] ;
            for( int ii = i-1 ; ii >= 0 ; ii-- ) {
                b[ii] -= x * A[i][ii];
            }
    }
    return true;
}

__device__ bool solve2( float i[3][3], float b[3] )
{
    float det0b = - i[1][2] * i[1][2];
    float det0a =   i[1][1] * i[2][2];
    float det0 = det0b + det0a;

    float det1b = - i[0][1] * i[2][2];
    float det1a =   i[1][2] * i[0][2];
    float det1 = det1b + det1a;

    float det2b = - i[1][1] * i[0][2];
    float det2a =   i[0][1] * i[1][2];
    float det2 = det2b + det2a;

    float det3b = - i[0][2] * i[0][2];
    float det3a =   i[0][0] * i[2][2];
    float det3 = det3b + det3a;

    float det4b = - i[0][0] * i[1][2];
    float det4a =   i[0][1] * i[0][2];
    float det4 = det4b + det4a;

    float det5b = - i[0][1] * i[0][1];
    float det5a =   i[0][0] * i[1][1];
    float det5 = det5b + det5a;

    float det;
    det  = ( i[0][0] * det0 );
    det += ( i[0][1] * det1 );
    det += ( i[0][2] * det2 );

    // float rsd = 1.0 / det;
    float rsd = __frcp_rn( det );

    i[0][0] = det0 * rsd;
    i[1][0] = det1 * rsd;
    i[2][0] = det2 * rsd;
    i[1][1] = det3 * rsd;
    i[1][2] = det4 * rsd;
    i[2][2] = det5 * rsd;
    i[0][1] = i[1][0];
    i[0][2] = i[2][0];
    i[2][1] = i[1][2];

    float vout[3];
    vout[0] = vout[1] = vout[2] = 0;
    for (   int y = 0;  y < 3;  y ++ ) {
        for ( int x = 0;  x < 3;  x ++ ) {
            vout[y] += ( i[y][x] * b[x] );
        }
    }
    b[0] = vout[0];
    b[1] = vout[1];
    b[2] = vout[2];

    return true;
}

__device__
bool find_extrema_in_dog_v4_bemap( float*             dog[3], // level-1, level, level+1
                                   float              edge_limit,
                                   float              threshold,
                                   const uint32_t     width,
                                   const uint32_t     pitch,
                                   const uint32_t     height,
                                   const uint32_t     level,
                                   const uint32_t     maxlevel,
                                   ExtremaMgmt*       d_extrema_mgmt,
                                   ExtremumCandidate* d_extrema )
{
    /*
     * First consideration: extrema cannot be found on any outermost edge,
     * one pixel on the left, right, upper, lower edge will never qualify.
     * Also, the upper and lower DoG layer will never qualify. So there is
     * no reason for selecting any of those pixel for the center of a 3x3x3
     * region.
     * Instead, I use groups of 32xHEIGHT threads that read from a 34x34x3 area,
     * but implicitly, they fetch * 64xHEIGHT+2x3 floats (bad luck).
     * To find maxima, compare first on the left edge of the 3x3x3 cube, ie.
     * a 1x3x3 area. If the rightmost 2 threads of a warp (x==30 and 3==31)
     * are not extreme w.r.t. to the left slice, 8 fetch operations.
     */
    int32_t block_x = blockIdx.x * 32;
    int32_t block_y = blockIdx.y * blockDim.y;
    int32_t y       = block_y + threadIdx.y;
    int32_t x       = block_x + threadIdx.x;
    // int32_t z       = 0;

    if ( x+2 >= width ) {
        // atomicAdd( &debug_r.too_wide, 1 );
        return false;
    }
    if ( y+2 >= height ) {
        // atomicAdd( &debug_r.too_high, 1 );
        return false;
    }

    int32_t x0      = x;
    int32_t x1      = x+1;
    int32_t x2      = x+2;
    int32_t y0w     = y * pitch;
    int32_t y1w     = (y+1) * pitch;
    int32_t y2w     = (y+2) * pitch;

    float val = dog[1][y1w+x1];

    if( fabs( val ) < threshold ) {
        // atomicAdd( &debug_r.under_threshold, 1 );
        return false;
    }

    if( not is_extremum_v4( dog, y0w, y1w, y2w, x0, x1, x2 ) ) {
        // atomicAdd( &debug_r.not_extremum, 1 );
        return false;
    }

    // based on Bemap
    float Dx  = 0.0f;
    float Dy  = 0.0f;
    float Ds  = 0.0f;
    float Dxx = 0.0f;
    float Dyy = 0.0f;
    float Dss = 0.0f;
    float Dxy = 0.0f;
    float Dxs = 0.0f;
    float Dys = 0.0f;
    float dx  = 0.0f;
    float dy  = 0.0f;
    float ds  = 0.0f;

    float v = val;

    int32_t ni = y+1; // y1w;
    int32_t nj = x1;
    int32_t ns = level;

    int32_t tx = 0;
    int32_t ty = 0;
    int32_t ts = 0;

    int32_t iter;

    /* must be execute at least once */
    for ( iter = 0; iter < 5; iter++) {
        /* compute gradient */
        Dx = 0.5 * ( dog[1][y1w+x2] - dog[1][y1w+x0] );
        Dy = 0.5 * ( dog[1][y2w+x1] - dog[1][y2w+x1] );
        Ds = 0.5 * ( dog[2][y1w+x1] - dog[0][y1w+x1] );

        /* compute Hessian */
        Dxx = dog[1][y1w+x2] + dog[1][y1w+x0] - 2.0 * dog[1][y1w+x1];
        Dyy = dog[1][y2w+x1] + dog[1][y0w+x1] - 2.0 * dog[1][y1w+x1];
        Dss = dog[2][y1w+x1] + dog[0][y1w+x1] - 2.0 * dog[1][y1w+x1];

        Dxy = 0.25f * ( dog[1][y2w+x2] + dog[1][y0w+x0]
                      - dog[1][y2w+x0] - dog[1][y0w+x2] );
        Dxs = 0.25f * ( dog[2][y1w+x2] + dog[0][y1w+x0]
                      - dog[2][y1w+x0] - dog[0][y1w+x2] );
        Dys = 0.25f * ( dog[2][y2w+x1] + dog[0][y0w+x1]
                      - dog[0][y2w+x1] - dog[2][y0w+x1] );

        float b[3];
        float A[3][3];

        /* Solve linear system. */
        A[0][0] = Dxx;
        A[1][1] = Dyy;
        A[2][2] = Dss;
        A[1][0] = A[0][1] = Dxy;
        A[2][0] = A[0][2] = Dxs;
        A[2][1] = A[1][2] = Dys;

        b[0] = -Dx;
        b[1] = -Dy;
        b[2] = -Ds;

#if 0
        if( solve( A, b ) == false ) {
            dx = 0;
            dy = 0;
            ds = 0;
            break ;
        }
#else
        if( solve2( A, b ) == false ) {
            dx = 0;
            dy = 0;
            ds = 0;
            break ;
        }
#endif

        dx = b[0];
        dy = b[1];
        ds = b[2];

        /* If the translation of the keypoint is big, move the keypoint
         * and re-iterate the computation. Otherwise we are all set.
         */
        if( fabs(ds) < 0.5f && fabs(dy) < 0.5f && fabs(dx) < 0.5f) break;

        tx = ((dx >= 0.5f && nj < width-2) ?  1 : 0 )
           + ((dx <= -0.5f && nj > 1)? -1 : 0 );

        ty = ((dy >= 0.5f && ni < height-2)  ?  1 : 0 )
           + ((dy <= -0.5f && ni > 1) ? -1 : 0 );

        ts = ((ds >= 0.5f && ns < maxlevel-1)  ?  1 : 0 )
           + ((ds <= -0.5f && ns > 1) ? -1 : 0 );

        ni += ty;
        nj += tx;
        ns += ts;
    } /* go to next iter */

    /* ensure convergence of interpolation */
    if (iter >= 5) {
        // atomicAdd( &debug_r.convergence_failure, 1 );
        return false;
    }

    float contr   = v + 0.5f * (Dx * dx + Dy * dy + Ds * ds);
    float tr      = Dxx + Dyy;
    float det     = Dxx * Dyy - Dxy * Dxy;
    float edgeval = tr * tr / det;
    float xn      = nj + dx;
    float yn      = ni + dy;
    float sn      = ns + ds;

    /* negative determinant => curvatures have different signs -> reject it */
    if (det <= 0.0) {
        // atomicAdd( &debug_r.determinant_zero, 1 );
        return false;
    }

    /* accept-reject extremum */
    if( fabs(contr) < (threshold*2.0f) ) {
        // atomicAdd( &debug_r.thresh_exceeded, 1 );
        return false;
    }

    /* reject condition: tr(H)^2/det(H) < (r+1)^2/r */
    if( edgeval > (edge_limit+1.0f)*(edge_limit+1.0f)/edge_limit ) {
        // atomicAdd( &debug_r.edge_exceeded, 1 );
        return false;
    }

    uint32_t write_index = extrema_count_v4( true, d_extrema_mgmt );

    if( write_index >= d_extrema_mgmt->max1 ) {
        // atomicAdd( &debug_r.max_exceeded, 1 );
        return false;
    }
    // atomicAdd( &debug_r.continuing, 1 );
    // __syncthreads();

    ExtremumCandidate ec;
    ec.xpos    = xn;
    ec.ypos    = yn;
    ec.sigma   = d_sigma0 * pow(d_sigma_k, sn);
            // key_candidate->sigma = sigma0 * pow(sigma_k, sn);
        // ec.value   = 0;
        // ec.edge    = 0;
    ec.angle_from_bemap = 0;
    ec.not_a_keypoint   = 0;
    d_extrema[write_index] = ec;

    return true;
}

__global__
void find_extrema_in_dog_v4( float*             dog_upper,
                             float*             dog_here,
                             float*             dog_lower,
                             float              edge_limit,
                             float              threshold,
                             const uint32_t     width,
                             const uint32_t     pitch,
                             const uint32_t     height,
                             const uint32_t     level,
                             const uint32_t     maxlevel,
                             ExtremaMgmt*       mgmt_array,
                             ExtremumCandidate* d_extrema )
{
    float* dog_array[3];
    dog_array[0] = dog_upper;
    dog_array[1] = dog_here;
    dog_array[2] = dog_lower;

    ExtremaMgmt* mgmt = &mgmt_array[level];

    uint32_t indicator = find_extrema_in_dog_v4_bemap( dog_array, edge_limit, threshold, width, pitch, height, level, maxlevel, mgmt, d_extrema );
}

__global__
void fix_extrema_count_v4( ExtremaMgmt* mgmt_array, uint32_t mgmt_level )
{
    ExtremaMgmt* mgmt = &mgmt_array[mgmt_level];

    mgmt->counter = min( mgmt->counter, mgmt->max1 );
    // printf("%s>%d - %d\n", __FILE__, __LINE__, mgmt->counter );
}

#if 0
__global__
void start_orientation_v4( ExtremumCandidate* extrema,
                           ExtremaMgmt*       mgmt,
                           const float*       layer,
                           int                layer_pitch,
                           int                layer_height )
{
    mgmt->counter = min( mgmt->counter, mgmt->max1 );

    compute_keypoint_orientations_v2
        <<<mgmt->counter,16>>>
        ( extrema,
          mgmt,
          layer,
          layer_pitch,
          layer_height );
}
#endif

/*************************************************************
 * V4: host side
 *************************************************************/
__host__
void Pyramid::find_extrema_v4( uint32_t height, float edgeLimit, float threshold )
{
    cerr << "Entering " << __FUNCTION__ << " - bitfield, 32x" << height << " kernels" << endl;

#if 0
    cudaDeviceSynchronize();
    ReturnReasons a;
    a.too_wide = 0;
    a.too_high = 0;
    a.under_threshold = 0;
    a.not_extremum = 0;
    a.convergence_failure = 0;
    a.determinant_zero = 0;
    a.thresh_exceeded = 0;
    a.edge_exceeded = 0;
    a.max_exceeded = 0;
    a.continuing = 0;
    cudaMemcpyToSymbol( debug_r, &a, sizeof(ReturnReasons), 0, cudaMemcpyHostToDevice );
#endif

    _keep_time_extrema_v4.start();

    for( int octave=0; octave<_num_octaves; octave++ ) {
        for( int level=1; level<_levels-1; level++ ) {
            dim3 block;
            dim3 grid;
            grid.x  = _octaves[octave].getPitch()  / 32;
            grid.y  = _octaves[octave].getHeight() / height;
            block.x = 32;
            block.y = height;

            find_extrema_in_dog_v4
                <<<grid,block,0,_stream>>>
                ( _octaves[octave].getDogData( level-1 ),
                  _octaves[octave].getDogData( level ),
                  _octaves[octave].getDogData( level+1 ),
                  edgeLimit,
                  threshold,
                  _octaves[octave].getWidth( ),
                  _octaves[octave].getPitch( ),
                  _octaves[octave].getHeight( ),
                  level,
                  _levels,
                  _octaves[octave].getExtremaMgmtD( ),
                  _octaves[octave].getExtrema( level ) );
#if 1
            fix_extrema_count_v4
                <<<1,1,0,_stream>>>
                ( _octaves[octave].getExtremaMgmtD( ),
                  level );
#else
    // this does not work yet: I have no idea how to link with CUDA
    // and still achieve dynamic parallelism
            start_orientation_v4
                <<<1,1,0,_stream>>>
                ( _octaves[octave].getExtrema( level ),
                  _octaves[octave].getExtremaMgmtD( level ),
                  _octaves[octave].getDogData( level ),
                  _octaves[octave].getPitch( ),
                  _octaves[octave].getHeight( ) );
#endif
        }
    }
    cudaError_t err = cudaGetLastError();
    POP_CUDA_FATAL_TEST( err, "find_extrema_in_dog_v4 failed: " );

    _keep_time_extrema_v4.stop();

#if 0
    cudaDeviceSynchronize();
    cudaMemcpyFromSymbol( &a, debug_r, sizeof(ReturnReasons), 0, cudaMemcpyDeviceToHost );
    cerr << __FILE__ << ":" << __LINE__ << endl
         << "reasons for returning:" << endl
         << "  too wide: " << a.too_wide << endl
         << "  too high: " << a.too_high << endl
         << "  under threshold: " << a.under_threshold << endl
         << "  not extremum: " << a.not_extremum << endl
         << "  convergence failure: " << a.convergence_failure << endl
         << "  determinant zero: " << a.determinant_zero << endl
         << "  threshold exceeded: " << a.thresh_exceeded << endl
         << "  edge limit exceeded: " << a.edge_exceeded << endl
         << "  max exceeded: " << a.max_exceeded << endl
         << "  everything OK: " << a.continuing << endl
         << endl;
#endif
}

void Pyramid::init_sigma( float sigma0, uint32_t levels, cudaStream_t stream )
{
    cudaError_t err;

    err = cudaMemcpyToSymbolAsync( d_sigma0, &sigma0,
                                   sizeof(float), 0,
                                   cudaMemcpyHostToDevice,
                                   stream );
    POP_CUDA_FATAL_TEST( err, "Failed to upload sigma0 to device: " );

    const float sigma_k = powf(2.0f, 1.0f / levels );

    err = cudaMemcpyToSymbolAsync( d_sigma_k, &sigma_k,
                                   sizeof(float), 0,
                                   cudaMemcpyHostToDevice,
                                   stream );
    POP_CUDA_FATAL_TEST( err, "Failed to upload sigma_k to device: " );
}

