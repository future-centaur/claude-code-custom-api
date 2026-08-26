// Loopback-only forwarding proxy for OpenRouter.
// Claude Code sometimes attaches a stale Claude subscription credential to the
// x-api-key header even when ANTHROPIC_AUTH_TOKEN is set, which OpenRouter's
// gateway misroutes. This strips that one header and forwards everything else
// unchanged. No request/response content is logged anywhere.
const http = require('http');
const https = require('https');

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    const outHeaders = { ...req.headers };
    delete outHeaders.host;
    delete outHeaders['x-api-key'];
    outHeaders.host = 'openrouter.ai';

    const proxyReq = https.request(
      { hostname: 'openrouter.ai', path: '/api' + req.url, method: req.method, headers: outHeaders },
      (proxyRes) => {
        res.writeHead(proxyRes.statusCode, proxyRes.headers);
        proxyRes.pipe(res);
      }
    );
    proxyReq.on('error', () => {
      res.writeHead(502);
      res.end();
    });
    proxyReq.end(body);
  });
});

server.listen(0, '127.0.0.1', () => {
  console.log('PORT:' + server.address().port);
});
