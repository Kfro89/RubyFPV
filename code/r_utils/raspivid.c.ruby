/*
Copyright (c) 2018, Raspberry Pi (Trading) Ltd.
Copyright (c) 2013, Broadcom Europe Ltd.
Copyright (c) 2013, James Hughes
All rights reserved.

Redistribution and/or use in source and/or binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions and/or use of the source code (partially or complete) must retain
      the above copyright notice, this list of conditions and the following disclaimer
        in the documentation and/or other materials provided with the distribution.
    * Redistributions in binary form (partially or complete) must reproduce
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the copyright holder nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

/**
 * \file RaspiVid.c
 * Command line program to capture a camera video stream and encode it to file.
 * Also optionally display a preview/viewfinder of current camera input.
 *
 * Description
 *
 * 3 components are created; camera, preview and video encoder.
 * Camera component has three ports, preview, video and stills.
 * This program connects preview and video to the preview and video
 * encoder. Using mmal we don't need to worry about buffers between these
 * components, but we do need to handle buffers from the encoder, which
 * are simply written straight to the file in the requisite buffer callback.
 *
 * If raw option is selected, a video splitter component is connected between
 * camera and preview. This allows us to set up callback for raw camera data
 * (in YUV420 or RGB format) which might be useful for further image processing.
 *
 * We use the RaspiCamControl code to handle the specific camera settings.
 * We use the RaspiPreview code to handle the (generic) preview window
 */

// We use some GNU extensions (basename)
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <memory.h>
#include <sysexits.h>

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>

#include <sys/mman.h>
#include <sys/stat.h> /* For mode constants */
#include <fcntl.h> /* For O_* constants */

#include "bcm_host.h"
#include "interface/vcos/vcos.h"

#include "interface/mmal/mmal.h"
#include "interface/mmal/mmal_logging.h"
#include "interface/mmal/mmal_buffer.h"
#include "interface/mmal/util/mmal_util.h"
#include "interface/mmal/util/mmal_util_params.h"
#include "interface/mmal/util/mmal_default_components.h"
#include "interface/mmal/util/mmal_connection.h"
#include "interface/mmal/mmal_parameters_camera.h"

#include "RaspiCommonSettings.h"
#include "RaspiCamControl.h"
#include "RaspiPreview.h"
#include "RaspiCLI.h"
#include "RaspiHelpers.h"
#include "RaspiGPS.h"

#include <semaphore.h>

#include <stdbool.h>

typedef unsigned char u8;
typedef unsigned int u32;

FILE* s_fdLog = NULL;
int s_bLog = 1;
int s_iDebug = 0;
u8* s_pSharedMemComm = NULL;
int s_bQuit = 0;

// From camera ---------------------------------------------------------
/// Structure to cross reference exposure strings against the MMAL parameter equivalent
static XREF_T  exposure_map[] =
{
   {"off",           MMAL_PARAM_EXPOSUREMODE_OFF},
   {"auto",          MMAL_PARAM_EXPOSUREMODE_AUTO},
   {"night",         MMAL_PARAM_EXPOSUREMODE_NIGHT},
   {"nightpreview",  MMAL_PARAM_EXPOSUREMODE_NIGHTPREVIEW},
   {"backlight",     MMAL_PARAM_EXPOSUREMODE_BACKLIGHT},
   {"spotlight",     MMAL_PARAM_EXPOSUREMODE_SPOTLIGHT},
   {"sports",        MMAL_PARAM_EXPOSUREMODE_SPORTS},
   {"snow",          MMAL_PARAM_EXPOSUREMODE_SNOW},
   {"beach",         MMAL_PARAM_EXPOSUREMODE_BEACH},
   {"verylong",      MMAL_PARAM_EXPOSUREMODE_VERYLONG},
   {"fixedfps",      MMAL_PARAM_EXPOSUREMODE_FIXEDFPS},
   {"antishake",     MMAL_PARAM_EXPOSUREMODE_ANTISHAKE},
   {"fireworks",     MMAL_PARAM_EXPOSUREMODE_FIREWORKS}
};

static const int exposure_map_size = sizeof(exposure_map) / sizeof(exposure_map[0]);

/// Structure to cross reference flicker avoid strings against the MMAL parameter equivalent

static XREF_T  flicker_avoid_map[] =
{
   {"off",           MMAL_PARAM_FLICKERAVOID_OFF},
   {"auto",          MMAL_PARAM_FLICKERAVOID_AUTO},
   {"50hz",          MMAL_PARAM_FLICKERAVOID_50HZ},
   {"60hz",          MMAL_PARAM_FLICKERAVOID_60HZ}
};

static const int flicker_avoid_map_size = sizeof(flicker_avoid_map) / sizeof(flicker_avoid_map[0]);

/// Structure to cross reference awb strings against the MMAL parameter equivalent
static XREF_T awb_map[] =
{
   {"off",           MMAL_PARAM_AWBMODE_OFF},
   {"auto",          MMAL_PARAM_AWBMODE_AUTO},
   {"sun",           MMAL_PARAM_AWBMODE_SUNLIGHT},
   {"cloud",         MMAL_PARAM_AWBMODE_CLOUDY},
   {"shade",         MMAL_PARAM_AWBMODE_SHADE},
   {"tungsten",      MMAL_PARAM_AWBMODE_TUNGSTEN},
   {"fluorescent",   MMAL_PARAM_AWBMODE_FLUORESCENT},
   {"incandescent",  MMAL_PARAM_AWBMODE_INCANDESCENT},
   {"flash",         MMAL_PARAM_AWBMODE_FLASH},
   {"horizon",       MMAL_PARAM_AWBMODE_HORIZON},
   {"greyworld",     MMAL_PARAM_AWBMODE_GREYWORLD}
};

static const int awb_map_size = sizeof(awb_map) / sizeof(awb_map[0]);

/// Structure to cross reference image effect against the MMAL parameter equivalent
static XREF_T imagefx_map[] =
{
   {"none",          MMAL_PARAM_IMAGEFX_NONE},
   {"negative",      MMAL_PARAM_IMAGEFX_NEGATIVE},
   {"solarise",      MMAL_PARAM_IMAGEFX_SOLARIZE},
   {"sketch",        MMAL_PARAM_IMAGEFX_SKETCH},
   {"denoise",       MMAL_PARAM_IMAGEFX_DENOISE},
   {"emboss",        MMAL_PARAM_IMAGEFX_EMBOSS},
   {"oilpaint",      MMAL_PARAM_IMAGEFX_OILPAINT},
   {"hatch",         MMAL_PARAM_IMAGEFX_HATCH},
   {"gpen",          MMAL_PARAM_IMAGEFX_GPEN},
   {"pastel",        MMAL_PARAM_IMAGEFX_PASTEL},
   {"watercolour",   MMAL_PARAM_IMAGEFX_WATERCOLOUR},
   {"film",          MMAL_PARAM_IMAGEFX_FILM},
   {"blur",          MMAL_PARAM_IMAGEFX_BLUR},
   {"saturation",    MMAL_PARAM_IMAGEFX_SATURATION},
   {"colourswap",    MMAL_PARAM_IMAGEFX_COLOURSWAP},
   {"washedout",     MMAL_PARAM_IMAGEFX_WASHEDOUT},
   {"posterise",     MMAL_PARAM_IMAGEFX_POSTERISE},
   {"colourpoint",   MMAL_PARAM_IMAGEFX_COLOURPOINT},
   {"colourbalance", MMAL_PARAM_IMAGEFX_COLOURBALANCE},
   {"cartoon",       MMAL_PARAM_IMAGEFX_CARTOON}
};

static const int imagefx_map_size = sizeof(imagefx_map) / sizeof(imagefx_map[0]);

static XREF_T metering_mode_map[] =
{
   {"average",       MMAL_PARAM_EXPOSUREMETERINGMODE_AVERAGE},
   {"spot",          MMAL_PARAM_EXPOSUREMETERINGMODE_SPOT},
   {"backlit",       MMAL_PARAM_EXPOSUREMETERINGMODE_BACKLIT},
   {"matrix",        MMAL_PARAM_EXPOSUREMETERINGMODE_MATRIX}
};

static const int metering_mode_map_size = sizeof(metering_mode_map)/sizeof(metering_mode_map[0]);

static XREF_T drc_mode_map[] =
{
   {"off",           MMAL_PARAMETER_DRC_STRENGTH_OFF},
   {"low",           MMAL_PARAMETER_DRC_STRENGTH_LOW},
   {"med",           MMAL_PARAMETER_DRC_STRENGTH_MEDIUM},
   {"high",          MMAL_PARAMETER_DRC_STRENGTH_HIGH}
};

static const int drc_mode_map_size = sizeof(drc_mode_map)/sizeof(drc_mode_map[0]);

static XREF_T stereo_mode_map[] =
{
   {"off",           MMAL_STEREOSCOPIC_MODE_NONE},
   {"sbs",           MMAL_STEREOSCOPIC_MODE_SIDE_BY_SIDE},
   {"tb",            MMAL_STEREOSCOPIC_MODE_TOP_BOTTOM},
};

static const int stereo_mode_map_size = sizeof(stereo_mode_map)/sizeof(stereo_mode_map[0]);
 
// From camera ---------------------------------------------------------

// Standard port setting for the camera component
#define MMAL_CAMERA_PREVIEW_PORT 0
#define MMAL_CAMERA_VIDEO_PORT 1
#define MMAL_CAMERA_CAPTURE_PORT 2

// Port configuration for the splitter component
#define SPLITTER_OUTPUT_PORT 0
#define SPLITTER_PREVIEW_PORT 1

// Video format information
// 0 implies variable
#define VIDEO_FRAME_RATE_NUM 30
#define VIDEO_FRAME_RATE_DEN 1

/// Video render needs at least 2 buffers.
#define VIDEO_OUTPUT_BUFFERS_NUM 3

// Max bitrate we allow for recording
const int MAX_BITRATE_MJPEG = 25000000; // 25Mbits/s
const int MAX_BITRATE_LEVEL4 = 25000000; // 25Mbits/s
const int MAX_BITRATE_LEVEL42 = 62500000; // 62.5Mbits/s

/// Interval at which we check for an failure abort during capture
const int ABORT_INTERVAL = 10; // ms


/// Capture/Pause switch method
/// Simply capture for time specified
enum
{
   WAIT_METHOD_NONE,       /// Simply capture for time specified
   WAIT_METHOD_TIMED,      /// Cycle between capture and pause for times specified
   WAIT_METHOD_KEYPRESS,   /// Switch between capture and pause on keypress
   WAIT_METHOD_SIGNAL,     /// Switch between capture and pause on signal
   WAIT_METHOD_FOREVER     /// Run/record forever
};

// Forward
typedef struct RASPIVID_STATE_S RASPIVID_STATE;

/** Struct used to pass information in encoder port userdata to callback
 */
typedef struct
{
   FILE *file_handle;                   /// File handle to write buffer data to.
   RASPIVID_STATE *pstate;              /// pointer to our state in case required in callback
   int abort;                           /// Set to 1 in callback if an error occurs to attempt to abort the capture
   char *cb_buff;                       /// Circular buffer
   int   cb_len;                        /// Length of buffer
   int   cb_wptr;                       /// Current write pointer
   int   cb_wrap;                       /// Has buffer wrapped at least once?
   int   cb_data;                       /// Valid bytes in buffer
#define IFRAME_BUFSIZE (60*1000)
   int   iframe_buff[IFRAME_BUFSIZE];          /// buffer of iframe pointers
   int   iframe_buff_wpos;
   int   iframe_buff_rpos;
   char  header_bytes[29];
   int  header_wptr;
   FILE *imv_file_handle;               /// File handle to write inline motion vectors to.
   FILE *raw_file_handle;               /// File handle to write raw data to.
   int  flush_buffers;
   FILE *pts_file_handle;               /// File timestamps
} PORT_USERDATA;

/** Possible raw output formats
 */
typedef enum
{
   RAW_OUTPUT_FMT_YUV = 0,
   RAW_OUTPUT_FMT_RGB,
   RAW_OUTPUT_FMT_GRAY,
} RAW_OUTPUT_FMT;

/** Structure containing all state information for the current run
 */
struct RASPIVID_STATE_S
{
   RASPICOMMONSETTINGS_PARAMETERS common_settings;     /// Common settings
   int timeout;                        /// Time taken before frame is grabbed and app then shuts down. Units are milliseconds
   MMAL_FOURCC_T encoding;             /// Requested codec video encoding (MJPEG or H264)
   int bitrate;                        /// Requested bitrate
   int framerate;                      /// Requested frame rate (fps)
   int intraperiod;                    /// Intra-refresh period (key frame rate)
   int quantisationParameter;          /// Quantisation parameter - quality. Set bitrate 0 and set this for variable bitrate
   int bInlineHeaders;                  /// Insert inline headers to stream (SPS, PPS)
   int demoMode;                       /// Run app in demo mode
   int demoInterval;                   /// Interval between camera settings changes
   int immutableInput;                 /// Flag to specify whether encoder works in place or creates a new buffer. Result is preview can display either
   /// the camera output or the encoder output (with compression artifacts)
   int profile;                        /// H264 profile to use for encoding
   int level;                          /// H264 level to use for encoding
   int waitMethod;                     /// Method for switching between pause and capture

   int onTime;                         /// In timed cycle mode, the amount of time the capture is on per cycle
   int offTime;                        /// In timed cycle mode, the amount of time the capture is off per cycle

   int segmentSize;                    /// Segment mode In timed cycle mode, the amount of time the capture is off per cycle
   int segmentWrap;                    /// Point at which to wrap segment counter
   int segmentNumber;                  /// Current segment counter
   int splitNow;                       /// Split at next possible i-frame if set to 1.
   int splitWait;                      /// Switch if user wants splited files

   RASPIPREVIEW_PARAMETERS preview_parameters;   /// Preview setup parameters
   RASPICAM_CAMERA_PARAMETERS camera_parameters; /// Camera setup parameters

   MMAL_COMPONENT_T *camera_component;    /// Pointer to the camera component
   MMAL_COMPONENT_T *splitter_component;  /// Pointer to the splitter component
   MMAL_COMPONENT_T *encoder_component;   /// Pointer to the encoder component
   MMAL_CONNECTION_T *preview_connection; /// Pointer to the connection from camera or splitter to preview
   MMAL_CONNECTION_T *splitter_connection;/// Pointer to the connection from camera to splitter
   MMAL_CONNECTION_T *encoder_connection; /// Pointer to the connection from camera to encoder

   MMAL_POOL_T *splitter_pool; /// Pointer to the pool of buffers used by splitter output port 0
   MMAL_POOL_T *encoder_pool; /// Pointer to the pool of buffers used by encoder output port

   PORT_USERDATA callback_data;        /// Used to move data to the encoder callback

   int bCapturing;                     /// State of capture/pause
   int bCircularBuffer;                /// Whether we are writing to a circular buffer

   int inlineMotionVectors;             /// Encoder outputs inline Motion Vectors
   char *imv_filename;                  /// filename of inline Motion Vectors output
   int raw_output;                      /// Output raw video from camera as well
   RAW_OUTPUT_FMT raw_output_fmt;       /// The raw video format
   char *raw_filename;                  /// Filename for raw video output
   int intra_refresh_type;              /// What intra refresh type to use. -1 to not set.
   int frame;
   char *pts_filename;
   int save_pts;
   int64_t starttime;
   int64_t lasttime;

   bool netListen;
   MMAL_BOOL_T addSPSTiming;
   int slices;
};


/// Structure to cross reference H264 profile strings against the MMAL parameter equivalent
static XREF_T  profile_map[] =
{
   {"baseline",     MMAL_VIDEO_PROFILE_H264_BASELINE},
   {"main",         MMAL_VIDEO_PROFILE_H264_MAIN},
   {"extended",     MMAL_VIDEO_PROFILE_H264_EXTENDED},
   {"high",         MMAL_VIDEO_PROFILE_H264_HIGH},
//   {"constrained",  MMAL_VIDEO_PROFILE_H264_CONSTRAINED_BASELINE} // Does anyone need this?
};

static int profile_map_size = sizeof(profile_map) / sizeof(profile_map[0]);

/// Structure to cross reference H264 level strings against the MMAL parameter equivalent
static XREF_T  level_map[] =
{
   {"4",           MMAL_VIDEO_LEVEL_H264_4},
   {"4.1",         MMAL_VIDEO_LEVEL_H264_41},
   {"4.2",         MMAL_VIDEO_LEVEL_H264_42},
};

static int level_map_size = sizeof(level_map) / sizeof(level_map[0]);

static XREF_T  initial_map[] =
{
   {"record",     0},
   {"pause",      1},
};

static int initial_map_size = sizeof(initial_map) / sizeof(initial_map[0]);

static XREF_T  intra_refresh_map[] =
{
   {"cyclic",       MMAL_VIDEO_INTRA_REFRESH_CYCLIC},
   {"adaptive",     MMAL_VIDEO_INTRA_REFRESH_ADAPTIVE},
   {"both",         MMAL_VIDEO_INTRA_REFRESH_BOTH},
   {"cyclicrows",   MMAL_VIDEO_INTRA_REFRESH_CYCLIC_MROWS},
//   {"random",       MMAL_VIDEO_INTRA_REFRESH_PSEUDO_RAND} Cannot use random, crashes the encoder. No idea why.
};

static int intra_refresh_map_size = sizeof(intra_refresh_map) / sizeof(intra_refresh_map[0]);

static XREF_T  raw_output_fmt_map[] =
{
   {"yuv",  RAW_OUTPUT_FMT_YUV},
   {"rgb",  RAW_OUTPUT_FMT_RGB},
   {"gray", RAW_OUTPUT_FMT_GRAY},
};

static int raw_output_fmt_map_size = sizeof(raw_output_fmt_map) / sizeof(raw_output_fmt_map[0]);

/// Command ID's and Structure defining our command line options
enum
{
   CommandBitrate,
   CommandTimeout,
   CommandDemoMode,
   CommandFramerate,
   CommandPreviewEnc,
   CommandIntraPeriod,
   CommandProfile,
   CommandTimed,
   CommandSignal,
   CommandKeypress,
   CommandInitialState,
   CommandQP,
   CommandInlineHeaders,
   CommandSegmentFile,
   CommandSegmentWrap,
   CommandSegmentStart,
   CommandSplitWait,
   CommandCircular,
   CommandIMV,
   CommandIntraRefreshType,
   CommandFlush,
   CommandSavePTS,
   CommandCodec,
   CommandLevel,
   CommandRaw,
   CommandRawFormat,
   CommandNetListen,
   CommandSPSTimings,
   CommandSlices
};

static COMMAND_LIST cmdline_commands[] =
{
   { CommandBitrate,       "-bitrate",    "b",  "Set bitrate. Use bits per second (e.g. 10MBits/s would be -b 10000000)", 1 },
   { CommandTimeout,       "-timeout",    "t",  "Time (in ms) to capture for. If not specified, set to 5s. Zero to disable", 1 },
   { CommandDemoMode,      "-demo",       "d",  "Run a demo mode (cycle through range of camera options, no capture)", 1},
   { CommandFramerate,     "-framerate",  "fps","Specify the frames per second to record", 1},
   { CommandPreviewEnc,    "-penc",       "e",  "Display preview image *after* encoding (shows compression artifacts)", 0},
   { CommandIntraPeriod,   "-intra",      "g",  "Specify the intra refresh period (key frame rate/GoP size). Zero to produce an initial I-frame and then just P-frames.", 1},
   { CommandProfile,       "-profile",    "pf", "Specify H264 profile to use for encoding", 1},
   { CommandTimed,         "-timed",      "td", "Cycle between capture and pause. -cycle on,off where on is record time and off is pause time in ms", 0},
   { CommandSignal,        "-signal",     "s",  "Cycle between capture and pause on Signal", 0},
   { CommandKeypress,      "-keypress",   "k",  "Cycle between capture and pause on ENTER", 0},
   { CommandInitialState,  "-initial",    "i",  "Initial state. Use 'record' or 'pause'. Default 'record'", 1},
   { CommandQP,            "-qp",         "qp", "Quantisation parameter. Use approximately 10-40. Default 0 (off)", 1},
   { CommandInlineHeaders, "-inline",     "ih", "Insert inline headers (SPS, PPS) to stream", 0},
   { CommandSegmentFile,   "-segment",    "sg", "Segment output file in to multiple files at specified interval <ms>", 1},
   { CommandSegmentWrap,   "-wrap",       "wr", "In segment mode, wrap any numbered filename back to 1 when reach number", 1},
   { CommandSegmentStart,  "-start",      "sn", "In segment mode, start with specified segment number", 1},
   { CommandSplitWait,     "-split",      "sp", "In wait mode, create new output file for each start event", 0},
   { CommandCircular,      "-circular",   "c",  "Run encoded data through circular buffer until triggered then save", 0},
   { CommandIMV,           "-vectors",    "x",  "Output filename <filename> for inline motion vectors", 1 },
   { CommandIntraRefreshType,"-irefresh", "if", "Set intra refresh type", 1},
   { CommandFlush,         "-flush",      "fl",  "Flush buffers in order to decrease latency", 0 },
   { CommandSavePTS,       "-save-pts",   "pts","Save Timestamps to file for mkvmerge", 1 },
   { CommandCodec,         "-codec",      "cd", "Specify the codec to use - H264 (default) or MJPEG", 1 },
   { CommandLevel,         "-level",      "lev","Specify H264 level to use for encoding", 1},
   { CommandRaw,           "-raw",        "r",  "Output filename <filename> for raw video", 1 },
   { CommandRawFormat,     "-raw-format", "rf", "Specify output format for raw video. Default is yuv", 1},
   { CommandNetListen,     "-listen",     "l", "Listen on a TCP socket", 0},
   { CommandSPSTimings,    "-spstimings",    "stm", "Add in h.264 sps timings", 0},
   { CommandSlices   ,     "-slices",     "sl", "Horizontal slices per frame. Default 1 (off)", 1},
};

static int cmdline_commands_size = sizeof(cmdline_commands) / sizeof(cmdline_commands[0]);


static struct
{
   char *description;
   int nextWaitMethod;
} wait_method_description[] =
{
   {"Simple capture",         WAIT_METHOD_NONE},
   {"Capture forever",        WAIT_METHOD_FOREVER},
   {"Cycle on time",          WAIT_METHOD_TIMED},
   {"Cycle on keypress",      WAIT_METHOD_KEYPRESS},
   {"Cycle on signal",        WAIT_METHOD_SIGNAL},
};

static int wait_method_description_size = sizeof(wait_method_description) / sizeof(wait_method_description[0]);



/**
 * Assign a default set of parameters to the state passed in
 *
 * @param state Pointer to state structure to assign defaults to
 */
static void default_status(RASPIVID_STATE *state)
{
   if (!state)
   {
      vcos_assert(0);
      return;
   }

   // Default everything to zero
   memset(state, 0, sizeof(RASPIVID_STATE));

   raspicommonsettings_set_defaults(&state->common_settings);

   if ( s_bLog )
   {
      fprintf(s_fdLog, "Setting default settings\n");
      fflush(s_fdLog);
   }
   // Now set anything non-zero
   state->timeout = -1; // replaced with 5000ms later if unset
   state->common_settings.width = 1920;       // Default to 1080p
   state->common_settings.height = 1080;
   state->encoding = MMAL_ENCODING_H264;
   state->bitrate = 17000000; // This is a decent default bitrate for 1080p
   state->framerate = VIDEO_FRAME_RATE_NUM;
   state->intraperiod = -1;    // Not set
   state->quantisationParameter = 0;
   state->demoMode = 0;
   state->demoInterval = 250; // ms
   state->immutableInput = 1;
   state->profile = MMAL_VIDEO_PROFILE_H264_HIGH;
   state->level = MMAL_VIDEO_LEVEL_H264_4;
   state->waitMethod = WAIT_METHOD_NONE;
   state->onTime = 5000;
   state->offTime = 5000;
   state->bCapturing = 0;
   state->bInlineHeaders = 0;
   state->segmentSize = 0;  // 0 = not segmenting the file.
   state->segmentNumber = 1;
   state->segmentWrap = 0; // Point at which to wrap segment number back to 1. 0 = no wrap
   state->splitNow = 0;
   state->splitWait = 0;
   state->inlineMotionVectors = 0;
   state->intra_refresh_type = -1;
   state->frame = 0;
   state->save_pts = 0;
   state->netListen = false;
   state->addSPSTiming = MMAL_FALSE;
   state->slices = 1;


   // Setup preview window defaults
   raspipreview_set_defaults(&state->preview_parameters);

   // Set up the camera_parameters to default
   raspicamcontrol_set_defaults(&state->camera_parameters);
}

static void check_camera_model(int cam_num)
{
   MMAL_COMPONENT_T *camera_info;
   MMAL_STATUS_T status;

   // Try to get the camera name
   status = mmal_component_create(MMAL_COMPONENT_DEFAULT_CAMERA_INFO, &camera_info);
   if (status == MMAL_SUCCESS)
   {
      MMAL_PARAMETER_CAMERA_INFO_T param;
      param.hdr.id = MMAL_PARAMETER_CAMERA_INFO;
      param.hdr.size = sizeof(param)-4;  // Deliberately undersize to check firmware version
      status = mmal_port_parameter_get(camera_info->control, &param.hdr);

      if (status != MMAL_SUCCESS)
      {
         // Running on newer firmware
         param.hdr.size = sizeof(param);
         status = mmal_port_parameter_get(camera_info->control, &param.hdr);
         if (status == MMAL_SUCCESS && param.num_cameras > cam_num)
         {
            if (!strncmp(param.cameras[cam_num].camera_name, "toshh2c", 7))
            {
               if ( s_bLog )
               {
               fprintf(s_fdLog, "The driver for the TC358743 HDMI to CSI2 chip you are using is NOT supported.\n");
               fprintf(s_fdLog, "They were written for a demo purposes only, and are in the firmware on an as-is\n");
               fprintf(s_fdLog, "basis and therefore requests for support or changes will not be acted on.\n\n");
               fflush(s_fdLog);
               }
            }
         }
      }

      mmal_component_destroy(camera_info);
   }
}

/**
 * Dump image state parameters to stderr.
 *
 * @param state Pointer to state structure to assign defaults to
 */
static void dump_status(RASPIVID_STATE *state)
{
   int i;

   if (!state)
   {
      vcos_assert(0);
      return;
   }

   //raspicommonsettings_dump_parameters(&state->common_settings);
   if ( s_bLog )
   {
   fprintf(s_fdLog, "-----------------------------------------------\n");
   fprintf(s_fdLog, "Camera Name %s\n", state->common_settings.camera_name);
   fprintf(s_fdLog, "Width %d, Height %d, filename %s\n", state->common_settings.width,
           state->common_settings.height, state->common_settings.filename);
   fprintf(s_fdLog, "Using camera %d, sensor mode %d\n\n", state->common_settings.cameraNum, state->common_settings.sensor_mode);
   if ( state->common_settings.gps )
      fprintf(s_fdLog, "GPS output %s\n\n", state->common_settings.gps ? "Enabled" : "Disabled"); 
   fprintf(s_fdLog, "-----------------------------------------------\n");
   }

   if ( s_bLog )
   {
   fprintf(s_fdLog, "bitrate %d, framerate %d, time delay %d\n", state->bitrate, state->framerate, state->timeout);
   fprintf(s_fdLog, "H264 Profile %s\n", raspicli_unmap_xref(state->profile, profile_map, profile_map_size));
   fprintf(s_fdLog, "H264 Level %s\n", raspicli_unmap_xref(state->level, level_map, level_map_size));
   fprintf(s_fdLog, "H264 Quantisation level %d, Inline headers %s\n", state->quantisationParameter, state->bInlineHeaders ? "Yes" : "No");
   fprintf(s_fdLog, "H264 Fill SPS Timings %s\n", state->addSPSTiming ? "Yes" : "No");
   fprintf(s_fdLog, "H264 Intra refresh type %s, period %d\n", raspicli_unmap_xref(state->intra_refresh_type, intra_refresh_map, intra_refresh_map_size), state->intraperiod);
   fprintf(s_fdLog, "H264 Slices %d\n", state->slices);

   fprintf(s_fdLog, "H264 Cyclic Rows IF: width: %d->%f, height: %d->%f\n", (int)state->common_settings.width, (float)state->common_settings.width/16.0, (int)state->common_settings.height, (float)state->common_settings.height/16.0);

   fprintf(s_fdLog, "Segment size %d, segment wrap value %d, initial segment number %d\n", state->segmentSize, state->segmentWrap, state->segmentNumber);
   fflush(s_fdLog);
   }


   if (state->raw_output && s_bLog)
   {
      fprintf(s_fdLog, "Raw output enabled, format %s\n", raspicli_unmap_xref(state->raw_output_fmt, raw_output_fmt_map, raw_output_fmt_map_size));
      fflush(s_fdLog);
   }

   if ( s_bLog )
   {
   fprintf(s_fdLog, "Wait method : ");
   for (i=0; i<wait_method_description_size; i++)
   {
      if (state->waitMethod == wait_method_description[i].nextWaitMethod)
         fprintf(s_fdLog, "%s", wait_method_description[i].description);
   }
   fprintf(s_fdLog, "\nInitial state '%s'\n", raspicli_unmap_xref(state->bCapturing, initial_map, initial_map_size));
   fprintf(s_fdLog, "\n\n");
   fflush(s_fdLog);
   }

   //raspipreview_dump_parameters(&state->preview_parameters);
   if ( s_bLog )
   {
      fprintf(s_fdLog, "-----------------------------------------------\n");
      fprintf(s_fdLog, "Preview %s, Full screen %s\n", state->preview_parameters.wantPreview ? "Yes" : "No",
           state->preview_parameters.wantFullScreenPreview ? "Yes" : "No");
      fprintf(s_fdLog, "Preview window %d,%d,%d,%d\nOpacity %d\n", state->preview_parameters.previewWindow.x,
           state->preview_parameters.previewWindow.y, state->preview_parameters.previewWindow.width,
           state->preview_parameters.previewWindow.height, state->preview_parameters.opacity); 
      fprintf(s_fdLog, "-----------------------------------------------\n");
   }


   //raspicamcontrol_dump_parameters(&state->camera_parameters);

   if ( s_bLog )
   {
   const char *exp_mode = raspicli_unmap_xref(state->camera_parameters.exposureMode, exposure_map, exposure_map_size);
   const char *fl_mode = raspicli_unmap_xref(state->camera_parameters.flickerAvoidMode, flicker_avoid_map, flicker_avoid_map_size);
   const char *awb_mode = raspicli_unmap_xref(state->camera_parameters.awbMode, awb_map, awb_map_size);
   const char *image_effect = raspicli_unmap_xref(state->camera_parameters.imageEffect, imagefx_map, imagefx_map_size);
   const char *metering_mode = raspicli_unmap_xref(state->camera_parameters.exposureMeterMode, metering_mode_map, metering_mode_map_size);

      fprintf(s_fdLog, "-----------------------------------------------\n");
   fprintf(s_fdLog, "Sharpness %d, Contrast %d, Brightness %d\n", state->camera_parameters.sharpness, state->camera_parameters.contrast, state->camera_parameters.brightness);
   fprintf(s_fdLog, "Saturation %d, ISO %d, Video Stabilisation %s, Exposure compensation %d\n", state->camera_parameters.saturation, state->camera_parameters.ISO, state->camera_parameters.videoStabilisation ? "Yes": "No", state->camera_parameters.exposureCompensation);
   fprintf(s_fdLog, "Exposure Mode '%s', AWB Mode '%s', Image Effect '%s'\n", exp_mode, awb_mode, image_effect);
   fprintf(s_fdLog, "Flicker Avoid Mode '%s'\n", fl_mode);
   fprintf(s_fdLog, "Metering Mode '%s', Colour Effect Enabled %s with U = %d, V = %d\n", metering_mode, state->camera_parameters.colourEffects.enable ? "Yes":"No", state->camera_parameters.colourEffects.u, state->camera_parameters.colourEffects.v);
   fprintf(s_fdLog, "Rotation %d, hflip %s, vflip %s\n", state->camera_parameters.rotation, state->camera_parameters.hflip ? "Yes":"No",state->camera_parameters.vflip ? "Yes":"No");
   fprintf(s_fdLog, "ROI x %lf, y %f, w %f h %f\n", state->camera_parameters.roi.x, state->camera_parameters.roi.y, state->camera_parameters.roi.w, state->camera_parameters.roi.h); 
      fprintf(s_fdLog, "-----------------------------------------------\n");
   }
}

/**
 * Display usage information for the application to stdout
 *
 * @param app_name String to display as the application name
 */
static void application_help_message(char *app_name)
{
   int i;

   fprintf(stdout, "Display camera output to display, and optionally saves an H264 capture at requested bitrate\n\n");
   fprintf(stdout, "\nusage: %s [options]\n\n", app_name);

   fprintf(stdout, "Image parameter commands\n\n");

   raspicli_display_help(cmdline_commands, cmdline_commands_size);

   // Profile options
   fprintf(stdout, "\n\nH264 Profile options :\n%s", profile_map[0].mode );

   for (i=1; i<profile_map_size; i++)
   {
      fprintf(stdout, ",%s", profile_map[i].mode);
   }

   // Level options
   fprintf(stdout, "\n\nH264 Level options :\n%s", level_map[0].mode );

   for (i=1; i<level_map_size; i++)
   {
      fprintf(stdout, ",%s", level_map[i].mode);
   }

   // Intra refresh options
   fprintf(stdout, "\n\nH264 Intra refresh options :\n%s", intra_refresh_map[0].mode );

   for (i=1; i<intra_refresh_map_size; i++)
   {
      fprintf(stdout, ",%s", intra_refresh_map[i].mode);
   }

   // Raw output format options
   fprintf(stdout, "\n\nRaw output format options :\n%s", raw_output_fmt_map[0].mode );

   for (i=1; i<raw_output_fmt_map_size; i++)
   {
      fprintf(stdout, ",%s", raw_output_fmt_map[i].mode);
   }

   fprintf(stdout, "\n\n");

   fprintf(stdout, "Raspivid allows output to a remote IPv4 host e.g. -o tcp://192.168.1.2:1234"
           "or -o udp://192.168.1.2:1234\n"
           "To listen on a TCP port (IPv4) and wait for an incoming connection use the -l option\n"
           "e.g. raspivid -l -o tcp://0.0.0.0:3333 -> bind to all network interfaces,\n"
           "raspivid -l -o tcp://192.168.1.1:3333 -> bind to a certain local IPv4 port\n");

   return;
}

/**
 * Parse the incoming command line and put resulting parameters in to the state
 *
 * @param argc Number of arguments in command line
 * @param argv Array of pointers to strings from command line
 * @param state Pointer to state structure to assign any discovered parameters to
 * @return Non-0 if failed for some reason, 0 otherwise
 */
static int parse_cmdline(int argc, const char **argv, RASPIVID_STATE *state)
{
   // Parse the command line arguments.
   // We are looking for --<something> or -<abbreviation of something>

   int valid = 1;
   int i;

   for (i = 1; i < argc && valid; i++)
   {
      int command_id, num_parameters;

      if (!argv[i])
         continue;

      if (argv[i][0] != '-')
      {
         valid = 0;
         continue;
      }

      // Assume parameter is valid until proven otherwise
      valid = 1;

      if ( strcmp(argv[i], "-log") == 0 )
      {
         s_bLog = 1;
         continue;
      }

      if ( strcmp(argv[i], "-dbg") == 0 )
      {
         s_iDebug = 1;
         s_bLog = 1;
         continue;
      }

      command_id = raspicli_get_command_id(cmdline_commands, cmdline_commands_size, &argv[i][1], &num_parameters);

      // If we found a command but are missing a parameter, continue (and we will drop out of the loop)
      if (command_id != -1 && num_parameters > 0 && (i + 1 >= argc) )
         continue;

      //  We are now dealing with a command line option
      switch (command_id)
      {
      case CommandBitrate: // 1-100
         if (sscanf(argv[i + 1], "%u", &state->bitrate) == 1)
         {
            i++;
         }
         else
            valid = 0;

         break;

      case CommandTimeout: // Time to run viewfinder/capture
      {
         if (sscanf(argv[i + 1], "%d", &state->timeout) == 1)
         {
            // Ensure that if previously selected a waitMethod we don't overwrite it
            if (state->timeout == 0 && state->waitMethod == WAIT_METHOD_NONE)
               state->waitMethod = WAIT_METHOD_FOREVER;

            i++;
         }
         else
            valid = 0;
         break;
      }

      case CommandDemoMode: // Run in demo mode - no capture
      {
         // Demo mode might have a timing parameter
         // so check if a) we have another parameter, b) its not the start of the next option
         if (i + 1 < argc  && argv[i+1][0] != '-')
         {
            if (sscanf(argv[i + 1], "%u", &state->demoInterval) == 1)
            {
               // TODO : What limits do we need for timeout?
               if (state->demoInterval == 0)
                  state->demoInterval = 250; // ms

               state->demoMode = 1;
               i++;
            }
            else
               valid = 0;
         }
         else
         {
            state->demoMode = 1;
         }

         break;
      }

      case CommandFramerate: // fps to record
      {
         if (sscanf(argv[i + 1], "%u", &state->framerate) == 1)
         {
            // TODO : What limits do we need for fps 1 - 30 - 120??
            i++;
         }
         else
            valid = 0;
         break;
      }

      case CommandPreviewEnc:
         state->immutableInput = 0;
         break;

      case CommandIntraPeriod: // key frame rate
      {
         if (sscanf(argv[i + 1], "%u", &state->intraperiod) == 1)
            i++;
         else
            valid = 0;
         break;
      }

      case CommandQP: // quantisation parameter
      {
         if (sscanf(argv[i + 1], "%u", &state->quantisationParameter) == 1)
            i++;
         else
            valid = 0;
         break;
      }

      case CommandProfile: // H264 profile
      {
         state->profile = raspicli_map_xref(argv[i + 1], profile_map, profile_map_size);

         if( state->profile == -1)
            state->profile = MMAL_VIDEO_PROFILE_H264_HIGH;

         i++;
         break;
      }

      case CommandInlineHeaders: // H264 inline headers
      {
         state->bInlineHeaders = 1;
         break;
      }

      case CommandTimed:
      {
         if (sscanf(argv[i + 1], "%u,%u", &state->onTime, &state->offTime) == 2)
         {
            i++;

            if (state->onTime < 1000)
               state->onTime = 1000;

            if (state->offTime < 1000)
               state->offTime = 1000;

            state->waitMethod = WAIT_METHOD_TIMED;

            if (state->timeout == -1)
               state->timeout = 0;
         }
         else
            valid = 0;
         break;
      }

      case CommandKeypress:
         state->waitMethod = WAIT_METHOD_KEYPRESS;

         if (state->timeout == -1)
            state->timeout = 0;

         break;

      case CommandSignal:
         state->waitMethod = WAIT_METHOD_SIGNAL;
         // Reenable the signal
         signal(SIGUSR1, default_signal_handler);

         if (state->timeout == -1)
            state->timeout = 0;

         break;

      case CommandInitialState:
      {
         state->bCapturing = raspicli_map_xref(argv[i + 1], initial_map, initial_map_size);

         if( state->bCapturing == -1)
            state->bCapturing = 0;

         i++;
         break;
      }

      case CommandSegmentFile: // Segment file in to chunks of specified time
      {
         if (sscanf(argv[i + 1], "%u", &state->segmentSize) == 1)
         {
            // Must enable inline headers for this to work
            state->bInlineHeaders = 1;
            i++;
         }
         else
            valid = 0;
         break;
      }

      case CommandSegmentWrap: // segment wrap value
      {
         if (sscanf(argv[i + 1], "%u", &state->segmentWrap) == 1)
            i++;
         else
            valid = 0;
         break;
      }

      case CommandSegmentStart: // initial segment number
      {
         if((sscanf(argv[i + 1], "%u", &state->segmentNumber) == 1) && (!state->segmentWrap || (state->segmentNumber <= state->segmentWrap)))
            i++;
         else
            valid = 0;
         break;
      }

      case CommandSplitWait: // split files on restart
      {
         // Must enable inline headers for this to work
         state->bInlineHeaders = 1;
         state->splitWait = 1;
         break;
      }

      case CommandCircular:
      {
         state->bCircularBuffer = 1;
         break;
      }

      case CommandIMV:  // output filename
      {
         state->inlineMotionVectors = 1;
         int len = strlen(argv[i + 1]);
         if (len)
         {
            state->imv_filename = malloc(len + 1);
            vcos_assert(state->imv_filename);
            if (state->imv_filename)
               strncpy(state->imv_filename, argv[i + 1], len+1);
            i++;
         }
         else
            valid = 0;
         break;
      }

      case CommandIntraRefreshType:
      {
         state->intra_refresh_type = raspicli_map_xref(argv[i + 1], intra_refresh_map, intra_refresh_map_size);
         i++;
         break;
      }

      case CommandFlush:
      {
         state->callback_data.flush_buffers = 1;
         break;
      }
      case CommandSavePTS:  // output filename
      {
         state->save_pts = 1;
         int len = strlen(argv[i + 1]);
         if (len)
         {
            state->pts_filename = malloc(len + 1);
            vcos_assert(state->pts_filename);
            if (state->pts_filename)
               strncpy(state->pts_filename, argv[i + 1], len+1);
            i++;
         }
         else
            valid = 0;
         break;
      }
      case CommandCodec:  // codec type
      {
         int len = strlen(argv[i + 1]);
         if (len)
         {
            if (len==4 && !strncmp("H264", argv[i+1], 4))
               state->encoding = MMAL_ENCODING_H264;
            else  if (len==5 && !strncmp("MJPEG", argv[i+1], 5))
               state->encoding = MMAL_ENCODING_MJPEG;
            else
               valid = 0;
            i++;
         }
         else
            valid = 0;
         break;
      }

      case CommandLevel: // H264 level
      {
         state->level = raspicli_map_xref(argv[i + 1], level_map, level_map_size);

         if( state->level == -1)
            state->level = MMAL_VIDEO_LEVEL_H264_4;

         i++;
         break;
      }

      case CommandRaw:  // output filename
      {
         state->raw_output = 1;
         //state->raw_output_fmt defaults to 0 / yuv
         int len = strlen(argv[i + 1]);
         if (len)
         {
            state->raw_filename = malloc(len + 1);
            vcos_assert(state->raw_filename);
            if (state->raw_filename)
               strncpy(state->raw_filename, argv[i + 1], len+1);
            i++;
         }
         else
            valid = 0;
         break;
      }

      case CommandRawFormat:
      {
         state->raw_output_fmt = raspicli_map_xref(argv[i + 1], raw_output_fmt_map, raw_output_fmt_map_size);

         if (state->raw_output_fmt == -1)
            valid = 0;

         i++;
         break;
      }

      case CommandNetListen:
      {
         state->netListen = true;

         break;
      }
      case CommandSlices:
      {
         if ((sscanf(argv[i + 1], "%d", &state->slices) == 1) && (state->slices > 0))
            i++;
         else
            valid = 0;
         break;
      }

      case CommandSPSTimings:
      {
         state->addSPSTiming = MMAL_TRUE;

         break;
      }

      default:
      {
         // Try parsing for any image specific parameters
         // result indicates how many parameters were used up, 0,1,2
         // but we adjust by -1 as we have used one already
         const char *second_arg = (i + 1 < argc) ? argv[i + 1] : NULL;
         int parms_used = (raspicamcontrol_parse_cmdline(&state->camera_parameters, &argv[i][1], second_arg));

         // Still unused, try common settings
         if (!parms_used)
            parms_used = raspicommonsettings_parse_cmdline(&state->common_settings, &argv[i][1], second_arg, &application_help_message);

         // Still unused, try preview options
         if (!parms_used)
            parms_used = raspipreview_parse_cmdline(&state->preview_parameters, &argv[i][1], second_arg);

         // If no parms were used, this must be a bad parameter
         if (!parms_used)
            valid = 0;
         else
            i += parms_used - 1;

         break;
      }
      }
   }

   if (!valid)
   {
      if ( s_bLog )
      {
         fprintf(s_fdLog, "Invalid command line option (%s)\n", argv[i-1]);
         fflush(s_fdLog);
      }
      return 1;
   }

   return 0;
}

/**
 * Open a file based on the settings in state
 *
 * @param state Pointer to state
 */
static FILE *open_filename(RASPIVID_STATE *pState, char *filename)
{
   FILE *new_handle = NULL;
   char *tempname = NULL;

   if (pState->segmentSize || pState->splitWait)
   {
      // Create a new filename string

      //If %d/%u or any valid combination e.g. %04d is specified, assume segment number.
      bool bSegmentNumber = false;
      const char* pPercent = strchr(filename, '%');
      if (pPercent)
      {
         pPercent++;
         while (isdigit(*pPercent))
            pPercent++;
         if (*pPercent == 'u' || *pPercent == 'd')
            bSegmentNumber = true;
      }

      if (bSegmentNumber)
      {
         asprintf(&tempname, filename, pState->segmentNumber);
      }
      else
      {
         char temp_ts_str[100];
         time_t t = time(NULL);
         struct tm *tm = localtime(&t);
         strftime(temp_ts_str, 100, filename, tm);
         asprintf(&tempname, "%s", temp_ts_str);
      }

      filename = tempname;
   }

   if (filename)
   {
      bool bNetwork = false;
      int sfd = -1, socktype;

      if(!strncmp("tcp://", filename, 6))
      {
         bNetwork = true;
         socktype = SOCK_STREAM;
      }
      else if(!strncmp("udp://", filename, 6))
      {
         if (pState->netListen)
         {
            if ( s_bLog )
            {
               fprintf(s_fdLog, "No support for listening in UDP mode\n");
               fflush(s_fdLog);
            }
            exit(131);
         }
         bNetwork = true;
         socktype = SOCK_DGRAM;
      }

      if(bNetwork)
      {
         unsigned short port;
         filename += 6;
         char *colon;
         if(NULL == (colon = strchr(filename, ':')))
         {
            if ( s_bLog )
            {
               fprintf(s_fdLog, "%s is not a valid IPv4:port, use something like tcp://1.2.3.4:1234 or udp://1.2.3.4:1234\n",
                    filename);
               fflush(s_fdLog);
            }
            exit(132);
         }
         if(1 != sscanf(colon + 1, "%hu", &port))
         {
            if ( s_bLog )
            {
               fprintf(s_fdLog,
                    "Port parse failed. %s is not a valid network file name, use something like tcp://1.2.3.4:1234 or udp://1.2.3.4:1234\n",
                    filename);
               fflush(s_fdLog);
            }
            exit(133);
         }
         char chTmp = *colon;
         *colon = 0;

         struct sockaddr_in saddr= {};
         saddr.sin_family = AF_INET;
         saddr.sin_port = htons(port);
         if(0 == inet_aton(filename, &saddr.sin_addr))
         {
            if ( s_bLog )
            {
               fprintf(s_fdLog, "inet_aton failed. %s is not a valid IPv4 address\n",
                    filename);
               fflush(s_fdLog);
            }
            exit(134);
         }
         *colon = chTmp;

         if (pState->netListen)
         {
            int sockListen = socket(AF_INET, SOCK_STREAM, 0);
            if (sockListen >= 0)
            {
               int iTmp = 1;
               setsockopt(sockListen, SOL_SOCKET, SO_REUSEADDR, &iTmp, sizeof(int));//no error handling, just go on
               if (bind(sockListen, (struct sockaddr *) &saddr, sizeof(saddr)) >= 0)
               {
                  while ((-1 == (iTmp = listen(sockListen, 0))) && (EINTR == errno))
                     ;
                  if (-1 != iTmp)
                  {
                     if ( s_bLog )
                     {
                     fprintf(s_fdLog, "Waiting for a TCP connection on %s:%"SCNu16"...",
                             inet_ntoa(saddr.sin_addr), ntohs(saddr.sin_port));
                     fflush(s_fdLog);
                     }
                     struct sockaddr_in cli_addr;
                     socklen_t clilen = sizeof(cli_addr);
                     while ((-1 == (sfd = accept(sockListen, (struct sockaddr *) &cli_addr, &clilen))) && (EINTR == errno))
                        ;
                     if ( s_bLog )
                     {
                     if (sfd >= 0)
                        fprintf(s_fdLog, "Client connected from %s:%"SCNu16"\n", inet_ntoa(cli_addr.sin_addr), ntohs(cli_addr.sin_port));
                     else
                        fprintf(s_fdLog, "Error on accept: %s\n", strerror(errno));
                     }
                  }
                  else//if (-1 != iTmp)
                  {
                     if ( s_bLog )
                        fprintf(s_fdLog, "Error trying to listen on a socket: %s\n", strerror(errno));
                  }
               }
               else//if (bind(sockListen, (struct sockaddr *) &saddr, sizeof(saddr)) >= 0)
               {
                  if ( s_bLog )
                  {
                     fprintf(s_fdLog, "Error on binding socket: %s\n", strerror(errno));
                     fflush(s_fdLog);
                  }
               }
            }
            else//if (sockListen >= 0)
            {
               if ( s_bLog )
               {
                  fprintf(s_fdLog, "Error creating socket: %s\n", strerror(errno));
                  fflush(s_fdLog);
               }
            }

            if (sockListen >= 0)//regardless success or error
               close(sockListen);//do not listen on a given port anymore
         }
         else//if (pState->netListen)
         {
            if(0 <= (sfd = socket(AF_INET, socktype, 0)))
            {
               if ( s_bLog )
               {
                  fprintf(s_fdLog, "Connecting to %s:%hu...", inet_ntoa(saddr.sin_addr), port);
                  fflush(s_fdLog);
               }
               int iTmp = 1;
               while ((-1 == (iTmp = connect(sfd, (struct sockaddr *) &saddr, sizeof(struct sockaddr_in)))) && (EINTR == errno))
                  ;

               if ( s_bLog )
               {
               if (iTmp < 0)
                  fprintf(s_fdLog, "error: %s\n", strerror(errno));
               else
                  fprintf(s_fdLog, "connected, sending video...\n");
               fflush(s_fdLog);
               }
            }
            else
               if ( s_bLog )
               {
                  fprintf(s_fdLog, "Error creating socket: %s\n", strerror(errno));
                  fflush(s_fdLog);
               }
         }

         if (sfd >= 0)
            new_handle = fdopen(sfd, "w");
      }
      else
      {
         new_handle = fopen(filename, "wb");
      }
   }

   if (s_bLog)
   {
      if (new_handle)
         fprintf(s_fdLog, "Opening output file \"%s\"\n", filename);
      else
         fprintf(s_fdLog, "Failed to open new file \"%s\"\n", filename);
      fflush(s_fdLog);
   }

   if (tempname)
      free(tempname);

   return new_handle;
}

/**
 * Update any annotation data specific to the video.
 * This simply passes on the setting from cli, or
 * if application defined annotate requested, updates
 * with the H264 parameters
 *
 * @param state Pointer to state control struct
 *
 */
static void update_annotation_data(RASPIVID_STATE *state, int iSecond)
{
   //if ( s_bLog )
   //{
   //   fprintf(s_fdLog, "Annotation check\n");
   //   fflush(s_fdLog);
   //}

   // So, if we have asked for a application supplied string, set it to the H264 or GPS parameters
   if (state->camera_parameters.enable_annotate & ANNOTATE_APP_TEXT)
   {
      /*
      char *text;

      if (state->common_settings.gps)
      {
         text = raspi_gps_location_string();
      }
      else
      {
         const char *refresh = raspicli_unmap_xref(state->intra_refresh_type, intra_refresh_map, intra_refresh_map_size);

         asprintf(&text,  "%dk,%df,%s,%d,%s,%s %d:%02d",
                  state->bitrate / 1000,  state->framerate,
                  refresh ? refresh : "(none)",
                  state->intraperiod,
                  raspicli_unmap_xref(state->profile, profile_map, profile_map_size),
                  raspicli_unmap_xref(state->level, level_map, level_map_size), iSecond/60, iSecond%60);
      }

      raspicamcontrol_set_annotate(state->camera_component, state->camera_parameters.enable_annotate, text,
                                   state->camera_parameters.annotate_text_size,
                                   state->camera_parameters.annotate_text_colour,
                                   state->camera_parameters.annotate_bg_colour,
                                   state->camera_parameters.annotate_justify,
                                   state->camera_parameters.annotate_x,
                                   state->camera_parameters.annotate_y
                                  );

      free(text);
      */
   }
   else
   {
      if ( state->camera_parameters.annotate_string[0] != 0 )
      {
         /*
         const char *refresh = raspicli_unmap_xref(state->intra_refresh_type, intra_refresh_map, intra_refresh_map_size);
         char szBuff[512];
         sprintf(szBuff,  "%s: %dkb,%dfps,%s,%d,%s,%s,%d:%02d",
                  state->camera_parameters.annotate_string,
                  state->bitrate / 1000,  state->framerate,
                  refresh ? refresh : "(none)",
                  state->intraperiod,
                  raspicli_unmap_xref(state->profile, profile_map, profile_map_size),
                  raspicli_unmap_xref(state->level, level_map, level_map_size), iSecond/60, iSecond%60);
         */
         raspicamcontrol_set_annotate(state->camera_component, state->camera_parameters.enable_annotate, state->camera_parameters.annotate_string,
                                   state->camera_parameters.annotate_text_size*0.3,
                                   state->camera_parameters.annotate_text_colour,
                                   state->camera_parameters.annotate_bg_colour,
                                   state->camera_parameters.annotate_justify,
                                   state->camera_parameters.annotate_x,
                                   state->camera_parameters.annotate_y+70
                                  );
      }
   }
}

/**
 *  buffer header callback function for encoder
 *
 *  Callback will dump buffer data to the specific file
 *
 * @param port Pointer to port from which callback originated
 * @param buffer mmal buffer header pointer
 */
static void encoder_buffer_callback(MMAL_PORT_T *port, MMAL_BUFFER_HEADER_T *buffer)
{
   MMAL_BUFFER_HEADER_T *new_buffer;
   static int64_t base_time =  -1;
   static int64_t last_second = -1;

   // All our segment times based on the receipt of the first encoder callback
   if (base_time == -1)
      base_time = get_microseconds64()/1000;

   // We pass our file handle and other stuff in via the userdata field.

   PORT_USERDATA *pData = (PORT_USERDATA *)port->userdata;

   if (pData)
   {
      int bytes_written = buffer->length;
      int64_t current_time = get_microseconds64()/1000;

      vcos_assert(pData->file_handle);
      if(pData->pstate->inlineMotionVectors) vcos_assert(pData->imv_file_handle);

      if (pData->cb_buff)
      {
         int space_in_buff = pData->cb_len - pData->cb_wptr;
         int copy_to_end = space_in_buff > buffer->length ? buffer->length : space_in_buff;
         int copy_to_start = buffer->length - copy_to_end;

         if(buffer->flags & MMAL_BUFFER_HEADER_FLAG_CONFIG)
         {
            if(pData->header_wptr + buffer->length > sizeof(pData->header_bytes))
            {
               vcos_log_error("Error in header bytes\n");
            }
            else
            {
               // These are the header bytes, save them for final output
               mmal_buffer_header_mem_lock(buffer);
               memcpy(pData->header_bytes + pData->header_wptr, buffer->data, buffer->length);
               mmal_buffer_header_mem_unlock(buffer);
               pData->header_wptr += buffer->length;
            }
         }
         else if((buffer->flags & MMAL_BUFFER_HEADER_FLAG_CODECSIDEINFO))
         {
            // Do something with the inline motion vectors...
         }
         else
         {
            static int frame_start = -1;
            int i;

            if(frame_start == -1)
               frame_start = pData->cb_wptr;

            if(buffer->flags & MMAL_BUFFER_HEADER_FLAG_KEYFRAME)
            {
               pData->iframe_buff[pData->iframe_buff_wpos] = frame_start;
               pData->iframe_buff_wpos = (pData->iframe_buff_wpos + 1) % IFRAME_BUFSIZE;
            }

            if(buffer->flags & MMAL_BUFFER_HEADER_FLAG_FRAME_END)
               frame_start = -1;

            // If we overtake the iframe rptr then move the rptr along
            if((pData->iframe_buff_rpos + 1) % IFRAME_BUFSIZE != pData->iframe_buff_wpos)
            {
               while(
                  (
                     pData->cb_wptr <= pData->iframe_buff[pData->iframe_buff_rpos] &&
                     (pData->cb_wptr + buffer->length) > pData->iframe_buff[pData->iframe_buff_rpos]
                  ) ||
                  (
                     (pData->cb_wptr > pData->iframe_buff[pData->iframe_buff_rpos]) &&
                     (pData->cb_wptr + buffer->length) > (pData->iframe_buff[pData->iframe_buff_rpos] + pData->cb_len)
                  )
               )
                  pData->iframe_buff_rpos = (pData->iframe_buff_rpos + 1) % IFRAME_BUFSIZE;
            }

            mmal_buffer_header_mem_lock(buffer);
            // We are pushing data into a circular buffer
            memcpy(pData->cb_buff + pData->cb_wptr, buffer->data, copy_to_end);
            memcpy(pData->cb_buff, buffer->data + copy_to_end, copy_to_start);
            mmal_buffer_header_mem_unlock(buffer);

            if((pData->cb_wptr + buffer->length) > pData->cb_len)
               pData->cb_wrap = 1;

            pData->cb_wptr = (pData->cb_wptr + buffer->length) % pData->cb_len;

            for(i = pData->iframe_buff_rpos; i != pData->iframe_buff_wpos; i = (i + 1) % IFRAME_BUFSIZE)
            {
               int p = pData->iframe_buff[i];
               if(pData->cb_buff[p] != 0 || pData->cb_buff[p+1] != 0 || pData->cb_buff[p+2] != 0 || pData->cb_buff[p+3] != 1)
               {
                  vcos_log_error("Error in iframe list\n");
               }
            }
         }
      }
      else
      {
         // For segmented record mode, we need to see if we have exceeded our time/size,
         // but also since we have inline headers turned on we need to break when we get one to
         // ensure that the new stream has the header in it. If we break on an I-frame, the
         // SPS/PPS header is actually in the previous chunk.
         if ((buffer->flags & MMAL_BUFFER_HEADER_FLAG_CONFIG) &&
               ((pData->pstate->segmentSize && current_time > base_time + pData->pstate->segmentSize) ||
                (pData->pstate->splitWait && pData->pstate->splitNow)))
         {
            FILE *new_handle;

            base_time = current_time;

            pData->pstate->splitNow = 0;
            pData->pstate->segmentNumber++;

            // Only wrap if we have a wrap point set
            if (pData->pstate->segmentWrap && pData->pstate->segmentNumber > pData->pstate->segmentWrap)
               pData->pstate->segmentNumber = 1;

            if (pData->pstate->common_settings.filename && pData->pstate->common_settings.filename[0] != '-')
            {
               new_handle = open_filename(pData->pstate, pData->pstate->common_settings.filename);

               if (new_handle)
               {
                  fclose(pData->file_handle);
                  pData->file_handle = new_handle;
               }
            }

            if (pData->pstate->imv_filename && pData->pstate->imv_filename[0] != '-')
            {
               new_handle = open_filename(pData->pstate, pData->pstate->imv_filename);

               if (new_handle)
               {
                  fclose(pData->imv_file_handle);
                  pData->imv_file_handle = new_handle;
               }
            }

            if (pData->pstate->pts_filename && pData->pstate->pts_filename[0] != '-')
            {
               new_handle = open_filename(pData->pstate, pData->pstate->pts_filename);

               if (new_handle)
               {
                  fclose(pData->pts_file_handle);
                  pData->pts_file_handle = new_handle;
               }
            }
         }
         if (buffer->length)
         {
            mmal_buffer_header_mem_lock(buffer);
            if(buffer->flags & MMAL_BUFFER_HEADER_FLAG_CODECSIDEINFO)
            {
               if(pData->pstate->inlineMotionVectors)
               {
                  bytes_written = fwrite(buffer->data, 1, buffer->length, pData->imv_file_handle);
                  if(pData->flush_buffers) fflush(pData->imv_file_handle);
               }
               else
               {
                  //We do not want to save inlineMotionVectors...
                  bytes_written = buffer->length;
               }
            }
            else
            {
               bytes_written = fwrite(buffer->data, 1, buffer->length, pData->file_handle);
               if(pData->flush_buffers)
               {
                   fflush(pData->file_handle);
                   fdatasync(fileno(pData->file_handle));
               }

               if (pData->pstate->save_pts &&
                  !(buffer->flags & MMAL_BUFFER_HEADER_FLAG_CONFIG) &&
                  buffer->pts != MMAL_TIME_UNKNOWN &&
                  buffer->pts != pData->pstate->lasttime)
               {
                  int64_t pts;
                  if (pData->pstate->frame == 0)
                     pData->pstate->starttime = buffer->pts;
                  pData->pstate->lasttime = buffer->pts;
                  pts = buffer->pts - pData->pstate->starttime;
                  fprintf(pData->pts_file_handle, "%lld.%03lld\n", pts/1000, pts%1000);
                  pData->pstate->frame++;
               }
            }

            mmal_buffer_header_mem_unlock(buffer);

            if (bytes_written != buffer->length)
            {
               vcos_log_error("Failed to write buffer data (%d from %d)- aborting", bytes_written, buffer->length);
               pData->abort = 1;
            }
         }
      }

      // See if the second count has changed and we need to update any annotation
      if (current_time/1000 != last_second)
      {
         update_annotation_data(pData->pstate, (int)last_second);
         last_second = current_time/1000;
      }
   }
   else
   {
      vcos_log_error("Received a encoder buffer callback with no state");
   }

   // release buffer back to the pool
   mmal_buffer_header_release(buffer);

   // and send one back to the port (if still open)
   if (port->is_enabled)
   {
      MMAL_STATUS_T status;

      new_buffer = mmal_queue_get(pData->pstate->encoder_pool->queue);

      if (new_buffer)
         status = mmal_port_send_buffer(port, new_buffer);

      if (!new_buffer || status != MMAL_SUCCESS)
         vcos_log_error("Unable to return a buffer to the encoder port");
   }
}

/**
 *  buffer header callback function for splitter
 *
 *  Callback will dump buffer data to the specific file
 *
 * @param port Pointer to port from which callback originated
 * @param buffer mmal buffer header pointer
 */
static void splitter_buffer_callback(MMAL_PORT_T *port, MMAL_BUFFER_HEADER_T *buffer)
{
   MMAL_BUFFER_HEADER_T *new_buffer;
   PORT_USERDATA *pData = (PORT_USERDATA *)port->userdata;

   if (pData)
   {
      int bytes_written = 0;
      int bytes_to_write = buffer->length;

      /* Write only luma component to get grayscale image: */
      if (buffer->length && pData->pstate->raw_output_fmt == RAW_OUTPUT_FMT_GRAY)
         bytes_to_write = port->format->es->video.width * port->format->es->video.height;

      vcos_assert(pData->raw_file_handle);

      if (bytes_to_write)
      {
         mmal_buffer_header_mem_lock(buffer);
         bytes_written = fwrite(buffer->data, 1, bytes_to_write, pData->raw_file_handle);
         mmal_buffer_header_mem_unlock(buffer);

         if (bytes_written != bytes_to_write)
         {
            vcos_log_error("Failed to write raw buffer data (%d from %d)- aborting", bytes_written, bytes_to_write);
            pData->abort = 1;
         }
      }
   }
   else
   {
      vcos_log_error("Received a camera buffer callback with no state");
   }

   // release buffer back to the pool
   mmal_buffer_header_release(buffer);

   // and send one back to the port (if still open)
   if (port->is_enabled)
   {
      MMAL_STATUS_T status;

      new_buffer = mmal_queue_get(pData->pstate->splitter_pool->queue);

      if (new_buffer)
         status = mmal_port_send_buffer(port, new_buffer);

      if (!new_buffer || status != MMAL_SUCCESS)
         vcos_log_error("Unable to return a buffer to the splitter port");
   }
}

/**
 * Create the camera component, set up its ports
 *
 * @param state Pointer to state control struct
 *
 * @return MMAL_SUCCESS if all OK, something else otherwise
 *
 */
static MMAL_STATUS_T create_camera_component(RASPIVID_STATE *state)
{
   MMAL_COMPONENT_T *camera = 0;
   MMAL_ES_FORMAT_T *format;
   MMAL_PORT_T *preview_port = NULL, *video_port = NULL, *still_port = NULL;
   MMAL_STATUS_T status;

   /* Create the component */
   status = mmal_component_create(MMAL_COMPONENT_DEFAULT_CAMERA, &camera);

   if (status != MMAL_SUCCESS)
   {
      vcos_log_error("Failed to create camera component");
      goto error;
   }

   status = raspicamcontrol_set_stereo_mode(camera->output[0], &state->camera_parameters.stereo_mode);
   status += raspicamcontrol_set_stereo_mode(camera->output[1], &state->camera_parameters.stereo_mode);
   status += raspicamcontrol_set_stereo_mode(camera->output[2], &state->camera_parameters.stereo_mode);

   if (status != MMAL_SUCCESS)
   {
      vcos_log_error("Could not set stereo mode : error %d", status);
      goto error;
   }

   MMAL_PARAMETER_INT32_T camera_num =
   {{MMAL_PARAMETER_CAMERA_NUM, sizeof(camera_num)}, state->common_settings.cameraNum};

   status = mmal_port_parameter_set(camera->control, &camera_num.hdr);

   if (status != MMAL_SUCCESS)
   {
      vcos_log_error("Could not select camera : error %d", status);
      goto error;
   }

   if (!camera->output_num)
   {
      status = MMAL_ENOSYS;
      vcos_log_error("Camera doesn't have output ports");
      goto error;
   }

   status = mmal_port_parameter_set_uint32(camera->control, MMAL_PARAMETER_CAMERA_CUSTOM_SENSOR_CONFIG, state->common_settings.sensor_mode);

   if (status != MMAL_SUCCESS)
   {
      vcos_log_error("Could not set sensor mode : error %d", status);
      goto error;
   }

   preview_port = camera->output[MMAL_CAMERA_PREVIEW_PORT];
   video_port = camera->output[MMAL_CAMERA_VIDEO_PORT];
   still_port = camera->output[MMAL_CAMERA_CAPTURE_PORT];

   // Enable the camera, and tell it its control callback function
   status = mmal_port_enable(camera->control, default_camera_control_callback);

   if (status != MMAL_SUCCESS)
   {
      vcos_log_error("Unable to enable control port : error %d", status);
      goto error;
   }

   //  set up the camera configuration
   {
      MMAL_PARAMETER_CAMERA_CONFIG_T cam_config =
      {
         { MMAL_PARAMETER_CAMERA_CONFIG, sizeof(cam_config) },
         .max_stills_w = state->common_settings.width,
         .max_stills_h = state->common_settings.height,
         .stills_yuv422 = 0,
         .one_shot_stills = 0,
         .max_preview_video_w = state->common_settings.width,
         .max_preview_video_h = state->common_settings.height,
         .num_preview_video_frames = 3 + vcos_max(0, (state->framerate-30)/10),
         .stills_capture_circular_buffer_height = 0,
         .fast_preview_resume = 0,
         .use_stc_timestamp = MMAL_PARAM_TIMESTAMP_MODE_RAW_STC
      };
      mmal_port_parameter_set(camera->control, &cam_config.hdr);
   }

   // Now set up the port formats

   // Set the encode format on the Preview port
   // HW limitations mean we need the preview to be the same size as the required recorded output

   format = preview_port->format;

   format->encoding = MMAL_ENCODING_OPAQUE;
   format->encoding_variant = MMAL_ENCODING_I420;

   if(state->camera_parameters.shutter_speed > 6000000)
   {
      MMAL_PARAMETER_FPS_RANGE_T fps_range = {{MMAL_PARAMETER_FPS_RANGE, sizeof(fps_range)},
         { 5, 1000 }, {166, 1000}
      };
      mmal_port_parameter_set(preview_port, &fps_range.hdr);
   }
   else if(state->camera_parameters.shutter_speed > 1000000)
   {
      MMAL_PARAMETER_FPS_RANGE_T fps_range = {{MMAL_PARAMETER_FPS_RANGE, sizeof(fps_range)},
         { 166, 1000 }, {999, 1000}
      };
      mmal_port_parameter_set(preview_port, &fps_range.hdr);
   }

   //enable dynamic framerate if necessary
   if (state->camera_parameters.shutter_speed)
   {
      if (state->framerate > 1000000./state->camera_parameters.shutter_speed)
      {
         state->framerate=0;
         if (s_bLog)
         {
            fprintf(s_fdLog, "Enable dynamic frame rate to fulfil shutter speed requirement\n");
            fflush(s_fdLog);
         }
      }
   }

   format->encoding = MMAL_ENCODING_OPAQUE;
   format->es->video.width = VCOS_ALIGN_UP(state->common_settings.width, 32);
   format->es->video.height = VCOS_ALIGN_UP(state->common_settings.height, 16);
   format->es->video.crop.x = 0;
   format->es->video.crop.y = 0;
   format->es->video.crop.width = state->common_settings.width;
   format->es->video.crop.height = state->common_settings.height;
   format->es->video.frame_rate.num = state->framerate;
   format->es->video.frame_rate.den = VIDEO_FRAME_RATE_DEN;

   status = mmal_port_format_commit(preview_port);

   if (status != MMAL_SUCCESS)
   {
      vcos_log_error("camera viewfinder format couldn't be set");
      goto error;
   }

   // Set the encode format on the video  port

   format = video_port->format;
   format->encoding_variant = MMAL_ENCODING_I420;

   if(state->camera_parameters.shutter_speed > 6000000)
   {
      MMAL_PARAMETER_FPS_RANGE_T fps_range = {{MMAL_PARAMETER_FPS_RANGE, sizeof(fps_range)},
         { 5, 1000 }, {166, 1000}
      };
      mmal_port_parameter_set(video_port, &fps_range.hdr);
   }
   else if(state->camera_parameters.shutter_speed > 1000000)
   {
      MMAL_PARAMETER_FPS_RANGE_T fps_range = {{MMAL_PARAMETER_FPS_RANGE, sizeof(fps_range)},
         { 167, 1000 }, {999, 1000}
      };
      mmal_port_parameter_set(video_port, &fps_range.hdr);
   }

   format->encoding = MMAL_ENCODING_OPAQUE;
   format->es->video.width = VCOS_ALIGN_UP(state->common_settings.width, 32);
   format->es->video.height = VCOS_ALIGN_UP(state->common_settings.height, 16);
   format->es->video.crop.x = 0;
   format->es->video.crop.y = 0;
   format->es->video.crop.width = state->common_settings.width;
   format->es->video.crop.height = state->common_settings.height;
   format->es->video.frame_rate.num = state->framerate;
   format->es->video.frame_rate.den = VIDEO_FRAME_RATE_DEN;

   status = mmal_port_format_commit(video_port);

   if (status != MMAL_SUCCESS)
   {
      vcos_log_error("camera video format couldn't be set");
      goto error;
   }

   // Ensure there are enough buffers to avoid dropping frames
   if (video_port->buffer_num < VIDEO_OUTPUT_BUFFERS_NUM)
      video_port->buffer_num = VIDEO_OUTPUT_BUFFERS_NUM;


   // Set the encode format on the still  port

   format = still_port->format;

   format->encoding = MMAL_ENCODING_OPAQUE;
   format->encoding_variant = MMAL_ENCODING_I420;

   format->es->video.width = VCOS_ALIGN_UP(state->common_settings.width, 32);
   format->es->video.height = VCOS_ALIGN_UP(state->common_settings.height, 16);
   format->es->video.crop.x = 0;
   format->es->video.crop.y = 0;
   format->es->video.crop.width = state->common_settings.width;
   format->es->video.crop.height = state->common_settings.height;
   format->es->video.frame_rate.num = 0;
   format->es->video.frame_rate.den = 1;

   status = mmal_port_format_commit(still_port);

   if (status != MMAL_SUCCESS)
   {
      vcos_log_error("camera still format couldn't be set");
      goto error;
   }

   /* Ensure there are enough buffers to avoid dropping frames */
   if (still_port->buffer_num < VIDEO_OUTPUT_BUFFERS_NUM)
      still_port->buffer_num = VIDEO_OUTPUT_BUFFERS_NUM;

   /* Enable component */
   status = mmal_component_enable(camera);

   if (status != MMAL_SUCCESS)
   {
      vcos_log_error("camera component couldn't be enabled");
      goto error;
   }

   // Note: this sets lots of parameters that were not individually addressed before.
   raspicamcontrol_set_all_parameters(camera, &state->camera_parameters);

   state->camera_component = camera;

   update_annotation_data(state, 0);

   if (s_bLog)
   {
      fprintf(s_fdLog, "Camera component done\n");
      fflush(s_fdLog);
   }
   return status;

error:

   if (camera)
      mmal_component_destroy(camera);

   return status;
}

/**
 * Destroy the camera component
 *
 * @param state Pointer to state control struct
 *
 */
static void destroy_camera_component(RASPIVID_STATE *state)
{
   if (state->camera_component)
   {
      mmal_component_destroy(state->camera_component);
      state->camera_component = NULL;
   }
}

/**
 * Create the splitter component, set up its ports
 *
 * @param state Pointer to state control struct
 *
 * @return MMAL_SUCCESS if all OK, something else otherwise
 *
 */
static MMAL_STATUS_T create_splitter_component(RASPIVID_STATE *state)
{
   MMAL_COMPONENT_T *splitter = 0;
   MMAL_PORT_T *splitter_output = NULL;
   MMAL_ES_FORMAT_T *format;
   MMAL_STATUS_T status;
   MMAL_POOL_T *pool;
   int i;

   if (state->camera_component == NULL)
   {
      status = MMAL_ENOSYS;
      vcos_log_error("Camera component must be created before splitter");
      goto error;
   }

   /* Create the component */
   status = mmal_component_create(MMAL_COMPONENT_DEFAULT_VIDEO_SPLITTER, &splitter);

   if (status != MMAL_SUCCESS)
   {
      vcos_log_error("Failed to create splitter component");
      goto error;
   }

   if (!splitter->input_num)
   {
      status = MMAL_ENOSYS;
      vcos_log_error("Splitter doesn't have any input port");
      goto error;
   }

   if (splitter->output_num < 2)
   {
      status = MMAL_ENOSYS;
      vcos_log_error("Splitter doesn't have enough output ports");
      goto error;
   }

   /* Ensure there are enough buffers to avoid dropping frames: */
   mmal_format_copy(splitter->input[0]->format, state->camera_component->output[MMAL_CAMERA_PREVIEW_PORT]->format);

   if (splitter->input[0]->buffer_num < VIDEO_OUTPUT_BUFFERS_NUM)
      splitter->input[0]->buffer_num = VIDEO_OUTPUT_BUFFERS_NUM;

   status = mmal_port_format_commit(splitter->input[0]);

   if (status != MMAL_SUCCESS)
   {
      vcos_log_error("Unable to set format on splitter input port");
      goto error;
   }

   /* Splitter can do format conversions, configure format for its output port: */
   for (i = 0; i < splitter->output_num; i++)
   {
      mmal_format_copy(splitter->output[i]->format, splitter->input[0]->format);

      if (i == SPLITTER_OUTPUT_PORT)
      {
         format = splitter->output[i]->format;

         switch (state->raw_output_fmt)
         {
         case RAW_OUTPUT_FMT_YUV:
         case RAW_OUTPUT_FMT_GRAY: /* Grayscale image contains only luma (Y) component */
            format->encoding = MMAL_ENCODING_I420;
            format->encoding_variant = MMAL_ENCODING_I420;
            break;
         case RAW_OUTPUT_FMT_RGB:
            if (mmal_util_rgb_order_fixed(state->camera_component->output[MMAL_CAMERA_CAPTURE_PORT]))
               format->encoding = MMAL_ENCODING_RGB24;
            else
               format->encoding = MMAL_ENCODING_BGR24;
            format->encoding_variant = 0;  /* Irrelevant when not in opaque mode */
            break;
         default:
            status = MMAL_EINVAL;
            vcos_log_error("unknown raw output format");
            goto error;
         }
      }

      status = mmal_port_format_commit(splitter->output[i]);

      if (status != MMAL_SUCCESS)
      {
         vcos_log_error("Unable to set format on splitter output port %d", i);
         goto error;
      }
   }

   /* Enable component */
   status = mmal_component_enable(splitter);

   if (status != MMAL_SUCCESS)
   {
      vcos_log_error("splitter component couldn't be enabled");
      goto error;
   }

   /* Create pool of buffer headers for the output port to consume */
   splitter_output = splitter->output[SPLITTER_OUTPUT_PORT];
   pool = mmal_port_pool_create(splitter_output, splitter_output->buffer_num, splitter_output->buffer_size);

   if (!pool)
   {
      vcos_log_error("Failed to create buffer header pool for splitter output port %s", splitter_output->name);
   }

   state->splitter_pool = pool;
   state->splitter_component = splitter;

   if (s_bLog)
   {
      fprintf(s_fdLog, "Splitter component done\n");
      fflush(s_fdLog);
   }
   return status;

error:

   if (splitter)
      mmal_component_destroy(splitter);

   return status;
}

/**
 * Destroy the splitter component
 *
 * @param state Pointer to state control struct
 *
 */
static void destroy_splitter_component(RASPIVID_STATE *state)
{
   // Get rid of any port buffers first
   if (state->splitter_pool)
   {
      mmal_port_pool_destroy(state->splitter_component->output[SPLITTER_OUTPUT_PORT], state->splitter_pool);
   }

   if (state->splitter_component)
   {
      mmal_component_destroy(state->splitter_component);
      state->splitter_component = NULL;
   }
}

/**
 * Create the encoder component, set up its ports
 *
 * @param state Pointer to state control struct
 *
 * @return MMAL_SUCCESS if all OK, something else otherwise
 *
 */
static MMAL_STATUS_T create_encoder_component(RASPIVID_STATE *state)
{
   MMAL_COMPONENT_T *encoder = 0;
   MMAL_PORT_T *encoder_input = NULL, *encoder_output = NULL;
   MMAL_STATUS_T status;
   MMAL_POOL_T *pool;

   status = mmal_component_create(MMAL_COMPONENT_DEFAULT_VIDEO_ENCODER, &encoder);

   if (status != MMAL_SUCCESS)
   {
      vcos_log_error("Unable to create video encoder component");
      goto error;
   }

   if (!encoder->input_num || !encoder->output_num)
   {
      status = MMAL_ENOSYS;
      vcos_log_error("Video encoder doesn't have input/output ports");
      goto error;
   }

   encoder_input = encoder->input[0];
   encoder_output = encoder->output[0];

   // We want same format on input and output
   mmal_format_copy(encoder_output->format, encoder_input->format);

   // Only supporting H264 at the moment
   encoder_output->format->encoding = state->encoding;

   if(state->encoding == MMAL_ENCODING_H264)
   {
      if(state->level == MMAL_VIDEO_LEVEL_H264_4)
      {
         if(state->bitrate > MAX_BITRATE_LEVEL4)
         {
            state->bitrate = MAX_BITRATE_LEVEL4;
            if ( s_bLog )
            {
               fprintf(s_fdLog, "Bitrate too high: Reducing to 25MBit/s\n");
               fflush(s_fdLog);
            }
         }
      }
      else
      {
         if(state->bitrate > MAX_BITRATE_LEVEL42)
         {
            state->bitrate = MAX_BITRATE_LEVEL42;
            if ( s_bLog )
            {
               fprintf(s_fdLog, "Bitrate too high: Reducing to 62.5MBit/s\n");
               fflush(s_fdLog);
            }
         }
      }
   }
   else if(state->encoding == MMAL_ENCODING_MJPEG)
   {
      if(state->bitrate > MAX_BITRATE_MJPEG)
      {
         state->bitrate = MAX_BITRATE_MJPEG;
         if ( s_bLog )
         {
            fprintf(s_fdLog, "Bitrate too high: Reducing to 25MBit/s\n");
            fflush(s_fdLog);
         }
      }
   }

   encoder_output->format->bitrate = state->bitrate;

   if (state->encoding == MMAL_ENCODING_H264)
      encoder_output->buffer_size = encoder_output->buffer_size_recommended;
   else
      encoder_output->buffer_size = 256<<10;


   if (encoder_output->buffer_size < encoder_output->buffer_size_min)
      encoder_output->buffer_size = encoder_output->buffer_size_min;

   encoder_output->buffer_num = encoder_output->buffer_num_recommended;

   if (encoder_output->buffer_num < encoder_output->buffer_num_min)
      encoder_output->buffer_num = encoder_output->buffer_num_min;

   // We need to set the frame rate on output to 0, to ensure it gets
   // updated correctly from the input framerate when port connected
   encoder_output->format->es->video.frame_rate.num = 0;
   encoder_output->format->es->video.frame_rate.den = 1;

   // Commit the port changes to the output port
   status = mmal_port_format_commit(encoder_output);

   if (status != MMAL_SUCCESS)
   {
      vcos_log_error("Unable to set format on video encoder output port");
      goto error;
   }

   // Set the rate control parameter
   if (0)
   {
      MMAL_PARAMETER_VIDEO_RATECONTROL_T param = {{ MMAL_PARAMETER_RATECONTROL, sizeof(param)}, MMAL_VIDEO_RATECONTROL_DEFAULT};
      status = mmal_port_parameter_set(encoder_output, &param.hdr);
      if (status != MMAL_SUCCESS)
      {
         vcos_log_error("Unable to set ratecontrol");
         goto error;
      }

   }

   if (state->encoding == MMAL_ENCODING_H264 &&
         state->intraperiod != -1)
   {
      MMAL_PARAMETER_UINT32_T param = {{ MMAL_PARAMETER_INTRAPERIOD, sizeof(param)}, state->intraperiod};
      status = mmal_port_parameter_set(encoder_output, &param.hdr);
      if (status != MMAL_SUCCESS)
      {
         vcos_log_error("Unable to set intraperiod");
         goto error;
      }
   }

   if (state->encoding == MMAL_ENCODING_H264 && state->slices > 1 && state->common_settings.width <= 1280)
   {
      int frame_mb_rows = VCOS_ALIGN_UP(state->common_settings.height, 16) >> 4;

      if (state->slices > frame_mb_rows) //warn user if too many slices selected
      {
         // Continue rather than abort..
         if ( s_bLog )
         {
         fprintf(s_fdLog,"H264 Slice count (%d) exceeds number of macroblock rows (%d). Setting slices to %d.\n", state->slices, frame_mb_rows, frame_mb_rows);
         fflush(s_fdLog);
         }
      }
      int slice_row_mb = frame_mb_rows/state->slices;
      if (frame_mb_rows - state->slices*slice_row_mb)
         slice_row_mb++; //must round up to avoid extra slice if not evenly divided

      status = mmal_port_parameter_set_uint32(encoder_output, MMAL_PARAMETER_MB_ROWS_PER_SLICE, slice_row_mb);
      if (status != MMAL_SUCCESS)
      {
         vcos_log_error("Unable to set number of slices");
         goto error;
      }
   }

   if (state->encoding == MMAL_ENCODING_H264 &&
       state->quantisationParameter)
   {
      if ( s_bLog )
      {
         fprintf(s_fdLog,"Setting Quant params...\n");
         fflush(s_fdLog);
      }
      MMAL_PARAMETER_UINT32_T param = {{ MMAL_PARAMETER_VIDEO_ENCODE_INITIAL_QUANT, sizeof(param)}, state->quantisationParameter};
      status = mmal_port_parameter_set(encoder_output, &param.hdr);
      if (status != MMAL_SUCCESS)
      {
         vcos_log_error("Unable to set initial QP");
         goto error;
      }

      MMAL_PARAMETER_UINT32_T param2 = {{ MMAL_PARAMETER_VIDEO_ENCODE_MIN_QUANT, sizeof(param)}, state->quantisationParameter};
      status = mmal_port_parameter_set(encoder_output, &param2.hdr);
      if (status != MMAL_SUCCESS)
      {
         vcos_log_error("Unable to set min QP");
         goto error;
      }

      MMAL_PARAMETER_UINT32_T param3 = {{ MMAL_PARAMETER_VIDEO_ENCODE_MAX_QUANT, sizeof(param)}, state->quantisationParameter};
      status = mmal_port_parameter_set(encoder_output, &param3.hdr);
      if (status != MMAL_SUCCESS)
      {
         vcos_log_error("Unable to set max QP");
         goto error;
      }
   }

   if (state->encoding == MMAL_ENCODING_H264)
   {
      MMAL_PARAMETER_VIDEO_PROFILE_T  param;
      param.hdr.id = MMAL_PARAMETER_PROFILE;
      param.hdr.size = sizeof(param);

      param.profile[0].profile = state->profile;

      if((VCOS_ALIGN_UP(state->common_settings.width,16) >> 4) * (VCOS_ALIGN_UP(state->common_settings.height,16) >> 4) * state->framerate > 245760)
      {
         if((VCOS_ALIGN_UP(state->common_settings.width,16) >> 4) * (VCOS_ALIGN_UP(state->common_settings.height,16) >> 4) * state->framerate <= 522240)
         {
            if ( s_bLog )
            {
               fprintf(s_fdLog, "Too many macroblocks/s: Increasing H264 Level to 4.2\n");
               fflush(s_fdLog);
            }
            state->level=MMAL_VIDEO_LEVEL_H264_42;
         }
         else
         {
            vcos_log_error("Too many macroblocks/s requested");
            status = MMAL_EINVAL;
            goto error;
         }
      }

      param.profile[0].level = state->level;

      status = mmal_port_parameter_set(encoder_output, &param.hdr);
      if (status != MMAL_SUCCESS)
      {
         vcos_log_error("Unable to set H264 profile");
         goto error;
      }
   }

   if (mmal_port_parameter_set_boolean(encoder_input, MMAL_PARAMETER_VIDEO_IMMUTABLE_INPUT, state->immutableInput) != MMAL_SUCCESS)
   {
      vcos_log_error("Unable to set immutable input flag");
      // Continue rather than abort..
   }

   if (state->encoding == MMAL_ENCODING_H264)
   {
      //set INLINE HEADER flag to generate SPS and PPS for every IDR if requested
      if (mmal_port_parameter_set_boolean(encoder_output, MMAL_PARAMETER_VIDEO_ENCODE_INLINE_HEADER, state->bInlineHeaders) != MMAL_SUCCESS)
      {
         vcos_log_error("failed to set INLINE HEADER FLAG parameters");
         // Continue rather than abort..
      }

      //set flag for add SPS TIMING
      if (mmal_port_parameter_set_boolean(encoder_output, MMAL_PARAMETER_VIDEO_ENCODE_SPS_TIMING, state->addSPSTiming) != MMAL_SUCCESS)
      {
         vcos_log_error("failed to set SPS TIMINGS FLAG parameters");
         // Continue rather than abort..
      }

      //set INLINE VECTORS flag to request motion vector estimates
      if (mmal_port_parameter_set_boolean(encoder_output, MMAL_PARAMETER_VIDEO_ENCODE_INLINE_VECTORS, state->inlineMotionVectors) != MMAL_SUCCESS)
      {
         vcos_log_error("failed to set INLINE VECTORS parameters");
         // Continue rather than abort..
      }

      // Adaptive intra refresh settings
      if ( state->intra_refresh_type != -1)
      {
         MMAL_PARAMETER_VIDEO_INTRA_REFRESH_T  param;
         param.hdr.id = MMAL_PARAMETER_VIDEO_INTRA_REFRESH;
         param.hdr.size = sizeof(param);

         // Get first so we don't overwrite anything unexpectedly
         status = mmal_port_parameter_get(encoder_output, &param.hdr);
         if (status != MMAL_SUCCESS)
         {
            vcos_log_warn("Unable to get existing H264 intra-refresh values. Please update your firmware");
            // Set some defaults, don't just pass random stack data
            param.air_mbs = param.air_ref = param.cir_mbs = param.pir_mbs = 0;
         }

         param.refresh_mode = state->intra_refresh_type;

         if (state->intra_refresh_type == MMAL_VIDEO_INTRA_REFRESH_CYCLIC_MROWS)
         {
            param.cir_mbs = ((int)(state->common_settings.width>>4));
            if ( s_bLog )
            {
               fprintf(s_fdLog, "\n\n Set cyclic Rows IF to %d, width: %d->%f, height: %d->%f\n\n", (int)param.cir_mbs, (int)state->common_settings.width, (float)state->common_settings.width/16.0, (int)state->common_settings.height, (float)state->common_settings.height/16.0);
               fflush(s_fdLog);
            }
         }
         status = mmal_port_parameter_set(encoder_output, &param.hdr);
         if (status != MMAL_SUCCESS)
         {
            vcos_log_error("Unable to set H264 intra-refresh values");
            goto error;
         }
      }
   }

   //  Enable component
   status = mmal_component_enable(encoder);

   if (status != MMAL_SUCCESS)
   {
      vcos_log_error("Unable to enable video encoder component");
      goto error;
   }

   /* Create pool of buffer headers for the output port to consume */
   pool = mmal_port_pool_create(encoder_output, encoder_output->buffer_num, encoder_output->buffer_size);

   if (!pool)
   {
      vcos_log_error("Failed to create buffer header pool for encoder output port %s", encoder_output->name);
   }

   state->encoder_pool = pool;
   state->encoder_component = encoder;

   if (s_bLog)
   {
      fprintf(s_fdLog, "Encoder component done\n");
      fflush(s_fdLog);
   }
   return status;

error:
   if (encoder)
      mmal_component_destroy(encoder);

   state->encoder_component = NULL;

   return status;
}

/**
 * Destroy the encoder component
 *
 * @param state Pointer to state control struct
 *
 */
static void destroy_encoder_component(RASPIVID_STATE *state)
{
   // Get rid of any port buffers first
   if (state->encoder_pool)
   {
      mmal_port_pool_destroy(state->encoder_component->output[0], state->encoder_pool);
   }

   if (state->encoder_component)
   {
      mmal_component_destroy(state->encoder_component);
      state->encoder_component = NULL;
   }
}

/**
 * Pause for specified time, but return early if detect an abort request
 *
 * @param state Pointer to state control struct
 * @param pause Time in ms to pause
 * @param callback Struct contain an abort flag tested for early termination
 *
 */
static int pause_and_test_abort(RASPIVID_STATE *state, int pause)
{
   int wait;

   if (!pause)
      return 0;

   // Going to check every ABORT_INTERVAL milliseconds
   for (wait = 0; wait < pause; wait+= ABORT_INTERVAL)
   {
      vcos_sleep(ABORT_INTERVAL);
      if (state->callback_data.abort)
         return 1;
   }

   return 0;
}


void* open_shared_mem(const char* name, int size, int readOnly)
{
   int fd;
   if ( readOnly )
      fd = shm_open(name, O_RDONLY, S_IRUSR | S_IWUSR);
   else
      fd = shm_open(name, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR);
   if(fd < 0)
   {
       if ( s_bLog )
       {
          fprintf(s_fdLog, "Failed to open shared memory: %s, error: %s\n", name, strerror(errno));
          fflush(s_fdLog);
       }
       return NULL;
   }
   if ( ! readOnly )
   if (ftruncate(fd, size) == -1)
   {
       if ( s_bLog )
       {
          fprintf(s_fdLog, "Failed to init (ftruncate) shared memory for writing: %s\n", name);
          fflush(s_fdLog);
       }
       return NULL;   
   }
   void *retval = NULL;
   if ( readOnly )
      retval = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);
   else
      retval = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
   if (retval == MAP_FAILED)
   {
       if ( s_bLog )
       {
          fprintf(s_fdLog, "Failed to map shared memory: %s\n", name);
          fflush(s_fdLog);
       }
      return NULL;
   }
   return retval;
}

void* open_shared_mem_for_write(const char* name, int size)
{
   return open_shared_mem(name, size, 0);
}

void* open_shared_mem_for_read(const char* name, int size)
{
   return open_shared_mem(name, size, 1);
}

void _set_h264_quantization(RASPIVID_STATE* pState, u8 uCommandType, int uParam1)
{
   int status = 0;

   MMAL_PARAMETER_UINT32_T param_quant_start = {{ MMAL_PARAMETER_VIDEO_ENCODE_INITIAL_QUANT, sizeof(param_quant_start)}, 0};
   status = mmal_port_parameter_get(pState->encoder_component->output[0], &param_quant_start.hdr);
   if (status != MMAL_SUCCESS)
   {
       if ( s_bLog )
       {
       fprintf(s_fdLog, "Failed to get qant start param!\n");
       fflush(s_fdLog);
       }
   }
   if ( s_bLog && s_iDebug )
   {
       fprintf(s_fdLog, "Current qant start param: %d\n", param_quant_start.value);
       fflush(s_fdLog);
   }

   MMAL_PARAMETER_UINT32_T param_quant_min = {{ MMAL_PARAMETER_VIDEO_ENCODE_MIN_QUANT, sizeof(param_quant_min)}, 0};
   status = mmal_port_parameter_get(pState->encoder_component->output[0], &param_quant_min.hdr);
   if (status != MMAL_SUCCESS)
   {
       if ( s_bLog )
       {
          fprintf(s_fdLog, "Failed to get quant param min!\n");
          fflush(s_fdLog);
       }
   }
   if ( s_bLog && s_iDebug )
   {
       fprintf(s_fdLog, "Current qant param min: %d\n", param_quant_min.value);
       fflush(s_fdLog);
   }
         
   MMAL_PARAMETER_UINT32_T param_quant_max = {{ MMAL_PARAMETER_VIDEO_ENCODE_MAX_QUANT, sizeof(param_quant_max)}, 0};
   status = mmal_port_parameter_get(pState->encoder_component->output[0], &param_quant_max.hdr);
   if (status != MMAL_SUCCESS)
   {
       if ( s_bLog )
       {
       fprintf(s_fdLog, "Failed to get qant param max!\n");
       fflush(s_fdLog);
       }
   }
   if ( s_bLog && s_iDebug )
   {
       fprintf(s_fdLog, "Current qant param max: %d\n", param_quant_max.value);
       fflush(s_fdLog);
   }

   int iQInit = -1;
   int iQMin = -1;
   int iQMax = -1;

   if ( uCommandType == 50 )
   {
      if ( uParam1 > 0 )
         pState->quantisationParameter = uParam1;
      else
      {
         pState->quantisationParameter = param_quant_start.value;
         if ( pState->quantisationParameter <= 0 )
             pState->quantisationParameter = 40;
      }
      iQInit = pState->quantisationParameter;
      iQMin = pState->quantisationParameter;
      iQMax = pState->quantisationParameter;

      if ( s_bLog && s_iDebug )
      {
         fprintf(s_fdLog, "Set quantisation to %d\n", pState->quantisationParameter );
         fflush(s_fdLog);
      }
   }
   if ( uCommandType == 51 )
      iQInit = uParam1;
   if ( uCommandType == 52 )
      iQMin = uParam1;
   if ( uCommandType == 53 )
      iQMax = uParam1;

   if ( iQInit != -1 )
   {
      MMAL_PARAMETER_UINT32_T param1 = {{ MMAL_PARAMETER_VIDEO_ENCODE_INITIAL_QUANT, sizeof(param1)}, iQInit};
      status = mmal_port_parameter_set(pState->encoder_component->output[0], &param1.hdr);
      if (status != MMAL_SUCCESS)
      {
          if ( s_bLog )
          {
          fprintf(s_fdLog, "Failed to set qant param initial value!\n");
          fflush(s_fdLog);
          }
      }
      else if ( s_bLog && s_iDebug )
      {
          fprintf(s_fdLog, "Set quantisation init param to %d\n", iQInit );
          fflush(s_fdLog);
      }
   }

   if ( iQMin != -1 )
   {
   MMAL_PARAMETER_UINT32_T param2 = {{ MMAL_PARAMETER_VIDEO_ENCODE_MIN_QUANT, sizeof(param2)}, iQMin};
   status = mmal_port_parameter_set(pState->encoder_component->output[0], &param2.hdr);
   if (status != MMAL_SUCCESS)
   {
       if ( s_bLog )
       {
       fprintf(s_fdLog, "Failed to set qant param min!\n");
       fflush(s_fdLog);
       }
   }
   else if ( s_bLog && s_iDebug )
    {
         fprintf(s_fdLog, "Set quantisation min param to %d\n", iQMin );
         fflush(s_fdLog);
     }
   }

   if ( iQMax != -1 )
   {
   MMAL_PARAMETER_UINT32_T param3 = {{ MMAL_PARAMETER_VIDEO_ENCODE_MAX_QUANT, sizeof(param3)}, iQMax};
   status = mmal_port_parameter_set(pState->encoder_component->output[0], &param3.hdr);
   if (status != MMAL_SUCCESS)
   {
       if ( s_bLog )
       {
       fprintf(s_fdLog, "Failed to set qant param max!\n");
       fflush(s_fdLog);
       }
   }
   else if ( s_bLog && s_iDebug )
    {
         fprintf(s_fdLog, "Set quantisation max param to %d\n", iQMax );
         fflush(s_fdLog);
     }
   }
}

static void process_raspi_command(RASPIVID_STATE* pState, u8 uCmdCounter, u8 uCommandType, u8 uParam1, u8 uParam2)
{
   if ( uCommandType == 1 && uParam1 < 100 )
   {
      raspicamcontrol_set_brightness(pState->camera_component, uParam1); 
      return;
   }
   if ( uCommandType == 2 && uParam1 < 100 )
   {
      raspicamcontrol_set_contrast(pState->camera_component, ((int)uParam1)-50);
      return;
   }
   if ( uCommandType == 3 && uParam1 < 200)
   {
      raspicamcontrol_set_saturation(pState->camera_component, ((int)uParam1)-100);
      return;
   }
   if ( uCommandType == 4 && uParam1 < 200)
   {
      raspicamcontrol_set_sharpness(pState->camera_component, ((int)uParam1)-100);
      return;
   }

   if ( s_bLog && s_iDebug )
   {
      fprintf(s_fdLog, "Exec cmd nb. %d, cmd type: %d, param: %d\n", uCmdCounter, uCommandType, uParam1);
      fflush(s_fdLog);
   }

   // FPS
   if ( uCommandType == 10 && uParam1 < 200 )
   {
      int status = 0;

      // Get current framerate
      MMAL_PARAMETER_FRAME_RATE_T paramGet = {{ MMAL_PARAMETER_VIDEO_FRAME_RATE, sizeof(paramGet)}, {0,0}};
      status = mmal_port_parameter_get(pState->encoder_component->output[0], &paramGet.hdr);
      if (status != MMAL_SUCCESS)
      {
          if ( s_bLog )
          {
             fprintf(s_fdLog, "Failed to get video framerate!\n");
             fflush(s_fdLog);
          }
      }
      if ( s_bLog )
          fprintf(s_fdLog, "Current video framerate is: %i / %i = %i\n", (int)paramGet.frame_rate.num, (int)paramGet.frame_rate.den, (int)paramGet.frame_rate.num / (int)paramGet.frame_rate.den);
            

      // Set new framerate
      pState->framerate = uParam1;
      fprintf(s_fdLog, "Set new video framerate to: %i\n", (int)pState->framerate);
      fflush(s_fdLog);

      MMAL_PARAMETER_FRAME_RATE_T param = {{ MMAL_PARAMETER_VIDEO_FRAME_RATE, sizeof(param)}, {pState->framerate, 1}};
      param.frame_rate.num = pState->framerate;
      param.frame_rate.den = 1;
      status = mmal_port_parameter_set(pState->encoder_component->output[0], &param.hdr);
      if (status != MMAL_SUCCESS)
      {
          if ( s_bLog )
          {
             fprintf(s_fdLog, "Failed to set video framerate!\n");
             fflush(s_fdLog);
          }
      }
      return;
   }

   // Keyframe
   if ( uCommandType == 11 )
   {
      int keyframe = uParam1;
      if ( uParam1 > 200 )
         keyframe = (uParam1-200)*20;
      
      int status = 0;
      pState->intraperiod = keyframe;
      MMAL_PARAMETER_UINT32_T param = {{ MMAL_PARAMETER_INTRAPERIOD, sizeof(param)}, pState->intraperiod};
      status = mmal_port_parameter_set(pState->encoder_component->output[0], &param.hdr);
      if (status != MMAL_SUCCESS)
      {
          if ( s_bLog )
          {
             fprintf(s_fdLog, "Failed to set video keyframe!\n");
             fflush(s_fdLog);
          }
      }
      else if ( s_bLog )
      {
         fprintf(s_fdLog, "Set keyframe to %d.\n", pState->intraperiod);
         fflush(s_fdLog);
      }
      return;
   }

   // Quantization
   if ( uCommandType == 50 || uCommandType == 51 || uCommandType == 52 || uCommandType == 53 )
   {
      _set_h264_quantization(pState, uCommandType, (int)uParam1);
      return;
   }

   // Bitrate
   if ( uCommandType == 55 )
   {
      int status = 0;
      MMAL_PARAMETER_UINT32_T param = {{ MMAL_PARAMETER_VIDEO_BIT_RATE, sizeof(param)}, 0};
      status = mmal_port_parameter_get(pState->encoder_component->output[0], &param.hdr);
      if (status != MMAL_SUCCESS)
      {
         if ( s_bLog )
         {
          fprintf(s_fdLog, "Failed to get video bitrate!\n");
          fflush(s_fdLog);
         }
      }
      if ( s_bLog && s_iDebug )
      {
          fprintf(s_fdLog, "Current video bitrate %u\n", param.value);
          fflush(s_fdLog);
      }
      

      pState->bitrate = ((int)uParam1)*100000;
      if ( s_bLog && s_iDebug )
      {
          //fprintf(s_fdLog, "Setting video bitrate to: %u\n", pState->bitrate);
          //fflush(s_fdLog);
      }

      MMAL_PARAMETER_UINT32_T param2 = {{ MMAL_PARAMETER_VIDEO_BIT_RATE, sizeof(param2)}, pState->bitrate};
      status = mmal_port_parameter_set(pState->encoder_component->output[0], &param2.hdr);
      if (status != MMAL_SUCCESS)
      {
         if ( s_bLog )
         {
          fprintf(s_fdLog, "Failed to set video bitrate!\n");
          fflush(s_fdLog);
         }
      }
      else if ( s_bLog && s_iDebug )
      {
          fprintf(s_fdLog, "Set video bitrate to: %d\n", pState->bitrate);
          fflush(s_fdLog);
      }

      //if ( pState->bitrate < 2500000 )
      //   _set_h264_quantization(pState, 50, 0);

      if ( 0 )
      if ( pState->bitrate < 2500000 )
      {
         MMAL_STATUS_T statusMal;
         
         statusMal = mmal_component_disable(pState->encoder_component);
         if ( statusMal != MMAL_SUCCESS )
         if ( s_bLog )
         {
            fprintf(s_fdLog, "Failed to disable encoder component!\n");
            fflush(s_fdLog);
         }

         // Commit the port changes to the output port
      
         pState->encoder_component->output[0]->format->bitrate = pState->bitrate;
         statusMal = mmal_port_format_commit(pState->encoder_component->output[0]);
         if (statusMal != MMAL_SUCCESS)
         {
            if ( s_bLog )
            {
             fprintf(s_fdLog, "Failed to commit the change in video bitrate!\n");
             fflush(s_fdLog);
            }
         }
         else
         {
            if ( s_bLog )
            {
             fprintf(s_fdLog, "Commited the change in video bitrate to %d\n", pState->bitrate);
             fflush(s_fdLog);
            }
         }

         statusMal = mmal_component_enable(pState->encoder_component);
         if ( statusMal != MMAL_SUCCESS )
         if ( s_bLog )
         {
            fprintf(s_fdLog, "Failed to enable encoder component!\n");
            fflush(s_fdLog);
         }
      }
      return;
   }
}

static void main_loop(RASPIVID_STATE* pState)
{
   u32 s_lastModifiedCounter = 0;
   u32 bufferCommands[8];
   u32 uLastProcessedCommands[8];
   int s_gotInitialState = 0;

   if ( s_bLog )
   {
      fprintf(s_fdLog, "Entering continous loop state...\n");
      fflush(s_fdLog);
   }

   /*
   if ( s_bLog )
   {
      s_bLog = 0;
      fprintf(s_fdLog, "Closing log file.\n");
      fflush(s_fdLog);
      fclose(s_fdLog);
      s_fdLog = NULL;
   }
   */

   while ((!pState->callback_data.abort) && (!s_bQuit) )
   {
      // Have a sleep so we don't hog the CPU.
      vcos_sleep(ABORT_INTERVAL);

      if ( NULL == s_pSharedMemComm )
      {
         s_pSharedMemComm = open_shared_mem_for_read("/SYSTEM_SHARED_MEM_RASPIVID_COMM", 32);
         if ( NULL != s_pSharedMemComm )
         {
            if ( s_bLog )
               fprintf(s_fdLog, "Opened shared mem /SYSTEM_SHARED_MEM_RASPIVID_COMM for read.\n");
         }
      }
      if ( NULL == s_pSharedMemComm )
      {
         if ( s_bLog )
         {
            fprintf(s_fdLog, "No shared mem port available...\n");
            fflush(s_fdLog);
         }
         continue;
      }

      memcpy((u8*)&(bufferCommands[0]), s_pSharedMemComm, 32);

      // u32 0: command modify stamp (must match u32 7)
      // u32 1: byte 0: command counter;
      //        byte 1: command type;
      //        byte 2: command parameter;
      //        byte 3: command parameter 2;
      // u32 2-6: history of previous commands (after current one from u32-1)
      // u32 7: command modify stamp (must match u32 0)

      if ( bufferCommands[0] != bufferCommands[7] )
         continue;

      if ( ! s_gotInitialState )
      {
         s_gotInitialState = true;
         s_lastModifiedCounter = bufferCommands[0];
         memset((u8*)&(uLastProcessedCommands[0]), 0, 8*sizeof(u32));
         continue;
      }

      if ( bufferCommands[0] == s_lastModifiedCounter )
         continue;

      // Execute all commands received, from oldest to newest, if not found in executed history

      for( int i=6; i>0; i-- )
      {
         int iFoundInHistory = 0;
         for( int k=0; k<8; k++ )
            if ( bufferCommands[i] == uLastProcessedCommands[k] )
            {
               iFoundInHistory = 1;
               break;
            }
         if ( iFoundInHistory )
            continue;

         process_raspi_command(pState, bufferCommands[i] & 0xFF, (bufferCommands[i] >> 8) & 0xFF, (bufferCommands[i] >> 16) & 0xFF, (bufferCommands[i] >> 24) & 0xFF);
         
         // Add it to history
         for( int k=7; k>0; k-- )
            uLastProcessedCommands[k] = uLastProcessedCommands[k-1];
         uLastProcessedCommands[0] = bufferCommands[i];
      }
      s_lastModifiedCounter = bufferCommands[0];
   }

   if ( s_bLog )
   {
      fprintf(s_fdLog, "Exit from main loop.\n");
      fflush(s_fdLog);
   }
}

/**
 * Function to wait in various ways (depending on settings)
 *
 * @param state Pointer to the state data
 *
 * @return !0 if to continue, 0 if reached end of run
 */
static int wait_for_next_change(RASPIVID_STATE *state)
{
   int keep_running = 1;
   static int64_t complete_time = -1;
   static int brightness_p = 0;
   static int qp_value = 35;

   if ( NULL != state )
   {
      FILE* fCam = fopen("/home/pi/ruby/tmp/cam_name.txt", "w");
      if ( NULL != fCam )
      {
         fprintf(fCam, "%s\n", state->common_settings.camera_name);
         fclose(fCam);
         if ( s_bLog )
         {
            fprintf(s_fdLog, "Written camera name to file.\n");
            fflush(s_fdLog);
         }
      }
      else
      {
         if ( s_bLog )
         {
            fprintf(s_fdLog, "Failed to write camera name to file.\n");
            fflush(s_fdLog);
         }
      }
   }

   if (s_bLog)
      dump_status(state);

   // Have we actually exceeded our timeout?
   int64_t current_time =  get_microseconds64()/1000;

   if (complete_time == -1)
      complete_time =  current_time + state->timeout;

   // if we have run out of time, flag we need to exit
   if (current_time >= complete_time && state->timeout != 0)
      keep_running = 0;

   switch (state->waitMethod)
   {
   case WAIT_METHOD_NONE:
   {
      if (s_bLog)
      {
         fprintf(s_fdLog, "Waiting method: None\n");
         fflush(s_fdLog);
      }
      (void)pause_and_test_abort(state, state->timeout);
      return 0;
   }
   case WAIT_METHOD_FOREVER:
   {
      if (s_bLog)
      {
         //fprintf(s_fdLog, "Waiting method: Forever\n");
         //fflush(s_fdLog);
      }

      main_loop(state);
      return 0;

      // We never return from this. Expect a ctrl-c to exit or abort.
      while (!state->callback_data.abort)
      {
         // Have a sleep so we don't hog the CPU.
         vcos_sleep(ABORT_INTERVAL);
         /*
         // CHANGED_BR
         brightness_p++;
         if ( brightness_p > 70 )
         {
            brightness_p = 10;
            qp_value -= 3;
            if ( qp_value < 15 )
               qp_value = 36;
            //fprintf(fdlog,"Setting new Quant params: %d\n", qp_value);
            //fflush(fdlog);

            state->quantisationParameter = qp_value;

            MMAL_PARAMETER_UINT32_T param2 = {{ MMAL_PARAMETER_VIDEO_ENCODE_MIN_QUANT, sizeof(param2)}, state->quantisationParameter};
            int status = mmal_port_parameter_set(state->encoder_component->output[0], &param2.hdr);
            if (status != MMAL_SUCCESS)
            {
                if ( s_bLog )
                {
                fprintf(s_fdLog, "Failed to set qp min!\n");
                fflush(s_fdLog);
                }
            }

            MMAL_PARAMETER_UINT32_T param3 = {{ MMAL_PARAMETER_VIDEO_ENCODE_MAX_QUANT, sizeof(param3)}, state->quantisationParameter};
            status = mmal_port_parameter_set(state->encoder_component->output[0], &param3.hdr);
            if (status != MMAL_SUCCESS)
            {
                if ( s_bLog )
                {
                fprintf(s_fdLog, "Failed to set qp max!\n");
                fflush(s_fdLog);
                }
            }
         }
         raspicamcontrol_set_brightness(state->camera_component, brightness_p); 
         //int val = raspicamcontrol_get_brightness(state->camera_component);
         //int val = 0;
         //if ( s_bLog )
         //   fprintf(s_fdLog, "%d -> %d\n", brightness_p, val);
         */
      }
      return 0;
   }

   case WAIT_METHOD_TIMED:
   {
      int abort;

      if (state->bCapturing)
         abort = pause_and_test_abort(state, state->onTime);
      else
         abort = pause_and_test_abort(state, state->offTime);

      if (abort)
         return 0;
      else
         return keep_running;
   }

   case WAIT_METHOD_KEYPRESS:
   {
      char ch;

      if (s_bLog)
      {
         fprintf(s_fdLog, "Press Enter to %s, X then ENTER to exit, [i,o,r] then ENTER to change zoom\n", state->bCapturing ? "pause" : "capture");
         fflush(s_fdLog);
      }

      ch = getchar();
      if (ch == 'x' || ch == 'X')
         return 0;
      else if (ch == 'i' || ch == 'I')
      {
         if (s_bLog)
         {
            fprintf(s_fdLog, "Starting zoom in\n");
            fflush(s_fdLog);
         }
         raspicamcontrol_zoom_in_zoom_out(state->camera_component, ZOOM_IN, &(state->camera_parameters).roi);
      }
      else if (ch == 'o' || ch == 'O')
      {
         if (s_bLog)
         {
            fprintf(s_fdLog, "Starting zoom out\n");
            fflush(s_fdLog);
         }
         raspicamcontrol_zoom_in_zoom_out(state->camera_component, ZOOM_OUT, &(state->camera_parameters).roi);
      }
      else if (ch == 'r' || ch == 'R')
      {
         if (s_bLog)
         {
            fprintf(s_fdLog, "starting reset zoom\n");
            fflush(s_fdLog);
         }
         raspicamcontrol_zoom_in_zoom_out(state->camera_component, ZOOM_RESET, &(state->camera_parameters).roi);
      }

      return keep_running;
   }


   case WAIT_METHOD_SIGNAL:
   {
      // Need to wait for a SIGUSR1 signal
      sigset_t waitset;
      int sig;
      int result = 0;

      sigemptyset( &waitset );
      sigaddset( &waitset, SIGUSR1 );

      // We are multi threaded because we use mmal, so need to use the pthread
      // variant of procmask to block SIGUSR1 so we can wait on it.
      pthread_sigmask( SIG_BLOCK, &waitset, NULL );

      if (s_bLog)
      {
         fprintf(s_fdLog, "Waiting for SIGUSR1 to %s\n", state->bCapturing ? "pause" : "capture");
         fflush(s_fdLog);
      }

      result = sigwait( &waitset, &sig );

      if (s_bLog && result != 0)
      {
         fprintf(s_fdLog, "Bad signal received - error %d\n", errno);
         fflush(s_fdLog);
      }
      return keep_running;
   }

   } // switch

   return keep_running;
}

void handle_sigint(int sig) 
{
   if ( s_bLog )
   {
      fprintf(s_fdLog, "--------------------\nReceived signal to quit.\n--------------------\n");
      fflush(s_fdLog);
   }
   s_bQuit = 1;
}  

/**
 * main
 */
int main(int argc, const char **argv)
{
   if ( strcmp(argv[argc-1], "-ver") == 0 )
   {
      printf("7.4 (b51)");
      return 0;
   }


   s_iDebug = 0;
   if ( strcmp(argv[1], "-dbg") == 0 )
      s_iDebug = 1;

   // Our main data storage vessel..
   RASPIVID_STATE state;
   int exit_code = EX_OK;

   MMAL_STATUS_T status = MMAL_SUCCESS;
   MMAL_PORT_T *camera_preview_port = NULL;
   MMAL_PORT_T *camera_video_port = NULL;
   MMAL_PORT_T *camera_still_port = NULL;
   MMAL_PORT_T *preview_input_port = NULL;
   MMAL_PORT_T *encoder_input_port = NULL;
   MMAL_PORT_T *encoder_output_port = NULL;
   MMAL_PORT_T *splitter_input_port = NULL;
   MMAL_PORT_T *splitter_output_port = NULL;
   MMAL_PORT_T *splitter_preview_port = NULL;

   check_camera_stack();

   bcm_host_init();

   // Register our application with the logging system
   vcos_log_register("RaspiVid", VCOS_LOG_CATEGORY);

   //signal(SIGINT, default_signal_handler);

   signal(SIGINT, handle_sigint);
   signal(SIGTERM, handle_sigint);
   signal(SIGQUIT, handle_sigint);
  
   // Disable USR1 for the moment - may be reenabled if go in to signal capture mode
   signal(SIGUSR1, SIG_IGN);

   set_app_name(argv[0]);

   s_bLog = 1;
   s_fdLog = NULL;

   if ( s_bLog )
   {
      s_fdLog = fopen("/home/pi/ruby/logs/log_video.txt", "a");
      if ( s_fdLog <= 0 )
         s_bLog = 0;
      else
      {
         fprintf(s_fdLog, "-------------------------------\n");
         fprintf(s_fdLog, "Starting ruby_capture_raspi v7.2.b43...\n");
         if ( s_iDebug )
            fprintf(s_fdLog, "Debug flag is set.");
         else
            fprintf(s_fdLog, "Debug flag disabled.");
         fflush(s_fdLog);
         fclose(s_fdLog);
      }
   }

   s_bLog = 0;

   // Do we have any parameters
   if (argc == 1)
   {
      display_valid_parameters(basename(get_app_name()), &application_help_message);
      exit(EX_USAGE);
   }

   default_status(&state);

   // Parse the command line and put options in to our status structure
   if (parse_cmdline(argc, argv, &state))
   {
      status = -1;
      exit(EX_USAGE);
   }

   if ( s_bLog )
   {
      s_fdLog = fopen("/home/pi/ruby/logs/log_video.txt", "a");
      if ( s_fdLog <= 0 )
      {
         s_bLog = 0;
         s_iDebug = 0;
      }
   }
   else
      s_iDebug = 0;

   if (state.timeout == -1)
      state.timeout = 5000;

   // Setup for sensor specific parameters, only set W/H settings if zero on entry
   get_sensor_defaults(state.common_settings.cameraNum, state.common_settings.camera_name,
                       &state.common_settings.width, &state.common_settings.height);

   if (s_bLog && (0 != state.common_settings.camera_name[0]))
   {
      fprintf(s_fdLog, "Got camera name: %s\n", state.common_settings.camera_name);
      fflush(s_fdLog);   
   }

   check_camera_model(state.common_settings.cameraNum);

   if (state.common_settings.gps)
      if (raspi_gps_setup(state.common_settings.verbose))
         state.common_settings.gps = 0;

   // OK, we have a nice set of parameters. Now set up our components
   // We have three components. Camera, Preview and encoder.

   if ((status = create_camera_component(&state)) != MMAL_SUCCESS)
   {
      vcos_log_error("%s: Failed to create camera component", __func__);
      exit_code = EX_SOFTWARE;
   }
   else if ((status = raspipreview_create(&state.preview_parameters)) != MMAL_SUCCESS)
   {
      vcos_log_error("%s: Failed to create preview component", __func__);
      destroy_camera_component(&state);
      exit_code = EX_SOFTWARE;
   }
   else if ((status = create_encoder_component(&state)) != MMAL_SUCCESS)
   {
      vcos_log_error("%s: Failed to create encode component", __func__);
      raspipreview_destroy(&state.preview_parameters);
      destroy_camera_component(&state);
      exit_code = EX_SOFTWARE;
   }
   else if (state.raw_output && (status = create_splitter_component(&state)) != MMAL_SUCCESS)
   {
      vcos_log_error("%s: Failed to create splitter component", __func__);
      raspipreview_destroy(&state.preview_parameters);
      destroy_camera_component(&state);
      destroy_encoder_component(&state);
      exit_code = EX_SOFTWARE;
   }
   else
   {
      if (s_bLog)
      {
         fprintf(s_fdLog, "Starting component connection stage\n");
         fflush(s_fdLog);
      }
      camera_preview_port = state.camera_component->output[MMAL_CAMERA_PREVIEW_PORT];
      camera_video_port   = state.camera_component->output[MMAL_CAMERA_VIDEO_PORT];
      camera_still_port   = state.camera_component->output[MMAL_CAMERA_CAPTURE_PORT];
      preview_input_port  = state.preview_parameters.preview_component->input[0];
      encoder_input_port  = state.encoder_component->input[0];
      encoder_output_port = state.encoder_component->output[0];

      if (state.raw_output)
      {
         splitter_input_port = state.splitter_component->input[0];
         splitter_output_port = state.splitter_component->output[SPLITTER_OUTPUT_PORT];
         splitter_preview_port = state.splitter_component->output[SPLITTER_PREVIEW_PORT];
      }

      if (state.preview_parameters.wantPreview )
      {
         if (state.raw_output)
         {
            if (s_bLog)
            {
               fprintf(s_fdLog, "Connecting camera preview port to splitter input port\n");
               fflush(s_fdLog);
            }
            // Connect camera to splitter
            status = connect_ports(camera_preview_port, splitter_input_port, &state.splitter_connection);

            if (status != MMAL_SUCCESS)
            {
               state.splitter_connection = NULL;
               vcos_log_error("%s: Failed to connect camera preview port to splitter input", __func__);
               goto error;
            }

            if (s_bLog)
            {
               fprintf(s_fdLog, "Connecting splitter preview port to preview input port\n");
               fprintf(s_fdLog, "Starting video preview\n");
               fflush(s_fdLog);
            }

            // Connect splitter to preview
            status = connect_ports(splitter_preview_port, preview_input_port, &state.preview_connection);
         }
         else
         {
            if (s_bLog)
            {
               fprintf(s_fdLog, "Connecting camera preview port to preview input port\n");
               fprintf(s_fdLog, "Starting video preview\n");
               fflush(s_fdLog);
            }

            // Connect camera to preview
            status = connect_ports(camera_preview_port, preview_input_port, &state.preview_connection);
         }

         if (status != MMAL_SUCCESS)
            state.preview_connection = NULL;
      }
      else
      {
         if (state.raw_output)
         {
            if (s_bLog)
            {
               fprintf(s_fdLog, "Connecting camera preview port to splitter input port\n");
               fflush(s_fdLog);
            }
            // Connect camera to splitter
            status = connect_ports(camera_preview_port, splitter_input_port, &state.splitter_connection);

            if (status != MMAL_SUCCESS)
            {
               state.splitter_connection = NULL;
               vcos_log_error("%s: Failed to connect camera preview port to splitter input", __func__);
               goto error;
            }
         }
         else
         {
            status = MMAL_SUCCESS;
         }
      }

      if (status == MMAL_SUCCESS)
      {
         if (s_bLog)
         {
            fprintf(s_fdLog, "Connecting camera video port to encoder input port\n");
            fflush(s_fdLog);
         }
         // Now connect the camera to the encoder
         status = connect_ports(camera_video_port, encoder_input_port, &state.encoder_connection);

         if (status != MMAL_SUCCESS)
         {
            state.encoder_connection = NULL;
            vcos_log_error("%s: Failed to connect camera video port to encoder input", __func__);
            goto error;
         }
      }

      if (status == MMAL_SUCCESS)
      {
         // Set up our userdata - this is passed though to the callback where we need the information.
         state.callback_data.pstate = &state;
         state.callback_data.abort = 0;

         if (state.raw_output)
         {
            splitter_output_port->userdata = (struct MMAL_PORT_USERDATA_T *)&state.callback_data;

            if (s_bLog)
            {
               fprintf(s_fdLog, "Enabling splitter output port\n");
               fflush(s_fdLog);
            }
            // Enable the splitter output port and tell it its callback function
            status = mmal_port_enable(splitter_output_port, splitter_buffer_callback);

            if (status != MMAL_SUCCESS)
            {
               vcos_log_error("%s: Failed to setup splitter output port", __func__);
               goto error;
            }
         }

         state.callback_data.file_handle = NULL;

         if (state.common_settings.filename)
         {
            if (state.common_settings.filename[0] == '-')
            {
               state.callback_data.file_handle = stdout;
            }
            else
            {
               state.callback_data.file_handle = open_filename(&state, state.common_settings.filename);
            }

            if (!state.callback_data.file_handle)
            {
               // Notify user, carry on but discarding encoded output buffers
               vcos_log_error("%s: Error opening output file: %s\nNo output file will be generated\n", __func__, state.common_settings.filename);
            }
         }

         state.callback_data.imv_file_handle = NULL;

         if (state.imv_filename)
         {
            if (state.imv_filename[0] == '-')
            {
               state.callback_data.imv_file_handle = stdout;
            }
            else
            {
               state.callback_data.imv_file_handle = open_filename(&state, state.imv_filename);
            }

            if (!state.callback_data.imv_file_handle)
            {
               // Notify user, carry on but discarding encoded output buffers
               if ( s_bLog )
               {
               fprintf(s_fdLog, "Error opening output file: %s\nNo output file will be generated\n",state.imv_filename);
               fflush(s_fdLog);
               }
               state.inlineMotionVectors=0;
            }
         }

         state.callback_data.pts_file_handle = NULL;

         if (state.pts_filename)
         {
            if (state.pts_filename[0] == '-')
            {
               state.callback_data.pts_file_handle = stdout;
            }
            else
            {
               state.callback_data.pts_file_handle = open_filename(&state, state.pts_filename);
               if (state.callback_data.pts_file_handle) /* save header for mkvmerge */
                  fprintf(state.callback_data.pts_file_handle, "# timecode format v2\n");
            }

            if (!state.callback_data.pts_file_handle)
            {
               // Notify user, carry on but discarding encoded output buffers
               if ( s_bLog )
               {
               fprintf(s_fdLog, "Error opening output file: %s\nNo output file will be generated\n",state.pts_filename);
               fflush(s_fdLog);
               }
               state.save_pts=0;
            }
         }

         state.callback_data.raw_file_handle = NULL;

         if (state.raw_filename)
         {
            if (state.raw_filename[0] == '-')
            {
               state.callback_data.raw_file_handle = stdout;
            }
            else
            {
               state.callback_data.raw_file_handle = open_filename(&state, state.raw_filename);
            }

            if (!state.callback_data.raw_file_handle)
            {
               // Notify user, carry on but discarding encoded output buffers
               if ( s_bLog )
               {
               fprintf(s_fdLog, "Error opening output file: %s\nNo output file will be generated\n", state.raw_filename);
               fflush(s_fdLog);
               }
               state.raw_output = 0;
            }
         }

         if(state.bCircularBuffer)
         {
            if(state.bitrate == 0)
            {
               vcos_log_error("%s: Error circular buffer requires constant bitrate and small intra period\n", __func__);
               goto error;
            }
            else if(state.timeout == 0)
            {
               vcos_log_error("%s: Error, circular buffer size is based on timeout must be greater than zero\n", __func__);
               goto error;
            }
            else if(state.waitMethod != WAIT_METHOD_KEYPRESS && state.waitMethod != WAIT_METHOD_SIGNAL)
            {
               vcos_log_error("%s: Error, Circular buffer mode requires either keypress (-k) or signal (-s) triggering\n", __func__);
               goto error;
            }
            else if(!state.callback_data.file_handle)
            {
               vcos_log_error("%s: Error require output file (or stdout) for Circular buffer mode\n", __func__);
               goto error;
            }
            else
            {
               int count = state.bitrate * (state.timeout / 1000) / 8;

               state.callback_data.cb_buff = (char *) malloc(count);
               if(state.callback_data.cb_buff == NULL)
               {
                  vcos_log_error("%s: Unable to allocate circular buffer for %d seconds at %.1f Mbits\n", __func__, state.timeout / 1000, (double)state.bitrate/1000000.0);
                  goto error;
               }
               else
               {
                  state.callback_data.cb_len = count;
                  state.callback_data.cb_wptr = 0;
                  state.callback_data.cb_wrap = 0;
                  state.callback_data.cb_data = 0;
                  state.callback_data.iframe_buff_wpos = 0;
                  state.callback_data.iframe_buff_rpos = 0;
                  state.callback_data.header_wptr = 0;
               }
            }
         }

         // Set up our userdata - this is passed though to the callback where we need the information.
         encoder_output_port->userdata = (struct MMAL_PORT_USERDATA_T *)&state.callback_data;

         if (s_bLog)
         {
            fprintf(s_fdLog, "Enabling encoder output port\n");
            fflush(s_fdLog);
         }
         // Enable the encoder output port and tell it its callback function
         status = mmal_port_enable(encoder_output_port, encoder_buffer_callback);

         if (status != MMAL_SUCCESS)
         {
            vcos_log_error("Failed to setup encoder output");
            goto error;
         }

         if (state.demoMode)
         {
            // Run for the user specific time..
            int num_iterations = state.timeout / state.demoInterval;
            int i;

            if (s_bLog)
            {
               fprintf(s_fdLog, "Running in demo mode\n");
               fflush(s_fdLog);
            }
            for (i=0; state.timeout == 0 || i<num_iterations; i++)
            {
               raspicamcontrol_cycle_test(state.camera_component);
               vcos_sleep(state.demoInterval);
            }
         }
         else
         {
            // Only encode stuff if we have a filename and it opened
            // Note we use the copy in the callback, as the call back MIGHT change the file handle
            if (state.callback_data.file_handle || state.callback_data.raw_file_handle)
            {
               int running = 1;

               // Send all the buffers to the encoder output port
               if (state.callback_data.file_handle)
               {
                  int num = mmal_queue_length(state.encoder_pool->queue);
                  int q;
                  for (q=0; q<num; q++)
                  {
                     MMAL_BUFFER_HEADER_T *buffer = mmal_queue_get(state.encoder_pool->queue);

                     if (!buffer)
                        vcos_log_error("Unable to get a required buffer %d from pool queue", q);

                     if (mmal_port_send_buffer(encoder_output_port, buffer)!= MMAL_SUCCESS)
                        vcos_log_error("Unable to send a buffer to encoder output port (%d)", q);
                  }
               }

               // Send all the buffers to the splitter output port
               if (state.callback_data.raw_file_handle)
               {
                  int num = mmal_queue_length(state.splitter_pool->queue);
                  int q;
                  for (q = 0; q < num; q++)
                  {
                     MMAL_BUFFER_HEADER_T *buffer = mmal_queue_get(state.splitter_pool->queue);

                     if (!buffer)
                        vcos_log_error("Unable to get a required buffer %d from pool queue", q);

                     if (mmal_port_send_buffer(splitter_output_port, buffer)!= MMAL_SUCCESS)
                        vcos_log_error("Unable to send a buffer to splitter output port (%d)", q);
                  }
               }

               int initialCapturing=state.bCapturing;
               while (running)
               {
                  // Change state

                  state.bCapturing = !state.bCapturing;

                  if (mmal_port_parameter_set_boolean(camera_video_port, MMAL_PARAMETER_CAPTURE, state.bCapturing) != MMAL_SUCCESS)
                  {
                     // How to handle?
                  }

                  // In circular buffer mode, exit and save the buffer (make sure we do this after having paused the capture
                  if(state.bCircularBuffer && !state.bCapturing)
                  {
                     break;
                  }

                  if (s_bLog)
                  {
                     if (state.bCapturing)
                        fprintf(s_fdLog, "Starting video capture\n");
                     else
                        fprintf(s_fdLog, "Pausing video capture\n");
                     fflush(s_fdLog);
                  }

                  if(state.splitWait)
                  {
                     if(state.bCapturing)
                     {
                        if (mmal_port_parameter_set_boolean(encoder_output_port, MMAL_PARAMETER_VIDEO_REQUEST_I_FRAME, 1) != MMAL_SUCCESS)
                        {
                           vcos_log_error("failed to request I-FRAME");
                        }
                     }
                     else
                     {
                        if(!initialCapturing)
                           state.splitNow=1;
                     }
                     initialCapturing=0;
                  }
                  running = wait_for_next_change(&state);
               }

               if (s_bLog)
               {
                  fprintf(s_fdLog, "Finished capture\n");
                  fflush(s_fdLog);
               }
            }
            else
            {
               if (state.timeout)
                  vcos_sleep(state.timeout);
               else
               {
                  // timeout = 0 so run forever
                  while(1)
                     vcos_sleep(ABORT_INTERVAL);
               }
            }
         }
      }
      else
      {
         mmal_status_to_int(status);
         vcos_log_error("%s: Failed to connect camera to preview", __func__);
      }

      if(state.bCircularBuffer)
      {
         int copy_from_end, copy_from_start;

         copy_from_end = state.callback_data.cb_len - state.callback_data.iframe_buff[state.callback_data.iframe_buff_rpos];
         copy_from_start = state.callback_data.cb_len - copy_from_end;
         copy_from_start = state.callback_data.cb_wptr < copy_from_start ? state.callback_data.cb_wptr : copy_from_start;
         if(!state.callback_data.cb_wrap)
         {
            copy_from_start = state.callback_data.cb_wptr;
            copy_from_end = 0;
         }

         fwrite(state.callback_data.header_bytes, 1, state.callback_data.header_wptr, state.callback_data.file_handle);
         // Save circular buffer
         fwrite(state.callback_data.cb_buff + state.callback_data.iframe_buff[state.callback_data.iframe_buff_rpos], 1, copy_from_end, state.callback_data.file_handle);
         fwrite(state.callback_data.cb_buff, 1, copy_from_start, state.callback_data.file_handle);
         if(state.callback_data.flush_buffers) fflush(state.callback_data.file_handle);
      }

error:

      if ( s_bLog )
      {
      fprintf(s_fdLog, "Error, closing\n");
      fflush(s_fdLog);
      }

      mmal_status_to_int(status);


      // Disable all our ports that are not handled by connections
      check_disable_port(camera_still_port);
      check_disable_port(encoder_output_port);
      check_disable_port(splitter_output_port);

      if (state.preview_parameters.wantPreview && state.preview_connection)
         mmal_connection_destroy(state.preview_connection);

      if (state.encoder_connection)
         mmal_connection_destroy(state.encoder_connection);

      if (state.splitter_connection)
         mmal_connection_destroy(state.splitter_connection);

      // Can now close our file. Note disabling ports may flush buffers which causes
      // problems if we have already closed the file!
      if (state.callback_data.file_handle && state.callback_data.file_handle != stdout)
         fclose(state.callback_data.file_handle);
      if (state.callback_data.imv_file_handle && state.callback_data.imv_file_handle != stdout)
         fclose(state.callback_data.imv_file_handle);
      if (state.callback_data.pts_file_handle && state.callback_data.pts_file_handle != stdout)
         fclose(state.callback_data.pts_file_handle);
      if (state.callback_data.raw_file_handle && state.callback_data.raw_file_handle != stdout)
         fclose(state.callback_data.raw_file_handle);

      /* Disable components */
      if (state.encoder_component)
         mmal_component_disable(state.encoder_component);

      if (state.preview_parameters.preview_component)
         mmal_component_disable(state.preview_parameters.preview_component);

      if (state.splitter_component)
         mmal_component_disable(state.splitter_component);

      if (state.camera_component)
         mmal_component_disable(state.camera_component);

      destroy_encoder_component(&state);
      raspipreview_destroy(&state.preview_parameters);
      destroy_splitter_component(&state);
      destroy_camera_component(&state);

      if (s_bLog)
      {
         fprintf(s_fdLog, "Close down completed, all components disconnected, disabled and destroyed\n\n");
         fflush(s_fdLog);
      }
   }

   if (status != MMAL_SUCCESS)
      raspicamcontrol_check_configuration(128);

   if (state.common_settings.gps)
      raspi_gps_shutdown(state.common_settings.verbose);

   if ( NULL != s_pSharedMemComm )
      munmap(s_pSharedMemComm, 32);
   s_pSharedMemComm = NULL;

   if ( NULL != s_fdLog )
   {
      fprintf(s_fdLog, "Closed\n");
      fflush(s_fdLog);
      fclose(s_fdLog);
      s_fdLog = NULL;
   }
   return exit_code;
}
