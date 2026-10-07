#!/usr/bin/env python3
"""Decode the engine's framed video pipe before handing pixels to ffmpeg."""
import signal
import struct
import subprocess
import sys

HEADER = struct.Struct("<4sHHIIIIB7xQQ16x")


def read_exact(stream, size, allow_eof=False):
    data = bytearray()
    while len(data) < size:
        chunk = stream.read(size - len(data))
        if not chunk:
            if not data and allow_eof:
                return None
            raise EOFError("incomplete final video frame")
        data.extend(chunk)
    return bytes(data)


def read_frame(stream, width, content_height):
    header = read_exact(stream, HEADER.size, allow_eof=True)
    if header is None:
        return None
    magic, version, length, w, h, stride, pixels, bottom_up, seq, timestamp = HEADER.unpack(header)
    if (magic, version, length, pixels, bottom_up) != (b"S2VT", 1, 64, 0x41524742, 1):
        raise ValueError("unsupported S2VT video header")
    if w != width or not content_height <= h <= content_height + 19 or stride != w * 4:
        raise ValueError("unexpected video geometry %dx%d (stride %d)" % (w, h, stride))
    return w, h, read_exact(stream, stride * h)


def record(pipe, output, width, height):
    encoder = None
    geometry = None
    frames = 0
    try:
        with open(pipe, "rb", buffering=0) as stream:
            while True:
                try:
                    frame = read_frame(stream, width, height)
                except EOFError as exc:
                    # Stopping the simulator can interrupt its final write.
                    # Never pass an incomplete payload into ffmpeg.
                    print("walk-video: %s; discarded" % exc, file=sys.stderr)
                    break
                if frame is None:
                    break
                w, h, payload = frame
                if encoder is None:
                    geometry = w, h
                    encoder = subprocess.Popen([
                        "ffmpeg", "-nostdin", "-y", "-loglevel", "error",
                        "-f", "rawvideo", "-pixel_format", "bgr0",
                        "-video_size", "%dx%d" % (w, h), "-framerate", "15",
                        "-use_wallclock_as_timestamps", "1", "-i", "pipe:0",
                        "-vf", "vflip,crop=%d:%d:0:%d,pad=ceil(iw/2)*2:ceil(ih/2)*2,format=yuv420p"
                        % (width, height, h - height),
                        "-fps_mode", "cfr", "-r", "15", "-c:v", "libx264",
                        "-preset", "ultrafast", "-crf", "20",
                        "-movflags", "+frag_keyframe+empty_moov+default_base_moof",
                        "-frag_duration", "1000000", "-flush_packets", "1", output,
                    ], stdin=subprocess.PIPE)
                elif (w, h) != geometry:
                    raise ValueError("video surface resized during recording")
                encoder.stdin.write(payload)
                frames += 1
    finally:
        if encoder is not None:
            try:
                encoder.stdin.close()
            finally:
                try:
                    status = encoder.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    encoder.kill()
                    encoder.wait()
                    raise
            if status:
                raise RuntimeError("ffmpeg exited with status %d" % status)
    if not frames:
        raise RuntimeError("the engine delivered no complete video frames")
    print("walk-video: recorded %d complete frames" % frames, file=sys.stderr)


def interrupted(signum, frame):
    raise InterruptedError("recording interrupted")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    try:
        record(sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
        sys.exit("walk-video: %s" % exc)
