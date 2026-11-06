import math, itertools
from colorcheck import cr, de
def oklch2hex(L,C,h):
    a=C*math.cos(math.radians(h)); b=C*math.sin(math.radians(h))
    l_=L+0.3963377774*a+0.2158037573*b; m_=L-0.1055613458*a-0.0638541728*b; s_=L-0.0894841775*a-1.2914855480*b
    l,m,s=l_**3,m_**3,s_**3
    r=4.0767416621*l-3.3077115913*m+0.2309699292*s; g=-1.2684380046*l+2.6097574011*m-0.3413193965*s; bb=-0.0041960863*l-0.7034186147*m+1.7076147010*s
    out=[]
    for c in (r,g,bb):
        if c<-0.001 or c>1.001: return None
        c=min(max(c,0),1); c=12.92*c if c<=0.0031308 else 1.055*c**(1/2.4)-0.055
        out.append(round(c*255))
    return '#%02x%02x%02x'%tuple(out)
best=None
names=['red','orange','olive','green','teal','blue','violet','magenta']
for off in range(0,45,3):
  for Ls in [(0.52,)*8,(0.50,0.56)*4,(0.48,0.57)*4]:
    for C in (0.12,0.13,0.14):
        hs=[(off+i*45)%360 for i in range(8)]
        cols=[oklch2hex(Ls[i],C,hs[i]) for i in range(8)]
        if None in cols: continue
        if min(cr(c,'#ffffff') for c in cols)<4.6: continue
        m=min(de(a,b) for a,b in itertools.combinations(cols,2))
        if best is None or m>best[0]: best=(m,off,Ls,C,cols)
print(best)
