from PIL import Image, ImageDraw, ImageFilter, ImageFont
import math
S=2; W,H=1920*S,1080*S
P='/usr/share/fonts/truetype/google-fonts/Poppins-'
def F(w,s): return ImageFont.truetype(P+w+'.ttf', s*S)

def base():
    img=Image.new('RGB',(W,H),'#070B1E')
    # vertical gradient
    g=Image.new('RGB',(1,H))
    for y in range(H):
        t=y/H
        c=(int(7+ (12-7)*t), int(11+(16-11)*t), int(30+(46-30)*t))
        g.putpixel((0,y),c)
    img=g.resize((W,H))
    # glows
    glow=Image.new('RGBA',(W,H),(0,0,0,0)); d=ImageDraw.Draw(glow)
    d.ellipse([-500*S,650*S,700*S,1500*S],fill=(124,58,237,90))
    d.ellipse([1500*S,-300*S,2400*S,500*S],fill=(6,182,212,55))
    d.ellipse([1300*S,800*S,2300*S,1500*S],fill=(236,72,153,45))
    glow=glow.filter(ImageFilter.GaussianBlur(220*S))
    img=Image.alpha_composite(img.convert('RGBA'),glow)
    # subtle grid lines
    gl=Image.new('RGBA',(W,H),(0,0,0,0)); gd=ImageDraw.Draw(gl)
    for x in range(0,W,60*S): gd.line([x,0,x,H],fill=(255,255,255,6),width=S)
    for y in range(0,H,60*S): gd.line([0,y,W,y],fill=(255,255,255,6),width=S)
    return Image.alpha_composite(img,gl)

def panel(img,x,y,w,h,r=18):
    x,y,w,h=[int(v*S) for v in (x,y,w,h)]
    sh=Image.new('RGBA',img.size,(0,0,0,0)); ImageDraw.Draw(sh).rounded_rectangle([x+6*S,y+10*S,x+w+6*S,y+h+10*S],r*S,fill=(0,0,0,110))
    img=Image.alpha_composite(img,sh.filter(ImageFilter.GaussianBlur(14*S)))
    lay=Image.new('RGBA',img.size,(0,0,0,0)); d=ImageDraw.Draw(lay)
    d.rounded_rectangle([x,y,x+w,y+h],r*S,fill=(19,27,58,215),outline=(58,72,128,255),width=S)
    # accent top line gradient
    for i in range(int(w-2*r*S)):
        t=i/(w-2*r*S); c=(int(124+(6-124)*t),int(58+(182-58)*t),int(237+(212-237)*t),200)
        d.line([x+r*S+i,y,x+r*S+i,y+2*S],fill=c)
    return Image.alpha_composite(img,lay)

def grad_card(img,x,y,w,h,c1,c2,icon,r=18):
    X,Y,Wd,Hd=[int(v*S) for v in (x,y,w,h)]
    sh=Image.new('RGBA',img.size,(0,0,0,0)); ImageDraw.Draw(sh).rounded_rectangle([X+6*S,Y+12*S,X+Wd+6*S,Y+Hd+12*S],r*S,fill=(0,0,0,130))
    img=Image.alpha_composite(img,sh.filter(ImageFilter.GaussianBlur(16*S)))
    card=Image.new('RGBA',(Wd,Hd))
    gd=ImageDraw.Draw(card)
    for i in range(Wd):
        t=i/Wd; gd.line([i,0,i,Hd],fill=tuple(int(a+(b-a)*t) for a,b in zip(c1,c2))+(255,))
    deco=Image.new('RGBA',(Wd,Hd),(0,0,0,0)); dd=ImageDraw.Draw(deco)
    dd.ellipse([Wd-170*S,-70*S,Wd+30*S,130*S],fill=(255,255,255,30))
    dd.ellipse([Wd-100*S,70*S,Wd+60*S,230*S],fill=(255,255,255,20))
    cx,cy,rad=Wd-75*S,Hd//2,36*S
    dd.ellipse([cx-rad,cy-rad,cx+rad,cy+rad],fill=(255,255,255,45),outline=(255,255,255,150),width=2*S)
    card=Image.alpha_composite(card,deco)
    icon(ImageDraw.Draw(card),cx,cy)
    m=Image.new('L',(Wd,Hd),0); ImageDraw.Draw(m).rounded_rectangle([0,0,Wd-1,Hd-1],r*S,fill=255)
    lay=Image.new('RGBA',img.size,(0,0,0,0)); lay.paste(card,(X,Y),m)
    return Image.alpha_composite(img,lay)

W1=(255,255,255,255)
def ic_text(t,size=30):
    def f(d,cx,cy):
        fn=F('Bold',size); d.text((cx,cy),t,font=fn,fill=W1,anchor='mm')
    return f
def ic_bag(d,cx,cy):
    s=S; d.rounded_rectangle([cx-18*s,cy-8*s,cx+18*s,cy+20*s],4*s,outline=W1,width=4*s)
    d.arc([cx-10*s,cy-22*s,cx+10*s,cy+2*s],180,360,fill=W1,width=4*s)
def ic_receipt(d,cx,cy):
    s=S; pts=[(cx-15*s,cy-22*s),(cx+15*s,cy-22*s),(cx+15*s,cy+22*s)]
    for i in range(6):
        pts.append((cx+15*s-(i+0.5)*5*s,cy+(16 if i%2==0 else 22)*s))
    pts.append((cx-15*s,cy+22*s))
    d.polygon(pts,outline=W1,width=4*s)
    for k in (-10,-1,8): d.line([cx-8*s,cy+k*s,cx+8*s,cy+k*s],fill=W1,width=3*s)
def ic_trend(d,cx,cy):
    s=S; d.line([(cx-20*s,cy+14*s),(cx-6*s,cy),(cx+4*s,cy+8*s),(cx+20*s,cy-12*s)],fill=W1,width=4*s,joint='curve')
    d.polygon([(cx+22*s,cy-16*s),(cx+10*s,cy-14*s),(cx+20*s,cy-4*s)],fill=W1)
def ic_bolt(d,cx,cy):
    s=S; d.polygon([(cx+4*s,cy-24*s),(cx-14*s,cy+4*s),(cx-1*s,cy+4*s),(cx-6*s,cy+24*s),(cx+14*s,cy-6*s),(cx+1*s,cy-6*s)],fill=W1)

def header(img,sub):
    d=ImageDraw.Draw(img)
    lay=Image.new('RGBA',img.size,(0,0,0,0)); ld=ImageDraw.Draw(lay)
    ld.rectangle([0,0,W,90*S],fill=(5,8,24,170))
    for i in range(W):
        t=i/W; ld.line([i,90*S-2*S,i,90*S],fill=(int(124+(6-124)*t),int(58+(182-58)*t),int(237+(212-237)*t),220))
    img=Image.alpha_composite(img,lay); d=ImageDraw.Draw(img)
    # logo
    d.rounded_rectangle([30*S,22*S,76*S,68*S],12*S,fill=(124,58,237,255))
    # db cylinder icon
    cx,cy=53*S,45*S
    d.ellipse([cx-12*S,cy-14*S,cx+12*S,cy-6*S],outline=W1,width=3*S)
    d.line([cx-12*S,cy-10*S,cx-12*S,cy+10*S],fill=W1,width=3*S); d.line([cx+12*S,cy-10*S,cx+12*S,cy+10*S],fill=W1,width=3*S)
    d.arc([cx-12*S,cy+6*S,cx+12*S,cy+14*S],0,180,fill=W1,width=3*S)
    d.text((92*S,45*S),'monitor db',font=F('Light',30),fill=(226,232,240,255),anchor='lm')
    w=d.textlength('monitor db ',font=F('Light',30))
    d.text((92*S+w,45*S),'| IA',font=F('Bold',30),fill=W1,anchor='lm')
    d.text((1890*S,36*S),sub,font=F('Medium',22),fill=W1,anchor='rm')
    d.text((1890*S,62*S),'Base fictícia de varejo · PostgreSQL + IA local',font=F('Regular',14),fill=(148,163,184,255),anchor='rm')
    return img

def save(img,name):
    img.convert('RGB').resize((1920,1080),Image.LANCZOS).save('/tmp/claude-0/bg/'+name,optimize=True)


def ic_shirt(d,cx,cy):
    s=S; d.polygon([(cx-8*s,cy-20*s),(cx-22*s,cy-12*s),(cx-16*s,cy-2*s),(cx-11*s,cy-5*s),(cx-11*s,cy+20*s),(cx+11*s,cy+20*s),(cx+11*s,cy-5*s),(cx+16*s,cy-2*s),(cx+22*s,cy-12*s),(cx+8*s,cy-20*s),(cx,cy-14*s)],outline=W1,width=3*s)
def ic_x(d,cx,cy):
    s=S; d.line([cx-12*s,cy-12*s,cx+12*s,cy+12*s],fill=W1,width=5*s); d.line([cx-12*s,cy+12*s,cx+12*s,cy-12*s],fill=W1,width=5*s)
def ic_box(d,cx,cy):
    s=S; d.polygon([(cx,cy-20*s),(cx+19*s,cy-10*s),(cx+19*s,cy+12*s),(cx,cy+22*s),(cx-19*s,cy+12*s),(cx-19*s,cy-10*s)],outline=W1,width=3*s)
    d.line([(cx-19*s,cy-10*s),(cx,cy),(cx+19*s,cy-10*s)],fill=W1,width=3*s); d.line([cx,cy,cx,cy+22*s],fill=W1,width=3*s)
def ic_alert(d,cx,cy):
    s=S; d.polygon([(cx,cy-21*s),(cx+22*s,cy+18*s),(cx-22*s,cy+18*s)],outline=W1,width=3*s)
    d.line([cx,cy-7*s,cx,cy+6*s],fill=W1,width=4*s); d.ellipse([cx-3*s,cy+10*s,cx+3*s,cy+16*s],fill=W1)
def ic_check(d,cx,cy):
    s=S; d.line([(cx-16*s,cy+1*s),(cx-5*s,cy+12*s),(cx+17*s,cy-12*s)],fill=W1,width=5*s,joint='curve')
def ic_truck(d,cx,cy):
    s=S; d.rectangle([cx-22*s,cy-12*s,cx+4*s,cy+8*s],outline=W1,width=3*s)
    d.polygon([(cx+4*s,cy-4*s),(cx+15*s,cy-4*s),(cx+22*s,cy+3*s),(cx+22*s,cy+8*s),(cx+4*s,cy+8*s)],outline=W1,width=3*s)
    for x in (-13,13): d.ellipse([cx+x*s-5*s,cy+8*s,cx+x*s+5*s,cy+18*s],fill=W1)
def ic_clock(d,cx,cy):
    s=S; d.ellipse([cx-19*s,cy-19*s,cx+19*s,cy+19*s],outline=W1,width=3*s)
    d.line([cx,cy,cx,cy-11*s],fill=W1,width=3*s); d.line([cx,cy,cx+9*s,cy+5*s],fill=W1,width=3*s)

def grad_card_small(img,x,y,w,h,c1,c2,icon,r=18):
    X,Y,Wd,Hd=[int(v*S) for v in (x,y,w,h)]
    sh=Image.new('RGBA',img.size,(0,0,0,0)); ImageDraw.Draw(sh).rounded_rectangle([X+6*S,Y+12*S,X+Wd+6*S,Y+Hd+12*S],r*S,fill=(0,0,0,130))
    img=Image.alpha_composite(img,sh.filter(ImageFilter.GaussianBlur(16*S)))
    card=Image.new('RGBA',(Wd,Hd)); gd=ImageDraw.Draw(card)
    for i in range(Wd):
        t=i/Wd; gd.line([i,0,i,Hd],fill=tuple(int(a+(b-a)*t) for a,b in zip(c1,c2))+(255,))
    deco=Image.new('RGBA',(Wd,Hd),(0,0,0,0)); dd=ImageDraw.Draw(deco)
    dd.ellipse([Wd-130*S,-60*S,Wd+30*S,100*S],fill=(255,255,255,30))
    cx,cy,rad=Wd-52*S,Hd//2,30*S
    dd.ellipse([cx-rad,cy-rad,cx+rad,cy+rad],fill=(255,255,255,45),outline=(255,255,255,150),width=2*S)
    card=Image.alpha_composite(card,deco)
    # ícone reduzido: desenha em camada maior e reduz
    big=Image.new('RGBA',(120*S,120*S),(0,0,0,0)); icon(ImageDraw.Draw(big),60*S,60*S)
    big=big.resize((96*S,96*S),Image.LANCZOS); card.alpha_composite(big,(cx-48*S,cy-48*S))
    m=Image.new('L',(Wd,Hd),0); ImageDraw.Draw(m).rounded_rectangle([0,0,Wd-1,Hd-1],r*S,fill=255)
    lay=Image.new('RGBA',img.size,(0,0,0,0)); lay.paste(card,(X,Y),m)
    return Image.alpha_composite(img,lay)

GR=[((16,185,129),(6,182,212)),((124,58,237),(236,72,153)),((245,158,11),(239,68,68)),((59,130,246),(6,182,212)),((236,72,153),(244,63,94)),((99,102,241),(139,92,246))]
def six_cards(img,icons):
    cw=(1860-5*20)/6
    for i,ic in enumerate(icons):
        img=grad_card_small(img,30+i*(cw+20),110,cw,140,GR[i][0],GR[i][1],ic)
    return img

# Página 1: 6 cards
img=header(base(),'Visão geral de vendas')
img=six_cards(img,[ic_text('R$',26),ic_bag,ic_receipt,ic_text('%',34),ic_shirt,ic_x])
for r in [(30,270,1210,380),(1260,270,630,380),(30,670,920,390),(970,670,920,390)]:
    img=panel(img,*r)
save(img,'fundo-visao-geral.png')

# Página 2: Performance (3 cards)
img=header(base(),'Performance do banco')
cw=(1860-2*20)/3
for i,ic in enumerate([ic_trend,ic_text('IA',26),ic_bolt]):
    img=grad_card(img,30+i*(cw+20),110,cw,140,GR[i][0],GR[i][1],ic)
for r in [(30,270,1100,790),(1150,270,740,790)]:
    img=panel(img,*r)
save(img,'fundo-performance.png')

# Página 3: Estoque e inventário
img=header(base(),'Estoque e inventário')
img=six_cards(img,[ic_box,ic_alert,ic_text('%',34),ic_check,ic_truck,ic_clock])
for r in [(30,270,1210,380),(1260,270,630,380),(30,670,920,390),(970,670,920,390)]:
    img=panel(img,*r)
save(img,'fundo-estoque.png')
print('ok')
