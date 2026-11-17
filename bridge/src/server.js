// Convo bridge: one small authenticated REST + WebSocket API over WhatsApp and Signal.
import http from 'node:http'
import fs from 'node:fs'
import crypto from 'node:crypto'
import { WebSocketServer } from 'ws'
import * as store from './store.js'
import * as whatsapp from './whatsapp.js'
import * as signal from './signal.js'

const PORT = Number(process.env.PORT || 8080)
const TOKEN = process.env.BRIDGE_TOKEN || ''
if (TOKEN.length < 16) {
  console.error('Set BRIDGE_TOKEN to a random string of at least 16 characters (e.g. `openssl rand -hex 24`).')
  process.exit(1)
}

const networks = { whatsapp, signal }
const status = () => ({ whatsapp: whatsapp.status(), signal: signal.status() })

function authorized(req) {
  const given = Buffer.from(req.headers.authorization || '')
  const wanted = Buffer.from(`Bearer ${TOKEN}`)
  return given.length === wanted.length && crypto.timingSafeEqual(given, wanted)
}

function json(res, code, data) {
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8' })
  res.end(JSON.stringify(data))
}
function file(res, path, type) {
  res.writeHead(200, { 'content-type': type, 'cache-control': 'private, max-age=86400' })
  fs.createReadStream(path).pipe(res)
}
async function readBody(req, limit = 30 * 1024 * 1024) {
  let size = 0
  const chunks = []
  for await (const chunk of req) {
    if ((size += chunk.length) > limit) throw store.httpError(413, 'Request too large')
    chunks.push(chunk)
  }
  return chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : {}
}

async function route(req, res) {
  const url = new URL(req.url, 'http://bridge')
  const [api, a, b, c] = url.pathname.split('/').filter(Boolean).map(decodeURIComponent)
  const is = (method, ...path) => req.method === method && path.every((p, i) => p === [a, b, c][i])
  if (api !== 'api') return json(res, 404, { error: 'Not found' })

  if (is('GET', 'status')) return json(res, 200, status())
  if (is('POST', 'whatsapp', 'pair')) return json(res, 200, { code: await whatsapp.pair((await readBody(req)).phone) })
  if (is('POST', 'whatsapp', 'logout')) return json(res, 200, { ok: await whatsapp.logout() ?? true })
  if (is('GET', 'signal', 'qr')) {
    const png = await signal.qr()
    res.writeHead(200, { 'content-type': png.type, 'cache-control': 'no-store' })
    return res.end(png.body)
  }
  if (is('GET', 'media') && b) {
    const msg = store.getMessage(b)
    if (msg?.media && !fs.existsSync(store.mediaPath(b))) {
      await networks[store.getChat(msg.chatId).network].fetchMedia(msg).catch(e => console.warn('media download:', e.message))
    }
    return msg?.media && fs.existsSync(store.mediaPath(b)) ? file(res, store.mediaPath(b), msg.media) : json(res, 404, { error: 'No media' })
  }
  // A group member's picture, by the senderId on their messages.
  if (is('GET', 'people', b, 'avatar')) {
    const path = await networks[b.startsWith('wa:') ? 'whatsapp' : 'signal'].avatar({ id: b })
    return path ? file(res, path, 'image/jpeg') : json(res, 404, { error: 'No avatar' })
  }
  if (a === 'messages' && b && req.method === 'POST') {
    const msg = store.getMessage(b)
    if (!msg) return json(res, 404, { error: 'Not found' })
    const chat = store.getChat(msg.chatId)
    const body = await readBody(req)
    if (is('POST', 'messages', b, 'react')) return json(res, 200, await networks[chat.network].react(chat, msg, body.emoji || ''))
    if (is('POST', 'messages', b, 'vote')) {
      if (!msg.poll) throw store.httpError(400, 'That message is not a poll')
      return json(res, 200, await networks[chat.network].vote(chat, msg, Array.isArray(body.options) ? body.options : []))
    }
  }
  if (is('GET', 'chats') && !b) return json(res, 200, store.listChats())
  if (is('POST', 'chats') && !b) {
    const { network, phone } = await readBody(req)
    if (!networks[network]) throw store.httpError(400, 'network must be "whatsapp" or "signal"')
    return json(res, 200, await networks[network].startChat(phone))
  }

  const chat = a === 'chats' && b ? store.getChat(b) : null
  if (!chat) return json(res, 404, { error: 'Not found' })
  if (is('GET', 'chats', b, 'messages')) {
    const before = Number(url.searchParams.get('before')) || undefined
    return json(res, 200, store.listMessages(chat.id, before))
  }
  if (is('POST', 'chats', b, 'messages')) {
    const { text = '', image, poll } = await readBody(req)
    if (poll) {
      const options = (poll.options || []).map(o => String(o).trim()).filter(Boolean)
      if (!String(poll.question || '').trim() || options.length < 2) throw store.httpError(400, 'A poll needs a question and at least two options')
      if (new Set(options).size !== options.length) throw store.httpError(400, 'Poll options must be different')
      const message = await networks[chat.network].send(chat, { poll: { question: poll.question.trim(), options, multi: !!poll.multi } })
      return json(res, 200, message)
    }
    if (!text.trim() && !image) throw store.httpError(400, 'Send text or an image')
    const message = await networks[chat.network].send(chat, { text: text.trim(), image: image && Buffer.from(image, 'base64') })
    return json(res, 200, message)
  }
  if (is('POST', 'chats', b, 'read')) return json(res, 200, store.markRead(chat.id))
  if (is('GET', 'chats', b, 'avatar')) {
    const path = await networks[chat.network].avatar(chat)
    return path ? file(res, path, 'image/jpeg') : json(res, 404, { error: 'No avatar' })
  }
  json(res, 404, { error: 'Not found' })
}

const server = http.createServer(async (req, res) => {
  if (req.url === '/health') return json(res, 200, { ok: true })
  if (!authorized(req)) return json(res, 401, { error: 'Wrong or missing token' })
  try {
    await route(req, res)
  } catch (e) {
    if (!e.status) console.error(e)
    if (!res.headersSent) json(res, e.status || 500, { error: e.message || 'Something went wrong' })
  }
})

// Live events for the app: message, update (reactions, votes), chat, status, reload.
const wss = new WebSocketServer({ noServer: true })
server.on('upgrade', (req, socket, head) => {
  if (new URL(req.url, 'http://bridge').pathname !== '/api/events' || !authorized(req)) return socket.destroy()
  wss.handleUpgrade(req, socket, head, ws => {
    ws.isAlive = true
    ws.on('pong', () => { ws.isAlive = true })
    ws.send(JSON.stringify({ type: 'status', status: status() }))
  })
})
const broadcast = event => {
  const data = JSON.stringify(event)
  for (const ws of wss.clients) if (ws.readyState === 1) ws.send(data)
}
store.bus.on('message', ({ chat, message }) => broadcast({ type: 'message', chat, message }))
store.bus.on('update', ({ chat, message }) => broadcast({ type: 'update', chat, message }))
store.bus.on('chat', chat => broadcast({ type: 'chat', chat }))
store.bus.on('status', () => broadcast({ type: 'status', status: status() }))
store.bus.on('reload', () => broadcast({ type: 'reload' }))
setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.isAlive) ws.terminate()
    else { ws.isAlive = false; ws.ping() }
  }
}, 30000)

server.listen(PORT, () => console.log(`Convo bridge listening on :${PORT}`))
whatsapp.start().catch(e => console.error('WhatsApp failed to start:', e))
signal.start().catch(e => console.error('Signal failed to start:', e))
