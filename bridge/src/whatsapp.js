// WhatsApp via Baileys: the bridge links as a companion device ("Linked devices" in WhatsApp).
import fs from 'node:fs'
import path from 'node:path'
import pino from 'pino'
import makeWASocket, {
  Browsers, DisconnectReason, downloadMediaMessage, normalizeMessageContent, useMultiFileAuthState,
} from 'baileys'
import * as store from './store.js'

const AUTH_DIR = path.join(store.DATA, 'whatsapp-auth')
const logger = pino({ level: process.env.LOG_LEVEL || 'warn' })
const noAvatar = new Map() // chat id -> time we last found none

let sock = null
let state = { state: 'connecting', qr: null, me: null }

export const status = () => state
function setState(patch) {
  state = { ...state, ...patch }
  store.bus.emit('status')
}

const chatId = jid => 'wa:' + jid
const jidOf = chat => chat.id.slice(3)
const toNumber = t => (typeof t === 'number' ? t : t?.toNumber ? t.toNumber() : Number(t))

export async function start() {
  const { state: auth, saveCreds } = await useMultiFileAuthState(AUTH_DIR)
  const s = sock = makeWASocket({
    auth, logger, browser: Browsers.macOS('Desktop'), markOnlineOnConnect: false, syncFullHistory: false,
  })

  s.ev.on('creds.update', saveCreds)
  s.ev.on('connection.update', ({ connection, lastDisconnect, qr }) => {
    if (qr) setState({ state: 'qr', qr })
    if (connection === 'open') {
      setState({ state: 'linked', qr: null, me: '+' + s.user.id.split(/[:@]/)[0] })
      s.groupFetchAllParticipating()
        .then(groups => Object.values(groups).forEach(g => store.renameChat(chatId(g.id), g.subject)))
        .catch(e => logger.warn(e, 'group fetch failed'))
    }
    if (connection === 'close' && sock === s) {
      const loggedOut = lastDisconnect?.error?.output?.statusCode === DisconnectReason.loggedOut
      if (loggedOut) fs.rmSync(AUTH_DIR, { recursive: true, force: true })
      setState({ state: 'connecting', qr: null, ...(loggedOut && { me: null }) })
      setTimeout(() => start().catch(e => logger.error(e)), loggedOut ? 0 : 2000)
    }
  })

  s.ev.on('messages.upsert', ({ messages }) => {
    for (const m of messages) handle(m).catch(e => logger.warn(e, 'message failed'))
  })
  s.ev.on('messaging-history.set', async ({ contacts = [], messages = [] }) => {
    for (const m of messages) await handle(m, { live: false }).catch(() => {})
    contacts.forEach(nameContact)
    store.bus.emit('reload')
  })
  s.ev.on('contacts.upsert', cs => cs.forEach(nameContact))
  s.ev.on('contacts.update', cs => cs.forEach(nameContact))
  s.ev.on('groups.update', gs => gs.forEach(g => store.renameChat(chatId(g.id), g.subject)))
}

function nameContact(c) {
  store.renameChat(chatId(c.id), c.name || c.notify || c.verifiedName)
}

// What we show for each kind of WhatsApp message. Anything else (reactions, edits, receipts) is skipped.
function describe(c) {
  if (c.conversation) return { text: c.conversation }
  if (c.extendedTextMessage) return { text: c.extendedTextMessage.text || '' }
  if (c.imageMessage) return { text: c.imageMessage.caption || '', image: c.imageMessage.mimetype || 'image/jpeg' }
  if (c.videoMessage) return { text: c.videoMessage.caption || '🎥 Video' }
  if (c.audioMessage) return { text: '🎤 Voice message' }
  if (c.documentMessage) return { text: '📎 ' + (c.documentMessage.fileName || 'Document') }
  if (c.stickerMessage) return { text: '💟 Sticker' }
  if (c.locationMessage || c.liveLocationMessage) return { text: '📍 Location' }
  if (c.contactMessage) return { text: '👤 ' + (c.contactMessage.displayName || 'Contact') }
  const poll = c.pollCreationMessage || c.pollCreationMessageV2 || c.pollCreationMessageV3
  if (poll) return { text: '📊 ' + (poll.name || 'Poll') }
  return {}
}

// Stores one WhatsApp message and returns it (or the copy already stored).
async function handle(msg, { live = true, imageBuffer = null } = {}) {
  const key = msg.key
  let jid = key.remoteJid
  if (!jid || jid.endsWith('@broadcast') || jid.endsWith('@newsletter')) return null
  if (jid.endsWith('@lid') && key.remoteJidAlt?.endsWith('@s.whatsapp.net')) jid = key.remoteJidAlt

  const content = normalizeMessageContent(msg.message)
  if (!content) return null
  const { text, image } = describe(content)
  if (!text && !image) return null

  const id = chatId(jid)
  const isGroup = jid.endsWith('@g.us')
  const isNew = !store.getChat(id)
  store.ensureChat(id, 'whatsapp', { isGroup, name: isGroup || key.fromMe ? null : msg.pushName })
  if (isGroup && isNew) sock.groupMetadata(jid).then(g => store.renameChat(id, g.subject)).catch(() => {})

  const message = {
    id: `${id}/${key.id}`, chatId: id, fromMe: !!key.fromMe,
    sender: key.fromMe ? '' : msg.pushName || '', text,
    ts: toNumber(msg.messageTimestamp) * 1000 || Date.now(), media: null,
  }
  const existing = store.getMessage(message.id)
  if (existing) return existing

  if (image && (live || imageBuffer)) {
    try {
      const buffer = imageBuffer
        || await downloadMediaMessage(msg, 'buffer', {}, { logger, reuploadRequest: sock.updateMediaMessage })
      store.saveMedia(message.id, buffer)
      message.media = image
    } catch (e) {
      logger.warn(e, 'image download failed')
    }
  }
  if (image && !message.media && !message.text) message.text = '📷 Photo'
  return store.addMessage(message, { live }) ?? store.getMessage(message.id)
}

function requireLinked() {
  if (!sock || state.state !== 'linked') throw store.httpError(503, 'WhatsApp is not linked yet')
}

export async function send(chat, { text, image }) {
  requireLinked()
  const sent = await sock.sendMessage(jidOf(chat), image ? { image, caption: text || undefined } : { text })
  return handle(sent, { imageBuffer: image })
}

export async function startChat(phone) {
  requireLinked()
  const digits = String(phone || '').replace(/\D/g, '')
  if (!digits) throw store.httpError(400, 'Enter a phone number with country code')
  const [found] = await sock.onWhatsApp(digits + '@s.whatsapp.net')
  if (!found?.exists) throw store.httpError(404, 'That number is not on WhatsApp')
  store.ensureChat(chatId(found.jid), 'whatsapp')
  return store.getChat(chatId(found.jid))
}

// Link with a phone number instead of a QR code (WhatsApp → Linked devices → Link with phone number).
export async function pair(phone) {
  if (state.state !== 'qr') throw store.httpError(409, 'WhatsApp is not waiting to be linked')
  const digits = String(phone || '').replace(/\D/g, '')
  if (!digits) throw store.httpError(400, 'Enter your WhatsApp phone number with country code')
  return sock.requestPairingCode(digits)
}

export async function logout() {
  requireLinked()
  await sock.logout()
}

export async function avatar(chat) {
  const file = path.join(store.DATA, 'avatars', store.sha1(chat.id))
  const fresh = f => fs.existsSync(f) && Date.now() - fs.statSync(f).mtimeMs < 864e5
  if (fresh(file)) return file
  if (Date.now() - (noAvatar.get(chat.id) || 0) < 864e5 || state.state !== 'linked') return fs.existsSync(file) ? file : null
  try {
    const url = await sock.profilePictureUrl(jidOf(chat), 'preview')
    const res = url && await fetch(url)
    if (!res?.ok) throw new Error('no picture')
    fs.writeFileSync(file, Buffer.from(await res.arrayBuffer()))
    return file
  } catch {
    noAvatar.set(chat.id, Date.now())
    return fs.existsSync(file) ? file : null
  }
}
