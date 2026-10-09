#ifndef ENCODED_STREAM_HANDLER_H_
#define ENCODED_STREAM_HANDLER_H_

#include <gst/gst.h>

#include <string>
#include <vector>

// Which codec an encoded stream is asked to produce.
//
// Named for the wire, not for GStreamer: `start_recording.codec` is a closed
// seven-value vocabulary, and this device only implements the two that have an
// Annex B form. `mjpeg` needs no encoder at all — a JPEG already is one.
enum class EncodedCodec { kH264, kH265 };

// Answers "what can this machine encode", before any pipeline exists.
//
// Split out from the branch itself because the two questions are asked at
// different times and one of them has no camera: registration needs to know
// which codecs are worth announcing, and it needs to know that before a
// recording has been commanded, on a device that may never open a camera at
// all. Nothing here touches a pipeline.
class EncodedStreamHandler {
 public:
  // The GStreamer element factory that will encode [codec] on this machine,
  // or an empty string when this machine cannot encode it.
  //
  // Hardware first. A software encoder that can hold 1080p60 exists, but it
  // costs most of a core to do it while a preview pipeline runs alongside, so
  // a machine with a hardware path should be using it. Falling back to
  // software is not a failure either — what decides whether a rate is
  // announced is the measured throughput, not which element produced it, and
  // a machine with no encoder at all simply does not announce that codec.
  static std::string DetectEncoder(EncodedCodec codec);

  // The codecs this machine can encode, as wire names: "h264", "h265".
  //
  // Empty is a correct answer. The device always has `mjpeg` on top of
  // whatever comes back here, because `takePicture()` works everywhere.
  static std::vector<std::string> AvailableEncoders();
};

#endif  // ENCODED_STREAM_HANDLER_H_
