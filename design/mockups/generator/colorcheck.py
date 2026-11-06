import math, itertools, sys
def hx(h): h=h.lstrip('#'); return [int(h[i:i+2],16)/255 for i in (0,2,4)]
def lin(c): return c/12.92 if c<=0.04045 else ((c+0.055)/1.055)**2.4
def lum(h): r,g,b=[lin(c) for c in hx(h)]; return 0.2126*r+0.7152*g+0.0722*b
def cr(a,b):
    la,lb=lum(a),lum(b); return (max(la,lb)+0.05)/(min(la,lb)+0.05)
def oklab(h):
    r,g,b=[lin(c) for c in hx(h)]
    l=0.4122214708*r+0.5363325363*g+0.0514459929*b
    m=0.2119034982*r+0.6806995451*g+0.1073969566*b
    s=0.0883024619*r+0.2817188376*g+0.6299787005*b
    l,m,s=[x**(1/3) for x in (l,m,s)]
    return (0.2104542553*l+0.7936177850*m-0.0040720468*s,1.9779984951*l-2.4285922050*m+0.4505937099*s,0.0259040371*l+0.7827717662*m-0.8086757660*s)
def de(a,b): A,B=oklab(a),oklab(b); return 100*math.dist(A,B)
av=dict(green='#2e7d32',blue='#2f67c8',red='#c0392f',violet='#6a4fc8',orange='#b5541b',teal='#0f7c72',ochre='#8a6500',magenta='#b4386e')
av=dict(a.split('=') for a in sys.argv[1:]) if len(sys.argv)>1 else av
if __name__=="__main__":
 for k,v in av.items():
    L=oklab(v)
    print(f"{k:8} {v} white {cr(v,'#ffffff'):.2f}  vs content-dark {cr(v,'#1e1e1e'):.2f} sidebar-dark {cr(v,'#2a2a2a'):.2f}  vs content-light {cr(v,'#ffffff'):.2f} sidebar-light {cr(v,'#e8e8e8'):.2f} L={L[0]:.2f}")
ps=[(de(av[a],av[b]),a,b) for a,b in itertools.combinations(av,2)]
ps.sort(); print('min pair dE', [f"{d:.1f} {a}-{b}" for d,a,b in ps[:5]])
lanes=['#008300','#2a78d6','#e34948','#6250d6','#eb6834','#1baf7a','#eda100','#e87ba4']
