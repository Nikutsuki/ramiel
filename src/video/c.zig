pub const c = @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libswresample/swresample.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libavutil/channel_layout.h");
    @cInclude("libavutil/imgutils.h");
});