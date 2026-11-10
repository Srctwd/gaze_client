#!/usr/bin/env python3
# Grows a world.bin (GWL7/GWL8/GWL9) by adding chunks around its edges.
#
#   python3 grow_world.py world.bin bigger.bin --ring 4
#   python3 grow_world.py world.bin world.bin --east 8 --south 2      (in place, keeps world.bin.bak)
#   python3 grow_world.py world.bin bigger.bin --to 64x64             (adds the same amount on each side)
#
# Existing chunks and every section after the terrain (objects, water, biomes,
# props, walls, ...) are copied byte for byte. Only the header (size, origin,
# section offsets) and the chunk table change. Everything placed in the world
# keeps its world position, because the origin moves with the new west/north
# chunks. The painted-cells file (<world>.cells.bin) and the spawns json don't
# need to change: cells are stored by grid coordinate and spawns by world
# position.
#
# New chunks are plain terrain. By default they continue the old world's outer
# edge outwards (each new vertex copies the nearest edge vertex), so there's no
# seam. With --height H they're flat at H instead; only the vertices they
# share with the old world keep the old heights.
#
# Heights are never decoded into Python lists, so RAM stays around the size of
# the old world's outer border, whatever the world size.

import argparse
import mmap
import os
import shutil
import struct
import sys

import numpy

HEADER_FORMAT = '<IIIIfiiII'
HEADER_SIZE = struct.calcsize(HEADER_FORMAT)
TABLE_ENTRY_FORMAT = '<BBI'
TABLE_ENTRY_SIZE = struct.calcsize(TABLE_ENTRY_FORMAT)
SUPPORTED_MAGICS = (0x47574C37, 0x47574C38, 0x47574C39)
MAGIC_GWL9 = 0x47574C39  # header has a trailing pillar_offset
CHUNK_TERRAIN = 0
CHUNK_CAVE = 2


def chunk_byte_size(chunk_type, vertex_count):
    layer_count = 3 if chunk_type == CHUNK_CAVE else 1
    return vertex_count * 4 * layer_count


def read_h1(file_bytes, offset, stride):
    heights = numpy.frombuffer(file_bytes, dtype='<f4', count=stride * stride, offset=offset)
    return heights.reshape(stride, stride)


# The old world's outer ring of vertices as four arrays in old-world vertex
# coordinates: north is z = 0, south is z = max, west is x = 0, east is x = max.
def read_outer_border(file_bytes, table, chunks_x, chunks_z, chunk_cells):
    stride = chunk_cells + 1
    vertices_x = chunks_x * chunk_cells + 1
    vertices_z = chunks_z * chunk_cells + 1
    north = numpy.zeros(vertices_x, dtype='<f4')
    south = numpy.zeros(vertices_x, dtype='<f4')
    west = numpy.zeros(vertices_z, dtype='<f4')
    east = numpy.zeros(vertices_z, dtype='<f4')
    for chunk_ax in range(chunks_x):
        top = read_h1(file_bytes, table[chunk_ax][2], stride)
        bottom = read_h1(file_bytes, table[(chunks_z - 1) * chunks_x + chunk_ax][2], stride)
        start = chunk_ax * chunk_cells
        north[start:start + stride] = top[0, :]
        south[start:start + stride] = bottom[chunk_cells, :]
    for chunk_az in range(chunks_z):
        left = read_h1(file_bytes, table[chunk_az * chunks_x][2], stride)
        right = read_h1(file_bytes, table[chunk_az * chunks_x + chunks_x - 1][2], stride)
        start = chunk_az * chunk_cells
        west[start:start + stride] = left[:, 0]
        east[start:start + stride] = right[:, chunk_cells]
    return north, south, west, east


# h1 of a new chunk whose first vertex sits at old-world vertex (first_gx, first_gz).
def build_new_h1(first_gx, first_gz, chunk_cells, border, max_gx, max_gz, flat_height):
    north, south, west, east = border
    offsets = numpy.arange(chunk_cells + 1)
    grid_gx, grid_gz = numpy.meshgrid(first_gx + offsets, first_gz + offsets)
    clamped_gx = numpy.clip(grid_gx, 0, max_gx)
    clamped_gz = numpy.clip(grid_gz, 0, max_gz)
    # Every clamped vertex lies on the old outer border, so one of the four
    # arrays holds it.
    heights = numpy.where(clamped_gx == max_gx, east[clamped_gz], west[clamped_gz])
    heights = numpy.where(clamped_gz == max_gz, south[clamped_gx], heights)
    heights = numpy.where(clamped_gz == 0, north[clamped_gx], heights)
    on_old_border = (grid_gx == clamped_gx) & (grid_gz == clamped_gz)
    if flat_height is not None:
        heights = numpy.where(on_old_border, heights, numpy.float32(flat_height))
    else:
        # A hole (NaN) on the old edge stays a hole where it's shared, but
        # isn't dragged outwards across the new chunks.
        heights = numpy.where(on_old_border | ~numpy.isnan(heights), heights, numpy.float32(0.0))
    return heights.astype('<f4').tobytes()


def parse_target_size(text):
    parts = text.lower().split('x')
    if len(parts) != 2:
        raise argparse.ArgumentTypeError('expected WxH, e.g. 64x64')
    return int(parts[0]), int(parts[1])


def main():
    parser = argparse.ArgumentParser(description='Add chunks around the edges of a world.bin.')
    parser.add_argument('input')
    parser.add_argument('output', help='may equal input; the old file is then kept as <input>.bak')
    parser.add_argument('--west', type=int, default=0, help='chunks to add on the -x side')
    parser.add_argument('--east', type=int, default=0, help='chunks to add on the +x side')
    parser.add_argument('--north', type=int, default=0, help='chunks to add on the -z side')
    parser.add_argument('--south', type=int, default=0, help='chunks to add on the +z side')
    parser.add_argument('--ring', type=int, default=0, help='chunks to add on every side')
    parser.add_argument('--to', type=parse_target_size, help='final size WxH in chunks, split evenly between both sides (the odd one goes east/south)')
    parser.add_argument('--height', type=float, default=None, help='flat height for new chunks (default: extend the old edge outwards)')
    parser.add_argument('--biome', type=int, default=None, help='biome id for new chunks (default: the nearest old chunk\'s)')
    arguments = parser.parse_args()

    with open(arguments.input, 'rb') as input_file:
        file_bytes = mmap.mmap(input_file.fileno(), 0, access=mmap.ACCESS_READ)
    magic, chunk_cells, chunks_x, chunks_z, cell_size, origin_cx, origin_cz, static_offset, box_offset = struct.unpack_from(HEADER_FORMAT, file_bytes, 0)
    if magic not in SUPPORTED_MAGICS:
        sys.exit('unsupported world format %#x (need GWL7/GWL8/GWL9)' % magic)
    has_pillars = magic == MAGIC_GWL9
    header_size = HEADER_SIZE + (4 if has_pillars else 0)
    pillar_offset = struct.unpack_from('<I', file_bytes, HEADER_SIZE)[0] if has_pillars else 0
    if box_offset < static_offset:
        sys.exit('box offset %d is before static offset %d: the file looks truncated (interrupted save?)' % (box_offset, static_offset))

    add_west = arguments.west + arguments.ring
    add_east = arguments.east + arguments.ring
    add_north = arguments.north + arguments.ring
    add_south = arguments.south + arguments.ring
    if arguments.to is not None:
        target_x, target_z = arguments.to
        if target_x < chunks_x or target_z < chunks_z:
            sys.exit('--to %dx%d is smaller than the world (%dx%d); this script only grows' % (target_x, target_z, chunks_x, chunks_z))
        add_west += (target_x - chunks_x) // 2
        add_east += (target_x - chunks_x) - (target_x - chunks_x) // 2
        add_north += (target_z - chunks_z) // 2
        add_south += (target_z - chunks_z) - (target_z - chunks_z) // 2
    if min(add_west, add_east, add_north, add_south) < 0:
        sys.exit('chunk counts must not be negative')
    if add_west + add_east + add_north + add_south == 0:
        sys.exit('nothing to add (use --ring, --to or --west/--east/--north/--south)')

    stride = chunk_cells + 1
    vertex_count = stride * stride
    old_count = chunks_x * chunks_z
    table = [struct.unpack_from(TABLE_ENTRY_FORMAT, file_bytes, header_size + index * TABLE_ENTRY_SIZE) for index in range(old_count)]
    for chunk_type, biome, offset in table:
        if offset + chunk_byte_size(chunk_type, vertex_count) > len(file_bytes):
            sys.exit('chunk data at %d runs past the end of the file' % offset)

    new_chunks_x = chunks_x + add_west + add_east
    new_chunks_z = chunks_z + add_north + add_south
    new_count = new_chunks_x * new_chunks_z
    max_gx = chunks_x * chunk_cells
    max_gz = chunks_z * chunk_cells
    border = read_outer_border(file_bytes, table, chunks_x, chunks_z, chunk_cells)

    # Lay out the new chunk table: (type, biome, offset, old index or -1).
    layout = []
    data_cursor = header_size + new_count * TABLE_ENTRY_SIZE
    for new_az in range(new_chunks_z):
        for new_ax in range(new_chunks_x):
            old_ax = new_ax - add_west
            old_az = new_az - add_north
            if 0 <= old_ax < chunks_x and 0 <= old_az < chunks_z:
                old_index = old_az * chunks_x + old_ax
                chunk_type, biome, old_offset = table[old_index]
            else:
                old_index = -1
                chunk_type = CHUNK_TERRAIN
                nearest_ax = min(max(old_ax, 0), chunks_x - 1)
                nearest_az = min(max(old_az, 0), chunks_z - 1)
                biome = table[nearest_az * chunks_x + nearest_ax][1] if arguments.biome is None else arguments.biome
            layout.append((chunk_type, biome, data_cursor, old_index, old_ax, old_az))
            data_cursor += chunk_byte_size(chunk_type, vertex_count)
    new_static_offset = data_cursor
    new_box_offset = box_offset - static_offset + new_static_offset
    new_pillar_offset = pillar_offset - static_offset + new_static_offset if pillar_offset else 0

    temp_path = arguments.output + '.tmp'
    with open(temp_path, 'wb') as output_file:
        output_file.write(struct.pack(HEADER_FORMAT, magic, chunk_cells, new_chunks_x, new_chunks_z, cell_size, origin_cx - add_west, origin_cz - add_north, new_static_offset, new_box_offset))
        if has_pillars:
            output_file.write(struct.pack('<I', new_pillar_offset))
        for chunk_type, biome, offset, old_index, old_ax, old_az in layout:
            output_file.write(struct.pack(TABLE_ENTRY_FORMAT, chunk_type, biome, offset))
        for chunk_type, biome, offset, old_index, old_ax, old_az in layout:
            if old_index >= 0:
                old_offset = table[old_index][2]
                output_file.write(file_bytes[old_offset:old_offset + chunk_byte_size(chunk_type, vertex_count)])
            else:
                output_file.write(build_new_h1(old_ax * chunk_cells, old_az * chunk_cells, chunk_cells, border, max_gx, max_gz, arguments.height))
        assert output_file.tell() == new_static_offset
        output_file.write(file_bytes[static_offset:])
    file_bytes.close()

    if os.path.abspath(arguments.output) == os.path.abspath(arguments.input):
        shutil.copy2(arguments.input, arguments.input + '.bak')
    os.replace(temp_path, arguments.output)

    chunk_span = chunk_cells * cell_size
    print('%dx%d -> %dx%d chunks (%.0f x %.0f m), origin (%d, %d) -> (%d, %d), %d new chunks, %s written' % (chunks_x, chunks_z, new_chunks_x, new_chunks_z, new_chunks_x * chunk_span, new_chunks_z * chunk_span, origin_cx, origin_cz, origin_cx - add_west, origin_cz - add_north, new_count - old_count, arguments.output))


if __name__ == '__main__':
    main()
