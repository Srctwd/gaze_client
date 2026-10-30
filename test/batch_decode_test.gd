extends SceneTree

# Builds SpawnUnitBatch/UnitPosBatch packets the way the server's PacketWriter
# does (little-endian) and checks network.gd unpacks every record.
func _initialize() -> void:
	var net = load("res://net/network.gd").new()
	var spawned := []
	var moved := []
	net.unit_spawned.connect(func(id, t, v, p, a, r, h): spawned.append([id, t, v, p, a, r, h]))
	net.unit_pos.connect(func(id, t, v, p, ry, pi, a): moved.append([id, t, v, p, a]))

	var sb := PackedByteArray([0x27, 3])
	for i in 3:
		var rec := PackedByteArray(); rec.resize(27)
		rec.encode_u32(0, 1000 + i); rec[4] = 9; rec[5] = i
		rec.encode_float(6, 1.5 + i); rec.encode_float(10, -4.25); rec.encode_float(14, 8.0)
		rec[18] = 0; rec.encode_float(19, 0.3); rec.encode_float(23, 1.0)
		sb.append_array(rec)
	net._parse(sb)

	var pb := PackedByteArray([0x28, 2])
	for i in 2:
		var rec := PackedByteArray(); rec.resize(20)
		rec.encode_u32(0, 2000 + i); rec[4] = 1; rec[5] = 7
		rec.encode_float(6, 10.0 * i); rec.encode_float(10, 2.0); rec.encode_float(14, -3.0)
		rec[18] = 0x23; rec[19] = 1
		pb.append_array(rec)
	net._parse(pb)

	var ok := spawned.size() == 3 and moved.size() == 2
	ok = ok and spawned[2][0] == 1002 and spawned[2][1] == 9 and spawned[2][2] == 2
	ok = ok and spawned[2][3] == Vector3(3.5, -4.25, 8.0) and is_equal_approx(spawned[2][5], 0.3) and spawned[2][6] == 1.0
	ok = ok and moved[1][0] == 2001 and moved[1][3] == Vector3(10.0, 2.0, -3.0) and moved[1][4] == 1
	print(spawned)
	print(moved)
	print("BATCH DECODE ", "OK" if ok else "FAILED")
	net.free()
	quit(0 if ok else 1)
