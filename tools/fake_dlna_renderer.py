"""假的 DLNA MediaRenderer，用于验证投屏链路。

- GET /description.xml  返回标准 UPnP 设备描述（含 AVTransport 服务块）
- POST /AVTransport/control 记录 SOAP 请求（SetAVTransportURI / Play ...）
- POST /media/check 让被测端把待投 URL 报过来，验证内置 HTTP 服务可达

只用于本地联调，不属于 App 代码。
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'soap.log')

DESC = """<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Fake DLNA TV</friendlyName>
    <manufacturer>PerchPlay Test</manufacturer>
    <modelName>FakeRenderer</modelName>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/AVTransport/control</controlURL>
        <eventSubURL>/AVTransport/event</eventSubURL>
        <SCPDURL>/AVTransport/scpd.xml</SCPDURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <controlURL>/RenderingControl/control</controlURL>
      </service>
    </serviceList>
  </device>
</root>
"""

RESP = """<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
 s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
 <s:Body><u:%sResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"/>
 </s:Body></s:Envelope>"""


def log(msg):
    with open(LOG, 'a', encoding='utf-8') as f:
        f.write(msg + '\n')
    print(msg, flush=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def _send(self, code, body: bytes, ctype='text/xml; charset="utf-8"'):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if 'description' in self.path or self.path == '/':
            log('GET %s -> description' % self.path)
            self._send(200, DESC.encode('utf-8'))
        else:
            log('GET %s -> 404' % self.path)
            self._send(404, b'not found')

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length).decode('utf-8', 'replace')
        action = ''
        if '<u:' in body:
            action = body.split('<u:')[1].split('>')[0].split()[0]
        soapaction = self.headers.get('SOAPACTION', '')
        log('POST %s action=%s soapaction=%s' % (self.path, action, soapaction))
        # 完整记录 body，便于核对 CurrentURI 等参数
        log('   BODY: ' + ' '.join(body.split())[:600])
        self._send(200, (RESP % (action or 'Ok')).encode('utf-8'))

    def log_message(self, *args):
        pass


if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
    open(LOG, 'w', encoding='utf-8').close()
    log('fake DLNA renderer listening on 0.0.0.0:%d' % port)
    ThreadingHTTPServer(('0.0.0.0', port), Handler).serve_forever()
