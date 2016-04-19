#include "sift_conf.h"

namespace popart
{

Config::Config( )
    : start_sampling( -1 )
    , octaves( -1 )
    , levels( 3 )
    , sigma( 1.6f )
    , _edge_limit( 10.0f )
    , _threshold( 10.0f / 256.0f )
    , sift_mode( Config::OpenCV )
    , log_mode( Config::None )
    , scaling_mode( Config::IndirectDownscaling )
    , verbose( false )
    , gauss_group_size( 1 )
{ }

void Config::setModeVLFeat( )
{
    sift_mode = Config::VLFeat;
    sigma     = 0.82f;
}

void Config::setModeOpenCV( )
{
    sift_mode = Config::OpenCV;
    sigma     = 1.6f;
}

void Config::setVerbose( bool on )
{
    verbose = on;
}

void Config::setLogMode( LogMode mode )
{
    log_mode = mode;
}

void Config::setScalingMode( ScalingMode mode )
{
    scaling_mode = mode;
}

void Config::setDownsampling( float v ) { start_sampling = v; }
void Config::setOctaves( int v ) { octaves = v; }
void Config::setLevels( int v ) { levels = v; }
void Config::setSigma( float v ) { sigma = v; }
void Config::setEdgeLimit( float v ) { _edge_limit = v; }
void Config::setThreshold( float v ) { _threshold = v; }

void Config::setGaussGroup( int groupsize )
{
    gauss_group_size = groupsize;
}

int  Config::getGaussGroup( ) const
{
    return gauss_group_size;
}

}; // namespace popart

