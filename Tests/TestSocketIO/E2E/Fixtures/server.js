import { Server } from "socket.io";
import http from "node:http";
import crypto from "node:crypto";

const SECRET = crypto.randomBytes(32).toString("hex");

const recoveryWindowMsEnv = Number(process.env.RECOVERY_WINDOW_MS);
const recoveryWindowMs = Number.isFinite(recoveryWindowMsEnv) && recoveryWindowMsEnv > 0
  ? recoveryWindowMsEnv
  : 60_000;

const readJson = (req) => new Promise((resolve, reject) => {
  let buf = "";
  req.on("data", (c) => { buf += c; if (buf.length > 1_000_000) reject(new Error("body too large")); });
  req.on("end", () => { try { resolve(buf ? JSON.parse(buf) : {}); } catch (e) { reject(e); } });
  req.on("error", reject);
});

const lastAuthBySid = new Map();

const httpServer = http.createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "127.0.0.1"}`);
  if (!url.pathname.startsWith("/admin/")) { res.writeHead(404).end(); return; }
  if (req.headers["x-admin-secret"] !== SECRET) { res.writeHead(401).end("unauthorized"); return; }
  const host = req.headers.host ?? "";
  if (!/^127\.0\.0\.1:\d+$|^localhost:\d+$/.test(host)) { res.writeHead(403).end("bad host"); return; }

  try {
    if (url.pathname === "/admin/ping") { res.writeHead(200).end("pong"); return; }
    if (url.pathname === "/admin/shutdown") { res.writeHead(200).end("bye"); setTimeout(() => process.exit(0), 10); return; }
    if (url.pathname === "/admin/kill-transport") {
      const sid = url.searchParams.get("sid");
      const s = sid ? io.sockets.sockets.get(sid) : null;
      if (!s) { res.writeHead(404).end("no sid"); return; }
      s.conn.close();
      res.writeHead(200).end("killed"); return;
    }
    if (url.pathname === "/admin/emit") {
      const event = url.searchParams.get("event") ?? "msg";
      const body = await readJson(req);
      const args = Array.isArray(body?.args) ? body.args : [];
      const binary = url.searchParams.get("binary") === "true";
      const payload = binary ? args.map((a) => typeof a === "string" && a.startsWith("b64:") ? Buffer.from(a.slice(4), "base64") : a) : args;
      io.emit(event, ...payload);
      res.writeHead(200).end("ok"); return;
    }
    if (url.pathname === "/admin/last-auth") {
      const sid = url.searchParams.get("sid");
      const entry = sid ? lastAuthBySid.get(sid) : null;
      res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ auth: entry ?? null }));
      return;
    }
    res.writeHead(404).end("no route");
  } catch (e) {
    res.writeHead(500).end(String(e));
  }
});

const io = new Server(httpServer, {
  connectionStateRecovery: {
    maxDisconnectionDuration: recoveryWindowMs,
    skipMiddlewares: true,
  },
});

io.on("connection", (socket) => {
  lastAuthBySid.set(socket.id, socket.handshake.auth);
  socket.on("disconnect", () => {});
});

httpServer.listen(0, "127.0.0.1", () => {
  const port = httpServer.address().port;
  console.log(`READY port=${port} secret=${SECRET}`);
});
