// WhatsApp via Baileys: the bridge links as a companion device ("Linked devices" in WhatsApp).
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import pino from 'pino'
import makeWASocket, {
  aesEncryptGCM, Browsers, decryptPollVote, DisconnectReason, downloadMediaMessage, fetchLatestWaWebVersion, hmacSign,
  jidNormalizedUser, normalizeMessageContent, proto, sha256, useMultiFileAuthState,
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
  // WhatsApp rejects linking ("Couldn't link device") from an outdated web client version,
  // so ask for the current one instead of relying on the version baked into Baileys.
  const { version } = await fetchLatestWaWebVersion()
  const s = sock = makeWASocket({
    version, auth, logger, browser: Browsers.ubuntu('Chrome'), markOnlineOnConnect: false, syncFullHistory: false,
  })

  s.ev.on('creds.update', saveCreds)
  s.ev.on('connection.update', ({ connection, lastDisconnect, qr }) => {
    if (qr) setState({ state: 'qr', qr })
    if (connection === 'open') {
      setState({ state: 'linked', qr: null, me: '+' + s.user.id.split(/[:@]/)[0] })
      s.groupFetchAllParticipating()
        .then(groups => Object.values(groups).forEach(g => store.renameChat(chatId(g.id), g.subject)))
        .catch(e => logger.warn(e, 'group fetch failed'))
      phonesForLidChats().catch(e => logger.warn(e, 'lid lookup failed'))
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

// Some chats are only known by their LID (a private WhatsApp id), so look up their phone number,
// which the app uses to show the name from the iPhone's contacts.
const pnForLid = lid => sock.signalRepository.lidMapping.getPNForLID(lid).catch(() => null)
async function phonesForLidChats() {
  for (const id of store.chatIdsLike('wa:%@lid')) {
    const pn = await pnForLid(id.slice(3))
    if (pn) store.setPhone(id, '+' + jidNormalizedUser(pn).split('@')[0])
  }
}

// The chat a message belongs to: by phone number where we can, but keep using a LID chat that already exists.
async function chatJid(key) {
  const jid = key.remoteJid
  if (!jid.endsWith('@lid') || store.getChat(chatId(jid))) return jid
  if (key.remoteJidAlt?.endsWith('@s.whatsapp.net')) return key.remoteJidAlt
  const pn = await pnForLid(jid)
  return pn ? jidNormalizedUser(pn) : jid
}

// Every jid a key's author may go by (phone number and LID); the author's id prefers the phone number.
const userJids = key => [...new Set([key.participant, key.participantAlt, key.remoteJid, key.remoteJidAlt]
  .filter(j => j && !j.endsWith('@g.us')).map(jidNormalizedUser))]
const myJids = () => [sock.user?.id, sock.user?.lid].filter(Boolean).map(jidNormalizedUser)
const authorOf = key => key.fromMe ? store.ME : userJids(key).find(j => j.endsWith('@s.whatsapp.net')) || userJids(key)[0]

// We keep each message's key (to react to it) and, for photos and polls, the message itself
// (to download the photo later, and for the secret that poll votes are encrypted with).
function makeRef(msg, keepMessage) {
  const raw = keepMessage ? Buffer.from(proto.Message.encode(msg.message).finish()).toString('base64') : undefined
  return JSON.stringify({ key: msg.key, raw })
}
function readRef(messageId) {
  const ref = store.getRef(messageId)
  if (!ref) return null
  const { key, raw } = JSON.parse(ref)
  return { key, message: raw ? proto.Message.decode(Buffer.from(raw, 'base64')) : null }
}

const pollOf = c => c && (c.pollCreationMessage || c.pollCreationMessageV2 || c.pollCreationMessageV3)
// Votes name the picked options by their SHA-256 hash.
const optionNames = (poll, hashes = []) =>
  poll.options.filter(name => hashes.some(h => sha256(Buffer.from(name)).equals(Buffer.from(h))))

// What we show for each kind of WhatsApp message. Anything else (edits, receipts…) is skipped.
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
  const poll = pollOf(c)
  if (poll) {
    const options = (poll.options || []).map(o => o.optionName || '')
    return { text: '', poll: { question: poll.name || 'Poll', options, multi: poll.selectableOptionsCount !== 1 } }
  }
  return {}
}

// Stores one WhatsApp message (or applies a reaction or poll vote) and returns the message it touched.
async function handle(msg, { live = true, imageBuffer = null } = {}) {
  const key = msg.key
  if (!key.remoteJid || key.remoteJid.endsWith('@broadcast') || key.remoteJid.endsWith('@newsletter')) return null
  const content = normalizeMessageContent(msg.message)
  if (!content) return null
  const jid = await chatJid(key)
  const id = chatId(jid)

  if (content.reactionMessage) {
    const r = content.reactionMessage
    return store.react(`${id}/${r.key.id}`, authorOf(key), r.text || '', { live })
  }
  if (content.pollUpdateMessage) return pollVote(id, key, content.pollUpdateMessage, live)

  const { text, image, poll } = describe(content)
  if (!text && !image && !poll) return null

  const isGroup = jid.endsWith('@g.us')
  const isNew = !store.getChat(id)
  store.ensureChat(id, 'whatsapp', { isGroup, name: isGroup || key.fromMe ? null : msg.pushName })
  if (isGroup && isNew) sock.groupMetadata(jid).then(g => store.renameChat(id, g.subject)).catch(() => {})

  const message = {
    id: `${id}/${key.id}`, chatId: id, fromMe: !!key.fromMe,
    sender: key.fromMe ? '' : msg.pushName || '', senderId: key.fromMe || !authorOf(key) ? '' : chatId(authorOf(key)), text,
    ts: toNumber(msg.messageTimestamp) * 1000 || Date.now(),
    media: image || null, poll, ref: makeRef(msg, image || poll),
  }
  const existing = store.getMessage(message.id)
  if (existing) return existing

  // New photos are fetched right away; photos from history when the app first shows them.
  if (imageBuffer) store.saveMedia(message.id, imageBuffer)
  else if (image && live) await download(message.id, msg).catch(e => logger.warn(e, 'image download failed'))
  store.addMessage(message, { live })

  // History sync brings reactions and (already decrypted) poll votes along with the message.
  for (const r of msg.reactions || []) store.react(message.id, authorOf(r.key), r.text || '', { live: false })
  for (const u of poll ? msg.pollUpdates || [] : []) {
    store.vote(message.id, authorOf(u.pollUpdateMessageKey), optionNames(poll, u.vote?.selectedOptions), { live: false })
  }
  return store.getMessage(message.id)
}

async function download(messageId, msg) {
  const buffer = await downloadMediaMessage(msg, 'buffer', {}, { logger, reuploadRequest: sock.updateMediaMessage })
  store.saveMedia(messageId, buffer)
}

// Called when the app asks for a photo we haven't downloaded yet. Returns whether it worked.
export async function fetchMedia(message) {
  const ref = readRef(message.id)
  if (!ref?.message || state.state !== 'linked') return false
  await download(message.id, ref)
  return true
}

// Votes are encrypted with a key derived from the poll's secret and the creator's and voter's jids.
// We don't know which form (phone number or LID) WhatsApp used for each, so try them all.
function pollVote(id, key, update, live) {
  const pollId = `${id}/${update.pollCreationMessageKey.id}`
  const ref = readRef(pollId)
  const secret = ref?.message?.messageContextInfo?.messageSecret
  const poll = ref?.message && describe(normalizeMessageContent(ref.message)).poll
  if (!secret || !poll) return null
  for (const pollCreatorJid of ref.key.fromMe ? myJids() : userJids(ref.key)) {
    for (const voterJid of key.fromMe ? myJids() : userJids(key)) {
      let vote
      try {
        vote = decryptPollVote(update.vote, { pollCreatorJid, pollMsgId: ref.key.id, pollEncKey: secret, voterJid })
      } catch {
        continue
      }
      return store.vote(pollId, authorOf(key), optionNames(poll, vote.selectedOptions), { live })
    }
  }
  logger.warn({ pollId }, 'could not decrypt poll vote')
  return null
}

function requireLinked() {
  if (!sock || state.state !== 'linked') throw store.httpError(503, 'WhatsApp is not linked yet')
}

export async function send(chat, { text, image, poll }) {
  requireLinked()
  const content = poll ? { poll: { name: poll.question, values: poll.options, selectableCount: poll.multi ? 0 : 1 } }
    : image ? { image, caption: text || undefined } : { text }
  const sent = await sock.sendMessage(jidOf(chat), content)
  return handle(sent, { imageBuffer: image })
}

export async function react(chat, message, emoji) {
  requireLinked()
  const ref = readRef(message.id)
  if (!ref) throw store.httpError(409, 'You can only react to messages that arrived after this update')
  await sock.sendMessage(jidOf(chat), { react: { text: emoji, key: ref.key } })
  return store.react(message.id, store.ME, emoji)
}

// Sends my vote (the options I picked; none clears it), encrypted the way pollVote() decrypts it.
export async function vote(chat, message, picked) {
  requireLinked()
  const ref = readRef(message.id)
  const secret = ref?.message?.messageContextInfo?.messageSecret
  if (!secret || !message.poll) throw store.httpError(409, 'You can only vote on polls that arrived after this update')
  const names = message.poll.options.map(o => o.name).filter(n => picked.includes(n))
  const author = ref.key.participant || ref.key.remoteJid
  const lid = author.endsWith('@lid') || ref.key.addressingMode === 'lid'
  const me = jidNormalizedUser(lid && sock.user.lid ? sock.user.lid : sock.user.id)
  const creator = ref.key.fromMe ? me : jidNormalizedUser(author)
  const sign = Buffer.concat([Buffer.from(ref.key.id), Buffer.from(creator), Buffer.from(me), Buffer.from('Poll Vote'), Buffer.from([1])])
  const encKey = hmacSign(sign, hmacSign(secret, new Uint8Array(32), 'sha256'), 'sha256')
  const encIv = crypto.randomBytes(12)
  const plain = proto.Message.PollVoteMessage.encode({ selectedOptions: names.map(n => sha256(Buffer.from(n))) }).finish()
  const encPayload = aesEncryptGCM(plain, encKey, encIv, Buffer.from(`${ref.key.id}\u0000${me}`))
  await sock.relayMessage(jidOf(chat), {
    pollUpdateMessage: { pollCreationMessageKey: ref.key, vote: { encPayload, encIv }, senderTimestampMs: Date.now() },
  }, {})
  return store.vote(message.id, store.ME, names)
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
  // A socket gives up waiting after a few QR refreshes (~2.5 min), which would cut a code link
  // short, so request the code on a fresh socket to get its full window.
  const old = sock
  await start()
  old.end(undefined)
  await new Promise((resolve, reject) => {
    sock.ev.on('connection.update', u => u.qr && resolve())
    setTimeout(() => reject(store.httpError(503, 'WhatsApp did not respond, try again')), 20000)
  })
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
