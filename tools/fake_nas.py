"""假的 NAS（群晖风格 Web UI + WebDAV），用于验证局域网自动发现。

- :5000  普通 HTTP，标题/Server 头伪装成群晖 DSM
- :5005  WebDAV（PROPFIND 返回 207 + DAV 头）

只用于本地联调，不属于 App 代码。
"""
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading

DSM_PAGE = """<!DOCTYPE html><html><head><title>Synology DiskStation</title></head>
<body><h1>Synology DiskStation</h1><p>DSM 7.2</p></body></html>
"""

DAV_XML = """<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/</D:href>
    <D:propstat>
      <D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>
"""


class DsmHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    # Python 默认会自带一个 Server 头，再额外加一个会变成重复头，
    # 客户端读到重复头会直接抛异常。这里直接改默认值。
    def version_string(self):
        return 'nginx'

    def _send(self, code, body: bytes, extra=None):
        self.send_response(code)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        print('DSM GET %s from %s' % (self.path, self.client_address[0]), flush=True)
        self._send(200, DSM_PAGE.encode('utf-8'))

    def do_PROPFIND(self):
        print('DSM PROPFIND %s from %s' % (self.path, self.client_address[0]),
              flush=True)
        self.send_response(207)
        self.send_header('Content-Type', 'application/xml; charset=utf-8')
        self.send_header('DAV', '1,2')
        self.send_header('Content-Length', str(len(DAV_XML)))
        self.end_headers()
        self.wfile.write(DAV_XML.encode('utf-8'))

    def log_message(self, *args):
        pass


class DavHandler(DsmHandler):
    pass


def serve(port, handler):
    srv = ThreadingHTTPServer(('0.0.0.0', port), handler)
    print('fake NAS listening on %d' % port, flush=True)
    srv.serve_forever()


if __name__ == '__main__':
    threading.Thread(target=serve, args=(5000, DsmHandler), daemon=True).start()
    serve(5005, DavHandler)
