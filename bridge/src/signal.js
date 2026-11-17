// Signal via signal-cli-rest-api (json-rpc mode), which runs as a linked device next to this bridge.
import * as store from './store.js'

const API = (process.env.SIGNAL_API || 'http://signal:8080').replace(/\/$/, '')
const groups = new Map() // signal-cli internal group id -> { id: 'group.…', name }

let account = null
let state = { state: 'connecting', number: null }

export const status = () => state
function setState(patch) {
  state = { ...state, ...patch }
  store.bus.emit('status')
}

const sleep = ms => new Promise(r => setTimeout(r, ms))
const enc = encodeURIComponent
async function getJSON(p) {
  const res = await fetch(API + p)
  if (!res.ok) throw new Error(`${p}: HTTP ${res.status}`)
  return res.json()
}

// Waits until signal-cli has a linked account, then listens for messages.
export async function start() {
  while (!account) {
    try {
      const accounts = await getJSON('/v1/accounts')
      if (accounts.length) account = accounts[0]
      else setState({ state: 'unlinked', number: null })
    } catch {
      setState({ state: 'connecting', number: null })
    }
    if (!account) await sleep(5000)
  }
  setState({ state: 'linked', number: account })
  await refreshNames().catch(e => console.warn('signal names:', e.message))
  listen()
}

function listen() {
  const ws = new WebSocket(`${API.replace(/^http/, 'ws')}/v1/receive/${enc(account)}`)
  ws.onmessage = e => handle(JSON.parse(e.data)).catch(err => console.warn('signal message:', err.message))
  ws.onclose = () => setTimeout(listen, 3000)
}

async function refreshNames() {
  const [gs, cs] = await Promise.all([getJSON(`/v1/groups/${enc(account)}`), getJSON(`/v1/contacts/${enc(account)}`)])
  for (const g of gs || []) {
    groups.set(g.internal_id, { id: g.id, name: g.name })
    store.renameChat('sg:' + g.id, g.name)
  }
  for (const c of cs || []) {
    const name = c.name || c.profile_name || c.profile?.given_name
    if (c.number) store.renameChat('sg:' + c.number, name)
    if (c.uuid) store.renameChat('sg:' + c.uuid, name)
  }
}

async function handle(data) {
  const env = (data.params ?? data).envelope
  const sent = env?.syncMessage?.sentMessage // something I sent from my phone
  const dm = sent || env?.dataMessage
  if (!dm) return

  const sender = env.sourceNumber || env.sourceUuid || env.source
  const groupId = dm.groupInfo?.groupId
  let address = sent ? sent.destinationNumber || sent.destinationUuid || sent.destination : sender
  if (groupId) {
    if (!groups.has(groupId)) await refreshNames().catch(() => {})
    address = groups.get(groupId)?.id
  }
  if (!address) return
  const id = 'sg:' + address

  // A reaction points at its message by the message's sent time.
  if (dm.reaction) {
    const target = store.messageAt(id, dm.reaction.targetSentTimestamp)
    if (target) store.react(target.id, sent ? store.ME : sender, dm.reaction.isRemove ? '' : dm.reaction.emoji)
    return
  }

  const image = (dm.attachments || []).find(a => a.contentType?.startsWith('image/'))
  const text = dm.message || (dm.attachments?.length && !image ? '📎 Attachment' : '')
  if (!text && !image) return // receipts, typing…

  store.ensureChat(id, 'signal', {
    isGroup: !!groupId, name: groupId ? groups.get(groupId).name : sent ? null : env.sourceName,
  })
  const message = {
    id: `${id}/${dm.timestamp}/${sender}`, chatId: id, fromMe: !!sent,
    sender: sent ? '' : env.sourceName || sender, senderId: sent ? '' : 'sg:' + sender, text, ts: dm.timestamp || env.timestamp || Date.now(), media: null,
  }
  if (image) {
    // signal-cli may still be writing the file when the message arrives, so try a few times.
    for (let attempt = 0; attempt < 5 && !message.media; attempt++) {
      if (attempt) await sleep(1000)
      try {
        const res = await fetch(`${API}/v1/attachments/${enc(image.id)}`)
        if (res.ok) {
          store.saveMedia(message.id, Buffer.from(await res.arrayBuffer()))
          message.media = image.contentType
        }
      } catch (e) {
        console.warn('signal attachment:', e.message)
      }
    }
    if (!message.media && !message.text) message.text = '📷 Photo'
  }
  store.addMessage(message)
}

function requireLinked() {
  if (!account) throw store.httpError(503, 'Signal is not linked yet')
}

export async function send(chat, { text, image, poll }) {
  requireLinked()
  if (poll) throw store.httpError(501, 'Polls are only supported for WhatsApp')
  const body = { number: account, recipients: [chat.id.slice(3)], message: text || '' }
  if (image) body.base64_attachments = [`data:image/jpeg;filename=photo.jpg;base64,${image.toString('base64')}`]
  const res = await fetch(`${API}/v2/send`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
  })
  const out = await res.json().catch(() => ({}))
  if (!res.ok) throw store.httpError(502, out.error || `Signal send failed (HTTP ${res.status})`)

  const ts = Number(out.timestamp) || Date.now()
  const message = { id: `${chat.id}/${ts}/${account}`, chatId: chat.id, fromMe: true, sender: '', text: text || '', ts, media: null }
  if (image) {
    store.saveMedia(message.id, image)
    message.media = 'image/jpeg'
  }
  return store.addMessage(message) ?? store.getMessage(message.id)
}

// Message ids end in "/<sent time>/<author>", which is how Signal names the message to react to.
export async function react(chat, message, emoji) {
  requireLinked()
  const [ts, author] = message.id.split('/').slice(-2)
  const res = await fetch(`${API}/v1/reactions/${enc(account)}`, {
    method: emoji ? 'POST' : 'DELETE', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ recipient: chat.id.slice(3), reaction: emoji || mine(message), target_author: author, timestamp: Number(ts) }),
  })
  if (!res.ok) throw store.httpError(502, (await res.json().catch(() => ({}))).error || `Signal reaction failed (HTTP ${res.status})`)
  return store.react(message.id, store.ME, emoji)
}
const mine = message => message.reactions.find(r => r.fromMe)?.emoji || ''

export async function vote() {
  throw store.httpError(501, 'Polls are only supported for WhatsApp')
}

export async function fetchMedia() {
  return false
}

export async function startChat(phone) {
  requireLinked()
  const digits = String(phone || '').replace(/\D/g, '')
  if (!digits) throw store.httpError(400, 'Enter a phone number with country code')
  store.ensureChat('sg:+' + digits, 'signal')
  return store.getChat('sg:+' + digits)
}

// PNG QR code to scan in Signal → Settings → Linked devices. start() notices the new account by itself.
export async function qr() {
  if (account) throw store.httpError(409, 'Signal is already linked')
  const res = await fetch(`${API}/v1/qrcodelink?device_name=Convo`).catch(() => {
    throw store.httpError(502, 'signal-cli is not reachable')
  })
  if (!res.ok) throw store.httpError(502, `signal-cli could not create a link code (HTTP ${res.status})`)
  return { type: res.headers.get('content-type') || 'image/png', body: Buffer.from(await res.arrayBuffer()) }
}

export async function avatar() {
  return null
}
