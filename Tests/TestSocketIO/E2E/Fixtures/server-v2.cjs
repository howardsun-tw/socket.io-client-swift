const crypto = require("crypto");
const http = require("http");

const SECRET = crypto.randomBytes(32).toString("hex");

const httpServer = http.createServer((req, res) => {
  const url = new URL(req.url || "/", `http://${req.headers.host || "127.0.0.1"}`);
  if (!url.pathname.startsWith("/admin/")) {
    res.writeHead(404).end();
    return;
  }
  if (req.headers["x-admin-secret"] !== SECRET) {
    res.writeHead(401).end("unauthorized");
    return;
  }
  const host = req.headers.host || "";
  if (!/^127\.0\.0\.1:\d+$|^localhost:\d+$/.test(host)) {
    res.writeHead(403).end("bad host");
    return;
  }

  if (url.pathname === "/admin/ping") {
    res.writeHead(200).end("pong");
    return;
  }
  if (url.pathname === "/admin/shutdown") {
    res.writeHead(200).end("bye");
    setTimeout(() => process.exit(0), 10);
    return;
  }

  res.writeHead(404).end("no route");
});

const io = require("socket.io-v2")(httpServer);

io.on("connection", () => {});

httpServer.listen(0, "127.0.0.1", () => {
  const address = httpServer.address();
  const port = address && typeof address === "object" ? address.port : 0;
  console.log(`READY port=${port} secret=${SECRET}`);
});
