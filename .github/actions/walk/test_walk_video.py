import importlib.util
import io
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("walk_video", Path(__file__).with_name("walk-video.py"))
video = importlib.util.module_from_spec(spec)
spec.loader.exec_module(video)


def packet(payload, w=8, h=4, **changes):
    values = dict(magic=b"S2VT", version=1, length=64, w=w, h=h,
                  stride=w * 4, pixels=0x41524742, bottom_up=1, seq=1, timestamp=10)
    values.update(changes)
    return video.HEADER.pack(*values.values()) + payload


class Chunked(io.BytesIO):
    def read(self, size):
        return super().read(min(size, 7))


class VideoProtocolTests(unittest.TestCase):
    def test_headers_are_removed_from_every_frame(self):
        first, second = bytes(range(128)), bytes(reversed(range(128)))
        stream = Chunked(packet(first) + packet(second, seq=2))
        self.assertEqual(video.read_frame(stream, 8, 4), (8, 4, first))
        self.assertEqual(video.read_frame(stream, 8, 4), (8, 4, second))
        self.assertIsNone(video.read_frame(stream, 8, 4))

    def test_header_and_payload_truncation_never_emit_partial_pixels(self):
        for data in (b"S2", packet(b"short")):
            with self.subTest(data=data), self.assertRaises(EOFError):
                video.read_frame(io.BytesIO(data), 8, 4)

    def test_unsupported_headers_are_rejected(self):
        for change in (dict(magic=b"FAIL"), dict(version=2), dict(length=32),
                       dict(pixels=0), dict(bottom_up=0)):
            with self.subTest(change=change), self.assertRaises(ValueError):
                video.read_frame(io.BytesIO(packet(bytes(128), **change)), 8, 4)

    def test_wrong_geometry_and_stride_are_rejected(self):
        for change in (dict(w=9), dict(h=3), dict(h=24), dict(stride=40)):
            with self.subTest(change=change), self.assertRaises(ValueError):
                video.read_frame(io.BytesIO(packet(bytes(128), **change)), 8, 4)

    def test_surface_with_menu_bar_uses_header_dimensions(self):
        payload = bytes(8 * 23 * 4)
        self.assertEqual(video.read_frame(io.BytesIO(packet(payload, h=23)), 8, 4), (8, 23, payload))


if __name__ == "__main__":
    unittest.main()
