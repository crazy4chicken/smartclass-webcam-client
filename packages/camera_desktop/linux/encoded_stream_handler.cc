#include "encoded_stream_handler.h"

#include <cstddef>

namespace {

// Encoder candidates per codec, best first.
//
// Same shape as RecordHandler's list, extended: hardware first, because the
// device has to hold a high rate while a preview pipeline runs at the same
// time, and the software path costs most of a core to do it.
//
// The two VAAPI spellings both appear because they are different plugins —
// `vah264enc` is gst-plugins-bad's `va` element, `vaapih264enc` is
// gstreamer-vaapi's — and which one a distribution ships varies. Asking the
// factory is the only way to tell; there is no capability query to make.
const char* const kH264Candidates[] = {
    "vah264enc",
    "vaapih264enc",
    "nvv4l2h264enc",
    "x264enc",
    "openh264enc",
    "avenc_h264",
};

const char* const kH265Candidates[] = {
    "vah265enc",
    "vaapih265enc",
    "nvv4l2h265enc",
    "x265enc",
    "avenc_hevc",
};

template <std::size_t N>
std::string FirstPresent(const char* const (&candidates)[N]) {
  for (std::size_t i = 0; i < N; i++) {
    GstElementFactory* factory = gst_element_factory_find(candidates[i]);
    if (factory) {
      gst_object_unref(factory);
      return candidates[i];
    }
  }
  return "";
}

}  // namespace

std::string EncodedStreamHandler::DetectEncoder(EncodedCodec codec) {
  switch (codec) {
    case EncodedCodec::kH264:
      return FirstPresent(kH264Candidates);
    case EncodedCodec::kH265:
      return FirstPresent(kH265Candidates);
  }
  return "";
}

std::vector<std::string> EncodedStreamHandler::AvailableEncoders() {
  std::vector<std::string> codecs;
  if (!DetectEncoder(EncodedCodec::kH264).empty()) {
    codecs.push_back("h264");
  }
  if (!DetectEncoder(EncodedCodec::kH265).empty()) {
    codecs.push_back("h265");
  }
  return codecs;
}
