#include "sift_conf.h"

namespace popart
{

Config::Config( )
    : start_sampling( -1 )
    , octaves( -1 )
    , levels( 3 )
    , sigma( 1.6f )
    , edge_limit( 10.0f )
    , threshold( 10.0f / 256.0f )
    , sift_mode( Config::OpenCV )
    , log_mode( Config::None )
    , scaling_mode( Config::DownscaledOctaves )
    , verbose( false )
{ }

void Config::setModeVLFeat( float s )
{
    sift_mode = Config::VLFeat;
    sigma     = s;
}

void Config::setModeOpenCV( float s )
{
    sift_mode = Config::OpenCV;
    sigma     = s;
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

void Config::setUpsampling( float v ) { start_sampling = v; }
void Config::setOctaves( int v ) { octaves = v; }
void Config::setLevels( int v ) { levels = v; }
void Config::setSigma( float v ) { sigma = v; }
void Config::setEdgeLimit( float v ) { edge_limit = v; }
void Config::setThreshold( float v ) { threshold = v; }

}; // namespace popart

