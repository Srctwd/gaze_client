from PIL import Image, ImageDraw
import random
import math

width, height = 1024, 1024
random.seed(1337)

# Warm, weathered brown stone wall
image = Image.new("RGB", (width, height), (49, 37, 27))
draw = ImageDraw.Draw(image)

brick_width = 128
brick_height = 64

# Tiling only works if the brick grid divides the texture exactly and the running-bond offset repeats
assert width % brick_width == 0 and height % brick_height == 0 and (height // brick_height) % 2 == 0

# Every shape is drawn at its position plus the 8 neighbouring tile positions, so anything crossing an edge reappears on the opposite edge
wrap_offsets = [(offset_x, offset_y) for offset_x in (-width, 0, width) for offset_y in (-height, 0, height)]


def shift_points(points, offset_x, offset_y):
    return [(point_x + offset_x, point_y + offset_y) for point_x, point_y in points]


def shift_box(box, offset_x, offset_y):
    return [box[0] + offset_x, box[1] + offset_y, box[2] + offset_x, box[3] + offset_y]


def wrap_line(points, **style):
    for offset_x, offset_y in wrap_offsets:
        draw.line(shift_points(points, offset_x, offset_y), **style)


def wrap_ellipse(box, **style):
    for offset_x, offset_y in wrap_offsets:
        draw.ellipse(shift_box(box, offset_x, offset_y), **style)


def wrap_rectangle(box, **style):
    for offset_x, offset_y in wrap_offsets:
        draw.rectangle(shift_box(box, offset_x, offset_y), **style)


def wrap_point(point_x, point_y, fill):
    draw.point((point_x % width, point_y % height), fill=fill)


# Earthy brown stone palette
brick_colors = [
    (100, 68, 43),
    (112, 77, 48),
    (91, 61, 40),
    (123, 84, 52),
    (104, 72, 46),
    (85, 59, 41),
    (116, 79, 47),
]

# Draw bricks with variation and weathered edges, one brick per grid cell so edge bricks are shared across the seam
for row in range(height // brick_height):
    y = row * brick_height
    offset = (row % 2) * (brick_width // 2)

    for column in range(width // brick_width):
        x = column * brick_width + offset
        color = random.choice(brick_colors)

        wrap_rectangle([x, y, x + brick_width - 2, y + brick_height - 2], fill=color, outline=(39, 30, 23), width=3)

        # Scattered stone grain and weathering
        for _ in range(random.randint(35, 65)):
            px = random.randint(x + 5, x + brick_width - 7)
            py = random.randint(y + 5, y + brick_height - 7)

            variation = random.choice([-22, -14, -8, 8, 14, 20])
            grain = tuple(max(0, min(255, channel + variation)) for channel in color)

            size = random.choice([1, 2, 3])
            wrap_ellipse([px, py, px + size, py + size], fill=grain)

        # Occasional cracks
        if random.random() < 0.35:
            cx = random.randint(x + 15, x + brick_width - 15)
            cy = random.randint(y + 10, y + brick_height - 10)

            points = [(cx, cy)]
            for _ in range(random.randint(2, 4)):
                cx += random.randint(-5, 5)
                cy += random.randint(3, 8)
                points.append((cx, cy))

            wrap_line(points, fill=(49, 36, 25), width=2)

# Moss growing in horizontal mortar joints, including the joint on the tile edge
moss_colors = [
    (53, 68, 32),
    (67, 77, 36),
    (83, 89, 43),
    (44, 57, 30),
]

for y in range(0, height, brick_height):
    for x in range(width):
        if random.random() < 0.13:
            wrap_point(x, y + random.randint(-2, 2), random.choice(moss_colors))


def draw_vine(start_x, start_y):
    # The vine climbs exactly one texture height and ends where it began, so it continues into the tile above
    end_y = start_y - height
    points = [(start_x, start_y)]
    x, y = start_x, start_y

    # Winding, organic growth
    while y - 25 > end_y:
        y -= random.randint(12, 25)
        x += random.randint(-16, 16)
        points.append((x, y))

    points.append((x + random.randint(-16, 16), end_y))

    # Spread the accumulated sideways drift along the vine so the top lines up with the bottom
    drift = points[-1][0] - start_x
    climb_points = []
    for point_x, point_y in points:
        progress = (start_y - point_y) / height
        climb_points.append((int(round(point_x - drift * progress)), point_y))
    points = climb_points

    # Thick woody stem drawn as whole layers so joints stay smooth instead of each segment covering the last highlight
    wrap_line(points, fill=(30, 35, 20), width=10, joint="curve")
    wrap_line(points, fill=(65, 75, 35), width=7, joint="curve")
    wrap_line(points, fill=(105, 92, 48), width=2, joint="curve")

    # Side branches
    for index in range(len(points) - 1):
        p1, p2 = points[index], points[index + 1]

        if random.random() < 0.7:
            bx = (p1[0] + p2[0]) // 2
            by = (p1[1] + p2[1]) // 2
            direction = random.choice([-1, 1])
            ex = bx + direction * random.randint(12, 25)
            ey = by - random.randint(5, 16)

            wrap_line([(bx, by), (ex, ey)], fill=(63, 82, 35), width=3)

    leaf_greens = [
        (44, 86, 30),
        (58, 110, 35),
        (79, 133, 42),
        (105, 148, 49),
        (36, 68, 28),
        (126, 151, 57),
    ]

    # Leaves attached to stems and branches; the last point is the first point in the next tile, so it is skipped
    for px, py in points[:-1]:
        for _ in range(random.randint(3, 6)):
            angle = random.uniform(0, 2 * math.pi)
            distance = random.randint(5, 22)

            lx = px + int(math.cos(angle) * distance)
            ly = py + int(math.sin(angle) * distance)

            leaf_w = random.randint(5, 10)
            leaf_h = random.randint(4, 8)

            green = random.choice(leaf_greens)

            # Leaf shadow
            wrap_ellipse([lx - leaf_w, ly - leaf_h + 2, lx + leaf_w, ly + leaf_h + 2], fill=(31, 39, 23))

            # Leaf
            wrap_ellipse([lx - leaf_w, ly - leaf_h, lx + leaf_w, ly + leaf_h], fill=green, outline=(35, 55, 24))

            # Central leaf vein
            wrap_line([(lx - leaf_w // 2, ly), (lx + leaf_w // 2, ly)], fill=(145, 153, 73), width=1)


# Main climbing vines
for _ in range(9):
    start_x = random.randint(0, width - 1)
    draw_vine(start_x, random.randint(0, height - 1))

# Scattered moss tufts; spread over the whole tile because a ground band would show as a stripe when repeated
moss_tuft_colors = [
    (49, 70, 31),
    (63, 83, 37),
    (78, 94, 43),
    (91, 99, 47),
]

for _ in range(250):
    x = random.randint(0, width - 1)
    y = random.randint(0, height - 1)

    color = random.choice(moss_tuft_colors)

    wrap_ellipse([x, y, x + random.randint(2, 5), y + random.randint(2, 5)], fill=color)

# Uniform darkening keeps the old overall tone; an edge vignette would show as a grid of dark lines when tiled
image = Image.blend(image, Image.new("RGB", (width, height), (16, 11, 7)), 0.18)

image.save("climbable_vine_wall.png")
print("Successfully generated 'climbable_vine_wall.png'!")
