#include <iostream>
#include <sstream>
#include <string>
#include <cmath>
#include <iomanip>
#include <stdlib.h>

#include <getopt.h>
#include <boost/filesystem.hpp>

#include "libavformat/avformat.h"
#include "libavutil/avutil.h"

#include "popsift.h"
#include "sift_conf.h"
#include "device_prop.h"

using namespace std;

static void validate( const char* appName, popart::Config& config );

/* User parameters */
int    verbose         = false;

string keyFilename     = "";
string inputFilename   = "";
string realName        = ""; 
string prefix          = "";

static void usage( const char* argv )
{
    cout << argv
         << "     <filename>"
         << endl << endl
         << "* Options *" << endl
         << " --help / -h / -?            Print usage" << endl
         << " --verbose / -v" << endl
         << " --log / -l                  Write debugging files" << endl
         << endl
         << "* Parameters *" << endl
         << " --octaves=<int>             Number of octaves" << endl
         << " --levels=<int>              Number of levels per octave" << endl
         << " --sigma=<float>             Initial sigma value" << endl
         << " --threshold=<float>         Keypoint strength threshold" << endl
         << " --edge-threshold=<float> or" << endl
         << " --edge-limit=<float>        On-edge threshold" << endl
         << " --downsampling=<float>      Downscale width and height of input by 2^N (default N=-1)" << endl
         << endl
         << "* Modes *" << endl
         << " --vlfeat-mode               Compute Gauss filter like VLFeat instead of like OpenCV" << endl
         << "                             Default filtering mode is \"indirect filtered\", which means" << endl
         << "                             that level-3 of an octave is downscaled and Gaussian blur" << endl
         << "                             is applied to get level 0 of the new octave." << endl
         << " --direct-downscale / --dd     Direct each octave from upscaled orig instead of blurred level" << endl
         << " --indirect-unfiltered / --iu  Downscaling from level-3, without applying Gaussian blur" << endl
         << " --indirect-downscale          Downscaling from level-3 and applying Gaussian blur" << endl
         << "                               Note: indirect-downscale blurs much more than it should" << endl
         << " --group-gauss=<int>         Gauss-filter N levels at once (N=2, 3 or 8)" << endl
         << "                             3 is accurate for default sigmas of VLFeat and OpenCV mode" << endl
         << endl;
    exit(0);
}

static struct option longopts[] = {
    { "help",                no_argument,            NULL, 'h' },
    { "verbose",             no_argument,            NULL, 'v' },
    { "log",                 no_argument,            NULL, 'l' },

    { "octaves",             required_argument,      NULL, 1000 },
    { "levels",              required_argument,      NULL, 1001 },
    { "downsampling",        required_argument,      NULL, 1002 },
    { "threshold",           required_argument,      NULL, 1003 },
    { "edge-threshold",      required_argument,      NULL, 1004 },
    { "edge-limit",          required_argument,      NULL, 1004 },
    { "sigma",               required_argument,      NULL, 1005 },

    { "vlfeat-mode",         no_argument,            NULL, 1100 },
    { "direct-downscale",    no_argument,            NULL, 1101 },
    { "dd",                  no_argument,            NULL, 1101 },
    { "indirect-downscale",  no_argument,            NULL, 1102 },
    { "indirect-unfiltered", no_argument,            NULL, 1103 },
    { "iu",                  no_argument,            NULL, 1103 },
    { "group-gauss",         required_argument,      NULL, 1104 },

    { NULL,                  0,                      NULL, 0  }
};

static void parseargs( int argc, char**argv, popart::Config& config, string& inputFile )
{
    const char* appName = argv[0];
    if( argc == 0 ) usage( "<program>" );
    if( argc == 1 ) usage( argv[0] );

    int opt;
    bool applySigma = false;
    float sigma;

    while( (opt = getopt_long(argc, argv, "?hvl", longopts, NULL)) != -1 )
    {
        switch (opt)
        {
        case '?' :
        case 'h' : usage( appName ); break;
        case 'v' : config.setVerbose(); break;
        case 'l' : config.setLogMode( popart::Config::All ); break;

        case 1100 : config.setModeVLFeat( ); break;
        case 1101 : config.setScalingMode( popart::Config::DirectDownscaling ); break;
        case 1102 : config.setScalingMode( popart::Config::IndirectDownscaling ); break;
        case 1103 : config.setScalingMode( popart::Config::IndirectUnfilteredDownscaling ); break;
        case 1104 : config.setGaussGroup( strtol( optarg, NULL, 0 ) ); break;

        case 1000 : config.setOctaves( strtol( optarg, NULL, 0 ) ); break;
        case 1001 : config.setLevels(  strtol( optarg, NULL, 0 ) ); break;
        case 1002 : config.setDownsampling( strtof( optarg, NULL ) ); break;
        case 1003 : config.setThreshold(  strtof( optarg, NULL ) ); break;
        case 1004 : config.setEdgeLimit(  strtof( optarg, NULL ) ); break;
        case 1005 : applySigma = true; sigma = strtof( optarg, NULL ); break;
        default   : usage( appName );
        }
    }

    if( applySigma ) config.setSigma( sigma );

    validate( appName, config );

    argc -= optind;
    argv += optind;

    if( argc == 0 ) usage( appName );

    inputFile = argv[0];
}

int main(int argc, char **argv)
{
    cudaDeviceReset();

    popart::Config config;
    string         inputFile = "";
    const char*    appName   = argv[0];

    parseargs( argc, argv, config, inputFile ); // Parse command line

    if( inputFile == "" ) {
        cerr << "No input filename given" << endl;
        usage( appName );
    }

    if( not boost::filesystem::exists( inputFile ) ) {
        cerr << "File " << inputFile << " not found" << endl;
        usage( appName );
    }

    imgStream inp;

    realName = extract_filename( inputFile, prefix );
    read_gray( inputFile, inp );
    cerr << "Input image size: "
         << inp.width << "X" << inp.height
         << " filename: " << realName << endl;

    device_prop_t deviceInfo;
    deviceInfo.set( 0 );
    deviceInfo.print( );

    PopSift PopSift( config );

    PopSift.init( 0, inp.width, inp.height );
    PopSift.execute( 0, inp );
    PopSift.uninit( 0 );
    return 0;
}

static void validate( const char* appName, popart::Config& config )
{
    switch( config.getGaussGroup() )
    {
    case 1 :
    case 2 :
    case 3 :
    case 8 :
        break;
    default :
        cerr << "Only 2, 3 or 8 Gauss levels can be combined at this time" << endl;
        usage( appName );
        exit( -1 );
    }
}

