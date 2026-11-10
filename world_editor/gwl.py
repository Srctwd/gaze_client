import struct
class R:
    def __init__(s,b): s.b=b; s.p=0
    def u8(s): v=s.b[s.p]; s.p+=1; return v
    def u32(s): v=struct.unpack_from('<I',s.b,s.p)[0]; s.p+=4; return v
    def f(s): v=struct.unpack_from('<f',s.b,s.p)[0]; s.p+=4; return v
    def ps(s): n=s.u8(); v=s.b[s.p:s.p+n].decode(); s.p+=n; return v
    def eof(s): return s.p>=len(s.b)
def i32(v): return v-0x100000000 if v>=0x80000000 else v
def load(path):
    r=R(open(path,'rb').read()); W={}
    magic=r.u32(); assert magic in (0x47574C37,0x47574C38,0x47574C39), hex(magic)  # GWL7; GWL8 (no biome material/spawner); GWL9 (+ pillars)
    W['cc']=r.u32(); W['cx']=r.u32(); W['cz']=r.u32(); W['cs']=r.f()
    W['ox']=i32(r.u32()); W['oz']=i32(r.u32()); so=r.u32(); bo=r.u32()
    po=r.u32() if magic==0x47574C39 else 0
    n=W['cx']*W['cz']; cells=(W['cc']+1)**2
    tab=[(r.u8(),r.u8(),r.u32()) for _ in range(n)]
    W['chunks']=[]
    for t,b,o in tab:
        r.p=o; h1=[r.f() for _ in range(cells)]; h2=h3=[]
        if t==2: h2=[r.f() for _ in range(cells)]; h3=[r.f() for _ in range(cells)]
        W['chunks'].append(dict(type=t,biome=b,h1=h1,h2=h2,h3=h3))
    r.p=so
    W['objs']=[dict(type=r.u8(),x=r.f(),z=r.f(),radius=r.f(),height=r.f()) for _ in range(r.u32())]
    W['water']=[dict(x=r.f(),z=r.f(),width=r.f(),depth=r.f(),y=r.f(),wf=r.u8()) for _ in range(r.u32())]
    W['biomes']=[]
    for _ in range(r.u8()):
        bid=r.u8(); nm=r.ps()
        if magic==0x47574C37: r.ps()  # material
        props=[(r.ps(),r.f()) for _ in range(r.u8())]
        if magic==0x47574C37: r.ps(); r.f(); r.u8(); r.f()  # spawner: type interval max prob
        W['biomes'].append(dict(id=bid,name=nm,props=props))
    W['ptypes']=[r.ps() for _ in range(r.u8())]
    W['props']=[dict(t=r.u8(),x=r.f(),y=r.f(),z=r.f(),ry=r.f(),sx=r.f(),sy=r.f(),sz=r.f()) for _ in range(r.u32())]
    W['otypes']=[(r.u8(),r.ps(),r.f()) for _ in range(r.u32())]
    assert r.p==bo,(r.p,bo)
    W['walls']=[]
    for _ in range(r.u32()):
        w=dict(type=r.u8(),x=r.f(),z=r.f(),hx=r.f(),hz=r.f(),ry=r.f(),h=r.f(),yo=r.f())
        w['low']=r.f()  # ramp: top rises from low at -hx to h at +hx; <0 = flat
        w['op']=[tuple(r.f() for _ in range(6)) for _ in range(r.u8())]
        W['walls'].append(w)
    W['wtypes']=[(r.u8(),r.ps()) for _ in range(r.u32())]
    W['pillars']=[]  # upright cylinders; base = terrain under the centre + yo
    if po:
        assert r.p==po,(r.p,po)
        W['pillars']=[dict(type=r.u8(),x=r.f(),z=r.f(),radius=r.f(),height=r.f(),yo=r.f()) for _ in range(r.u32())]
    assert r.eof()
    return W
def save(W,path):
    out=bytearray(); P=lambda fmt,*a: out.extend(struct.pack('<'+fmt,*a))
    def ps(s): b=s.encode()[:255]; P('B',len(b)); out.extend(b)
    n=W['cx']*W['cz']; cells=(W['cc']+1)**2
    cur=40+n*6; offs=[]
    for c in W['chunks']:
        offs.append(cur); cur+=cells*4*(3 if c['type']==2 else 1)
    P('I',0x47574C39); P('III',W['cc'],W['cx'],W['cz']); P('f',W['cs'])
    P('II',W['ox']&0xFFFFFFFF,W['oz']&0xFFFFFFFF); P('I',cur); P('I',0); P('I',0)  # box_off, pillar_off: patched below
    for c,o in zip(W['chunks'],offs): P('BBI',c['type'],c['biome'],o)
    for c in W['chunks']:
        out.extend(struct.pack('<%df'%cells,*c['h1']))
        if c['type']==2:
            out.extend(struct.pack('<%df'%cells,*c['h2'])); out.extend(struct.pack('<%df'%cells,*c['h3']))
    assert len(out)==cur
    P('I',len(W['objs']))
    for o in W['objs']: P('Bffff',o['type'],o['x'],o['z'],o['radius'],o['height'])
    P('I',len(W['water']))
    for w in W['water']: P('fffffB',w['x'],w['z'],w['width'],w['depth'],w['y'],w['wf'])
    P('B',len(W['biomes']))
    for b in W['biomes']:
        P('B',b['id']); ps(b['name']); P('B',len(b['props']))
        for pth,wt in b['props']: ps(pth); P('f',wt)
    P('B',len(W['ptypes']))
    for t in W['ptypes']: ps(t)
    P('I',len(W['props']))
    for p in W['props']: P('Bfffffff',p['t'],p['x'],p['y'],p['z'],p['ry'],p['sx'],p['sy'],p['sz'])
    P('I',len(W['otypes']))
    for i,m,s in W['otypes']: P('B',i); ps(m); P('f',s)
    struct.pack_into('<I',out,32,len(out))
    P('I',len(W['walls']))
    for w in W['walls']:
        P('Bffffffff',w['type'],w['x'],w['z'],w['hx'],w['hz'],w['ry'],w['h'],w['yo'],w.get('low',-1.0)); P('B',len(w['op']))
        for o in w['op']: P('6f',*o)
    P('I',len(W['wtypes']))
    for i,t in W['wtypes']: P('B',i); ps(t)
    struct.pack_into('<I',out,36,len(out))
    pillars=W.get('pillars',[])
    P('I',len(pillars))
    for p in pillars: P('Bfffff',p['type'],p['x'],p['z'],p['radius'],p['height'],p.get('yo',0.0))
    open(path,'wb').write(out)
