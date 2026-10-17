extends RefCounted
## Builds PS2-style paletted textures (PS2_RENDERING.md §5): a small image
## whose pixels are indices into a 16-colour (4-bit) or 256-colour (8-bit)
## CLUT. The GS looks the index up and then filters bilinearly, so the
## result is returned as an ordinary RGBA texture holding only palette
## colours.

const SPRITE_MAX_SIZE := 32   # particle textures were tiny: VRAM is 4 MB in total
const KMEANS_ROUNDS   := 8


## `colours` is the palette size (16 = PSMT4, 256 = PSMT8). `msdf` bakes a
## multi-channel distance field down to a plain white sprite with alpha,
## since the GS can only sample colours.
static func palettize(tex: Texture2D, colours: int = 16, max_size: int = SPRITE_MAX_SIZE,
		msdf: bool = false) -> ImageTexture:
	var img := tex.get_image()
	if img == null or img.is_empty():
		return null
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	if msdf:
		_bake_msdf(img)
	var w := img.get_width()
	var h := img.get_height()
	if maxi(w, h) > max_size:
		var k := float(max_size) / maxi(w, h)
		img.resize(maxi(1, nearest_po2(int(w * k))), maxi(1, nearest_po2(int(h * k))), Image.INTERPOLATE_LANCZOS)

	var palette := _kmeans(img, colours)
	for y in img.get_height():
		for x in img.get_width():
			img.set_pixel(x, y, palette[_closest(palette, img.get_pixel(x, y))])
	img.generate_mipmaps()
	var out := ImageTexture.create_from_image(img)
	out.set_meta("ps2_palette", palette)
	return out


# MSDF: the shape edge is where the median of R, G, B crosses 0.5.
static func _bake_msdf(img: Image) -> void:
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var d := maxf(minf(c.r, c.g), minf(maxf(c.r, c.g), c.b))
			img.set_pixel(x, y, Color(1, 1, 1, clampf((d - 0.5) * 8.0 + 0.5, 0.0, 1.0) * c.a))


# Palette by k-means over RGBA, seeded from pixels spread across brightness.
static func _kmeans(img: Image, colours: int) -> PackedColorArray:
	var px := PackedColorArray()
	for y in img.get_height():
		for x in img.get_width():
			px.append(img.get_pixel(x, y))
	var sorted := Array(px)
	sorted.sort_custom(func(a: Color, b: Color): return a.get_luminance() + a.a < b.get_luminance() + b.a)
	var k := mini(colours, px.size())
	var pal := PackedColorArray()
	for i in k:
		pal.append(sorted[int((i + 0.5) * sorted.size() / k)])

	for _round in KMEANS_ROUNDS:
		var sums: Array[Vector4] = []
		var counts := PackedInt32Array()
		sums.resize(k)
		counts.resize(k)
		for i in k:
			sums[i] = Vector4()
		for c in px:
			var j := _closest(pal, c)
			sums[j] += Vector4(c.r, c.g, c.b, c.a)
			counts[j] += 1
		for i in k:
			if counts[i] > 0:
				var m: Vector4 = sums[i] / counts[i]
				pal[i] = Color(m.x, m.y, m.z, m.w)
	# Snap to 8 bits per channel, as stored in the CLUT (PSMCT32).
	for i in k:
		var c := pal[i]
		pal[i] = Color8(roundi(c.r * 255.0), roundi(c.g * 255.0), roundi(c.b * 255.0), roundi(c.a * 255.0))
	return pal


static func _closest(pal: PackedColorArray, c: Color) -> int:
	var best := 0
	var best_d := INF
	for i in pal.size():
		var p := pal[i]
		var d := (p.r - c.r) * (p.r - c.r) + (p.g - c.g) * (p.g - c.g) + (p.b - c.b) * (p.b - c.b) + (p.a - c.a) * (p.a - c.a)
		if d < best_d:
			best_d = d
			best = i
	return best
