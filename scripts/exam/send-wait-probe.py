import json,socket,sys,time,os
d=sys.argv[1]; wait=sys.argv[2]=="1"; to=int(sys.argv[3])
token=open(d+"/token").read().strip(); path=open(d+"/socket").read().strip()
s=socket.socket(socket.AF_UNIX); s.settimeout(120); s.connect(path)
t=time.time()
s.sendall((json.dumps({"cmd":"send","conv":"","target":"x","text":"hi","wait":wait,"timeout":to,"token":token})+"\n").encode())
b=b""
while True:
    c=s.recv(65536)
    if not c: break
    b+=c
print("%.0f 秒" % (time.time()-t), b.decode().strip())
