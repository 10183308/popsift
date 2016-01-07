#pragma once

#include "s_image.hpp"
#include "keep_time.hpp"

#ifndef INF
#define INF               (1<<29)
#endif
#ifndef NINF
#define NINF              (-INF)
#endif
#ifndef M_PI
#define M_PI  3.1415926535897932384626433832F
#endif
#ifndef M_PI2
#define M_PI2 (2.0F * M_PI)
#endif

#define GAUSS_ONE_SIDE_RANGE 12
#define GAUSS_SPAN           (2*GAUSS_ONE_SIDE_RANGE+1)

namespace popart {

struct ExtremaMgmt
{
    uint32_t counter;
    uint32_t max1;     // initial max
    uint32_t max2;     // max after finding alternative angles
                       // Lowe says it happens to 15%, I reserve floor(25%)
    void init( uint32_t m1 ) {
        counter = 0;
        max1    = m1;
        max2    = m1 + m1/4;
    }
    ExtremaMgmt( ) { }

    ExtremaMgmt( uint32_t m1 ) {
        counter = 0;
        max1    = m1;
        max2    = m1 + m1/4;
    }
};

struct ExtremumCandidate
{
    float    xpos;
    float    ypos;
    float    sigma; // scale;
    // float    value;
    // float edge;
    float    angle_from_bemap;
    uint32_t not_a_keypoint;
    // float dummy_7;
};

struct Descriptor
{
    float features[128];
};

class Pyramid
{
    class Octave
    {
        cudaStream_t _stream;

        uchar*    _data;   // main frame
        uchar*    _data_2; // alternative to transposed data, surface Mem
        uchar*    _t_data; // transsposed data, used without surface
        uchar*    _dog_data; // difference of Gaussian
        uint32_t  _levels;
        uint32_t  _width; // width in number of floats, not bytes
        uint32_t  _height;
        uint32_t  _pitch; // pitch in number of floats, not bytes !!!
        uint32_t  _t_pitch;

        /* It seems strange strange to collect extrema globally only.
         * Because of the global cut-off, features from the later
         * octave have a smaller chance of being accepted.
         * Besides, the management of computing gradiants and atans
         * must be handled per scale (level) of an octave.
         * There: one set of extrema per octave and level.
         */
        ExtremaMgmt*        _h_extrema_mgmt; // host side info
        ExtremaMgmt*        _d_extrema_mgmt; // device side info
        ExtremumCandidate** _d_extrema;
        Descriptor**        _d_desc;
        Descriptor**        _h_desc;

    public:
        Octave( );
        ~Octave( ) { this->free(); }

        inline int getLevels() const { return _levels; }
        inline int getWidth() const  { return _width; }
        inline int getHeight() const { return _height; }
        inline int getPitch() const  { return _pitch; }
        inline int getTransposedWidth() const  { return _height; }
        inline int getTransposedHeight() const { return _width; }
        inline int getTransposedPitch() const  { return _t_pitch; }

        inline float* getData()           { return (float*)_data; }
        inline float* getData2()          { return (float*)_data_2; }
        inline float* getDogData()        { return (float*)_dog_data; }
        inline float* getTransposedData() { return (float*)_t_data; }

        inline float* getData( uint32_t level ) {
            uchar* ret = _data;
            ret += ( level * getByteSizeData() );
            return (float*)ret;
        }
        inline float* getData2( uint32_t level ) { uchar* ret = _data_2; ret += ( level * getByteSizeData() ); return (float*)ret; }
        inline float* getDogData( uint32_t level ) {
            uchar* ret = _dog_data;
            ret += ( level * getByteSizeDogData() );
            return (float*)ret;
        }
        inline float* getTransposedData( uint32_t level ) {
            uchar* ret = _t_data;
            ret += ( level * getByteSizeTransposedData() );
            return (float*)ret;
        }

        inline uint32_t getFloatSizeData() const           { return _pitch * _height; }
        inline uint32_t getFloatSizeDogData() const        { return getFloatSizeData(); }
        inline uint32_t getFloatSizeTransposedData() const { return _t_pitch * _width; }

        inline uint32_t getByteSizeData() const {
            return sizeof(float) * getFloatSizeData();
        }
        inline uint32_t getByteSizeDogData() const { return getByteSizeData(); }
        inline uint32_t getByteSizeTransposedData() const {
            return sizeof(float) * getFloatSizeTransposedData();
        }
        inline uint32_t getByteSizePitch() const {
            return sizeof(float) * getPitch();
        }
        inline uint32_t getByteSizeTransposedPitch() const {
            return sizeof(float) * getTransposedPitch();
        }

        inline ExtremaMgmt* getExtremaMgmtH( uint32_t level ) {
            return &_h_extrema_mgmt[level];
        }

        inline ExtremaMgmt* getExtremaMgmtD( ) {
            return _d_extrema_mgmt;
        }

        inline ExtremumCandidate* getExtrema( uint32_t level ) {
            return _d_extrema[level];
        }

        void resetExtremaCount( cudaStream_t stream );
        void readExtremaCount( cudaStream_t stream );
        uint32_t getExtremaCount( ) const;
        uint32_t getExtremaCount( uint32_t level ) const;

        void        allocDescriptors( );
        Descriptor* getDescriptors( uint32_t level );
        void        downloadDescriptor( cudaStream_t stream );
        void        writeDescriptor( ostream& ostr );

        /**
         * alloc() - allocates all GPU memories for one octave
         * @param width in floats, not bytes!!!
         */
        void alloc( uint32_t width, uint32_t height, uint32_t levels, uint32_t layer_max_extrema, cudaStream_t stream=0 );
        void free();

        /**
         * debug:
         * download a level and write to disk
         */
        void download_and_save_array( const char* basename, uint32_t octave, uint32_t level );

    private:
        void allocExtrema( uint32_t layer_max_extrema );
        void freeExtrema( );
    };

    uint32_t     _num_octaves;
    uint32_t     _levels;
    Octave*      _octaves;
    cudaStream_t _stream;

public:
    Pyramid( Image* base, uint32_t octaves, uint32_t levels, cudaStream_t stream );
    ~Pyramid( );

    static void init_filter( float sigma, uint32_t level, cudaStream_t stream );
    static void init_sigma(  float sigma, uint32_t level, cudaStream_t stream );
    void build( Image* base, uint32_t idx );

    void find_extrema( float edgeLimit, float threshold );

    void download_and_save_array( const char* basename, uint32_t octave, uint32_t level );

    void download_and_save_descriptors( const char* basename, uint32_t octave );

    void report_times();

private:
    void build_v6  ( Image* base );
    void build_v7  ( Image* base );

    void reset_extremum_counter( );
    void find_extrema_v4( uint32_t height, float edgeLimit, float threshold );

    void orientation_v1( );
    void orientation_v2( );

    void descriptors_v1( );

    void test_last_error( int line, cudaStream_t stream );
    void debug_out_floats  ( float* data, uint32_t pitch, uint32_t height );
    void debug_out_floats_t( float* data, uint32_t pitch, uint32_t height );

    KeepTime _keep_time_pyramid_v6;
    KeepTime _keep_time_pyramid_v7;

    KeepTime _keep_time_extrema_v4;

    KeepTime _keep_time_orient_v1;
    KeepTime _keep_time_orient_v2;

    KeepTime _keep_time_descr_v1;
};

} // namespace popart
