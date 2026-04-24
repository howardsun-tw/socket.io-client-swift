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
let blockNewConnectionsUntil = 0;
let blockNewConnectionsPending = false;
let blockResetTimer = null;

const resetBlockedConnections = () => {
  if (blockResetTimer) {
    clearTimeout(blockResetTimer);
    blockResetTimer = null;
  }
  blockNewConnectionsPending = false;
  blockNewConnectionsUntil = 0;
};

const armBlockedConnectionsUntil = (durationMs) => {
  if (blockResetTimer) {
    clearTimeout(blockResetTimer);
    blockResetTimer = null;
  }

  blockNewConnectionsPending = false;
  blockNewConnectionsUntil = durationMs === 0 ? 0 : Date.now() + durationMs;
  if (durationMs > 0) {
    blockResetTimer = setTimeout(() => {
      blockResetTimer = null;
      blockNewConnectionsUntil = 0;
    }, durationMs);
  }
};

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
    if (url.pathname === "/admin/kill-transport-and-block-new-connections") {
      const sid = url.searchParams.get("sid");
      const durationMs = Number(url.searchParams.get("durationMs") ?? "0");
      const s = sid ? io.sockets.sockets.get(sid) : null;
      if (!s) { res.writeHead(404).end("no sid"); return; }
      if (!Number.isFinite(durationMs) || durationMs < 0) {
        res.writeHead(400).end("bad durationMs");
        return;
      }

      resetBlockedConnections();
      blockNewConnectionsPending = true;

      let settled = false;
      let timeout = null;
      const finish = (status, body) => {
        if (settled) return;
        settled = true;
        if (timeout) clearTimeout(timeout);
        res.writeHead(status, { "Content-Type": "application/json" }).end(JSON.stringify(body));
      };
      const cleanupAndFail = (message) => {
        s.off("disconnect", onDisconnect);
        resetBlockedConnections();
        finish(500, { error: message });
      };
      const onDisconnect = () => {
        armBlockedConnectionsUntil(durationMs);
        finish(200, { blockNewConnectionsUntil });
      };

      s.once("disconnect", onDisconnect);
      timeout = setTimeout(() => {
        cleanupAndFail("disconnect timeout");
      }, 4_000);

      try {
        s.conn.close();
      } catch (error) {
        cleanupAndFail(String(error));
      }
      return;
    }
    if (url.pathname === "/admin/kill-transport-and-emit-on-disconnect") {
      const sid = url.searchParams.get("sid");
      const event = url.searchParams.get("event");
      const s = sid ? io.sockets.sockets.get(sid) : null;
      if (!s || !event) { res.writeHead(404).end("no sid"); return; }

      const body = await readJson(req);
      const argsList = Array.isArray(body?.argsList)
        ? body.argsList.filter((args) => Array.isArray(args))
        : [];
      if (argsList.length === 0) { res.writeHead(400).end("no argsList"); return; }

      let settled = false;
      let timeout = null;
      const finish = (status, message) => {
        if (settled) return;
        settled = true;
        if (timeout) clearTimeout(timeout);
        res.writeHead(status).end(message);
      };

      s.once("disconnect", () => {
        for (const args of argsList) {
          io.emit(event, ...args);
        }
        finish(200, "ok");
      });

      timeout = setTimeout(() => {
        finish(500, "disconnect timeout");
      }, 4_000);

      s.conn.close();
      return;
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
    if (url.pathname === "/admin/emit-raw") {
      const sid = url.searchParams.get("sid");
      const event = url.searchParams.get("event") ?? "msg";
      const s = sid ? io.sockets.sockets.get(sid) : null;
      if (!s) { res.writeHead(404).end("no sid"); return; }

      const body = await readJson(req);
      const args = Array.isArray(body?.args) ? body.args : [];
      s.packet({ type: 2, data: [event, ...args] });
      res.writeHead(200).end("ok"); return;
    }
    if (url.pathname === "/admin/socket-live") {
      const sid = url.searchParams.get("sid");
      const live = sid ? io.sockets.sockets.has(sid) : false;
      res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ live }));
      return;
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
  allowRequest: (_req, callback) => {
    callback(null, !blockNewConnectionsPending && Date.now() >= blockNewConnectionsUntil);
  },
  connectionStateRecovery: {
    maxDisconnectionDuration: recoveryWindowMs,
    skipMiddlewares: true,
  },
});

io.on("connection", (socket) => {
  lastAuthBySid.set(socket.id, socket.handshake.auth);
  socket.on("disconnect", () => {});
});

io.of("/admin").on("connection", (socket) => {
  socket.on("disconnect", () => {});
});

httpServer.listen(0, "127.0.0.1", () => {
  const port = httpServer.address().port;
  console.log(`READY port=${port} secret=${SECRET}`);
});
