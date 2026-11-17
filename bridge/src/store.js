// SQLite store shared by both networks, plus an event bus the WebSocket clients listen to.
import { DatabaseSync } from 'node:sqlite'
import { EventEmitter } from 'node:events'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

export const DATA = process.env.DATA_DIR || './data'
for (const dir of ['media', 'avatars']) fs.mkdirSync(path.join(DATA, dir), { recursive: true })

export const bus = new EventEmitter()
export const httpError = (status, message) => Object.assign(new Error(message), { status })
export const sha1 = s => crypto.createHash('sha1').update(s).digest('hex')

const db = new DatabaseSync(path.join(DATA, 'convo.db'))
db.exec(`
  CREATE TABLE IF NOT EXISTS chats (
    id TEXT PRIMARY KEY, network TEXT NOT NULL, name TEXT, is_group INTEGER NOT NULL DEFAULT 0,
    unread INTEGER NOT NULL DEFAULT 0, last_ts INTEGER NOT NULL DEFAULT 0,
    last_text TEXT NOT NULL DEFAULT '', last_sender TEXT NOT NULL DEFAULT '', last_from_me INTEGER NOT NULL DEFAULT 0
  );
  CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY, chat_id TEXT NOT NULL, from_me INTEGER NOT NULL, sender TEXT NOT NULL,
    text TEXT NOT NULL, ts INTEGER NOT NULL, media TEXT
  );
  CREATE INDEX IF NOT EXISTS messages_chat_ts ON messages (chat_id, ts);
`)

// Chat ids are "wa:<jid>" or "sg:<number|uuid|group.id>"; show a phone number when we know no name.
function fallbackName(id) {
  const addr = id.slice(3), user = addr.split('@')[0]
  return /^\d+$/.test(user) ? '+' + user : addr
}
const toChat = r => r && ({
  id: r.id, network: r.network, name: r.name || fallbackName(r.id), isGroup: !!r.is_group,
  unread: r.unread, lastTs: r.last_ts, lastText: r.last_text, lastSender: r.last_sender, lastFromMe: !!r.last_from_me,
})
const toMessage = r => r && ({
  id: r.id, chatId: r.chat_id, fromMe: !!r.from_me, sender: r.sender, text: r.text, ts: r.ts, media: r.media,
})

export const getChat = id => toChat(db.prepare('SELECT * FROM chats WHERE id = ?').get(id))
export const getMessage = id => toMessage(db.prepare('SELECT * FROM messages WHERE id = ?').get(id))
export const listChats = () => db.prepare('SELECT * FROM chats ORDER BY last_ts DESC').all().map(toChat)

export function listMessages(chatId, before = Number.MAX_SAFE_INTEGER, limit = 60) {
  return db.prepare('SELECT * FROM messages WHERE chat_id = ? AND ts < ? ORDER BY ts DESC LIMIT ?')
    .all(chatId, before, limit).map(toMessage).reverse()
}

// Creates the chat if needed; a name given here only fills in a missing one.
export function ensureChat(id, network, { name = null, isGroup = false } = {}) {
  db.prepare(`INSERT INTO chats (id, network, name, is_group) VALUES (?, ?, ?, ?)
    ON CONFLICT (id) DO UPDATE SET name = COALESCE(chats.name, excluded.name)`).run(id, network, name || null, isGroup ? 1 : 0)
}

// Authoritative name (address book, group subject). Only touches chats that exist.
export function renameChat(id, name) {
  if (!name) return
  if (db.prepare('UPDATE chats SET name = ? WHERE id = ? AND name IS NOT ?').run(name, id, name).changes) {
    bus.emit('chat', getChat(id))
  }
}

export function markRead(id) {
  db.prepare('UPDATE chats SET unread = 0 WHERE id = ?').run(id)
  const chat = getChat(id)
  bus.emit('chat', chat)
  return chat
}

// live = a new message (counts as unread, pushed to clients). History imports pass live: false.
export function addMessage(m, { live = true } = {}) {
  const inserted = db.prepare('INSERT OR IGNORE INTO messages (id, chat_id, from_me, sender, text, ts, media) VALUES (?, ?, ?, ?, ?, ?, ?)')
    .run(m.id, m.chatId, m.fromMe ? 1 : 0, m.sender || '', m.text || '', m.ts, m.media || null).changes
  if (!inserted) return null
  db.prepare(`UPDATE chats SET last_ts = ?, last_text = ?, last_sender = ?, last_from_me = ? WHERE id = ? AND last_ts <= ?`)
    .run(m.ts, m.text || (m.media ? '📷 Photo' : ''), m.sender || '', m.fromMe ? 1 : 0, m.chatId, m.ts)
  if (live) db.prepare(`UPDATE chats SET unread = ${m.fromMe ? '0' : 'unread + 1'} WHERE id = ?`).run(m.chatId)
  const message = getMessage(m.id)
  if (live) bus.emit('message', { chat: getChat(m.chatId), message })
  return message
}

export const mediaPath = messageId => path.join(DATA, 'media', sha1(messageId))
export const saveMedia = (messageId, buffer) => fs.writeFileSync(mediaPath(messageId), buffer)
