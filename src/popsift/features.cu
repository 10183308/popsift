/*
 * Copyright 2016-2017, Simula Research Laboratory
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */
#include <iomanip>
#include <iostream>
#include <unistd.h>
#ifndef __APPLE__
#include <malloc.h>
#endif
#include <stdlib.h>
#include <errno.h>
#include <math_constants.h>
#include "features.h"
#include "sift_extremum.h"
#include "common/debug_macros.h"
#include "sift_conf.h"
#include <thrust/sort.h>
#include <thrust/device_ptr.h>
#include <thrust/execution_policy.h>

using namespace std;

namespace popsift {
    

/*************************************************************
 * Features
 *************************************************************/

    Features::Features( )
	: _num_ext( 0 )
	, _num_ori( 0 )
    { }
    
    Features::~Features( )
    { }
    
/*************************************************************
 * HostFeatures
 *************************************************************/
    
    HostFeatures::HostFeatures( )
	: _ext( 0 )
	, _ori( 0 )
    { }

    HostFeatures::HostFeatures( int num_ext, int num_ori )
	: _ext( 0 )
	, _ori( 0 )
    {
	reset( num_ext, num_ori );
    }

    HostFeatures::~HostFeatures( )
    {
	free( _ext );
	free( _ori );
    }

#ifdef __APPLE__
    static void* memalign( size_t alignment, size_t size )
    {
	void* ret;
	int err = posix_memalign( &ret, alignment, size );
	if( err != 0 ) {
	    errno = err;
	    ret = 0;
	}
	return ret;
    }
#endif

    void HostFeatures::reset( int num_ext, int num_ori )
    {
	if( _ext != 0 ) { free( _ext ); _ext = 0; }
	if( _ori != 0 ) { free( _ori ); _ori = 0; }

	_ext = (Feature*)memalign( sysconf(_SC_PAGESIZE), num_ext * sizeof(Feature) );
	if( _ext == 0 ) {
	    cerr << __FILE__ << ":" << __LINE__ << " Runtime error:" << endl
		 << "    Failed to (re)allocate memory for downloading " << num_ext << " features" << endl;
	    if( errno == EINVAL ) cerr << "    Alignment is not a power of two." << endl;
	    if( errno == ENOMEM ) cerr << "    Not enough memory." << endl;
	    exit( -1 );
	}
	_ori = (Descriptor*)memalign( sysconf(_SC_PAGESIZE), num_ori * sizeof(Descriptor) );
	if( _ori == 0 ) {
	    cerr << __FILE__ << ":" << __LINE__ << " Runtime error:" << endl
		 << "    Failed to (re)allocate memory for downloading " << num_ori << " descriptors" << endl;
	    if( errno == EINVAL ) cerr << "    Alignment is not a power of two." << endl;
	    if( errno == ENOMEM ) cerr << "    Not enough memory." << endl;
	    exit( -1 );
	}

	setFeatureCount( num_ext );
	setDescriptorCount( num_ori );
    }

    void HostFeatures::pin( )
    {
	cudaError_t err;
	err = cudaHostRegister( _ext, getFeatureCount() * sizeof(Feature), 0 );
	if( err != cudaSuccess ) {
	    cerr << __FILE__ << ":" << __LINE__ << " Runtime warning:" << endl
		 << "    Failed to register feature memory in CUDA." << endl
		 << "    " << cudaGetErrorString(err) << endl;
	}
	err = cudaHostRegister( _ori, getDescriptorCount() * sizeof(Descriptor), 0 );
	if( err != cudaSuccess ) {
	    cerr << __FILE__ << ":" << __LINE__ << " Runtime warning:" << endl
		 << "    Failed to register descriptor memory in CUDA." << endl
		 << "    " << cudaGetErrorString(err) << endl;
	}
    }

    void HostFeatures::unpin( )
    {
	cudaHostUnregister( _ext );
	cudaHostUnregister( _ori );
    }

    void HostFeatures::print( std::ostream& ostr, bool write_as_uchar ) const
    {
	for( int i=0; i<size(); i++ ) {
	    _ext[i].print( ostr, write_as_uchar );
	}
    }

    std::ostream& operator<<( std::ostream& ostr, const HostFeatures& feature )
    {
	feature.print( ostr, false );
	return ostr;
    }

/*************************************************************
 * DeviceFeatures
 *************************************************************/

    DeviceFeatures::DeviceFeatures( )
	: _ext( 0 )
	, _ori( 0 )
	, _rev( 0 )
    { }

    DeviceFeatures::DeviceFeatures( int num_ext, int num_ori )
	: _ext( 0 )
	, _ori( 0 )
	, _rev( 0 )
    {
	reset( num_ext, num_ori );
    }

    DeviceFeatures::~DeviceFeatures( )
    {
	cudaFree( _ext );
	cudaFree( _ori );
	cudaFree( _rev );
    }

    void DeviceFeatures::reset( int num_ext, int num_ori )
    {
	if( _ext != 0 ) { cudaFree( _ext ); _ext = 0; }
	if( _ori != 0 ) { cudaFree( _ori ); _ori = 0; }
	if( _rev != 0 ) { cudaFree( _rev ); _rev = 0; }

	_ext = popsift::cuda::malloc_devT<Feature>   ( num_ext, __FILE__, __LINE__ );
	_ori = popsift::cuda::malloc_devT<Descriptor>( num_ori, __FILE__, __LINE__ );
	_rev = popsift::cuda::malloc_devT<int>       ( num_ori, __FILE__, __LINE__ );

	setFeatureCount( num_ext );
	setDescriptorCount( num_ori );
    }

    __device__ inline float
    l2_in_t0( const float4* lptr, const float4* rptr )
    {
	const float4  lval = lptr[threadIdx.x];
	const float4  rval = rptr[threadIdx.x];
	const float4  mval = make_float4( lval.x - rval.x,
					  lval.y - rval.y,
					  lval.z - rval.z,
					  lval.w - rval.w );
	float   res = mval.x * mval.x
	    + mval.y * mval.y
	    + mval.z * mval.z
	    + mval.w * mval.w;

	res += __shfl_down( res, 16 );
	res += __shfl_down( res,  8 );
	res += __shfl_down( res,  4 );
	res += __shfl_down( res,  2 );
	res += __shfl_down( res,  1 );

	return res;
    }
    __device__ inline float
    dot_l2_in_t0( const float4* lptr, const float4* rptr )
    {
	const float4  lval = lptr[threadIdx.x];
	const float4  rval = rptr[threadIdx.x];
	const float4  mval = make_float4( lval.x * rval.x,
					  lval.y * rval.y,
					  lval.z * rval.z,
					  lval.w * rval.w );
	float   res = mval.x
	    + mval.y
	    + mval.z
	    + mval.w;

    
	res += __shfl_down( res, 16 );
	res += __shfl_down( res,  8 );
	res += __shfl_down( res,  4 );
	res += __shfl_down( res,  2 );
	res += __shfl_down( res,  1 );
	return res;
    }
  
    __global__ void
    compute_distance_l2( int3* match_matrix, Descriptor* l, int l_len, Descriptor* r, int r_len )
    {
	if( blockIdx.x >= l_len ) return;
	const int idx = blockIdx.x;

	float match_1st_val = CUDART_INF_F;
	float match_2nd_val = CUDART_INF_F;
	int   match_1st_idx = 0;
	int   match_2nd_idx = 0;

	const float4* lptr = (const float4*)( &l[idx] );

	for( int i=0; i<r_len; i++ )
	{
	    const float4* rptr = (const float4*)( &r[i] );

	    const float   res  = l2_in_t0( lptr, rptr );

	    if( threadIdx.x == 0 )
	    {
		if( res < match_1st_val )
		{
		    match_2nd_val = match_1st_val;
		    match_2nd_idx = match_1st_idx;
		    match_1st_val = res;
		    match_1st_idx = i;
		}
		else if( res < match_2nd_val )
		{
		    match_2nd_val = res;
		    match_2nd_idx = i;
		}
	    }
	    __syncthreads();
	}

	if( threadIdx.x == 0 )
	{
	    bool accept = ( match_1st_val / match_2nd_val < 0.8f );
	    match_matrix[blockIdx.x] = make_int3( match_1st_idx, match_2nd_idx, accept );
	}
    }
  
  
    __global__ void
    compute_distance_dot( int3* match_matrix, Descriptor* l, int l_len, Descriptor* r, int r_len )
    {
	if( blockIdx.x >= l_len ) return;
	const int idx = blockIdx.x;

	float match_1st_val = -1.0f;
	float match_2nd_val = -1.0f;
	int   match_1st_idx = 0;
	int   match_2nd_idx = 0;

  

	const float4* lptr = (const float4*)( &l[idx] );

	for( int i=0; i<r_len; i++ )
	{
	    const float4* rptr = (const float4*)( &r[i] );
	    const float   res  = dot_l2_in_t0( lptr, rptr );

	
	    if( threadIdx.x == 0 )
	    {
		if( res > match_1st_val )
		{
		    match_2nd_val = match_1st_val;
		    match_2nd_idx = match_1st_idx;
		    match_1st_val = res;
		    match_1st_idx = i;
		}
		else if( res > match_2nd_val )
		{
		    match_2nd_val = res;
		    match_2nd_idx = i;
		}
	    }

	    __syncthreads();	
	}
    
    
	const int one = __shfl(match_1st_idx, 0);
	const int two = __shfl(match_2nd_idx, 0);
  
	const float4* rptr = (const float4*)( &r[one] );
	const float res2 = l2_in_t0( lptr, rptr );
	const float4* rptr2 = (const float4*)( &r[two] );
	const float res3 = l2_in_t0( lptr, rptr2 );

	if( threadIdx.x == 0 )
	{
	    bool accept = (res2/res3 < 0.8f );
	    match_matrix[blockIdx.x] = make_int3( match_1st_idx, match_2nd_idx, accept );
	}
    }

    __device__ void
    printBits( unsigned int num )
    {
        for ( int bit = 0; bit < 32; bit++ )
	{
	    printf("%i", num & 0x01);
	    num = num >> 1;
	}
    }

  
    __device__ void
    printFeature( unsigned int *num )
    {
        for ( int i = 0; i < 128; i += 4 ) {
            for (int j = 0; j < 4; j++) {
		printBits(num[ i + j]);
		printf( " " );
            }
            
            printf( "\n" ); 
        }
        
	printf( "\n\n" );
    }

    __device__ void
    print32x32( unsigned int *num )
    {
        for ( int i = 0; i < 32; i++ ) {
            printBits(num[i]);
            printf( "\n" ); 
        }
        
        printf( "\n\n" );
    }
    
    __device__ void
    transpose32(unsigned int *A) {
        int j, k;
        unsigned m, t;
        
        m = 0x0000FFFF;
        for (j = 16; j != 0; j = j >> 1, m = m ^ (m << j)) {
            for (k = 0; k < 32; k = (k + j + 1) & ~j) {
                t = (A[k] ^ (A[k+j] >> j)) & m;
                A[k] = A[k] ^ t;
                A[k+j] = A[k+j] ^ (t << j);
            }
        }
    }
    
    __device__ void
    organize_32( unsigned int* A, unsigned int* B )
    {
        int i = threadIdx.x;
        int cnt = threadIdx.x * 4;
        for (int j = 0; j < 128; j +=32)
	{
	    B[cnt] = A[i + j];
	    cnt++;   
                
	}
    }
	
    // Using __shared__ variables within a descriptor
    __global__ void
    compute_distance_shared_32(unsigned int *featurex, unsigned int *featurey)
    {
//int i = blockIdx.x*blockDim.x + threadIdx.x;
	int s = threadIdx.x * 4;
	int i;
	__shared__ unsigned int T[128];
	for (i = s; i < s + 4; i++)
	    T[i] = *(featurex + i + 128 * blockIdx.x);
        
	__syncthreads();
	if (threadIdx.x < 4)
	    transpose32(T + 32 * threadIdx.x);
	__syncthreads();
	organize_32(T, featurey + 128 * blockIdx.x);
        
        
//__syncthreads();
//if (threadIdx.x == 0 && blockIdx.x == 32)
//printFeature(featurey + DIMENSIONS * blockIdx.x);
        
    }
    
  
    
    __device__ void
    transpose(Descriptor * src, Descriptor *des, int size) {
              
        int idx = blockIdx.x;

        
	
        unsigned int * featurex = (unsigned int*)(&src[idx]);       
	//const float4* fx = (const float4*)(&src[idx]);
	//const float4 fx1 = fx[0];
	//unsigned int * featurex = (unsigned int*)&fx1.x;
	
        unsigned int * featurey = (unsigned int*)(&des[idx]);
        
        //int i = blockIdx.x*blockDim.x + threadIdx.x;
        int s = threadIdx.x * 4;
        int i;
        __shared__ unsigned int T[128];
	for (i = s; i < s + 4; i++)
            T[i] = *(featurex + i + 128 * idx);


//	    if(idx == 0 && threadIdx.x == 0) 
//		printFeature(featurex);
	    
        __syncthreads();        
        if (threadIdx.x < 4)
            transpose32(T + 32 * threadIdx.x);
        __syncthreads();
        organize_32(T, featurey + 128 * blockIdx.x);


//	    if(idx == 0 && threadIdx.x == 0)
//		printFeature(featurey+128*idx);

	__syncthreads();

	//if(idx == 0 && threadIdx.x == 0)
	//   printFeature((unsigned int*)des+128*idx);
	//const int N = 2;	
	//std::string s1((char*)featurey+128*idx, 16);
	//std::string s2((char*)featurex, 16);
	//int keys[N] = {1, 2};
	//char values[N] = {'b', 'a'};	    
	//thrust::stable_sort_by_key(thrust::device, keys, keys+N, values);
        
       
    }
    
    __global__ void
    compute_distance_transposed_hamming( int3* match_matrix, Descriptor* l, int l_len, Descriptor* r, int r_len , Descriptor * l_tra, Descriptor *r_tra) {

        if(blockIdx.x > l_len)
            return;

	if(blockIdx.x == 2 && threadIdx.x == 0)
	    printFeature((unsigned int*)l+128*blockIdx.x);
	
	
        transpose(l, l_tra, l_len);
	
	if(blockIdx.x == 2 && threadIdx.x == 0)
	printFeature((unsigned int*)l_tra+128*blockIdx.x);
	
	
    }

    __global__ void
    compute_distance_print( int3* match_matrix, Descriptor* l, int l_len, Descriptor* r, int r_len , Descriptor * l_tra, Descriptor *r_tra) {
	printf("address: %d\n", l_tra);


	for(int i = 0; i < 4; i++) {
	    for(int j = 0; j < 10; j++)
		printf("%u\t", l_tra[i].features[j]);
	    printf("\n");
	}
	/*
	unsigned int * t = (unsigned int*)(&l_tra[0]);
	printFeature((unsigned int *)t);
	t = (unsigned int*)(&l_tra[1]);
	printFeature((unsigned int *)t);
	t = (unsigned int*)(&l_tra[2]);
	printFeature((unsigned int *)t);
	t = (unsigned int*)(&l_tra[3]);
	printFeature((unsigned int *)t);
	t = (unsigned int*)(&l_tra[4]);
	printFeature((unsigned int *)t);
	t = (unsigned int*)(&l_tra[5]);
	printFeature((unsigned int *)t);
	t = (unsigned int*)(&l_tra[6]);
	printFeature((unsigned int *)t);
	*/
	printf("-------\n");
	//printFeature((unsigned int *)l_tra + 128);
    }

    struct compare_descriptors {
	template <typename T>
	__host__ __device__
	bool operator()(const T &l, const T &r) const {
	    for(int i = 0; i < 128; i++) {
		if(l.features[i] > r.features[i])
		    return true;
		if(l.features[i] < r.features[i])
		    return false;
	    }
	    return false;
	}
    };

    
    __global__ void
    show_distance( int3*       match_matrix,
		   Feature*    l_ext,
		   Descriptor* l_ori,
		   int*        l_fem,
		   int         l_len,
		   Feature*    r_ext,
		   Descriptor* r_ori,
		   int*        r_fem,
		   int         r_len )
    {
	int counter = 0;
	for( int i=0; i<l_len; i++ )
	{
	    const float4* lptr  = (const float4*)( &l_ori[i] );
	    const float4* rptr1 = (const float4*)( &r_ori[match_matrix[i].x] );
	    const float4* rptr2 = (const float4*)( &r_ori[match_matrix[i].y] );
	    float d1 = l2_in_t0( lptr, rptr1 );
	    float d2 = l2_in_t0( lptr, rptr2 );
	    if( threadIdx.x == 0 )
	    {
	  
		if( match_matrix[i].z )
		    counter++;
		/*printf( "accept feat %4d [%4d] matches feat %4d [%4d] ( 2nd feat %4d [%4d] ) dist %.3f vs %.3f\n",
		  l_fem[i], i,
		  r_fem[match_matrix[i].x], match_matrix[i].x,
		  r_fem[match_matrix[i].y], match_matrix[i].y,
		  d1, d2 );*/
	  
		//else
		/*printf( "reject feat %4d [%4d] matches feat %4d [%4d] ( 2nd feat %4d [%4d] ) dist %.3f vs %.3f\n",
		  l_fem[i], i,
		  r_fem[match_matrix[i].x], match_matrix[i].x,
		  r_fem[match_matrix[i].y], match_matrix[i].y,
		  d1, d2 );*/
	    }
	
	    __syncthreads();
      
	}
	if( threadIdx.x == 0 )
	    printf("Matches: %d\n", counter);
  
    }


    __host__ Descriptor * gpu_init(int SIZE) {
	Descriptor *tmp;

	cudaError_t err = cudaMalloc((void **)&tmp, SIZE * sizeof(Descriptor));
	if(err != cudaSuccess)
	    printf("%s\n", cudaGetErrorString(err));

	return tmp;
    }



    
    void DeviceFeatures::match( DeviceFeatures* other, const popsift::Config& config )
    {

	int l_len = getDescriptorCount( );
	int r_len = other->getDescriptorCount( );

	cudaDeviceSetLimit(cudaLimitPrintfFifoSize, 10000000);

	int3* match_matrix = popsift::cuda::malloc_devT<int3>( l_len, __FILE__, __LINE__ );    
    
	dim3 grid;
	grid.x = l_len;
	grid.y = 1;
	grid.z = 1;
	dim3 block;
	block.x = 32;
	block.y = 1;
	block.z = 1;

	if ( config.getModeMatching() == popsift::Config::l2 )
	{
	    compute_distance_l2
		<<<grid,block>>>
		( match_matrix, getDescriptors(), l_len, other->getDescriptors(), r_len );
	}
	else if ( config.getModeMatching() == popsift::Config::dot )
	{
	    compute_distance_dot
		<<<grid,block>>>
		( match_matrix, getDescriptors(), l_len, other->getDescriptors(), r_len );
	}
	else
	{


	    //transpose first set of descritors

	    //sort the transposed descriptors

	    //transpose and compare with the second set
	
	
	    Descriptor *l_copy = gpu_init(l_len);
	    Descriptor *r_copy = gpu_init(r_len);
/*
	    compute_distance_print
		<<<1, 1>>>
		( match_matrix, getDescriptors(), l_len, other->getDescriptors(), r_len , l_copy, r_copy);
	    cudaDeviceSynchronize();*/
	    compute_distance_transposed_hamming
		<<<grid,block>>>
		( match_matrix, getDescriptors(), l_len, other->getDescriptors(), r_len , l_copy, r_copy);
	    
	    cudaDeviceSynchronize();
	    // printf("%f\n", [0].features[0]);
	    
	    Descriptor *h_data;
	    Descriptor *d_data;
	    Descriptor *tmp_host = (Descriptor*)malloc(l_len * sizeof(Descriptor));
	    //h_data = l_copy;

	    cudaMalloc(
		&d_data,
		l_len*sizeof(Descriptor));

	    cudaDeviceSynchronize();
	    compute_distance_print
		<<<1, 1>>>
		( match_matrix, getDescriptors(), l_len, other->getDescriptors(), r_len , l_copy, r_copy);


	    /*
	    cudaMemcpy(
		d_data,
	        l_copy,
		l_len*sizeof(Descriptor),
		cudaMemcpyDeviceToDevice);

	    */
	    /*
	     cudaDeviceSynchronize();
	    compute_distance_print
		<<<1, 1>>>
		( match_matrix, getDescriptors(), l_len, other->getDescriptors(), r_len , d_data, r_copy);
	    */
	    //thrust::device_ptr<Descriptor> d_ptr(d_data);
/*
	    thrust::device_ptr<Descriptor> d_ptr = thrust::device_pointer_cast(l_copy);
	    
	    
	    thrust::sort(
		d_ptr,
		d_ptr+l_len,
		compare_descriptors());
*/
	    cudaDeviceSynchronize();
	    compute_distance_print
		<<<1, 1>>>
		( match_matrix, getDescriptors(), l_len, other->getDescriptors(), r_len , l_copy, r_copy);
/*
	    cudaMemcpy(
		tmp_host,
		d_data,
		l_len*sizeof(Descriptor),
		cudaMemcpyDeviceToHost);
*/

  
	    //int tmp_size = l_len;
	    
	    // for(int i = 0; i < tmp_size; i++)
	    //	printf("%f %f\n", tmp_host[i].features[126], tmp_host[i].features[127]);
	
	}

	show_distance
	    <<<1,32>>>
	    ( match_matrix,
	      getFeatures(),
	      getDescriptors(),
	      getReverseMap(),
	      l_len,
	      other->getFeatures(),
	      other->getDescriptors(),
	      other->getReverseMap(),
	      r_len );


	cudaFree( match_matrix );
    }

/*************************************************************
 * Feature
 *************************************************************/

    void Feature::print( std::ostream& ostr, bool write_as_uchar ) const
    {
	float sigval =  1.0f / ( sigma * sigma );

	for( int ori=0; ori<num_ori; ori++ ) {
	    ostr << xpos << " " << ypos << " "
		 << sigval << " 0 " << sigval << " ";
	    if( write_as_uchar ) {
		for( int i=0; i<128; i++ ) {
		    ostr << roundf(desc[ori]->features[i]) << " ";
		}
	    } else {
		ostr << std::setprecision(3);
		for( int i=0; i<128; i++ ) {
		    ostr << desc[ori]->features[i] << " ";
		}
		ostr << std::setprecision(6);
	    }
	    ostr << std::endl;
	}
    }

    std::ostream& operator<<( std::ostream& ostr, const Feature& feature )
    {
	feature.print( ostr, false );
	return ostr;
    }

} // namespace popsift
