#!/usr/bin/env python3
"""Real dual-stack DNS forwarding and Windows dynamic WFP lifetime checks."""
import argparse, concurrent.futures, json, runpy, socket, struct, threading, time
from pathlib import Path
Core=runpy.run_path(str(Path(__file__).with_name('qa-core-heartbeat.py')))['Core']

def read(stream,count):
    data=b''
    while len(data)<count:
        chunk=stream.recv(count-len(data))
        if not chunk: raise AssertionError('Unexpected DNS EOF')
        data+=chunk
    return data

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--library',required=True);parser.add_argument('--firewall',action='store_true');args=parser.parse_args()
    listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();upstream=listener.getsockname()[1]
    udp=socket.socket(type=socket.SOCK_DGRAM);udp.bind(('127.0.0.1',upstream))
    def answer(query): return query[:2]+b'\x81\x83'+query[4:]
    def serve_udp():
        while True:
            try:
                q,peer=udp.recvfrom(65535)
                if b'abandoned' in q:time.sleep(.1)
                udp.sendto(answer(q),peer)
            except OSError:return
    def stream(client):
        with client:
            try:
                while True:
                    size=struct.unpack('!H',read(client,2))[0];q=read(client,size);client.sendall(struct.pack('!H',size)+answer(q))
            except (OSError,AssertionError):pass
    def serve_tcp():
        while True:
            try:client,_=listener.accept();threading.Thread(target=stream,args=(client,),daemon=True).start()
            except OSError:return
    threading.Thread(target=serve_udp,daemon=True).start();threading.Thread(target=serve_tcp,daemon=True).start()
    core=Core(args.library);cases=[]
    try:
        port=core.call(op='dnsStart',listenPort=0,upstreamPort=upstream)
        for host in ['127.0.0.1','::1']:
            for tcp in [False,True]:core.call(op='dnsProbe',port=port,host=host,tcp=tcp,timeout=2)
        cases.append('IPv4/IPv6 UDP/TCP loopback forwarding')
        def exchange(index):
            q=bytes(core.call(op='dnsQuery',name=f'client-{index}.example.com',id=42,type=1))
            with socket.socket(type=socket.SOCK_DGRAM) as client:
                client.settimeout(3);client.sendto(q,('127.0.0.1',port));response=client.recv(65535)
                assert core.call(op='dnsValid',query=list(q),response=list(response))
        with concurrent.futures.ThreadPoolExecutor(max_workers=32) as executor:list(executor.map(exchange,range(64)))
        cases.append('64 concurrent clients with identical transaction IDs remain isolated')
        for index in range(4):
            with socket.socket(type=socket.SOCK_DGRAM) as abandoned:
                q=bytes(core.call(op='dnsQuery',name='abandoned.example.com',id=index,type=1))
                abandoned.sendto(q,('127.0.0.1',port))
        time.sleep(.7)
        for host in ['127.0.0.1','::1']:
            for tcp in [False,True]:core.call(op='dnsProbe',port=port,host=host,tcp=tcp,timeout=2)
        cases.append('closed UDP clients cannot terminate the DNS listeners')
        with socket.create_connection(('127.0.0.1',port),3) as client:
            queries=[bytes(core.call(op='dnsQuery',name='pipeline.example.com',id=n,type=1)) for n in range(4)]
            client.sendall(b''.join(struct.pack('!H',len(q))+q for q in queries));client.shutdown(socket.SHUT_WR)
            for q in queries:response=read(client,struct.unpack('!H',read(client,2))[0]);assert response==answer(q)
        cases.append('pipelining and write half-close retain complete replies')
        core.call(op='dnsStop');assert core.call(op='dnsStart',listenPort=port,upstreamPort=upstream)==port
        core.call(op='dnsStop');cases.append('stop synchronously releases all four listeners')
        if args.firewall:
            core.call(op='dnsProbe',host='1.1.1.1',port=53,timeout=2)
            core.call(op='dnsStart',listenPort=53,upstreamPort=upstream)
            core.call(op='firewallStart')
            try:
                for host in ['127.0.0.1','::1']:
                    for tcp in [False,True]:core.call(op='dnsProbe',port=53,host=host,tcp=tcp,timeout=2)
                cases.append('WFP preserves IPv4/IPv6 TCP/UDP loopback DNS on port 53')
                for tcp in [False,True]:
                    try:core.call(op='dnsProbe',host='1.1.1.1',port=53,tcp=tcp,timeout=1)
                    except RuntimeError:pass
                    else:raise AssertionError('External plaintext DNS bypassed WFP')
                cases.append('WFP blocks new IPv4 TCP/UDP external DNS')
            finally:core.call(op='firewallStop')
            core.call(op='dnsProbe',host='1.1.1.1',port=53,timeout=2)
            cases.append('removing dynamic WFP session restores external DNS')
        print(json.dumps({'passed':len(cases),'cases':cases},indent=2))
    finally:core.close();listener.close();udp.close()
if __name__=='__main__':main()
