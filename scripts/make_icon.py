"""Generate an original 32px book icon without external image dependencies."""
from pathlib import Path
import struct
import zlib

size = 32
pixels = bytearray()
for y in range(size):
    pixels.append(0)
    for x in range(size):
        color = (39, 119, 106, 255)
        if 6 <= x <= 25 and 7 <= y <= 24:
            color = (244, 244, 224, 255)
        if x in (15, 16) and 8 <= y <= 24:
            color = (39, 119, 106, 255)
        if 10 <= y <= 19 and y % 4 == 2 and (8 <= x <= 12 or 19 <= x <= 23):
            color = (131, 168, 146, 255)
        pixels.extend(color)

def chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))

png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')
target = Path(__file__).resolve().parents[1] / 'assets' / 'tray.ico'
target.parent.mkdir(exist_ok=True)
target.write_bytes(struct.pack('<HHH', 0, 1, 1) + struct.pack('<BBBBHHII', size, size, 0, 0, 1, 32, len(png), 22) + png)
