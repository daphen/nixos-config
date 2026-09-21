import socket, struct, time

class Pointer:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(str(path)); self.sock.settimeout(3)
        self.pending = b''; self.callback = 2; self.globals = {}
        self.send(1, 1, struct.pack('I', 2))
        self.sync()
        name, version = self.globals['zwlr_virtual_pointer_manager_v1']
        iface = b'zwlr_virtual_pointer_manager_v1\0'
        string = struct.pack('I',len(iface))+iface+b'\0'*((-len(iface))%4)
        self.send(2, 0, struct.pack('I',name)+string+struct.pack('II',min(version,2),4))
        self.send(4, 0, struct.pack('II',0,5)); self.callback = 5; self.sync()
    def send(self, obj, opcode, data=b''):
        self.sock.sendall(struct.pack('II',obj,((len(data)+8)<<16)|opcode)+data)
    def sync(self):
        self.callback += 1
        self.send(1,0,struct.pack('I',self.callback))
        while True:
            while len(self.pending)<8: self.pending += self.sock.recv(65536)
            obj, header = struct.unpack('II', self.pending[:8]); size, op = header>>16, header&65535
            while len(self.pending)<size: self.pending += self.sock.recv(65536)
            data, self.pending = self.pending[8:size], self.pending[size:]
            if obj==1 and op==0: raise RuntimeError(repr(data))
            if obj==2 and op==0:
                name,n=struct.unpack('II',data[:8]); iface=data[8:8+n-1].decode()
                version=struct.unpack_from('I',data,8+(n+3)//4*4)[0];self.globals[iface]=(name,version)
            if obj==self.callback and op==0:return
    def move(self,x=640,y=360):
        self.send(5,1,struct.pack('IIIII',self.now(),x,y,1280,720));self.send(5,4);self.sync()
    def axis(self,axis,value,source):
        self.send(5,3,struct.pack('IIi',self.now(),axis,round(value*256)))
        self.send(5,5,struct.pack('I',source))
        self.send(5,4);self.sync()
        if source==1:
            self.send(5,6,struct.pack('II',self.now(),axis));self.send(5,5,struct.pack('I',source));self.send(5,4);self.sync()
    def now(self):return int(time.monotonic()*1000)&0xffffffff
    def close(self):self.sock.close()
